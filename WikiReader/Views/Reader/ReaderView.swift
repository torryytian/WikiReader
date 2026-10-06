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
        ArticleTextView(document: document)
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
    }
}
