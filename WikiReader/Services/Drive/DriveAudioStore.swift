import Foundation
import Observation
import OSLog

/// Where generated speech audio comes from before OpenAI is asked: a source that may already have it.
protocol RemoteAudioSource: AnyObject {
    /// Whether it can be asked at all (signed in).
    var isEnabled: Bool { get }
    /// The audio for `request`, saved into `cache`, or nil if the source doesn't have it (or can't be reached).
    func fetch(_ request: OpenAISpeechRequest, into cache: SpeechAudioCache) async -> URL?
    /// `request`'s audio was just generated and stored in `cache`; share it.
    func didGenerate(_ request: OpenAISpeechRequest, in cache: SpeechAudioCache)
}

/// The audio cache shared through Google Drive with other devices and the Chrome extension
/// (format: docs/shared-tts-cache-format.md). Audio is looked for here after this iPhone's own cache and before
/// OpenAI; audio generated here is uploaded in the background; each article read or downloaded gets a manifest.
///
/// What is on Drive is mirrored in a local index (`DriveAudioIndex.json`): the audio folder is listed in full once,
/// then only what was created since the last look, usually one small request. So whether a piece is on Drive is
/// answered on the phone, and playing doesn't wait on Drive to say "no". An answer is trusted for `indexFreshness`;
/// after that the next question first asks Drive what is new (another device may have uploaded it).
///
/// Every file is a request of its own whatever its size, so request count, not size, is what to save: uploads run
/// `uploadConcurrency` at a time (Google advises staying around 3 writes a second per account), and rate limiting or
/// server errors back off exponentially from `retryDelay` up to `maxRetryDelay`.
@Observable
final class DriveAudioStore: RemoteAudioSource {
    static let shared = DriveAudioStore()

    static let rootName = "WikiReader Cache"
    static let audioFolder = "audio"
    static let articlesFolder = "articles"
    static let formatFile = "format.json"
    static let formatContents: [String: Any] = ["formatVersion": 1, "key": "ios-v1"]
    static let indexFreshness: TimeInterval = 2 * 60
    static let uploadConcurrency = 2
    static let maxRetryDelay: Duration = .seconds(300)

    struct Layout: Equatable {
        var root: String
        var audio: String
        var articles: String
    }

    /// The audio folder's contents as last seen, kept on disk between launches.
    struct AudioIndex: Codable, Equatable {
        /// The audio folder this describes; a different one (another account) starts over.
        var folder: String?
        /// File ids by key.
        var files: [String: String] = [:]
        /// The newest creation time seen, where the next look starts.
        var syncedThrough: String?
    }

    /// Keys of audio generated here and not uploaded yet, oldest first. Kept on disk, so nothing is lost if the app quits.
    private(set) var pendingUploads: [String] = []
    private(set) var isUploading = false
    /// Uploads are held because the connection costs money and the reader asked for Wi-Fi only.
    private(set) var isWaitingForFreeNetwork = false
    /// The last thing that went wrong talking to Drive, for Settings; cleared by the next success.
    private(set) var lastError: String?
    /// Audio taken from Drive and uploaded to it since the app started, for Settings.
    private(set) var downloadedCount = 0
    private(set) var uploadedCount = 0

    @ObservationIgnored private let client: DriveClient
    @ObservationIgnored private let isSignedIn: () -> Bool
    @ObservationIgnored private let cache: SpeechAudioCache
    @ObservationIgnored private let queueFile: URL
    @ObservationIgnored private let indexFile: URL
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let canUploadNow: () -> Bool
    @ObservationIgnored private var layoutTask: Task<Layout, Error>?
    @ObservationIgnored private var index: AudioIndex
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var syncTask: Task<Void, Error>?
    @ObservationIgnored private var uploadsInFlight: Set<String> = []
    @ObservationIgnored private var currentBackoff: Duration?
    @ObservationIgnored private var manifestIDs: [String: String] = [:]
    @ObservationIgnored private var writtenManifests: [String: DriveManifest] = [:]
    /// Articles read or downloaded this session, whose manifests are brought up to date when uploads finish.
    @ObservationIgnored private var notedArticles: [String: DriveManifest] = [:]
    @ObservationIgnored private var retryScheduled = false

    init(
        client: DriveClient = DriveClient(token: { force in try await GoogleAccount.shared.validAccessToken(force: force) }),
        isSignedIn: @escaping () -> Bool = { GoogleAccount.shared.isSignedIn },
        cache: SpeechAudioCache = .standard,
        queueFile: URL = URL.applicationSupportDirectory.appending(path: "DriveUploadQueue.json"),
        indexFile: URL = URL.applicationSupportDirectory.appending(path: "DriveAudioIndex.json"),
        retryDelay: Duration = .seconds(2),
        canUploadNow: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: SettingsKeys.driveUploadAnyNetwork) || !NetworkWatcher.shared.isExpensive
        }
    ) {
        self.client = client
        self.isSignedIn = isSignedIn
        self.cache = cache
        self.queueFile = queueFile
        self.indexFile = indexFile
        self.retryDelay = retryDelay
        self.canUploadNow = canUploadNow
        pendingUploads = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: queueFile))) ?? []
        index = (try? JSONDecoder().decode(AudioIndex.self, from: Data(contentsOf: indexFile))) ?? AudioIndex()
    }

    var isEnabled: Bool { isSignedIn() }

    /// Forgets what was learned about Drive (after signing out or in as someone else).
    func reset() {
        layoutTask?.cancel()
        layoutTask = nil
        index = AudioIndex()
        lastSync = nil
        try? FileManager.default.removeItem(at: indexFile)
        manifestIDs = [:]
        writtenManifests = [:]
        notedArticles = [:]
        lastError = nil
    }

    // MARK: - The shared folder

    /// `WikiReader Cache/` with its `audio/` and `articles/` folders and `format.json`, found or created once.
    func layout() async throws -> Layout {
        if let layoutTask { return try await layoutTask.value }
        let client = client
        let task = Task { () throws -> Layout in
            let root: String
            if let found = try await client.folder(named: Self.rootName, in: "root") {
                root = found
                try await Self.checkFormat(in: root, client: client)
            } else {
                root = try await client.createFolder(named: Self.rootName, in: "root")
                Log.app.info("Created the Drive folder \(Self.rootName, privacy: .public)")
            }
            if try await client.files(named: [Self.formatFile], in: root).isEmpty {
                let data = try JSONSerialization.data(withJSONObject: Self.formatContents, options: [.sortedKeys])
                _ = try await client.upload(name: Self.formatFile, data: data, mimeType: "application/json", in: root)
            }
            async let audio = Self.subfolder(Self.audioFolder, in: root, client: client)
            async let articles = Self.subfolder(Self.articlesFolder, in: root, client: client)
            return try await Layout(root: root, audio: audio, articles: articles)
        }
        layoutTask = task
        do {
            return try await task.value
        } catch {
            layoutTask = nil  // try again next time
            throw error
        }
    }

    private static func subfolder(_ name: String, in root: String, client: DriveClient) async throws -> String {
        if let found = try await client.folder(named: name, in: root) { return found }
        return try await client.createFolder(named: name, in: root)
    }

    /// Refuses a folder written in a format this version doesn't know, rather than mixing caches.
    private static func checkFormat(in root: String, client: DriveClient) async throws {
        guard let id = try await client.files(named: [formatFile], in: root)[formatFile] else { return }
        let object = try? JSONSerialization.jsonObject(with: try await client.download(fileID: id)) as? [String: Any]
        let version = object?["formatVersion"] as? Int
        let key = object?["key"] as? String
        // Exactly what the Chrome extension accepts too, so neither writes into a folder the other refuses.
        guard version == 1, key == "ios-v1" else {
            throw DriveError.unsupportedFormat("formatVersion \(version.map(String.init) ?? "?"), key \(key ?? "?")")
        }
    }

    // MARK: - Finding audio

    /// Brings the local index of the audio folder up to date, unless it was just done. Lists only files created since
    /// the last look (a minute's overlap allows for clocks and Drive's ordering), so it is usually a single request.
    func syncIndex(force: Bool = false) async {
        guard isEnabled else { return }
        if !force, let lastSync, Date.now.timeIntervalSince(lastSync) < Self.indexFreshness { return }
        if let syncTask {
            _ = try? await syncTask.value
            return
        }
        let task = Task { () throws -> Void in
            let audio = try await layout().audio
            if index.folder != audio { index = AudioIndex(folder: audio) }
            let since = index.syncedThrough.flatMap { Self.rfc3339(minus: 60, from: $0) }
            let listed = try await client.listFolder(audio, createdAfter: since)
            for file in listed where file.name.hasSuffix(".mp3") {
                let key = String(file.name.dropLast(4))
                // Two devices uploading the same audio leave two copies; keep the one already known.
                if index.files[key] == nil { index.files[key] = file.id }
                if let created = file.createdTime, created > (index.syncedThrough ?? "") { index.syncedThrough = created }
            }
            lastSync = .now
            saveIndex()
            Log.app.info("Drive: index has \(self.index.files.count) pieces (\(listed.count) listed)")
        }
        syncTask = task
        defer { syncTask = nil }
        do {
            try await task.value
            lastError = nil
        } catch {
            note(error, while: "listing audio")
        }
    }

    /// For callers about to need these keys: the index answers for all of them at once, so it is only brought up to date.
    func prepareIndex(keys: [String]) async {
        await syncIndex()
    }

    /// Whether the key's audio is on Drive, as far as is known (nil: the index isn't fresh enough to say "no").
    func isOnDrive(_ key: String) -> Bool? {
        if index.files[key] != nil { return true }
        guard let lastSync, Date.now.timeIntervalSince(lastSync) < Self.indexFreshness else { return nil }
        return false
    }

    func fetch(_ request: OpenAISpeechRequest, into cache: SpeechAudioCache) async -> URL? {
        guard isEnabled else { return nil }
        let key = SpeechAudioCache.key(for: request)
        if isOnDrive(key) == nil { await syncIndex() }
        guard let id = index.files[key] else { return nil }
        do {
            let data = try await client.download(fileID: id)
            let url = try cache.store(data, for: request)
            downloadedCount += 1
            lastError = nil
            Log.app.info("Drive: took a piece from Drive (\(data.count) bytes)")
            return url
        } catch DriveError.http(status: 404, _) {
            // Deleted on Drive since it was indexed.
            index.files[key] = nil
            saveIndex()
            return nil
        } catch {
            note(error, while: "downloading audio")
            return nil
        }
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: indexFile, options: .atomic)
    }

    /// An RFC 3339 time `seconds` before `time`, in Drive's format.
    static func rfc3339(minus seconds: TimeInterval, from time: String) -> String? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: time) ?? ISO8601DateFormatter().date(from: time) else { return nil }
        return fractional.string(from: date.addingTimeInterval(-seconds))
    }

    // MARK: - Uploading

    func didGenerate(_ request: OpenAISpeechRequest, in cache: SpeechAudioCache) {
        // Only the app's own cache: tests and samples in other folders aren't shared.
        guard isEnabled, cache.directory == self.cache.directory else { return }
        enqueue([SpeechAudioCache.key(for: request)])
    }

    /// Queues audio in this iPhone's cache for upload; keys already on Drive or queued are skipped.
    func enqueue(_ keys: [String]) {
        var queued = Set(pendingUploads)
        let new = keys.filter { index.files[$0] == nil && queued.insert($0).inserted }
        guard !new.isEmpty else { return }
        pendingUploads += new
        saveQueue()
        pumpUploads()
    }

    /// Starts uploading, `uploadConcurrency` files at a time, unless the connection costs money and the reader asked
    /// for Wi-Fi only (`NetworkWatcher` calls this again when that changes) or a backoff is running. A failure that
    /// may pass stops the uploads and they resume after the backoff; nothing is dropped.
    func pumpUploads() {
        guard isEnabled, !pendingUploads.isEmpty else { return }
        guard canUploadNow() else {
            isWaitingForFreeNetwork = true
            return
        }
        isWaitingForFreeNetwork = false
        guard !retryScheduled else { return }
        while uploadsInFlight.count < Self.uploadConcurrency,
              let key = pendingUploads.first(where: { !uploadsInFlight.contains($0) }) {
            uploadsInFlight.insert(key)
            isUploading = true
            Task { await upload(key) }
        }
    }

    private func upload(_ key: String) async {
        let file = cache.directory.appending(path: key + "." + OpenAITTSClient.audioFormat)
        var failed = false
        if isEnabled, let data = try? Data(contentsOf: file) {
            do {
                let audio = try await layout().audio
                if index.files[key] == nil {
                    index.files[key] = try await client.upload(name: key + ".mp3", data: data, mimeType: "audio/mpeg", in: audio)
                    uploadedCount += 1
                    saveIndex()
                }
                dropFromQueue(key)
                currentBackoff = nil
                lastError = nil
            } catch {
                failed = true
                note(error, while: "uploading audio")
                // Signed out or refused: waiting won't help, the next sign-in or queued audio starts again.
                if (error as? DriveError)?.isTransient ?? true { scheduleRetry() }
            }
        } else if isEnabled {
            dropFromQueue(key)  // deleted from this iPhone since: nothing to share
        }
        uploadsInFlight.remove(key)
        isUploading = !uploadsInFlight.isEmpty
        guard !failed else { return }
        if pendingUploads.isEmpty {
            if uploadsInFlight.isEmpty {
                Log.app.info("Drive: upload queue empty")
                await refreshNotedManifests()
            }
        } else {
            pumpUploads()
        }
    }

    private func dropFromQueue(_ key: String) {
        pendingUploads.removeAll { $0 == key }
        saveQueue()
    }

    private func saveQueue() {
        try? FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pendingUploads).write(to: queueFile, options: .atomic)
    }

    /// Waits before trying again, twice as long each time in a row (2 s, 4 s, 8 s ... up to 5 minutes).
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = currentBackoff.map { min($0 * 2, Self.maxRetryDelay) } ?? retryDelay
        currentBackoff = delay
        Log.app.info("Drive: retrying uploads in \(delay)")
        Task {
            try? await Task.sleep(for: delay)
            retryScheduled = false
            pumpUploads()
        }
    }

    // MARK: - Manifests

    /// Records an article being read or downloaded with `voice`: looks its pieces up on Drive and writes its manifest
    /// if it changed. Written again once queued uploads finish, so `complete` catches up.
    func noteArticle(title: String, url: String, blocks: [ContentBlock], voice: String) async {
        guard isEnabled, !blocks.isEmpty else { return }
        let manifest = DriveManifest(title: title, url: url, blocks: blocks, voice: voice)
        notedArticles[manifest.fileName] = manifest
        await syncIndex()
        await writeManifest(manifest)
    }

    private func refreshNotedManifests() async {
        for manifest in notedArticles.values {
            await writeManifest(manifest)
        }
    }

    private func writeManifest(_ base: DriveManifest) async {
        var manifest = base
        manifest.complete = manifest.keys.allSatisfy { index.files[$0] != nil }
        manifest.updatedAt = ISO8601DateFormatter().string(from: .now)
        if let written = writtenManifests[manifest.fileName], written.sameContent(as: manifest) { return }
        do {
            let folder = try await layout().articles
            let id: String?
            if let known = manifestIDs[manifest.fileName] {
                id = known
            } else {
                id = try await client.files(named: [manifest.fileName], in: folder)[manifest.fileName]
            }
            if let id {
                try await client.replace(fileID: id, data: manifest.encoded(), mimeType: "application/json")
                manifestIDs[manifest.fileName] = id
            } else {
                manifestIDs[manifest.fileName] = try await client.upload(
                    name: manifest.fileName, data: manifest.encoded(), mimeType: "application/json", in: folder
                )
            }
            writtenManifests[manifest.fileName] = manifest
            lastError = nil
        } catch {
            note(error, while: "writing an article manifest")
        }
    }

    // MARK: - The library's audio

    /// Queues every piece of audio on this iPhone that belongs to the library (any voice) and isn't on Drive, and
    /// writes the articles' manifests for `voice`. For moving audio paid for before Drive was set up.
    /// - Returns: How many pieces were queued.
    @discardableResult
    func uploadLibrary(_ articles: [(title: String, url: String, blocksData: Data)], voice: String) async -> Int {
        guard isEnabled else { return 0 }
        let cache = cache
        let local = await Self.localKeys(of: articles.map(\.blocksData), cache: cache)
        await syncIndex(force: true)
        let missing = local.filter { index.files[$0] == nil }
        enqueue(missing)
        for article in articles {
            let blocks = Article.decodeBlocks(article.blocksData)
            notedArticles[DriveManifest.urlHash(article.url) + ".json"] = DriveManifest(title: article.title, url: article.url, blocks: blocks, voice: voice)
        }
        if pendingUploads.isEmpty { await refreshNotedManifests() }
        return missing.count
    }

    @concurrent
    private static func localKeys(of library: [Data], cache: SpeechAudioCache) async -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for blocks in library.map(Article.decodeBlocks) {
            for input in ArticleAudio.inputs(of: blocks) {
                for voice in OpenAISpeechEngine.voices {
                    let request = OpenAISpeechEngine.request(for: input, voice: voice)
                    let key = SpeechAudioCache.key(for: request)
                    if cache.cachedFile(for: request) != nil, seen.insert(key).inserted { keys.append(key) }
                }
            }
        }
        return keys
    }

    // MARK: - Errors

    private func note(_ error: Error, while doing: String) {
        let message = (error as? DriveError)?.message ?? (error as? GoogleAuthError)?.message ?? error.localizedDescription
        lastError = message
        Log.app.error("Drive: failed \(doing, privacy: .public): \(message, privacy: .public)")
    }
}
