import Foundation
import Observation
import OSLog
import SwiftData

/// The English Reader site's articles on this iPhone: the catalog (every published article, kept in step with the
/// site by change number, docs/site-api-for-ios.md §2), and for the ones opened here, a link to their `Article` and
/// where their narration is on the site.
///
/// Kept in `Application Support/Site/` as JSON rather than SwiftData, like the word book, so a build without these
/// fields (installed from the other Mac) can't drop them. An `Article` made from the site is an ordinary article: its
/// `sourceURL` is the site's `canonicalUrl`, which for Wikipedia articles is the same address as when added by hand.
@Observable
final class SiteLibrary {
    static let shared = SiteLibrary()

    enum State: Equatable {
        case idle
        case syncing
        case synced
        case failed(String)
    }

    /// An article of the catalog opened on this iPhone.
    struct Link: Codable, Equatable {
        /// The `sourceURL` of its `Article`.
        var articleURL: URL
        /// The detail that the `Article`'s text came from.
        var contentVersion: String
        /// The site's narration voice, when its files can be used here (`SiteArticleDetail.audioFiles`).
        var voice: String?
        /// The text is the site's (made from it), not one added by hand before: only then is it updated from the site.
        var ownsText: Bool
        /// Where the text comes from and its license, as the site words it.
        var attribution: String?
        /// Only the beginning was sent (the site's preview, for readers without an access token): fetched again each
        /// time it is opened, so an access token added since brings the rest.
        var preview: SiteArticleDetail.Preview?
    }

    /// Bumped whenever `SiteArticleSummary` learns a field. Summaries kept by an older version lack it, and the site
    /// only sends an article again when it changes, so the whole catalog is fetched once. 2: categories' numbers,
    /// pictures (2026-11-05).
    static let summaryVersion = 2

    private struct Stored: Codable {
        /// The `summaryVersion` the kept summaries were made with (nil: before there was one).
        var summaryVersion: Int?
        var epoch: String?
        var since = 0
        var articles: [String: SiteArticleSummary] = [:]
        var links: [String: Link] = [:]
        /// The site's categories, by number, when it lists them.
        var categories: [Int: SiteCategoryInfo]?
    }

    private(set) var state = State.idle
    private(set) var lastSynced: Date?
    /// Newest first.
    private(set) var articles: [SiteArticleSummary] = []
    private(set) var links: [String: Link] = [:]
    /// The site's categories, by number: descriptions and the order it wants (empty until it lists them).
    private(set) var categoryInfo: [Int: SiteCategoryInfo] = [:]
    /// The site refused the access token saved in Settings (revoked or expired) the last time it was asked.
    private(set) var tokenRefused = false

    @ObservationIgnored private var stored: Stored
    /// Narration files on the site, by cache key: for the articles opened here.
    @ObservationIgnored private var audio: [String: URL]
    /// When each word starts in the pieces of a recording, by cache key.
    @ObservationIgnored private var wordTimes: [String: [Int]]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let client: SiteClient
    @ObservationIgnored private let now: () -> Date
    /// Tells the account a refused key was its device key; false if it has none, so the access token was refused.
    @ObservationIgnored private let keyRefused: () -> Bool
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Pieces whose file was missing (404) and whose article was fetched again for new addresses, this launch.
    @ObservationIgnored private var refreshedKeys: Set<String> = []

    /// The catalog is checked at most this often when the app comes to the front (pulling to refresh always checks).
    static let minimumInterval: TimeInterval = 10 * 60

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "Site", directoryHint: .isDirectory),
        client: SiteClient = SiteClient(),
        now: @escaping () -> Date = Date.init,
        keyRefused: @escaping () -> Bool = { SiteAccount.shared.keyRefused() }
    ) {
        self.directory = directory
        self.client = client
        self.now = now
        self.keyRefused = keyRefused
        stored = (try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: directory.appending(path: "Catalog.json")))) ?? Stored()
        audio = (try? JSONDecoder().decode([String: URL].self, from: Data(contentsOf: directory.appending(path: "AudioIndex.json")))) ?? [:]
        wordTimes = (try? JSONDecoder().decode([String: [Int]].self, from: Data(contentsOf: directory.appending(path: "WordTimes.json")))) ?? [:]
        fillInAttributions()
        publish()
    }

    /// Links made before attributions were kept get theirs from the detail kept on disk (once: then it is saved).
    private func fillInAttributions() {
        var filled = false
        for (id, link) in stored.links where link.attribution == nil {
            let file = directory.appending(path: "Articles/\(id).json")
            guard let data = try? Data(contentsOf: file), let text = (try? SiteClient.decodeArticle(data))?.attribution?.text else { continue }
            stored.links[id]?.attribution = text
            filled = true
        }
        if filled { save() }
    }

    // MARK: - The catalog

    /// Brings the catalog up to date: only what changed since last time, or everything when the site's database was
    /// restored (a new epoch). `ifDue` skips it if it ran a few minutes ago.
    func sync(ifDue: Bool = false) async {
        if ifDue, let lastSynced, now().timeIntervalSince(lastSynced) < Self.minimumInterval { return }
        if let running { return await running.value }
        let task = Task { await syncOnce() }
        running = task
        await task.value
        running = nil
    }

    private func syncOnce() async {
        state = .syncing
        do {
            var since = stored.since
            // The articles seen when everything is fetched again for fields this version adds (summaries kept by an
            // older version dropped the ones it didn't know); the rest are dropped at the end. Until then the kept
            // summaries stay, so a failure part-way loses nothing.
            var refetched: Set<String>?
            if stored.summaryVersion != Self.summaryVersion, since > 0 {
                Log.app.info("English Reader: fetching the whole catalog again for fields this version adds")
                since = 0
                refetched = []
            }
            var changed = 0
            while true {
                let page = try await client.catalog(since: since)
                if stored.epoch != nil, page.epoch != stored.epoch || since > page.maxSeq {
                    // Restored from a backup: change numbers went back. Start over (links to articles stay).
                    Log.app.info("English Reader: the site's database was restored; fetching the whole catalog")
                    stored.articles = [:]
                    stored.epoch = page.epoch
                    since = 0
                    stored.since = 0
                    refetched = nil
                    continue
                }
                stored.epoch = page.epoch
                for item in page.items {
                    switch item {
                    case .article(let article):
                        stored.articles[article.id] = article
                        refetched?.insert(article.id)
                    case .removed(let id, _): stored.articles[id] = nil
                    }
                }
                changed += page.items.count
                since = page.latest
                if refetched == nil { stored.since = since }
                save()
                if !page.hasMore || page.items.isEmpty { break }
            }
            if let refetched {
                stored.articles = stored.articles.filter { refetched.contains($0.key) }
                stored.since = since
            }
            stored.summaryVersion = Self.summaryVersion
            save()
            noteToken(nil)
            await syncCategories()
            publish()
            lastSynced = now()
            state = .synced
            Log.app.info("English Reader: catalog synced (\(changed) changes, \(self.stored.articles.count) articles)")
        } catch let error as SiteError {
            noteToken(error)
            state = .failed(error.message)
            Log.app.error("English Reader: catalog sync failed: \(error.message, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The category list is an optional part of the site's API: without it, categories are ordered by size and have
    /// no description. Never fails the sync.
    private func syncCategories() async {
        do throws(SiteError) {
            let list = try await client.categories()
            stored.categories = Dictionary(list.map { ($0.id, $0) }) { first, _ in first }
            save()
        } catch .notFound {
            // Not offered (yet).
        } catch {
            Log.app.error("English Reader: categories failed: \(error.message, privacy: .public)")
        }
    }

    /// Notes whether the site accepted the device key or the access token, from a request's outcome.
    private func noteToken(_ error: SiteError?) {
        if error == .invalidToken {
            if !keyRefused() { tokenRefused = true }
        } else if error == nil {
            tokenRefused = false
        }
    }

    /// Asks the site once with the access token now in Settings: `tokenRefused` says what it answered.
    func checkToken() async {
        do throws(SiteError) {
            let list = try await client.categories()
            stored.categories = Dictionary(list.map { ($0.id, $0) }) { first, _ in first }
            noteToken(nil)
        } catch .notFound {
            noteToken(nil)
        } catch {
            noteToken(error)
        }
    }

    /// Categories with their articles, in the site's order when it gives one.
    var categories: [(category: SiteCategory, articles: [SiteArticleSummary])] {
        SiteCategories.group(articles, info: categoryInfo)
    }

    func info(for category: SiteCategory) -> SiteCategoryInfo? {
        guard category.id.hasPrefix("c"), let number = Int(category.id.dropFirst()) else { return nil }
        return categoryInfo[number]
    }

    func article(id: String) -> SiteArticleSummary? {
        stored.articles[id]
    }

    // MARK: - Opening an article

    /// The `Article` for a catalog entry, made or brought up to date from the site's detail: the one opened before,
    /// or a Wikipedia article already added by hand (its text is left as it is), or a new one. Without a connection,
    /// one opened before still opens. Only a preview (no access token, docs/site-api-for-ios.md §10): it is kept as one
    /// and fetched again next time; a whole article kept here is never swapped for a preview.
    func open(_ summary: SiteArticleSummary, in context: ModelContext) async throws(SiteError) -> Article {
        let link = stored.links[summary.id]
        let existing = Self.article(at: link?.articleURL ?? summary.canonicalUrl, in: context)
        // A recording opened with a version that couldn't play it is fetched again, for its audio.
        let missesRecording = link?.voice == nil && summary.audio?.voice.map(OpenAISpeechEngine.isRecording) == true
        if let existing, let link, link.contentVersion == summary.contentVersion, !missesRecording, link.preview == nil {
            return existing
        }

        let detail: SiteArticleDetail
        do {
            let fetched = try await client.article(id: summary.id)
            detail = fetched.detail
            noteToken(nil)
            if detail.isPreview, let existing, let link, link.preview == nil {
                // The site's limit came on, or the token went: keep the whole article from before (its entry is left
                // as it was, so it is asked for again next time).
                Log.app.info("English Reader: the site sent only a preview; keeping the whole article from before")
                return existing
            }
            keepDetail(fetched.data, id: summary.id)
        } catch {
            noteToken(error)
            if let existing { return existing }
            throw error
        }
        let blocks = detail.contentBlocks
        let article: Article
        let ownsText: Bool
        if let existing {
            article = existing
            ownsText = link?.ownsText ?? false
            if ownsText, article.blocks != blocks {
                article.blocksData = (try? JSONEncoder().encode(blocks)) ?? article.blocksData
                article.lastReadBlockIndex = min(article.lastReadBlockIndex, max(blocks.count - 1, 0))
                article.title = detail.summary.title
                Log.app.info("English Reader: updated an article's text from the site")
            }
        } else {
            article = Article(title: detail.summary.title, sourceURL: detail.summary.canonicalUrl, blocks: blocks)
            article.origin = detail.summary.isWikipedia ? Article.wikipediaOrigin : Article.siteOrigin
            context.insert(article)
            ownsText = true
            Log.app.info("English Reader: added an article from the site (\(blocks.count) blocks)")
        }
        let files = detail.audioFiles
        if detail.mismatchedChunks > 0 {
            Log.app.error("English Reader: \(detail.mismatchedChunks) narration pieces don't match their text; not used")
        }
        audio.merge(files) { _, new in new }
        wordTimes.merge(detail.wordStarts) { _, new in new }
        stored.links[summary.id] = Link(
            articleURL: article.sourceURL, contentVersion: detail.summary.contentVersion,
            voice: files.isEmpty ? nil : detail.narration?.voice, ownsText: ownsText,
            attribution: detail.attribution?.text,
            preview: detail.isPreview ? (detail.preview ?? SiteArticleDetail.Preview()) : nil
        )
        if detail.isPreview { Log.app.info("English Reader: only a preview of this article (no access token)") }
        // The detail is newer than the catalog entry: keep what it says.
        stored.articles[summary.id] = detail.summary
        save()
        publish()
        return article
    }

    /// Matched in memory: a library is at most a few hundred articles, and it sidesteps comparing URLs in a predicate.
    private static func article(at url: URL, in context: ModelContext) -> Article? {
        (try? context.fetch(FetchDescriptor<Article>()))?.first { $0.sourceURL == url }
    }

    /// The catalog entry an article was opened from, if it was.
    func summary(forArticleURL url: URL) -> SiteArticleSummary? {
        guard let id = stored.links.first(where: { $0.value.articleURL == url })?.key else { return nil }
        return stored.articles[id]
    }

    /// What the site says about an article opened from it: its source and license.
    func link(forArticleURL url: URL) -> Link? {
        stored.links.values.first { $0.articleURL == url }
    }

    /// The voice to read an article with so the site's narration plays: nil if it isn't from the site or the site
    /// has no usable files for it.
    func narrationVoice(forArticleURL url: URL) -> String? {
        stored.links.values.first { $0.articleURL == url }?.voice
    }

    /// What the site sent of an article opened from it, when it was only a preview.
    func preview(forArticleURL url: URL) -> SiteArticleDetail.Preview? {
        stored.links.values.first { $0.articleURL == url }?.preview
    }

    /// Whether an article is read from its speaker's own recording on the site.
    func isRecording(articleURL url: URL) -> Bool {
        narrationVoice(forArticleURL: url).map(OpenAISpeechEngine.isRecording) ?? false
    }

    /// The recordings' voices of the articles at `urls` (opened from the site and read from a recording).
    func recordingVoices(of urls: [URL]) -> [String] {
        let wanted = Set(urls)
        return Array(Set(stored.links.values.compactMap { link in
            wanted.contains(link.articleURL) ? link.voice.flatMap { OpenAISpeechEngine.isRecording($0) ? $0 : nil } : nil
        }))
    }

    // MARK: - Narration files

    var hasAudio: Bool { !audio.isEmpty }

    func audioURL(forKey key: String) -> URL? {
        audio[key]
    }

    /// A narration file the site no longer has at its address (404: the site renames its files now and then): the
    /// article with the piece is fetched again and its files' new addresses kept. Returns the piece's address now, if
    /// it changed. At most once per piece each launch.
    func refreshAudio(forKey key: String) async -> URL? {
        guard refreshedKeys.insert(key).inserted, let old = audio[key] else { return nil }
        let needle = Data(key.utf8)
        for id in stored.links.keys {
            guard let data = try? Data(contentsOf: directory.appending(path: "Articles/\(id).json")),
                  data.range(of: needle) != nil else { continue }
            do throws(SiteError) {
                let fetched = try await client.article(id: id)
                noteToken(nil)
                audio.merge(fetched.detail.audioFiles) { _, new in new }
                wordTimes.merge(fetched.detail.wordStarts) { _, new in new }
                if !fetched.detail.isPreview { keepDetail(fetched.data, id: id) }
                save()
                Log.app.info("English Reader: fetched an article again for its narration's new addresses")
            } catch {
                noteToken(error)
                return nil
            }
            return audio[key] == old ? nil : audio[key]
        }
        return nil
    }

    /// When each word of a recording's piece starts, in milliseconds, if the site measured it.
    func wordStarts(forKey key: String) -> [Int]? {
        wordTimes[key]
    }

    // MARK: - Storage

    private func keepDetail(_ data: Data, id: String) {
        let folder = directory.appending(path: "Articles", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: "\(id).json"), options: .atomic)
        } catch {
            Log.app.error("English Reader: couldn't keep an article's detail: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(stored).write(to: directory.appending(path: "Catalog.json"), options: .atomic)
            try encoder.encode(audio).write(to: directory.appending(path: "AudioIndex.json"), options: .atomic)
            try encoder.encode(wordTimes).write(to: directory.appending(path: "WordTimes.json"), options: .atomic)
        } catch {
            Log.app.error("English Reader: saving the catalog failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publish() {
        articles = stored.articles.values.sorted {
            let (a, b) = ($0.shownDate ?? .distantPast, $1.shownDate ?? .distantPast)
            return a != b ? a > b : $0.title < $1.title
        }
        links = stored.links
        categoryInfo = stored.categories ?? [:]
    }
}
