import Foundation

/// Turns the text of an imported file (or pasted text) into the article's blocks.
///
/// The text is plain text with a little Markdown, which is what an article written by Claude looks like:
/// `# Title`, `## Section` headings, paragraphs separated by blank lines, `-` / `1.` list items. PDF and photo
/// extraction produce the same shape (see `PDFTextExtractor`), so every source ends up here.
///
/// The rules the article format is held to are in `docs/ARTICLE-FORMAT.md`.
nonisolated struct ParsedLocalArticle: Equatable, Sendable {
    /// The one `#` heading, if the text has exactly one; it names the article and is not a block.
    var title: String?
    var blocks: [ContentBlock]
    /// Lines left out because they can't be read aloud sensibly: table rows, code blocks.
    var skippedLines: Int

    var paragraphCount: Int { blocks.filter { $0.kind == .paragraph }.count }
}

nonisolated enum LocalArticleParser {
    private enum Item {
        /// `hashes` is the number of `#` the heading was written with.
        case heading(hashes: Int, text: String)
        case paragraph(String)
    }

    static func parse(_ raw: String) -> ParsedLocalArticle {
        // Wikipedia-style markup is converted first, so a `.wiki` file, a `.txt` of wikitext and pasted wikitext all work.
        let source = WikitextConverter.looksLikeWikitext(raw) ? WikitextConverter.markdown(from: raw) : raw
        let text = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let cleaner = InlineCleaner()

        var items: [Item] = []
        var current: [String] = []
        var skipped = 0
        var inFence = false

        func flush() {
            guard !current.isEmpty else { return }
            let paragraph = cleaner.clean(current.joined(separator: " "))
            if !paragraph.isEmpty { items.append(.paragraph(paragraph)) }
            current = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            var trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                inFence.toggle()
                continue
            }
            if inFence {
                if !trimmed.isEmpty { skipped += 1 }
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if isHorizontalRule(trimmed) {
                flush()
                continue
            }
            if trimmed.hasPrefix("|") {
                flush()
                skipped += 1
                continue
            }
            if isFootnoteDefinition(trimmed) {
                flush()
                continue
            }
            if trimmed.count <= 6, trimmed.allSatisfy({ $0 == "#" }) {
                // A heading with no text.
                flush()
                continue
            }
            if let (hashes, title) = heading(in: trimmed) {
                flush()
                let cleaned = cleaner.clean(title)
                if !cleaned.isEmpty { items.append(.heading(hashes: hashes, text: cleaned)) }
                continue
            }
            if trimmed.hasPrefix(">") {
                trimmed = String(trimmed.drop { $0 == ">" || $0 == " " })
                if trimmed.isEmpty { continue }
            }
            if let item = listItemText(in: trimmed) {
                // Every list item is a block of its own; lines that follow it without a blank line belong to it.
                flush()
                current = [item]
                continue
            }
            current.append(trimmed)
        }
        flush()

        return assemble(items, skipped: skipped)
    }

    private static func assemble(_ items: [Item], skipped: Int) -> ParsedLocalArticle {
        let titleCount = items.reduce(0) { count, item in
            if case .heading(1, _) = item { count + 1 } else { count }
        }
        var title: String?
        var blocks: [ContentBlock] = []
        for item in items {
            switch item {
            case .heading(let hashes, let text):
                if hashes == 1, titleCount == 1 {
                    title = text
                } else {
                    // The article's own title is the page title, so section headings start at level 2, as on Wikipedia.
                    blocks.append(.heading(text, level: max(hashes, 2)))
                }
            case .paragraph(let text):
                blocks.append(.paragraph(text))
            }
        }
        return ParsedLocalArticle(title: title, blocks: blocks, skippedLines: skipped)
    }

    // MARK: - Line shapes

    /// `## Text` → (2, "Text"). A `#` not followed by a space (such as `#hashtag`) isn't a heading.
    private static func heading(in line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        // Closing hashes (`## Title ##`) are decoration.
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        return (hashes, title.trimmingCharacters(in: .whitespaces))
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_=".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isFootnoteDefinition(_ line: String) -> Bool {
        line.hasPrefix("[^") && line.contains("]:")
    }

    /// `- item`, `* item`, `• item`, `1. item`, `2) item` → "item". Needs a space after the marker, so `**bold**`
    /// and a year such as `2009.` at the start of a sentence are not list items.
    private static func listItemText(in line: String) -> String? {
        var index = line.startIndex
        if let first = line.first, "-*+•".contains(first) {
            index = line.index(after: index)
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard (1...3).contains(digits.count) else { return nil }
            index = line.index(line.startIndex, offsetBy: digits.count)
            guard index < line.endIndex, ".)".contains(line[index]) else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == " " else { return nil }
        return line[index...].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Inline Markdown

    /// Removes Markdown and HTML decoration inside a paragraph, leaving the words that should be read.
    struct InlineCleaner {
        /// Characters a backslash can escape. While the rules run they are swapped for private-use stand-ins, so an
        /// escaped `\*` isn't taken for the start of italics.
        private static let escapable = Array("\\`*_{}[]()#+-.!|>~")
        private static let standInBase: UInt32 = 0xE000

        private let rules: [(NSRegularExpression, String)]
        private let spaces = try! NSRegularExpression(pattern: "\\s+")

        init() {
            let patterns: [(String, String)] = [
                ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),                       // images
                ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),                    // [text](url)
                ("\\[\\^[^\\]]+\\]", ""),                                // footnote marks
                ("<https?://[^>]+>", ""),                                // <autolinks>
                ("<br\\s*/?>", " "),                                      // <br>
                ("</?[A-Za-z][^>]*>", ""),                               // other html tags
                ("(\\*\\*|__)(.+?)\\1", "$2"),                           // bold
                ("(?<![\\w*])\\*(?![\\s*])(.+?)(?<![\\s*])\\*(?![\\w*])", "$1"),  // *italic*
                ("(?<![\\w_])_(?![\\s_])(.+?)(?<![\\s_])_(?![\\w_])", "$1"),      // _italic_
                ("~~(.+?)~~", "$1"),                                     // strikethrough
                ("`([^`]+)`", "$1"),                                     // inline code
            ]
            rules = patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
        }

        func clean(_ text: String) -> String {
            var result = protectEscapes(in: text.replacingOccurrences(of: "\u{00A0}", with: " "))
            for (regex, template) in rules {
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template
                )
            }
            result = spaces.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " "
            )
            return restoreEscapes(in: result).trimmingCharacters(in: .whitespaces)
        }

        private func protectEscapes(in text: String) -> String {
            guard text.contains("\\") else { return text }
            var result = ""
            var iterator = text.makeIterator()
            while let character = iterator.next() {
                if character == "\\", let next = iterator.next() {
                    if let index = Self.escapable.firstIndex(of: next) {
                        result.unicodeScalars.append(Unicode.Scalar(Self.standInBase + UInt32(index))!)
                    } else {
                        result.append(character)
                        result.append(next)
                    }
                } else {
                    result.append(character)
                }
            }
            return result
        }

        private func restoreEscapes(in text: String) -> String {
            var result = ""
            for scalar in text.unicodeScalars {
                let offset = Int(scalar.value) - Int(Self.standInBase)
                if offset >= 0, offset < Self.escapable.count {
                    result.append(Self.escapable[offset])
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
            return result
        }
    }
}
