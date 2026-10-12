import Foundation
import Testing
@testable import WikiReader

/// Wraps body markup the way `action=parse` returns it.
private func page(_ body: String) -> String {
    "<div class=\"mw-content-ltr mw-parser-output\">\(body)</div>"
}

private func heading(_ level: Int, _ title: String) -> String {
    "<div class=\"mw-heading mw-heading\(level)\"><h\(level) id=\"x\">\(title)</h\(level)></div>"
}

struct ArticleCleanerTests {
    // MARK: - Sections

    @Test func headingsKeepLevels() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            <p>Lead paragraph.</p>
            \(heading(2, "History"))<p>Text.</p>
            \(heading(3, "Early life"))<p>More text.</p>
            """))
        #expect(blocks == [
            .paragraph("Lead paragraph."),
            .heading("History", level: 2),
            .paragraph("Text."),
            .heading("Early life", level: 3),
            .paragraph("More text."),
        ])
    }

    @Test func excludedSectionsAndSubsectionsAreRemoved() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            <p>Lead.</p>
            \(heading(2, "Legacy"))<p>Kept.</p>
            \(heading(2, "References"))<p>Ref text.</p>
            \(heading(3, "Citations"))<p>Citation text.</p>
            \(heading(2, "SEE ALSO"))<ul><li>Link.</li></ul>
            \(heading(2, "Works Cited"))<p>Book.</p>
            \(heading(2, "Afterword"))<p>Also kept.</p>
            """))
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
        let blocks = ArticleCleaner.blocks(fromHTML: page("<p>Lead.</p>\(heading(2, name.uppercased()))<p>Gone.</p>"))
        #expect(blocks == [.paragraph("Lead.")])
    }

    @Test func sectionsLeftEmptyAreRemoved() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            <p>Lead.</p>
            \(heading(2, "Notes and references"))
            \(heading(3, "Notes"))<p>A note.</p>
            \(heading(3, "References"))<p>A ref.</p>
            """))
        #expect(blocks == [.paragraph("Lead.")])
    }

    @Test func whitespaceAndEntitiesAreNormalised() {
        let blocks = ArticleCleaner.blocks(fromHTML: page(
            "<p>First   paragraph\n here.</p>\n\n<p>Second&#160;one &amp; <b>bold</b>&nbsp;&#x2013; &lt;done&gt;. </p>"
        ))
        #expect(blocks == [.paragraph("First paragraph here."), .paragraph("Second one & bold – <done>.")])
    }

    // MARK: - Kept and skipped markup

    @Test func listItemsAreKeptAsBlocks() {
        let blocks = ArticleCleaner.blocks(fromHTML: page(
            "<p>Intro:</p><ul><li>One</li><li>Two<ul><li>Nested</li></ul> and after</li></ul><p>End.</p>"
        ))
        #expect(blocks == [
            .paragraph("Intro:"), .paragraph("One"), .paragraph("Two"), .paragraph("Nested"),
            .paragraph("and after"), .paragraph("End."),
        ])
    }

    @Test func excerptParagraphsAreKeptButItsHatnoteIsNot() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            \(heading(3, "Great Leap Forward"))
            <div class="excerpt-block"><style>.x{color:red}</style><link rel="mw-deduplicated-inline-style" href="x" />
            <div role="note" class="hatnote navigation-not-searchable dablink excerpt-hat selfref">This paragraph is an excerpt from <a href="/wiki/Great_Leap_Forward">Great Leap Forward</a>.<span class="mw-editsection-like"><span>[</span><a href="x">edit</a><span>]</span></span></div>
            <div class="excerpt"><p>The Great Leap Forward was a campaign.<sup class="reference"><a href="#n">[6]</a></sup></p></div></div>
            <p>On 11 January 1962, a conference was held.</p>
            """))
        #expect(blocks == [
            .heading("Great Leap Forward", level: 3),
            .paragraph("The Great Leap Forward was a campaign."),
            .paragraph("On 11 January 1962, a conference was held."),
        ])
    }

    @Test func imagesCaptionsQuoteBoxesHatnotesAndBoxesAreSkipped() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            <div class="shortdescription nomobile noexcerpt noprint searchaux" style="display:none">Short description</div>
            <div class="hatnote navigation-not-searchable" role="note">Main article: <a href="x">Foo</a></div>
            <table class="infobox"><tr><td><p>Born in a box.</p></td></tr></table>
            <p>Lead text.</p>
            <figure class="mw-default-size"><a href="x"><img src="y" /></a><figcaption>A caption that must not be read.</figcaption></figure>
            <div class="thumb tright"><div class="thumbinner"><div class="thumbcaption">Another caption.</div></div></div>
            <blockquote class="templatequote"><p>A long quotation.</p></blockquote>
            <div class="templatequotecite"><p>— Someone</p></div>
            <div class="quotebox pullquote floatright"><blockquote><p>Pull quote.</p></blockquote></div>
            <div class="navbox"><ul><li>Navigation</li></ul></div>
            <div class="box-Multiple_issues plainlinks metadata ambox ambox-multiple_issues"><p>This article needs work.</p></div>
            <div class="div-col"><ul><li>Algiers, 2003</li></ul></div>
            <p>Closing text.</p>
            """))
        #expect(blocks == [.paragraph("Lead text."), .paragraph("Closing text.")])
    }

    @Test func footnoteMarkersEditLinksAndHiddenCoordinatesAreDropped() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            <p>It was seen at 6°56′12″N 103°35′6″E<span class="geo-nondefault"><span class="geo-multi-punct">&#160;/&#160;</span><span class="geo-dec">6.93667°N 103.58500°E</span><span style="display:none">&#160;/ <span class="geo">6.93667; 103.58500</span> (<span class="fn org">Waypoint</span>)</span></span>.<sup id="cite_ref-1" class="reference"><a href="#cite_note-1"><span class="cite-bracket">&#91;</span>1<span class="cite-bracket">&#93;</span></a></sup> Then<sup class="noprint Inline-Template">[<i>citation needed</i>]</sup> it left. 10<sup>6</sup> times.</p>
            """))
        #expect(blocks == [.paragraph("It was seen at 6°56′12″N 103°35′6″E. Then it left. 106 times.")])
    }

    @Test func bibliographyEntriesAreSkipped() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            \(heading(2, "Publications"))\(heading(3, "Scientific"))
            <ul><li><cite class="citation journal cs1">Einstein, Albert (1905). A paper.</cite></li></ul>
            \(heading(2, "Legacy"))<p>Remembered.</p>
            """))
        #expect(blocks == [.heading("Legacy", level: 2), .paragraph("Remembered.")])
    }

    @Test func inlineMathIsDroppedAndTheSentenceStaysReadable() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            <p>Two squares whose sides have a measure of <span class="mwe-math-element"><span class="mwe-math-mathml-inline"><math alttext="{\\displaystyle a+b}"><mrow><mi>a</mi></mrow></math></span><img src="x" alt="{\\displaystyle a+b}" /></span> and which contain four triangles.</p>
            <p>The equation:</p><dl><dd><span class="mwe-math-element"><math><mi>c</mi></math></span></dd></dl><p>is named for Pythagoras.</p>
            """))
        #expect(blocks == [
            .paragraph("Two squares whose sides have a measure of and which contain four triangles."),
            .paragraph("The equation:"),
            .paragraph("is named for Pythagoras."),
        ])
    }

    @Test func displayFormulaInsideAParagraphSplitsIt() {
        let blocks = ArticleCleaner.blocks(fromHTML: page("""
            <p>The Pythagorean equation:<sup class="reference"><a href="#n">[2]</a></sup> <span class="mwe-math-element mwe-math-element-block"><span class="mwe-math-mathml-a11y" style="display: none;"><math><mi>c</mi></math></span><img src="x" alt="c" /></span> The theorem is named for Pythagoras.</p>
            """))
        #expect(blocks == [
            .paragraph("The Pythagorean equation:"),
            .paragraph("The theorem is named for Pythagoras."),
        ])
    }

    @Test func brokenMarkupDoesNotCrash() {
        #expect(ArticleCleaner.blocks(fromHTML: "").isEmpty)
        #expect(ArticleCleaner.blocks(fromHTML: "<p>Open paragraph <b>never closed") == [.paragraph("Open paragraph never closed")])
        #expect(ArticleCleaner.blocks(fromHTML: "<p>1 < 2 and 3 > 2 &unknown; &#xZZ;</p>") == [.paragraph("1 < 2 and 3 > 2 &unknown; &#xZZ;")])
        #expect(ArticleCleaner.blocks(fromHTML: "</div></p><p>Stray end tags.</p><!-- comment <p>no</p> -->") == [.paragraph("Stray end tags.")])
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

    @Test func excerptSectionIsKept() throws {
        // Real markup from "Cultural Revolution": the "Great Leap Forward" subsection is an excerpt from another
        // article, which TextExtracts leaves out entirely.
        let blocks = try Fixture.blocks("excerpt_section")
        #expect(blocks.contains(.heading("Great Leap Forward", level: 3)))
        let excerpt = try #require(blocks.first { $0.text.hasPrefix("The Great Leap Forward was an industrialization campaign") })
        #expect(excerpt.text.hasSuffix("largest or second-largest famine in human history."))
        #expect(!blocks.contains { $0.text.contains("This paragraph is an excerpt") })
        #expect(blocks.contains { $0.text.hasPrefix("On 11 January 1962, an enlarged Central Committee") })
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
