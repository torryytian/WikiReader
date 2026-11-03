import Foundation
import Observation
import OSLog

/// The saved-word book: one for the whole library, the same as the Chrome extension's (docs/shared-vocab-format.md).
/// Kept on this iPhone as `Application Support/Vocabulary.json`, in exactly the shared format, and merged with
/// Google Drive's copy by `VocabSync`.
///
/// Saving a word records the sentence and article it was found in. Removing a word, from anywhere, deletes it for
/// good on every device (a tombstone): the book is global, and "I know this one now" is the same as deleting it.
@Observable
final class VocabularyBook {
    static let shared = VocabularyBook()

    private(set) var file: VocabFile
    /// Bumped by every change, so the reader marks the text again and the sync knows there is something to send.
    private(set) var version = 0
    /// Called after a change made here (not after a sync brought one in), to schedule a sync.
    @ObservationIgnored var onLocalChange: (() -> Void)?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let lemmaOf: (String) -> String?

    init(
        fileURL: URL = URL.applicationSupportDirectory.appending(path: "Vocabulary.json"),
        now: @escaping () -> Date = Date.init,
        lemmaOf: @escaping (String) -> String? = { DictionaryDatabase.bundled.lemma(of: $0) }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.lemmaOf = lemmaOf
        if let data = try? Data(contentsOf: fileURL) {
            do {
                file = try VocabFile.decode(data)
            } catch {
                // Kept aside rather than overwritten, so nothing is lost for good.
                Log.app.error("Vocabulary: unreadable book set aside: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.moveItem(at: fileURL, to: fileURL.deletingPathExtension().appendingPathExtension("unreadable.json"))
                file = VocabFile()
            }
        } else {
            file = VocabFile()
        }
    }

    /// Newest first.
    var entries: [VocabEntry] {
        file.entries.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : VocabFormat.precedes($0.key, $1.key) }
    }

    var count: Int { file.entries.count }

    var keys: Set<String> { Set(file.entries.map(\.key)) }

    func entry(forKey key: String) -> VocabEntry? {
        file.entries.first { $0.key == key }
    }

    func entry(forTerm term: String) -> VocabEntry? {
        entry(forKey: VocabFormat.normalize(term))
    }

    func isSaved(term: String) -> Bool {
        entry(forTerm: term) != nil
    }

    /// The words saved from one article.
    func entries(savedFrom url: URL) -> [VocabEntry] {
        let url = url.absoluteString
        return entries.filter { $0.contexts.contains { $0.url == url } }
    }

    // MARK: - Changes

    /// Saves a word met in an article, or adds this sentence to it if it is saved already.
    @discardableResult
    func save(word: String, term: String, sentence: String, url: URL, title: String, meaning: String? = nil) -> VocabEntry {
        let time = VocabFormat.milliseconds(now())
        let key = VocabFormat.normalize(term)
        let context = VocabContext(
            id: VocabFormat.contextID(of: sentence), sentence: sentence, url: url.absoluteString, title: title,
            savedAt: time, meaning: meaning
        )
        var entry = entry(forKey: key) ?? VocabEntry(
            key: key, term: term, lemma: lemmaOf(key), forms: [], createdAt: time, updatedAt: time, meaning: meaning, contexts: []
        )
        if let index = entry.contexts.firstIndex(where: { $0.id == context.id }) {
            entry.contexts[index].savedAt = time
            if let meaning { entry.contexts[index].meaning = meaning }
        } else {
            entry.contexts.append(context)
        }
        if !entry.forms.contains(where: { $0.unicodeScalars.elementsEqual(word.unicodeScalars) }) {
            entry.forms.append(word)
        }
        if entry.meaning == nil { entry.meaning = meaning }
        entry.updatedAt = time
        file.deleted[key] = nil
        store(entry)
        Log.app.info("Vocabulary: saved a word (\(self.file.entries.count) in the book)")
        return entry
    }

    /// Deletes a word everywhere: here now, on other devices at their next sync.
    func delete(key: String) {
        guard let index = file.entries.firstIndex(where: { $0.key == key }) else { return }
        file.entries.remove(at: index)
        file.deleted[key] = VocabFormat.milliseconds(now())
        changed(locally: true)
    }

    /// The dictionary's bookmark button: saves the word, or deletes it if it is saved. Returns whether it is saved after.
    @discardableResult
    func toggle(_ request: WordLookupRequest, url: URL, title: String, meaning: String? = nil) -> Bool {
        if let saved = entry(forTerm: request.term) {
            delete(key: saved.key)
            return false
        }
        save(word: request.word, term: request.term, sentence: request.sentence, url: url, title: title, meaning: meaning)
        return true
    }

    /// Attaches the AI's short gloss: to the sentence it was made for, and to the word if it has none yet.
    func setMeaning(_ meaning: String, term: String, sentence: String? = nil) {
        guard var entry = entry(forTerm: term) else { return }
        if let sentence, let index = entry.contexts.firstIndex(where: { $0.id == VocabFormat.contextID(of: sentence) }) {
            entry.contexts[index].meaning = meaning
        }
        if entry.meaning == nil { entry.meaning = meaning }
        entry.updatedAt = VocabFormat.milliseconds(now())
        store(entry)
    }

    /// The book after a sync: `merged` already includes everything that was here.
    func replace(with merged: VocabFile) {
        guard merged != file else { return }
        file = merged
        changed(locally: false)
    }

    private func store(_ entry: VocabEntry) {
        if let index = file.entries.firstIndex(where: { $0.key == entry.key }) {
            file.entries[index] = entry
        } else {
            file.entries.append(entry)
        }
        changed(locally: true)
    }

    private func changed(locally: Bool) {
        file.updatedAt = VocabFormat.milliseconds(now())
        file.updatedBy = "ios"
        version += 1
        save()
        if locally { onLocalChange?() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.encoded().write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Vocabulary: saving failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds another copy of the book (a backup's) by the shared merge: a word deleted here since stays deleted.
    func merge(_ other: VocabFile) {
        guard other.formatVersion == VocabFile.currentVersion else { return }
        let merged = VocabFormat.merge(file, other, now: VocabFormat.milliseconds(now()), by: "ios")
        guard !VocabFormat.sameContent(merged, file) else { return }
        file = merged
        changed(locally: true)
    }

    // MARK: - Moving in the per-article lists

    /// Words saved before the book was global, from each article's own list. The lists are left in place (an
    /// older build still reads them); a word deleted from the book since stays deleted, its tombstone being newer.
    func importArticleWords(_ articles: [(url: URL, title: String, words: [SavedWord])]) {
        var incoming: [String: VocabEntry] = [:]
        for article in articles {
            for word in article.words {
                let time = VocabFormat.milliseconds(word.savedAt)
                let key = VocabFormat.normalize(word.term)
                let entry = VocabEntry(
                    key: key, term: word.term, lemma: lemmaOf(key), forms: [word.word], createdAt: time, updatedAt: time,
                    meaning: word.meaning,
                    contexts: [VocabContext(
                        id: VocabFormat.contextID(of: word.sentence), sentence: word.sentence, url: article.url.absoluteString,
                        title: article.title, savedAt: time, meaning: word.meaning
                    )]
                )
                incoming[key] = incoming[key].map { VocabFormat.mergeEntry($0, entry) } ?? entry
            }
        }
        guard !incoming.isEmpty else { return }
        let merged = VocabFormat.merge(file, VocabFile(entries: Array(incoming.values)), now: VocabFormat.milliseconds(now()), by: "ios")
        guard !VocabFormat.sameContent(merged, file) else { return }
        file = merged
        Log.app.info("Vocabulary: moved \(incoming.count) words from the articles' lists into the book")
        changed(locally: true)
    }

    /// Once per device: the per-article lists into the book.
    func importArticleWordsOnce(_ articles: [Article], defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: SettingsKeys.vocabularyImported) else { return }
        importArticleWords(articles.map { (url: $0.sourceURL, title: $0.title, words: $0.savedWords) })
        defaults.set(true, forKey: SettingsKeys.vocabularyImported)
    }

    // MARK: - Matching

    /// What the reader marks: these words, and other forms of them through `lemmas`.
    func matcher(lemmas: [String: String]) -> VocabMatcher {
        VocabMatcher(keys: keys, lemmas: lemmas, version: version &* 31 &+ lemmas.count)
    }
}
