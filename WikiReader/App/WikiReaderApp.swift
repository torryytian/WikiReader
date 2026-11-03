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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LibraryView()
            .preferredColorScheme(appearance.colorScheme)
            .onAppear {
                appearance.apply()
                // Audio generated while offline or before quitting is uploaded now, and again whenever the
                // connection changes (uploads may be waiting for Wi-Fi).
                DriveAudioStore.shared.pumpUploads()
                NetworkWatcher.shared.onChange = { DriveAudioStore.shared.pumpUploads() }
                // The word book: the dictionary's base forms for marking related words, and a sync with Drive a
                // few seconds after each change.
                VocabLemmas.shared.load()
                VocabularyBook.shared.onLocalChange = { VocabSync.shared.scheduleSync() }
            }
            .onChange(of: appearance) { _, new in new.apply() }
            // Coming to the front (launch included): words saved on other devices or in Chrome come in.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { Task { await VocabSync.shared.sync() } }
            }
    }
}
