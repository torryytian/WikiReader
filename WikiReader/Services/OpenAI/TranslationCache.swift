import CryptoKit
import Foundation

/// Translations on disk, one file per (model, text), so the same passage is never translated or paid
/// for twice and stays readable offline. Under Application Support, like the speech audio, so the
/// system can't purge it.
nonisolated struct TranslationCache: Sendable {
    let directory: URL

    static let standard = TranslationCache(
        directory: URL.applicationSupportDirectory.appending(path: "Translations", directoryHint: .isDirectory)
    )

    static func key(for text: String) -> String {
        let identity = [OpenAIChatClient.model, OpenAITranslateClient.clipped(text)].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func fileURL(for text: String) -> URL {
        directory.appending(path: Self.key(for: text) + ".json")
    }

    func cached(for text: String) -> PassageTranslation? {
        guard let data = try? Data(contentsOf: fileURL(for: text)) else { return nil }
        return try? JSONDecoder().decode(PassageTranslation.self, from: data)
    }

    /// Writes atomically, so a crash mid-write never leaves a truncated file that looks cached.
    func store(_ translation: PassageTranslation, for text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(translation).write(to: fileURL(for: text), options: .atomic)
    }
}
