import Foundation
import Observation
import OSLog
import UIKit

/// What is remembered between launches about keeping the word book in step with the site.
nonisolated struct VocabSiteState: Codable, Equatable, Sendable {
    /// How far through the site's changes this iPhone is. Nil: the two books haven't been compared yet, so a full sync
    /// comes first.
    var cursor: String?
    /// Words changed here and not yet sent.
    var pending: Set<String> = []
    /// Refused for a time in the future (a wrong clock): tried again when the app next comes to the front. Dropping
    /// them, as the spec says, would leave them off the site for good, even with the clock put right.
    var held: Set<String> = []
    /// What was last sent, until the site's answer has arrived. Sent again exactly as it was, under the same id.
    var batch: VocabPushBatch?
}

/// How a full sync ended, for offering to undo it.
struct VocabFullSyncOutcome: Equatable, Sendable {
    /// How many words this iPhone has now.
    var deviceWords: Int
    /// How many words the site has now.
    var siteWords: Int
    /// Set when the site changed and can be put back.
    var undoID: String?
    /// Whether this iPhone's book changed.
    var changedHere: Bool
    /// Changes that were waiting to be sent when the book was compared.
    var pendingBefore: Set<String>

    var canUndo: Bool { undoID != nil || changedHere }
}

/// Keeps the word book the same here and on English Reader, for the account signed in with `SiteAccount`
/// (docs/vocab-sync-v1.md). The site is the centre: the website and every signed-in device exchange changes with it,
/// and this replaces Drive's `vocab.json` (`VocabSync`) for as long as the account stays signed in.
///
/// Like a replica following a primary's log: changes made here are sent about five seconds later, and the site's
/// changes are read from a cursor, every 30 seconds while the app is on screen. This is what "live" can mean here,
/// since a free developer account has no push notifications. Both ends merge by the shared format's rules, so it
/// doesn't matter who hears of a change first, and a word deleted anywhere goes everywhere.
///
/// Before the two books have been compared there is no cursor and nothing is exchanged: a full sync comes first, and
/// never without the user's say (`startFullSync`, `finishFullSync`).
@Observable
final class VocabSiteSync {
    static let shared = VocabSiteSync()

    static let debounce: Duration = .seconds(5)
    /// How often the site is asked for changes while the app is on screen.
    static let pollInterval: Duration = .seconds(30)
    /// The longest wait between tries after a failure, in seconds.
    static let longestRetry = 300
    /// The cursor of a book that has nothing to compare: everything on the site is simply taken in.
    static let startCursor = "0"

    enum Status: Equatable {
        /// Not signed in: the word book isn't this class's business.
        case off
        case syncing
        case synced
        case offline
        case needsSignIn
        case needsFullSync
        case failed(String)
    }

    private enum Activity: Equatable {
        case idle
        case syncing
        case synced
        case offline
        case failed(String)
    }

    private(set) var lastSynced: Date?
    /// The site refused a word for being dated in the future.
    private(set) var clockLooksWrong = false
    private var state: VocabSiteState
    private var activity = Activity.idle

    @ObservationIgnored private let book: VocabularyBook
    @ObservationIgnored private let account: SiteAccount
    @ObservationIgnored private let client: SiteVocabClient
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let backupURL: URL
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// A full sync is on screen: nothing else moves until it is settled, or its numbers would stop being true.
    @ObservationIgnored private var isFullSyncOpen = false
    /// The book's version when it was sent for comparing.
    @ObservationIgnored private var comparedVersion: Int?

    init(
        book: VocabularyBook = .shared,
        account: SiteAccount = .shared,
        client: SiteVocabClient = SiteVocabClient(),
        directory: URL = URL.applicationSupportDirectory,
        debounce: Duration = VocabSiteSync.debounce,
        pollInterval: Duration = VocabSiteSync.pollInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.book = book
        self.account = account
        self.client = client
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.now = now
        stateURL = directory.appending(path: "VocabularySiteSync.json")
        backupURL = directory.appending(path: "Vocabulary-before-full-sync.json")
        state = (try? JSONDecoder().decode(VocabSiteState.self, from: Data(contentsOf: stateURL))) ?? VocabSiteState()
        book.onLocalKeysChange = { [weak self] keys in self?.noteLocalChange(keys) }
    }

    /// Where things stand, for showing.
    var status: Status {
        switch account.state {
        case .signedOut: return .off
        case .needsSignIn: return .needsSignIn
        case .signedIn: break
        }
        guard state.cursor != nil else { return .needsFullSync }
        switch activity {
        case .idle, .syncing: return .syncing
        case .synced: return .synced
        case .offline: return .offline
        case .failed(let message): return .failed(message)
        }
    }

    /// Changes made here that the site hasn't confirmed.
    var waitingCount: Int {
        state.pending.count + state.held.count + (state.batch?.changes.count ?? 0)
    }

    private var isWaiting: Bool { !state.pending.isEmpty || state.batch != nil }

    /// `status` in a few words.
    var statusText: String {
        switch status {
        case .off: return "Not signed in"
        case .syncing: return "Syncing…"
        case .needsSignIn: return "Sign in again"
        case .needsFullSync: return "Full sync needed"
        case .failed(let message): return message
        case .offline: return waitingCount == 0 ? "Offline" : "Offline, \(Self.changes(waitingCount)) waiting"
        case .synced:
            if clockLooksWrong { return "Check this iPhone's date and time" }
            if waitingCount > 0 { return "\(Self.changes(waitingCount)) waiting" }
            return lastSynced.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Synced"
        }
    }

    private static func changes(_ count: Int) -> String {
        count == 1 ? "1 change" : "\(count) changes"
    }

    // MARK: - Signing in and out

    /// Signs in and makes this the account's book. If the book has words, `status` then asks for a full sync; an
    /// empty one simply takes in what the site has.
    func signIn() async throws(SiteAuthError) {
        await running?.value
        let user = try await account.signIn()
        book.belong(to: user.email.lowercased())
        state = VocabSiteState()
        if book.file.entries.isEmpty && book.file.deleted.isEmpty { state.cursor = Self.startCursor }
        saveState()
        failures = 0
        activity = .idle
        clockLooksWrong = false
        await sync()
    }

    /// Signs out on purpose: the words stay here, and the word book goes back to Drive if that is signed in.
    func signOut() async {
        await running?.value
        scheduled?.cancel()
        await account.signOut()
        state = VocabSiteState()
        saveState()
        activity = .idle
        clockLooksWrong = false
    }

    // MARK: - Everyday sync

    private func noteLocalChange(_ keys: Set<String>) {
        guard account.keepsWordBook else { return }
        state.pending.formUnion(keys)
        state.held.subtract(keys)
        saveState()
        scheduleSync()
    }

    /// A sync shortly, so a burst of changes is sent once.
    func scheduleSync(after delay: Duration? = nil) {
        guard isReady() else { return }
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: delay ?? debounce)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// The app came to the front: words held back are tried again, and the site is asked for changes from now on.
    func appBecameActive() {
        if !state.held.isEmpty {
            state.pending.formUnion(state.held)
            state.held = []
            saveState()
        }
        polling?.cancel()
        polling = Task {
            while !Task.isCancelled {
                await sync()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// The app left the screen: no more asking, and what is waiting goes now rather than at the next launch (iOS
    /// gives a leaving app about half a minute to finish).
    func appWentToBackground() {
        polling?.cancel()
        polling = nil
        scheduled?.cancel()
        guard isWaiting, isReady(), backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Word book") { [weak self] in
            self?.endBackgroundTask()
        }
        Task {
            await sync()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Syncs now, from a button: shows that it is working even if the last try failed.
    func syncNow() async {
        guard isReady() else { return }
        activity = .syncing
        await sync()
    }

    /// Sends what is waiting, then takes in what changed on the site. A sync asked for while one runs makes it go
    /// round once more.
    func sync() async {
        guard isReady() else { return }
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                again = false
                await syncOnce()
            } while again && isReady()
        }
        running = task
        await task.value
        running = nil
    }

    private func isReady() -> Bool {
        guard account.isSignedIn else {
            // The key was refused somewhere else (reading an article): the cursor goes with it.
            if state.cursor != nil {
                state.cursor = nil
                saveState()
            }
            return false
        }
        return state.cursor != nil && !isFullSyncOpen
    }

    private func syncOnce() async {
        if activity == .idle || (activity == .synced && isWaiting) { activity = .syncing }
        do throws(SiteVocabError) {
            try await push()
            try await pull()
            failures = 0
            lastSynced = now()
            activity = .synced
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: SiteVocabError) {
        Log.app.error("Word book sync with English Reader failed: \(error.message, privacy: .public)")
        switch error {
        case .signedOut:
            noteRefusal(error)
        case .cursorExpired:
            state.cursor = nil
            saveState()
        case .rateLimited(let seconds):
            activity = .failed(error.message)
            scheduleSync(after: .seconds(seconds))
        case .network, .timedOut:
            activity = .offline
            retryLater()
        case .maintenance, .httpStatus, .notJSON:
            activity = .failed(error.message)
            retryLater()
        default:
            activity = .failed(error.message)
        }
    }

    /// The site no longer accepts the key. Words and waiting changes stay; after signing in again a full sync settles them.
    private func noteRefusal(_ error: SiteVocabError) {
        guard error == .signedOut else { return }
        account.keyRefused()
        state.cursor = nil
        saveState()
    }

    /// 2, 4, 8… seconds, up to five minutes.
    private func retryLater() {
        failures += 1
        scheduleSync(after: .seconds(min(1 << min(failures, 9), Self.longestRetry)))
    }

    // MARK: Sending

    private func push() async throws(SiteVocabError) {
        while let batch = state.batch ?? nextBatch() {
            state.batch = batch
            saveState()
            let response: VocabPushResponse
            do throws(SiteVocabError) {
                response = try await client.push(batch)
            } catch .tooLarge where batch.changes.count > 1 {
                // Half now, the rest in the next round. A new id: what is sent isn't the same any more.
                let half = batch.changes.count / 2
                state.pending.formUnion(batch.changes[half...].map(\.key))
                state.batch = VocabPushBatch(requestId: UUID().uuidString, changes: Array(batch.changes[..<half]))
                saveState()
                continue
            }
            take(response, of: batch)
        }
    }

    /// The next changes to send: each word as it is now, however many times it changed.
    private func nextBatch() -> VocabPushBatch? {
        let keys = state.pending.sorted().prefix(SiteVocabClient.batchLimit)
        guard !keys.isEmpty else { return nil }
        state.pending.subtract(keys)
        let changes = keys.compactMap { key -> VocabChange? in
            if let entry = book.entry(forKey: key) { return .upsert(entry.forSite) }
            return book.file.deleted[key].map { .delete(key: key, deletedAt: $0) }
        }
        // Nothing to say about any of them (a deletion that has aged out): the next round looks at the rest.
        return changes.isEmpty ? nextBatch() : VocabPushBatch(requestId: UUID().uuidString, changes: changes)
    }

    /// Merges rather than overwrites as the spec says: the word may have changed here while it was on its way, and
    /// merging gives the same result when it hasn't.
    private func take(_ response: VocabPushResponse, of batch: VocabPushBatch) {
        var entries: [VocabEntry] = []
        var deleted: [String: Int64] = [:]
        var skewed = false
        for result in response.results {
            switch result.status {
            case .created, .merged, .keptNewer:
                if let entry = result.entry { entries.append(entry) }
            case .deletedElsewhere:
                if let deletedAt = result.deletedAt { deleted[result.key] = deletedAt }
            case .clockSkew:
                skewed = true
                if !state.pending.contains(result.key) { state.held.insert(result.key) }
            case .invalidEntry:
                Log.app.error("English Reader refused a word: \(result.message ?? "no reason given", privacy: .public)")
            case .unchanged, .deleted, .other:
                break
            }
        }
        book.applyFromSite(entries: entries, deleted: deleted)
        clockLooksWrong = skewed
        state.batch = nil
        saveState()
    }

    // MARK: Receiving

    private func pull() async throws(SiteVocabError) {
        while let cursor = state.cursor {
            let page = try await client.changes(since: cursor)
            // The book is written first: if this stops halfway the same page comes again, and merging twice is harmless.
            book.applyFromSite(
                entries: page.entries,
                deleted: Dictionary(page.deleted.map { ($0.key, $0.deletedAt) }) { max($0, $1) }
            )
            if page.cursor != cursor {
                state.cursor = page.cursor
                saveState()
            }
            guard page.more else { return }
        }
    }

    // MARK: - Full sync

    /// Sends the whole book for the site to compare with its own. Everyday syncing stops until `closeFullSync`.
    func startFullSync() async throws(SiteVocabError) -> VocabSyncPreview {
        isFullSyncOpen = true
        scheduled?.cancel()
        await running?.value
        comparedVersion = book.version
        var file = book.file
        file.entries = file.entries.map(\.forSite)
        do throws(SiteVocabError) {
            return try await client.preview(file)
        } catch {
            noteRefusal(error)
            throw error
        }
    }

    /// Does what the user chose. Whatever it is, this iPhone's book is copied first, for undoing it.
    func finishFullSync(_ preview: VocabSyncPreview, option: VocabSyncOption) async throws(SiteVocabError) -> VocabFullSyncOutcome {
        guard book.version == comparedVersion, let choice = preview.choice(option) else { throw .changedSincePreview }
        let before = book.file
        do {
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try before.encoded().write(to: backupURL, options: .atomic)
        } catch {
            throw .backupFailed
        }
        let applied: VocabSyncApplied
        do throws(SiteVocabError) {
            applied = try await client.apply(
                previewID: preview.previewId, option: option,
                confirm: VocabSyncConfirmation(deviceRemove: choice.device.remove, serverRemove: choice.server.remove)
            )
        } catch {
            noteRefusal(error)
            throw error
        }
        let rejected = preview.rejected ?? []
        if let new = applied.book {
            guard new.formatVersion == VocabFile.currentVersion else { throw .badResponse("the book's format") }
            book.replace(with: Self.keeping(Set(rejected.map(\.key)), of: before, in: new))
        }
        let pendingBefore = state.pending.union(state.held).union(state.batch?.changes.map(\.key) ?? [])
        // Everything that was waiting went up with the comparison and has been dealt with by the user's choice, except
        // words the site turned down for a wrong clock, which are worth trying again.
        var settled = VocabSiteState(cursor: applied.cursor)
        settled.held = Set(rejected.filter { $0.status == .clockSkew }.map(\.key))
        state = settled
        saveState()
        clockLooksWrong = !settled.held.isEmpty
        activity = .synced
        lastSynced = now()
        Log.app.info("Word book: full sync done (\(option.rawValue, privacy: .public))")
        return VocabFullSyncOutcome(
            deviceWords: book.count, siteWords: applied.result.server.after, undoID: applied.undoId,
            changedHere: !VocabFormat.sameContent(before, book.file), pendingBefore: pendingBefore
        )
    }

    /// `new`, with this iPhone's own data for the words the site left out of the comparison: it said nothing about them.
    private static func keeping(_ keys: Set<String>, of before: VocabFile, in new: VocabFile) -> VocabFile {
        guard !keys.isEmpty else { return new }
        var kept = new
        kept.entries.removeAll { keys.contains($0.key) }
        kept.entries += before.entries.filter { keys.contains($0.key) }
        for key in keys { kept.deleted[key] = before.deleted[key] }
        return kept
    }

    /// Puts both sides back as they were: the site undoes what it can, this iPhone goes back to its copy, and the
    /// cursor moves past the site's undoing, so that doesn't arrive here as new changes. The site's call comes first:
    /// if it fails, nothing has moved. Words the sync added to the site stay there (they came from a device, and
    /// deleting them would reach that device). Returns how many words the site left alone, having changed since.
    @discardableResult
    func undoFullSync(_ outcome: VocabFullSyncOutcome) async throws(SiteVocabError) -> Int {
        guard let data = try? Data(contentsOf: backupURL), let copy = try? VocabFile.decode(data) else { throw .backupFailed }
        var skipped = 0
        if let undoID = outcome.undoID {
            do throws(SiteVocabError) {
                let undone = try await client.undo(undoID: undoID)
                state.cursor = undone.cursor
                skipped = undone.skipped?.count ?? 0
            } catch {
                noteRefusal(error)
                throw error
            }
        }
        book.replace(with: copy)
        state.pending = outcome.pendingBefore
        state.held = []
        saveState()
        clockLooksWrong = false
        return skipped
    }

    /// The full sync left the screen, settled or not.
    func closeFullSync() {
        isFullSyncOpen = false
        comparedVersion = nil
        scheduleSync(after: .zero)
    }

    // MARK: - Storage

    private func saveState() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.app.error("Word book: saving the sync state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
