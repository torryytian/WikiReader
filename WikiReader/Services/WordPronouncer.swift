import AVFoundation
import OSLog

/// Speaks single words for the dictionary screen, in an American English on-device voice.
///
/// Always the system voice, even when the article is read with a cloud voice: one word isn't worth a
/// network request. It has its own synthesizer, so it never touches the one that reads the article.
final class WordPronouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    /// - Parameter voiceIdentifier: The voice chosen in Settings; used if it is an American voice,
    ///   otherwise the best installed American voice.
    init(voiceIdentifier: String?) {
        let chosen = VoiceSelection.americanVoice(preferring: voiceIdentifier, from: VoiceSelection.installedVoices())
        voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
        Log.lookup.info("Word voice: \(self.voice?.name ?? "system default", privacy: .public) (\(self.voice?.language ?? "-", privacy: .public))")
    }

    func speak(_ word: String) {
        // Only activated, never deactivated: deactivating the session could break an article reading
        // that is merely paused behind the dictionary and must be able to continue.
        SpokenAudioSession.activate()
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = voice
        // A little slower than the default, so single words are easier to catch.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
        Log.lookup.info("Pronouncing \(word, privacy: .public)")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
