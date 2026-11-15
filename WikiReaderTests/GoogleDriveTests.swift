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

    @Test func grantedScopesAreReadAndDriveMustBeAmongThem() throws {
        let granted = try GoogleOAuth.tokenResponse(
            data: Data(#"{"access_token":"a","expires_in":1,"scope":"openid https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email"}"#.utf8),
            status: 200
        )
        #expect(granted.grantsDrive)
        // The Drive box left unticked on Google's page: only the basic scopes come back.
        let partial = try GoogleOAuth.tokenResponse(
            data: Data(#"{"access_token":"a","expires_in":1,"scope":"openid https://www.googleapis.com/auth/userinfo.email"}"#.utf8),
            status: 200
        )
        #expect(!partial.grantsDrive)
        // A response without the field is taken at its word.
        #expect(try GoogleOAuth.tokenResponse(data: Data(#"{"access_token":"a","expires_in":1}"#.utf8), status: 200).grantsDrive)
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

    @Test func signingInAsSomeoneElseIsNoticed() throws {
        let (account, store, _) = makeAccount { _ in (500, "{}") }
        defer { try? store.delete() }
        var changes = 0
        account.onAccountChange = { changes += 1 }
        func signIn(_ email: String) throws {
            let payload = GoogleOAuth.base64URL(Data(#"{"email":"\#(email)"}"#.utf8))
            try account.finishSignIn(.init(accessToken: "a1", expiresIn: 3600, refreshToken: "r1", idToken: "h.\(payload).s"))
        }

        try signIn("me@example.com")
        #expect(changes == 0)
        #expect(account.accountID == "me@example.com")
        account.signOut()
        #expect(account.accountID == nil)
        try signIn("Me@Example.com")  // the same account
        #expect(changes == 0)
        account.signOut()
        try signIn("other@example.com")
        #expect(changes == 1)
        #expect(account.accountID == "other@example.com")
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

    @Test func aSignInWithoutDriveIsRefusedWithTheReason() throws {
        let (account, store, _) = makeAccount { _ in (200, "{}") }
        defer { try? store.delete() }
        #expect(throws: GoogleAuthError.driveNotGranted) {
            try account.finishSignIn(.init(accessToken: "a1", expiresIn: 3600, refreshToken: "r1", idToken: nil, scope: "openid email"))
        }
        #expect(account.state == .signedOut)
        #expect(account.problem == GoogleAuthError.driveNotGranted.message)
        #expect(store.read() == nil)
    }

    @Test func driveRefusingTheTokenSignsOut() throws {
        let (account, store, _) = makeAccount { _ in (200, "{}") }
        defer { try? store.delete() }
        try account.finishSignIn(.init(accessToken: "a1", expiresIn: 3600, refreshToken: "r1", idToken: nil))
        account.driveAccessMissing()
        #expect(account.state == .signedOut)
        #expect(account.problem == GoogleAuthError.driveNotGranted.message)
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
        var createdTime: String
        var description: String?
        var properties: [String: String]?
    }

    private(set) var files: [File] = []
    private(set) var requests: [String] = []
    private var nextID = 1
    /// Answer 401 to the next request, as for an expired access token.
    var rejectNext = false
    /// Answer every request with 403 "insufficient authentication scopes", as for a token without Drive access.
    var lacksScope = false

    func setLacksScope(_ value: Bool) { lacksScope = value }

    func setRejectNext() { rejectNext = true }

    /// Status codes to answer the next uploads with, before behaving normally again.
    private var uploadFailures: [Int] = []
    func failNextUploads(_ statuses: [Int]) { uploadFailures = statuses }

    func add(name: String, parent: String, mimeType: String = "application/octet-stream", data: Data = Data()) -> String {
        let id = "f\(nextID)"
        // Creation times one second apart, in Drive's RFC 3339 format.
        let created = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(nextID)))
        nextID += 1
        files.append(File(id: id, name: name, parent: parent, mimeType: mimeType, data: data, createdTime: created))
        return id
    }

    func remove(named name: String) { files.removeAll { $0.name == name } }
    /// What the site does when it moves a folder: only the parent changes, the id stays.
    func move(_ id: String, to parent: String) { files.indices.filter { files[$0].id == id }.forEach { files[$0].parent = parent } }
    func setData(_ id: String, _ data: Data) { files.indices.filter { files[$0].id == id }.forEach { files[$0].data = data } }
    func files(in parent: String) -> [File] { files.filter { $0.parent == parent } }
    func listCount() -> Int { requests.count { $0 == "GET /drive/v3/files" } }
    func uploadCount() -> Int { requests.count { $0 == "POST /upload/drive/v3/files" } }

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
        if lacksScope {
            return reply(403, json(["error": ["message": "Request had insufficient authentication scopes."]]))
        }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let method = request.httpMethod ?? "GET"

        if method == "GET", url.path == "/drive/v3/files" {
            let q = query["q"] ?? ""
            let parent = q.firstMatch(of: #/'([^']*)' in parents/#).map { String($0.1) }
            let names = Set(q.matches(of: #/name = '([^']*)'/#).map { String($0.1) })
            let foldersOnly = q.contains("mimeType = 'application/vnd.google-apps.folder'")
            let after = q.firstMatch(of: #/createdTime > '([^']*)'/#).flatMap { Self.date(String($0.1)) }
            let found = files.filter {
                (parent == nil || $0.parent == parent) && (names.isEmpty || names.contains($0.name))
                    && (!foldersOnly || $0.mimeType == DriveClient.folderType)
                    && (after == nil || Self.date($0.createdTime)! > after!)
            }
            return reply(200, json(["files": found.map { ["id": $0.id, "name": $0.name, "createdTime": $0.createdTime] }]))
        }
        if method == "POST", url.path == "/drive/v3/files" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let id = add(name: body["name"] as! String, parent: (body["parents"] as! [String])[0], mimeType: body["mimeType"] as! String)
            return reply(200, json(["id": id]))
        }
        if method == "POST", url.path == "/upload/drive/v3/files" {
            if !uploadFailures.isEmpty {
                let status = uploadFailures.removeFirst()
                return reply(status, json(["error": ["message": status == 403 ? "User rate limit exceeded." : "Backend Error"]]))
            }
            let (metadata, data, mime) = Self.parseMultipart(request)
            let id = add(name: metadata["name"] as! String, parent: (metadata["parents"] as! [String])[0], mimeType: mime, data: data)
            if let index = files.firstIndex(where: { $0.id == id }) {
                files[index].description = metadata["description"] as? String
                files[index].properties = metadata["properties"] as? [String: String]
            }
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

    static func date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
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

    @Test func aTokenWithoutDriveAccessIsRecognized() async throws {
        let drive = FakeDrive()
        await drive.setLacksScope(true)
        let client = DriveClient(transport: { try await drive.handle($0) }, token: { _ in "t" })
        await #expect(throws: DriveError.missingDriveAccess) { try await client.files(named: ["x"], in: "p") }
        #expect(!DriveError.missingDriveAccess.isTransient)
        #expect(DriveClient.isMissingScope("Request had insufficient authentication scopes."))
        #expect(!DriveClient.isMissingScope("User rate limit exceeded."))
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
    let indexFile = URL.temporaryDirectory.appending(path: "DriveIndex-\(UUID().uuidString).json")
    let network = NetworkState()
    let access = AccessLog()

    final class NetworkState { var free = true }
    final class AccessLog {
        var lost = 0
        var awake: [Bool] = []
    }

    private func makeStore(
        signedIn: Bool = true, lookUpFirst: Bool = true, autoBackUp: Bool = true,
        siteAudio: Set<String> = [], layoutRecheck: TimeInterval = DriveAudioStore.layoutFreshness
    ) -> DriveAudioStore {
        let drive = drive, network = network, access = access
        return DriveAudioStore(
            client: DriveClient(transport: { try await drive.handle($0) }, token: { _ in "t" }),
            isSignedIn: { signedIn }, cache: cache, queueFile: queueFile, indexFile: indexFile,
            retryDelay: .milliseconds(20), canUploadNow: { network.free }, onAccessLost: { access.lost += 1 },
            keepAwake: { access.awake.append($0) }, looksUpFirst: { lookUpFirst }, backsUpAutomatically: { autoBackUp },
            isSiteAudio: { siteAudio.contains($0) }, layoutRecheck: layoutRecheck
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

    @Test func aFormatFileWithoutTheKeyIsRefusedLikeChromeDoes() async throws {
        let root = await drive.add(name: DriveAudioStore.rootName, parent: "root", mimeType: DriveClient.folderType)
        _ = await drive.add(name: "format.json", parent: root, data: Data(#"{"formatVersion":1}"#.utf8))
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
        #expect(access.awake.first == true && access.awake.last == false)  // screen kept on only while uploading

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

    @Test func theIndexIsListedOnceThenOnlyWhatIsNew() async throws {
        let store = makeStore()
        let audio = try await store.layout().audio
        for text in ["One.", "Two.", "Three."] {
            _ = await drive.add(name: SpeechAudioCache.key(for: request(text)) + ".mp3", parent: audio)
        }
        await store.syncIndex()
        #expect(store.isOnDrive(SpeechAudioCache.key(for: request("Two."))) == true)
        #expect(store.isOnDrive(SpeechAudioCache.key(for: request("Four."))) == false)

        // Another device uploads one more: a forced sync lists only that (and a minute's overlap) in the audio folder,
        // plus the few manifests: two requests however many files there are.
        _ = await drive.add(name: SpeechAudioCache.key(for: request("Four.")) + ".mp3", parent: audio)
        let before = await drive.listCount()
        await store.syncIndex(force: true)
        #expect(await drive.listCount() == before + 2)
        #expect(store.isOnDrive(SpeechAudioCache.key(for: request("Four."))) == true)

        // The index survives a restart; a recent answer needs no request at all.
        let restarted = makeStore()
        #expect(restarted.isOnDrive(SpeechAudioCache.key(for: request("One."))) == true)
        await store.syncIndex()
        #expect(await drive.listCount() == before + 2)
    }

    @Test func aPieceDeletedOnDriveIsForgottenWhenItCantBeDownloaded() async throws {
        let store = makeStore()
        let audio = try await store.layout().audio
        let wanted = request("Gone.")
        let name = SpeechAudioCache.key(for: wanted) + ".mp3"
        _ = await drive.add(name: name, parent: audio)
        await store.syncIndex()
        await drive.remove(named: name)
        #expect(await store.fetch(wanted, into: cache) == nil)
        #expect(store.isOnDrive(SpeechAudioCache.key(for: wanted)) != true)
    }

    @Test func rateLimitedUploadsBackOffAndThenFinish() async throws {
        let store = makeStore()
        _ = try await store.layout()
        let before = await drive.uploadCount()  // format.json
        await drive.failNextUploads([429, 403])
        let texts = (1...5).map { "Paragraph \($0)." }
        for text in texts { try cache.store(Data("ID3 \(text)".utf8), for: request(text)) }

        store.enqueue(texts.map { SpeechAudioCache.key(for: request($0)) })
        try await waitFor { store.pendingUploads.isEmpty && !store.isUploading }

        #expect(store.pendingUploads.isEmpty)
        for text in texts { #expect(await drive.count(named: SpeechAudioCache.key(for: request(text)) + ".mp3") == 1) }
        #expect(await drive.uploadCount() - before == 7)  // 5 files, 2 refused once
    }

    @Test func uploadsWaitForAFreeConnection() async throws {
        let store = makeStore()
        _ = try await store.layout()
        let before = await drive.uploadCount()  // format.json
        network.free = false
        let made = request("Wait for Wi-Fi.")
        try cache.store(Data("ID3 w".utf8), for: made)
        store.enqueue([SpeechAudioCache.key(for: made)])
        #expect(store.isWaitingForFreeNetwork)
        #expect(await drive.uploadCount() == before)

        network.free = true
        store.pumpUploads()
        try await waitFor { store.pendingUploads.isEmpty && !store.isUploading }
        #expect(!store.isWaitingForFreeNetwork)
        #expect(await drive.uploadCount() - before == 1)
    }

    @Test func driveTimesAreMovedBackForTheOverlap() {
        #expect(DriveAudioStore.rfc3339(minus: 60, from: "2026-11-01T08:00:30.250Z") == "2026-11-01T07:59:30.250Z")
        #expect(DriveAudioStore.rfc3339(minus: 60, from: "2026-11-01T08:00:30Z") == "2026-11-01T07:59:30.000Z")
        #expect(DriveAudioStore.rfc3339(minus: 60, from: "nonsense") == nil)
    }

    @Test func aSignInWithoutDriveAccessIsReportedNotRetried() async throws {
        let store = makeStore()
        await drive.setLacksScope(true)
        let made = request("Never sent.")
        try cache.store(Data("ID3 n".utf8), for: made)

        store.enqueue([SpeechAudioCache.key(for: made)])
        try await waitFor { !store.isUploading }
        try await Task.sleep(for: .milliseconds(100))  // longer than the retry delay: nothing may try again

        #expect(access.lost >= 1)
        #expect(store.lastError == DriveError.missingDriveAccess.message)
        #expect(store.pendingUploads.count == 1)  // kept for after signing in again
        #expect(await drive.uploadCount() == 0)
    }

    @Test func uploadsLookAtDriveFirstSoNothingIsUploadedTwice() async throws {
        // Another device already uploaded this piece; this iPhone hasn't listed Drive yet.
        let setup = makeStore()
        let audio = try await setup.layout().audio
        let made = request("Already there.")
        _ = await drive.add(name: SpeechAudioCache.key(for: made) + ".mp3", parent: audio)
        try cache.store(Data("ID3 a".utf8), for: made)
        let before = await drive.uploadCount()

        let store = makeStore()
        store.enqueue([SpeechAudioCache.key(for: made)])
        try await waitFor { store.pendingUploads.isEmpty && !store.isUploading }

        #expect(await drive.uploadCount() == before)
        #expect(await drive.count(named: SpeechAudioCache.key(for: made) + ".mp3") == 1)
    }

    @Test func backupStatusComparesThisIPhoneWithDrive() async throws {
        let url = "https://en.wikipedia.org/wiki/T"
        let blocks: [ContentBlock] = [.heading("History", level: 2), .paragraph("First."), .paragraph("Second.")]
        let data = try JSONEncoder().encode(blocks)
        func key(_ text: String, _ voice: String) -> String { SpeechAudioCache.key(for: OpenAISpeechEngine.request(for: text, voice: voice)) }
        func backup(indexed: Set<String>, pending: Set<String> = [], manifests: Set<String> = []) async -> DriveAudioStore.ArticleBackup {
            await DriveAudioStore.backup(url: url, blocksData: data, voice: "alloy", indexed: indexed, pending: pending, manifests: manifests, cache: cache)
        }
        let manifest: Set<String> = [DriveManifest.urlHash(url) + ".json"]

        #expect(await backup(indexed: []).state == .noAudio)

        // Two alloy parts and one marin part on this iPhone.
        try cache.store(Data(count: 100), for: OpenAISpeechEngine.request(for: "History", voice: "alloy"))
        try cache.store(Data(count: 250), for: OpenAISpeechEngine.request(for: "First.", voice: "alloy"))
        try cache.store(Data(count: 50), for: OpenAISpeechEngine.request(for: "Second.", voice: "marin"))
        let all: Set<String> = [key("History", "alloy"), key("First.", "alloy"), key("Second.", "marin")]

        let none = await backup(indexed: [])
        #expect(none.state == .notBackedUp)
        #expect(none.missing == 3)
        #expect(none.piecesHere == 2 && none.pieces == 3 && none.bytesHere == 350)

        let queued = await backup(indexed: [key("History", "alloy")], pending: [key("First.", "alloy"), key("Second.", "marin")])
        #expect(queued.state == .uploading)
        #expect(queued.waiting == 2)

        let done = await backup(indexed: all, manifests: manifest)
        #expect(done == DriveAudioStore.ArticleBackup(
            pieces: 3, piecesHere: 2, piecesOnDrive: 2, bytesHere: 350, waiting: 0, missing: 0, otherVoicePieces: 1, hasManifest: true
        ))
        #expect(done.state == .backedUp)
        #expect(await backup(indexed: all).hasManifest == false)
    }

    @Test func backUpQueuesOnlyWhatDriveLacksIncludingAudioMadeWhileSignedOut() async throws {
        let url = "https://en.wikipedia.org/wiki/T"
        let blocks: [ContentBlock] = [.paragraph("Made earlier."), .paragraph("Made while signed out."), .paragraph("Never made.")]
        let data = try JSONEncoder().encode(blocks)
        let store = makeStore()
        let audio = try await store.layout().audio
        // On Drive already (uploaded by another device), and on this iPhone too.
        let earlier = request("Made earlier.")
        _ = await drive.add(name: SpeechAudioCache.key(for: earlier) + ".mp3", parent: audio)
        try cache.store(Data("ID3 e".utf8), for: earlier)
        // Generated while signed out: on this iPhone only, never queued.
        let offline = request("Made while signed out.")
        try cache.store(Data("ID3 o".utf8), for: offline)
        let before = await drive.uploadCount()

        let result = await store.backUp([DriveArticle(title: "T", url: url, blocksData: data)], voice: "alloy")
        try await waitFor { store.pendingUploads.isEmpty && !store.isUploading && store.manifestNames.count == 1 }

        #expect(result == DriveAudioStore.BackupResult(onThisIPhone: 2, missing: 1))
        #expect(store.backupRun == nil)  // automatic: no progress row
        #expect(await drive.count(named: SpeechAudioCache.key(for: offline) + ".mp3") == 1)
        #expect(await drive.count(named: SpeechAudioCache.key(for: earlier) + ".mp3") == 1)
        // The audio and the manifest: two uploads.
        #expect(await drive.uploadCount() - before == 2)
        #expect(store.manifestNames == [DriveManifest.urlHash(url) + ".json"])
    }

    @Test func whatOnlyDriveHasIsCountedForDownloading() async throws {
        let url = "https://en.wikipedia.org/wiki/T"
        let blocks: [ContentBlock] = [.paragraph("Here and there."), .paragraph("Only on Drive.")]
        let data = try JSONEncoder().encode(blocks)
        func key(_ text: String) -> String { SpeechAudioCache.key(for: request(text)) }
        try cache.store(Data(count: 10), for: request("Here and there."))

        let backup = await DriveAudioStore.backup(
            url: url, blocksData: data, voice: "alloy", indexed: [key("Here and there."), key("Only on Drive.")],
            pending: [], manifests: [], cache: cache
        )
        #expect(backup.piecesOnDrive == 2)
        #expect(backup.piecesOnlyOnDrive == 1)
        #expect(backup.charactersOnlyOnDrive == "Only on Drive.".count)
        #expect(backup.state == .backedUp)
    }

    @Test func withAutomaticBackupOffOnlyWhatIsAskedForGoesUp() async throws {
        let url = "https://en.wikipedia.org/wiki/T"
        let blocks: [ContentBlock] = [.paragraph("Generated here.")]
        let data = try JSONEncoder().encode(blocks)
        let library = [DriveArticle(title: "T", url: url, blocksData: data)]
        let store = makeStore(autoBackUp: false)
        let generated = request("Generated here.")
        try cache.store(Data("ID3 g".utf8), for: generated)
        let manifest = DriveManifest.urlHash(url) + ".json"

        store.didGenerate(generated, in: cache)
        await store.backUpIfDue(library, voice: "alloy")
        await store.noteArticle(title: "T", url: url, blocks: blocks, voice: "alloy")
        #expect(store.pendingUploads.isEmpty)
        #expect(!store.isBackingUpAutomatically)
        #expect(await drive.file(named: manifest) == nil)
        #expect(await drive.count(named: SpeechAudioCache.key(for: generated) + ".mp3") == 0)

        let result = await store.backUp(library, voice: "alloy", showsProgress: true)
        #expect(result?.missing == 1)
        #expect(store.backupRun == DriveAudioStore.BackupRun(total: 1, done: 0))
        try await waitFor { store.backupRun?.isFinished == true && store.manifestNames.contains(manifest) }

        #expect(store.backupRun == DriveAudioStore.BackupRun(total: 1, done: 1))
        #expect(await drive.count(named: SpeechAudioCache.key(for: generated) + ".mp3") == 1)
        #expect(await drive.file(named: manifest) != nil)
        store.dismissBackupRun()
        #expect(store.backupRun == nil)
    }

    @Test func aBackupAskedForCanBeStopped() async throws {
        let blocks: [ContentBlock] = [.paragraph("One."), .paragraph("Two.")]
        let data = try JSONEncoder().encode(blocks)
        for text in ["One.", "Two."] { try cache.store(Data("ID3".utf8), for: request(text)) }
        network.free = false  // held, so nothing goes up before Stop
        let store = makeStore()

        await store.backUp([DriveArticle(title: "T", url: "https://en.wikipedia.org/wiki/T", blocksData: data)], voice: "alloy", showsProgress: true)
        #expect(store.pendingUploads.count == 2)
        #expect(store.backupRun == DriveAudioStore.BackupRun(total: 2, done: 0))
        #expect(store.isWaitingForFreeNetwork)

        store.stopBackupRun()
        #expect(store.pendingUploads.isEmpty)
        #expect(store.backupRun == nil)
    }

    @Test func checkingDriveFirstCanBeTurnedOffWithoutSigningOut() {
        let store = makeStore(lookUpFirst: false)
        #expect(store.isEnabled)
        #expect(!store.looksUpBeforeGenerating)
        #expect(store.isBackingUpAutomatically)
        #expect(makeStore().looksUpBeforeGenerating)
        #expect(!makeStore(signedIn: false).looksUpBeforeGenerating)
    }

    @Test func anUnchangedManifestIsNotWrittenAgainAfterARestart() async throws {
        let blocks: [ContentBlock] = [.paragraph("Only paragraph.")]
        let url = "https://en.wikipedia.org/wiki/Once"
        await makeStore().noteArticle(title: "Once", url: url, blocks: blocks, voice: "alloy")
        let afterFirst = await drive.requests.filter { $0.hasPrefix("POST /upload") || $0.hasPrefix("PATCH") }.count

        let restarted = makeStore()
        await restarted.noteArticle(title: "Once", url: url, blocks: blocks, voice: "alloy")
        let afterSecond = await drive.requests.filter { $0.hasPrefix("POST /upload") || $0.hasPrefix("PATCH") }.count

        #expect(afterSecond == afterFirst)
        #expect(await drive.count(named: DriveManifest.urlHash(url) + ".json") == 1)
    }

    @Test func anIndexSavedBeforeManifestsWereTrackedStillLoads() throws {
        let old = #"{"folder":"f9","files":{"abc":"f10"},"syncedThrough":"2026-11-01T08:00:00Z"}"#
        let index = try JSONDecoder().decode(DriveAudioStore.AudioIndex.self, from: Data(old.utf8))
        #expect(index.files == ["abc": "f10"])
        #expect(index.manifests.isEmpty && index.manifestDigests.isEmpty)
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

    // MARK: - One folder for the site and the apps (docs/shared-drive-layout.md)

    static let legacyFormat = #"{"formatVersion":1,"key":"ios-v1"}"#
    static let sharedFormat = #"{"formatVersion":2,"key":"ios-v1","layout":"english-reader-drive/2"}"#
    static let movedFormat = #"{"formatVersion":2,"key":"ios-v1","movedTo":"English Reader"}"#

    private func folder(_ name: String, in parent: String = "root") async -> String {
        await drive.add(name: name, parent: parent, mimeType: DriveClient.folderType)
    }

    @discardableResult
    private func format(_ json: String, in folder: String) async -> String {
        await drive.add(name: "format.json", parent: folder, mimeType: "application/json", data: Data(json.utf8))
    }

    @Test func theSitesFolderIsLeftAloneUntilItSaysVersion2() async throws {
        let shared = await folder(DriveAudioStore.sharedRootName)
        _ = await folder("articles", in: shared)
        let legacy = await folder(DriveAudioStore.rootName)
        await format(Self.legacyFormat, in: legacy)

        let layout = try await makeStore().layout()
        #expect(layout.root == legacy)
        #expect(layout.rootName == DriveAudioStore.rootName)
        #expect(layout.otherRoot == shared)
        #expect(layout.otherAudio == nil)
        #expect(await drive.files(in: shared).map(\.name) == ["articles"])  // nothing written into the site's folder
    }

    @Test func withoutTheOldFolderTheAppMakesItAndNeverWritesTheSitesVersion2() async throws {
        let shared = await folder(DriveAudioStore.sharedRootName)
        let layout = try await makeStore().layout()
        let legacy = try #require(await drive.file(named: DriveAudioStore.rootName))
        #expect(layout.root == legacy.id)
        #expect(await drive.files(in: shared).isEmpty)
        let written = try #require(await drive.files(in: legacy.id).first { $0.name == "format.json" })
        #expect(DriveAudioStore.FolderFormat(try JSONSerialization.jsonObject(with: written.data) as? [String: Any]) == .legacy)
    }

    @Test func afterTheMoveTheSitesFolderIsUsedWithTheSameAudio() async throws {
        let shared = await folder(DriveAudioStore.sharedRootName)
        let sharedArticles = await folder("articles", in: shared)
        let legacy = await folder(DriveAudioStore.rootName)
        let legacyFormatFile = await format(Self.legacyFormat, in: legacy)
        let audio = await folder("audio", in: legacy)
        _ = await folder("articles", in: legacy)
        let old = request("Paid for once.")
        _ = await drive.add(name: SpeechAudioCache.key(for: old) + ".mp3", parent: audio, data: Data("ID3 old".utf8))
        let store = makeStore(layoutRecheck: 0)
        await store.syncIndex()
        #expect(store.isOnDrive(SpeechAudioCache.key(for: old)) == true)
        #expect(store.folderName == DriveAudioStore.rootName)

        // The site moves the audio folder whole, writes its version 2 last, and marks the old folder moved.
        await drive.move(audio, to: shared)
        await format(Self.sharedFormat, in: shared)
        await drive.setData(legacyFormatFile, Data(Self.movedFormat.utf8))

        // Coming to the front: the site's folder is used, the audio already indexed is still known.
        store.appBecameActive()
        let layout = try await store.layout()
        #expect(layout.root == shared)
        #expect(layout.audio == audio)
        #expect(layout.articles == sharedArticles)
        #expect(layout.otherRoot == legacy)
        #expect(store.folderName == DriveAudioStore.sharedRootName)
        await store.syncIndex()
        #expect(store.isOnDrive(SpeechAudioCache.key(for: old)) == true)

        // New audio goes into the moved folder; no folder is made anywhere.
        let made = request("Made after the move.")
        try cache.store(Data("ID3 new".utf8), for: made)
        store.didGenerate(made, in: cache)
        try await waitFor { store.pendingUploads.isEmpty && !store.isUploading }
        #expect(await drive.file(named: SpeechAudioCache.key(for: made) + ".mp3")?.parent == audio)
        #expect(await drive.count(named: "audio") == 1)
        #expect(await drive.count(named: DriveAudioStore.rootName) == 1)
        #expect(Set(await drive.files(in: legacy).map(\.name)) == ["format.json", "articles"])
    }

    @Test func aFolderMarkedMovedWithoutTheSitesFolderIsRefused() async throws {
        let legacy = await folder(DriveAudioStore.rootName)
        await format(Self.movedFormat, in: legacy)
        await #expect(throws: DriveError.self) { try await makeStore().layout() }
        #expect(await drive.count(named: DriveAudioStore.sharedRootName) == 0)
    }

    @Test func inTheMiddleOfTheMoveTheMovedAudioFolderIsUsedNotANewOne() async throws {
        let shared = await folder(DriveAudioStore.sharedRootName)
        let legacy = await folder(DriveAudioStore.rootName)
        await format(Self.legacyFormat, in: legacy)
        let audio = await folder("audio", in: shared)  // already moved; the site hasn't written its version 2 yet
        let layout = try await makeStore().layout()
        #expect(layout.root == legacy)
        #expect(layout.audio == audio)
        #expect(layout.otherAudio == nil)
        #expect(await drive.count(named: "audio") == 1)
    }

    @Test func whileBothFoldersHaveAudioBothAreLookedIn() async throws {
        let shared = await folder(DriveAudioStore.sharedRootName)
        await format(Self.sharedFormat, in: shared)
        let newAudio = await folder("audio", in: shared)
        let legacy = await folder(DriveAudioStore.rootName)
        await format(Self.movedFormat, in: legacy)
        let oldAudio = await folder("audio", in: legacy)  // made by a device that wasn't updated
        let stray = request("Uploaded by an old device.")
        _ = await drive.add(name: SpeechAudioCache.key(for: stray) + ".mp3", parent: oldAudio, data: Data("ID3 stray".utf8))

        let store = makeStore()
        let layout = try await store.layout()
        #expect(layout.audio == newAudio)
        #expect(layout.otherAudio == oldAudio)
        let url = await store.fetch(stray, into: cache)
        #expect(try Data(contentsOf: #require(url)) == Data("ID3 stray".utf8))
        store.enqueue([SpeechAudioCache.key(for: stray)])
        #expect(store.pendingUploads.isEmpty)  // already on Drive: not uploaded again
    }

    @Test func aManifestIsReadBeforeItIsRewrittenAndKeepsWhatTheAppDoesNotKnow() async throws {
        let store = makeStore()
        let articles = try await store.layout().articles
        let url = "https://en.wikipedia.org/wiki/COVID-19"
        let name = DriveManifest.urlHash(url) + ".json"
        let base = DriveManifest(title: "COVID-19", url: url, blocks: [.paragraph("Old text.")], voice: "alloy")
        var theirs = try #require(try JSONSerialization.jsonObject(with: base.encoded()) as? [String: Any])
        theirs["updatedBy"] = "web"
        theirs["chunkExtras"] = ["k": ["ms": 1200]]
        theirs["source"] = ["kind": "wikipedia", "revision": 7]
        _ = await drive.add(name: name, parent: articles, mimeType: "application/json", data: try JSONSerialization.data(withJSONObject: theirs))

        await store.noteArticle(title: "COVID-19", url: url, blocks: [.paragraph("New text.")], voice: "alloy")

        let file = try #require(await drive.file(named: name))
        let written = try #require(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
        #expect(written["updatedBy"] as? String == "ios")
        #expect((written["chunks"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["New text."])
        #expect((written["source"] as? [String: Any])?["revision"] as? Int == 7)
        #expect((written["chunkExtras"] as? [String: Any])?["k"] != nil)
        #expect(await drive.count(named: name) == 1)
    }

    @Test func aManifestForAnotherVoiceIsLeftAlone() async throws {
        let store = makeStore()
        let articles = try await store.layout().articles
        let url = "https://en.wikipedia.org/wiki/Paris"
        let name = DriveManifest.urlHash(url) + ".json"
        let theirs = DriveManifest(title: "Paris", url: url, blocks: [.paragraph("Frozen text.")], voice: "marin").encoded()
        _ = await drive.add(name: name, parent: articles, mimeType: "application/json", data: theirs)

        await store.noteArticle(title: "Paris", url: url, blocks: [.paragraph("Newer text.")], voice: "alloy")
        #expect(await drive.file(named: name)?.data == theirs)
        #expect(await drive.count(named: name) == 1)

        // Not downloaded again on the next visit.
        let downloads = await drive.requests.count { $0.hasPrefix("GET /drive/v3/files/") }
        await store.noteArticle(title: "Paris", url: url, blocks: [.paragraph("Newer text.")], voice: "alloy")
        #expect(await drive.requests.count { $0.hasPrefix("GET /drive/v3/files/") } == downloads)
    }

    @Test func aDeletedManifestIsReplacedByANewFile() {
        let url = "https://en.wikipedia.org/wiki/Paris"
        let ours = DriveManifest(title: "Paris", url: url, blocks: [.paragraph("P.")], voice: "alloy")
        let deleted = Data(#"{"deleted":true,"model":"gpt-4o-mini-tts","voice":"alloy"}"#.utf8)
        #expect(DriveManifest.write(ours, over: deleted) == .create(ours.encoded()))
        let newer = Data(#"{"formatVersion":3,"model":"gpt-4o-mini-tts","voice":"alloy"}"#.utf8)
        #expect(DriveManifest.write(ours, over: newer) == .leave)
    }

    @Test func aNewManifestCarriesTheTitleAndPropertiesForPeople() async throws {
        let url = "https://en.wikipedia.org/wiki/Paris"
        await makeStore().noteArticle(title: "Paris", url: url, blocks: [.paragraph("P.")], voice: "alloy")
        let file = try #require(await drive.file(named: DriveManifest.urlHash(url) + ".json"))
        #expect(file.description == "Paris")
        #expect(file.properties == ["articleId": DriveManifest.urlHash(url), "title": "Paris", "kind": "wikipedia"])
    }

    @Test func propertyValuesFitDrivesLimit() {
        let cut = DriveManifest.propertyValue(String(repeating: "é", count: 100), key: "title")  // 2 bytes each
        #expect(cut.utf8.count == 118)  // 124 - "title"
        #expect(DriveManifest.propertyValue("Paris", key: "title") == "Paris")
    }

    @Test func anArticleFromTheSiteGetsNoURLManifestAndTheSitesAudioStaysOffDrive() async throws {
        // The site's canonical address for an article it took from Wikipedia is the Wikipedia address.
        let url = "https://en.wikipedia.org/wiki/COVID-19"
        let fromSite = request("Edited on the site.")
        let generated = request("Generated here.")
        try cache.store(Data("ID3 site".utf8), for: fromSite)
        try cache.store(Data("ID3 paid".utf8), for: generated)
        let blocks: [ContentBlock] = [.paragraph("Edited on the site."), .paragraph("Generated here.")]
        let store = makeStore(siteAudio: [SpeechAudioCache.key(for: fromSite)])

        await store.noteArticle(title: "COVID-19", url: url, blocks: blocks, voice: "alloy", listsArticle: false)
        let result = await store.backUp(
            [DriveArticle(title: "COVID-19", url: url, blocksData: try JSONEncoder().encode(blocks), isFromSite: true)], voice: "alloy"
        )
        try await waitFor { store.pendingUploads.isEmpty && !store.isUploading }

        #expect(result?.missing == 1)
        #expect(await drive.count(named: SpeechAudioCache.key(for: generated) + ".mp3") == 1)  // paid for here: backed up
        #expect(await drive.count(named: SpeechAudioCache.key(for: fromSite) + ".mp3") == 0)  // the site's copy: not
        #expect(await drive.count(named: DriveManifest.urlHash(url) + ".json") == 0)
    }
}

// MARK: - Drive before OpenAI

/// A remote source answering from a fixed set of texts.
@MainActor
final class FakeRemote: RemoteAudioSource {
    var isEnabled = true
    /// Settings' "Check Drive First".
    var looksUp = true
    var has: Set<String> = []
    var generated: [String] = []

    var looksUpBeforeGenerating: Bool { isEnabled && looksUp }

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

    @Test func withCheckingOffOpenAIIsAskedButAPullStillTakesFromDrive() async throws {
        let remote = FakeRemote()
        remote.looksUp = false
        remote.has = ["On Drive.", "Also on Drive."]
        let generations = SpeechGenerations(remote: remote)
        #expect(!generations.canWorkWithoutKey)

        _ = await generations.generate(OpenAISpeechEngine.request(for: "On Drive.", voice: "alloy"), apiKey: "sk", client: client, cache: cache).value
        #expect(await sent.inputs == ["On Drive."])

        let pulled = await generations.fetchFromRemote(OpenAISpeechEngine.request(for: "Also on Drive.", voice: "alloy"), cache: cache)
        #expect(try Data(contentsOf: #require(pulled)) == Data("ID3 remote".utf8))
        #expect(await generations.fetchFromRemote(OpenAISpeechEngine.request(for: "Nowhere.", voice: "alloy"), cache: cache) == nil)
        #expect(await sent.inputs == ["On Drive."])

        remote.isEnabled = false
        #expect(await generations.fetchFromRemote(OpenAISpeechEngine.request(for: "Also on Drive.", voice: "marin"), cache: cache) == nil)
    }

    @Test func aDrivePullKeepsOnlyWhatDriveHasAndCostsNothing() throws {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let first = Article(title: "A", sourceURL: URL(string: "https://en.wikipedia.org/wiki/A")!, blocks: [])
        let second = Article(title: "B", sourceURL: URL(string: "https://en.wikipedia.org/wiki/B")!, blocks: [])
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        let pieces = ArticleAudio.pieces(of: [.paragraph(String(repeating: "a", count: 840)), .paragraph(String(repeating: "b", count: 420))], voice: "alloy")
        var plan = AudioDownloader.Plan(
            voice: NarrationVoice("alloy"),
            items: [.init(article: first.persistentModelID, piece: pieces[0]), .init(article: second.persistentModelID, piece: pieces[1])],
            articleCount: 2
        )
        let onDrive = SpeechAudioCache.key(for: pieces[0].request)
        plan.markOnDrive { $0 == onDrive }

        let pull = plan.onlyFromDrive()
        #expect(pull.isDriveOnly)
        #expect(pull.items.count == 1 && pull.items.allSatisfy(\.fromDriveOnly))
        #expect(pull.articleCount == 1)
        #expect(pull.characters == 840)
        #expect(pull.leftOutCharacters == 420)
        #expect(pull.dollars == 0)
        #expect(!plan.isDriveOnly)
    }

    @Test func downloadPlansPriceOnlyWhatIsNotOnDrive() throws {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let article = Article(title: "T", sourceURL: URL(string: "https://en.wikipedia.org/wiki/T")!, blocks: [])
        container.mainContext.insert(article)
        let pieces = ArticleAudio.pieces(of: [.paragraph(String(repeating: "a", count: 840)), .paragraph(String(repeating: "b", count: 840))], voice: "alloy")
        var plan = AudioDownloader.Plan(voice: NarrationVoice("alloy"), items: pieces.map { .init(article: article.persistentModelID, piece: $0) }, articleCount: 1)
        let onDrive = SpeechAudioCache.key(for: pieces[0].request)
        plan.markOnDrive { $0 == onDrive }
        #expect(plan.driveCharacters == 840)
        #expect(plan.generatedCharacters == 840)
        #expect(abs(plan.dollars - ArticleAudio.dollars(forCharacters: 840)) < 1e-9)
    }
}
