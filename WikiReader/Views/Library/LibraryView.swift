import SwiftUI

/// Home screen: the list of saved articles.
/// Phase 0 placeholder — articles will come from SwiftData in phase 1.
struct LibraryView: View {
    var body: some View {
        NavigationStack {
            List {
                // Saved articles go here.
            }
            .overlay {
                ContentUnavailableView(
                    "No Articles",
                    systemImage: "books.vertical",
                    description: Text("Articles you add will appear here.")
                )
            }
            .navigationTitle("Library")
        }
    }
}

#Preview {
    LibraryView()
}
