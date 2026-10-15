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
    private let makeClip: (URL) async throws -> AudioClip
    private let tickInterval: Duration
    /// How long after starting a clip it must have moved before it is called stalled; nil turns the check off.
    private let stallCheck: Duration?
    private let log: PlaybackLog

    /// Generation in progress, by cache key: `speak` and `prepare` share one request per text.
    private var inFlight: [String: Task<Result<URL, OpenAITTSError>, Never>] = [:]
    /// Texts to generate ahead of time, nearest first, not started yet. Replaced by each `prepare`.
    private var queued: [(key: String, request: OpenAISpeechRequest)] = []
    /// The generations in `inFlight` that were started ahead of time; at most `maxConcurrentPrefetch` run at once, so
    /// preparing several blocks doesn't flood the API (new accounts are rate limited) or slow the one being read.
    private var prefetching: Set<String> = []
    static let maxConcurrentPrefetch = 2
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
        /// Checks that the clip's playhead really moves after it was started or continued.
        var watchdog: Task<Void, Never>?

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
        makeClip: @escaping (URL) async throws -> AudioClip = { try await AVAudioClip.make(contentsOf: $0) },
        tickInterval: Duration = .milliseconds(80),
        stallCheck: Duration? = .milliseconds(500),
        log: PlaybackLog = .standard
    ) {
        self.voice = voice
        self.client = client
        self.cache = cache
        self.apiKey = apiKey
        self.makeClip = makeClip
        self.tickInterval = tickInterval
        self.stallCheck = stallCheck
        self.log = log
        Log.speech.info("Using OpenAI voice \(voice, privacy: .public)")
    }

    // MARK: - SpeechEngine

    func speak(_ utterance: SpeechUtterance) {
        stopPlayback()
        SpokenAudioSession.activate()
        let playback = Playback(utterance)
        current = playback
        log.record("engine", "speak id=\(utterance.id) chars=\(playback.text.length) from=\(utterance.startOffset) chunks=\(playback.chunks.count) rate=\(utterance.rate.rawValue) \(AudioDiagnostics.sessionSummary())")
        let first = playback.chunks.firstIndex { utterance.startOffset < $0.upperBound } ?? playback.chunks.count - 1
        play(chunk: first, of: playback, from: utterance.startOffset)
        // The rest of a long block is generated while its start plays.
        for index in playback.chunks.indices where index > first {
            _ = audioFile(for: playback.chunkText(index))
        }
    }

    func pause() {
        guard let playback = current else {
            log.record("engine", "pause: nothing is being played")
            return
        }
        playback.isPaused = true
        playback.clip?.pause()
        playback.ticker?.cancel()
        playback.watchdog?.cancel()
        log.record("engine", "pause chunk=\(playback.chunkIndex + 1)/\(playback.chunks.count) \(AudioDiagnostics.clipSummary(playback.clip))")
    }

    func resume() {
        guard let playback = current, playback.isPaused else {
            log.record("engine", "resume ignored: \(current == nil ? "nothing is being played" : "not paused")")
            return
        }
        playback.isPaused = false
        // `speak` activates the audio session; continuing a paused clip has to as well, in case the system
        // deactivated it while nothing was playing.
        SpokenAudioSession.activate()
        log.record("engine", "resume chunk=\(playback.chunkIndex + 1)/\(playback.chunks.count) \(AudioDiagnostics.clipSummary(playback.clip)) \(AudioDiagnostics.sessionSummary())")
        // If the audio is still being generated, it starts when ready.
        if playback.clip != nil { start(playback) }
    }

    func stop() {
        queued = []
        stopPlayback()
        SpokenAudioSession.deactivate()
    }

    func prepare(upcoming texts: [String]) {
        var wanted: [(key: String, request: OpenAISpeechRequest)] = []
        for text in texts {
            let ns = text as NSString
            for chunk in SpeechChunking.chunks(of: text) {
                let request = request(for: ns.substring(with: chunk))
                let key = SpeechAudioCache.key(for: request)
                guard inFlight[key] == nil, !wanted.contains(where: { $0.key == key }), cache.cachedFile(for: request) == nil else { continue }
                wanted.append((key, request))
            }
        }
        queued = wanted
        if !wanted.isEmpty { log.record("prefetch", "queued \(wanted.count) request(s) ahead; running \(prefetching.count)") }
        pumpPrefetch()
    }

    /// Starts queued generations while fewer than `maxConcurrentPrefetch` of them are running.
    private func pumpPrefetch() {
        guard let key = apiKey(), !key.isEmpty else {
            queued = []
            return
        }
        while prefetching.count < Self.maxConcurrentPrefetch, !queued.isEmpty {
            let next = queued.removeFirst()
            guard inFlight[next.key] == nil, cache.cachedFile(for: next.request) == nil else { continue }
            prefetching.insert(next.key)
            _ = startGeneration(next.request, key: next.key, apiKey: key)
        }
    }

    // MARK: - Playback

    private func stopPlayback() {
        guard let playback = current else { return }
        current = nil
        // Generation itself isn't cancelled: the audio is paid for, so let it reach the cache.
        playback.loading?.cancel()
        playback.ticker?.cancel()
        playback.watchdog?.cancel()
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
                    try await load(url, text: chunkText, startingAt: offset.map { $0 - chunkRange.location }, into: playback)
                    // Opening the clip took a moment (it is amplified off the main actor): look again.
                    guard current === playback, !Task.isCancelled else { return }
                    if playback.isPaused {
                        log.record("engine", "chunk \(index + 1)/\(playback.chunks.count) ready but paused; waiting for play")
                    } else {
                        start(playback)
                    }
                } catch {
                    fail(playback, .audio(error.localizedDescription))
                }
            }
        }
    }

    /// Opens a chunk's audio, seeked to `offset` (relative to the chunk text) if given.
    private func load(_ url: URL, text: String, startingAt offset: Int?, into playback: Playback) async throws {
        let clip = try await makeClip(url)
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
        if let note = clip.loudnessNote {
            log.record("clip", "opened chunk \(playback.chunkIndex + 1)/\(playback.chunks.count) \(note)")
        }
    }

    private func start(_ playback: Playback) {
        guard let clip = playback.clip else { return }
        let accepted = clip.play()
        log.record("clip", "play() -> \(accepted) chunk=\(playback.chunkIndex + 1)/\(playback.chunks.count) \(AudioDiagnostics.clipSummary(clip))")
        watch(playback, clip: clip)
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

    /// After a clip is started or continued, checks that its playhead moves. If it doesn't (the system accepted
    /// `play()` but nothing is coming out) it tries the audio session once more, and if that doesn't help either
    /// reports `stalled`, so the reader starts the utterance again with a fresh player.
    private func watch(_ playback: Playback, clip: AudioClip) {
        playback.watchdog?.cancel()
        guard let stallCheck else { return }
        playback.watchdog = Task {
            for attempt in 1...2 {
                let from = clip.currentTime
                try? await Task.sleep(for: stallCheck)
                guard !Task.isCancelled, current === playback, !playback.isPaused, playback.clip === clip else { return }
                // A clip about to end has nothing left to move through.
                if clip.duration - from < 0.4 { return }
                // A quarter of how far a healthy player would have moved in that time.
                let needed = 0.25 * (Double(stallCheck.components.seconds) + Double(stallCheck.components.attoseconds) / 1e18) * Double(max(clip.rate, 0.5))
                let moved = clip.currentTime - from
                if clip.isPlaying, moved >= needed { return }
                log.record("stall", "no audio progress after \(stallCheck) (moved \(String(format: "%.2f", moved)) s) attempt \(attempt) \(AudioDiagnostics.clipSummary(clip)) \(AudioDiagnostics.sessionSummary())")
                if attempt == 1 {
                    SpokenAudioSession.activate()
                    let accepted = clip.play()
                    log.record("stall", "re-activated the session and called play() -> \(accepted)")
                }
            }
            log.record("stall", "still silent: asking the reader to start again from the current word")
            onEvent?(.stalled(id: playback.id))
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
        playback.watchdog?.cancel()
        log.record("clip", "chunk \(playback.chunkIndex + 1)/\(playback.chunks.count) finished")
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

    /// The cached audio for `text`, generating it at once if needed (this is what is being read, so it doesn't wait
    /// behind the queue of audio prepared ahead). Concurrent callers share one request.
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
        queued.removeAll { $0.key == key }
        return startGeneration(request, key: key, apiKey: apiKey)
    }

    private func startGeneration(_ request: OpenAISpeechRequest, key: String, apiKey: String) -> Task<Result<URL, OpenAITTSError>, Never> {
        Log.speech.info("Generating OpenAI audio for \(request.input.utf16.count) characters")
        let client = client, cache = cache
        let task = Task { await Self.generate(request, apiKey: apiKey, client: client, cache: cache) }
        inFlight[key] = task
        Task {
            _ = await task.value
            inFlight[key] = nil
            // A finished generation frees a slot for the next one waiting.
            if prefetching.remove(key) != nil { pumpPrefetch() }
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
