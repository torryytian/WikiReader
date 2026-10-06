import OSLog

/// App-wide loggers. View them with Console.app or:
/// `xcrun simctl spawn booted log stream --predicate 'subsystem == "tik.tian.com.WikiReader"'`
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "WikiReader"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let importing = Logger(subsystem: subsystem, category: "Import")
    static let lookup = Logger(subsystem: subsystem, category: "Lookup")
    static let speech = Logger(subsystem: subsystem, category: "Speech")
}
