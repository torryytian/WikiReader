import SwiftUI
import UIKit

/// An English Reader article as a book on a shelf: a paper cover with its category and short title over its picture
/// (or its category's art), then the full title and what it is underneath. Laid out three to a row.
struct SiteBookCell: View {
    /// What the library knows about the article on this iPhone.
    struct State: Equatable {
        /// Downloaded share of its narration, once it was opened here (nil: never opened).
        var audioFraction: Double?
        var isOpening = false
        var isDownloading = false
        /// Only the beginning was sent (no access token): the share of the article it is, if the site said.
        var preview: SiteArticleDetail.Preview?
    }

    let summary: SiteArticleSummary
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SiteBookCover(summary: summary, state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "B1 · 29 min", or the words when there is no narration yet.
    private var details: String {
        var parts: [String] = []
        if let cefr = summary.cefr { parts.append(cefr) }
        if let audio = summary.audio, audio.readyChunks > 0, let ms = audio.readyMs {
            parts.append(Self.duration(ms))
        } else if let words = summary.wordCount, words > 0 {
            parts.append("\(words.formatted()) words")
        }
        if parts.isEmpty { parts.append(summary.siteCategory.name) }
        return parts.joined(separator: " · ")
    }

    /// "4 min", "1 h 41 min".
    static func duration(_ ms: Int64) -> String {
        let minutes = max(1, Int((Double(ms) / 60_000).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// The cover itself. Paper with a darker binding down the left edge, like a printed book; the picture takes its
/// lower part. The short title is the part before a colon ("Steve Jobs" of "Steve Jobs: Stanford Commencement…"):
/// the whole one is under the cover.
struct SiteBookCover: View {
    let summary: SiteArticleSummary
    var state = SiteBookCell.State()

    static let aspectRatio: CGFloat = 0.72

    private var theme: CategoryTheme { .forCategory(summary.siteCategory.name) }

    var body: some View {
        Color.clear
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .overlay {
                VStack(spacing: 0) {
                    heading
                    picture
                        .padding(.horizontal, 7)
                        .padding(.bottom, 8)
                }
            }
            .background(Self.paper)
            .overlay(alignment: .leading) { binding }
            .overlay(alignment: .topLeading) { openedRibbon }
            .overlay(alignment: .topTrailing) { recordingBadge }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 2)
            .overlay {
                if state.isOpening {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .accessibilityHidden(true)
    }

    private var heading: some View {
        VStack(spacing: 3) {
            Text(summary.siteCategory.name.uppercased())
                .font(.system(size: 7, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Self.label(theme))
                .lineLimit(1)
            Text(Self.shortTitle(of: summary.title))
                .font(.system(size: 13, weight: .bold, design: .serif))
                .foregroundStyle(Self.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity)
    }

    private var picture: some View {
        Color.clear
            .overlay {
                if let cover = summary.cover {
                    AsyncImage(url: cover.small) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            CategoryArt(theme: theme)
                        }
                    }
                } else {
                    CategoryArt(theme: theme)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .overlay(alignment: .bottom) { status }
    }

    /// Downloading, a preview only, or all the narration here.
    @ViewBuilder
    private var status: some View {
        if let label = statusLabel {
            label
                .font(.system(size: 9, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(5)
        }
    }

    private var statusLabel: Label<Text, Image>? {
        guard let fraction = state.audioFraction else { return nil }
        if state.isDownloading { return Label("\(Int((fraction * 100).rounded(.down)))%", systemImage: "arrow.down") }
        if state.preview != nil { return Label("Preview", systemImage: "lock.fill") }
        if fraction >= 1 { return Label("Audio", systemImage: "headphones") }
        return nil
    }

    /// Hangs from the top on articles opened here, like a bookmark left in.
    @ViewBuilder
    private var openedRibbon: some View {
        if state.audioFraction != nil {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(rgb: 0x34C759))
                .offset(x: 9, y: -3)
        }
    }

    /// The speaker's own voice rather than a narrator's.
    @ViewBuilder
    private var recordingBadge: some View {
        if summary.audio?.voice.map(OpenAISpeechEngine.isRecording) == true {
            Image(systemName: "mic.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color(rgb: theme.bottom), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(5)
        }
    }

    private var binding: some View {
        LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.05), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: 7)
            .overlay(alignment: .trailing) {
                Rectangle().fill(.white.opacity(0.35)).frame(width: 0.5)
            }
    }

    static func shortTitle(of title: String) -> String {
        guard let colon = title.firstIndex(of: ":") else { return title }
        let head = title[..<colon].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? title : head
    }

    /// The category's darker color on paper, its lighter one on the dark board.
    static func label(_ theme: CategoryTheme) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: theme.top) : UIColor(rgb: theme.bottom) })
    }

    /// Paper: warm white, or a dark board at night.
    static let paper = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x2C2A27) : UIColor(rgb: 0xFBF8F2) })
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xEDE8DF) : UIColor(rgb: 0x262321) })
}

/// The tabs over English Reader's shelf: For You, then each category.
struct SiteShelfTabs: View {
    let categories: [SiteCategory]
    /// Nil: For You.
    @Binding var selection: SiteCategory?

    private static let forYou = "for you"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    tab("For You", isOn: selection == nil) { selection = nil }
                        .id(Self.forYou)
                    ForEach(categories) { category in
                        tab(category.name, isOn: selection == category) { selection = category }
                            .id(category.id)
                    }
                }
                // In line with the shelf, and clear of the list's rounded corners.
                .padding(.horizontal, LibraryView.shelfInset)
                .padding(.top, 6)
            }
            .scrollClipDisabled()
            // The tab shown is always in view, also when See All chose it.
            .onAppear { proxy.scrollTo(selection?.id ?? Self.forYou, anchor: .center) }
            .onChange(of: selection) { _, new in
                withAnimation { proxy.scrollTo(new?.id ?? Self.forYou, anchor: .center) }
            }
        }
    }

    private func tab(_ title: String, isOn: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.body, weight: isOn ? .bold : .regular))
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                Capsule()
                    .fill(isOn ? Color.accentColor : .clear)
                    .frame(width: 20, height: 3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A section's heading on the shelf: large, with See All when there is more than shown.
struct SiteShelfHeading: View {
    let title: String
    var seeAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Absolute colors: a section header's own style would turn the relative ones gray.
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.primary)
            Spacer()
            if let seeAll {
                Button(action: seeAll) {
                    HStack(spacing: 2) {
                        Text("See All")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
            }
        }
        .textCase(nil)
        // In line with the books under it.
        .padding(.horizontal, LibraryView.shelfInset - 16)
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
