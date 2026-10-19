import Foundation
import SwiftData
import Testing
@testable import WikiReader

private func temporaryCache() -> SpeechAudioCache {
    SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "AudioDownloaderTests-\(UUID().uuidString)"))
}

private func store(_ text: String, voice: String = "marin", in cache: SpeechAudioCache, bytes: Int = 10) throws {
    try cache.store(Data(repeating: 1, count: bytes), for: OpenAISpeechEngine.request(for: text, voice: voice))
}

private let blocks: [ContentBlock] = [
    .heading("History", level: 2),
    .paragraph("The first paragraph."),
    .paragraph("The second paragraph."),
]

// MARK: - ArticleAudio

struct ArticleAudioTests {
    @Test func statusCountsWhatIsOnDiskInTheChosenVoice() throws {
        let cache = temporaryCache()
        try store("History", in: cache, bytes: 100)
        try store("The second paragraph.", in: cache, bytes: 200)
        try store("The first paragraph.", voice: "cedar", in: cache, bytes: 50)

        let status = ArticleAudio.status(of: blocks, voice: "marin", cache: cache)

        #expect(status.totalPieces == 3)
        #expect(status.cachedPieces == 2)
        #expect(status.bytes == 300)
        #expect(status.otherVoiceBytes == 50)
        #expect(status.missing.map(\.request.input) == ["The first paragraph."])
        #expect(status.missing.first?.block == 1)
        #expect(!status.isComplete)
        let expected = Double("History".count + "The second paragraph.".count) / Double(status.totalCharacters)
        #expect(abs(status.fraction - expected) < 1e-9)
        #expect(status.fraction(ofBlocks: 0..<1) == 1)
        #expect(status.fraction(ofBlocks: 1..<2) == 0)
        // Out-of-range ranges are clamped, not trapped on.
        #expect(status.fraction(ofBlocks: 2..<10) == 1)
    }

    @Test func longBlocksAreCountedPieceByPieceTheWayTheReaderSplitsThem() {
        let sentence = "This sentence is repeated to make a block longer than one request allows. "
        let long = String(repeating: sentence, count: 120)
        let pieces = ArticleAudio.pieces(of: [.paragraph(long)], voice: "marin")
        #expect(pieces.count == SpeechChunking.chunks(of: long).count)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.block == 0 })
    }

    @Test func emptyArticleIsNeitherDownloadedNorMissingAnything() {
        let status = ArticleAudio.status(of: [], voice: "marin", cache: temporaryCache())
        #expect(status.totalPieces == 0)
        #expect(status.fraction == 0)
        #expect(status.isComplete)
    }

    @Test func deletingAnArticlesAudioKeepsWhatAnotherArticleUses() throws {
        let cache = temporaryCache()
        for voice in ["marin", "cedar"] {
            for block in blocks { try store(block.text, voice: voice, in: cache) }
        }
        let other: [ContentBlock] = [.heading("History", level: 2), .paragraph("Something else.")]

        let files = ArticleAudio.files(of: blocks, notUsedBy: [other], cache: cache)

        // Two paragraphs in two voices; "History" is shared, so kept.
        #expect(files.count == 4)
        #expect(!files.contains(cache.fileURL(for: OpenAISpeechEngine.request(for: "History", voice: "marin"))))
    }

    @Test func usageSortsFilesIntoChosenVoiceOtherVoicesAndUnused() throws {
        let cache = temporaryCache()
        try store("History", in: cache, bytes: 100)
        try store("The first paragraph.", voice: "cedar", in: cache, bytes: 40)
        try store("A deleted article's paragraph.", in: cache, bytes: 7)
        try store(ArticleAudio.sampleText, voice: "ash", in: cache, bytes: 3)
        // Not a name the app writes: ignored.
        try Data("x".utf8).write(to: cache.directory.appending(path: "notes.txt"))

        let usage = ArticleAudio.usage(of: [blocks], voice: "marin", cache: cache)

        #expect(usage.voiceBytes == 100)
        #expect(usage.otherVoiceBytes == 40)
        #expect(usage.otherVoiceFiles.count == 1)
        #expect(usage.unusedBytes == 7)
        #expect(usage.unusedFiles.map(\.lastPathComponent) == [cache.fileURL(for: OpenAISpeechEngine.request(for: "A deleted article's paragraph.", voice: "marin")).lastPathComponent])
        #expect(usage.totalBytes == 150)
        #expect(usage.missingPieces == 2)
        #expect(usage.missingCharacters == "The first paragraph.".count + "The second paragraph.".count)
    }

    @Test func removeReportsTheBytesFreedAndSkipsMissingFiles() throws {
        let cache = temporaryCache()
        try store("History", in: cache, bytes: 30)
        let present = cache.fileURL(for: OpenAISpeechEngine.request(for: "History", voice: "marin"))
        let missing = cache.directory.appending(path: String(repeating: "a", count: 64) + ".mp3")
        #expect(ArticleAudio.remove([present, missing]) == 30)
        #expect(cache.cachedFile(for: OpenAISpeechEngine.request(for: "History", voice: "marin")) == nil)
    }

    @Test func estimatesFollowTheReadingSpeed() {
        let characters = Int(ReadingSession.charactersPerSecond * 60 * 10)
        #expect(abs(ArticleAudio.minutes(forCharacters: characters) - 10) < 1e-9)
        #expect(abs(ArticleAudio.dollars(forCharacters: characters) - 0.15) < 1e-9)
    }

    @Test func formatsDurationsAndCosts() {
        #expect(AudioFormat.duration(minutes: 0.2) == "under a minute")
        #expect(AudioFormat.duration(minutes: 25) == "25 min")
        #expect(AudioFormat.duration(minutes: 60) == "1 h")
        #expect(AudioFormat.duration(minutes: 116) == "1 h 56 min")
        #expect(AudioFormat.cost(0.004) == "less than a cent")
        #expect(AudioFormat.cost(1.694) == "$1.69")
        #expect(AudioFormat.bytes(0) == "None")
    }
}

// MARK: - AudioDownloader

/// The texts sent to the fake OpenAI endpoint.
actor SentInputs {
    private(set) var inputs: [String] = []
    func record(_ input: String) { inputs.append(input) }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioDownloaderTests {
    let cache = temporaryCache()
    let sent = SentInputs()
    let container: ModelContainer

    init() throws {
        container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    final class AwakeLog {
        var values: [Bool] = []
    }

    private func article(_ title: String, _ blocks: [ContentBlock]) throws -> Article {
        let article = Article(title: title, sourceURL: URL(string: "https://en.wikipedia.org/wiki/\(title)")!, blocks: blocks)
        container.mainContext.insert(article)
        try container.mainContext.save()
        return article
    }

    /// A downloader whose network answers with `status` (failing with a lost connection for texts in `dropping`).
    private func makeDownloader(
        status: Int = 200, dropping: Set<String> = [], delay: Duration = .milliseconds(5), key: String? = "sk-test",
        awake: AwakeLog = AwakeLog()
    ) -> AudioDownloader {
        let sent = sent
        let client = OpenAITTSClient(
            transport: { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                await sent.record(body["input"]!)
                try await Task.sleep(for: delay)
                if dropping.contains(body["input"]!) { throw URLError(.networkConnectionLost) }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (status == 200 ? Data("ID3 fake audio".utf8) : Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8), response)
            },
            retry: .never
        )
        return AudioDownloader(
            client: client, cache: cache, generations: SpeechGenerations(), apiKey: { key },
            keepAwake: { awake.values.append($0) }
        )
    }

    private func plan(_ articles: [Article], voice: String = "marin") async -> AudioDownloader.Plan {
        await AudioDownloader.plan(
            for: articles.map { AudioDownloader.Source(id: $0.persistentModelID, blocksData: $0.blocksData) },
            voice: voice, cache: cache
        )
    }

    private func waitUntilDone(_ downloader: AudioDownloader) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while downloader.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func planListsOnlyWhatIsMissing() async throws {
        let first = try article("First", blocks)
        let second = try article("Second", [.paragraph("Already here.")])
        try store("History", in: cache)
        try store("Already here.", in: cache)

        let plan = await plan([first, second])

        #expect(plan.items.map(\.piece.request.input) == ["The first paragraph.", "The second paragraph."])
        #expect(plan.articleCount == 1)
        #expect(plan.characters == "The first paragraph.".count + "The second paragraph.".count)
        #expect(plan.voice == "marin")
    }

    @Test func downloadsEverythingMissingOnceAndKeepsTheScreenOnMeanwhile() async throws {
        let first = try article("First", blocks)
        let awake = AwakeLog()
        let downloader = makeDownloader(awake: awake)

        downloader.start(await plan([first]))
        #expect(downloader.isRunning)
        #expect(downloader.isDownloading(first.persistentModelID))
        try await waitUntilDone(downloader)

        #expect(downloader.phase == .finished)
        #expect(downloader.donePieces == 3)
        #expect(downloader.failedPieces == 0)
        #expect(downloader.fraction == 1)
        #expect(!downloader.isDownloading(first.persistentModelID))
        #expect(await sent.inputs.sorted() == blocks.map(\.text).sorted())
        #expect(ArticleAudio.status(of: blocks, voice: "marin", cache: cache).isComplete)
        #expect(awake.values == [true, false])

        downloader.dismiss()
        #expect(downloader.phase == .idle)
    }

    @Test func audioThatAppearedSinceThePlanIsNotRequestedAgain() async throws {
        let first = try article("First", blocks)
        let downloader = makeDownloader()
        let plan = await plan([first])
        try store("The first paragraph.", in: cache)

        downloader.start(plan)
        try await waitUntilDone(downloader)

        #expect(downloader.donePieces == 3)
        #expect(await !sent.inputs.contains("The first paragraph."))
    }

    @Test func aRejectedKeyStopsAtOnce() async throws {
        let first = try article("First", blocks)
        let downloader = makeDownloader(status: 401)

        downloader.start(await plan([first]))
        try await waitUntilDone(downloader)

        #expect(downloader.phase == .stopped(OpenAITTSError.invalidKey.message))
        #expect(downloader.donePieces == 0)
        // Two workers may each have sent one request; nothing after that.
        #expect(await sent.inputs.count <= AudioDownloader.maxConcurrent)
    }

    @Test func noKeyStopsWithoutRequesting() async throws {
        let first = try article("First", blocks)
        let downloader = makeDownloader(key: nil)

        downloader.start(await plan([first]))
        try await waitUntilDone(downloader)

        #expect(downloader.phase == .stopped(OpenAITTSError.missingKey.message))
        #expect(await sent.inputs.isEmpty)
    }

    @Test func aFailedPieceIsSkippedAndCounted() async throws {
        let first = try article("First", blocks)
        let downloader = makeDownloader(dropping: ["The first paragraph."])

        downloader.start(await plan([first]))
        try await waitUntilDone(downloader)

        #expect(downloader.phase == .finished)
        #expect(downloader.donePieces == 2)
        #expect(downloader.failedPieces == 1)
    }

    @Test func manyFailuresInARowStopTheDownload() async throws {
        let texts = (1...10).map { "Paragraph number \($0)." }
        let first = try article("First", texts.map(ContentBlock.paragraph))
        let downloader = makeDownloader(dropping: Set(texts))

        downloader.start(await plan([first]))
        try await waitUntilDone(downloader)

        guard case .stopped(let reason) = downloader.phase else {
            Issue.record("expected a stop, got \(downloader.phase)")
            return
        }
        #expect(reason.contains("failures in a row"))
        #expect(await sent.inputs.count < texts.count)
    }

    @Test func cancellingAnArticleDropsWhatIsQueuedForIt() async throws {
        let texts = (1...8).map { "Paragraph number \($0)." }
        let first = try article("First", texts.map(ContentBlock.paragraph))
        let second = try article("Second", [.paragraph("The only paragraph.")])
        let downloader = makeDownloader(delay: .milliseconds(50))

        downloader.start(await plan([first, second]))
        downloader.cancel(article: first.persistentModelID)
        #expect(!downloader.isDownloading(first.persistentModelID))
        try await waitUntilDone(downloader)

        #expect(downloader.phase == .finished)
        // Only what had already been sent for the first article went out.
        #expect(await sent.inputs.count(where: texts.contains) <= AudioDownloader.maxConcurrent)
        #expect(await sent.inputs.contains("The only paragraph."))
    }

    @Test func cancelStopsAndClearsTheQueue() async throws {
        let texts = (1...8).map { "Paragraph number \($0)." }
        let first = try article("First", texts.map(ContentBlock.paragraph))
        let downloader = makeDownloader(delay: .milliseconds(50))

        downloader.start(await plan([first]))
        downloader.cancel()

        #expect(downloader.phase == .idle)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await sent.inputs.count <= AudioDownloader.maxConcurrent)
        #expect(downloader.phase == .idle)
    }

    @Test func addingToARunningDownloadSkipsTextAlreadyQueued() async throws {
        let first = try article("First", blocks)
        let downloader = makeDownloader(delay: .milliseconds(30))
        let plan = await plan([first])

        downloader.start(plan)
        downloader.start(plan)
        #expect(downloader.totalPieces == 3)
        try await waitUntilDone(downloader)

        #expect(await sent.inputs.count == 3)
    }
}

// MARK: - SpeechGenerations

@MainActor
struct SpeechGenerationsTests {
    @Test func theSameTextIsGeneratedOnceWhileInFlight() async throws {
        let sent = SentInputs()
        let client = OpenAITTSClient(transport: { request in
            await sent.record("x")
            try await Task.sleep(for: .milliseconds(30))
            return (Data("ID3".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, retry: .never)
        let cache = temporaryCache()
        let generations = SpeechGenerations()
        let request = OpenAISpeechEngine.request(for: "Hello.", voice: "marin")

        let first = generations.generate(request, apiKey: "sk", client: client, cache: cache)
        let second = generations.generate(request, apiKey: "sk", client: client, cache: cache)
        #expect(generations.isGenerating(request, in: cache))
        _ = await first.value
        _ = await second.value

        #expect(await sent.inputs.count == 1)
        #expect(cache.cachedFile(for: request) != nil)
        // A different cache is a different file, so a different generation.
        let other = temporaryCache()
        _ = await generations.generate(request, apiKey: "sk", client: client, cache: other).value
        #expect(await sent.inputs.count == 2)
    }
}
