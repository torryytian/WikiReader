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
/// What is known to be on Drive is kept in memory: an article's pieces are looked up together when it opens (a few
/// queries for a long article), so playing a piece rarely waits for Drive to answer "no". A "no" is trusted for
/// `absentLifetime`, after which another device may have uploaded it.
@Observable
final class DriveAudioStore: RemoteAudioSource {
    static let shared = DriveAudioStore()

    static let rootName = "WikiReader Cache"
    static let audioFolder = "audio"
    static let articlesFolder = "articles"
    static let formatFile = "format.json"
    static let formatContents: [String: Any] = ["formatVersion": 1, "key": "ios-v1"]
    static let absentLifetime: TimeInterval = 10 * 60

    struct Layout: Equatable {
        var root: String
        var audio: String
        var articles: String
    }

    /// Keys of audio generated here and not uploaded yet, oldest first. Kept on disk, so nothing is lost if the app quits.
    private(set) var pendingUploads: [String] = []
    private(set) var isUploading = false
    /// The last thing that went wrong talking to Drive, for Settings; cleared by the next success.
    private(set) var lastError: String?
    /// Audio taken from Drive and uploaded to it since the app started, for Settings.
    private(set) var downloadedCount = 0
    private(set) var uploadedCount = 0

    @ObservationIgnored private let client: DriveClient
    @ObservationIgnored private let isSignedIn: () -> Bool
    @ObservationIgnored private let cache: SpeechAudioCache
    @ObservationIgnored private let queueFile: URL
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var layoutTask: Task<Layout, Error>?
    /// File ids of audio known to be on Drive, by key.
    @ObservationIgnored private var present: [String: String] = [:]
    /// When each key was last found missing on Drive.
    @ObservationIgnored private var absent: [String: Date] = [:]
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
        retryDelay: Duration = .seconds(60)
    ) {
        self.client = client
        self.isSignedIn = isSignedIn
        self.cache = cache
        self.queueFile = queueFile
        self.retryDelay = retryDelay
        pendingUploads = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: queueFile))) ?? []
    }

    var isEnabled: Bool { isSignedIn() }

    /// Forgets what was learned about Drive (after signing out or in as someone else).
    func reset() {
        layoutTask?.cancel()
        layoutTask = nil
        present = [:]
        absent = [:]
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

    /// Looks up which of these keys are on Drive, in a few queries, so later lookups are answered from memory.
    func prepareIndex(keys: [String]) async {
        guard isEnabled else { return }
        let unknown = Array(Set(keys.filter { present[$0] == nil && !isKnownAbsent($0) }))
        guard !unknown.isEmpty else { return }
        do {
            let audio = try await layout().audio
            let found = try await client.files(named: unknown.map { $0 + ".mp3" }, in: audio)
            let now = Date.now
            for key in unknown {
                if let id = found[key + ".mp3"] { present[key] = id } else { absent[key] = now }
            }
            lastError = nil
            Log.app.info("Drive: \(found.count) of \(unknown.count) pieces are on Drive")
        } catch {
            note(error, while: "looking up audio")
        }
    }

    /// Whether the key's audio is on Drive, as far as is known (nil: not looked up, or the answer went stale).
    func isOnDrive(_ key: String) -> Bool? {
        if present[key] != nil { return true }
        return isKnownAbsent(key) ? false : nil
    }

    private func isKnownAbsent(_ key: String) -> Bool {
        guard let when = absent[key] else { return false }
        return Date.now.timeIntervalSince(when) < Self.absentLifetime
    }

    func fetch(_ request: OpenAISpeechRequest, into cache: SpeechAudioCache) async -> URL? {
        guard isEnabled else { return nil }
        let key = SpeechAudioCache.key(for: request)
        if isOnDrive(key) == nil { await prepareIndex(keys: [key]) }
        guard let id = present[key] else { return nil }
        do {
            let data = try await client.download(fileID: id)
            let url = try cache.store(data, for: request)
            downloadedCount += 1
            lastError = nil
            Log.app.info("Drive: took a piece from Drive (\(data.count) bytes)")
            return url
        } catch {
            note(error, while: "downloading audio")
            return nil
        }
    }

    // MARK: - Uploading

    func didGenerate(_ request: OpenAISpeechRequest, in cache: SpeechAudioCache) {
        // Only the app's own cache: tests and samples in other folders aren't shared.
        guard isEnabled, cache.directory == self.cache.directory else { return }
        enqueue([SpeechAudioCache.key(for: request)])
    }

    /// Queues audio in this iPhone's cache for upload; keys already on Drive or queued are skipped.
    func enqueue(_ keys: [String]) {
        let queued = Set(pendingUploads)
        let new = keys.filter { !queued.contains($0) && present[$0] == nil }
        guard !new.isEmpty else { return }
        pendingUploads += new
        saveQueue()
        pumpUploads()
    }

    /// Uploads the queue one file at a time. A failure stops it and it tries again after `retryDelay` (or when more
    /// audio is queued); nothing is dropped.
    func pumpUploads() {
        guard !isUploading, isEnabled, !pendingUploads.isEmpty else { return }
        isUploading = true
        Task {
            defer { isUploading = false }
            while let key = pendingUploads.first {
                guard isEnabled else { return }
                let file = cache.directory.appending(path: key + "." + OpenAITTSClient.audioFormat)
                guard let data = try? Data(contentsOf: file) else {
                    dropFromQueue(key)  // deleted since: nothing to share
                    continue
                }
                do {
                    let audio = try await layout().audio
                    if present[key] == nil, let existing = try await client.files(named: [key + ".mp3"], in: audio)[key + ".mp3"] {
                        present[key] = existing  // another device got there first
                    } else if present[key] == nil {
                        present[key] = try await client.upload(name: key + ".mp3", data: data, mimeType: "audio/mpeg", in: audio)
                        uploadedCount += 1
                    }
                    absent[key] = nil
                    dropFromQueue(key)
                    lastError = nil
                } catch {
                    note(error, while: "uploading audio")
                    scheduleRetry()
                    return
                }
            }
            Log.app.info("Drive: upload queue empty")
            await refreshNotedManifests()
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

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
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
        await prepareIndex(keys: manifest.keys)
        await writeManifest(manifest)
    }

    private func refreshNotedManifests() async {
        for manifest in notedArticles.values {
            await writeManifest(manifest)
        }
    }

    private func writeManifest(_ base: DriveManifest) async {
        var manifest = base
        manifest.complete = manifest.keys.allSatisfy { present[$0] != nil }
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
        await prepareIndex(keys: local)
        let missing = local.filter { present[$0] == nil }
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
