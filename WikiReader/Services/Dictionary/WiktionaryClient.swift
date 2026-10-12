import CryptoKit
import Foundation

/// English definitions of a word from Wiktionary, trimmed for display.
nonisolated struct WiktionaryDefinition: Codable, Equatable, Sendable {
    struct Sense: Codable, Equatable, Sendable {
        var text: String
        var example: String?
    }
    struct Group: Codable, Equatable, Sendable {
        var partOfSpeech: String
        var senses: [Sense]
    }

    var word: String
    var groups: [Group]
}

nonisolated enum WiktionaryError: Error, Equatable {
    /// Wiktionary has no English entry for the word.
    case notFound
    case timedOut
    case network(description: String)
    case httpStatus(Int)
    case badResponse
}

/// Asks en.wiktionary.org for the English definitions of one word, only when the word card opens.
///
/// Only the word is sent, never the sentence. Wiktionary is Wikimedia's, like Wikipedia, so the same
/// User-Agent applies. (dictionaryapi.dev was tried first: its server was timing out on every word it
/// hadn't cached, answering 522 after ~20 s.)
nonisolated struct WiktionaryClient: Sendable {
    static let maxGroups = 6
    static let maxSensesPerGroup = 4

    /// Gives up fast: the word card already shows the offline entry, and this part is a bonus.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration)
    }()

    var session: URLSession = defaultSession

    @concurrent
    func definition(of word: String) async throws(WiktionaryError) -> WiktionaryDefinition {
        var request = URLRequest(url: Self.requestURL(forWord: word))
        request.setValue(WikipediaClient.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw .timedOut
        } catch {
            throw .network(description: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw .notFound }
            if !(200..<300).contains(http.statusCode) { throw .httpStatus(http.statusCode) }
        }
        return try Self.parse(data, word: word)
    }

    static func requestURL(forWord word: String) -> URL {
        var components = URLComponents(string: "https://en.wiktionary.org/api/rest_v1/page/definition")!
        // The word is a path segment; "/" and "?" inside it must be escaped too.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        components.percentEncodedPath += "/" + (word.addingPercentEncoding(withAllowedCharacters: allowed) ?? word)
        return components.url!
    }

    /// The response maps language codes to entries; only English is used.
    static func parse(_ data: Data, word: String) throws(WiktionaryError) -> WiktionaryDefinition {
        let decoded: [String: [RawEntry]]
        do {
            decoded = try JSONDecoder().decode([String: [RawEntry]].self, from: data)
        } catch {
            throw .badResponse
        }
        var groups: [WiktionaryDefinition.Group] = []
        for entry in decoded["en"] ?? [] where groups.count < maxGroups {
            var senses: [WiktionaryDefinition.Sense] = []
            for definition in entry.definitions where senses.count < maxSensesPerGroup {
                let text = ArticleHTMLParser.plainText(fromHTML: definition.definition)
                guard !text.isEmpty, !senses.contains(where: { $0.text == text }) else { continue }
                let example = definition.parsedExamples?.first
                    .map { ArticleHTMLParser.plainText(fromHTML: $0.example) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                senses.append(.init(text: text, example: example))
            }
            if !senses.isEmpty { groups.append(.init(partOfSpeech: entry.partOfSpeech, senses: senses)) }
        }
        guard !groups.isEmpty else { throw .notFound }
        return WiktionaryDefinition(word: word, groups: groups)
    }

    private struct RawEntry: Decodable {
        struct Definition: Decodable {
            struct Example: Decodable { var example: String }
            var definition: String
            var parsedExamples: [Example]?
        }
        var partOfSpeech: String
        var definitions: [Definition]
    }
}

/// Wiktionary answers on disk, one file per word, so a word seen once reads offline afterwards.
/// Under Application Support, like the other caches, so the system can't purge it.
nonisolated struct DefinitionCache: Sendable {
    let directory: URL

    static let standard = DefinitionCache(
        directory: URL.applicationSupportDirectory.appending(path: "Definitions", directoryHint: .isDirectory)
    )

    func fileURL(for word: String) -> URL {
        let key = SHA256.hash(data: Data(word.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: key + ".json")
    }

    func cached(for word: String) -> WiktionaryDefinition? {
        guard let data = try? Data(contentsOf: fileURL(for: word)) else { return nil }
        return try? JSONDecoder().decode(WiktionaryDefinition.self, from: data)
    }

    /// Writes atomically, so a crash mid-write never leaves a truncated file that looks cached.
    func store(_ definition: WiktionaryDefinition, for word: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(definition).write(to: fileURL(for: word), options: .atomic)
    }
}
