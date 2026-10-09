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
    /// No answer in time.
    case timedOut
    case badRequest(String)
    case server(status: Int)
    case network(String)
    case badResponse
    /// The audio couldn't be saved or played back.
    case audio(String)

    /// How this error counts in the call log.
    var outcome: CallOutcome {
        switch self {
        case .missingKey: .missingKey
        case .invalidKey: .invalidKey
        case .quotaExceeded: .outOfCredit
        case .rateLimited: .rateLimited
        case .timedOut: .timedOut
        case .badRequest: .rejected
        case .server: .serverError
        case .network: .network
        case .badResponse: .badResponse
        case .audio: .audioError
        }
    }

    /// What to note next to the outcome, without anything from the request itself.
    var detail: String? {
        switch self {
        case .server(let status): "HTTP \(status)"
        case .network(let text), .badRequest(let text), .audio(let text): text
        default: nil
        }
    }

    var failure: SpeechFailure {
        SpeechFailure(message: message, isFixableInSettings: self == .missingKey || self == .invalidKey)
    }

    /// Shown to the user in the reader.
    var message: String {
        switch self {
        case .missingKey: "No OpenAI API key. Add one in Settings."
        case .invalidKey: "The OpenAI API key was rejected. Check it in Settings."
        case .quotaExceeded: "Your OpenAI account has no remaining credit."
        case .rateLimited: "OpenAI is rate limiting requests. Try again in a moment."
        case .timedOut: "OpenAI didn't answer in time. Try again."
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

    /// Where each request's time and result are noted, for the diagnostics page.
    var log: OpenAICallLog = .standard

    /// Returns MP3 audio for the request. Runs off the main actor.
    @concurrent
    func synthesize(_ speech: OpenAISpeechRequest, apiKey: String) async throws(OpenAITTSError) -> Data {
        guard !apiKey.isEmpty else { throw .missingKey }
        let start = ContinuousClock.now
        do {
            let audio = try await perform(speech, apiKey: apiKey)
            log.note(.speech, size: speech.input.count, since: start, outcome: .ok)
            return audio
        } catch {
            log.note(.speech, size: speech.input.count, since: start, outcome: error.outcome, detail: error.detail)
            throw error
        }
    }

    private func perform(_ speech: OpenAISpeechRequest, apiKey: String) async throws(OpenAITTSError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(Self.urlRequest(for: speech, apiKey: apiKey))
        } catch let error as URLError where error.code == .timedOut {
            throw .timedOut
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
