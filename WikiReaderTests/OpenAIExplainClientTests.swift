import Foundation
import Testing
@testable import WikiReader

struct OpenAIExplainClientTests {
    private let word = "contact"
    private let sentence = "The pilots lost contact with air traffic control."

    /// A chat completion whose message content is `content` (itself a JSON string, as the API sends it).
    private func reply(content: String?) -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content as Any]]]])
        return String(decoding: json, as: UTF8.self)
    }

    private static let explanationJSON = """
        {"partOfSpeech":"noun","meaning":"联系；通信","explanation":"这里指和某人保持沟通。",\
        "sentenceTranslation":"飞行员与空中交通管制失去了联系。",\
        "examples":[{"english":"Keep in contact.","chinese":"保持联系。"},\
        {"english":"Eye contact matters.","chinese":"眼神接触很重要。"},\
        {"english":"I have no contact with him.","chinese":"我和他没有联系。"}]}
        """

    private func client(status: Int, body: String = "", error: (any Error)? = nil) -> OpenAIExplainClient {
        OpenAIExplainClient { request in
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func explain(with client: OpenAIExplainClient, key: String = "k") async throws(OpenAIExplainError) -> WordExplanation {
        try await client.explain(word: word, sentence: sentence, apiKey: key)
    }

    // MARK: - Request

    @Test func requestShape() throws {
        let request = OpenAIExplainClient.urlRequest(word: word, sentence: sentence, apiKey: "sk-test")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == OpenAIExplainClient.model)

        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["strict"] as? Bool == true)
    }

    @Test func userMessageHasWordAndSentenceOnly() throws {
        let body = try #require(OpenAIExplainClient.urlRequest(word: word, sentence: sentence, apiKey: "k").httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "Word: contact\nSentence: The pilots lost contact with air traffic control.")
    }

    @Test func veryLongSentenceIsCut() {
        let long = String(repeating: "word ", count: 500)
        let prompt = OpenAIExplainClient.userPrompt(word: "word", sentence: long)
        #expect(prompt.count <= "Word: word\nSentence: ".count + OpenAIExplainClient.maxSentenceLength)
    }

    @Test func schemaRequiresEveryProperty() throws {
        // Structured Outputs' strict mode needs every property listed as required.
        let schema = OpenAIExplainClient.replySchema
        let properties = try #require(schema["properties"] as? [String: Any])
        let required = try #require(schema["required"] as? [String])
        #expect(Set(required) == Set(properties.keys))
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    // MARK: - Reply

    @Test func successParsesExplanation() async throws {
        let explanation = try await explain(with: client(status: 200, body: reply(content: Self.explanationJSON)))
        #expect(explanation.partOfSpeech == "noun")
        #expect(explanation.meaning == "联系；通信")
        #expect(explanation.examples.count == 3)
        #expect(explanation.examples[0] == WordExplanation.Example(english: "Keep in contact.", chinese: "保持联系。"))
    }

    @Test(arguments: [
        "not json at all",
        #"{"choices":[]}"#,
        #"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."}}]}"#,
        #"{"choices":[{"message":{"content":"{\"meaning\":\"only one field\"}"}}]}"#,
    ])
    func unusableReplyIsBadResponse(body: String) async {
        await #expect(throws: OpenAIExplainError.badResponse) { try await explain(with: client(status: 200, body: body)) }
    }

    // MARK: - Failures

    @Test func missingKeyFailsWithoutRequest() async {
        let client = OpenAIExplainClient { _ in
            Issue.record("No request should be sent without a key")
            throw URLError(.cancelled)
        }
        await #expect(throws: OpenAIExplainError.missingKey) { try await explain(with: client, key: "") }
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"Incorrect API key","code":"invalid_api_key"}}"#, OpenAIExplainError.invalidKey),
        (429, #"{"error":{"message":"You exceeded your quota","code":"insufficient_quota"}}"#, .quotaExceeded),
        (429, #"{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}"#, .rateLimited),
        (404, #"{"error":{"message":"The model does not exist"}}"#, .badRequest("The model does not exist")),
        (503, "", .server(status: 503)),
    ])
    func errorResponses(status: Int, body: String, expected: OpenAIExplainError) async {
        await #expect(throws: expected) { try await explain(with: client(status: status, body: body)) }
    }

    @Test func timeoutAndNetworkFailures() async {
        await #expect(throws: OpenAIExplainError.timedOut) {
            try await explain(with: client(status: 0, error: URLError(.timedOut)))
        }
        await #expect(throws: OpenAIExplainError.network(URLError(.notConnectedToInternet).localizedDescription)) {
            try await explain(with: client(status: 0, error: URLError(.notConnectedToInternet)))
        }
    }

    @Test func messagesNeverContainTheKeyAndRetryMatchesTheCause() {
        let errors: [OpenAIExplainError] = [
            .missingKey, .invalidKey, .quotaExceeded, .rateLimited, .badRequest("x"),
            .server(status: 500), .network("x"), .timedOut, .badResponse,
        ]
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains("sk-"))
        }
        // Retrying can't fix a key or credit problem, only transient ones.
        #expect(!OpenAIExplainError.missingKey.isRetryable)
        #expect(!OpenAIExplainError.invalidKey.isRetryable)
        #expect(OpenAIExplainError.timedOut.isRetryable)
    }
}

@MainActor
struct WordExplanationModelTests {
    private func model(key: String?, client: OpenAIExplainClient) -> WordExplanationModel {
        WordExplanationModel(word: "contact", sentence: "Lost contact.", client: client, apiKey: { key })
    }

    @Test func withoutKeyItFailsImmediatelyAndSendsNothing() {
        let client = OpenAIExplainClient { _ in
            Issue.record("No request should be sent without a key")
            throw URLError(.cancelled)
        }
        let model = model(key: nil, client: client)
        model.load()
        #expect(model.state == .failed(.missingKey))
    }

    @Test func loadsExplanation() async throws {
        let content = #"{"partOfSpeech":"noun","meaning":"联系","explanation":"x","sentenceTranslation":"y","examples":[]}"#
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), as: UTF8.self)
        let client = OpenAIExplainClient { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let model = model(key: "k", client: client)
        #expect(model.state == .loading)
        model.load()
        for _ in 0..<100 where model.state == .loading { try await Task.sleep(for: .milliseconds(20)) }
        guard case .loaded(let explanation) = model.state else {
            Issue.record("Expected a loaded explanation, got \(model.state)")
            return
        }
        #expect(explanation.meaning == "联系")
    }
}
