import Foundation

/// What happens when an article has been read to the end.
nonisolated enum PlaybackMode: String, CaseIterable, Sendable {
    /// Go on with the next article in the library, and stop after the last one.
    case sequential
    /// Start this article again.
    case loop
    /// Go on with a random other article.
    case shuffle

    var label: String {
        switch self {
        case .sequential: "Sequential"
        case .loop: "Loop"
        case .shuffle: "Shuffle"
        }
    }

    var detail: String {
        switch self {
        case .sequential: "All articles, in library order"
        case .loop: "This article, again and again"
        case .shuffle: "All articles, in random order"
        }
    }

    /// The mode a tap on the mode button switches to: sequential, loop, shuffle, and round again.
    var cycled: PlaybackMode {
        switch self {
        case .sequential: .loop
        case .loop: .shuffle
        case .shuffle: .sequential
        }
    }

    /// Name and scope in one line, for a menu or a message.
    var menuTitle: String {
        switch self {
        case .sequential: "Sequential · All articles"
        case .loop: "Loop · This article"
        case .shuffle: "Shuffle · All articles"
        }
    }

    var symbol: String {
        switch self {
        case .sequential: "arrow.right"
        case .loop: "repeat"
        case .shuffle: "shuffle"
        }
    }

    /// The mode saved in settings.
    static var saved: PlaybackMode {
        UserDefaults.standard.string(forKey: SettingsKeys.playbackMode).flatMap(PlaybackMode.init(rawValue:)) ?? .sequential
    }

    /// What to do after an article ends, given the library's articles in order and the one just finished.
    enum Next: Equatable {
        case restart
        /// Index into `articles` of the article to read next.
        case article(Int)
        case stop
    }

    /// - Parameters:
    ///   - count: Number of articles in the library.
    ///   - index: Position of the finished article in the library.
    ///   - random: Picks a number in `0..<upperBound`; injected so tests are repeatable.
    func next(count: Int, index: Int, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Next {
        switch self {
        case .loop:
            return .restart
        case .sequential:
            return index + 1 < count ? .article(index + 1) : .stop
        case .shuffle:
            // With only one article there is nothing else to pick: read it again.
            guard count > 1 else { return .restart }
            let pick = random(count - 1)
            return .article(pick >= index ? pick + 1 : pick)  // any article except this one
        }
    }
}
