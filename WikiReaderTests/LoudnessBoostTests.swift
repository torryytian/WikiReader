import AVFoundation
import Foundation
import Testing
@testable import WikiReader

struct LoudnessBoostTests {
    /// Bursts of a 220 Hz tone with silence between them, a stand-in for speech: `amplitude` is the tone's peak.
    private func speechLike(amplitude: Float, seconds: Double = 2, rate: Int = 24_000) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            let t = Double(index) / Double(rate)
            let inBurst = Int(t * 4) % 2 == 0   // 0.25 s on, 0.25 s off
            return inBurst ? amplitude * Float(sin(2 * .pi * 220 * t)) : 0
        }
    }

    private func rmsDB(_ channel: [Float]) -> Double {
        LoudnessBoost.measure([channel])!.rmsDB
    }

    @Test func measuresOnlyTheParthatIsNotSilence() throws {
        // A sine of peak 0.1 has an RMS of 0.1/√2 = −23 dBFS; the silent half must not pull that down.
        let measured = try #require(LoudnessBoost.measure([speechLike(amplitude: 0.1)]))
        #expect(abs(measured.rmsDB - -23.0) < 0.3)
    }

    @Test func raisesQuietSpeechToTheTarget() throws {
        let original = speechLike(amplitude: 0.1)
        let result = try #require(LoudnessBoost.boosted([original], target: -17, sampleRate: 24_000))
        let boosted = result.channels[0]
        #expect(abs(rmsDB(boosted) - -17) < 0.3)
        #expect(boosted.count == original.count)
        #expect(boosted.allSatisfy { abs($0) <= 1 })
        // The silence stays silence.
        #expect(boosted[Int(0.3 * 24_000)] == 0)
        // Plenty of room: the limiter has nothing to do.
        #expect(result.report.deepestReduction < 0.01)
        #expect(abs(result.report.gain - 6) < 0.4)
        #expect(abs(result.report.originalRMS - -23) < 0.3)
    }

    @Test func neverMakesAnythingQuieter() {
        #expect(LoudnessBoost.boosted([speechLike(amplitude: 0.5)], target: -30, sampleRate: 24_000) == nil)
        #expect(LoudnessBoost.boosted([speechLike(amplitude: 0.1)], target: -23.2, sampleRate: 24_000) == nil)  // within half a dB
    }

    @Test func silenceAndEmptyAudioAreLeftAlone() {
        #expect(LoudnessBoost.boosted([[Float](repeating: 0, count: 1000)], target: -14, sampleRate: 24_000) == nil)
        #expect(LoudnessBoost.boosted([[]], target: -14, sampleRate: 24_000) == nil)
        #expect(LoudnessBoost.boosted([], target: -14, sampleRate: 24_000) == nil)
        // Channels of different lengths are not audio this knows how to handle.
        #expect(LoudnessBoost.boosted([[0.1, 0.1], [0.1]], target: -14, sampleRate: 24_000) == nil)
    }

    @Test func gainStopsWhereTheLoudestMomentWouldNeedTurningDownTooFar() throws {
        // Quiet speech with one loud spike: its average asks for far more gain than the spike allows.
        var samples = speechLike(amplitude: 0.1)
        samples[1000] = 0.9
        let result = try #require(LoudnessBoost.boosted([samples], target: -8, sampleRate: 24_000))
        let allowed = 20 * log10(Double(LoudnessBoost.ceiling) / 0.9) + LoudnessBoost.maxReduction
        #expect(result.report.gain <= allowed + 0.01)
        #expect(result.report.gain > allowed - 0.5)
        #expect(result.report.deepestReduction <= LoudnessBoost.maxReduction + 0.1)
        #expect(result.report.resultRMS < -8)   // the target was out of reach, and that is reported honestly
        // Very quiet audio is raised by at most maxGain.
        let whisper = LoudnessBoost.boosted([speechLike(amplitude: 0.001)], target: -14, sampleRate: 24_000)
        #expect(whisper == nil || whisper!.report.gain <= LoudnessBoost.maxGain + 0.01)
    }

    @Test func nothingIsEverLouderThanTheCeilingAfterTheLimiter() throws {
        // Speech-like bursts with spikes of several sizes, including right at the start and the end.
        var samples = speechLike(amplitude: 0.15, seconds: 3)
        for (index, size) in [(0, Float(0.7)), (500, 0.5), (12_345, 0.8), (40_000, -0.9), (samples.count - 1, 0.6)] { samples[index] = size }
        let result = try #require(LoudnessBoost.boosted([samples, samples.map { $0 * 0.5 }], target: -10, sampleRate: 24_000))
        for channel in result.channels {
            #expect(channel.allSatisfy { abs($0) <= LoudnessBoost.ceiling + 0.0001 })
            #expect(channel.count == samples.count)
        }
        #expect(result.report.deepestReduction > 1)
    }

    @Test func limiterLeavesAudioAloneWhenNothingReachesTheCeiling() {
        let peaks: [Float] = [0, 0.1, 0.3, 0.2, 0.05]
        let gains = LoudnessBoost.limiterGains(peaks: peaks, factor: 2, sampleRate: 24_000)
        #expect(gains == [Float](repeating: 1, count: peaks.count))
        #expect(LoudnessBoost.limiterGains(peaks: [], factor: 2, sampleRate: 24_000).isEmpty)
    }

    @Test func limiterTurnsDownBeforeAPeakAndLetsGoAfterIt() {
        let rate = 24_000
        var peaks = [Float](repeating: 0.2, count: rate)   // one second
        peaks[12_000] = 0.8
        let gains = LoudnessBoost.limiterGains(peaks: peaks, factor: 4, sampleRate: rate)   // the peak would be 3.2
        let needed = LoudnessBoost.ceiling / 3.2
        // Reaches the needed gain no later than the peak, and never goes below the need there.
        #expect(gains[12_000] <= needed + 0.0001)
        // Already coming down a few frames before: look-ahead.
        #expect(gains[12_000 - 20] < 1)
        // Mostly back to full gain at five times the 80 ms release (0.4 s), but not at once: a quarter of a release
        // after the peak the voice is still held down.
        #expect(gains[12_000 + 10_000] > 0.99)
        #expect(gains[12_000 + 500] < 0.7)
        // The base level is 0.2 × 4 = 0.8, under the ceiling, so away from the peak nothing is touched.
        #expect(gains[100] == 1)
        // A smooth ramp, not a step.
        let steps = zip(gains, gains.dropFirst()).map { abs($0 - $1) }
        #expect((steps.max() ?? 0) < 0.1)
        // And the result never passes the ceiling.
        for (peak, gain) in zip(peaks, gains) { #expect(peak * 4 * gain <= LoudnessBoost.ceiling + 0.0001) }
    }

    @Test func slidingMinimumMatchesTheObviousWay() {
        var generator = SystemRandomNumberGenerator()
        let values = (0..<500).map { _ in Float.random(in: 0.1...1, using: &generator) }
        for radius in [1, 3, 10, 499, 1000] {
            let fast = LoudnessBoost.slidingMinimum(values, radius: radius)
            for index in values.indices {
                let window = values[max(0, index - radius)...min(values.count - 1, index + radius)]
                #expect(fast[index] == window.min())
            }
        }
        #expect(LoudnessBoost.slidingMinimum([], radius: 3).isEmpty)
    }

    @Test func wavDataHasAValidHeaderAndSamples() {
        let data = LoudnessBoost.wav(channels: [[0, 0.5, -0.5, 1]], sampleRate: 24_000)
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) } == 24_000)
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 46, as: Int16.self) } == 16384)
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 50, as: Int16.self) } == 32767)
    }

    @Test func aFileRoundTripsLouderAndStillPlaysInAnAudioPlayer() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "quiet-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try LoudnessBoost.wav(channels: [speechLike(amplitude: 0.1, seconds: 1)], sampleRate: 24_000).write(to: url)

        #expect(LoudnessBoost.boostedWAV(from: url, level: .normal) == nil)
        let louder = try #require(LoudnessBoost.boostedWAV(from: url, level: .louder)).data
        let loudest = try #require(LoudnessBoost.boostedWAV(from: url, level: .loudest)).data
        #expect(loudest.count == louder.count)

        func level(_ data: Data) throws -> Double {
            let file = FileManager.default.temporaryDirectory.appending(path: "read-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: file) }
            try data.write(to: file)
            let audio = try AVAudioFile(forReading: file)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let channel = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            return rmsDB(channel)
        }
        #expect(abs(try level(louder) - -16) < 0.5)
        #expect(abs(try level(loudest) - -11) < 0.5)
        // The result is a clip AVAudioPlayer accepts, with the original's length.
        let player = try AVAudioPlayer(data: loudest, fileTypeHint: AVFileType.wav.rawValue)
        #expect(abs(player.duration - 1) < 0.01)
    }

    @Test func unreadableFilesAreLeftAsTheyAre() {
        #expect(LoudnessBoost.boostedWAV(from: URL(filePath: "/nonexistent.mp3"), level: .loudest) == nil)
        let junk = FileManager.default.temporaryDirectory.appending(path: "junk-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: junk) }
        try? Data("not audio".utf8).write(to: junk)
        #expect(LoudnessBoost.boostedWAV(from: junk, level: .loudest) == nil)
    }

    @Test func theSettingDefaultsToLoudestAndReadsWhatIsStored() {
        let key = SettingsKeys.speechLoudness
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.removeObject(forKey: key)
        #expect(SpeechLoudness.current == .loudest)
        defaults.set("normal", forKey: key)
        #expect(SpeechLoudness.current == .normal)
        defaults.set("garbage", forKey: key)
        #expect(SpeechLoudness.current == .loudest)
        #expect(SpeechLoudness.normal.targetRMS == nil)
    }

    @Test func realOpenAIAudioIsBoostedToTheTarget() async throws {
        // A 3.6 s clip generated by gpt-4o-mini-tts (marin): MP3, 24 kHz mono, about −20.6 dBFS RMS as delivered.
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "tts_sample", withExtension: "mp3"))
        let original = try AVAudioPlayer(contentsOf: url)
        let louder = try #require(LoudnessBoost.boostedWAV(from: url, level: .louder))
        let loudest = try #require(LoudnessBoost.boostedWAV(from: url, level: .loudest))

        func level(_ data: Data) throws -> Double {
            let file = FileManager.default.temporaryDirectory.appending(path: "real-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: file) }
            try data.write(to: file)
            let audio = try AVAudioFile(forReading: file)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            return rmsDB(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
        }
        #expect(abs(try level(louder.data) - -16) < 0.6)
        // This clip's loudest moment is high (−3.7 dBFS), so the limiter's 6 dB allowance runs out at about 9 dB of
        // gain: a little short of the −11 target rather than squashed.
        let loudestLevel = try level(loudest.data)
        #expect(loudestLevel > -13.8 && loudestLevel < -12.2)
        #expect(loudest.report.deepestReduction <= LoudnessBoost.maxReduction + 0.1)
        #expect(abs(loudest.report.resultRMS - loudestLevel) < 0.3)
        // Louder and Loudest really are different, by several dB.
        #expect(try level(loudest.data) - level(louder.data) > 2.5)
        // Same length as the original, so the word timing estimate and seeking are unaffected.
        let player = try AVAudioPlayer(data: loudest.data, fileTypeHint: AVFileType.wav.rawValue)
        #expect(abs(player.duration - original.duration) < 0.05)

        // And through the same path the engine uses, off the main actor.
        let clip = try await AVAudioClip.make(contentsOf: url, loudness: .loudest)
        #expect(abs(clip.duration - original.duration) < 0.05)
        #expect(clip.loudnessNote?.hasPrefix("loudness=loudest gain=+") == true)
        let untouched = try await AVAudioClip.make(contentsOf: url, loudness: .normal)
        #expect(abs(untouched.duration - original.duration) < 0.05)
        #expect(untouched.loudnessNote == "loudness=normal as generated")
    }

    private final class BundleToken {}
}
