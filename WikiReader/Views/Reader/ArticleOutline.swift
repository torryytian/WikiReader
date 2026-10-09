import Foundation

/// The article's table of contents: its section headings, in order, each with the block it starts at and how far
/// into the article that is. Built from the blocks, so it needs nothing more than the article.
nonisolated struct ArticleOutline: Equatable {
    struct Entry: Equatable, Identifiable {
        var title: String
        /// Heading level as in wikitext (2 for a main section, 3 for a subsection, ...); 2 for the introduction.
        var level: Int
        /// Index of the heading's block, which is where reading jumps to.
        var block: Int
        /// 0 to 1: how much of the article's text comes before this section.
        var fraction: Double

        var id: Int { block }
        /// Nesting depth for display: main sections at 0, then 1, then 2 and deeper.
        var depth: Int { min(max(level - 2, 0), 2) }
        var percentText: String { "\(Int((fraction * 100).rounded()))%" }
    }

    static let introductionTitle = "Introduction"

    var entries: [Entry]

    init(blocks: [ContentBlock]) {
        let lengths = blocks.map(\.text.count)
        let total = lengths.reduce(0, +)
        var before = 0
        var entries: [Entry] = []
        for (index, block) in blocks.enumerated() {
            if block.kind == .heading {
                entries.append(Entry(title: block.text, level: block.level, block: index, fraction: total > 0 ? Double(before) / Double(total) : 0))
            }
            before += lengths[index]
        }
        // Text before the first heading is the introduction.
        if let first = entries.first, first.block > 0 {
            entries.insert(Entry(title: Self.introductionTitle, level: 2, block: 0, fraction: 0), at: 0)
        } else if entries.isEmpty, !blocks.isEmpty {
            entries = [Entry(title: Self.introductionTitle, level: 2, block: 0, fraction: 0)]
        }
        self.entries = entries
    }

    /// The entry the reader is in when at `block`: the last one that starts at or before it.
    func currentEntry(atBlock block: Int) -> Entry? {
        entries.last { $0.block <= block } ?? entries.first
    }
}
