import OSLog
import UIKit

/// Shows the iOS system dictionary for a lookup request.
///
/// Presented directly with UIKit rather than through a SwiftUI `.sheet`: the dictionary
/// controller dismisses itself with its own Done button, and a SwiftUI sheet would keep a
/// separate "is presented" state that can fall out of sync with that.
enum DictionaryPresenter {
    static func present(_ request: WordLookupRequest) {
        guard let presenter = topViewController() else {
            Log.lookup.error("No view controller to present the dictionary from")
            return
        }
        // A second tap while the dictionary is still animating in would otherwise stack two.
        guard !(presenter is UIReferenceLibraryViewController) else { return }

        // Shown even without a definition: the system screen then offers to manage/download dictionaries.
        let dictionary = UIReferenceLibraryViewController(term: request.term)
        presenter.present(dictionary, animated: true)
        Log.lookup.info("Presented dictionary for \(request.term, privacy: .public)")
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
