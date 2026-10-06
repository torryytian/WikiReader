import OSLog
import SwiftData
import SwiftUI

struct ReaderView: View {
    let article: Article
    // Created on first appearance rather than in init: SwiftUI may construct this view many
    // times, and laying out the article or starting a speech engine each time would be wasteful.
    @State private var document: ArticleDocument?
    @State private var session: ReadingSession?

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
                    PlayerBar(session: session)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
            engine: SystemSpeechEngine()
        )
        session.onBlockChange = { [article] block in
            article.lastReadBlockIndex = block
            Log.app.info("Reading position saved: block \(block)")
        }
        self.session = session
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
        DictionaryPresenter.present(request)
    }
}
