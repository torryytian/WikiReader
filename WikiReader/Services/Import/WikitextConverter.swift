import Foundation

/// Turns MediaWiki markup (`== Heading ==`, `[[link|text]]`, `''italic''`, `{{template}}`) into the Markdown-like
/// text `LocalArticleParser` reads. Claude writes articles "for Wikipedia" in this form, so it is accepted as well.
nonisolated enum WikitextConverter {
    /// Sections at the end that only list links or sources; like Wikipedia articles, they aren't read.
    static let unreadSections: Set<String> = [
        "see also", "references", "notes", "footnotes", "citations", "sources", "bibliography",
        "works cited", "further reading", "external links",
    ]

    /// True when the text has a `== Heading ==` line and is not Markdown. A `# ` line is a Markdown title when it
    /// opens the text and a numbered list item otherwise; `## ` and deeper are always Markdown.
    static func looksLikeWikitext(_ text: String) -> Bool {
        var hasWikiHeading = false
        var seenFirstLine = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes > 0, trimmed.dropFirst(hashes).first == " " {
                if hashes >= 2 || !seenFirstLine { return false }
            }
            seenFirstLine = true
            if wikiHeading(in: trimmed) != nil { hasWikiHeading = true }
        }
        return hasWikiHeading
    }

    static func markdown(from raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = removing(pattern: "<!--.*?-->", from: text, dotMatchesNewlines: true)
        text = removing(pattern: "<ref[^>]*?/>", from: text, dotMatchesNewlines: true)
        text = removing(pattern: "<ref[^>]*>.*?</ref>", from: text, dotMatchesNewlines: true)
        text = removing(pattern: "__[A-Z]+__", from: text, dotMatchesNewlines: false)
        text = removingTemplates(from: text)
        text = removingTables(from: text)

        var output: [String] = []
        var skippingSection = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if let (level, title) = wikiHeading(in: line) {
                skippingSection = unreadSections.contains(inline(title).lowercased())
                if !skippingSection { output.append(String(repeating: "#", count: level) + " " + inline(title)) }
                continue
            }
            if skippingSection { continue }
            if line.isEmpty { output.append(""); continue }
            // A line that is only a category, file or interlanguage link.
            if line.range(of: #"^\[\[(Category|File|Image|Media|[a-z]{2,3}):[^\]]*\]\]$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            output.append(listMarkerConverted(line))
        }
        return output.map(inline).joined(separator: "\n")
    }

    // MARK: - Lines

    /// `== Title ==` → (2, "Title"). One `=` on each side is a level-1 title.
    static func wikiHeading(in line: String) -> (Int, String)? {
        let opening = line.prefix { $0 == "=" }.count
        guard opening >= 1, line.count > opening * 2 else { return nil }
        let closing = line.reversed().prefix { $0 == "=" }.count
        guard closing >= 1 else { return nil }
        let level = min(opening, closing, 6)
        let title = line.dropFirst(level).dropLast(level).trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title.contains("==") ? nil : (level, title)
    }

    /// `* item` / `# item` / `: indent` / `; term` → a Markdown list item or plain line.
    private static func listMarkerConverted(_ line: String) -> String {
        guard let first = line.first, "*#:;".contains(first) else { return line }
        let rest = line.drop { "*#:; ".contains($0) }
        guard !rest.isEmpty else { return "" }
        return (first == "*" || first == "#") ? "- " + rest : String(rest)
    }

    // MARK: - Inline markup

    private static func inline(_ text: String) -> String {
        var result = text
        // [[Target|shown]] and [[Target]]; a link to a file or category inside a sentence is dropped.
        result = removing(pattern: #"\[\[(?:File|Image|Media|Category):[^\]]*\]\]"#, from: result, dotMatchesNewlines: false, caseInsensitive: true)
        result = replacing(pattern: #"\[\[[^\]|]*\|([^\]]*)\]\]"#, with: "$1", in: result)
        result = replacing(pattern: #"\[\[([^\]]*)\]\]"#, with: "$1", in: result)
        // [https://example.com shown text] → shown text; a bare [https://example.com] is dropped.
        result = replacing(pattern: #"\[(?:https?:)?//\S+\s+([^\]]*)\]"#, with: "$1", in: result)
        result = removing(pattern: #"\[(?:https?:)?//\S+\]"#, from: result, dotMatchesNewlines: false)
        // '''bold''', ''italic'', '''''both'''''
        result = replacing(pattern: "'{2,5}", with: "", in: result)
        result = replacing(pattern: "<br\\s*/?>", with: " ", in: result)
        // A dropped link can leave a space before the punctuation that followed it.
        result = replacing(pattern: #"\s+([.,;:!?])"#, with: "$1", in: result)
        return result
    }

    // MARK: - Blocks

    /// Removes `{{...}}`, including nested templates and ones spread over several lines.
    private static func removingTemplates(from text: String) -> String {
        var result = ""
        var depth = 0
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if character == "{" {
                if let next = iterator.next() {
                    if next == "{" { depth += 1; continue }
                    pending = next
                }
            } else if character == "}", depth > 0 {
                if let next = iterator.next() {
                    if next == "}" { depth -= 1; continue }
                    pending = next
                }
                continue
            }
            if depth == 0 { result.append(character) }
        }
        return result
    }

    /// Removes `{| ... |}` tables: read aloud they are only noise.
    private static func removingTables(from text: String) -> String {
        var kept: [Substring] = []
        var depth = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{|") { depth += 1; continue }
            if depth > 0 {
                if trimmed.hasPrefix("|}") { depth -= 1 }
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Regex helpers

    private static func replacing(pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func removing(pattern: String, from text: String, dotMatchesNewlines: Bool, caseInsensitive: Bool = false) -> String {
        var options: NSRegularExpression.Options = []
        if dotMatchesNewlines { options.insert(.dotMatchesLineSeparators) }
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
