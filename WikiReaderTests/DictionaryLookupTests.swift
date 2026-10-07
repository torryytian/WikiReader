import Foundation
import Testing
@testable import WikiReader

@MainActor
struct DictionaryLookupTests {
    /// A fake dictionary that knows exactly these terms.
    private func lookup(knowing terms: Set<String>) -> DictionaryLookup {
        DictionaryLookup { terms.contains($0) }
    }

    /// Requests a lookup for the first occurrence of `word` in `text`.
    private func request(_ word: String, in text: String, knowing terms: Set<String>) throws -> WordLookupRequest {
        let range = try #require(text.range(of: word))
        return lookup(knowing: terms).request(forWordAt: range, in: text)
    }

    // MARK: - Lemmas

    @Test(arguments: [
        ("studies", "He studies physics at the university.", "study"),
        ("running", "She was running late for the lecture.", "run"),
        ("studied", "Einstein studied mathematics in Zurich.", "study"),
        ("children", "The children played outside.", "child"),
        ("theories", "Both theories were later confirmed.", "theory"),
    ])
    func lemma(word: String, text: String, expected: String) throws {
        let range = try #require(text.range(of: word))
        #expect(DictionaryLookup.lemma(forWordAt: range, in: text) == expected)
    }

    // MARK: - Choosing the term

    @Test func originalWordWinsWhenKnown() throws {
        let result = try request("studies", in: "He studies physics.", knowing: ["studies", "study"])
        #expect(result.term == "studies")
        #expect(result.hasDefinition)
    }

    @Test func fallsBackToLemma() throws {
        let result = try request("studies", in: "He studies physics.", knowing: ["study"])
        #expect(result.word == "studies")
        #expect(result.term == "study")
        #expect(result.hasDefinition)
    }

    @Test func capitalizedWordFallsBackToLowercase() throws {
        let text = "Running is good exercise."
        #expect(try request("Running", in: text, knowing: ["running"]).term == "running")
        #expect(try request("Running", in: text, knowing: ["run"]).term == "run")
    }

    @Test func possessiveIsRemoved() throws {
        #expect(try request("Einstein's", in: "Einstein's theory changed physics.", knowing: ["Einstein"]).term == "Einstein")
        #expect(try request("Einstein’s", in: "Einstein’s theory changed physics.", knowing: ["Einstein"]).term == "Einstein")
    }

    @Test func unknownWordIsLookedUpAsIs() throws {
        let result = try request("Asdfqwer", in: "The word Asdfqwer means nothing.", knowing: [])
        #expect(result.term == "Asdfqwer")
        #expect(!result.hasDefinition)
    }

    @Test func candidatesAreOrderedAndUnique() {
        #expect(DictionaryLookup.candidates(word: "Studies", lemma: "study") == ["Studies", "studies", "study"])
        #expect(DictionaryLookup.candidates(word: "run", lemma: "run") == ["run"])
        #expect(DictionaryLookup.candidates(word: "Einstein's", lemma: nil) == ["Einstein's", "Einstein", "einstein"])
    }

    // MARK: - Which tokens count as words

    @Test(arguments: ["physics", "E", "mc2", "Zürich", "don't"])
    func lookupWords(token: String) {
        #expect(DictionaryLookup.isLookupWord(token))
    }

    @Test(arguments: ["1879", "–", ",", "(", "105.4", "\"", " "])
    func nonWords(token: String) {
        #expect(!DictionaryLookup.isLookupWord(token))
    }

    // MARK: - Sentence context

    @Test func sentenceContainingWord() throws {
        let text = "Einstein was born in Ulm. He studies physics in Zurich. Later he moved to Berlin."
        let result = try request("studies", in: text, knowing: [])
        #expect(result.sentence == "He studies physics in Zurich.")
    }

    // MARK: - Base form shown on the word card

    @Test func baseFormIsShownWhenAnotherFormWasLookedUp() throws {
        // "Einstein's" has no entry of its own, so the form without the possessive is looked up instead.
        let result = try request("Einstein's", in: "Einstein's theory was confirmed.", knowing: ["Einstein"])
        #expect(result.baseForm == "Einstein")
    }

    @Test func baseFormIsHiddenWhenTheWordItselfWasLookedUp() throws {
        let result = try request("studies", in: "He studies physics.", knowing: ["studies"])
        #expect(result.baseForm == nil)
    }

    @Test func baseFormIgnoresCase() throws {
        // Sentence-initial "Physics" is looked up as "physics": same word, nothing to point out.
        let result = try request("Physics", in: "Physics is hard.", knowing: ["physics"])
        #expect(result.baseForm == nil)
    }

    @Test func baseFormIsHiddenWhenNothingWasFound() throws {
        let result = try request("Zzyzx", in: "Zzyzx is a place.", knowing: [])
        #expect(result.baseForm == nil)
    }
}
