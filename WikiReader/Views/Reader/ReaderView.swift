import OSLog
import SwiftData
import SwiftUI

/// Opens an article and keeps reading across articles: when one has been read to the end, the playback mode
/// (sequential, loop, shuffle) decides what comes next. Switching articles replaces the reader below, so each
/// article gets a fresh reading session.
struct ReaderView: View {
    let article: Article
    @Query(sort: \Article.addedAt, order: .reverse) private var library: [Article]
    /// The article being read after an automatic switch; nil while it is still the one that was opened.
    @State private var switchedTo: Article?
    @State private var startsPlaying = false
    /// Bumped to rebuild the reader for the same article (the only article in the library, in shuffle mode).
    @State private var generation = 0

    private struct ReaderID: Hashable {
        var article: PersistentIdentifier
        var generation: Int
    }

    var body: some View {
        let shown = switchedTo ?? article
        ArticleReader(article: shown, startsPlaying: startsPlaying, onFinished: { advance(from: shown) })
            .id(ReaderID(article: shown.persistentModelID, generation: generation))
    }

    /// Called when `finished` was read to the end (reading is already stopped).
    private func advance(from finished: Article) {
        let index = library.firstIndex { $0.persistentModelID == finished.persistentModelID } ?? 0
        let next = PlaybackMode.saved.next(count: library.count, index: index)
        Log.speech.info("Article finished (\(PlaybackMode.saved.rawValue, privacy: .public)): \(String(describing: next), privacy: .public)")
        switch next {
        case .article(let target) where library.indices.contains(target):
            startsPlaying = true
            switchedTo = library[target]
        case .restart:
            // The same article again: a new reader, started from the top.
            startsPlaying = true
            switchedTo = finished
            generation += 1
        default:
            break
        }
    }
}

private struct ArticleReader: View {
    let article: Article
    /// Start reading from the top as soon as the article opens (when arriving from the previous article).
    let startsPlaying: Bool
    let onFinished: () -> Void
    // Created on first appearance rather than in init: SwiftUI may construct this view many
    // times, and laying out the article or starting a speech engine each time would be wasteful.
    @State private var document: ArticleDocument?
    @State private var session: ReadingSession?
    /// Lock screen and Control Center: shows what is being read and takes their buttons.
    @State private var nowPlaying: NowPlayingController?
    @AppStorage(SettingsKeys.voiceIdentifier) private var voiceIdentifier: String?
    @AppStorage(SettingsKeys.speechEngine) private var engineChoice = SpeechEngineChoice.system
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice = OpenAISpeechEngine.defaultVoice
    /// Whether the session currently uses a cloud engine (and so could fall back to the system voice).
    @State private var usesCloudEngine = false
    @State private var isShowingSettings = false
    @AppStorage(SettingsKeys.speechRate) private var rateValue = SpeechRate.normal.rawValue

    @AppStorage(SettingsKeys.readerFont) private var fontFamily = ReaderStyle.FontFamily.system
    @AppStorage(SettingsKeys.readerFontSize) private var fontSize = ReaderStyle.defaultSize
    @AppStorage(SettingsKeys.readerLineSpacing) private var lineSpacing = ReaderStyle.LineSpacing.standard
    @AppStorage(SettingsKeys.readerMargins) private var margins = ReaderStyle.Margins.standard
    @AppStorage(SettingsKeys.readerTheme) private var theme = ReaderStyle.Theme.system
    @AppStorage(SettingsKeys.readerDarkLevel) private var darkLevel = ReaderStyle.defaultDarkLevel
    @AppStorage(SettingsKeys.playbackMode) private var playbackMode = PlaybackMode.sequential
    @State private var blocks: [ContentBlock] = []
    /// A message shown in the middle of the screen for a few seconds (the play mode just chosen).
    @State private var toast: PlaybackMode?
    @State private var toastGeneration = 0
    @State private var translation: PassageTranslationModel?
    @State private var isShowingSavedWords = false
    @State private var isShowingContents = false
    @State private var outline = ArticleOutline(blocks: [])
    @State private var scrollTarget: ArticleTextView.ScrollTarget?
    /// Whether text is selected: a sideways swipe then belongs to the selection, not to the panels.
    @State private var hasSelection = false
    /// Whether reading was going when a lookup or translation paused it, so it can carry on afterwards. A reader
    /// who paused by hand before looking something up stays paused.
    @State private var lookupResume = LookupResume()
    @Environment(\.dismiss) private var dismiss
    /// The reader is full screen; these menus appear when the reader taps near the top or bottom edge.
    @State private var showsTopBar = false
    @State private var showsBottomBar = false

    private var style: ReaderStyle {
        ReaderStyle(
            fontFamily: fontFamily, fontSize: fontSize, lineSpacing: lineSpacing, margins: margins,
            theme: theme, darkLevel: darkLevel
        )
    }

    var body: some View {
        ZStack {
            if let document, let session {
                ArticleTextView(
                    document: document,
                    style: style,
                    spokenWord: session.spokenWord.flatMap { document.textRange(of: $0.range, inBlock: $0.block) },
                    spokenBlock: session.spokenWord?.block,
                    onWordTapped: { lookUpWord(at: $0, in: document, pausing: session) },
                    onReadFromHere: { block in
                        Log.speech.info("Read from here: start at block \(block)")
                        session.start(at: block)
                    },
                    onTranslate: { translate($0, pausing: session) },
                    onTapZone: handleTap(in:),
                    savedWordKeys: Set(article.savedWords.flatMap { [$0.word.lowercased(), $0.term.lowercased()] }),
                    onSwipeLeft: {
                        hideMenus()
                        isShowingSavedWords = true
                    },
                    scrollTarget: scrollTarget,
                    onSelectionChanged: { hasSelection = $0 },
                    onScrollBegan: hideMenus,
                    initialBlock: startsPlaying ? 0 : article.lastReadBlockIndex,
                    onScrollSettled: { block in
                        // Scrolling only moves the reading position when nothing is being read.
                        session.moveWhileStopped(to: block)
                    }
                )
                // Full screen except at the top, so the first line never hides behind the Dynamic Island.
                .ignoresSafeArea(edges: .bottom)

                topTapStrip

                VStack(spacing: 0) {
                    if showsTopBar {
                        ReaderTopInfoBar(
                            title: article.title,
                            progress: ReadingProgress(blocks: blocks, currentBlock: session.currentBlock, rate: session.rate),
                            style: style,
                            onBack: { dismiss() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    // A speech error must be seen even if the player is hidden.
                    if showsBottomBar || session.failure != nil {
                        VStack(spacing: 0) {
                            if let failure = session.failure {
                                SpeechErrorBanner(
                                    title: usesCloudEngine ? "OpenAI voice unavailable" : "Reading stopped",
                                    failure: failure,
                                    onOpenSettings: { isShowingSettings = true },
                                    onRetry: session.play,
                                    onUseSystemVoice: usesCloudEngine ? { useSystemVoice(in: session) } : nil,
                                    onDismiss: session.dismissFailure
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            if showsBottomBar {
                                ReaderBottomMenu(
                                    session: session, style: style, fontFamily: $fontFamily, fontSize: $fontSize,
                                    lineSpacing: $lineSpacing, margins: $margins, theme: $theme, playbackMode: $playbackMode,
                                    onModeChanged: showToast
                                )
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: showsTopBar)
                .animation(.easeInOut(duration: 0.22), value: showsBottomBar)
                .animation(.default, value: session.failure)
                .sheet(isPresented: $isShowingSettings, onDismiss: { settingsClosed(session) }) {
                    // Only opened from the error banner, where the fix is a voice or an API key.
                    SettingsView(opensVoicePage: true)
                }
                .sheet(item: $translation, onDismiss: { resumeIfPausedForLookup(session) }) { model in
                    TranslationView(model: model)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }

                savedWordsPanel(session: session)
                contentsPanel(session: session)

                if let toast {
                    ReaderToast(symbol: toast.symbol, text: toast.menuTitle, style: style)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .background(Color(style.backgroundColor).ignoresSafeArea())
        .background(SwipeBackEnabler(onSwipe: handleSwipe))
        .preferredColorScheme(style.theme.colorScheme)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .onChange(of: session?.rate) { _, rate in
            // The player's speed is also the default for next time.
            if let rate { rateValue = rate.rawValue }
        }
        .onChange(of: style) { oldStyle, newStyle in
            // New fonts and text colors mean a new text; the text view keeps the reader's place.
            guard oldStyle.textLayout != newStyle.textLayout else { return }
            document = ArticleDocument(title: article.title, blocks: blocks, style: newStyle)
        }
        .onAppear(perform: prepare)
        .onDisappear {
            session?.stop()
            nowPlaying?.teardown()
            nowPlaying = nil
            // Save now rather than waiting for autosave, so the position survives the app being killed.
            try? article.modelContext?.save()
        }
    }

    // MARK: - Saved words panel

    /// The saved words slide in from the right (after a left swipe) and fill the screen; the close button or a
    /// swipe to the right (handled by `SwipeBackEnabler`) puts them away.
    private func savedWordsPanel(session: ReadingSession) -> some View {
        ZStack(alignment: .trailing) {
            if isShowingSavedWords {
                SavedWordsView(article: article, onLookUp: { saved in
                    let request = WordLookupRequest(
                        word: saved.word, term: saved.term,
                        hasDefinition: DictionaryLookup.system.hasDefinition(saved.term), sentence: saved.sentence
                    )
                    pauseForLookup(session)
                    DictionaryPresenter.present(request, saving: saving(for: request), onDismiss: { resumeIfPausedForLookup(session) })
                }, onClose: closeSavedWords)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isShowingSavedWords)
    }

    /// Sideways swipes: right opens the contents (or closes the saved words if they are open), left closes the
    /// contents (the text itself opens the saved words on a left swipe). A swipe while text is selected is left alone.
    private func handleSwipe(_ direction: SwipeDirection) {
        switch direction {
        case .right:
            if isShowingSavedWords {
                closeSavedWords()
            } else if !isShowingContents, !hasSelection {
                hideMenus()
                isShowingContents = true
            }
        case .left:
            if isShowingContents { isShowingContents = false }
        }
    }

    // MARK: - Contents panel

    /// The table of contents slides in from the left and fills the screen.
    private func contentsPanel(session: ReadingSession) -> some View {
        ZStack(alignment: .leading) {
            if isShowingContents {
                ContentsView(articleTitle: article.title, outline: outline, currentBlock: session.currentBlock, style: style, onSelect: { entry in
                    isShowingContents = false
                    Log.app.info("Contents: jump to block \(entry.block)")
                    session.go(to: entry.block)
                    scrollTarget = ArticleTextView.ScrollTarget(token: (scrollTarget?.token ?? 0) + 1, block: entry.block)
                }, onClose: { isShowingContents = false })
                .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isShowingContents)
    }

    private func closeSavedWords() {
        isShowingSavedWords = false
    }

    // MARK: - Menus

    /// Announces the play mode in the middle of the screen for about three seconds. A newer message replaces it
    /// and restarts the time.
    private func showToast(_ mode: PlaybackMode) {
        toast = mode
        toastGeneration += 1
        let generation = toastGeneration
        Task {
            try? await Task.sleep(for: .seconds(3))
            if generation == toastGeneration { toast = nil }
        }
    }

    /// The safe area above the text (the Dynamic Island strip) isn't part of the text view, so taps there would do
    /// nothing. This invisible strip covers it, so tapping the very top of the screen opens the top menu.
    private var topTapStrip: some View {
        GeometryReader { proxy in
            Color.clear
                .frame(height: proxy.safeAreaInsets.top)
                .contentShape(Rectangle())
                .onTapGesture { handleTap(in: .top) }
                .offset(y: -proxy.safeAreaInsets.top)
        }
    }

    private func handleTap(in zone: ArticleTextView.TapZone) {
        switch zone {
        case .top:
            showsTopBar.toggle()
        case .bottom:
            showsBottomBar.toggle()
        case .middle:
            hideMenus()
        }
    }

    private func hideMenus() {
        guard showsTopBar || showsBottomBar else { return }
        showsTopBar = false
        showsBottomBar = false
    }

    private func prepare() {
        guard document == nil else { return }
        let blocks = article.blocks
        self.blocks = blocks
        outline = ArticleOutline(blocks: blocks)
        document = ArticleDocument(title: article.title, blocks: blocks, style: style)

        let session = ReadingSession(
            blocks: blocks,
            startBlock: article.lastReadBlockIndex,
            rate: SpeechRate(rawValue: rateValue) ?? .normal,
            engine: makeEngine()
        )
        session.onBlockChange = { [article] block in
            article.lastReadBlockIndex = block
            Log.app.info("Reading position saved: block \(block)")
        }
        session.onFinished = { [onFinished] in
            // Loop stays in this reader; the other modes hand over to the library-wide logic.
            if PlaybackMode.saved == .loop {
                session.start(at: 0)
            } else {
                onFinished()
            }
        }
        self.session = session
        nowPlaying = NowPlayingController(session: session, blocks: blocks, title: article.title)
        if startsPlaying { session.start(at: 0) }
    }

    private func makeEngine() -> SpeechEngine {
        switch engineChoice {
        case .system:
            usesCloudEngine = false
            return SystemSpeechEngine(voiceIdentifier: voiceIdentifier)
        case .openAI:
            usesCloudEngine = true
            return OpenAISpeechEngine(voice: openAIVoice)
        }
    }

    /// Settings may have a new key, engine or voice: rebuild the engine (keeping the place) and,
    /// if reading can work now, continue where it stopped.
    private func settingsClosed(_ session: ReadingSession) {
        session.replaceEngine(makeEngine())
        if engineChoice == .system || KeychainStore.openAIKey.read() != nil {
            session.play()
        }
    }

    /// For this reading only: settings keep the cloud voice for next time.
    private func useSystemVoice(in session: ReadingSession) {
        Log.speech.info("Falling back to the system voice for this article")
        usesCloudEngine = false
        session.replaceEngine(SystemSpeechEngine(voiceIdentifier: voiceIdentifier))
        session.play()
    }

    private func translate(_ text: String, pausing session: ReadingSession) {
        Log.lookup.info("Translate requested: \(text.count) characters")
        // Like looking up a word: reading pauses, and carries on when the sheet closes if it was going.
        pauseForLookup(session)
        translation = PassageTranslationModel(text: text)
    }

    private func lookUpWord(at range: NSRange, in document: ArticleDocument, pausing session: ReadingSession) {
        guard let context = document.context(for: range) else { return }
        let request = DictionaryLookup.system.request(forWordAt: context.wordRange, in: context.text)
        Log.lookup.info("""
            Tapped \(request.word, privacy: .public) -> term \(request.term, privacy: .public), \
            hasDefinition: \(request.hasDefinition, privacy: .public)
            """)
        // Looking up pauses reading; it carries on when the dictionary closes if it was going.
        pauseForLookup(session)
        DictionaryPresenter.present(request, saving: saving(for: request), onDismiss: { resumeIfPausedForLookup(session) })
    }

    /// Pauses for a lookup, remembering whether reading was going. A second lookup while the first is still
    /// open (the reader is already paused by then) keeps the first answer.
    private func pauseForLookup(_ session: ReadingSession) {
        lookupResume.begin(wasPlaying: session.isPlaying)
        session.pause()
    }

    /// Carries on reading if it was going before the lookup; otherwise leaves it paused until Play is pressed.
    private func resumeIfPausedForLookup(_ session: ReadingSession) {
        if lookupResume.end(isPaused: session.state == .paused) { session.play() }
    }

    /// The dictionary's bookmark button saves into this article's own word list.
    private func saving(for request: WordLookupRequest) -> WordSaving {
        WordSaving(
            isSaved: article.isSaved(term: request.term),
            toggle: { [article] meaning in article.toggleSavedWord(request, meaning: meaning) },
            setMeaning: { [article] meaning in article.setMeaning(meaning, forTerm: request.term) }
        )
    }
}
