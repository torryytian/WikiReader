import Testing
@testable import WikiReader

struct VoiceSelectionTests {
    private func voice(
        _ name: String, _ language: String, _ quality: VoiceInfo.Quality,
        novelty: Bool = false, identifier: String? = nil
    ) -> VoiceInfo {
        VoiceInfo(
            identifier: identifier ?? "com.apple.voice.compact.\(language).\(name)",
            name: name, language: language, quality: quality, isNoveltyOrPersonal: novelty
        )
    }

    /// The English voices a fresh iOS 27 simulator has (all "standard" quality).
    @Test func simulatorVoicesPickSamanthaNotFred() {
        let voices = [
            voice("Daniel", "en-GB", .standard, identifier: "com.apple.voice.super-compact.en-GB.Daniel"),
            voice("Samantha", "en-US", .standard, identifier: "com.apple.voice.super-compact.en-US.Samantha"),
            voice("Fred", "en-US", .standard, identifier: "com.apple.speech.synthesis.voice.Fred"),
            voice("Kathy", "en-US", .standard, identifier: "com.apple.speech.synthesis.voice.Kathy"),
            voice("Albert", "en-US", .standard, novelty: true, identifier: "com.apple.speech.synthesis.voice.Albert"),
        ]
        #expect(VoiceSelection.rankedEnglishVoices(voices).map(\.name) == ["Samantha", "Daniel", "Fred", "Kathy"])
    }

    @Test func legacyVoiceLosesOnlyAtEqualQuality() {
        let voices = [
            voice("Eddy", "en-US", .enhanced, identifier: "com.apple.eloquence.en-US.Eddy"),
            voice("Samantha", "en-US", .standard),
        ]
        #expect(VoiceSelection.bestEnglishVoice(voices)?.name == "Eddy")
    }

    @Test func chosenVoiceIsUsedWhileInstalled() {
        let voices = [voice("Ava", "en-US", .premium), voice("Karen", "en-AU", .standard)]
        #expect(VoiceSelection.voice(preferring: "com.apple.voice.compact.en-AU.Karen", from: voices)?.name == "Karen")
    }

    @Test func missingOrNoChoiceFallsBackToBest() {
        let voices = [voice("Karen", "en-AU", .standard), voice("Ava", "en-US", .premium)]
        #expect(VoiceSelection.voice(preferring: "com.apple.voice.premium.en-US.Deleted", from: voices)?.name == "Ava")
        #expect(VoiceSelection.voice(preferring: nil, from: voices)?.name == "Ava")
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

    // MARK: - Pronouncing single words

    @Test func wordsUseTheChosenVoiceWhenItIsAmerican() {
        let voices = [voice("Ava", "en-US", .premium), voice("Zoe", "en-US", .enhanced)]
        #expect(VoiceSelection.americanVoice(preferring: "com.apple.voice.compact.en-US.Zoe", from: voices)?.name == "Zoe")
    }

    @Test func wordsSkipABritishChosenVoice() {
        let voices = [voice("Daniel", "en-GB", .premium), voice("Samantha", "en-US", .standard)]
        #expect(VoiceSelection.americanVoice(preferring: "com.apple.voice.compact.en-GB.Daniel", from: voices)?.name == "Samantha")
    }

    @Test func wordsFallBackToAnyEnglishVoiceWithoutAnAmericanOne() {
        let voices = [voice("Daniel", "en-GB", .standard)]
        #expect(VoiceSelection.americanVoice(preferring: nil, from: voices)?.name == "Daniel")
    }
}
