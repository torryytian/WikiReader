import Foundation

/// The one voice that reads articles: an iPhone voice or an OpenAI voice. Picking a voice also picks
/// the engine, so Settings shows a single selection instead of one per engine.
nonisolated enum VoiceChoice: Equatable, Sendable {
    /// An installed iPhone voice; `nil` is Automatic (the best installed English voice).
    case iPhone(identifier: String?)
    case openAI(voice: String)

    /// The engine that reads with this voice.
    var engine: SpeechEngineChoice {
        switch self {
        case .iPhone: .system
        case .openAI: .openAI
        }
    }

    /// What the stored settings amount to right now.
    /// - Parameter installedVoices: The iPhone voices Settings lists.
    static func current(
        engine: SpeechEngineChoice, voiceIdentifier: String?, openAIVoice: String,
        hasOpenAIKey: Bool, installedVoices: [VoiceInfo]
    ) -> VoiceChoice {
        // OpenAI can't read without a key, so the iPhone voice is what is actually in use.
        if engine == .openAI && hasOpenAIKey { return .openAI(voice: openAIVoice) }
        // A chosen voice that was deleted in iPhone Settings reads as Automatic.
        let installed = installedVoices.first { $0.identifier == voiceIdentifier }
        return .iPhone(identifier: installed?.identifier)
    }

    /// Short description for the settings list, e.g. "Marin · OpenAI".
    func summary(installedVoices: [VoiceInfo]) -> String {
        switch self {
        case .openAI(let voice):
            return "\(voice.capitalized) · OpenAI"
        case .iPhone(let identifier):
            let name = installedVoices.first { $0.identifier == identifier }?.name
            return "\(name ?? "Automatic") · iPhone"
        }
    }
}
