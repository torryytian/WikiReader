import SwiftData
import SwiftUI

/// An article's details, opened by swiping its row in the library: what it is about, how it is laid out, how much of
/// its OpenAI audio is on this iPhone, taking it from or backing it up to Google Drive, and deleting it.
struct ArticleInfoView: View {
    let article: Article
    /// Opens the article at a block.
    var onOpen: (Int) -> Void
    /// Deletes the article; true: its audio too.
    var onDelete: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var library: [Article]
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice = OpenAISpeechEngine.defaultVoice
    @AppStorage(SettingsKeys.speechEngine) private var engineChoice = SpeechEngineChoice.system
    @AppStorage(SettingsKeys.driveLookUpFirst) private var driveLookUpFirst = true
    @AppStorage(SettingsKeys.driveAutoBackUp) private var driveAutoBackUp = true
    @State private var downloader = AudioDownloader.shared
    @State private var drive = DriveAudioStore.shared
    @State private var account = GoogleAccount.shared
    /// A Google Drive action being worked out.
    @State private var isPreparingDrive = false

    @State private var blocks: [ContentBlock] = []
    @State private var outline = ArticleOutline(blocks: [])
    @State private var status: ArticleAudioStatus?
    /// Whether this article's audio is backed up to Google Drive; nil while not signed in or not worked out yet.
    @State private var backup: DriveAudioStore.ArticleBackup?
    @State private var showsWholeSummary = false
    @State private var downloadPrompt: AudioDownloadPrompt?
    @State private var isConfirmingAudioDelete = false
    @State private var isConfirmingDelete = false
    /// Bumped to recount the audio after deleting it.
    @State private var audioVersion = 0

    private var isDownloading: Bool { downloader.isDownloading(article.persistentModelID) }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                overviewSection
                bookmarksSection
                audioSection
                driveSection
                contentsSection
                Section {
                    Button("Delete Article", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Article Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if blocks.isEmpty {
                    blocks = article.blocks
                    outline = ArticleOutline(blocks: blocks)
                }
            }
            .task(id: StatusInput(
                voice: openAIVoice, done: downloader.donePieces, version: audioVersion,
                pending: drive.pendingUploads.count, signedIn: account.isSignedIn
            )) {
                if drive.isEnabled {
                    await drive.syncIndex()
                    backup = await DriveAudioStore.backup(
                        url: article.sourceURL.absoluteString, blocksData: article.blocksData, voice: openAIVoice,
                        indexed: drive.indexedKeys, pending: Set(drive.pendingUploads), manifests: drive.manifestNames
                    )
                }
                status = await ArticleAudio.status(ofBlocksData: article.blocksData, voice: openAIVoice)
            }
            .audioDownloadPrompt($downloadPrompt)
            .confirmationDialog("Delete \(article.title)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Article and Its Audio", role: .destructive) { onDelete(true) }
                Button("Delete Article, Keep Audio", role: .destructive) { onDelete(false) }
            } message: {
                Text("Its saved words and reading position go too. Audio that is kept is used again if the article is added again unchanged.")
            }
            .confirmationDialog("Delete this article's audio?", isPresented: $isConfirmingAudioDelete, titleVisibility: .visible) {
                Button("Delete Audio", role: .destructive) {
                    Task {
                        await LibraryActions.removeAudio(of: [article], library: library)
                        audioVersion += 1
                    }
                }
            } message: {
                Text("All voices. It will be generated and paid for again when read.")
            }
        }
    }

    private struct StatusInput: Equatable {
        var voice: String
        var done: Int
        var version: Int
        var pending: Int
        var signedIn: Bool
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(article.title)
                    .font(.title2.weight(.bold))
                if let lead = blocks.first(where: { $0.kind == .paragraph })?.text {
                    Text(lead)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsWholeSummary ? nil : 5)
                    Button(showsWholeSummary ? "Less" : "More") {
                        withAnimation { showsWholeSummary.toggle() }
                    }
                    .font(.callout.weight(.medium))
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
            if article.isImported {
                Label("Imported text", systemImage: "doc.text")
                    .foregroundStyle(.secondary)
            } else {
                Link(destination: article.sourceURL) {
                    Label("Open on Wikipedia", systemImage: "safari")
                }
            }
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        Section("Overview") {
            LabeledContent("Words", value: wordCount.formatted())
            LabeledContent("Sections", value: "\(outline.entries.count) · \(paragraphCount) paragraphs")
            LabeledContent("Listening Time", value: AudioFormat.duration(minutes: Double(outline.totalMinutes)) + " at 1×")
            LabeledContent("Reading Position", value: positionText)
            LabeledContent("Words Saved Here", value: "\(VocabularyBook.shared.entries(savedFrom: article.sourceURL).count)")
            LabeledContent("Added", value: article.addedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private var wordCount: Int {
        blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private var paragraphCount: Int {
        blocks.count(where: { $0.kind == .paragraph })
    }

    private var positionText: String {
        let block = article.lastReadBlockIndex
        guard block > 0, let entry = outline.currentEntry(atBlock: block) else { return "Not started" }
        let before = blocks.prefix(block).reduce(0) { $0 + $1.text.count }
        let percent = outline.totalCharacters > 0 ? Int((Double(before) / Double(outline.totalCharacters) * 100).rounded()) : 0
        return "\(percent)% · \(entry.title)"
    }

    // MARK: - Bookmarks

    @ViewBuilder
    private var bookmarksSection: some View {
        let marks = article.bookmarks.filter { blocks.indices.contains($0.block) }
        if !marks.isEmpty {
            Section {
                ForEach(marks) { mark in
                    Button {
                        onOpen(mark.block)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(Color.accentColor)
                                .padding(.top, 2)
                            let section = outline.currentEntry(atBlock: mark.block)?.title ?? article.title
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if mark.excerpt != section {
                                    Text(mark.excerpt)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    for index in offsets { article.removeBookmark(id: marks[index].id) }
                }
            } header: {
                Text("Bookmarks")
            } footer: {
                Text("Tap a bookmark to read from there.")
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            if let status {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(status.isComplete ? "All downloaded" : "\(Int((status.fraction * 100).rounded(.down)))% downloaded")
                        Spacer()
                        Text(AudioFormat.bytes(status.bytes))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: status.fraction)
                        .tint(status.isComplete ? .green : nil)
                    Text("\(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: status.cachedCharacters))) of \(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: status.totalCharacters)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if isDownloading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Downloading…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { downloader.cancel(article: article.persistentModelID) }
                            .buttonStyle(.borderless)
                    }
                } else if !status.isComplete {
                    Button {
                        Task { downloadPrompt = await LibraryActions.downloadPrompt(for: [article]) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download Remaining Audio")
                                Text("About \(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: status.missingCharacters))), roughly \(AudioFormat.cost(ArticleAudio.dollars(forCharacters: status.missingCharacters)))")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                }

                if status.otherVoiceBytes > 0 {
                    LabeledContent("Other Voices", value: AudioFormat.bytes(status.otherVoiceBytes))
                }
                Button("Delete This Article's Audio", systemImage: "speaker.slash", role: .destructive) {
                    isConfirmingAudioDelete = true
                }
                .foregroundStyle(status.bytes + status.otherVoiceBytes > 0 ? .red : .secondary)
                .disabled(status.bytes + status.otherVoiceBytes == 0)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("Audio · \(openAIVoice.capitalized)")
        } footer: {
            Text(audioFooter)
        }
    }

    private var audioFooter: String {
        var text = "OpenAI audio on this iPhone, for listening offline. Times and costs are estimates."
        if engineChoice == .system {
            text += " You're listening with an iPhone voice now; this audio plays when the \(openAIVoice.capitalized) voice is chosen in Settings."
        }
        return text
    }

    // MARK: - Google Drive

    @ViewBuilder
    private var driveSection: some View {
        if account.isSignedIn {
            Section {
                BackupStatusLine(backup: backup)
                    .font(.subheadline)
                    .padding(.vertical, 2)
                driveButton(
                    "Download from Drive", systemImage: "icloud.and.arrow.down", detail: pullDetail
                ) {
                    Task { downloadPrompt = await LibraryActions.drivePullPrompt(for: [article]) }
                }
                .disabled(isDownloading || downloader.isRunning)
                driveButton(
                    "Back Up to Drive", systemImage: "icloud.and.arrow.up", detail: backUpDetail
                ) {
                    Task { downloadPrompt = await LibraryActions.backUpToDrive([article]) }
                }
            } header: {
                Text("Google Drive")
            } footer: {
                Text(driveFooter)
            }
        }
    }

    private func driveButton(_ title: String, systemImage: String, detail: String?, action: @escaping () async -> Void) -> some View {
        Button {
            isPreparingDrive = true
            Task {
                await action()
                isPreparingDrive = false
            }
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                if isPreparingDrive {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isPreparingDrive)
    }

    private var pullDetail: String? {
        guard let backup else { return nil }
        guard backup.piecesOnlyOnDrive > 0 else { return "Nothing in Drive that isn't on this iPhone" }
        let parts = backup.piecesOnlyOnDrive == 1 ? "1 part" : "\(backup.piecesOnlyOnDrive) parts"
        return "\(parts) · about \(AudioFormat.duration(minutes: ArticleAudio.minutes(forCharacters: backup.charactersOnlyOnDrive))) · free"
    }

    private var backUpDetail: String? {
        guard let backup else { return nil }
        if backup.missing > 0 { return backup.missing == 1 ? "1 part isn't in Drive yet" : "\(backup.missing) parts aren't in Drive yet" }
        if backup.waiting > 0 { return backup.waiting == 1 ? "1 part waiting to upload" : "\(backup.waiting) parts waiting to upload" }
        if backup.state == .noAudio { return "No audio on this iPhone yet" }
        return backup.hasManifest ? "Everything on this iPhone is in Drive" : "Lists the article in Drive for the Chrome extension"
    }

    private var driveFooter: String {
        switch (driveLookUpFirst, driveAutoBackUp) {
        case (true, true):
            "Drive is also checked before a paragraph is generated, and new audio is backed up on its own. Change that in Settings → Google Drive."
        case (true, false):
            "Drive is checked before a paragraph is generated. New audio isn't backed up on its own (Settings → Google Drive): back it up here."
        case (false, true):
            "New audio is backed up on its own, but Drive isn't checked before generating (Settings → Google Drive): download from it here."
        case (false, false):
            "Drive is only used when you ask here: automatic checking and backup are off in Settings → Google Drive."
        }
    }

    // MARK: - Contents

    private var contentsSection: some View {
        Section {
            ForEach(Array(outline.entries.enumerated()), id: \.element.id) { index, entry in
                Button {
                    onOpen(entry.block)
                } label: {
                    contentsRow(entry, end: index + 1 < outline.entries.count ? outline.entries[index + 1].block : blocks.count)
                }
                .tint(.primary)
            }
        } header: {
            Text("Contents")
        } footer: {
            Text("Tap a section to read from there. The rings show how much of each section's audio is downloaded.")
        }
    }

    private func contentsRow(_ entry: ArticleOutline.Entry, end: Int) -> some View {
        let isCurrent = outline.currentEntry(atBlock: article.lastReadBlockIndex)?.id == entry.id && article.lastReadBlockIndex > 0
        return HStack(spacing: 10) {
            Text(entry.title)
                .font(entry.depth == 0 ? .body.weight(.medium) : .subheadline)
                .foregroundStyle(entry.depth == 0 ? .primary : .secondary)
                .padding(.leading, CGFloat(entry.depth) * 16)
                .lineLimit(2)
            if isCurrent {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Reading here")
            }
            Spacer(minLength: 8)
            Text("\(entry.minutes) min")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            AudioProgressRing(fraction: status?.fraction(ofBlocks: entry.block..<end) ?? 0)
        }
        .contentShape(Rectangle())
    }
}
