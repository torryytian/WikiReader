import SwiftUI

/// The words saved from one article, newest first. Tap a word to open its dictionary entry; swipe to remove it.
struct SavedWordsView: View {
    let article: Article
    let onLookUp: (SavedWord) -> Void
    @Environment(\.dismiss) private var dismiss

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
                            Text(saved.sentence)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
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
}
