import Foundation
import Testing
@testable import WikiReader

/// Fails every request with a fixed URLError, without touching the network.
private final class FailingURLProtocol: URLProtocol {
    static let code = URLError.Code.timedOut

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}

struct WikipediaClientTests {
    @Test func defaultSessionGivesUpInsteadOfSpinningForever() {
        let configuration = WikipediaClient.defaultSession.configuration
        #expect(configuration.timeoutIntervalForRequest <= 20)
        #expect(configuration.timeoutIntervalForResource <= 60)
    }

    @Test func timeoutBecomesTimedOutError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        let client = WikipediaClient(session: URLSession(configuration: configuration))
        await #expect(throws: WikipediaError.timedOut) {
            try await client.fetchArticle(title: "Albert Einstein")
        }
    }

    @Test func requestURLHasRequiredParameters() throws {
        let url = WikipediaClient.requestURL(forTitle: "Albert Einstein")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "en.wikipedia.org")
        #expect(query["action"] == "parse")
        #expect(query["prop"] == "text")
        #expect(query["redirects"] == "1")
        #expect(query["disableeditsection"] == "1")
        #expect(query["formatversion"] == "2")
        #expect(query["page"] == "Albert Einstein")
    }

    @Test func plusSignIsEscaped() {
        // An unescaped "+" would be read by the API as a space.
        let url = WikipediaClient.requestURL(forTitle: "C++")
        #expect(url.absoluteString.hasSuffix("page=C%2B%2B"))
    }

    @Test func userAgentHasContact() {
        #expect(WikipediaClient.userAgent.hasPrefix("WikiReader/0.1 (personal app; contact: "))
        #expect(!WikipediaClient.userAgent.contains("YOUR_EMAIL"))
    }

    @Test func parsesArticle() throws {
        let article = try Fixture.article("albert_einstein")
        #expect(article.title == "Albert Einstein")
        #expect(article.html.contains("<h2 id=\"Life_and_career\">Life and career</h2>"))
        #expect(article.html.contains("Albert Einstein"))
    }

    @Test func followsRedirect() throws {
        // Requested "Einstein"; the API resolved the redirect.
        #expect(try Fixture.article("redirect_einstein", requestedTitle: "Einstein").title == "Albert Einstein")
    }

    @Test func missingPage() {
        #expect(throws: WikipediaError.pageNotFound(title: "Asdfqwerzxcv123")) {
            try Fixture.article("missing_page", requestedTitle: "Asdfqwerzxcv123")
        }
    }

    @Test func invalidTitle() {
        let json = #"{"error":{"code":"invalidtitle","info":"Bad title \"[]\"."}}"#
        #expect(throws: WikipediaError.invalidTitle(title: "[]")) {
            try WikipediaClient.parseResponse(Data(json.utf8), requestedTitle: "[]")
        }
    }

    @Test func emptyText() {
        let json = #"{"parse":{"title":"Empty","pageid":1,"text":"  "}}"#
        #expect(throws: WikipediaError.emptyArticle(title: "Empty")) {
            try WikipediaClient.parseResponse(Data(json.utf8), requestedTitle: "Empty")
        }
    }

    @Test func unknownAPIErrorIsABadResponse() {
        let json = #"{"error":{"code":"ratelimited","info":"slow down"}}"#
        #expect(throws: WikipediaError.badResponse) {
            try WikipediaClient.parseResponse(Data(json.utf8), requestedTitle: "X")
        }
    }

    @Test func garbageResponse() {
        #expect(throws: WikipediaError.badResponse) { try WikipediaClient.parseResponse(Data("<html>".utf8), requestedTitle: "X") }
        #expect(throws: WikipediaError.badResponse) { try WikipediaClient.parseResponse(Data(#"{"batchcomplete":true}"#.utf8), requestedTitle: "X") }
    }
}
