import SwiftUI

/// A library row drawn as its own card, which slides left to reveal an Info block of the same height and shape.
///
/// The system's swipe actions can't be made to match the card (their size and the title under the icon are fixed),
/// so the row does its own: a horizontal drag narrows the card, letting go past half the block keeps it open, and a tap
/// on an open card closes it. Vertical drags are left to the list, so scrolling is unaffected.
struct SwipeRevealRow<Content: View>: View {
    var isOpen: Bool
    /// Off while selecting rows: the list's own taps choose them then.
    var isEnabled: Bool
    var onOpenChange: (Bool) -> Void
    var onInfo: () -> Void
    /// Tapping the closed card; nil leaves taps to the list.
    var onTap: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var dragX: CGFloat = 0
    /// Whether the current drag was judged horizontal; nil until it has moved far enough to tell.
    @State private var isHorizontalDrag: Bool?

    static var cornerRadius: CGFloat { 24 }
    private static var blockWidth: CGFloat { 72 }
    private static var gap: CGFloat { 8 }
    private static var openOffset: CGFloat { -(blockWidth + gap) }
    /// Dark: a gray a step lighter than the card. Light: the system gray. Quiet, like Mail's More.
    private static var infoTint: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? .systemGray3 : .systemGray })
    }

    private var offset: CGFloat {
        let resting = isOpen ? Self.openOffset : 0
        // Past the block it follows the finger at a third of the speed, so it feels held.
        let raw = min(resting + dragX, 0)
        return raw < Self.openOffset ? Self.openOffset + (raw - Self.openOffset) / 3 : raw
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.blockWidth)
                    .frame(maxHeight: .infinity)
                    .background(Self.infoTint, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(offset < -1 ? 1 : 0)
            .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .onTapGesture {
                    if isOpen {
                        onOpenChange(false)
                    } else {
                        onTap?()
                    }
                }
                .allowsHitTesting(onTap != nil || isOpen)
                // The card narrows from the right rather than sliding off to the left, so it keeps its rounded
                // corners and its left edge lines up with the rest of the screen.
                .padding(.trailing, -offset)
                .simultaneousGesture(drag, including: isEnabled ? .all : .subviews)
        }
        .animation(.snappy(duration: 0.25), value: isOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Info", onInfo)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled && isOpen { onOpenChange(false) }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isHorizontalDrag == nil {
                    isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                }
                guard isHorizontalDrag == true else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                defer { isHorizontalDrag = nil }
                guard isHorizontalDrag == true else { return }
                let resting = isOpen ? Self.openOffset : 0
                // A quick flick counts as much as a long drag.
                let projected = resting + value.predictedEndTranslation.width
                let shouldOpen = projected < Self.openOffset / 2
                withAnimation(.snappy(duration: 0.25)) {
                    dragX = 0
                }
                if shouldOpen != isOpen { onOpenChange(shouldOpen) }
            }
    }
}
