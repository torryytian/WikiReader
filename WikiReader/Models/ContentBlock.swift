import Foundation

/// One readable unit of an article: a section heading or a paragraph.
/// Speech and highlighting work block by block, so blocks are the unit of position.
nonisolated struct ContentBlock: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heading
        case paragraph
    }

    var kind: Kind
    /// Heading level as in wikitext: `==` is 2, `===` is 3, and so on. Always 0 for paragraphs.
    var level: Int
    var text: String

    static func heading(_ text: String, level: Int) -> ContentBlock {
        ContentBlock(kind: .heading, level: level, text: text)
    }

    static func paragraph(_ text: String) -> ContentBlock {
        ContentBlock(kind: .paragraph, level: 0, text: text)
    }
}
