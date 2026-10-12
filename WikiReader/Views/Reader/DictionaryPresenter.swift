import OSLog
import SwiftUI
import UIKit

/// How the dictionary screen saves its word: the current state, and a toggle that returns the new state.
struct WordSaving {
    var isSaved: Bool
    /// Saves or removes the word, given a meaning to keep if one is known. Returns the new state.
    var toggle: (String?) -> Bool
    /// Gives an already saved word a meaning.
    var setMeaning: (String) -> Void
}

/// Hosts the word card as a sheet and reports when it has really gone.
final class WordCardHostingController: UIHostingController<WordCardView> {
    private var onDismiss: () -> Void

    init(rootView: WordCardView, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Not when only something on top of the card (the AI sheet, the system dictionary) came or went.
        if isBeingDismissed || presentingViewController == nil {
            let finished = onDismiss
            onDismiss = {}
            finished()
        }
    }
}

/// Shows the word card for a lookup request.
///
/// Presented directly with UIKit rather than through a SwiftUI `.sheet`, so the reader can present it from
/// anywhere (the text, the saved-words list) and learn when it closes, however that happened.
enum DictionaryPresenter {
    /// - Parameter saving: When given, the card gets a bookmark button for the article's word list.
    /// - Parameter onDismiss: Called when the card has been closed, however that happened.
    static func present(_ request: WordLookupRequest, saving: WordSaving? = nil, onDismiss: @escaping () -> Void = {}) {
        guard let presenter = topViewController() else {
            Log.lookup.error("No view controller to present the dictionary from")
            return
        }
        // A second tap while the card is still animating in would otherwise stack two.
        guard !(presenter is WordCardHostingController) else { return }

        let voiceIdentifier = UserDefaults.standard.string(forKey: SettingsKeys.voiceIdentifier)
        let model = WordCardModel(request: request, saving: saving, voiceIdentifier: voiceIdentifier)
        let card = WordCardHostingController(
            rootView: WordCardView(model: model, onOpenSystemDictionary: { presentSystemDictionary(for: $0) }),
            onDismiss: onDismiss
        )
        card.sheetPresentationController?.detents = [.medium(), .large()]
        card.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(card, animated: true)
        Log.lookup.info("Presented word card for \(request.term, privacy: .public), offline entry: \(model.entry != nil, privacy: .public)")
    }

    /// The iPhone's own dictionary, on top of the card, for when its definitions are wanted too.
    private static func presentSystemDictionary(for term: String) {
        guard let presenter = topViewController(), !(presenter is UIReferenceLibraryViewController) else { return }
        presenter.present(UIReferenceLibraryViewController(term: term), animated: true)
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
