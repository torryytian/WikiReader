import AVFoundation
import Observation
import OSLog
import UIKit

/// One line of the playback log.
nonisolated struct PlaybackEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    /// Short label of where it came from: "play", "pause", "engine", "clip", "stall", "session", "route", "app"…
    var kind: String
    var detail: String
}

/// A log of what the reader and the audio system did, kept on this device so that a stretch of silence after
/// Pause → Play can be looked at afterwards: every pause, play and skip with the player's and audio session's state,
/// the system's interruptions and route changes, and when the app went to the background.
/// Only the newest `limit` events are kept. It records nothing under tests.
///
/// Everything here runs on the main actor (the reader, the engines and the notification observers all do),
/// so events are in the order they happened and nothing needs a lock.
@MainActor
@Observable
final class PlaybackLog {
    static let standard = PlaybackLog(
        fileURL: URL.applicationSupportDirectory.appending(path: "Diagnostics/playback-events.json"),
        isEnabled: !OpenAICallLog.isRunningTests
    )

    private(set) var events: [PlaybackEvent]
    let isEnabled: Bool
    private let fileURL: URL
    private let limit: Int
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(fileURL: URL, isEnabled: Bool = true, limit: Int = 600) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
        self.limit = limit
        if isEnabled, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([PlaybackEvent].self, from: data) {
            events = saved
        } else {
            events = []
        }
    }

    func record(_ kind: String, _ detail: String = "", at date: Date = .now) {
        guard isEnabled else { return }
        events.append(PlaybackEvent(date: date, kind: kind, detail: detail))
        if events.count > limit { events.removeFirst(events.count - limit) }
        Log.speech.info("[\(kind, privacy: .public)] \(detail, privacy: .public)")
        scheduleSave()
    }

    func clear() {
        events = []
        save()
    }

    /// Writes soon, and at most about once a second however many events come in.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            pendingSave = nil
            save()
        }
    }

    /// Writes now (also when the app is about to be suspended, so the end of the log isn't lost).
    func save() {
        guard isEnabled else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(events).write(to: fileURL, options: .atomic)
    }

    /// Plain text for pasting into a message: newest last, with the time of day to the millisecond.
    func report(now: Date = .now) -> String {
        Self.report(events: events, now: now)
    }

    nonisolated static func report(events: [PlaybackEvent], now: Date) -> String {
        let device = "iOS \(UIDevice.current.systemVersion)"
        var lines = ["WikiReader playback log", "Created \(now.formatted(.iso8601)), \(device), \(events.count) events", ""]
        let formatter = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().second()
        for event in events {
            let time = event.date.formatted(formatter) + String(format: ".%03d", Int(event.date.timeIntervalSince1970 * 1000) % 1000)
            lines.append("\(time)  \(event.kind.padding(toLength: 8, withPad: " ", startingAt: 0))  \(event.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

/// A one-line description of the audio session and where sound is going, for log entries.
@MainActor
enum AudioDiagnostics {
    static func sessionSummary() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "session[\(short(session.category.rawValue))/\(short(session.mode.rawValue)) otherAudio=\(session.isOtherAudioPlaying) "
            + "silenceHint=\(session.secondaryAudioShouldBeSilencedHint) vol=\(String(format: "%.2f", session.outputVolume)) "
            + "out=\(outputs.isEmpty ? "none" : outputs)]"
    }

    /// "AVAudioSessionCategoryPlayback" → "Playback".
    private static func short(_ name: String) -> String {
        name.replacingOccurrences(of: "AVAudioSessionCategory", with: "").replacingOccurrences(of: "AVAudioSessionMode", with: "")
    }

    static func clipSummary(_ clip: AudioClip?) -> String {
        guard let clip else { return "clip[none]" }
        return String(format: "clip[playing=%@ t=%.2f/%.2f rate=%.2f]", String(clip.isPlaying), clip.currentTime, clip.duration, clip.rate)
    }
}

/// Writes the system's audio and app lifecycle notifications into the playback log, whoever is listening
/// to them: an interruption that never reaches the reader still shows up.
@MainActor
final class AudioSessionMonitor {
    static let shared = AudioSessionMonitor()
    private var started = false
    private var observers: [NSObjectProtocol] = []

    func start(log: PlaybackLog = .standard) {
        guard !started, log.isEnabled else { return }
        started = true
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            // Delivered on the main queue, so it is safe to say we are on the main actor.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated { handler(note) }
            })
        }

        observe(AVAudioSession.interruptionNotification) { note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            var detail = type == .began ? "began" : "ended"
            if let raw = info?[AVAudioSessionInterruptionReasonKey] as? UInt,
               let reason = AVAudioSession.InterruptionReason(rawValue: raw) {
                detail += " reason=\(Self.describe(reason))"
            }
            if let raw = info?[AVAudioSessionInterruptionOptionKey] as? UInt {
                detail += " shouldResume=\(AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume))"
            }
            log.record("session", "interruption \(detail) \(AudioDiagnostics.sessionSummary())")
        }
        observe(AVAudioSession.routeChangeNotification) { note in
            let info = note.userInfo
            let reason = (info?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = (info?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",") ?? "?"
            log.record("route", "change reason=\(reason.map(Self.describe) ?? "?") previous=\(previous) \(AudioDiagnostics.sessionSummary())")
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { _ in log.record("session", "media services were LOST") }
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in log.record("session", "media services were RESET") }
        observe(AVAudioSession.silenceSecondaryAudioHintNotification) { note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            log.record("session", "silence-secondary-audio hint \(raw == 1 ? "begin" : "end")")
        }
        for (name, label) in [
            (UIApplication.willResignActiveNotification, "will resign active"),
            (UIApplication.didEnterBackgroundNotification, "entered background"),
            (UIApplication.willEnterForegroundNotification, "entering foreground"),
            (UIApplication.didBecomeActiveNotification, "became active"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "screen locking"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "screen unlocked"),
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING"),
        ] {
            observe(name) { _ in
                log.record("app", "\(label) \(AudioDiagnostics.sessionSummary())")
                if name == UIApplication.didEnterBackgroundNotification || name == UIApplication.willResignActiveNotification { log.save() }
            }
        }
        log.record("app", "launched \(AudioDiagnostics.sessionSummary())")
    }

    private static func describe(_ reason: AVAudioSession.InterruptionReason) -> String {
        switch reason {
        case .default: "default"
        case .appWasSuspended: "appWasSuspended"
        case .builtInMicMuted: "builtInMicMuted"
        case .routeDisconnected: "routeDisconnected"
        @unknown default: "unknown(\(reason.rawValue))"
        }
    }

    private static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "other(\(reason.rawValue))"
        }
    }
}
