import Foundation

/// One entry of the bundled English–Chinese dictionary (ECDICT, MIT licence), as stored.
nonisolated struct DictionaryEntry: Equatable, Sendable {
    var word: String
    var phonetic: String
    /// English meanings, one per line.
    var englishDefinition: String
    /// Chinese meanings, one per line, each starting with a part of speech ("n. 饥荒, 缺乏").
    var chineseTranslation: String
    /// 0…5 Collins stars.
    var collins: Int
    /// In the Oxford 3000 list of core words.
    var isOxford3000: Bool
    /// Exam tags as stored: "zk gk cet4 cet6 ky toefl ielts gre".
    var tags: String
    var exchange: String

    /// The phonetic spelling tidied for display: ECDICT writes the schwa with the Cyrillic "ә" (U+04D9) and
    /// sprinkles in "^" markers, neither of which belongs in IPA.
    var displayPhonetic: String {
        phonetic.replacingOccurrences(of: "\u{04D9}", with: "\u{0259}").replacingOccurrences(of: "^", with: "")
    }

    /// Chinese meanings as separate lines. The database stores line breaks as the two characters `\` `n`.
    var chineseLines: [String] { Self.lines(of: chineseTranslation) }
    var englishLines: [String] { Self.lines(of: englishDefinition) }

    /// Readable exam labels for the stored tags, in a fixed order.
    var examLabels: [String] {
        let known = tags.split(separator: " ").map(String.init)
        return Self.examNames.compactMap { key, name in known.contains(key) ? name : nil }
    }

    /// The base form this entry is an inflection of ("studies" → "study"), if it says so.
    var lemma: String? { forms.lemma }

    /// Inflections and the lemma, parsed from the `exchange` field.
    var forms: Forms { Forms(exchange: exchange) }

    /// A short Chinese gloss for lists: the first meaning line, trimmed.
    var shortMeaning: String? {
        guard let first = chineseLines.first else { return nil }
        let trimmed = first.count > 40 ? String(first.prefix(40)) + "…" : first
        return trimmed.isEmpty ? nil : trimmed
    }

    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let examNames: [(String, String)] = [
        ("zk", "中考"), ("gk", "高考"), ("cet4", "四级"), ("cet6", "六级"),
        ("ky", "考研"), ("toefl", "托福"), ("ielts", "雅思"), ("gre", "GRE"),
    ]

    /// `exchange` looks like `p:went/d:gone/i:going/3:goes/s:…`; an inflected entry instead has `0:go/1:p`.
    struct Forms: Equatable, Sendable {
        var lemma: String?
        var pastTense: String?
        var pastParticiple: String?
        var presentParticiple: String?
        var thirdPerson: String?
        var comparative: String?
        var superlative: String?
        var plural: String?

        init(exchange: String) {
            for part in exchange.split(separator: "/") {
                guard let colon = part.firstIndex(of: ":") else { continue }
                let value = String(part[part.index(after: colon)...])
                guard !value.isEmpty else { continue }
                switch part[..<colon] {
                case "0": lemma = value
                case "p": pastTense = value
                case "d": pastParticiple = value
                case "i": presentParticiple = value
                case "3": thirdPerson = value
                case "r": comparative = value
                case "t": superlative = value
                case "s": plural = value
                default: break
                }
            }
        }

        /// Labelled forms for display, without repeats ("studied" is both past tense and participle).
        var labelled: [(label: String, form: String)] {
            var result: [(String, String)] = []
            for (label, form) in [
                ("plural", plural), ("3rd person", thirdPerson), ("past", pastTense), ("past participle", pastParticiple),
                ("-ing", presentParticiple), ("comparative", comparative), ("superlative", superlative),
            ] {
                guard let form else { continue }
                if let index = result.firstIndex(where: { $0.1 == form }) {
                    result[index].0 += " / \(label)"
                } else {
                    result.append((label, form))
                }
            }
            return result
        }
    }
}
