import OSLog
import SwiftUI

struct ReaderView: View {
    let article: Article
    /// Built once per article: decoding blocks and laying out a long article isn't free.
    @State private var document: ArticleDocument

    init(article: Article) {
        self.article = article
        _document = State(initialValue: ArticleDocument(title: article.title, blocks: article.blocks))
    }

    var body: some View {
        ArticleTextView(document: document, onWordTapped: lookUpWord)
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
    }

    private func lookUpWord(at range: NSRange) {
        guard let context = document.context(for: range) else { return }
        let request = DictionaryLookup.system.request(forWordAt: context.wordRange, in: context.text)
        Log.lookup.info("""
            Tapped \(request.word, privacy: .public) -> term \(request.term, privacy: .public), \
            hasDefinition: \(request.hasDefinition, privacy: .public)
            """)
    }
}
