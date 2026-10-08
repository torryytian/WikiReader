import Foundation
import OSLog
import SwiftData

/// A setting copied between devices: the stored settings are all text or numbers.
nonisolated enum SettingValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        }
    }
}

nonisolated struct ExportedArticle: Codable, Equatable, Sendable {
    var title: String
    var sourceURL: URL
    var addedAt: Date
    var lastReadBlockIndex: Int
    var blocks: [ContentBlock]
    var savedWords: [SavedWord]
}

/// The contents of a backup file's `library.json`.
nonisolated struct LibraryExport: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let path = "library.json"

    var formatVersion = LibraryExport.currentVersion
    var exportedAt = Date.now
    var articles: [ExportedArticle]
    var settings: [String: SettingValue]
}

/// What an import did, for the message shown afterwards.
nonisolated struct ImportReport: Equatable, Sendable {
    var articlesAdded = 0
    var articlesMerged = 0
    var wordsAdded = 0
    var audioFiles = 0
    var translations = 0
    var appliedSettings = false
}

/// A backup ready to be written: everything read from the database and the disk, so the writing itself can
/// happen off the main thread.
nonisolated struct BackupSnapshot: Sendable {
    var library: LibraryExport
    /// Backup path and the file to copy into it.
    var files: [(path: String, url: URL)]

    var totalBytes: Int64 {
        files.reduce(0) { sum, file in
            sum + Int64((try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// Export and import of the whole library as one file: articles with their reading position and saved
/// words, the settings that make sense on another device, and the audio and translations already paid for.
///
/// Audio and translation files are named by a hash of what they contain, the same on every device, so a copied
/// file is found again by the app without any bookkeeping.
nonisolated enum LibraryBackup {
    static let fileExtension = "wikireader"
    static let audioFolder = "audio/"
    static let translationFolder = "translations/"

    /// Settings that mean the same on another device. The system voice is left out (voices differ per device),
    /// and the OpenAI key is never exported.
    static let portableSettingKeys = [
        SettingsKeys.speechRate, SettingsKeys.speechEngine, SettingsKeys.openAIVoice, SettingsKeys.appAppearance,
        SettingsKeys.readerFont, SettingsKeys.readerFontSize, SettingsKeys.readerLineSpacing,
        SettingsKeys.readerMargins, SettingsKeys.readerTheme, SettingsKeys.readerDarkLevel,
    ]

    /// Names the app itself writes: 64 hex digits and an extension. Anything else in a file is ignored, so a
    /// crafted file can't write outside the cache folders.
    static func isCacheFileName(_ name: String, extension ext: String) -> Bool {
        guard name.hasSuffix("." + ext) else { return false }
        let stem = name.dropLast(ext.count + 1)
        return stem.count == 64 && stem.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Export

    /// Reads what to export. Audio is matched to articles by recomputing the cache names of their text for every
    /// OpenAI voice, so only audio that belongs to the chosen articles is included.
    @MainActor
    static func snapshot(
        of articles: [Article], includeAudio: Bool,
        defaults: UserDefaults = .standard,
        audioCache: SpeechAudioCache = .standard, translationCache: TranslationCache = .standard
    ) -> BackupSnapshot {
        let exported = articles.map {
            ExportedArticle(
                title: $0.title, sourceURL: $0.sourceURL, addedAt: $0.addedAt,
                lastReadBlockIndex: $0.lastReadBlockIndex, blocks: $0.blocks, savedWords: $0.savedWords
            )
        }

        var settings: [String: SettingValue] = [:]
        for key in portableSettingKeys {
            switch defaults.object(forKey: key) {
            case let text as String: settings[key] = .text(text)
            case let number as NSNumber: settings[key] = .number(number.doubleValue)
            default: break
            }
        }

        var files: [(path: String, url: URL)] = []
        if includeAudio {
            files += audioFiles(for: exported.flatMap(\.blocks), cache: audioCache)
        }
        files += translationFiles(in: translationCache)

        return BackupSnapshot(library: LibraryExport(articles: exported, settings: settings), files: files)
    }

    static func audioFiles(for blocks: [ContentBlock], cache: SpeechAudioCache) -> [(path: String, url: URL)] {
        var seen = Set<String>()
        var files: [(path: String, url: URL)] = []
        for block in blocks {
            let text = block.text as NSString
            for chunk in SpeechChunking.chunks(of: block.text) {
                let input = text.substring(with: chunk)
                for voice in OpenAISpeechEngine.voices {
                    let request = OpenAISpeechRequest(
                        model: OpenAISpeechEngine.model, voice: voice, input: input,
                        instructions: OpenAISpeechEngine.instructions
                    )
                    guard let url = cache.cachedFile(for: request), seen.insert(url.lastPathComponent).inserted else { continue }
                    files.append((audioFolder + url.lastPathComponent, url))
                }
            }
        }
        return files
    }

    /// All cached translations: they are small, and a selection can't be tied to one article.
    static func translationFiles(in cache: TranslationCache) -> [(path: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { isCacheFileName($0.lastPathComponent, extension: "json") }
            .map { (translationFolder + $0.lastPathComponent, $0) }
    }

    @concurrent
    static func write(_ snapshot: BackupSnapshot, to url: URL) async throws(BackupError) {
        let writer = try ArchiveWriter(url: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try writer.add(try encoder.encode(snapshot.library), path: LibraryExport.path)
        } catch let error as BackupError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
        for file in snapshot.files {
            try writer.addFile(at: file.url, path: file.path)
        }
        try writer.finish()
    }

    // MARK: - Import

    @concurrent
    static func readLibrary(from url: URL) async throws(BackupError) -> LibraryExport {
        let reader = try ArchiveReader(url: url)
        let data = try reader.data(at: LibraryExport.path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library: LibraryExport
        do {
            library = try decoder.decode(LibraryExport.self, from: data)
        } catch {
            throw .notABackup
        }
        guard library.formatVersion <= LibraryExport.currentVersion else {
            throw .unsupportedVersion(library.formatVersion)
        }
        return library
    }

    /// Copies audio and translation files the device doesn't have yet.
    @concurrent
    static func copyCaches(
        from url: URL,
        audioCache: SpeechAudioCache = .standard, translationCache: TranslationCache = .standard
    ) async throws(BackupError) -> (audio: Int, translations: Int) {
        let reader = try ArchiveReader(url: url)
        var audio = 0
        var translations = 0
        for path in reader.paths {
            let isAudio = path.hasPrefix(audioFolder)
            let isTranslation = path.hasPrefix(translationFolder)
            guard isAudio || isTranslation else { continue }

            let name = String(path.dropFirst(isAudio ? audioFolder.count : translationFolder.count))
            guard isCacheFileName(name, extension: isAudio ? OpenAITTSClient.audioFormat : "json") else { continue }

            let destination = (isAudio ? audioCache.directory : translationCache.directory).appending(path: name)
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
            try reader.copy(path, to: destination)
            if isAudio { audio += 1 } else { translations += 1 }
        }
        return (audio, translations)
    }

    /// Adds the backup's articles to the library. An article already there (same title) isn't replaced: it keeps
    /// its reading position and gains any saved words it lacked. Settings are applied only when asked.
    @MainActor
    static func merge(
        _ library: LibraryExport, into context: ModelContext,
        applySettings: Bool, defaults: UserDefaults = .standard
    ) throws -> ImportReport {
        var report = ImportReport()
        let existing = try context.fetch(FetchDescriptor<Article>())
        var byTitle = Dictionary(existing.map { (normalizedTitle($0.title), $0) }, uniquingKeysWith: { first, _ in first })

        for incoming in library.articles {
            let key = normalizedTitle(incoming.title)
            if let article = byTitle[key] {
                var words = article.savedWords
                let known = Set(words.map(\.id))
                let added = incoming.savedWords.filter { !known.contains($0.id) }
                // A word saved here without a meaning can take the one from the backup.
                for index in words.indices where words[index].meaning == nil {
                    words[index].meaning = incoming.savedWords.first { $0.id == words[index].id }?.meaning
                }
                if !added.isEmpty || words != article.savedWords {
                    article.savedWords = (words + added).sorted { $0.savedAt > $1.savedAt }
                }
                report.wordsAdded += added.count
                report.articlesMerged += 1
            } else {
                let article = Article(
                    title: incoming.title, sourceURL: incoming.sourceURL, blocks: incoming.blocks, addedAt: incoming.addedAt
                )
                article.lastReadBlockIndex = min(max(incoming.lastReadBlockIndex, 0), max(incoming.blocks.count - 1, 0))
                article.savedWords = incoming.savedWords
                context.insert(article)
                byTitle[key] = article
                report.wordsAdded += incoming.savedWords.count
                report.articlesAdded += 1
            }
        }
        try context.save()

        if applySettings {
            for (key, value) in library.settings where portableSettingKeys.contains(key) {
                switch value {
                case .text(let text): defaults.set(text, forKey: key)
                case .number(let number): defaults.set(number, forKey: key)
                }
            }
            report.appliedSettings = !library.settings.isEmpty
        }
        return report
    }
}
