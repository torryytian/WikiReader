import SwiftUI

/// Where the reader is in the article, for the top bar: how far, which section and paragraph, how long is left.
/// Distances count characters, and time uses `ReadingSession.charactersPerSecond`, so the minutes are an estimate.
nonisolated struct ReadingProgress: Equatable {
    /// The last heading at or before the current block; nil before the first heading.
    var section: String?
    /// Which paragraph (headings aren't counted) is being read, from 1.
    var paragraph: Int
    var paragraphCount: Int
    /// 0 to 1, by characters.
    var fraction: Double
    var minutesLeft: Int

    init(blocks: [ContentBlock], currentBlock: Int, rate: SpeechRate) {
        let current = blocks.indices.contains(currentBlock) ? currentBlock : 0
        let lengths = blocks.map(\.text.count)
        let total = lengths.reduce(0, +)
        let before = lengths.prefix(current).reduce(0, +)

        section = blocks.prefix(current + 1).last { $0.kind == .heading }?.text
        paragraphCount = blocks.filter { $0.kind == .paragraph }.count
        paragraph = min(max(blocks.prefix(current + 1).filter { $0.kind == .paragraph }.count, 1), max(paragraphCount, 1))
        fraction = total > 0 ? Double(before) / Double(total) : 0

        let seconds = Double(total - before) / (ReadingSession.charactersPerSecond * rate.rawValue)
        minutesLeft = Int((seconds / 60).rounded(.up))
    }

    var percentText: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    var detailText: String {
        var parts: [String] = []
        if let section { parts.append(section) }
        parts.append("paragraph \(paragraph) of \(paragraphCount)")
        parts.append(minutesLeft <= 1 ? "under a minute left" : "about \(minutesLeft) min left")
        return parts.joined(separator: " · ")
    }
}

/// The colors a reader menu draws with, taken from the reader's theme.
private struct MenuColors {
    let text: Color
    let secondary: Color
    let bar: Color
    let accent: Color
    let onAccent: Color
    let chip = Color.primary.opacity(0.07)

    init(_ style: ReaderStyle) {
        text = Color(style.theme.text)
        secondary = Color(style.theme.secondaryText)
        bar = Color(style.theme.barBackground)
        accent = style.theme.accent.map(Color.init) ?? .accentColor
        onAccent = Color(style.theme.onAccent)
    }
}

/// Shown at the top of the reader when the reader taps near the top edge. Information only: the title and
/// how far along the article is.
struct ReaderTopInfoBar: View {
    let title: String
    let progress: ReadingProgress
    let style: ReaderStyle

    var body: some View {
        let colors = MenuColors(style)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(progress.percentText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(colors.secondary)
            }
            Text(progress.detailText)
                .font(.caption)
                .foregroundStyle(colors.secondary)
                .lineLimit(1)

            GeometryReader { proxy in
                Capsule().fill(colors.chip)
                    .overlay(alignment: .leading) {
                        Capsule().fill(colors.accent)
                            .frame(width: proxy.size.width * progress.fraction)
                    }
            }
            .frame(height: 3)
            .padding(.top, 6)
        }
        .foregroundStyle(colors.text)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .readerBar(edge: .top, color: colors.bar)
        // Taps on the bar itself must not reach the text underneath and toggle the menu.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .combine)
    }
}

private enum MenuTab: String, CaseIterable {
    case playback, font, theme, layout

    var title: String {
        switch self {
        case .playback: "Playback"
        case .font: "Font & Size"
        case .theme: "Theme"
        case .layout: "Layout"
        }
    }

    var symbol: String {
        switch self {
        case .playback: "play.circle"
        case .font: "textformat.size"
        case .theme: "circle.lefthalf.filled"
        case .layout: "rectangle.split.3x1"
        }
    }
}

/// Shown at the bottom of the reader when the reader taps near the bottom edge:
/// four equal tabs: playback, font and size, theme, layout. One is always open, the one used last; the playback
/// controls show only on the playback tab. Changes apply to the article behind it right away.
struct ReaderBottomMenu: View {
    let session: ReadingSession
    let style: ReaderStyle
    @Binding var fontFamily: ReaderStyle.FontFamily
    @Binding var fontSize: Double
    @Binding var lineSpacing: ReaderStyle.LineSpacing
    @Binding var margins: ReaderStyle.Margins
    @Binding var theme: ReaderStyle.Theme
    @Binding var playbackMode: PlaybackMode

    /// The tab in view. Remembered, so the menu opens on the one used last.
    @AppStorage(SettingsKeys.readerMenuTab) private var tab = MenuTab.playback

    var body: some View {
        let colors = MenuColors(style)
        VStack(spacing: 0) {
            panel(for: tab, colors: colors)
                .padding(.horizontal, tab == .playback ? 6 : 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            HStack {
                ForEach(MenuTab.allCases, id: \.self) { item in
                    tabButton(item, colors: colors)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .foregroundStyle(colors.text)
        .tint(colors.accent)
        .readerBar(edge: .bottom, color: colors.bar)
        // Taps on the menu itself must not reach the text underneath and toggle the menu.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func tabButton(_ item: MenuTab, colors: MenuColors) -> some View {
        let isSelected = tab == item
        return Button {
            tab = item
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18))
                    .frame(width: 52, height: 28)
                    .background(isSelected ? colors.accent.opacity(0.16) : .clear, in: Capsule())
                Text(item.title)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? colors.accent : colors.secondary)
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func panel(for tab: MenuTab, colors: MenuColors) -> some View {
        switch tab {
        case .playback: playbackPanel(colors)
        case .font: fontPanel(colors)
        case .theme: themePanel(colors)
        case .layout: layoutPanel(colors)
        }
    }

    // MARK: - Playback

    private func playbackPanel(_ colors: MenuColors) -> some View {
        PlayerBar(session: session, playbackMode: $playbackMode, accent: colors.accent, onAccent: colors.onAccent)
            .padding(.bottom, 2)
    }

    // MARK: - Font and size

    private func fontPanel(_ colors: MenuColors) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(ReaderStyle.FontFamily.allCases, id: \.self) { family in
                    fontButton(family, colors: colors)
                }
            }
            HStack(spacing: 12) {
                Text("A").font(.system(size: 13, weight: .medium)).foregroundStyle(colors.secondary)
                Slider(value: $fontSize, in: ReaderStyle.sizeRange, step: 1) {
                    Text("Size")
                }
                Text("A").font(.system(size: 23, weight: .medium)).foregroundStyle(colors.secondary)
                Text("\(Int(fontSize))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(colors.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
        }
    }

    /// A card showing "Aa" in the font itself, so the choice is visible instead of named.
    private func fontButton(_ family: ReaderStyle.FontFamily, colors: MenuColors) -> some View {
        let isSelected = fontFamily == family
        return Button {
            fontFamily = family
        } label: {
            VStack(spacing: 1) {
                Text("Aa")
                    .font(Font(family.font(size: 20, weight: .regular) as CTFont))
                Text(family.label)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(colors.secondary)
            }
            .foregroundStyle(isSelected ? colors.accent : colors.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 11).fill(colors.chip))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isSelected ? colors.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(family.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Theme

    private func themePanel(_ colors: MenuColors) -> some View {
        HStack {
            ForEach(ReaderStyle.Theme.allCases, id: \.self) { option in
                themeButton(option, colors: colors)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    private func themeButton(_ option: ReaderStyle.Theme, colors: MenuColors) -> some View {
        let isSelected = theme == option
        let page = Color(option == .dark ? ReaderStyle.darkBackground(level: ReaderStyle.defaultDarkLevel) : option.background)
        return Button {
            theme = option
        } label: {
            VStack(spacing: 5) {
                swatchLabel(for: option)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background {
                        if option == .system {
                            // Follows the iPhone: half light, half dark.
                            Circle().fill(LinearGradient(
                                stops: [.init(color: .white, location: 0.5), .init(color: Color(white: 0.17), location: 0.5)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                        } else {
                            Circle().fill(page)
                        }
                    }
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .padding(3)
                    .overlay(Circle().strokeBorder(isSelected ? colors.accent : .clear, lineWidth: 2.5))
                Text(option.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? colors.accent : colors.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "Aa" in the theme's text color; for Auto, a dark "A" on the light half and a light "a" on the dark half.
    @ViewBuilder
    private func swatchLabel(for option: ReaderStyle.Theme) -> some View {
        if option == .system {
            HStack(spacing: 0) {
                Text("A").foregroundStyle(.black)
                Text("a").foregroundStyle(.white)
            }
        } else {
            Text("Aa").foregroundStyle(Color(option.text))
        }
    }

    // MARK: - Layout

    private func layoutPanel(_ colors: MenuColors) -> some View {
        VStack(spacing: 12) {
            segmentedRow("Spacing", colors: colors) {
                Picker("Line Spacing", selection: $lineSpacing) {
                    ForEach(ReaderStyle.LineSpacing.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            segmentedRow("Margins", colors: colors) {
                Picker("Margins", selection: $margins) {
                    ForEach(ReaderStyle.Margins.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func segmentedRow<Content: View>(_ title: String, colors: MenuColors, @ViewBuilder picker: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(colors.secondary)
            Spacer(minLength: 12)
            picker()
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
        }
    }
}
