import SwiftData
import Testing
import UIKit
@testable import WikiReader

/// Restoring and tracking the reading position on a real text view with the Einstein article.
@MainActor
@Suite(.serialized)
struct ReadingPositionTests {
    let document: ArticleDocument
    let window: UIWindow
    let textView: LayoutReportingTextView
    let coordinator = ArticleTextView.Coordinator()

    init() throws {
        document = ArticleDocument(title: "Albert Einstein", blocks: try Fixture.blocks("albert_einstein"))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        textView = LayoutReportingTextView(frame: window.bounds)
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.show(document)
        textView.layoutIfNeeded()
    }

    @Test func startsAtTopWithFirstBlock() {
        #expect(textView.contentOffset.y == 0)
        #expect(coordinator.topVisibleBlock() == 0)  // the title maps to the first block
    }

    @Test(arguments: [5, 40, 120])
    func scrollToBlockPutsItAtTheTop(block: Int) {
        coordinator.scroll(toBlock: block)
        #expect(coordinator.topVisibleBlock() == block)
    }

    @Test func lastBlockIsVisibleEvenIfItCannotReachTheTop() throws {
        let last = document.blockRanges.count - 1
        coordinator.scroll(toBlock: last)
        let rect = try #require(textView.rect(of: NSRange(location: document.blockRanges[last].location, length: 1)))
        #expect(textView.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    @Test func pendingScrollRunsAfterLayout() async throws {
        let fresh = LayoutReportingTextView(frame: .zero)  // like makeUIView: no size yet
        let coordinator = ArticleTextView.Coordinator()
        coordinator.textView = fresh
        coordinator.show(document)
        coordinator.pendingScrollBlock = 60
        fresh.onLayout = { [weak coordinator] in coordinator?.performPendingScroll() }

        fresh.layoutIfNeeded()  // zero size: must not scroll or consume the pending block
        #expect(coordinator.pendingScrollBlock == 60)

        fresh.frame = window.bounds
        window.addSubview(fresh)
        fresh.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))  // the scroll is dispatched after layout
        #expect(coordinator.pendingScrollBlock == nil)
        #expect(coordinator.topVisibleBlock() == 60)
    }

    @Test func settledScrollReportsTopBlock() {
        var reported: [Int] = []
        coordinator.onScrollSettled = { reported.append($0) }
        coordinator.scroll(toBlock: 30)
        coordinator.scrollViewDidEndDecelerating(textView)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: true)  // still moving: no report
        #expect(reported == [30])
    }
}

@MainActor
struct LibraryDeleteTests {
    @Test func deleteRemovesOnlyThatArticle() throws {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let einstein = Article(title: "Albert Einstein", sourceURL: ArticleInput.articleURL(forTitle: "Albert Einstein"), blocks: [.paragraph("A")])
        let paris = Article(title: "Paris", sourceURL: ArticleInput.articleURL(forTitle: "Paris"), blocks: [.paragraph("B")])
        context.insert(einstein)
        context.insert(paris)
        try context.save()

        LibraryView.delete([einstein], from: context)

        let remaining = try context.fetch(FetchDescriptor<Article>())
        #expect(remaining.map(\.title) == ["Paris"])
    }
}
