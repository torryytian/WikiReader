import AVFoundation
import OSLog

/// `SpeechEngine` backed by the on-device `AVSpeechSynthesizer`.
final class SystemSpeechEngine: NSObject, SpeechEngine {
    var onEvent: ((SpeechEvent) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    /// The utterance being spoken, the caller's id for it, and where in the caller's text it starts.
    /// Delegate callbacks identify utterances by object, so this maps them back; callbacks for any
    /// other utterance are stale and dropped.
    private var current: (utterance: ObjectIdentifier, id: Int, startOffset: Int)?

    /// - Parameter voiceIdentifier: The voice to use; if nil or no longer installed, the best
    ///   installed English voice. Voices are always chosen explicitly: `AVSpeechSynthesisVoice(language:)`
    ///   has been seen to ignore the user's chosen voice on iOS 26.
    init(voiceIdentifier: String? = nil) {
        let chosen = VoiceSelection.voice(preferring: voiceIdentifier, from: VoiceSelection.installedVoices())
        voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
        super.init()
        synthesizer.delegate = self
        Log.speech.info("Using voice \(self.voice?.name ?? "system default", privacy: .public) (\(self.voice?.identifier ?? "-", privacy: .public))")
    }

    func speak(_ utterance: SpeechUtterance) {
        SpokenAudioSession.activate()
        let text = utterance.text as NSString
        let start = min(max(utterance.startOffset, 0), text.length)
        let spoken = AVSpeechUtterance(string: text.substring(from: start))
        spoken.voice = voice
        spoken.rate = utterance.rate.systemRate
        spoken.postUtteranceDelay = utterance.pauseAfter
        current = (ObjectIdentifier(spoken), utterance.id, start)

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(spoken)
    }

    func pause() {
        // Immediate, not at the next word boundary: by the time a pause request arrives the synthesizer
        // has often started the following word, which it then repeats after continueSpeaking.
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        SpokenAudioSession.deactivate()
    }

    // MARK: - Events

    /// Passes on an event for the current utterance; `makeEvent` gets its id and start offset.
    private func deliver(_ utterance: ObjectIdentifier, _ makeEvent: (_ id: Int, _ startOffset: Int) -> SpeechEvent) {
        guard let current, current.utterance == utterance else { return }
        onEvent?(makeEvent(current.id, current.startOffset))
    }
}

// The synthesizer doesn't promise which thread it calls its delegate on, so these methods are
// `nonisolated`: they take only Sendable values out of the callback (an object identifier and a
// range) and hop to the main actor, where all of this class's state lives.
extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.deliver(key) { id, _ in .started(id: id) }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            // The synthesizer only saw the text from startOffset on; report ranges in the whole text.
            self.deliver(key) { id, startOffset in
                .willSpeak(id: id, range: NSRange(location: startOffset + characterRange.location, length: characterRange.length))
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.deliver(key) { id, _ in .finished(id: id) }
        }
    }
}
