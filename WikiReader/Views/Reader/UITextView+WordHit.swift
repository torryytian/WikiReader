import UIKit

extension UITextView {
    /// The range of the lookup-worthy word under `point` (in the text view's coordinates),
    /// or nil for whitespace, punctuation, numbers and empty areas.
    func lookupWordRange(at point: CGPoint) -> NSRange? {
        // closestPosition always returns *some* position, even far from any text,
        // so the hit is confirmed against the word's on-screen rects below.
        guard let position = closestPosition(to: point) else { return nil }

        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let backward = UITextDirection(rawValue: UITextStorageDirection.backward.rawValue)
        guard let wordRange = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: forward)
            ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: backward)
        else { return nil }

        // Forgiving vertically (between lines), strict horizontally so a tap on the comma
        // right after a word doesn't count as a tap on the word.
        let isOnWord = selectionRects(for: wordRange).contains { $0.rect.insetBy(dx: 0, dy: -4).contains(point) }
        guard isOnWord else { return nil }

        let range = NSRange(
            location: offset(from: beginningOfDocument, to: wordRange.start),
            length: offset(from: wordRange.start, to: wordRange.end)
        )
        guard DictionaryLookup.isLookupWord((text as NSString).substring(with: range)) else { return nil }
        return range
    }
}
