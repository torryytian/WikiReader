import Foundation
import Testing
@testable import WikiReader

struct ArticleCleanerTests {
    // MARK: - Sections

    @Test func headingsKeepLevels() {
        let blocks = ArticleCleaner.blocks(from: """
            Lead paragraph.

            == History ==
            Text.

            === Early life ===
            More text.
            """)
        #expect(blocks == [
            .paragraph("Lead paragraph."),
            .heading("History", level: 2),
            .paragraph("Text."),
            .heading("Early life", level: 3),
            .paragraph("More text."),
        ])
    }

    @Test func excludedSectionsAndSubsectionsAreRemoved() {
        let blocks = ArticleCleaner.blocks(from: """
            Lead.

            == Legacy ==
            Kept.

            == References ==
            Ref text.

            === Citations ===
            Citation text.

            == SEE ALSO ==
            Link.

            == Works Cited ==
            Book.

            == Afterword ==
            Also kept.
            """)
        #expect(blocks == [
            .paragraph("Lead."),
            .heading("Legacy", level: 2),
            .paragraph("Kept."),
            .heading("Afterword", level: 2),
            .paragraph("Also kept."),
        ])
    }

    @Test(arguments: ["See also", "References", "Notes", "Footnotes", "Citations", "Sources",
                      "Bibliography", "Works cited", "Further reading", "External links"])
    func everyExcludedSectionIsRemoved(name: String) {
        let blocks = ArticleCleaner.blocks(from: "Lead.\n\n== \(name.uppercased()) ==\nGone.")
        #expect(blocks == [.paragraph("Lead.")])
    }

    @Test func sectionsLeftEmptyAreRemoved() {
        let blocks = ArticleCleaner.blocks(from: """
            Lead.

            == Notes and references ==

            === Notes ===
            A note.

            === References ===
            A ref.
            """)
        #expect(blocks == [.paragraph("Lead.")])
    }

    @Test func blankLinesAndSpacesAreCollapsed() {
        let blocks = ArticleCleaner.blocks(from: "First   paragraph  here.\n\n\n\nSecond\u{00A0}one. \n")
        #expect(blocks == [.paragraph("First paragraph here."), .paragraph("Second one.")])
    }

    // MARK: - Pronunciation

    @Test(arguments: [
        // Classic Wikipedia lead formats.
        ("Paris (French pronunciation: [paʁi] ⓘ) is the capital of France.",
         "Paris is the capital of France."),
        ("Albert Einstein (/ˈaɪnstaɪn/ EYEN-styne; German: [ˈalbɛʁt ˈʔaɪnʃtaɪn] ⓘ; 14 March 1879 – 18 April 1955) was a physicist.",
         "Albert Einstein (14 March 1879 – 18 April 1955) was a physicist."),
        ("Paris (English: /ˈpærɪs/; French: [paʁi] (listen)) is a city.",
         "Paris is a city."),
        ("Lutetia ( ; Latin) was a town.",
         "Lutetia (Latin) was a town."),
        ("A town ( ) here.", "A town here."),
        // From the current Paris article (Etymology section).
        ("Parisians and in French as Parisiens ([paʁizjɛ̃] ). They are also called Parigots ([paʁiɡo] ).",
         "Parisians and in French as Parisiens. They are also called Parigots."),
        // Outside parentheses.
        ("It is called Lutèce [lytɛs] in French.", "It is called Lutèce in French."),
    ])
    func pronunciationIsRemoved(input: String, expected: String) {
        #expect(ArticleCleaner.cleanInline(input) == expected)
    }

    @Test(arguments: [
        "\"[the] intellectual needs of this nation\"",
        "Born (in Ulm) in 1879.",
        "Plato (428/427 or 424/423 – 348/347 BC) taught.",
        "The ratios a/R, b/R tend to zero.",
        "Hawaiʻi (state) is in the Pacific.",
    ])
    func normalBracketsAreKept(text: String) {
        #expect(ArticleCleaner.cleanInline(text) == text)
    }

    // MARK: - Citations

    @Test(arguments: [
        ("Einstein was born in 1879.[1] He died in 1955.[2][3]", "Einstein was born in 1879. He died in 1955."),
        ("A claim[citation needed] here.", "A claim here."),
        ("A note[a] and [note 3] and [Citation Needed].", "A note and and."),
        ("Dubious[dubious – discuss] claim.", "Dubious claim."),
    ])
    func citationMarkersAreRemoved(input: String, expected: String) {
        #expect(ArticleCleaner.cleanInline(input) == expected)
    }

    // MARK: - Formulas

    // Built from arrays because the leading whitespace on each line is significant
    // and multi-line string literals would strip it.

    @Test func inlineFormulaJoinsSentence() {
        let extract = [
            "Two squares whose sides have a measure of ",
            "  ",
            "    ",
            "      ",
            "        a",
            "        +",
            "        b",
            "      ",
            "    ",
            "    {\\displaystyle a+b}",
            "  ",
            " and which contain four triangles.",
        ].joined(separator: "\n")
        #expect(ArticleCleaner.blocks(from: extract) == [
            .paragraph("Two squares whose sides have a measure of and which contain four triangles."),
        ])
    }

    @Test func displayFormulaBecomesParagraphBreak() {
        let extract = [
            "The Pythagorean equation:",
            "",
            "  ",
            "    ",
            "      c",
            "      =",
            "      1",
            "    ",
            "    {\\textstyle c=1.}",
            "  ",
            "",
            "The theorem is named for Pythagoras.",
        ].joined(separator: "\n")
        #expect(ArticleCleaner.blocks(from: extract) == [
            .paragraph("The Pythagorean equation:"),
            .paragraph("The theorem is named for Pythagoras."),
        ])
    }

    @Test func formulaLeftoversAreTidied() {
        #expect(ArticleCleaner.cleanInline("such as \u{2060} \u{2060}, \u{2060} \u{2060}, \u{2060} \u{2060}. More") == "such as. More")
        #expect(ArticleCleaner.cleanInline("triangles (A and B ) built") == "triangles (A and B) built")
    }

    // MARK: - Real articles (fixtures)

    @Test(arguments: ["albert_einstein", "paris", "pythagorean_theorem"])
    func fixtureHasNoResidue(name: String) throws {
        let blocks = try Fixture.blocks(name)
        let headings = Set(blocks.filter { $0.kind == .heading }.map { $0.text.lowercased() })
        #expect(headings.isDisjoint(with: ArticleCleaner.excludedSections))

        for block in blocks {
            #expect(!block.text.isEmpty)
            #expect(!block.text.contains("displaystyle"))
            #expect(!block.text.contains("textstyle"))
            #expect(!block.text.contains("{\\"))
            #expect(!block.text.contains("()"))
            #expect(!block.text.contains("( )"))
            #expect(!block.text.contains("( ;"))
            #expect(!block.text.contains("  "))
            #expect(!block.text.contains("\u{2060}"))
            #expect(block.text.firstMatch(of: #/\[\d+\]|\[citation needed\]/#) == nil)
            #expect(block.text == block.text.trimmingCharacters(in: .whitespaces))
        }
    }

    @Test func einsteinStructure() throws {
        let blocks = try Fixture.blocks("albert_einstein")
        #expect(blocks.first?.text.hasPrefix("Albert Einstein (14 March 1879 – 18 April 1955) was a German-born theoretical physicist") == true)
        #expect(blocks.contains(.heading("Life and career", level: 2)))
        #expect(blocks.contains(.heading("Childhood, youth and education", level: 3)))
        #expect(blocks.contains { $0.text.contains("\"[the] intellectual needs") })
        #expect(!blocks.contains { $0.text == "External links" || $0.text == "Footnotes" })
    }

    @Test func parisPronunciationRemoved() throws {
        let text = try Fixture.blocks("paris").map(\.text).joined(separator: "\n")
        #expect(text.hasPrefix("Paris is the capital and largest city of France"))
        #expect(text.contains("in French as Parisiens. They are also pejoratively called Parigots."))
        #expect(!text.contains("paʁi"))
    }

    @Test func pythagoreanFormulasRemoved() throws {
        let blocks = try Fixture.blocks("pythagorean_theorem")
        let text = blocks.map(\.text).joined(separator: "\n")
        #expect(text.contains("whose sides have a measure of and which contain four right triangles"))
        #expect(blocks.contains(.paragraph(
            "The theorem can be written as an equation relating the lengths of the sides a, b and the hypotenuse c, sometimes called the Pythagorean equation:"
        )))
        #expect(blocks.contains(.heading("Spherical geometry", level: 4)))
        #expect(!blocks.contains { $0.text == "Notes and references" })
    }
}
