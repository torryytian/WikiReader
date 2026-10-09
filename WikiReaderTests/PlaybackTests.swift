import Foundation
import Testing
@testable import WikiReader

// MARK: - Skipping

struct SkipTargetTests {
    private let lengths = [100, 50, 80]

    @Test func forwardWithinABlock() {
        let target = ReadingSession.skipTarget(blockLengths: lengths, block: 0, offset: 10, characters: 30)
        #expect(target == (0, 40))
    }

    @Test func forwardOverABlockBoundary() {
        // 10 left in block 0, all 50 of block 1, then 20 into block 2.
        let target = ReadingSession.skipTarget(blockLengths: lengths, block: 0, offset: 90, characters: 80)
        #expect(target == (2, 20))
    }

    @Test func forwardStopsAtTheEndOfTheArticle() {
        let target = ReadingSession.skipTarget(blockLengths: lengths, block: 2, offset: 70, characters: 500)
        #expect(target == (2, 80))
    }

    @Test func backwardWithinABlock() {
        let target = ReadingSession.skipTarget(blockLengths: lengths, block: 1, offset: 40, characters: -30)
        #expect(target == (1, 10))
    }

    @Test func backwardOverABlockBoundary() {
        // 5 back to the start of block 1, then 15 into block 0 from its end.
        let target = ReadingSession.skipTarget(blockLengths: lengths, block: 1, offset: 5, characters: -20)
        #expect(target == (0, 85))
    }

    @Test func backwardStopsAtTheStart() {
        let target = ReadingSession.skipTarget(blockLengths: lengths, block: 1, offset: 5, characters: -999)
        #expect(target == (0, 0))
    }

    @Test func zeroDistanceStaysPut() {
        #expect(ReadingSession.skipTarget(blockLengths: lengths, block: 1, offset: 7, characters: 0) == (1, 7))
    }

    @Test func positionSnapsToTheStartOfAWord() {
        let text = "Einstein was born in Ulm." as NSString
        #expect(ReadingSession.wordStart(in: text, atOrBefore: 15) == 13)  // inside "born"
        #expect(ReadingSession.wordStart(in: text, atOrBefore: 13) == 13)  // already at a word start
        #expect(ReadingSession.wordStart(in: text, atOrBefore: 12) == 9)  // on the space after "was"
        #expect(ReadingSession.wordStart(in: text, atOrBefore: 3) == 0)
        #expect(ReadingSession.wordStart(in: text, atOrBefore: 0) == 0)
    }
}

@MainActor
struct SessionSkipTests {
    // 14 characters per second at 1x: 10 seconds is 140 characters.
    let blocks: [ContentBlock] = [
        .paragraph(String(repeating: "word ", count: 40)),  // 200 characters
        .paragraph(String(repeating: "more ", count: 40)),  // 200 characters
    ]
    let engine = FakeSpeechEngine()

    private func makeSession(rate: SpeechRate = .normal) -> ReadingSession {
        ReadingSession(blocks: blocks, rate: rate, engine: engine)
    }

    @Test func skippingForwardWhilePlayingContinuesFromTheNewPosition() {
        let session = makeSession()
        session.play()
        session.skip(seconds: 10)
        #expect(session.currentBlock == 0)
        #expect(engine.lastSpoken?.startOffset == 140)
        #expect(session.state == .playing)
    }

    @Test func skippingPastTheEndOfABlockMovesToTheNext() {
        let session = makeSession()
        session.play()
        session.skip(seconds: 20)  // 280 characters: 200 of block 0, then 80 into block 1
        #expect(session.currentBlock == 1)
        #expect(engine.lastSpoken?.startOffset == 80)
    }

    @Test func skippingBackFromTheStartStaysAtTheStart() {
        let session = makeSession()
        session.play()
        session.skip(seconds: -10)
        #expect(session.currentBlock == 0)
        #expect(engine.lastSpoken?.startOffset == 0)
    }

    @Test func skipDistanceFollowsTheSpeed() {
        let session = makeSession(rate: .faster)  // 1.5x: 210 characters in 10 seconds
        session.play()
        session.skip(seconds: 10)
        // 210 characters is 200 of block 0 and 10 into block 1, at a word start.
        #expect(session.currentBlock == 1)
        #expect(engine.lastSpoken?.startOffset == 10)
    }

    @Test func skippingWhilePausedKeepsItPausedAndPlayStartsThere() {
        let session = makeSession()
        session.play()
        session.pause()
        session.skip(seconds: 10)
        #expect(session.state == .paused)
        session.play()
        #expect(engine.lastSpoken?.startOffset == 140)
    }

    @Test func skippingWhileStoppedMovesTheStartingPoint() {
        let session = makeSession()
        session.skip(seconds: 10)
        #expect(session.state == .stopped)
        session.play()
        #expect(engine.lastSpoken?.startOffset == 140)
    }

    @Test func skipStartsFromTheSpokenWord() {
        let session = makeSession()
        session.play()
        engine.emitWord(NSRange(location: 100, length: 4))
        session.skip(seconds: 10)
        #expect(engine.lastSpoken?.startOffset == 240 - 200)  // 100 + 140 = 240: 40 into block 1
        #expect(session.currentBlock == 1)
    }
}

// MARK: - Playback mode

struct PlaybackModeTests {
    @Test func loopRestartsTheSameArticle() {
        #expect(PlaybackMode.loop.next(count: 3, index: 1) == .restart)
    }

    @Test func sequentialGoesToTheNextArticleAndStopsAfterTheLast() {
        #expect(PlaybackMode.sequential.next(count: 3, index: 0) == .article(1))
        #expect(PlaybackMode.sequential.next(count: 3, index: 1) == .article(2))
        #expect(PlaybackMode.sequential.next(count: 3, index: 2) == .stop)
    }

    @Test func shuffleNeverPicksTheArticleJustRead() {
        for index in 0..<4 {
            for pick in 0..<3 {  // every value the random source can give for 4 articles
                guard case .article(let target) = PlaybackMode.shuffle.next(count: 4, index: index, random: { _ in pick }) else {
                    Issue.record("Expected another article")
                    return
                }
                #expect(target != index)
                #expect((0..<4).contains(target))
            }
        }
    }

    @Test func shuffleCanReachEveryOtherArticle() {
        let reached = Set((0..<3).compactMap { pick -> Int? in
            if case .article(let target) = PlaybackMode.shuffle.next(count: 4, index: 1, random: { _ in pick }) { target } else { nil }
        })
        #expect(reached == [0, 2, 3])
    }

    @Test func shuffleWithOneArticleReadsItAgain() {
        #expect(PlaybackMode.shuffle.next(count: 1, index: 0) == .restart)
    }

    @Test func unknownSavedModeFallsBackToSequential() {
        UserDefaults.standard.set("nonsense", forKey: SettingsKeys.playbackMode)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.playbackMode) }
        #expect(PlaybackMode.saved == .sequential)
    }
}

@MainActor
struct SessionFinishTests {
    @Test func finishingTheLastBlockReportsTheEndOnce() {
        let engine = FakeSpeechEngine()
        let session = ReadingSession(blocks: [.paragraph("One."), .paragraph("Two.")], engine: engine)
        var finished = 0
        session.onFinished = { finished += 1 }

        session.play()
        engine.emitFinished()
        #expect(finished == 0)  // one block left
        engine.emitFinished()
        #expect(finished == 1)
        #expect(session.state == .stopped)
        #expect(session.currentBlock == 0)  // back at the start, ready for the next round
    }
}

// MARK: - Progress shown in the top bar

struct ReadingProgressTests {
    private let blocks: [ContentBlock] = [
        .paragraph(String(repeating: "a", count: 100)),
        .heading("History", level: 2),
        .paragraph(String(repeating: "b", count: 300)),
        .paragraph(String(repeating: "c", count: 600)),
    ]

    @Test func startOfTheArticle() {
        let progress = ReadingProgress(blocks: blocks, currentBlock: 0, rate: .normal)
        #expect(progress.fraction == 0)
        #expect(progress.percentText == "0%")
        #expect(progress.section == nil)
        #expect(progress.paragraph == 1)
        #expect(progress.paragraphCount == 3)
    }

    @Test func middleOfTheArticleKnowsItsSectionAndParagraph() {
        let progress = ReadingProgress(blocks: blocks, currentBlock: 3, rate: .normal)
        #expect(progress.section == "History")
        #expect(progress.paragraph == 3)
        // 100 + 7 + 300 characters are behind the current block, out of 1007.
        #expect(progress.percentText == "40%")
    }

    @Test func aHeadingCountsAsTheParagraphBeforeIt() {
        #expect(ReadingProgress(blocks: blocks, currentBlock: 1, rate: .normal).paragraph == 1)
    }

    @Test func minutesLeftUseTheSpeed() {
        let long = [ContentBlock.paragraph(String(repeating: "x", count: 14 * 60 * 10))]  // 10 minutes at 1x
        #expect(ReadingProgress(blocks: long, currentBlock: 0, rate: .normal).minutesLeft == 10)
        #expect(ReadingProgress(blocks: long, currentBlock: 0, rate: .faster).minutesLeft == 7)
    }

    @Test func detailTextReadsNaturally() {
        let text = ReadingProgress(blocks: blocks, currentBlock: 3, rate: .normal).detailText
        #expect(text.hasPrefix("History · paragraph 3 of 3 · "))
        #expect(text.hasSuffix("left"))
        #expect(ReadingProgress(blocks: [], currentBlock: 0, rate: .normal).detailText.contains("under a minute"))
    }
}

struct PlaybackModeCycleTests {
    @Test func tappingGoesThroughEveryModeAndBack() {
        #expect(PlaybackMode.sequential.cycled == .loop)
        #expect(PlaybackMode.loop.cycled == .shuffle)
        #expect(PlaybackMode.shuffle.cycled == .sequential)
    }

    @Test func everyModeHasAMessage() {
        for mode in PlaybackMode.allCases {
            #expect(!mode.menuTitle.isEmpty)
            #expect(!mode.symbol.isEmpty)
        }
    }
}

// MARK: - Contents

struct ArticleOutlineTests {
    private let blocks: [ContentBlock] = [
        .paragraph(String(repeating: "a", count: 100)),   // 0 introduction
        .heading("Life", level: 2),                       // 1
        .paragraph(String(repeating: "b", count: 193)),   // 2
        .heading("Early years", level: 3),                // 3
        .paragraph(String(repeating: "c", count: 200)),   // 4
        .heading("Legacy", level: 2),                     // 5
        .paragraph(String(repeating: "d", count: 100)),   // 6
    ]

    @Test func listsTheIntroductionAndEveryHeading() {
        let outline = ArticleOutline(blocks: blocks)
        #expect(outline.entries.map(\.title) == ["Introduction", "Life", "Early years", "Legacy"])
        #expect(outline.entries.map(\.block) == [0, 1, 3, 5])
    }

    @Test func entriesKnowTheirDepthAndPosition() {
        let outline = ArticleOutline(blocks: blocks)
        #expect(outline.entries.map(\.depth) == [0, 0, 1, 0])
        // 100 + 4 + 193 + 11 + 200 = 508 characters come before "Legacy", out of 614.
        #expect(outline.entries[3].percentText == "83%")
        #expect(outline.entries[0].percentText == "0%")
    }

    @Test func currentEntryIsTheLastOneAtOrBeforeTheBlock() {
        let outline = ArticleOutline(blocks: blocks)
        #expect(outline.currentEntry(atBlock: 0)?.title == "Introduction")
        #expect(outline.currentEntry(atBlock: 2)?.title == "Life")
        #expect(outline.currentEntry(atBlock: 3)?.title == "Early years")
        #expect(outline.currentEntry(atBlock: 6)?.title == "Legacy")
    }

    @Test func noIntroductionEntryWhenTheArticleStartsWithAHeading() {
        let outline = ArticleOutline(blocks: [.heading("History", level: 2), .paragraph("Text.")])
        #expect(outline.entries.map(\.title) == ["History"])
    }

    @Test func anArticleWithoutHeadingsIsOneEntry() {
        #expect(ArticleOutline(blocks: [.paragraph("Only text.")]).entries.map(\.title) == ["Introduction"])
        #expect(ArticleOutline(blocks: []).entries.isEmpty)
    }

    @Test func deepHeadingsStopIndentingAtTwoLevels() {
        let outline = ArticleOutline(blocks: [.heading("A", level: 2), .heading("B", level: 5), .heading("C", level: 9)])
        #expect(outline.entries.map(\.depth) == [0, 2, 2])
    }
}

@MainActor
struct SessionJumpTests {
    let blocks: [ContentBlock] = [.paragraph("One."), .heading("Two", level: 2), .paragraph("Three."), .paragraph("Four.")]
    let engine = FakeSpeechEngine()

    @Test func jumpingWhilePlayingContinuesFromThere() {
        let session = ReadingSession(blocks: blocks, engine: engine)
        session.play()
        session.go(to: 2)
        #expect(session.currentBlock == 2)
        #expect(session.state == .playing)
        #expect(engine.lastSpoken?.text == "Three.")
    }

    @Test func jumpingWhileStoppedMovesThePlaceWithoutPlaying() {
        let session = ReadingSession(blocks: blocks, engine: engine)
        session.go(to: 3)
        #expect(session.currentBlock == 3)
        #expect(session.state == .stopped)
        #expect(engine.spoken.isEmpty)
        session.play()
        #expect(engine.lastSpoken?.text == "Four.")
    }

    @Test func jumpingWhilePausedStaysPaused() {
        let session = ReadingSession(blocks: blocks, engine: engine)
        session.play()
        session.pause()
        session.go(to: 1)
        #expect(session.state == .paused)
        session.play()
        #expect(engine.lastSpoken?.text == "Two")
    }

    @Test func jumpingToAnInvalidBlockDoesNothing() {
        let session = ReadingSession(blocks: blocks, engine: engine)
        session.go(to: 99)
        #expect(session.currentBlock == 0)
    }
}

struct ArticleOutlineLengthTests {
    private let blocks: [ContentBlock] = [
        .paragraph(String(repeating: "a", count: 840)),    // 1 minute at 14 characters a second
        .heading("Life", level: 2),
        .paragraph(String(repeating: "b", count: 2520)),   // 3 minutes
        .heading("Early years", level: 3),
        .paragraph(String(repeating: "c", count: 10)),
    ]

    @Test func eachSectionKnowsItsOwnLength() {
        let entries = ArticleOutline(blocks: blocks).entries
        // The heading text counts toward its own section.
        #expect(entries.map(\.characters) == [840, 4 + 2520, 11 + 10])
        #expect(entries.reduce(0) { $0 + $1.characters } == ArticleOutline(blocks: blocks).totalCharacters)
    }

    @Test func minutesRoundButNeverShowZero() {
        let entries = ArticleOutline(blocks: blocks).entries
        #expect(entries[0].minutes == 1)
        #expect(entries[1].minutes == 3)
        #expect(entries[2].minutes == 1)  // a tiny section still reads "1 min"
    }

    @Test func totalMinutesAddUp() {
        #expect(ArticleOutline(blocks: blocks).totalMinutes == 4)
    }

    @Test func onlyTheLeadingTextIsTheIntroduction() {
        let entries = ArticleOutline(blocks: blocks).entries
        #expect(entries.map(\.isIntroduction) == [true, false, false])
    }

    @Test func mainSectionsAreNumberedFromOneAfterTheIntroduction() {
        let entries = ArticleOutline(blocks: blocks + [.heading("Legacy", level: 2), .paragraph("Text.")]).entries
        // Introduction, Life, Early years (a subsection), Legacy.
        #expect(ContentsView.mainSectionNumbers(entries) == [nil, 1, nil, 2])
    }
}
