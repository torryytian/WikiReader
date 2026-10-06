import Foundation
import Testing
@testable import WikiReader

@MainActor
struct ReadingSessionTests {
    let blocks: [ContentBlock] = [
        .paragraph("Albert Einstein was a physicist."),  // 0
        .heading("Early life", level: 2),                // 1
        .paragraph("He was born in Ulm."),               // 2
        .paragraph("He moved to Munich."),               // 3
    ]
    let engine = FakeSpeechEngine()

    private func makeSession(startBlock: Int = 0) -> ReadingSession {
        ReadingSession(blocks: blocks, startBlock: startBlock, engine: engine)
    }

    // MARK: - Starting

    @Test func playStartsAtFirstBlockByDefault() {
        let session = makeSession()
        session.play()
        #expect(session.state == .playing)
        #expect(engine.lastSpoken?.text == "Albert Einstein was a physicist.")
        #expect(engine.lastSpoken?.rate == .normal)
    }

    @Test func playStartsAtSavedBlock() {
        let session = makeSession(startBlock: 2)
        session.play()
        #expect(session.currentBlock == 2)
        #expect(engine.lastSpoken?.text == "He was born in Ulm.")
    }

    @Test func invalidSavedBlockFallsBackToStart() {
        let session = makeSession(startBlock: 99)
        #expect(session.currentBlock == 0)
    }

    @Test func emptyArticleDoesNothing() {
        let session = ReadingSession(blocks: [], engine: engine)
        session.play()
        #expect(session.state == .stopped)
        #expect(engine.calls.isEmpty)
    }

    @Test func longPressStartsAtThatBlock() {
        var saved: [Int] = []
        let session = makeSession()
        session.onBlockChange = { saved.append($0) }
        session.start(at: 3)
        #expect(session.state == .playing)
        #expect(engine.lastSpoken?.text == "He moved to Munich.")
        #expect(saved == [3])
    }

    // MARK: - Progress

    @Test func spokenWordIsRelativeToBlock() {
        let session = makeSession(startBlock: 2)
        session.play()
        engine.emitWord(NSRange(location: 7, length: 4))  // "born"
        #expect(session.spokenWord == .init(block: 2, range: NSRange(location: 7, length: 4)))
    }

    @Test func finishedBlockMovesToNext() {
        var saved: [Int] = []
        let session = makeSession()
        session.onBlockChange = { saved.append($0) }
        session.play()
        engine.emitFinished()
        #expect(session.currentBlock == 1)
        #expect(session.state == .playing)
        #expect(engine.lastSpoken?.text == "Early life")
        #expect(saved == [1])
    }

    @Test func headingsGetAPauseParagraphsDont() {
        let session = makeSession()
        session.play()
        #expect(engine.lastSpoken?.pauseAfter == 0)
        engine.emitFinished()
        #expect(engine.lastSpoken?.pauseAfter == ReadingSession.pauseAfterHeading)
    }

    @Test func finishingLastBlockStopsAndRewinds() {
        var saved: [Int] = []
        let session = makeSession(startBlock: 3)
        session.onBlockChange = { saved.append($0) }
        session.play()
        engine.emitWord(NSRange(location: 3, length: 5))
        engine.emitFinished()
        #expect(session.state == .stopped)
        #expect(session.spokenWord == nil)
        #expect(session.currentBlock == 0)
        #expect(saved == [0])

        session.play()
        #expect(engine.lastSpoken?.text == "Albert Einstein was a physicist.")
    }

    @Test func readsWholeArticleInOrder() {
        let session = makeSession()
        session.play()
        for _ in blocks { engine.emitFinished() }
        #expect(engine.spoken.map(\.text) == blocks.map(\.text))
        #expect(session.state == .stopped)
    }

    // MARK: - Pause and resume

    @Test func pauseThenPlayResumesTheSameUtterance() {
        let session = makeSession()
        session.play()
        session.pause()
        #expect(session.state == .paused)
        session.play()
        #expect(session.state == .playing)
        #expect(engine.calls.suffix(2) == [.pause, .resume])
        #expect(engine.spoken.count == 1)
    }

    @Test func togglePlayPause() {
        let session = makeSession()
        session.togglePlayPause()
        #expect(session.isPlaying)
        session.togglePlayPause()
        #expect(session.state == .paused)
        session.togglePlayPause()
        #expect(session.isPlaying)
    }

    @Test func pauseWhenNotPlayingDoesNothing() {
        let session = makeSession()
        session.pause()
        #expect(session.state == .stopped)
        #expect(engine.calls.isEmpty)
    }

    @Test func stopThenPlayRestartsCurrentBlock() {
        let session = makeSession(startBlock: 2)
        session.play()
        engine.emitWord(NSRange(location: 7, length: 4))
        session.stop()
        #expect(session.state == .stopped)
        #expect(session.spokenWord == nil)
        #expect(engine.calls.last == .stop)
        session.play()
        #expect(engine.lastSpoken?.text == "He was born in Ulm.")
    }

    // MARK: - Skipping

    @Test func nextWhilePlayingSpeaksNextBlock() {
        let session = makeSession()
        session.play()
        session.next()
        #expect(session.currentBlock == 1)
        #expect(session.state == .playing)
        #expect(engine.lastSpoken?.text == "Early life")
    }

    @Test func eventsFromInterruptedUtteranceAreIgnored() {
        let session = makeSession()
        session.play()
        let oldID = engine.lastSpoken!.id
        session.next()

        engine.emitWord(NSRange(location: 0, length: 6), id: oldID)
        #expect(session.spokenWord == nil)
        engine.emitFinished(id: oldID)
        #expect(session.currentBlock == 1)  // not advanced to 2
        #expect(engine.spoken.count == 2)
    }

    @Test func skippingWhilePausedStaysPaused() {
        let session = makeSession()
        session.play()
        session.pause()
        session.next()
        #expect(session.state == .paused)
        #expect(session.currentBlock == 1)
        #expect(engine.calls.last == .stop)

        session.play()  // must start the new block, not resume the old one
        #expect(engine.lastSpoken?.text == "Early life")
        #expect(!engine.calls.contains(.resume))
    }

    @Test func skippingWhileStoppedOnlyMoves() {
        let session = makeSession()
        session.next()
        session.next()
        #expect(session.currentBlock == 2)
        #expect(session.state == .stopped)
        #expect(engine.calls.isEmpty)
    }

    @Test func nextAtLastBlockDoesNothing() {
        let session = makeSession(startBlock: 3)
        session.play()
        session.next()
        #expect(session.currentBlock == 3)
        #expect(engine.spoken.count == 1)
    }

    @Test func previousGoesBackAndRestartsFirstBlock() {
        let session = makeSession(startBlock: 1)
        session.play()
        session.previous()
        #expect(session.currentBlock == 0)
        #expect(engine.lastSpoken?.text == "Albert Einstein was a physicist.")
        session.previous()
        #expect(session.currentBlock == 0)
        #expect(engine.spoken.count == 3)  // restarted block 0
    }

    // MARK: - Preparing ahead

    @Test func eachBlockPreparesOnlyTheNextOne() {
        let session = makeSession()
        session.play()
        #expect(engine.prepared == ["Early life"])
        engine.emitFinished()
        #expect(engine.prepared == ["Early life", "He was born in Ulm."])
    }

    @Test func lastBlockPreparesNothing() {
        let session = makeSession(startBlock: 3)
        session.play()
        #expect(engine.prepared.isEmpty)
    }

    // MARK: - Waiting and failures

    @Test func waitsForAudioUntilStarted() {
        let session = makeSession()
        session.play()
        #expect(session.isWaitingForAudio)
        engine.emitStarted()
        #expect(!session.isWaitingForAudio)
    }

    @Test func firstWordAlsoEndsWaiting() {
        let session = makeSession()
        session.play()
        engine.emitWord(NSRange(location: 0, length: 6))
        #expect(!session.isWaitingForAudio)
    }

    @Test func failurePausesAndKeepsThePlace() {
        let session = makeSession(startBlock: 2)
        session.play()
        engine.emitWord(NSRange(location: 7, length: 4))  // "born"
        engine.emitFailed("No network")
        #expect(session.state == .paused)
        #expect(session.failure == SpeechFailure(message: "No network"))
        #expect(!session.isWaitingForAudio)

        session.play()  // retry from the last word heard, as a new utterance
        #expect(session.failure == nil)
        #expect(engine.lastSpoken?.startOffset == 7)
        #expect(!engine.calls.contains(.resume))
    }

    @Test func staleFailureIsIgnored() {
        let session = makeSession()
        session.play()
        let oldID = engine.lastSpoken!.id
        session.next()
        engine.emitFailed("Late error", id: oldID)
        #expect(session.state == .playing)
        #expect(session.failure == nil)
    }

    // MARK: - Switching engines

    @Test func replacingAfterFailureContinuesWithNewEngine() {
        let session = makeSession(startBlock: 2)
        session.play()
        engine.emitWord(NSRange(location: 7, length: 4))
        engine.emitFailed("No network")

        let fallback = FakeSpeechEngine()
        session.replaceEngine(fallback)
        #expect(session.failure == nil)
        #expect(session.state == .paused)
        session.play()
        #expect(fallback.lastSpoken?.startOffset == 7)
        #expect(fallback.lastSpoken?.text == "He was born in Ulm.")
    }

    @Test func replacingWhilePlayingSwitchesImmediately() {
        let session = makeSession(startBlock: 2)
        session.play()
        engine.emitWord(NSRange(location: 7, length: 4))
        let oldID = engine.lastSpoken!.id

        let fallback = FakeSpeechEngine()
        session.replaceEngine(fallback)
        #expect(engine.calls.last == .stop)
        #expect(fallback.lastSpoken?.startOffset == 7)
        #expect(session.isPlaying)

        engine.onEvent?(.finished(id: oldID))  // the old engine is detached
        #expect(session.currentBlock == 2)
    }

    // MARK: - Position set from scrolling

    @Test func scrolledPositionAppliesWhenStopped() {
        var saved: [Int] = []
        let session = makeSession()
        session.onBlockChange = { saved.append($0) }
        session.moveWhileStopped(to: 3)
        #expect(session.currentBlock == 3)
        #expect(saved == [3])
        session.play()
        #expect(engine.lastSpoken?.text == "He moved to Munich.")
    }

    @Test func scrolledPositionIsIgnoredWhilePlayingOrPaused() {
        let session = makeSession()
        session.play()
        session.moveWhileStopped(to: 3)
        #expect(session.currentBlock == 0)
        session.pause()
        session.moveWhileStopped(to: 3)
        #expect(session.currentBlock == 0)
        session.play()
        #expect(engine.calls.last == .resume)
    }

    @Test func scrolledPositionOutOfRangeIsIgnored() {
        let session = makeSession()
        session.moveWhileStopped(to: 42)
        #expect(session.currentBlock == 0)
    }

    // MARK: - Speed

    @Test func rateChangeWhilePlayingRestartsAtCurrentWord() {
        let session = makeSession(startBlock: 2)
        session.play()
        engine.emitWord(NSRange(location: 7, length: 4))  // "born"
        session.setRate(.fast)

        // The whole block is passed with a start offset, so cloud engines can reuse its audio.
        #expect(engine.lastSpoken?.text == "He was born in Ulm.")
        #expect(engine.lastSpoken?.startOffset == 7)
        #expect(engine.lastSpoken?.rate == .fast)
        engine.emitWord(NSRange(location: 12, length: 2))  // "in"
        #expect(session.spokenWord == .init(block: 2, range: NSRange(location: 12, length: 2)))
    }

    @Test func rateChangeWhilePausedAppliesOnPlay() {
        let session = makeSession(startBlock: 2)
        session.play()
        engine.emitWord(NSRange(location: 7, length: 4))
        session.pause()
        session.setRate(.slow)
        #expect(session.state == .paused)
        #expect(engine.calls.last == .stop)

        session.play()
        #expect(engine.lastSpoken?.text == "He was born in Ulm.")
        #expect(engine.lastSpoken?.startOffset == 7)
        #expect(engine.lastSpoken?.rate == .slow)
    }

    @Test func rateChangeWhileStoppedAppliesToNextPlay() {
        let session = makeSession()
        session.setRate(.faster)
        #expect(engine.calls.isEmpty)
        session.play()
        #expect(engine.lastSpoken?.rate == .faster)
    }

    @Test func rateStaysForFollowingBlocks() {
        let session = makeSession()
        session.play()
        session.setRate(.slow)
        engine.emitFinished()
        #expect(engine.lastSpoken?.text == "Early life")
        #expect(engine.lastSpoken?.rate == .slow)
    }
}
