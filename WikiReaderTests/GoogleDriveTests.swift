import Foundation
import SwiftData
import Testing
@testable import WikiReader

// MARK: - OAuth

struct GoogleOAuthTests {
    static let clientID = "123456-abcdef.apps.googleusercontent.com"

    @Test func clientIDIsCheckedAndReversedForTheRedirect() throws {
        let client = try #require(GoogleOAuth.Client(id: "  \(Self.clientID)\n"))
        #expect(client.id == Self.clientID)
        #expect(client.redirectScheme == "com.googleusercontent.apps.123456-abcdef")
        #expect(client.redirectURI == "com.googleusercontent.apps.123456-abcdef:/oauth2redirect")
        #expect(GoogleOAuth.Client(id: "") == nil)
        #expect(GoogleOAuth.Client(id: "sk-not-a-client") == nil)
        #expect(GoogleOAuth.Client(id: ".apps.googleusercontent.com") == nil)
    }

    /// RFC 7636, appendix B.
    @Test func pkceChallengeMatchesTheSpecExample() {
        #expect(GoogleOAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce = GoogleOAuth.PKCE.make()
        #expect(pkce.verifier.count == 64)
        #expect(pkce.challenge == GoogleOAuth.PKCE.challenge(for: pkce.verifier))
        #expect(GoogleOAuth.PKCE.make().verifier != pkce.verifier)
    }

    @Test func authorizationURLAsksForDriveFileWithPKCE() throws {
        let client = try #require(GoogleOAuth.Client(id: Self.clientID))
        let url = GoogleOAuth.authorizationURL(client: client, pkce: GoogleOAuth.PKCE(verifier: "v", challenge: "c"), state: "s1")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["client_id"] == Self.clientID)
        #expect(items["redirect_uri"] == client.redirectURI)
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.file openid email")
        #expect(items["code_challenge"] == "c")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "s1")
    }

    @Test func redirectGivesTheCodeOnlyForOurRequest() throws {
        let base = "com.googleusercontent.apps.x:/oauth2redirect"
        #expect(try GoogleOAuth.code(fromRedirect: URL(string: "\(base)?state=s1&code=4/abc")!, state: "s1") == "4/abc")
        #expect(throws: GoogleAuthError.rejected("state mismatch")) {
            try GoogleOAuth.code(fromRedirect: URL(string: "\(base)?state=other&code=4/abc")!, state: "s1")
        }
        #expect(throws: GoogleAuthError.cancelled) {
            try GoogleOAuth.code(fromRedirect: URL(string: "\(base)?error=access_denied&state=s1")!, state: "s1")
        }
    }

    @Test func tokenRequestsAreFormEncoded() throws {
        let client = try #require(GoogleOAuth.Client(id: Self.clientID))
        let request = GoogleOAuth.tokenRequest(client: client, code: "4/a b", verifier: "ver")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        #expect(request.httpMethod == "POST")
        #expect(body.contains("code=4%2Fa%20b"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=ver"))
        let refresh = String(data: GoogleOAuth.refreshRequest(client: client, refreshToken: "r1").httpBody!, encoding: .utf8)!
        #expect(refresh.contains("grant_type=refresh_token") && refresh.contains("refresh_token=r1"))
    }

    @Test func tokenResponsesAndErrors() throws {
        let ok = try GoogleOAuth.tokenResponse(data: Data(#"{"access_token":"a1","expires_in":3599,"refresh_token":"r1","id_token":"x"}"#.utf8), status: 200)
        #expect(ok == GoogleOAuth.TokenResponse(accessToken: "a1", expiresIn: 3599, refreshToken: "r1", idToken: "x"))
        #expect(throws: GoogleAuthError.signInExpired) {
            try GoogleOAuth.tokenResponse(data: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)
        }
        #expect(throws: GoogleAuthError.rejected("invalid_client")) {
            try GoogleOAuth.tokenResponse(data: Data(#"{"error":"invalid_client"}"#.utf8), status: 401)
        }
    }

    @Test func emailComesFromTheIDToken() {
        let payload = GoogleOAuth.base64URL(Data(#"{"email":"someone@example.com","sub":"1"}"#.utf8))
        #expect(GoogleOAuth.email(fromIDToken: "eyJhbGciOiJSUzI1NiJ9.\(payload).sig") == "someone@example.com")
        #expect(GoogleOAuth.email(fromIDToken: "garbage") == nil)
    }
}

@MainActor
struct GoogleAccountTests {
    final class Calls { var bodies: [String] = [] }

    private func makeAccount(answer: @escaping @Sendable (String) -> (Int, String)) -> (GoogleAccount, KeychainStore, UserDefaults) {
        let store = KeychainStore(service: "tik.tian.com.WikiReader.tests.\(UUID().uuidString)", account: "refreshToken")
        let defaults = UserDefaults(suiteName: "GoogleAccountTests-\(UUID().uuidString)")!
        defaults.set(GoogleOAuthTests.clientID, forKey: SettingsKeys.googleClientID)
        let account = GoogleAccount(refreshTokenStore: store, defaults: defaults) { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let (status, json) = answer(body)
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return (account, store, defaults)
    }

    @Test func signInKeepsTheRefreshTokenAndRefreshesAccessTokens() async throws {
        let (account, store, _) = makeAccount { body in
            body.contains("refresh_token=r1") ? (200, #"{"access_token":"a2","expires_in":3600}"#) : (500, "{}")
        }
        defer { try? store.delete() }
        #expect(!account.isSignedIn)

        let payload = GoogleOAuth.base64URL(Data(#"{"email":"me@example.com"}"#.utf8))
        try account.finishSignIn(.init(accessToken: "a1", expiresIn: 3600, refreshToken: "r1", idToken: "h.\(payload).s"))
        #expect(account.state == .signedIn(email: "me@example.com"))
        #expect(store.read() == "r1")
        #expect(try await account.validAccessToken() == "a1")
        // Forced (as after a 401): asks Google with the refresh token.
        #expect(try await account.validAccessToken(force: true) == "a2")
        #expect(try await account.validAccessToken() == "a2")
    }

    @Test func aRefreshTokenGoogleNoLongerAcceptsSignsOut() async throws {
        let (account, store, _) = makeAccount { _ in (400, #"{"error":"invalid_grant"}"#) }
        defer { try? store.delete() }
        try account.finishSignIn(.init(accessToken: "a1", expiresIn: 0, refreshToken: "r1", idToken: nil))

        await #expect(throws: GoogleAuthError.signInExpired) { try await account.validAccessToken() }
        #expect(account.state == .signedOut)
        #expect(account.problem == GoogleAuthError.signInExpired.message)
        #expect(store.read() == nil)
    }

    @Test func signOutForgetsEverything() throws {
        let (account, store, defaults) = makeAccount { _ in (200, "{}") }
        try account.finishSignIn(.init(accessToken: "a1", expiresIn: 3600, refreshToken: "r1", idToken: nil))
        account.signOut()
        #expect(account.state == .signedOut)
        #expect(store.read() == nil)
        #expect(defaults.string(forKey: SettingsKeys.googleAccountEmail) == nil)
    }
}

// MARK: - A Drive in memory

/// Enough of the Drive v3 API for the client: queries by parent, name and folder type, folder creation, multipart
/// upload, media download and replace.
actor FakeDrive {
    struct File {
        var id: String
        var name: String
        var parent: String
        var mimeType: String
        var data: Data
    }

    private(set) var files: [File] = []
    private(set) var requests: [String] = []
    private var nextID = 1
    /// Answer 401 to the next request, as for an expired access token.
    var rejectNext = false

    func setRejectNext() { rejectNext = true }

    func add(name: String, parent: String, mimeType: String = "application/octet-stream", data: Data = Data()) -> String {
        let id = "f\(nextID)"
        nextID += 1
        files.append(File(id: id, name: name, parent: parent, mimeType: mimeType, data: data))
        return id
    }

    func file(named name: String) -> File? { files.first { $0.name == name } }
    func count(named name: String) -> Int { files.count { $0.name == name } }

    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        requests.append("\(request.httpMethod ?? "GET") \(url.path)")
        func reply(_ status: Int, _ data: Data) -> (Data, URLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        if rejectNext {
            rejectNext = false
            return reply(401, json(["error": ["message": "Invalid Credentials"]]))
        }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let method = request.httpMethod ?? "GET"

        if method == "GET", url.path == "/drive/v3/files" {
            let q = query["q"] ?? ""
            let parent = q.firstMatch(of: #/'([^']*)' in parents/#).map { String($0.1) }
            let names = Set(q.matches(of: #/name = '([^']*)'/#).map { String($0.1) })
            let foldersOnly = q.contains("mimeType = 'application/vnd.google-apps.folder'")
            let found = files.filter {
                (parent == nil || $0.parent == parent) && (names.isEmpty || names.contains($0.name))
                    && (!foldersOnly || $0.mimeType == DriveClient.folderType)
            }
            return reply(200, json(["files": found.map { ["id": $0.id, "name": $0.name] }]))
        }
        if method == "POST", url.path == "/drive/v3/files" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let id = add(name: body["name"] as! String, parent: (body["parents"] as! [String])[0], mimeType: body["mimeType"] as! String)
            return reply(200, json(["id": id]))
        }
        if method == "POST", url.path == "/upload/drive/v3/files" {
            let (metadata, data, mime) = Self.parseMultipart(request)
            let id = add(name: metadata["name"] as! String, parent: (metadata["parents"] as! [String])[0], mimeType: mime, data: data)
            return reply(200, json(["id": id]))
        }
        if method == "PATCH", url.path.hasPrefix("/upload/drive/v3/files/") {
            let id = url.lastPathComponent
            guard let index = files.firstIndex(where: { $0.id == id }) else { return reply(404, Data()) }
            files[index].data = request.httpBody ?? Data()
            return reply(200, json(["id": id]))
        }
        if method == "GET", url.path.hasPrefix("/drive/v3/files/"), query["alt"] == "media" {
            guard let file = files.first(where: { $0.id == url.lastPathComponent }) else { return reply(404, Data()) }
            return reply(200, file.data)
        }
        return reply(400, Data())
    }

    static func parseMultipart(_ request: URLRequest) -> ([String: Any], Data, String) {
        let type = request.value(forHTTPHeaderField: "Content-Type")!
        let boundary = String(type.split(separator: "boundary=")[1])
        let body = request.httpBody!
        let separator = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var rest = body[...]
        while let range = rest.range(of: separator) {
            parts.append(Data(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        let content = parts.dropFirst().map { part -> (String, Data) in
            let split = part.range(of: Data("\r\n\r\n".utf8))!
            let headers = String(data: part[..<split.lowerBound], encoding: .utf8)!
            var data = Data(part[split.upperBound...])
            if data.suffix(2) == Data("\r\n".utf8) { data.removeLast(2) }
            return (headers, data)
        }
        let metadata = try! JSONSerialization.jsonObject(with: content[0].1) as! [String: Any]
        let mime = content[1].0.components(separatedBy: "Content-Type: ").last!.trimmingCharacters(in: .whitespacesAndNewlines)
        return (metadata, content[1].1, mime)
    }
}


// MARK: - Client

struct DriveClientTests {
    @Test func queryLiteralsAreEscaped() {
        #expect(DriveClient.quoted("plain") == "'plain'")
        #expect(DriveClient.quoted("O'Brien \\ x") == #"'O\'Brien \\ x'"#)
    }

    @Test func manyNamesAreAskedInBatches() async throws {
        let drive = FakeDrive()
        let names = (0..<120).map { "k\($0).mp3" }
        for name in names.prefix(70) { _ = await drive.add(name: name, parent: "audio") }
        let client = DriveClient(transport: { try await drive.handle($0) }, token: { _ in "t" })

        let found = try await client.files(named: names, in: "audio")

        #expect(found.count == 70)
        #expect(await drive.requests.count == 3)  // 50 + 50 + 20
    }

    @Test func aRejectedTokenIsRefreshedOnce() async throws {
        let drive = FakeDrive()
        await drive.setRejectNext()
        let forced = ForcedTokens()
        let client = DriveClient(transport: { try await drive.handle($0) }, token: { force in
            await forced.record(force)
            return force ? "fresh" : "stale"
        })
        _ = try await client.files(named: ["x"], in: "p")
        #expect(await forced.values == [false, true])
    }

    @Test func uploadIsMultipartWithMetadataFirst() async throws {
        let drive = FakeDrive()
        let client = DriveClient(transport: { try await drive.handle($0) }, token: { _ in "t" })
        let id = try await client.upload(name: "a.mp3", data: Data([1, 2, 3, 13, 10]), mimeType: "audio/mpeg", in: "audio")
        let file = try #require(await drive.file(named: "a.mp3"))
        #expect(file.id == id)
        #expect(file.parent == "audio")
        #expect(file.mimeType == "audio/mpeg")
        #expect(file.data == Data([1, 2, 3, 13, 10]))
        #expect(try await client.download(fileID: id) == Data([1, 2, 3, 13, 10]))
    }
}

actor ForcedTokens {
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}

// MARK: - The shared audio store

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DriveAudioStoreTests {
    let drive = FakeDrive()
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "DriveStoreTests-\(UUID().uuidString)"))
    let queueFile = URL.temporaryDirectory.appending(path: "DriveQueue-\(UUID().uuidString).json")

    private func makeStore(signedIn: Bool = true) -> DriveAudioStore {
        let drive = drive
        return DriveAudioStore(
            client: DriveClient(transport: { try await drive.handle($0) }, token: { _ in "t" }),
            isSignedIn: { signedIn }, cache: cache, queueFile: queueFile, retryDelay: .milliseconds(20)
        )
    }

    private func request(_ text: String) -> OpenAISpeechRequest {
        OpenAISpeechEngine.request(for: text, voice: "alloy")
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func firstUseCreatesTheSharedFolders() async throws {
        let layout = try await makeStore().layout()
        let root = try #require(await drive.file(named: DriveAudioStore.rootName))
        #expect(root.parent == "root")
        #expect(layout.root == root.id)
        #expect(await drive.file(named: "audio")?.parent == root.id)
        #expect(await drive.file(named: "articles")?.parent == root.id)
        let format = try #require(await drive.file(named: "format.json"))
        let object = try JSONSerialization.jsonObject(with: format.data) as? [String: Any]
        #expect(object?["formatVersion"] as? Int == 1)
        #expect(object?["key"] as? String == "ios-v1")
    }

    @Test func anExistingFolderIsReusedNotDuplicated() async throws {
        let root = await drive.add(name: DriveAudioStore.rootName, parent: "root", mimeType: DriveClient.folderType)
        _ = await drive.add(name: "format.json", parent: root, data: Data(#"{"formatVersion":1,"key":"ios-v1"}"#.utf8))
        let layout = try await makeStore().layout()
        #expect(layout.root == root)
        #expect(await drive.count(named: DriveAudioStore.rootName) == 1)
        #expect(await drive.count(named: "format.json") == 1)
    }

    @Test func aFolderInAnotherFormatIsRefused() async throws {
        let root = await drive.add(name: DriveAudioStore.rootName, parent: "root", mimeType: DriveClient.folderType)
        _ = await drive.add(name: "format.json", parent: root, data: Data(#"{"formatVersion":2}"#.utf8))
        await #expect(throws: DriveError.self) { try await makeStore().layout() }
    }

    @Test func audioOnDriveIsDownloadedIntoTheCache() async throws {
        let store = makeStore()
        let audio = try await store.layout().audio
        let wanted = request("History")
        _ = await drive.add(name: SpeechAudioCache.key(for: wanted) + ".mp3", parent: audio, data: Data("ID3 from drive".utf8))

        let url = await store.fetch(wanted, into: cache)

        #expect(url == cache.cachedFile(for: wanted))
        #expect(try Data(contentsOf: #require(url)) == Data("ID3 from drive".utf8))
        #expect(await store.fetch(request("Not there"), into: cache) == nil)
        #expect(store.isOnDrive(SpeechAudioCache.key(for: request("Not there"))) == false)
    }

    @Test func signedOutAsksNothing() async throws {
        let store = makeStore(signedIn: false)
        #expect(await store.fetch(request("History"), into: cache) == nil)
        #expect(await drive.requests.isEmpty)
    }

    @Test func generatedAudioIsUploadedOnceAndTheQueueSurvivesARestart() async throws {
        let store = makeStore()
        let made = request("A new paragraph.")
        try cache.store(Data("ID3 new".utf8), for: made)

        store.didGenerate(made, in: cache)
        store.didGenerate(made, in: cache)
        try await waitFor { store.pendingUploads.isEmpty && !store.isUploading }

        let name = SpeechAudioCache.key(for: made) + ".mp3"
        #expect(await drive.count(named: name) == 1)
        #expect(await drive.file(named: name)?.data == Data("ID3 new".utf8))
        #expect(store.isOnDrive(SpeechAudioCache.key(for: made)) == true)
        #expect(store.uploadedCount == 1)

        // A queue left on disk is picked up by the next launch.
        let other = request("Queued before quitting.")
        try cache.store(Data("ID3 q".utf8), for: other)
        try JSONEncoder().encode([SpeechAudioCache.key(for: other)]).write(to: queueFile)
        let restarted = makeStore()
        #expect(restarted.pendingUploads.count == 1)
        restarted.pumpUploads()
        try await waitFor { restarted.pendingUploads.isEmpty && !restarted.isUploading }
        #expect(await drive.count(named: SpeechAudioCache.key(for: other) + ".mp3") == 1)
    }

    @Test func audioFromOtherCachesIsNotShared() async throws {
        let store = makeStore()
        let elsewhere = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "Elsewhere-\(UUID().uuidString)"))
        store.didGenerate(request("x"), in: elsewhere)
        #expect(store.pendingUploads.isEmpty)
    }

    @Test func manifestListsEveryPieceAndCompletesWhenAllAudioIsThere() async throws {
        let store = makeStore()
        let blocks: [ContentBlock] = [.heading("History", level: 2), .paragraph("The first paragraph.")]
        let url = "https://en.wikipedia.org/wiki/Paris"
        try cache.store(Data("ID3 h".utf8), for: request("History"))

        await store.noteArticle(title: "Paris", url: url, blocks: blocks, voice: "alloy")
        let name = DriveManifest.urlHash(url) + ".json"
        var manifest = try JSONDecoder().decode(DriveManifest.self, from: #require(await drive.file(named: name)).data)
        #expect(manifest.chunks.map(\.text) == ["History", "The first paragraph."])
        #expect(manifest.chunks.map(\.kind) == ["heading", "paragraph"])
        #expect(manifest.chunks.map(\.p) == [0, 1])
        #expect(manifest.voice == "alloy")
        #expect(manifest.chunker == "ios-paragraph-4096")
        #expect(manifest.updatedBy == "ios")
        #expect(!manifest.complete)

        // Both pieces end up on Drive: the manifest is rewritten in place as complete.
        try cache.store(Data("ID3 p".utf8), for: request("The first paragraph."))
        store.didGenerate(request("History"), in: cache)
        store.didGenerate(request("The first paragraph."), in: cache)
        try await waitFor {
            guard let file = await drive.file(named: name),
                  let written = try? JSONDecoder().decode(DriveManifest.self, from: file.data) else { return false }
            return written.complete
        }
        manifest = try JSONDecoder().decode(DriveManifest.self, from: #require(await drive.file(named: name)).data)
        #expect(manifest.complete)
        #expect(await drive.count(named: name) == 1)
    }
}

// MARK: - Drive before OpenAI

/// A remote source answering from a fixed set of texts.
@MainActor
final class FakeRemote: RemoteAudioSource {
    var isEnabled = true
    var has: Set<String> = []
    var generated: [String] = []

    func fetch(_ request: OpenAISpeechRequest, into cache: SpeechAudioCache) async -> URL? {
        guard has.contains(request.input) else { return nil }
        return try? cache.store(Data("ID3 remote".utf8), for: request)
    }

    func didGenerate(_ request: OpenAISpeechRequest, in cache: SpeechAudioCache) {
        generated.append(request.input)
    }
}

@MainActor
struct DriveBeforeOpenAITests {
    let cache = SpeechAudioCache(directory: URL.temporaryDirectory.appending(path: "DriveFirst-\(UUID().uuidString)"))
    let sent = SentInputs()

    private var client: OpenAITTSClient {
        let sent = sent
        return OpenAITTSClient(transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            await sent.record(body["input"]!)
            return (Data("ID3 openai".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, retry: .never)
    }

    @Test func driveIsAskedFirstAndOpenAIOnlyForTheRest() async throws {
        let remote = FakeRemote()
        remote.has = ["On Drive."]
        let generations = SpeechGenerations(remote: remote)
        let onDrive = OpenAISpeechEngine.request(for: "On Drive.", voice: "alloy")
        let notOnDrive = OpenAISpeechEngine.request(for: "Not on Drive.", voice: "alloy")

        let first = await generations.generate(onDrive, apiKey: "sk", client: client, cache: cache).value
        let second = await generations.generate(notOnDrive, apiKey: "sk", client: client, cache: cache).value

        #expect(try Data(contentsOf: first.get()) == Data("ID3 remote".utf8))
        #expect(try Data(contentsOf: second.get()) == Data("ID3 openai".utf8))
        #expect(await sent.inputs == ["Not on Drive."])
        #expect(remote.generated == ["Not on Drive."])  // shared back
    }

    @Test func withoutAKeyDriveStillServes() async throws {
        let remote = FakeRemote()
        remote.has = ["On Drive."]
        let generations = SpeechGenerations(remote: remote)
        #expect(generations.canWorkWithoutKey)
        let hit = await generations.generate(OpenAISpeechEngine.request(for: "On Drive.", voice: "alloy"), apiKey: nil, client: client, cache: cache).value
        let miss = await generations.generate(OpenAISpeechEngine.request(for: "Elsewhere.", voice: "alloy"), apiKey: nil, client: client, cache: cache).value
        #expect((try? hit.get()) != nil)
        #expect(miss == .failure(.missingKey))
        #expect(await sent.inputs.isEmpty)
    }

    @Test func aSignedOutRemoteIsSkipped() async throws {
        let remote = FakeRemote()
        remote.isEnabled = false
        remote.has = ["On Drive."]
        let generations = SpeechGenerations(remote: remote)
        _ = await generations.generate(OpenAISpeechEngine.request(for: "On Drive.", voice: "alloy"), apiKey: "sk", client: client, cache: cache).value
        #expect(await sent.inputs == ["On Drive."])
    }

    @Test func downloadPlansPriceOnlyWhatIsNotOnDrive() throws {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let article = Article(title: "T", sourceURL: URL(string: "https://en.wikipedia.org/wiki/T")!, blocks: [])
        container.mainContext.insert(article)
        let pieces = ArticleAudio.pieces(of: [.paragraph(String(repeating: "a", count: 840)), .paragraph(String(repeating: "b", count: 840))], voice: "alloy")
        var plan = AudioDownloader.Plan(voice: "alloy", items: pieces.map { .init(article: article.persistentModelID, piece: $0) }, articleCount: 1)
        let onDrive = SpeechAudioCache.key(for: pieces[0].request)
        plan.markOnDrive { $0 == onDrive }
        #expect(plan.driveCharacters == 840)
        #expect(plan.generatedCharacters == 840)
        #expect(abs(plan.dollars - ArticleAudio.dollars(forCharacters: 840)) < 1e-9)
    }
}
