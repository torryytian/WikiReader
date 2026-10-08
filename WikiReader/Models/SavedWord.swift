import Foundation

/// A word the reader saved from the dictionary screen, with the sentence it was found in.
/// Belongs to one article: each article keeps its own list.
struct SavedWord: Codable, Identifiable, Equatable, Sendable {
    /// The word as it appeared in the text, e.g. "studies".
    var word: String
    /// What the dictionary was asked for, e.g. "study". Two taps that resolve to the same term are one entry.
    var term: String
    /// The sentence (or paragraph, for text without sentence breaks) containing the word.
    var sentence: String
    var savedAt: Date
    /// A short Chinese gloss, from an AI explanation the reader asked for. Nil until then.
    var meaning: String?

    var id: String { Self.key(for: term) }

    static func key(for term: String) -> String {
        term.lowercased()
    }
}

extension Article {
    /// Saved words, newest first. Stored as JSON in one field, like the blocks, so the schema stays simple.
    var savedWords: [SavedWord] {
        get {
            (try? JSONDecoder().decode([SavedWord].self, from: savedWordsData)) ?? []
        }
        set {
            savedWordsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    func isSaved(term: String) -> Bool {
        let key = SavedWord.key(for: term)
        return savedWords.contains { $0.id == key }
    }

    /// Saves the word if it isn't saved yet, otherwise removes it. Returns whether it is saved afterwards.
    @discardableResult
    func toggleSavedWord(_ request: WordLookupRequest, meaning: String? = nil, at date: Date = .now) -> Bool {
        var words = savedWords
        let key = SavedWord.key(for: request.term)
        if let index = words.firstIndex(where: { $0.id == key }) {
            words.remove(at: index)
            savedWords = words
            return false
        }
        words.insert(SavedWord(word: request.word, term: request.term, sentence: request.sentence, savedAt: date, meaning: meaning), at: 0)
        savedWords = words
        return true
    }

    /// Attaches a meaning to a saved word. Does nothing if the word isn't saved (any more).
    func setMeaning(_ meaning: String, forTerm term: String) {
        var words = savedWords
        let key = SavedWord.key(for: term)
        guard let index = words.firstIndex(where: { $0.id == key }) else { return }
        words[index].meaning = meaning
        savedWords = words
    }

    func removeSavedWord(id: SavedWord.ID) {
        savedWords = savedWords.filter { $0.id != id }
    }
}
