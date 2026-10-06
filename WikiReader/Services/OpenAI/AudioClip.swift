import AVFoundation

/// Plays one audio file. A protocol so tests can drive playback without sound.
protocol AudioClip: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    /// Playback speed multiplier (1 = normal), applied without changing pitch.
    var rate: Float { get set }
    /// Called when playback reaches the end (not when stopped).
    var onFinish: (() -> Void)? { get set }
    func play()
    func pause()
    func stop()
}

/// `AudioClip` backed by `AVAudioPlayer`.
final class AVAudioClip: NSObject, AudioClip {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?

    init(contentsOf url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.enableRate = true  // must be set before prepareToPlay
        player.delegate = self
        player.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
}

// As with the speech synthesizer, the delegate thread isn't guaranteed: hop to the main actor.
extension AVAudioClip: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.onFinish?()
        }
    }
}
