import Testing
import UIKit
@testable import WikiReader

/// Hit-testing on a real, laid-out UITextView configured like the reader's.
@MainActor
struct WordHitTests {
    let document = ArticleDocument(title: "Albert Einstein", blocks: [
        .heading("Early life", level: 2),
        .paragraph("He studies physics, and in 1879 – 1955 he was running fast."),
        .paragraph("Einstein's theory changed everything."),
    ])
    let textView: UITextView

    init() {
        textView = UITextView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        textView.attributedText = document.attributedText
        textView.layoutIfNeeded()
    }

    /// Screen rect of the first occurrence of `substring`.
    private func rect(of substring: String) throws -> CGRect {
        let range = (textView.text as NSString).range(of: substring)
        try #require(range.location != NSNotFound)
        let start = try #require(textView.position(from: textView.beginningOfDocument, offset: range.location))
        let end = try #require(textView.position(from: start, offset: range.length))
        let rect = textView.firstRect(for: try #require(textView.textRange(from: start, to: end)))
        try #require(!rect.isNull && !rect.isEmpty)
        return rect
    }

    private func word(at point: CGPoint) -> String? {
        textView.lookupWordRange(at: point).map { (textView.text as NSString).substring(with: $0) }
    }

    private func center(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test(arguments: ["studies", "physics", "running", "Einstein", "changed", "Early", "Albert"])
    func tapOnWordFindsIt(word expected: String) throws {
        #expect(word(at: center(try rect(of: expected))) == expected)
    }

    @Test func tapNearWordEdgesStillFindsIt() throws {
        let r = try rect(of: "physics")
        #expect(word(at: CGPoint(x: r.minX + 1, y: r.midY)) == "physics")
        #expect(word(at: CGPoint(x: r.maxX - 1, y: r.midY)) == "physics")
    }

    @Test func possessiveTapReturnsTheWord() throws {
        let tapped = word(at: center(try rect(of: "Einstein's")))
        #expect(tapped?.hasPrefix("Einstein") == true)
    }

    @Test(arguments: ["1879", "1955", "–", ","])
    func tapOnNumberOrPunctuationIsIgnored(token: String) throws {
        #expect(word(at: center(try rect(of: token))) == nil)
    }

    @Test func tapOnBlankSpaceIsIgnored() throws {
        let heading = try rect(of: "Early life")
        // Right of the short heading, same line.
        #expect(word(at: CGPoint(x: textView.bounds.width - 24, y: heading.midY)) == nil)
        // Below all text.
        #expect(word(at: CGPoint(x: 100, y: 700)) == nil)
    }

    @Test func contextMapsTappedWordToItsParagraph() throws {
        let range = (document.attributedText.string as NSString).range(of: "running")
        let context = try #require(document.context(for: range))
        #expect(context.text == "He studies physics, and in 1879 – 1955 he was running fast.")
        #expect(context.text[context.wordRange] == "running")
        #expect(document.blockIndex(containing: range.location) == 1)
    }

    @Test func blockRangeMapsToFullText() throws {
        let full = document.attributedText.string as NSString
        let inBlock = NSRange(location: 3, length: 7)  // "studies" in block 1
        let mapped = try #require(document.textRange(of: inBlock, inBlock: 1))
        #expect(full.substring(with: mapped) == "studies")
        #expect(document.textRange(of: NSRange(location: 0, length: 999), inBlock: 1) == nil)
        #expect(document.textRange(of: inBlock, inBlock: 9) == nil)
    }

    @Test func nearestBlockForTitleAndLineBreaks() {
        #expect(document.blockIndex(nearest: 0) == 0)  // title -> first block
        let lineBreak = document.blockRanges[1].location - 1
        #expect(document.blockIndex(nearest: lineBreak) == 1)
        #expect(document.blockIndex(nearest: document.blockRanges[2].location) == 2)
        #expect(document.blockIndex(nearest: document.attributedText.length + 5) == nil)
    }

    @Test func contextForTitle() throws {
        let range = (document.attributedText.string as NSString).range(of: "Albert")
        let context = try #require(document.context(for: range))
        #expect(context.text == "Albert Einstein")
        #expect(document.blockIndex(containing: range.location) == nil)
    }
}
