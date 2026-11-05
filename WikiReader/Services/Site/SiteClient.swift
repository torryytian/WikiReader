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
    /// The access token in Settings was refused: unknown, revoked or expired (401 `invalid_token`).
    case invalidToken
    /// Too many requests with this access token (429), still after waiting as the site asked.
    case rateLimited

    var message: String {
        switch self {
        case .network(let description): "Couldn't reach English Reader: \(description)"
        case .timedOut: "English Reader didn't answer in time."
        case .httpStatus(let status): "English Reader answered with an error (\(status))."
        case .notFound: "This article is no longer on English Reader."
        case .notJSON: "English Reader answered with a web page instead of data. Its bot check may be blocking the app."
        case .badResponse(let detail): "English Reader sent something this version can't read (\(detail))."
        case .newerFormat(let version): "English Reader uses a newer format (\(version)). Update WikiReader."
        case .invalidToken: "English Reader didn't accept your access token: it may have been revoked or have expired. Paste a new one in Settings → English Reader."
        case .rateLimited: "Too many requests to English Reader with this access token. Try again in a minute."
        }
    }
}

/// Reads the English Reader site's app API (docs/site-api-for-ios.md): the catalog of published articles and each
/// article's text and narration. Read-only: nothing about the user is sent (no address in the User-Agent, unlike
/// Wikipedia's), only the access token the site's owner made for this app, when one is saved in Settings (§10). It
/// goes to the site alone, never to the audio files' host.
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
    /// The access token from Settings, if any (`KeychainStore.siteToken`).
    var token: @Sendable () -> String? = { KeychainStore.siteToken.read() }
    /// The longest wait a 429's `Retry-After` is followed for before giving up.
    var longestRetryWait: Duration = .seconds(30)

    /// What changed after `since` (0: everything), one page of at most `limit`.
    @concurrent
    func catalog(since: Int, limit: Int = 200) async throws(SiteError) -> SiteCatalogPage {
        var components = URLComponents(url: baseURL.appending(path: "api/app/v1/articles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "limit", value: String(limit))]
        let page: SiteCatalogPage = try decode(try await get(components.url!))
        guard page.formatVersion <= SiteFormat.version else { throw .newerFormat(page.formatVersion) }
        return page
    }

    /// The categories, with their descriptions and order (an optional part of the API: `.notFound` if the site
    /// doesn't have it).
    @concurrent
    func categories() async throws(SiteError) -> [SiteCategoryInfo] {
        let list: SiteCategoryList = try decode(try await get(baseURL.appending(path: "api/app/v1/categories")))
        return list.categories
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

    /// One request, with the access token if there is one. Rate limited (429): waits as long as `Retry-After` says
    /// (up to `longestRetryWait`) and tries again, three tries in all. A refused token is reported, never retried
    /// without it: that would only bring the preview.
    private func get(_ url: URL) async throws(SiteError) -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = token()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for attempt in 1...3 {
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
            if http.statusCode == 401 { throw .invalidToken }
            if http.statusCode == 429 {
                let wait = Duration.seconds(Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2)
                guard attempt < 3, wait <= longestRetryWait else { throw .rateLimited }
                try? await Task.sleep(for: wait)
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw .httpStatus(http.statusCode) }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard type.contains("json") else { throw .notJSON }
            return data
        }
        throw .rateLimited
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
