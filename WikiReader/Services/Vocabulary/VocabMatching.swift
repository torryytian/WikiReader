import Foundation
import Observation

/// How a word in the text relates to the saved-word book (docs/shared-vocab-format.md §4).
nonisolated enum VocabMatch: String, Equatable, Sendable {
    /// It is a saved word.
    case saved
    /// Another form of a saved word: the same dictionary base form ("studied" when "studies" is saved).
    case related
}

/// Decides, for any word, whether it is saved or a form of a saved word, the same way the Chrome extension does.
nonisolated struct VocabMatcher: Sendable, Equatable {
    let keys: Set<String>
    /// `group(key)` of every saved word.
    let groups: Set<String>
    /// Lower-cased word → its dictionary base form (`DictionaryDatabase.lemmaTable()`).
    private let lemmas: [String: String]
    /// Changes whenever the words or the lemma table do, so the reader knows to mark the text again.
    let version: Int

    static let empty = VocabMatcher(keys: [], lemmas: [:], version: 0)

    init(keys: some Sequence<String>, lemmas: [String: String], version: Int) {
        let keys = Set(keys)
        self.keys = keys
        self.lemmas = lemmas
        self.version = version
        groups = Set(keys.map { lemmas[$0] ?? $0 })
    }

    static func == (a: VocabMatcher, b: VocabMatcher) -> Bool {
        a.version == b.version && a.keys == b.keys && a.lemmas.count == b.lemmas.count
    }

    /// `lemma(key) ?? key` (§4).
    func group(of key: String) -> String {
        lemmas[key] ?? key
    }

    /// The match of a word whose key is `key` (`VocabFormat.normalize(term)`).
    func match(key: String) -> VocabMatch? {
        if keys.contains(key) { return .saved }
        return groups.contains(group(of: key)) ? .related : nil
    }

    /// The match of a word as it stands in the text. The term rule asks the dictionary which candidate it knows;
    /// marking a whole article that way would ask it thousands of times, so this takes the word itself, or without
    /// its possessive. ECDICT has nearly every inflected form, so that is the term in all but rare cases (a word
    /// the dictionary only knows through NLTagger's lemma).
    func match(word: some StringProtocol) -> VocabMatch? {
        guard !keys.isEmpty, word.contains(where: \.isLetter) else { return nil }
        let text = String(word)
        let key = VocabFormat.normalize(text)
        if keys.contains(key) { return .saved }
        let base = VocabFormat.normalize(DictionaryLookup.removingPossessive(text))
        if base != key, keys.contains(base) { return .saved }
        return groups.contains(group(of: base)) ? .related : nil
    }
}

/// The term and key of a word, and the dictionary's base forms (§3.1, §4).
nonisolated enum VocabTerms {
    /// The term for a word: the first of its candidates the dictionary contains, else the word (§3.1).
    static func term(for word: String, lemma: String? = nil, contains: (String) -> Bool) -> String {
        DictionaryLookup.candidates(word: word, lemma: lemma).first(where: contains) ?? word
    }

    /// The base form the dictionary gives for a key ("studies" → "study"), or nil.
    static func lemma(ofKey key: String, in table: [String: String]) -> String? {
        table[key]
    }
}

/// The dictionary's whole lemma table, read once in the background (about 58,000 rows).
@Observable
final class VocabLemmas {
    static let shared = VocabLemmas()

    private(set) var table: [String: String] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?

    var isLoaded: Bool { !table.isEmpty }

    func load(from database: DictionaryDatabase = .bundled) {
        guard table.isEmpty, loading == nil else { return }
        loading = Task {
            table = await Self.read(database)
        }
    }

    @concurrent
    private static func read(_ database: DictionaryDatabase) async -> [String: String] {
        database.lemmaTable()
    }
}
