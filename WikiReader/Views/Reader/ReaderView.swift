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
    @State private var wordCard: WordCard?
    @AppStorage(SettingsKeys.speechRate) private var rateValue = SpeechRate.normal.rawValue

    var body: some View {
        Group {
            if let document, let session {
                ArticleTextView(
                    document: document,
                    spokenWord: session.spokenWord.flatMap { document.textRange(of: $0.range, inBlock: $0.block) },
                    spokenBlock: session.spokenWord?.block,
                    onWordTapped: { lookUpWord(at: $0, in: document, pausing: session) },
                    onBlockLongPressed: { block in
                        Log.speech.info("Long press: start at block \(block)")
                        session.start(at: block)
                    },
                    initialBlock: article.lastReadBlockIndex,
                    onScrollSettled: { block in
                        // Scrolling only moves the reading position when nothing is being read.
                        session.moveWhileStopped(to: block)
                    }
                )
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // One opaque bottom area, so article text scrolling underneath never shows through.
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
                        PlayerBar(session: session)
                    }
                    .background(.bar)
                    .animation(.default, value: session.failure)
                }
                .sheet(isPresented: $isShowingSettings, onDismiss: { settingsClosed(session) }) {
                    SettingsView()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $wordCard) { card in
            WordCardView(request: card.request, voiceIdentifier: voiceIdentifier)
        }
        .onChange(of: session?.rate) { _, rate in
            // The player's speed is also the default for next time.
            if let rate { rateValue = rate.rawValue }
        }
        .onAppear(perform: prepare)
        .onDisappear {
            session?.stop()
            // Save now rather than waiting for autosave, so the position survives the app being killed.
            try? article.modelContext?.save()
        }
    }

    private func prepare() {
        guard document == nil else { return }
        let blocks = article.blocks
        document = ArticleDocument(title: article.title, blocks: blocks)

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

    private func lookUpWord(at range: NSRange, in document: ArticleDocument, pausing session: ReadingSession) {
        guard let context = document.context(for: range) else { return }
        let request = DictionaryLookup.system.request(forWordAt: context.wordRange, in: context.text)
        Log.lookup.info("""
            Tapped \(request.word, privacy: .public) -> term \(request.term, privacy: .public), \
            hasDefinition: \(request.hasDefinition, privacy: .public)
            """)
        // Looking up pauses reading; it stays paused after the card closes until Play is pressed.
        session.pause()
        wordCard = WordCard(request: request)
    }
}
