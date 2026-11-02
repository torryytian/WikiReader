import Foundation
import SwiftData

@Model
final class Article {
    var title: String
    var sourceURL: URL
    var addedAt: Date
    /// `[ContentBlock]` encoded as JSON. Stored as a single blob so the schema
    /// stays simple and block changes don't require SwiftData migrations.
    var blocksData: Data
    /// Index into `blocks` of the last block read or spoken.
    var lastReadBlockIndex: Int
    /// `[SavedWord]` encoded as JSON (see `SavedWord.swift`). The default lets existing databases upgrade in place.
    var savedWordsData: Data = Data()
    /// `[Bookmark]` encoded as JSON (see `Bookmark.swift`). The default lets existing databases upgrade in place.
    var bookmarksData: Data = Data()
    /// Where the text came from: `Article.wikipediaOrigin`, or `Article.importedOrigin` for a file, photos or pasted
    /// text. The default lets existing databases upgrade in place (all of them are Wikipedia articles).
    var origin: String = Article.wikipediaOrigin

    static let wikipediaOrigin = "wikipedia"
    static let importedOrigin = "imported"

    /// The scheme of an imported article's placeholder `sourceURL`.
    static let importedScheme = "wikireader-import"

    /// An article brought in from a file, photos or pasted text, rather than fetched from Wikipedia. Its placeholder
    /// URL says so too, which still holds when `origin` was lost: a build without that field opened the store (on
    /// 2026-11-01 the iPhone ran such a build, and SwiftData dropped the column) and left the default behind.
    var isImported: Bool { origin == Self.importedOrigin || sourceURL.scheme == Self.importedScheme }

    /// Imported articles have no web page; this placeholder keeps `sourceURL` non-optional.
    static func importedSourceURL() -> URL {
        URL(string: "\(importedScheme)://local/\(UUID().uuidString)")!
    }

    /// Puts back `origin` on imported articles that lost it (see `isImported`). Returns whether anything changed.
    @discardableResult
    static func repairOrigins(_ articles: [Article]) -> Bool {
        var changed = false
        for article in articles where article.isImported && article.origin != importedOrigin {
            article.origin = importedOrigin
            changed = true
        }
        return changed
    }

    init(title: String, sourceURL: URL, blocks: [ContentBlock], addedAt: Date = .now) {
        self.title = title
        self.sourceURL = sourceURL
        self.addedAt = addedAt
        self.blocksData = (try? JSONEncoder().encode(blocks)) ?? Data()
        self.lastReadBlockIndex = 0
    }

    var blocks: [ContentBlock] {
        Self.decodeBlocks(blocksData)
    }

    /// For work off the main actor on a copy of `blocksData` (a long article takes a moment to decode).
    nonisolated static func decodeBlocks(_ data: Data) -> [ContentBlock] {
        (try? JSONDecoder().decode([ContentBlock].self, from: data)) ?? []
    }
}
