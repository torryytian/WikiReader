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
            case .light: "Light"
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
            case .dark: UIColor(white: 0.09, alpha: 1)
            }
        }

        var text: UIColor {
            switch self {
            case .system: .label
            case .light: .black
            case .sepia: UIColor(red: 0.23, green: 0.19, blue: 0.14, alpha: 1)
            case .dark: UIColor(white: 0.88, alpha: 1)
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

    var fontFamily = FontFamily.system
    var fontSize = defaultSize
    var lineSpacing = LineSpacing.standard
    var margins = Margins.standard
    var theme = Theme.system

    static let `default` = ReaderStyle()

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
