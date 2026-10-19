import Foundation
import SwiftData

/// Which of an article's OpenAI audio is on disk, worked out the way the reader looks it up: each block's text split
/// into request-sized pieces (`SpeechChunking`), each piece a file named after its request.
nonisolated enum ArticleAudio {
    /// About what OpenAI charges for gpt-4o-mini-tts, per minute of audio.
    static let dollarsPerMinute = 0.015
    /// The text voice samples in Settings read, kept by cleanups like any article's audio.
    static let sampleText = "This is how Wikipedia articles will sound with this voice."

    /// One request's worth of an article's text.
    struct Piece: Sendable {
        var block: Int
        var request: OpenAISpeechRequest
        var characters: Int
    }

    /// The pieces that read `blocks` with `voice`, in reading order.
    static func pieces(of blocks: [ContentBlock], voice: String) -> [Piece] {
        var pieces: [Piece] = []
        for (index, block) in blocks.enumerated() {
            let text = block.text as NSString
            for chunk in SpeechChunking.chunks(of: block.text) {
                let input = text.substring(with: chunk)
                pieces.append(Piece(block: index, request: OpenAISpeechEngine.request(for: input, voice: voice), characters: input.count))
            }
        }
        return pieces
    }

    /// The texts sent for `blocks`, whatever the voice.
    static func inputs(of blocks: [ContentBlock]) -> Set<String> {
        var inputs = Set<String>()
        for block in blocks {
            let text = block.text as NSString
            for chunk in SpeechChunking.chunks(of: block.text) {
                inputs.insert(text.substring(with: chunk))
            }
        }
        return inputs
    }

    /// Minutes of speech in this many characters, at normal speed.
    static func minutes(forCharacters characters: Int) -> Double {
        Double(characters) / (ReadingSession.charactersPerSecond * 60)
    }

    static func dollars(forCharacters characters: Int) -> Double {
        minutes(forCharacters: characters) * dollarsPerMinute
    }

    /// Where `blocks` stand with `voice`.
    static func status(of blocks: [ContentBlock], voice: String, cache: SpeechAudioCache) -> ArticleAudioStatus {
        let files = AudioFiles(cache)
        var status = ArticleAudioStatus(voice: voice, blockCharacters: Array(repeating: 0, count: blocks.count), cachedBlockCharacters: Array(repeating: 0, count: blocks.count))
        for piece in pieces(of: blocks, voice: voice) {
            status.totalPieces += 1
            status.blockCharacters[piece.block] += piece.characters
            let name = cache.fileURL(for: piece.request).lastPathComponent
            if let size = files.sizes[name] {
                status.cachedPieces += 1
                status.cachedBlockCharacters[piece.block] += piece.characters
                status.bytes += size
            } else {
                status.missing.append(piece)
            }
        }
        for input in inputs(of: blocks) {
            for other in OpenAISpeechEngine.voices where other != voice {
                if let size = files.sizes[cache.fileURL(for: OpenAISpeechEngine.request(for: input, voice: other)).lastPathComponent] {
                    status.otherVoiceBytes += size
                }
            }
        }
        return status
    }

    /// The audio files of `blocks`, in every voice, that no article in `keeping` uses too: what deleting the
    /// article's audio removes.
    static func files(of blocks: [ContentBlock], notUsedBy keeping: [[ContentBlock]], cache: SpeechAudioCache) -> [URL] {
        let shared = keeping.reduce(into: Set<String>()) { $0.formUnion(inputs(of: $1)) }
        let files = AudioFiles(cache)
        var urls: [URL] = []
        for input in inputs(of: blocks) where !shared.contains(input) {
            for voice in OpenAISpeechEngine.voices {
                let url = cache.fileURL(for: OpenAISpeechEngine.request(for: input, voice: voice))
                if files.sizes[url.lastPathComponent] != nil { urls.append(url) }
            }
        }
        return urls
    }

    /// How the whole audio folder is used by `library` (each article's blocks), with `voice` being the one chosen.
    static func usage(of library: [[ContentBlock]], voice: String, cache: SpeechAudioCache) -> LibraryAudioUsage {
        let files = AudioFiles(cache)
        var usage = LibraryAudioUsage()
        usage.totalBytes = files.sizes.values.reduce(0, +)

        var inputs = library.reduce(into: Set<String>()) { $0.formUnion(Self.inputs(of: $1)) }
        for blocks in library {
            for piece in pieces(of: blocks, voice: voice) {
                usage.totalCharacters += piece.characters
                if files.sizes[cache.fileURL(for: piece.request).lastPathComponent] == nil {
                    usage.missingCharacters += piece.characters
                    usage.missingPieces += 1
                }
            }
        }
        inputs.insert(sampleText)

        var used = Set<String>()
        for input in inputs {
            for other in OpenAISpeechEngine.voices {
                let name = cache.fileURL(for: OpenAISpeechEngine.request(for: input, voice: other)).lastPathComponent
                guard let size = files.sizes[name], used.insert(name).inserted else { continue }
                if other == voice {
                    usage.voiceBytes += size
                } else if input != sampleText {
                    usage.otherVoiceFiles.append(cache.directory.appending(path: name))
                    usage.otherVoiceBytes += size
                }
            }
        }
        for (name, size) in files.sizes where !used.contains(name) {
            usage.unusedFiles.append(cache.directory.appending(path: name))
            usage.unusedBytes += size
        }
        return usage
    }

    // MARK: - Off the main actor
    // Articles come as their `blocksData`: decoding and hashing a long library takes a moment.

    @concurrent
    static func status(ofBlocksData data: Data, voice: String, cache: SpeechAudioCache = .standard) async -> ArticleAudioStatus {
        status(of: Article.decodeBlocks(data), voice: voice, cache: cache)
    }

    /// How much of each article has audio in `voice`, 0 to 1.
    @concurrent
    static func fractions(
        of articles: [(id: PersistentIdentifier, blocksData: Data)], voice: String, cache: SpeechAudioCache = .standard
    ) async -> [PersistentIdentifier: Double] {
        var fractions: [PersistentIdentifier: Double] = [:]
        for article in articles {
            fractions[article.id] = status(of: Article.decodeBlocks(article.blocksData), voice: voice, cache: cache).fraction
        }
        return fractions
    }

    @concurrent
    static func usage(ofBlocksData library: [Data], voice: String, cache: SpeechAudioCache = .standard) async -> LibraryAudioUsage {
        usage(of: library.map(Article.decodeBlocks), voice: voice, cache: cache)
    }

    /// Deletes the audio of `removed` articles that the `keeping` ones don't share. Returns the bytes freed.
    @concurrent
    @discardableResult
    static func removeAudio(of removed: [Data], keeping: [Data], cache: SpeechAudioCache = .standard) async -> Int64 {
        let kept = keeping.map(Article.decodeBlocks)
        let urls = removed.flatMap { files(of: Article.decodeBlocks($0), notUsedBy: kept, cache: cache) }
        return remove(Array(Set(urls)))
    }

    @concurrent
    @discardableResult
    static func removeFiles(_ urls: [URL]) async -> Int64 {
        remove(urls)
    }

    // MARK: - Files

    /// Deletes files from the audio folder; ones already gone are skipped. Returns the bytes freed.
    @discardableResult
    static func remove(_ urls: [URL]) -> Int64 {
        var freed: Int64 = 0
        for url in urls {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }

    /// The audio folder's files the app wrote (`<sha256>.mp3`), by name, with their sizes.
    private struct AudioFiles {
        var sizes: [String: Int64] = [:]

        init(_ cache: SpeechAudioCache) {
            let urls = (try? FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls where LibraryBackup.isCacheFileName(url.lastPathComponent, extension: OpenAITTSClient.audioFormat) {
                sizes[url.lastPathComponent] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }
}

/// An article's OpenAI audio in one voice: how much of it is on disk.
nonisolated struct ArticleAudioStatus: Sendable {
    var voice: String
    var totalPieces = 0
    var cachedPieces = 0
    /// Characters of each block, and how many of them have audio.
    var blockCharacters: [Int]
    var cachedBlockCharacters: [Int]
    /// The voice's files for this article.
    var bytes: Int64 = 0
    /// The article's files in the other voices.
    var otherVoiceBytes: Int64 = 0
    /// Pieces without audio yet, in reading order.
    var missing: [ArticleAudio.Piece] = []

    var totalCharacters: Int { blockCharacters.reduce(0, +) }
    var cachedCharacters: Int { cachedBlockCharacters.reduce(0, +) }
    var missingCharacters: Int { totalCharacters - cachedCharacters }
    var isComplete: Bool { missing.isEmpty }

    /// 0 to 1, by length of text rather than by piece, so it tracks minutes of audio.
    var fraction: Double {
        totalCharacters > 0 ? Double(cachedCharacters) / Double(totalCharacters) : 0
    }

    /// How much of `blocks` has audio, 0 to 1 (1 for blocks with no text).
    func fraction(ofBlocks blocks: Range<Int>) -> Double {
        let range = blocks.clamped(to: blockCharacters.indices)
        let total = blockCharacters[range].reduce(0, +)
        return total > 0 ? Double(cachedBlockCharacters[range].reduce(0, +)) / Double(total) : 1
    }
}

/// How the audio folder is used across the library.
nonisolated struct LibraryAudioUsage: Sendable {
    /// Everything in the audio folder.
    var totalBytes: Int64 = 0
    /// The library's audio in the chosen voice (voice samples included).
    var voiceBytes: Int64 = 0
    /// The library's audio in the other voices.
    var otherVoiceFiles: [URL] = []
    var otherVoiceBytes: Int64 = 0
    /// Audio no saved article reads any more: left behind by deleted articles, or by text that changed.
    var unusedFiles: [URL] = []
    var unusedBytes: Int64 = 0
    /// The library's text, and the part of it with no audio yet in the chosen voice.
    var totalCharacters = 0
    var missingCharacters = 0
    var missingPieces = 0
}
