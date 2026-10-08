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

/// Asks OpenAI to explain one word in its sentence. Called only when the user taps the AI button on the
/// dictionary screen, and sends just that word and its sentence.
nonisolated struct OpenAIExplainClient: Sendable {
    static var model: String { OpenAIChatClient.model }
    /// Longest sentence sent; a "sentence" cut from a table or list can be a whole paragraph.
    static let maxSentenceLength = 800

    /// Injected so tests can answer requests without the network.
    var transport: OpenAIChatClient.Transport = OpenAIChatClient.defaultTransport

    @concurrent
    func explain(word: String, sentence: String, apiKey: String) async throws(OpenAIChatError) -> WordExplanation {
        guard !apiKey.isEmpty else { throw .missingKey }
        let request = Self.urlRequest(word: word, sentence: sentence, apiKey: apiKey)
        return try await OpenAIChatClient(transport: transport).send(request, as: WordExplanation.self)
    }

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
        OpenAIChatClient.urlRequest(
            system: systemPrompt, user: userPrompt(word: word, sentence: sentence),
            schemaName: "word_explanation", schema: replySchema, apiKey: apiKey
        )
    }
}
