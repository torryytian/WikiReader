import SwiftUI

/// Where to start an article that has bookmarks, asked when it is opened from the library: where reading last
/// stopped, the beginning, or one of the bookmarks.
struct StartPointView: View {
    let article: Article
    var onChoose: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var blocks: [ContentBlock] = []
    @State private var outline = ArticleOutline(blocks: [])
    /// Where each block starts, in characters, for the percentages.
    @State private var starts: [Int] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let last = article.lastReadBlockIndex
                    if last > 0, blocks.indices.contains(last) {
                        choice(
                            title: "Continue Reading", symbol: "book.fill",
                            detail: "\(percent(at: last))% · \(section(at: last))",
                            excerpt: Bookmark.excerpt(of: blocks[last].text), block: last
                        )
                    }
                    choice(title: "From the Beginning", symbol: "arrow.counterclockwise", detail: nil, excerpt: nil, block: 0)
                }

                Section("Bookmarks") {
                    ForEach(article.bookmarks.filter { blocks.indices.contains($0.block) }) { mark in
                        choice(
                            title: section(at: mark.block), symbol: "bookmark.fill",
                            detail: "\(percent(at: mark.block))%", excerpt: mark.excerpt, block: mark.block
                        )
                    }
                }
            }
            .navigationTitle(article.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                guard blocks.isEmpty else { return }
                blocks = article.blocks
                outline = ArticleOutline(blocks: blocks)
                var before = 0
                starts = blocks.map { block in
                    defer { before += block.text.count }
                    return before
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func section(at block: Int) -> String {
        outline.currentEntry(atBlock: block)?.title ?? article.title
    }

    private func percent(at block: Int) -> Int {
        guard starts.indices.contains(block), outline.totalCharacters > 0 else { return 0 }
        return Int((Double(starts[block]) / Double(outline.totalCharacters) * 100).rounded())
    }

    private func choice(title: String, symbol: String, detail: String?, excerpt: String?, block: Int) -> some View {
        Button {
            onChoose(block)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    // The rows are tinted with the text color, so name the accent color itself.
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if let detail {
                            Spacer(minLength: 4)
                            Text(detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    // A bookmarked heading's text is the section's name, already the title.
                    if let excerpt, excerpt != title {
                        Text(excerpt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
    }
}
