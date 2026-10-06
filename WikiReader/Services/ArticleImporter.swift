import Foundation

/// A fetched and cleaned article, ready to be saved.
nonisolated struct ImportedArticle: Sendable {
    var title: String
    var sourceURL: URL
    var blocks: [ContentBlock]
}

nonisolated enum ImportError: LocalizedError, Equatable {
    case input(ArticleInput.ParseError)
    case wikipedia(WikipediaError)
    case nothingToRead(title: String)

    var errorDescription: String? {
        switch self {
        case .input(.empty):
            "Enter a Wikipedia link or an article title."
        case .input(.unsupportedHost(let host)):
            "Only English Wikipedia (en.wikipedia.org) is supported, not \(host)."
        case .input(.notAnArticleLink):
            "This link doesn't point to a Wikipedia article."
        case .wikipedia(.pageNotFound(let title)):
            "There is no English Wikipedia article called “\(title)”."
        case .wikipedia(.invalidTitle(let title)):
            "“\(title)” isn't a valid article title."
        case .wikipedia(.emptyArticle(let title)), .nothingToRead(let title):
            "“\(title)” has no readable text."
        case .wikipedia(.network(let description)):
            "Couldn't reach Wikipedia: \(description)"
        case .wikipedia(.httpStatus(let code)):
            "Wikipedia returned an error (HTTP \(code)). Try again later."
        case .wikipedia(.badResponse):
            "Wikipedia returned an unexpected response."
        }
    }
}

/// Input → title → fetch → clean. Saving is left to the caller, which owns the SwiftData context.
nonisolated struct ArticleImporter: Sendable {
    var client = WikipediaClient()

    /// `@concurrent` runs this on a background thread: cleaning a long article takes noticeable CPU time.
    @concurrent
    func importArticle(from input: String) async throws(ImportError) -> ImportedArticle {
        let requestedTitle: String
        do {
            requestedTitle = try ArticleInput.title(from: input)
        } catch {
            throw .input(error)
        }

        let fetched: FetchedArticle
        do {
            fetched = try await client.fetchArticle(title: requestedTitle)
        } catch {
            throw .wikipedia(error)
        }

        let blocks = ArticleCleaner.blocks(from: fetched.extract)
        guard blocks.contains(where: { $0.kind == .paragraph }) else {
            throw .nothingToRead(title: fetched.title)
        }
        return ImportedArticle(
            title: fetched.title,
            sourceURL: ArticleInput.articleURL(forTitle: fetched.title),
            blocks: blocks
        )
    }
}
