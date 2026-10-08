import SwiftUI

/// Menu bar shown at the top of the reader when the reader taps near the top edge.
struct ReaderTopBar: View {
    let title: String
    let onBack: () -> Void
    let onStyle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button("Back", systemImage: "chevron.left", action: onBack)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button("Text Settings", systemImage: "textformat.size", action: onStyle)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
    }
}

/// Typography panel: theme, font, size, line spacing and margins. Changes apply to the article behind it right away.
struct ReaderStylePanel: View {
    @Binding var fontFamily: ReaderStyle.FontFamily
    @Binding var fontSize: Double
    @Binding var lineSpacing: ReaderStyle.LineSpacing
    @Binding var margins: ReaderStyle.Margins
    @Binding var theme: ReaderStyle.Theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    HStack(spacing: 14) {
                        ForEach(ReaderStyle.Theme.allCases, id: \.self) { option in
                            themeButton(option)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Section("Text") {
                    Picker("Font", selection: $fontFamily) {
                        ForEach(ReaderStyle.FontFamily.allCases, id: \.self) { family in
                            Text(family.label).tag(family)
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .accessibilityHidden(true)
                        Slider(value: $fontSize, in: ReaderStyle.sizeRange, step: 1) {
                            Text("Size")
                        }
                        Image(systemName: "textformat.size.larger")
                            .accessibilityHidden(true)
                        Text("\(Int(fontSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                Section("Layout") {
                    Picker("Line Spacing", selection: $lineSpacing) {
                        ForEach(ReaderStyle.LineSpacing.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Margins", selection: $margins) {
                        ForEach(ReaderStyle.Margins.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .pickerStyle(.segmented)

                Section {
                    Button("Reset to Default") {
                        let standard = ReaderStyle.default
                        fontFamily = standard.fontFamily
                        fontSize = standard.fontSize
                        lineSpacing = standard.lineSpacing
                        margins = standard.margins
                        theme = standard.theme
                    }
                }
            }
            .navigationTitle("Text Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func themeButton(_ option: ReaderStyle.Theme) -> some View {
        Button {
            theme = option
        } label: {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.headline)
                    .foregroundStyle(Color(option.text))
                    .frame(width: 52, height: 52)
                    .background(Color(option.background), in: Circle())
                    .overlay(Circle().strokeBorder(theme == option ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: theme == option ? 3 : 1))
                Text(option.label)
                    .font(.caption)
                    .foregroundStyle(theme == option ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(theme == option ? .isSelected : [])
    }
}
