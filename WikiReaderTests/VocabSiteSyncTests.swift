import Foundation
import Testing
@testable import WikiReader

/// A request's JSON body.
private func body<Value>(of request: URLRequest) throws -> Value {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? Value)
}

/// The word book kept in step with English Reader (docs/vocab-sync-v1.md). `FakeVocabSite` follows the site's own code
/// for everyday changes (`src/server/vocabApi.ts`), so two devices can talk through it; a full sync's answers are
/// written out by each test, since the numbers in them are the site's.
actor FakeVocabSite {
    private(set) var requests: [URLRequest] = []
    private(set) var entries: [String: VocabEntry] = [:]
    private(set) var tombstones: [String: Int64] = [:]
    private var changedAt: [String: Int] = [:]
    private var seq = 0
    private var answers: [String: Data] = [:]
    private var codes: Set<String> = []
    private var issued = 0
    private(set) var validKeys: Set<String> = []

    /// What the site's clock says; times more than 10 minutes past it are refused.
    var clock: Int64 = 1_793_700_000_000
    var hasSignIn = true
    var isOffline = false
    /// The next push is carried out, but its answer never arrives.
    var losesNextAnswer = false
    var cursorIsTooOld = false
    /// Cuts pages shorter than the limit asked for.
    var pageSize = 500
    /// Refuses pushes of more changes than this as too large.
    var largestPush = Int.max
    /// Something to do while the next push is on its way.
    var duringPush: (@Sendable () async -> Void)?
    var email = "me@example.com"
    /// Full sync: path after `vocab/sync/` → status and body.
    var fullSync: [String: (Int, Data)] = [:]

    func change(_ edit: @Sendable (isolated FakeVocabSite) -> Void) {
        edit(self)
    }

    func answer(_ path: String, status: Int = 200, _ body: [String: Any]) throws {
        fullSync[path] = (status, try JSONSerialization.data(withJSONObject: body))
    }

    func store(_ entry: VocabEntry) {
        seq += 1
        entries[entry.key] = entry
        tombstones[entry.key] = nil
        changedAt[entry.key] = seq
    }

    func remove(_ key: String, at time: Int64) {
        seq += 1
        entries[key] = nil
        tombstones[key] = time
        changedAt[key] = seq
    }

    var cursor: String { String(seq) }

    func requests(to path: String, method: String = "POST") -> [URLRequest] {
        requests.filter { $0.url?.path() == path && $0.httpMethod == method }
    }

    func revokeAllKeys() {
        validKeys = []
    }

    nonisolated func client(key: @escaping @Sendable () -> String?) -> SiteVocabClient {
        SiteVocabClient(baseURL: URL(string: "https://site.test")!, transport: { try await self.handle($0) }, key: key)
    }

    // MARK: - Requests

    private func respond(_ request: URLRequest, _ status: Int, _ body: Data = Data()) -> (Data, URLResponse) {
        let headers = ["Content-Type": "application/json", "Retry-After": "7"]
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    private func error(_ request: URLRequest, _ status: Int, _ code: String) -> (Data, URLResponse) {
        respond(request, status, Data(#"{"error":{"code":"\#(code)","message":"from the fake site"}}"#.utf8))
    }

    private func json(_ object: some Encodable) throws -> Data {
        try JSONEncoder().encode(object)
    }

    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if isOffline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path().replacingOccurrences(of: "/api/app/v1/", with: "")
        let isPost = request.httpMethod == "POST"

        if path == "auth/token" { return try token(request) }
        guard hasSignIn else { return error(request, 404, "not_found") }
        let key = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        guard let key, validKeys.contains(key) else { return error(request, 401, "invalid_token") }

        switch path {
        case "auth/logout":
            validKeys.remove(key)
            return respond(request, 204)
        case "vocab/changes" where isPost:
            return try await push(request)
        case "vocab/changes":
            return try changes(request)
        default:
            let name = path.replacingOccurrences(of: "vocab/sync/", with: "")
            guard let (status, body) = fullSync[name] else { return error(request, 404, "not_found") }
            return respond(request, status, body)
        }
    }

    /// The one-time code a sign-in sheet would come back with.
    func issueCode() -> String {
        issued += 1
        codes.insert("code-\(issued)")
        return "code-\(issued)"
    }

    private func token(_ request: URLRequest) throws -> (Data, URLResponse) {
        let fields: [String: String] = try body(of: request)
        guard let code = fields["code"], codes.remove(code) != nil, fields["client"] == "ios",
              fields["redirect_uri"] == "wikireader://auth/callback", (fields["code_verifier"] ?? "").count >= 43
        else { return error(request, 400, "invalid_grant") }
        let key = "erd_key-\(issued)"
        validKeys.insert(key)
        return respond(request, 200, try JSONSerialization.data(withJSONObject: [
            "device_token": key,
            "device": ["id": "dev_\(issued)", "name": "iPhone", "client": "ios", "createdAt": clock],
            "user": ["email": email, "name": NSNull()],
        ]))
    }

    private struct Result: Encodable {
        var key: String
        var status: String
        var entry: VocabEntry?
        var deletedAt: Int64?
        var message: String?
    }

    private struct Answer: Encodable {
        var results: [Result]
        var count: Int
    }

    private func push(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let batch = try JSONDecoder().decode(VocabPushBatch.self, from: #require(request.httpBody))
        if batch.changes.count > largestPush { return error(request, 413, "too_large") }
        if let action = duringPush {
            duringPush = nil
            await action()
        }
        if let earlier = answers[batch.requestId] { return respond(request, 200, earlier) }

        var results: [Result] = []
        for change in batch.changes {
            switch change {
            case .upsert(let entry):
                results.append(take(entry))
            case .delete(let key, let time):
                if time > clock + 600_000 {
                    results.append(Result(key: key, status: "clock_skew", message: "in the future"))
                } else if let current = entries[key], current.updatedAt > time {
                    results.append(Result(key: key, status: "kept_newer", entry: current))
                } else {
                    if entries[key] != nil || (tombstones[key] ?? 0) < time { remove(key, at: max(time, tombstones[key] ?? 0)) }
                    results.append(Result(key: key, status: "deleted"))
                }
            }
        }
        let body = try json(Answer(results: results, count: entries.count))
        answers[batch.requestId] = body
        if losesNextAnswer {
            losesNextAnswer = false
            throw URLError(.networkConnectionLost)
        }
        return respond(request, 200, body)
    }

    private func take(_ entry: VocabEntry) -> Result {
        let times = [entry.createdAt, entry.updatedAt] + entry.contexts.map(\.savedAt)
        if times.max()! > clock + 600_000 { return Result(key: entry.key, status: "clock_skew", message: "in the future") }
        if entry.term == "refused" || entry.contexts.contains(where: { $0.sentence.utf16.count > 2000 }) {
            return Result(key: entry.key, status: "invalid_entry", message: "not acceptable")
        }
        if let current = entries[entry.key] {
            let merged = VocabFormat.mergeEntry(current, entry)
            if merged == current { return Result(key: entry.key, status: "unchanged", entry: current) }
            store(merged)
            return Result(key: entry.key, status: "merged", entry: merged)
        }
        if let time = tombstones[entry.key], time >= entry.updatedAt {
            return Result(key: entry.key, status: "deleted_elsewhere", deletedAt: time)
        }
        store(entry)
        return Result(key: entry.key, status: "created", entry: entry)
    }

    private struct Page: Encodable {
        struct Deletion: Encodable {
            var key: String
            var deletedAt: Int64
        }

        var entries: [VocabEntry]
        var deleted: [Deletion]
        var cursor: String
        var more: Bool
        var count: Int
    }

    private func changes(_ request: URLRequest) throws -> (Data, URLResponse) {
        if cursorIsTooOld { return error(request, 410, "cursor_expired") }
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let since = Int(try #require(items.first { $0.name == "since" }?.value)) ?? -1
        let changed = changedAt.filter { $0.value > since }.sorted { $0.value < $1.value }
        let page = changed.prefix(pageSize)
        return respond(request, 200, try json(Page(
            entries: page.compactMap { entries[$0.key] },
            deleted: page.compactMap { item in tombstones[item.key].map { Page.Deletion(key: item.key, deletedAt: $0) } },
            cursor: String(page.last?.value ?? since), more: changed.count > page.count, count: entries.count
        )))
    }
}

/// One signed-in phone: its book, its account and its sync, all kept in its own folder.
@MainActor
final class VocabDevice {
    typealias Clock = VocabularyBookTests.Clock

    let site: FakeVocabSite
    let clock: Clock
    let directory = URL.temporaryDirectory.appending(path: "VocabSite-\(UUID().uuidString)", directoryHint: .isDirectory)
    let keys = KeychainStore(service: "tik.tian.com.WikiReader.tests.\(UUID().uuidString)", account: "deviceKey")
    let defaults = UserDefaults(suiteName: "VocabSite-\(UUID().uuidString)")!
    let url = URL(string: "https://en.wikipedia.org/wiki/Paris")!
    /// What the web page of the sign-in does, given the page's address.
    var signInPage: (URL) async -> Result<URL, WebSignInSheet.Failure>
    var pagesOpened = 0

    private(set) lazy var book = makeBook()
    private(set) lazy var account = makeAccount()
    private(set) lazy var sync = makeSync()

    init(site: FakeVocabSite, clock: Clock = Clock()) {
        self.site = site
        self.clock = clock
        signInPage = { page in
            let state = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let code = await site.issueCode()
            return .success(URL(string: "wikireader://auth/callback?code=\(code)&state=\(state)")!)
        }
    }

    private var client: SiteVocabClient {
        site.client { [keys] in keys.read() }
    }

    func makeBook() -> VocabularyBook {
        let clock = clock
        return VocabularyBook(fileURL: directory.appending(path: "Vocabulary.json"), now: { clock.now }, lemmaOf: { _ in nil })
    }

    func makeAccount() -> SiteAccount {
        SiteAccount(keyStore: keys, defaults: defaults, client: client, webSignIn: { [weak self] page, _ in
            self?.pagesOpened += 1
            return await self?.signInPage(page) ?? .failure(.cancelled)
        }, deviceName: { "iPhone" })
    }

    func makeSync(pollInterval: Duration = VocabSiteSync.pollInterval) -> VocabSiteSync {
        let clock = clock
        return VocabSiteSync(
            book: book, account: account, client: client, directory: directory,
            debounce: .seconds(3600), pollInterval: pollInterval, now: { clock.now }
        )
    }

    /// As after restarting the app: everything read back from disk.
    func relaunchedSync() -> VocabSiteSync {
        let clock = clock
        return VocabSiteSync(book: book, account: makeAccount(), client: client, directory: directory, debounce: .seconds(3600), now: { clock.now })
    }

    @discardableResult
    func save(_ word: String) -> VocabEntry {
        clock.advance()
        return book.save(word: word, term: word, sentence: "A sentence with \(word).", url: url, title: "Paris")
    }

    func delete(_ word: String) {
        clock.advance()
        book.delete(key: word)
    }
}

@MainActor
struct SiteSignInTests {
    let site = FakeVocabSite()

    @Test func theSitesLoginEndsInADeviceKeyInTheKeychain() async throws {
        let device = VocabDevice(site: site)
        var opened: URL?
        let answer = device.signInPage
        device.signInPage = { page in
            opened = page
            return await answer(page)
        }
        let user = try await device.account.signIn()
        #expect(user.email == "me@example.com")
        #expect(device.account.state == .signedIn(SiteUser(email: "me@example.com")))
        #expect(device.keys.read() == "erd_key-1")
        #expect(device.account.keepsWordBook)

        let page = try #require(opened)
        let query = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems)
        let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(page.path() == "/app/authorize")
        #expect(items["client"] == "ios")
        #expect(items["redirect_uri"] == "wikireader://auth/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["device_name"] == "iPhone")

        let request = try #require(await site.requests(to: "/api/app/v1/auth/token").first)
        let fields: [String: String] = try body(of: request)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "code-1")
        #expect(fields["device_id"] == nil)
        // The secret goes only here, and it is the one behind the challenge sent to the page.
        let verifier = try #require(fields["code_verifier"])
        #expect(GoogleOAuth.PKCE.challenge(for: verifier) == items["code_challenge"])
        #expect(!page.absoluteString.contains(verifier))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "WikiReader/0.1 (iOS app)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aRelaunchedAppIsStillSignedIn() async throws {
        let device = VocabDevice(site: site)
        _ = try await device.account.signIn()
        #expect(device.makeAccount().state == .signedIn(SiteUser(email: "me@example.com")))
    }

    @Test func cancellingOrAForgedAnswerGetsNoKey() async throws {
        let device = VocabDevice(site: site)
        device.signInPage = { _ in .failure(.cancelled) }
        await #expect(throws: SiteAuthError.cancelled) { _ = try await device.account.signIn() }

        // The page's Cancel button.
        device.signInPage = { page in
            let state = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return .success(URL(string: "wikireader://auth/callback?error=access_denied&state=\(state)")!)
        }
        await #expect(throws: SiteAuthError.cancelled) { _ = try await device.account.signIn() }

        // An answer to some other sign-in, whatever it claims.
        device.signInPage = { _ in .success(URL(string: "wikireader://auth/callback?code=code-1&state=someone-elses")!) }
        await #expect(throws: SiteAuthError.rejected("the answer wasn't for this sign-in")) { _ = try await device.account.signIn() }
        await #expect(throws: SiteAuthError.rejected("the answer wasn't for this sign-in")) { _ = try await device.account.signIn() }

        #expect(await site.requests(to: "/api/app/v1/auth/token").isEmpty)
        #expect(device.keys.read() == nil)
        #expect(device.account.state == .signedOut)
    }

    @Test func aCodeUsedOrExpiredIsNotRetried() async throws {
        let device = VocabDevice(site: site)
        device.signInPage = { page in
            let state = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return .success(URL(string: "wikireader://auth/callback?code=stale&state=\(state)")!)
        }
        await #expect(throws: SiteAuthError.rejected("the sign-in expired")) { _ = try await device.account.signIn() }
        #expect(await site.requests(to: "/api/app/v1/auth/token").count == 1)
        #expect(device.account.state == .signedOut)
    }

    @Test func aSiteThatCantSignAppsInSaysSoBeforeTheSheetOpens() async throws {
        await site.change { $0.hasSignIn = false }
        let device = VocabDevice(site: site)
        await #expect(throws: SiteAuthError.notAvailable) { _ = try await device.account.signIn() }
        #expect(device.pagesOpened == 0)
    }

    @Test func signingOutEndsTheKeyOnTheSiteToo() async throws {
        let device = VocabDevice(site: site)
        _ = try await device.account.signIn()
        await device.account.signOut()
        #expect(await site.validKeys.isEmpty)
        #expect(device.keys.read() == nil)
        #expect(device.account.state == .signedOut)
        #expect(!device.account.keepsWordBook)
    }

    @Test func signingInAgainReplacesThisDevicesEarlierKey() async throws {
        let device = VocabDevice(site: site)
        _ = try await device.account.signIn()
        await device.account.signOut()
        _ = try await device.account.signIn()
        let request = try #require(await site.requests(to: "/api/app/v1/auth/token").last)
        let fields: [String: String] = try body(of: request)
        #expect(fields["device_id"] == "dev_1")
    }

    @Test func aRefusedKeyIsForgottenAndTheAccountRemembered() async throws {
        let device = VocabDevice(site: site)
        _ = try await device.account.signIn()
        #expect(device.account.keyRefused())
        #expect(device.account.state == .needsSignIn(SiteUser(email: "me@example.com")))
        #expect(device.account.keepsWordBook)
        #expect(device.keys.read() == nil)
        #expect(!device.account.keyRefused())
        #expect(device.makeAccount().state == .needsSignIn(SiteUser(email: "me@example.com")))
    }
}

@MainActor
struct VocabSiteSyncTests {
    let site = FakeVocabSite()

    private func signedIn(_ device: VocabDevice? = nil) async throws -> VocabDevice {
        let device = device ?? VocabDevice(site: site)
        _ = device.sync  // listens to the book from here on
        try await device.sync.signIn()
        return device
    }

    private func pushes() async -> [VocabPushBatch] {
        await site.requests(to: "/api/app/v1/vocab/changes").compactMap { request in
            request.httpBody.flatMap { try? JSONDecoder().decode(VocabPushBatch.self, from: $0) }
        }
    }

    // MARK: First sign-in

    @Test func anEmptyBookTakesInWhatTheSiteHas() async throws {
        await site.store(VocabEntry(key: "verdict", term: "verdict", forms: [], createdAt: 1, updatedAt: 1, contexts: []))
        let device = try await signedIn()
        #expect(device.book.keys == ["verdict"])
        #expect(device.sync.status == .synced)
        #expect(await site.requests(to: "/api/app/v1/vocab/sync/preview").isEmpty)
        #expect(device.book.owner == "me@example.com")
    }

    @Test func aBookWithWordsWaitsToBeCompared() async throws {
        let device = VocabDevice(site: site)
        _ = device.sync
        device.save("verdict")
        try await device.sync.signIn()
        #expect(device.sync.status == .needsFullSync)
        await device.sync.sync()
        #expect(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").isEmpty)
        #expect(await pushes().isEmpty)
        #expect(await site.entries.isEmpty)
    }

    @Test func anotherAccountsWordsStayApart() async throws {
        let device = VocabDevice(site: site)
        _ = device.sync
        device.book.belong(to: "someone@example.com")
        device.save("verdict")
        try await device.sync.signIn()
        #expect(device.book.keys.isEmpty)
        #expect(device.sync.status == .synced)
        #expect(device.book.belong(to: "someone@example.com"))
        #expect(device.book.keys == ["verdict"])
    }

    // MARK: Everyday changes

    @Test func wordsAddedAndDeletedOnOneDeviceFollowOnTheOther() async throws {
        let phone = try await signedIn()
        let other = try await signedIn(VocabDevice(site: site, clock: phone.clock))

        phone.save("verdict")
        await phone.sync.sync()
        await other.sync.sync()
        #expect(other.book.keys == ["verdict"])

        other.delete("verdict")
        await other.sync.sync()
        await phone.sync.sync()
        #expect(phone.book.keys.isEmpty)
        #expect(await site.tombstones["verdict"] != nil)

        // Saved again later: back everywhere.
        phone.save("verdict")
        await phone.sync.sync()
        await other.sync.sync()
        #expect(other.book.keys == ["verdict"])
        #expect(await site.tombstones["verdict"] == nil)
    }

    @Test func aWordDeletedOnTheWebsiteGoesFromTheBook() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await phone.sync.sync()
        await site.remove("verdict", at: VocabFormat.milliseconds(phone.clock.now) + 1000)
        await phone.sync.sync()
        #expect(phone.book.keys.isEmpty)
    }

    @Test func changesMadeOfflineGoInOnePushOnceBack() async throws {
        let phone = try await signedIn()
        phone.save("taken")
        await phone.sync.sync()

        await site.change { $0.isOffline = true }
        phone.save("one")
        phone.save("two")
        phone.save("three")
        phone.delete("taken")
        await phone.sync.sync()
        #expect(phone.sync.status == .offline)
        #expect(phone.sync.waitingCount == 4)
        #expect(phone.sync.statusText == "Offline, 4 changes waiting")

        await site.change { $0.isOffline = false }
        await phone.sync.sync()
        #expect(phone.sync.status == .synced)
        #expect(phone.sync.waitingCount == 0)
        #expect(await site.entries.keys.sorted() == ["one", "three", "two"])
        #expect(await site.tombstones["taken"] != nil)
        let attempts = await pushes()
        #expect(attempts.count == 3)
        #expect(attempts[1] == attempts[2])  // the same batch, under the same id, tried twice
        #expect(attempts[2].changes.count == 4)
    }

    @Test func aBurstOfChangesToOneWordIsSentOnce() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        phone.clock.advance()
        phone.book.setMeaning("判决", term: "verdict")
        await phone.sync.sync()
        let batch = try #require(await pushes().first)
        #expect(batch.changes.map(\.key) == ["verdict"])
        #expect(await site.entries["verdict"]?.meaning == "判决")
    }

    @Test func aPushWhoseAnswerWasLostGoesAgainUnchanged() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await site.change { $0.losesNextAnswer = true }
        await phone.sync.sync()
        #expect(phone.sync.status == .offline)
        #expect(await site.entries.keys.contains("verdict"))

        // Changed again meanwhile: that is the next push's business.
        phone.save("another")
        await phone.sync.sync()
        let attempts = await pushes()
        #expect(attempts.count == 3)
        #expect(attempts[0] == attempts[1])
        #expect(attempts[2].changes.map(\.key) == ["another"])
        #expect(attempts[2].requestId != attempts[1].requestId)
    }

    @Test func anUnansweredPushSurvivesARelaunch() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await site.change { $0.losesNextAnswer = true }
        await phone.sync.sync()

        await phone.relaunchedSync().sync()
        let attempts = await pushes()
        #expect(attempts.count == 2)
        #expect(attempts[0] == attempts[1])
    }

    @Test func changesWaitingToBeSentSurviveARelaunch() async throws {
        let phone = try await signedIn()
        await site.change { $0.isOffline = true }
        phone.save("verdict")
        await site.change { $0.isOffline = false }

        let relaunched = phone.relaunchedSync()
        #expect(relaunched.waitingCount == 1)
        await relaunched.sync()
        #expect(await site.entries.keys.contains("verdict"))
    }

    @Test func aWordChangedElsewhereLaterSurvivesADeleteFromHere() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await phone.sync.sync()

        await site.change { $0.isOffline = true }
        phone.delete("verdict")
        await phone.sync.sync()
        await site.change { $0.isOffline = false }
        var newer = try #require(await site.entries["verdict"])
        newer.updatedAt = VocabFormat.milliseconds(phone.clock.now) + 60_000
        newer.meaning = "判决"
        await site.store(newer)

        await phone.sync.sync()
        #expect(phone.book.entry(forKey: "verdict")?.meaning == "判决")
        #expect(phone.book.file.deleted["verdict"] == nil)
    }

    @Test func aWordDeletedElsewhereLaterGoesEvenThoughItChangedHere() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await phone.sync.sync()

        await site.change { $0.isOffline = true }
        phone.book.setMeaning("判决", term: "verdict")
        await phone.sync.sync()
        await site.change { $0.isOffline = false }
        let later = VocabFormat.milliseconds(phone.clock.now) + 60_000
        await site.remove("verdict", at: later)

        await phone.sync.sync()
        #expect(phone.book.entry(forKey: "verdict") == nil)
        #expect(phone.book.file.deleted["verdict"] == later)
    }

    @Test func aChangeMadeWhileSendingIsntLost() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        let book = phone.book
        await site.change { site in
            site.duringPush = { @Sendable in
                await MainActor.run { book.setMeaning("判决", term: "verdict") }
            }
        }
        await phone.sync.sync()
        #expect(phone.book.entry(forKey: "verdict")?.meaning == "判决")
        #expect(await site.entries["verdict"]?.meaning == "判决")
        #expect(phone.sync.waitingCount == 0)
    }

    @Test func aFutureTimeIsHeldBackAndTriedAgainLater() async throws {
        let phone = try await signedIn()
        phone.clock.advance(3600)
        phone.save("verdict")
        await phone.sync.sync()
        #expect(await site.entries.isEmpty)
        #expect(phone.sync.clockLooksWrong)
        #expect(phone.sync.statusText == "Check this iPhone's date and time")
        #expect(phone.book.keys == ["verdict"])

        // Not sent again and again meanwhile.
        let attempts = await pushes().count
        await phone.sync.sync()
        #expect(await pushes().count == attempts)

        // An hour on, the same word is no longer in the future.
        await site.change { $0.clock += 3_700_000 }
        phone.sync.appBecameActive()
        phone.sync.appWentToBackground()
        await phone.sync.sync()
        #expect(await site.entries.keys.contains("verdict"))
        #expect(!phone.sync.clockLooksWrong)
    }

    @Test func aWordTheSiteWontTakeIsLeftOut() async throws {
        let phone = try await signedIn()
        phone.save("refused")
        phone.save("verdict")
        await phone.sync.sync()
        #expect(await site.entries.keys.sorted() == ["verdict"])
        #expect(phone.sync.waitingCount == 0)
        #expect(phone.sync.status == .synced)
        #expect(phone.book.keys == ["refused", "verdict"])
    }

    @Test func aLongSentenceGoesShortenedAndTheWordStillArrives() async throws {
        let phone = try await signedIn()
        phone.clock.advance()
        let long = String(repeating: "word ", count: 500)
        phone.book.save(word: "word", term: "word", sentence: long, url: phone.url, title: "Paris")
        await phone.sync.sync()
        let sent = try #require(await site.entries["word"]?.contexts.first)
        #expect(sent.sentence.utf16.count == 2000)
        #expect(sent.id == VocabFormat.contextID(of: long))
    }

    @Test func shorteningNeverSplitsACharacter() throws {
        let sentence = String(repeating: "a", count: 1999) + "😀😀"
        let entry = VocabEntry(key: "a", term: "a", forms: [], createdAt: 1, updatedAt: 1, contexts: [
            VocabContext(id: "x", sentence: sentence, url: "", title: "", savedAt: 1),
        ])
        #expect(entry.forSite.contexts[0].sentence == String(repeating: "a", count: 1999))
        #expect(entry.contexts[0].sentence == sentence)
    }

    @Test func pagesAreFollowedAndTheCursorMovesWithThem() async throws {
        let phone = try await signedIn()
        for word in ["one", "two", "three"] {
            await site.store(VocabEntry(key: word, term: word, forms: [], createdAt: 1, updatedAt: 1, contexts: []))
        }
        await site.change { $0.pageSize = 2 }
        await phone.sync.sync()
        #expect(phone.book.keys == ["one", "two", "three"])
        #expect(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").count == 3)  // the first sync, and two pages

        await site.change { $0.pageSize = 500 }
        await phone.relaunchedSync().sync()
        let last = try #require(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").last?.url?.query())
        #expect(last.contains("since=\(await site.cursor)"))
    }

    @Test func nothingNewLeavesTheBookAlone() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await phone.sync.sync()
        await phone.sync.sync()  // takes in its own change, sent back
        let version = phone.book.version
        await phone.sync.sync()
        await phone.sync.sync()
        #expect(phone.book.version == version)
    }

    @Test func aChangeNotYetSentShowsAsWaiting() async throws {
        let phone = try await signedIn()
        phone.clock.advance()
        await phone.sync.sync()
        #expect(phone.sync.statusText.hasPrefix("Synced"))
        phone.save("verdict")
        #expect(phone.sync.statusText == "1 change waiting")
    }

    @Test func theSiteIsAskedWhileTheAppIsOnScreenAndNotAfter() async throws {
        let phone = VocabDevice(site: site)
        let sync = phone.makeSync(pollInterval: .milliseconds(10))
        try await sync.signIn()
        sync.appBecameActive()
        for _ in 0..<500 where await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").count < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").count >= 4)

        sync.appWentToBackground()
        try await Task.sleep(for: .milliseconds(50))
        let asked = await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").count
        try await Task.sleep(for: .milliseconds(100))
        #expect(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").count == asked)
    }

    // MARK: Trouble

    @Test func aRefusedKeyKeepsTheWordsAndAsksToSignInAgain() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await phone.sync.sync()
        phone.save("another")
        await site.revokeAllKeys()

        await phone.sync.sync()
        #expect(phone.sync.status == .needsSignIn)
        #expect(phone.keys.read() == nil)
        #expect(phone.book.keys == ["verdict", "another"])
        #expect(phone.sync.statusText == "Sign in again")

        // Signing in again compares the two books first, even though it is the same account.
        try await phone.sync.signIn()
        #expect(phone.sync.status == .needsFullSync)
    }

    @Test func aKeyRefusedWhileReadingAnArticleStopsTheSyncToo() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        phone.account.keyRefused()
        await phone.sync.sync()
        #expect(phone.sync.status == .needsSignIn)
        #expect(await pushes().isEmpty)
        #expect(phone.relaunchedSync().status == .needsSignIn)
    }

    @Test func aCursorTooOldAsksForAFullSync() async throws {
        let phone = try await signedIn()
        await site.change { $0.cursorIsTooOld = true }
        await phone.sync.sync()
        #expect(phone.sync.status == .needsFullSync)
        #expect(phone.sync.statusText == "Full sync needed")
        #expect(phone.relaunchedSync().status == .needsFullSync)
    }

    @Test func signingOutForgetsTheCursorAndKeepsTheWords() async throws {
        let phone = try await signedIn()
        phone.save("verdict")
        await phone.sync.sync()
        await phone.sync.signOut()
        #expect(phone.sync.status == .off)
        #expect(phone.book.keys == ["verdict"])
        #expect(phone.sync.waitingCount == 0)
        await phone.sync.sync()
        #expect(phone.sync.status == .off)

        // Changes made while signed out are no business of this class: the first sync after signing in sees them.
        phone.save("another")
        #expect(phone.sync.waitingCount == 0)
    }

    @Test func aPushTooLargeIsSentInSmallerParts() async throws {
        let phone = try await signedIn()
        for word in ["one", "two", "three", "four", "five"] { phone.save(word) }
        await site.change { $0.largestPush = 2 }
        await phone.sync.sync()
        #expect(await site.entries.keys.sorted() == ["five", "four", "one", "three", "two"])
        #expect(phone.sync.status == .synced)
        #expect(phone.sync.waitingCount == 0)
    }

    @Test func aSingleChangeTooLargeIsReportedRatherThanRetriedForever() async throws {
        let phone = try await signedIn()
        phone.save("one")
        await site.change { $0.largestPush = 0 }
        await phone.sync.sync()
        #expect(phone.sync.status == .failed(SiteVocabError.tooLarge.message))
        #expect(phone.sync.waitingCount == 1)
    }

    @Test func changesGoInTheShapeTheSiteReads() async throws {
        let phone = try await signedIn()
        let entry = phone.save("one")
        let batch = VocabPushBatch(requestId: "r", changes: [.upsert(entry), .delete(key: "gone", deletedAt: 5)])
        let data = try JSONEncoder().encode(batch)
        #expect(try JSONDecoder().decode(VocabPushBatch.self, from: data) == batch)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes = try #require(json["changes"] as? [[String: Any]])
        #expect(changes[0]["type"] as? String == "upsert")
        #expect((changes[0]["entry"] as? [String: Any])?["key"] as? String == "one")
        #expect(changes[1]["type"] as? String == "delete")
        #expect(changes[1]["key"] as? String == "gone")
        #expect(changes[1]["deletedAt"] as? Int == 5)
    }
}

@MainActor
struct VocabFullSyncTests {
    let site = FakeVocabSite()

    /// The numbers of the spec's example (§5.2), with a few of the words.
    static let specPreview: [String: Any] = [
        "previewId": "pv_1", "expiresAt": 1_762_500_600_000,
        "counts": [
            "device": 50, "server": 40, "same": 30, "differ": 5, "deviceNewer": 3, "serverNewer": 2,
            "deviceOnly": 12, "deviceOnlyDeletedOnServer": 3, "serverOnly": 3, "serverOnlyDeletedOnDevice": 2,
        ],
        "words": [
            "differ": [["key": "take off", "term": "take off", "newer": "device"]],
            "deviceOnly": [["key": "here", "term": "here"]],
            "deviceOnlyDeletedOnServer": [["key": "gone", "term": "gone", "deletedAt": 1_762_402_000_000]],
            "serverOnly": [["key": "there", "term": "there"]],
            "serverOnlyDeletedOnDevice": [["key": "dropped", "term": "dropped", "deletedAt": 1_762_402_000_000]],
        ],
        "options": [
            "merge": side(50, 3, 3, 5, 50, 12, 2, 5),
            "serverToDevice.add": side(53, 3, 0, 5, 40, 0, 0, 0),
            "serverToDevice.overwrite": side(40, 5, 15, 5, 40, 0, 0, 0),
            "deviceToServer.add": side(50, 0, 0, 0, 52, 12, 0, 5),
            "deviceToServer.overwrite": side(50, 0, 0, 0, 50, 15, 5, 5),
        ],
    ]

    private static func side(_ deviceAfter: Int, _ deviceAdd: Int, _ deviceRemove: Int, _ deviceUpdate: Int,
                             _ serverAfter: Int, _ serverAdd: Int, _ serverRemove: Int, _ serverUpdate: Int) -> [String: Any] {
        [
            "device": ["after": deviceAfter, "add": deviceAdd, "remove": deviceRemove, "update": deviceUpdate],
            "server": ["after": serverAfter, "add": serverAdd, "remove": serverRemove, "update": serverUpdate],
        ]
    }

    private static func applied(book: VocabFile?, cursor: String = "90", undoID: String? = "undo_1") throws -> [String: Any] {
        var answer: [String: Any] = ["result": ["device": ["after": 50], "server": ["after": 50]], "cursor": cursor]
        if let book { answer["book"] = try JSONSerialization.jsonObject(with: book.encoded()) }
        if let undoID { answer["undoId"] = undoID }
        return answer
    }

    private func word(_ word: String, at time: Int64 = 1000) -> VocabEntry {
        VocabEntry(key: word, term: word, forms: [word], createdAt: time, updatedAt: time, contexts: [])
    }

    /// A phone with words, signed in, and asked to compare them.
    private func comparing(_ words: String...) async throws -> VocabDevice {
        let phone = VocabDevice(site: site)
        _ = phone.sync
        for word in words { phone.save(word) }
        try await phone.sync.signIn()
        try await site.answer("preview", Self.specPreview)
        return phone
    }

    private func confirmation() async throws -> [String: Any] {
        let request = try #require(await site.requests(to: "/api/app/v1/vocab/sync/apply").last)
        return try body(of: request)
    }

    @Test func theSpecsExampleReads() throws {
        let preview = try JSONDecoder().decode(VocabSyncPreview.self, from: JSONSerialization.data(withJSONObject: Self.specPreview))
        #expect(preview.counts.device == 50)
        #expect(!preview.counts.match)
        #expect(preview.choice(.deviceToServerOverwrite)?.server.remove == 5)
        #expect(preview.choice(.merge)?.device.after == 50)
        #expect(preview.rejected == nil)
        #expect(preview.wordsRemovedHere(by: .merge).map(\.term) == ["gone"])
        #expect(preview.wordsRemovedHere(by: .serverToDeviceOverwrite).map(\.term) == ["here", "gone"])
        #expect(preview.wordsRemovedHere(by: .serverToDeviceAdd).isEmpty)
        #expect(preview.wordsRemovedOnSite(by: .merge).map(\.term) == ["dropped"])
        #expect(preview.wordsRemovedOnSite(by: .deviceToServerOverwrite).map(\.term) == ["there", "dropped"])
        #expect(preview.wordsRemovedOnSite(by: .deviceToServerAdd).isEmpty)
    }

    @Test func theWholeBookIsSentToCompare() async throws {
        let phone = try await comparing("verdict")
        phone.delete("verdict")
        phone.save("another")
        _ = try await phone.sync.startFullSync()
        let request = try #require(await site.requests(to: "/api/app/v1/vocab/sync/preview").first)
        let file = try VocabFile.decode(#require(request.httpBody))
        #expect(file.formatVersion == 2)
        #expect(file.entries.map(\.key) == ["another"])
        #expect(file.deleted["verdict"] != nil)
    }

    @Test func theNumbersShownGoBackAndTheSitesBookReplacesThisOne() async throws {
        let phone = try await comparing("verdict", "tabloid")
        var book = VocabFile(entries: [word("merged")])
        book.deleted["tabloid"] = 5000
        try await site.answer("apply", Self.applied(book: book, cursor: "90"))

        let preview = try await phone.sync.startFullSync()
        let outcome = try await phone.sync.finishFullSync(preview, option: .merge)

        let sent = try await confirmation()
        #expect(sent["previewId"] as? String == "pv_1")
        #expect(sent["option"] as? String == "merge")
        #expect(sent["confirm"] as? [String: Int] == ["deviceRemove": 3, "serverRemove": 2])

        #expect(phone.book.keys == ["merged"])
        #expect(phone.book.file.deleted["tabloid"] == 5000)
        #expect(outcome.deviceWords == 1)
        #expect(outcome.siteWords == 50)
        #expect(outcome.canUndo)
        #expect(phone.sync.status == .synced)
        #expect(phone.sync.waitingCount == 0)

        // Back to everyday syncing, from where the site said.
        phone.sync.closeFullSync()
        await phone.sync.sync()
        let last = try #require(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").last?.url?.query())
        #expect(last.contains("since=90"))
    }

    @Test func whatWasWaitingToBeSentGoesWithTheFullSync() async throws {
        let phone = VocabDevice(site: site)
        _ = phone.sync
        try await phone.sync.signIn()
        await site.change { $0.isOffline = true }
        phone.save("verdict")
        await phone.sync.sync()
        await site.change { $0.isOffline = false }
        #expect(phone.sync.waitingCount == 1)

        try await site.answer("preview", Self.specPreview)
        try await site.answer("apply", Self.applied(book: VocabFile(entries: [word("verdict")])))
        let preview = try await phone.sync.startFullSync()
        _ = try await phone.sync.finishFullSync(preview, option: .merge)
        phone.sync.closeFullSync()
        #expect(phone.sync.waitingCount == 0)
        await phone.sync.sync()
        let attempts = await site.requests(to: "/api/app/v1/vocab/changes").count
        #expect(attempts == 1)  // only the one made offline, before the full sync
    }

    @Test func goingOneWayToTheSiteLeavesThisBookAlone() async throws {
        let phone = try await comparing("verdict")
        let before = phone.book.file
        try await site.answer("apply", Self.applied(book: nil, cursor: "91"))
        let preview = try await phone.sync.startFullSync()
        let outcome = try await phone.sync.finishFullSync(preview, option: .deviceToServerOverwrite)
        #expect(phone.book.file == before)
        #expect(outcome.undoID == "undo_1")
        #expect(!outcome.changedHere)
        #expect(try await confirmation()["confirm"] as? [String: Int] == ["deviceRemove": 0, "serverRemove": 5])
    }

    @Test func wordsTheSiteLeftOutStayAsTheyAreHere() async throws {
        let phone = try await comparing("verdict", "future")
        phone.delete("verdict")
        var preview = Self.specPreview
        preview["rejected"] = [
            ["key": "future", "status": "clock_skew", "message": "in the future", "serverTime": 1],
            ["key": "verdict", "status": "invalid_entry", "message": "no good"],
        ]
        try await site.answer("preview", preview)
        try await site.answer("apply", Self.applied(book: VocabFile(entries: [word("merged")])))

        let tombstone = try #require(phone.book.file.deleted["verdict"])
        let answer = try await phone.sync.startFullSync()
        _ = try await phone.sync.finishFullSync(answer, option: .merge)
        #expect(phone.book.keys == ["merged", "future"])
        #expect(phone.book.file.deleted["verdict"] == tombstone)

        // The clock's turn to be fixed: tried again, and said so.
        #expect(phone.sync.clockLooksWrong)
        #expect(phone.sync.waitingCount == 1)
    }

    @Test func aBookChangedAfterComparingIsNotSynced() async throws {
        let phone = try await comparing("verdict")
        let preview = try await phone.sync.startFullSync()
        phone.save("another")
        await #expect(throws: SiteVocabError.changedSincePreview) {
            _ = try await phone.sync.finishFullSync(preview, option: .merge)
        }
        #expect(await site.requests(to: "/api/app/v1/vocab/sync/apply").isEmpty)
    }

    @Test func aRefusalChangesNothing() async throws {
        let phone = try await comparing("verdict")
        for (status, code, error) in [
            (409, "changed_since_preview", SiteVocabError.changedSincePreview),
            (410, "preview_expired", SiteVocabError.previewExpired),
            (422, "confirmation_mismatch", SiteVocabError.confirmationMismatch),
        ] {
            try await site.answer("apply", status: status, ["error": ["code": code, "message": "no"]])
            let before = phone.book.file
            let preview = try await phone.sync.startFullSync()
            await #expect(throws: error) { _ = try await phone.sync.finishFullSync(preview, option: .merge) }
            #expect(phone.book.file == before)
            #expect(phone.sync.status == .needsFullSync)
        }
    }

    @Test func aKeyRefusedDuringAFullSyncAsksToSignInAgain() async throws {
        let phone = try await comparing("verdict")
        await site.revokeAllKeys()
        await #expect(throws: SiteVocabError.signedOut) { _ = try await phone.sync.startFullSync() }
        #expect(phone.sync.status == .needsSignIn)
        #expect(phone.book.keys == ["verdict"])
    }

    @Test func nothingElseMovesWhileAFullSyncIsOpen() async throws {
        let phone = VocabDevice(site: site)
        _ = phone.sync
        try await phone.sync.signIn()
        try await site.answer("preview", Self.specPreview)
        let asked = await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").count

        _ = try await phone.sync.startFullSync()
        phone.save("verdict")
        await phone.sync.sync()
        #expect(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").count == asked)
        #expect(await site.requests(to: "/api/app/v1/vocab/changes").isEmpty)

        phone.sync.closeFullSync()
        await phone.sync.sync()
        #expect(await site.entries.keys.contains("verdict"))
    }

    @Test func undoingPutsThisBookBackAndSkipsTheSitesOwnChanges() async throws {
        let phone = try await comparing("verdict", "tabloid")
        try await site.answer("apply", Self.applied(book: VocabFile(entries: [word("merged")]), cursor: "90"))
        try await site.answer("undo", ["restored": 5, "reverted": 5, "kept": 15, "skipped": [["key": "x", "reason": "changed_later"]], "cursor": "120"])
        let before = phone.book.file

        let preview = try await phone.sync.startFullSync()
        let outcome = try await phone.sync.finishFullSync(preview, option: .merge)
        #expect(phone.book.keys == ["merged"])

        let skipped = try await phone.sync.undoFullSync(outcome)
        #expect(skipped == 1)
        #expect(phone.book.keys == Set(before.entries.map(\.key)))
        let request = try #require(await site.requests(to: "/api/app/v1/vocab/sync/undo").first)
        let fields: [String: String] = try body(of: request)
        #expect(fields == ["undoId": "undo_1"])

        phone.sync.closeFullSync()
        await phone.sync.sync()
        let last = try #require(await site.requests(to: "/api/app/v1/vocab/changes", method: "GET").last?.url?.query())
        #expect(last.contains("since=120"))
    }

    @Test func aFailedUndoMovesNothing() async throws {
        let phone = try await comparing("verdict")
        try await site.answer("apply", Self.applied(book: VocabFile(entries: [word("merged")]), cursor: "90"))
        try await site.answer("undo", status: 409, ["error": ["code": "already_undone", "message": "done"]])
        let preview = try await phone.sync.startFullSync()
        let outcome = try await phone.sync.finishFullSync(preview, option: .merge)
        await #expect(throws: SiteVocabError.alreadyUndone) { _ = try await phone.sync.undoFullSync(outcome) }
        #expect(phone.book.keys == ["merged"])
    }

    @Test func undoingAChangeMadeOnlyHereDoesntAskTheSite() async throws {
        let phone = try await comparing("verdict")
        phone.delete("verdict")
        phone.save("kept")
        try await site.answer("apply", Self.applied(book: VocabFile(entries: [word("fromsite")]), cursor: "90", undoID: nil))

        let preview = try await phone.sync.startFullSync()
        let outcome = try await phone.sync.finishFullSync(preview, option: .serverToDeviceOverwrite)
        #expect(outcome.undoID == nil)
        #expect(outcome.canUndo)
        #expect(phone.book.keys == ["fromsite"])

        try await phone.sync.undoFullSync(outcome)
        #expect(phone.book.keys == ["kept"])
        #expect(phone.book.file.deleted["verdict"] != nil)
        #expect(await site.requests(to: "/api/app/v1/vocab/sync/undo").isEmpty)
    }

    @Test func aFullSyncThatChangedNothingHasNothingToUndo() async throws {
        let phone = try await comparing("verdict")
        try await site.answer("apply", Self.applied(book: nil, undoID: nil))
        let preview = try await phone.sync.startFullSync()
        let outcome = try await phone.sync.finishFullSync(preview, option: .deviceToServerAdd)
        #expect(!outcome.canUndo)
    }

    @Test func undoingBringsBackWhatWasWaiting() async throws {
        let phone = VocabDevice(site: site)
        _ = phone.sync
        try await phone.sync.signIn()
        await site.change { $0.isOffline = true }
        phone.save("verdict")
        await phone.sync.sync()
        await site.change { $0.isOffline = false }

        try await site.answer("preview", Self.specPreview)
        try await site.answer("apply", Self.applied(book: VocabFile(entries: []), undoID: nil))
        let preview = try await phone.sync.startFullSync()
        let outcome = try await phone.sync.finishFullSync(preview, option: .serverToDeviceOverwrite)
        try await phone.sync.undoFullSync(outcome)
        phone.sync.closeFullSync()
        #expect(phone.book.keys == ["verdict"])
        await phone.sync.sync()
        #expect(await site.entries.keys.contains("verdict"))
    }
}

@MainActor
struct SiteKeyOnArticlesTests {
    let site = FakeSite()
    let directory = URL.temporaryDirectory.appending(path: "Site-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func aRefusedDeviceKeyIsTheAccountsProblemNotTheTokens() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", Data(#"{"error":{"code":"invalid_token"}}"#.utf8), status: 401)
        var refusals = 0
        let library = SiteLibrary(directory: directory, client: site.client(token: "erd_key"), keyRefused: {
            refusals += 1
            return true
        })
        await library.sync()
        #expect(refusals == 1)
        #expect(!library.tokenRefused)
    }

    @Test func aRefusedAccessTokenStaysTheTokensProblem() async throws {
        await site.answer("/api/app/v1/articles?since=0&limit=200", Data(#"{"error":{"code":"invalid_token"}}"#.utf8), status: 401)
        let library = SiteLibrary(directory: directory, client: site.client(token: "er_token"), keyRefused: { false })
        await library.sync()
        #expect(library.tokenRefused)
    }
}
