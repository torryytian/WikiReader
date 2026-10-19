import Foundation

/// A paragraph (or heading) the reader marked to come back to. Belongs to one article; at most one per block.
nonisolated struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Index of the block in the article's `blocks`.
    var block: Int
    var createdAt: Date
    /// The start of the block's text, so a list of bookmarks says what each one is about.
    var excerpt: String

    static let excerptLength = 140

    static func excerpt(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > excerptLength else { return trimmed }
        return String(trimmed.prefix(excerptLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension Article {
    /// Bookmarks in reading order. Stored as JSON in one field, like the saved words.
    var bookmarks: [Bookmark] {
        get {
            guard !bookmarksData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([Bookmark].self, from: bookmarksData)) ?? []
        }
        set {
            bookmarksData = (try? JSONEncoder().encode(newValue.sorted { $0.block < $1.block })) ?? Data()
        }
    }

    var bookmarkedBlocks: Set<Int> {
        Set(bookmarks.map(\.block))
    }

    func isBookmarked(block: Int) -> Bool {
        bookmarks.contains { $0.block == block }
    }

    /// Bookmarks `block` if it isn't yet, otherwise removes its bookmark. Returns whether it is bookmarked afterwards.
    @discardableResult
    func toggleBookmark(block: Int, text: String, at date: Date = .now) -> Bool {
        var marks = bookmarks
        if let index = marks.firstIndex(where: { $0.block == block }) {
            marks.remove(at: index)
            bookmarks = marks
            return false
        }
        marks.append(Bookmark(block: block, createdAt: date, excerpt: Bookmark.excerpt(of: text)))
        bookmarks = marks
        return true
    }

    func removeBookmark(id: Bookmark.ID) {
        bookmarks = bookmarks.filter { $0.id != id }
    }
}
