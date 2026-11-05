import Foundation

/// What the English Reader site's app API returns (docs/site-api-for-ios.md, format 1). Fields the app doesn't know
/// are ignored and optional ones may be missing, so the site can add fields without the app changing.
nonisolated enum SiteFormat {
    static let version = 1
}

/// One page of the catalog: what changed after `since`, in change order.
nonisolated struct SiteCatalogPage: Decodable, Equatable, Sendable {
    var formatVersion: Int
    /// Changes when the site's database was restored from a backup: everything is fetched again.
    var epoch: String
    /// The highest change number on the site now.
    var maxSeq: Int
    /// Where the next request continues from.
    var latest: Int
    var hasMore: Bool
    var items: [SiteCatalogItem]
}

nonisolated enum SiteCatalogItem: Decodable, Equatable, Sendable {
    case article(SiteArticleSummary)
    /// Unpublished or deleted on the site.
    case removed(id: String, seq: Int)

    var id: String {
        switch self {
        case .article(let article): article.id
        case .removed(let id, _): id
        }
    }

    private enum Keys: String, CodingKey { case id, seq, removed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .removed) == true {
            self = .removed(id: try container.decode(String.self, forKey: .id), seq: try container.decode(Int.self, forKey: .seq))
        } else {
            self = .article(try SiteArticleSummary(from: decoder))
        }
    }
}

/// A published article as the catalog lists it. Also the start of an article's full detail.
nonisolated struct SiteArticleSummary: Codable, Equatable, Sendable {
    /// Never changes (the slug may).
    var id: String
    var seq: Int
    var slug: String?
    var pageUrl: URL?
    /// What every app calls this article by: the Wikipedia address for Wikipedia articles, else `pageUrl`. Saved
    /// words' sentences point here, and a Wikipedia article already on this iPhone is recognized by it.
    var canonicalUrl: URL
    var title: String
    var excerpt: String?
    var category: Category?
    var cefr: String?
    var wordCount: Int?
    var source: Source?
    var license: String?
    var publishedAt: Int64?
    var releasedAt: Int64?
    /// Fingerprint of the text and which audio is ready; a change means the detail is worth fetching again.
    var contentVersion: String
    /// Nil for an article read with the system voice only.
    var audio: Audio?
    /// A picture for its card (docs/site-api-for-ios.md §9.1); nil: the category's drawn cover stands in.
    var cover: Cover?

    nonisolated struct Category: Codable, Equatable, Sendable {
        /// The site's own number for it: stays the same when the category is renamed.
        var id: Int?
        var name: String
    }

    nonisolated struct Source: Codable, Equatable, Sendable {
        /// `wikipedia`, `web`, `original` or `upload`.
        var kind: String
        var url: URL?
        var host: String?
        var revision: Int?
    }

    nonisolated struct Cover: Codable, Equatable, Sendable {
        var src: URL
        /// The small version, for lists.
        var src600: URL?
        var width: Int?
        var height: Int?
        var alt: String?
        /// Who made the picture and its license, shown on the Info page.
        var credit: String?
        var license: String?

        var small: URL { src600 ?? src }
    }

    nonisolated struct Audio: Codable, Equatable, Sendable {
        var voice: String?
        var totalChunks: Int
        var readyChunks: Int
        var readyMs: Int64?
    }

    var isWikipedia: Bool { source?.kind == "wikipedia" }

    /// The newest of when it was published and last updated, for sorting.
    var shownDate: Date? {
        (releasedAt ?? publishedAt).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// What the site says about a category (docs/site-api-for-ios.md §9.2).
nonisolated struct SiteCategoryInfo: Codable, Equatable, Sendable {
    var id: Int
    var slug: String?
    var name: String
    var description: String?
    /// The site's order, smallest first.
    var sort: Int?
    var articleCount: Int?
}

nonisolated struct SiteCategoryList: Decodable, Sendable {
    var formatVersion: Int
    var categories: [SiteCategoryInfo]
}

/// An article in full: its text in blocks, and where each piece of its narration is.
nonisolated struct SiteArticleDetail: Decodable, Equatable, Sendable {
    var summary: SiteArticleSummary
    var attribution: Attribution?
    var narration: Narration?
    var blocks: [Block]

    nonisolated struct Attribution: Decodable, Equatable, Sendable {
        var text: String?
    }

    nonisolated struct Narration: Decodable, Equatable, Sendable {
        var model: String
        var voice: String
        var instructions: String?
        var profile: String?
        /// The files on the site are byte for byte what OpenAI returned (the same as Drive's). Only such files are
        /// taken as this app's own cached audio: they may be backed up to Drive from here.
        var sourceIdentical: Bool?
    }

    nonisolated struct Block: Decodable, Equatable, Sendable {
        var kind: String
        var level: Int?
        var text: String?
        var readable: Bool
        var chunks: [Chunk]?
    }

    nonisolated struct Chunk: Decodable, Equatable, Sendable {
        var key: String
        var text: String
        var off: Int?
        /// Missing until the site has the audio.
        var url: URL?
        var ms: Int?
        /// A recording's piece: when each of its words starts, in milliseconds from the start of the piece, as
        /// speech recognition heard them (in the order of the site's word splitting).
        var wordStartsMs: [Int]?
    }

    private enum Keys: String, CodingKey { case attribution, narration, blocks }

    init(from decoder: Decoder) throws {
        summary = try SiteArticleSummary(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        attribution = try container.decodeIfPresent(Attribution.self, forKey: .attribution)
        narration = try container.decodeIfPresent(Narration.self, forKey: .narration)
        blocks = try container.decode([Block].self, forKey: .blocks)
    }

    /// The text as this app reads it: the readable blocks, a heading or a paragraph each (lists, quotes and the like
    /// read as paragraphs). Figures and tables aren't shown yet.
    var contentBlocks: [ContentBlock] {
        blocks.compactMap { block in
            guard block.readable, let text = block.text, !text.isEmpty else { return nil }
            return block.kind == "heading" ? .heading(text, level: max(2, block.level ?? 2)) : .paragraph(text)
        }
    }

    /// The audio files the site has for this article, by this app's cache key. Only pieces whose key is the one this
    /// app gives their text in the narration's voice (so a mix-up on the site can never play the wrong sentence, and
    /// the reader finds them), and only files that are OpenAI's originals (`sourceIdentical`) or a speaker's own
    /// recording (never backed up to Drive: Drive only takes OpenAI voices).
    var audioFiles: [String: URL] {
        guard let narration, isUsable(narration) else { return [:] }
        var files: [String: URL] = [:]
        for block in blocks {
            for chunk in block.chunks ?? [] {
                guard let url = chunk.url, Self.key(of: chunk, in: narration) == chunk.key else { continue }
                files[chunk.key] = url
            }
        }
        return files
    }

    /// When each word starts, by cache key, for the pieces of `audioFiles` that come with it (recordings).
    var wordStarts: [String: [Int]] {
        guard let narration, isUsable(narration) else { return [:] }
        var starts: [String: [Int]] = [:]
        for block in blocks {
            for chunk in block.chunks ?? [] {
                guard chunk.url != nil, let times = chunk.wordStartsMs, Self.key(of: chunk, in: narration) == chunk.key else { continue }
                starts[chunk.key] = times
            }
        }
        return starts
    }

    /// Pieces listed with a file whose key doesn't match their text: logged, so a site bug shows up.
    var mismatchedChunks: Int {
        guard let narration else { return 0 }
        return blocks.flatMap { $0.chunks ?? [] }.count { chunk in
            chunk.url != nil && Self.key(of: chunk, in: narration) != chunk.key
        }
    }

    private func isUsable(_ narration: Narration) -> Bool {
        narration.sourceIdentical == true || OpenAISpeechEngine.isRecording(narration.voice)
    }

    /// The key this app gives a piece's text in the narration's voice. The same as the site's when the narration's
    /// model and instructions are the ones this app uses for that voice.
    private static func key(of chunk: Chunk, in narration: Narration) -> String {
        SpeechAudioCache.key(for: OpenAISpeechEngine.request(for: chunk.text, voice: narration.voice))
    }
}
