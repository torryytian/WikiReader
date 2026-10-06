import Foundation

/// One request to OpenAI's speech endpoint (`POST /v1/audio/speech`).
nonisolated struct OpenAISpeechRequest: Equatable, Sendable {
    static let maxInputLength = 4096

    var model: String
    var voice: String
    /// At most `maxInputLength` characters.
    var input: String
    /// Speaking style; only honored by gpt-4o-mini-tts.
    var instructions: String?
}

nonisolated enum OpenAITTSError: Error, Equatable {
    case missingKey
    case invalidKey
    case quotaExceeded
    case rateLimited
    case badRequest(String)
    case server(status: Int)
    case network(String)
    case badResponse
    /// The audio couldn't be saved or played back.
    case audio(String)

    /// Shown to the user in the reader.
    var message: String {
        switch self {
        case .missingKey: "No OpenAI API key. Add one in Settings."
        case .invalidKey: "The OpenAI API key was rejected. Check it in Settings."
        case .quotaExceeded: "Your OpenAI account has no remaining credit."
        case .rateLimited: "OpenAI is rate limiting requests. Try again in a moment."
        case .badRequest(let detail): "OpenAI rejected the request: \(detail)"
        case .server(let status): "OpenAI had a problem (HTTP \(status)). Try again later."
        case .network(let detail): "Couldn't reach OpenAI: \(detail)"
        case .badResponse: "OpenAI returned an unexpected response."
        case .audio(let detail): "Couldn't play the generated audio: \(detail)"
        }
    }
}

/// Generates speech audio with OpenAI. Called only for the block being read and the next one.
nonisolated struct OpenAITTSClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// AVAudioPlayer plays MP3 natively, and it is compact for caching.
    static let audioFormat = "mp3"

    /// Injected so tests can answer requests without the network.
    var transport: Transport = { request in try await URLSession.shared.data(for: request) }

    /// Returns MP3 audio for the request. Runs off the main actor.
    @concurrent
    func synthesize(_ speech: OpenAISpeechRequest, apiKey: String) async throws(OpenAITTSError) -> Data {
        guard !apiKey.isEmpty else { throw .missingKey }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(Self.urlRequest(for: speech, apiKey: apiKey))
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        guard !data.isEmpty else { throw .badResponse }
        return data
    }

    static func urlRequest(for speech: OpenAISpeechRequest, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body: [String: String] = [
            "model": speech.model,
            "voice": speech.voice,
            "input": speech.input,
            "response_format": audioFormat,
        ]
        if let instructions = speech.instructions, !instructions.isEmpty {
            body["instructions"] = instructions
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Maps an error response (`{"error": {"message": ..., "code": ...}}`) to an error.
    static func error(status: Int, body: Data) -> OpenAITTSError {
        let details = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
        switch status {
        case 401: return .invalidKey
        case 429: return details?.code == "insufficient_quota" ? .quotaExceeded : .rateLimited
        case 400..<500: return .badRequest(details?.message ?? "HTTP \(status)")
        default: return .server(status: status)
        }
    }

    private struct ErrorBody: Decodable {
        struct Details: Decodable {
            var message: String?
            var code: String?
        }
        var error: Details
    }
}
