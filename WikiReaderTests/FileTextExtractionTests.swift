import CoreGraphics
import Foundation
import PDFKit
import Testing
import UIKit
@testable import WikiReader

// MARK: - Assembling lines

struct TextLineAssemblerTests {
    private func line(
        _ text: String, size: CGFloat = 12, bold: Bool = false, top: CGFloat, page: Int = 0,
        minX: CGFloat = 50, maxX: CGFloat = 550
    ) -> TextLine {
        TextLine(text: text, size: size, isBold: bold, minX: minX, maxX: maxX, top: top, height: size, page: page, pageHeight: 800)
    }

    private func assemble(_ lines: [TextLine]) -> String {
        TextLineAssembler().markdown(from: lines)
    }

    @Test func largerTextBecomesHeadings() {
        let text = assemble([
            line("The Tea Trade", size: 28, top: 100),
            line("Early Years", size: 18, top: 160),
            line("Tea came to Europe by sea.", top: 200),
        ])
        #expect(text == "# The Tea Trade\n\n## Early Years\n\nTea came to Europe by sea.")
    }

    @Test func wrappedLinesJoinAndALargerGapStartsAParagraph() {
        let text = assemble([
            line("This sentence runs over", top: 200),
            line("two lines of the page.", top: 216),
            line("A second paragraph begins", top: 250),
            line("right here.", top: 266),
        ])
        #expect(text == "This sentence runs over two lines of the page.\n\nA second paragraph begins right here.")
    }

    @Test func aShortLineAfterAFullStopEndsTheParagraph() {
        let text = assemble([
            line("A full line of text that reaches the edge of the page and goes on", top: 200),
            line("and ends here.", top: 216, maxX: 200),
            line("The next paragraph starts here with no extra gap at all.", top: 232),
        ])
        #expect(text == "A full line of text that reaches the edge of the page and goes on and ends here.\n\nThe next paragraph starts here with no extra gap at all.")
    }

    @Test func hyphenatedWordsAreRejoined() {
        let text = assemble([
            line("The merchants were interna-", top: 200),
            line("tional in outlook.", top: 216),
        ])
        #expect(text == "The merchants were international in outlook.")
    }

    @Test func aParagraphContinuesOverAPageBreak() {
        let text = assemble([
            line("A sentence that has not", top: 700, page: 0),
            line("finished when the page ends.", top: 60, page: 1),
        ])
        #expect(text == "A sentence that has not finished when the page ends.")
    }

    @Test func pageNumbersAndRepeatedHeadersAreDropped() {
        var lines: [TextLine] = []
        for page in 0..<4 {
            lines.append(line("Tea Trade Review", size: 9, top: 20, page: page))
            lines.append(line("Body text on page \(page + 1) goes here.", top: 300, page: page))
            lines.append(line("\(page + 1)", size: 9, top: 770, page: page))
        }
        let text = assemble(lines)
        #expect(!text.contains("Tea Trade Review"))
        #expect(!text.contains("\n\n4"))
        #expect(text.contains("Body text on page 1"))
    }

    @Test func boldShortLinesAreHeadingsWhenBoldIsRare() {
        let text = assemble([
            line("Where tea grew", bold: true, top: 100),
            line("Mostly in the hills of Assam and the south of China, where the rain is steady.", top: 130),
            line("It was picked by hand through the spring and early summer months every year.", top: 146),
        ])
        #expect(text.hasPrefix("# Where tea grew\n\nMostly in the hills"))
    }

    @Test func bulletLinesBecomeListItems() {
        let text = assemble([
            line("Words to learn", size: 18, top: 100),
            line("• ubiquitous", top: 140),
            line("• ephemeral", top: 156),
        ])
        #expect(text == "# Words to learn\n\n- ubiquitous\n\n- ephemeral")
    }

    @Test func pageNumberShapes() {
        #expect(TextLineAssembler.isPageNumber("12"))
        #expect(TextLineAssembler.isPageNumber("Page 3 of 10"))
        #expect(TextLineAssembler.isPageNumber("3/10"))
        #expect(!TextLineAssembler.isPageNumber("In 1999 it grew"))
    }

    @Test func noLinesNoText() {
        #expect(assemble([]) == "")
    }
}

// MARK: - Files

struct FileTextExtractorTests {
    private func temporaryFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "extract-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func kindsFollowTheFileExtension() {
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/b.txt")) == .text)
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/b.MD")) == .text)
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/b.markdown")) == .text)
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/b.pdf")) == .pdf)
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/b.PNG")) == .image)
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/b.jpeg")) == .image)
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/b.docx")) == nil)
    }

    @Test func titlesComeFromFileNames() {
        #expect(FileTextExtractor.suggestedTitle(forFileNamed: "the_tea-trade") == "the tea trade")
        #expect(FileTextExtractor.suggestedTitle(forFileNamed: "___") == "Imported Article")
    }

    @Test func markdownFileIsRead() async throws {
        let url = try temporaryFile("tea_trade.md", Data("# Tea\n\nA paragraph.".utf8))
        let extracted = try await FileTextExtractor.extract(from: url)
        #expect(extracted.text == "# Tea\n\nA paragraph.")
        #expect(extracted.suggestedTitle == "tea trade")
    }

    @Test func utf16AndWindowsTextAreDecoded() async throws {
        let utf16 = try temporaryFile("a.txt", "Café au lait.".data(using: .utf16)!)
        #expect(try await FileTextExtractor.extract(from: utf16).text == "Café au lait.")

        let windows = try temporaryFile("b.txt", "It’s fine.".data(using: .windowsCP1252)!)
        #expect(try await FileTextExtractor.extract(from: windows).text == "It’s fine.")
    }

    @Test func emptyFileHasNoText() async throws {
        let url = try temporaryFile("empty.txt", Data("  \n ".utf8))
        await #expect(throws: ImportFileError.noText) { try await FileTextExtractor.extract(from: url) }
    }

    @Test func unknownTypeIsRefused() async throws {
        let url = try temporaryFile("report.docx", Data("x".utf8))
        await #expect(throws: ImportFileError.unsupported("report.docx")) { try await FileTextExtractor.extract(from: url) }
    }

    @Test func brokenPDFIsReported() async throws {
        let url = try temporaryFile("broken.pdf", Data("not a pdf".utf8))
        await #expect(throws: ImportFileError.unreadable("it isn't a valid PDF")) { try await FileTextExtractor.extract(from: url) }
    }
}

// MARK: - PDF and photos

struct PDFAndImageExtractionTests {
    /// A one-column page like one printed from a document: a title, a section heading, two paragraphs.
    private func makePDF() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let body = "Tea came to Europe by sea in the early seventeenth century. The first cargoes were small, and the leaves were sold as a medicine by apothecaries in London and Amsterdam."
        let second = "Within fifty years the drink had spread to every port city. Merchants built fortunes on it, and governments soon learned to tax it heavily."
        return renderer.pdfData { context in
            context.beginPage()
            func draw(_ text: String, font: UIFont, y: CGFloat, height: CGFloat) {
                (text as NSString).draw(
                    in: CGRect(x: 72, y: y, width: 468, height: height),
                    withAttributes: [.font: font, .foregroundColor: UIColor.black]
                )
            }
            draw("The Tea Trade", font: .boldSystemFont(ofSize: 28), y: 72, height: 40)
            draw("Early Years", font: .boldSystemFont(ofSize: 18), y: 130, height: 30)
            draw(body, font: .systemFont(ofSize: 12), y: 175, height: 80)
            draw(second, font: .systemFont(ofSize: 12), y: 285, height: 60)
        }
    }

    @Test func textPDFKeepsHeadingsAndParagraphs() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tea-\(UUID().uuidString).pdf")
        try makePDF().write(to: url)

        let extracted = try await FileTextExtractor.extract(from: url)
        let article = LocalArticleParser.parse(extracted.text)

        #expect(article.title == "The Tea Trade")
        #expect(article.blocks.first == .heading("Early Years", level: 2))
        #expect(article.paragraphCount == 2)
        #expect(article.blocks[1].text.hasPrefix("Tea came to Europe by sea"))
        #expect(article.blocks[1].text.hasSuffix("London and Amsterdam."))
        #expect(!article.blocks[1].text.contains("\n"))
        #expect(article.blocks[2].text.hasPrefix("Within fifty years"))
    }

    /// A picture of text, big and clear.
    private func makeImage() -> UIImage {
        let size = CGSize(width: 1200, height: 800)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.black]
            ("Tea came to Europe by sea." as NSString).draw(at: CGPoint(x: 60, y: 100), withAttributes: attributes)
            ("The first cargoes were small." as NSString).draw(at: CGPoint(x: 60, y: 200), withAttributes: attributes)
        }
    }

    @Test func photoTextIsRecognized() async throws {
        let data = try #require(makeImage().pngData())
        let extracted = try await FileTextExtractor.extract(imageData: [data], title: "Photo")
        let text = extracted.text.lowercased()
        #expect(text.contains("tea came to europe"))
        #expect(text.contains("first cargoes"))
    }

    @Test func aBlankPhotoHasNoText() async throws {
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        }
        let data = try #require(blank.pngData())
        await #expect(throws: ImportFileError.noText) { try await FileTextExtractor.extract(imageData: [data], title: "Blank") }
    }
}
