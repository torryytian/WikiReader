import SwiftUI

/// The full-screen panel that slides in from the right: the word book while reading. "In This Article" lists the
/// saved words that appear in the text (wherever they were saved, the Chrome extension included); "All" is the
/// whole book. Tap a word to open its dictionary entry; swipe to delete it, everywhere. A word without a meaning
/// has a button that asks AI for one, only when pressed.
struct SavedWordsView: View {
    let articleURL: URL
    /// Keys of the saved words that appear in this article, as they are or in another form.
    let keysInArticle: Set<String>
    let onLookUp: (VocabEntry) -> Void
    let onClose: () -> Void
    @State private var book = VocabularyBook.shared
    @State private var meanings = MeaningFetcher()
    @State private var scope = Scope.article

    private enum Scope: Hashable {
        case article
        case all
    }

    private var words: [VocabEntry] {
        scope == .all ? book.entries : book.entries.filter { keysInArticle.contains($0.key) }
    }

    var body: some View {
        let words = words
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Words", selection: $scope) {
                    Text("In This Article").tag(Scope.article)
                    Text("All \(book.count)").tag(Scope.all)
                }
                .pickerStyle(.segmented)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            List {
                ForEach(words) { entry in
                    Button {
                        onLookUp(entry)
                    } label: {
                        VocabEntryRow(entry: entry, meanings: meanings, articleURL: articleURL)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for offset in offsets { book.delete(key: words[offset].key) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if words.isEmpty {
                    ContentUnavailableView(
                        scope == .article ? "No Saved Words Here" : "No Saved Words",
                        systemImage: "character.book.closed",
                        description: Text(scope == .article
                            ? "Saved words that appear in this article show here, wherever you saved them. Tap a word, then the bookmark in the dictionary, to save it."
                            : "Tap a word, then the bookmark in the dictionary, to save it.")
                    )
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}
