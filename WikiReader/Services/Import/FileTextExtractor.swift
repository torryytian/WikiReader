import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Text taken from something the reader brought in, ready for review and then `LocalArticleParser`.
nonisolated struct ExtractedText: Equatable, Sendable {
    var text: String
    /// A name for the article if the text doesn't give one: the file's name.
    var suggestedTitle: String
}

/// Reads text from a text or Markdown file, a PDF, or an image. Everything happens on the device.
nonisolated enum FileTextExtractor {
    /// What the file picker offers.
    static var allowedTypes: [UTType] {
        // `.data` lets a file with a type the system doesn't know (such as `.wiki`) be chosen; `kind(of:)` then
        // refuses what can't be read, with a message that says so.
        [.plainText, .text, .pdf, .image, .data] + textExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Text files: plain text, Markdown, and MediaWiki markup.
    static let textExtensions = ["txt", "text", "md", "markdown", "wiki", "wikitext", "mediawiki"]

    enum Kind { case text, pdf, image }

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return .text }
        if ext == "pdf" { return .pdf }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .plainText) { return .text }
            if type.conforms(to: .pdf) { return .pdf }
        }
        return nil
    }

    /// `@concurrent`: recognizing text in pages takes seconds.
    @concurrent
    static func extract(from url: URL) async throws(ImportFileError) -> ExtractedText {
        let title = suggestedTitle(forFileNamed: url.deletingPathExtension().lastPathComponent)
        guard let kind = kind(of: url) else { throw .unsupported(url.lastPathComponent) }
        let text: String
        switch kind {
        case .text:
            text = try readText(at: url)
        case .pdf:
            text = try PDFTextExtractor.markdown(from: url)
        case .image:
            guard let data = try? Data(contentsOf: url) else { throw .unreadable("it can't be opened") }
            text = try recognize(imageData: [data])
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .noText }
        return ExtractedText(text: text, suggestedTitle: title)
    }

    /// Photos chosen from the library.
    @concurrent
    static func extract(imageData: [Data], title: String) async throws(ImportFileError) -> ExtractedText {
        let text = try recognize(imageData: imageData)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .noText }
        return ExtractedText(text: text, suggestedTitle: title)
    }

    // MARK: - Pieces

    static func readText(at url: URL) throws(ImportFileError) -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        // Not valid UTF-8/UTF-16: an old Windows file.
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw .unreadable("its text encoding isn't supported")
    }

    static func recognize(imageData: [Data]) throws(ImportFileError) -> String {
        var pictures: [(image: CGImage, orientation: CGImagePropertyOrientation)] = []
        for data in imageData {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                throw .unreadable("it isn't an image")
            }
            pictures.append((cgImage, orientation(of: image)))
        }
        return try ImageTextRecognizer.markdown(fromImages: pictures)
    }

    /// How Vision should turn the picture upright: a photo from the camera is stored sideways with a rotation flag.
    static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    /// "the_tea-trade" → "the tea trade".
    static func suggestedTitle(forFileNamed name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let collapsed = spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.isEmpty ? "Imported Article" : collapsed
    }
}
