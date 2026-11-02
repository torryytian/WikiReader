import OSLog
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Text ready to be reviewed before it becomes an article.
struct ImportDraft: Identifiable {
    let id = UUID()
    var text: String
    /// Used as the title when the text has no `# Title` of its own.
    var suggestedTitle: String
}

/// Drives importing an article from a file, photos or the clipboard: choosing, extracting text, then the review sheet.
@Observable
@MainActor
final class ArticleImportCoordinator {
    var isChoosingFile = false
    var isChoosingPhotos = false
    var photoSelection: [PhotosPickerItem] = []
    private(set) var isWorking = false
    var draft: ImportDraft?
    var errorMessage: String?

    /// From the file picker.
    func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            run {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return await Self.extract(fileAt: url)
            }
        }
    }

    /// From the photo picker: the pictures in the order they were chosen.
    func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        run {
            var pictures: [Data] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    return .failure(.unreadable("a photo couldn't be loaded"))
                }
                pictures.append(data)
            }
            return await Self.extract(photos: pictures)
        }
    }

    /// Opens the review sheet with whatever text is on the clipboard (possibly none: the text can be typed there).
    func paste() {
        draft = ImportDraft(text: UIPasteboard.general.string ?? "", suggestedTitle: "Pasted Article")
    }

    private func run(_ work: @escaping () async -> Result<ExtractedText, ImportFileError>) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let result = await work()
            isWorking = false
            photoSelection = []
            switch result {
            case .success(let extracted):
                Log.importing.info("Extracted \(extracted.text.count) characters from an import")
                draft = ImportDraft(text: extracted.text, suggestedTitle: extracted.suggestedTitle)
            case .failure(let error):
                Log.importing.error("Import extraction failed: \(String(describing: error), privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Separate functions, so the typed error from the extractor is caught where its type is known.
    private static func extract(fileAt url: URL) async -> Result<ExtractedText, ImportFileError> {
        do {
            return .success(try await FileTextExtractor.extract(from: url))
        } catch {
            return .failure(error)
        }
    }

    private static func extract(photos: [Data]) async -> Result<ExtractedText, ImportFileError> {
        do {
            let title = "Photos " + Date.now.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            return .success(try await FileTextExtractor.extract(imageData: photos, title: title))
        } catch {
            return .failure(error)
        }
    }
}

extension View {
    /// The pickers, progress, error and review sheet for importing articles, driven by `coordinator`.
    func articleImport(_ coordinator: ArticleImportCoordinator, onAdded: @escaping (Article) -> Void) -> some View {
        modifier(ArticleImportModifier(coordinator: coordinator, onAdded: onAdded))
    }
}

private struct ArticleImportModifier: ViewModifier {
    @Bindable var coordinator: ArticleImportCoordinator
    var onAdded: (Article) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $coordinator.isChoosingFile, allowedContentTypes: FileTextExtractor.allowedTypes) {
                coordinator.importFile($0)
            }
            .photosPicker(
                isPresented: $coordinator.isChoosingPhotos, selection: $coordinator.photoSelection,
                maxSelectionCount: 30, matching: .images
            )
            .onChange(of: coordinator.photoSelection) { _, items in
                coordinator.importPhotos(items)
            }
            .sheet(item: $coordinator.draft) { draft in
                ImportDraftView(draft: draft, onAdded: onAdded)
            }
            .overlay {
                if coordinator.isWorking {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Reading text…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Couldn't Import", isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.errorMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(coordinator.errorMessage ?? "")
            }
    }
}

/// Review of the extracted text before it is saved: fix the title or the text (recognition can get a word wrong),
/// see how it will be split, then add it.
struct ImportDraftView: View {
    let draft: ImportDraft
    var onAdded: (Article) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var title: String
    @State private var text: String
    @State private var titleWasEdited = false
    @State private var parsed: ParsedLocalArticle
    @State private var errorMessage: String?

    init(draft: ImportDraft, onAdded: @escaping (Article) -> Void) {
        self.draft = draft
        self.onAdded = onAdded
        let parsed = LocalArticleParser.parse(draft.text)
        _text = State(initialValue: draft.text)
        _parsed = State(initialValue: parsed)
        _title = State(initialValue: parsed.title ?? draft.suggestedTitle)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Title", text: Binding(
                    get: { title },
                    set: { title = $0; titleWasEdited = true }
                ))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Paste or type the text here. A line starting with ## is a section heading.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }

                Divider()
                summary
            }
            .navigationTitle("Review Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(parsed.paragraphCount == 0 || cleanTitle.isEmpty)
                }
            }
            // Parsing a long text on every key press would stutter; wait for a pause in typing.
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                parsed = LocalArticleParser.parse(text)
                if !titleWasEdited { title = parsed.title ?? draft.suggestedTitle }
            }
        }
        .interactiveDismissDisabled(!text.isEmpty && text != draft.text)
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            let sections = parsed.blocks.filter { $0.kind == .heading }.count
            let words = parsed.blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            Text("\(parsed.paragraphCount) \(parsed.paragraphCount == 1 ? "paragraph" : "paragraphs") · \(sections) \(sections == 1 ? "section" : "sections") · \(words.formatted()) words · about \(max(1, Int((Double(words) / 150).rounded()))) min to listen")
                .foregroundStyle(.secondary)
            if parsed.skippedLines > 0 {
                Text("\(parsed.skippedLines) lines of tables or code are left out, since they can't be read aloud.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func add() {
        let result = LocalArticleParser.parse(text)
        guard result.paragraphCount > 0 else {
            errorMessage = "There is no paragraph to read."
            return
        }
        do {
            let article = try save(title: uniqueTitle(cleanTitle), blocks: result.blocks)
            dismiss()
            onAdded(article)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Two different texts can share a title; the second gets "(2)".
    private func uniqueTitle(_ wanted: String) -> String {
        let existing = Set(((try? modelContext.fetch(FetchDescriptor<Article>())) ?? []).map(\.title))
        guard existing.contains(wanted) else { return wanted }
        var number = 2
        while existing.contains("\(wanted) (\(number))") { number += 1 }
        return "\(wanted) (\(number))"
    }

    private func save(title: String, blocks: [ContentBlock]) throws -> Article {
        let article = Article(title: title, sourceURL: Article.importedSourceURL(), blocks: blocks)
        article.origin = Article.importedOrigin
        modelContext.insert(article)
        try modelContext.save()
        Log.importing.info("Saved imported article \(title, privacy: .public) with \(blocks.count) blocks")
        return article
    }
}
