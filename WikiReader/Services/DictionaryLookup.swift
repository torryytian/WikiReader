import NaturalLanguage
import OSLog
import UIKit

/// What the reader asks to look up after a word is tapped. Carries the sentence too,
/// so other kinds of lookup (e.g. an AI explanation) can be added without changing the reader.
nonisolated struct WordLookupRequest: Equatable, Sendable {
    /// The word as it appears in the text, e.g. "studies".
    var word: String
    /// The term to look up: the first candidate the dictionary knows, else `word`.
    var term: String
    /// Whether the dictionary has an entry for `term`.
    var hasDefinition: Bool
    /// The sentence containing the word.
    var sentence: String
}

/// Picks the term to look up for a tapped word: the word itself, then simpler forms of it
/// (without possessive, lowercased, lemma), using the first one the dictionary knows.
struct DictionaryLookup {
    /// Whether the dictionary has an entry for a term. Injected so tests don't depend on installed dictionaries.
    var hasDefinition: (String) -> Bool

    /// Uses the iOS system dictionaries (the ones enabled in Settings → General → Dictionary).
    static let system = DictionaryLookup { term in
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }

    /// - Parameters:
    ///   - range: The tapped word inside `text`.
    ///   - text: The paragraph containing the word; context makes lemmatization more accurate.
    func request(forWordAt range: Range<String.Index>, in text: String) -> WordLookupRequest {
        let word = String(text[range])
        let lemma = Self.lemma(forWordAt: range, in: text)
        let candidates = Self.candidates(word: word, lemma: lemma)
        let term = candidates.first(where: hasDefinition)
        return WordLookupRequest(
            word: word,
            term: term ?? word,
            hasDefinition: term != nil,
            sentence: Self.sentence(containing: range, in: text)
        )
    }

    /// Lookup candidates in order of preference, without duplicates.
    static func candidates(word: String, lemma: String?) -> [String] {
        let base = removingPossessive(word)
        var result: [String] = []
        for candidate in [word, base, base.lowercased(), lemma, lemma?.lowercased()] {
            if let candidate, !candidate.isEmpty, !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    /// True if a token is worth looking up: it contains at least one letter.
    /// Numbers ("1879"), punctuation and symbols are ignored.
    static func isLookupWord(_ token: some StringProtocol) -> Bool {
        token.contains(where: \.isLetter)
    }

    /// Asks the system to make the English lemma model available. On a fresh device it may still be
    /// downloading, and until then lemmas come back nil (lookup then just skips that candidate).
    static func prepareLemmaModel() {
        NLTagger.requestAssets(for: .english, tagScheme: .lemma) { result, error in
            if let error {
                Log.app.error("Lemma model unavailable: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.app.info("Lemma model status: \(result == .available ? "available" : "not available", privacy: .public)")
            }
        }
    }

    static func lemma(forWordAt range: Range<String.Index>, in text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma)
        return tag?.rawValue
    }

    static func sentence(containing range: Range<String.Index>, in text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let sentenceRange = tokenizer.tokenRange(at: range.lowerBound)
        guard !sentenceRange.isEmpty else { return text }
        return text[sentenceRange].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Einstein's" -> "Einstein", "parents'" -> "parents".
    static func removingPossessive(_ word: String) -> String {
        for suffix in ["'s", "’s", "'", "’"] where word.count > suffix.count && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }
}
