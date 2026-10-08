import OSLog
import SwiftUI

/// Loads the AI translation of one passage. The cache answers first, so a passage translated before
/// shows at once, offline and without a key.
@Observable
final class PassageTranslationModel: Identifiable {
    enum State: Equatable {
        case loading
        case loaded(PassageTranslation)
        case failed(OpenAIChatError)
    }

    let text: String
    private(set) var state = State.loading

    private let client: OpenAITranslateClient
    private let cache: TranslationCache
    private let apiKey: () -> String?
    private var task: Task<Void, Never>?

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    /// Whether only the start of the text is translated.
    var isClipped: Bool { text.count > OpenAITranslateClient.maxLength }

    init(
        text: String,
        client: OpenAITranslateClient = OpenAITranslateClient(),
        cache: TranslationCache = .standard,
        apiKey: @escaping () -> String? = { KeychainStore.openAIKey.read() }
    ) {
        self.text = text
        self.client = client
        self.cache = cache
        self.apiKey = apiKey
    }

    func load() {
        task?.cancel()
        if let cached = cache.cached(for: text) {
            Log.lookup.info("Translation from cache (\(self.text.count) characters)")
            state = .loaded(cached)
            return
        }
        state = .loading
        guard let key = apiKey(), !key.isEmpty else {
            state = .failed(.missingKey)
            return
        }
        Log.lookup.info("Asking AI to translate \(self.text.count) characters")
        task = Task {
            let result = await fetch(key: key)
            guard !Task.isCancelled else { return }
            state = result
        }
    }

    private func fetch(key: String) async -> State {
        do {
            let translation = try await client.translate(text, apiKey: key)
            try? cache.store(translation, for: text)
            return .loaded(translation)
        } catch {
            Log.lookup.error("AI translation failed: \(error.message, privacy: .public)")
            return .failed(error)
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// The sheet that shows a translation: opened from the selection menu or a paragraph's Translate label.
struct TranslationView: View {
    @State var model: PassageTranslationModel
    @State private var showsFullOriginal = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Translating…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let translation):
                    content(translation)
                case .failed(let error):
                    failureView(error)
                }
            }
            .navigationTitle("Translation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { model.load() }
        .onDisappear(perform: model.cancel)
    }

    private func content(_ translation: PassageTranslation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(translation.translation)
                    .font(.title3)
                    .lineSpacing(5)

                if !translation.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Worth Knowing")
                        ForEach(translation.notes, id: \.expression) { note in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.expression).fontWeight(.semibold)
                                Text(note.explanation).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Original")
                    Text(model.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsFullOriginal ? nil : 4)
                        .onTapGesture { showsFullOriginal.toggle() }
                        .accessibilityHint(showsFullOriginal ? "Shows less" : "Shows all")
                }

                if model.isClipped {
                    Text("Only the first \(OpenAITranslateClient.maxLength) characters were translated.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Written by AI, so it can be wrong.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .textSelection(.enabled)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func failureView(_ error: OpenAIChatError) -> some View {
        VStack(spacing: 16) {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if error.isRetryable {
                Button("Try Again", action: model.load)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
