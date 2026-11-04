import OSLog
import SwiftData
import SwiftUI

/// Where the library leads: an article, or one of English Reader's categories.
enum LibraryRoute: Hashable {
    case article(Article)
    case category(SiteCategory)
}

/// The two parts of the library.
enum LibraryShelf: String {
    /// Articles added here: from Wikipedia, files, photos, pasted text.
    case mine
    /// The English Reader site's catalog; an article is fetched when first opened.
    case site
}

/// Home screen: the articles added here, newest first, or the English Reader site's catalog. Swiping a row reveals
/// its Info button; the + menu adds articles, selects several for batch work (a swipe right leaves), and opens
/// storage and Google Drive.
struct LibraryView: View {
    @Query(sort: \Article.addedAt, order: .reverse) private var articles: [Article]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice = OpenAISpeechEngine.defaultVoice
    @AppStorage(SettingsKeys.libraryShelf) private var shelf = LibraryShelf.mine
    @State private var downloader = AudioDownloader.shared
    @State private var drive = DriveAudioStore.shared
    @State private var site = SiteLibrary.shared
    /// The English Reader article being fetched to be opened.
    @State private var openingSiteID: String?
    @State private var siteOpenError: String?
    @State private var path: [LibraryRoute] = []
    @State private var isAddingArticle = false
    @State private var importer = ArticleImportCoordinator()
    @State private var isShowingSettings = false
    @State private var isShowingStorage = false
    @State private var isShowingDrive = false
    @State private var isShowingWordBook = false
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

    /// What is listed: the site's shelf only outside of selecting (selecting is for the articles added here).
    private var showsSite: Bool { shelf == .site && !isSelecting }

    /// The articles the site's text was made into: listed under English Reader, not with the ones added here.
    private var siteArticleURLs: Set<URL> {
        Set(site.links.values.filter(\.ownsText).map(\.articleURL))
    }

    private var myArticles: [Article] {
        let siteURLs = siteArticleURLs
        return articles.filter { !siteURLs.contains($0.sourceURL) }
    }

    private var shownArticles: [Article] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let mine = myArticles
        return query.isEmpty ? mine : mine.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var shownSiteArticles: [SiteArticleSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? site.articles : site.articles.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// A catalog entry's article on this iPhone, once opened.
    private func localArticle(_ summary: SiteArticleSummary) -> Article? {
        guard let url = site.links[summary.id]?.articleURL else { return nil }
        return articles.first { $0.sourceURL == url }
    }

    private var selectedArticles: [Article] {
        articles.filter { selection.contains($0.persistentModelID) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selection) {
                if !isSelecting {
                    Section {
                        Picker("Show", selection: $shelf) {
                            Text("My Articles").tag(LibraryShelf.mine)
                            Text("English Reader").tag(LibraryShelf.site)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    }
                }
                if (downloader.phase != .idle || drive.backupRun != nil) && !isSelecting {
                    Section {
                        if downloader.phase != .idle { AudioDownloadStatusRow() }
                        if drive.backupRun != nil { DriveBackupStatusRow() }
                    }
                }
                if showsSite {
                    if searchText.isEmpty, !site.articles.isEmpty {
                        Section {
                            categoryCarousel
                        } header: {
                            Text("Categories")
                        }
                    }
                    Section {
                        ForEach(shownSiteArticles, id: \.id) { summary in
                            siteRow(summary)
                        }
                    } header: {
                        if searchText.isEmpty, !site.articles.isEmpty { Text("Latest") }
                    } footer: {
                        if !site.articles.isEmpty { Text(siteFooter) }
                    }
                } else {
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
                                    path = [.article(article)]
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
            }
            // Keeps the shelf picker close to the articles.
            .listSectionSpacing(.compact)
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            // While selecting, a swipe to the right anywhere leaves, like going back; rows can't be swiped then.
            .simultaneousGesture(leaveSelectingSwipe, including: isSelecting ? .all : .subviews)
            .searchable(text: $searchText, prompt: "Search titles")
            // New and changed articles on English Reader (cheap: only what changed since last time).
            .refreshable { await site.sync() }
            .task(id: shelf) {
                if shelf == .site { await site.sync(ifDue: true) }
            }
            .alert("Couldn't Open the Article", isPresented: Binding(get: { siteOpenError != nil }, set: { if !$0 { siteOpenError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(siteOpenError ?? "")
            }
            .overlay {
                if showsSite {
                    siteOverlay
                } else if myArticles.isEmpty {
                    ContentUnavailableView(
                        "No Articles",
                        systemImage: "books.vertical",
                        description: Text("Tap + to add an article from Wikipedia, or import your own text, PDF or photos.")
                    )
                } else if shownArticles.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle(isSelecting ? (selection.isEmpty ? "Select Articles" : "\(selection.count) Selected") : "Library")
            .navigationBarTitleDisplayMode(isSelecting ? .inline : .automatic)
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .article(let article):
                    ReaderView(article: article)
                case .category(let category):
                    SiteCategoryView(category: category, state: siteRowState, onOpen: openSite)
                }
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
            .task(id: FractionInput(
                count: articles.count, voice: openAIVoice, done: downloader.donePieces, phase: downloader.phase, siteLinks: site.links
            )) {
                audioFractions = await fractions()
            }
            .task {
                if Article.repairOrigins(articles) { try? modelContext.save() }
                // Words saved before the word book was global, from each article's own list (once per device).
                VocabularyBook.shared.importArticleWordsOnce(articles)
                // Incremental backup to Google Drive: whatever audio on this iPhone Drive lacks (e.g. generated while
                // signed out) is queued. At most every ten minutes, so coming back from an article is cheap.
                let drive = DriveAudioStore.shared
                guard drive.isEnabled else { return }
                let library = articles.map { (title: $0.title, url: $0.sourceURL.absoluteString, blocksData: $0.blocksData) }
                await drive.backUpIfDue(library, voice: openAIVoice)
            }
            .sheet(isPresented: $isAddingArticle) {
                AddArticleView { article in
                    path = [.article(article)]
                }
            }
            .articleImport(importer) { article in
                path = [.article(article)]
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $isShowingStorage, onDismiss: refreshFractions) {
                LibraryStorageView()
            }
            .sheet(isPresented: $isShowingDrive, onDismiss: refreshFractions) {
                GoogleDriveSheet()
            }
            .sheet(isPresented: $isShowingWordBook) {
                WordBookView()
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
        /// An article opened from the site, or updated from it.
        var siteLinks: [String: SiteLibrary.Link]
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
    struct BadgeLabelStyle: LabelStyle {
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
            path = [.article(article)]
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
        show(article)
    }

    /// Opens the reader: over a category's page if one is shown (back returns to it), else from the library.
    private func show(_ article: Article) {
        if case .category = path.last {
            path.append(.article(article))
        } else {
            path = [.article(article)]
        }
    }

    // MARK: - + menu

    private var addMenu: some View {
        Menu {
            Button("Add from Wikipedia", systemImage: "plus") {
                isAddingArticle = true
            }
            Section("Import") {
                Button("File…", systemImage: "doc") { importer.isChoosingFile = true }
                Button("Photos…", systemImage: "photo.on.rectangle") { importer.isChoosingPhotos = true }
                Button("Paste Text", systemImage: "doc.on.clipboard") { importer.paste() }
            }
            Button("Select Articles", systemImage: "checkmark.circle") {
                withAnimation {
                    shelf = .mine
                    isSelecting = true
                }
            }
            .disabled(myArticles.isEmpty)
            // Downloading audio is in Select Articles (Select All covers the whole library) and in Library & Storage.
            Section {
                Button("Word Book", systemImage: "character.book.closed") {
                    isShowingWordBook = true
                }
                Button("Library & Storage", systemImage: "internaldrive") {
                    isShowingStorage = true
                }
                Button("Google Drive", systemImage: "icloud") {
                    isShowingDrive = true
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
            Menu("Google Drive") {
                Button("Download from Drive", systemImage: "icloud.and.arrow.down") {
                    let chosen = selectedArticles
                    Task {
                        downloadPrompt = await LibraryActions.drivePullPrompt(for: chosen)
                        if case .confirm = downloadPrompt { endSelecting() }
                    }
                }
                .disabled(downloader.isRunning)
                Button("Back Up to Drive", systemImage: "icloud.and.arrow.up") {
                    let chosen = selectedArticles
                    Task {
                        downloadPrompt = await LibraryActions.backUpToDrive(chosen)
                        // Started: the progress row at the top of the library follows it.
                        if downloadPrompt == nil { endSelecting() }
                    }
                }
            }
            .disabled(selection.isEmpty)
            Spacer()
            // An icon: three titles don't fit, and the bar would fold this one into an overflow menu.
            Menu("Delete", systemImage: "trash") {
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
        Task { audioFractions = await fractions() }
    }

    /// How much of each article's audio is here: in the site's narration voice for articles opened from the site,
    /// in Settings' OpenAI voice for the rest.
    private func fractions() async -> [PersistentIdentifier: Double] {
        let groups = Dictionary(grouping: articles) { site.narrationVoice(forArticleURL: $0.sourceURL) ?? openAIVoice }
        var result: [PersistentIdentifier: Double] = [:]
        for (voice, group) in groups {
            let sources = group.map { (id: $0.persistentModelID, blocksData: $0.blocksData) }
            result.merge(await ArticleAudio.fractions(of: sources, voice: voice)) { $1 }
        }
        return result
    }

    // MARK: - English Reader

    private func siteRow(_ summary: SiteArticleSummary) -> some View {
        let local = localArticle(summary)
        let rowID = local?.persistentModelID
        return SwipeRevealRow(
            isOpen: rowID != nil && openRow == rowID,
            // Info needs the article here, so only once it was opened.
            isEnabled: local != nil,
            onOpenChange: { openRow = $0 ? rowID : nil },
            onInfo: {
                openRow = nil
                infoArticle = local
            },
            onTap: {
                openRow = nil
                openSite(summary)
            }
        ) {
            SiteArticleRow(summary: summary, state: siteRowState(summary))
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
    }

    /// The site's categories as a row of covers, the fullest first; each leads to its own page.
    private var categoryCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(SiteCategories.group(site.articles), id: \.category) { group in
                    Button {
                        path.append(.category(group.category))
                    } label: {
                        CategoryTile(category: group.category, count: group.articles.count)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // The covers scroll out to the screen's edges rather than stopping at the list's margins.
        .scrollClipDisabled()
        .frame(height: CategoryTile.size.height)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private func siteRowState(_ summary: SiteArticleSummary) -> SiteArticleRow.State {
        let rowID = localArticle(summary)?.persistentModelID
        return SiteArticleRow.State(
            audioFraction: rowID.map { audioFractions[$0] ?? 0 },
            isOpening: openingSiteID == summary.id,
            isDownloading: rowID.map { downloader.isDownloading($0) } ?? false
        )
    }

    /// Fetches the article the first time (and when the site changed it), then opens it like any other.
    private func openSite(_ summary: SiteArticleSummary) {
        guard openingSiteID == nil else { return }
        openingSiteID = summary.id
        Task {
            defer { openingSiteID = nil }
            do throws(SiteError) {
                let article = try await site.open(summary, in: modelContext)
                try? modelContext.save()
                if article.bookmarks.isEmpty {
                    show(article)
                } else {
                    startChoice = article
                }
            } catch {
                siteOpenError = error.message
            }
        }
    }

    @ViewBuilder
    private var siteOverlay: some View {
        if site.articles.isEmpty {
            switch site.state {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load English Reader", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await site.sync() } }
                }
            case .synced:
                ContentUnavailableView("No Articles Yet", systemImage: "books.vertical", description: Text("Articles published on English Reader appear here."))
            case .idle, .syncing:
                ProgressView("Loading English Reader…")
            }
        } else if shownSiteArticles.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var siteFooter: String {
        let base = "From english.thrones.wang. An article is downloaded when you open it; its narration plays from the site, free."
        if case .failed(let message) = site.state { return "\(base)\n\nCouldn't check for new articles: \(message)" }
        return base
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Article.self, inMemory: true)
}
