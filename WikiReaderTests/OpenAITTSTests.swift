import Foundation
import Testing
@testable import WikiReader

struct OpenAITTSClientTests {
    let speech = OpenAISpeechRequest(model: "gpt-4o-mini-tts", voice: "marin", input: "Hello world.", instructions: "Calm.")

    @Test func requestShape() throws {
        let request = OpenAITTSClient.urlRequest(for: speech, apiKey: "sk-test")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "model": "gpt-4o-mini-tts", "voice": "marin", "input": "Hello world.",
            "instructions": "Calm.", "response_format": "mp3",
        ])
    }

    @Test func noInstructionsFieldWhenEmpty() throws {
        var plain = speech
        plain.instructions = nil
        let body = try #require(OpenAITTSClient.urlRequest(for: plain, apiKey: "k").httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["instructions"] == nil)
    }

    private func client(status: Int, body: String = "", error: (any Error)? = nil) -> OpenAITTSClient {
        OpenAITTSClient { request in
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test func successReturnsAudio() async throws {
        let audio = try await client(status: 200, body: "ID3fake-mp3").synthesize(speech, apiKey: "k")
        #expect(audio == Data("ID3fake-mp3".utf8))
    }

    @Test func missingKeyFailsWithoutRequest() async {
        let client = OpenAITTSClient { _ in
            Issue.record("No request should be sent without a key")
            throw URLError(.cancelled)
        }
        await #expect(throws: OpenAITTSError.missingKey) { try await client.synthesize(speech, apiKey: "") }
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"Incorrect API key","code":"invalid_api_key"}}"#, OpenAITTSError.invalidKey),
        (429, #"{"error":{"message":"You exceeded your quota","code":"insufficient_quota"}}"#, .quotaExceeded),
        (429, #"{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}"#, .rateLimited),
        (400, #"{"error":{"message":"Invalid voice"}}"#, .badRequest("Invalid voice")),
        (404, "not json", .badRequest("HTTP 404")),
        (503, "", .server(status: 503)),
    ])
    func errorResponses(status: Int, body: String, expected: OpenAITTSError) async {
        await #expect(throws: expected) { try await client(status: status, body: body).synthesize(speech, apiKey: "k") }
    }

    @Test func networkFailure() async {
        await #expect(throws: OpenAITTSError.network(URLError(.notConnectedToInternet).localizedDescription)) {
            try await client(status: 0, error: URLError(.notConnectedToInternet)).synthesize(speech, apiKey: "k")
        }
    }

    @Test func emptyAudioIsBadResponse() async {
        await #expect(throws: OpenAITTSError.badResponse) { try await client(status: 200).synthesize(speech, apiKey: "k") }
    }

    @Test func messagesNeverContainTheKey() {
        let errors: [OpenAITTSError] = [.missingKey, .invalidKey, .quotaExceeded, .rateLimited, .badRequest("x"), .server(status: 500), .network("x"), .badResponse]
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains("sk-"))
        }
    }
}

struct SpeechChunkingTests {
    @Test func shortTextIsOneChunk() {
        #expect(SpeechChunking.chunks(of: "Hello world.") == [NSRange(location: 0, length: 12)])
    }

    @Test func longTextSplitsAtSentencesAndCoversEverything() {
        let sentence = "This sentence is exactly fifty characters long ok. "
        let text = String(repeating: sentence, count: 10)  // 510 characters
        let chunks = SpeechChunking.chunks(of: text, maxLength: 120)

        #expect(chunks.allSatisfy { $0.length <= 120 })
        #expect(chunks.first?.location == 0)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.upperBound == b.location)  // contiguous
        }
        #expect(chunks.last?.upperBound == (text as NSString).length)
        for chunk in chunks.dropLast() {
            #expect((text as NSString).substring(with: chunk).hasSuffix(". "))  // sentence boundary
        }
    }

    @Test func sentenceLongerThanLimitSplitsAtSpace() {
        let text = String(repeating: "word ", count: 50)  // one 250-character "sentence"
        let chunks = SpeechChunking.chunks(of: text, maxLength: 100)
        #expect(chunks.allSatisfy { $0.length <= 100 })
        for chunk in chunks.dropLast() {
            #expect((text as NSString).substring(with: chunk).hasSuffix(" "))
        }
    }

    @Test func realParagraphsFitTheLimit() throws {
        for block in try Fixture.blocks("albert_einstein") {
            for chunk in SpeechChunking.chunks(of: block.text) {
                #expect(chunk.length <= OpenAISpeechRequest.maxInputLength)
            }
        }
    }
}

struct WordTimelineTests {
    let text = "Einstein was born in Ulm. He moved to Munich, then Italy."

    private func word(_ timeline: WordTimeline, at fraction: Double) -> String? {
        timeline.wordIndex(atFraction: fraction).map { (text as NSString).substring(with: timeline.words[$0]) }
    }

    @Test func startsAtFirstWordAndEndsAtLast() {
        let timeline = WordTimeline(text: text)
        #expect(word(timeline, at: 0) == "Einstein")
        #expect(word(timeline, at: 0.999) == "Italy")
    }

    @Test func wordsAdvanceMonotonically() {
        let timeline = WordTimeline(text: text)
        let indices = stride(from: 0.0, through: 1.0, by: 0.01).compactMap { timeline.wordIndex(atFraction: $0) }
        #expect(indices == indices.sorted())
        #expect(Set(indices).count == timeline.words.count)  // no word skipped at this resolution
    }

    @Test func offsetAndFractionRoundTrip() {
        let timeline = WordTimeline(text: text)
        for (index, range) in timeline.words.enumerated() {
            let fraction = timeline.fraction(atOffset: range.location)
            #expect(timeline.wordIndex(atFraction: fraction) == index)
        }
        #expect(timeline.fraction(atOffset: 0) == 0)
    }

    @Test func sentenceEndTakesLongerThanPlainGap() {
        let timeline = WordTimeline(text: "aaaa bbbb. cccc dddd")
        let a = timeline.fraction(atOffset: 0), b = timeline.fraction(atOffset: 5)
        let c = timeline.fraction(atOffset: 11), d = timeline.fraction(atOffset: 16)
        #expect(c - b > b - a)  // "bbbb." is followed by a pause
        #expect(abs((d - c) - (b - a)) < 0.001)
    }

    @Test func emptyText() {
        let timeline = WordTimeline(text: "")
        #expect(timeline.wordIndex(atFraction: 0.5) == nil)
    }
}

struct SpeechAudioCacheTests {
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "SpeechAudioCacheTests-\(UUID().uuidString)"))
    let request = OpenAISpeechRequest(model: "gpt-4o-mini-tts", voice: "marin", input: "Hello.", instructions: nil)

    @Test func keyDependsOnEveryField() {
        let base = SpeechAudioCache.key(for: request)
        var other = request
        other.voice = "cedar"
        #expect(SpeechAudioCache.key(for: other) != base)
        other = request
        other.instructions = "Calm."
        #expect(SpeechAudioCache.key(for: other) != base)
        other = request
        other.input = "Hello!"
        #expect(SpeechAudioCache.key(for: other) != base)
        #expect(SpeechAudioCache.key(for: request) == base)  // stable
    }

    @Test func storeFindSizeAndClear() throws {
        #expect(cache.cachedFile(for: request) == nil)
        try cache.store(Data(count: 1000), for: request)
        let file = try #require(cache.cachedFile(for: request))
        #expect(try Data(contentsOf: file).count == 1000)
        #expect(cache.totalSize() == 1000)

        try cache.removeAll()
        #expect(cache.cachedFile(for: request) == nil)
        #expect(cache.totalSize() == 0)
        try cache.removeAll()  // clearing an empty cache is fine
    }
}

struct KeychainStoreTests {
    let store = KeychainStore(service: "tik.tian.com.WikiReader.tests", account: UUID().uuidString)

    @Test func saveReadReplaceDelete() throws {
        #expect(store.read() == nil)
        try store.save("first")
        #expect(store.read() == "first")
        try store.save("second")
        #expect(store.read() == "second")
        try store.delete()
        #expect(store.read() == nil)
        try store.delete()  // deleting nothing is fine
    }

    @Test func savingEmptyDeletes() throws {
        try store.save("value")
        try store.save("")
        #expect(store.read() == nil)
    }
}
