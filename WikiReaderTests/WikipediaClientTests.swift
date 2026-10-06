import Foundation
import Testing
@testable import WikiReader

struct WikipediaClientTests {
    @Test func requestURLHasRequiredParameters() throws {
        let url = WikipediaClient.requestURL(forTitle: "Albert Einstein")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "en.wikipedia.org")
        #expect(query["prop"] == "extracts")
        #expect(query["explaintext"] == "1")
        #expect(query["exsectionformat"] == "wiki")
        #expect(query["redirects"] == "1")
        #expect(query["formatversion"] == "2")
        #expect(query["titles"] == "Albert Einstein")
    }

    @Test func plusSignIsEscaped() {
        // An unescaped "+" would be read by the API as a space.
        let url = WikipediaClient.requestURL(forTitle: "C++")
        #expect(url.absoluteString.hasSuffix("titles=C%2B%2B"))
    }

    @Test func userAgentHasContact() {
        #expect(WikipediaClient.userAgent.hasPrefix("WikiReader/0.1 (personal app; contact: "))
        #expect(!WikipediaClient.userAgent.contains("YOUR_EMAIL"))
    }

    @Test func parsesArticle() throws {
        let article = try Fixture.article("albert_einstein")
        #expect(article.title == "Albert Einstein")
        #expect(article.extract.hasPrefix("Albert Einstein ("))
        #expect(article.extract.contains("== Life and career =="))
    }

    @Test func followsRedirect() throws {
        // Requested "Einstein"; the API resolved the redirect.
        #expect(try Fixture.article("redirect_einstein").title == "Albert Einstein")
    }

    @Test func missingPage() {
        #expect(throws: WikipediaError.pageNotFound(title: "Asdfqwerzxcv123")) {
            try Fixture.article("missing_page")
        }
    }

    @Test func invalidTitle() {
        let json = #"{"batchcomplete":true,"query":{"pages":[{"title":"[]","invalidreason":"bad","invalid":true}]}}"#
        #expect(throws: WikipediaError.invalidTitle(title: "[]")) {
            try WikipediaClient.parseResponse(Data(json.utf8))
        }
    }

    @Test func emptyExtract() {
        let json = #"{"query":{"pages":[{"pageid":1,"ns":0,"title":"Empty","extract":"  "}]}}"#
        #expect(throws: WikipediaError.emptyArticle(title: "Empty")) {
            try WikipediaClient.parseResponse(Data(json.utf8))
        }
    }

    @Test func garbageResponse() {
        #expect(throws: WikipediaError.badResponse) { try WikipediaClient.parseResponse(Data("<html>".utf8)) }
        #expect(throws: WikipediaError.badResponse) { try WikipediaClient.parseResponse(Data(#"{"batchcomplete":true}"#.utf8)) }
    }
}
