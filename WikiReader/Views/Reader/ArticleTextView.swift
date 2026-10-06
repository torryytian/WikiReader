import SwiftUI
import UIKit

/// Read-only, scrollable `UITextView` showing the whole article.
/// UIKit rather than SwiftUI `Text` because we need word hit-testing (tap to look up),
/// per-word highlighting and scrolling to a text range.
struct ArticleTextView: UIViewRepresentable {
    let document: ArticleDocument
    /// Called with the full-text range of a tapped word. Taps on punctuation, numbers and blank space are ignored.
    var onWordTapped: (NSRange) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        // Selection would compete with tap-to-look-up.
        textView.isSelectable = false
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        textView.alwaysBounceVertical = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        context.coordinator.show(document)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onWordTapped = onWordTapped
        context.coordinator.show(document)
    }

    /// The UIKit side: owns the gesture and the temporary highlight. A plain class, so UIKit
    /// can call back into it (target-action, delegate), which a SwiftUI struct can't receive.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var textView: UITextView?
        var onWordTapped: (NSRange) -> Void = { _ in }

        private var shownText: NSAttributedString?
        /// A tap that stops a fling-scroll shouldn't also look up a word, matching system apps.
        private var tapStartedWhileScrolling = false

        func show(_ document: ArticleDocument) {
            // Compare identity, not contents: the highlight edits the text view's copy,
            // and resetting the text would also reset the scroll position.
            guard let textView, shownText !== document.attributedText else { return }
            shownText = document.attributedText
            textView.attributedText = document.attributedText
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            tapStartedWhileScrolling = textView?.isDecelerating ?? false
            return true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, !tapStartedWhileScrolling, let textView else { return }
            guard let range = textView.lookupWordRange(at: gesture.location(in: textView)) else { return }
            flashHighlight(range, in: textView)
            onWordTapped(range)
        }

        /// Briefly tints the tapped word as touch feedback.
        private func flashHighlight(_ range: NSRange, in textView: UITextView) {
            let storage = textView.textStorage
            storage.addAttribute(.backgroundColor, value: UIColor.tintColor.withAlphaComponent(0.25), range: range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard range.upperBound <= storage.length else { return }
                storage.removeAttribute(.backgroundColor, range: range)
            }
        }
    }
}
