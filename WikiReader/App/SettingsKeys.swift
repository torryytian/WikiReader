import SwiftUI

/// `UserDefaults` keys for user settings (read with `@AppStorage`). Small, non-sensitive values only;
/// secrets such as API keys belong in the Keychain.
nonisolated enum SettingsKeys {
    /// Identifier of the chosen voice; absent means "pick the best installed voice".
    static let voiceIdentifier = "voiceIdentifier"
    /// `SpeechRate.rawValue` of the reading speed, shared by the player bar and Settings.
    static let speechRate = "speechRate"
    /// `SpeechEngineChoice.rawValue`.
    static let speechEngine = "speechEngine"
    /// Name of the chosen OpenAI voice, e.g. "marin".
    static let openAIVoice = "openAIVoice"
    /// `AppAppearance.rawValue`: light, dark, or follow the system.
    static let appAppearance = "appAppearance"
    /// Reader typography, each the raw value of the matching `ReaderStyle` type (the size is a Double).
    static let readerFont = "readerFont"
    static let readerFontSize = "readerFontSize"
    static let readerLineSpacing = "readerLineSpacing"
    static let readerMargins = "readerMargins"
    static let readerTheme = "readerTheme"
    static let readerDarkLevel = "readerDarkLevel"
}

/// Whether the whole app is light, dark, or follows the iPhone's setting. The reader's own theme
/// (Auto, Light, Sepia, Dark) sits on top of this: its Auto follows this choice.
nonisolated enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Sets the style on every window, so sheets, alerts and UIKit screens (the dictionary) follow too.
    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}

/// Which engine reads articles aloud. Chosen by picking a voice (see `VoiceChoice`).
nonisolated enum SpeechEngineChoice: String, Sendable {
    case system
    case openAI
}
