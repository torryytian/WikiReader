import SwiftUI

/// The whole word book, from the library's + menu: every saved word, newest first, searchable. Tap one for where
/// it was met; swipe to delete it (a word you know now is simply deleted, here and on every device).
struct WordBookView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var book = VocabularyBook.shared
    @State private var sync = VocabSync.shared
    @State private var account = GoogleAccount.shared
    @State private var meanings = MeaningFetcher()
    @State private var searchText = ""

    private var shown: [VocabEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return book.entries }
        return book.entries.filter {
            $0.term.localizedCaseInsensitiveContains(query) || ($0.meaning ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(shown) { entry in
                        NavigationLink {
                            WordDetailView(key: entry.key)
                        } label: {
                            VocabEntryRow(entry: entry, meanings: meanings)
                        }
                    }
                    .onDelete { offsets in
                        let entries = shown
                        for index in offsets { book.delete(key: entries[index].key) }
                    }
                } header: {
                    if !book.entries.isEmpty { Text(book.count == 1 ? "1 word" : "\(book.count) words") }
                } footer: {
                    if !book.entries.isEmpty { Text(syncText) }
                }
            }
            .searchable(text: $searchText, prompt: "Search words and meanings")
            .overlay {
                if book.entries.isEmpty {
                    ContentUnavailableView(
                        "No Saved Words",
                        systemImage: "character.book.closed",
                        description: Text("Tap a word while reading, then the bookmark in the dictionary, to save it here. \(syncText)")
                    )
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .refreshable { await sync.sync() }
            .navigationTitle("Word Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await sync.sync() }
        }
    }

    private var syncText: String {
        guard account.isSignedIn else {
            return "Sign in to Google Drive in Settings to share these words with your other devices and the Chrome extension."
        }
        switch sync.state {
        case .idle, .syncing:
            return "Syncing with Google Drive…"
        case .synced:
            return "Synced with Google Drive and the Chrome extension. Deleting a word deletes it there too."
        case .waitingForChrome:
            return "The word book in Google Drive is in the Chrome extension's old format. It syncs once the extension is updated."
        case .failed(let message):
            return "Couldn't sync with Google Drive: \(message)"
        }
    }
}

/// One saved word in full: its meaning, the spellings seen, and the sentences it was met in.
struct WordDetailView: View {
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var book = VocabularyBook.shared

    var body: some View {
        if let entry = book.entry(forKey: key) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.term)
                            .font(.title2.weight(.bold))
                        if let meaning = entry.meaning {
                            Text(meaning)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if let lemma = entry.lemma, VocabFormat.normalize(lemma) != entry.key {
                        LabeledContent("Base Form", value: lemma)
                    }
                    if entry.forms.count > 1 || entry.forms.first.map({ $0 != entry.term }) ?? false {
                        LabeledContent("Seen As", value: entry.forms.joined(separator: ", "))
                    }
                    LabeledContent("Saved", value: Date(timeIntervalSince1970: Double(entry.createdAt) / 1000).formatted(date: .abbreviated, time: .omitted))
                }
                Section("Sentences") {
                    ForEach(entry.contexts.reversed(), id: \.id) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.sentence)
                            if let meaning = context.meaning, meaning != entry.meaning {
                                Text(meaning)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text(context.title)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    Button("Delete Word", systemImage: "trash", role: .destructive) {
                        book.delete(key: key)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                } footer: {
                    Text("Delete a word once you know it. It is deleted on your other devices and in the Chrome extension too.")
                }
            }
            .navigationTitle(entry.term)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Word Deleted", systemImage: "character.book.closed")
        }
    }
}

/// A saved word in a list: the word, its meaning, and a button that asks AI for a meaning when it has none.
struct VocabEntryRow: View {
    let entry: VocabEntry
    let meanings: MeaningFetcher
    /// The article being read, whose sentence is the one to explain.
    var articleURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.term)
                        .font(.headline)
                    if let lemma = entry.lemma, VocabFormat.normalize(lemma) != entry.key {
                        Text(lemma)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let meaning = entry.meaning {
                    Text(meaning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.meaning == nil {
                meaningControl
            }
        }
        .padding(.vertical, 2)
        // The separator starts under the word, not under the Meaning button.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    @ViewBuilder
    private var meaningControl: some View {
        if meanings.loading.contains(entry.key) {
            ProgressView()
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    meanings.fetch(entry, preferring: articleURL)
                } label: {
                    Label("Meaning", systemImage: "sparkles")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                if let failure = meanings.failures[entry.key] {
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

/// Asks OpenAI for a saved word's short meaning, only when its button is pressed (nothing is sent because a list
/// opened), with the sentence it was saved in.
@Observable
final class MeaningFetcher {
    private(set) var loading: Set<String> = []
    private(set) var failures: [String: String] = [:]

    func fetch(_ entry: VocabEntry, preferring url: URL? = nil, book: VocabularyBook = .shared) {
        guard let apiKey = KeychainStore.openAIKey.read(), !apiKey.isEmpty else {
            failures[entry.key] = OpenAIChatError.missingKey.message
            return
        }
        let sentence = entry.context(preferring: url)?.sentence ?? entry.term
        let word = entry.forms.last ?? entry.term
        failures[entry.key] = nil
        loading.insert(entry.key)
        Task {
            defer { loading.remove(entry.key) }
            switch await Self.explain(word: word, sentence: sentence, apiKey: apiKey) {
            case .success(let explanation):
                book.setMeaning(explanation.meaning, term: entry.term, sentence: sentence)
            case .failure(let error):
                failures[entry.key] = error.message
            }
        }
    }

    /// A separate function, so the typed error from the client is caught where its type is known.
    private static func explain(word: String, sentence: String, apiKey: String) async -> Result<WordExplanation, OpenAIChatError> {
        do {
            return .success(try await OpenAIExplainClient().explain(word: word, sentence: sentence, apiKey: apiKey))
        } catch {
            return .failure(error)
        }
    }
}

extension VocabEntry {
    /// The sentence to show or explain: one from the article at `url` if there is one, else the latest.
    func context(preferring url: URL?) -> VocabContext? {
        if let url = url?.absoluteString, let here = contexts.last(where: { $0.url == url }) { return here }
        return contexts.max { $0.savedAt < $1.savedAt }
    }
}
