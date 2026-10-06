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
    var text: String
    var rate: SpeechRate
    /// Silence after the text, e.g. a short pause after a heading.
    var pauseAfter: TimeInterval = 0
}

nonisolated enum SpeechEvent: Equatable, Sendable {
    /// About to speak `range` (UTF-16, relative to the utterance text).
    case willSpeak(id: Int, range: NSRange)
    /// The utterance was spoken to the end (not emitted when it is stopped or replaced).
    case finished(id: Int)
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
