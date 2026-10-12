import Foundation
import Testing
@testable import WikiReader

struct WordCardModelTests {
    private func request(_ term: String) -> WordLookupRequest {
        WordLookupRequest(word: term, term: term, hasDefinition: true, sentence: "A sentence.")
    }

    /// A saving stub that records what it was given.
    private final class SavingLog {
        var meanings: [String?] = []
        var isSaved = false
    }

    private func saving(_ log: SavingLog) -> WordSaving {
        WordSaving(
            isSaved: log.isSaved,
            toggle: { meaning in
                log.meanings.append(meaning)
                log.isSaved.toggle()
                return log.isSaved
            },
            setMeaning: { log.meanings.append($0) }
        )
    }

    private func cache() -> DefinitionCache {
        DefinitionCache(directory: FileManager.default.temporaryDirectory.appending(path: "cards-\(UUID().uuidString)"))
    }

    @Test func inflectedWordShowsItsBaseFormAndAsksForThat() throws {
        let model = WordCardModel(request: request("studies"), saving: nil, voiceIdentifier: nil, cache: cache())
        #expect(model.entry?.word == "studies")
        #expect(model.lemmaEntry?.word == "study")
        #expect(model.definitionWord == "study")
    }

    @Test func baseFormHasNoSeparateLemmaEntry() {
        let model = WordCardModel(request: request("famine"), saving: nil, voiceIdentifier: nil, cache: cache())
        #expect(model.entry != nil)
        #expect(model.lemmaEntry == nil)
        #expect(model.definitionWord == "famine")
    }

    @Test func wordMissingFromTheDictionaryStillOpensACard() {
        let model = WordCardModel(request: request("asdfqwerzxcv"), saving: nil, voiceIdentifier: nil, cache: cache())
        #expect(model.entry == nil && model.lemmaEntry == nil)
        #expect(!model.canSave)
    }

    @Test func savingKeepsTheShortChineseMeaningWhenThereIsNoAIOne() {
        let log = SavingLog()
        let model = WordCardModel(request: request("famine"), saving: saving(log), voiceIdentifier: nil, cache: cache())
        model.toggleSaved()
        #expect(model.isSaved)
        #expect(log.meanings.first == model.entry?.shortMeaning)
        #expect(log.meanings.first??.contains("饥荒") == true)
    }

    @Test func anAIMeaningWinsOverTheDictionaryOne() {
        let log = SavingLog()
        let model = WordCardModel(request: request("famine"), saving: saving(log), voiceIdentifier: nil, cache: cache())
        model.didLoadAIMeaning("饥荒（这里指大饥荒）")
        model.toggleSaved()
        #expect(log.meanings == ["饥荒（这里指大饥荒）", "饥荒（这里指大饥荒）"])
    }

    @Test func cachedDefinitionsAreUsedWithoutAskingTheNetwork() throws {
        let cache = cache()
        let definition = WiktionaryDefinition(word: "famine", groups: [.init(partOfSpeech: "Noun", senses: [.init(text: "Scarcity of food.", example: nil)])])
        try cache.store(definition, for: "famine")
        let failing = URLSessionConfiguration.ephemeral
        failing.protocolClasses = []
        // A client whose session can never succeed: the card must not need it.
        let model = WordCardModel(
            request: request("famine"), saving: nil, voiceIdentifier: nil,
            client: WiktionaryClient(session: URLSession(configuration: failing)), cache: cache
        )
        model.loadOnlineDefinitions()
        #expect(model.online == .loaded(definition))
    }
}
