import SwiftUI
import UIKit

/// Read-only, scrollable `UITextView` showing the whole article.
/// UIKit rather than SwiftUI `Text` because later phases need word hit-testing
/// (tap to look up), per-word highlighting and scrolling to a text range.
struct ArticleTextView: UIViewRepresentable {
    let document: ArticleDocument

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        // Selection would compete with tap-to-look-up in phase 2.
        textView.isSelectable = false
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        textView.alwaysBounceVertical = true
        textView.attributedText = document.attributedText
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Only replace the text when it actually changed: resetting it would lose the scroll position.
        if !textView.attributedText.isEqual(to: document.attributedText) {
            textView.attributedText = document.attributedText
        }
    }
}
