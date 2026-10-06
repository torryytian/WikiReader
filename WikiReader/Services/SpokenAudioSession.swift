import AVFoundation
import OSLog

/// The app's audio session for reading aloud: "spoken audio" playback, audible with the silent
/// switch on, pausing other apps' audio rather than mixing underneath. Shared by all speech engines.
enum SpokenAudioSession {
    static func activate() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            Log.speech.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.speech.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
