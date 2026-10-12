import Foundation

/// Reads the HTML that the MediaWiki `action=parse` API returns for an article and pulls out
/// the readable text: section headings, paragraphs and list items, in document order.
///
/// It is a whitelist: only `<p>`, `<li>`, `<dd>`, `<dt>` and `<h2>`…`<h6>` produce text, and whole
/// subtrees that are not running prose (tables, infoboxes, navigation boxes, figures and their captions,
/// quote boxes, "Main article:" hatnotes, footnote markers, math, hidden templates…) are skipped.
/// Paragraphs that a page pulls in from another article ("excerpts") are ordinary `<p>` elements
/// inside `div.excerpt`, so they are kept; only the "This paragraph is an excerpt from…" hatnote is dropped.
///
/// The HTML is not valid XML (`<link …>`, `<br>`, unquoted attributes), so `XMLParser` cannot read it;
/// this is a small tolerant tokenizer instead. It works on UTF-8 bytes because articles are ~1 MB.
nonisolated enum ArticleHTMLParser {
    struct RawBlock: Equatable, Sendable {
        /// 0 for a paragraph, 2…6 for a heading (`<h2>`…`<h6>`).
        var level: Int
        var text: String
    }

    static func rawBlocks(from html: String) -> [RawBlock] {
        var walker = Walker(bytes: Array(html.utf8))
        walker.run()
        return walker.blocks
    }

    /// Text of a small HTML snippet (a dictionary definition, say): tags dropped, entities decoded, spaces collapsed.
    static func plainText(fromHTML snippet: String) -> String {
        var walker = Walker(bytes: Array(("<p>" + snippet + "</p>").utf8))
        walker.run()
        return walker.blocks.map(\.text).joined(separator: " ")
    }

    // MARK: - What is skipped

    private static let skippedTags: Set<String> = [
        "table", "style", "script", "figure", "figcaption", "math", "svg", "audio", "video", "blockquote",
        "form", "button", "input", "select", "textarea", "noscript", "template", "iframe",
    ]

    /// Class names that mark a subtree as "not prose". Matched against whole class tokens.
    private static let skippedClasses: Set<String> = [
        // Boxes and navigation
        "infobox", "navbox", "navbox-inner", "vertical-navbox", "sidebar", "toc", "toccolours", "sistersitebox",
        "side-box", "portalbox", "asbox", "navigation-not-searchable", "mw-collapsible-toggle",
        // Hatnotes: "Main article: …", "See also: …", "This paragraph is an excerpt from …"
        "hatnote", "dablink", "rellink", "excerpt-hat",
        // Maintenance banners
        "ambox", "tmbox", "cmbox", "imbox", "ombox", "fmbox", "mbox-small", "metadata",
        // Images, captions, galleries
        "thumb", "thumbinner", "thumbcaption", "tmulti", "gallery", "gallerybox", "mw-gallery-traditional",
        // Quote boxes
        "quotebox", "cquote", "templatequote", "templatequotecite",
        // Footnotes and editorial markers
        "reference", "references", "reflist", "refbegin", "mw-references-wrap", "mw-editsection",
        "noprint", "nomobile", "noexcerpt", "Inline-Template", "Template-Fact", "shortdescription",
        // Bibliography entries (`<cite class="citation …">`), e.g. a "Publications" list
        "citation",
        // Hidden or duplicate renderings of coordinates ("35°36′S 92°48′E / 35.6°S 92.8°E / …")
        "geo-nondefault", "geo-multi-punct",
        // Long multi-column lists (sister cities, alumni, works) read badly aloud
        "div-col", "columns",
        // Math (the old text path dropped it too; see SPEC F2)
        "mwe-math-element", "mw-math-element",
    ]

    /// `div`s that float an image or a box beside the text.
    private static let skippedFloats: Set<String> = ["floatright", "floatleft", "tright", "tleft"]

    private static let skippedIDs: Set<String> = ["coordinates", "toc", "siteSub", "contentSub"]

    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Elements whose text becomes a block of its own.
    private static func blockLevel(of tag: String) -> Int? {
        switch tag {
        case "p", "li", "dd", "dt": 0
        case "h2": 2
        case "h3": 3
        case "h4": 4
        case "h5": 5
        case "h6": 6
        default: nil
        }
    }

    /// Elements that end the current block even though they are not blocks themselves
    /// (a list nested in a list item, for instance).
    private static let flushingTags: Set<String> = ["ul", "ol", "dl", "div", "blockquote", "section"]

    // MARK: - Walker

    private struct Open {
        var tag: String
        /// Block level if this element starts a block (`blockLevel(of:)`), else nil.
        var level: Int?
    }

    private struct Walker {
        let bytes: [UInt8]
        var position = 0
        var stack: [Open] = []
        /// Stack depth at which a skipped subtree began; text and blocks are ignored while set.
        var skipDepth: Int?
        var buffer: [UInt8] = []
        var bufferLevel: Int?
        var pendingSpace = false
        var blocks: [RawBlock] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func run() {
            while position < bytes.count {
                if bytes[position] == UInt8(ascii: "<"), let next = bytes[safe: position + 1],
                   next == UInt8(ascii: "/") || next == UInt8(ascii: "!") || next == UInt8(ascii: "?") || isLetter(next) {
                    readMarkup()
                } else {
                    readText()
                }
            }
            flush()
        }

        // MARK: Text

        private mutating func readText() {
            let start = position
            position += 1
            while position < bytes.count, bytes[position] != UInt8(ascii: "<") || !startsMarkup(at: position) {
                position += 1
            }
            guard skipDepth == nil, bufferLevel != nil else { return }
            append(decodeEntities(bytes[start..<position]))
        }

        private func startsMarkup(at index: Int) -> Bool {
            guard let next = bytes[safe: index + 1] else { return false }
            return next == UInt8(ascii: "/") || next == UInt8(ascii: "!") || next == UInt8(ascii: "?") || isLetter(next)
        }

        /// Appends text, collapsing every run of whitespace into one space.
        private mutating func append(_ text: [UInt8]) {
            for byte in text {
                if byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D {
                    pendingSpace = true
                } else {
                    if pendingSpace, !buffer.isEmpty { buffer.append(0x20) }
                    pendingSpace = false
                    buffer.append(byte)
                }
            }
        }

        // MARK: Markup

        private mutating func readMarkup() {
            let next = bytes[position + 1]
            if next == UInt8(ascii: "!") {
                skipCommentOrDeclaration()
            } else if next == UInt8(ascii: "?") {
                skip(past: UInt8(ascii: ">"))
            } else if next == UInt8(ascii: "/") {
                readEndTag()
            } else {
                readStartTag()
            }
        }

        private mutating func skipCommentOrDeclaration() {
            if bytes[position...].starts(with: Array("<!--".utf8)) {
                position += 4
                while position + 2 < bytes.count,
                      !(bytes[position] == UInt8(ascii: "-") && bytes[position + 1] == UInt8(ascii: "-") && bytes[position + 2] == UInt8(ascii: ">")) {
                    position += 1
                }
                position = min(position + 3, bytes.count)
            } else {
                skip(past: UInt8(ascii: ">"))
            }
        }

        private mutating func skip(past byte: UInt8) {
            while position < bytes.count, bytes[position] != byte { position += 1 }
            position = min(position + 1, bytes.count)
        }

        private mutating func readEndTag() {
            position += 2
            let name = readName()
            skip(past: UInt8(ascii: ">"))
            close(tag: name)
        }

        private mutating func readStartTag() {
            position += 1
            let name = readName()
            var classes: [Substring] = []
            var id = ""
            var hidden = false
            var selfClosing = false

            // Attributes
            while position < bytes.count {
                skipWhitespace()
                guard position < bytes.count else { break }
                let byte = bytes[position]
                if byte == UInt8(ascii: ">") { position += 1; break }
                if byte == UInt8(ascii: "/") { selfClosing = true; position += 1; continue }
                let attribute = readName(allowing: ":-_.")
                if attribute.isEmpty { position += 1; continue }
                var value = ""
                skipWhitespace()
                if position < bytes.count, bytes[position] == UInt8(ascii: "=") {
                    position += 1
                    skipWhitespace()
                    value = readAttributeValue()
                }
                if attribute == "class" { classes = value.split(whereSeparator: \.isWhitespace) }
                else if attribute == "id" { id = value }
                else if attribute == "style" { hidden = value.contains(#/display\s*:\s*none/#) }
            }

            open(tag: name, classes: classes, id: id, hidden: hidden, selfClosing: selfClosing)
        }

        private mutating func readName(allowing extra: String = "") -> String {
            let start = position
            let allowed = Set(extra.utf8)
            while position < bytes.count, isLetter(bytes[position]) || isDigit(bytes[position]) || allowed.contains(bytes[position]) {
                position += 1
            }
            return String(decoding: bytes[start..<position], as: UTF8.self).lowercased()
        }

        private mutating func readAttributeValue() -> String {
            guard position < bytes.count else { return "" }
            let quote = bytes[position]
            if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                position += 1
                let start = position
                while position < bytes.count, bytes[position] != quote { position += 1 }
                let value = String(decoding: bytes[start..<position], as: UTF8.self)
                position = min(position + 1, bytes.count)
                return value
            }
            let start = position
            while position < bytes.count, !isSpace(bytes[position]), bytes[position] != UInt8(ascii: ">") { position += 1 }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        private mutating func skipWhitespace() {
            while position < bytes.count, isSpace(bytes[position]) { position += 1 }
        }

        // MARK: Elements

        private mutating func open(tag: String, classes: [Substring], id: String, hidden: Bool, selfClosing: Bool) {
            if tag == "style" || tag == "script" {
                skipRawText(until: tag)
                return
            }
            if tag == "br" {
                if skipDepth == nil, bufferLevel != nil { pendingSpace = true }
                return
            }
            if voidTags.contains(tag) || selfClosing { return }

            let level = ArticleHTMLParser.blockLevel(of: tag)
            if skipDepth == nil {
                // A display formula sits inside its paragraph; it ends that paragraph, as the old text path did.
                if level != nil || ArticleHTMLParser.flushingTags.contains(tag) || classes.contains("mwe-math-element-block") { flush() }
                if hidden || shouldSkip(tag: tag, classes: classes, id: id) {
                    stack.append(Open(tag: tag, level: nil))
                    skipDepth = stack.count
                    return
                }
                stack.append(Open(tag: tag, level: level))
                if let level { beginBlock(level: level) }
            } else {
                stack.append(Open(tag: tag, level: nil))
            }
        }

        private mutating func close(tag: String) {
            guard let index = stack.lastIndex(where: { $0.tag == tag }) else { return }
            let closing = stack[index...]
            let wasBlock = closing.contains { $0.level != nil }
            if skipDepth == nil, wasBlock || ArticleHTMLParser.flushingTags.contains(tag) { flush() }
            stack.removeSubrange(index...)
            if let depth = skipDepth, stack.count < depth { skipDepth = nil }
            guard skipDepth == nil else { return }
            // Back inside an enclosing block (e.g. text after a nested list in a list item): keep collecting.
            if bufferLevel == nil, let enclosing = stack.last(where: { $0.level != nil })?.level {
                beginBlock(level: enclosing)
            }
        }

        private func shouldSkip(tag: String, classes: [Substring], id: String) -> Bool {
            if ArticleHTMLParser.skippedTags.contains(tag) { return true }
            if ArticleHTMLParser.skippedIDs.contains(id) { return true }
            for name in classes {
                let name = String(name)
                if ArticleHTMLParser.skippedClasses.contains(name) { return true }
                if tag == "div", ArticleHTMLParser.skippedFloats.contains(name) { return true }
            }
            // "…-sidebar", "navbox-…" and friends.
            return classes.contains { $0.hasPrefix("navbox") || $0.hasPrefix("infobox") || $0.hasPrefix("sidebar") }
        }

        private mutating func skipRawText(until tag: String) {
            let closing = Array("</\(tag)".utf8)
            while position < bytes.count {
                if bytes[position] == UInt8(ascii: "<"), bytes[position...].starts(with: closing) { break }
                position += 1
            }
            skip(past: UInt8(ascii: ">"))
        }

        // MARK: Blocks

        private mutating func beginBlock(level: Int) {
            buffer.removeAll(keepingCapacity: true)
            bufferLevel = level
            pendingSpace = false
        }

        private mutating func flush() {
            defer { buffer.removeAll(keepingCapacity: true); bufferLevel = nil; pendingSpace = false }
            guard let level = bufferLevel, !buffer.isEmpty else { return }
            blocks.append(RawBlock(level: level, text: String(decoding: buffer, as: UTF8.self)))
        }
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "times": "×", "minus": "−", "deg": "°", "middot": "·", "shy": "\u{00AD}", "zwj": "\u{200D}",
    ]

    /// Decodes `&amp;`, `&#8211;`, `&#x2013;` and a short list of named entities (MediaWiki writes
    /// almost everything else as literal UTF-8). Unknown entities are left as they are.
    static func decodeEntities(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        guard bytes.contains(UInt8(ascii: "&")) else { return Array(bytes) }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "&"),
               let semicolon = bytes[index..<min(index + 12, bytes.endIndex)].firstIndex(of: UInt8(ascii: ";")) {
                let name = String(decoding: bytes[(index + 1)..<semicolon], as: UTF8.self)
                if let replacement = decodeEntity(name) {
                    result.append(contentsOf: replacement.utf8)
                    index = semicolon + 1
                    continue
                }
            }
            result.append(byte)
            index += 1
        }
        return result
    }

    private static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[name]
    }
}

private nonisolated func isLetter(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
}

private nonisolated func isDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
}

private nonisolated func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
