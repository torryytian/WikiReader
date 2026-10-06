import Foundation
import OSLog

/// `SpeechEngine` that speaks with OpenAI voices.
///
/// Each block is generated once (split into chunks if longer than a request allows), cached on
/// disk, and played with `AVAudioPlayer`. Starting part-way through a block seeks inside its audio,
/// and speed is the player's rate, so neither generates new audio. Word positions are estimated
/// from playback progress (`WordTimeline`), since OpenAI returns no timestamps.
final class OpenAISpeechEngine: SpeechEngine {
    static let model = "gpt-4o-mini-tts"
    static let defaultVoice = "marin"
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
    static let instructions = "Read like a clear, natural audiobook narrator, at a steady, moderate pace."

    var onEvent: ((SpeechEvent) -> Void)?

    private let voice: String
    private let client: OpenAITTSClient
    private let cache: SpeechAudioCache
    private let apiKey: () -> String?
    private let makeClip: (URL) throws -> AudioClip
    private let tickInterval: Duration

    /// Generation in progress, by cache key: `speak` and `prepare` share one request per text.
    private var inFlight: [String: Task<Result<URL, OpenAITTSError>, Never>] = [:]
    private var current: Playback?

    /// Playback state of the utterance being spoken.
    private final class Playback {
        let id: Int
        let text: NSString
        let chunks: [NSRange]
        let rate: SpeechRate
        let pauseAfter: TimeInterval
        var chunkIndex = 0
        var clip: AudioClip?
        var timeline: WordTimeline?
        var isPaused = false
        var hasStarted = false
        var lastWord: NSRange?
        var loading: Task<Void, Never>?
        var ticker: Task<Void, Never>?

        init(_ utterance: SpeechUtterance) {
            id = utterance.id
            text = utterance.text as NSString
            chunks = SpeechChunking.chunks(of: utterance.text)
            rate = utterance.rate
            pauseAfter = utterance.pauseAfter
        }

        func chunkText(_ index: Int) -> String { text.substring(with: chunks[index]) }
    }

    init(
        voice: String = OpenAISpeechEngine.defaultVoice,
        client: OpenAITTSClient = OpenAITTSClient(),
        cache: SpeechAudioCache = .standard,
        apiKey: @escaping () -> String? = { KeychainStore.openAIKey.read() },
        makeClip: @escaping (URL) throws -> AudioClip = { try AVAudioClip(contentsOf: $0) },
        tickInterval: Duration = .milliseconds(80)
    ) {
        self.voice = voice
        self.client = client
        self.cache = cache
        self.apiKey = apiKey
        self.makeClip = makeClip
        self.tickInterval = tickInterval
        Log.speech.info("Using OpenAI voice \(voice, privacy: .public)")
    }

    // MARK: - SpeechEngine

    func speak(_ utterance: SpeechUtterance) {
        stopPlayback()
        SpokenAudioSession.activate()
        let playback = Playback(utterance)
        current = playback
        let first = playback.chunks.firstIndex { utterance.startOffset < $0.upperBound } ?? playback.chunks.count - 1
        play(chunk: first, of: playback, from: utterance.startOffset)
        // The rest of a long block is generated while its start plays.
        for index in playback.chunks.indices where index > first {
            _ = audioFile(for: playback.chunkText(index))
        }
    }

    func pause() {
        guard let playback = current else { return }
        playback.isPaused = true
        playback.clip?.pause()
        playback.ticker?.cancel()
    }

    func resume() {
        guard let playback = current, playback.isPaused else { return }
        playback.isPaused = false
        // If the audio is still being generated, it starts when ready.
        if playback.clip != nil { start(playback) }
    }

    func stop() {
        stopPlayback()
        SpokenAudioSession.deactivate()
    }

    func prepare(_ text: String) {
        for chunk in SpeechChunking.chunks(of: text) {
            _ = audioFile(for: (text as NSString).substring(with: chunk))
        }
    }

    // MARK: - Playback

    private func stopPlayback() {
        guard let playback = current else { return }
        current = nil
        // Generation itself isn't cancelled: the audio is paid for, so let it reach the cache.
        playback.loading?.cancel()
        playback.ticker?.cancel()
        playback.clip?.stop()
    }

    private func play(chunk index: Int, of playback: Playback, from offset: Int?) {
        playback.chunkIndex = index
        playback.clip = nil
        let chunkRange = playback.chunks[index]
        let chunkText = playback.chunkText(index)
        let file = audioFile(for: chunkText)

        playback.loading = Task {
            let result = await file.value
            guard current === playback else { return }
            switch result {
            case .failure(let error):
                fail(playback, error)
            case .success(let url):
                do {
                    try load(url, text: chunkText, startingAt: offset.map { $0 - chunkRange.location }, into: playback)
                    if !playback.isPaused { start(playback) }
                } catch {
                    fail(playback, .audio(error.localizedDescription))
                }
            }
        }
    }

    /// Opens a chunk's audio, seeked to `offset` (relative to the chunk text) if given.
    private func load(_ url: URL, text: String, startingAt offset: Int?, into playback: Playback) throws {
        let clip = try makeClip(url)
        let timeline = WordTimeline(text: text)
        clip.rate = Float(playback.rate.rawValue)
        if let offset, offset > 0 {
            clip.currentTime = timeline.fraction(atOffset: offset) * clip.duration
        }
        // Weak: playback owns the clip, which owns this closure.
        clip.onFinish = { [weak self, weak playback] in
            guard let self, let playback else { return }
            chunkFinished(playback)
        }
        playback.clip = clip
        playback.timeline = timeline
    }

    private func start(_ playback: Playback) {
        guard let clip = playback.clip else { return }
        clip.play()
        if !playback.hasStarted {
            playback.hasStarted = true
            onEvent?(.started(id: playback.id))
        }
        playback.ticker?.cancel()
        playback.ticker = Task {
            while !Task.isCancelled {
                reportWord(playback)
                try? await Task.sleep(for: tickInterval)
            }
        }
    }

    /// Emits `willSpeak` when the estimated word under the playhead changes.
    private func reportWord(_ playback: Playback) {
        guard current === playback, let clip = playback.clip, let timeline = playback.timeline, clip.duration > 0,
              let index = timeline.wordIndex(atFraction: clip.currentTime / clip.duration)
        else { return }
        let local = timeline.words[index]
        let word = NSRange(location: playback.chunks[playback.chunkIndex].location + local.location, length: local.length)
        guard word != playback.lastWord else { return }
        playback.lastWord = word
        onEvent?(.willSpeak(id: playback.id, range: word))
    }

    private func chunkFinished(_ playback: Playback) {
        guard current === playback else { return }
        playback.ticker?.cancel()
        if playback.chunkIndex + 1 < playback.chunks.count {
            play(chunk: playback.chunkIndex + 1, of: playback, from: nil)
            return
        }
        playback.loading = Task {
            if playback.pauseAfter > 0 {
                try? await Task.sleep(for: .seconds(playback.pauseAfter))
            }
            guard current === playback, !Task.isCancelled else { return }
            current = nil
            onEvent?(.finished(id: playback.id))
        }
    }

    private func fail(_ playback: Playback, _ error: OpenAITTSError) {
        Log.speech.error("OpenAI speech failed: \(error.message, privacy: .public)")
        stopPlayback()
        onEvent?(.failed(id: playback.id, failure: error.failure))
    }

    // MARK: - Audio files

    private func request(for text: String) -> OpenAISpeechRequest {
        OpenAISpeechRequest(model: Self.model, voice: voice, input: text, instructions: Self.instructions)
    }

    /// The cached audio for `text`, generating it if needed. Concurrent callers share one request.
    private func audioFile(for text: String) -> Task<Result<URL, OpenAITTSError>, Never> {
        let request = request(for: text)
        let key = SpeechAudioCache.key(for: request)
        if let pending = inFlight[key] { return pending }
        if let url = cache.cachedFile(for: request) {
            return Task { .success(url) }
        }
        guard let apiKey = apiKey(), !apiKey.isEmpty else {
            return Task { .failure(.missingKey) }
        }

        Log.speech.info("Generating OpenAI audio for \((text as NSString).length) characters")
        let client = client, cache = cache
        let task = Task { await Self.generate(request, apiKey: apiKey, client: client, cache: cache) }
        inFlight[key] = task
        Task {
            _ = await task.value
            inFlight[key] = nil
        }
        return task
    }

    /// Network and file work, off the main actor.
    @concurrent
    private static func generate(
        _ request: OpenAISpeechRequest, apiKey: String, client: OpenAITTSClient, cache: SpeechAudioCache
    ) async -> Result<URL, OpenAITTSError> {
        let audio: Data
        do {
            audio = try await client.synthesize(request, apiKey: apiKey)
        } catch {
            return .failure(error)
        }
        do {
            return .success(try cache.store(audio, for: request))
        } catch {
            return .failure(.audio(error.localizedDescription))
        }
    }
}
