import Foundation
import OSLog

/// Speech audio being generated right now, shared by everything that generates it (the reader's engine, voice
/// samples, the batch download), so text that is already being generated is never requested, and paid for, twice.
///
/// Keyed by the file the audio will be stored in, which names the cache as well as the request: two caches (as in
/// tests) never share a generation.
final class SpeechGenerations {
    typealias Generation = Task<Result<URL, OpenAITTSError>, Never>

    static let shared = SpeechGenerations()

    private var running: [URL: Generation] = [:]

    /// The generation of `request`'s audio: the one already running, or a new one. It is never cancelled by its
    /// callers going away: the audio is paid for, so it is allowed to reach the cache.
    func generate(_ request: OpenAISpeechRequest, apiKey: String, client: OpenAITTSClient, cache: SpeechAudioCache) -> Generation {
        let file = cache.fileURL(for: request)
        if let pending = running[file] { return pending }
        Log.speech.info("Generating OpenAI audio for \(request.input.utf16.count) characters")
        let task = Task { await Self.run(request, apiKey: apiKey, client: client, cache: cache) }
        running[file] = task
        Task {
            _ = await task.value
            if running[file] == task { running[file] = nil }
        }
        return task
    }

    func isGenerating(_ request: OpenAISpeechRequest, in cache: SpeechAudioCache) -> Bool {
        running[cache.fileURL(for: request)] != nil
    }

    /// Network and file work, off the main actor.
    @concurrent
    private static func run(
        _ request: OpenAISpeechRequest, apiKey: String, client: OpenAITTSClient, cache: SpeechAudioCache
    ) async -> Result<URL, OpenAITTSError> {
        let audio: Data
        do {
            audio = try await client.synthesize(request, apiKey: apiKey)
        } catch {
            return .failure(error)
        }
        do {
            return .success(try cache.store(audio, for: request))
        } catch {
            return .failure(.audio(error.localizedDescription))
        }
    }
}
