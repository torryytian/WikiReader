import Foundation
import Testing
@testable import WikiReader

/// Uses the real bundled dictionary (the tests run inside the app, so `Bundle.main` has it).
struct DictionaryDatabaseTests {
    let database = DictionaryDatabase.bundled

    @Test func bundledDatabaseIsPresentAndBig() throws {
        let url = try #require(database.url)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 50_000_000)   // the full ECDICT, not a trimmed copy
    }

    @Test func findsAWordWithChineseAndEnglishMeanings() throws {
        let entry = try #require(database.entry(for: "shirk"))
        #expect(entry.word == "shirk")
        #expect(entry.chineseLines.contains { $0.contains("逃避") })
        #expect(entry.englishLines.contains { $0.contains("avoid") })
        #expect(!entry.phonetic.isEmpty)
    }

    @Test func lookupIgnoresCaseAndSurroundingSpace() {
        #expect(database.contains("Famine"))
        #expect(database.contains("  famine\n"))
        #expect(database.entry(for: "FAMINE")?.word == "famine")
    }

    @Test func inflectedFormPointsToItsBaseForm() throws {
        let entry = try #require(database.entry(for: "studies"))
        #expect(entry.lemma == "study")
        #expect(database.contains("study"))
        let running = try #require(database.entry(for: "running"))
        #expect(running.lemma == "run")
    }

    @Test func baseFormListsItsInflections() throws {
        let forms = try #require(database.entry(for: "shirk")).forms
        #expect(forms.presentParticiple == "shirking")
        #expect(forms.pastTense == "shirked")
        #expect(forms.lemma == nil)
    }

    @Test func unknownWordsAndEmptyInputFindNothing() {
        #expect(database.entry(for: "asdfqwerzxcv") == nil)
        #expect(database.entries(for: "   ").isEmpty)
        #expect(!database.contains(""))
    }

    @Test func quotesAndPunctuationInTheTermAreSafe() {
        // The term is bound as a parameter, never pasted into the SQL.
        #expect(database.entries(for: "x' OR '1'='1").isEmpty)
        #expect(database.entries(for: "don't").count <= 1)
    }

    @Test func missingFileMeansNoEntries() {
        let missing = DictionaryDatabase(url: URL(filePath: "/nonexistent/ecdict.sqlite"))
        #expect(missing.entry(for: "shirk") == nil)
        #expect(DictionaryDatabase(url: nil).entry(for: "shirk") == nil)
    }

    @Test func lookupUsesTheBundledDictionaryForCandidates() throws {
        let text = "The famine spread."
        let range = try #require(text.range(of: "famine"))
        let request = DictionaryLookup.bundled.request(forWordAt: range, in: text)
        #expect(request.term == "famine")
        #expect(request.hasDefinition)
    }
}

struct DictionaryEntryTests {
    private func entry(translation: String = "", definition: String = "", tags: String = "", exchange: String = "") -> DictionaryEntry {
        DictionaryEntry(
            word: "w", phonetic: "", englishDefinition: definition, chineseTranslation: translation,
            collins: 0, isOxford3000: false, tags: tags, exchange: exchange
        )
    }

    @Test func linesAreSplitOnTheStoredBackslashN() {
        // The database stores line breaks as the two characters backslash and n.
        let e = entry(translation: #"n. 赛跑, 流出\na. 流动的"#, definition: "n. a\nn. b")
        #expect(e.chineseLines == ["n. 赛跑, 流出", "a. 流动的"])
        #expect(e.englishLines == ["n. a", "n. b"])
        #expect(entry().chineseLines.isEmpty)
    }

    @Test func formsAreParsedAndLabelsMerged() {
        let forms = DictionaryEntry.Forms(exchange: "p:went/d:gone/i:going/3:goes/r:x/t:y/s:ws")
        #expect(forms.pastTense == "went" && forms.pastParticiple == "gone" && forms.presentParticiple == "going")
        #expect(forms.thirdPerson == "goes" && forms.comparative == "x" && forms.superlative == "y" && forms.plural == "ws")
        let merged = DictionaryEntry.Forms(exchange: "p:studied/d:studied/i:studying/3:studies").labelled
        #expect(merged.map(\.form) == ["studies", "studied", "studying"])
        #expect(merged[1].label == "past / past participle")
    }

    @Test func lemmaComesFromZeroEntry() {
        #expect(entry(exchange: "0:study/1:s3").lemma == "study")
        #expect(entry(exchange: "p:went").lemma == nil)
        #expect(entry(exchange: "garbage//:/0:").lemma == nil)
    }

    @Test func examLabelsFollowAFixedOrder() {
        #expect(entry(tags: "gre ky cet4 zk").examLabels == ["中考", "四级", "考研", "GRE"])
        #expect(entry(tags: "").examLabels.isEmpty)
    }

    @Test func phoneticIsShownWithRealIPASymbols() throws {
        let e = DictionaryEntry(word: "w", phonetic: "ʃ\u{04D9}:k ju:^\u{04D9}u", englishDefinition: "", chineseTranslation: "",
                                collins: 0, isOxford3000: false, tags: "", exchange: "")
        #expect(e.displayPhonetic == "ʃə:k ju:əu")
        // And the bundled data really does contain the Cyrillic letter this guards against.
        #expect(try #require(DictionaryDatabase.bundled.entry(for: "shirk")).phonetic.contains("\u{04D9}"))
    }

    @Test func shortMeaningIsTheFirstLineTrimmed() {
        #expect(entry(translation: #"n. 饥荒, 缺乏\nn. 饥饿"#).shortMeaning == "n. 饥荒, 缺乏")
        #expect(entry(translation: String(repeating: "长", count: 60)).shortMeaning == String(repeating: "长", count: 40) + "…")
        #expect(entry().shortMeaning == nil)
    }
}
