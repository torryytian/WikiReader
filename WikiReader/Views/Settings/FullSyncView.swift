import SwiftUI

/// Settling the differences between this iPhone's word book and the website's (docs/vocab-sync-v1.md §5.6), in three
/// screens: what differs, what to do about it, and a last check of what will be deleted. Nothing changes until the
/// last one, and everyday syncing waits meanwhile. Every number comes from the site, so the Chrome extension shows the
/// same ones.
struct FullSyncView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case comparing
        case failed(String)
        case compared(VocabSyncPreview)
        case finished(VocabFullSyncOutcome)
        case undone(addedToSite: Bool, skipped: Int)
    }

    private enum Page: Hashable {
        case choose
        case confirm(VocabSyncOption)
    }

    private enum Direction {
        case bothWays, siteToDevice, deviceToSite
    }

    private enum Mode {
        case addMissing, replace
    }

    private let sync: VocabSiteSync

    @State private var stage = Stage.comparing
    @State private var path: [Page] = []
    @State private var direction = Direction.bothWays
    @State private var mode = Mode.addMissing
    @State private var typedNumber = ""
    @State private var isWorking = false
    @State private var failure: String?
    /// The failure means the comparison is out of date, so closing its alert compares again.
    @State private var comparesAgain = false

    init(sync: VocabSiteSync = .shared) {
        self.sync = sync
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch stage {
                case .comparing:
                    ProgressView("Comparing…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Compare", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await compare() } }
                    }
                case .compared(let preview):
                    differences(preview)
                case .finished(let outcome):
                    finished(outcome)
                case .undone(let addedToSite, let skipped):
                    undone(addedToSite: addedToSite, skipped: skipped)
                }
            }
            .navigationTitle("Full Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isOpenToCancel {
                        Button("Cancel") { dismiss() }
                            .disabled(isWorking)
                    }
                }
            }
            .navigationDestination(for: Page.self) { page in
                if case .compared(let preview) = stage {
                    switch page {
                    case .choose: choose(preview)
                    case .confirm(let option): confirm(preview, option)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .task { await compare() }
        .onDisappear { sync.closeFullSync() }
        .alert("Couldn't Sync", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {
                if comparesAgain {
                    comparesAgain = false
                    Task { await compare() }
                }
            }
        } message: {
            Text(failure ?? "")
        }
    }

    private var isOpenToCancel: Bool {
        switch stage {
        case .finished, .undone: false
        default: true
        }
    }

    private func compare() async {
        path = []
        typedNumber = ""
        stage = .comparing
        do throws(SiteVocabError) {
            stage = .compared(try await sync.startFullSync())
        } catch {
            stage = .failed(error.message)
        }
    }

    private func finish(_ preview: VocabSyncPreview, _ option: VocabSyncOption) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do throws(SiteVocabError) {
                let outcome = try await sync.finishFullSync(preview, option: option)
                path = []
                stage = .finished(outcome)
            } catch {
                comparesAgain = [.changedSincePreview, .previewExpired, .confirmationMismatch].contains(error)
                failure = error.message
            }
        }
    }

    private func undo(_ outcome: VocabFullSyncOutcome) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do throws(SiteVocabError) {
                let skipped = try await sync.undoFullSync(outcome)
                stage = .undone(addedToSite: outcome.undoID != nil, skipped: skipped)
            } catch {
                failure = error.message
            }
        }
    }

    private static func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count) words"
    }

    // MARK: - 1. What differs

    private func differences(_ preview: VocabSyncPreview) -> some View {
        let counts = preview.counts
        let words = preview.words
        return List {
            Section {
                LabeledContent("This device", value: Self.words(counts.device))
                LabeledContent("English Reader", value: Self.words(counts.server))
            }
            if counts.match {
                Section {
                    Label("Both sides have the same words.", systemImage: "checkmark.circle")
                }
            } else {
                Section {
                    wordGroup("Same on both", count: counts.same, words: [])
                    wordGroup(
                        "On both, but different", count: counts.differ,
                        note: counts.differ == 0 ? nil : "newer here \(counts.deviceNewer), newer on the site \(counts.serverNewer)",
                        words: words.differ
                    )
                    wordGroup(
                        "Only on this device", count: counts.deviceOnly + counts.deviceOnlyDeletedOnServer,
                        note: counts.deviceOnlyDeletedOnServer == 0 ? nil : "\(counts.deviceOnlyDeletedOnServer) of them were deleted on the site later",
                        words: words.deviceOnly + words.deviceOnlyDeletedOnServer
                    )
                    wordGroup(
                        "Only on the site", count: counts.serverOnly + counts.serverOnlyDeletedOnDevice,
                        note: counts.serverOnlyDeletedOnDevice == 0 ? nil : "\(counts.serverOnlyDeletedOnDevice) of them you deleted on this device",
                        words: words.serverOnly + words.serverOnlyDeletedOnDevice
                    )
                }
            }
            if let rejected = preview.rejected, !rejected.isEmpty {
                Section {
                    Text(rejected.count == 1
                        ? "1 word can't be compared and stays as it is on both sides."
                        : "\(rejected.count) words can't be compared and stay as they are on both sides.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if counts.match {
                    Button("Done") { finish(preview, .merge) }
                        .disabled(isWorking)
                } else {
                    NavigationLink("Continue", value: Page.choose)
                }
            }
        }
    }

    /// One kind of difference, opening to list its words when there are any to list.
    @ViewBuilder
    private func wordGroup(_ title: String, count: Int, note: String? = nil, words: [VocabSyncPreview.Word]) -> some View {
        let label = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        if words.isEmpty {
            label
        } else {
            DisclosureGroup {
                wordList(words, total: count)
            } label: {
                label
            }
        }
    }

    /// The site lists up to 200 words of a kind.
    @ViewBuilder
    private func wordList(_ words: [VocabSyncPreview.Word], total: Int) -> some View {
        ForEach(words) { word in
            Text(word.term)
        }
        if words.count < total {
            Text("…and \(total - words.count) more")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 2. What to do

    private var chosenOption: VocabSyncOption {
        switch (direction, mode) {
        case (.bothWays, _): .merge
        case (.siteToDevice, .addMissing): .serverToDeviceAdd
        case (.siteToDevice, .replace): .serverToDeviceOverwrite
        case (.deviceToSite, .addMissing): .deviceToServerAdd
        case (.deviceToSite, .replace): .deviceToServerOverwrite
        }
    }

    private func choose(_ preview: VocabSyncPreview) -> some View {
        List {
            Section("Direction") {
                choice("Both ways (recommended)", selected: direction == .bothWays, result: preview.choice(.merge)) {
                    direction = .bothWays
                }
                choice("Site → this device", selected: direction == .siteToDevice) { direction = .siteToDevice }
                choice("This device → site", selected: direction == .deviceToSite) { direction = .deviceToSite }
            }
            if direction != .bothWays {
                Section("How") {
                    choice(
                        "Add missing only", selected: mode == .addMissing,
                        result: preview.choice(direction == .siteToDevice ? .serverToDeviceAdd : .deviceToServerAdd)
                    ) { mode = .addMissing }
                    choice(
                        "Replace completely", selected: mode == .replace,
                        result: preview.choice(direction == .siteToDevice ? .serverToDeviceOverwrite : .deviceToServerOverwrite)
                    ) { mode = .replace }
                }
            }
            Section {
                NavigationLink("Continue", value: Page.confirm(chosenOption))
            }
        }
        .navigationTitle("Choose")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ title: String, selected: Bool, result: VocabSyncPreview.Choice? = nil, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let result {
                        Group {
                            Text("After: this device \(result.device.after) · site \(result.server.after)")
                            Text("This device: \(change(result.device))")
                            Text("Site: \(change(result.server))")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func change(_ side: VocabSyncPreview.Side) -> String {
        side.changesNothing ? "no change" : "+\(side.add)  −\(side.remove)  ✎\(side.update)"
    }

    // MARK: - 3. The last check

    private func summary(of option: VocabSyncOption) -> String {
        switch option {
        case .merge: "Both sides become the same book."
        case .serverToDeviceAdd: "Words only on the site are added to this device. Nothing is deleted."
        case .serverToDeviceOverwrite: "This device becomes exactly the same as English Reader."
        case .deviceToServerAdd: "Words only on this device are added to English Reader. Nothing is deleted."
        case .deviceToServerOverwrite: "English Reader becomes exactly the same as this device."
        }
    }

    private func confirm(_ preview: VocabSyncPreview, _ option: VocabSyncOption) -> some View {
        let result = preview.choice(option)
        let removedHere = result?.device.remove ?? 0
        let removedOnSite = result?.server.remove ?? 0
        let needsNumber = removedOnSite > 0 && typedNumber.trimmingCharacters(in: .whitespaces) != String(removedOnSite)
        return List {
            Section {
                Text(summary(of: option))
                if let result {
                    Text("After: this device \(result.device.after) · site \(result.server.after)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if removedHere > 0 {
                Section {
                    wordList(preview.wordsRemovedHere(by: option), total: removedHere)
                } header: {
                    warning("\(Self.words(removedHere)) will be removed from this device")
                }
            }
            if removedOnSite > 0 {
                Section {
                    wordList(preview.wordsRemovedOnSite(by: option), total: removedOnSite)
                } header: {
                    warning("\(Self.words(removedOnSite)) will be deleted from English Reader, and from your other devices when they sync. You can undo this for 30 days on the website.")
                }
                Section("Type \(removedOnSite) to confirm") {
                    TextField("\(removedOnSite)", text: $typedNumber)
                        .keyboardType(.numberPad)
                }
            }
            Section {
                Button(removedHere + removedOnSite > 0 ? "Remove \(removedHere + removedOnSite) and sync" : "Sync", role: removedHere + removedOnSite > 0 ? .destructive : nil) {
                    finish(preview, option)
                }
                .disabled(isWorking || needsNumber)
            }
        }
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
            .foregroundStyle(.red)
    }

    // MARK: - Afterwards

    private func finished(_ outcome: VocabFullSyncOutcome) -> some View {
        List {
            Section {
                Label("Word book synced", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("This device", value: Self.words(outcome.deviceWords))
                LabeledContent("English Reader", value: Self.words(outcome.siteWords))
            }
            if outcome.canUndo {
                Section {
                    Button("Undo") { undo(outcome) }
                        .disabled(isWorking)
                } footer: {
                    Text(outcome.undoID == nil
                        ? "Puts this iPhone's words back as they were."
                        : "Puts this iPhone's words back, and what the website deleted or changed. Words added to the website stay there. You can also undo this on the website for 30 days.")
                }
            }
            Section {
                Button("Done") { dismiss() }
                    .disabled(isWorking)
            }
        }
    }

    private func undone(addedToSite: Bool, skipped: Int) -> some View {
        List {
            Section {
                Label("Undone", systemImage: "arrow.uturn.backward.circle.fill")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This iPhone's words are back as they were.")
                    if addedToSite {
                        Text("Words this sync added to the website stay there.")
                    }
                    if skipped > 0 {
                        Text(skipped == 1
                            ? "1 word changed on the website since, and was left as it is."
                            : "\(skipped) words changed on the website since, and were left as they are.")
                    }
                }
            }
            Section {
                Button("Done") { dismiss() }
            }
        }
    }
}
