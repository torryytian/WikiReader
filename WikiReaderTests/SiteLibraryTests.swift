import Foundation
import SwiftData
import Testing
@testable import WikiReader

/// The English Reader site as an article source (docs/site-api-for-ios.md). The samples in `Fixtures/site/` are in
/// the specified format, made from the live pages' data before the API existed.
struct SiteFormatTests {
    @Test func catalogPagesReadArticlesAndRemovals() throws {
        let page = try JSONDecoder().decode(SiteCatalogPage.self, from: Fixture.data("site_catalog_page1"))
        #expect(page.epoch == "k3v9q2")
        #expect(page.hasMore)
        guard case .article(let usa) = page.items[0], case .article(let essay) = page.items[1] else {
            Issue.record("expected two articles")
            return
        }
        #expect(usa.isWikipedia)
        #expect(usa.canonicalUrl == URL(string: "https://en.wikipedia.org/wiki/United_States"))
        #expect(usa.audio?.readyChunks == 191)
        #expect(!essay.isWikipedia)
        #expect(essay.canonicalUrl == URL(string: "https://english.thrones.wang/a/the-paradox-of-convenience"))

        let next = try JSONDecoder().decode(SiteCatalogPage.self, from: Fixture.data("site_catalog_page2"))
        #expect(next.items.first == .removed(id: "77b0d4aa-1c2e-4f3a-8b5d-6e7f8091a2b3", seq: 14))
    }

    @Test func theReadersOwnKeysFindTheSitesFiles() throws {
        let detail = try SiteClient.decodeArticle(Fixture.data("site_article_paradox"))
        let blocks = detail.contentBlocks
        #expect(blocks.count == 13)
        #expect(blocks.first?.text.hasPrefix("For most of human history") == true)
        let files = detail.audioFiles
        #expect(files.count == 13)
        #expect(detail.mismatchedChunks == 0)
        // What the OpenAI engine asks the cache for while reading, with the site's voice: every piece is there.
        let voice = try #require(detail.narration?.voice)
        for block in blocks {
            let text = block.text as NSString
            for range in SpeechChunking.chunks(of: block.text) {
                let key = SpeechAudioCache.key(for: OpenAISpeechEngine.request(for: text.substring(with: range), voice: voice))
                #expect(files[key] != nil)
            }
        }
    }

    @Test func aPieceWhoseKeyDoesntMatchItsTextIsNotUsed() throws {
        var json = try #require(String(data: Fixture.data("site_article_paradox"), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"text\":\"For most of human history", with: "\"text\":\"For much of human history")
            .replacingOccurrences(of: "\"text\": \"For most of human history", with: "\"text\": \"For much of human history")
        let detail = try SiteClient.decodeArticle(Data(json.utf8))
        #expect(detail.audioFiles.count == 12)
        #expect(detail.mismatchedChunks == 1)
    }

    @Test func filesThatArentTheOriginalsAreNotTakenAsCachedAudio() throws {
        var json = try #require(String(data: Fixture.data("site_article_paradox"), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"sourceIdentical\": true", with: "\"sourceIdentical\": false")
        #expect(try SiteClient.decodeArticle(Data(json.utf8)).audioFiles.isEmpty)
    }
}

/// Answers the app API's requests from the fixtures, keeping them.
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
    let essayID = "8a6f0c2e-5b1d-4c7a-9e3f-2d4b6a8c0e11"

    private func makeLibrary() -> SiteLibrary {
        SiteLibrary(directory: directory, client: site.client)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func page(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    @Test func theCatalogComesInPagesAndThenOnlyWhatChanged() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try Fixture.data("site_catalog_page1"))
        await site.answer("/api/app/v1/articles?since=12&limit=200", try Fixture.data("site_catalog_page2"))
        let library = makeLibrary()
        await library.sync()
        #expect(library.state == .synced)
        #expect(library.articles.map(\.title).sorted() == ["The Paradox of Convenience", "United States"])
        #expect(library.article(id: essayID)?.seq == 15)
        #expect(await site.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == SiteClient.userAgent })
        #expect(!SiteClient.userAgent.contains("@"))

        // Next time (after a restart too): only what changed after 15.
        await site.answer("/api/app/v1/articles?since=15&limit=200", try page([
            "formatVersion": 1, "epoch": "k3v9q2", "maxSeq": 16, "latest": 16, "hasMore": false,
            "items": [["id": essayID, "seq": 16, "removed": true]],
        ]))
        let again = makeLibrary()
        await again.sync()
        #expect(await site.paths.last == "/api/app/v1/articles?since=15&limit=200")
        #expect(again.articles.map(\.title) == ["United States"])
    }

    @Test func aRestoredSiteDatabaseMeansFetchingEverythingAgain() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try Fixture.data("site_catalog_page1"))
        await site.answer("/api/app/v1/articles?since=12&limit=200", try Fixture.data("site_catalog_page2"))
        let library = makeLibrary()
        await library.sync()

        // Restored from a backup: a new epoch, and only the essay is published there.
        let essay = try JSONSerialization.jsonObject(with: Fixture.data("site_article_paradox")) as! [String: Any]
        await site.answer("/api/app/v1/articles?since=15&limit=200", try page([
            "formatVersion": 1, "epoch": "new", "maxSeq": 3, "latest": 15, "hasMore": false, "items": [],
        ]))
        await site.answer("/api/app/v1/articles?since=0&limit=200", try page([
            "formatVersion": 1, "epoch": "new", "maxSeq": 3, "latest": 3, "hasMore": false,
            "items": [essay.filter { !["blocks", "narration", "_note", "formatVersion"].contains($0.key) }.merging(["seq": 3]) { $1 }],
        ]))
        await library.sync()
        #expect(library.articles.map(\.title) == ["The Paradox of Convenience"])
        // And from there on, the new numbers.
        await site.answer("/api/app/v1/articles?since=3&limit=200", try page([
            "formatVersion": 1, "epoch": "new", "maxSeq": 3, "latest": 3, "hasMore": false, "items": [],
        ]))
        await library.sync()
        #expect(await site.paths.last == "/api/app/v1/articles?since=3&limit=200")
    }

    @Test func aWebPageInsteadOfDataIsReportedAsABotCheck() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", Data("<html>Just a moment…</html>".utf8), type: "text/html")
        let library = makeLibrary()
        await library.sync()
        #expect(library.state == .failed(SiteError.notJSON.message))
        #expect(library.articles.isEmpty)
    }

    @Test func openingMakesAnArticleOnceAndUpdatesItWhenTheSiteChangesIt() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try Fixture.data("site_catalog_page1"))
        await site.answer("/api/app/v1/articles?since=12&limit=200", try Fixture.data("site_catalog_page2"))
        await site.answer("/api/app/v1/articles/\(essayID)", try Fixture.data("site_article_paradox"))
        let library = makeLibrary()
        await library.sync()
        let context = try makeContext()
        let summary = try #require(library.article(id: essayID))

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
        let same = try await library.open(try #require(library.article(id: essayID)), in: context)
        #expect(same === article)
        #expect(await detailRequests() == 1)
        #expect(try context.fetch(FetchDescriptor<Article>()).count == 1)

        // The site edited it: the text is updated in place and the reading position kept within it.
        var edited = try JSONSerialization.jsonObject(with: Fixture.data("site_article_paradox")) as! [String: Any]
        var blocks = edited["blocks"] as! [[String: Any]]
        blocks.removeLast(3)
        edited["blocks"] = blocks
        edited["contentVersion"] = "edited"
        edited["seq"] = 20
        await site.answer("/api/app/v1/articles/\(essayID)", try JSONSerialization.data(withJSONObject: edited))
        var changed = summary
        changed.contentVersion = "edited"
        let updated = try await library.open(changed, in: context)
        #expect(updated === article)
        #expect(article.blocks.count == 10)
        #expect(article.lastReadBlockIndex == 9)
        #expect(await detailRequests() == 2)
    }

    @Test func aWikipediaArticleAlreadyAddedIsUsedAsItIs() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try Fixture.data("site_catalog_page1"))
        await site.answer("/api/app/v1/articles?since=12&limit=200", try Fixture.data("site_catalog_page2"))
        // The site's United States, in brief: one paragraph.
        let usaID = "3c9e7d21-0f4a-4b8e-a6d2-91c5e7f3b204"
        let library = makeLibrary()
        await library.sync()
        let usa = try #require(library.article(id: usaID))
        var detail = try JSONSerialization.jsonObject(with: Fixture.data("site_article_paradox")) as! [String: Any]
        for (key, value) in try JSONSerialization.jsonObject(with: JSONEncoder().encode(usa)) as! [String: Any] { detail[key] = value }
        await site.answer("/api/app/v1/articles/\(usaID)", try JSONSerialization.data(withJSONObject: detail))

        let context = try makeContext()
        let mine = Article(title: "United States", sourceURL: usa.canonicalUrl, blocks: [.paragraph("My own copy.")])
        context.insert(mine)
        let opened = try await library.open(usa, in: context)
        #expect(opened === mine)
        #expect(mine.blocks == [.paragraph("My own copy.")])
        #expect(try context.fetch(FetchDescriptor<Article>()).count == 1)
        #expect(library.links[usaID]?.ownsText == false)
    }

    @Test func offlineAnArticleOpenedBeforeStillOpens() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", try Fixture.data("site_catalog_page1"))
        await site.answer("/api/app/v1/articles?since=12&limit=200", try Fixture.data("site_catalog_page2"))
        await site.answer("/api/app/v1/articles/\(essayID)", try Fixture.data("site_article_paradox"))
        let library = makeLibrary()
        await library.sync()
        let context = try makeContext()
        let article = try await library.open(try #require(library.article(id: essayID)), in: context)

        await site.answer("/api/app/v1/articles/\(essayID)", Data(), status: 503)
        var changed = try #require(library.article(id: essayID))
        changed.contentVersion = "newer"
        #expect(try await library.open(changed, in: context) === article)

        // Never opened and unreachable: an error.
        let usa = try #require(library.article(id: "3c9e7d21-0f4a-4b8e-a6d2-91c5e7f3b204"))
        await #expect(throws: SiteError.notFound) { try await library.open(usa, in: context) }
    }
}
