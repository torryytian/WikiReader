import Testing
@testable import WikiReader

struct VoiceChoiceTests {
    private let ava = VoiceInfo(
        identifier: "com.apple.voice.premium.en-US.Ava", name: "Ava", language: "en-US",
        quality: .premium, isNoveltyOrPersonal: false
    )
    private let daniel = VoiceInfo(
        identifier: "com.apple.voice.compact.en-GB.Daniel", name: "Daniel", language: "en-GB",
        quality: .standard, isNoveltyOrPersonal: false
    )

    private func current(
        engine: SpeechEngineChoice, voiceIdentifier: String? = nil, hasKey: Bool = true
    ) -> VoiceChoice {
        VoiceChoice.current(
            engine: engine, voiceIdentifier: voiceIdentifier, openAIVoice: "marin",
            hasOpenAIKey: hasKey, installedVoices: [ava, daniel]
        )
    }

    // MARK: - Which voice is in use

    @Test func openAIEngineWithKeyIsTheOpenAIVoice() {
        #expect(current(engine: .openAI) == .openAI(voice: "marin"))
    }

    @Test func openAIEngineWithoutKeyFallsBackToTheIPhoneVoice() {
        #expect(current(engine: .openAI, voiceIdentifier: ava.identifier, hasKey: false) == .iPhone(identifier: ava.identifier))
    }

    @Test func systemEngineUsesTheChosenIPhoneVoice() {
        // The OpenAI voice and key don't matter while the system engine is chosen.
        #expect(current(engine: .system, voiceIdentifier: daniel.identifier) == .iPhone(identifier: daniel.identifier))
    }

    @Test func noChoiceOrDeletedVoiceIsAutomatic() {
        #expect(current(engine: .system) == .iPhone(identifier: nil))
        #expect(current(engine: .system, voiceIdentifier: "com.apple.voice.premium.en-US.Gone") == .iPhone(identifier: nil))
    }

    // MARK: - Engine and summary

    @Test func choosingAVoiceChoosesItsEngine() {
        #expect(VoiceChoice.iPhone(identifier: nil).engine == .system)
        #expect(VoiceChoice.iPhone(identifier: ava.identifier).engine == .system)
        #expect(VoiceChoice.openAI(voice: "cedar").engine == .openAI)
    }

    @Test func summaryNamesVoiceAndSource() {
        let voices = [ava, daniel]
        #expect(VoiceChoice.openAI(voice: "marin").summary(installedVoices: voices) == "Marin · OpenAI")
        #expect(VoiceChoice.iPhone(identifier: ava.identifier).summary(installedVoices: voices) == "Ava · iPhone")
        #expect(VoiceChoice.iPhone(identifier: nil).summary(installedVoices: voices) == "Automatic · iPhone")
    }
}
