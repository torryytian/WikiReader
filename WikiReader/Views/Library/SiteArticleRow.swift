import SwiftUI

/// The inside of an English Reader article's card in the library: title, a line of what it is (category, level,
/// length, narration) and its summary; once opened here, how much of its audio is on this iPhone.
struct SiteArticleRow: View {
    let summary: SiteArticleSummary
    /// Downloaded share of its narration, once it was opened here (nil: never opened).
    let audioFraction: Double?
    let isOpening: Bool
    let isDownloading: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let excerpt = summary.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let badge {
                    badge
                        .labelStyle(LibraryView.BadgeLabelStyle())
                        .font(.caption)
                        .foregroundStyle(isDownloading ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
            if isOpening {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// "Places · C1 · 9,631 words · 1 h 10 min".
    private var details: String {
        var parts: [String] = []
        if let category = summary.category?.name { parts.append(category) }
        if let cefr = summary.cefr { parts.append(cefr) }
        if let words = summary.wordCount, words > 0 { parts.append("\(words.formatted()) words") }
        if let audio = summary.audio, audio.readyChunks > 0, let ms = audio.readyMs {
            parts.append(Self.duration(ms))
        }
        if parts.isEmpty { parts.append(summary.isWikipedia ? "Wikipedia" : "English Reader") }
        return parts.joined(separator: " · ")
    }

    private var badge: Label<Text, Image>? {
        guard let fraction = audioFraction else { return nil }
        let percent = Int((fraction * 100).rounded(.down))
        if isDownloading { return Label("Downloading \(percent)%", systemImage: "arrow.down.circle") }
        if fraction >= 1 { return Label("Audio downloaded", systemImage: "headphones") }
        if fraction > 0 { return Label("Audio \(percent)% on this iPhone", systemImage: "headphones") }
        return Label("Opened", systemImage: "book")
    }

    /// "4 min", "1 h 41 min".
    static func duration(_ ms: Int64) -> String {
        let minutes = max(1, Int((Double(ms) / 60_000).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
