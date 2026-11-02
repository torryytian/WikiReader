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

    /// An article brought in from a file, photos or pasted text, rather than fetched from Wikipedia.
    var isImported: Bool { origin == Self.importedOrigin }

    /// Imported articles have no web page; this placeholder keeps `sourceURL` non-optional.
    static func importedSourceURL() -> URL {
        URL(string: "wikireader-import://local/\(UUID().uuidString)")!
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
