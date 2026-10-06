import Foundation
@testable import WikiReader

/// A silent SpeechEngine: records what it was asked to do, and lets tests emit progress events.
final class FakeSpeechEngine: SpeechEngine {
    enum Call: Equatable {
        case speak(SpeechUtterance)
        case pause
        case resume
        case stop
    }

    var onEvent: ((SpeechEvent) -> Void)?
    private(set) var calls: [Call] = []

    var spoken: [SpeechUtterance] {
        calls.compactMap { if case .speak(let utterance) = $0 { utterance } else { nil } }
    }

    var lastSpoken: SpeechUtterance? { spoken.last }

    func speak(_ utterance: SpeechUtterance) { calls.append(.speak(utterance)) }
    func pause() { calls.append(.pause) }
    func resume() { calls.append(.resume) }
    func stop() { calls.append(.stop) }

    /// Pretends the last utterance reached the word at `range` (relative to its text).
    func emitWord(_ range: NSRange, id: Int? = nil) {
        onEvent?(.willSpeak(id: id ?? lastSpoken!.id, range: range))
    }

    /// Pretends the given (default: last) utterance finished.
    func emitFinished(id: Int? = nil) {
        onEvent?(.finished(id: id ?? lastSpoken!.id))
    }
}
