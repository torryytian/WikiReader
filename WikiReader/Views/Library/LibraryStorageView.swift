import OSLog
import SwiftData
import SwiftUI

/// The whole library at a glance, from the library's + menu: its size, downloading all its audio, and clearing out
/// audio nothing needs any more.
struct LibraryStorageView: View {
    @Query(sort: \Article.addedAt, order: .reverse) private var articles: [Article]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice = OpenAISpeechEngine.defaultVoice
    @State private var downloader = AudioDownloader.shared

    @State private var usage: LibraryAudioUsage?
    @State private var totals: Totals?
    @State private var downloadPrompt: AudioDownloadPrompt?
    @State private var cleanup: Cleanup?
    /// Bumped to measure again after deleting files.
    @State private var version = 0

    nonisolated private struct Totals: Sendable {
        var words = 0
        var characters = 0
        var savedWords = 0
    }

    private enum Cleanup: Identifiable {
        case unused
        case otherVoices
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                if downloader.phase != .idle {
                    Section { AudioDownloadStatusRow() }
                }
                librarySection
                audioSection
                storageSection
                Section {
                    NavigationLink {
                        LibraryBackupView()
                    } label: {
                        Label("Backup & Transfer", systemImage: "arrow.up.arrow.down.circle")
                    }
                } footer: {
                    Text("Export the library with its audio to a file, to keep or to move to another iPhone.")
                }
            }
            .navigationTitle("Library & Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: articles.count) {
                totals = await Self.totals(of: articles.map(\.blocksData), savedWords: articles.reduce(0) { $0 + $1.savedWords.count })
            }
            .task(id: MeasureInput(count: articles.count, voice: openAIVoice, done: downloader.donePieces, version: version)) {
                usage = await ArticleAudio.usage(ofBlocksData: articles.map(\.blocksData), voice: openAIVoice)
            }
            .audioDownloadPrompt($downloadPrompt)
            .confirmationDialog(cleanupTitle, isPresented: Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } }), titleVisibility: .visible, presenting: cleanup) { kind in
                Button("Delete", role: .destructive) { clean(kind) }
            } message: { kind in
                Text(kind == .unused
                     ? "Audio of articles that were deleted, or whose text changed. Adding such an article again generates it again."
                     : "Your articles' audio in voices other than \(openAIVoice.capitalized). Choosing one of them again generates it again.")
            }
        }
    }

    private struct MeasureInput: Equatable {
        var count: Int
        var voice: String
        var done: Int
        var version: Int
    }

    @concurrent
    private static func totals(of library: [Data], savedWords: Int) async -> Totals {
        var totals = Totals(savedWords: savedWords)
        for block in library.flatMap(Article.decodeBlocks) {
            totals.words += block.text.split(whereSeparator: \.isWhitespace).count
            totals.characters += block.text.count
        }
        return totals
    }

    // MARK: - Sections

    private var librarySection: some View {
        Section("Library") {
            LabeledContent("Articles", value: "\(articles.count)")
            LabeledContent("Words", value: totals.map { $0.words.formatted() } ?? "…")
            LabeledContent("Listening Time", value: totals.map { AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: $0.characters)) + " at 1×" } ?? "…")
            LabeledContent("Saved Words", value: totals.map { "\($0.savedWords)" } ?? "…")
        }
    }

    private var audioSection: some View {
        Section {
            if let usage {
                let downloaded = usage.totalCharacters - usage.missingCharacters
                let fraction = usage.totalCharacters > 0 ? Double(downloaded) / Double(usage.totalCharacters) : 0
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(usage.missingPieces == 0 ? "All downloaded" : "\(Int((fraction * 100).rounded(.down)))% downloaded")
                        Spacer()
                        Text(AudioFormat.bytes(usage.voiceBytes))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: fraction)
                        .tint(usage.missingPieces == 0 ? .green : nil)
                    Text("\(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: downloaded))) of \(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: usage.totalCharacters)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if usage.missingPieces > 0 && !downloader.isRunning {
                    Button {
                        Task { downloadPrompt = await LibraryActions.downloadPrompt(for: articles) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download All Remaining Audio")
                                Text("About \(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: usage.missingCharacters))), roughly \(AudioFormat.cost(ArticleAudio.dollars(forCharacters: usage.missingCharacters)))")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("Audio · \(openAIVoice.capitalized)")
        } footer: {
            Text("Each paragraph is generated once and kept for offline listening. To download only some articles, choose Select Articles in the + menu.")
        }
    }

    private var storageSection: some View {
        Section {
            if let usage {
                LabeledContent("\(openAIVoice.capitalized) Voice", value: AudioFormat.bytes(usage.voiceBytes))
                cleanupRow("Other Voices", bytes: usage.otherVoiceBytes, kind: .otherVoices)
                cleanupRow("Not Used by Any Article", bytes: usage.unusedBytes, kind: .unused)
                LabeledContent("Total", value: AudioFormat.bytes(usage.totalBytes))
                    .fontWeight(.medium)
            }
        } header: {
            Text("Audio Storage")
        } footer: {
            Text("Audio not used by any article is left behind by deleted articles. Deleting it can't be undone: it would be generated and paid for again.")
        }
    }

    private func cleanupRow(_ title: String, bytes: Int64, kind: Cleanup) -> some View {
        HStack {
            LabeledContent(title, value: AudioFormat.bytes(bytes))
            if bytes > 0 {
                Button("Delete", role: .destructive) { cleanup = kind }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
            }
        }
    }

    private var cleanupTitle: String {
        switch cleanup {
        case .unused: "Delete audio no article uses?"
        case .otherVoices: "Delete audio in other voices?"
        case nil: ""
        }
    }

    private func clean(_ kind: Cleanup) {
        guard let usage else { return }
        let files = kind == .unused ? usage.unusedFiles : usage.otherVoiceFiles
        Task {
            let freed = await ArticleAudio.removeFiles(files)
            Log.app.info("Storage cleanup (\(kind == .unused ? "unused" : "other voices", privacy: .public)) freed \(freed) bytes")
            version += 1
        }
    }
}
