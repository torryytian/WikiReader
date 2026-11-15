import Foundation
import SwiftData
import Testing
@testable import WikiReader

/// The English Reader site as an article source (docs/site-api-for-ios.md). `Fixtures/site/` holds the live API's
/// answers, captured with curl on 2026-11-05: the catalog (4 articles), The Paradox of Convenience and COVID-19
/// (one piece of it without audio yet, list items, figures and tables).
enum SiteFixture {
    static let essayID = "c73e080c-2414-475a-a57d-34d395598637"
    static let australiaID = "73d62e6f-a9a2-4365-9244-1f2249e3a79f"
    static let covidID = "08fbef10-d1ab-4b39-9fb5-64be1089a0f5"
    static let usaID = "e490d1f0-d0ae-4eb1-b572-e4656518773a"

    static func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Fixture.data(name)) as! [String: Any]
    }

    /// The live catalog's items.
    static func items() throws -> [[String: Any]] {
        try json("site_catalog")["items"] as! [[String: Any]]
    }

    /// A catalog page around `items`.
    static func page(_ items: [[String: Any]], latest: Int, maxSeq: Int, hasMore: Bool = false, epoch: String = "yr2oIK3N") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "epoch": epoch, "maxSeq": maxSeq, "latest": latest, "hasMore": hasMore, "items": items,
        ])
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

struct SiteFormatTests {
    @Test func theCatalogListsArticlesWithWhatTheyAreCalledEverywhere() throws {
        let page = try JSONDecoder().decode(SiteCatalogPage.self, from: Fixture.data("site_catalog"))
        #expect(page.epoch == "yr2oIK3N")
        #expect(!page.hasMore)
        let articles = page.items.compactMap { if case .article(let a) = $0 { a } else { nil } }
        #expect(articles.map(\.title) == ["The Paradox of Convenience", "Australia", "COVID-19", "United States"])
        let usa = try #require(articles.last)
        #expect(usa.isWikipedia)
        #expect(usa.canonicalUrl == URL(string: "https://en.wikipedia.org/wiki/United_States"))
        #expect(usa.audio?.readyChunks == 191)
        let essay = try #require(articles.first)
        #expect(!essay.isWikipedia)
        #expect(essay.canonicalUrl == URL(string: "https://english.thrones.wang/a/the-paradox-of-convenience"))
        #expect(essay.category?.name == "Society & Ideas")

        let removed = try JSONDecoder().decode(SiteCatalogPage.self, from: SiteFixture.page(
            [["id": SiteFixture.essayID, "seq": 5, "removed": true]], latest: 5, maxSeq: 5
        ))
        #expect(removed.items == [.removed(id: SiteFixture.essayID, seq: 5)])
    }

    @Test func theReadersOwnKeysFindTheSitesFiles() throws {
        for name in ["site_article_paradox", "site_article_covid"] {
            let detail = try SiteClient.decodeArticle(Fixture.data(name))
            let voice = try #require(detail.narration?.voice)
            let files = detail.audioFiles
            #expect(detail.mismatchedChunks == 0)
            // What the OpenAI engine asks the cache for while reading, with the site's voice.
            var asked = 0, found = 0
            for block in detail.contentBlocks {
                let text = block.text as NSString
                for range in SpeechChunking.chunks(of: block.text) {
                    asked += 1
                    let key = SpeechAudioCache.key(for: OpenAISpeechEngine.request(for: text.substring(with: range), voice: voice))
                    if files[key] != nil { found += 1 }
                }
            }
            #expect(found == files.count)
            #expect(asked == (name == "site_article_paradox" ? 13 : 241))
            #expect(found == (name == "site_article_paradox" ? 13 : 240))  // one COVID-19 piece isn't made yet
        }
    }

    @Test func headingsParagraphsAndListItemsAreReadFiguresAndTablesAreNot() throws {
        let essay = try SiteClient.decodeArticle(Fixture.data("site_article_paradox"))
        #expect(essay.contentBlocks.first == .paragraph(essay.blocks[0].text!))
        #expect(essay.contentBlocks[1] == .heading("Hedonic adaptation", level: 2))
        let covid = try SiteClient.decodeArticle(Fixture.data("site_article_covid"))
        #expect(covid.contentBlocks.count == 241)
        #expect(covid.blocks.count { $0.kind == "figure" } == 28)
        #expect(covid.contentBlocks.allSatisfy { !$0.text.isEmpty })
    }

    @Test func aPieceWhoseKeyDoesntMatchItsTextIsNotUsed() throws {
        var detail = try SiteFixture.json("site_article_paradox")
        var blocks = detail["blocks"] as! [[String: Any]]
        var chunks = blocks[0]["chunks"] as! [[String: Any]]
        chunks[0]["text"] = "Something else entirely."
        blocks[0]["chunks"] = chunks
        detail["blocks"] = blocks
        let decoded = try SiteClient.decodeArticle(SiteFixture.data(detail))
        #expect(decoded.audioFiles.count == 12)
        #expect(decoded.mismatchedChunks == 1)
    }

    @Test func compressedCopiesOfTheNarrationArePlayedToo() throws {
        // Since 2026-11-05 the site serves compressed copies (`sourceIdentical: false`, §4.2): they play like the
        // originals; that they never go to Drive from here is DriveAudioStore's test.
        var detail = try SiteFixture.json("site_article_paradox")
        let originals = try SiteClient.decodeArticle(SiteFixture.data(detail)).audioFiles
        var narration = detail["narration"] as! [String: Any]
        narration["sourceIdentical"] = false
        narration["profile"] = "mp3-48k"
        detail["narration"] = narration
        #expect(!originals.isEmpty)
        #expect(try SiteClient.decodeArticle(SiteFixture.data(detail)).audioFiles == originals)
    }
}

/// Answers the app API's requests, keeping them.
actor FakeSite {
    private(set) var requests: [URLRequest] = []
    /// Path and query → (status, content type, body).
    private var routes: [String: (Int, String, Data)] = [:]

    var paths: [String] { requests.map { Self.route(of: $0.url!) } }

    nonisolated static func route(of url: URL) -> String {
        url.path() + (url.query().map { "?" + $0 } ?? "")
    }

    func answer(_ path: String, _ body: Data, status: Int = 200, type: String = "application/json; charset=utf-8") {
        routes[path] = (status, type, body)
    }

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        let (status, type, body) = routes[Self.route(of: request.url!)]
            ?? (404, "application/json", Data(#"{"error":{"code":"not_found"}}"#.utf8))
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!)
    }

    /// Without an access token unless given one (never the one in this simulator's Keychain).
    nonisolated var client: SiteClient { client(token: nil) }

    nonisolated func client(token: String?) -> SiteClient {
        SiteClient(baseURL: URL(string: "https://site.test")!, transport: { request in await self.handle(request) }, token: { token })
    }
}

@MainActor
struct SiteLibraryTests {
    let site = FakeSite()
    let directory = URL.temporaryDirectory.appending(path: "Site-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeLibrary() -> SiteLibrary {
        SiteLibrary(directory: directory, client: site.client)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func catalog(since: Int) -> String {
        "/api/app/v1/articles?since=\(since)&limit=200"
    }

    /// The catalog requests made (each sync also asks for the optional category list).
    private func catalogRequests() async -> [String] {
        await site.paths.filter { $0.hasPrefix("/api/app/v1/articles?") }
    }

    private func detailPath(_ id: String) -> String {
        "/api/app/v1/articles/\(id)"
    }

    /// The live catalog, as two pages.
    private func serveCatalog() async throws {
        let items = try SiteFixture.items()
        await site.answer(catalog(since: 0), try SiteFixture.page(Array(items[0..<2]), latest: 2, maxSeq: 4, hasMore: true))
        await site.answer(catalog(since: 2), try SiteFixture.page(Array(items[2...]), latest: 4, maxSeq: 4))
    }

    @Test func theCatalogComesInPagesAndThenOnlyWhatChanged() async throws {
        try await serveCatalog()
        let library = makeLibrary()
        await library.sync()
        #expect(library.state == .synced)
        #expect(library.articles.count == 4)
        #expect(await catalogRequests() == [catalog(since: 0), catalog(since: 2)])
        #expect(await site.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == SiteClient.userAgent })
        #expect(!SiteClient.userAgent.contains("@"))

        // Next time, after a restart too: only what changed after 4.
        await site.answer(catalog(since: 4), try SiteFixture.page([["id": SiteFixture.essayID, "seq": 5, "removed": true]], latest: 5, maxSeq: 5))
        let again = makeLibrary()
        await again.sync()
        #expect(await catalogRequests().last == catalog(since: 4))
        #expect(again.articles.map(\.title).sorted() == ["Australia", "COVID-19", "United States"])
    }

    @Test func aRestoredSiteDatabaseMeansFetchingEverythingAgain() async throws {
        try await serveCatalog()
        let library = makeLibrary()
        await library.sync()

        // Restored from a backup: a new epoch, and only the essay is published there.
        let essay = try SiteFixture.items()[0].merging(["seq": 1]) { $1 }
        await site.answer(catalog(since: 4), try SiteFixture.page([], latest: 4, maxSeq: 1, epoch: "new"))
        await site.answer(catalog(since: 0), try SiteFixture.page([essay], latest: 1, maxSeq: 1, epoch: "new"))
        await library.sync()
        #expect(library.articles.map(\.title) == ["The Paradox of Convenience"])
        // And from there on, the new numbers.
        await site.answer(catalog(since: 1), try SiteFixture.page([], latest: 1, maxSeq: 1, epoch: "new"))
        await library.sync()
        #expect(await catalogRequests().last == catalog(since: 1))
    }

    @Test func aWebPageInsteadOfDataIsReportedAsABotCheck() async throws {
        await site.answer(catalog(since: 0), Data("<html>Just a moment…</html>".utf8), type: "text/html")
        let library = makeLibrary()
        await library.sync()
        #expect(library.state == .failed(SiteError.notJSON.message))
        #expect(library.articles.isEmpty)
    }

    @Test func openingMakesAnArticleOnceAndUpdatesItWhenTheSiteChangesIt() async throws {
        try await serveCatalog()
        await site.answer(detailPath(SiteFixture.essayID), try Fixture.data("site_article_paradox"))
        let library = makeLibrary()
        await library.sync()
        let context = try makeContext()
        let summary = try #require(library.article(id: SiteFixture.essayID))

        let article = try await library.open(summary, in: context)
        #expect(article.title == "The Paradox of Convenience")
        #expect(article.origin == Article.siteOrigin)
        #expect(article.sourceURL == summary.canonicalUrl)
        #expect(article.blocks.count == 13)
        #expect(library.narrationVoice(forArticleURL: article.sourceURL) == NarrationVoice("alloy"))
        #expect(library.hasAudio)
        func detailRequests() async -> Int { await site.paths.count { $0.hasPrefix("/api/app/v1/articles/") } }
        #expect(await detailRequests() == 1)

        // Unchanged: opened again without asking the site.
        article.lastReadBlockIndex = 12
        let same = try await library.open(try #require(library.article(id: SiteFixture.essayID)), in: context)
        #expect(same === article)
        #expect(await detailRequests() == 1)
        #expect(try context.fetch(FetchDescriptor<Article>()).count == 1)

        // The site edited it: the text is updated in place and the reading position kept within it.
        var edited = try SiteFixture.json("site_article_paradox")
        edited["blocks"] = Array((edited["blocks"] as! [[String: Any]]).dropLast(3))
        edited["contentVersion"] = "edited"
        edited["seq"] = 20
        await site.answer(detailPath(SiteFixture.essayID), try SiteFixture.data(edited))
        var changed = summary
        changed.contentVersion = "edited"
        let updated = try await library.open(changed, in: context)
        #expect(updated === article)
        #expect(article.blocks.count == 10)
        #expect(article.lastReadBlockIndex == 9)
        #expect(await detailRequests() == 2)
    }

    @Test func aWikipediaArticleAlreadyAddedIsUsedAsItIs() async throws {
        try await serveCatalog()
        await site.answer(detailPath(SiteFixture.covidID), try Fixture.data("site_article_covid"))
        let library = makeLibrary()
        await library.sync()
        let covid = try #require(library.article(id: SiteFixture.covidID))

        let context = try makeContext()
        let mine = Article(title: "COVID-19", sourceURL: covid.canonicalUrl, blocks: [.paragraph("My own copy.")])
        context.insert(mine)
        let opened = try await library.open(covid, in: context)
        #expect(opened === mine)
        #expect(mine.blocks == [.paragraph("My own copy.")])
        #expect(mine.origin == Article.wikipediaOrigin)
        #expect(try context.fetch(FetchDescriptor<Article>()).count == 1)
        #expect(library.links[SiteFixture.covidID]?.ownsText == false)
        // Its narration is still the site's where the text is the same.
        #expect(library.narrationVoice(forArticleURL: mine.sourceURL) == NarrationVoice("alloy"))
    }

    @Test func offlineAnArticleOpenedBeforeStillOpens() async throws {
        try await serveCatalog()
        await site.answer(detailPath(SiteFixture.essayID), try Fixture.data("site_article_paradox"))
        let library = makeLibrary()
        await library.sync()
        let context = try makeContext()
        let article = try await library.open(try #require(library.article(id: SiteFixture.essayID)), in: context)

        await site.answer(detailPath(SiteFixture.essayID), Data(), status: 503)
        var changed = try #require(library.article(id: SiteFixture.essayID))
        changed.contentVersion = "newer"
        #expect(try await library.open(changed, in: context) === article)

        // Never opened and unreachable: an error.
        let usa = try #require(library.article(id: SiteFixture.usaID))
        await #expect(throws: SiteError.notFound) { try await library.open(usa, in: context) }
    }
}

/// Serves narration files: a status per request in turn (the last one repeats), counting what was asked.
actor FakeAudioHost {
    private(set) var requested: [URL] = []
    private var statuses: [Int]

    init(statuses: [Int] = [200]) {
        self.statuses = statuses
    }

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
        requested.append(request.url!)
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        let body = status == 200 ? Data("ID3 site".utf8) : Data()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated var transport: SiteAudioSource.Transport {
        { request in await self.handle(request) }
    }
}

@MainActor
struct SiteAudioTests {
    let site = FakeSite()
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "SiteAudio-\(UUID().uuidString)"))
    let sent = SentInputs()

    private var openAI: OpenAITTSClient {
        let sent = sent
        return OpenAITTSClient(transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            await sent.record(body["input"]!)
            return (Data("ID3 openai".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, retry: .never)
    }

    /// A library that has opened The Paradox of Convenience, so it knows the site's files for it.
    private func libraryWithTheEssay() async throws -> (SiteLibrary, [ContentBlock]) {
        let items = try SiteFixture.items()
        await site.answer("/api/app/v1/articles?since=0&limit=200", try SiteFixture.page(items, latest: 4, maxSeq: 4))
        await site.answer("/api/app/v1/articles/\(SiteFixture.essayID)", try Fixture.data("site_article_paradox"))
        let library = SiteLibrary(directory: URL.temporaryDirectory.appending(path: "SiteAudio-\(UUID().uuidString)"), client: site.client)
        await library.sync()
        let context = ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let article = try await library.open(try #require(library.article(id: SiteFixture.essayID)), in: context)
        return (library, article.blocks)
    }

    @Test func theSiteIsAskedFirstThenDriveThenOpenAI() async throws {
        let (library, blocks) = try await libraryWithTheEssay()
        let host = FakeAudioHost()
        let drive = FakeRemote()
        let first = blocks[0].text
        drive.has = [first, "On Drive."]
        let generations = SpeechGenerations(remote: drive, site: SiteAudioSource(library: library, retryDelay: .zero, transport: host.transport))

        let fromSite = await generations.generate(OpenAISpeechEngine.request(for: first, voice: "alloy"), apiKey: "sk", client: openAI, cache: cache).value
        #expect(try Data(contentsOf: fromSite.get()) == Data("ID3 site".utf8))
        #expect(await host.requested.first?.host() == "audio.thrones.wang")

        // Not the site's: no request to it at all, Drive has it.
        let fromDrive = await generations.generate(OpenAISpeechEngine.request(for: "On Drive.", voice: "alloy"), apiKey: "sk", client: openAI, cache: cache).value
        #expect(try Data(contentsOf: fromDrive.get()) == Data("ID3 remote".utf8))
        #expect(await host.requested.count == 1)

        // Another voice is another file: the site doesn't have it (nor does Drive, here), so it is generated.
        let second = blocks[1].text
        let otherVoice = await generations.generate(OpenAISpeechEngine.request(for: second, voice: "marin"), apiKey: "sk", client: openAI, cache: cache).value
        #expect(try Data(contentsOf: otherVoice.get()) == Data("ID3 openai".utf8))
        #expect(await sent.inputs == [second])
        #expect(await host.requested.count == 1)
    }

    @Test func withoutAKeyOrDriveTheSitesNarrationStillPlays() async throws {
        let (library, blocks) = try await libraryWithTheEssay()
        let drive = FakeRemote()
        drive.isEnabled = false
        let generations = SpeechGenerations(remote: drive, site: SiteAudioSource(library: library, retryDelay: .zero, transport: FakeAudioHost().transport))
        #expect(generations.canWorkWithoutKey)
        let hit = await generations.generate(OpenAISpeechEngine.request(for: blocks[1].text, voice: "alloy"), apiKey: nil, client: openAI, cache: cache).value
        let miss = await generations.generate(OpenAISpeechEngine.request(for: "Elsewhere.", voice: "alloy"), apiKey: nil, client: openAI, cache: cache).value
        #expect((try? hit.get()) != nil)
        #expect(miss == .failure(.missingKey))
        #expect(await sent.inputs.isEmpty)
    }

    @Test func aPassingFailureIsTriedAgainAMissingFileIsNot() async throws {
        let (library, blocks) = try await libraryWithTheEssay()
        let request = OpenAISpeechEngine.request(for: blocks[2].text, voice: "alloy")

        let flaky = FakeAudioHost(statuses: [503, 200])
        #expect(await SiteAudioSource(library: library, retryDelay: .zero, transport: flaky.transport).fetch(request, into: cache) != nil)
        #expect(await flaky.requested.count == 2)

        let gone = FakeAudioHost(statuses: [404])
        let other = OpenAISpeechEngine.request(for: blocks[3].text, voice: "alloy")
        #expect(await SiteAudioSource(library: library, retryDelay: .zero, transport: gone.transport).fetch(other, into: cache) == nil)
        #expect(await gone.requested.count == 1)
        #expect(cache.cachedFile(for: other) == nil)
    }

    @Test func aFileMovedOnTheSiteIsFoundAgainAtItsNewAddress() async throws {
        let (library, blocks) = try await libraryWithTheEssay()
        let request = OpenAISpeechEngine.request(for: blocks[2].text, voice: "alloy")
        let key = SpeechAudioCache.key(for: request)
        let old = try #require(library.audioURL(forKey: key)).absoluteString
        let moved = old.replacingOccurrences(of: "/audio/", with: "/audio/renamed/")

        // The site renamed its files (§10.4): the article now lists new addresses, the old one answers 404.
        var detail = try SiteFixture.json("site_article_paradox")
        detail["blocks"] = (detail["blocks"] as! [[String: Any]]).map { block in
            var block = block
            if let chunks = block["chunks"] as? [[String: Any]] {
                block["chunks"] = chunks.map { chunk in
                    var chunk = chunk
                    if let url = chunk["url"] as? String { chunk["url"] = url.replacingOccurrences(of: "/audio/", with: "/audio/renamed/") }
                    return chunk
                }
            }
            return block
        }
        await site.answer("/api/app/v1/articles/\(SiteFixture.essayID)", try SiteFixture.data(detail))
        let host = FakeAudioHost(statuses: [404, 200])

        let file = await SiteAudioSource(library: library, retryDelay: .zero, transport: host.transport).fetch(request, into: cache)
        #expect(file != nil)
        #expect(await host.requested.map(\.absoluteString) == [old, moved])
        #expect(library.audioURL(forKey: key)?.absoluteString == moved)
    }
}

/// Access tokens and previews (docs/site-api-for-ios.md §10).
@MainActor
struct SiteAccessTests {
    let site = FakeSite()
    let directory = URL.temporaryDirectory.appending(path: "SiteAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
    let detailPath = "/api/app/v1/articles/\(SiteFixture.essayID)"

    private func library(token: String? = nil) async throws -> SiteLibrary {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try SiteFixture.page(try SiteFixture.items(), latest: 4, maxSeq: 4))
        let library = SiteLibrary(directory: directory, client: site.client(token: token))
        await library.sync()
        return library
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    /// The essay as the site sends it to a reader without a token while its limit is on: the first blocks only.
    private func previewOfTheEssay(contentVersion: String? = nil) throws -> Data {
        var detail = try SiteFixture.json("site_article_paradox")
        detail["blocks"] = Array((detail["blocks"] as! [[String: Any]]).prefix(3))
        detail["access"] = "preview"
        detail["preview"] = ["percent": 20, "shown": 112, "total": 556]
        if let contentVersion { detail["contentVersion"] = contentVersion }
        return try SiteFixture.data(detail)
    }

    private func detailRequests() async -> Int {
        await site.paths.count { $0 == detailPath }
    }

    @Test func theTokenIsSentAsABearerHeaderAndOnlyWhenThereIsOne() async throws {
        _ = try await library(token: " er_abc\n")
        #expect(await !site.requests.isEmpty)
        #expect(await site.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer er_abc" })

        let bare = FakeSite()
        await bare.answer("/api/app/v1/articles?since=0&limit=200", try SiteFixture.page([], latest: 0, maxSeq: 0))
        _ = try await bare.client(token: nil).catalog(since: 0)
        _ = try await bare.client(token: "").catalog(since: 0)
        #expect(await bare.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func aRefusedTokenIsReportedNotDroppedToTryAgain() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", Data(#"{"error":{"code":"invalid_token"}}"#.utf8), status: 401)
        let library = SiteLibrary(directory: directory, client: site.client(token: "er_revoked"))
        await library.sync()
        #expect(library.state == .failed(SiteError.invalidToken.message))
        #expect(library.tokenRefused)
        #expect(await site.requests.count == 1)

        // A token the site takes again (as after pasting a new one): the warning goes.
        await site.answer("/api/app/v1/categories", try Fixture.data("site_categories"))
        await library.checkToken()
        #expect(!library.tokenRefused)
    }

    @Test func rateLimitedRequestsWaitAsToldAndTryAgain() async throws {
        actor Counter {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let empty = try SiteFixture.page([], latest: 0, maxSeq: 0)
        func client(limitedTimes: Int, retryAfter: String) -> (SiteClient, Counter) {
            let counter = Counter()
            let client = SiteClient(baseURL: URL(string: "https://site.test")!, transport: { request in
                let status = await counter.next() <= limitedTimes ? 429 : 200
                let headers = ["Content-Type": "application/json", "Retry-After": retryAfter]
                return (status == 200 ? empty : Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
            }, token: { "er_x" })
            return (client, counter)
        }

        let (twice, twiceCount) = client(limitedTimes: 2, retryAfter: "0")
        #expect(try await twice.catalog(since: 0).items.isEmpty)
        #expect(await twiceCount.count == 3)

        let (always, alwaysCount) = client(limitedTimes: 10, retryAfter: "0")
        await #expect(throws: SiteError.rateLimited) { try await always.catalog(since: 0) }
        #expect(await alwaysCount.count == 3)

        // Told to wait longer than is worth it: gives up at once.
        let (long, longCount) = client(limitedTimes: 10, retryAfter: "3600")
        await #expect(throws: SiteError.rateLimited) { try await long.catalog(since: 0) }
        #expect(await longCount.count == 1)
    }

    @Test func aPreviewIsKeptAsOneAndTheWholeArticleReplacesItWhenTheSiteSendsIt() async throws {
        let library = try await library()
        await site.answer(detailPath, try previewOfTheEssay())
        let context = try makeContext()
        let summary = try #require(library.article(id: SiteFixture.essayID))
        let previewBlocks = try SiteClient.decodeArticle(try previewOfTheEssay()).contentBlocks

        let article = try await library.open(summary, in: context)
        #expect(article.blocks == previewBlocks)
        #expect(library.preview(forArticleURL: article.sourceURL)?.percent == 20)
        #expect(library.links[SiteFixture.essayID]?.preview?.total == 556)

        // Opened again, same version: asked again since it is only a preview, and now the site sends it all.
        await site.answer(detailPath, try Fixture.data("site_article_paradox"))
        let whole = try await library.open(summary, in: context)
        #expect(whole === article)
        #expect(article.blocks.count == 13)
        #expect(library.preview(forArticleURL: article.sourceURL) == nil)
        #expect(await detailRequests() == 2)

        // Whole now: opened again without asking.
        _ = try await library.open(summary, in: context)
        #expect(await detailRequests() == 2)
    }

    @Test func aWholeArticleKeptHereIsNeverSwappedForAPreview() async throws {
        let library = try await library()
        await site.answer(detailPath, try Fixture.data("site_article_paradox"))
        let context = try makeContext()
        var summary = try #require(library.article(id: SiteFixture.essayID))
        let article = try await library.open(summary, in: context)
        #expect(article.blocks.count == 13)

        // The site's limit comes on and the article changes: only a preview comes back.
        await site.answer(detailPath, try previewOfTheEssay(contentVersion: "v2"))
        summary.contentVersion = "v2"
        #expect(try await library.open(summary, in: context) === article)
        #expect(article.blocks.count == 13)
        #expect(library.preview(forArticleURL: article.sourceURL) == nil)
        // Its entry still says the old version, so the site is asked again next time.
        _ = try await library.open(summary, in: context)
        #expect(await detailRequests() == 3)
    }
}

/// The library's categories and their covers.
struct SiteCategoryTests {
    private func articles() throws -> [SiteArticleSummary] {
        try JSONDecoder().decode(SiteCatalogPage.self, from: Fixture.data("site_catalog")).items.compactMap {
            if case .article(let article) = $0 { article } else { nil }
        }
    }

    @Test func theCatalogIsGroupedFullestFirstWithOtherLast() throws {
        let groups = SiteCategories.group(try articles())
        #expect(groups.map(\.category.name) == ["Places", "Society & Ideas", "Other"])
        #expect(groups.map(\.articles.count) == [1, 1, 2])
        #expect(groups.last?.articles.map(\.title).sorted() == ["COVID-19", "United States"])
        // The site's number names a category, so a rename keeps it the same one.
        #expect(groups[0].category.id == "c2")
    }

    @Test func levelsAndOrders() throws {
        let all = try articles()
        #expect(SiteCategories.levels(in: all) == ["B2", "C1", "C2"])
        #expect(SiteCategories.sorted(all, by: .easiest).map(\.title) == ["The Paradox of Convenience", "Australia", "United States", "COVID-19"])
        #expect(SiteCategories.sorted(all, by: .shortest).first?.title == "The Paradox of Convenience")
    }

    @Test func everyCategoryGetsACoverEvenOnesThatDontExistYet() {
        #expect(CategoryTheme.forCategory("Places").symbol == "globe.europe.africa.fill")
        #expect(CategoryTheme.forCategory("HISTORY") == CategoryTheme.forCategory("History"))
        // Words in a new category's name.
        #expect(CategoryTheme.forCategory("Sports").symbol == "figure.run")
        #expect(CategoryTheme.forCategory("World Music").symbol == "music.note")
        #expect(CategoryTheme.forCategory("Artificial Intelligence").symbol == "cpu.fill")
        #expect(CategoryTheme.forCategory("Air Travel").symbol == "airplane")  // not "ai", technology
        #expect(CategoryTheme.forCategory("Global Warming").symbol != "building.columns.fill")  // not "war", history
        // Nothing to go by: still a cover, the same one every time.
        let odd = CategoryTheme.forCategory("Zebra Crossing")
        #expect(odd == CategoryTheme.forCategory("Zebra Crossing"))
        #expect(!odd.symbol.isEmpty)
    }
}

/// Downloading a site article's whole narration: free, from the site alone.
@MainActor
struct SiteDownloadTests {
    let site = FakeSite()
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "SiteDownload-\(UUID().uuidString)"))
    let sent = SentInputs()

    @Test func theWholeNarrationComesFromTheSiteAndNothingIsGenerated() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try SiteFixture.page(SiteFixture.items(), latest: 4, maxSeq: 4))
        await site.answer("/api/app/v1/articles/\(SiteFixture.essayID)", try Fixture.data("site_article_paradox"))
        let library = SiteLibrary(directory: URL.temporaryDirectory.appending(path: "SiteDownload-\(UUID().uuidString)"), client: site.client)
        await library.sync()
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let article = try await library.open(try #require(library.article(id: SiteFixture.essayID)), in: container.mainContext)

        let host = FakeAudioHost()
        let sent = sent
        let openAI = OpenAITTSClient(transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            await sent.record(body["input"]!)
            return (Data("ID3 openai".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, retry: .never)
        let generations = SpeechGenerations(remote: FakeRemote(), site: SiteAudioSource(library: library, retryDelay: .zero, transport: host.transport))
        let downloader = AudioDownloader(client: openAI, cache: cache, generations: generations, apiKey: { "sk-test" }, keepAwake: { _ in })

        // What LibraryActions.siteDownloadPrompt plans: the site's voice, only what the site has.
        let voice = try #require(library.narrationVoice(forArticleURL: article.sourceURL))
        var plan = await AudioDownloader.plan(
            for: [AudioDownloader.Source(id: article.persistentModelID, blocksData: article.blocksData)], voice: voice, cache: cache
        )
        plan.markOnDrive { library.audioURL(forKey: $0) != nil }
        var fromSite = plan.onlyFromDrive()
        fromSite.isFromSite = true
        #expect(fromSite.items.count == 13)
        #expect(fromSite.leftOutCharacters == 0)
        #expect(AudioDownloadPrompt.confirm(fromSite).title == "Download from English Reader?")

        downloader.start(fromSite)
        #expect(downloader.isFromSite)
        for _ in 0..<200 where downloader.phase == .running { try await Task.sleep(for: .milliseconds(10)) }
        #expect(downloader.phase == .finished)
        #expect(downloader.donePieces == 13)
        #expect(await host.requested.count == 13)
        #expect(await sent.inputs.isEmpty)
        #expect(await ArticleAudio.status(ofBlocksData: article.blocksData, voice: voice, cache: cache).isComplete)
    }
}

/// The two optional parts asked for later (docs/site-api-for-ios.md §9): article pictures and the category list.
@MainActor
struct SiteExtrasTests {
    let site = FakeSite()

    @Test func anArticlesPictureIsReadAndItsSmallVersionUsedInLists() throws {
        var items = try SiteFixture.items()
        items[3]["cover"] = [
            "src": "https://audio.thrones.wang/img/abc.webp", "src600": "https://audio.thrones.wang/img/abc-600.webp",
            "width": 960, "height": 630, "credit": "Someone", "license": "CC BY-SA 4.0",
        ]
        let page = try JSONDecoder().decode(SiteCatalogPage.self, from: SiteFixture.page(items, latest: 4, maxSeq: 4))
        guard case .article(let usa) = page.items[3], case .article(let essay) = page.items[0] else {
            Issue.record("expected articles")
            return
        }
        #expect(usa.cover?.small == URL(string: "https://audio.thrones.wang/img/abc-600.webp"))
        #expect(usa.cover?.credit == "Someone")
        #expect(essay.cover == nil)
    }

    @Test func theSitesCategoryListOrdersAndDescribesCategories() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try SiteFixture.page(SiteFixture.items(), latest: 4, maxSeq: 4))
        await site.answer("/api/app/v1/categories", try SiteFixture.data([
            "formatVersion": 1,
            "categories": [
                ["id": 1, "slug": "society", "name": "Society & Ideas", "description": "How we live.", "sort": 0, "articleCount": 1],
                ["id": 2, "slug": "places", "name": "Places", "sort": 5, "articleCount": 1],
            ],
        ]))
        let library = SiteLibrary(directory: URL.temporaryDirectory.appending(path: "SiteExtras-\(UUID().uuidString)"), client: site.client)
        await library.sync()
        // The site's order rather than size and name; Other stays last.
        #expect(library.categories.map(\.category.name) == ["Society & Ideas", "Places", "Other"])
        let society = try #require(library.categories.first?.category)
        #expect(library.info(for: society)?.description == "How we live.")
        #expect(library.info(for: .other) == nil)
    }

    @Test func withoutTheCategoryListTheCatalogStillSyncs() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try SiteFixture.page(SiteFixture.items(), latest: 4, maxSeq: 4))
        let library = SiteLibrary(directory: URL.temporaryDirectory.appending(path: "SiteExtras-\(UUID().uuidString)"), client: site.client)
        await library.sync()
        #expect(library.state == .synced)
        #expect(library.categoryInfo.isEmpty)
        #expect(library.categories.map(\.category.name) == ["Places", "Society & Ideas", "Other"])
    }
}
