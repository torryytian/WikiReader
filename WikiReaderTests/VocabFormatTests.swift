import Foundation
import Testing
@testable import WikiReader

/// The shared saved-word format (docs/shared-vocab-format.md), checked against the vectors the Chrome extension
/// runs too (Fixtures/shared/vocab/).
struct VocabFormatTests {
    private struct NormalizeVector: Decodable {
        var input: String
        var key: String
        var sentence: String
        var id: String
    }

    private struct TermVector: Decodable {
        var word: String
        var term: String
        var key: String
        var lemma: String?
        var group: String
    }

    private struct MatchVectors: Decodable {
        struct Case: Decodable {
            var word: String
            var result: String
        }
        var keys: [String]
        var cases: [Case]
    }

    private struct MergeVector: Decodable {
        var name: String
        var now: Int64
        var local: VocabFile
        var remote: VocabFile?
        var expected: JSONValue
    }

    private static let lemmas = DictionaryDatabase.bundled.lemmaTable()

    @Test func normalizeAndSentenceIDs() throws {
        let vectors = try JSONDecoder().decode([NormalizeVector].self, from: Fixture.data("normalize"))
        #expect(vectors.count >= 15)
        for vector in vectors {
            // Code point by code point: Swift's == would call "e\u{301}" and "é" equal.
            #expect(Array(VocabFormat.normalize(vector.input).unicodeScalars) == Array(vector.key.unicodeScalars), "\(vector.input)")
            #expect(Array(VocabFormat.normalize(vector.input, lowercase: false).unicodeScalars) == Array(vector.sentence.unicodeScalars), "\(vector.input)")
            #expect(VocabFormat.contextID(of: vector.input) == vector.id, "\(vector.input)")
        }
    }

    @Test func termKeyAndLemmaComeFromTheDictionary() throws {
        let vectors = try JSONDecoder().decode([TermVector].self, from: Fixture.data("term_key"))
        #expect(Self.lemmas.count > 50_000)
        let matcher = VocabMatcher(keys: [], lemmas: Self.lemmas, version: 1)
        for vector in vectors {
            let term = VocabTerms.term(for: vector.word, contains: DictionaryDatabase.bundled.contains)
            #expect(term == vector.term, "\(vector.word)")
            let key = VocabFormat.normalize(term)
            #expect(key == vector.key, "\(vector.word)")
            #expect(Self.lemmas[key] == vector.lemma, "\(vector.word)")
            #expect(matcher.group(of: key) == vector.group, "\(vector.word)")
        }
    }

    @Test func savedAndRelatedWords() throws {
        let vectors = try JSONDecoder().decode(MatchVectors.self, from: Fixture.data("match"))
        let matcher = VocabMatcher(keys: vectors.keys, lemmas: Self.lemmas, version: 1)
        for vector in vectors.cases {
            // The rule itself: the key of the word's term.
            let term = VocabTerms.term(for: vector.word, contains: DictionaryDatabase.bundled.contains)
            let byTerm = vector.word.contains(where: \.isLetter) ? matcher.match(key: VocabFormat.normalize(term)) : nil
            #expect((byTerm?.rawValue ?? "none") == vector.result, "\(vector.word)")
            // The reader's quick version, without asking the dictionary, agrees on these.
            #expect((matcher.match(word: vector.word)?.rawValue ?? "none") == vector.result, "\(vector.word) (quick)")
        }
    }

    @Test func mergeVectorsGiveTheExpectedBookEitherWayRound() throws {
        let vectors = try JSONDecoder().decode([MergeVector].self, from: Fixture.data("merge"))
        #expect(vectors.count >= 12)
        for vector in vectors {
            let merged = VocabFormat.merge(vector.local, vector.remote, now: vector.now, by: "ios")
            #expect(merged.updatedAt == vector.now && merged.updatedBy == "ios", "\(vector.name)")
            #expect(try Self.comparable(merged) == vector.expected, "\(vector.name)")
            if let remote = vector.remote {
                let swapped = VocabFormat.merge(remote, vector.local, now: vector.now, by: "ios")
                #expect(try Self.comparable(swapped) == vector.expected, "\(vector.name) (swapped)")
                // Merging the result again changes nothing.
                let again = VocabFormat.merge(merged, remote, now: vector.now, by: "ios")
                #expect(VocabFormat.sameContent(again, merged), "\(vector.name) (idempotent)")
            }
        }
    }

    @Test func aFileRoundTripsWithFieldsThisVersionDoesNotKnow() throws {
        let json = #"{"formatVersion":2,"updatedAt":5,"updatedBy":"chrome","future":[1,2.5,null,"x"],"entries":[{"key":"k","term":"K","forms":["K"],"createdAt":1,"updatedAt":2,"contexts":[{"id":"0000000000000001","sentence":"S.","url":"u","title":"t","savedAt":1,"x":{"y":true}}],"chrome":{"explanation":{"pos":"n.","examples":[]},"dict":null}}],"deleted":{"gone":3}}"#
        let file = try VocabFile.decode(Data(json.utf8))
        let written = try VocabFile.decode(file.encoded())
        #expect(written == file)
        #expect(file.entries.first?.other["chrome"] == .object(["explanation": .object(["pos": .string("n."), "examples": .array([])]), "dict": .null]))
        #expect(file.other["future"] == .array([.int(1), .double(2.5), .null, .string("x")]))
        #expect(file.entries.first?.contexts.first?.other["x"] == .object(["y": .bool(true)]))
    }

    @Test func aVersionOneFileIsReadOnlyForItsVersion() throws {
        let v1 = #"{"formatVersion":1,"app":"chrome","updatedAt":5,"entries":[{"word":"studies","display":"studies","contexts":[],"createdAt":1,"updatedAt":2}],"deleted":{}}"#
        let file = try VocabFile.decode(Data(v1.utf8))
        #expect(file.formatVersion == 1)
        #expect(file.entries.isEmpty)
    }

    /// The merged book as the vectors' `expected`: without the time and writer of the file.
    private static func comparable(_ file: VocabFile) throws -> JSONValue {
        guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: file.encoded()) else { return .null }
        object["updatedAt"] = nil
        object["updatedBy"] = nil
        return .object(object)
    }
}
