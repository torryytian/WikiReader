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

    @Test func recordingsCutUpByTheSiteAreNotTakenAsCachedAudio() throws {
        // An uploaded recording's pieces are re-encoded, not OpenAI's originals (the site's reply, §2.4).
        var detail = try SiteFixture.json("site_article_paradox")
        var narration = detail["narration"] as! [String: Any]
        narration["sourceIdentical"] = false
        detail["narration"] = narration
        #expect(try SiteClient.decodeArticle(SiteFixture.data(detail)).audioFiles.isEmpty)
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

    nonisolated var client: SiteClient {
        SiteClient(baseURL: URL(string: "https://site.test")!) { request in await self.handle(request) }
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
        #expect(await site.paths == [catalog(since: 0), catalog(since: 2)])
        #expect(await site.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == SiteClient.userAgent })
        #expect(!SiteClient.userAgent.contains("@"))

        // Next time, after a restart too: only what changed after 4.
        await site.answer(catalog(since: 4), try SiteFixture.page([["id": SiteFixture.essayID, "seq": 5, "removed": true]], latest: 5, maxSeq: 5))
        let again = makeLibrary()
        await again.sync()
        #expect(await site.paths.last == catalog(since: 4))
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
        #expect(await site.paths.last == catalog(since: 1))
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
        #expect(library.narrationVoice(forArticleURL: article.sourceURL) == "alloy")
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
        #expect(library.narrationVoice(forArticleURL: mine.sourceURL) == "alloy")
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
