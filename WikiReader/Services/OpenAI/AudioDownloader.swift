import Foundation
import Observation
import OSLog
import SwiftData
import UIKit

/// Generates the OpenAI audio of whole articles ahead of time, so they can be listened to offline. Only runs when
/// asked from the library, after its length and cost were shown (`Plan`). A plan made `onlyFromDrive` takes what
/// Google Drive has and nothing else: no OpenAI request, no cost.
///
/// Two requests at a time, sharing in-flight generations with the reader (`SpeechGenerations`) so nothing is paid for
/// twice. A rejected key or an empty account stops it at once; other failures are counted and skipped, and a run of
/// them in a row (the connection is gone) stops it too. Audio already on disk is never requested.
@Observable
final class AudioDownloader {
    static let shared = AudioDownloader()
    static let maxConcurrent = 2
    static let maxConsecutiveFailures = 4

    /// An article to download: its id and its `blocksData`, decoded off the main actor.
    nonisolated struct Source: Sendable {
        var id: PersistentIdentifier
        var blocksData: Data
    }

    /// What a download will do, worked out before it starts so its length and cost can be shown first.
    nonisolated struct Plan: Sendable {
        struct Item: Sendable {
            var article: PersistentIdentifier
            var piece: ArticleAudio.Piece
            /// Already in Google Drive: downloading it costs nothing.
            var isOnDrive = false
            /// Taken from Google Drive alone, never generated.
            var fromDriveOnly = false
        }

        var voice: String
        /// Pieces without audio yet, article by article in the order given.
        var items: [Item]
        /// Articles with something to download.
        var articleCount: Int
        /// Made by `onlyFromDrive`.
        var isDriveOnly = false
        /// For a Drive-only plan: the missing audio that isn't in Drive and was left out.
        var leftOutCharacters = 0

        var characters: Int { items.reduce(0) { $0 + $1.piece.characters } }
        var minutes: Double { ArticleAudio.minutes(forCharacters: characters) }
        /// The part that comes from Google Drive, free.
        var driveCharacters: Int { items.filter(\.isOnDrive).reduce(0) { $0 + $1.piece.characters } }
        /// The part OpenAI generates, which is what costs money.
        var generatedCharacters: Int { characters - driveCharacters }
        var dollars: Double { ArticleAudio.dollars(forCharacters: generatedCharacters) }

        /// Marks the items whose audio `isOnDrive` says is in Google Drive.
        mutating func markOnDrive(_ isOnDrive: (String) -> Bool) {
            for index in items.indices {
                items[index].isOnDrive = isOnDrive(SpeechAudioCache.key(for: items[index].piece.request))
            }
        }
        var isEmpty: Bool { items.isEmpty }

        /// Only the items `markOnDrive` found in Google Drive, to be taken from Drive alone: nothing is generated or
        /// paid for, whatever Settings say about looking in Drive first.
        func onlyFromDrive() -> Plan {
            var plan = self
            plan.items = items.filter(\.isOnDrive).map { item in
                var item = item
                item.fromDriveOnly = true
                return item
            }
            plan.articleCount = Set(plan.items.map(\.article)).count
            plan.isDriveOnly = true
            plan.leftOutCharacters = generatedCharacters
            return plan
        }
    }

    enum Phase: Equatable {
        case idle
        case running
        /// Everything asked for was tried; `failedPieces` says how much didn't work.
        case finished
        /// Gave up, with why.
        case stopped(String)
    }

    private(set) var phase = Phase.idle
    private(set) var voice = ""
    private(set) var totalPieces = 0
    private(set) var donePieces = 0
    private(set) var failedPieces = 0
    private(set) var totalCharacters = 0
    private(set) var doneCharacters = 0
    /// Pieces still to do, per article.
    private(set) var pending: [PersistentIdentifier: Int] = [:]
    /// Of `totalPieces`, those taken from Google Drive alone.
    private(set) var driveOnlyPieces = 0

    @ObservationIgnored private let client: OpenAITTSClient
    @ObservationIgnored private let cache: SpeechAudioCache
    @ObservationIgnored private let generations: SpeechGenerations
    @ObservationIgnored private let apiKey: () -> String?
    @ObservationIgnored private let keepAwake: (Bool) -> Void
    @ObservationIgnored private var queue: [Plan.Item] = []
    /// Bumped by every stop, so workers of an earlier run leave the counts alone.
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var workers = 0
    @ObservationIgnored private var consecutiveFailures = 0

    init(
        client: OpenAITTSClient = OpenAITTSClient(),
        cache: SpeechAudioCache = .standard,
        generations: SpeechGenerations = .shared,
        apiKey: @escaping () -> String? = { KeychainStore.openAIKey.read() },
        // Downloads stop when the app is suspended, which an auto-locking screen does after a minute or two.
        keepAwake: @escaping (Bool) -> Void = { ScreenAwake.set("audio download", $0) }
    ) {
        self.client = client
        self.cache = cache
        self.generations = generations
        self.apiKey = apiKey
        self.keepAwake = keepAwake
    }

    var isRunning: Bool { phase == .running }
    /// Everything in this download comes from Google Drive alone.
    var isFromDriveOnly: Bool { totalPieces > 0 && driveOnlyPieces == totalPieces }
    var fraction: Double { totalCharacters > 0 ? Double(doneCharacters) / Double(totalCharacters) : 0 }

    func isDownloading(_ article: PersistentIdentifier) -> Bool {
        (pending[article] ?? 0) > 0
    }

    /// What downloading `articles` with `voice` would take. Reads the disk, so it runs off the main actor.
    @concurrent
    static func plan(for articles: [Source], voice: String, cache: SpeechAudioCache = .standard) async -> Plan {
        var items: [Plan.Item] = []
        var articleCount = 0
        for article in articles {
            let missing = ArticleAudio.status(of: Article.decodeBlocks(article.blocksData), voice: voice, cache: cache).missing
            if !missing.isEmpty { articleCount += 1 }
            items += missing.map { Plan.Item(article: article.id, piece: $0) }
        }
        return Plan(voice: voice, items: items, articleCount: articleCount)
    }

    /// Starts downloading, or adds to the download already running. Text already queued is not queued again.
    func start(_ plan: Plan) {
        guard !plan.items.isEmpty else { return }
        if phase != .running {
            totalPieces = 0
            donePieces = 0
            failedPieces = 0
            totalCharacters = 0
            doneCharacters = 0
            driveOnlyPieces = 0
            pending = [:]
            consecutiveFailures = 0
        }
        voice = plan.voice
        var queued = Set(queue.map { cache.fileURL(for: $0.piece.request) })
        for item in plan.items where queued.insert(cache.fileURL(for: item.piece.request)).inserted {
            queue.append(item)
            totalPieces += 1
            totalCharacters += item.piece.characters
            if item.fromDriveOnly { driveOnlyPieces += 1 }
            pending[item.article, default: 0] += 1
        }
        Log.speech.info("Audio download: \(self.queue.count) pieces queued with \(plan.voice, privacy: .public)")
        phase = .running
        keepAwake(true)
        while workers < Self.maxConcurrent, !queue.isEmpty {
            workers += 1
            Task { [run] in
                await work(run: run)
                guard self.run == run else { return }
                workers -= 1
                if workers == 0 { finish() }
            }
        }
    }

    /// Stops, leaving what was downloaded. Requests already sent still finish and are kept: they are paid for.
    func cancel() {
        guard phase == .running else { return }
        Log.speech.info("Audio download cancelled after \(self.donePieces) of \(self.totalPieces) pieces")
        end(.idle)
    }

    /// Drops what is still queued for one article, e.g. because it was deleted.
    func cancel(article: PersistentIdentifier) {
        let dropped = queue.filter { $0.article == article }
        guard !dropped.isEmpty else { return }
        queue.removeAll { $0.article == article }
        totalPieces -= dropped.count
        totalCharacters -= dropped.reduce(0) { $0 + $1.piece.characters }
        driveOnlyPieces -= dropped.count(where: \.fromDriveOnly)
        pending[article] = nil
    }

    /// Clears a finished or stopped download's summary.
    func dismiss() {
        if phase != .running { phase = .idle }
    }

    // MARK: - Work

    /// How one piece went.
    private enum Outcome {
        case done
        /// Skipped and counted; why.
        case failed(String)
        /// Nothing else will work either (no key, no credit); why.
        case stop(String)
    }

    private func work(run: Int) async {
        while self.run == run, !queue.isEmpty {
            let item = queue.removeFirst()
            let outcome = item.fromDriveOnly ? await fetchFromDrive(item.piece.request) : await fetch(item.piece.request)
            guard self.run == run else { return }
            pending[item.article, default: 1] -= 1
            if pending[item.article] == 0 { pending[item.article] = nil }
            switch outcome {
            case .done:
                donePieces += 1
                doneCharacters += item.piece.characters
                consecutiveFailures = 0
            case .stop(let reason):
                Log.speech.error("Audio download: a piece failed: \(reason, privacy: .public)")
                end(.stopped(reason))
                return
            case .failed(let reason):
                Log.speech.error("Audio download: a piece failed: \(reason, privacy: .public)")
                failedPieces += 1
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    end(.stopped("Stopped after \(consecutiveFailures) failures in a row. \(reason)"))
                    return
                }
            }
        }
    }

    private func fetch(_ request: OpenAISpeechRequest) async -> Outcome {
        if cache.cachedFile(for: request) != nil { return .done }
        // Without a key, Google Drive may still have it; `generate` fails with missingKey otherwise.
        switch await generations.generate(request, apiKey: apiKey(), client: client, cache: cache).value {
        case .success:
            return .done
        case .failure(let error):
            switch error {
            case .missingKey, .invalidKey, .quotaExceeded: return .stop(error.message)
            default: return .failed(error.message)
            }
        }
    }

    private func fetchFromDrive(_ request: OpenAISpeechRequest) async -> Outcome {
        if cache.cachedFile(for: request) != nil { return .done }
        if await generations.fetchFromRemote(request, cache: cache) != nil { return .done }
        return .failed("Google Drive didn't send the audio.")
    }

    private func finish() {
        Log.speech.info("Audio download finished: \(self.donePieces) pieces, \(self.failedPieces) failed")
        end(.finished)
    }

    private func end(_ phase: Phase) {
        run += 1
        queue = []
        workers = 0
        pending = [:]
        self.phase = phase
        keepAwake(false)
    }
}
