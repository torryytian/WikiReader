import CryptoKit
import Foundation
import Testing
@testable import WikiReader

/// Golden vectors for the audio cache key, shared with the Chrome extension (docs/shared-tts-cache-format.md).
/// If one of these fails, the key changed: every cached and paid-for file would stop being found, here and in Drive.
struct SharedCacheFormatTests {
    @Test(arguments: [
        ("marin", "History", "c38d77d2cd3a52901c7456918124df580153bd59e6dad5b0f7750cf38d469c99"),
        ("marin", "Paris is the capital and largest city of France.", "52d523be04f1e95b54b6ffdf47139a1dcbb626fd25f3a3895047693fa5591df7"),
        ("marin", "Café “Le Procope” — founded 1686, it’s Paris’s oldest café.", "c46c86aa2c932c0a4a2b5c85b8ac30f344408fbdb9cd4ea4e71b8fb878eb124c"),
        ("alloy", "History", "6ad6857debc4cd97e362ae44631e2564a9d817d230b62fea2eccc40b69705fbd"),
    ])
    func keyMatchesTheSharedFormat(voice: String, text: String, key: String) {
        #expect(SpeechAudioCache.key(for: OpenAISpeechEngine.request(for: text, voice: voice)) == key)
    }

    @Test func shortParagraphsAreOneChunk() {
        let paragraph = String(repeating: "A sentence of moderate length. ", count: 130)  // about 4000 characters
        #expect(SpeechChunking.chunks(of: paragraph).count == 1)
    }

    /// What the app makes of each fixture article: every block's text, how it is split into requests, and each
    /// request's key. The Chrome extension checks its port of the cleaner against the same files.
    @Test(arguments: ["albert_einstein", "paris", "pythagorean_theorem", "excerpt_section"])
    func fixtureBlocksAndKeysAreUnchanged(name: String) throws {
        let golden = try JSONDecoder().decode(GoldenArticle.self, from: Fixture.data("\(name).blocks"))
        let article = try Fixture.article(name)
        let blocks = ArticleCleaner.blocks(fromHTML: article.html)
        #expect(article.title == golden.title)
        #expect(ArticleInput.articleURL(forTitle: article.title).absoluteString == golden.url)
        #expect(blocks.count == golden.blocks.count)
        for (block, expected) in zip(blocks, golden.blocks) {
            #expect(block.text == expected.text)
            #expect(block.kind.rawValue == expected.kind)
            let ns = block.text as NSString
            let chunks = SpeechChunking.chunks(of: block.text).map { ns.substring(with: $0) }
            #expect(chunks == expected.chunks.map(\.text))
            #expect(chunks.map { SpeechAudioCache.key(for: OpenAISpeechEngine.request(for: $0, voice: golden.voice)) } == expected.chunks.map(\.key))
        }
    }

    /// Article URLs (the base of the Drive manifest's name) as `URLComponents` encodes them.
    @Test func articleURLsAndTheirHashes() throws {
        let vectors = try JSONDecoder().decode([URLVector].self, from: Fixture.data("url_hash"))
        // The Chrome extension's own vectors, from its tests/fixtures/wikipedia/url-vectors.tsv.
        let chrome = [
            ("Café", "https://en.wikipedia.org/wiki/Caf%C3%A9"), ("What? (film)", "https://en.wikipedia.org/wiki/What%3F_(film)"),
            ("Ōsaka", "https://en.wikipedia.org/wiki/%C5%8Csaka"), ("Hello#x", "https://en.wikipedia.org/wiki/Hello%23x"),
            ("O'Brien", "https://en.wikipedia.org/wiki/O'Brien"), ("Pi; e", "https://en.wikipedia.org/wiki/Pi;_e"),
            ("A&B", "https://en.wikipedia.org/wiki/A&B"),
        ]
        for vector in vectors {
            let url = ArticleInput.articleURL(forTitle: vector.title).absoluteString
            #expect(url == vector.url)
            #expect(SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined() == vector.urlHash)
        }
        for (title, url) in chrome {
            #expect(ArticleInput.articleURL(forTitle: title).absoluteString == url)
        }
    }

    private struct GoldenArticle: Decodable {
        struct Block: Decodable {
            struct Chunk: Decodable { var text: String; var key: String }
            var kind: String
            var text: String
            var chunks: [Chunk]
        }
        var title: String
        var url: String
        var voice: String
        var blocks: [Block]
    }

    private struct URLVector: Decodable {
        var title: String
        var url: String
        var urlHash: String
    }

    @Test func fixedRequestFields() {
        #expect(OpenAISpeechEngine.model == "gpt-4o-mini-tts")
        #expect(OpenAISpeechEngine.instructions == "Read like a clear, natural audiobook narrator, at a steady, moderate pace.")
        #expect(OpenAISpeechRequest.maxInputLength == 4096)
        #expect(OpenAITTSClient.audioFormat == "mp3")
    }
}
