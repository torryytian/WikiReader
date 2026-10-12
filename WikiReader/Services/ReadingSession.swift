import Foundation
import Observation
import OSLog

/// The read-aloud flow for one article: which block is spoken, moving on to the next one,
/// pausing and resuming, skipping, and speed changes. Sound itself comes from a `SpeechEngine`.
@Observable
final class ReadingSession {
    enum State: Equatable {
        case stopped
        case playing
        case paused
    }

    /// Where the speech currently is: a word inside a block (UTF-16 range relative to the block text).
    struct Position: Equatable {
        var block: Int
        var range: NSRange
    }

    /// Pause after a heading is read, so it sounds like a heading.
    static let pauseAfterHeading: TimeInterval = 0.6
    /// How fast speech goes at 1×, in characters per second. Neither the system synthesizer nor the cloud audio
    /// reports time per character, so "skip 10 seconds" and "minutes left" are estimates from this.
    nonisolated static let charactersPerSecond = 14.0

    private(set) var state: State = .stopped
    /// The block being read, or the one that will be read when playback starts.
    private(set) var currentBlock: Int
    /// The word being spoken; nil when nothing is being spoken.
    private(set) var spokenWord: Position?
    private(set) var rate: SpeechRate
    /// True between asking the engine to speak and sound actually starting (a cloud voice may
    /// need a moment to generate audio).
    private(set) var isWaitingForAudio = false
    /// Why speech stopped unexpectedly; cleared on the next play.
    private(set) var failure: SpeechFailure?

    /// Called whenever reading moves to another block, so the position can be saved.
    @ObservationIgnored var onBlockChange: (Int) -> Void = { _ in }
    /// Called when the last block has been read to the end. By then the session is stopped and back at the
    /// start; the owner decides what happens next (loop, another article, nothing).
    @ObservationIgnored var onFinished: () -> Void = {}

    @ObservationIgnored private let blocks: [ContentBlock]
    @ObservationIgnored private var engine: SpeechEngine
    /// Id of the utterance we're waiting on; events with other ids are stale.
    @ObservationIgnored private var utteranceID = 0
    /// Whether the engine holds a (possibly paused) utterance for `currentBlock` that `resume` can continue.
    @ObservationIgnored private var hasActiveUtterance = false
    /// UTF-16 offset in the block to start from on the next `speakCurrentBlock`.
    @ObservationIgnored private var resumeOffset = 0
    @ObservationIgnored private let playbackLog: PlaybackLog
    /// How many times in a row an engine reported silence and the utterance was started again; reset by anything
    /// the user does and by an utterance that played to its end.
    @ObservationIgnored private var stallRestarts = 0
    static let maxStallRestarts = 2
    /// How far ahead audio is prepared: up to this many seconds of speech after the current block, but never more than
    /// `maxLookaheadBlocks` blocks. A heading is read in a second or two while the paragraph after it takes several
    /// seconds to generate, so preparing only the next block would leave the reader waiting.
    nonisolated static let lookaheadSeconds = 75.0
    nonisolated static let maxLookaheadBlocks = 4

    init(blocks: [ContentBlock], startBlock: Int = 0, rate: SpeechRate = .normal, engine: SpeechEngine, log: PlaybackLog = .standard) {
        self.playbackLog = log
        self.blocks = blocks
        self.currentBlock = blocks.indices.contains(startBlock) ? startBlock : 0
        self.rate = rate
        self.engine = engine
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    var isPlaying: Bool { state == .playing }

    /// One line in the playback log, with where reading is.
    private func record(_ kind: String, _ detail: String = "") {
        let word = spokenWord.map { "@\($0.range.location)" } ?? "-"
        playbackLog.record(kind, "\(detail)\(detail.isEmpty ? "" : " ")[state=\(state) block=\(currentBlock + 1)/\(blocks.count) word=\(word) active=\(hasActiveUtterance) waiting=\(isWaitingForAudio)]")
    }

    // MARK: - Controls

    /// Continues where speech left off: the paused word, else the start of `currentBlock`.
    func play() {
        guard !blocks.isEmpty, state != .playing else { return }
        failure = nil
        stallRestarts = 0
        if state == .paused && hasActiveUtterance {
            record("play", "resume the paused utterance")
            engine.resume()
            state = .playing
            Log.speech.info("Resumed block \(self.currentBlock)")
        } else {
            record("play", "start speaking")
            speakCurrentBlock()
        }
    }

    func pause() {
        guard state == .playing else { return }
        record("pause")
        engine.pause()
        state = .paused
        Log.speech.info("Paused in block \(self.currentBlock)")
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Starts reading at a block, e.g. after a long press on a paragraph.
    func start(at block: Int) {
        guard blocks.indices.contains(block) else { return }
        stallRestarts = 0
        record("start", "at block \(block + 1)")
        move(to: block)
        speakCurrentBlock()
    }

    /// Jumps to a block (e.g. a section chosen in the table of contents). While playing, reading continues from
    /// there; while paused or stopped, it stays so and play starts there.
    func go(to block: Int) {
        guard blocks.indices.contains(block) else { return }
        record("jump", "go to block \(block + 1)")
        jump(to: block)
    }

    func next() {
        guard currentBlock + 1 < blocks.count else { return }
        record("jump", "next")
        jump(to: currentBlock + 1)
    }

    /// Goes to the previous block; at the first block, back to its start.
    func previous() {
        record("jump", "previous")
        jump(to: max(currentBlock - 1, 0))
    }

    /// Skips forward (positive) or back (negative) by about this many seconds of speech, across blocks if needed.
    /// The distance is an estimate (`charactersPerSecond`), and the new position is the start of a word.
    /// While playing, speech continues from there; while paused or stopped, play starts from there.
    func skip(seconds: Double) {
        guard !blocks.isEmpty else { return }
        let characters = Int((seconds * Self.charactersPerSecond * rate.rawValue).rounded())
        let lengths = blocks.map { ($0.text as NSString).length }
        let from = spokenWord?.range.location ?? resumeOffset
        let target = Self.skipTarget(blockLengths: lengths, block: currentBlock, offset: from, characters: characters)

        let text = blocks[target.block].text as NSString
        let offset = Self.wordStart(in: text, atOrBefore: min(target.offset, max(text.length - 1, 0)))
        Log.speech.info("Skip \(Int(seconds)) s: block \(self.currentBlock) -> \(target.block), offset \(offset)")
        stallRestarts = 0
        record("skip", "\(Int(seconds)) s -> block \(target.block + 1) offset \(offset)")

        switch state {
        case .playing:
            move(to: target.block)
            speakCurrentBlock(from: offset)
        case .paused, .stopped:
            discardUtterance()
            move(to: target.block)
            resumeOffset = offset
            spokenWord = nil
        }
    }

    /// Where moving `characters` (negative: back) from `offset` in `block` ends up, walking over block boundaries.
    /// Stops at the very start, or at the end of the last block.
    static func skipTarget(blockLengths: [Int], block: Int, offset: Int, characters: Int) -> (block: Int, offset: Int) {
        var block = block
        var offset = offset
        var remaining = characters
        while remaining > 0 {
            let available = blockLengths[block] - offset
            if remaining < available {
                offset += remaining
                break
            }
            guard block + 1 < blockLengths.count else { return (block, blockLengths[block]) }
            remaining -= available
            block += 1
            offset = 0
        }
        while remaining < 0 {
            if -remaining <= offset {
                offset += remaining
                break
            }
            guard block > 0 else { return (0, 0) }
            remaining += offset
            block -= 1
            offset = blockLengths[block]
        }
        return (block, offset)
    }

    /// The start of the word at or before `offset`, so speech never begins in the middle of a word.
    static func wordStart(in text: NSString, atOrBefore offset: Int) -> Int {
        var index = min(max(offset, 0), text.length)
        while index > 0, let scalar = Unicode.Scalar(text.character(at: index - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            index -= 1
        }
        return index
    }

    /// Changes speed. While speaking, restarts from the current word so the change is immediate.
    func setRate(_ newRate: SpeechRate) {
        guard newRate != rate else { return }
        rate = newRate
        Log.speech.info("Rate set to \(newRate.label, privacy: .public)")
        let wordOffset = spokenWord.map { $0.range.location } ?? resumeOffset
        switch state {
        case .playing:
            speakCurrentBlock(from: wordOffset)
        case .paused:
            // The paused utterance has the old speed baked in; start fresh from this word on play.
            discardUtterance()
            resumeOffset = wordOffset
        case .stopped:
            break
        }
    }

    func dismissFailure() {
        failure = nil
    }

    /// Switches to another engine (e.g. the system voice after a cloud voice failed), keeping the
    /// place: if playing, the new engine continues from the current word.
    func replaceEngine(_ newEngine: SpeechEngine) {
        let wordOffset = spokenWord?.range.location ?? resumeOffset
        discardUtterance()
        engine.onEvent = nil  // late events from the old engine must not reach us
        engine = newEngine
        newEngine.onEvent = { [weak self] event in self?.handle(event) }
        failure = nil
        Log.speech.info("Speech engine replaced")
        record("engine", "replaced the speech engine")
        if state == .playing {
            speakCurrentBlock(from: wordOffset)
        } else {
            resumeOffset = wordOffset
        }
    }

    /// Sets where reading will start, e.g. the paragraph the user scrolled to.
    /// Ignored while playing or paused: the spoken position wins then.
    func moveWhileStopped(to block: Int) {
        guard state == .stopped, blocks.indices.contains(block) else { return }
        move(to: block)
    }

    func stop() {
        guard state != .stopped || hasActiveUtterance else { return }
        record("stop")
        discardUtterance()
        state = .stopped
        spokenWord = nil
        Log.speech.info("Stopped at block \(self.currentBlock)")
    }

    // MARK: - Speaking

    private func jump(to block: Int) {
        switch state {
        case .playing:
            move(to: block)
            speakCurrentBlock()
        case .paused, .stopped:
            // Stay paused/stopped; play will start at the new block.
            discardUtterance()
            move(to: block)
            spokenWord = nil
        }
    }

    private func move(to block: Int) {
        resumeOffset = 0
        guard block != currentBlock else { return }
        currentBlock = block
        onBlockChange(block)
    }

    private func speakCurrentBlock(from offset: Int? = nil) {
        let block = blocks[currentBlock]
        let start = min(offset ?? resumeOffset, (block.text as NSString).length)
        resumeOffset = 0

        utteranceID += 1
        hasActiveUtterance = true
        isWaitingForAudio = true
        state = .playing
        engine.speak(SpeechUtterance(
            id: utteranceID,
            text: block.text,
            startOffset: start,
            rate: rate,
            pauseAfter: block.kind == .heading ? Self.pauseAfterHeading : 0
        ))
        Log.speech.info("Speaking block \(self.currentBlock) from offset \(start) at \(self.rate.label, privacy: .public)")
        // Let engines that need time to produce audio get the blocks after this one ready.
        engine.prepare(upcoming: upcomingTexts())
    }

    /// The texts of the blocks after the current one that are worth preparing: about `lookaheadSeconds` of speech at
    /// the current speed (always at least the next block), at most `maxLookaheadBlocks`.
    private func upcomingTexts() -> [String] {
        var texts: [String] = []
        var seconds = 0.0
        var index = currentBlock + 1
        while index < blocks.count, texts.count < Self.maxLookaheadBlocks, texts.isEmpty || seconds < Self.lookaheadSeconds {
            let text = blocks[index].text
            texts.append(text)
            seconds += Double((text as NSString).length) / (Self.charactersPerSecond * rate.rawValue)
            index += 1
        }
        return texts
    }

    private func discardUtterance() {
        guard hasActiveUtterance else { return }
        engine.stop()
        hasActiveUtterance = false
        isWaitingForAudio = false
        utteranceID += 1  // anything still in flight from the old utterance is now stale
    }

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .started(let id):
            guard id == utteranceID else { return }
            isWaitingForAudio = false
        case .willSpeak(let id, let range):
            guard id == utteranceID else { return }
            isWaitingForAudio = false
            spokenWord = Position(block: currentBlock, range: range)
        case .failed(let id, let failure):
            guard id == utteranceID else { return }
            // Keep the place: play retries from the last word heard.
            Log.speech.error("Speech failed in block \(self.currentBlock): \(failure.message, privacy: .public)")
            record("failed", failure.message)
            resumeOffset = spokenWord?.range.location ?? 0
            hasActiveUtterance = false
            isWaitingForAudio = false
            self.failure = failure
            state = .paused
        case .stalled(let id):
            guard id == utteranceID, state == .playing else { return }
            stallRestarts += 1
            let word = spokenWord?.range.location ?? resumeOffset
            if stallRestarts > Self.maxStallRestarts {
                record("stall", "gave up after \(Self.maxStallRestarts) restarts")
                failure = SpeechFailure(message: "Sound isn't coming out. Check the volume and the output device, then press Play.")
                resumeOffset = word
                discardUtterance()
                state = .paused
            } else {
                record("stall", "restart \(stallRestarts)/\(Self.maxStallRestarts) from word @\(word)")
                speakCurrentBlock(from: word)
            }
        case .finished(let id):
            guard id == utteranceID else { return }
            stallRestarts = 0
            hasActiveUtterance = false
            isWaitingForAudio = false
            spokenWord = nil
            if currentBlock + 1 < blocks.count {
                move(to: currentBlock + 1)
                speakCurrentBlock()
            } else {
                // Finished the article: stop, and start from the top next time.
                Log.speech.info("Finished the article")
                state = .stopped
                engine.stop()
                move(to: 0)
                onFinished()
            }
        }
    }
}

/// Remembers whether reading was going when a lookup paused it, so it can carry on afterwards. A reader who paused
/// by hand before looking something up stays paused.
nonisolated struct LookupResume: Equatable {
    private(set) var pending = false

    /// A lookup starts. A second one while the first is still open (reading is paused by then) keeps the first answer.
    mutating func begin(wasPlaying: Bool) {
        if wasPlaying { pending = true }
    }

    /// The lookup closed. True when reading should start again: it was going before, and is paused now
    /// (if the reader pressed Play meanwhile, or left, there is nothing to do).
    mutating func end(isPaused: Bool) -> Bool {
        defer { pending = false }
        return pending && isPaused
    }
}
