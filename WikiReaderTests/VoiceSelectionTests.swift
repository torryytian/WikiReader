import Testing
@testable import WikiReader

struct VoiceSelectionTests {
    private func voice(
        _ name: String, _ language: String, _ quality: VoiceInfo.Quality, novelty: Bool = false
    ) -> VoiceInfo {
        VoiceInfo(identifier: "id.\(name)", name: name, language: language, quality: quality, isNoveltyOrPersonal: novelty)
    }

    @Test func qualityComesFirst() {
        let voices = [
            voice("Samantha", "en-US", .standard),
            voice("Daniel", "en-GB", .premium),
            voice("Ava", "en-US", .enhanced),
        ]
        #expect(VoiceSelection.rankedEnglishVoices(voices).map(\.name) == ["Daniel", "Ava", "Samantha"])
    }

    @Test func accentBreaksTies() {
        let voices = [
            voice("Karen", "en-AU", .enhanced),
            voice("Rishi", "en-IN", .enhanced),
            voice("Moira", "en-IE", .enhanced),
            voice("Zoe", "en-US", .enhanced),
            voice("Serena", "en-GB", .enhanced),
            voice("Fred", "en-NZ", .enhanced),
        ]
        #expect(VoiceSelection.rankedEnglishVoices(voices).map(\.name) == ["Zoe", "Serena", "Karen", "Moira", "Rishi", "Fred"])
    }

    @Test func nameBreaksRemainingTies() {
        let voices = [voice("Zoe", "en-US", .premium), voice("Ava", "en-US", .premium)]
        #expect(VoiceSelection.bestEnglishVoice(voices)?.name == "Ava")
    }

    @Test func nonEnglishAndNoveltyVoicesAreExcluded() {
        let voices = [
            voice("Thomas", "fr-FR", .premium),
            voice("Tingting", "zh-CN", .premium),
            voice("Bubbles", "en-US", .premium, novelty: true),
            voice("Samantha", "en-US", .standard),
        ]
        #expect(VoiceSelection.rankedEnglishVoices(voices).map(\.name) == ["Samantha"])
    }

    @Test func noEnglishVoice() {
        #expect(VoiceSelection.bestEnglishVoice([voice("Thomas", "fr-FR", .premium)]) == nil)
        #expect(VoiceSelection.bestEnglishVoice([]) == nil)
    }

    @Test func ratesIncreaseWithSpeed() {
        let rates = SpeechRate.allCases.map(\.systemRate)
        #expect(rates == rates.sorted())
        #expect(Set(rates).count == rates.count)
        #expect(SpeechRate.normal.systemRate == 0.5)
    }
}
