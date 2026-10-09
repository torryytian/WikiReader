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
        /// Characters in this section's own text, up to the next heading of any level.
        var characters = 0
        /// The text before the first heading, which has no heading of its own.
        var isIntroduction = false

        var id: Int { block }
        /// Nesting depth for display: main sections at 0, then 1, then 2 and deeper.
        var depth: Int { min(max(level - 2, 0), 2) }
        var percentText: String { "\(Int((fraction * 100).rounded()))%" }

        /// Reading time of the section's own text at normal speed, at least one minute.
        var minutes: Int {
            max(1, Int((Double(characters) / (ReadingSession.charactersPerSecond * 60)).rounded()))
        }
    }

    static let introductionTitle = "Introduction"

    var entries: [Entry]
    /// All the article's characters, for the total reading time.
    var totalCharacters: Int

    var totalMinutes: Int {
        max(1, Int((Double(totalCharacters) / (ReadingSession.charactersPerSecond * 60)).rounded()))
    }

    init(blocks: [ContentBlock]) {
        let lengths = blocks.map(\.text.count)
        let total = lengths.reduce(0, +)
        totalCharacters = total
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
            entries.insert(Entry(title: Self.introductionTitle, level: 2, block: 0, fraction: 0, isIntroduction: true), at: 0)
        } else if entries.isEmpty, !blocks.isEmpty {
            entries = [Entry(title: Self.introductionTitle, level: 2, block: 0, fraction: 0, isIntroduction: true)]
        }
        // Each section's own length: from its start to the next entry's start (or the end).
        var starts = entries.map { entry in lengths.prefix(entry.block).reduce(0, +) }
        starts.append(total)
        for index in entries.indices {
            entries[index].characters = starts[index + 1] - starts[index]
        }
        self.entries = entries
    }

    /// The entry the reader is in when at `block`: the last one that starts at or before it.
    func currentEntry(atBlock block: Int) -> Entry? {
        entries.last { $0.block <= block } ?? entries.first
    }
}
