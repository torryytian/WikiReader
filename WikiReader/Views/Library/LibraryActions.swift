import OSLog
import SwiftData
import SwiftUI

/// What the library, the article info page, the storage page and the Google Drive page share: deleting articles and
/// their audio, asking before a download, and taking audio from or backing it up to Google Drive.
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
        var plan = await AudioDownloader.plan(for: sources, voice: openAIVoice)
        let drive = DriveAudioStore.shared
        if drive.looksUpBeforeGenerating, !plan.isEmpty {
            // What another device already made is free: only the rest is priced.
            await drive.prepareIndex(keys: plan.items.map { SpeechAudioCache.key(for: $0.piece.request) })
            plan.markOnDrive { drive.isOnDrive($0) == true }
            for article in articles {
                Task {
                    await drive.noteArticle(title: article.title, url: article.sourceURL.absoluteString, blocks: article.blocks, voice: openAIVoice)
                }
            }
        }
        return plan.isEmpty ? .nothingToDo : .confirm(plan)
    }

    // MARK: Google Drive

    /// Works out what taking `articles`' audio (in the chosen voice) from Google Drive would bring, for the
    /// confirmation. Only what Drive has is downloaded; nothing is generated, so it is free.
    static func drivePullPrompt(for articles: [Article]) async -> AudioDownloadPrompt {
        let drive = DriveAudioStore.shared
        guard drive.isEnabled else { return .driveNotConnected }
        let sources = articles.map { AudioDownloader.Source(id: $0.persistentModelID, blocksData: $0.blocksData) }
        var plan = await AudioDownloader.plan(for: sources, voice: openAIVoice)
        guard !plan.isEmpty else { return .nothingToDo }
        // Another device may have uploaded some a moment ago.
        await drive.syncIndex(force: true)
        plan.markOnDrive { drive.isOnDrive($0) == true }
        let fromDrive = plan.onlyFromDrive()
        guard fromDrive.isEmpty else { return .confirm(fromDrive) }
        if let error = drive.lastError { return .notice(title: "Google Drive Unavailable", message: error) }
        let these = articles.count == 1 ? "this article" : "these articles"
        return .notice(
            title: "Not in Google Drive",
            message: "None of the \(openAIVoice.capitalized) audio \(these) still lack is in your Google Drive. Download Audio generates it with OpenAI."
        )
    }

    /// Backs up `articles`' audio on this iPhone (any voice) that Drive lacks, and lists them in Drive. Returns what
    /// to tell, or nil when uploads started: the backup's progress row shows them.
    static func backUpToDrive(_ articles: [Article]) async -> AudioDownloadPrompt? {
        let drive = DriveAudioStore.shared
        guard drive.isEnabled else { return .driveNotConnected }
        let library = articles.map { (title: $0.title, url: $0.sourceURL.absoluteString, blocksData: $0.blocksData) }
        guard let result = await drive.backUp(library, voice: openAIVoice, showsProgress: true) else {
            return .notice(title: "Google Drive Unavailable", message: drive.lastError ?? "Google Drive couldn't be reached.")
        }
        guard result.missing == 0 else { return nil }
        let these = articles.count == 1 ? "this article" : "these articles"
        if result.onThisIPhone == 0 {
            return .notice(title: "No Audio to Back Up", message: "There is no audio for \(these) on this iPhone yet.")
        }
        return .notice(title: "Already Backed Up", message: "All the audio for \(these) on this iPhone is already in your Google Drive.")
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

/// The question asked before a download starts, or what a Google Drive action has to say.
enum AudioDownloadPrompt: Identifiable {
    case confirm(AudioDownloader.Plan)
    case nothingToDo
    case noKey
    /// Just something to tell, with OK.
    case notice(title: String, message: String)

    static let driveNotConnected = AudioDownloadPrompt.notice(
        title: "Google Drive Not Connected", message: "Sign in under Settings → Google Drive first."
    )

    var id: String {
        switch self {
        case .confirm(let plan): "confirm-\(plan.isDriveOnly)-\(plan.items.count)"
        case .nothingToDo: "nothing"
        case .noKey: "noKey"
        case .notice(let title, _): "notice-\(title)"
        }
    }

    var title: String {
        switch self {
        case .confirm(let plan): plan.isDriveOnly ? "Download from Google Drive?" : "Download Audio?"
        case .nothingToDo: "Already Downloaded"
        case .noKey: "OpenAI Key Needed"
        case .notice(let title, _): title
        }
    }

    var message: String {
        switch self {
        case .confirm(let plan) where plan.isDriveOnly:
            let articles = plan.articleCount == 1 ? "1 article" : "\(plan.articleCount) articles"
            var text = "About \(AudioFormat.duration(minutes: plan.minutes)) of \(plan.voice.capitalized) audio for \(articles) is in your Google Drive. "
                + "Downloading it is free; nothing is generated."
            if plan.leftOutCharacters > 0 {
                text += " Another \(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: plan.leftOutCharacters))) isn't in Drive: Download Audio generates it with OpenAI."
            }
            if NetworkWatcher.shared.isExpensive { text += " You're on cellular data." }
            return text + " Keep WikiReader open until it finishes."
        case .confirm(let plan):
            let articles = plan.articleCount == 1 ? "1 article" : "\(plan.articleCount) articles"
            let keepOpen = "Keep WikiReader open until it finishes; the screen stays on meanwhile."
            let fromDrive = ArticleAudio.minutes(forCharacters: plan.driveCharacters)
            guard plan.driveCharacters > 0 else {
                return "About \(AudioFormat.duration(minutes: plan.minutes)) of audio for \(articles) with the \(plan.voice.capitalized) voice, "
                    + "roughly \(AudioFormat.cost(plan.dollars)) on your OpenAI account. " + keepOpen
            }
            guard plan.generatedCharacters > 0 else {
                return "All \(AudioFormat.duration(minutes: fromDrive)) of audio for \(articles) is in your Google Drive, so it costs nothing. " + keepOpen
            }
            return "About \(AudioFormat.duration(minutes: plan.minutes)) of audio for \(articles) with the \(plan.voice.capitalized) voice: "
                + "\(AudioFormat.duration(minutes: fromDrive)) comes from your Google Drive for free, "
                + "\(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: plan.generatedCharacters))) is generated, "
                + "roughly \(AudioFormat.cost(plan.dollars)) on your OpenAI account. " + keepOpen
        case .nothingToDo:
            return "All the audio for the \(LibraryActions.openAIVoice.capitalized) voice is already on this iPhone."
        case .noKey:
            return "Audio is generated with an OpenAI voice. Save an API key in Settings → Voice first."
        case .notice(_, let message):
            return message
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
                    Label(
                        downloader.isFromDriveOnly ? "Downloading from Google Drive" : "Downloading audio",
                        systemImage: downloader.isFromDriveOnly ? "icloud.and.arrow.down" : "arrow.down.circle"
                    )
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
                downloader.failedPieces == 0
                    ? (downloader.isFromDriveOnly ? "Downloaded from Google Drive" : "Audio downloaded")
                    : "Audio downloaded, \(downloader.failedPieces) parts failed",
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
