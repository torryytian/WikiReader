import Foundation
import Testing
@testable import WikiReader

struct OpenAITranslateClientTests {
    private let passage = "The pilots lost contact with air traffic control."

    private func reply(content: String) -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return String(decoding: json, as: UTF8.self)
    }

    private static let translationJSON = """
        {"translation":"飞行员与空中交通管制失去了联系。",\
        "notes":[{"expression":"lost contact","explanation":"失去联系"}]}
        """

    private func client(status: Int = 200, body: String = "", error: (any Error)? = nil) -> OpenAITranslateClient {
        OpenAITranslateClient { request in
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test func requestSendsOnlyThePassage() throws {
        let request = OpenAITranslateClient.urlRequest(text: passage, apiKey: "sk-test")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == passage)
    }

    @Test func longTextIsClipped() {
        let long = String(repeating: "a", count: OpenAITranslateClient.maxLength + 500)
        #expect(OpenAITranslateClient.clipped(long).count == OpenAITranslateClient.maxLength)
        #expect(OpenAITranslateClient.clipped(passage) == passage)
    }

    @Test func schemaRequiresEveryProperty() throws {
        let schema = OpenAITranslateClient.replySchema
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(try #require(schema["required"] as? [String])) == Set(properties.keys))
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func successParsesTranslationAndNotes() async throws {
        let result = try await client(body: reply(content: Self.translationJSON)).translate(passage, apiKey: "k")
        #expect(result.translation == "飞行员与空中交通管制失去了联系。")
        #expect(result.notes == [PassageTranslation.Note(expression: "lost contact", explanation: "失去联系")])
    }

    @Test func missingKeyFailsWithoutRequest() async {
        let client = OpenAITranslateClient { _ in
            Issue.record("No request should be sent without a key")
            throw URLError(.cancelled)
        }
        await #expect(throws: OpenAIChatError.missingKey) { try await client.translate(passage, apiKey: "") }
    }

    @Test func failuresMapToErrors() async {
        await #expect(throws: OpenAIChatError.invalidKey) {
            try await client(status: 401, body: #"{"error":{"message":"Incorrect API key"}}"#).translate(passage, apiKey: "k")
        }
        await #expect(throws: OpenAIChatError.timedOut) {
            try await client(error: URLError(.timedOut)).translate(passage, apiKey: "k")
        }
        await #expect(throws: OpenAIChatError.badResponse) {
            try await client(body: "nonsense").translate(passage, apiKey: "k")
        }
    }
}

struct TranslationCacheTests {
    private func makeCache() -> TranslationCache {
        TranslationCache(directory: FileManager.default.temporaryDirectory.appending(path: "translations-\(UUID().uuidString)"))
    }

    private let translation = PassageTranslation(translation: "你好", notes: [.init(expression: "hello", explanation: "问候")])

    @Test func storedTranslationIsFoundAgain() throws {
        let cache = makeCache()
        #expect(cache.cached(for: "Hello") == nil)
        try cache.store(translation, for: "Hello")
        #expect(cache.cached(for: "Hello") == translation)
        #expect(cache.cached(for: "Hello there") == nil)
    }

    @Test func differentTextsHaveDifferentKeys() {
        #expect(TranslationCache.key(for: "a") != TranslationCache.key(for: "b"))
        #expect(TranslationCache.key(for: "a") == TranslationCache.key(for: "a"))
    }

    @Test func corruptFileCountsAsNotCached() throws {
        let cache = makeCache()
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cache.fileURL(for: "Hello"))
        #expect(cache.cached(for: "Hello") == nil)
    }
}

@MainActor
struct PassageTranslationModelTests {
    private let translation = PassageTranslation(translation: "你好", notes: [])

    private func cache() -> TranslationCache {
        TranslationCache(directory: FileManager.default.temporaryDirectory.appending(path: "translations-\(UUID().uuidString)"))
    }

    private func waitForResult(_ model: PassageTranslationModel) async throws {
        for _ in 0..<100 where model.state == .loading { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func cachedTranslationNeedsNeitherKeyNorNetwork() throws {
        let cache = cache()
        try cache.store(translation, for: "Hello")
        let client = OpenAITranslateClient { _ in
            Issue.record("A cached translation must not be requested again")
            throw URLError(.cancelled)
        }
        let model = PassageTranslationModel(text: "Hello", client: client, cache: cache, apiKey: { nil })
        model.load()
        #expect(model.state == .loaded(translation))
    }

    @Test func withoutKeyOrCacheItFailsAndSendsNothing() {
        let client = OpenAITranslateClient { _ in
            Issue.record("No request should be sent without a key")
            throw URLError(.cancelled)
        }
        let model = PassageTranslationModel(text: "Hello", client: client, cache: cache(), apiKey: { nil })
        model.load()
        #expect(model.state == .failed(.missingKey))
    }

    @Test func freshTranslationIsCachedForNextTime() async throws {
        let content = #"{"translation":"你好","notes":[]}"#
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), as: UTF8.self)
        let client = OpenAITranslateClient { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let cache = cache()
        let model = PassageTranslationModel(text: "Hello", client: client, cache: cache, apiKey: { "k" })
        model.load()
        try await waitForResult(model)
        #expect(model.state == .loaded(translation))
        #expect(cache.cached(for: "Hello") == translation)
    }

    @Test func clippedFlagFollowsLength() {
        #expect(!PassageTranslationModel(text: "short").isClipped)
        #expect(PassageTranslationModel(text: String(repeating: "a", count: OpenAITranslateClient.maxLength + 1)).isClipped)
    }
}
