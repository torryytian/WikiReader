import SwiftUI

/// The full-screen table of contents that slides in from the left. The section being read is highlighted; tapping a
/// section jumps there. Drawn in the reader's own theme colors, so it looks like part of the page.
struct ContentsView: View {
    let outline: ArticleOutline
    let currentBlock: Int
    let style: ReaderStyle
    let onSelect: (ArticleOutline.Entry) -> Void
    let onClose: () -> Void

    var body: some View {
        let text = Color(style.theme.text)
        let secondary = Color(style.theme.secondaryText)
        let accent = style.theme.accent.map(Color.init) ?? .accentColor
        let current = outline.currentEntry(atBlock: currentBlock)

        VStack(spacing: 0) {
            HStack {
                Text("Contents")
                    .font(.headline)
                Text("\(outline.entries.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(outline.entries) { entry in
                        let isCurrent = entry.id == current?.id
                        Button {
                            onSelect(entry)
                        } label: {
                            HStack(spacing: 10) {
                                Text(entry.title)
                                    .font(entry.depth == 0 ? .body.weight(.semibold) : .subheadline)
                                    .foregroundStyle(isCurrent ? accent : (entry.depth == 0 ? text : secondary))
                                    .lineLimit(2)
                                    .padding(.leading, CGFloat(entry.depth) * 18)
                                Spacer(minLength: 8)
                                Text(entry.percentText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(isCurrent ? accent : secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isCurrent ? accent.opacity(0.12) : Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.1))
                        .id(entry.id)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Opens with the section being read in view.
                .onAppear {
                    if let current { proxy.scrollTo(current.id, anchor: .center) }
                }
            }
        }
        .foregroundStyle(text)
        .background(Color(style.backgroundColor).ignoresSafeArea())
    }
}
