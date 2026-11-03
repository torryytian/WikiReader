import CryptoKit
import Foundation

// The saved-word book shared with the Chrome extension through Google Drive (`WikiReader Cache/vocab.json`).
// docs/shared-vocab-format.md is the definition; everything here follows it word for word, and the shared test
// vectors in WikiReaderTests/Fixtures/shared/vocab/ check it on both sides.

/// One sentence a saved word was found in.
nonisolated struct VocabContext: Codable, Equatable, Sendable {
    /// `VocabFormat.contextID(of: sentence)`.
    var id: String
    var sentence: String
    /// The article's canonical URL (an imported article's `wikireader-import://` one included).
    var url: String
    var title: String
    /// Unix milliseconds.
    var savedAt: Int64
    /// What the word means in this sentence (the AI's short Chinese gloss).
    var meaning: String?
    /// Fields this version doesn't know, kept as they are.
    var other: [String: JSONValue] = [:]

    private static let known: Set<String> = ["id", "sentence", "url", "title", "savedAt", "meaning"]

    init(id: String, sentence: String, url: String, title: String, savedAt: Int64, meaning: String? = nil) {
        self.id = id
        self.sentence = sentence
        self.url = url
        self.title = title
        self.savedAt = savedAt
        self.meaning = meaning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        sentence = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("sentence")) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("url")) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("title")) ?? ""
        savedAt = try container.decodeIfPresent(Int64.self, forKey: AnyCodingKey("savedAt")) ?? 0
        meaning = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("meaning"))
        other = try container.otherFields(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(sentence, forKey: AnyCodingKey("sentence"))
        try container.encode(url, forKey: AnyCodingKey("url"))
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(savedAt, forKey: AnyCodingKey("savedAt"))
        try container.encodeIfPresent(meaning, forKey: AnyCodingKey("meaning"))
        try container.encode(otherFields: other)
    }
}

/// A saved word.
nonisolated struct VocabEntry: Codable, Equatable, Sendable, Identifiable {
    /// `VocabFormat.normalize(term)`: what makes two saves the same word.
    var key: String
    /// The word as shown, in the case of the text ("Einstein").
    var term: String
    /// The dictionary's base form of `term`, for showing only ("studies" → "study").
    var lemma: String?
    /// Spellings seen in the text.
    var forms: [String]
    var createdAt: Int64
    /// Changes with every change to the entry, a new sentence included.
    var updatedAt: Int64
    /// A short Chinese gloss.
    var meaning: String?
    var contexts: [VocabContext]
    /// Everything else: the Chrome extension's "chrome" data, an "ios" one, and fields of later versions.
    var other: [String: JSONValue] = [:]

    var id: String { key }

    private static let known: Set<String> = ["key", "term", "lemma", "forms", "createdAt", "updatedAt", "meaning", "contexts"]

    init(key: String, term: String, lemma: String? = nil, forms: [String], createdAt: Int64, updatedAt: Int64,
         meaning: String? = nil, contexts: [VocabContext]) {
        self.key = key
        self.term = term
        self.lemma = lemma
        self.forms = forms
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.meaning = meaning
        self.contexts = contexts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        key = try container.decode(String.self, forKey: AnyCodingKey("key"))
        term = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("term")) ?? key
        lemma = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("lemma"))
        forms = try container.decodeIfPresent([String].self, forKey: AnyCodingKey("forms")) ?? []
        createdAt = try container.decode(Int64.self, forKey: AnyCodingKey("createdAt"))
        updatedAt = try container.decode(Int64.self, forKey: AnyCodingKey("updatedAt"))
        meaning = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("meaning"))
        contexts = try container.decodeIfPresent([VocabContext].self, forKey: AnyCodingKey("contexts")) ?? []
        other = try container.otherFields(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(key, forKey: AnyCodingKey("key"))
        try container.encode(term, forKey: AnyCodingKey("term"))
        try container.encodeIfPresent(lemma, forKey: AnyCodingKey("lemma"))
        try container.encode(forms, forKey: AnyCodingKey("forms"))
        try container.encode(createdAt, forKey: AnyCodingKey("createdAt"))
        try container.encode(updatedAt, forKey: AnyCodingKey("updatedAt"))
        try container.encodeIfPresent(meaning, forKey: AnyCodingKey("meaning"))
        try container.encode(contexts, forKey: AnyCodingKey("contexts"))
        try container.encode(otherFields: other)
    }
}

/// The whole book, as in `vocab.json` (and this iPhone's copy of it).
nonisolated struct VocabFile: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var formatVersion = VocabFile.currentVersion
    /// Unix milliseconds of the last write.
    var updatedAt: Int64 = 0
    /// "ios" or "chrome", for finding out who wrote what.
    var updatedBy: String?
    var entries: [VocabEntry] = []
    /// Deleted words: key → when, in Unix milliseconds.
    var deleted: [String: Int64] = [:]
    var other: [String: JSONValue] = [:]

    private static let known: Set<String> = ["formatVersion", "updatedAt", "updatedBy", "entries", "deleted"]

    init(entries: [VocabEntry] = [], deleted: [String: Int64] = [:]) {
        self.entries = entries
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        formatVersion = try container.decode(Int.self, forKey: AnyCodingKey("formatVersion"))
        updatedAt = try container.decodeIfPresent(Int64.self, forKey: AnyCodingKey("updatedAt")) ?? 0
        updatedBy = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("updatedBy"))
        // A v1 file (Chrome's own) has different entries: only the version is read, and nothing is done with it.
        guard formatVersion == Self.currentVersion else { return }
        entries = try container.decodeIfPresent([VocabEntry].self, forKey: AnyCodingKey("entries")) ?? []
        deleted = try container.decodeIfPresent([String: Int64].self, forKey: AnyCodingKey("deleted")) ?? [:]
        other = try container.otherFields(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(formatVersion, forKey: AnyCodingKey("formatVersion"))
        try container.encode(updatedAt, forKey: AnyCodingKey("updatedAt"))
        try container.encodeIfPresent(updatedBy, forKey: AnyCodingKey("updatedBy"))
        try container.encode(entries, forKey: AnyCodingKey("entries"))
        try container.encode(deleted, forKey: AnyCodingKey("deleted"))
        try container.encode(otherFields: other)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> VocabFile {
        try JSONDecoder().decode(VocabFile.self, from: data)
    }
}

// MARK: - Normalizing

nonisolated enum VocabFormat {
    static let maxForms = 20
    static let maxContexts = 20
    /// Tombstones are kept for a year.
    static let tombstoneLifetime: Int64 = 365 * 24 * 3600 * 1000

    /// Code points that count as white space (§3.2 step 5), the same list on both sides.
    private static func isSpace(_ value: UInt32) -> Bool {
        switch value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    /// The key of a term (§3.2): NFKC, without U+FEFF/U+200B, lower-cased one code point at a time, straight
    /// apostrophes, one space between words. `lowercase: false` is the sentence form used for context ids.
    static func normalize(_ text: String, lowercase: Bool = true) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.value {
            case 0xFEFF, 0x200B:
                continue
            case 0x2018, 0x2019, 0x02BC:
                scalars.append("'")
            case let value where isSpace(value):
                scalars.append(" ")
            default:
                if lowercase {
                    // The mapping of one code point alone: no locale, no context (word-final sigma stays σ).
                    scalars.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
                } else {
                    scalars.append(scalar)
                }
            }
        }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// A sentence's id (§3.3): the first 16 hex digits of the SHA-256 of its normalized form.
    static func contextID(of sentence: String) -> String {
        let digest = SHA256.hash(data: Data(normalize(sentence, lowercase: false).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Code point order, the same on both sides (JavaScript's `localeCompare` is not).
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Merging (§6)

    /// Merges this iPhone's book with Drive's. Independent of which side is which, except in the ties noted.
    static func merge(_ local: VocabFile, _ remote: VocabFile?, now: Int64, by writer: String) -> VocabFile {
        var deleted: [String: Int64] = [:]
        for source in [local.deleted, remote?.deleted ?? [:]] {
            for (key, time) in source where now - time < tombstoneLifetime {
                deleted[key] = max(deleted[key] ?? time, time)
            }
        }

        var byKey: [String: VocabEntry] = [:]
        for entry in local.entries + (remote?.entries ?? []) {
            byKey[entry.key] = byKey[entry.key].map { mergeEntry($0, entry) } ?? entry
        }
        var entries: [VocabEntry] = []
        for entry in byKey.values {
            if let tombstone = deleted[entry.key] {
                if tombstone >= entry.updatedAt { continue }
                deleted[entry.key] = nil  // saved again after it was deleted
            }
            entries.append(entry)
        }
        entries.sort { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : precedes($0.key, $1.key) }

        var merged = VocabFile(entries: entries, deleted: deleted)
        if let remote, remote.updatedAt > local.updatedAt {
            merged.other = remote.other
        } else {
            merged.other = local.other
        }
        merged.updatedAt = now
        merged.updatedBy = writer
        return merged
    }

    static func mergeEntry(_ a: VocabEntry, _ b: VocabEntry) -> VocabEntry {
        let (newer, older) = isNewer(b, than: a) ? (b, a) : (a, b)
        var merged = newer
        merged.lemma = newer.lemma ?? older.lemma
        merged.meaning = newer.meaning ?? older.meaning
        merged.other = older.other.merging(newer.other) { _, fromNewer in fromNewer }

        // Compared code point by code point, as JavaScript does (Swift's == would merge "é" and "e\u{301}").
        var forms: [String] = []
        for form in (a.forms + b.forms).sorted(by: precedes)
        where forms.last.map({ !$0.unicodeScalars.elementsEqual(form.unicodeScalars) }) ?? true {
            forms.append(form)
        }
        merged.forms = Array(forms.prefix(maxForms))

        var byID: [String: VocabContext] = [:]
        for context in older.contexts + newer.contexts {
            guard let existing = byID[context.id] else {
                byID[context.id] = context
                continue
            }
            // `context` comes from the newer entry when both have it, so it wins ties after the meaning.
            byID[context.id] = mergeContext(existing, context)
        }
        let kept = byID.values
            .sorted { $0.savedAt != $1.savedAt ? $0.savedAt > $1.savedAt : precedes($0.id, $1.id) }
            .prefix(maxContexts)
        merged.contexts = kept.sorted { $0.savedAt != $1.savedAt ? $0.savedAt < $1.savedAt : precedes($0.id, $1.id) }

        merged.createdAt = min(a.createdAt, b.createdAt)
        merged.updatedAt = max(a.updatedAt, b.updatedAt)
        return merged
    }

    /// Whether `b` counts as the newer copy of the same word: edited later; on the same millisecond, the larger
    /// meaning, then the larger term.
    private static func isNewer(_ b: VocabEntry, than a: VocabEntry) -> Bool {
        if a.updatedAt != b.updatedAt { return b.updatedAt > a.updatedAt }
        let (meaningA, meaningB) = (a.meaning ?? "", b.meaning ?? "")
        if meaningA != meaningB { return precedes(meaningA, meaningB) }
        if a.term != b.term { return precedes(a.term, b.term) }
        return false
    }

    /// Two copies of the same sentence; `fromNewer` belongs to the newer entry.
    private static func mergeContext(_ fromOlder: VocabContext, _ fromNewer: VocabContext) -> VocabContext {
        let chosen: VocabContext, other: VocabContext
        if fromOlder.savedAt != fromNewer.savedAt {
            (chosen, other) = fromOlder.savedAt > fromNewer.savedAt ? (fromOlder, fromNewer) : (fromNewer, fromOlder)
        } else if (fromOlder.meaning == nil) != (fromNewer.meaning == nil) {
            (chosen, other) = fromOlder.meaning != nil ? (fromOlder, fromNewer) : (fromNewer, fromOlder)
        } else {
            (chosen, other) = (fromNewer, fromOlder)
        }
        var merged = chosen
        merged.meaning = chosen.meaning ?? other.meaning
        merged.other = other.other.merging(chosen.other) { _, fromChosen in fromChosen }
        return merged
    }

    /// Whether two books say the same, whoever wrote them and when, and in whatever order (§7 step 4).
    static func sameContent(_ a: VocabFile, _ b: VocabFile) -> Bool {
        func canonical(_ file: VocabFile) -> VocabFile {
            var file = file
            file.updatedAt = 0
            file.updatedBy = nil
            file.entries = file.entries
                .map { entry in
                    var entry = entry
                    entry.contexts.sort { precedes($0.id, $1.id) }
                    return entry
                }
                .sorted { precedes($0.key, $1.key) }
            return file
        }
        return canonical(a) == canonical(b)
    }
}
