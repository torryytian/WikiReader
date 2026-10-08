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
}

/// Which engine reads articles aloud. Chosen by picking a voice (see `VoiceChoice`).
nonisolated enum SpeechEngineChoice: String, Sendable {
    case system
    case openAI
}
