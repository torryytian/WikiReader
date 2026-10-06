import Foundation

/// Speaks one piece of text at a time and reports progress.
/// The reading flow (which block next, pause for lookups, ...) lives in `ReadingSession`;
/// an engine only knows how to turn text into sound, so a cloud TTS can replace the system one.
protocol SpeechEngine: AnyObject {
    /// Progress of the utterance most recently passed to `speak`. Events for earlier,
    /// interrupted utterances may still arrive; callers match them by `SpeechUtterance.id`.
    var onEvent: ((SpeechEvent) -> Void)? { get set }

    /// Starts speaking, interrupting anything currently being spoken.
    func speak(_ utterance: SpeechUtterance)
    func pause()
    func resume()
    func stop()
}

nonisolated struct SpeechUtterance: Equatable, Sendable {
    /// Chosen by the caller to recognize this utterance's events.
    var id: Int
    /// The whole block, even when starting part-way: engines that generate audio per text (cloud TTS)
    /// can then reuse what they already have for this block instead of generating new audio.
    var text: String
    /// UTF-16 offset in `text` to start speaking from (e.g. resuming at a word after a speed change).
    var startOffset = 0
    var rate: SpeechRate
    /// Silence after the text, e.g. a short pause after a heading.
    var pauseAfter: TimeInterval = 0
}

nonisolated enum SpeechEvent: Equatable, Sendable {
    /// Sound has started. Can come noticeably after `speak` when audio has to be generated first.
    case started(id: Int)
    /// About to speak `range` (UTF-16, relative to the whole utterance text, not to `startOffset`).
    case willSpeak(id: Int, range: NSRange)
    /// The utterance was spoken to the end (not emitted when it is stopped or replaced).
    case finished(id: Int)
    /// The utterance can't be spoken, e.g. a cloud voice without network. `message` is shown to the user.
    case failed(id: Int, message: String)
}

/// Playback speed choices shown in the player bar.
nonisolated enum SpeechRate: Double, CaseIterable, Sendable {
    case slow = 0.75
    case normal = 1
    case fast = 1.25
    case faster = 1.5

    var label: String {
        switch self {
        case .slow: "0.75×"
        case .normal: "1×"
        case .fast: "1.25×"
        case .faster: "1.5×"
        }
    }

    /// `AVSpeechUtterance.rate` value. The system scale isn't linear (0.5 is normal speed and
    /// speech gets fast quickly above it), so these are tuned by ear rather than multiplied.
    var systemRate: Float {
        switch self {
        case .slow: 0.42
        case .normal: 0.50
        case .fast: 0.55
        case .faster: 0.60
        }
    }
}
