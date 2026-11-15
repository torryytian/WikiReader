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

/// An article in full: its text in blocks, and where each piece of its narration is. Or only its beginning, when the
/// site is set to show readers without an access token a preview (docs/site-api-for-ios.md §10).
nonisolated struct SiteArticleDetail: Decodable, Equatable, Sendable {
    var summary: SiteArticleSummary
    var attribution: Attribution?
    var narration: Narration?
    var blocks: [Block]
    /// `full`, or `preview`: only the first blocks (and their narration) are here. Missing from sites before access
    /// tokens: the whole article.
    var access: String?
    var preview: Preview?
    /// The voices the site has the whole narration in, the one it reads with by default first
    /// (docs/site-api-for-ios.md §13). Missing when it has only one.
    var voices: [VoiceOption]?
    /// The voice this detail's narration is in, when one was asked for (`?voice=<id>`).
    var voice: String?

    var isPreview: Bool { access == "preview" }

    /// One of the voices an article is narrated in on the site.
    nonisolated struct VoiceOption: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// A hash of the model, voice and style: it never changes.
        var id: String
        /// `openai`, `gemini` (Google) or `upload` (a recording).
        var engine: String?
        var model: String
        var voice: String
        var instructions: String?
        /// "Alloy · OpenAI", "Kore · Google".
        var name: String
        var `default`: Bool?

        var narration: NarrationVoice {
            NarrationVoice(model: model, voice: voice, instructions: instructions ?? "")
        }
    }

    nonisolated struct Preview: Codable, Equatable, Sendable {
        var percent: Int?
        /// Words included, and in the whole article.
        var shown: Int?
        var total: Int?
    }

    nonisolated struct Attribution: Decodable, Equatable, Sendable {
        var text: String?
    }

    nonisolated struct Narration: Decodable, Equatable, Sendable {
        var model: String
        var voice: String
        var instructions: String?
        var profile: String?
        /// The files on the site are byte for byte what OpenAI returned (the same as Drive's); false since the site
        /// serves compressed copies (2026-11-05). Either way they play from this app's cache under the piece's key, and
        /// neither is ever uploaded to Drive from here (`DriveAudioStore` skips audio the site serves).
        var sourceIdentical: Bool?

        /// The voice it is read in, which names its pieces.
        var narrationVoice: NarrationVoice {
            NarrationVoice(model: model, voice: voice, instructions: instructions ?? "")
        }
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

    private enum Keys: String, CodingKey { case attribution, narration, blocks, access, preview, voices, voice }

    init(from decoder: Decoder) throws {
        summary = try SiteArticleSummary(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        attribution = try container.decodeIfPresent(Attribution.self, forKey: .attribution)
        narration = try container.decodeIfPresent(Narration.self, forKey: .narration)
        blocks = try container.decode([Block].self, forKey: .blocks)
        access = try container.decodeIfPresent(String.self, forKey: .access)
        preview = try container.decodeIfPresent(Preview.self, forKey: .preview)
        // Optional extras: one the app can't read leaves the article readable in its default voice.
        voices = (try? container.decodeIfPresent([VoiceOption].self, forKey: .voices)).flatMap { $0.isEmpty ? nil : $0 }
        voice = try? container.decodeIfPresent(String.self, forKey: .voice)
    }

    /// The text as this app reads it: the readable blocks, a heading or a paragraph each (lists, quotes and the like
    /// read as paragraphs). Figures and tables aren't shown yet.
    var contentBlocks: [ContentBlock] {
        blocks.compactMap { block in
            guard block.readable, let text = block.text, !text.isEmpty else { return nil }
            return block.kind == "heading" ? .heading(text, level: max(2, block.level ?? 2)) : .paragraph(text)
        }
    }

    /// The audio files the site has for this article, by cache key. Only pieces whose key is the one their text gets in
    /// the narration's voice (its model, voice and style, as the site lists them): so a mix-up on the site can never
    /// play the wrong sentence, and the reader finds them by the same name.
    var audioFiles: [String: URL] {
        guard let narration else { return [:] }
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
        guard let narration else { return [:] }
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

    /// The key a piece's text gets in the narration's voice: the ios-v1 key the site names its files by.
    private static func key(of chunk: Chunk, in narration: Narration) -> String {
        SpeechAudioCache.key(for: narration.narrationVoice.request(for: chunk.text))
    }
}
