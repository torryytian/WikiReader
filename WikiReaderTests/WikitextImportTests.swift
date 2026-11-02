import Foundation
import Testing
@testable import WikiReader

struct WikitextImportTests {
    private func parse(_ text: String) -> ParsedLocalArticle {
        LocalArticleParser.parse(text)
    }

    @Test func wikiHeadingsBecomeSections() {
        let article = parse("Intro text.\n\n== History ==\nOld times.\n\n=== Early ===\nEarlier.")
        #expect(article.blocks == [
            .paragraph("Intro text."), .heading("History", level: 2), .paragraph("Old times."),
            .heading("Early", level: 3), .paragraph("Earlier."),
        ])
    }

    @Test func linksAndEmphasisKeepTheirWords() {
        let article = parse("== A ==\nSee ''[[Hedonic treadmill|hedonic adaptation]]'' and '''the [[IKEA effect]]''' and [[trade-off]]s.")
        #expect(article.blocks[1].text == "See hedonic adaptation and the IKEA effect and trade-offs.")
    }

    @Test func externalLinksKeepTheirLabel() {
        let article = parse("== A ==\nRead [https://example.com the report] and [https://example.org].")
        #expect(article.blocks[1].text == "Read the report and.")
    }

    @Test func templatesCommentsAndRefsAreRemoved() {
        let article = parse("{{Short description|An essay}}\n{{Infobox\n| a = {{nested|x}}\n}}\n== A ==\nText<ref>Source, p. 4</ref> here.<!-- hidden --> More<ref name=x />.")
        #expect(article.blocks.map(\.text) == ["A", "Text here. More."])
    }

    @Test func categoriesAndFilesAreRemoved() {
        let article = parse("== A ==\nBody.\n\n[[File:Tea.jpg|thumb|A cup]]\n[[Category:Essays]]\n[[Category:Happiness]]")
        #expect(article.blocks.map(\.text) == ["A", "Body."])
    }

    @Test func seeAlsoAndReferencesAreNotRead() {
        let article = parse("== Body ==\nText.\n\n== See also ==\n* [[One]]\n* [[Two]]\n\n== References ==\n* A book\n\n== After ==\nMore.")
        #expect(article.blocks.map(\.text) == ["Body", "Text.", "After", "More."])
    }

    @Test func listsAndTablesAreHandled() {
        let article = parse("== A ==\n* first\n* second with [[link]]\n# numbered\n\n{| class=\"wikitable\"\n|-\n! h\n|-\n| cell\n|}\nAfter.")
        #expect(article.blocks.map(\.text) == ["A", "first", "second with link", "numbered", "After."])
    }

    @Test func markdownWithAnEqualsSignIsNotWikitext() {
        #expect(!WikitextConverter.looksLikeWikitext("# Title\n\n== A ==\nText."))
        #expect(!WikitextConverter.looksLikeWikitext("Plain text with x = y."))
        #expect(WikitextConverter.looksLikeWikitext("== A ==\nText."))
    }

    @Test func wikiFilesAreTextFiles() {
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/Essay.wiki")) == .text)
        #expect(FileTextExtractor.kind(of: URL(filePath: "/a/Essay.mediawiki")) == .text)
    }

    @Test func theRealEssayFile() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "The_Paradox_of_Convenience", withExtension: "wiki"))
        let text = try FileTextExtractor.readText(at: url)
        let article = parse(text)

        #expect(article.title == nil)
        #expect(article.blocks.filter { $0.kind == .heading }.map(\.text) == [
            "Hedonic adaptation", "Effort as a source of meaning", "Convenience and time",
            "Trade-offs", "Deliberate friction", "Conclusion",
        ])
        #expect(article.paragraphCount == 7)
        let all = article.blocks.map(\.text).joined(separator: " ")
        for leftover in ["[[", "]]", "{{", "''", "==", "Category", "Short description", "See also"] {
            #expect(!all.contains(leftover), "left over: \(leftover)")
        }
        #expect(all.contains("quietly absorbed by technology."))
        #expect(all.contains("hedonic adaptation: the tendency"))
        #expect(all.contains("trade-offs that are easy to overlook"))
        #expect(all.contains("rather than outsource it"))
    }

    private final class BundleToken {}
}
