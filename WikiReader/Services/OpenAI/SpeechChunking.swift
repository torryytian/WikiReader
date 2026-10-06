import Foundation
import NaturalLanguage

/// Splits text that is too long for one speech request, and estimates word timing within audio.
nonisolated enum SpeechChunking {
    /// Contiguous UTF-16 ranges covering `text`, each at most `maxLength` long, split at sentence ends
    /// where possible (then at spaces, then anywhere) so each request sounds natural on its own.
    static func chunks(of text: String, maxLength: Int = OpenAISpeechRequest.maxInputLength) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > maxLength else { return [NSRange(location: 0, length: ns.length)] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let sentenceEnds = tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { NSRange($0, in: text).upperBound }

        var result: [NSRange] = []
        var start = 0
        while ns.length - start > maxLength {
            let limit = start + maxLength
            let end = sentenceEnds.last { $0 > start && $0 <= limit }
                ?? lastSpace(in: ns, from: start, to: limit)
                ?? limit
            result.append(NSRange(location: start, length: end - start))
            start = end
        }
        result.append(NSRange(location: start, length: ns.length - start))
        return result
    }

    private static func lastSpace(in text: NSString, from start: Int, to limit: Int) -> Int? {
        let range = text.rangeOfCharacter(from: .whitespaces, options: .backwards, range: NSRange(location: start, length: limit - start))
        return range.location == NSNotFound || range.location == start ? nil : range.location + 1
    }
}

/// Estimates when each word is spoken in an audio clip whose only timing information is its duration.
///
/// OpenAI returns no word timestamps, so time is shared out by word length, with extra weight
/// for the pauses after punctuation. Good enough for highlighting; it can drift by a word or two.
nonisolated struct WordTimeline: Sendable {
    /// Words of the clip's text, as UTF-16 ranges in that text.
    let words: [NSRange]
    /// Cumulative weight at the start of each word, normalized to 0..<1.
    private let starts: [Double]

    init(text: String) {
        let ns = text as NSString
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let words = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { NSRange($0, in: text) }

        var weights: [Double] = []
        for (index, word) in words.enumerated() {
            let gapEnd = index + 1 < words.count ? words[index + 1].location : ns.length
            let gap = ns.substring(with: NSRange(location: word.upperBound, length: gapEnd - word.upperBound))
            weights.append(Double(word.length) + 1 + Self.pauseWeight(after: gap))
        }
        let total = max(weights.reduce(0, +), 1)
        var cumulative = 0.0
        var starts: [Double] = []
        for weight in weights {
            starts.append(cumulative / total)
            cumulative += weight
        }
        self.words = words
        self.starts = starts
    }

    /// Extra time, in characters, for the pause punctuation causes.
    private static func pauseWeight(after gap: String) -> Double {
        if gap.contains(where: { ".!?".contains($0) }) { return 6 }
        if gap.contains(where: { ",;:–—".contains($0) }) { return 3 }
        return 0
    }

    /// The word being spoken at `fraction` (0...1) of the clip's duration.
    func wordIndex(atFraction fraction: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        let index = starts.lastIndex { $0 <= fraction } ?? 0
        return index
    }

    /// Fraction of the clip's duration at which the word containing (or following) `offset` starts.
    func fraction(atOffset offset: Int) -> Double {
        guard let index = words.firstIndex(where: { offset < $0.upperBound }) else { return 1 }
        return starts[index]
    }
}
