import Foundation
import OSLog

/// Narration files on the English Reader site (Cloudflare R2, public), for the articles opened from it. Asked after
/// this iPhone's own cache and before Google Drive and OpenAI, and free. Only files the site lists for this exact text
/// are asked for (`SiteLibrary.audioURL(forKey:)`), so there is never a request for audio that isn't there.
///
/// A downloaded file goes into the same cache as generated audio, named by the same key: the same speech (the site's
/// copies are compressed since 2026-11-05), so it is never uploaded to Drive from here (`DriveAudioStore.isSiteAudio`).
/// The site renames its files now and then; a file gone from its address (404) has its article fetched again once.
final class SiteAudioSource: RemoteAudioSource {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = SiteAudioSource()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    private let library: SiteLibrary
    private let transport: Transport
    private let retryDelay: Duration

    init(
        library: SiteLibrary = .shared,
        retryDelay: Duration = .seconds(1),
        transport: @escaping Transport = { try await SiteAudioSource.session.data(for: $0) }
    ) {
        self.library = library
        self.retryDelay = retryDelay
        self.transport = transport
    }

    var isEnabled: Bool { library.hasAudio }

    func fetch(_ request: OpenAISpeechRequest, into cache: SpeechAudioCache) async -> URL? {
        let key = SpeechAudioCache.key(for: request)
        guard let url = library.audioURL(forKey: key) else { return nil }
        switch await Self.download(url, as: request, into: cache, transport: transport, retryDelay: retryDelay) {
        case .stored(let file):
            return file
        case .failed:
            return nil
        case .gone:
            guard let moved = await library.refreshAudio(forKey: key) else { return nil }
            if case .stored(let file) = await Self.download(moved, as: request, into: cache, transport: transport, retryDelay: retryDelay) {
                return file
            }
            return nil
        }
    }

    nonisolated enum Outcome: Sendable {
        case stored(URL)
        /// 404: not at this address (any more).
        case gone
        case failed
    }

    /// Nothing to share: audio generated here is Google Drive's business.
    func didGenerate(_ request: OpenAISpeechRequest, in cache: SpeechAudioCache) {}

    /// Off the main actor. Up to 3 tries for what may pass (no answer, 5xx, 429); a 404 means the file isn't at this
    /// address (any more).
    @concurrent
    private static func download(
        _ url: URL, as request: OpenAISpeechRequest, into cache: SpeechAudioCache, transport: Transport, retryDelay: Duration
    ) async -> Outcome {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(SiteClient.userAgent, forHTTPHeaderField: "User-Agent")
        for attempt in 1...3 {
            if attempt > 1 { try? await Task.sleep(for: retryDelay * (attempt - 1)) }
            do {
                let (data, response) = try await transport(urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, !data.isEmpty {
                    return .stored(try cache.store(data, for: request))
                }
                Log.speech.error("English Reader audio: HTTP \(status)")
                if status == 404 { return .gone }
                guard status == 429 || status >= 500 else { return .failed }
            } catch {
                Log.speech.error("English Reader audio failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .failed
    }
}
