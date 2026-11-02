import CoreGraphics
import Foundation

/// A line of text found in a PDF page or a photographed page, with where and how big it was.
/// Coordinates are measured from the top-left of the page, in any consistent unit.
nonisolated struct TextLine: Equatable, Sendable {
    var text: String
    /// Font size (PDF) or the height of the line's box (OCR): what tells a heading from body text.
    var size: CGFloat
    var isBold = false
    var minX: CGFloat
    var maxX: CGFloat
    var top: CGFloat
    var height: CGFloat
    var page: Int
    var pageHeight: CGFloat
}

/// Rebuilds headings and paragraphs from lines of text: a PDF or a photo has no paragraph marks, only lines.
/// The result is the same plain text with `#` headings that `LocalArticleParser` reads.
nonisolated struct TextLineAssembler {
    /// How much bigger than the body text a line must be to count as a heading. A PDF knows its font sizes
    /// exactly; the height of a recognized line varies with its letters (g, y, p), so OCR needs more margin.
    var headingRatio: CGFloat = 1.15

    func markdown(from allLines: [TextLine]) -> String {
        let lines = withoutPageFurniture(allLines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !lines.isEmpty else { return "" }

        let body = bodySize(of: lines)
        let headingSizes = Set(lines.filter { isHeading($0, body: body, boldIsHeading: boldMarksHeadings(lines)) && $0.size > body * 1.05 }
            .map { round($0.size * 2) / 2 })
            .sorted(by: >)
        let boldHeadings = boldMarksHeadings(lines)

        let leftEdge = percentile(lines.map(\.minX), 0.1)
        let rightEdge = percentile(lines.map(\.maxX), 0.9)
        let leading = typicalLeading(of: lines)

        var output: [String] = []
        var paragraph = ""
        var previous: TextLine?
        var previousWasHeading = false
        var headingText = ""
        var headingMarks = ""

        func flushParagraph() {
            if !paragraph.isEmpty { output.append(paragraph) }
            paragraph = ""
        }
        func flushHeading() {
            if !headingText.isEmpty { output.append(headingMarks + " " + headingText) }
            headingText = ""
        }

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if isHeading(line, body: body, boldIsHeading: boldHeadings) {
                flushParagraph()
                let rank = headingSizes.firstIndex(of: round(line.size * 2) / 2) ?? headingSizes.count
                let marks = String(repeating: "#", count: min(rank + 1, 6))
                if previousWasHeading, marks == headingMarks, previous?.page == line.page {
                    // A heading that wrapped onto a second line.
                    headingText += " " + text
                } else {
                    flushHeading()
                    headingMarks = marks
                    headingText = text
                }
                previousWasHeading = true
                previous = line
                continue
            }

            flushHeading()
            let startsListItem = Self.bulletPrefix(of: text) != nil
            let breaks = previous == nil || previousWasHeading || startsListItem
                || startsNewParagraph(line, after: previous!, leading: leading, leftEdge: leftEdge, rightEdge: rightEdge, body: body)
            if breaks {
                flushParagraph()
                paragraph = startsListItem ? "- " + Self.removingBullet(from: text) : text
            } else if paragraph.hasSuffix("-"), let last = paragraph.dropLast().last, last.isLetter,
                      text.first?.isLowercase == true {
                // A word hyphenated at the end of the line.
                paragraph.removeLast()
                paragraph += text
            } else {
                paragraph += " " + text
            }
            previousWasHeading = false
            previous = line
        }
        flushParagraph()
        flushHeading()
        return output.joined(separator: "\n\n")
    }

    // MARK: - Headings

    /// The font size most of the text is set in.
    private func bodySize(of lines: [TextLine]) -> CGFloat {
        var characters: [CGFloat: Int] = [:]
        for line in lines { characters[round(line.size * 2) / 2, default: 0] += line.text.count }
        return characters.max { $0.value < $1.value }?.key ?? lines[0].size
    }

    /// Bold lines count as headings only when bold is the exception: a document set mostly in bold has no signal.
    private func boldMarksHeadings(_ lines: [TextLine]) -> Bool {
        let total = lines.reduce(0) { $0 + $1.text.count }
        let bold = lines.filter(\.isBold).reduce(0) { $0 + $1.text.count }
        return total > 0 && Double(bold) / Double(total) < 0.4
    }

    private func isHeading(_ line: TextLine, body: CGFloat, boldIsHeading: Bool) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        if Self.bulletPrefix(of: text) != nil { return false }
        if line.size >= body * headingRatio, text.count <= 140 { return true }
        // A short bold line without a full stop: a heading set in the body size.
        return boldIsHeading && line.isBold && text.count <= 90 && !Self.endsSentence(text) && line.size >= body * 0.95
    }

    // MARK: - Paragraphs

    private func startsNewParagraph(
        _ line: TextLine, after previous: TextLine, leading: CGFloat,
        leftEdge: CGFloat, rightEdge: CGFloat, body: CGFloat
    ) -> Bool {
        let previousEnds = Self.endsSentence(previous.text.trimmingCharacters(in: .whitespaces))
        if line.page != previous.page {
            // A paragraph carries over a page break unless the sentence had ended.
            return previousEnds
        }
        // A bigger gap than the normal line spacing.
        if leading > 0, line.top - previous.top > leading * 1.45 { return true }
        // The previous line stopped short of the right edge after a full stop: the paragraph ended there.
        let width = max(rightEdge - leftEdge, 1)
        if previousEnds, previous.maxX < rightEdge - 0.12 * width { return true }
        // A first-line indent after a full stop.
        if previousEnds, line.minX > leftEdge + max(body * 1.2, 0.02 * width) { return true }
        return false
    }

    /// The usual distance between two lines of one paragraph: the most common line step.
    private func typicalLeading(of lines: [TextLine]) -> CGFloat {
        var steps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) where a.page == b.page {
            let step = b.top - a.top
            if step > 0 { steps.append(step) }
        }
        guard !steps.isEmpty else { return 0 }
        return percentile(steps, 0.4)
    }

    // MARK: - Page numbers, running headers

    /// Drops page numbers and the header or footer repeated on most pages.
    private func withoutPageFurniture(_ lines: [TextLine]) -> [TextLine] {
        let pages = Set(lines.map(\.page)).count
        func inBand(_ line: TextLine) -> Bool {
            line.pageHeight > 0 && (line.top < line.pageHeight * 0.09 || line.top + line.height > line.pageHeight * 0.92)
        }
        func shape(_ text: String) -> String {
            text.lowercased().filter { !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        }

        var pagesWithShape: [String: Set<Int>] = [:]
        for line in lines where inBand(line) {
            pagesWithShape[shape(line.text), default: []].insert(line.page)
        }
        return lines.filter { line in
            guard inBand(line) else { return true }
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if Self.isPageNumber(text) { return false }
            if pages >= 3, (pagesWithShape[shape(text)]?.count ?? 0) >= 3, text.count < 80 { return false }
            return true
        }
    }

    static func isPageNumber(_ text: String) -> Bool {
        text.range(of: #"^(page\s+)?\d{1,4}(\s*(of|/)\s*\d{1,4})?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Text shape

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?:;\"”’)".contains(last)
    }

    private static let bullets = "•◦▪‣·●○■□–—-*"

    /// "• text", "- text" (a bullet followed by a space).
    static func bulletPrefix(of text: String) -> Character? {
        guard let first = text.first, bullets.contains(first), text.dropFirst().first == " " else { return nil }
        return first
    }

    static func removingBullet(from text: String) -> String {
        bulletPrefix(of: text) == nil ? text : String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private func percentile(_ values: [CGFloat], _ fraction: Double) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count - 1) * fraction), sorted.count - 1)]
    }
}
