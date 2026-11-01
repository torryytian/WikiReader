import AuthenticationServices
import Foundation
import Observation
import OSLog
import UIKit

/// The Google account audio is shared through: signing in and out, and handing out access tokens to `DriveClient`.
///
/// The refresh token, which keeps the app signed in, is in the Keychain like the OpenAI key; access tokens last an
/// hour and live only in memory. The client id is the Google Cloud project's iOS OAuth client, public by design (it
/// identifies the app, it doesn't authorize anything), so it is a setting rather than a secret.
@Observable
final class GoogleAccount {
    static let shared = GoogleAccount()

    enum State: Equatable {
        case signedOut
        case signedIn(email: String?)
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private(set) var state: State
    /// Why the account was signed out on its own (Google stopped accepting the refresh token), for Settings to show.
    private(set) var problem: String?

    @ObservationIgnored private let refreshTokenStore: KeychainStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private var accessToken: (token: String, expires: Date)?
    /// A refresh in progress, shared by everyone who needs a token meanwhile.
    @ObservationIgnored private var refreshing: Task<String, Error>?
    @ObservationIgnored private var presenter: SignInPresenter?

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    init(
        refreshTokenStore: KeychainStore = KeychainStore(service: "tik.tian.com.WikiReader.google", account: "refreshToken"),
        defaults: UserDefaults = .standard,
        transport: @escaping Transport = { try await GoogleAccount.session.data(for: $0) }
    ) {
        self.refreshTokenStore = refreshTokenStore
        self.defaults = defaults
        self.transport = transport
        state = refreshTokenStore.read() == nil ? .signedOut : .signedIn(email: defaults.string(forKey: SettingsKeys.googleAccountEmail))
    }

    var isSignedIn: Bool { state != .signedOut }

    var client: GoogleOAuth.Client? {
        GoogleOAuth.Client(id: defaults.string(forKey: SettingsKeys.googleClientID) ?? "")
    }

    // MARK: - Signing in and out

    /// Opens Google's sign-in page in the system's sign-in sheet and keeps the result.
    func signIn() async throws(GoogleAuthError) {
        guard let client else { throw .notConfigured }
        let pkce = GoogleOAuth.PKCE.make()
        let state = UUID().uuidString
        let redirect = try await presentSignIn(
            url: GoogleOAuth.authorizationURL(client: client, pkce: pkce, state: state),
            callbackScheme: client.redirectScheme
        )
        let code = try GoogleOAuth.code(fromRedirect: redirect, state: state)
        let response = try await exchange(GoogleOAuth.tokenRequest(client: client, code: code, verifier: pkce.verifier))
        try finishSignIn(response)
    }

    /// Keeps what the code exchange returned. Separate from the browser part so tests can drive it.
    func finishSignIn(_ response: GoogleOAuth.TokenResponse) throws(GoogleAuthError) {
        guard let refresh = response.refreshToken else { throw .rejected("no refresh token") }
        do {
            try refreshTokenStore.save(refresh)
        } catch {
            throw .rejected("couldn't save to the Keychain")
        }
        let email = response.idToken.flatMap(GoogleOAuth.email(fromIDToken:))
        defaults.set(email, forKey: SettingsKeys.googleAccountEmail)
        accessToken = (response.accessToken, .now.addingTimeInterval(TimeInterval(response.expiresIn)))
        problem = nil
        state = .signedIn(email: email)
        Log.app.info("Signed in to Google")  // never log tokens or the address
    }

    /// Forgets the sign-in here and asks Google to revoke it (best effort: offline, it simply lapses).
    func signOut() {
        if let token = refreshTokenStore.read() {
            let request = GoogleOAuth.revokeRequest(token: token)
            let transport = transport
            Task { _ = try? await transport(request) }
        }
        clear(problem: nil)
        Log.app.info("Signed out of Google")
    }

    private func clear(problem: String?) {
        try? refreshTokenStore.delete()
        defaults.removeObject(forKey: SettingsKeys.googleAccountEmail)
        accessToken = nil
        refreshing?.cancel()
        refreshing = nil
        self.problem = problem
        state = .signedOut
    }

    // MARK: - Tokens

    /// A current access token, refreshed when it is about to expire (or when `force`, after Drive said 401).
    func validAccessToken(force: Bool = false) async throws -> String {
        if !force, let accessToken, accessToken.expires > .now.addingTimeInterval(60) {
            return accessToken.token
        }
        if let refreshing { return try await refreshing.value }
        guard let client else { throw GoogleAuthError.notConfigured }
        guard let refresh = refreshTokenStore.read() else { throw GoogleAuthError.notSignedIn }
        let task = Task { () throws -> String in
            let response = try await self.exchange(GoogleOAuth.refreshRequest(client: client, refreshToken: refresh))
            self.accessToken = (response.accessToken, .now.addingTimeInterval(TimeInterval(response.expiresIn)))
            return response.accessToken
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            return try await task.value
        } catch GoogleAuthError.signInExpired {
            Log.app.error("Google refresh token no longer accepted; signed out")
            clear(problem: GoogleAuthError.signInExpired.message)
            throw GoogleAuthError.signInExpired
        }
    }

    private func exchange(_ request: URLRequest) async throws(GoogleAuthError) -> GoogleOAuth.TokenResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw .network(error.localizedDescription)
        }
        return try GoogleOAuth.tokenResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - The sign-in sheet

    private func presentSignIn(url: URL, callbackScheme: String) async throws(GoogleAuthError) -> URL {
        let result: Result<URL, GoogleAuthError> = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: .success(callback))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: .failure(.cancelled))
                } else {
                    continuation.resume(returning: .failure(.rejected(error?.localizedDescription ?? "no answer")))
                }
            }
            let presenter = SignInPresenter()
            self.presenter = presenter
            session.presentationContextProvider = presenter
            // Shares Safari's cookies, so a Google account already signed in there needs no password.
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(returning: .failure(.rejected("the sign-in sheet couldn't open")))
            }
        }
        presenter = nil
        return try result.get()
    }

    /// Tells the sign-in sheet which window to appear over.
    private final class SignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first.map(UIWindow.init(windowScene:)) ?? UIWindow()
        }
    }
}
