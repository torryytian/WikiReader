import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads text out of a photo or a screenshot of a page with the system's on-device text recognition (no network).
nonisolated enum ImageTextRecognizer {
    /// Lines of text in the image, top to bottom, in a 1000 × 1000 coordinate space (only comparisons within one
    /// axis are meaningful, so the picture's shape doesn't matter).
    static func lines(in image: CGImage, orientation: CGImagePropertyOrientation = .up, page: Int = 0) throws(ImportFileError) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        } catch {
            throw .unreadable(error.localizedDescription)
        }

        let scale: CGFloat = 1000
        let found: [TextLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return TextLine(
                text: text, size: box.height * scale,
                minX: box.minX * scale, maxX: box.maxX * scale,
                top: (1 - box.maxY) * scale, height: box.height * scale,
                page: page, pageHeight: scale
            )
        }
        return found.sorted { ($0.top, $0.minX) < ($1.top, $1.minX) }
    }

    /// Text of several pictures in order, as one document.
    static func markdown(fromImages images: [(image: CGImage, orientation: CGImagePropertyOrientation)]) throws(ImportFileError) -> String {
        var lines: [TextLine] = []
        for (index, picture) in images.enumerated() {
            lines += try Self.lines(in: picture.image, orientation: picture.orientation, page: index)
        }
        return TextLineAssembler(headingRatio: 1.35).markdown(from: lines)
    }
}
