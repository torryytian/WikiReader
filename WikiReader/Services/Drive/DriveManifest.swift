import CryptoKit
import Foundation

/// `articles/<urlHash>.json` in the shared Drive folder: an article's text as it is read aloud, piece by piece, with
/// each piece's audio key. The Chrome extension plays straight from it (docs/shared-tts-cache-format.md §3), so it
/// lists every piece, with or without audio yet.
nonisolated struct DriveManifest: Codable, Equatable, Sendable {
    struct Chunk: Codable, Equatable, Sendable {
        /// Position among all pieces of the article.
        var i: Int
        /// The block the piece belongs to.
        var p: Int
        var text: String
        var key: String
        /// `heading` or `paragraph`: the extension pauses after headings, as the app does.
        var kind: String?
        var level: Int?
    }

    static let chunkerName = "ios-paragraph-4096"

    var formatVersion = 1
    var chunker = DriveManifest.chunkerName
    var url: String
    var title: String
    var model: String
    var voice: String
    var instructions: String
    var chunks: [Chunk]
    /// Whether every piece's audio is on Drive.
    var complete: Bool
    var updatedAt: String
    var updatedBy = "ios"

    init(title: String, url: String, blocks: [ContentBlock], voice: String, complete: Bool = false, updatedAt: Date = .now) {
        self.title = title
        self.url = url
        model = OpenAISpeechEngine.model
        self.voice = voice
        instructions = OpenAISpeechEngine.instructions
        chunks = []
        for (index, block) in blocks.enumerated() {
            let text = block.text as NSString
            for range in SpeechChunking.chunks(of: block.text) {
                let piece = text.substring(with: range)
                chunks.append(Chunk(
                    i: chunks.count, p: index, text: piece,
                    key: SpeechAudioCache.key(for: OpenAISpeechEngine.request(for: piece, voice: voice)),
                    kind: block.kind.rawValue, level: block.level
                ))
            }
        }
        self.complete = complete
        self.updatedAt = ISO8601DateFormatter().string(from: updatedAt)
    }

    var keys: [String] { chunks.map(\.key) }

    /// `lowercase_hex(SHA-256(url))`, the manifest's file name without `.json`.
    static func urlHash(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var fileName: String { Self.urlHash(url) + ".json" }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// A digest of everything but `updatedAt`: two manifests with the same digest say the same thing.
    var contentDigest: String {
        var copy = self
        copy.updatedAt = ""
        return SHA256.hash(data: copy.encoded()).map { String(format: "%02x", $0) }.joined()
    }

    /// The same manifest apart from when it was written: whether writing it again would change anything.
    func sameContent(as other: DriveManifest) -> Bool {
        var a = self, b = other
        a.updatedAt = ""
        b.updatedAt = ""
        return a == b
    }
}
