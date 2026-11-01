import OSLog
import SwiftData
import SwiftUI

@main
struct WikiReaderApp: App {
    init() {
        Log.app.info("App launched")
        DictionaryLookup.prepareLemmaModel()
        AudioSessionMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: Article.self)
    }
}

/// The app's first view. It is a `View` (not the `App`) because only a view reliably re-renders when the
/// appearance setting changes, and it owns applying that setting to every window.
private struct RootView: View {
    @AppStorage(SettingsKeys.appAppearance) private var appearance = AppAppearance.system

    var body: some View {
        LibraryView()
            .preferredColorScheme(appearance.colorScheme)
            .onAppear {
                appearance.apply()
                // Audio generated while offline or before quitting is uploaded now, and again whenever the
                // connection changes (uploads may be waiting for Wi-Fi).
                DriveAudioStore.shared.pumpUploads()
                NetworkWatcher.shared.onChange = { DriveAudioStore.shared.pumpUploads() }
            }
            .onChange(of: appearance) { _, new in new.apply() }
    }
}
