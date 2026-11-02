import Testing
@testable import WikiReader

struct LocalArticleParserTests {
    private func parse(_ text: String) -> ParsedLocalArticle {
        LocalArticleParser.parse(text)
    }

    private func texts(_ article: ParsedLocalArticle) -> [String] {
        article.blocks.map(\.text)
    }

    @Test func singleTitleHeadingNamesTheArticle() {
        let article = parse("""
        # The Tea Trade

        Tea came to Europe by sea.

        ## Early Years

        The first cargoes were small.
        """)
        #expect(article.title == "The Tea Trade")
        #expect(texts(article) == ["Tea came to Europe by sea.", "Early Years", "The first cargoes were small."])
        #expect(article.blocks[1] == .heading("Early Years", level: 2))
    }

    @Test func headingLevelsFollowTheHashes() {
        let article = parse("## A\n\n### B\n\n#### C\n\nText.")
        #expect(article.title == nil)
        #expect(article.blocks.map(\.level) == [2, 3, 4, 0])
    }

    @Test func severalTopHeadingsAreSectionsNotATitle() {
        let article = parse("# One\n\nA.\n\n# Two\n\nB.")
        #expect(article.title == nil)
        #expect(article.blocks[0] == .heading("One", level: 2))
        #expect(article.blocks[2] == .heading("Two", level: 2))
    }

    @Test func hardWrappedLinesJoinIntoOneParagraph() {
        let article = parse("The first line\ncontinues here\nand ends here.\n\nNext paragraph.")
        #expect(texts(article) == ["The first line continues here and ends here.", "Next paragraph."])
    }

    @Test func manyBlankLinesAreOneBreak() {
        #expect(texts(parse("A.\n\n\n\n   \nB.")) == ["A.", "B."])
    }

    @Test func windowsLineEndingsAndBOM() {
        #expect(texts(parse("\u{FEFF}# T\r\n\r\nA line.\r\n\r\nAnother.")) == ["A line.", "Another."])
    }

    @Test func listItemsBecomeSeparateParagraphs() {
        let article = parse("Words to learn:\n\n- ubiquitous\n- ephemeral, meaning short-lived\n* candid\n1. first\n2) second")
        #expect(texts(article) == ["Words to learn:", "ubiquitous", "ephemeral, meaning short-lived", "candid", "first", "second"])
    }

    @Test func aYearAtTheStartOfASentenceIsNotAListItem() {
        #expect(texts(parse("2009. was a year.\n\n2009 was a year.")) == ["2009. was a year.", "2009 was a year."])
    }

    @Test func inlineMarkdownIsRemoved() {
        let article = parse("This is **bold**, *italic*, _also italic_, `code`, ~~gone~~ and a [link](https://example.com) here.")
        #expect(texts(article) == ["This is bold, italic, also italic, code, gone and a link here."])
    }

    @Test func snakeCaseAndMultiplicationAreLeftAlone() {
        #expect(texts(parse("Use snake_case_names and 3 * 4 = 12.")) == ["Use snake_case_names and 3 * 4 = 12."])
    }

    @Test func imagesFootnotesAndHTMLAreDropped() {
        let article = parse("Text![alt](pic.png) with a note[^1] and<br>a break <b>bold</b>.\n\n[^1]: The note itself.")
        #expect(texts(article) == ["Text with a note and a break bold."])
    }

    @Test func escapedCharactersAreKept() {
        #expect(texts(parse(#"A \*star\* and 1\. one."#)) == ["A *star* and 1. one."])
    }

    @Test func tablesAndCodeAreSkippedAndCounted() {
        let article = parse("""
        Intro.

        | Word | Meaning |
        |------|---------|
        | tea  | a drink |

        ```
        let x = 1
        print(x)
        ```

        Outro.
        """)
        #expect(texts(article) == ["Intro.", "Outro."])
        #expect(article.skippedLines == 5)
    }

    @Test func rulesAndEmptyHeadingsAreIgnored() {
        #expect(texts(parse("A.\n\n---\n\n## \n\nB.\n\n***")) == ["A.", "B."])
    }

    @Test func blockquotesAreRead() {
        #expect(texts(parse("> A quoted line\n> continues.\n\nAfter.")) == ["A quoted line continues.", "After."])
    }

    @Test func hashtagIsNotAHeading() {
        #expect(texts(parse("#hashtag stays text.")) == ["#hashtag stays text."])
    }

    @Test func closingHashesAreDropped() {
        #expect(parse("## Title ##\n\nBody.").blocks.first == .heading("Title", level: 2))
    }

    @Test func plainTextWithoutMarkupIsParagraphs() {
        let article = parse("First paragraph.\n\nSecond paragraph.")
        #expect(article.title == nil)
        #expect(article.paragraphCount == 2)
    }

    @Test func emptyInputHasNothingToRead() {
        #expect(parse("  \n\n ").blocks.isEmpty)
        #expect(parse("# Only a title").paragraphCount == 0)
    }
}
