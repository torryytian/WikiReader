import Foundation

/// Turns the readable text of an article (see `ArticleHTMLParser`) into blocks that are pleasant to
/// read and to listen to: drops excluded sections, pronunciation, citation markers and formula leftovers.
nonisolated enum ArticleCleaner {
    /// Sections removed together with all their subsections. Compared case-insensitively.
    static let excludedSections: Set<String> = [
        "see also", "references", "notes", "footnotes", "citations", "sources",
        "bibliography", "works cited", "further reading", "external links",
    ]

    /// `html` is the `text` of an `action=parse` response.
    static func blocks(fromHTML html: String) -> [ContentBlock] {
        blocks(from: ArticleHTMLParser.rawBlocks(from: html))
    }

    static func blocks(from rawBlocks: [ArticleHTMLParser.RawBlock]) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        // While set, we are inside an excluded section of this level: skip until a heading at or above it.
        var skippingLevel: Int?

        for raw in rawBlocks {
            let text = cleanInline(raw.text)
            if raw.level > 0 {
                if let level = skippingLevel, raw.level > level { continue }
                skippingLevel = nil
                if excludedSections.contains(text.lowercased()) {
                    skippingLevel = raw.level
                    continue
                }
                if !text.isEmpty { blocks.append(.heading(text, level: raw.level)) }
            } else if skippingLevel == nil, !text.isEmpty {
                blocks.append(.paragraph(text))
            }
        }
        return removingEmptySections(blocks)
    }

    // MARK: - Sections

    /// Drops headings with no paragraph anywhere below them (before the next heading at the same or a higher level),
    /// e.g. "Notes and references" once its "Notes" and "References" subsections are gone.
    static func removingEmptySections(_ blocks: [ContentBlock]) -> [ContentBlock] {
        blocks.indices.compactMap { index in
            let block = blocks[index]
            guard block.kind == .heading else { return block }
            for next in blocks[(index + 1)...] {
                if next.kind == .paragraph { return block }
                if next.level <= block.level { return nil }
            }
            return nil
        }
    }

    // MARK: - Inline cleanup

    static func cleanInline(_ text: String) -> String {
        var text = removingInvisibleCharacters(text)
        text = removingPronunciation(text)
        text = removingCitationMarkers(text)
        return tidyingPunctuation(text)
    }

    /// Word joiners, zero-width spaces etc. that formulas and templates leave behind.
    static func removingInvisibleCharacters(_ text: String) -> String {
        let invisible: Set<Unicode.Scalar> = ["\u{00AD}", "\u{200B}", "\u{2060}", "\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}", "\u{FEFF}"]
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !invisible.contains(scalar) {
            scalars.append(scalar == "\u{00A0}" ? " " : scalar)
        }
        return String(scalars)
    }

    /// Removes IPA transcriptions, respellings and "listen" links.
    ///
    /// Inside parentheses, the content is split on `;` and every part that carries pronunciation
    /// is dropped, so `(/ˈaɪnstaɪn/ EYEN-styne; German: [ˈalbɛʁt] ⓘ; 14 March 1879 – 1955)`
    /// becomes `(14 March 1879 – 1955)`, and parentheses left empty are removed entirely.
    static func removingPronunciation(_ text: String) -> String {
        // Innermost parentheses first; repeat so "(French: [paʁi] (listen))" is handled from the inside out.
        var text = text
        for _ in 0..<3 {
            let updated = text.replacing(#/(\s*)\(([^()]*)\)/#) { match in
                let (whole, leadingSpace, content) = match.output
                let parts = content.split(separator: ";", omittingEmptySubsequences: false)
                let kept = parts.filter { !isPronunciation($0) }
                if kept.count == parts.count { return String(whole) }
                let joined = kept.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
                return joined.isEmpty ? "" : "\(leadingSpace)(\(joined))"
            }
            if updated == text { break }
            text = updated
        }
        // IPA outside parentheses, e.g. "known as Lutetia [lytesja]".
        text = text.replacing(#/\s*(\[[^\[\]\n]{1,60}\]|/[^/\s][^/\n]{0,58}/)/#) { match in
            containsIPA(match.output.1) ? "" : String(match.output.0)
        }
        return text.replacingOccurrences(of: "ⓘ", with: "")
    }

    private static func isPronunciation(_ part: Substring) -> Bool {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "listen" || trimmed.contains("ⓘ") { return true }
        return part.contains(#/\[[^\]]*\]|/[^/]*//#) && containsIPA(part)
    }

    /// True if the text contains characters that only appear in phonetic transcriptions.
    static func containsIPA(_ text: some StringProtocol) -> Bool {
        let extraIPA: Set<Unicode.Scalar> = ["æ", "ð", "θ", "ŋ", "œ", "ø"]
        let modifierApostrophes: Set<Unicode.Scalar> = ["\u{02BB}", "\u{02BC}"]  // ʻokina etc., used in normal words
        return text.unicodeScalars.contains { scalar in
            if modifierApostrophes.contains(scalar) { return false }
            return (0x0250...0x02FF).contains(scalar.value) || extraIPA.contains(scalar)
        }
    }

    /// Removes footnote markers like `[1]`, `[a]`, `[note 3]`, `[citation needed]`.
    /// Editorial brackets inside quotes (`"[the] needs"`) are kept.
    static func removingCitationMarkers(_ text: String) -> String {
        text.replacing(
            #/(?i)\s*\[(?:\d+|[a-z]|(?:note|nb) \d+|citation needed|clarification needed|better source needed|failed verification|dubious(?: – discuss)?|according to whom\?|who\?|when\?|which\?|by whom\?|page needed)\]/#,
            with: ""
        )
    }

    /// Fixes spacing and punctuation left behind by removed formulas and pronunciation.
    static func tidyingPunctuation(_ text: String) -> String {
        var text = text
        text = text.replacing(#/\(\s*[,;:]*\s*\)/#, with: "")      // "( )", "( ; )"
        text = text.replacing(#/\s+([,.;:!?)])/#) { String($0.output.1) }  // "word ," -> "word,"
        text = text.replacing(#/\(\s*[,;:]?\s*/#, with: "(")         // "( ; Latin)" -> "(Latin)"
        text = text.replacing(#/\s*[,;:]\s*\)/#, with: ")")           // "(Latin; )" -> "(Latin)"
        text = text.replacing(#/,(?:\s*,)+/#, with: ",")             // ", , ," -> ","
        text = text.replacing(#/,\s*([.;:])/#) { String($0.output.1) }  // ", ." -> "."
        text = text.replacing(#/\s{2,}/#, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
