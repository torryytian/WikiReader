import UIKit

/// The whole article as one attributed string, plus where each block lives in it.
/// `blockRanges[i]` is the range of `blocks[i]`; speech, highlighting and
/// "start reading from this paragraph" all map between blocks and text through it.
struct ArticleDocument {
    let attributedText: NSAttributedString
    let blockRanges: [NSRange]
    /// Range of the article title shown above the first block.
    let titleRange: NSRange

    init(title: String, blocks: [ContentBlock]) {
        let text = NSMutableAttributedString()

        let titleStart = text.length
        text.append(NSAttributedString(string: title, attributes: Self.attributes(for: .title)))
        titleRange = NSRange(location: titleStart, length: text.length - titleStart)

        var ranges: [NSRange] = []
        ranges.reserveCapacity(blocks.count)
        for block in blocks {
            text.append(NSAttributedString(string: "\n"))
            let style: Style = block.kind == .heading ? .heading(level: block.level) : .paragraph
            let start = text.length
            text.append(NSAttributedString(string: block.text, attributes: Self.attributes(for: style)))
            ranges.append(NSRange(location: start, length: text.length - start))
        }

        attributedText = text
        blockRanges = ranges
    }

    /// Index of the block containing a text location, or nil for the title and separators.
    func blockIndex(containing location: Int) -> Int? {
        // Blocks are in text order, so binary search would work; linear is plenty for a few hundred blocks.
        blockRanges.firstIndex { NSLocationInRange(location, $0) }
    }

    /// The block at a text location, or the next block for the title and the line breaks between blocks.
    func blockIndex(nearest location: Int) -> Int? {
        blockIndex(containing: location) ?? blockRanges.firstIndex { $0.location > location }
    }

    /// Full-text range of a range inside a block.
    func textRange(of range: NSRange, inBlock block: Int) -> NSRange? {
        guard blockRanges.indices.contains(block) else { return nil }
        let blockRange = blockRanges[block]
        guard NSMaxRange(range) <= blockRange.length else { return nil }
        return NSRange(location: blockRange.location + range.location, length: range.length)
    }

    /// The paragraph (or heading, or title) containing `range`, and `range` expressed inside it.
    /// Used to give the lemmatizer the surrounding sentence.
    func context(for range: NSRange) -> (text: String, wordRange: Range<String.Index>)? {
        let container = blockIndex(containing: range.location).map { blockRanges[$0] } ?? titleRange
        guard NSIntersectionRange(container, range).length == range.length else { return nil }

        let text = (attributedText.string as NSString).substring(with: container)
        let local = NSRange(location: range.location - container.location, length: range.length)
        guard let wordRange = Range(local, in: text) else { return nil }
        return (text, wordRange)
    }

    // MARK: - Styling

    enum Style {
        case title
        case heading(level: Int)
        case paragraph
    }

    static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        let font: UIFont
        switch style {
        case .title:
            font = scaledFont(.largeTitle, weight: .bold)
            paragraph.paragraphSpacing = 12
        case .heading(let level):
            switch level {
            case ...2: font = scaledFont(.title2, weight: .bold)
            case 3: font = scaledFont(.title3, weight: .semibold)
            default: font = scaledFont(.headline, weight: .semibold)
            }
            paragraph.paragraphSpacingBefore = level <= 2 ? 24 : 16
            paragraph.paragraphSpacing = 8
        case .paragraph:
            font = UIFont.preferredFont(forTextStyle: .body).withSize(19)
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 14
        }
        return [
            .font: font,
            .foregroundColor: UIColor.label,  // adapts to dark mode
            .paragraphStyle: paragraph,
        ]
    }

    private static func scaledFont(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }
}
