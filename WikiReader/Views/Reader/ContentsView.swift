import SwiftUI

/// The table of contents that slides in from the left and fills the screen, drawn as a timeline: a rail runs
/// down the left with a node for each section. Main sections get a numbered node and room around them, subsections
/// a small dot and an indent. What has been read is colored in, the section being read is the filled node, and
/// each row shows how long the section takes to read. Tapping a section jumps there.
///
/// A switch at the top shows the article's bookmarks instead: each with its section, where it is in the article and
/// the start of its text. Tapping one jumps there.
struct ContentsView: View {
    /// A bookmark as listed: with the section it is in and how far into the article it is.
    struct BookmarkItem: Identifiable {
        var bookmark: Bookmark
        var section: String
        var percent: Int
        var id: Bookmark.ID { bookmark.id }
    }

    enum Tab: String, CaseIterable {
        case contents = "Contents"
        case bookmarks = "Bookmarks"
    }

    let articleTitle: String
    let outline: ArticleOutline
    let currentBlock: Int
    let style: ReaderStyle
    let bookmarks: [BookmarkItem]
    let onSelect: (ArticleOutline.Entry) -> Void
    let onSelectBookmark: (Bookmark) -> Void
    let onDeleteBookmark: (Bookmark) -> Void
    let onClose: () -> Void

    @State private var tab = Tab.contents

    private struct Palette {
        let text: Color
        let secondary: Color
        let accent: Color
        let onAccent: Color
        let rail: Color
        let page: Color
    }

    var body: some View {
        let palette = Palette(
            text: Color(style.theme.text),
            secondary: Color(style.theme.secondaryText),
            accent: style.theme.accent.map(Color.init) ?? .accentColor,
            onAccent: Color(style.theme.onAccent),
            rail: Color.primary.opacity(0.16),
            page: Color(style.backgroundColor)
        )
        let entries = outline.entries
        let currentIndex = entries.firstIndex { $0.id == outline.currentEntry(atBlock: currentBlock)?.id } ?? 0
        // Numbers for the main sections, counting from the first one after the introduction.
        let numbers = Self.mainSectionNumbers(entries)

        VStack(spacing: 0) {
            header(palette)

            if tab == .bookmarks {
                bookmarkList(palette)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                Button {
                                    onSelect(entry)
                                } label: {
                                    row(entry, index: index, number: numbers[index], currentIndex: currentIndex,
                                        isFirst: index == 0, isLast: index == entries.count - 1, palette: palette)
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(index == currentIndex ? .isSelected : [])
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                    }
                    // Opens with the section being read in view.
                    .onAppear {
                        if entries.indices.contains(currentIndex) { proxy.scrollTo(entries[currentIndex].id, anchor: .center) }
                    }
                }
            }
        }
        .foregroundStyle(palette.text)
        .background(Color(style.backgroundColor).ignoresSafeArea())
    }

    /// Main-section numbers by position (nil for the introduction and for subsections).
    static func mainSectionNumbers(_ entries: [ArticleOutline.Entry]) -> [Int?] {
        var count = 0
        return entries.map { entry in
            guard entry.depth == 0, !entry.isIntroduction else { return nil }
            count += 1
            return count
        }
    }

    // MARK: - Header

    private func header(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(articleTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text("\(outline.entries.count) sections · about \(outline.totalMinutes) min")
                        .font(.footnote)
                        .foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            tabSwitch(palette)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }
    }

    /// Two chips in the theme's colors, rather than a system segmented control that ignores the reader's theme.
    private func tabSwitch(_ palette: Palette) -> some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { option in
                let isOn = tab == option
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = option }
                } label: {
                    HStack(spacing: 5) {
                        Text(option.rawValue)
                        if option == .bookmarks, !bookmarks.isEmpty {
                            Text("\(bookmarks.count)")
                                .monospacedDigit()
                                .foregroundStyle(isOn ? palette.onAccent.opacity(0.8) : palette.secondary)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOn ? palette.onAccent : palette.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(isOn ? palette.accent : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    // MARK: - Bookmarks

    @ViewBuilder
    private func bookmarkList(_ palette: Palette) -> some View {
        if bookmarks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bookmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(palette.secondary)
                Text("No Bookmarks")
                    .font(.headline)
                Text("Tap the bookmark at the top right of the reader, or select some text and choose Bookmark.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(bookmarks) { item in
                        bookmarkRow(item, palette: palette)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func bookmarkRow(_ item: BookmarkItem, palette: Palette) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                onSelectBookmark(item.bookmark)
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(item.section)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(item.percent)%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(palette.secondary)
                        }
                        // A bookmarked heading's text is the section's name, already shown above.
                        if item.bookmark.excerpt != item.section {
                            Text(item.bookmark.excerpt)
                                .font(.subheadline)
                                .foregroundStyle(palette.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation { onDeleteBookmark(item.bookmark) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Bookmark")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 50)
        }
    }

    // MARK: - Rows

    private func row(
        _ entry: ArticleOutline.Entry, index: Int, number: Int?, currentIndex: Int,
        isFirst: Bool, isLast: Bool, palette: Palette
    ) -> some View {
        let isMain = entry.depth == 0
        let isCurrent = index == currentIndex
        let isRead = index < currentIndex
        // Where the node sits from the top of the row, level with the first line of the title.
        let nodeY: CGFloat = isMain ? 28 : 19
        let railX: CGFloat = 38

        return HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: 2 * railX - 12 + CGFloat(entry.depth) * 0)  // room for the rail and its nodes
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(isMain ? .system(size: 17, weight: .semibold) : .system(size: 15))
                    .foregroundStyle(isCurrent ? palette.accent : (isMain ? palette.text : palette.secondary))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if isCurrent {
                    Text("Reading now")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.leading, CGFloat(min(entry.depth, 1)) * 14 + CGFloat(max(entry.depth - 1, 0)) * 14)
            Spacer(minLength: 12)
            Text("\(entry.minutes) min")
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.secondary)
                .padding(.top, isMain ? 3 : 2)
                .padding(.trailing, 20)
        }
        .padding(.top, isMain ? 18 : 6)
        .padding(.bottom, isMain ? 4 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? palette.accent.opacity(0.10) : Color.clear)
        .overlay(alignment: .topLeading) {
            rail(
                number: number, isIntroduction: entry.isIntroduction, isMain: isMain, isCurrent: isCurrent, isRead: isRead,
                nodeY: nodeY, railX: railX, isFirst: isFirst, isLast: isLast, palette: palette
            )
        }
        .contentShape(Rectangle())
    }

    /// The rail through the row and the section's node. The rail is colored down to the section being read.
    private func rail(
        number: Int?, isIntroduction: Bool, isMain: Bool, isCurrent: Bool, isRead: Bool,
        nodeY: CGFloat, railX: CGFloat, isFirst: Bool, isLast: Bool, palette: Palette
    ) -> some View {
        let size: CGFloat = isMain ? 26 : 9
        let above = isRead || isCurrent ? palette.accent.opacity(0.55) : palette.rail
        let below = isRead ? palette.accent.opacity(0.55) : palette.rail

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Rectangle().fill(above).frame(width: 2, height: isFirst ? 0 : nodeY)
                Rectangle().fill(below).frame(width: 2).frame(maxHeight: isLast ? 0 : .infinity)
            }
            .frame(width: 2)
            .offset(x: railX - 1, y: isFirst ? nodeY : 0)

            node(number: number, isIntroduction: isIntroduction, isMain: isMain, isCurrent: isCurrent, isRead: isRead, size: size, palette: palette)
                .offset(x: railX - size / 2, y: nodeY - size / 2)
        }
    }

    @ViewBuilder
    private func node(
        number: Int?, isIntroduction: Bool, isMain: Bool, isCurrent: Bool, isRead: Bool, size: CGFloat, palette: Palette
    ) -> some View {
        let filled = isCurrent || isRead
        ZStack {
            // Solid page color underneath, so the rail doesn't show through the tinted node.
            Circle().fill(palette.page)
            Circle()
                .fill(isCurrent ? palette.accent : (isRead ? palette.accent.opacity(0.22) : Color.primary.opacity(0.07)))
            if !isMain {
                if !filled { Circle().strokeBorder(palette.rail, lineWidth: 1.5) }
            } else if isIntroduction {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isCurrent ? palette.onAccent : (isRead ? palette.accent : palette.secondary))
            } else if let number {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(isCurrent ? palette.onAccent : (isRead ? palette.accent : palette.secondary))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            // A halo around the node of the section being read.
            if isCurrent { Circle().strokeBorder(palette.accent.opacity(0.3), lineWidth: 4).padding(-4) }
        }
    }
}
