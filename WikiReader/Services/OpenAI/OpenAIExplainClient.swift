import Foundation

/// What the AI says about a word as it is used in its sentence. Decoded from the model's JSON reply,
/// so the field names are the schema's property names.
nonisolated struct WordExplanation: Codable, Equatable, Sendable {
    struct Example: Codable, Equatable, Sendable {
        var english: String
        var chinese: String
    }

    /// e.g. "noun".
    var partOfSpeech: String
    /// A short Chinese gloss of the word in this sentence.
    var meaning: String
    /// A few Chinese sentences on nuance and usage.
    var explanation: String
    var sentenceTranslation: String
    var examples: [Example]
}

nonisolated enum OpenAIExplainError: Error, Equatable {
    case missingKey
    case invalidKey
    case quotaExceeded
    case rateLimited
    case badRequest(String)
    case server(status: Int)
    case network(String)
    case timedOut
    case badResponse

    /// Shown to the user under the word.
    var message: String {
        switch self {
        case .missingKey: "No OpenAI API key. Add one in Settings → Voice."
        case .invalidKey: "The OpenAI API key was rejected. Check it in Settings → Voice."
        case .quotaExceeded: "Your OpenAI account has no remaining credit."
        case .rateLimited: "OpenAI is rate limiting requests. Try again in a moment."
        case .badRequest(let detail): "OpenAI rejected the request: \(detail)"
        case .server(let status): "OpenAI had a problem (HTTP \(status)). Try again later."
        case .network(let detail): "Couldn't reach OpenAI: \(detail)"
        case .timedOut: "OpenAI didn't answer in time. Try again."
        case .badResponse: "OpenAI returned an unexpected answer."
        }
    }

    /// Whether asking again could work without changing anything.
    var isRetryable: Bool {
        switch self {
        case .missingKey, .invalidKey, .quotaExceeded, .badRequest: false
        case .rateLimited, .server, .network, .timedOut, .badResponse: true
        }
    }
}

/// Asks OpenAI to explain one word in its sentence (`POST /v1/chat/completions`). Called only when the
/// user taps the AI button on the dictionary screen, and sends just that word and its sentence.
nonisolated struct OpenAIExplainClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let model = "gpt-4o-mini"
    /// Longest sentence sent; a "sentence" cut from a table or list can be a whole paragraph.
    static let maxSentenceLength = 800

    /// Gives up instead of leaving the sheet on its spinner: 20 s of silence, 40 s overall.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    /// Injected so tests can answer requests without the network.
    var transport: Transport = { request in try await OpenAIExplainClient.session.data(for: request) }

    /// Runs off the main actor.
    @concurrent
    func explain(word: String, sentence: String, apiKey: String) async throws(OpenAIExplainError) -> WordExplanation {
        guard !apiKey.isEmpty else { throw .missingKey }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(Self.urlRequest(word: word, sentence: sentence, apiKey: apiKey))
        } catch let error as URLError where error.code == .timedOut {
            throw .timedOut
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        return try Self.parseReply(data)
    }

    // MARK: - Request

    static let systemPrompt = """
        You are an English tutor for an adult whose first language is Chinese and who reads English Wikipedia. \
        The user looked up a word while reading. Explain that word as it is used in the sentence they were reading. \
        Write the meaning, the explanation and the sentence translation in Simplified Chinese. \
        Keep it short: the meaning is a short phrase, the explanation at most three sentences about nuance, \
        usage or how it differs from similar words. \
        Give exactly three example sentences in plain, natural English, each with a Chinese translation. \
        Use the same sense of the word as in the user's sentence.
        """

    static func userPrompt(word: String, sentence: String) -> String {
        "Word: \(word)\nSentence: \(sentence.prefix(maxSentenceLength))"
    }

    /// Structured Outputs schema: the reply is always JSON in this shape.
    static var replySchema: [String: Any] { [
        "type": "object",
        "properties": [
            "partOfSpeech": ["type": "string"],
            "meaning": ["type": "string"],
            "explanation": ["type": "string"],
            "sentenceTranslation": ["type": "string"],
            "examples": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["english": ["type": "string"], "chinese": ["type": "string"]],
                    "required": ["english", "chinese"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["partOfSpeech", "meaning", "explanation", "sentenceTranslation", "examples"],
        "additionalProperties": false,
    ] }

    static func urlRequest(word: String, sentence: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(word: word, sentence: sentence)],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "word_explanation", "strict": true, "schema": replySchema],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: - Reply

    /// Reads `choices[0].message.content`, which holds the explanation as a JSON string.
    static func parseReply(_ data: Data) throws(OpenAIExplainError) -> WordExplanation {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let content = reply.choices.first?.message.content,
              let explanation = try? JSONDecoder().decode(WordExplanation.self, from: Data(content.utf8))
        else { throw .badResponse }
        return explanation
    }

    /// Maps an error response (`{"error": {"message": ..., "code": ...}}`) to an error.
    static func error(status: Int, body: Data) -> OpenAIExplainError {
        let details = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
        switch status {
        case 401: return .invalidKey
        case 429: return details?.code == "insufficient_quota" ? .quotaExceeded : .rateLimited
        case 400..<500: return .badRequest(details?.message ?? "HTTP \(status)")
        default: return .server(status: status)
        }
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                /// Nil when the model refused to answer.
                var content: String?
            }
            var message: Message
        }
        var choices: [Choice]
    }

    private struct ErrorBody: Decodable {
        struct Details: Decodable {
            var message: String?
            var code: String?
        }
        var error: Details
    }
}
