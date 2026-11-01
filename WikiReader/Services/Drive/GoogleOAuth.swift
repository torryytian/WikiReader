import CryptoKit
import Foundation

/// The OAuth 2.0 pieces of signing in to Google as an installed app (authorization code with PKCE), as plain
/// functions so they can be tested without a network or a browser.
///
/// The flow, roughly what a CLI's "log in with your browser" does: open Google's sign-in page with a one-time
/// challenge, Google redirects back to the app with a code, the app trades the code (and the secret the challenge
/// was made from) for an access token, good for an hour, and a refresh token, kept to get new access tokens later.
nonisolated enum GoogleOAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// Only files this app (or the Chrome extension, same Google Cloud project) created; plus the account's email,
    /// to show who is signed in.
    static let scopes = ["https://www.googleapis.com/auth/drive.file", "openid", "email"]

    /// An iOS OAuth client of a Google Cloud project, e.g. `123-abc.apps.googleusercontent.com`.
    struct Client: Equatable, Sendable {
        var id: String

        init?(id: String) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix(".apps.googleusercontent.com"), trimmed.count > ".apps.googleusercontent.com".count,
                  trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_") })
            else { return nil }
            self.id = trimmed
        }

        /// Google sends iOS clients back to the client id reversed, as a URL scheme the app's sign-in sheet listens for.
        var redirectScheme: String {
            id.split(separator: ".").reversed().joined(separator: ".")
        }

        var redirectURI: String { redirectScheme + ":/oauth2redirect" }
    }

    /// The one-time secret (`verifier`) and what is sent in its place up front (`challenge`), so a code intercepted on
    /// the way back is useless to anyone else.
    struct PKCE: Equatable, Sendable {
        var verifier: String
        var challenge: String

        static func make() -> PKCE {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            var generator = SystemRandomNumberGenerator()
            let verifier = String((0..<64).map { _ in alphabet.randomElement(using: &generator)! })
            return PKCE(verifier: verifier, challenge: challenge(for: verifier))
        }

        static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(client: Client, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: client.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The code Google sent back to the redirect URL, after checking it answers our request (`state`).
    static func code(fromRedirect url: URL, state: String) throws(GoogleAuthError) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? .cancelled : .rejected(error)
        }
        guard value("state") == state else { throw .rejected("state mismatch") }
        guard let code = value("code"), !code.isEmpty else { throw .badResponse }
        return code
    }

    static func tokenRequest(client: Client, code: String, verifier: String) -> URLRequest {
        formRequest(tokenEndpoint, [
            "client_id": client.id,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": client.redirectURI,
        ])
    }

    static func refreshRequest(client: Client, refreshToken: String) -> URLRequest {
        formRequest(tokenEndpoint, [
            "client_id": client.id,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
    }

    static func revokeRequest(token: String) -> URLRequest {
        formRequest(revokeEndpoint, ["token": token])
    }

    private static func formRequest(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return request
    }

    struct TokenResponse: Decodable, Equatable, Sendable {
        var accessToken: String
        var expiresIn: Int
        /// Only on the first exchange; refreshing returns none and the old one stays valid.
        var refreshToken: String?
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    /// Reads a token endpoint answer. `invalid_grant` means the refresh token is no longer accepted (revoked, or
    /// expired: a Google Cloud app left in "Testing" gets refresh tokens that last 7 days), so signing in again is needed.
    static func tokenResponse(data: Data, status: Int) throws(GoogleAuthError) -> TokenResponse {
        guard (200..<300).contains(status) else {
            let error = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            if error == "invalid_grant" { throw .signInExpired }
            throw .rejected(error ?? "HTTP \(status)")
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data), !response.accessToken.isEmpty
        else { throw .badResponse }
        return response
    }

    /// The email in an ID token (a JWT: header.payload.signature). Only shown in Settings, so the signature, which the
    /// token endpoint answered over TLS, isn't checked.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }

    private struct ErrorBody: Decodable {
        var error: String?
    }
}

nonisolated enum GoogleAuthError: Error, Equatable, Sendable {
    /// No client id saved, or it isn't one.
    case notConfigured
    case notSignedIn
    case cancelled
    /// Google no longer accepts the saved sign-in.
    case signInExpired
    case rejected(String)
    case network(String)
    case badResponse

    var message: String {
        switch self {
        case .notConfigured: "Enter the iOS client ID from Google Cloud first."
        case .notSignedIn: "Not signed in to Google."
        case .cancelled: "Sign-in was cancelled."
        case .signInExpired: "The Google sign-in has expired. Sign in again."
        case .rejected(let detail): "Google refused the sign-in: \(detail)"
        case .network(let detail): "Couldn't reach Google: \(detail)"
        case .badResponse: "Google returned an unexpected response."
        }
    }
}
