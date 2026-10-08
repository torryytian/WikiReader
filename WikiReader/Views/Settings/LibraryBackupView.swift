import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Export the library to one file (to AirDrop or keep in Files) and import it again, on this or another iPhone.
struct LibraryBackupView: View {
    @Query(sort: \Article.addedAt, order: .reverse) private var articles: [Article]
    @Environment(\.modelContext) private var modelContext

    /// Titles left out of the export; everything is included by default.
    @State private var excluded: Set<PersistentIdentifier> = []
    @State private var includesAudio = true
    @State private var estimate: Estimate?
    @State private var isWorking = false
    @State private var shareFile: ShareFile?
    @State private var isChoosingFile = false
    @State private var alert: BackupAlert?

    private struct Estimate: Equatable {
        var audioFiles: Int
        var bytes: Int64
    }

    private struct ShareFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private struct BackupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var selectedArticles: [Article] {
        articles.filter { !excluded.contains($0.persistentModelID) }
    }

    var body: some View {
        Form {
            exportSection
            importSection
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: EstimateInput(excluded: excluded, includesAudio: includesAudio, count: articles.count)) {
            estimate = computeEstimate()
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(url: file.url)
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.data]) { result in
            handleImport(result)
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Export

    private struct EstimateInput: Equatable {
        var excluded: Set<PersistentIdentifier>
        var includesAudio: Bool
        var count: Int
    }

    private var exportSection: some View {
        Section {
            ForEach(articles) { article in
                Toggle(article.title, isOn: Binding(
                    get: { !excluded.contains(article.persistentModelID) },
                    set: { isOn in
                        if isOn { excluded.remove(article.persistentModelID) } else { excluded.insert(article.persistentModelID) }
                    }
                ))
            }
            Toggle("Include audio", isOn: $includesAudio)
            Button {
                export()
            } label: {
                HStack {
                    Label("Export Backup…", systemImage: "square.and.arrow.up")
                    Spacer()
                    if let estimate, estimate.bytes > 0 {
                        Text(Self.sizeText(estimate.bytes))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(selectedArticles.isEmpty)
        } header: {
            Text("Export")
        } footer: {
            Text(exportFooter)
        }
    }

    private var exportFooter: String {
        var text = "One file with the chosen articles, where you stopped reading, saved words and settings. "
        if includesAudio {
            let count = estimate?.audioFiles ?? 0
            text += count > 0
                ? "\(count) audio clips already generated for these articles are included, so another iPhone doesn't pay for them again. "
                : "None of these articles has OpenAI audio generated yet. "
        }
        return text + "Your OpenAI key is never included."
    }

    private func computeEstimate() -> Estimate {
        let snapshot = LibraryBackup.snapshot(of: selectedArticles, includeAudio: includesAudio)
        return Estimate(
            audioFiles: snapshot.files.filter { $0.path.hasPrefix(LibraryBackup.audioFolder) }.count,
            bytes: snapshot.totalBytes
        )
    }

    private func export() {
        let snapshot = LibraryBackup.snapshot(of: selectedArticles, includeAudio: includesAudio)
        let name = "WikiReader-\(Date.now.formatted(.iso8601.year().month().day())).\(LibraryBackup.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        isWorking = true
        Task {
            let result = await Self.write(snapshot, to: url)
            isWorking = false
            switch result {
            case .success:
                Log.app.info("Backup written: \(snapshot.library.articles.count) articles, \(snapshot.files.count) files")
                shareFile = ShareFile(url: url)
            case .failure(let error):
                alert = BackupAlert(title: "Export Failed", message: error.message)
            }
        }
    }

    /// A separate function, so the typed error is caught where its type is known.
    private static func write(_ snapshot: BackupSnapshot, to url: URL) async -> Result<Void, BackupError> {
        do {
            try await LibraryBackup.write(snapshot, to: url)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                isChoosingFile = true
            } label: {
                Label("Import Backup…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Import")
        } footer: {
            Text("Choose a .wikireader file from Files or AirDrop. Articles you already have are kept as they are and only gain the saved words they lacked. On a fresh install the backup's settings are applied too.")
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let appliesSettings = articles.isEmpty
        isWorking = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let outcome = await runImport(from: url, appliesSettings: appliesSettings)
            isWorking = false
            switch outcome {
            case .success(let report):
                alert = BackupAlert(title: "Backup Imported", message: Self.summary(of: report))
            case .failure(let error):
                alert = BackupAlert(title: "Import Failed", message: error.message)
            }
        }
    }

    private func runImport(from url: URL, appliesSettings: Bool) async -> Result<ImportReport, BackupError> {
        let library: LibraryExport
        do {
            library = try await LibraryBackup.readLibrary(from: url)
        } catch {
            return .failure(error)
        }
        var report: ImportReport
        do {
            report = try LibraryBackup.merge(library, into: modelContext, applySettings: appliesSettings)
        } catch {
            return .failure(.io(error.localizedDescription))
        }
        do {
            let copied = try await LibraryBackup.copyCaches(from: url)
            report.audioFiles = copied.audio
            report.translations = copied.translations
        } catch {
            return .failure(error)
        }
        Log.app.info("Backup imported: \(report.articlesAdded) added, \(report.articlesMerged) merged")
        return .success(report)
    }

    static func summary(of report: ImportReport) -> String {
        var lines: [String] = []
        lines.append("\(report.articlesAdded) new articles, \(report.articlesMerged) already here.")
        if report.wordsAdded > 0 { lines.append("\(report.wordsAdded) saved words added.") }
        if report.audioFiles > 0 { lines.append("\(report.audioFiles) audio clips added.") }
        if report.translations > 0 { lines.append("\(report.translations) translations added.") }
        if report.appliedSettings { lines.append("Settings applied.") }
        return lines.joined(separator: "\n")
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The system share sheet (AirDrop, Save to Files, …) for one file.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
