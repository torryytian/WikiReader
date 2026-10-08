import Testing
import UIKit
@testable import WikiReader

struct ArticleDocumentTests {
    private let blocks: [ContentBlock] = [
        .paragraph("First paragraph of the lead."),
        .heading("History", level: 2),
        .paragraph("Second paragraph about history."),
        .paragraph("Third paragraph."),
    ]

    private func document(style: ReaderStyle = .default) -> ArticleDocument {
        ArticleDocument(title: "Example", blocks: blocks, style: style)
    }

    private func text(_ document: ArticleDocument, _ range: NSRange) -> String {
        (document.attributedText.string as NSString).substring(with: range)
    }

    // MARK: - Block ranges

    @Test func blockRangesCoverExactlyTheBlockText() {
        let document = document()
        #expect(document.blockRanges.map { text(document, $0) } == blocks.map(\.text))
        #expect(document.blockText(2) == "Second paragraph about history.")
        #expect(document.blockText(9) == nil)
    }

    // MARK: - Translate labels

    @Test func everyParagraphButNoHeadingEndsWithATranslateLabel() {
        let document = document()
        for (index, block) in blocks.enumerated() {
            let labelLocation = NSMaxRange(document.blockRanges[index])
            if block.kind == .paragraph {
                #expect(document.translateBlock(at: labelLocation + 1) == index)
            } else {
                #expect(document.translateBlock(at: labelLocation) == nil)
            }
        }
    }

    @Test func labelsAreNotPartOfAnyBlock() {
        let document = document()
        let labelLocation = NSMaxRange(document.blockRanges[0]) + 1
        #expect(document.blockIndex(containing: labelLocation) == nil)
        // Not a block, so a tap on the label can't be mistaken for a word lookup in the paragraph.
        #expect(document.context(for: NSRange(location: labelLocation, length: 4)) == nil)
        // Reading position still resolves to the following block.
        #expect(document.blockIndex(nearest: labelLocation) == 1)
    }

    @Test func articleTextOutsideLabelsHasNoTranslateAttribute() {
        let document = document()
        #expect(document.translateBlock(at: document.blockRanges[0].location) == nil)
        #expect(document.translateBlock(at: -1) == nil)
        #expect(document.translateBlock(at: document.attributedText.length) == nil)
    }

    // MARK: - Selected text

    @Test func selectionInsideOneBlock() {
        let document = document()
        let range = NSRange(location: document.blockRanges[0].location + 6, length: 9)
        #expect(document.selectedText(in: range) == "paragraph")
    }

    @Test func selectionAcrossBlocksJoinsParagraphsAndSkipsLabelsAndBreaks() {
        let document = document()
        let start = document.blockRanges[2].location + 7
        let end = NSMaxRange(document.blockRanges[3])
        let result = document.selectedText(in: NSRange(location: start, length: end - start))
        #expect(result == "paragraph about history.\n\nThird paragraph.")
    }

    @Test func selectionOfOnlyALabelIsEmpty() {
        let document = document()
        let label = NSRange(location: NSMaxRange(document.blockRanges[0]), length: 10)
        #expect(document.selectedText(in: label).isEmpty)
    }

    @Test func selectionCanIncludeTheTitle() {
        let document = document()
        #expect(document.selectedText(in: document.titleRange) == "Example")
    }

    // MARK: - Style

    @Test func fontSizeFollowsTheStyle() {
        func paragraphFont(_ style: ReaderStyle) -> UIFont? {
            let document = document(style: style)
            return document.attributedText.attribute(.font, at: document.blockRanges[0].location, effectiveRange: nil) as? UIFont
        }
        #expect(paragraphFont(ReaderStyle(fontSize: 19))?.pointSize == 19)
        #expect(paragraphFont(ReaderStyle(fontSize: 26))?.pointSize == 26)
    }

    @Test func headingsAreLargerThanBodyAndTitleLargerStill() {
        let document = document(style: ReaderStyle(fontSize: 20))
        func size(at location: Int) -> CGFloat {
            (document.attributedText.attribute(.font, at: location, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
        }
        let body = size(at: document.blockRanges[0].location)
        let heading = size(at: document.blockRanges[1].location)
        let title = size(at: document.titleRange.location)
        #expect(heading > body)
        #expect(title > heading)
    }

    @Test func lineSpacingFollowsTheStyle() {
        func lineSpacing(_ spacing: ReaderStyle.LineSpacing) -> CGFloat {
            let document = document(style: ReaderStyle(lineSpacing: spacing))
            let paragraph = document.attributedText.attribute(.paragraphStyle, at: document.blockRanges[0].location, effectiveRange: nil)
            return (paragraph as? NSParagraphStyle)?.lineSpacing ?? -1
        }
        #expect(lineSpacing(.compact) < lineSpacing(.standard))
        #expect(lineSpacing(.standard) < lineSpacing(.relaxed))
    }

    @Test func outOfRangeFontSizeIsClamped() {
        #expect(ReaderStyle(fontSize: 3).clampedFontSize == CGFloat(ReaderStyle.sizeRange.lowerBound))
        #expect(ReaderStyle(fontSize: 300).clampedFontSize == CGFloat(ReaderStyle.sizeRange.upperBound))
        #expect(ReaderStyle(fontSize: 21).clampedFontSize == 21)
    }

    @Test func everyFontFamilyProducesAFont() {
        for family in ReaderStyle.FontFamily.allCases {
            #expect(family.font(size: 20, weight: .regular).pointSize == 20)
            #expect(family.font(size: 20, weight: .bold).pointSize == 20)
        }
    }
}

struct TapZoneTests {
    private func zone(_ y: CGFloat, top: CGFloat = 0, bottom: CGFloat = 0) -> ArticleTextView.TapZone {
        ArticleTextView.TapZone.zone(forY: y, viewHeight: 800, topInset: top, bottomInset: bottom)
    }

    @Test func topAndBottomStripsOpenMenus() {
        #expect(zone(0) == .top)
        #expect(zone(39) == .top)
        #expect(zone(41) == .middle)
        #expect(zone(799) == .bottom)
        #expect(zone(731) == .bottom)
        #expect(zone(729) == .middle)
    }

    @Test func insetsMoveTheStrips() {
        #expect(zone(59, top: 20) == .top)
        #expect(zone(61, top: 20) == .middle)
        #expect(zone(700, bottom: 34) == .bottom)
        #expect(zone(690, bottom: 34) == .middle)
    }

    @Test func middleOfTheScreenLooksUpWords() {
        #expect(zone(400, top: 59, bottom: 34) == .middle)
    }
}
