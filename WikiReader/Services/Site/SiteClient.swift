import Foundation

nonisolated enum SiteError: Error, Equatable {
    case network(String)
    case timedOut
    case httpStatus(Int)
    case notFound
    /// A web page came back instead of JSON (typically a bot check in front of the site).
    case notJSON
    case badResponse(String)
    /// The site speaks a newer format than this version of the app.
    case newerFormat(Int)

    var message: String {
        switch self {
        case .network(let description): "Couldn't reach English Reader: \(description)"
        case .timedOut: "English Reader didn't answer in time."
        case .httpStatus(let status): "English Reader answered with an error (\(status))."
        case .notFound: "This article is no longer on English Reader."
        case .notJSON: "English Reader answered with a web page instead of data. Its bot check may be blocking the app."
        case .badResponse(let detail): "English Reader sent something this version can't read (\(detail))."
        case .newerFormat(let version): "English Reader uses a newer format (\(version)). Update WikiReader."
        }
    }
}

/// Reads the English Reader site's app API (docs/site-api-for-ios.md): the catalog of published articles and each
/// article's text and narration. Read-only and public: nothing about the user is sent (no address in the
/// User-Agent, unlike Wikipedia's).
nonisolated struct SiteClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let siteURL = URL(string: "https://english.thrones.wang")!
    static let userAgent = "WikiReader/0.1 (iOS app)"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    var baseURL: URL = SiteClient.siteURL
    var transport: Transport = { try await SiteClient.session.data(for: $0) }

    /// What changed after `since` (0: everything), one page of at most `limit`.
    @concurrent
    func catalog(since: Int, limit: Int = 200) async throws(SiteError) -> SiteCatalogPage {
        var components = URLComponents(url: baseURL.appending(path: "api/app/v1/articles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "limit", value: String(limit))]
        let page: SiteCatalogPage = try decode(try await get(components.url!))
        guard page.formatVersion <= SiteFormat.version else { throw .newerFormat(page.formatVersion) }
        return page
    }

    /// One article in full, with the response itself, kept so it needn't be fetched again until it changes.
    @concurrent
    func article(id: String) async throws(SiteError) -> (detail: SiteArticleDetail, data: Data) {
        let data = try await get(baseURL.appending(path: "api/app/v1/articles").appending(path: id))
        return (try Self.decodeArticle(data), data)
    }

    static func decodeArticle(_ data: Data) throws(SiteError) -> SiteArticleDetail {
        try SiteClient().decode(data)
    }

    private func get(_ url: URL) async throws(SiteError) -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code == .timedOut {
            throw .timedOut
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse("not HTTP") }
        if http.statusCode == 404 { throw .notFound }
        guard (200..<300).contains(http.statusCode) else { throw .httpStatus(http.statusCode) }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("json") else { throw .notJSON }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws(SiteError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw .badResponse("missing \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, context) {
            throw .badResponse("unexpected \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw .badResponse("not readable")
        }
    }
}
