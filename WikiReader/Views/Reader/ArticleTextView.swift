import OSLog
import SwiftUI
import UIKit

/// Read-only, scrollable `UITextView` showing the whole article.
/// UIKit rather than SwiftUI `Text` because we need word hit-testing (tap to look up),
/// per-word highlighting and scrolling to a text range.
struct ArticleTextView: UIViewRepresentable {
    enum TapZone: Equatable {
        case top, middle, bottom

        /// Height of the strip, below the top safe area / above the bottom one, where a tap opens a menu.
        static let topStrip: CGFloat = 40
        static let bottomStrip: CGFloat = 70

        /// Which zone a tap at `y` (measured from the top of the text view) is in. The top zone also
        /// includes the safe area above the text view, which is handled outside it, so only `topStrip` counts here.
        static func zone(forY y: CGFloat, viewHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> TapZone {
            if y < topInset + topStrip { return .top }
            if y > viewHeight - bottomInset - bottomStrip { return .bottom }
            return .middle
        }
    }

    let document: ArticleDocument
    var style = ReaderStyle.default
    /// The word being read aloud, in full-text coordinates, and the block it belongs to.
    var spokenWord: NSRange?
    var spokenBlock: Int?
    /// Called with the full-text range of a tapped word. Taps on punctuation, numbers and blank space are ignored.
    var onWordTapped: (NSRange) -> Void = { _ in }
    /// Called with the index of the block where a selection starts, from the selection menu's "Read From Here".
    var onReadFromHere: (Int) -> Void = { _ in }
    /// Called with article text to translate: a selection, or a paragraph whose "Translate" label was tapped.
    var onTranslate: (String) -> Void = { _ in }
    /// Called for a tap that isn't on a word: near the top or bottom edge (where the menus are), or elsewhere.
    var onTapZone: (TapZone) -> Void = { _ in }
    /// Lowercased words and terms the reader saved; they get a light highlight wherever they appear.
    var savedWordKeys: Set<String> = []
    /// Called when the reader swipes left across the text.
    var onSwipeLeft: () -> Void = {}
    /// Called when the user starts dragging the text, so overlays can get out of the way.
    var onScrollBegan: () -> Void = {}
    /// Block to show at the top when the article first appears.
    var initialBlock = 0
    /// Called with the block at the top of the screen after the user scrolls and lets go.
    var onScrollSettled: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = LayoutReportingTextView()
        textView.isEditable = false
        // Long press selects text (to translate several words or paragraphs); a single tap still looks up a word.
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        textView.alwaysBounceVertical = true
        textView.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipe.delegate = context.coordinator
        textView.addGestureRecognizer(swipe)

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.apply(style)
        coordinator.show(document)
        if initialBlock > 0 {
            // The view has no size yet; scroll once it has been laid out.
            coordinator.pendingScrollBlock = initialBlock
            textView.onLayout = { [weak coordinator] in coordinator?.performPendingScroll() }
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onWordTapped = onWordTapped
        coordinator.onReadFromHere = onReadFromHere
        coordinator.onTranslate = onTranslate
        coordinator.onTapZone = onTapZone
        coordinator.onSwipeLeft = onSwipeLeft
        coordinator.onScrollBegan = onScrollBegan
        coordinator.onScrollSettled = onScrollSettled
        coordinator.apply(style)
        coordinator.show(document)
        coordinator.showSavedWords(savedWordKeys)
        coordinator.showSpokenWord(spokenWord, inBlock: spokenBlock)
    }

    /// The UIKit side: owns the gestures, highlights and scrolling. A plain class, so UIKit
    /// can call back into it (target-action, delegate), which a SwiftUI struct can't receive.
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var textView: UITextView?
        var onWordTapped: (NSRange) -> Void = { _ in }
        var onReadFromHere: (Int) -> Void = { _ in }
        var onTranslate: (String) -> Void = { _ in }
        var onTapZone: (TapZone) -> Void = { _ in }
        var onSwipeLeft: () -> Void = {}
        var onScrollBegan: () -> Void = {}
        var onScrollSettled: (Int) -> Void = { _ in }
        var pendingScrollBlock: Int?

        private var document: ArticleDocument?
        private var shownText: NSAttributedString?
        /// A tap that stops a fling-scroll shouldn't also look up a word, matching system apps.
        private var tapStartedWhileScrolling = false
        /// A tap that dismisses a selection (and its menu) shouldn't also look up a word. Recorded when the
        /// touch begins, because the text view's own tap clears the selection before ours is handled.
        private var tapStartedWithSelection = false
        private var shownStyle: ReaderStyle?

        private var spokenRange: NSRange?
        private var spokenBlock: Int?
        /// Set while following is paused because the user scrolled during speech, so reading back a few
        /// lines isn't yanked away. Holds the block being spoken when the user started scrolling.
        private var followPausedInBlock: Int?
        private var resumeFollowing: DispatchWorkItem?
        /// How long after the user's scrolling stops before the view follows speech again.
        static var followResumeDelay: TimeInterval = 3

        private var savedKeys: Set<String>?
        private var savedRanges: [NSRange] = []

        private static let savedColor = UIColor { traits in
            UIColor.systemOrange.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.28 : 0.2)
        }
        private static let tapColor = UIColor.tintColor.withAlphaComponent(0.25)
        private static let spokenColor = UIColor { traits in
            UIColor.systemYellow.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.35 : 0.45)
        }

        func show(_ document: ArticleDocument) {
            // Compare identity, not contents: highlights edit the text view's copy,
            // and resetting the text would also reset the scroll position.
            guard let textView, shownText !== document.attributedText else { return }
            // A new text (e.g. after changing the font size) starts at the top; scroll back to where the reader was.
            let anchor = shownText == nil ? nil : topVisibleBlock()
            self.document = document
            shownText = document.attributedText
            spokenRange = nil
            savedKeys = nil
            savedRanges = []
            textView.attributedText = document.attributedText
            if let anchor { scroll(toBlock: anchor) }
        }

        /// Colors and margins; the fonts and text colors are in the document itself.
        func apply(_ style: ReaderStyle) {
            guard let textView, style != shownStyle else { return }
            shownStyle = style
            textView.backgroundColor = style.backgroundColor
            textView.overrideUserInterfaceStyle = switch style.theme.colorScheme {
            case .light?: .light
            case .dark?: .dark
            default: .unspecified
            }
            textView.textContainerInset.left = style.margins.inset
            textView.textContainerInset.right = style.margins.inset
        }

        // MARK: Saved words

        /// Lightly highlights every occurrence of the saved words. Redone only when the set of words changes
        /// (or the text is replaced), since it walks the whole article.
        func showSavedWords(_ keys: Set<String>) {
            guard let textView, let document, keys != savedKeys else { return }
            let storage = textView.textStorage
            for range in savedRanges where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            savedKeys = keys
            savedRanges = document.ranges(ofWords: keys)
            for range in savedRanges where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: Self.savedColor, range: range)
            }
            // The spoken word keeps its stronger highlight over a saved one.
            if let spoken = spokenRange, NSMaxRange(spoken) <= storage.length {
                storage.addAttribute(.backgroundColor, value: Self.spokenColor, range: spoken)
            }
        }

        /// Removes a temporary highlight (spoken word, tap flash) and puts back the saved-word tint under it.
        private func clearHighlight(in range: NSRange, of storage: NSTextStorage) {
            storage.removeAttribute(.backgroundColor, range: range)
            for saved in savedRanges where NSMaxRange(saved) <= storage.length && NSIntersectionRange(saved, range).length > 0 {
                storage.addAttribute(.backgroundColor, value: Self.savedColor, range: saved)
            }
        }

        // MARK: Spoken word

        func showSpokenWord(_ range: NSRange?, inBlock block: Int?) {
            guard let textView, range != spokenRange else { return }
            let storage = textView.textStorage
            if let old = spokenRange, NSMaxRange(old) <= storage.length {
                clearHighlight(in: old, of: storage)
            }
            spokenRange = range
            spokenBlock = block
            guard let range, NSMaxRange(range) <= storage.length else { return }
            storage.addAttribute(.backgroundColor, value: Self.spokenColor, range: range)

            if let paused = followPausedInBlock, paused != block, !textView.isTracking {
                resumeFollowingSpeech(reason: "speech reached block \(block ?? -1)")
            }
            if followPausedInBlock == nil {
                scrollToKeepVisible(range, in: textView)
            }
        }

        /// Keeps the spoken word on screen: once it gets near an edge, scroll it to a third of the way down.
        private func scrollToKeepVisible(_ range: NSRange, in textView: UITextView) {
            guard !textView.isTracking, !textView.isDecelerating, let wordRect = textView.rect(of: range) else { return }

            let insets = textView.adjustedContentInset
            let visibleTop = textView.contentOffset.y + insets.top
            let visibleHeight = textView.bounds.height - insets.top - insets.bottom
            let comfortable = visibleTop + visibleHeight * 0.1 ... visibleTop + visibleHeight * 0.8
            guard !comfortable.contains(wordRect.minY) || !comfortable.contains(wordRect.maxY) else { return }

            let target = textView.clampedOffset(wordRect.minY - insets.top - visibleHeight / 3)
            Log.speech.info("Auto-scroll to y=\(Int(target)) for word at y=\(Int(wordRect.minY))")
            textView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        }

        // MARK: Reading position

        func performPendingScroll() {
            guard pendingScrollBlock != nil, let textView, textView.bounds.height > 0 else { return }
            // Not from inside layoutSubviews: scrolling there would re-enter layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, let block = pendingScrollBlock else { return }
                pendingScrollBlock = nil
                scroll(toBlock: block)
            }
        }

        /// Puts the start of a block at the top of the screen.
        func scroll(toBlock block: Int) {
            guard let textView, let document, document.blockRanges.indices.contains(block) else { return }
            let start = NSRange(location: document.blockRanges[block].location, length: 1)
            // Off-screen positions are estimates in TextKit 2 until laid out, so measure again
            // after each jump until the position stops moving.
            for _ in 0..<4 {
                guard let rect = textView.rect(of: start) else { return }
                let target = textView.clampedOffset(rect.minY - textView.adjustedContentInset.top - 8)
                guard abs(target - textView.contentOffset.y) >= 1 else { break }
                textView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                textView.layoutIfNeeded()
            }
            Log.app.info("Restored reading position: block \(block)")
        }

        /// The block whose text is at the top of the visible area.
        func topVisibleBlock() -> Int? {
            guard let textView, let document else { return nil }
            let point = CGPoint(
                x: textView.textContainerInset.left + 1,
                y: textView.contentOffset.y + textView.adjustedContentInset.top + textView.textContainerInset.top
            )
            guard let position = textView.closestPosition(to: point) else { return nil }
            return document.blockIndex(nearest: textView.offset(from: textView.beginningOfDocument, to: position))
        }

        private func reportScrollSettled() {
            if let block = topVisibleBlock() {
                onScrollSettled(block)
            }
        }

        // Following pauses when the user starts scrolling during speech, and resumes once their
        // scrolling has stopped for a moment or speech moves on to another block, whichever comes first.

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onScrollBegan()
            resumeFollowing?.cancel()
            guard spokenRange != nil, followPausedInBlock == nil else { return }
            followPausedInBlock = spokenBlock
            Log.speech.info("Follow paused: user scrolling")
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                scheduleResumeFollowing()
                reportScrollSettled()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scheduleResumeFollowing()
            reportScrollSettled()
        }

        private func scheduleResumeFollowing() {
            guard followPausedInBlock != nil else { return }
            resumeFollowing?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.resumeFollowingSpeech(reason: "scrolling stopped")
            }
            resumeFollowing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.followResumeDelay, execute: work)
        }

        private func resumeFollowingSpeech(reason: String) {
            resumeFollowing?.cancel()
            resumeFollowing = nil
            guard followPausedInBlock != nil else { return }
            followPausedInBlock = nil
            Log.speech.info("Follow resumed: \(reason, privacy: .public)")
            // No scroll here: the next spoken word scrolls into view. While speech is paused
            // nothing is spoken, so browsing the article doesn't get pulled back.
        }

        // MARK: Taps

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            tapStartedWhileScrolling = textView?.isDecelerating ?? false
            tapStartedWithSelection = (textView?.selectedRange.length ?? 0) > 0
            return true
        }

        /// Our tap runs next to the text view's own selection gestures instead of waiting for them.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// The swipe recognizer only starts for a clearly sideways, leftward movement, so ordinary scrolling is untouched.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > 2 * abs(velocity.y)
        }

        @objc func handleSwipe(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let translation = gesture.translation(in: gesture.view)
            if translation.x < -80 && abs(translation.x) > 2 * abs(translation.y) {
                onSwipeLeft()
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, !tapStartedWhileScrolling, let textView, let document else { return }
            if tapStartedWithSelection {
                textView.selectedTextRange = nil
                return
            }

            let point = gesture.location(in: textView)
            let zone = tapZone(forY: point.y - textView.contentOffset.y, in: textView)
            guard zone == .middle else {
                onTapZone(zone)
                return
            }

            onTapZone(.middle)
            if let label = translateLabel(at: point, in: textView, document: document) {
                if let text = document.blockText(label) { onTranslate(text) }
                return
            }
            guard let range = textView.lookupWordRange(at: point) else { return }
            flashHighlight(range, in: textView)
            onWordTapped(range)
        }

        /// The top and bottom strips are where the menus appear, so taps there never look up a word.
        private func tapZone(forY y: CGFloat, in textView: UITextView) -> TapZone {
            let insets = textView.adjustedContentInset
            return TapZone.zone(forY: y, viewHeight: textView.bounds.height, topInset: insets.top, bottomInset: insets.bottom)
        }

        /// The block whose "Translate" label is under `point`.
        private func translateLabel(at point: CGPoint, in textView: UITextView, document: ArticleDocument) -> Int? {
            guard let position = textView.closestPosition(to: point) else { return nil }
            let location = textView.offset(from: textView.beginningOfDocument, to: position)
            // closestPosition may land just after the label, so look at the character before it as well.
            for candidate in [location, location - 1] {
                guard let block = document.translateBlock(at: candidate),
                      let start = textView.position(from: textView.beginningOfDocument, offset: candidate),
                      let end = textView.position(from: start, offset: 1),
                      let range = textView.textRange(from: start, to: end)
                else { continue }
                let hit = textView.selectionRects(for: range).contains { $0.rect.insetBy(dx: -6, dy: -8).contains(point) }
                if hit { return block }
            }
            return nil
        }

        /// Briefly tints the tapped word as touch feedback.
        private func flashHighlight(_ range: NSRange, in textView: UITextView) {
            let storage = textView.textStorage
            storage.addAttribute(.backgroundColor, value: Self.tapColor, range: range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard range.upperBound <= storage.length else { return }
                self?.clearHighlight(in: range, of: storage)
                // The flash may have covered the spoken word; put its highlight back.
                if let spoken = self?.spokenRange, NSIntersectionRange(spoken, range).length > 0 {
                    storage.addAttribute(.backgroundColor, value: Self.spokenColor, range: spoken)
                }
            }
        }

        // MARK: Selection menu

        /// The menu over a selection: translate it, read from it, or copy it. Our own menu instead of the system's,
        /// whose "Look Up" and "Share" lead to web search.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let document, range.length > 0 else { return nil }
            let text = document.selectedText(in: range)
            guard !text.isEmpty else { return nil }

            let translate = UIAction(title: "AI Translate", image: UIImage(systemName: "character.bubble")) { [weak self, weak textView] _ in
                textView?.selectedTextRange = nil
                self?.onTranslate(text)
            }
            var actions = [translate]
            if let block = document.blockIndex(nearest: range.location) {
                actions.append(UIAction(title: "Read From Here", image: UIImage(systemName: "play")) { [weak self, weak textView] _ in
                    textView?.selectedTextRange = nil
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    self?.onReadFromHere(block)
                })
            }
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            })
            return UIMenu(children: actions)
        }
    }
}

/// A text view that reports layout passes, so work that needs a real size can wait for one.
final class LayoutReportingTextView: UITextView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

extension UITextView {
    /// On-screen rect (content coordinates) of the first line of a text range.
    func rect(of range: NSRange) -> CGRect? {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end)
        else { return nil }
        let rect = firstRect(for: textRange)
        return rect.isNull || rect.isInfinite ? nil : rect
    }

    /// A vertical content offset limited to the scrollable range.
    func clampedOffset(_ y: CGFloat) -> CGFloat {
        let insets = adjustedContentInset
        let maxOffset = max(contentSize.height + insets.bottom - bounds.height, -insets.top)
        return min(max(y, -insets.top), maxOffset)
    }
}
