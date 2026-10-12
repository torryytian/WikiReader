import Foundation

/// The article as returned by the `action=parse` API, before cleaning.
nonisolated struct FetchedArticle: Equatable, Sendable {
    /// Final title after the API followed redirects and normalization.
    var title: String
    /// The rendered page body (HTML). Unlike the TextExtracts plain text, it still contains paragraphs
    /// that a page pulls in from other articles, which TextExtracts leaves out.
    var html: String
}

nonisolated enum WikipediaError: Error, Equatable {
    case pageNotFound(title: String)
    case invalidTitle(title: String)
    /// The page exists but has no text (e.g. a special page).
    case emptyArticle(title: String)
    case network(description: String)
    /// No complete response arrived within the time limit.
    case timedOut
    case httpStatus(Int)
    case badResponse
}

/// Fetches article text from English Wikipedia. Only called when the user adds an article.
nonisolated struct WikipediaClient: Sendable {
    static let userAgent = "WikiReader/0.1 (personal app; contact: torryytian@gmail.com)"

    /// Not `.shared`: its defaults wait 60 s of silence per request and up to 7 days overall, so a bad
    /// connection looks like an endless spinner. A parse response is a few hundred KB compressed, so these are generous.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15  // longest silence on the connection
        configuration.timeoutIntervalForResource = 30  // whole fetch, even if data keeps trickling in
        return URLSession(configuration: configuration)
    }()

    var session: URLSession = defaultSession

    /// Runs off the main actor (`@concurrent`) so a slow network never blocks the UI.
    @concurrent
    func fetchArticle(title: String) async throws(WikipediaError) -> FetchedArticle {
        var request = URLRequest(url: Self.requestURL(forTitle: title))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw .timedOut
        } catch {
            throw .network(description: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .httpStatus(http.statusCode)
        }
        return try Self.parseResponse(data, requestedTitle: title)
    }

    static func requestURL(forTitle title: String) -> URL {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "prop", value: "text"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "disableeditsection", value: "1"),
            URLQueryItem(name: "disablelimitreport", value: "1"),
            URLQueryItem(name: "disabletoc", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "page", value: title),
        ]
        // URLComponents leaves "+" unescaped in queries, but the API reads it as a space ("C++" -> "C  ").
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Parses a `formatversion=2` parse response. Separate from networking so tests can feed fixtures.
    /// `requestedTitle` is only used for error messages: the API's error replies don't name the page.
    static func parseResponse(_ data: Data, requestedTitle: String) throws(WikipediaError) -> FetchedArticle {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw .badResponse
        }
        if let error = decoded.error {
            switch error.code {
            case "missingtitle": throw .pageNotFound(title: requestedTitle)
            case "invalidtitle": throw .invalidTitle(title: requestedTitle)
            default: throw .badResponse
            }
        }
        guard let page = decoded.parse else { throw .badResponse }
        guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .emptyArticle(title: page.title) }
        return FetchedArticle(title: page.title, html: page.text)
    }

    private struct Response: Decodable {
        struct Parse: Decodable {
            var title: String
            var text: String
        }
        struct APIError: Decodable {
            var code: String
        }
        var parse: Parse?
        var error: APIError?
    }
}
