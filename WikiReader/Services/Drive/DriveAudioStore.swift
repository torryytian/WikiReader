import Foundation
import Observation
import OSLog

/// Where generated speech audio comes from before OpenAI is asked: a source that may already have it.
protocol RemoteAudioSource: AnyObject {
    /// Whether it can be asked at all (signed in).
    var isEnabled: Bool { get }
    /// Whether to ask it before generating: `isEnabled`, unless the reader turned that off.
    var looksUpBeforeGenerating: Bool { get }
    /// The audio for `request`, saved into `cache`, or nil if the source doesn't have it (or can't be reached).
    func fetch(_ request: OpenAISpeechRequest, into cache: SpeechAudioCache) async -> URL?
    /// `request`'s audio was just generated and stored in `cache`; share it.
    func didGenerate(_ request: OpenAISpeechRequest, in cache: SpeechAudioCache)
}

extension RemoteAudioSource {
    var looksUpBeforeGenerating: Bool { isEnabled }
}

/// An article as the Drive backup sees it.
nonisolated struct DriveArticle: Sendable {
    var title: String
    var url: String
    var blocksData: Data
    /// From the English Reader site: no `<urlHash>.json` for it (see `DriveAudioStore.noteArticle`).
    var isFromSite = false
}

extension Article {
    var driveArticle: DriveArticle {
        DriveArticle(
            title: title, url: sourceURL.absoluteString, blocksData: blocksData,
            isFromSite: !DriveAudioStore.listsArticle(self)
        )
    }
}

/// The audio cache shared through Google Drive with other devices and the Chrome extension
/// (format: docs/shared-tts-cache-format.md). Audio is looked for here after this iPhone's own cache and before
/// OpenAI; audio generated here is uploaded in the background; each article gets a manifest.
///
/// Backing up is incremental: a piece is uploaded right after it is generated, and `backUp` (run when the app opens,
/// after signing in, and when asked for some articles or all of them) compares their audio on this iPhone with the
/// index and queues only what Drive lacks, which also catches audio made while signed out or while uploads were failing.
/// Both automatic parts, and looking in Drive before generating, can be turned off in Settings (`looksUpFirst`,
/// `backsUpAutomatically`); what is asked for by hand always runs.
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

    /// The folder the apps create and use until the site moves everything (docs/shared-drive-layout.md §2).
    static let rootName = "WikiReader Cache"
    /// The site's folder, the one place for everything once its `format.json` says version 2. Only the site creates
    /// it and writes that file; the apps never do.
    static let sharedRootName = "English Reader"
    static let audioFolder = "audio"
    static let articlesFolder = "articles"
    static let formatFile = "format.json"
    /// What this app writes into a `WikiReader Cache/` it creates.
    static let formatContents: [String: Any] = ["formatVersion": 1, "key": "ios-v1"]
    static let indexFreshness: TimeInterval = 2 * 60
    /// Which folder to use is looked up again when the app comes to the front, if it was decided longer ago than this.
    static let layoutFreshness: TimeInterval = 5 * 60
    static let uploadConcurrency = 2
    static let maxRetryDelay: Duration = .seconds(300)

    struct Layout: Equatable {
        var root: String
        /// `rootName` or `sharedRootName`.
        var rootName: String
        var audio: String
        var articles: String
        /// The other of the two folders while both exist (before the site's move, or after it until the old one is
        /// deleted): looked in for audio and the word book, never written.
        var otherRoot: String?
        /// Its audio folder, when it has one of its own.
        var otherAudio: String?
    }

    /// What a folder's `format.json` says.
    nonisolated enum FolderFormat: Equatable, Sendable {
        /// No `format.json`.
        case none
        /// `WikiReader Cache/` as the apps write it: version 1.
        case legacy
        /// `English Reader/` once the site has moved everything into it: version 2.
        case shared
        /// `WikiReader Cache/` after the move: version 2 with `movedTo`.
        case moved
        /// Anything else, described for the error.
        case unknown(String)

        init(_ object: [String: Any]?) {
            let version = object?["formatVersion"] as? Int
            let key = object?["key"] as? String
            switch (version, key) {
            case (1, "ios-v1"): self = .legacy
            case (2, "ios-v1"): self = object?["movedTo"] is String ? .moved : .shared
            default: self = .unknown("formatVersion \(version.map(String.init) ?? "?"), key \(key ?? "?")")
            }
        }

        var description: String {
            switch self {
            case .none: "no format.json"
            case .legacy: "formatVersion 1, key ios-v1"
            case .shared: "formatVersion 2, key ios-v1"
            case .moved: "formatVersion 2, key ios-v1, moved"
            case .unknown(let found): found
            }
        }
    }

    /// The audio folders' contents as last seen, kept on disk between launches.
    struct AudioIndex: Codable, Equatable {
        /// The audio folder this describes; a different one (another account) starts over.
        var folder: String?
        /// File ids by key.
        var files: [String: String] = [:]
        /// The newest creation time seen, where the next look starts.
        var syncedThrough: String?
        /// The same for the other folder's audio folder (`Layout.otherAudio`), while there is one.
        var otherFolder: String?
        var otherFiles: [String: String] = [:]
        var otherSyncedThrough: String?
        /// The articles folder's manifests, file ids by file name, as of the last sync.
        var manifests: [String: String] = [:]
        /// What this iPhone last wrote into each manifest (a digest of everything but the time), so an unchanged
        /// manifest isn't written again on every launch.
        var manifestDigests: [String: String] = [:]

        init(folder: String? = nil) {
            self.folder = folder
        }

        // Indexes saved before manifests (or the other folder) were tracked lack those fields.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            folder = try container.decodeIfPresent(String.self, forKey: .folder)
            files = try container.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
            syncedThrough = try container.decodeIfPresent(String.self, forKey: .syncedThrough)
            otherFolder = try container.decodeIfPresent(String.self, forKey: .otherFolder)
            otherFiles = try container.decodeIfPresent([String: String].self, forKey: .otherFiles) ?? [:]
            otherSyncedThrough = try container.decodeIfPresent(String.self, forKey: .otherSyncedThrough)
            manifests = try container.decodeIfPresent([String: String].self, forKey: .manifests) ?? [:]
            manifestDigests = try container.decodeIfPresent([String: String].self, forKey: .manifestDigests) ?? [:]
        }

        /// The key's file in either audio folder.
        func file(for key: String) -> String? {
            files[key] ?? otherFiles[key]
        }

        /// Adds listed audio files (of the other folder's audio folder with `toOther`) and moves the place where the
        /// next look starts on to the newest.
        mutating func add(_ listed: [DriveClient.ListedFile], toOther: Bool = false) {
            for file in listed where file.name.hasSuffix(".mp3") {
                let key = String(file.name.dropLast(4))
                let created = file.createdTime ?? ""
                // Two devices uploading the same audio leave two copies; keep the one already known.
                if toOther {
                    if otherFiles[key] == nil { otherFiles[key] = file.id }
                    if created > (otherSyncedThrough ?? "") { otherSyncedThrough = created }
                } else {
                    if files[key] == nil { files[key] = file.id }
                    if created > (syncedThrough ?? "") { syncedThrough = created }
                }
            }
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

    /// A backup asked for by hand (not the automatic one), for its progress row.
    struct BackupRun: Equatable {
        /// Pieces it found missing on Drive, and how many of them have gone up since.
        var total = 0
        var done = 0
        var isFinished: Bool { done >= total }
    }

    /// The latest backup asked for by hand, until its finished summary is dismissed.
    private(set) var backupRun: BackupRun?

    /// The Drive folder in use (`rootName` or `sharedRootName`), once known, for Settings.
    private(set) var folderName: String?

    @ObservationIgnored private let client: DriveClient
    @ObservationIgnored private let isSignedIn: () -> Bool
    @ObservationIgnored private let cache: SpeechAudioCache
    @ObservationIgnored private let queueFile: URL
    @ObservationIgnored private let indexFile: URL
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let canUploadNow: () -> Bool
    @ObservationIgnored private let onAccessLost: () -> Void
    @ObservationIgnored private let keepAwake: (Bool) -> Void
    @ObservationIgnored private let looksUpFirst: () -> Bool
    @ObservationIgnored private let backsUpAutomatically: () -> Bool
    /// Whether the English Reader site serves this key's audio: the site keeps the original on Drive itself, and what
    /// this iPhone has of it is the site's compressed copy, which must not go into Drive's folder of originals.
    @ObservationIgnored private let isSiteAudio: (String) -> Bool
    @ObservationIgnored private let layoutRecheck: TimeInterval
    /// The pieces of `backupRun` still to go up.
    @ObservationIgnored private var runKeys: Set<String> = []
    @ObservationIgnored private var layoutTask: Task<Layout, Error>?
    /// When `layoutTask` started, so coming to the front can look again after `layoutFreshness`.
    @ObservationIgnored private var layoutStarted: Date?
    @ObservationIgnored private var lastLayout: Layout?
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
        keepAwake: @escaping (Bool) -> Void = { ScreenAwake.set("drive upload", $0) },
        looksUpFirst: @escaping () -> Bool = { SettingsKeys.isOn(SettingsKeys.driveLookUpFirst) },
        backsUpAutomatically: @escaping () -> Bool = { SettingsKeys.isOn(SettingsKeys.driveAutoBackUp) },
        isSiteAudio: @escaping (String) -> Bool = { SiteLibrary.shared.audioURL(forKey: $0) != nil },
        layoutRecheck: TimeInterval = DriveAudioStore.layoutFreshness
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
        self.looksUpFirst = looksUpFirst
        self.backsUpAutomatically = backsUpAutomatically
        self.isSiteAudio = isSiteAudio
        self.layoutRecheck = layoutRecheck
        pendingUploads = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: queueFile))) ?? []
        index = (try? JSONDecoder().decode(AudioIndex.self, from: Data(contentsOf: indexFile))) ?? AudioIndex()
    }

    var isEnabled: Bool { isSignedIn() }

    /// Signed in, and Settings' "Check Drive First" is on: playing and downloading take audio from Drive before
    /// paying OpenAI for it.
    var looksUpBeforeGenerating: Bool { isEnabled && looksUpFirst() }

    /// Signed in, and new audio is backed up without being asked.
    var isBackingUpAutomatically: Bool { isEnabled && backsUpAutomatically() }

    /// Forgets what was learned about Drive (after signing out or in as someone else).
    func reset() {
        layoutTask?.cancel()
        layoutTask = nil
        layoutStarted = nil
        lastLayout = nil
        folderName = nil
        index = AudioIndex()
        lastSync = nil
        try? FileManager.default.removeItem(at: indexFile)
        notedArticles = [:]
        lastBackUp = nil
        lastError = nil
        runKeys = []
        backupRun = nil
    }

    // MARK: - The shared folder

    /// The folders in use, found (or, the first time on an account, created) once, and looked up again when the app
    /// comes to the front (`appBecameActive`), since the site may have moved everything in the meantime.
    func layout() async throws -> Layout {
        if let layoutTask { return try await layoutTask.value }
        let client = client
        let task = Task { () throws -> Layout in try await Self.findLayout(client: client) }
        layoutTask = task
        layoutStarted = .now
        do {
            let layout = try await task.value
            if let lastLayout, lastLayout != layout {
                Log.app.info("Drive: now using \(layout.rootName, privacy: .public)")
                lastSync = nil  // list the (maybe different) folders again before trusting "not on Drive"
            }
            lastLayout = layout
            folderName = layout.rootName
            return layout
        } catch {
            if layoutTask == task { layoutTask = nil }  // try again next time
            throw error
        }
    }

    /// Coming to the front: which folder to use is decided again before Drive is next used, unless that was just done.
    func appBecameActive() {
        guard let layoutStarted, Date.now.timeIntervalSince(layoutStarted) >= layoutRecheck else { return }
        layoutTask = nil
        self.layoutStarted = nil
    }

    /// Which folder to use (docs/shared-drive-layout.md §2): `English Reader/` once the site has moved everything into it
    /// (its `format.json` says version 2, or the old folder's says where it went); until then `WikiReader Cache/`,
    /// created with a version 1 `format.json` on an account that has neither. Only the site creates `English Reader/`
    /// and writes its version 2: if a listing ever missed `WikiReader Cache/`, an app writing it would switch every
    /// device to an empty folder, which then pays OpenAI again.
    static func findLayout(client: DriveClient) async throws -> Layout {
        async let sharedFound = client.folder(named: sharedRootName, in: "root")
        async let legacyFound = client.folder(named: rootName, in: "root")
        let shared = try await sharedFound
        let legacy = try await legacyFound
        async let sharedFormatRead = format(in: shared, client: client)
        async let legacyFormatRead = format(in: legacy, client: client)
        let sharedFormat = try await sharedFormatRead
        let legacyFormat = try await legacyFormatRead

        let root: String, name: String, other: String?
        if let shared, sharedFormat == .shared || legacyFormat == .moved {
            (root, name, other) = (shared, sharedRootName, legacy)
        } else if let legacy {
            switch legacyFormat {
            case .none, .legacy:
                if legacyFormat == .none { try await writeFormat(in: legacy, client: client) }
                (root, name, other) = (legacy, rootName, shared)
            case .moved:
                throw DriveError.unsupportedFormat("\(rootName) says it moved to \(sharedRootName), which isn't in Drive")
            case .shared, .unknown:
                // Exactly what the Chrome extension refuses too, so neither writes into a folder the other refuses.
                throw DriveError.unsupportedFormat(legacyFormat.description)
            }
        } else {
            let created = try await client.createFolder(named: rootName, in: "root")
            Log.app.info("Created the Drive folder \(rootName, privacy: .public)")
            try await writeFormat(in: created, client: client)
            (root, name, other) = (created, rootName, shared)
        }

        let otherAudio: String? = if let other { try await client.folder(named: audioFolder, in: other) } else { nil }
        // An audio folder missing here while the other folder has one is being moved by the site right now (it moves
        // the whole folder): use that one rather than starting an empty one.
        let audio: String
        if let found = try await client.folder(named: audioFolder, in: root) {
            audio = found
        } else if let otherAudio {
            audio = otherAudio
        } else {
            audio = try await client.createFolder(named: audioFolder, in: root)
        }
        let articles = try await subfolder(articlesFolder, in: root, client: client)
        return Layout(
            root: root, rootName: name, audio: audio, articles: articles,
            otherRoot: other, otherAudio: otherAudio == audio ? nil : otherAudio
        )
    }

    private static func subfolder(_ name: String, in root: String, client: DriveClient) async throws -> String {
        if let found = try await client.folder(named: name, in: root) { return found }
        return try await client.createFolder(named: name, in: root)
    }

    /// What `folder`'s `format.json` says (`.none` without a folder or a file).
    private static func format(in folder: String?, client: DriveClient) async throws -> FolderFormat {
        guard let folder, let id = try await client.files(named: [formatFile], in: folder)[formatFile] else { return .none }
        return FolderFormat(try? JSONSerialization.jsonObject(with: try await client.download(fileID: id)) as? [String: Any])
    }

    private static func writeFormat(in folder: String, client: DriveClient) async throws {
        let data = try JSONSerialization.data(withJSONObject: formatContents, options: [.sortedKeys])
        _ = try await client.upload(name: formatFile, data: data, mimeType: "application/json", in: folder)
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
            let listed = try await Self.list(audio, after: index.syncedThrough, client: client)
            index.add(listed)
            // While both folders exist, audio in the other one counts too (the site moves the audio folder whole, so
            // usually there is only one).
            if index.otherFolder != layout.otherAudio {
                index.otherFolder = layout.otherAudio
                index.otherFiles = [:]
                index.otherSyncedThrough = nil
            }
            if let otherAudio = layout.otherAudio {
                let listedOther = try await Self.list(otherAudio, after: index.otherSyncedThrough, client: client)
                index.add(listedOther, toOther: true)
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

    /// Lists the audio files created in `folder` since `syncedThrough` (a minute's overlap allows for clocks and Drive's
    /// ordering).
    private static func list(_ folder: String, after syncedThrough: String?, client: DriveClient) async throws -> [DriveClient.ListedFile] {
        try await client.listFolder(folder, createdAfter: syncedThrough.flatMap { rfc3339(minus: 60, from: $0) })
    }


    /// For callers about to need these keys: the index answers for all of them at once, so it is only brought up to date.
    func prepareIndex(keys: [String]) async {
        await syncIndex()
    }

    /// Whether the key's audio is on Drive, as far as is known (nil: the index isn't fresh enough to say "no").
    func isOnDrive(_ key: String) -> Bool? {
        if index.file(for: key) != nil { return true }
        guard let lastSync, Date.now.timeIntervalSince(lastSync) < Self.indexFreshness else { return nil }
        return false
    }

    func fetch(_ request: OpenAISpeechRequest, into cache: SpeechAudioCache) async -> URL? {
        guard isEnabled else { return nil }
        let key = SpeechAudioCache.key(for: request)
        if isOnDrive(key) == nil { await syncIndex() }
        guard let id = index.file(for: key) else { return nil }
        do {
            let data = try await client.download(fileID: id)
            let url = try cache.store(data, for: request)
            downloadedCount += 1
            lastError = nil
            Log.app.info("Drive: took a piece from Drive (\(data.count) bytes)")
            return url
        } catch DriveError.http(status: 404, _) {
            // Deleted on Drive since it was indexed.
            if index.files[key] == id { index.files[key] = nil }
            if index.otherFiles[key] == id { index.otherFiles[key] = nil }
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
        guard isBackingUpAutomatically, cache.directory == self.cache.directory else { return }
        enqueue([SpeechAudioCache.key(for: request)])
    }

    /// Queues audio in this iPhone's cache for upload; keys already on Drive or queued are skipped, and so is audio the
    /// English Reader site serves (it keeps the originals on Drive; this iPhone only has its compressed copy).
    func enqueue(_ keys: [String]) {
        var queued = Set(pendingUploads)
        let new = keys.filter { index.file(for: $0) == nil && !isSiteAudio($0) && queued.insert($0).inserted }
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
                if index.file(for: key) == nil {
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
        if runKeys.remove(key) != nil { backupRun?.done += 1 }
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
    /// if it changed. Written again once queued uploads finish, so `complete` catches up. With automatic backup off
    /// nothing is written (only a backup asked for lists an article), and with Drive not looked in either, nothing is done.
    /// - Parameter listsArticle: False for an article from the English Reader site: its text may have been edited
    ///   there, and `<urlHash>.json` is only for text the shared cleaner took from that URL (the site lists its own).
    func noteArticle(title: String, url: String, blocks: [ContentBlock], voice: String, listsArticle: Bool = true) async {
        guard isEnabled, !blocks.isEmpty else { return }
        let shares = backsUpAutomatically()
        guard shares || looksUpFirst() else { return }
        guard shares, listsArticle else {
            await syncIndex()
            return
        }
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

    /// Writes `base` over what Drive has under its name (docs/shared-drive-layout.md §3): Drive's is read first, a manifest
    /// made for another voice is left alone (its text is what that audio was made from), and fields this app doesn't
    /// know are kept.
    private func writeManifest(_ base: DriveManifest) async {
        var manifest = base
        manifest.complete = manifest.keys.allSatisfy { index.file(for: $0) != nil }
        manifest.updatedAt = ISO8601DateFormatter().string(from: .now)
        let digest = manifest.contentDigest
        let name = manifest.fileName
        // Written before with the same content and still there: nothing to do, and no request.
        if index.manifestDigests[name] == digest, index.manifests[name] != nil { return }
        do {
            let folder = try await layout().articles
            if let id = index.manifests[name] {
                switch DriveManifest.write(manifest, over: try await client.download(fileID: id)) {
                case .leave:
                    Log.app.info("Drive: \(name, privacy: .public) is for another voice; left as it is")
                case .replace(let data):
                    try await client.replace(fileID: id, data: data, mimeType: "application/json")
                case .create(let data):
                    index.manifests[name] = try await upload(manifest, data: data, in: folder)
                }
            } else {
                index.manifests[name] = try await upload(manifest, data: manifest.encoded(), in: folder)
            }
            index.manifestDigests[name] = digest
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

    /// A new manifest file, with the article's title as its Drive description and the public properties people and
    /// the other apps can recognise it by (lookups go by file name only).
    private func upload(_ manifest: DriveManifest, data: Data, in folder: String) async throws -> String {
        let kind = URL(string: manifest.url)?.scheme == Article.importedScheme ? "imported" : "wikipedia"
        return try await client.upload(
            name: manifest.fileName, data: data, mimeType: "application/json", in: folder,
            description: manifest.title, properties: manifest.driveProperties(kind: kind)
        )
    }

    // MARK: - Per article

    /// Keys known to be on Drive (from the local index).
    var indexedKeys: Set<String> { Set(index.files.keys).union(index.otherFiles.keys) }

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
        /// Of those on Drive, the ones not on this iPhone, and their length: what downloading from Drive would bring.
        var piecesOnlyOnDrive = 0
        var charactersOnlyOnDrive = 0
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
            if indexed.contains(key) {
                result.piecesOnDrive += 1
                if size == nil {
                    result.piecesOnlyOnDrive += 1
                    result.charactersOnlyOnDrive += piece.characters
                }
            }
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

    /// What `backUp` found.
    nonisolated struct BackupResult: Equatable, Sendable {
        /// Pieces of the articles' audio on this iPhone, in any voice.
        var onThisIPhone = 0
        /// Of those, the ones Drive lacks, now queued (or already queued before).
        var missing = 0
    }

    /// Backs up articles incrementally: queues every piece of audio on this iPhone that belongs to them (any voice)
    /// and isn't on Drive, and brings their manifests for `voice` up to date (only those that changed are written).
    /// Usually costs a request or two: Drive is compared with the local index, not asked piece by piece.
    /// - Parameter showsProgress: Asked for by hand: `backupRun` follows the pieces it queued.
    /// - Returns: What was found, or nil if Drive couldn't be listed (`lastError` says why).
    @discardableResult
    func backUp(_ articles: [DriveArticle], voice: String, showsProgress: Bool = false) async -> BackupResult? {
        guard isEnabled else { return nil }
        let local = await Self.localKeys(of: articles.map(\.blocksData), cache: cache)
        await syncIndex(force: true)
        guard lastSync != nil else { return nil }
        let missing = local.filter { index.file(for: $0) == nil && !isSiteAudio($0) }
        if showsProgress, !missing.isEmpty { follow(missing) }
        enqueue(missing)
        for article in articles where !article.isFromSite {
            let blocks = Article.decodeBlocks(article.blocksData)
            let manifest = DriveManifest(title: article.title, url: article.url, blocks: blocks, voice: voice)
            notedArticles[manifest.fileName] = manifest
        }
        if pendingUploads.isEmpty { await refreshNotedManifests() }
        if !missing.isEmpty { Log.app.info("Drive: backup queued \(missing.count) pieces") }
        return BackupResult(onThisIPhone: local.count, missing: missing.count)
    }

    /// `backUp` of the whole library, unless it ran in the last `backUpInterval` or automatic backup is off: for when
    /// the app opens or comes back to the library.
    func backUpIfDue(_ articles: [DriveArticle], voice: String) async {
        guard isBackingUpAutomatically else { return }
        if let lastBackUp, Date.now.timeIntervalSince(lastBackUp) < Self.backUpInterval { return }
        lastBackUp = .now
        await backUp(articles, voice: voice)
    }

    /// Adds pieces to `backupRun` (a new one if the last has finished).
    private func follow(_ keys: [String]) {
        if backupRun?.isFinished ?? true {
            backupRun = BackupRun()
            runKeys = []
        }
        let new = Set(keys).subtracting(runKeys)
        runKeys.formUnion(new)
        backupRun?.total += new.count
    }

    /// Stops the backup asked for: what it queued and hasn't started uploading is taken off the queue (an automatic
    /// backup, if on, finds it again later). Uploads already running finish.
    func stopBackupRun() {
        pendingUploads.removeAll { runKeys.contains($0) && !uploadsInFlight.contains($0) }
        saveQueue()
        runKeys = []
        backupRun = nil
    }

    /// Clears a finished backup's summary.
    func dismissBackupRun() {
        if backupRun?.isFinished ?? false { backupRun = nil }
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

    /// Whether `article` may get a `<urlHash>.json` manifest (not one from the English Reader site).
    static func listsArticle(_ article: Article) -> Bool {
        article.origin != Article.siteOrigin
    }

    // MARK: - Errors

    private func note(_ error: Error, while doing: String) {
        let message = (error as? DriveError)?.message ?? (error as? GoogleAuthError)?.message ?? error.localizedDescription
        lastError = message
        if (error as? DriveError) == .missingDriveAccess { onAccessLost() }
        Log.app.error("Drive: failed \(doing, privacy: .public): \(message, privacy: .public)")
    }
}
