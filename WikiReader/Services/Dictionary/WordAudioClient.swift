import CryptoKit
import Foundation

/// Human recordings of single words from Wikimedia Commons ("En-us-shirk.ogg", American English).
///
/// Commons keeps a ready-made MP3 next to each Ogg file, and iOS can't play Ogg Vorbis, so the MP3 is
/// fetched. Many common words have a recording; plenty (e.g. "comrade") don't, and then the caller
/// falls back to the on-device voice. Only the word is sent, and only when the speaker button is pressed.
nonisolated struct WordAudioClient: Sendable {
    let cacheDirectory: URL
    var session: URLSession = defaultSession

    static let standard = WordAudioClient(
        cacheDirectory: URL.applicationSupportDirectory.appending(path: "WordAudio", directoryHint: .isDirectory)
    )

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration)
    }()

    /// The MP3 transcode of the American recording of a word, e.g. for "Shirk":
    /// `…/commons/transcoded/<m>/<md>/En-us-shirk.ogg/En-us-shirk.ogg.mp3`, where `<m>` and `<md>` are the first one
    /// and two hex digits of the MD5 of the file name (how Commons spreads files over directories).
    static func recordingURL(for word: String) -> URL? {
        let normalized = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        // Only plain words: Commons file names with punctuation need more escaping than is worth getting wrong.
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) else { return nil }
        let file = "En-us-\(normalized).ogg"
        let hash = Insecure.MD5.hash(data: Data(file.utf8)).map { String(format: "%02x", $0) }.joined()
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return URL(string: "https://upload.wikimedia.org/wikipedia/commons/transcoded/\(hash.prefix(1))/\(hash.prefix(2))/\(encoded)/\(encoded).mp3")
    }

    func cacheURL(for word: String) -> URL {
        let key = SHA256.hash(data: Data(word.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appending(path: key + ".mp3")
    }

    /// The recording, from disk if it was fetched before; nil when there is none or the network fails.
    @concurrent
    func recording(for word: String) async -> Data? {
        if let data = try? Data(contentsOf: cacheURL(for: word)), !data.isEmpty { return data }
        guard let url = Self.recordingURL(for: word) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(WikipediaClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (response.mimeType ?? "").hasPrefix("audio"), !data.isEmpty
        else { return nil }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(for: word), options: .atomic)
        return data
    }
}
