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
    private(set) var errorMessage: String?

    /// Called whenever reading moves to another block, so the position can be saved.
    @ObservationIgnored var onBlockChange: (Int) -> Void = { _ in }

    @ObservationIgnored private let blocks: [ContentBlock]
    @ObservationIgnored private let engine: SpeechEngine
    /// Id of the utterance we're waiting on; events with other ids are stale.
    @ObservationIgnored private var utteranceID = 0
    /// Whether the engine holds a (possibly paused) utterance for `currentBlock` that `resume` can continue.
    @ObservationIgnored private var hasActiveUtterance = false
    /// UTF-16 offset in the block to start from on the next `speakCurrentBlock`.
    @ObservationIgnored private var resumeOffset = 0

    init(blocks: [ContentBlock], startBlock: Int = 0, rate: SpeechRate = .normal, engine: SpeechEngine) {
        self.blocks = blocks
        self.currentBlock = blocks.indices.contains(startBlock) ? startBlock : 0
        self.rate = rate
        self.engine = engine
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    var isPlaying: Bool { state == .playing }

    // MARK: - Controls

    /// Continues where speech left off: the paused word, else the start of `currentBlock`.
    func play() {
        guard !blocks.isEmpty, state != .playing else { return }
        errorMessage = nil
        if state == .paused && hasActiveUtterance {
            engine.resume()
            state = .playing
            Log.speech.info("Resumed block \(self.currentBlock)")
        } else {
            speakCurrentBlock()
        }
    }

    func pause() {
        guard state == .playing else { return }
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
        move(to: block)
        speakCurrentBlock()
    }

    func next() {
        guard currentBlock + 1 < blocks.count else { return }
        jump(to: currentBlock + 1)
    }

    /// Goes to the previous block; at the first block, back to its start.
    func previous() {
        jump(to: max(currentBlock - 1, 0))
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

    /// Sets where reading will start, e.g. the paragraph the user scrolled to.
    /// Ignored while playing or paused: the spoken position wins then.
    func moveWhileStopped(to block: Int) {
        guard state == .stopped, blocks.indices.contains(block) else { return }
        move(to: block)
    }

    func stop() {
        guard state != .stopped || hasActiveUtterance else { return }
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
        // Let engines that need time to produce audio get the next block ready (only one ahead).
        if currentBlock + 1 < blocks.count {
            engine.prepare(blocks[currentBlock + 1].text)
        }
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
        case .failed(let id, let message):
            guard id == utteranceID else { return }
            // Keep the place: play retries from the last word heard.
            Log.speech.error("Speech failed in block \(self.currentBlock): \(message, privacy: .public)")
            resumeOffset = spokenWord?.range.location ?? 0
            hasActiveUtterance = false
            isWaitingForAudio = false
            errorMessage = message
            state = .paused
        case .finished(let id):
            guard id == utteranceID else { return }
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
            }
        }
    }
}
