import AVFoundation
import Foundation

/// How loud the cloud voice is made. OpenAI's audio is quiet next to most apps (its speech sits around
/// −21 dBFS RMS with peaks near −5 dBFS), so switching to music or a video is a jolt. `AVAudioPlayer.volume`
/// can't go above 1, so the audio itself is amplified when a clip is opened; the cached files are left
/// as they were generated (backups and the cache keys don't change).
nonisolated enum SpeechLoudness: String, CaseIterable, Sendable {
    case normal
    case louder
    case loudest

    static let `default` = SpeechLoudness.loudest

    var label: String {
        switch self {
        case .normal: "Normal"
        case .louder: "Louder"
        case .loudest: "Loudest"
        }
    }

    /// The level the voice ends up at: RMS of the parts that aren't silence, in dBFS. Nil leaves it as generated.
    /// Speech from OpenAI starts around −21, so Louder is about 5 dB above Normal and Loudest about 10 dB
    /// (three times the amplitude): each step is easy to hear.
    var targetRMS: Double? {
        switch self {
        case .normal: nil
        case .louder: -16
        case .loudest: -11
        }
    }

    /// The setting, read when a clip is opened.
    static var current: SpeechLoudness {
        UserDefaults.standard.string(forKey: SettingsKeys.speechLoudness).flatMap(SpeechLoudness.init(rawValue:)) ?? .default
    }
}

/// Raises the level of speech audio: measures it, applies a gain, and runs a look-ahead limiter that
/// pulls down only the moments that would pass the ceiling. Never makes anything quieter.
///
/// Speech is peaky (the loud syllables sit 10 dB or more above the average), so with the peaks left alone the
/// gain is capped by them and the voice barely gets louder. The limiter lets the average rise well past that:
/// each peak is turned down smoothly, starting a moment before it arrives and letting go over about 80 ms.
nonisolated enum LoudnessBoost {
    /// The most gain ever applied before limiting, in dB.
    static let maxGain = 18.0
    /// The most the limiter may turn the loudest moment of a clip down, in dB. Past that the gain stops rising:
    /// the voice would get louder on paper but start to sound squashed.
    static let maxReduction = 6.0
    /// Below this the audio counts as silence when measuring (−50 dBFS).
    static let silenceGate: Float = 0.003_162
    /// Below this much gain nothing is changed (not worth re-encoding).
    static let minGain = 0.5
    /// Nothing leaves the limiter above this (about −0.45 dBFS).
    static let ceiling: Float = 0.95
    /// How far ahead of a peak the limiter starts turning down, in seconds.
    static let lookahead = 0.0015
    /// How long the limiter takes to let go after a peak, in seconds.
    static let release = 0.08

    /// What was done to a clip, for the playback log.
    struct Report: Equatable, Sendable {
        /// Level as generated and as played, in dBFS.
        var originalRMS: Double
        var resultRMS: Double
        /// The gain applied before limiting, in dB.
        var gain: Double
        /// How far the limiter turned the voice down, in dB: on average over the speech, and at the loudest moment.
        var meanReduction: Double
        var deepestReduction: Double

        var summary: String {
            String(format: "gain=+%.1fdB rms %.1f→%.1f limiter avg %.1f max %.1fdB", gain, originalRMS, resultRMS, meanReduction, deepestReduction)
        }
    }

    /// Amplified audio ready for `AVAudioPlayer(data:)`.
    struct Boosted: Sendable {
        var data: Data
        var report: Report
    }

    /// Opens an audio file and returns the amplified version as 16-bit WAV data, or nil if the file
    /// should be played as it is (loudness "normal", already loud enough, silent, or unreadable).
    static func boostedWAV(from url: URL, level: SpeechLoudness) -> Boosted? {
        guard let target = level.targetRMS,
              let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData
        else { return nil }
        let channels = (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
        }
        let sampleRate = Int(buffer.format.sampleRate)
        guard let (boosted, report) = boosted(channels, target: target, sampleRate: sampleRate) else { return nil }
        return Boosted(data: wav(channels: boosted, sampleRate: sampleRate), report: report)
    }

    /// `boostedWAV` off the main actor: decoding and scanning a minute of audio is quick in a release build, but
    /// noticeable in a debug one, and a chunk is opened while the UI is live.
    @concurrent
    static func boostedWAVInBackground(from url: URL, level: SpeechLoudness) async -> Boosted? {
        boostedWAV(from: url, level: level)
    }

    /// The channels raised to `target` (RMS of the non-silent parts, dBFS), or nil if no change is called for.
    ///
    /// The limiter takes some of the level back, so the gain is searched for: start from the plain difference
    /// and correct by what the limiter took, a few times, until the result is within a quarter of a dB.
    static func boosted(_ channels: [[Float]], target: Double, sampleRate: Int) -> (channels: [[Float]], report: Report)? {
        guard let original = measure(channels), let frames = channels.first?.count, frames > 0,
              channels.allSatisfy({ $0.count == frames })
        else { return nil }

        // The loudest sample of each frame across channels: one limiter keeps the stereo image steady.
        var peaks = [Float](repeating: 0, count: frames)
        for channel in channels {
            for index in 0..<frames { peaks[index] = max(peaks[index], abs(channel[index])) }
        }
        // The gain at which the loudest moment would be turned down by `maxReduction`.
        let loudestPeak = Double(peaks.max() ?? 0)
        let cap = min(maxGain, 20 * log10(Double(ceiling) / max(loudestPeak, 1e-6)) + maxReduction)
        var gain = min(target - original.rmsDB, cap)
        guard gain >= minGain else { return nil }

        var attempt = (gain: gain, gains: limiterGains(peaks: peaks, factor: factor(for: gain), sampleRate: sampleRate))
        var level = rmsDB(channels, factor: factor(for: attempt.gain), gains: attempt.gains)
        var previous: (gain: Double, level: Double)?
        for _ in 0..<4 {
            let miss = target - level
            if abs(miss) < 0.25 { break }
            // How much of a dB of extra gain survives the limiter; the first correction assumes all of it.
            var slope = 1.0
            if let previous, abs(attempt.gain - previous.gain) > 0.01 {
                slope = min(max((level - previous.level) / (attempt.gain - previous.gain), 0.2), 1)
            }
            let next = min(max(attempt.gain + miss / slope, minGain), cap)
            if abs(next - attempt.gain) < 0.05 { break }
            previous = (attempt.gain, level)
            attempt = (next, limiterGains(peaks: peaks, factor: factor(for: next), sampleRate: sampleRate))
            level = rmsDB(channels, factor: factor(for: next), gains: attempt.gains)
        }
        gain = attempt.gain

        let multiplier = factor(for: gain)
        let output = channels.map { channel in
            (0..<frames).map { index in max(-1, min(1, channel[index] * multiplier * attempt.gains[index])) }
        }
        let deepest = -20 * log10(Double(attempt.gains.min() ?? 1))
        // Averaged over the frames that carry speech, not the pauses between them.
        var reduction = 0.0
        var speech = 0
        for index in 0..<frames where peaks[index] > silenceGate {
            reduction -= 20 * log10(Double(attempt.gains[index]))
            speech += 1
        }
        return (output, Report(
            originalRMS: original.rmsDB, resultRMS: level, gain: gain,
            meanReduction: speech > 0 ? reduction / Double(speech) : 0, deepestReduction: deepest
        ))
    }

    private static func factor(for gainDB: Double) -> Float { Float(pow(10, gainDB / 20)) }

    struct Measurement: Equatable {
        /// RMS of the samples above the silence gate, in dBFS.
        var rmsDB: Double
    }

    static func measure(_ channels: [[Float]]) -> Measurement? {
        var sumSquares = 0.0
        var count = 0
        for channel in channels {
            for sample in channel where abs(sample) > silenceGate {
                sumSquares += Double(sample) * Double(sample)
                count += 1
            }
        }
        guard count > 0, sumSquares > 0 else { return nil }
        return Measurement(rmsDB: 10 * log10(sumSquares / Double(count)))
    }

    /// `measure` of the channels after `factor` and the limiter gains, without building the output.
    private static func rmsDB(_ channels: [[Float]], factor: Float, gains: [Float]) -> Double {
        var sumSquares = 0.0
        var count = 0
        for channel in channels {
            for index in 0..<channel.count {
                let sample = channel[index] * factor * gains[index]
                if abs(sample) > silenceGate {
                    sumSquares += Double(sample) * Double(sample)
                    count += 1
                }
            }
        }
        return count > 0 && sumSquares > 0 ? 10 * log10(sumSquares / Double(count)) : -120
    }

    // MARK: - Limiter

    /// A gain for every frame (1 = untouched, below 1 = turned down) that keeps `peaks × factor × gain` under the
    /// ceiling. The gain starts falling a moment before a peak and reaches its lowest at the peak, then climbs back.
    ///
    /// How it keeps the promise: each frame needs at most `ceiling / peak`; the lowest need within a window on either
    /// side is taken, so the gain is already down by the time any peak in the window arrives; letting it recover
    /// slowly afterwards never lifts it above that; and the final moving average over the same window can't either,
    /// because every value it averages near a peak is at or below that peak's need.
    static func limiterGains(peaks: [Float], factor: Float, sampleRate: Int) -> [Float] {
        let frames = peaks.count
        guard frames > 0 else { return [] }
        let radius = max(1, Int(lookahead * Double(sampleRate)))

        let needed = peaks.map { peak -> Float in
            let boosted = peak * factor
            return boosted > ceiling ? ceiling / boosted : 1
        }
        guard needed.contains(where: { $0 < 1 }) else { return needed }

        // Lowest need within `radius` frames either side.
        let lowest = slidingMinimum(needed, radius: radius)

        // Fall at once, recover over the release time.
        let letGo = Float(exp(-1 / (release * Double(sampleRate))))
        var held = [Float](repeating: 1, count: frames)
        var last: Float = 1
        for index in 0..<frames {
            last = min(lowest[index], 1 - (1 - last) * letGo)
            held[index] = last
        }

        // Moving average over the window, repeating the edge frames, so the fall and the rise are ramps.
        let window = 2 * radius + 1
        var gains = [Float](repeating: 1, count: frames)
        var sum = 0.0
        for offset in -radius...radius { sum += Double(held[min(max(offset, 0), frames - 1)]) }
        for index in 0..<frames {
            gains[index] = Float(sum / Double(window))
            sum += Double(held[min(index + radius + 1, frames - 1)]) - Double(held[max(index - radius, 0)])
        }
        return gains
    }

    /// For each index, the smallest value within `radius` indices either side (a monotonic queue, linear time).
    static func slidingMinimum(_ values: [Float], radius: Int) -> [Float] {
        let count = values.count
        var result = [Float](repeating: 1, count: count)
        var queue = [Int](repeating: 0, count: count)   // indices with rising values
        var head = 0
        var tail = 0
        var next = 0   // next index to add to the queue
        for index in 0..<count {
            let upper = min(index + radius, count - 1)
            while next <= upper {
                while tail > head && values[queue[tail - 1]] >= values[next] { tail -= 1 }
                queue[tail] = next
                tail += 1
                next += 1
            }
            while queue[head] < index - radius { head += 1 }
            result[index] = values[queue[head]]
        }
        return result
    }

    // MARK: - WAV

    /// 16-bit PCM WAV, channels interleaved.
    static func wav(channels: [[Float]], sampleRate: Int) -> Data {
        let channelCount = channels.count
        let frames = channels.first?.count ?? 0
        let dataSize = frames * channelCount * 2
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(channelCount)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * channelCount * 2)); append(UInt16(channelCount * 2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        for frame in 0..<frames {
            for channel in channels {
                append(Int16((max(-1, min(1, channel[frame])) * 32767).rounded()))
            }
        }
        return data
    }
}
