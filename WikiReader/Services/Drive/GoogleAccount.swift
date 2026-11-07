import Foundation
import Observation
import OSLog

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
    /// Called when a sign-in is for a different Google account than the last one: what was learned about the other
    /// account's Drive (folder ids, the audio index) must not be used for this one.
    @ObservationIgnored var onAccountChange: (() -> Void)?

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
        // Sign-ins from before the last account was remembered: the one signed in now is it.
        if defaults.string(forKey: SettingsKeys.googleLastAccount) == nil, let email = defaults.string(forKey: SettingsKeys.googleAccountEmail) {
            defaults.set(email, forKey: SettingsKeys.googleLastAccount)
        }
    }

    var isSignedIn: Bool { state != .signedOut }

    /// The signed-in account's address, lowercased: what the word book is kept apart by. Nil when signed out, or
    /// when Google didn't say (then nothing is told apart).
    var accountID: String? {
        guard case .signedIn(let email?) = state, !email.isEmpty else { return nil }
        return email.lowercased()
    }

    /// The iOS OAuth client of the user's "WikiReader" Google Cloud project, the one the Chrome extension's client is
    /// in too (drive.file only shows files made by clients of the same project). Public by design.
    static let defaultClientID = "174740959205-ha26vdrcfbsama9s4lcpqdmq777rri42.apps.googleusercontent.com"

    /// The client id from Settings, or the built-in one when none was entered.
    var client: GoogleOAuth.Client? {
        let entered = defaults.string(forKey: SettingsKeys.googleClientID) ?? ""
        return GoogleOAuth.Client(id: entered.isEmpty ? Self.defaultClientID : entered)
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
        // Without the Drive permission the sign-in is no use: say so now rather than fail on every Drive request.
        guard response.grantsDrive else {
            Log.app.error("Google sign-in without Drive access")
            revoke(response.refreshToken ?? response.accessToken)
            clear(problem: GoogleAuthError.driveNotGranted.message)
            throw .driveNotGranted
        }
        guard let refresh = response.refreshToken else { throw .rejected("no refresh token") }
        do {
            try refreshTokenStore.save(refresh)
        } catch {
            throw .rejected("couldn't save to the Keychain")
        }
        let email = response.idToken.flatMap(GoogleOAuth.email(fromIDToken:))
        defaults.set(email, forKey: SettingsKeys.googleAccountEmail)
        let previous = defaults.string(forKey: SettingsKeys.googleLastAccount)
        if let email { defaults.set(email, forKey: SettingsKeys.googleLastAccount) }
        accessToken = (response.accessToken, .now.addingTimeInterval(TimeInterval(response.expiresIn)))
        problem = nil
        state = .signedIn(email: email)
        Log.app.info("Signed in to Google")  // never log tokens or the address
        if let previous, let email, previous.lowercased() != email.lowercased() {
            Log.app.info("Signed in as a different Google account than before")
            onAccountChange?()
        }
    }

    /// Forgets the sign-in here and asks Google to revoke it (best effort: offline, it simply lapses).
    func signOut() {
        if let token = refreshTokenStore.read() { revoke(token) }
        clear(problem: nil)
        Log.app.info("Signed out of Google")
    }

    /// Drive refused the token for lacking the Drive permission (a sign-in from before that was checked, or access
    /// removed in the Google account since): sign out, with the reason for Settings to show.
    func driveAccessMissing() {
        guard isSignedIn else { return }
        Log.app.error("Drive says the sign-in lacks Drive access; signed out")
        if let token = refreshTokenStore.read() { revoke(token) }
        clear(problem: GoogleAuthError.driveNotGranted.message)
    }

    /// Asks Google to forget a grant, so the next sign-in asks about every permission again.
    private func revoke(_ token: String) {
        let request = GoogleOAuth.revokeRequest(token: token)
        let transport = transport
        Task { _ = try? await transport(request) }
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
        switch await WebSignInSheet.present(url: url, callbackScheme: callbackScheme) {
        case .success(let redirect): redirect
        case .failure(.cancelled): throw .cancelled
        case .failure(.failed(let detail)): throw .rejected(detail)
        }
    }
}
