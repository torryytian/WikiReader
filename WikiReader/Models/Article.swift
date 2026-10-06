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

    init(title: String, sourceURL: URL, blocks: [ContentBlock], addedAt: Date = .now) {
        self.title = title
        self.sourceURL = sourceURL
        self.addedAt = addedAt
        self.blocksData = (try? JSONEncoder().encode(blocks)) ?? Data()
        self.lastReadBlockIndex = 0
    }

    var blocks: [ContentBlock] {
        (try? JSONDecoder().decode([ContentBlock].self, from: blocksData)) ?? []
    }
}
