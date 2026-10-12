import Foundation
import Testing
@testable import WikiReader

@MainActor
struct PlaybackLogTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "playback-\(UUID().uuidString)/events.json")
    }

    @Test func keepsOnlyTheNewestEvents() {
        let log = PlaybackLog(fileURL: tempFile(), limit: 3)
        for index in 1...5 { log.record("play", "event \(index)") }
        #expect(log.events.map(\.detail) == ["event 3", "event 4", "event 5"])
    }

    @Test func savedEventsComeBackAfterARestart() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = PlaybackLog(fileURL: file)
        log.record("pause", "in block 3")
        log.record("stall", "no progress")
        log.save()
        let reopened = PlaybackLog(fileURL: file)
        #expect(reopened.events.map(\.kind) == ["pause", "stall"])
        #expect(reopened.events.last?.detail == "no progress")
    }

    @Test func aDisabledLogRecordsAndWritesNothing() {
        let file = tempFile()
        let log = PlaybackLog(fileURL: file, isEnabled: false)
        log.record("play", "ignored")
        log.save()
        #expect(log.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func clearEmptiesTheLogAndTheFile() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = PlaybackLog(fileURL: file)
        log.record("play")
        log.save()
        log.clear()
        #expect(log.events.isEmpty)
        #expect(PlaybackLog(fileURL: file).events.isEmpty)
    }

    @Test func aCorruptFileStartsAnEmptyLog() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("not json".utf8).write(to: file)
        #expect(PlaybackLog(fileURL: file).events.isEmpty)
    }

    @Test func reportListsEventsOldestFirstWithMilliseconds() {
        let base = Date(timeIntervalSince1970: 1_800_000_000.123)
        let events = [
            PlaybackEvent(date: base, kind: "pause", detail: "first"),
            PlaybackEvent(date: base.addingTimeInterval(2.5), kind: "stall", detail: "second"),
        ]
        let report = PlaybackLog.report(events: events, now: base)
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "WikiReader playback log")
        #expect(lines[1].contains("2 events"))
        #expect(lines[3].hasSuffix("pause     first") && lines[3].contains(".123"))
        #expect(lines[4].hasSuffix("stall     second") && lines[4].contains(".623"))
    }

    @Test func sessionSummaryNamesTheCategoryAndRoute() {
        let summary = AudioDiagnostics.sessionSummary()
        #expect(summary.hasPrefix("session["))
        #expect(summary.contains("out="))
        #expect(AudioDiagnostics.clipSummary(nil) == "clip[none]")
    }
}
