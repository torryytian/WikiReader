import Foundation
import Testing
@testable import WikiReader

struct ArticleInputTests {
    @Test(arguments: [
        ("https://en.wikipedia.org/wiki/Albert_Einstein", "Albert Einstein"),
        ("https://en.m.wikipedia.org/wiki/Albert_Einstein", "Albert Einstein"),
        ("http://en.wikipedia.org/wiki/Albert_Einstein", "Albert Einstein"),
        ("en.wikipedia.org/wiki/Albert_Einstein", "Albert Einstein"),
        ("HTTPS://EN.WIKIPEDIA.ORG/wiki/Albert_Einstein", "Albert Einstein"),
        ("https://en.wikipedia.org/w/index.php?title=Albert_Einstein&oldid=1", "Albert Einstein"),
    ])
    func links(input: String, expected: String) throws {
        #expect(try ArticleInput.title(from: input) == expected)
    }

    @Test func fragmentIsDropped() throws {
        #expect(try ArticleInput.title(from: "https://en.wikipedia.org/wiki/Albert_Einstein#Early_life") == "Albert Einstein")
        #expect(try ArticleInput.title(from: "Albert Einstein#Early life") == "Albert Einstein")
    }

    @Test func percentEncodingIsDecoded() throws {
        #expect(try ArticleInput.title(from: "https://en.wikipedia.org/wiki/C%2B%2B") == "C++")
        #expect(try ArticleInput.title(from: "https://en.wikipedia.org/wiki/Caf%C3%A9") == "Café")
        #expect(try ArticleInput.title(from: "https://en.wikipedia.org/wiki/Pythagorean_theorem%23Proofs") == "Pythagorean theorem#Proofs")
    }

    @Test func bareTitles() throws {
        #expect(try ArticleInput.title(from: "Albert Einstein") == "Albert Einstein")
        #expect(try ArticleInput.title(from: "  Albert_Einstein \n") == "Albert Einstein")
        #expect(try ArticleInput.title(from: "Einstein") == "Einstein")
        #expect(try ArticleInput.title(from: "C++") == "C++")
        #expect(try ArticleInput.title(from: "100% (album)") == "100% (album)")
    }

    @Test func emptyInput() {
        #expect(throws: ArticleInput.ParseError.empty) { try ArticleInput.title(from: "   ") }
        #expect(throws: ArticleInput.ParseError.empty) { try ArticleInput.title(from: "#Section") }
    }

    @Test func otherSitesAreRejected() {
        #expect(throws: ArticleInput.ParseError.unsupportedHost("fr.wikipedia.org")) {
            try ArticleInput.title(from: "https://fr.wikipedia.org/wiki/Paris")
        }
        #expect(throws: ArticleInput.ParseError.unsupportedHost("www.google.com")) {
            try ArticleInput.title(from: "https://www.google.com/search?q=paris")
        }
    }

    @Test func nonArticleLinksAreRejected() {
        #expect(throws: ArticleInput.ParseError.notAnArticleLink) {
            try ArticleInput.title(from: "https://en.wikipedia.org/")
        }
        #expect(throws: ArticleInput.ParseError.notAnArticleLink) {
            try ArticleInput.title(from: "https://en.wikipedia.org/wiki/")
        }
    }

    @Test func canonicalURL() {
        #expect(ArticleInput.articleURL(forTitle: "Albert Einstein").absoluteString == "https://en.wikipedia.org/wiki/Albert_Einstein")
        #expect(ArticleInput.articleURL(forTitle: "C++").absoluteString == "https://en.wikipedia.org/wiki/C++")
    }
}
