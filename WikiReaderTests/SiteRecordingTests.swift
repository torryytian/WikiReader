import Foundation
import SwiftData
import Testing
@testable import WikiReader

/// Articles read from their speaker's own recording on English Reader (the site's reply, §2.4): the recording cut into
/// one piece per paragraph, named like OpenAI audio (model `upload`, voice `rec-…`), each with its words' start times.
/// The fixture is Shakira's 2009 Oxford Union address, captured from the live API on 2026-11-05.
@MainActor
struct SiteRecordingTests {
    static let shakiraID = "0c06379c-e6e0-4725-886b-7af63ca48cd1"

    let site = FakeSite()
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "Recording-\(UUID().uuidString)"))
    let sent = SentInputs()

    private var openAI: OpenAITTSClient {
        let sent = sent
        return OpenAITTSClient(transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            await sent.record(body["input"]!)
            return (Data("ID3 openai".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, retry: .never)
    }

    private func detail() throws -> SiteArticleDetail {
        try SiteClient.decodeArticle(Fixture.data("site_article_shakira"))
    }

    private func makeLibrary() -> SiteLibrary {
        SiteLibrary(directory: URL.temporaryDirectory.appending(path: "Recording-\(UUID().uuidString)"), client: site.client)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private var detailPath: String { "/api/app/v1/articles/\(Self.shakiraID)" }

    @Test func aRecordingsPiecesAreFoundByTheReadersOwnKeys() throws {
        let detail = try detail()
        let narration = try #require(detail.narration)
        #expect(OpenAISpeechEngine.isRecording(narration.voice))
        #expect(narration.model == OpenAISpeechEngine.recordingModel)
        // Not OpenAI's audio, yet usable: it is the speaker.
        #expect(narration.sourceIdentical == false)

        let files = detail.audioFiles
        let keys = Set(ArticleAudio.pieces(of: detail.contentBlocks, voice: narration.voice).map { SpeechAudioCache.key(for: $0.request) })
        #expect(files.count == 38)
        #expect(Set(files.keys) == keys)
        #expect(detail.mismatchedChunks == 0)
        #expect(Set(detail.wordStarts.keys) == keys)
        #expect(OpenAISpeechEngine.displayName(of: narration.voice) == "Original Recording")
        #expect(OpenAISpeechEngine.displayName(of: "alloy") == "Alloy")
    }

    @Test func theSitesWordTimesMatchTheReadersWords() throws {
        let detail = try detail()
        let chunks = detail.blocks.flatMap { $0.chunks ?? [] }
        let measured = chunks.filter { chunk in
            WordTimeline(text: chunk.text, startsMs: chunk.wordStartsMs, duration: Double(chunk.ms ?? 0) / 1000).isMeasured
        }
        #expect(chunks.count == 38)
        #expect(measured.count == 38)
    }

    @Test func measuredWordTimesAreUsedOnlyWhenTheWordsMatch() {
        let text = "Thank you, Oxford."
        let timeline = WordTimeline(text: text, startsMs: [0, 400, 1000], duration: 2)
        #expect(timeline.isMeasured)
        #expect(timeline.wordIndex(atFraction: 0.1) == 0)
        #expect(timeline.wordIndex(atFraction: 0.25) == 1)
        #expect(timeline.wordIndex(atFraction: 0.6) == 2)
        // Starting at "Oxford" seeks to its real start.
        #expect(timeline.fraction(atOffset: 11) == 0.5)

        // Split into other words than the site's: estimated, as for OpenAI audio.
        let estimated = WordTimeline(text: text, startsMs: [0, 400], duration: 2)
        #expect(!estimated.isMeasured)
        #expect(estimated.words == WordTimeline(text: text).words)
        #expect(estimated.fraction(atOffset: 11) == WordTimeline(text: text).fraction(atOffset: 11))

        // Times out of order or past the end stay in order and inside the clip.
        let odd = WordTimeline(text: "a b c", startsMs: [500, 100, 9000], duration: 1)
        #expect(odd.isMeasured)
        #expect(odd.wordIndex(atFraction: 0.99) == 1)
        #expect(odd.wordIndex(atFraction: 1) == 2)
    }

    @Test func aRecordingComesOnlyFromTheSiteNeverDriveOrOpenAI() async throws {
        await site.answer(detailPath, try Fixture.data("site_article_shakira"))
        let library = makeLibrary()
        let article = try await library.open(try detail().summary, in: try makeContext())
        let voice = try #require(library.narrationVoice(forArticleURL: article.sourceURL))
        #expect(library.isRecording(articleURL: article.sourceURL))
        #expect(library.recordingVoices(of: [article.sourceURL]) == [voice])
        let piece = ArticleAudio.pieces(of: article.blocks, voice: voice)[1].request
        #expect(library.wordStarts(forKey: SpeechAudioCache.key(for: piece)) != nil)

        // The site can't send it: Drive has the same text, but isn't asked; OpenAI isn't asked, even with a key.
        let drive = FakeRemote()
        drive.has = [piece.input]
        let gone = FakeAudioHost(statuses: [404])
        let generations = SpeechGenerations(remote: drive, site: SiteAudioSource(library: library, retryDelay: .zero, transport: gone.transport))
        let missing = await generations.generate(piece, apiKey: "sk", client: openAI, cache: cache).value
        #expect(missing == .failure(.notOnSite))
        #expect(await generations.fetchFromRemote(piece, cache: cache) == nil)
        #expect(cache.cachedFile(for: piece) == nil)
        #expect(await sent.inputs.isEmpty)

        // When the site sends it, it plays, and isn't handed to Drive to back up.
        let host = FakeAudioHost()
        let working = SpeechGenerations(remote: drive, site: SiteAudioSource(library: library, retryDelay: .zero, transport: host.transport))
        let played = await working.generate(piece, apiKey: nil, client: openAI, cache: cache).value
        #expect(try Data(contentsOf: played.get()) == Data("ID3 site".utf8))
        #expect(await host.requested.first?.host() == "audio.thrones.wang")
        #expect(drive.generated.isEmpty)
    }

    @Test func aRecordingOpenedByAnOlderVersionIsFetchedAgainForItsAudio() async throws {
        // An older version kept no voice for it (it didn't take recordings): as if the detail had no narration.
        var older = try SiteFixture.json("site_article_shakira")
        older["narration"] = nil
        await site.answer(detailPath, try SiteFixture.data(older))
        let library = makeLibrary()
        let context = try makeContext()
        let summary = try detail().summary
        let article = try await library.open(summary, in: context)
        #expect(library.narrationVoice(forArticleURL: article.sourceURL) == nil)

        // Unchanged on the site, yet fetched again once, now with its recording.
        await site.answer(detailPath, try Fixture.data("site_article_shakira"))
        let again = try await library.open(summary, in: context)
        #expect(again === article)
        #expect(library.isRecording(articleURL: article.sourceURL))
        _ = try await library.open(summary, in: context)
        #expect(await site.paths.filter { $0 == detailPath }.count == 2)
    }

    @Test func deletingAndStorageCountTheRecordings() throws {
        let blocks = [ContentBlock.paragraph("Thank you, Oxford.")]
        let recording = OpenAISpeechEngine.request(for: "Thank you, Oxford.", voice: "rec-0123456789abcdef")
        try cache.store(Data("ID3".utf8), for: recording)

        // Deleting the article's audio takes its recording too.
        #expect(ArticleAudio.files(of: blocks, notUsedBy: [], cache: cache).isEmpty)
        #expect(ArticleAudio.files(of: blocks, notUsedBy: [], recordings: [recording.voice], cache: cache) == [cache.fileURL(for: recording)])

        // Storage: English Reader's, not another voice nor unused, and nothing for the OpenAI voice to download.
        let usage = ArticleAudio.usage(of: [blocks], voice: "marin", narrations: [recording.voice], cache: cache)
        #expect(usage.siteBytes == 3)
        #expect(usage.unusedFiles.isEmpty)
        #expect(usage.otherVoiceFiles.isEmpty)
        #expect(usage.totalCharacters == 0)
        #expect(ArticleAudio.usage(of: [blocks], voice: "marin", cache: cache).unusedFiles.count == 1)
    }

    @Test func speechesHaveTheirOwnCoverAndLicense() {
        #expect(CategoryTheme.forCategory("Speeches").symbol == "mic.fill")
        #expect(CategoryTheme.forCategory("TED Talks").symbol == "mic.fill")
        #expect(CategoryTheme.forCategory("Commencement Addresses").symbol == "mic.fill")
        #expect(ArticleInfoView.licenseName("publicly-available") == "publicly available, copyright with its owner")
    }
}

/// The site's answer to docs/site-api-for-ios.md §9 (2026-11-05 afternoon): articles' pictures and the category list,
/// captured live (23 articles, 3 with a picture; 2 categories listed, the rest of the articles have none yet).
@MainActor
struct SiteCoversLiveTests {
    @Test func picturesAndCategoriesAsTheSiteSendsThem() throws {
        let page = try JSONDecoder().decode(SiteCatalogPage.self, from: Fixture.data("site_catalog_covers"))
        let articles = page.items.compactMap { if case .article(let article) = $0 { article } else { nil } }
        #expect(articles.count == 23)
        #expect(articles.filter { $0.cover != nil }.map(\.title).sorted() == ["Australia", "COVID-19", "United States"])
        let usa = try #require(articles.first { $0.title == "United States" }?.cover)
        #expect(usa.small.host() == "audio.thrones.wang")
        #expect(usa.small.absoluteString.hasSuffix("-600.webp"))

        // Commons credits name the license already: it isn't said twice.
        #expect(ArticleInfoView.pictureCredit(usa) == "Pinpin, CC BY-SA 3.0, via Wikimedia Commons.")
        var bare = usa
        bare.credit = "Pinpin"
        #expect(ArticleInfoView.pictureCredit(bare) == "Pinpin, CC BY-SA 3.0.")

        let list = try JSONDecoder().decode(SiteCategoryList.self, from: Fixture.data("site_categories"))
        let info = Dictionary(uniqueKeysWithValues: list.categories.map { ($0.id, $0) })
        #expect(info[2]?.description == "Countries, cities and the people who live there.")
        // The site's order (Society & Ideas first, though no fuller), and Other last.
        let groups = SiteCategories.group(articles, info: info)
        #expect(groups.map(\.category.name) == ["Society & Ideas", "Places", "Other"])
        #expect(groups.last?.articles.count == 21)
    }
}

/// Summaries kept by an older version lack the fields it didn't know (it dropped categories' numbers), and the site
/// only sends an article again when it changes: such a catalog is fetched whole, once.
@MainActor
struct SiteSummaryVersionTests {
    let site = FakeSite()
    let directory = URL.temporaryDirectory.appending(path: "SiteVersion-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func anOlderVersionsCatalogIsFetchedWholeOnce() async throws {
        // As an older version left it: up to change 4, without categories' numbers, and an article since removed.
        var items = try SiteFixture.items()
        for index in items.indices {
            if var category = items[index]["category"] as? [String: Any] {
                category["id"] = nil
                items[index]["category"] = category
            }
        }
        var kept = Dictionary(uniqueKeysWithValues: items.map { ($0["id"] as! String, $0) })
        kept["gone"] = items[0].merging(["id": "gone", "title": "Gone"]) { $1 }
        let old: [String: Any] = ["epoch": "yr2oIK3N", "since": 4, "articles": kept, "links": [String: Any]()]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SiteFixture.data(old).write(to: directory.appending(path: "Catalog.json"))

        await site.answer("/api/app/v1/articles?since=0&limit=200", try Fixture.data("site_catalog"))
        let library = SiteLibrary(directory: directory, client: site.client)
        #expect(library.articles.count == 5)
        await library.sync()
        #expect(library.articles.map(\.title).sorted() == ["Australia", "COVID-19", "The Paradox of Convenience", "United States"])
        #expect(library.article(id: SiteFixture.essayID)?.category?.id == 1)

        // Once: next time only what changed after 4.
        await site.answer("/api/app/v1/articles?since=4&limit=200", try SiteFixture.page([], latest: 4, maxSeq: 4))
        await SiteLibrary(directory: directory, client: site.client).sync()
        #expect(await site.paths.filter { $0.hasPrefix("/api/app/v1/articles?") } == [
            "/api/app/v1/articles?since=0&limit=200", "/api/app/v1/articles?since=4&limit=200",
        ])
    }
}
