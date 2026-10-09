import SwiftUI

/// How the OpenAI requests have been going: how many worked, how long they took, why the others failed.
/// Everything here comes from the log on this device; nothing is sent anywhere unless you copy the report.
struct OpenAIDiagnosticsView: View {
    @State private var records: [CallRecord] = []
    @State private var kind = CallKind.speech
    @State private var copied = false
    @State private var isConfirmingClear = false

    private var shown: [CallRecord] { records.filter { $0.kind == kind } }

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(CallKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Speech is the audio for each paragraph; AI Text is word explanations and translations. Only times and results are kept, never the text.")
            }

            let stats = CallStats(shown)
            if stats.count == 0 {
                Section {
                    Text("No requests recorded yet. They appear here after OpenAI has been used.")
                        .foregroundStyle(.secondary)
                }
            } else {
                summarySection(stats)
                if !stats.failures.isEmpty { failuresSection(stats) }
                recentSection
            }

            Section {
                Button(copied ? "Copied" : "Copy Report", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = CallReport.text(records: records, now: .now)
                    copied = true
                }
                .disabled(records.isEmpty)
                Button("Clear Log", systemImage: "trash", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(records.isEmpty)
            } footer: {
                Text("The report is plain text you can paste into a message.")
            }
        }
        .navigationTitle("OpenAI Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { records = await OpenAICallLog.standard.all() }
        .confirmationDialog("Clear the log?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task {
                    await OpenAICallLog.standard.clear()
                    records = []
                    copied = false
                }
            }
        }
    }

    private func summarySection(_ stats: CallStats) -> some View {
        Section("Summary") {
            LabeledContent("Requests", value: "\(stats.count)")
            if let rate = stats.successRate {
                LabeledContent("Succeeded", value: "\(stats.okCount) (\(Int((rate * 100).rounded()))%)")
            }
            if let median = stats.median { LabeledContent("Typical time", value: Self.time(median)) }
            if let p90 = stats.p90 { LabeledContent("9 in 10 within", value: Self.time(p90)) }
            if let slowest = stats.slowest { LabeledContent("Slowest success", value: Self.time(slowest)) }
            LabeledContent("Over \(Int(CallStats.slowThreshold)) s", value: "\(stats.slowCount)")
        }
    }

    private func failuresSection(_ stats: CallStats) -> some View {
        Section("Why requests failed") {
            ForEach(stats.failures, id: \.outcome) { failure in
                LabeledContent(failure.outcome.label, value: "\(failure.count)")
            }
        }
    }

    private var recentSection: some View {
        Section("Latest") {
            ForEach(shown.suffix(30).reversed()) { record in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.date, format: .dateTime.month().day().hour().minute().second())
                            .font(.footnote.monospacedDigit())
                        if let detail = record.detail, record.outcome != .ok {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(record.outcome.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(record.outcome == .ok ? Color.green : Color.red)
                        Text(Self.describe(record))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }

    static func describe(_ record: CallRecord) -> String {
        record.kind == .speech ? "\(time(record.seconds)) · \(record.size) chars" : time(record.seconds)
    }
}

/// The plain-text version of the diagnostics, for pasting into a message.
nonisolated enum CallReport {
    static func text(records: [CallRecord], now: Date) -> String {
        var lines = ["WikiReader OpenAI request report", "Created \(now.formatted(.iso8601))", ""]
        for kind in CallKind.allCases {
            let items = records.filter { $0.kind == kind }
            let stats = CallStats(items)
            lines.append("\(kind.label): \(stats.count) requests")
            guard stats.count > 0 else { lines.append(""); continue }
            if let rate = stats.successRate {
                lines.append("  succeeded \(stats.okCount) (\(Int((rate * 100).rounded()))%)")
            }
            if let median = stats.median, let p90 = stats.p90, let slowest = stats.slowest {
                lines.append("  time of successes: typical \(fixed(median)) s, 9 in 10 within \(fixed(p90)) s, slowest \(fixed(slowest)) s")
            }
            lines.append("  over \(Int(CallStats.slowThreshold)) s: \(stats.slowCount)")
            for failure in stats.failures {
                lines.append("  \(failure.outcome.label): \(failure.count)")
            }
            lines.append("  latest:")
            for record in items.suffix(15) {
                let when = record.date.formatted(.iso8601)
                let detail = record.detail.map { " (\($0))" } ?? ""
                lines.append("    \(when)  \(record.outcome.label)\(detail)  \(fixed(record.seconds)) s  size \(record.size)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func fixed(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
