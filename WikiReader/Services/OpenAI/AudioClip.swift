import AVFoundation

/// Plays one audio file. A protocol so tests can drive playback without sound.
protocol AudioClip: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    /// Whether the player reports that it is playing.
    var isPlaying: Bool { get }
    /// Playback speed multiplier (1 = normal), applied without changing pitch.
    var rate: Float { get set }
    /// Called when playback reaches the end (not when stopped).
    var onFinish: (() -> Void)? { get set }
    /// Starts or continues playback. False means the system refused (for example the audio session is inactive).
    @discardableResult func play() -> Bool
    func pause()
    func stop()
    /// How the clip was amplified, for the playback log.
    var loudnessNote: String? { get }
}

extension AudioClip {
    var loudnessNote: String? { nil }
}

/// `AudioClip` backed by `AVAudioPlayer`.
final class AVAudioClip: NSObject, AudioClip {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?
    let loudnessNote: String?

    /// - Parameters:
    ///   - boosted: The same audio, amplified (see `LoudnessBoost`); played instead of the file when given.
    ///   - loudnessNote: What was done to it, for the log.
    init(contentsOf url: URL, boosted: Data? = nil, loudnessNote: String? = nil) throws {
        if let boosted {
            player = try AVAudioPlayer(data: boosted, fileTypeHint: AVFileType.wav.rawValue)
        } else {
            player = try AVAudioPlayer(contentsOf: url)
        }
        self.loudnessNote = loudnessNote
        super.init()
        player.enableRate = true  // must be set before prepareToPlay
        player.delegate = self
        player.prepareToPlay()
    }

    /// Opens a clip at the loudness the user chose, doing the amplifying off the main actor.
    static func make(contentsOf url: URL, loudness: SpeechLoudness = .current) async throws -> AVAudioClip {
        let boosted = await LoudnessBoost.boostedWAVInBackground(from: url, level: loudness)
        let note: String
        if loudness == .normal {
            note = "loudness=normal as generated"
        } else if let boosted {
            note = "loudness=\(loudness.rawValue) \(boosted.report.summary)"
        } else {
            note = "loudness=\(loudness.rawValue) left as generated (already loud enough or unreadable)"
        }
        return try AVAudioClip(contentsOf: url, boosted: boosted?.data, loudnessNote: note)
    }

    var duration: TimeInterval { player.duration }
    var isPlaying: Bool { player.isPlaying }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    func play() -> Bool { player.play() }
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
