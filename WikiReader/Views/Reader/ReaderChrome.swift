import SwiftUI

extension EnvironmentValues {
    /// The page color, which floating controls take on so the text behind them fades instead of showing through.
    @Entry var floatingTint: Color = .clear
}

private struct ReaderBarBackground: ViewModifier {
    @Environment(\.floatingTint) private var tint
    let edge: VerticalEdge

    func body(content: Content) -> some View {
        content
            .background {
                // Opaque page color running into the safe area, so no text shows through or behind the bar.
                tint.ignoresSafeArea(edges: edge == .top ? .top : .bottom)
            }
            .overlay(alignment: edge == .top ? .bottom : .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
            }
    }
}

extension View {
    /// Background for the reader's top and bottom menus: the page color with a hairline on the edge facing the text.
    func readerBar(edge: VerticalEdge) -> some View {
        modifier(ReaderBarBackground(edge: edge))
    }
}

/// Menu at the top of the reader, shown when the reader taps near the top edge. It holds the text settings
/// directly (size, theme, font, spacing, margins); going back is the swipe from the left edge.
/// Changes apply to the article behind it right away.
struct ReaderTopMenu: View {
    @Binding var fontFamily: ReaderStyle.FontFamily
    @Binding var fontSize: Double
    @Binding var lineSpacing: ReaderStyle.LineSpacing
    @Binding var margins: ReaderStyle.Margins
    @Binding var theme: ReaderStyle.Theme
    @Binding var darkLevel: Double

    var body: some View {
        VStack(spacing: 16) {
            sizeRow
            themeRow
            fontRow
            VStack(spacing: 10) {
                segmentedRow("Spacing") {
                    Picker("Line Spacing", selection: $lineSpacing) {
                        ForEach(ReaderStyle.LineSpacing.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                segmentedRow("Margins") {
                    Picker("Margins", selection: $margins) {
                        ForEach(ReaderStyle.Margins.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            Button("Reset to Default", action: reset)
                .font(.footnote)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .readerBar(edge: .top)
        .animation(.easeInOut(duration: 0.2), value: theme)
        // Taps on the menu's own parts must not reach the text underneath and toggle the menu.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func reset() {
        let standard = ReaderStyle.default
        fontFamily = standard.fontFamily
        fontSize = standard.fontSize
        lineSpacing = standard.lineSpacing
        margins = standard.margins
        theme = standard.theme
        darkLevel = standard.darkLevel
    }

    // MARK: - Size

    private var sizeRow: some View {
        HStack(spacing: 12) {
            Text("A").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            Slider(value: $fontSize, in: ReaderStyle.sizeRange, step: 1) {
                Text("Size")
            }
            Text("A").font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
            Text("\(Int(fontSize))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    // MARK: - Theme

    private var themeRow: some View {
        VStack(spacing: 12) {
            HStack {
                ForEach(ReaderStyle.Theme.allCases, id: \.self) { option in
                    themeButton(option)
                        .frame(maxWidth: .infinity)
                }
            }

            // The dark theme's background can be moved between a soft charcoal and almost black.
            if theme == .dark {
                Slider(value: $darkLevel, in: 0...1) {
                    Text("Darkness")
                } minimumValueLabel: {
                    Text("Soft").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Deep").font(.caption).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
    }

    private func themeButton(_ option: ReaderStyle.Theme) -> some View {
        let background = option == .dark ? ReaderStyle.darkBackground(level: darkLevel) : option.background
        let isSelected = theme == option
        return Button {
            theme = option
        } label: {
            VStack(spacing: 5) {
                Text("Aa")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(option.text))
                    .frame(width: 44, height: 44)
                    .background(Color(background), in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .padding(3)
                    .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(option.label)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Font

    private var fontRow: some View {
        HStack(spacing: 8) {
            ForEach(ReaderStyle.FontFamily.allCases, id: \.self) { family in
                fontButton(family)
            }
        }
    }

    /// A card showing "Aa" in the font itself, so the choice is visible instead of named.
    private func fontButton(_ family: ReaderStyle.FontFamily) -> some View {
        let isSelected = fontFamily == family
        return Button {
            fontFamily = family
        } label: {
            VStack(spacing: 2) {
                Text("Aa")
                    .font(Font(family.font(size: 22, weight: .regular) as CTFont))
                Text(family.label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .accessibilityLabel(family.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func segmentedRow<Content: View>(_ title: String, @ViewBuilder picker: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 12)
            picker()
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
        }
    }
}

/// Hiding the navigation bar also turns off the swipe-from-the-left-edge gesture that goes back. This turns
/// it on again, so the reader can always be left without finding the top menu.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    /// Off while a full-screen panel is open, so a swipe from the edge closes the panel instead of leaving the article.
    var isEnabled = true

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isSwipeBackEnabled = isEnabled
        controller.applyIfVisible()
    }

    final class Controller: UIViewController {
        var isSwipeBackEnabled = true

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func applyIfVisible() {
            if viewIfLoaded?.window != nil { apply() }
        }

        private func apply() {
            // Its default delegate refuses the gesture while the navigation bar is hidden.
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
            navigationController?.interactivePopGestureRecognizer?.isEnabled = isSwipeBackEnabled
        }
    }
}
