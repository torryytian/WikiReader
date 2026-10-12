import SwiftUI

/// The playback log: every pause, play and skip with the state of the player and the audio session, and the
/// system's audio events. For when Play after a Pause makes no sound: copy the report and send it.
/// Everything stays on this device unless you copy the report.
struct PlaybackDiagnosticsView: View {
    private let log = PlaybackLog.standard
    @State private var copied = false
    @State private var isConfirmingClear = false

    private static let shown = 200

    var body: some View {
        Form {
            summarySection
            if log.events.isEmpty {
                Section {
                    Text("Nothing recorded yet. Events appear here after you read something aloud.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Latest first") {
                    ForEach(log.events.suffix(Self.shown).reversed()) { event in
                        row(event)
                    }
                }
            }
            Section {
                Button(copied ? "Copied" : "Copy Report", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = log.report()
                    copied = true
                }
                .disabled(log.events.isEmpty)
                Button("Clear Log", systemImage: "trash", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(log.events.isEmpty)
            } footer: {
                Text("The report holds the last \(log.events.count) events as plain text. It has no article text, only positions and audio states.")
            }
        }
        .navigationTitle("Playback Log")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear the log?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                log.clear()
                copied = false
            }
        }
    }

    private var summarySection: some View {
        let stalls = log.events.filter { $0.kind == "stall" }.count
        let pauses = log.events.filter { $0.kind == "pause" }.count
        return Section("Summary") {
            LabeledContent("Events", value: "\(log.events.count)")
            LabeledContent("Pauses", value: "\(pauses)")
            LabeledContent("Silence detected", value: "\(stalls)")
        }
    }

    private func row(_ event: PlaybackEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.date, format: .dateTime.hour().minute().second())
                    .font(.footnote.monospacedDigit())
                Text(event.kind)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Self.color(for: event.kind))
            }
            Text(event.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private static func color(for kind: String) -> Color {
        switch kind {
        case "stall", "failed": .red
        case "session", "route": .orange
        case "app": .purple
        default: .blue
        }
    }
}
