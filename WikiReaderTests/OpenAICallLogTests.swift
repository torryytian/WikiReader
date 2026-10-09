import Foundation
import Testing
@testable import WikiReader

struct CallStatsTests {
    private func record(_ seconds: Double, _ outcome: CallOutcome = .ok, kind: CallKind = .speech) -> CallRecord {
        CallRecord(date: Date(timeIntervalSince1970: 0), kind: kind, size: 100, seconds: seconds, outcome: outcome, detail: nil)
    }

    @Test func successRateAndTimes() {
        let stats = CallStats((1...10).map { record(Double($0)) } + [record(60, .timedOut), record(0.2, .rateLimited)])
        #expect(stats.count == 12)
        #expect(stats.okCount == 10)
        #expect(abs((stats.successRate ?? 0) - 10.0 / 12.0) < 0.0001)
        // Percentiles use only the successful calls.
        #expect(stats.median == 5)
        #expect(stats.p90 == 9)
        #expect(stats.slowest == 10)
    }

    @Test func slowCallsCountEvenWhenTheyFailed() {
        let stats = CallStats([record(2), record(11), record(60, .timedOut)])
        #expect(stats.slowCount == 2)
    }

    @Test func failuresAreGroupedAndSortedByFrequency() {
        let stats = CallStats([record(60, .timedOut), record(1, .rateLimited), record(60, .timedOut), record(1)])
        #expect(stats.failures.map(\.outcome) == [.timedOut, .rateLimited])
        #expect(stats.failures.map(\.count) == [2, 1])
    }

    @Test func noCallsMeansNoNumbers() {
        let stats = CallStats([])
        #expect(stats.successRate == nil && stats.median == nil && stats.p90 == nil && stats.slowest == nil)
    }

    @Test func onlyFailuresMeansNoTimes() {
        let stats = CallStats([record(60, .timedOut)])
        #expect(stats.successRate == 0)
        #expect(stats.median == nil)
    }
}

struct CallLogStorageTests {
    private func makeLog(limit: Int = 500) -> OpenAICallLog {
        OpenAICallLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "calls-\(UUID().uuidString)/log.json"), limit: limit)
    }

    private func entry(_ seconds: Double) -> CallRecord {
        CallRecord(date: .now, kind: .speech, size: 10, seconds: seconds, outcome: .ok, detail: nil)
    }

    @Test func recordsComeBackInOrderAndSurviveReopening() async {
        let log = makeLog()
        await log.record(entry(1))
        await log.record(entry(2))
        #expect(await log.all().map(\.seconds) == [1, 2])

        let reopened = OpenAICallLog(fileURL: await log.fileURLForTesting)
        #expect(await reopened.all().map(\.seconds) == [1, 2])
    }

    @Test func onlyTheNewestRecordsAreKept() async {
        let log = makeLog(limit: 3)
        for seconds in 1...5 { await log.record(entry(Double(seconds))) }
        #expect(await log.all().map(\.seconds) == [3, 4, 5])
    }

    @Test func clearingEmptiesTheLog() async {
        let log = makeLog()
        await log.record(entry(1))
        await log.clear()
        #expect(await log.all().isEmpty)
    }

    @Test func theRealLogIsOffWhileTesting() {
        // Test runs go through the real clients; they must not fill the log kept for the real app.
        #expect(!OpenAICallLog.standard.isEnabled)
    }

    @Test func aDisabledLogRecordsNothing() async {
        let log = OpenAICallLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "off-\(UUID().uuidString).json"), isEnabled: false)
        await log.record(entry(1))
        #expect(await log.all().isEmpty)
    }
}

struct CallReportTests {
    @Test func reportListsCountsFailuresAndLatestCalls() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            CallRecord(date: now, kind: .speech, size: 400, seconds: 3.2, outcome: .ok, detail: nil),
            CallRecord(date: now, kind: .speech, size: 900, seconds: 60.0, outcome: .timedOut, detail: nil),
            CallRecord(date: now, kind: .text, size: 300, seconds: 1.1, outcome: .ok, detail: nil),
        ]
        let text = CallReport.text(records: records, now: now)
        #expect(text.contains("Speech: 2 requests"))
        #expect(text.contains("AI Text: 1 requests"))
        #expect(text.contains("succeeded 1 (50%)"))
        #expect(text.contains("Timed out: 1"))
        #expect(text.contains("60.0 s"))
    }

    @Test func reportNeverContainsRequestText() {
        let record = CallRecord(date: .now, kind: .speech, size: 5, seconds: 1, outcome: .network, detail: "The Internet connection appears to be offline.")
        let text = CallReport.text(records: [record], now: .now)
        #expect(!text.contains("sk-"))
    }
}

struct TTSOutcomeMappingTests {
    @Test func everyTTSErrorMapsToAnOutcome() {
        #expect(OpenAITTSError.timedOut.outcome == .timedOut)
        #expect(OpenAITTSError.rateLimited.outcome == .rateLimited)
        #expect(OpenAITTSError.quotaExceeded.outcome == .outOfCredit)
        #expect(OpenAITTSError.server(status: 503).detail == "HTTP 503")
        #expect(OpenAITTSError.network("offline").outcome == .network)
    }

    @Test func timeoutFromTheSystemBecomesTimedOut() async {
        let client = OpenAITTSClient { _ in throw URLError(.timedOut) }
        let speech = OpenAISpeechRequest(model: "m", voice: "v", input: "Hi.", instructions: nil)
        await #expect(throws: OpenAITTSError.timedOut) { try await client.synthesize(speech, apiKey: "k") }
    }

    @Test func chatErrorsMapToo() {
        #expect(OpenAIChatError.timedOut.outcome == .timedOut)
        #expect(OpenAIChatError.invalidKey.outcome == .invalidKey)
        #expect(OpenAIChatError.server(status: 500).detail == "HTTP 500")
    }
}
