import Foundation

nonisolated enum SiteVocabError: Error, Equatable, Sendable {
    case network(String)
    case timedOut
    /// The site no longer accepts this device's key (401 `invalid_token`).
    case signedOut
    case notAllowed
    case notFound
    /// The sign-in's one-time code was refused: expired, used, or not this app's.
    case invalidGrant
    /// The cursor is too old for changes alone to catch up: a full sync is needed.
    case cursorExpired
    case previewExpired
    /// The book changed after the comparison the user is answering.
    case changedSincePreview
    case confirmationMismatch
    case alreadyUndone
    case tooLarge
    case rateLimited(retryAfter: Int)
    case maintenance
    case badRequest(String)
    case httpStatus(Int)
    /// A web page came back instead of JSON (typically a bot check in front of the site).
    case notJSON
    case badResponse(String)
    /// The copy of this iPhone's book kept before a full sync couldn't be written or read.
    case backupFailed

    /// A problem with getting there, not with what was asked.
    var isConnectionProblem: Bool {
        switch self {
        case .network, .timedOut: true
        default: false
        }
    }

    var message: String {
        switch self {
        case .network(let description): "Couldn't reach English Reader: \(description)"
        case .timedOut: "English Reader didn't answer in time."
        case .signedOut: "Please sign in again."
        case .notAllowed: "This account can't use English Reader. Ask the site's owner."
        case .notFound: "English Reader doesn't have that."
        case .invalidGrant: "The sign-in didn't complete. Try again."
        case .cursorExpired: "This iPhone has been away too long. A full sync is needed."
        case .previewExpired: "The comparison has expired. Compare again."
        case .changedSincePreview: "The word book just changed. Compare again."
        case .confirmationMismatch: "The numbers no longer match. Compare again."
        case .alreadyUndone: "This full sync was already undone."
        case .tooLarge: "The word book is too large to send to English Reader. Ask the site's owner."
        case .rateLimited: "Too many requests to English Reader. Try again in a minute."
        case .maintenance: "English Reader is being updated. Try again in a moment."
        case .badRequest(let detail): "English Reader refused the request (\(detail))."
        case .httpStatus(let status): "English Reader answered with an error (\(status))."
        case .notJSON: "English Reader answered with a web page instead of data. Its bot check may be blocking the app."
        case .badResponse(let detail): "English Reader sent something this version can't read (\(detail))."
        case .backupFailed: "Couldn't keep a copy of this iPhone's words, so nothing was changed."
        }
    }
}

/// Reads and writes this account's word book on English Reader (docs/vocab-sync-v1.md). Every request carries this
/// iPhone's device key, which alone says whose book it is; no address goes in the User-Agent, unlike Wikipedia's.
nonisolated struct SiteVocabClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// How the site's own login gets back to this app.
    static let clientName = "ios"
    static let callbackScheme = "wikireader"
    static let redirectURI = "wikireader://auth/callback"
    /// The most changes in one request, and the page size asked for.
    static let batchLimit = 500

    var baseURL: URL = SiteClient.siteURL
    var transport: Transport = { try await SiteClient.session.data(for: $0) }
    /// This iPhone's device key, when signed in.
    var key: @Sendable () -> String? = { KeychainStore.siteDeviceKey.read() }

    private var api: URL { baseURL.appending(path: "api/app/v1") }

    // MARK: - Signing in (§2)

    /// The page that signs in to the site and asks for the user's consent, for the system's sign-in sheet.
    func authorizationURL(pkce: GoogleOAuth.PKCE, state: String, deviceName: String) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "app/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client", value: Self.clientName),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "device_name", value: String(deviceName.prefix(60))),
        ]
        return components.url!
    }

    /// The one-time code in the redirect, after checking that it answers our own request (`state`).
    static func code(fromRedirect url: URL, state: String) throws(SiteAuthError) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw .rejected("the answer wasn't for this sign-in") }
        if let error = value("error") { throw error == "access_denied" ? .cancelled : .rejected(error) }
        guard let code = value("code"), !code.isEmpty else { throw .rejected("no code in the answer") }
        return code
    }

    /// Whether the site can sign in apps. Asked without a key, it answers 401 if it can.
    @concurrent
    func supportsSignIn() async throws(SiteVocabError) -> Bool {
        do {
            _ = try await send("GET", api.appending(path: "me"), signed: false)
            return true
        } catch .signedOut {
            return true
        } catch .notFound {
            return false
        }
    }

    /// - Parameter deviceID: This device's id from its last sign-in, so the site replaces that key rather than list
    ///   the same iPhone twice.
    @concurrent
    func deviceKey(code: String, verifier: String, deviceID: String?) async throws(SiteVocabError) -> SiteDeviceGrant {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client": Self.clientName,
            "redirect_uri": Self.redirectURI,
        ]
        fields["device_id"] = deviceID
        return try decode(try await send("POST", api.appending(path: "auth/token"), body: try encode(fields), signed: false))
    }

    /// Ends this device's key on the site.
    @concurrent
    func logout() async throws(SiteVocabError) {
        _ = try await send("POST", api.appending(path: "auth/logout"))
    }

    // MARK: - Everyday changes (§4)

    @concurrent
    func changes(since cursor: String, limit: Int = batchLimit) async throws(SiteVocabError) -> VocabChangesPage {
        var components = URLComponents(url: api.appending(path: "vocab/changes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: cursor), URLQueryItem(name: "limit", value: String(limit))]
        return try decode(try await send("GET", components.url!))
    }

    @concurrent
    func push(_ batch: VocabPushBatch) async throws(SiteVocabError) -> VocabPushResponse {
        try decode(try await send("POST", api.appending(path: "vocab/changes"), body: try encode(batch)))
    }

    // MARK: - Full sync (§5)

    /// Sends the whole book for the site to compare with its own.
    @concurrent
    func preview(_ book: VocabFile) async throws(SiteVocabError) -> VocabSyncPreview {
        try decode(try await send("POST", api.appending(path: "vocab/sync/preview"), body: try encode(book)))
    }

    @concurrent
    func apply(previewID: String, option: VocabSyncOption, confirm: VocabSyncConfirmation) async throws(SiteVocabError) -> VocabSyncApplied {
        struct Request: Encodable {
            var previewId: String
            var option: String
            var confirm: VocabSyncConfirmation
        }
        let body = try encode(Request(previewId: previewID, option: option.rawValue, confirm: confirm))
        return try decode(try await send("POST", api.appending(path: "vocab/sync/apply"), body: body))
    }

    @concurrent
    func undo(undoID: String) async throws(SiteVocabError) -> VocabSyncUndone {
        try decode(try await send("POST", api.appending(path: "vocab/sync/undo"), body: try encode(["undoId": undoID])))
    }

    // MARK: - Requests

    private func send(_ method: String, _ url: URL, body: Data? = nil, signed: Bool = true) async throws(SiteVocabError) -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(SiteClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if signed, let key = key(), !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

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
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        // 204 for signing out: no body at all.
        if !data.isEmpty, !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") { throw .notJSON }
        return data
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            var code: String?
        }

        var error: Detail?
    }

    /// By the code in the answer. A 401 without one didn't come from the site's API (a page in front of it), so it
    /// doesn't sign anyone out.
    static func error(status: Int, body: Data, retryAfter: String?) -> SiteVocabError {
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error?.code
        switch code {
        case "invalid_token": return .signedOut
        case "invalid_grant": return .invalidGrant
        case "not_allowed": return .notAllowed
        case "not_found": return .notFound
        case "cursor_expired": return .cursorExpired
        case "preview_expired": return .previewExpired
        case "changed_since_preview": return .changedSincePreview
        case "confirmation_mismatch": return .confirmationMismatch
        case "already_undone": return .alreadyUndone
        case "too_large": return .tooLarge
        case "rate_limited": return .rateLimited(retryAfter: Int(retryAfter ?? "") ?? 2)
        case "maintenance": return .maintenance
        case "bad_request": return .badRequest("bad_request")
        default: break
        }
        switch status {
        case 404: return .notFound
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: Int(retryAfter ?? "") ?? 2)
        case 503: return .maintenance
        default: return .httpStatus(status)
        }
    }

    private func encode(_ value: some Encodable) throws(SiteVocabError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw .badRequest("not encodable")
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws(SiteVocabError) -> T {
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
