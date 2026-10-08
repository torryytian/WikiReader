import OSLog
import SwiftUI
import UIKit

/// The system dictionary with floating pronunciation and AI buttons on top.
///
/// The dictionary's own screen can't be extended (nor can its "Search Web" row be removed), so the
/// buttons are subviews laid over it. Each does something only when pressed: nothing is spoken or
/// sent to OpenAI just because the dictionary opened.
final class PronouncingDictionaryViewController: UIReferenceLibraryViewController {
    private let request: WordLookupRequest
    private let pronouncer: WordPronouncer

    init(request: WordLookupRequest, voiceIdentifier: String?) {
        self.request = request
        pronouncer = WordPronouncer(voiceIdentifier: voiceIdentifier)
        super.init(term: request.term)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let explainButton = floatingButton(title: "AI", symbol: "sparkles", label: "Explain \(request.word) with AI") { [weak self] in
            self?.showExplanation()
        }
        let speakButton = floatingButton(title: nil, symbol: "speaker.wave.2.fill", label: "Pronounce \(request.term)") { [weak self] in
            guard let self else { return }
            pronouncer.speak(request.term)
        }

        let buttons = UIStackView(arrangedSubviews: [explainButton, speakButton])
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    private func floatingButton(title: String?, symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        return button
    }

    private func showExplanation() {
        let model = WordExplanationModel(word: request.word, sentence: request.sentence)
        let sheet = UIHostingController(rootView: WordExplanationView(model: model))
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        present(sheet, animated: true)
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
        let dictionary = PronouncingDictionaryViewController(request: request, voiceIdentifier: voiceIdentifier)
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
