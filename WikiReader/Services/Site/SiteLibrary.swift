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
    }

    private struct Stored: Codable {
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

    @ObservationIgnored private var stored: Stored
    /// Narration files on the site, by cache key: for the articles opened here.
    @ObservationIgnored private var audio: [String: URL]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let client: SiteClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?

    /// The catalog is checked at most this often when the app comes to the front (pulling to refresh always checks).
    static let minimumInterval: TimeInterval = 10 * 60

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "Site", directoryHint: .isDirectory),
        client: SiteClient = SiteClient(),
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.client = client
        self.now = now
        stored = (try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: directory.appending(path: "Catalog.json")))) ?? Stored()
        audio = (try? JSONDecoder().decode([String: URL].self, from: Data(contentsOf: directory.appending(path: "AudioIndex.json")))) ?? [:]
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
                    continue
                }
                stored.epoch = page.epoch
                for item in page.items {
                    switch item {
                    case .article(let article): stored.articles[article.id] = article
                    case .removed(let id, _): stored.articles[id] = nil
                    }
                }
                changed += page.items.count
                since = page.latest
                stored.since = since
                save()
                if !page.hasMore || page.items.isEmpty { break }
            }
            await syncCategories()
            publish()
            lastSynced = now()
            state = .synced
            Log.app.info("English Reader: catalog synced (\(changed) changes, \(self.stored.articles.count) articles)")
        } catch let error as SiteError {
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
    /// one opened before still opens.
    func open(_ summary: SiteArticleSummary, in context: ModelContext) async throws(SiteError) -> Article {
        let link = stored.links[summary.id]
        let existing = Self.article(at: link?.articleURL ?? summary.canonicalUrl, in: context)
        if let existing, let link, link.contentVersion == summary.contentVersion { return existing }

        let detail: SiteArticleDetail
        do {
            let fetched = try await client.article(id: summary.id)
            detail = fetched.detail
            keepDetail(fetched.data, id: summary.id)
        } catch {
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
        stored.links[summary.id] = Link(
            articleURL: article.sourceURL, contentVersion: detail.summary.contentVersion,
            voice: files.isEmpty ? nil : detail.narration?.voice, ownsText: ownsText,
            attribution: detail.attribution?.text
        )
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

    // MARK: - Narration files

    var hasAudio: Bool { !audio.isEmpty }

    func audioURL(forKey key: String) -> URL? {
        audio[key]
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
