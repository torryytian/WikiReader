import SwiftUI

/// The rows of Settings → English Reader about signing in, which keeps the word book in step with the site.
struct SiteAccountRows: View {
    @State private var account = SiteAccount.shared
    @State private var sync = VocabSiteSync.shared
    @State private var showsFullSync = false
    @State private var confirmsSignOut = false

    var body: some View {
        Group {
            switch account.state {
            case .signedOut:
                SiteSignInButton(title: "Sign In") { showsFullSync = true }
            case .needsSignIn(let user):
                LabeledContent("Account", value: user.email)
                LabeledContent("Word Book") {
                    Label("Sign in again", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                SiteSignInButton(title: "Sign In Again") { showsFullSync = true }
            case .signedIn(let user):
                LabeledContent("Account", value: user.email)
                LabeledContent("Word Book", value: sync.statusText)
                if sync.status != .needsFullSync {
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync Word Book Now")
                            if sync.status == .syncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(sync.status == .syncing)
                }
                Button("Full Sync…") { showsFullSync = true }
                Button("Sign Out", role: .destructive) { confirmsSignOut = true }
            }
        }
        .sheet(isPresented: $showsFullSync) {
            FullSyncView()
        }
        .confirmationDialog("Sign out of English Reader?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await sync.signOut()
                    await VocabSync.shared.sync()  // back to Drive, if that is signed in
                }
            }
        } message: {
            Text("Your words stay on this iPhone, but stop syncing with the website.")
        }
    }
}

/// Signs in to English Reader. `onNeedsFullSync` runs if this iPhone's words now have to be compared with the site's.
struct SiteSignInButton: View {
    let title: String
    let onNeedsFullSync: () -> Void

    @State private var sync = VocabSiteSync.shared
    @State private var isSigningIn = false
    @State private var failure: String?

    var body: some View {
        Button(action: signIn) {
            HStack {
                Text(title)
                if isSigningIn {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isSigningIn)
        .alert("Couldn't Sign In", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func signIn() {
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do throws(SiteAuthError) {
                try await sync.signIn()
                if sync.status == .needsFullSync { onNeedsFullSync() }
            } catch .cancelled {
                // Nothing to say: the user knows.
            } catch {
                failure = error.message
            }
        }
    }
}
