import OSLog
import SwiftData
import SwiftUI

struct ReaderView: View {
    let article: Article
    // Created on first appearance rather than in init: SwiftUI may construct this view many
    // times, and laying out the article or starting a speech engine each time would be wasteful.
    @State private var document: ArticleDocument?
    @State private var session: ReadingSession?
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
    @State private var blocks: [ContentBlock] = []
    @State private var translation: PassageTranslationModel?
    @State private var isShowingSavedWords = false
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
                    onScrollBegan: hideMenus,
                    initialBlock: article.lastReadBlockIndex,
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
                        ReaderTopMenu(
                            fontFamily: $fontFamily, fontSize: $fontSize, lineSpacing: $lineSpacing,
                            margins: $margins, theme: $theme, darkLevel: $darkLevel
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
                                PlayerBar(session: session)
                            }
                        }
                        .padding(.bottom, showsBottomBar ? 0 : 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .environment(\.floatingTint, Color(style.backgroundColor))
                .animation(.easeInOut(duration: 0.22), value: showsTopBar)
                .animation(.easeInOut(duration: 0.22), value: showsBottomBar)
                .animation(.default, value: session.failure)
                .sheet(isPresented: $isShowingSettings, onDismiss: { settingsClosed(session) }) {
                    // Only opened from the error banner, where the fix is a voice or an API key.
                    SettingsView(opensVoicePage: true)
                }
                .sheet(item: $translation) { model in
                    TranslationView(model: model)
                        .presentationDetents([.medium, .large])
                }

                savedWordsPanel(session: session)
            }
        }
        .background(Color(style.backgroundColor).ignoresSafeArea())
        .background(SwipeBackEnabler(isEnabled: !isShowingSavedWords))
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
            // Save now rather than waiting for autosave, so the position survives the app being killed.
            try? article.modelContext?.save()
        }
    }

    // MARK: - Saved words panel

    /// The saved words slide in from the right (after a left swipe) and fill the screen; the close button or a
    /// swipe to the right puts them away.
    private func savedWordsPanel(session: ReadingSession) -> some View {
        ZStack(alignment: .trailing) {
            if isShowingSavedWords {
                SavedWordsView(article: article, onLookUp: { saved in
                    let request = WordLookupRequest(
                        word: saved.word, term: saved.term,
                        hasDefinition: DictionaryLookup.system.hasDefinition(saved.term), sentence: saved.sentence
                    )
                    session.pause()
                    DictionaryPresenter.present(request, saving: saving(for: request))
                }, onClose: closeSavedWords)
                .gesture(
                    DragGesture(minimumDistance: 20).onEnded { drag in
                        if drag.translation.width > 80, abs(drag.translation.width) > abs(drag.translation.height) {
                            closeSavedWords()
                        }
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isShowingSavedWords)
    }

    private func closeSavedWords() {
        isShowingSavedWords = false
    }

    // MARK: - Menus

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
        self.session = session
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
        // Like looking up a word: reading pauses, and stays paused until Play is pressed.
        session.pause()
        translation = PassageTranslationModel(text: text)
    }

    private func lookUpWord(at range: NSRange, in document: ArticleDocument, pausing session: ReadingSession) {
        guard let context = document.context(for: range) else { return }
        let request = DictionaryLookup.system.request(forWordAt: context.wordRange, in: context.text)
        Log.lookup.info("""
            Tapped \(request.word, privacy: .public) -> term \(request.term, privacy: .public), \
            hasDefinition: \(request.hasDefinition, privacy: .public)
            """)
        // Looking up pauses reading; it stays paused after the dictionary closes until Play is pressed.
        session.pause()
        DictionaryPresenter.present(request, saving: saving(for: request))
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
