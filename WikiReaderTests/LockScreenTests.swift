import Foundation
import Testing
import UIKit
@testable import WikiReader

struct LockScreenTextTests {
    private let paragraph = "Albert Einstein was born in Ulm. He moved to Munich in 1880. The family later lived in Italy."

    @Test func findsTheSentenceAroundTheSpokenWord() throws {
        let offset = (paragraph as NSString).range(of: "Munich").location
        let text = try #require(LockScreenText(block: paragraph, offset: offset))
        #expect(text.current == "He moved to Munich in 1880.")
        #expect(text.previous == "Albert Einstein was born in Ulm.")
        #expect(text.next == "The family later lived in Italy.")
    }

    @Test func firstAndLastSentencesHaveOneNeighbour() throws {
        let first = try #require(LockScreenText(block: paragraph, offset: 0))
        #expect(first.previous == nil)
        #expect(first.next != nil)
        let last = try #require(LockScreenText(block: paragraph, offset: (paragraph as NSString).length - 1))
        #expect(last.next == nil)
        #expect(last.current == "The family later lived in Italy.")
    }

    @Test func sentenceStartChangesOnlyWhenTheSentenceDoes() throws {
        let a = (paragraph as NSString).range(of: "moved").location
        let b = (paragraph as NSString).range(of: "Munich").location
        let c = (paragraph as NSString).range(of: "family").location
        let one = try #require(LockScreenText(block: paragraph, offset: a))
        let two = try #require(LockScreenText(block: paragraph, offset: b))
        let three = try #require(LockScreenText(block: paragraph, offset: c))
        #expect(one.currentStart == two.currentStart)
        #expect(one.currentStart != three.currentStart)
    }

    @Test func aShortHeadingIsOneSentence() throws {
        let text = try #require(LockScreenText(block: "Early life", offset: 3))
        #expect(text.current == "Early life")
        #expect(text.previous == nil && text.next == nil)
    }

    @Test func outOfRangeOffsetsAreClamped() throws {
        #expect(LockScreenText(block: paragraph, offset: -5)?.previous == nil)
        #expect(LockScreenText(block: paragraph, offset: 9999)?.next == nil)
    }

    @Test func emptyTextHasNothingToShow() {
        #expect(LockScreenText(block: "", offset: 0) == nil)
    }

    @Test func artworkIsASquareImage() throws {
        let text = try #require(LockScreenText(block: paragraph, offset: 40))
        let image = LockScreenArtwork.image(for: text, header: "Albert Einstein", side: 300)
        #expect(image.size == CGSize(width: 300, height: 300))
        if let path = ProcessInfo.processInfo.environment["WIKIREADER_ARTWORK_PATH"], let data = image.pngData() {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
