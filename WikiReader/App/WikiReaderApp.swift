import OSLog
import SwiftData
import SwiftUI

@main
struct WikiReaderApp: App {
    init() {
        Log.app.info("App launched")
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(for: Article.self)
    }
}
