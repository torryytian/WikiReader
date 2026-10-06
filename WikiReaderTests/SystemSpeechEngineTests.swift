import Foundation
import Testing
@testable import WikiReader

/// Smoke tests against the real AVSpeechSynthesizer: they check that events actually arrive
/// and are tagged correctly. They take a few seconds and produce sound in the simulator.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SystemSpeechEngineTests {
    let engine = SystemSpeechEngine()
    let recorder = EventRecorder()

    init() {
        engine.onEvent = { [recorder] in recorder.events.append($0) }
    }

    final class EventRecorder {
        var events: [SpeechEvent] = []
    }

    /// Waits until `condition` holds, polling the main actor (where events are delivered).
    private func wait(seconds: Double = 15, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func speaksAndReportsWordsThenFinishes() async throws {
        let text = "Hello world."
        engine.speak(SpeechUtterance(id: 1, text: text, rate: .faster))
        try await wait { recorder.events.contains(.finished(id: 1)) }

        #expect(recorder.events.last == .finished(id: 1))
        let words = recorder.events.compactMap { event -> NSRange? in
            if case .willSpeak(1, let range) = event { range } else { nil }
        }
        #expect(!words.isEmpty)
        for range in words {
            #expect(NSMaxRange(range) <= (text as NSString).length)
        }
        engine.stop()
    }

    @Test func interruptedUtteranceDoesNotFinish() async throws {
        engine.speak(SpeechUtterance(
            id: 1,
            text: "This is a long sentence that will be interrupted before it can be read to the end.",
            rate: .normal
        ))
        try await wait { recorder.events.contains { if case .willSpeak(1, _) = $0 { true } else { false } } }

        engine.speak(SpeechUtterance(id: 2, text: "Short.", rate: .faster))
        try await wait { recorder.events.contains(.finished(id: 2)) }

        #expect(recorder.events.contains(.finished(id: 2)))
        #expect(!recorder.events.contains(.finished(id: 1)))
        engine.stop()
    }
}
