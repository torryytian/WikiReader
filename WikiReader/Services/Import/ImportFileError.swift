import Foundation

/// Why a file, photos or text couldn't be turned into an article.
nonisolated enum ImportFileError: LocalizedError, Equatable {
    case unsupported(String)
    case unreadable(String)
    case encrypted
    case noText

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            "“\(name)” isn't a type WikiReader can read. Use a text or Markdown file, a PDF, or an image."
        case .unreadable(let reason):
            "The file couldn't be read: \(reason)"
        case .encrypted:
            "This PDF is locked with a password. Unlock it first, then import it again."
        case .noText:
            "No readable text was found."
        }
    }
}
