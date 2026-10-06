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

/// Which engine reads articles aloud.
nonisolated enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case system
    case openAI

    var label: String {
        switch self {
        case .system: "iPhone Voices"
        case .openAI: "OpenAI"
        }
    }
}
