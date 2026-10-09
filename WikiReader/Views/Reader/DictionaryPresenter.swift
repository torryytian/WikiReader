import OSLog
import SwiftUI
import UIKit

/// The system dictionary with floating pronunciation and AI buttons on top.
///
/// The dictionary's own screen can't be extended (nor can its "Search Web" row be removed), so the
/// buttons are subviews laid over it. Each does something only when pressed: nothing is spoken or
/// sent to OpenAI just because the dictionary opened.
final class PronouncingDictionaryViewController: UIReferenceLibraryViewController, UIGestureRecognizerDelegate {
    private let request: WordLookupRequest
    private let pronouncer: WordPronouncer
    private let saving: WordSaving?
    /// Called once, after the dictionary has been closed (by its Done button or by swiping down).
    private var onDismiss: () -> Void
    /// The meaning from an AI explanation opened on this screen; saved along with the word.
    private var meaning: String?

    init(request: WordLookupRequest, voiceIdentifier: String?, saving: WordSaving?, onDismiss: @escaping () -> Void = {}) {
        self.request = request
        self.saving = saving
        self.onDismiss = onDismiss
        pronouncer = WordPronouncer(voiceIdentifier: voiceIdentifier)
        super.init(term: request.term)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // The system dictionary sets itself up as "can't be swiped away" and can put that back after it was changed from
    // outside, so a swipe down did nothing. Overridden here, nothing can set it back.
    override var isModalInPresentation: Bool {
        get { false }
        set {}
    }

    override var modalPresentationStyle: UIModalPresentationStyle {
        get { .pageSheet }
        set {}
    }

    /// The dictionary's own content is drawn and handled by another process, so touches on it never reach this app:
    /// no gesture added here can see a drag that starts on a word or a definition. The grabber (the system sheet's)
    /// and this strip can: a transparent area over the title bar, as wide as the bar except for the close button,
    /// that closes the dictionary when dragged down. Much easier to hit than the grabber alone.
    private lazy var dragStrip: UIView = {
        let strip = UIView()
        strip.backgroundColor = .clear
        strip.accessibilityElementsHidden = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        pan.allowedScrollTypesMask = .all
        strip.addGestureRecognizer(pan)
        return strip
    }()

    /// Height of the strip from the top of the sheet: the grabber and the title row, including the "Dictionary" heading (not tappable), down to the first entry.
    private static let dragStripHeight: CGFloat = 104
    /// Width left free on the right for the system's close button.
    private static let closeButtonWidth: CGFloat = 72

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dragStrip.frame = CGRect(x: 0, y: 0, width: max(view.bounds.width - Self.closeButtonWidth, 0), height: Self.dragStripHeight)
        view.bringSubviewToFront(dragStrip)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Mostly downward, so a sideways swipe isn't taken.
        let velocity = pan.velocity(in: pan.view)
        return velocity.y > 0 && abs(velocity.y) > 1.2 * abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        if pan.translation(in: view).y > 40 || pan.velocity(in: view).y > 500 {
            Log.lookup.info("Dictionary closed by a swipe down")
            dismiss(animated: true)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(dragStrip)

        let explainButton = floatingButton(title: "AI", symbol: "sparkles", label: "Explain \(request.word) with AI") { [weak self] in
            self?.showExplanation()
        }
        let speakButton = floatingButton(title: nil, symbol: "speaker.wave.2.fill", label: "Pronounce \(request.term)") { [weak self] in
            guard let self else { return }
            pronouncer.speak(request.term)
        }

        var arranged = [explainButton, speakButton]
        if let saving {
            arranged.insert(saveButton(for: saving), at: 0)
        }
        let buttons = UIStackView(arrangedSubviews: arranged)
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    /// Bookmark that adds the word to this article's word list, or removes it again.
    private func saveButton(for saving: WordSaving) -> UIButton {
        func configure(_ button: UIButton, isSaved: Bool) {
            button.configuration?.image = UIImage(systemName: isSaved ? "bookmark.fill" : "bookmark")
            button.accessibilityLabel = isSaved ? "Remove \(request.word) from saved words" : "Save \(request.word)"
        }
        let button = floatingButton(title: nil, symbol: "bookmark", label: "") { }
        configure(button, isSaved: saving.isSaved)
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let button else { return }
            configure(button, isSaved: saving.toggle(self?.meaning))
        }, for: .primaryActionTriggered)
        return button
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
        model.onLoaded = { [weak self] explanation in
            guard let self else { return }
            meaning = explanation.meaning
            saving?.setMeaning(explanation.meaning)
        }
        let sheet = UIHostingController(rootView: WordExplanationView(model: model))
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        // The grabber is a handle that always drags the sheet away, even over scrolling content.
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        present(sheet, animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Log.lookup.info("Dictionary shown: modal \(self.isModalInPresentation, privacy: .public), style \(self.modalPresentationStyle.rawValue, privacy: .public), sheet \(self.sheetPresentationController != nil, privacy: .public)")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pronouncer.stop()
        // Not when only something on top of the dictionary (the AI sheet) came or went.
        if isBeingDismissed || presentingViewController == nil {
            let finished = onDismiss
            onDismiss = {}
            finished()
        }
    }
}

/// How the dictionary screen saves its word: the current state, and a toggle that returns the new state.
struct WordSaving {
    var isSaved: Bool
    /// Saves or removes the word, given a meaning to keep if one is known. Returns the new state.
    var toggle: (String?) -> Bool
    /// Gives an already saved word a meaning.
    var setMeaning: (String) -> Void
}

/// Shows the iOS system dictionary for a lookup request.
///
/// Presented directly with UIKit rather than through a SwiftUI `.sheet`: the dictionary
/// controller dismisses itself with its own Done button, and a SwiftUI sheet would keep a
/// separate "is presented" state that can fall out of sync with that.
enum DictionaryPresenter {
    /// - Parameter saving: When given, the dictionary gets a bookmark button for the article's word list.
    /// - Parameter onDismiss: Called when the dictionary has been closed, however that happened.
    static func present(_ request: WordLookupRequest, saving: WordSaving? = nil, onDismiss: @escaping () -> Void = {}) {
        guard let presenter = topViewController() else {
            Log.lookup.error("No view controller to present the dictionary from")
            return
        }
        // A second tap while the dictionary is still animating in would otherwise stack two.
        guard !(presenter is UIReferenceLibraryViewController) else { return }

        // Shown even without a definition: the system screen then offers to manage/download dictionaries.
        let voiceIdentifier = UserDefaults.standard.string(forKey: SettingsKeys.voiceIdentifier)
        let dictionary = PronouncingDictionaryViewController(
            request: request, voiceIdentifier: voiceIdentifier, saving: saving, onDismiss: onDismiss
        )
        // A sheet with a grabber to drag; a swipe down closes it (see the view controller for how that is kept working).
        dictionary.sheetPresentationController?.detents = [.medium(), .large()]
        dictionary.sheetPresentationController?.prefersGrabberVisible = true
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
