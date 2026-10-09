import Foundation
import OSLog

/// Which kind of OpenAI request a record is about.
nonisolated enum CallKind: String, Codable, CaseIterable, Sendable {
    /// Text to speech: the audio for a paragraph.
    case speech
    /// The AI word explanation and the translation.
    case text

    var label: String {
        switch self {
        case .speech: "Speech"
        case .text: "AI Text"
        }
    }
}

/// How a request ended.
nonisolated enum CallOutcome: String, Codable, Sendable {
    case ok
    case timedOut
    case network
    case rateLimited
    case outOfCredit
    case invalidKey
    case missingKey
    case rejected
    case serverError
    case badResponse
    case audioError

    var label: String {
        switch self {
        case .ok: "OK"
        case .timedOut: "Timed out"
        case .network: "Network error"
        case .rateLimited: "Rate limited"
        case .outOfCredit: "Out of credit"
        case .invalidKey: "Key rejected"
        case .missingKey: "No key"
        case .rejected: "Request rejected"
        case .serverError: "Server error"
        case .badResponse: "Bad response"
        case .audioError: "Audio error"
        }
    }
}

/// One OpenAI request: when, how big, how long it took, how it ended. Never the text itself.
nonisolated struct CallRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var kind: CallKind
    /// Characters sent for speech; the size of the request body in bytes for AI text.
    var size: Int
    /// From sending the request to getting the whole answer (or the failure).
    var seconds: Double
    var outcome: CallOutcome
    /// For failures, what the system or OpenAI said (e.g. "HTTP 503").
    var detail: String?
}

/// Numbers worked out from records, for the diagnostics page and the copied report.
nonisolated struct CallStats: Equatable, Sendable {
    var count: Int
    var okCount: Int
    /// Seconds for the calls that succeeded, sorted.
    var okSeconds: [Double]
    /// Failures by outcome, most frequent first.
    var failures: [(outcome: CallOutcome, count: Int)]
    /// Calls that took longer than `slowThreshold` seconds, successful or not.
    var slowCount: Int

    static let slowThreshold = 10.0

    init(_ records: [CallRecord]) {
        count = records.count
        okCount = records.filter { $0.outcome == .ok }.count
        okSeconds = records.filter { $0.outcome == .ok }.map(\.seconds).sorted()
        let failed = Dictionary(grouping: records.filter { $0.outcome != .ok }, by: \.outcome)
        failures = failed.map { ($0.key, $0.value.count) }.sorted { $0.count > $1.count }
        slowCount = records.filter { $0.seconds > Self.slowThreshold }.count
    }

    static func == (lhs: CallStats, rhs: CallStats) -> Bool {
        lhs.count == rhs.count && lhs.okCount == rhs.okCount && lhs.okSeconds == rhs.okSeconds
            && lhs.slowCount == rhs.slowCount
            && lhs.failures.map(\.outcome) == rhs.failures.map(\.outcome) && lhs.failures.map(\.count) == rhs.failures.map(\.count)
    }

    var successRate: Double? {
        count > 0 ? Double(okCount) / Double(count) : nil
    }

    var median: Double? { percentile(0.5) }
    var slowest: Double? { okSeconds.last }
    /// The time 9 in 10 successful calls came in under.
    var p90: Double? { percentile(0.9) }

    /// Nearest-rank percentile of the successful calls' times.
    private func percentile(_ fraction: Double) -> Double? {
        guard !okSeconds.isEmpty else { return nil }
        let rank = Int((fraction * Double(okSeconds.count)).rounded(.up))
        return okSeconds[min(max(rank, 1), okSeconds.count) - 1]
    }
}

/// A record of every OpenAI request, kept on this device so a slow or failing stretch can be looked at afterwards.
/// The newest `limit` records are kept. Under tests it records nothing, so test runs don't fill the real log.
actor OpenAICallLog {
    static let standard = OpenAICallLog(
        fileURL: URL.applicationSupportDirectory.appending(path: "Diagnostics/openai-calls.json"),
        isEnabled: !isRunningTests
    )

    nonisolated let isEnabled: Bool
    private let fileURL: URL
    /// For tests that reopen the same file.
    var fileURLForTesting: URL { fileURL }
    private let limit: Int
    private var loaded: [CallRecord]?

    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    init(fileURL: URL, isEnabled: Bool = true, limit: Int = 500) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
        self.limit = limit
    }

    func record(_ record: CallRecord) {
        guard isEnabled else { return }
        var records = all()
        records.append(record)
        if records.count > limit { records.removeFirst(records.count - limit) }
        loaded = records
        save(records)
    }

    /// Oldest first.
    func all() -> [CallRecord] {
        if let loaded { return loaded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([CallRecord].self, from: $0) } ?? []
        loaded = records
        return records
    }

    func clear() {
        loaded = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save(_ records: [CallRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Log.speech.error("Saving the OpenAI call log failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the record without making the caller wait for the disk.
    nonisolated func note(
        _ kind: CallKind, size: Int, since start: ContinuousClock.Instant, outcome: CallOutcome, detail: String? = nil
    ) {
        let seconds = start.duration(to: .now).seconds
        let entry = CallRecord(date: .now, kind: kind, size: size, seconds: seconds, outcome: outcome, detail: detail)
        Task { await record(entry) }
    }
}

extension Duration {
    nonisolated var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
