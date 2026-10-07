import OSLog
import UIKit

/// The system dictionary with a floating pronunciation button on top.
///
/// The dictionary's own screen can't be extended, so the button is a subview laid over it. It speaks
/// only when pressed; nothing is spoken just because the dictionary opened.
final class PronouncingDictionaryViewController: UIReferenceLibraryViewController {
    private let term: String
    private let pronouncer: WordPronouncer

    init(term: String, voiceIdentifier: String?) {
        self.term = term
        pronouncer = WordPronouncer(voiceIdentifier: voiceIdentifier)
        super.init(term: term)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "speaker.wave.2.fill")
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            pronouncer.speak(term)
        })
        button.accessibilityLabel = "Pronounce \(term)"
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pronouncer.stop()
    }
}

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
        let voiceIdentifier = UserDefaults.standard.string(forKey: SettingsKeys.voiceIdentifier)
        let dictionary = PronouncingDictionaryViewController(term: request.term, voiceIdentifier: voiceIdentifier)
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
