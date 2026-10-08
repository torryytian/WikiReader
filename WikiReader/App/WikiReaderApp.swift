import OSLog
import SwiftData
import SwiftUI

@main
struct WikiReaderApp: App {
    @AppStorage(SettingsKeys.appAppearance) private var appearance = AppAppearance.system

    init() {
        Log.app.info("App launched")
        DictionaryLookup.prepareLemmaModel()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { appearance.apply() }
                .onChange(of: appearance) { _, new in new.apply() }
        }
        .modelContainer(for: Article.self)
    }
}
