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

/// When each word is spoken in an audio clip.
///
/// OpenAI returns no word timestamps, so time is shared out by word length, with extra weight
/// for the pauses after punctuation. Good enough for highlighting; it can drift by a word or two.
/// A recording on English Reader comes with each word's real start, which is used instead when it
/// has as many words as this text does.
nonisolated struct WordTimeline: Sendable {
    /// Words of the clip's text, as UTF-16 ranges in that text.
    let words: [NSRange]
    /// Where each word starts, as a fraction of the clip's duration (0..<1).
    private let starts: [Double]
    /// The starts were measured rather than estimated.
    let isMeasured: Bool

    init(text: String) {
        let words = Self.words(of: text)
        self.words = words
        starts = Self.estimatedStarts(of: words, in: text as NSString)
        isMeasured = false
    }

    /// With each word's start in milliseconds (`startsMs`) in a clip of `duration` seconds, when they match the words
    /// of `text` one to one (the site splits words much as this app does, but not always alike); else estimated.
    init(text: String, startsMs: [Int]?, duration: TimeInterval) {
        let words = Self.words(of: text)
        self.words = words
        guard let startsMs, startsMs.count == words.count, !words.isEmpty, duration > 0 else {
            starts = Self.estimatedStarts(of: words, in: text as NSString)
            isMeasured = false
            return
        }
        var starts: [Double] = []
        var previous = 0.0
        for ms in startsMs {
            // Never backwards, never past the end.
            previous = min(max(Double(ms) / 1000 / duration, previous), 1)
            starts.append(previous)
        }
        self.starts = starts
        isMeasured = true
    }

    private static func words(of text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { NSRange($0, in: text) }
    }

    private static func estimatedStarts(of words: [NSRange], in ns: NSString) -> [Double] {
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
        return starts
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
