import Foundation
import SwiftData
import Testing
import UIKit
@testable import WikiReader

@MainActor
struct BookmarkTests {
    let container: ModelContainer
    let article: Article

    init() throws {
        container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        article = Article(
            title: "Paris", sourceURL: ArticleInput.articleURL(forTitle: "Paris"),
            blocks: [.paragraph("Paris is the capital of France."), .heading("History", level: 2), .paragraph("Long ago.")]
        )
        container.mainContext.insert(article)
        try container.mainContext.save()
    }

    @Test func toggleAddsThenRemovesAndKeepsReadingOrder() {
        #expect(article.bookmarks.isEmpty)
        #expect(article.toggleBookmark(block: 2, text: "Long ago."))
        #expect(article.toggleBookmark(block: 0, text: "Paris is the capital of France."))
        #expect(article.bookmarks.map(\.block) == [0, 2])
        #expect(article.bookmarks.first?.excerpt == "Paris is the capital of France.")
        #expect(article.isBookmarked(block: 2))
        #expect(article.bookmarkedBlocks == [0, 2])

        #expect(!article.toggleBookmark(block: 2, text: "Long ago."))
        #expect(article.bookmarks.map(\.block) == [0])
    }

    @Test func removeByID() {
        article.toggleBookmark(block: 0, text: "a")
        article.toggleBookmark(block: 2, text: "b")
        let first = article.bookmarks[0]
        article.removeBookmark(id: first.id)
        #expect(article.bookmarks.map(\.block) == [2])
    }

    @Test func bookmarksSurviveSaving() throws {
        article.toggleBookmark(block: 1, text: "History")
        try container.mainContext.save()
        let fetched = try container.mainContext.fetch(FetchDescriptor<Article>())
        #expect(fetched.first?.bookmarks.map(\.block) == [1])
    }

    @Test func longTextIsShortenedForTheExcerpt() {
        let long = String(repeating: "word ", count: 100)
        let excerpt = Bookmark.excerpt(of: long)
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.count <= Bookmark.excerptLength + 1)
        #expect(Bookmark.excerpt(of: "  Short.  ") == "Short.")
    }

    @Test func markersSitOutsideTheBlocksSoTheirTextIsUnchanged() {
        let blocks = article.blocks
        let plain = ArticleDocument(title: "Paris", blocks: blocks)
        let marked = ArticleDocument(title: "Paris", blocks: blocks, bookmarkedBlocks: [0, 2])
        for index in blocks.indices {
            #expect(marked.blockText(index) == blocks[index].text)
        }
        // Each marker is an attachment and a thin space, placed before its block.
        #expect(marked.attributedText.length == plain.attributedText.length + 4)
        #expect(marked.blockRanges[0].location == plain.blockRanges[0].location + 2)
        #expect(marked.attributedText.attribute(.attachment, at: marked.blockRanges[0].location - 2, effectiveRange: nil) != nil)
        // A selection over the marker still belongs to the block after it.
        #expect(marked.blockIndex(nearest: marked.blockRanges[2].location - 1) == 2)
        #expect(marked.bookmarkedBlocks == [0, 2])
        #expect(marked.layout == plain.layout)
    }
}
