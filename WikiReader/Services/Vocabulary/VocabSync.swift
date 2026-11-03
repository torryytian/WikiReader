import Foundation
import Observation
import OSLog

/// Keeps the saved-word book the same here, on other devices and in the Chrome extension, through
/// `WikiReader Cache/vocab.json` on Google Drive (docs/shared-vocab-format.md §7). Free: Drive only.
///
/// A sync downloads the file, merges it with this iPhone's book, keeps the result here, and uploads it only if it
/// differs from what was there: usually two or three requests. It runs when the app comes to the front, a few
/// seconds after a word is saved or deleted (several changes, one sync), after signing in, and from Settings.
@Observable
final class VocabSync {
    static let shared = VocabSync()

    static let fileName = "vocab.json"
    static let debounce: Duration = .seconds(5)

    enum State: Equatable {
        case idle
        case syncing
        case synced
        /// Drive still has Chrome's first format: the extension converts it, this app doesn't touch it.
        case waitingForChrome
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var lastSynced: Date?

    @ObservationIgnored private let book: VocabularyBook
    @ObservationIgnored private let client: DriveClient
    @ObservationIgnored private let isSignedIn: () -> Bool
    @ObservationIgnored private let rootFolder: () async throws -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?

    init(
        book: VocabularyBook = .shared,
        client: DriveClient = DriveClient(token: { force in try await GoogleAccount.shared.validAccessToken(force: force) }),
        isSignedIn: @escaping () -> Bool = { GoogleAccount.shared.isSignedIn },
        rootFolder: @escaping () async throws -> String = { try await DriveAudioStore.shared.layout().root },
        now: @escaping () -> Date = Date.init
    ) {
        self.book = book
        self.client = client
        self.isSignedIn = isSignedIn
        self.rootFolder = rootFolder
        self.now = now
    }

    /// A sync shortly, so a burst of changes is sent once.
    func scheduleSync(after delay: Duration = VocabSync.debounce) {
        guard isSignedIn() else { return }
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Syncs now. A sync asked for while one runs makes it go round once more.
    func sync() async {
        guard isSignedIn() else { return }
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                again = false
                await syncOnce()
            } while again
        }
        running = task
        await task.value
        running = nil
    }

    private func syncOnce() async {
        state = .syncing
        do {
            let root = try await rootFolder()
            let id = try await client.files(named: [Self.fileName], in: root)[Self.fileName]
            var remote: VocabFile?
            if let id {
                let file = try VocabFile.decode(try await client.download(fileID: id))
                if file.formatVersion == 1 {
                    state = .waitingForChrome
                    Log.app.info("Vocabulary sync: Drive has the first format; waiting for the Chrome extension")
                    return
                }
                guard file.formatVersion == VocabFile.currentVersion else {
                    throw VocabSyncError.unknownVersion(file.formatVersion)
                }
                remote = file
            }

            let local = book.file
            if remote == nil && local.entries.isEmpty && local.deleted.isEmpty {
                finish()
                return
            }
            var merged = VocabFormat.merge(local, remote, now: VocabFormat.milliseconds(now()), by: "ios")
            // Changed here while Drive was being asked: merge that in too (merging is order-free and idempotent).
            if book.file != local {
                merged = VocabFormat.merge(book.file, merged, now: VocabFormat.milliseconds(now()), by: "ios")
            }
            book.replace(with: merged)

            if let remote, VocabFormat.sameContent(merged, remote) {
                Log.app.info("Vocabulary sync: up to date (\(merged.entries.count) words)")
            } else {
                let data = try merged.encoded()
                if let id {
                    try await client.replace(fileID: id, data: data, mimeType: "application/json")
                } else {
                    _ = try await client.upload(name: Self.fileName, data: data, mimeType: "application/json", in: root)
                }
                Log.app.info("Vocabulary sync: wrote \(merged.entries.count) words to Drive")
            }
            finish()
        } catch {
            let message = (error as? DriveError)?.message ?? (error as? VocabSyncError)?.message ?? error.localizedDescription
            state = .failed(message)
            Log.app.error("Vocabulary sync failed: \(message, privacy: .public)")
        }
    }

    private func finish() {
        state = .synced
        lastSynced = now()
    }
}

enum VocabSyncError: Error {
    case unknownVersion(Int)

    var message: String {
        switch self {
        case .unknownVersion(let version):
            "The word book in Google Drive is in a newer format (\(version)). Update WikiReader."
        }
    }
}
