import AVFoundation
import OSLog

/// `SpeechEngine` backed by the on-device `AVSpeechSynthesizer`.
final class SystemSpeechEngine: NSObject, SpeechEngine {
    var onEvent: ((SpeechEvent) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    /// The utterance being spoken and the caller's id for it. Delegate callbacks identify utterances
    /// by object, so this maps them back; callbacks for any other utterance are stale and dropped.
    private var current: (utterance: ObjectIdentifier, id: Int)?

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
        activateAudioSession()
        let spoken = AVSpeechUtterance(string: utterance.text)
        spoken.voice = voice
        spoken.rate = utterance.rate.systemRate
        spoken.postUtteranceDelay = utterance.pauseAfter
        current = (ObjectIdentifier(spoken), utterance.id)

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
        deactivateAudioSession()
    }

    // MARK: - Audio session

    /// "Spoken audio" playback: audible with the silent switch on, and other apps' audio
    /// is paused rather than mixed underneath.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            Log.speech.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.speech.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Events

    private func deliver(_ utterance: ObjectIdentifier, _ makeEvent: (Int) -> SpeechEvent) {
        guard let current, current.utterance == utterance else { return }
        onEvent?(makeEvent(current.id))
    }
}

// The synthesizer doesn't promise which thread it calls its delegate on, so these methods are
// `nonisolated`: they take only Sendable values out of the callback (an object identifier and a
// range) and hop to the main actor, where all of this class's state lives.
extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.deliver(key) { .willSpeak(id: $0, range: characterRange) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.deliver(key) { .finished(id: $0) }
        }
    }
}
