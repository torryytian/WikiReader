import Foundation

/// Turns a TextExtracts plain-text extract into blocks that are pleasant to read and to listen to.
///
/// The API output looks like this:
/// - Section headings are lines like `== History ==`; the number of `=` is the level.
/// - Paragraphs are single lines; blank lines separate sections.
/// - Math formulas appear as a run of indented lines (one MathML token per line)
///   ending in a LaTeX annotation such as `{\displaystyle a^{2}+b^{2}=c^{2}}`.
nonisolated enum ArticleCleaner {
    /// Sections removed together with all their subsections. Compared case-insensitively.
    static let excludedSections: Set<String> = [
        "see also", "references", "notes", "footnotes", "citations", "sources",
        "bibliography", "works cited", "further reading", "external links",
    ]

    static func blocks(from extract: String) -> [ContentBlock] {
        let lines = removingFormulas(from: extract.components(separatedBy: .newlines))

        var blocks: [ContentBlock] = []
        // While set, we are inside an excluded section of this level: skip until a heading at or above it.
        var skippingLevel: Int?

        for line in lines {
            if let heading = parseHeading(line) {
                if let level = skippingLevel, heading.level > level { continue }
                skippingLevel = nil
                if excludedSections.contains(heading.title.lowercased()) {
                    skippingLevel = heading.level
                    continue
                }
                let title = cleanInline(heading.title)
                if !title.isEmpty { blocks.append(.heading(title, level: heading.level)) }
            } else if skippingLevel == nil {
                let text = cleanInline(line)
                if !text.isEmpty { blocks.append(.paragraph(text)) }
            }
        }
        return removingEmptySections(blocks)
    }

    // MARK: - Headings and sections

    static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: #/(={2,6})\s*(.+?)\s*(={2,6})/#),
              match.output.1.count == match.output.3.count
        else { return nil }
        return (match.output.1.count, String(match.output.2))
    }

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

    // MARK: - Formulas

    /// Removes formula runs: consecutive lines that are blank or indented by 2+ spaces and contain
    /// a LaTeX annotation line. A formula inside a sentence joins the text around it; a display
    /// formula (surrounded by blank lines) becomes a paragraph break.
    static func removingFormulas(from lines: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < lines.count {
            guard isFormulaRunLine(lines[index]) else {
                result.append(lines[index])
                index += 1
                continue
            }
            var end = index
            while end < lines.count, isFormulaRunLine(lines[end]) { end += 1 }
            let run = lines[index..<end]

            if !run.contains(where: isLaTeXAnnotation) {
                result.append(contentsOf: run)
            } else if run.contains(where: \.isEmpty) || result.isEmpty || end == lines.count {
                result.append("")
            } else {
                // Inline formula: the sentence continues on the line after the run.
                result[result.count - 1] = result[result.count - 1] + " " + lines[end]
                end += 1
            }
            index = end
        }
        return result
    }

    private static func isFormulaRunLine(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace) || line.hasPrefix("  ") || line.hasPrefix("\t")
    }

    private static func isLaTeXAnnotation(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).prefixMatch(of: #/\{\\[a-z]*style\b/#) != nil
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
        var text = text.replacing(#/(\s*)\(([^()]*)\)/#) { match in
            let (whole, leadingSpace, content) = match.output
            let parts = content.split(separator: ";", omittingEmptySubsequences: false)
            let kept = parts.filter { !isPronunciation($0) }
            if kept.count == parts.count { return String(whole) }
            let joined = kept.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
            return joined.isEmpty ? "" : "\(leadingSpace)(\(joined))"
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
        text = text.replacing(#/\(\s+/#, with: "(")
        text = text.replacing(#/,(?:\s*,)+/#, with: ",")             // ", , ," -> ","
        text = text.replacing(#/,\s*([.;:])/#) { String($0.output.1) }  // ", ." -> "."
        text = text.replacing(#/\s{2,}/#, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
