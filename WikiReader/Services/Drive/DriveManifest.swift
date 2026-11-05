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

    /// How to write a manifest where Drive already has a file of that name (docs/shared-drive-layout.md §3).
    enum Write: Equatable, Sendable {
        /// Drive's is for another voice (its text is what that audio was made from), or in a newer format: left alone.
        case leave
        /// The file's new contents: Drive's, with this app's fields written over it and every other field kept.
        case replace(Data)
        /// Drive's says the article was deleted: a new file with this instead.
        case create(Data)
    }

    static func write(_ manifest: DriveManifest, over existing: Data) -> Write {
        let ours = manifest.encoded()
        guard let theirs = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return .replace(ours) }
        if theirs["deleted"] as? Bool == true { return .create(ours) }
        if let version = theirs["formatVersion"] as? Int, version > manifest.formatVersion { return .leave }
        guard theirs["model"] as? String == manifest.model, theirs["voice"] as? String == manifest.voice,
              theirs["instructions"] as? String == manifest.instructions else { return .leave }
        var merged = theirs
        for (key, value) in (try? JSONSerialization.jsonObject(with: ours) as? [String: Any]) ?? [:] {
            merged[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return .replace(ours) }
        return .replace(data)
    }

    /// The Drive file's public properties: for people and the other apps to recognise it; lookups go by file name.
    /// - Parameter kind: `wikipedia` or `imported` (an article imported from a file on this iPhone).
    func driveProperties(kind: String) -> [String: String] {
        ["articleId": Self.urlHash(url), "title": Self.propertyValue(title, key: "title"), "kind": kind]
    }

    /// `value` cut to fit Drive's limit of 124 bytes of UTF-8 for a property's key and value together.
    static func propertyValue(_ value: String, key: String) -> String {
        var room = 124 - key.utf8.count
        var result = ""
        for character in value {
            let size = String(character).utf8.count
            guard size <= room else { break }
            result.append(character)
            room -= size
        }
        return result
    }

    /// The same manifest apart from when it was written: whether writing it again would change anything.
    func sameContent(as other: DriveManifest) -> Bool {
        var a = self, b = other
        a.updatedAt = ""
        b.updatedAt = ""
        return a == b
    }
}
