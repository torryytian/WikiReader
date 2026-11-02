import OSLog
import SwiftData
import SwiftUI

/// Home screen: the list of saved articles, newest first. Swiping a row reveals its Info button; the + menu adds
/// articles, selects several for batch work (a swipe right leaves) and shows storage.
struct LibraryView: View {
    @Query(sort: \Article.addedAt, order: .reverse) private var articles: [Article]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice = OpenAISpeechEngine.defaultVoice
    @State private var downloader = AudioDownloader.shared
    @State private var path: [Article] = []
    @State private var isAddingArticle = false
    @State private var isShowingSettings = false
    @State private var isShowingStorage = false
    @State private var infoArticle: Article?
    /// An article with bookmarks being opened: where to start is asked first.
    @State private var startChoice: Article?
    /// What to do once the info or start sheet has gone: an article can't be opened, or deleted, under its own sheet.
    @State private var afterInfo: AfterInfo?
    @State private var searchText = ""
    /// The row slid open to show its Info block; one at a time.
    @State private var openRow: PersistentIdentifier?

    @State private var isSelecting = false
    @State private var selection = Set<PersistentIdentifier>()
    @State private var isConfirmingDelete = false
    @State private var isConfirmingAudioDelete = false
    @State private var downloadPrompt: AudioDownloadPrompt?
    /// How much of each article's audio is downloaded, for the rows.
    @State private var audioFractions: [PersistentIdentifier: Double] = [:]

    private var shownArticles: [Article] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? articles : articles.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var selectedArticles: [Article] {
        articles.filter { selection.contains($0.persistentModelID) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selection) {
                if downloader.phase != .idle && !isSelecting {
                    Section { AudioDownloadStatusRow() }
                }
                Section {
                    ForEach(shownArticles) { article in
                        let id = article.persistentModelID
                        SwipeRevealRow(
                            isOpen: openRow == id,
                            isEnabled: !isSelecting,
                            onOpenChange: { openRow = $0 ? id : nil },
                            onInfo: {
                                openRow = nil
                                infoArticle = article
                            },
                            onTap: isSelecting ? nil : {
                                openRow = nil
                                // With bookmarks, ask where to start; otherwise carry on where reading stopped.
                                if article.bookmarks.isEmpty {
                                    path = [article]
                                } else {
                                    startChoice = article
                                }
                            }
                        ) {
                            row(article)
                        }
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: SwipeRevealRow<EmptyView>.cornerRadius, style: .continuous))
                        .contextMenu {
                            if !isSelecting { rowMenu(article) }
                        }
                        // The row draws its own card, so the list's background and separators stay out of the way.
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    }
                }
            }
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            // While selecting, a swipe to the right anywhere leaves, like going back; rows can't be swiped then.
            .simultaneousGesture(leaveSelectingSwipe, including: isSelecting ? .all : .subviews)
            .searchable(text: $searchText, prompt: "Search titles")
            .overlay {
                if articles.isEmpty {
                    ContentUnavailableView(
                        "No Articles",
                        systemImage: "books.vertical",
                        description: Text("Tap + to add a Wikipedia article.")
                    )
                } else if shownArticles.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle(isSelecting ? (selection.isEmpty ? "Select Articles" : "\(selection.count) Selected") : "Library")
            .navigationBarTitleDisplayMode(isSelecting ? .inline : .automatic)
            .navigationDestination(for: Article.self) { article in
                ReaderView(article: article)
            }
            .toolbar {
                if isSelecting {
                    selectionToolbar
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") {
                            isShowingSettings = true
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        addMenu
                    }
                }
            }
            .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
            .task(id: FractionInput(count: articles.count, voice: openAIVoice, done: downloader.donePieces, phase: downloader.phase)) {
                let sources = articles.map { (id: $0.persistentModelID, blocksData: $0.blocksData) }
                audioFractions = await ArticleAudio.fractions(of: sources, voice: openAIVoice)
            }
            .task {
                // Incremental backup to Google Drive: whatever audio on this iPhone Drive lacks (e.g. generated while
                // signed out) is queued. At most every ten minutes, so coming back from an article is cheap.
                let drive = DriveAudioStore.shared
                guard drive.isEnabled else { return }
                let library = articles.map { (title: $0.title, url: $0.sourceURL.absoluteString, blocksData: $0.blocksData) }
                await drive.backUpIfDue(library, voice: openAIVoice)
            }
            .sheet(isPresented: $isAddingArticle) {
                AddArticleView { article in
                    path = [article]
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $isShowingStorage, onDismiss: refreshFractions) {
                LibraryStorageView()
            }
            .sheet(item: $infoArticle, onDismiss: performAfterInfo) { article in
                ArticleInfoView(
                    article: article,
                    onOpen: { block in
                        afterInfo = .open(article, block: block)
                        infoArticle = nil
                    },
                    onDelete: { withAudio in
                        afterInfo = .delete(article, withAudio: withAudio)
                        infoArticle = nil
                    }
                )
            }
            .sheet(item: $startChoice, onDismiss: performAfterInfo) { article in
                StartPointView(article: article) { block in
                    afterInfo = .open(article, block: block)
                    startChoice = nil
                }
            }
            .audioDownloadPrompt($downloadPrompt)
            .confirmationDialog(deleteTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Articles and Their Audio", role: .destructive) { deleteSelected(withAudio: true) }
                Button("Delete Articles, Keep Audio", role: .destructive) { deleteSelected(withAudio: false) }
            } message: {
                Text("Their saved words and reading positions go too. Audio that is kept is used again if an article is added again unchanged.")
            }
            .confirmationDialog(audioDeleteTitle, isPresented: $isConfirmingAudioDelete, titleVisibility: .visible) {
                Button("Delete Audio", role: .destructive) {
                    let chosen = selectedArticles
                    Task {
                        await LibraryActions.removeAudio(of: chosen, library: articles)
                        refreshFractions()
                    }
                    endSelecting()
                }
            } message: {
                Text("All voices. It will be generated and paid for again when read.")
            }
        }
    }

    private enum AfterInfo {
        case open(Article, block: Int)
        case delete(Article, withAudio: Bool)
    }

    private struct FractionInput: Equatable {
        var count: Int
        var voice: String
        var done: Int
        var phase: AudioDownloader.Phase
    }

    // MARK: - Rows

    private func row(_ article: Article) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(article.addedAt, format: .dateTime.year().month().day().hour().minute())
                    audioBadge(article)
                    let marks = article.bookmarks.count
                    if marks > 0 {
                        Text("·")
                        Label("\(marks)", systemImage: "bookmark")
                            .labelStyle(BadgeLabelStyle())
                            .accessibilityLabel(marks == 1 ? "1 bookmark" : "\(marks) bookmarks")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func audioBadge(_ article: Article) -> some View {
        let fraction = audioFractions[article.persistentModelID] ?? 0
        if downloader.isDownloading(article.persistentModelID) {
            Text("·")
            Label("Downloading \(Int((fraction * 100).rounded(.down)))%", systemImage: "arrow.down.circle")
                .labelStyle(BadgeLabelStyle())
                .foregroundStyle(.tint)
        } else if fraction >= 1 {
            Text("·")
            Label("Audio downloaded", systemImage: "headphones")
                .labelStyle(BadgeLabelStyle())
        } else if fraction > 0 {
            Text("·")
            Label("Audio \(Int((fraction * 100).rounded(.down)))%", systemImage: "headphones")
                .labelStyle(BadgeLabelStyle())
        }
    }

    /// Icon and text close together, at caption size.
    private struct BadgeLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon
                configuration.title
            }
        }
    }

    /// Long press on a row: carry on reading, start from one of the bookmarks, or see the article's info.
    @ViewBuilder
    private func rowMenu(_ article: Article) -> some View {
        Button("Continue Reading", systemImage: "book") {
            openRow = nil
            path = [article]
        }
        let marks = article.bookmarks
        if !marks.isEmpty {
            Section("Bookmarks") {
                ForEach(marks) { mark in
                    Button(mark.excerpt, systemImage: "bookmark.fill") {
                        open(article, at: mark.block)
                    }
                }
            }
        }
        Section {
            Button("Info", systemImage: "info.circle") {
                openRow = nil
                infoArticle = article
            }
        }
    }

    /// Opens an article at a block (a bookmark, a section), which becomes its reading position.
    private func open(_ article: Article, at block: Int) {
        openRow = nil
        article.lastReadBlockIndex = block
        path = [article]
    }

    // MARK: - + menu

    private var addMenu: some View {
        Menu {
            Button("Add Article", systemImage: "plus") {
                isAddingArticle = true
            }
            Button("Select Articles", systemImage: "checkmark.circle") {
                withAnimation { isSelecting = true }
            }
            .disabled(articles.isEmpty)
            // Downloading audio is in Select Articles (Select All covers the whole library) and in Library & Storage.
            Section {
                Button("Library & Storage", systemImage: "internaldrive") {
                    isShowingStorage = true
                }
            }
        } label: {
            Label("Add and Manage", systemImage: "plus")
        }
    }

    // MARK: - Selecting

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            let allChosen = !shownArticles.isEmpty && shownArticles.allSatisfy { selection.contains($0.persistentModelID) }
            Button(allChosen ? "Deselect All" : "Select All") {
                if allChosen {
                    selection.subtract(shownArticles.map(\.persistentModelID))
                } else {
                    selection.formUnion(shownArticles.map(\.persistentModelID))
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: endSelecting)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Download Audio") {
                let chosen = selectedArticles
                Task {
                    downloadPrompt = await LibraryActions.downloadPrompt(for: chosen)
                    if case .confirm = downloadPrompt { endSelecting() }
                }
            }
            .disabled(selection.isEmpty)
            Spacer()
            Menu("Delete") {
                Button("Delete Audio Only", systemImage: "speaker.slash") { isConfirmingAudioDelete = true }
                Button("Delete Articles", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            }
            .disabled(selection.isEmpty)
        }
    }

    private var deleteTitle: String {
        selection.count == 1 ? "Delete 1 article?" : "Delete \(selection.count) articles?"
    }

    private var audioDeleteTitle: String {
        selection.count == 1 ? "Delete the audio of 1 article?" : "Delete the audio of \(selection.count) articles?"
    }

    private func deleteSelected(withAudio: Bool) {
        LibraryActions.delete(selectedArticles, withAudio: withAudio, library: articles, context: modelContext)
        endSelecting()
    }

    private var leaveSelectingSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard isSelecting, dx > 80, dx > abs(dy) * 2 else { return }
                endSelecting()
            }
    }

    private func endSelecting() {
        withAnimation {
            isSelecting = false
            selection = []
        }
    }

    // MARK: - Helpers

    private func performAfterInfo() {
        guard let action = afterInfo else { return }
        afterInfo = nil
        switch action {
        case .open(let article, let block):
            open(article, at: block)
        case .delete(let article, let withAudio):
            LibraryActions.delete([article], withAudio: withAudio, library: articles, context: modelContext)
        }
    }

    private func refreshFractions() {
        Task {
            let sources = articles.map { (id: $0.persistentModelID, blocksData: $0.blocksData) }
            audioFractions = await ArticleAudio.fractions(of: sources, voice: openAIVoice)
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Article.self, inMemory: true)
}
