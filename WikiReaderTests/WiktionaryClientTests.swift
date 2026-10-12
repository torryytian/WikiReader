import Foundation
import Testing
@testable import WikiReader

/// Answers every request with a fixed status and body, without touching the network.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var mimeType = "application/json"
    nonisolated(unsafe) static var failure: URLError.Code?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let code = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": Self.mimeType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session(status: Int = 200, body: Data = Data(), mimeType: String = "application/json", failure: URLError.Code? = nil) -> URLSession {
        self.status = status
        self.body = body
        self.mimeType = mimeType
        self.failure = failure
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized)
struct WiktionaryClientTests {
    @Test func requestURLEscapesTheWord() {
        #expect(WiktionaryClient.requestURL(forWord: "shirk").absoluteString == "https://en.wiktionary.org/api/rest_v1/page/definition/shirk")
        let tricky = WiktionaryClient.requestURL(forWord: "a/b?c#d e").absoluteString
        #expect(tricky.hasPrefix("https://en.wiktionary.org/api/rest_v1/page/definition/a%2Fb%3Fc%23d%20e"))
    }

    @Test func parsesDefinitionsAndStripsMarkup() throws {
        let definition = try WiktionaryClient.parse(Fixture.data("wiktionary_shirk"), word: "shirk")
        #expect(definition.word == "shirk")
        let verb = try #require(definition.groups.first { $0.partOfSpeech == "Verb" })
        #expect(verb.senses.first?.text == "To avoid, especially a duty, responsibility, etc.; to stay away from.")
        for group in definition.groups {
            #expect(group.senses.count <= WiktionaryClient.maxSensesPerGroup)
            for sense in group.senses {
                #expect(!sense.text.contains("<") && !sense.text.contains("&amp;") && !sense.text.contains("  "))
            }
        }
        #expect(definition.groups.count <= WiktionaryClient.maxGroups)
    }

    @Test func inflectedWordParses() throws {
        let definition = try WiktionaryClient.parse(Fixture.data("wiktionary_studies"), word: "studies")
        #expect(!definition.groups.isEmpty)
    }

    @Test func responseWithoutEnglishEntriesIsNotFound() {
        #expect(throws: WiktionaryError.notFound) { try WiktionaryClient.parse(Data("{}".utf8), word: "x") }
        #expect(throws: WiktionaryError.notFound) { try WiktionaryClient.parse(Data(#"{"de":[{"partOfSpeech":"Noun","definitions":[{"definition":"x"}]}]}"#.utf8), word: "x") }
    }

    @Test func garbageIsABadResponse() throws {
        #expect(throws: WiktionaryError.badResponse) { try WiktionaryClient.parse(Data("<html>".utf8), word: "x") }
        #expect(throws: WiktionaryError.badResponse) { try WiktionaryClient.parse(Fixture.data("wiktionary_missing"), word: "x") }
    }

    @Test func examplesAreKeptWhenPresent() throws {
        let json = #"{"en":[{"partOfSpeech":"Noun","language":"English","definitions":[{"definition":"A <b>thing</b> &amp; more.","parsedExamples":[{"example":"See <i>this</i> thing."}]}]}]}"#
        let definition = try WiktionaryClient.parse(Data(json.utf8), word: "thing")
        #expect(definition.groups == [.init(partOfSpeech: "Noun", senses: [.init(text: "A thing & more.", example: "See this thing.")])])
    }

    @Test func fetchSendsTheUserAgentAndMapsStatuses() async throws {
        let ok = try Fixture.data("wiktionary_shirk")
        var client = WiktionaryClient(session: StubURLProtocol.session(body: ok))
        let definition = try await client.definition(of: "shirk")
        #expect(!definition.groups.isEmpty)
        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent") == WikipediaClient.userAgent)

        client = WiktionaryClient(session: StubURLProtocol.session(status: 404, body: Data(#"{"status":404}"#.utf8)))
        await #expect(throws: WiktionaryError.notFound) { try await client.definition(of: "zzz") }
        client = WiktionaryClient(session: StubURLProtocol.session(status: 503))
        await #expect(throws: WiktionaryError.httpStatus(503)) { try await client.definition(of: "zzz") }
        client = WiktionaryClient(session: StubURLProtocol.session(failure: .timedOut))
        await #expect(throws: WiktionaryError.timedOut) { try await client.definition(of: "zzz") }
    }

    @Test func defaultSessionGivesUpQuickly() {
        let configuration = WiktionaryClient.defaultSession.configuration
        #expect(configuration.timeoutIntervalForRequest <= 10)
        #expect(configuration.timeoutIntervalForResource <= 20)
    }

    @Test func definitionCacheRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "defs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DefinitionCache(directory: directory)
        let definition = WiktionaryDefinition(word: "Shirk", groups: [.init(partOfSpeech: "Verb", senses: [.init(text: "To avoid.", example: nil)])])
        #expect(cache.cached(for: "shirk") == nil)
        try cache.store(definition, for: "Shirk")
        #expect(cache.cached(for: "shirk") == definition)   // not case sensitive
        #expect(cache.cached(for: "other") == nil)
    }

    // MARK: - Recordings

    @Test func recordingURLFollowsCommonsDirectoryLayout() {
        #expect(WordAudioClient.recordingURL(for: "Shirk")?.absoluteString
            == "https://upload.wikimedia.org/wikipedia/commons/transcoded/e/e4/En-us-shirk.ogg/En-us-shirk.ogg.mp3")
        #expect(WordAudioClient.recordingURL(for: "famine")?.absoluteString
            == "https://upload.wikimedia.org/wikipedia/commons/transcoded/7/7d/En-us-famine.ogg/En-us-famine.ogg.mp3")
    }

    @Test func recordingURLRefusesWhatIsNotAPlainWord() {
        for term in ["", "  ", "a/b", "x?y", "../etc", "2024", "it's"] {
            #expect(WordAudioClient.recordingURL(for: term) == nil, "\(term)")
        }
        #expect(WordAudioClient.recordingURL(for: "self-criticism") != nil)
    }

    @Test func recordingIsFetchedOnceThenReadFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mp3 = Data([0x49, 0x44, 0x33, 1, 2, 3])
        var client = WordAudioClient(cacheDirectory: directory, session: StubURLProtocol.session(body: mp3, mimeType: "audio/mpeg"))
        #expect(await client.recording(for: "shirk") == mp3)
        #expect(StubURLProtocol.requests.count == 1)
        // Offline now: the second call must not need the network.
        client = WordAudioClient(cacheDirectory: directory, session: StubURLProtocol.session(failure: .notConnectedToInternet))
        #expect(await client.recording(for: "shirk") == mp3)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func missingRecordingIsNilAndNotCached() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (status, mime) in [(404, "text/html"), (429, "text/html"), (200, "text/html")] {
            let client = WordAudioClient(cacheDirectory: directory, session: StubURLProtocol.session(status: status, body: Data("x".utf8), mimeType: mime))
            #expect(await client.recording(for: "comrade") == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
