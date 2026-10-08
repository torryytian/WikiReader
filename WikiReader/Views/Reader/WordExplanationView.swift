import OSLog
import SwiftUI

/// Loads the AI explanation of one word in its sentence. One request per sheet; "Try Again" asks again.
@Observable
final class WordExplanationModel {
    enum State: Equatable {
        case loading
        case loaded(WordExplanation)
        case failed(OpenAIChatError)
    }

    let word: String
    let sentence: String
    private(set) var state = State.loading

    private let client: OpenAIExplainClient
    private let apiKey: () -> String?
    private var task: Task<Void, Never>?

    init(
        word: String, sentence: String,
        client: OpenAIExplainClient = OpenAIExplainClient(),
        apiKey: @escaping () -> String? = { KeychainStore.openAIKey.read() }
    ) {
        self.word = word
        self.sentence = sentence
        self.client = client
        self.apiKey = apiKey
    }

    func load() {
        task?.cancel()
        state = .loading
        guard let key = apiKey(), !key.isEmpty else {
            state = .failed(.missingKey)
            return
        }
        Log.lookup.info("Asking AI to explain \(self.word, privacy: .public)")
        task = Task {
            let result = await fetch(key: key)
            guard !Task.isCancelled else { return }
            state = result
        }
    }

    private func fetch(key: String) async -> State {
        do {
            return .loaded(try await client.explain(word: word, sentence: sentence, apiKey: key))
        } catch {
            Log.lookup.error("AI explanation failed: \(error.message, privacy: .public)")
            return .failed(error)
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// The sheet opened by the AI button on the dictionary screen.
struct WordExplanationView: View {
    @State var model: WordExplanationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Asking AI…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let explanation):
                    ExplanationContent(model: model, explanation: explanation)
                case .failed(let error):
                    failureView(error)
                }
            }
            .navigationTitle(model.word)
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

private struct ExplanationContent: View {
    let model: WordExplanationModel
    let explanation: WordExplanation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(explanation.partOfSpeech)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(explanation.meaning)
                        .font(.title2.weight(.semibold))
                    Text(explanation.explanation)
                }

                section("In this sentence") {
                    Text(model.sentence)
                    Text(explanation.sentenceTranslation)
                        .foregroundStyle(.secondary)
                }

                section("Examples") {
                    ForEach(explanation.examples, id: \.english) { example in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(example.english)
                            Text(example.chinese)
                                .foregroundStyle(.secondary)
                        }
                    }
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

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}
