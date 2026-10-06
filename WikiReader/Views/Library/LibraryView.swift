import OSLog
import SwiftData
import SwiftUI

/// Home screen: the list of saved articles, newest first.
struct LibraryView: View {
    @Query(sort: \Article.addedAt, order: .reverse) private var articles: [Article]
    @Environment(\.modelContext) private var modelContext
    @State private var path: [Article] = []
    @State private var isAddingArticle = false
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(articles) { article in
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
                .onDelete { offsets in
                    Self.delete(offsets.map { articles[$0] }, from: modelContext)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }
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
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
        }
    }
}

extension LibraryView {
    static func delete(_ articles: [Article], from context: ModelContext) {
        for article in articles {
            Log.app.info("Deleting \(article.title, privacy: .public)")
            context.delete(article)
        }
        do {
            try context.save()
        } catch {
            Log.app.error("Saving after delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: Article.self, inMemory: true)
}
