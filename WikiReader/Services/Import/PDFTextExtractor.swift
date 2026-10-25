import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// Reads the text of a PDF. Text PDFs are read directly (with font sizes, so headings can be told from body text);
/// pages that are only a picture (a scan) are recognized like a photo.
nonisolated enum PDFTextExtractor {
    /// Pages with fewer characters than this are treated as scans.
    static let minimumTextCharacters = 20

    static func markdown(from url: URL) throws(ImportFileError) -> String {
        guard let document = PDFDocument(url: url) else { throw .unreadable("it isn't a valid PDF") }
        if document.isLocked, !document.unlock(withPassword: "") { throw .encrypted }

        var textLines: [TextLine] = []
        var scanned = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageText.count >= minimumTextCharacters {
                textLines += lines(on: page, index: index)
            } else if let picture = render(page) {
                scanned += 1
                let found = try ImageTextRecognizer.lines(in: picture, page: index)
                textLines += found
            }
        }
        // A scan's line sizes are box heights, which need the looser heading rule.
        let assembler = TextLineAssembler(headingRatio: scanned > document.pageCount / 2 ? 1.35 : 1.15)
        return assembler.markdown(from: textLines)
    }

    /// The lines of one page with their font size, boldness and position.
    private static func lines(on page: PDFPage, index: Int) -> [TextLine] {
        guard let attributed = page.attributedString else { return [] }
        let string = attributed.string as NSString
        let pageBounds = page.bounds(for: .mediaBox)
        var lines: [TextLine] = []

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { _, range, _, _ in
            let text = string.substring(with: range).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }

            var size: CGFloat = 0
            var boldCharacters = 0
            var characters = 0
            attributed.enumerateAttribute(.font, in: range) { value, run, _ in
                guard let font = value as? UIFont else { return }
                size = max(size, font.pointSize)
                characters += run.length
                if font.fontDescriptor.symbolicTraits.contains(.traitBold) { boldCharacters += run.length }
            }
            guard let bounds = page.selection(for: range)?.bounds(for: page), bounds.height > 0 else { return }

            lines.append(TextLine(
                text: text, size: size, isBold: characters > 0 && boldCharacters * 2 > characters,
                minX: bounds.minX, maxX: bounds.maxX,
                // PDF coordinates grow upward; the assembler measures from the top.
                top: pageBounds.maxY - bounds.maxY, height: bounds.height,
                page: index, pageHeight: pageBounds.height
            ))
        }
        return lines
    }

    /// A page drawn as a picture for text recognition.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 2200 / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        return image.cgImage
    }
}
