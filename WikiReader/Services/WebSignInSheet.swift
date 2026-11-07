import AuthenticationServices
import UIKit

/// The system's sign-in sheet, the one place a web page signs the user in: the app sees where the page redirects at
/// the end, never what is typed in it.
enum WebSignInSheet {
    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    /// Opens `url` and returns the address the page finally redirects to, on `callbackScheme`.
    static func present(url: URL, callbackScheme: String) async -> Result<URL, Failure> {
        let presenter = Presenter()
        let result: Result<URL, Failure> = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: .success(callback))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: .failure(.cancelled))
                } else {
                    continuation.resume(returning: .failure(.failed(error?.localizedDescription ?? "no answer")))
                }
            }
            session.presentationContextProvider = presenter
            // Shares Safari's cookies, so an account already signed in there needs no password.
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(returning: .failure(.failed("the sign-in sheet couldn't open")))
            }
        }
        // The session only holds it weakly.
        return withExtendedLifetime(presenter) { result }
    }

    /// Tells the sign-in sheet which window to appear over.
    private final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first.map(UIWindow.init(windowScene:)) ?? UIWindow()
        }
    }
}
