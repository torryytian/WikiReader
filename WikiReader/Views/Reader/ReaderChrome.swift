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

/// Menu at the top of the reader, shown when the reader taps near the top edge: back, the title, text settings.
/// A full-width bar in the page color, so it reads as part of the page rather than as pieces over the text.
struct ReaderTopBar: View {
    let title: String
    let onBack: () -> Void
    let onStyle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button(action: onStyle) {
                // Two sizes of "A", the usual sign for text settings.
                (Text("A").font(.system(size: 14, weight: .semibold)) + Text("A").font(.system(size: 21, weight: .semibold)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Text Settings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .readerBar(edge: .top)
        // Taps on the menu's own parts must not reach the text underneath and toggle the menu.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Typography panel: theme, font, size, line spacing and margins. Changes apply to the article behind it right away.
struct ReaderStylePanel: View {
    @Binding var fontFamily: ReaderStyle.FontFamily
    @Binding var fontSize: Double
    @Binding var lineSpacing: ReaderStyle.LineSpacing
    @Binding var margins: ReaderStyle.Margins
    @Binding var theme: ReaderStyle.Theme
    @Binding var darkLevel: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    card("Theme") { themeCard }
                    card("Font") { fontCard }
                    card("Layout") { layoutCard }

                    Button("Reset to Default", action: reset)
                        .font(.subheadline)
                        .padding(.top, 2)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Text Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Theme

    private var themeCard: some View {
        VStack(spacing: 16) {
            HStack {
                ForEach(ReaderStyle.Theme.allCases, id: \.self) { option in
                    themeButton(option)
                        .frame(maxWidth: .infinity)
                }
            }

            // The dark theme's background can be moved between a soft charcoal and almost black.
            if theme == .dark {
                HStack(spacing: 12) {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: $darkLevel, in: 0...1) {
                        Text("Darkness")
                    } minimumValueLabel: {
                        Text("Soft").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Deep").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: theme)
    }

    private func themeButton(_ option: ReaderStyle.Theme) -> some View {
        let background = option == .dark ? ReaderStyle.darkBackground(level: darkLevel) : option.background
        let isSelected = theme == option
        return Button {
            theme = option
        } label: {
            VStack(spacing: 7) {
                Text("Aa")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(option.text))
                    .frame(width: 54, height: 54)
                    .background(Color(background), in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .padding(3)
                    .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(option.label)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Font

    private var fontCard: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ReaderStyle.FontFamily.allCases, id: \.self) { family in
                    fontButton(family)
                }
            }

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
    }

    /// A card showing "Aa" in the font itself, so the choice is visible instead of named.
    private func fontButton(_ family: ReaderStyle.FontFamily) -> some View {
        let isSelected = fontFamily == family
        return Button {
            fontFamily = family
        } label: {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(Font(family.font(size: 26, weight: .regular) as CTFont))
                Text(family.label)
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(family.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Layout

    private var layoutCard: some View {
        VStack(spacing: 14) {
            segmentedRow("Line Spacing") {
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
    }

    private func segmentedRow<Content: View>(_ title: String, @ViewBuilder picker: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 12)
            picker()
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
        }
    }
}

/// Hiding the navigation bar also turns off the swipe-from-the-left-edge gesture that goes back. This turns
/// it on again, so the reader can always be left without finding the top menu.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Its default delegate refuses the gesture while the navigation bar is hidden.
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}
