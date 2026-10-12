import OSLog
import SwiftUI

/// What the word card knows about a lookup: the offline entry at once, the online English definitions a moment later.
@Observable
final class WordCardModel {
    enum OnlineState: Equatable {
        case loading
        case loaded(WiktionaryDefinition)
        /// Wiktionary has no English entry for the word.
        case notFound
        /// No answer (offline, timeout…); the offline entry is all there is.
        case unavailable
    }

    let request: WordLookupRequest
    let entry: DictionaryEntry?
    /// The base form's entry when `entry` is an inflection ("studies" → "study").
    let lemmaEntry: DictionaryEntry?
    private(set) var online = OnlineState.loading
    private(set) var isSaved: Bool
    /// The meaning from an AI explanation opened from this card; saved along with the word.
    private(set) var aiMeaning: String?

    private let saving: WordSaving?
    private let client: WiktionaryClient
    private let cache: DefinitionCache
    private let pronouncer: WordPronouncer
    private var task: Task<Void, Never>?

    init(
        request: WordLookupRequest, saving: WordSaving?, voiceIdentifier: String?,
        database: DictionaryDatabase = .bundled, client: WiktionaryClient = WiktionaryClient(), cache: DefinitionCache = .standard
    ) {
        self.request = request
        self.saving = saving
        self.client = client
        self.cache = cache
        isSaved = saving?.isSaved ?? false
        pronouncer = WordPronouncer(voiceIdentifier: voiceIdentifier)
        let entry = database.entry(for: request.term)
        self.entry = entry
        if let lemma = entry?.lemma, lemma.lowercased() != request.term.lowercased() {
            lemmaEntry = database.entry(for: lemma)
        } else {
            lemmaEntry = nil
        }
    }

    /// The word whose English definitions are asked for: the base form when there is one.
    var definitionWord: String { lemmaEntry?.word ?? request.term }

    var canSave: Bool { saving != nil }

    func loadOnlineDefinitions() {
        task?.cancel()
        let word = definitionWord
        if let cached = cache.cached(for: word) {
            online = .loaded(cached)
            return
        }
        online = .loading
        task = Task {
            do {
                let definition = try await client.definition(of: word)
                guard !Task.isCancelled else { return }
                try? cache.store(definition, for: word)
                online = .loaded(definition)
            } catch {
                guard !Task.isCancelled else { return }
                Log.lookup.info("No online definition for \(word, privacy: .public): \(String(describing: error), privacy: .public)")
                online = (error as? WiktionaryError) == .notFound ? .notFound : .unavailable
            }
        }
    }

    func pronounce() {
        pronouncer.pronounce(request.term)
    }

    /// Saves the word, or removes it again. A word saved without an AI explanation keeps the short Chinese meaning
    /// from the dictionary, so the saved-words list isn't left with empty rows.
    func toggleSaved() {
        guard let saving else { return }
        isSaved = saving.toggle(aiMeaning ?? entry?.shortMeaning ?? lemmaEntry?.shortMeaning)
    }

    func didLoadAIMeaning(_ meaning: String) {
        aiMeaning = meaning
        saving?.setMeaning(meaning)
    }

    func stop() {
        task?.cancel()
        pronouncer.stop()
    }
}

/// The dictionary screen shown when a word is tapped: Chinese and English meanings, pronunciation, and the
/// buttons for an AI explanation, saving the word and the system dictionary. It is ordinary SwiftUI inside this
/// app's own process, so a swipe down anywhere on it closes the sheet.
struct WordCardView: View {
    @State var model: WordCardModel
    var onOpenSystemDictionary: @MainActor (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var explanation: WordExplanationModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let entry = model.entry {
                    badges(for: entry)
                    chinese(entry)
                    if let lemma = model.lemmaEntry { formOf(lemma) }
                    forms(of: model.lemmaEntry ?? entry)
                    english(entry)
                } else {
                    notInDictionary
                }
                onlineSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .textSelection(.enabled)
        }
        .safeAreaInset(edge: .bottom) { actions }
        .overlay(alignment: .topTrailing) { closeButton }
        .task { model.loadOnlineDefinitions() }
        .onDisappear(perform: model.stop)
        .sheet(item: $explanation) { explanation in
            WordExplanationView(model: explanation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.request.term)
                .font(.largeTitle.weight(.bold))
                .padding(.trailing, 44)
            HStack(spacing: 12) {
                if let phonetic = model.entry?.displayPhonetic, !phonetic.isEmpty {
                    Text("/\(phonetic)/")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button(action: model.pronounce) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.body)
                        .padding(8)
                        .background(.tint.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Pronounce \(model.request.term)")
            }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private func badges(for entry: DictionaryEntry) -> some View {
        let labels = (entry.isOxford3000 ? ["Oxford 3000"] : []) + entry.examLabels
        if entry.collins > 0 || !labels.isEmpty {
            HStack(spacing: 8) {
                if entry.collins > 0 {
                    Text(String(repeating: "★", count: entry.collins) + String(repeating: "☆", count: 5 - entry.collins))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Collins \(entry.collins) of 5 stars")
                }
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.12), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: - Offline entry

    private func chinese(_ entry: DictionaryEntry) -> some View {
        section("中文") {
            ForEach(Array(entry.chineseLines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
            if entry.chineseLines.isEmpty {
                Text("No Chinese meaning in the dictionary.").foregroundStyle(.secondary)
            }
        }
    }

    private func formOf(_ lemma: DictionaryEntry) -> some View {
        section("Base form · \(lemma.word)") {
            ForEach(Array(lemma.chineseLines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
    }

    @ViewBuilder
    private func forms(of entry: DictionaryEntry) -> some View {
        let forms = entry.forms.labelled
        if !forms.isEmpty {
            section("Forms") {
                ForEach(forms, id: \.form) { item in
                    HStack(spacing: 8) {
                        Text(item.form).fontWeight(.medium)
                        Text(item.label).foregroundStyle(.secondary).font(.footnote)
                    }
                }
            }
        }
    }

    /// The dictionary's own English meanings; the online ones below are fuller and replace them when they arrive.
    @ViewBuilder
    private func english(_ entry: DictionaryEntry) -> some View {
        if case .loaded = model.online { EmptyView() } else if !entry.englishLines.isEmpty {
            section("English") {
                ForEach(Array(entry.englishLines.prefix(6).enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
        }
    }

    private var notInDictionary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not in the offline dictionary", systemImage: "questionmark.circle")
                .font(.headline)
            Text("Try the AI explanation, which looks at this word in its sentence, or the iPhone's own dictionary.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Online definitions

    @ViewBuilder
    private var onlineSection: some View {
        switch model.online {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading English definitions…").foregroundStyle(.secondary).font(.footnote)
            }
        case .loaded(let definition):
            ForEach(definition.groups, id: \.partOfSpeech) { group in
                section("\(group.partOfSpeech) · \(definition.word)") {
                    ForEach(Array(group.senses.enumerated()), id: \.offset) { index, sense in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(sense.text)")
                            if let example = sense.example {
                                Text(example).italic().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text("English definitions from Wiktionary (CC BY-SA).")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        case .notFound:
            EmptyView()
        case .unavailable:
            HStack(spacing: 8) {
                Label("English definitions need a connection.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Button("Retry", action: model.loadOnlineDefinitions).font(.footnote)
            }
        }
    }

    // MARK: - Buttons

    private var actions: some View {
        HStack(spacing: 10) {
            Button { explain() } label: {
                Label("AI", systemImage: "sparkles").padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Explain \(model.request.word) with AI")

            if model.canSave {
                Button(action: model.toggleSaved) {
                    Image(systemName: model.isSaved ? "bookmark.fill" : "bookmark").padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(model.isSaved ? "Remove \(model.request.word) from saved words" : "Save \(model.request.word)")
            }

            Spacer()

            Button { onOpenSystemDictionary(model.request.term) } label: {
                Label("iPhone Dictionary", systemImage: "character.book.closed").padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func explain() {
        let explanation = WordExplanationModel(word: model.request.word, sentence: model.request.sentence)
        explanation.onLoaded = { [model] loaded in model.didLoadAIMeaning(loaded.meaning) }
        self.explanation = explanation
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

extension WordExplanationModel: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}
