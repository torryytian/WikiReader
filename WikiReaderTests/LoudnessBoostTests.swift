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
        #expect(measured.p999 > 0.09 && measured.p999 < 0.11)
    }

    @Test func raisesQuietSpeechToTheTarget() throws {
        let original = speechLike(amplitude: 0.1)
        let boosted = try #require(LoudnessBoost.boosted([original], target: -17))
        #expect(abs(rmsDB(boosted[0]) - -17) < 0.3)
        #expect(boosted[0].count == original.count)
        #expect(boosted[0].allSatisfy { abs($0) <= 1 })
        // The silence stays silence.
        #expect(boosted[0][Int(0.3 * 24_000)] == 0)
    }

    @Test func neverMakesAnythingQuieter() {
        #expect(LoudnessBoost.boosted([speechLike(amplitude: 0.5)], target: -30) == nil)
        #expect(LoudnessBoost.boosted([speechLike(amplitude: 0.1)], target: -23.2) == nil)  // within half a dB
    }

    @Test func silenceAndEmptyAudioAreLeftAlone() {
        #expect(LoudnessBoost.boosted([[Float](repeating: 0, count: 1000)], target: -14) == nil)
        #expect(LoudnessBoost.boosted([[]], target: -14) == nil)
        #expect(LoudnessBoost.boosted([], target: -14) == nil)
    }

    @Test func gainIsCappedAndHeldBackByThePeaks() {
        // Very quiet: capped at maxGain.
        #expect(LoudnessBoost.gainDB(for: .init(rmsDB: -40, p999: 0.01), target: -14) == LoudnessBoost.maxGain)
        // Peaks already high: the gain stops where the 99.9th percentile would reach the ceiling.
        let held = LoudnessBoost.gainDB(for: .init(rmsDB: -30, p999: 0.5), target: -14)
        #expect(abs(held! - 20 * log10(LoudnessBoost.peakCeiling / 0.5)) < 0.001)
        // Nothing to gain.
        #expect(LoudnessBoost.gainDB(for: .init(rmsDB: -14, p999: 0.5), target: -14) == nil)
    }

    @Test func limiterIsTransparentBelowTheKneeAndNeverReachesOne() {
        for x: Float in [0, 0.1, -0.5, 0.79, -0.8] { #expect(LoudnessBoost.limit(x) == x) }
        for x: Float in [0.81, 1, 1.5, 4, 100] {
            let y = LoudnessBoost.limit(x)
            #expect(y > LoudnessBoost.limiterKnee && y <= 1)
            #expect(LoudnessBoost.limit(-x) == -y)
        }
        // Monotonic: louder in never means quieter out.
        var last: Float = 0
        for step in 0...400 {
            let y = LoudnessBoost.limit(Float(step) / 100)
            #expect(y >= last)
            last = y
        }
    }

    @Test func peaksPushedPastFullScaleAreRoundedNotClipped() throws {
        // Loud tone with a rare spike: after the boost the spike must stay under 1 without flattening the rest.
        var samples = speechLike(amplitude: 0.2)
        samples[1000] = 0.9
        let boosted = try #require(LoudnessBoost.boosted([samples], target: -10))
        #expect(boosted[0].allSatisfy { abs($0) <= 1 })
        #expect(boosted[0][1000] > 0.9)
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
        let louder = try #require(LoudnessBoost.boostedWAV(from: url, level: .louder))
        let loudest = try #require(LoudnessBoost.boostedWAV(from: url, level: .loudest))
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
        #expect(abs(try level(louder) - -17) < 0.5)
        #expect(abs(try level(loudest) - -14) < 0.5)
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
        #expect(abs(try level(louder) - -17) < 0.6)
        // This clip's peaks are high (99.9th percentile near −7 dBFS), so the gain is held back to about 6 dB:
        // a little under the −14 target rather than clipping.
        let loudestLevel = try level(loudest)
        #expect(loudestLevel > -15.2 && loudestLevel < -13.8)
        // Same length as the original, so the word timing estimate and seeking are unaffected.
        let player = try AVAudioPlayer(data: loudest, fileTypeHint: AVFileType.wav.rawValue)
        #expect(abs(player.duration - original.duration) < 0.05)

        // And through the same path the engine uses, off the main actor.
        let clip = try await AVAudioClip.make(contentsOf: url, loudness: .loudest)
        #expect(abs(clip.duration - original.duration) < 0.05)
        let untouched = try await AVAudioClip.make(contentsOf: url, loudness: .normal)
        #expect(abs(untouched.duration - original.duration) < 0.05)
    }

    private final class BundleToken {}
}
