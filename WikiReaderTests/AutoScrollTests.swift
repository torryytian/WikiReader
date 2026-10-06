import Testing
import UIKit
@testable import WikiReader

/// Following the spoken word on a real, laid-out text view with the Einstein article.
@MainActor
@Suite(.serialized)
struct AutoScrollTests {
    let document: ArticleDocument
    let window: UIWindow
    let textView: UITextView
    let coordinator = ArticleTextView.Coordinator()

    init() throws {
        document = ArticleDocument(title: "Albert Einstein", blocks: try Fixture.blocks("albert_einstein"))
        // A short screen, so the longest paragraph spans more than one screen.
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        textView = UITextView(frame: window.bounds)
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.show(document)
        textView.layoutIfNeeded()
        ArticleTextView.Coordinator.followResumeDelay = 0.3
    }

    /// Speaks a word of a block and gives the scroll animation time to finish.
    private func speak(block: Int, offset: Int = 0) async throws {
        let start = document.blockRanges[block].location + offset
        coordinator.showSpokenWord(NSRange(location: start, length: 3), inBlock: block)
        try await Task.sleep(for: .milliseconds(600))
    }

    private var offset: CGFloat { textView.contentOffset.y }

    @Test func followsSpeechBelowTheScreen() async throws {
        #expect(offset == 0)
        try await speak(block: 8)
        let first = offset
        #expect(first > 0)
        try await speak(block: 20)
        #expect(offset > first)
    }

    /// The longest block, which spans more than a screen: used to test behavior within one block.
    private var longBlock: Int {
        document.blockRanges.indices.max { document.blockRanges[$0].length < document.blockRanges[$1].length }!
    }

    @Test func doesNotScrollWhileWordIsComfortablyVisible() async throws {
        // Off-screen text only has estimated positions in TextKit 2, and laying out text above the
        // target can shift it again, so the first scrolls may need corrections. Speak neighboring
        // positions until the view stops moving, then the next word on the same line mustn't scroll.
        try await speak(block: 8)
        var position = 1
        for _ in 0..<5 {
            let before = offset
            try await speak(block: 8, offset: position)
            position += 1
            if offset == before { break }
        }
        let settled = offset
        try await speak(block: 8, offset: position + 2)
        #expect(offset == settled)
    }

    @Test func userScrollPausesFollowingUntilScrollingStops() async throws {
        let block = longBlock
        let length = document.blockRanges[block].length
        try #require(length > 1200)
        try await speak(block: block)
        try await speak(block: block, offset: 1)
        coordinator.scrollViewWillBeginDragging(textView)
        let afterDrag = offset

        try await speak(block: block, offset: length - 20)  // off-screen, same block: don't follow
        #expect(offset == afterDrag)

        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        try await Task.sleep(for: .milliseconds(400))  // > followResumeDelay
        #expect(offset == afterDrag)  // resuming alone doesn't scroll...
        try await speak(block: block, offset: length - 10)
        #expect(offset > afterDrag)   // ...the next spoken word does
    }

    @Test func nextBlockResumesFollowing() async throws {
        let block = longBlock
        let length = document.blockRanges[block].length
        try await speak(block: block)
        try await speak(block: block, offset: 1)
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: true)  // still flinging: no timer yet
        let afterDrag = offset

        try await speak(block: block, offset: length - 20)
        #expect(offset == afterDrag)
        try await speak(block: block + 2)
        #expect(offset > afterDrag)
    }
}
