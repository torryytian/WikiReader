import UIKit

/// Keeps the screen from locking while long work runs that would stop if the app were suspended (a batch download,
/// uploads to Google Drive). Each piece of work holds its own reason, so one finishing doesn't let the screen lock
/// while another still needs it.
enum ScreenAwake {
    private static var reasons: Set<String> = []

    static func set(_ reason: String, _ isNeeded: Bool) {
        if isNeeded { reasons.insert(reason) } else { reasons.remove(reason) }
        let keepOn = !reasons.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != keepOn {
            UIApplication.shared.isIdleTimerDisabled = keepOn
        }
    }
}
