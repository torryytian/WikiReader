import SwiftData
import SwiftUI

@main
struct WikiReaderApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(for: Article.self)
    }
}
