import Foundation
import Testing
@testable import WikiReader

/// A silent clip whose playhead the test moves by hand.
final class FakeClip: AudioClip {
    let url: URL
    var duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var rate: Float = 1
    var onFinish: (() -> Void)?
    private(set) var isPlaying = false
    private(set) var playCount = 0

    init(url: URL) { self.url = url }

    func play() { isPlaying = true; playCount += 1 }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func finish() { isPlaying = false; onFinish?() }
}

/// Records the texts sent to the fake OpenAI endpoint.
actor RequestLog {
    private(set) var inputs: [String] = []
    func record(_ input: String) { inputs.append(input) }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OpenAISpeechEngineTests {
    let log = RequestLog()
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "OpenAIEngineTests-\(UUID().uuidString)"))
    let recorder = Recorder()

    final class Recorder {
        var events: [SpeechEvent] = []
        var clips: [FakeClip] = []
    }

    /// An engine whose network answers after `delay` with `status` (200: fake MP3 bytes).
    private func makeEngine(status: Int = 200, delay: Duration = .zero, key: String? = "sk-test") -> OpenAISpeechEngine {
        let log = log
        let client = OpenAITTSClient { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            await log.record(body["input"]!)
            try await Task.sleep(for: delay)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (status == 200 ? Data("ID3 fake audio".utf8) : Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8), response)
        }
        let recorder = recorder
        let engine = OpenAISpeechEngine(
            client: client,
            cache: cache,
            apiKey: { key },
            makeClip: { url in
                let clip = FakeClip(url: url)
                recorder.clips.append(clip)
                return clip
            },
            tickInterval: .milliseconds(5)
        )
        engine.onEvent = { recorder.events.append($0) }
        return engine
    }

    private func wait(seconds: Double = 5, until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func spokenWords(_ text: String, id: Int = 1) -> [String] {
        recorder.events.compactMap {
            if case .willSpeak(id, let range) = $0 { (text as NSString).substring(with: range) } else { nil }
        }
    }

    private var requestCount: Int { get async { await log.inputs.count } }

    // MARK: - Playing

    @Test func generatesPlaysReportsWordsAndFinishes() async throws {
        let engine = makeEngine()
        let text = "Hello there, world."
        engine.speak(SpeechUtterance(id: 1, text: text, rate: .normal))
        try await wait { recorder.clips.first?.isPlaying == true }

        #expect(recorder.events.first == .started(id: 1))
        try await wait { spokenWords(text).contains("Hello") }
        recorder.clips[0].currentTime = 9.9
        try await wait { spokenWords(text).contains("world") }
        #expect(spokenWords(text) == spokenWords(text).sorted { text.range(of: $0)!.lowerBound < text.range(of: $1)!.lowerBound })

        recorder.clips[0].finish()
        try await wait { recorder.events.last == .finished(id: 1) }
        #expect(recorder.events.last == .finished(id: 1))
        #expect(await log.inputs == [text])
    }

    @Test func cachedTextIsNotGeneratedAgain() async throws {
        let engine = makeEngine()
        let text = "Spoken twice."
        engine.speak(SpeechUtterance(id: 1, text: text, rate: .normal))
        try await wait { recorder.clips.count == 1 }
        engine.speak(SpeechUtterance(id: 2, text: text, rate: .normal))
        try await wait { recorder.clips.count == 2 }
        #expect(await requestCount == 1)
        #expect(recorder.clips[0].url == recorder.clips[1].url)
    }

    @Test func startOffsetSeeksIntoTheAudioInsteadOfGeneratingAgain() async throws {
        let engine = makeEngine()
        let text = "First part here. Second part there."
        engine.speak(SpeechUtterance(id: 1, text: text, rate: .normal))
        try await wait { recorder.clips.count == 1 }

        let offset = (text as NSString).range(of: "Second").location
        engine.speak(SpeechUtterance(id: 2, text: text, startOffset: offset, rate: .normal))
        try await wait { spokenWords(text, id: 2).first != nil }
        #expect(recorder.clips[1].currentTime > 0)
        #expect(spokenWords(text, id: 2).first == "Second")
        #expect(await requestCount == 1)
    }

    @Test func rateIsThePlayerRate() async throws {
        let engine = makeEngine()
        engine.speak(SpeechUtterance(id: 1, text: "Fast.", rate: .fast))
        try await wait { recorder.clips.count == 1 }
        #expect(recorder.clips[0].rate == 1.25)
    }

    @Test func headingPauseDelaysFinish() async throws {
        let engine = makeEngine()
        engine.speak(SpeechUtterance(id: 1, text: "Early life", rate: .normal, pauseAfter: 0.2))
        try await wait { recorder.clips.count == 1 }
        let finishedAt = ContinuousClock.now
        recorder.clips[0].finish()
        try await wait { recorder.events.last == .finished(id: 1) }
        #expect(ContinuousClock.now - finishedAt >= .milliseconds(200))
    }

    // MARK: - Generating ahead

    @Test func prepareGeneratesOnceAhead() async throws {
        let engine = makeEngine()
        engine.prepare("The next block.")
        try await wait { await requestCount == 1 }
        try await Task.sleep(for: .milliseconds(50))
        engine.speak(SpeechUtterance(id: 1, text: "The next block.", rate: .normal))
        try await wait { recorder.clips.count == 1 }
        #expect(await requestCount == 1)
    }

    @Test func speakWhilePreparingSharesTheRequest() async throws {
        let engine = makeEngine(delay: .milliseconds(100))
        engine.prepare("Shared text.")
        engine.speak(SpeechUtterance(id: 1, text: "Shared text.", rate: .normal))
        try await wait { recorder.clips.count == 1 }
        #expect(await requestCount == 1)
    }

    @Test func longBlockPlaysItsChunksInOrder() async throws {
        let engine = makeEngine()
        let sentence = "This sentence is repeated to make a very long paragraph for the test. "
        let text = String(repeating: sentence, count: 70)  // about 4900 characters: two requests
        engine.speak(SpeechUtterance(id: 1, text: text, rate: .normal))
        try await wait { await requestCount == 2 }  // the second chunk is generated while the first plays
        try await wait { recorder.clips.count == 1 }

        recorder.clips[0].finish()
        try await wait { recorder.clips.count == 2 && recorder.clips[1].isPlaying }
        recorder.clips[1].currentTime = 0
        let secondChunkStart = SpeechChunking.chunks(of: text)[1].location
        try await wait {
            recorder.events.contains { if case .willSpeak(1, let r) = $0 { r.location >= secondChunkStart } else { false } }
        }
        #expect(!recorder.events.contains(.finished(id: 1)))
        recorder.clips[1].finish()
        try await wait { recorder.events.last == .finished(id: 1) }
        #expect(recorder.events.filter { $0 == .started(id: 1) }.count == 1)
    }

    // MARK: - Pausing and stopping

    @Test func pauseAndResume() async throws {
        let engine = makeEngine()
        engine.speak(SpeechUtterance(id: 1, text: "Pause me.", rate: .normal))
        try await wait { recorder.clips.first?.isPlaying == true }
        engine.pause()
        #expect(recorder.clips[0].isPlaying == false)
        engine.resume()
        #expect(recorder.clips[0].isPlaying)
        #expect(recorder.events.filter { $0 == .started(id: 1) }.count == 1)
    }

    @Test func pauseBeforeAudioIsReadyHoldsUntilResume() async throws {
        let engine = makeEngine(delay: .milliseconds(100))
        engine.speak(SpeechUtterance(id: 1, text: "Not ready yet.", rate: .normal))
        engine.pause()
        try await wait { recorder.clips.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.clips[0].playCount == 0)
        #expect(!recorder.events.contains(.started(id: 1)))

        engine.resume()
        #expect(recorder.clips[0].isPlaying)
        #expect(recorder.events.contains(.started(id: 1)))
    }

    @Test func stopWhileGeneratingEmitsNothingButKeepsTheAudio() async throws {
        let engine = makeEngine(delay: .milliseconds(100))
        let text = "Stopped early."
        engine.speak(SpeechUtterance(id: 1, text: text, rate: .normal))
        engine.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.events.isEmpty)
        #expect(recorder.clips.isEmpty)
        let request = OpenAISpeechRequest(model: OpenAISpeechEngine.model, voice: OpenAISpeechEngine.defaultVoice, input: text, instructions: OpenAISpeechEngine.instructions)
        #expect(cache.cachedFile(for: request) != nil)  // paid for, so kept for next time
    }

    @Test func newUtteranceSupersedesOneStillGenerating() async throws {
        let engine = makeEngine(delay: .milliseconds(80))
        engine.speak(SpeechUtterance(id: 1, text: "Old block.", rate: .normal))
        engine.speak(SpeechUtterance(id: 2, text: "New block.", rate: .normal))
        try await wait { recorder.events.contains(.started(id: 2)) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!recorder.events.contains { [.started(id: 1), .finished(id: 1)].contains($0) })
        #expect(recorder.clips.count == 1)
    }

    // MARK: - Failures

    @Test func missingKeyFailsWithoutARequest() async throws {
        let engine = makeEngine(key: nil)
        engine.speak(SpeechUtterance(id: 1, text: "No key.", rate: .normal))
        try await wait { !recorder.events.isEmpty }
        #expect(recorder.events == [.failed(id: 1, message: OpenAITTSError.missingKey.message)])
        #expect(await requestCount == 0)
    }

    @Test func apiErrorFails() async throws {
        let engine = makeEngine(status: 401)
        engine.speak(SpeechUtterance(id: 1, text: "Bad key.", rate: .normal))
        try await wait { !recorder.events.isEmpty }
        #expect(recorder.events == [.failed(id: 1, message: OpenAITTSError.invalidKey.message)])
        #expect(recorder.clips.isEmpty)
    }
}
