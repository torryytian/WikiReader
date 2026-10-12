import AVFoundation
import OSLog

/// Speaks single words for the dictionary screen: a human recording from Wikimedia Commons when there is
/// one, else an American English on-device voice.
///
/// The fallback is always the system voice, even when the article is read with a cloud voice: one word isn't
/// worth a paid request. It has its own synthesizer, so it never touches the one that reads the article.
final class WordPronouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let recordings: WordAudioClient
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    /// - Parameter voiceIdentifier: The voice chosen in Settings; used if it is an American voice,
    ///   otherwise the best installed American voice.
    init(voiceIdentifier: String?, recordings: WordAudioClient = .standard) {
        self.recordings = recordings
        let chosen = VoiceSelection.americanVoice(preferring: voiceIdentifier, from: VoiceSelection.installedVoices())
        voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
        Log.lookup.info("Word voice: \(self.voice?.name ?? "system default", privacy: .public) (\(self.voice?.language ?? "-", privacy: .public))")
    }

    /// Plays the recording of the word if Commons has one, else speaks it. Fetching a recording is a request
    /// to upload.wikimedia.org carrying only the word, made when the speaker button is pressed.
    func pronounce(_ word: String) {
        stop()
        task = Task {
            if let data = await recordings.recording(for: word), !Task.isCancelled,
               let player = try? AVAudioPlayer(data: data) {
                SpokenAudioSession.activate()
                self.player = player
                player.play()
                Log.lookup.info("Playing recording of \(word, privacy: .public)")
            } else if !Task.isCancelled {
                speak(word)
            }
        }
    }

    /// Speaks the word with the on-device voice.
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
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}
