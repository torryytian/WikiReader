import SwiftData
import SwiftUI

/// Home screen: the list of saved articles, newest first.
struct LibraryView: View {
    @Query(sort: \Article.addedAt, order: .reverse) private var articles: [Article]
    @State private var path: [Article] = []
    @State private var isAddingArticle = false

    var body: some View {
        NavigationStack(path: $path) {
            List(articles) { article in
                NavigationLink(value: article) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title)
                            .font(.headline)
                        Text(article.addedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if articles.isEmpty {
                    ContentUnavailableView(
                        "No Articles",
                        systemImage: "books.vertical",
                        description: Text("Tap + to add a Wikipedia article.")
                    )
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Article.self) { article in
                ReaderView(article: article)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Article", systemImage: "plus") {
                        isAddingArticle = true
                    }
                }
            }
            .sheet(isPresented: $isAddingArticle) {
                AddArticleView { article in
                    path = [article]
                }
            }
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Article.self, inMemory: true)
}
