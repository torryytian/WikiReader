import UIKit

extension NSAttributedString.Key {
    /// On the "Translate" label after a paragraph: the index of the block it translates.
    static let translateBlock = NSAttributedString.Key("WikiReader.translateBlock")
}

/// The whole article as one attributed string, plus where each block lives in it.
/// `blockRanges[i]` is the range of `blocks[i]`; speech, highlighting and
/// "start reading from this paragraph" all map between blocks and text through it.
/// Text that isn't a block (the title, the line breaks, the "Translate" labels) sits outside those ranges.
struct ArticleDocument {
    let attributedText: NSAttributedString
    let blockRanges: [NSRange]
    /// Range of the article title shown above the first block.
    let titleRange: NSRange

    init(title: String, blocks: [ContentBlock], style: ReaderStyle = .default) {
        let text = NSMutableAttributedString()

        let titleStart = text.length
        text.append(NSAttributedString(string: title, attributes: Self.attributes(for: .title, style: style)))
        titleRange = NSRange(location: titleStart, length: text.length - titleStart)

        var ranges: [NSRange] = []
        ranges.reserveCapacity(blocks.count)
        for (index, block) in blocks.enumerated() {
            text.append(NSAttributedString(string: "\n"))
            let kind: Style = block.kind == .heading ? .heading(level: block.level) : .paragraph
            let start = text.length
            text.append(NSAttributedString(string: block.text, attributes: Self.attributes(for: kind, style: style)))
            ranges.append(NSRange(location: start, length: text.length - start))
            if block.kind == .paragraph {
                text.append(Self.translateLabel(forBlock: index, style: style))
            }
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

    /// The text of a block, without the title, line breaks or "Translate" label.
    func blockText(_ block: Int) -> String? {
        guard blockRanges.indices.contains(block) else { return nil }
        return (attributedText.string as NSString).substring(with: blockRanges[block])
    }

    /// The article text inside a selection, one block per paragraph. Labels and line breaks are left out,
    /// so a selection that happens to cover a "Translate" label still yields only article text.
    func selectedText(in selection: NSRange) -> String {
        let text = attributedText.string as NSString
        return ([titleRange] + blockRanges)
            .map { NSIntersectionRange($0, selection) }
            .filter { $0.length > 0 }
            .map { text.substring(with: $0) }
            .joined(separator: "\n\n")
    }

    /// The block whose "Translate" label is at a text location, if any.
    func translateBlock(at location: Int) -> Int? {
        guard location >= 0, location < attributedText.length else { return nil }
        return attributedText.attribute(.translateBlock, at: location, effectiveRange: nil) as? Int
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

    static func attributes(for kind: Style, style: ReaderStyle) -> [NSAttributedString.Key: Any] {
        let size = style.clampedFontSize
        let paragraph = NSMutableParagraphStyle()
        let font: UIFont
        switch kind {
        case .title:
            font = style.fontFamily.font(size: size * 1.7, weight: .bold)
            paragraph.paragraphSpacing = 12
        case .heading(let level):
            switch level {
            case ...2: font = style.fontFamily.font(size: size * 1.35, weight: .bold)
            case 3: font = style.fontFamily.font(size: size * 1.18, weight: .semibold)
            default: font = style.fontFamily.font(size: size, weight: .semibold)
            }
            paragraph.paragraphSpacingBefore = level <= 2 ? 24 : 16
            paragraph.paragraphSpacing = 8
        case .paragraph:
            font = style.fontFamily.font(size: size, weight: .regular)
            paragraph.lineSpacing = size * style.lineSpacing.factor
            paragraph.paragraphSpacing = size * 0.75
        }
        return [
            .font: font,
            .foregroundColor: style.theme.text,
            .paragraphStyle: paragraph,
        ]
    }

    /// The small "Translate" link at the end of a paragraph. It carries the paragraph's own style, so the
    /// paragraph spacing stays the same, and sits outside the block's range.
    static func translateLabel(forBlock block: Int, style: ReaderStyle) -> NSAttributedString {
        var attributes = attributes(for: .paragraph, style: style)
        attributes[.font] = style.fontFamily.font(size: style.clampedFontSize * 0.78, weight: .medium)
        attributes[.foregroundColor] = UIColor.tintColor
        attributes[.translateBlock] = block
        return NSAttributedString(string: " Translate", attributes: attributes)
    }
}
