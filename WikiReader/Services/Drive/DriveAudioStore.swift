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
/// OpenAI; audio generated here is uploaded in the background; each article gets a manifest.
///
/// Backing up is incremental: a piece is uploaded right after it is generated, and `backUp` (run when the app opens,
/// after signing in, and from Settings) compares the library's audio on this iPhone with the index and queues only
/// what Drive lacks, which also catches audio made while signed out or while uploads were failing.
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
        /// The articles folder's manifests, file ids by file name, as of the last sync.
        var manifests: [String: String] = [:]
        /// What this iPhone last wrote into each manifest (a digest of everything but the time), so an unchanged
        /// manifest isn't written again on every launch.
        var manifestDigests: [String: String] = [:]

        init(folder: String? = nil) {
            self.folder = folder
        }

        // Indexes saved before manifests were tracked lack those fields.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            folder = try container.decodeIfPresent(String.self, forKey: .folder)
            files = try container.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
            syncedThrough = try container.decodeIfPresent(String.self, forKey: .syncedThrough)
            manifests = try container.decodeIfPresent([String: String].self, forKey: .manifests) ?? [:]
            manifestDigests = try container.decodeIfPresent([String: String].self, forKey: .manifestDigests) ?? [:]
        }
    }

    /// Keys of audio generated here and not uploaded yet, oldest first. Kept on disk, so nothing is lost if the app quits.
    private(set) var pendingUploads: [String] = []
    private(set) var isUploading = false {
        // Uploads stop when the app is suspended, which a locking screen does after a minute or two.
        didSet { if isUploading != oldValue { keepAwake(isUploading) } }
    }
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
    @ObservationIgnored private let onAccessLost: () -> Void
    @ObservationIgnored private let keepAwake: (Bool) -> Void
    @ObservationIgnored private var layoutTask: Task<Layout, Error>?
    @ObservationIgnored private var index: AudioIndex
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var syncTask: Task<Void, Error>?
    @ObservationIgnored private var uploadsInFlight: Set<String> = []
    @ObservationIgnored private var currentBackoff: Duration?
    /// When `backUp` last compared the library with Drive, so opening the app often doesn't redo it every time.
    @ObservationIgnored private var lastBackUp: Date?
    static let backUpInterval: TimeInterval = 10 * 60
    /// Articles read, downloaded or backed up this session, whose manifests are brought up to date when uploads finish.
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
        },
        onAccessLost: @escaping () -> Void = { GoogleAccount.shared.driveAccessMissing() },
        keepAwake: @escaping (Bool) -> Void = { ScreenAwake.set("drive upload", $0) }
    ) {
        self.client = client
        self.isSignedIn = isSignedIn
        self.cache = cache
        self.queueFile = queueFile
        self.indexFile = indexFile
        self.retryDelay = retryDelay
        self.canUploadNow = canUploadNow
        self.onAccessLost = onAccessLost
        self.keepAwake = keepAwake
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
        notedArticles = [:]
        lastBackUp = nil
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
            let layout = try await layout()
            let audio = layout.audio
            if index.folder != audio { index = AudioIndex(folder: audio) }
            let since = index.syncedThrough.flatMap { Self.rfc3339(minus: 60, from: $0) }
            let listed = try await client.listFolder(audio, createdAfter: since)
            for file in listed where file.name.hasSuffix(".mp3") {
                let key = String(file.name.dropLast(4))
                // Two devices uploading the same audio leave two copies; keep the one already known.
                if index.files[key] == nil { index.files[key] = file.id }
                if let created = file.createdTime, created > (index.syncedThrough ?? "") { index.syncedThrough = created }
            }
            // Manifests are few and replaced in place (their creation time doesn't move), so list them all.
            var manifests: [String: String] = [:]
            for file in try await client.listFolder(layout.articles) where file.name.hasSuffix(".json") {
                if manifests[file.name] == nil { manifests[file.name] = file.id }
            }
            index.manifests = manifests
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
                // Know what is on Drive before adding to it, or a piece another device uploaded is uploaded again.
                if lastSync == nil {
                    await syncIndex()
                    guard lastSync != nil else { throw DriveError.network("couldn't list the Drive folder") }
                }
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
        let digest = manifest.contentDigest
        // Written before with the same content and still there: nothing to do, and no request.
        if index.manifestDigests[manifest.fileName] == digest, index.manifests[manifest.fileName] != nil { return }
        do {
            let folder = try await layout().articles
            if let id = index.manifests[manifest.fileName] {
                try await client.replace(fileID: id, data: manifest.encoded(), mimeType: "application/json")
            } else {
                index.manifests[manifest.fileName] = try await client.upload(
                    name: manifest.fileName, data: manifest.encoded(), mimeType: "application/json", in: folder
                )
            }
            index.manifestDigests[manifest.fileName] = digest
            saveIndex()
            lastError = nil
        } catch DriveError.http(status: 404, _) {
            // Deleted on Drive since the last sync: create it again next time.
            index.manifests[manifest.fileName] = nil
            saveIndex()
        } catch {
            note(error, while: "writing an article manifest")
        }
    }

    // MARK: - Per article

    /// Keys known to be on Drive (from the local index).
    var indexedKeys: Set<String> { Set(index.files.keys) }

    /// Manifest file names known to be on Drive.
    var manifestNames: Set<String> { Set(index.manifests.keys) }

    /// Whether one article's audio on this iPhone is backed up to Drive.
    nonisolated struct ArticleBackup: Sendable, Equatable {
        enum State: Equatable, Sendable {
            /// No audio for this article on this iPhone or on Drive.
            case noAudio
            /// Everything on this iPhone is on Drive too.
            case backedUp
            /// Some audio is queued and will go up when uploads run.
            case uploading
            /// Some audio on this iPhone isn't on Drive and isn't queued (the next backup picks it up).
            case notBackedUp
        }

        /// Pieces of the article in the chosen voice.
        var pieces = 0
        /// Of those, how many are on this iPhone, and how many on Drive.
        var piecesHere = 0
        var piecesOnDrive = 0
        /// Size of the chosen voice's audio on this iPhone.
        var bytesHere: Int64 = 0
        /// Audio on this iPhone (any voice) queued for upload, and neither on Drive nor queued.
        var waiting = 0
        var missing = 0
        /// Pieces on Drive in the other voices.
        var otherVoicePieces = 0
        /// Whether the article's manifest is in Drive's articles folder.
        var hasManifest = false

        var state: State {
            if missing > 0 { return .notBackedUp }
            if waiting > 0 { return .uploading }
            if piecesHere == 0 && piecesOnDrive == 0 && otherVoicePieces == 0 { return .noAudio }
            return .backedUp
        }
    }

    /// Works out `ArticleBackup` for an article, off the main actor: which of its pieces are on this iPhone, which on
    /// Drive (`indexed`), which are queued (`pending`), and whether its manifest is listed (`manifests`).
    @concurrent
    static func backup(
        url: String, blocksData: Data, voice: String, indexed: Set<String>, pending: Set<String>, manifests: Set<String>,
        cache: SpeechAudioCache = .standard
    ) async -> ArticleBackup {
        let blocks = Article.decodeBlocks(blocksData)
        var result = ArticleBackup()
        result.hasManifest = manifests.contains(DriveManifest.urlHash(url) + ".json")
        var counted = Set<String>()
        func tally(_ key: String, isHere: Bool) {
            guard isHere, !indexed.contains(key) else { return }
            if pending.contains(key) { result.waiting += 1 } else { result.missing += 1 }
        }
        for piece in ArticleAudio.pieces(of: blocks, voice: voice) {
            let key = SpeechAudioCache.key(for: piece.request)
            guard counted.insert(key).inserted else { continue }
            result.pieces += 1
            let file = cache.fileURL(for: piece.request)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if let size {
                result.piecesHere += 1
                result.bytesHere += size
            }
            if indexed.contains(key) { result.piecesOnDrive += 1 }
            tally(key, isHere: size != nil)
        }
        for input in ArticleAudio.inputs(of: blocks) {
            for other in OpenAISpeechEngine.voices where other != voice {
                let request = OpenAISpeechEngine.request(for: input, voice: other)
                let key = SpeechAudioCache.key(for: request)
                guard counted.insert(key).inserted else { continue }
                if indexed.contains(key) { result.otherVoicePieces += 1 }
                tally(key, isHere: cache.cachedFile(for: request) != nil)
            }
        }
        return result
    }

    // MARK: - The library's audio

    /// Backs up the library incrementally: queues every piece of audio on this iPhone that belongs to it (any voice)
    /// and isn't on Drive, and brings the articles' manifests for `voice` up to date (only those that changed are
    /// written). Usually costs a request or two: Drive is compared with the local index, not asked piece by piece.
    /// - Returns: How many pieces were queued.
    @discardableResult
    func backUp(_ articles: [(title: String, url: String, blocksData: Data)], voice: String) async -> Int {
        guard isEnabled else { return 0 }
        lastBackUp = .now
        let local = await Self.localKeys(of: articles.map(\.blocksData), cache: cache)
        await syncIndex(force: true)
        guard lastSync != nil else { return 0 }  // Drive couldn't be listed; `lastError` says why
        let missing = local.filter { index.files[$0] == nil }
        enqueue(missing)
        for article in articles {
            let blocks = Article.decodeBlocks(article.blocksData)
            let manifest = DriveManifest(title: article.title, url: article.url, blocks: blocks, voice: voice)
            notedArticles[manifest.fileName] = manifest
        }
        if pendingUploads.isEmpty { await refreshNotedManifests() }
        if !missing.isEmpty { Log.app.info("Drive: backup queued \(missing.count) pieces") }
        return missing.count
    }

    /// `backUp`, unless it ran in the last `backUpInterval`: for when the app opens or comes back to the library.
    func backUpIfDue(_ articles: [(title: String, url: String, blocksData: Data)], voice: String) async {
        if let lastBackUp, Date.now.timeIntervalSince(lastBackUp) < Self.backUpInterval { return }
        await backUp(articles, voice: voice)
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
        if (error as? DriveError) == .missingDriveAccess { onAccessLost() }
        Log.app.error("Drive: failed \(doing, privacy: .public): \(message, privacy: .public)")
    }
}
