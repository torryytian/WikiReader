import Foundation
@testable import WikiReader

/// Loads saved API responses from `Fixtures/` (captured with curl; tests never touch the network).
enum Fixture {
    private final class BundleToken {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    static func article(_ name: String) throws -> FetchedArticle {
        try WikipediaClient.parseResponse(data(name))
    }

    /// Cleaned blocks of a fixture article.
    static func blocks(_ name: String) throws -> [ContentBlock] {
        ArticleCleaner.blocks(from: try article(name).extract)
    }
}
