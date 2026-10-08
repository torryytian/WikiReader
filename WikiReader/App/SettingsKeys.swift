import Foundation

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
    /// Reader typography, each the raw value of the matching `ReaderStyle` type (the size is a Double).
    static let readerFont = "readerFont"
    static let readerFontSize = "readerFontSize"
    static let readerLineSpacing = "readerLineSpacing"
    static let readerMargins = "readerMargins"
    static let readerTheme = "readerTheme"
    static let readerDarkLevel = "readerDarkLevel"
}

/// Which engine reads articles aloud. Chosen by picking a voice (see `VoiceChoice`).
nonisolated enum SpeechEngineChoice: String, Sendable {
    case system
    case openAI
}
