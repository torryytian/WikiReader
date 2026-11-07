import CryptoKit
import Foundation
import Observation
import OSLog

/// The saved-word book: one for the whole library, the same as the Chrome extension's (docs/shared-vocab-format.md).
/// Kept on this iPhone as `Application Support/Vocabulary.json`, in exactly the shared format, and kept in step with
/// English Reader by `VocabSiteSync` when signed in there, otherwise with Google Drive's copy by `VocabSync`.
///
/// Saving a word records the sentence and article it was found in. Removing a word, from anywhere, deletes it for
/// good on every device (a tombstone): the book is global, and "I know this one now" is the same as deleting it.
///
/// A book belongs to one account (`owner`, the first one it is synced with, Google's or English Reader's: an address
/// either way), so two accounts' words never mix: signing in as someone else sets this book aside and brings out
/// that account's own (`belong(to:)`).
@Observable
final class VocabularyBook {
    static let shared = VocabularyBook()

    private(set) var file: VocabFile
    /// Bumped by every change, so the reader marks the text again and the sync knows there is something to send.
    private(set) var version = 0
    /// The account (lowercased address) this book is kept in step with; nil until the first sync. Words saved
    /// while signed out belong to it too. Kept beside the book, not in it: the book's file is what goes to Drive.
    private(set) var owner: String?
    /// Called after a change made here (not after a sync brought one in), to schedule a sync.
    @ObservationIgnored var onLocalChange: (() -> Void)?
    /// Called with the same changes' words, for the site, which is told about each word rather than sent the whole book.
    @ObservationIgnored var onLocalKeysChange: ((Set<String>) -> Void)?

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
        file = Self.read(fileURL) ?? VocabFile()
        owner = (try? String(contentsOf: Self.ownerURL(of: fileURL), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The book in `url`, or nil if there is none. An unreadable one is set aside rather than overwritten, so
    /// nothing is lost for good.
    private static func read(_ url: URL) -> VocabFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try VocabFile.decode(data)
        } catch {
            Log.app.error("Vocabulary: unreadable book set aside: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("unreadable.json"))
            return nil
        }
    }

    private static func ownerURL(of fileURL: URL) -> URL {
        fileURL.appendingPathExtension("owner")
    }

    /// Where another account's book waits while this one is in use: `Vocabulary-<hash of the account>.json`.
    func setAsideURL(for account: String) -> URL {
        let hash = SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appending(path: "\(name)-\(hash).json")
    }

    // MARK: - Accounts

    /// Makes this the book of `account` (a lowercased address), before syncing with that account's copy. The first
    /// account keeps the book as it is. Another one gets its own: the book it had here before, or an empty one, while
    /// the current book is set aside for its owner to get back. Returns whether the book was swapped.
    @discardableResult
    func belong(to account: String) -> Bool {
        guard owner != account else { return false }
        guard let previous = owner else {
            setOwner(account)
            Log.app.info("Vocabulary: the book now belongs to the signed-in Google account")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.encoded().write(to: setAsideURL(for: previous), options: .atomic)
        } catch {
            // Not swapped: better to keep syncing the old book than to lose it.
            Log.app.error("Vocabulary: couldn't set the book aside: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let waiting = setAsideURL(for: account)
        file = Self.read(waiting) ?? VocabFile()
        try? FileManager.default.removeItem(at: waiting)
        setOwner(account)
        Log.app.info("Vocabulary: another Google account; its own book is in use (\(self.file.entries.count) words)")
        changed(locally: false)
        return true
    }

    private func setOwner(_ account: String) {
        owner = account
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(account.utf8).write(to: Self.ownerURL(of: fileURL), options: .atomic)
        } catch {
            Log.app.error("Vocabulary: couldn't save the book's account: \(error.localizedDescription, privacy: .public)")
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
        changed(locally: true, keys: [key])
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

    /// Words and deletions from English Reader, by the shared merge. Nothing happens if they say nothing new: the
    /// site's answers come every few seconds, often echoing what went up, and the reader marks its text again on every
    /// change.
    func applyFromSite(entries: [VocabEntry], deleted: [String: Int64]) {
        guard !entries.isEmpty || !deleted.isEmpty else { return }
        let merged = VocabFormat.merge(file, VocabFile(entries: entries, deleted: deleted), now: VocabFormat.milliseconds(now()), by: "ios")
        guard !VocabFormat.sameContent(merged, file) else { return }
        replace(with: merged)
    }

    private func store(_ entry: VocabEntry) {
        if let index = file.entries.firstIndex(where: { $0.key == entry.key }) {
            file.entries[index] = entry
        } else {
            file.entries.append(entry)
        }
        changed(locally: true, keys: [entry.key])
    }

    /// The words that differ between two versions of the book.
    private static func changedKeys(from old: VocabFile, to new: VocabFile) -> Set<String> {
        let before = Dictionary(old.entries.map { ($0.key, $0) }) { first, _ in first }
        var keys = Set(new.entries.filter { before[$0.key] != $0 }.map(\.key))
        keys.formUnion(new.deleted.keys.filter { old.deleted[$0] != new.deleted[$0] })
        return keys
    }

    private func changed(locally: Bool, keys: Set<String> = []) {
        file.updatedAt = VocabFormat.milliseconds(now())
        file.updatedBy = "ios"
        version += 1
        save()
        if locally {
            onLocalChange?()
            onLocalKeysChange?(keys)
        }
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
        let keys = Self.changedKeys(from: file, to: merged)
        file = merged
        changed(locally: true, keys: keys)
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
        let keys = Self.changedKeys(from: file, to: merged)
        file = merged
        Log.app.info("Vocabulary: moved \(incoming.count) words from the articles' lists into the book")
        changed(locally: true, keys: keys)
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
