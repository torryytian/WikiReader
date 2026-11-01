import Foundation

nonisolated enum DriveError: Error, Equatable, Sendable {
    case notSignedIn
    case unauthorized
    case http(status: Int, detail: String?)
    case network(String)
    case badResponse
    /// The shared folder holds a format this version doesn't know (see docs/shared-tts-cache-format.md).
    case unsupportedFormat(String)

    var message: String {
        switch self {
        case .notSignedIn: "Not signed in to Google."
        case .unauthorized: "Google Drive refused the sign-in. Sign in again."
        case .http(let status, let detail): "Google Drive answered HTTP \(status)\(detail.map { ": \($0)" } ?? "")."
        case .network(let detail): "Couldn't reach Google Drive: \(detail)"
        case .badResponse: "Google Drive returned an unexpected response."
        case .unsupportedFormat(let found): "The Drive folder holds a different cache format (\(found))."
        }
    }
}

/// Google Drive's REST API (v3), only what the shared audio cache needs: folders, finding files by name, downloading,
/// uploading and replacing. Everything goes through an access token from `GoogleAccount`; with the `drive.file` scope
/// it only ever sees files created by this app or the Chrome extension.
nonisolated struct DriveClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// A valid access token; `true` asks for a fresh one (after a 401).
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    static let api = URL(string: "https://www.googleapis.com/drive/v3/files")!
    static let uploadAPI = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    static let folderType = "application/vnd.google-apps.folder"
    /// Drive's limit on how long a query may be is generous, but 50 names per query keeps it well inside it.
    static let namesPerQuery = 50

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    var transport: Transport = { try await DriveClient.session.data(for: $0) }
    var token: TokenProvider

    // MARK: - Folders and files

    struct File: Decodable, Equatable, Sendable {
        var id: String
        var name: String
    }

    /// The first folder with this name in `parent` ("root" is My Drive), oldest first, so two devices that each
    /// created one agree on which to use.
    func folder(named name: String, in parent: String) async throws(DriveError) -> String? {
        try await list(query: "mimeType = '\(Self.folderType)' and name = \(Self.quoted(name)) and \(Self.quoted(parent)) in parents and trashed = false", orderBy: "createdTime")
            .first?.id
    }

    func createFolder(named name: String, in parent: String) async throws(DriveError) -> String {
        var request = URLRequest(url: Self.url(Self.api, ["fields": "id"]))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderType, "parents": [parent]])
        return try decode(File.self, from: await send(request)).id
    }

    /// The files in `folder` with these names, by name. Asks in batches of `namesPerQuery`.
    func files(named names: [String], in folder: String) async throws(DriveError) -> [String: String] {
        var found: [String: String] = [:]
        var start = 0
        while start < names.count {
            let batch = names[start..<min(start + Self.namesPerQuery, names.count)]
            start += Self.namesPerQuery
            let anyName = batch.map { "name = \(Self.quoted($0))" }.joined(separator: " or ")
            for file in try await list(query: "\(Self.quoted(folder)) in parents and trashed = false and (\(anyName))", orderBy: "createdTime") {
                // Two devices uploading the same audio leave two copies; any will do, so keep the first.
                if found[file.name] == nil { found[file.name] = file.id }
            }
        }
        return found
    }

    private func list(query: String, orderBy: String) async throws(DriveError) -> [File] {
        struct Page: Decodable {
            var files: [File]
            var nextPageToken: String?
        }
        var files: [File] = []
        var pageToken: String?
        repeat {
            var parameters = [
                "q": query, "fields": "nextPageToken,files(id,name)", "pageSize": "1000",
                "orderBy": orderBy, "spaces": "drive",
            ]
            if let pageToken { parameters["pageToken"] = pageToken }
            let page = try decode(Page.self, from: await send(URLRequest(url: Self.url(Self.api, parameters))))
            files += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    func download(fileID: String) async throws(DriveError) -> Data {
        try await send(URLRequest(url: Self.url(Self.api.appending(path: fileID), ["alt": "media"])))
    }

    /// Uploads a new file into `folder` and returns its id.
    func upload(name: String, data: Data, mimeType: String, in folder: String) async throws(DriveError) -> String {
        let boundary = "wikireader-\(UUID().uuidString)"
        var request = URLRequest(url: Self.url(Self.uploadAPI, ["uploadType": "multipart", "fields": "id"]))
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            metadata: ["name": name, "parents": [folder]], data: data, mimeType: mimeType, boundary: boundary
        )
        request.timeoutInterval = 120
        return try decode(File.self, from: await send(request)).id
    }

    /// Replaces a file's contents.
    func replace(fileID: String, data: Data, mimeType: String) async throws(DriveError) {
        var request = URLRequest(url: Self.url(Self.uploadAPI.appending(path: fileID), ["uploadType": "media", "fields": "id"]))
        request.httpMethod = "PATCH"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request)
    }

    // MARK: - Requests

    /// Sends with a bearer token; a 401 gets one retry with a fresh token.
    private func send(_ request: URLRequest) async throws(DriveError) -> Data {
        for attempt in 0..<2 {
            var request = request
            do {
                request.setValue("Bearer \(try await token(attempt > 0))", forHTTPHeaderField: "Authorization")
            } catch {
                throw .notSignedIn
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport(request)
            } catch {
                throw .network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw .badResponse }
            if http.statusCode == 401, attempt == 0 { continue }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 { throw .unauthorized }
                throw .http(status: http.statusCode, detail: Self.errorMessage(data))
            }
            return data
        }
        throw .unauthorized
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(DriveError) -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw .badResponse }
        return value
    }

    private static func errorMessage(_ data: Data) -> String? {
        struct Body: Decodable {
            struct Inner: Decodable { var message: String? }
            var error: Inner?
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error?.message
    }

    static func url(_ base: URL, _ parameters: [String: String]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` in a query value would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// A string literal in Drive's query language: single-quoted, with `\` and `'` escaped.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func multipartBody(metadata: [String: Any], data: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append((try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data())
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
