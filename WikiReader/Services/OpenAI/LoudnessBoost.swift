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

    /// The level the voice is raised to: RMS of the parts that aren't silence, in dBFS. Nil leaves it as generated.
    var targetRMS: Double? {
        switch self {
        case .normal: nil
        case .louder: -17
        case .loudest: -14
        }
    }

    /// The setting, read when a clip is opened.
    static var current: SpeechLoudness {
        UserDefaults.standard.string(forKey: SettingsKeys.speechLoudness).flatMap(SpeechLoudness.init(rawValue:)) ?? .default
    }
}

/// Raises the level of speech audio: measures it, applies a fixed gain, and rounds off the few peaks that
/// would pass full scale. Never makes anything quieter.
nonisolated enum LoudnessBoost {
    /// The most gain ever applied, in dB.
    static let maxGain = 10.0
    /// Below this the audio counts as silence when measuring (−50 dBFS).
    static let silenceGate: Float = 0.003_162
    /// Below this much gain nothing is changed (not worth re-encoding).
    static let minGain = 0.5
    /// The 99.9th-percentile sample may reach this after the gain (about −0.9 dBFS); only rarer peaks are limited.
    static let peakCeiling = 0.9
    /// Samples below this pass the limiter untouched; above it they bend smoothly toward 1.
    static let limiterKnee: Float = 0.8

    struct Measurement: Equatable {
        /// RMS of the samples above the silence gate, in dBFS.
        var rmsDB: Double
        /// The 99.9th percentile of absolute sample values (0…1).
        var p999: Double
    }

    /// Opens an audio file and returns the amplified version as 16-bit WAV data, or nil if the file
    /// should be played as it is (loudness "normal", already loud enough, silent, or unreadable).
    static func boostedWAV(from url: URL, level: SpeechLoudness) -> Data? {
        guard let target = level.targetRMS,
              let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData
        else { return nil }
        let channels = (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
        }
        guard let boosted = boosted(channels, target: target) else { return nil }
        return wav(channels: boosted, sampleRate: Int(buffer.format.sampleRate))
    }

    /// `boostedWAV` off the main actor: decoding and scanning a minute of audio is quick in a release build, but
    /// noticeable in a debug one, and a chunk is opened while the UI is live.
    @concurrent
    static func boostedWAVInBackground(from url: URL, level: SpeechLoudness) async -> Data? {
        boostedWAV(from: url, level: level)
    }

    /// The channels with the gain and limiter applied, or nil if no change is called for.
    static func boosted(_ channels: [[Float]], target: Double) -> [[Float]]? {
        guard let measurement = measure(channels),
              let gain = gainDB(for: measurement, target: target)
        else { return nil }
        let factor = Float(pow(10, gain / 20))
        return channels.map { channel in channel.map { limit($0 * factor) } }
    }

    static func measure(_ channels: [[Float]]) -> Measurement? {
        var sumSquares = 0.0
        var count = 0
        // 1/2048 resolution is plenty for finding the 99.9th percentile.
        var histogram = [Int](repeating: 0, count: 2048)
        var total = 0
        for channel in channels {
            for sample in channel {
                let magnitude = abs(sample)
                histogram[min(Int(magnitude * 2047), 2047)] += 1
                total += 1
                if magnitude > silenceGate {
                    sumSquares += Double(magnitude) * Double(magnitude)
                    count += 1
                }
            }
        }
        guard count > 0, total > 0, sumSquares > 0 else { return nil }
        var seen = 0
        var p999 = 1.0
        for (bin, hits) in histogram.enumerated() {
            seen += hits
            if Double(seen) >= 0.999 * Double(total) {
                p999 = Double(bin + 1) / 2048
                break
            }
        }
        return Measurement(rmsDB: 10 * log10(sumSquares / Double(count)), p999: p999)
    }

    /// The gain in dB to reach `target`, held back so the 99.9th-percentile peak stays under the ceiling,
    /// or nil if the result would be a change too small to bother with.
    static func gainDB(for measurement: Measurement, target: Double) -> Double? {
        var gain = target - measurement.rmsDB
        gain = min(gain, maxGain, 20 * log10(peakCeiling / max(measurement.p999, 1e-6)))
        return gain >= minGain ? gain : nil
    }

    /// Passes quiet samples unchanged and bends the loud ones smoothly toward 1, so a peak the gain
    /// pushed past full scale is rounded off rather than clipped flat.
    static func limit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }
        let room = 1 - limiterKnee
        let limited = limiterKnee + room * tanhf((magnitude - limiterKnee) / room)
        return sample < 0 ? -limited : limited
    }

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
