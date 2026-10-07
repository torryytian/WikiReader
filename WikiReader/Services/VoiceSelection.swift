import AVFoundation

/// The facts about a voice that matter for choosing one. A plain value (rather than
/// `AVSpeechSynthesisVoice`) so the ranking can be unit tested with made-up voices.
nonisolated struct VoiceInfo: Equatable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 0, enhanced, premium

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .standard: "Default"
            case .enhanced: "Enhanced"
            case .premium: "Premium"
            }
        }
    }

    var identifier: String
    var name: String
    /// BCP 47 code, e.g. "en-US".
    var language: String
    var quality: Quality
    /// Novelty voices ("Bubbles", "Bad News", ...) and the user's Personal Voice aren't suitable for reading.
    var isNoveltyOrPersonal: Bool

    /// Older synthesizer generations (MacinTalk "Fred", "Kathy", ...; Eloquence "Eddy", "Flo", ...)
    /// sound clearly worse than current Apple voices of the same nominal quality.
    var isLegacy: Bool {
        identifier.hasPrefix("com.apple.speech.synthesis.voice.") || identifier.hasPrefix("com.apple.eloquence.")
    }
}

nonisolated enum VoiceSelection {
    /// Accents in order of preference when voices are otherwise equal.
    static let preferredLanguages = ["en-US", "en-GB", "en-AU", "en-IE", "en-CA", "en-ZA", "en-IN"]

    /// English voices suitable for reading, best first: by quality, then current before legacy voices,
    /// then accent preference, then name.
    static func rankedEnglishVoices(_ voices: [VoiceInfo]) -> [VoiceInfo] {
        voices
            .filter { $0.language.hasPrefix("en") && !$0.isNoveltyOrPersonal }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                if a.isLegacy != b.isLegacy { return !a.isLegacy }
                let rankA = preferredLanguages.firstIndex(of: a.language) ?? preferredLanguages.count
                let rankB = preferredLanguages.firstIndex(of: b.language) ?? preferredLanguages.count
                if rankA != rankB { return rankA < rankB }
                return a.name < b.name
            }
    }

    static func bestEnglishVoice(_ voices: [VoiceInfo]) -> VoiceInfo? {
        rankedEnglishVoices(voices).first
    }

    /// The user's chosen voice if it is still installed (voices can be deleted in Settings),
    /// otherwise the best installed English voice.
    static func voice(preferring identifier: String?, from voices: [VoiceInfo]) -> VoiceInfo? {
        if let identifier, let chosen = voices.first(where: { $0.identifier == identifier }) {
            return chosen
        }
        return bestEnglishVoice(voices)
    }

    /// The voice for pronouncing single words: American English, since that is the standard wanted there.
    /// The user's chosen voice if it is American, otherwise the best American voice; with no American
    /// voice installed, whatever `voice(preferring:from:)` gives.
    static func americanVoice(preferring identifier: String?, from voices: [VoiceInfo]) -> VoiceInfo? {
        let american = voices.filter { $0.language == "en-US" }
        return voice(preferring: identifier, from: american) ?? voice(preferring: identifier, from: voices)
    }

    /// Voices installed on this device. Premium and Enhanced voices must be downloaded by the user in
    /// Settings → Accessibility → Spoken Content (Read & Speak) → Voices.
    static func installedVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map(VoiceInfo.init)
    }
}

extension VoiceInfo {
    nonisolated init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality = switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
        self.init(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: quality,
            isNoveltyOrPersonal: voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice)
        )
    }
}
