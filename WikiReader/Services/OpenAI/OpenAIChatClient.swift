import Foundation

nonisolated enum OpenAIChatError: Error, Equatable {
    case missingKey
    case invalidKey
    case quotaExceeded
    case rateLimited
    case badRequest(String)
    case server(status: Int)
    case network(String)
    case timedOut
    case badResponse

    /// Shown to the user in the sheet that asked.
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

    /// How this error counts in the call log.
    var outcome: CallOutcome {
        switch self {
        case .missingKey: .missingKey
        case .invalidKey: .invalidKey
        case .quotaExceeded: .outOfCredit
        case .rateLimited: .rateLimited
        case .badRequest: .rejected
        case .server: .serverError
        case .network: .network
        case .timedOut: .timedOut
        case .badResponse: .badResponse
        }
    }

    /// What to note next to the outcome, without anything from the request itself.
    var detail: String? {
        switch self {
        case .server(let status): "HTTP \(status)"
        case .network(let text), .badRequest(let text): text
        default: nil
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

/// Sends one chat request to OpenAI and decodes the JSON reply into a type (`POST /v1/chat/completions`).
/// The word explanation and the translation share it; each supplies its own prompt and reply schema.
/// Only used for something the user just asked for, such as a tap on the AI or Translate button.
nonisolated struct OpenAIChatClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let model = "gpt-4o-mini"

    /// Gives up instead of leaving the sheet on its spinner: 20 s of silence, 60 s overall.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    static let defaultTransport: Transport = { request in try await session.data(for: request) }

    /// Injected so tests can answer requests without the network.
    var transport: Transport = defaultTransport

    /// Where each request's time and result are noted, for the diagnostics page.
    var log: OpenAICallLog = .standard

    /// Structured Outputs: the reply is always JSON in the shape of `schema`.
    static func urlRequest(system: String, user: String, schemaName: String, schema: [String: Any], apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Runs off the main actor.
    @concurrent
    func send<Output: Decodable & Sendable>(_ request: URLRequest, as type: Output.Type) async throws(OpenAIChatError) -> Output {
        let start = ContinuousClock.now
        let size = request.httpBody?.count ?? 0
        do {
            let output = try await perform(request, as: type)
            log.note(.text, size: size, since: start, outcome: .ok)
            return output
        } catch {
            log.note(.text, size: size, since: start, outcome: error.outcome, detail: error.detail)
            throw error
        }
    }

    private func perform<Output: Decodable & Sendable>(_ request: URLRequest, as type: Output.Type) async throws(OpenAIChatError) -> Output {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code == .timedOut {
            throw .timedOut
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        return try Self.parseReply(data, as: type)
    }

    /// Reads `choices[0].message.content`, which holds the answer as a JSON string.
    static func parseReply<Output: Decodable>(_ data: Data, as type: Output.Type) throws(OpenAIChatError) -> Output {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let content = reply.choices.first?.message.content,
              let output = try? JSONDecoder().decode(type, from: Data(content.utf8))
        else { throw .badResponse }
        return output
    }

    /// Maps an error response (`{"error": {"message": ..., "code": ...}}`) to an error.
    static func error(status: Int, body: Data) -> OpenAIChatError {
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
