import Foundation
import OSLog

/// Speech audio being generated right now, shared by everything that generates it (the reader's engine, voice
/// samples, the batch download), so text that is already being generated is never requested, and paid for, twice.
///
/// Keyed by the file the audio will be stored in, which names the cache as well as the request: two caches (as in
/// tests) never share a generation.
///
/// A generation first asks `remote` (Google Drive) for audio another device made, and only then OpenAI; audio from
/// OpenAI is handed back to `remote` to share.
final class SpeechGenerations {
    typealias Generation = Task<Result<URL, OpenAITTSError>, Never>

    static let shared = SpeechGenerations(remote: DriveAudioStore.shared)

    private var running: [URL: Generation] = [:]
    /// Where audio is looked for before OpenAI; nil looks nowhere else.
    var remote: RemoteAudioSource?

    init(remote: RemoteAudioSource? = nil) {
        self.remote = remote
    }

    /// Whether audio can be had without an OpenAI key (from `remote`).
    var canWorkWithoutKey: Bool { remote?.looksUpBeforeGenerating ?? false }

    /// The generation of `request`'s audio: the one already running, or a new one. It is never cancelled by its
    /// callers going away: the audio is paid for, so it is allowed to reach the cache. Without an `apiKey` only
    /// `remote` is asked.
    func generate(_ request: OpenAISpeechRequest, apiKey: String?, client: OpenAITTSClient, cache: SpeechAudioCache) -> Generation {
        let file = cache.fileURL(for: request)
        if let pending = running[file] { return pending }
        let remote = remote
        let task = Task { () -> Result<URL, OpenAITTSError> in
            if let remote, remote.looksUpBeforeGenerating, let url = await remote.fetch(request, into: cache) {
                return .success(url)
            }
            guard let apiKey, !apiKey.isEmpty else { return .failure(.missingKey) }
            Log.speech.info("Generating OpenAI audio for \(request.input.utf16.count) characters")
            let result = await Self.run(request, apiKey: apiKey, client: client, cache: cache)
            if case .success = result { remote?.didGenerate(request, in: cache) }
            return result
        }
        running[file] = task
        Task {
            _ = await task.value
            if running[file] == task { running[file] = nil }
        }
        return task
    }

    /// `request`'s audio from `remote` alone, never from OpenAI, or nil if it isn't there: for downloading what Google
    /// Drive has, whether or not it is looked in before generating. A generation of the same text already running is
    /// waited for instead.
    func fetchFromRemote(_ request: OpenAISpeechRequest, cache: SpeechAudioCache) async -> URL? {
        if let pending = running[cache.fileURL(for: request)] { return try? await pending.value.get() }
        guard let remote, remote.isEnabled else { return nil }
        return await remote.fetch(request, into: cache)
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
