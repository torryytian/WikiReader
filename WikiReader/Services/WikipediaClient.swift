import Foundation

/// Raw article text as returned by the TextExtracts API, before cleaning.
nonisolated struct FetchedArticle: Equatable, Sendable {
    /// Final title after the API followed redirects and normalization.
    var title: String
    /// Plain text with `== Heading ==` section markers.
    var extract: String
}

nonisolated enum WikipediaError: Error, Equatable {
    case pageNotFound(title: String)
    case invalidTitle(title: String)
    /// The page exists but has no text (e.g. a special page).
    case emptyArticle(title: String)
    case network(description: String)
    case httpStatus(Int)
    case badResponse
}

/// Fetches article text from English Wikipedia. Only called when the user adds an article.
nonisolated struct WikipediaClient: Sendable {
    static let userAgent = "WikiReader/0.1 (personal app; contact: torryytian@gmail.com)"

    var session: URLSession = .shared

    /// Runs off the main actor (`@concurrent`) so a slow network never blocks the UI.
    @concurrent
    func fetchArticle(title: String) async throws(WikipediaError) -> FetchedArticle {
        var request = URLRequest(url: Self.requestURL(forTitle: title))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(description: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .httpStatus(http.statusCode)
        }
        return try Self.parseResponse(data)
    }

    static func requestURL(forTitle title: String) -> URL {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exsectionformat", value: "wiki"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "titles", value: title),
        ]
        // URLComponents leaves "+" unescaped in queries, but the API reads it as a space ("C++" -> "C  ").
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Parses a `formatversion=2` query response. Separate from networking so tests can feed fixtures.
    static func parseResponse(_ data: Data) throws(WikipediaError) -> FetchedArticle {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw .badResponse
        }
        guard let page = decoded.query?.pages.first else { throw .badResponse }
        if page.missing == true { throw .pageNotFound(title: page.title) }
        if page.invalid == true { throw .invalidTitle(title: page.title) }
        guard let extract = page.extract,
              !extract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .emptyArticle(title: page.title) }
        return FetchedArticle(title: page.title, extract: extract)
    }

    private struct Response: Decodable {
        struct Query: Decodable {
            var pages: [Page]
        }
        struct Page: Decodable {
            var title: String
            var extract: String?
            var missing: Bool?
            var invalid: Bool?
        }
        var query: Query?
    }
}
