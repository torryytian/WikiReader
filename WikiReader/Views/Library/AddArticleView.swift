import OSLog
import SwiftData
import SwiftUI

/// Sheet for adding an article by link or title. Fetches, cleans and saves it,
/// then hands the saved article back so the library can open it.
struct AddArticleView: View {
    var onAdded: (Article) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var input = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Link or title", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($isInputFocused)
                        .disabled(isLoading)
                        .onSubmit(startImport)
                } footer: {
                    Text("For example: https://en.wikipedia.org/wiki/Albert_Einstein or Albert Einstein")
                }

                if isLoading {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Fetching article…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: startImport)
                        .disabled(isLoading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isInputFocused = true }
        }
        .interactiveDismissDisabled(isLoading)
    }

    private func startImport() {
        guard !isLoading else { return }
        errorMessage = nil
        isLoading = true
        let input = input
        Log.importing.info("Import started, input: \(input, privacy: .public)")
        importTask = Task {
            defer { isLoading = false }
            do {
                let imported = try await ArticleImporter().importArticle(from: input)
                guard !Task.isCancelled else {
                    Log.importing.info("Import cancelled: \(imported.title, privacy: .public)")
                    return
                }
                let article = try save(imported)
                dismiss()
                onAdded(article)
            } catch is CancellationError {
                Log.importing.info("Import cancelled")
            } catch {
                Log.importing.error("Import failed for input \(input, privacy: .public): \(String(describing: error), privacy: .public)")
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    /// Saves the article, or returns the existing one if an article with the same title is already saved.
    private func save(_ imported: ImportedArticle) throws -> Article {
        let title = imported.title
        let existing = try modelContext.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.title == title }))
        if let article = existing.first {
            Log.importing.info("Already saved, opening existing: \(title, privacy: .public)")
            return article
        }

        let article = Article(title: imported.title, sourceURL: imported.sourceURL, blocks: imported.blocks)
        modelContext.insert(article)
        try modelContext.save()
        Log.importing.info("Saved \(title, privacy: .public) with \(imported.blocks.count) blocks")
        return article
    }
}
