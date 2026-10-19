import OSLog
import SwiftData
import SwiftUI

/// What the library, the article info page and the storage page share: deleting articles and their audio, and
/// asking before a download.
enum LibraryActions {
    /// The OpenAI voice downloads are made with: the one chosen in Settings, even while an iPhone voice reads.
    static var openAIVoice: String {
        UserDefaults.standard.string(forKey: SettingsKeys.openAIVoice) ?? OpenAISpeechEngine.defaultVoice
    }

    static var hasOpenAIKey: Bool {
        KeychainStore.openAIKey.read() != nil
    }

    /// Works out what downloading `articles` would take, for the confirmation.
    static func downloadPrompt(for articles: [Article]) async -> AudioDownloadPrompt {
        guard hasOpenAIKey else { return .noKey }
        let sources = articles.map { AudioDownloader.Source(id: $0.persistentModelID, blocksData: $0.blocksData) }
        let plan = await AudioDownloader.plan(for: sources, voice: openAIVoice)
        return plan.isEmpty ? .nothingToDo : .confirm(plan)
    }

    /// Deletes articles, and with `withAudio` also the audio only they used. Anything still queued for them in a
    /// download is dropped.
    static func delete(_ articles: [Article], withAudio: Bool, library: [Article], context: ModelContext) {
        let ids = Set(articles.map(\.persistentModelID))
        let removed = articles.map(\.blocksData)
        let keeping = library.filter { !ids.contains($0.persistentModelID) }.map(\.blocksData)
        for article in articles {
            Log.app.info("Deleting \(article.title, privacy: .public)\(withAudio ? " and its audio" : "", privacy: .public)")
            AudioDownloader.shared.cancel(article: article.persistentModelID)
            context.delete(article)
        }
        do {
            try context.save()
        } catch {
            Log.app.error("Saving after delete failed: \(error.localizedDescription, privacy: .public)")
        }
        guard withAudio else { return }
        Task {
            let freed = await ArticleAudio.removeAudio(of: removed, keeping: keeping)
            Log.app.info("Deleted \(freed) bytes of audio with the articles")
        }
    }

    /// Deletes the audio of `articles`, except what other articles share. Returns the bytes freed.
    @discardableResult
    static func removeAudio(of articles: [Article], library: [Article]) async -> Int64 {
        let ids = Set(articles.map(\.persistentModelID))
        for id in ids { AudioDownloader.shared.cancel(article: id) }
        let keeping = library.filter { !ids.contains($0.persistentModelID) }.map(\.blocksData)
        let freed = await ArticleAudio.removeAudio(of: articles.map(\.blocksData), keeping: keeping)
        Log.app.info("Deleted \(freed) bytes of audio of \(articles.count) articles")
        return freed
    }
}

// MARK: - Formatting

enum AudioFormat {
    /// "under a minute", "25 min", "1 h 5 min".
    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 1 { return "under a minute" }
        if total < 60 { return "\(total) min" }
        return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
    }

    static func cost(_ dollars: Double) -> String {
        dollars < 0.01 ? "less than a cent" : String(format: "$%.2f", dollars)
    }

    static func bytes(_ bytes: Int64) -> String {
        bytes == 0 ? "None" : bytes.formatted(.byteCount(style: .file))
    }
}

// MARK: - Download confirmation

/// The question asked before a download starts.
enum AudioDownloadPrompt: Identifiable {
    case confirm(AudioDownloader.Plan)
    case nothingToDo
    case noKey

    var id: String {
        switch self {
        case .confirm(let plan): "confirm-\(plan.items.count)"
        case .nothingToDo: "nothing"
        case .noKey: "noKey"
        }
    }

    var title: String {
        switch self {
        case .confirm: "Download Audio?"
        case .nothingToDo: "Already Downloaded"
        case .noKey: "OpenAI Key Needed"
        }
    }

    var message: String {
        switch self {
        case .confirm(let plan):
            let articles = plan.articleCount == 1 ? "1 article" : "\(plan.articleCount) articles"
            return "About \(AudioFormat.duration(minutes: plan.minutes)) of audio for \(articles) with the \(plan.voice.capitalized) voice, "
                + "roughly \(AudioFormat.cost(plan.dollars)) on your OpenAI account. Keep WikiReader open until it finishes; "
                + "the screen stays on meanwhile."
        case .nothingToDo:
            return "All the audio for the \(LibraryActions.openAIVoice.capitalized) voice is already on this iPhone."
        case .noKey:
            return "Audio is generated with an OpenAI voice. Save an API key in Settings → Voice first."
        }
    }
}

extension View {
    /// Shows `prompt` as an alert; confirming starts the download.
    func audioDownloadPrompt(_ prompt: Binding<AudioDownloadPrompt?>) -> some View {
        alert(
            prompt.wrappedValue?.title ?? "",
            isPresented: Binding(get: { prompt.wrappedValue != nil }, set: { if !$0 { prompt.wrappedValue = nil } }),
            presenting: prompt.wrappedValue
        ) { shown in
            if case .confirm(let plan) = shown {
                Button("Download") { AudioDownloader.shared.start(plan) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { shown in
            Text(shown.message)
        }
    }
}

// MARK: - Progress views

/// The running download (or how the last one ended), with Stop or OK.
struct AudioDownloadStatusRow: View {
    @State private var downloader = AudioDownloader.shared

    var body: some View {
        switch downloader.phase {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Downloading audio", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Stop") { downloader.cancel() }
                        .buttonStyle(.borderless)
                }
                ProgressView(value: downloader.fraction)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .finished:
            summary(
                downloader.failedPieces == 0 ? "Audio downloaded" : "Audio downloaded, \(downloader.failedPieces) parts failed",
                detail: downloader.failedPieces == 0
                    ? "\(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: downloader.doneCharacters))) of audio is on this iPhone."
                    : "Download again to retry the parts that failed.",
                symbol: downloader.failedPieces == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                tint: downloader.failedPieces == 0 ? .green : .orange
            )
        case .stopped(let reason):
            summary("Download stopped", detail: reason, symbol: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    private var progressText: String {
        let done = AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: downloader.doneCharacters))
        let total = AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: downloader.totalCharacters))
        var text = "\(done) of \(total) · \(downloader.voice.capitalized) · screen stays on"
        if downloader.failedPieces > 0 { text += " · \(downloader.failedPieces) failed" }
        return text
    }

    private func summary(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("OK") { downloader.dismiss() }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// A small ring that fills as audio is downloaded; a check mark when it is all there.
struct AudioProgressRing: View {
    var fraction: Double
    var size: CGFloat = 14

    var body: some View {
        Group {
            if fraction >= 1 {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .foregroundStyle(.green)
            } else {
                ZStack {
                    Circle().stroke(.tertiary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(fraction >= 1 ? "Audio downloaded" : "\(Int(fraction * 100))% of audio downloaded")
    }
}
