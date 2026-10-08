import Foundation

/// A Chinese translation of a passage, plus the expressions in it that are likely to be hard.
nonisolated struct PassageTranslation: Codable, Equatable, Sendable {
    struct Note: Codable, Equatable, Sendable {
        /// The English word, idiom or pattern.
        var expression: String
        /// What it means here, in Chinese.
        var explanation: String
    }

    var translation: String
    var notes: [Note]
}

/// Asks OpenAI to translate what the user selected, or a paragraph whose Translate button they tapped.
/// Sends only that text.
nonisolated struct OpenAITranslateClient: Sendable {
    /// Longest text sent. A selection can span many paragraphs; this keeps one request cheap and quick.
    static let maxLength = 6000

    /// Injected so tests can answer requests without the network.
    var transport: OpenAIChatClient.Transport = OpenAIChatClient.defaultTransport

    @concurrent
    func translate(_ text: String, apiKey: String) async throws(OpenAIChatError) -> PassageTranslation {
        guard !apiKey.isEmpty else { throw .missingKey }
        let request = Self.urlRequest(text: text, apiKey: apiKey)
        return try await OpenAIChatClient(transport: transport).send(request, as: PassageTranslation.self)
    }

    static let systemPrompt = """
        You translate English Wikipedia text into Simplified Chinese for an adult who is learning English. \\
        Translate the whole passage faithfully and naturally, keeping its paragraph breaks. \\
        Then list up to four words, idioms or grammar patterns from the passage that a learner is likely to find \\
        hard, each with a short Chinese explanation of what it means in this passage. \\
        If nothing is hard, return an empty list.
        """

    static func clipped(_ text: String) -> String {
        String(text.prefix(maxLength))
    }

    static var replySchema: [String: Any] { [
        "type": "object",
        "properties": [
            "translation": ["type": "string"],
            "notes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["expression": ["type": "string"], "explanation": ["type": "string"]],
                    "required": ["expression", "explanation"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["translation", "notes"],
        "additionalProperties": false,
    ] }

    static func urlRequest(text: String, apiKey: String) -> URLRequest {
        OpenAIChatClient.urlRequest(
            system: systemPrompt, user: clipped(text),
            schemaName: "passage_translation", schema: replySchema, apiKey: apiKey
        )
    }
}
