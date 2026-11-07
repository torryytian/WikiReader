import Foundation
import Observation
import OSLog
import UIKit

nonisolated enum SiteAuthError: Error, Equatable, Sendable {
    case cancelled
    /// The site doesn't sign apps in yet.
    case notAvailable
    case rejected(String)
    case network(String)
    case notSaved

    var message: String {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .notAvailable: "English Reader doesn't support signing in from the app yet."
        case .rejected(let detail): "English Reader refused the sign-in: \(detail)"
        case .network(let detail): detail
        case .notSaved: "Couldn't save the sign-in to the Keychain."
        }
    }
}

/// Signing in to English Reader itself (docs/vocab-sync-v1.md §2): the system's sign-in sheet opens the site's own
/// login, Google or an emailed code just as on the web, and the site answers with a one-time code that the app trades
/// for a device key. A device key is like a personal API token: one per device, kept in the Keychain, revocable from
/// the site's account page. The app never sees a password, and Google has no part in it after the login page.
///
/// From signing in until signing out on purpose, the word book goes through the site instead of Drive, even while the
/// site has stopped accepting the key: those words are waiting for this account, not for Drive.
@Observable
final class SiteAccount {
    static let shared = SiteAccount()

    enum State: Equatable {
        case signedOut
        case signedIn(SiteUser)
        /// The site stopped accepting the key: signed out from its account page, revoked, or unused for 180 days.
        case needsSignIn(SiteUser)
    }

    typealias WebSignIn = (_ url: URL, _ callbackScheme: String) async -> Result<URL, WebSignInSheet.Failure>

    private(set) var state: State

    @ObservationIgnored private let keyStore: KeychainStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: SiteVocabClient
    @ObservationIgnored private let webSignIn: WebSignIn
    @ObservationIgnored private let deviceName: () -> String

    init(
        keyStore: KeychainStore = .siteDeviceKey,
        defaults: UserDefaults = .standard,
        client: SiteVocabClient = SiteVocabClient(),
        webSignIn: @escaping WebSignIn = { await WebSignInSheet.present(url: $0, callbackScheme: $1) },
        deviceName: @escaping () -> String = { UIDevice.current.name }
    ) {
        self.keyStore = keyStore
        self.defaults = defaults
        self.client = client
        self.webSignIn = webSignIn
        self.deviceName = deviceName
        let user = defaults.data(forKey: SettingsKeys.siteAccount).flatMap { try? JSONDecoder().decode(SiteUser.self, from: $0) }
        if let user {
            state = keyStore.read() == nil ? .needsSignIn(user) : .signedIn(user)
        } else {
            state = .signedOut
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = state { true } else { false }
    }

    /// Whether the word book goes through the site rather than Drive.
    var keepsWordBook: Bool { state != .signedOut }

    var user: SiteUser? {
        switch state {
        case .signedOut: nil
        case .signedIn(let user), .needsSignIn(let user): user
        }
    }

    /// Opens the site's login in the system's sign-in sheet and keeps the device key it leads to.
    func signIn() async throws(SiteAuthError) -> SiteUser {
        do {
            // Otherwise the sheet would open on the site's "not found" page.
            guard try await client.supportsSignIn() else { throw SiteAuthError.notAvailable }
        } catch let error as SiteVocabError {
            throw .network(error.message)
        } catch let error as SiteAuthError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }

        let pkce = GoogleOAuth.PKCE.make()
        let requestState = GoogleOAuth.base64URL(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
        let url = client.authorizationURL(pkce: pkce, state: requestState, deviceName: deviceName())
        let redirect: URL
        switch await webSignIn(url, SiteVocabClient.callbackScheme) {
        case .success(let answer): redirect = answer
        case .failure(.cancelled): throw .cancelled
        case .failure(.failed(let detail)): throw .rejected(detail)
        }
        let code = try SiteVocabClient.code(fromRedirect: redirect, state: requestState)

        let grant: SiteDeviceGrant
        do throws(SiteVocabError) {
            grant = try await client.deviceKey(code: code, verifier: pkce.verifier, deviceID: defaults.string(forKey: SettingsKeys.siteDeviceID))
        } catch .invalidGrant {
            throw .rejected("the sign-in expired")
        } catch {
            throw .network(error.message)
        }
        do {
            try keyStore.save(grant.deviceToken)
        } catch {
            throw .notSaved
        }
        defaults.set(try? JSONEncoder().encode(grant.user), forKey: SettingsKeys.siteAccount)
        if let device = grant.device { defaults.set(device.id, forKey: SettingsKeys.siteDeviceID) }
        state = .signedIn(grant.user)
        Log.app.info("Signed in to English Reader")  // never log the key or the address
        return grant.user
    }

    /// Ends the key on the site (best effort: offline, it simply lapses) and forgets the sign-in here.
    func signOut() async {
        if isSignedIn { try? await client.logout() }
        try? keyStore.delete()
        defaults.removeObject(forKey: SettingsKeys.siteAccount)
        state = .signedOut
        Log.app.info("Signed out of English Reader")
    }

    /// The site refused the device key. The account is remembered, to sign in again. Returns whether there was a key
    /// to refuse: otherwise a refusal was about the access token from Settings.
    @discardableResult
    func keyRefused() -> Bool {
        guard case .signedIn(let user) = state else { return false }
        try? keyStore.delete()
        state = .needsSignIn(user)
        Log.app.error("English Reader no longer accepts this device's key")
        return true
    }
}
