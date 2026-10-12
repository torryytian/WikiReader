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

    /// Whether asking again is likely to help: the request got stuck, the connection dropped, OpenAI had a
    /// hiccup or is rate limiting. A rejected key, no credit or a bad request would only fail the same way.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .rateLimited, .server, .network: true
        case .missingKey, .invalidKey, .quotaExceeded, .badRequest, .badResponse, .audio: false
        }
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

/// How a failed request is repeated. Most requests answer in about 5 s, but a few percent get stuck for a minute;
/// asking again almost always works at once, so a stuck attempt is given up on early rather than waited out.
nonisolated struct RetryPolicy: Sendable {
    /// Requests in all, the first one included.
    var maxAttempts = 3
    /// Waits before the second and third attempt (when OpenAI doesn't say how long via `Retry-After`).
    var delays: [Duration] = [.seconds(1), .seconds(2)]
    /// The longest `Retry-After` that is honoured; a longer one means the reader is better off told.
    var maxRetryAfter: Duration = .seconds(15)

    static let standard = RetryPolicy()
    /// One attempt, no waiting: for tests of single outcomes.
    static let never = RetryPolicy(maxAttempts: 1, delays: [])
    /// Retries without waiting, for tests.
    static let immediately = RetryPolicy(maxAttempts: 3, delays: [.zero, .zero])
}

/// A failed attempt, with how long OpenAI asked to wait before the next one.
nonisolated struct TTSAttemptFailure: Error {
    var error: OpenAITTSError
    var retryAfter: Duration?
}

/// Generates speech audio with OpenAI. Called for the block being read and a few after it (see `ReadingSession`).
nonisolated struct OpenAITTSClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// AVAudioPlayer plays MP3 natively, and it is compact for caching.
    static let audioFormat = "mp3"

    /// Its own session rather than `.shared`: nothing cached, and a ceiling on one attempt's total time.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        // The audio is kept by `SpeechAudioCache`; a second copy in memory would be wasted.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Injected so tests can answer requests without the network.
    var transport: Transport = { request in try await session.data(for: request) }

    /// Where each request's time and result are noted, for the diagnostics page.
    var log: OpenAICallLog = .standard

    var retry = RetryPolicy.standard

    /// How long one attempt may take before it is given up on, by size. The answer arrives only when the audio
    /// is complete, so a longer text legitimately takes longer: 15 s covers the usual paragraph (typically 5 s,
    /// 9 in 10 within 8 s), then roughly 1 s more per 50 characters, up to 90 s for the longest.
    static func attemptTimeout(forCharacters count: Int) -> TimeInterval {
        min(max(8 + Double(count) / 50, 15), 90)
    }

    /// Returns MP3 audio for the request, trying again (see `RetryPolicy`) when an attempt gets stuck or fails
    /// in a way that may pass. Runs off the main actor.
    @concurrent
    func synthesize(_ speech: OpenAISpeechRequest, apiKey: String) async throws(OpenAITTSError) -> Data {
        guard !apiKey.isEmpty else { throw .missingKey }
        let start = ContinuousClock.now
        var attempt = 0
        var notes: [String] = []
        while true {
            attempt += 1
            let attemptStart = ContinuousClock.now
            do {
                let audio = try await perform(speech, apiKey: apiKey)
                notes.append("attempt \(attempt) ok in \(Self.fixed(attemptStart))")
                log.note(.speech, size: speech.input.count, since: start, outcome: .ok, detail: attempt > 1 ? notes.joined(separator: "; ") : nil, attempts: attempt)
                return audio
            } catch {
                notes.append("attempt \(attempt) \(error.error.outcome.label.lowercased()) after \(Self.fixed(attemptStart))")
                let willRetry = error.error.isRetryable && attempt < retry.maxAttempts && !Task.isCancelled
                guard willRetry else {
                    let detail = [error.error.detail, attempt > 1 ? notes.joined(separator: "; ") : nil].compactMap { $0 }.joined(separator: " · ")
                    log.note(.speech, size: speech.input.count, since: start, outcome: error.error.outcome, detail: detail.isEmpty ? nil : detail, attempts: attempt)
                    throw error.error
                }
                let backoff = retry.delays.indices.contains(attempt - 1) ? retry.delays[attempt - 1] : (retry.delays.last ?? .zero)
                let wait = error.retryAfter.map { min($0, retry.maxRetryAfter) } ?? backoff
                try? await Task.sleep(for: wait)
                if Task.isCancelled {
                    log.note(.speech, size: speech.input.count, since: start, outcome: error.error.outcome, detail: notes.joined(separator: "; "), attempts: attempt)
                    throw error.error
                }
            }
        }
    }

    private static func fixed(_ start: ContinuousClock.Instant) -> String {
        String(format: "%.1f s", start.duration(to: .now).seconds)
    }

    private func perform(_ speech: OpenAISpeechRequest, apiKey: String) async throws(TTSAttemptFailure) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(Self.urlRequest(for: speech, apiKey: apiKey))
        } catch let error as URLError where error.code == .timedOut {
            throw TTSAttemptFailure(error: .timedOut)
        } catch {
            throw TTSAttemptFailure(error: .network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { throw TTSAttemptFailure(error: .badResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSAttemptFailure(error: Self.error(status: http.statusCode, body: data), retryAfter: Self.retryAfter(http))
        }
        guard !data.isEmpty else { throw TTSAttemptFailure(error: .badResponse) }
        return data
    }

    /// The `Retry-After` header, when it is a number of seconds.
    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds.isFinite
        else { return nil }
        return .seconds(seconds)
    }

    static func urlRequest(for speech: OpenAISpeechRequest, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = attemptTimeout(forCharacters: speech.input.count)

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
