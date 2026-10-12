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
        var client = OpenAITTSClient { request in
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        client.retry = .never   // these tests are about what one attempt turns into
        return client
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

/// Counts what a stand-in network was asked, from any thread.
private actor Calls {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

struct OpenAITTSRetryTests {
    let speech = OpenAISpeechRequest(model: "m", voice: "v", input: "Hello world.", instructions: nil)

    private func ok(_ request: URLRequest, status: Int = 200, headers: [String: String]? = nil, body: String = "ID3audio") -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    /// A client whose network answers each call in turn from `script`; the last answer repeats.
    private func client(_ calls: Calls, retry: RetryPolicy = .immediately, log: OpenAICallLog = .standard,
                        script: @escaping @Sendable (Int, URLRequest) throws -> (Data, URLResponse)) -> OpenAITTSClient {
        var client = OpenAITTSClient { request in try script(await calls.next(), request) }
        client.retry = retry
        client.log = log
        return client
    }

    @Test func aStuckAttemptIsRepeatedAndTheSecondOneWorks() async throws {
        let calls = Calls()
        let client = client(calls) { call, request in
            if call == 1 { throw URLError(.timedOut) }
            return ok(request)
        }
        let audio = try await client.synthesize(speech, apiKey: "k")
        #expect(audio == Data("ID3audio".utf8))
        #expect(await calls.count == 2)
    }

    @Test func givesUpAfterThreeAttemptsWithTheLastError() async {
        let calls = Calls()
        let client = client(calls) { _, _ in throw URLError(.timedOut) }
        await #expect(throws: OpenAITTSError.timedOut) { try await client.synthesize(speech, apiKey: "k") }
        #expect(await calls.count == RetryPolicy.standard.maxAttempts)
    }

    @Test(arguments: [503, 500, 429])
    func transientServerAnswersAreRepeated(status: Int) async throws {
        let calls = Calls()
        let client = client(calls) { call, request in
            call == 1 ? ok(request, status: status, body: #"{"error":{"message":"busy","code":"rate_limit_exceeded"}}"#) : ok(request)
        }
        _ = try await client.synthesize(speech, apiKey: "k")
        #expect(await calls.count == 2)
    }

    @Test func aDroppedConnectionIsRepeated() async throws {
        let calls = Calls()
        let client = client(calls) { call, request in
            if call == 1 { throw URLError(.networkConnectionLost) }
            return ok(request)
        }
        _ = try await client.synthesize(speech, apiKey: "k")
        #expect(await calls.count == 2)
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"Incorrect API key","code":"invalid_api_key"}}"#),
        (429, #"{"error":{"message":"You exceeded your quota","code":"insufficient_quota"}}"#),
        (400, #"{"error":{"message":"Invalid voice"}}"#),
    ])
    func answersThatWouldRepeatTheSameFailureAreNotRetried(status: Int, body: String) async {
        let calls = Calls()
        let client = client(calls) { _, request in ok(request, status: status, body: body) }
        await #expect(throws: (any Error).self) { try await client.synthesize(speech, apiKey: "k") }
        #expect(await calls.count == 1)
    }

    @Test func emptyAudioIsNotRetried() async {
        let calls = Calls()
        let client = client(calls) { _, request in ok(request, body: "") }
        await #expect(throws: OpenAITTSError.badResponse) { try await client.synthesize(speech, apiKey: "k") }
        #expect(await calls.count == 1)
    }

    @Test func cancellingWhileWaitingToRetryStopsRetrying() async throws {
        let calls = Calls()
        let client = client(calls, retry: RetryPolicy(maxAttempts: 3, delays: [.seconds(30), .seconds(30)])) { _, _ in
            throw URLError(.timedOut)
        }
        let task = Task { try await client.synthesize(speech, apiKey: "k") }
        while await calls.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let started = ContinuousClock.now
        _ = await task.result
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await calls.count == 1)
    }

    @Test func retryAfterHeaderIsReadAsSeconds() {
        func response(_ value: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x.test")!, statusCode: 429, httpVersion: nil, headerFields: value.map { ["Retry-After": $0] })!
        }
        #expect(OpenAITTSClient.retryAfter(response("3")) == .seconds(3))
        #expect(OpenAITTSClient.retryAfter(response(" 0 ")) == .seconds(0))
        #expect(OpenAITTSClient.retryAfter(response("1.5")) == .seconds(1.5))
        #expect(OpenAITTSClient.retryAfter(response("Wed, 21 Oct 2026 07:28:00 GMT")) == nil)
        #expect(OpenAITTSClient.retryAfter(response("-4")) == nil)
        #expect(OpenAITTSClient.retryAfter(response(nil)) == nil)
    }

    @Test func rateLimitWaitsForRetryAfterNotTheBackoff() async throws {
        let calls = Calls()
        // A backoff of 30 s would make this test time out; Retry-After: 0 must win.
        let client = client(calls, retry: RetryPolicy(maxAttempts: 2, delays: [.seconds(30)])) { call, request in
            call == 1 ? ok(request, status: 429, headers: ["Retry-After": "0"], body: #"{"error":{"code":"rate_limit_exceeded"}}"#) : ok(request)
        }
        _ = try await client.synthesize(speech, apiKey: "k")
        #expect(await calls.count == 2)
    }

    @Test func attemptTimeoutGrowsWithTheTextAndIsBounded() {
        #expect(OpenAITTSClient.attemptTimeout(forCharacters: 0) == 15)
        #expect(OpenAITTSClient.attemptTimeout(forCharacters: 300) == 15)       // the usual paragraph: 15 s
        #expect(OpenAITTSClient.attemptTimeout(forCharacters: 1000) == 28)
        #expect(OpenAITTSClient.attemptTimeout(forCharacters: 2000) == 48)
        #expect(OpenAITTSClient.attemptTimeout(forCharacters: 4096) < 90)
        #expect(OpenAITTSClient.attemptTimeout(forCharacters: 100_000) == 90)
        var long = speech
        long.input = String(repeating: "x", count: 2000)
        #expect(OpenAITTSClient.urlRequest(for: long, apiKey: "k").timeoutInterval == 48)
    }

    @Test func theSessionIsDedicatedAndBounded() {
        let configuration = OpenAITTSClient.session.configuration
        #expect(configuration.timeoutIntervalForResource <= 120)
        #expect(configuration.urlCache == nil)
    }

    @Test func whichErrorsAreWorthRetrying() {
        let retryable: [OpenAITTSError] = [.timedOut, .rateLimited, .server(status: 503), .network("x")]
        let notRetryable: [OpenAITTSError] = [.missingKey, .invalidKey, .quotaExceeded, .badRequest("x"), .badResponse, .audio("x")]
        #expect(retryable.allSatisfy { $0.isRetryable })
        #expect(notRetryable.allSatisfy { !$0.isRetryable })
    }

    @Test func theLogNotesHowManyAttemptsItTookAndHowEachWent() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "calls-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = OpenAICallLog(fileURL: file)
        let calls = Calls()
        let client = client(calls, log: log) { call, request in
            if call < 3 { throw URLError(.timedOut) }
            return ok(request)
        }
        _ = try await client.synthesize(speech, apiKey: "k")
        var records = await log.all()
        for _ in 0..<100 where records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            records = await log.all()
        }
        let record = try #require(records.first)
        #expect(records.count == 1)   // one request as far as the reader is concerned
        #expect(record.outcome == .ok && record.attempts == 3 && record.wasRetried)
        let detail = try #require(record.detail)
        #expect(detail.contains("attempt 1 timed out") && detail.contains("attempt 2 timed out") && detail.contains("attempt 3 ok"))
    }

    @Test func aFailedRetriedRequestIsLoggedOnceWithItsAttempts() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "calls-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = OpenAICallLog(fileURL: file)
        let client = client(Calls(), log: log) { _, _ in throw URLError(.timedOut) }
        await #expect(throws: OpenAITTSError.timedOut) { try await client.synthesize(speech, apiKey: "k") }
        var records = await log.all()
        for _ in 0..<100 where records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            records = await log.all()
        }
        #expect(records.count == 1)
        #expect(records.first?.outcome == .timedOut && records.first?.attempts == 3)
    }

    @Test func recordsWrittenBeforeRetriesExistedStillLoad() throws {
        let old = #"{"id":"6F1E1B9B-7A52-4E9C-9F43-1F7D2B1C2A10","date":0,"kind":"speech","size":10,"seconds":1.5,"outcome":"ok"}"#
        let record = try JSONDecoder().decode(CallRecord.self, from: Data(old.utf8))
        #expect(record.attempts == nil && !record.wasRetried)
        #expect(CallStats([record]).retriedCount == 0)
    }

    @Test func statsCountRetriedRequestsAndHowManyWorked() {
        func record(_ outcome: CallOutcome, attempts: Int?) -> CallRecord {
            CallRecord(date: .now, kind: .speech, size: 10, seconds: 3, outcome: outcome, attempts: attempts)
        }
        let stats = CallStats([record(.ok, attempts: nil), record(.ok, attempts: 2), record(.timedOut, attempts: 3), record(.ok, attempts: 3)])
        #expect(stats.retriedCount == 3)
        #expect(stats.retriedOKCount == 2)
    }
}
