import SwiftUI
import UIKit

/// Read-only, scrollable `UITextView` showing the whole article.
/// UIKit rather than SwiftUI `Text` because we need word hit-testing (tap to look up),
/// per-word highlighting and scrolling to a text range.
struct ArticleTextView: UIViewRepresentable {
    let document: ArticleDocument
    /// The word being read aloud, in full-text coordinates, and the block it belongs to.
    var spokenWord: NSRange?
    var spokenBlock: Int?
    /// Called with the full-text range of a tapped word. Taps on punctuation, numbers and blank space are ignored.
    var onWordTapped: (NSRange) -> Void = { _ in }
    /// Called with the index of a long-pressed block (the title counts as block 0).
    var onBlockLongPressed: (Int) -> Void = { _ in }

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
        textView.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        textView.addGestureRecognizer(longPress)

        context.coordinator.textView = textView
        context.coordinator.show(document)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onWordTapped = onWordTapped
        coordinator.onBlockLongPressed = onBlockLongPressed
        coordinator.show(document)
        coordinator.showSpokenWord(spokenWord, inBlock: spokenBlock)
    }

    /// The UIKit side: owns the gestures, highlights and scrolling. A plain class, so UIKit
    /// can call back into it (target-action, delegate), which a SwiftUI struct can't receive.
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var textView: UITextView?
        var onWordTapped: (NSRange) -> Void = { _ in }
        var onBlockLongPressed: (Int) -> Void = { _ in }

        private var document: ArticleDocument?
        private var shownText: NSAttributedString?
        /// A tap that stops a fling-scroll shouldn't also look up a word, matching system apps.
        private var tapStartedWhileScrolling = false

        private var spokenRange: NSRange?
        private var spokenBlock: Int?
        /// Set when the user scrolls during speech: stop following until speech reaches another block,
        /// so reading back a few lines isn't yanked away.
        private var followPausedInBlock: Int?

        private static let tapColor = UIColor.tintColor.withAlphaComponent(0.25)
        private static let spokenColor = UIColor { traits in
            UIColor.systemYellow.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.35 : 0.45)
        }

        func show(_ document: ArticleDocument) {
            // Compare identity, not contents: highlights edit the text view's copy,
            // and resetting the text would also reset the scroll position.
            guard let textView, shownText !== document.attributedText else { return }
            self.document = document
            shownText = document.attributedText
            spokenRange = nil
            textView.attributedText = document.attributedText
        }

        // MARK: Spoken word

        func showSpokenWord(_ range: NSRange?, inBlock block: Int?) {
            guard let textView, range != spokenRange else { return }
            let storage = textView.textStorage
            if let old = spokenRange, NSMaxRange(old) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            spokenRange = range
            spokenBlock = block
            guard let range, NSMaxRange(range) <= storage.length else { return }
            storage.addAttribute(.backgroundColor, value: Self.spokenColor, range: range)

            if let paused = followPausedInBlock, paused != block {
                followPausedInBlock = nil
            }
            if followPausedInBlock == nil {
                scrollToKeepVisible(range, in: textView)
            }
        }

        /// Keeps the spoken word on screen: once it gets near an edge, scroll it to a third of the way down.
        private func scrollToKeepVisible(_ range: NSRange, in textView: UITextView) {
            guard !textView.isTracking, !textView.isDecelerating,
                  let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }
            let wordRect = textView.firstRect(for: textRange)
            guard !wordRect.isNull, !wordRect.isInfinite else { return }

            let insets = textView.adjustedContentInset
            let visibleTop = textView.contentOffset.y + insets.top
            let visibleHeight = textView.bounds.height - insets.top - insets.bottom
            let comfortable = visibleTop + visibleHeight * 0.1 ... visibleTop + visibleHeight * 0.8
            guard !comfortable.contains(wordRect.minY) || !comfortable.contains(wordRect.maxY) else { return }

            let maxOffset = max(textView.contentSize.height + insets.bottom - textView.bounds.height, -insets.top)
            let target = min(max(wordRect.minY - insets.top - visibleHeight / 3, -insets.top), maxOffset)
            textView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if spokenRange != nil {
                followPausedInBlock = spokenBlock
            }
        }

        // MARK: Tap to look up

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
            storage.addAttribute(.backgroundColor, value: Self.tapColor, range: range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard range.upperBound <= storage.length else { return }
                storage.removeAttribute(.backgroundColor, range: range)
                // The flash may have covered the spoken word; put its highlight back.
                if let spoken = self?.spokenRange, NSIntersectionRange(spoken, range).length > 0 {
                    storage.addAttribute(.backgroundColor, value: Self.spokenColor, range: spoken)
                }
            }
        }

        // MARK: Long press to read from here

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let textView, let document else { return }
            let point = gesture.location(in: textView)
            guard let position = textView.closestPosition(to: point) else { return }
            // Ignore presses well away from any line of text (e.g. below the end of the article).
            let caret = textView.caretRect(for: position)
            guard abs(point.y - caret.midY) <= caret.height else { return }

            let location = textView.offset(from: textView.beginningOfDocument, to: position)
            guard let block = document.blockIndex(nearest: location) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onBlockLongPressed(block)
        }
    }
}
