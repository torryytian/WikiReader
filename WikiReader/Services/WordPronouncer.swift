import AVFoundation
import Observation
import OSLog

/// Speaks single words for the word card, with the on-device voice chosen in Settings.
///
/// Always the system voice, even when the article is read with a cloud voice: one word isn't worth a
/// network request. It has its own synthesizer, so it never touches the one that reads the article.
@Observable
final class WordPronouncer: NSObject {
    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let voice: AVSpeechSynthesisVoice?
    /// The utterance being spoken; callbacks for any other utterance are stale and dropped.
    @ObservationIgnored private var current: ObjectIdentifier?

    /// - Parameter voiceIdentifier: The voice to use; if nil or no longer installed, the best installed English voice.
    init(voiceIdentifier: String?) {
        let chosen = VoiceSelection.voice(preferring: voiceIdentifier, from: VoiceSelection.installedVoices())
        voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ word: String) {
        // Only activated, never deactivated: deactivating the session could break an article reading
        // that is merely paused behind the card and must be able to continue.
        SpokenAudioSession.activate()
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = voice
        // A little slower than the default, so single words are easier to catch.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        current = ObjectIdentifier(utterance)
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = true
        synthesizer.speak(utterance)
        Log.lookup.info("Pronouncing \(word, privacy: .public)")
    }

    func stop() {
        current = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finished(_ utterance: ObjectIdentifier) {
        guard current == utterance else { return }
        current = nil
        isSpeaking = false
    }
}

// The synthesizer doesn't promise which thread it calls its delegate on, so these methods are
// `nonisolated` and hop to the main actor with only an object identifier (see SystemSpeechEngine).
extension WordPronouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(key) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(key) }
    }
}
