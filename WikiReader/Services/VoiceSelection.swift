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
}

nonisolated enum VoiceSelection {
    /// Accents in order of preference when voices are otherwise equal.
    static let preferredLanguages = ["en-US", "en-GB", "en-AU", "en-IE", "en-CA", "en-ZA", "en-IN"]

    /// English voices suitable for reading, best first: by quality, then accent preference, then name.
    static func rankedEnglishVoices(_ voices: [VoiceInfo]) -> [VoiceInfo] {
        voices
            .filter { $0.language.hasPrefix("en") && !$0.isNoveltyOrPersonal }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let rankA = preferredLanguages.firstIndex(of: a.language) ?? preferredLanguages.count
                let rankB = preferredLanguages.firstIndex(of: b.language) ?? preferredLanguages.count
                if rankA != rankB { return rankA < rankB }
                return a.name < b.name
            }
    }

    static func bestEnglishVoice(_ voices: [VoiceInfo]) -> VoiceInfo? {
        rankedEnglishVoices(voices).first
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
