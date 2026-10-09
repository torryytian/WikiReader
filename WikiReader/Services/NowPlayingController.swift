import MediaPlayer
import NaturalLanguage
import OSLog
import UIKit

/// The sentences around the one being read, for the lock screen.
nonisolated struct LockScreenText: Equatable {
    var previous: String?
    var current: String
    var next: String?
    /// Where the current sentence starts in the block (UTF-16), which tells when the sentence changes.
    var currentStart: Int

    /// - Parameters:
    ///   - text: The block being read.
    ///   - offset: UTF-16 offset of the word being spoken, or the start of the block.
    init?(block text: String, offset: Int) {
        let sentences = Self.sentenceRanges(of: text)
        guard !sentences.isEmpty else { return nil }
        let ns = text as NSString
        let location = min(max(offset, 0), max(ns.length - 1, 0))
        let index = sentences.lastIndex { $0.location <= location } ?? 0

        func trimmed(_ range: NSRange) -> String {
            ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        current = trimmed(sentences[index])
        currentStart = sentences[index].location
        previous = index > 0 ? trimmed(sentences[index - 1]) : nil
        next = index + 1 < sentences.count ? trimmed(sentences[index + 1]) : nil
    }

    static func sentenceRanges(of text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(NSRange(range, in: text))
            return true
        }
        return ranges
    }
}

/// Draws the lock screen picture: the sentence being read, with the ones before and after it dimmed. The lock
/// screen shows an app's artwork large, and it is the one place there is room for text, so the text goes there.
enum LockScreenArtwork {
    static func image(for text: LockScreenText, header: String, side: CGFloat = 720) -> UIImage {
        let size = CGSize(width: side, height: side)
        let margin = side * 0.075
        let bodyRect = CGRect(x: margin, y: margin * 2.6, width: side - margin * 2, height: side - margin * 4.2)

        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1), UIColor(red: 0.20, green: 0.17, blue: 0.15, alpha: 1)]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])

            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.04, weight: .semibold),
                .foregroundColor: UIColor(white: 1, alpha: 0.5),
            ]
            let headerStyle = NSMutableParagraphStyle()
            headerStyle.lineBreakMode = .byTruncatingTail
            var headerWithStyle = headerAttributes
            headerWithStyle[.paragraphStyle] = headerStyle
            (header as NSString).draw(in: CGRect(x: margin, y: margin, width: side - margin * 2, height: side * 0.06), withAttributes: headerWithStyle)

            // The largest type that fits, so a short sentence is easy to read and a long one still shows whole.
            var fontSize = side * 0.075
            var attributed = body(text, fontSize: fontSize)
            while fontSize > side * 0.034, attributed.boundingRect(
                with: CGSize(width: bodyRect.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil
            ).height > bodyRect.height {
                fontSize -= side * 0.004
                attributed = body(text, fontSize: fontSize)
            }
            // Centered vertically in the space below the header; only a very long text reaches the truncation.
            let height = min(bodyRect.height, attributed.boundingRect(
                with: CGSize(width: bodyRect.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil
            ).height.rounded(.up))
            let area = CGRect(x: bodyRect.minX, y: bodyRect.minY + (bodyRect.height - height) / 2, width: bodyRect.width, height: height)
            attributed.draw(with: area, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }

    private static func body(_ text: LockScreenText, fontSize: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.2
        style.paragraphSpacing = fontSize * 0.7
        style.lineBreakMode = .byWordWrapping

        func part(_ string: String, current: Bool) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: UIFont.systemFont(ofSize: current ? fontSize : fontSize * 0.78, weight: current ? .semibold : .regular),
                .foregroundColor: UIColor(white: 1, alpha: current ? 1 : 0.42),
                .paragraphStyle: style,
            ])
        }

        let result = NSMutableAttributedString()
        if let previous = text.previous { result.append(part(previous + "\n", current: false)) }
        result.append(part(text.current + (text.next == nil ? "" : "\n"), current: true))
        if let next = text.next { result.append(part(next, current: false)) }
        return result
    }
}

/// Keeps reading going with the screen locked and shows it on the lock screen and in Control Center, like a music
/// player: the sentence being read (as the title and in the artwork), play/pause, previous and next paragraph, and
/// back/forward 10 seconds. It follows a `ReadingSession` and sends nothing to it except what the buttons ask for.
///
/// It does not rely on SwiftUI to hear about changes: with the screen locked the views aren't updated, but the
/// session keeps running, so this watches the session directly.
@MainActor
final class NowPlayingController {
    /// The controller that owns the lock screen now. When one article gives way to the next, the old reader's
    /// cleanup may run after the new reader has started; it must not clear what the new one has set.
    private static weak var active: NowPlayingController?

    private let session: ReadingSession
    private let blocks: [ContentBlock]
    private let articleTitle: String
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var isTracking = true

    private var shownSentence: String?
    private var shownState: ReadingSession.State?
    private var shownRate: SpeechRate?
    private var artwork: MPMediaItemArtwork?

    init(session: ReadingSession, blocks: [ContentBlock], title: String) {
        self.session = session
        self.blocks = blocks
        self.articleTitle = title
        Self.active = self
        registerCommands()
        observeAudioEvents()
        track()
        refresh()
    }

    func teardown() {
        isTracking = false
        for target in targets { target.command.removeTarget(target.token) }
        targets = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if Self.active === self {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    // MARK: - Buttons

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { $0.session.play() }
        add(center.pauseCommand) { $0.session.pause() }
        add(center.togglePlayPauseCommand) { $0.session.togglePlayPause() }
        add(center.nextTrackCommand) { $0.session.next() }
        add(center.previousTrackCommand) { $0.session.previous() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { $0.session.skip(seconds: 10) }
        add(center.skipBackwardCommand) { $0.session.skip(seconds: -10) }
        // Speech can't be scrubbed to an exact time, so the lock screen's slider is only a display.
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NowPlayingController) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        targets.append((command, token))
    }

    /// A phone call or an alarm pauses reading; so does unplugging the headphones.
    private func observeAudioEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            Task { @MainActor [weak self] in self?.session.pause() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in self?.session.pause() }
        })
    }

    // MARK: - What the lock screen shows

    /// Runs `refresh` whenever the session changes, then watches again.
    private func track() {
        guard isTracking else { return }
        withObservationTracking {
            _ = session.state
            _ = session.currentBlock
            _ = session.rate
            _ = session.spokenWord
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                self.refresh()
                self.track()
            }
        }
    }

    private func refresh() {
        guard Self.active === self, blocks.indices.contains(session.currentBlock) else { return }
        let block = session.currentBlock
        let offset = session.spokenWord?.range.location ?? 0
        guard let text = LockScreenText(block: blocks[block].text, offset: offset) else { return }

        let sentenceKey = "\(block):\(text.currentStart)"
        guard sentenceKey != shownSentence || session.state != shownState || session.rate != shownRate else { return }
        let sentenceChanged = sentenceKey != shownSentence
        shownSentence = sentenceKey
        shownState = session.state
        shownRate = session.rate

        if sentenceChanged || artwork == nil {
            let image = LockScreenArtwork.image(for: text, header: articleTitle)
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        // Duration and position are estimates (characters at an average speaking speed), shown as article progress.
        let speed = ReadingSession.charactersPerSecond * session.rate.rawValue
        let lengths = blocks.map(\.text.count)
        let total = lengths.reduce(0, +)
        let done = lengths.prefix(block).reduce(0, +) + offset

        let section = blocks.prefix(block + 1).last { $0.kind == .heading }?.text
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: text.current,
            MPMediaItemPropertyArtist: articleTitle,
            MPMediaItemPropertyAlbumTitle: section ?? articleTitle,
            MPMediaItemPropertyPlaybackDuration: Double(total) / speed,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(done) / speed,
            MPNowPlayingInfoPropertyPlaybackRate: session.state == .playing ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = switch session.state {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }
}
