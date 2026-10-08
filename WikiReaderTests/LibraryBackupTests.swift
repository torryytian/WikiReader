import Foundation
import SwiftData
import Testing
@testable import WikiReader

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "backup-tests-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ArchiveFileTests {
    @Test func entriesComeBackIntact() throws {
        let dir = try temporaryDirectory()
        let source = dir.appending(path: "big.bin")
        let big = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try big.write(to: source)

        let file = dir.appending(path: "a.wikireader")
        let writer = try ArchiveWriter(url: file)
        try writer.add(Data("hello".utf8), path: "a.txt")
        try writer.addFile(at: source, path: "dir/big.bin")
        try writer.add(Data(), path: "empty")
        try writer.finish()

        let reader = try ArchiveReader(url: file)
        #expect(reader.paths == ["a.txt", "dir/big.bin", "empty"])
        #expect(try reader.data(at: "a.txt") == Data("hello".utf8))
        #expect(try reader.data(at: "empty").isEmpty)

        let copy = dir.appending(path: "out/copy.bin")
        try reader.copy("dir/big.bin", to: copy)
        #expect(try Data(contentsOf: copy) == big)
    }

    @Test func missingEntryIsReported() throws {
        let file = try temporaryDirectory().appending(path: "a.wikireader")
        let writer = try ArchiveWriter(url: file)
        try writer.finish()
        let reader = try ArchiveReader(url: file)
        #expect(throws: BackupError.missingEntry("nope")) { try reader.data(at: "nope") }
    }

    @Test func otherFilesAreRejected() throws {
        let dir = try temporaryDirectory()
        let junk = dir.appending(path: "junk.wikireader")
        try Data("this is not a backup at all, just some text".utf8).write(to: junk)
        #expect(throws: BackupError.notABackup) { try ArchiveReader(url: junk) }

        let tiny = dir.appending(path: "tiny.wikireader")
        try Data("x".utf8).write(to: tiny)
        #expect(throws: BackupError.notABackup) { try ArchiveReader(url: tiny) }
    }

    @Test func truncatedFileIsRejected() throws {
        let dir = try temporaryDirectory()
        let file = dir.appending(path: "a.wikireader")
        let writer = try ArchiveWriter(url: file)
        try writer.add(Data(repeating: 7, count: 1000), path: "x")
        try writer.finish()
        let whole = try Data(contentsOf: file)
        let cut = dir.appending(path: "cut.wikireader")
        try whole.prefix(whole.count - 30).write(to: cut)
        #expect(throws: BackupError.notABackup) { try ArchiveReader(url: cut) }
    }
}

@MainActor
struct LibraryBackupTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func article(_ title: String, blocks: [ContentBlock] = [.paragraph("First."), .paragraph("Second.")]) -> Article {
        Article(title: title, sourceURL: ArticleInput.articleURL(forTitle: title), blocks: blocks)
    }

    private func request(_ word: String) -> WordLookupRequest {
        WordLookupRequest(word: word, term: word, hasDefinition: true, sentence: "A sentence.")
    }

    private func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "backup-tests-" + UUID().uuidString)!
        return defaults
    }

    @Test func libraryRoundTripsThroughAFile() async throws {
        let dir = try temporaryDirectory()
        let source = try makeContext()
        let paris = article("Paris", blocks: [.heading("History", level: 2), .paragraph("Old city.")])
        paris.lastReadBlockIndex = 1
        source.insert(paris)
        paris.toggleSavedWord(request("city"), meaning: "城市")
        source.insert(article("Albert Einstein"))

        let defaults = isolatedDefaults()
        defaults.set(1.25, forKey: SettingsKeys.speechRate)
        defaults.set("serif", forKey: SettingsKeys.readerFont)
        defaults.set("never-exported", forKey: SettingsKeys.voiceIdentifier)

        let snapshot = LibraryBackup.snapshot(
            of: try source.fetch(FetchDescriptor<Article>()), includeAudio: false, defaults: defaults,
            audioCache: SpeechAudioCache(directory: dir.appending(path: "audio")),
            translationCache: TranslationCache(directory: dir.appending(path: "tr"))
        )
        let file = dir.appending(path: "b.wikireader")
        try await LibraryBackup.write(snapshot, to: file)

        let library = try await LibraryBackup.readLibrary(from: file)
        #expect(library.articles.count == 2)
        #expect(library.settings[SettingsKeys.voiceIdentifier] == nil)

        let target = try makeContext()
        let targetDefaults = isolatedDefaults()
        let report = try LibraryBackup.merge(library, into: target, applySettings: true, defaults: targetDefaults)
        #expect(report.articlesAdded == 2)
        #expect(report.wordsAdded == 1)

        let imported = try #require(try target.fetch(FetchDescriptor<Article>()).first { $0.title == "Paris" })
        #expect(imported.blocks == paris.blocks)
        #expect(imported.lastReadBlockIndex == 1)
        #expect(imported.savedWords.first?.meaning == "城市")
        #expect(imported.sourceURL == paris.sourceURL)
        #expect(targetDefaults.double(forKey: SettingsKeys.speechRate) == 1.25)
        #expect(targetDefaults.string(forKey: SettingsKeys.readerFont) == "serif")
        #expect(targetDefaults.string(forKey: SettingsKeys.voiceIdentifier) == nil)
    }

    @Test func importingTwiceDoesNotDuplicate() throws {
        let library = LibraryExport(articles: [
            ExportedArticle(
                title: "Paris", sourceURL: ArticleInput.articleURL(forTitle: "Paris"), addedAt: .now,
                lastReadBlockIndex: 0, blocks: [.paragraph("A.")],
                savedWords: [SavedWord(word: "city", term: "city", sentence: "s", savedAt: .now)]
            ),
        ], settings: [:])
        let context = try makeContext()
        _ = try LibraryBackup.merge(library, into: context, applySettings: false, defaults: isolatedDefaults())
        let second = try LibraryBackup.merge(library, into: context, applySettings: false, defaults: isolatedDefaults())

        #expect(try context.fetch(FetchDescriptor<Article>()).count == 1)
        #expect(second.articlesAdded == 0)
        #expect(second.articlesMerged == 1)
        #expect(second.wordsAdded == 0)
    }

    @Test func existingArticleKeepsItsPositionAndGainsWords() throws {
        let context = try makeContext()
        let local = article("Paris")
        local.lastReadBlockIndex = 1
        context.insert(local)
        local.toggleSavedWord(request("river"))

        let library = LibraryExport(articles: [
            ExportedArticle(
                title: "  paris ", sourceURL: local.sourceURL, addedAt: .now, lastReadBlockIndex: 0,
                blocks: local.blocks,
                savedWords: [
                    SavedWord(word: "city", term: "city", sentence: "s", savedAt: .now),
                    SavedWord(word: "River", term: "river", sentence: "s", savedAt: .now, meaning: "河"),
                ]
            ),
        ], settings: [:])
        let report = try LibraryBackup.merge(library, into: context, applySettings: false, defaults: isolatedDefaults())

        #expect(report.articlesMerged == 1)
        #expect(report.wordsAdded == 1)
        #expect(local.lastReadBlockIndex == 1)
        #expect(Set(local.savedWords.map(\.term)) == ["river", "city"])
        // The word saved here without a meaning picked up the backup's.
        #expect(local.savedWords.first { $0.term == "river" }?.meaning == "河")
    }

    @Test func settingsAreOnlyAppliedWhenAsked() throws {
        let library = LibraryExport(articles: [], settings: [SettingsKeys.readerTheme: .text("dark")])
        let defaults = isolatedDefaults()
        _ = try LibraryBackup.merge(library, into: try makeContext(), applySettings: false, defaults: defaults)
        #expect(defaults.string(forKey: SettingsKeys.readerTheme) == nil)
    }

    @Test func audioIsMatchedToTheArticlesText() throws {
        let dir = try temporaryDirectory()
        let cache = SpeechAudioCache(directory: dir)
        let mine = OpenAISpeechRequest(
            model: OpenAISpeechEngine.model, voice: "marin", input: "First.", instructions: OpenAISpeechEngine.instructions
        )
        let otherVoice = OpenAISpeechRequest(
            model: OpenAISpeechEngine.model, voice: "cedar", input: "Second.", instructions: OpenAISpeechEngine.instructions
        )
        let unrelated = OpenAISpeechRequest(
            model: OpenAISpeechEngine.model, voice: "marin", input: "Not in this article.", instructions: OpenAISpeechEngine.instructions
        )
        for request in [mine, otherVoice, unrelated] {
            try cache.store(Data("audio".utf8), for: request)
        }

        let files = LibraryBackup.audioFiles(for: [.paragraph("First."), .paragraph("Second.")], cache: cache)
        #expect(Set(files.map(\.path)) == [
            "audio/" + SpeechAudioCache.key(for: mine) + ".mp3",
            "audio/" + SpeechAudioCache.key(for: otherVoice) + ".mp3",
        ])
    }

    @Test func cachesAreCopiedOnlyWhenMissingAndOnlyWithSafeNames() async throws {
        let dir = try temporaryDirectory()
        let goodAudio = String(repeating: "a", count: 64) + ".mp3"
        let goodTranslation = String(repeating: "b", count: 64) + ".json"
        let existing = String(repeating: "c", count: 64) + ".mp3"

        let file = dir.appending(path: "c.wikireader")
        let writer = try ArchiveWriter(url: file)
        try writer.add(Data("new".utf8), path: "audio/" + goodAudio)
        try writer.add(Data("tr".utf8), path: "translations/" + goodTranslation)
        try writer.add(Data("incoming".utf8), path: "audio/" + existing)
        try writer.add(Data("evil".utf8), path: "audio/../../evil.mp3")
        try writer.add(Data("evil".utf8), path: "audio/notahash.mp3")
        try writer.finish()

        let audio = SpeechAudioCache(directory: dir.appending(path: "A"))
        let translations = TranslationCache(directory: dir.appending(path: "T"))
        try FileManager.default.createDirectory(at: audio.directory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: audio.directory.appending(path: existing))

        let counts = try await LibraryBackup.copyCaches(from: file, audioCache: audio, translationCache: translations)
        #expect(counts.audio == 1)
        #expect(counts.translations == 1)
        #expect(try Data(contentsOf: audio.directory.appending(path: existing)) == Data("mine".utf8))
        #expect(try Data(contentsOf: audio.directory.appending(path: goodAudio)) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: audio.directory.path(percentEncoded: false)).count == 2)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "evil.mp3").path(percentEncoded: false)))
    }

    @Test func newerFormatIsRefused() async throws {
        let dir = try temporaryDirectory()
        var library = LibraryExport(articles: [], settings: [:])
        library.formatVersion = LibraryExport.currentVersion + 1
        let file = dir.appending(path: "n.wikireader")
        try await LibraryBackup.write(BackupSnapshot(library: library, files: []), to: file)
        await #expect(throws: BackupError.unsupportedVersion(LibraryExport.currentVersion + 1)) {
            try await LibraryBackup.readLibrary(from: file)
        }
    }
}
