import SwiftUI

/// The words saved from one article, newest first, each with a short Chinese meaning. Tap a word to open its
/// dictionary entry; swipe to remove it. A word without a meaning has a button that asks AI for one, and only
/// when pressed (nothing is sent just because the list opened).
struct SavedWordsView: View {
    let article: Article
    let onLookUp: (SavedWord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loading: Set<SavedWord.ID> = []
    @State private var failures: [SavedWord.ID: String] = [:]

    var body: some View {
        NavigationStack {
            let words = article.savedWords
            List {
                ForEach(words) { saved in
                    Button {
                        onLookUp(saved)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(saved.word)
                                .font(.headline)
                            if let meaning = saved.meaning {
                                Text(meaning)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .trailing) { meaningControl(for: saved) }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        article.removeSavedWord(id: words[offset].id)
                    }
                }
            }
            .overlay {
                if words.isEmpty {
                    ContentUnavailableView(
                        "No Saved Words",
                        systemImage: "bookmark",
                        description: Text("Tap a word, then the bookmark in the dictionary, to save it here.")
                    )
                }
            }
            .navigationTitle("Saved Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Trailing control for a word without a meaning: a button to get one, a spinner, or the reason it failed.
    @ViewBuilder
    private func meaningControl(for saved: SavedWord) -> some View {
        if saved.meaning == nil {
            if loading.contains(saved.id) {
                ProgressView()
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Button {
                        fetchMeaning(of: saved)
                    } label: {
                        Label("Meaning", systemImage: "sparkles")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    if let failure = failures[saved.id] {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func fetchMeaning(of saved: SavedWord) {
        guard let key = KeychainStore.openAIKey.read(), !key.isEmpty else {
            failures[saved.id] = OpenAIChatError.missingKey.message
            return
        }
        failures[saved.id] = nil
        loading.insert(saved.id)
        Task {
            defer { loading.remove(saved.id) }
            switch await Self.explain(saved, apiKey: key) {
            case .success(let explanation):
                article.setMeaning(explanation.meaning, forTerm: saved.term)
            case .failure(let error):
                failures[saved.id] = error.message
            }
        }
    }

    /// A separate function, so the typed error from the client is caught where its type is known.
    private static func explain(_ saved: SavedWord, apiKey: String) async -> Result<WordExplanation, OpenAIChatError> {
        do {
            return .success(try await OpenAIExplainClient().explain(word: saved.word, sentence: saved.sentence, apiKey: apiKey))
        } catch {
            return .failure(error)
        }
    }
}
