import CryptoKit
import Foundation

/// Generated speech audio on disk, one file per (model, voice, instructions, text), so the same
/// text is never generated or paid for twice and can be played offline later.
///
/// Stored under Application Support rather than Caches, which iOS may purge, losing offline audio.
nonisolated struct SpeechAudioCache: Sendable {
    let directory: URL

    static let standard = SpeechAudioCache(
        directory: URL.applicationSupportDirectory.appending(path: "SpeechAudio", directoryHint: .isDirectory)
    )

    static func key(for request: OpenAISpeechRequest) -> String {
        // Fields joined with a separator that can't appear in them, so different splits can't collide.
        let identity = [request.model, request.voice, request.instructions ?? "", request.input].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func fileURL(for request: OpenAISpeechRequest) -> URL {
        directory.appending(path: Self.key(for: request) + "." + OpenAITTSClient.audioFormat)
    }

    func cachedFile(for request: OpenAISpeechRequest) -> URL? {
        let url = fileURL(for: request)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Writes atomically, so a crash mid-write never leaves a truncated file that looks cached.
    @discardableResult
    func store(_ audio: Data, for request: OpenAISpeechRequest) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: request)
        try audio.write(to: url, options: .atomic)
        return url
    }

    /// Total size of cached audio, in bytes.
    func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
