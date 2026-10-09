import SwiftUI
import UIKit

/// How the article looks: font, size, spacing, margins and colors. Chosen in the reader's typography panel.
nonisolated struct ReaderStyle: Equatable, Sendable {
    enum FontFamily: String, CaseIterable, Sendable {
        case system, serif, rounded, georgia, palatino

        var label: String {
            switch self {
            case .system: "System"
            case .serif: "Serif"
            case .rounded: "Rounded"
            case .georgia: "Georgia"
            case .palatino: "Palatino"
            }
        }

        func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            let system = UIFont.systemFont(ofSize: size, weight: weight)
            switch self {
            case .system:
                return system
            case .serif:
                return system.withDesign(.serif)
            case .rounded:
                return system.withDesign(.rounded)
            case .georgia:
                return Self.named("Georgia", bold: weight >= .semibold, size: size) ?? system
            case .palatino:
                return Self.named("Palatino", bold: weight >= .semibold, size: size) ?? system
            }
        }

        private static func named(_ family: String, bold: Bool, size: CGFloat) -> UIFont? {
            UIFont(name: bold ? "\(family)-Bold" : family, size: size)
        }
    }

    enum Theme: String, CaseIterable, Sendable {
        case system, light, sepia, dark

        var label: String {
            switch self {
            case .system: "Auto"
            case .light: "White"
            case .sepia: "Sepia"
            case .dark: "Dark"
            }
        }

        /// The color scheme the reader's own controls should use; nil follows the device.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light, .sepia: .light
            case .dark: .dark
            }
        }

        var background: UIColor {
            switch self {
            case .system: .systemBackground
            case .light: .white
            case .sepia: UIColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1)
            case .dark: ReaderStyle.darkBackground(level: ReaderStyle.defaultDarkLevel)
            }
        }

        var text: UIColor {
            switch self {
            case .system: .label
            case .light: .black
            case .sepia: UIColor(red: 0.23, green: 0.19, blue: 0.14, alpha: 1)
            case .dark: UIColor(white: 0.82, alpha: 1)
            }
        }

        /// The menus' background: a step away from the page, so the bars read as bars.
        var barBackground: UIColor {
            switch self {
            case .system: .secondarySystemBackground
            case .light: UIColor(red: 0.965, green: 0.965, blue: 0.953, alpha: 1)
            case .sepia: UIColor(red: 0.933, green: 0.894, blue: 0.808, alpha: 1)
            case .dark: UIColor(white: 0.20, alpha: 1)
            }
        }

        /// The menus' highlight color. Each theme has its own, chosen to sit well on its page; nil is the app's tint.
        var accent: UIColor? {
            switch self {
            case .system: nil
            case .light: UIColor(red: 0.184, green: 0.420, blue: 0.859, alpha: 1)
            case .sepia: UIColor(red: 0.706, green: 0.325, blue: 0.165, alpha: 1)
            case .dark: UIColor(red: 0.878, green: 0.643, blue: 0.345, alpha: 1)
            }
        }

        /// Icon color on a button filled with `accent`.
        var onAccent: UIColor {
            switch self {
            case .system, .light: .white
            case .sepia: UIColor(red: 1, green: 0.973, blue: 0.933, alpha: 1)
            case .dark: UIColor(red: 0.165, green: 0.125, blue: 0.075, alpha: 1)
            }
        }

        var secondaryText: UIColor {
            switch self {
            case .system: .secondaryLabel
            case .light: UIColor(white: 0, alpha: 0.55)
            case .sepia: UIColor(red: 0.23, green: 0.19, blue: 0.14, alpha: 0.6)
            case .dark: UIColor(white: 1, alpha: 0.55)
            }
        }
    }

    enum LineSpacing: String, CaseIterable, Sendable {
        case compact, standard, relaxed

        var label: String { rawValue.capitalized }

        /// Extra space between lines, as a fraction of the font size.
        var factor: CGFloat {
            switch self {
            case .compact: 0.12
            case .standard: 0.27
            case .relaxed: 0.45
            }
        }
    }

    enum Margins: String, CaseIterable, Sendable {
        case narrow, standard, wide

        var label: String { rawValue.capitalized }

        var inset: CGFloat {
            switch self {
            case .narrow: 10
            case .standard: 18
            case .wide: 34
            }
        }
    }

    static let sizeRange: ClosedRange<Double> = 14...32
    static let defaultSize = 19.0
    /// How deep the dark theme's background is: 0 is a soft charcoal, 1 is nearly black.
    static let defaultDarkLevel = 0.25

    var fontFamily = FontFamily.system
    var fontSize = defaultSize
    var lineSpacing = LineSpacing.standard
    var margins = Margins.standard
    var theme = Theme.system
    /// Only used by the dark theme.
    var darkLevel = defaultDarkLevel

    static let `default` = ReaderStyle()

    /// The dark theme's background for a level from 0 (soft charcoal) to 1 (nearly black).
    static func darkBackground(level: Double) -> UIColor {
        let level = min(max(level, 0), 1)
        return UIColor(white: 0.21 - 0.18 * level, alpha: 1)
    }

    /// This style with the dark level reset, so two styles compare equal when the text would look the same:
    /// the dark level only changes the page color, not the text, and shouldn't rebuild the article.
    var textLayout: ReaderStyle {
        var copy = self
        copy.darkLevel = Self.defaultDarkLevel
        return copy
    }

    /// Page color, which for the dark theme follows `darkLevel`.
    var backgroundColor: UIColor {
        theme == .dark ? Self.darkBackground(level: darkLevel) : theme.background
    }

    /// The font size, kept inside the range the panel offers (a stale or hand-edited setting can't break layout).
    var clampedFontSize: CGFloat {
        CGFloat(min(max(fontSize, Self.sizeRange.lowerBound), Self.sizeRange.upperBound))
    }
}

private extension UIFont {
    nonisolated func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(design) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
