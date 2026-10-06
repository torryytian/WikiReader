import Foundation

/// Turns what the user typed (a desktop/mobile Wikipedia link or a bare title)
/// into an article title suitable for the MediaWiki API.
nonisolated enum ArticleInput {
    enum ParseError: Error, Equatable {
        case empty
        /// A link to a site other than English Wikipedia.
        case unsupportedHost(String)
        /// An English Wikipedia link that doesn't point at an article.
        case notAnArticleLink
    }

    static let supportedHosts: Set<String> = ["en.wikipedia.org", "en.m.wikipedia.org"]

    static func title(from input: String) throws(ParseError) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }

        let raw = looksLikeLink(trimmed) ? try titleFromLink(trimmed) : stripFragment(trimmed)
        let title = normalize(raw)
        guard !title.isEmpty else { throw looksLikeLink(trimmed) ? .notAnArticleLink : .empty }
        return title
    }

    /// The canonical desktop URL for a title, e.g. `https://en.wikipedia.org/wiki/Albert_Einstein`.
    static func articleURL(forTitle title: String) -> URL {
        let path = title.replacingOccurrences(of: " ", with: "_")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "en.wikipedia.org"
        components.path = "/wiki/" + path
        return components.url!
    }

    // MARK: - Private

    private static func looksLikeLink(_ text: String) -> Bool {
        if text.contains("://") { return true }
        let lower = text.lowercased()
        return lower.hasPrefix("www.") || lower.range(of: #"^[a-z0-9.-]+\.[a-z]{2,}/"#, options: .regularExpression) != nil
    }

    private static func titleFromLink(_ text: String) throws(ParseError) -> String {
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme),
              let host = components.host?.lowercased()
        else { throw .notAnArticleLink }
        guard supportedHosts.contains(host) else { throw .unsupportedHost(host) }

        // URLComponents already separates the #fragment, so it never reaches the title.
        let path = components.percentEncodedPath
        if path.hasPrefix("/wiki/") {
            let encoded = String(path.dropFirst("/wiki/".count))
            return encoded.removingPercentEncoding ?? encoded
        }
        // Old-style links: /w/index.php?title=Albert_Einstein
        if path == "/w/index.php", let title = components.queryItems?.first(where: { $0.name == "title" })?.value {
            return title
        }
        throw .notAnArticleLink
    }

    private static func stripFragment(_ text: String) -> String {
        text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
    }

    private static func normalize(_ title: String) -> String {
        title
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
