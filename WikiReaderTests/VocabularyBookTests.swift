import Foundation
import SwiftData
import Testing
@testable import WikiReader

/// The global word book on this iPhone, and keeping it in step with Drive's `vocab.json`.
@MainActor
struct VocabularyBookTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_793_700_000)
        func advance(_ seconds: TimeInterval = 1) { now += seconds }
    }

    let fileURL = URL.temporaryDirectory.appending(path: "Vocabulary-\(UUID().uuidString).json")
    let clock = Clock()
    let paris = URL(string: "https://en.wikipedia.org/wiki/Paris")!
    let rome = URL(string: "https://en.wikipedia.org/wiki/Rome")!

    private func makeBook() -> VocabularyBook {
        let clock = clock
        return VocabularyBook(fileURL: fileURL, now: { clock.now }, lemmaOf: { ["studies": "study", "studied": "study"][$0] })
    }

    private func request(_ word: String, term: String? = nil, sentence: String = "Some studies say so.") -> WordLookupRequest {
        WordLookupRequest(word: word, term: term ?? word, hasDefinition: true, sentence: sentence)
    }

    @Test func savingRecordsTheSentenceAndArticleAndSurvivesARestart() throws {
        let book = makeBook()
        var changes = 0
        book.onLocalChange = { changes += 1 }

        #expect(book.toggle(request("Studies"), url: paris, title: "Paris", meaning: "研究"))
        let entry = try #require(book.entry(forTerm: "studies"))
        #expect(entry.key == "studies" && entry.term == "Studies" && entry.lemma == "study")
        #expect(entry.forms == ["Studies"])
        #expect(entry.meaning == "研究")
        #expect(entry.contexts.map(\.url) == [paris.absoluteString])
        #expect(entry.contexts.first?.id == VocabFormat.contextID(of: "Some studies say so."))
        #expect(changes == 1)

        let reopened = makeBook()
        #expect(reopened.file.entries == book.file.entries)
        #expect(reopened.entries(savedFrom: paris).map(\.key) == ["studies"])
        #expect(reopened.entries(savedFrom: rome).isEmpty)
    }

    @Test func theSameWordFromAnotherArticleAddsASentenceNotAWord() throws {
        let book = makeBook()
        book.save(word: "studies", term: "studies", sentence: "One.", url: paris, title: "Paris")
        clock.advance()
        book.save(word: "Studies", term: "Studies", sentence: "Two.", url: rome, title: "Rome")
        let entry = try #require(book.entry(forKey: "studies"))
        #expect(book.count == 1)
        #expect(entry.contexts.map(\.title) == ["Paris", "Rome"])
        #expect(entry.forms == ["studies", "Studies"])
        #expect(entry.updatedAt > entry.createdAt)
    }

    @Test func removingAWordAnywhereLeavesATombstoneAndSavingAgainLiftsIt() {
        let book = makeBook()
        book.toggle(request("studies"), url: paris, title: "Paris")
        clock.advance()
        #expect(!book.toggle(request("studies"), url: rome, title: "Rome"))
        #expect(book.count == 0)
        #expect(book.file.deleted["studies"] == VocabFormat.milliseconds(clock.now))

        clock.advance()
        book.toggle(request("studies"), url: rome, title: "Rome")
        #expect(book.count == 1)
        #expect(book.file.deleted["studies"] == nil)
    }

    @Test func aMeaningGoesToItsSentenceAndToTheWordWhenItHasNone() throws {
        let book = makeBook()
        book.save(word: "studies", term: "studies", sentence: "One.", url: paris, title: "Paris")
        book.save(word: "studies", term: "studies", sentence: "Two.", url: rome, title: "Rome")
        book.setMeaning("研究", term: "Studies", sentence: "Two.")
        let entry = try #require(book.entry(forKey: "studies"))
        #expect(entry.meaning == "研究")
        #expect(entry.contexts.map(\.meaning) == [nil, "研究"])
    }

    @Test func perArticleListsMoveInOnceAndDeletedWordsStayDeleted() throws {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Article(title: "Paris", sourceURL: paris, blocks: [])
        let b = Article(title: "Rome", sourceURL: rome, blocks: [])
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        let saved = Date(timeIntervalSince1970: 1_793_000_000)
        a.savedWords = [SavedWord(word: "studies", term: "studies", sentence: "In Paris.", savedAt: saved, meaning: "研究"),
                        SavedWord(word: "tabloid", term: "tabloid", sentence: "A tabloid.", savedAt: saved)]
        b.savedWords = [SavedWord(word: "Studies", term: "studies", sentence: "In Rome.", savedAt: saved + 60)]
        let defaults = try #require(UserDefaults(suiteName: "VocabImport-\(UUID().uuidString)"))

        let book = makeBook()
        book.importArticleWordsOnce([a, b], defaults: defaults)
        #expect(Set(book.keys) == ["studies", "tabloid"])
        let studies = try #require(book.entry(forKey: "studies"))
        #expect(studies.contexts.map(\.title) == ["Paris", "Rome"])
        #expect(studies.meaning == "研究")
        #expect(studies.createdAt == VocabFormat.milliseconds(saved))

        // Deleted since; a second import (another backup, an older list) doesn't bring it back.
        book.delete(key: "tabloid")
        book.importArticleWords([(url: paris, title: "Paris", words: a.savedWords)])
        #expect(book.entry(forKey: "tabloid") == nil)
        // And "once" means once.
        book.delete(key: "studies")
        book.importArticleWordsOnce([a, b], defaults: defaults)
        #expect(book.count == 0)
    }

    @Test func theMatcherMarksSavedWordsAndTheirOtherForms() {
        let book = makeBook()
        book.save(word: "studies", term: "studies", sentence: "S.", url: paris, title: "Paris")
        let matcher = book.matcher(lemmas: ["studies": "study", "studied": "study"])
        #expect(matcher.match(word: "Studies") == .saved)
        #expect(matcher.match(word: "studies'") == .saved)
        #expect(matcher.match(word: "studied") == .related)
        #expect(matcher.match(word: "study") == .related)
        #expect(matcher.match(word: "student") == nil)
        #expect(matcher.match(word: "1990") == nil)
    }
}

@MainActor
struct VocabSyncTests {
    let drive = FakeDrive()
    let fileURL = URL.temporaryDirectory.appending(path: "VocabSync-\(UUID().uuidString).json")
    let clock = VocabularyBookTests.Clock()
    let url = URL(string: "https://en.wikipedia.org/wiki/Paris")!

    private func makeBook() -> VocabularyBook {
        let clock = clock
        return VocabularyBook(fileURL: fileURL, now: { clock.now }, lemmaOf: { _ in nil })
    }

    private func makeSync(_ book: VocabularyBook, root: String) -> VocabSync {
        let drive = drive, clock = clock
        return VocabSync(
            book: book, client: DriveClient(transport: { try await drive.handle($0) }, token: { _ in "t" }),
            isSignedIn: { true }, rootFolder: { root }, now: { clock.now }
        )
    }

    private func remoteFile() async throws -> VocabFile {
        try VocabFile.decode(#require(await drive.file(named: VocabSync.fileName)).data)
    }

    private func writes() async -> Int {
        await drive.requests.count { $0.hasPrefix("POST /upload") || $0.hasPrefix("PATCH") }
    }

    @Test func theFirstSyncCreatesTheFileAndAnUnchangedBookIsNotWrittenAgain() async throws {
        let root = await drive.add(name: DriveAudioStore.rootName, parent: "root", mimeType: "application/vnd.google-apps.folder")
        let book = makeBook()
        book.save(word: "studies", term: "studies", sentence: "S.", url: url, title: "Paris")
        let sync = makeSync(book, root: root)

        await sync.sync()
        #expect(sync.state == .synced)
        #expect(try await remoteFile().entries.map(\.key) == ["studies"])
        #expect(try await remoteFile().updatedBy == "ios")
        #expect(await writes() == 1)

        clock.advance(60)
        await sync.sync()
        #expect(await writes() == 1)
    }

    @Test func wordsFromChromeArriveAndDeletionsReachBothWays() async throws {
        let root = await drive.add(name: DriveAudioStore.rootName, parent: "root", mimeType: "application/vnd.google-apps.folder")
        let now = VocabFormat.milliseconds(clock.now)
        var chrome = VocabFile(
            entries: [VocabEntry(key: "tabloid", term: "tabloid", forms: ["tabloid"], createdAt: now - 5000, updatedAt: now - 5000, contexts: [])],
            deleted: ["siege": now - 1000]
        )
        chrome.entries[0].other["chrome"] = .object(["explainedModel": .string("gpt-4o-mini")])
        chrome.updatedBy = "chrome"
        _ = await drive.add(name: VocabSync.fileName, parent: root, mimeType: "application/json", data: try chrome.encoded())

        let book = makeBook()
        clock.now -= 10  // saved before Chrome deleted it
        book.save(word: "siege", term: "siege", sentence: "S.", url: url, title: "Paris")
        clock.advance(20)
        book.save(word: "verdict", term: "verdict", sentence: "V.", url: url, title: "Paris")
        let sync = makeSync(book, root: root)

        await sync.sync()
        #expect(Set(book.keys) == ["tabloid", "verdict"])
        let remote = try await remoteFile()
        #expect(Set(remote.entries.map(\.key)) == ["tabloid", "verdict"])
        #expect(remote.deleted["siege"] == now - 1000)
        // Chrome's own data is carried along untouched.
        #expect(remote.entries.first { $0.key == "tabloid" }?.other["chrome"] == .object(["explainedModel": .string("gpt-4o-mini")]))
        #expect(await drive.count(named: VocabSync.fileName) == 1)

        clock.advance()
        book.delete(key: "tabloid")
        await sync.sync()
        #expect(try await remoteFile().entries.map(\.key) == ["verdict"])
        #expect(try await remoteFile().deleted["tabloid"] != nil)
    }

    @Test func chromesFirstFormatIsLeftAloneUntilTheExtensionConvertsIt() async throws {
        let root = await drive.add(name: DriveAudioStore.rootName, parent: "root", mimeType: "application/vnd.google-apps.folder")
        let v1 = Data(#"{"formatVersion":1,"app":"chrome","updatedAt":1,"entries":[],"deleted":{}}"#.utf8)
        _ = await drive.add(name: VocabSync.fileName, parent: root, mimeType: "application/json", data: v1)
        let book = makeBook()
        book.save(word: "verdict", term: "verdict", sentence: "V.", url: url, title: "Paris")

        let sync = makeSync(book, root: root)
        await sync.sync()

        #expect(sync.state == .waitingForChrome)
        #expect(await drive.file(named: VocabSync.fileName)?.data == v1)
        #expect(await writes() == 0)
        #expect(book.count == 1)
    }

    @Test func anEmptyBookWithNothingOnDriveWritesNothing() async throws {
        let root = await drive.add(name: DriveAudioStore.rootName, parent: "root", mimeType: "application/vnd.google-apps.folder")
        let sync = makeSync(makeBook(), root: root)
        await sync.sync()
        #expect(sync.state == .synced)
        #expect(await writes() == 0)
    }
}

/// The reader marks saved words with a tint and other forms of them with a dotted underline.
struct ReaderVocabMatchTests {
    private func document(_ paragraphs: [String]) -> ArticleDocument {
        ArticleDocument(title: "Example", blocks: paragraphs.map { .paragraph($0) }, style: .default)
    }

    private func found(_ keys: [String], lemmas: [String: String] = [:], in document: ArticleDocument) -> [String] {
        let text = document.attributedText.string as NSString
        return document.wordMatches(VocabMatcher(keys: keys, lemmas: lemmas, version: 1)).map {
            text.substring(with: $0.range) + ($0.match == .related ? "~" : "")
        }
    }

    @Test func findsEveryOccurrenceIgnoringCase() {
        let doc = document(["Wreckage was found. The wreckage sank.", "More WRECKAGE."])
        #expect(found(["wreckage"], in: doc) == ["Wreckage", "wreckage", "WRECKAGE"])
    }

    @Test func matchesWholeWordsOnly() {
        let doc = document(["The crash was a crashing bore."])
        #expect(found(["crash"], in: doc) == ["crash"])
    }

    @Test func possessiveStillMatches() {
        let doc = document(["The aircraft's recorders and the aircraft."])
        #expect(found(["aircraft"], in: doc) == ["aircraft's", "aircraft"])
    }

    @Test func otherFormsOfASavedWordAreRelated() {
        let doc = document(["Studies of study: she studied it."])
        let lemmas = ["studies": "study", "studied": "study"]
        #expect(found(["studies"], lemmas: lemmas, in: doc) == ["Studies", "study~", "studied~"])
        #expect(doc.bookKeys(VocabMatcher(keys: ["studies"], lemmas: lemmas, version: 1)) == ["studies"])
        #expect(document(["She studied."]).bookKeys(VocabMatcher(keys: ["studies", "tabloid"], lemmas: lemmas, version: 1)) == ["studies"])
    }

    @Test func noWordsNoMatchesAndTheTitleIsNotSearched() {
        #expect(found([], in: document(["Anything."])).isEmpty)
        #expect(found(["example"], in: document(["Body text."])).isEmpty)
    }
}

/// Backups carry the whole word book; an older backup's per-article lists still come in.
@MainActor
struct VocabularyBackupTests {
    let dir = URL.temporaryDirectory.appending(path: "VocabBackup-\(UUID().uuidString)")
    let clock = VocabularyBookTests.Clock()
    let paris = URL(string: "https://en.wikipedia.org/wiki/Paris")!

    private func makeBook(_ name: String) -> VocabularyBook {
        let clock = clock
        return VocabularyBook(fileURL: dir.appending(path: "\(name).json"), now: { clock.now }, lemmaOf: { _ in nil })
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    @Test func aBackupCarriesTheBookAndItsArticlesListThemForOlderVersions() async throws {
        let source = try makeContext()
        let article = Article(title: "Paris", sourceURL: paris, blocks: [.paragraph("A city.")])
        source.insert(article)
        let book = makeBook("source")
        book.save(word: "city", term: "city", sentence: "A city.", url: paris, title: "Paris", meaning: "城市")
        book.save(word: "tabloid", term: "tabloid", sentence: "Elsewhere.", url: URL(string: "https://example.com/news")!, title: "News")

        let snapshot = LibraryBackup.snapshot(
            of: [article], includeAudio: false, vocabulary: book.file, defaults: UserDefaults(suiteName: "VB-\(UUID().uuidString)")!,
            audioCache: SpeechAudioCache(directory: dir.appending(path: "audio")),
            translationCache: TranslationCache(directory: dir.appending(path: "tr"))
        )
        #expect(snapshot.library.articles.first?.savedWords.map(\.term) == ["city"])
        #expect(snapshot.library.articles.first?.savedWords.first?.meaning == "城市")
        let file = dir.appending(path: "b.wikireader")
        try await LibraryBackup.write(snapshot, to: file)
        let library = try await LibraryBackup.readLibrary(from: file)
        #expect(Set(library.vocabulary?.entries.map(\.key) ?? []) == ["city", "tabloid"])

        let target = makeBook("target")
        _ = try LibraryBackup.merge(library, into: try makeContext(), applySettings: false, book: target,
                                    defaults: UserDefaults(suiteName: "VB-\(UUID().uuidString)")!)
        #expect(Set(target.keys) == ["city", "tabloid"])
    }

    @Test func anOlderBackupsPerArticleListsComeIntoTheBook() throws {
        let saved = Date(timeIntervalSince1970: 1_793_000_000)
        let library = LibraryExport(articles: [ExportedArticle(
            title: "Paris", sourceURL: paris, addedAt: saved, lastReadBlockIndex: 0, blocks: [.paragraph("A city.")],
            savedWords: [SavedWord(word: "city", term: "city", sentence: "A city.", savedAt: saved, meaning: "城市")]
        )], settings: [:])
        let book = makeBook("older")
        _ = try LibraryBackup.merge(library, into: try makeContext(), applySettings: false, book: book,
                                    defaults: UserDefaults(suiteName: "VB-\(UUID().uuidString)")!)
        #expect(book.entry(forKey: "city")?.contexts.first?.title == "Paris")
        #expect(book.entry(forKey: "city")?.meaning == "城市")
    }
}
