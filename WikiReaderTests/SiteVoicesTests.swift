import Foundation
import SwiftData
import Testing
@testable import WikiReader

/// Articles English Reader narrates in more than one voice (docs/site-api-for-ios.md §13): the detail lists them
/// (`voices`, the site's first, default one first) and `?voice=<id>` sends the narration in another. The fixtures are
/// Australia's first blocks in OpenAI's Alloy and Google's Kore, captured from the live API on 2026-11-15.
@MainActor
struct SiteVoicesTests {
    static let koreID = "11e8fa6ffa"

    let site = FakeSite()
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "Voices-\(UUID().uuidString)"))
    let directory = URL.temporaryDirectory.appending(path: "Voices-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sent = SentInputs()

    private var openAI: OpenAITTSClient {
        let sent = sent
        return OpenAITTSClient(transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            await sent.record(body["input"]!)
            return (Data("ID3 openai".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, retry: .never)
    }

    private func detail(_ name: String = "site_article_two_voices") throws -> SiteArticleDetail {
        try SiteClient.decodeArticle(Fixture.data(name))
    }

    private func makeLibrary() -> SiteLibrary {
        SiteLibrary(directory: directory, client: site.client)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func detailPath(_ id: String, voice: String? = nil) -> String {
        "/api/app/v1/articles/\(id)" + (voice.map { "?voice=\($0)" } ?? "")
    }

    /// The site answering for the article in both voices.
    private func serveBothVoices() async throws -> SiteArticleSummary {
        let summary = try detail().summary
        await site.answer(detailPath(summary.id), try Fixture.data("site_article_two_voices"))
        await site.answer(detailPath(summary.id, voice: Self.koreID), try Fixture.data("site_article_two_voices_kore"))
        return summary
    }

    /// Opens the article, then picks Google's voice for it.
    private func openInKore(_ library: SiteLibrary, context: ModelContext) async throws -> Article {
        let article = try await library.open(try await serveBothVoices(), in: context)
        try await library.useVoice(try #require(library.link(forArticleURL: article.sourceURL)?.voices?.last), for: article)
        return article
    }

    @Test func eachVoicesFilesAreNamedByItsOwnModelAndStyle() throws {
        let alloy = try detail()
        let kore = try detail("site_article_two_voices_kore")
        let voices = try #require(alloy.voices)
        #expect(voices.map(\.name) == ["Alloy · OpenAI", "Kore · Google"])
        #expect(voices.first?.default == true)
        #expect(alloy.voice == nil)
        #expect(alloy.narration?.narrationVoice == NarrationVoice("alloy"))

        #expect(kore.voice == Self.koreID)
        let google = try #require(kore.narration?.narrationVoice)
        #expect(google == voices[1].narration)
        #expect(google.isSiteOnly)
        #expect(!google.isRecording)

        // Every piece the site lists is taken in both voices, and they are different files.
        #expect(alloy.audioFiles.count == 3)
        #expect(kore.audioFiles.count == 3)
        #expect(alloy.mismatchedChunks == 0)
        #expect(kore.mismatchedChunks == 0)
        #expect(Set(alloy.audioFiles.keys).isDisjoint(with: kore.audioFiles.keys))
        // They are what the reader asks for in that voice.
        let asked = Set(ArticleAudio.pieces(of: kore.contentBlocks, voice: google).map { SpeechAudioCache.key(for: $0.request) })
        #expect(Set(kore.audioFiles.keys).isSubset(of: asked))
    }

    @Test func anArticleIsReadInTheSitesFirstVoiceUntilAnotherIsChosen() async throws {
        let summary = try await serveBothVoices()
        let library = makeLibrary()
        let article = try await library.open(summary, in: try makeContext())
        #expect(library.narrationVoice(forArticleURL: article.sourceURL) == NarrationVoice("alloy"))
        let link = try #require(library.link(forArticleURL: article.sourceURL))
        #expect(link.currentVoice?.name == "Alloy · OpenAI")
        #expect(link.voiceID == nil)

        try await library.useVoice(try #require(link.voices?.last), for: article)
        let google = try #require(library.narrationVoice(forArticleURL: article.sourceURL))
        #expect(google.voice == "Kore")
        #expect(library.link(forArticleURL: article.sourceURL)?.currentVoice?.name == "Kore · Google")
        #expect(ArticleAudio.pieces(of: article.blocks, voice: google).contains { library.audioURL(forKey: SpeechAudioCache.key(for: $0.request)) != nil })
        // Both voices are the article's, for deleting its audio.
        #expect(Set(library.siteVoices(of: [article.sourceURL])) == [NarrationVoice("alloy"), google])
        // Kept: the library made again from disk reads it in Kore too.
        #expect(SiteLibrary(directory: directory, client: site.client).narrationVoice(forArticleURL: article.sourceURL) == google)

        // And back to the first, which is asked for without a voice.
        try await library.useVoice(try #require(link.voices?.first), for: article)
        #expect(library.narrationVoice(forArticleURL: article.sourceURL) == NarrationVoice("alloy"))
        #expect(library.link(forArticleURL: article.sourceURL)?.voiceID == nil)
        #expect(await site.paths == [detailPath(summary.id), detailPath(summary.id, voice: Self.koreID), detailPath(summary.id)])
    }

    @Test func aChosenVoiceIsAskedForWhileTheSiteHasItElseItsFirst() async throws {
        let library = makeLibrary()
        let context = try makeContext()
        let article = try await openInKore(library, context: context)
        var summary = try detail().summary

        // Unchanged on the site: opened as it is, without asking.
        _ = try await library.open(summary, in: context)
        #expect(await site.paths.count == 2)

        // Changed: fetched again, in the voice chosen.
        summary.contentVersion = "changed"
        _ = try await library.open(summary, in: context)
        #expect(await site.paths.last == detailPath(summary.id, voice: Self.koreID))
        #expect(library.narrationVoice(forArticleURL: article.sourceURL)?.voice == "Kore")

        // The site no longer has that voice: the article goes back to the site's first.
        await site.answer(detailPath(summary.id, voice: Self.koreID), Data(#"{"error":{"code":"not_found"}}"#.utf8), status: 404)
        summary.contentVersion = "changed again"
        _ = try await library.open(summary, in: context)
        #expect(await site.paths.suffix(2) == [detailPath(summary.id, voice: Self.koreID), detailPath(summary.id)])
        #expect(library.narrationVoice(forArticleURL: article.sourceURL) == NarrationVoice("alloy"))
        #expect(library.link(forArticleURL: article.sourceURL)?.voiceID == nil)
    }

    @Test func aGoogleVoiceComesOnlyFromTheSiteNeverDriveOrOpenAI() async throws {
        let library = makeLibrary()
        let article = try await openInKore(library, context: try makeContext())
        let google = try #require(library.narrationVoice(forArticleURL: article.sourceURL))
        let piece = try #require(ArticleAudio.pieces(of: article.blocks, voice: google).first {
            library.audioURL(forKey: SpeechAudioCache.key(for: $0.request)) != nil
        }).request

        // The site can't send it: Drive has the same text, but isn't asked; OpenAI isn't asked, even with a key.
        let drive = FakeRemote()
        drive.has = [piece.input]
        let gone = FakeAudioHost(statuses: [404])
        let generations = SpeechGenerations(remote: drive, site: SiteAudioSource(library: library, retryDelay: .zero, transport: gone.transport))
        #expect(await generations.generate(piece, apiKey: "sk", client: openAI, cache: cache).value == .failure(.notOnSite))
        #expect(await generations.fetchFromRemote(piece, cache: cache) == nil)
        #expect(cache.cachedFile(for: piece) == nil)
        #expect(await sent.inputs.isEmpty)

        // When the site sends it, it plays, and isn't handed to Drive to back up.
        let host = FakeAudioHost()
        let working = SpeechGenerations(remote: drive, site: SiteAudioSource(library: library, retryDelay: .zero, transport: host.transport))
        let played = await working.generate(piece, apiKey: nil, client: openAI, cache: cache).value
        #expect(try Data(contentsOf: played.get()) == Data("ID3 site".utf8))
        #expect(drive.generated.isEmpty)
    }

    @Test func anArticlesAudioIsDeletedAndCountedInEveryVoiceItWasHeardIn() async throws {
        let library = makeLibrary()
        let article = try await openInKore(library, context: try makeContext())
        let google = try #require(library.narrationVoice(forArticleURL: article.sourceURL))
        let voices = library.siteVoices(of: [article.sourceURL])
        let input = try #require(ArticleAudio.pieces(of: article.blocks, voice: google).first).request.input
        let stored = try voices.map { try cache.store(Data("ID3".utf8), for: $0.request(for: input)) }

        #expect(Set(ArticleAudio.files(of: article.blocks, notUsedBy: [], siteVoices: voices, cache: cache)) == Set(stored))
        // Storage: both are English Reader's, neither another voice nor unused.
        let usage = ArticleAudio.usage(of: [article.blocks], voice: "marin", narrations: [voices], cache: cache)
        #expect(usage.siteBytes == 6)
        #expect(usage.unusedFiles.isEmpty)
        #expect(usage.otherVoiceFiles.isEmpty)
        // The info page: the voice read in, and the other one.
        let status = ArticleAudio.status(of: article.blocks, voice: google, others: voices, cache: cache)
        #expect(status.bytes == 3)
        #expect(status.otherVoiceBytes == 3)
    }

    @Test func olderVersionsAreToldOnlyOfVoicesTheyCanRead() async throws {
        let library = makeLibrary()
        let context = try makeContext()
        let summary = try await serveBothVoices()
        let article = try await library.open(summary, in: context)
        func keptVoice() throws -> String? {
            let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "Catalog.json"))) as! [String: Any]
            let links = catalog["links"] as! [String: [String: Any]]
            return links[summary.id]?["voice"] as? String
        }
        #expect(try keptVoice() == "alloy")

        // An older version would ask OpenAI for "Kore": it is told of no voice instead.
        try await library.useVoice(try #require(library.link(forArticleURL: article.sourceURL)?.voices?.last), for: article)
        #expect(try keptVoice() == nil)
    }

    @Test func linksMadeBeforeVoicesAreFetchedOnceMoreForThem() async throws {
        let summary = try await serveBothVoices()
        let context = try makeContext()
        let article = Article(title: summary.title, sourceURL: summary.canonicalUrl, blocks: try detail().contentBlocks)
        context.insert(article)
        // As a version before 2026-11-15 kept it: the voice's name, no voices, no catalog version.
        let older = SiteLibrary.Link(
            articleURL: summary.canonicalUrl, contentVersion: summary.contentVersion, voice: "alloy", ownsText: true,
            attribution: nil, preview: nil
        )
        let catalog: [String: Any] = [
            "summaryVersion": SiteLibrary.summaryVersion, "since": 0,
            "articles": [summary.id: try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))],
            "links": [summary.id: try JSONSerialization.jsonObject(with: JSONEncoder().encode(older))],
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: catalog).write(to: directory.appending(path: "Catalog.json"))
        let library = makeLibrary()
        #expect(library.narrationVoice(forArticleURL: article.sourceURL) == NarrationVoice("alloy"))
        #expect(library.link(forArticleURL: article.sourceURL)?.voices == nil)

        // Unchanged on the site, yet fetched once more for its voices; then not again.
        #expect(try await library.open(summary, in: context) === article)
        #expect(library.link(forArticleURL: article.sourceURL)?.voices?.count == 2)
        _ = try await library.open(summary, in: context)
        #expect(await site.paths == [detailPath(summary.id)])
    }
}
