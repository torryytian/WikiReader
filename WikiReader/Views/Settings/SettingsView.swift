import OSLog
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.speechEngine) private var engineChoice = SpeechEngineChoice.system
    @AppStorage(SettingsKeys.voiceIdentifier) private var voiceIdentifier: String?
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice = OpenAISpeechEngine.defaultVoice
    @AppStorage(SettingsKeys.speechRate) private var rateValue = SpeechRate.normal.rawValue

    @State private var voices: [VoiceInfo] = []
    /// Kept alive while a sample plays; an engine speaks with the voice it was created with.
    @State private var previewEngine: SpeechEngine?
    @State private var previewingVoice: String?
    @State private var previewError: String?

    @State private var hasOpenAIKey = false
    @State private var keyInput = ""
    @State private var cacheSize: Int64 = 0
    @State private var isConfirmingClearCache = false

    private static let sampleText = "This is how Wikipedia articles will sound with this voice."

    var body: some View {
        NavigationStack {
            Form {
                engineSection
                switch engineChoice {
                case .system:
                    systemVoiceSection
                case .openAI:
                    openAIKeySection
                    openAIVoiceSection
                    openAICacheSection
                }
                speedSection
                dictionarySection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                voices = VoiceSelection.rankedEnglishVoices(VoiceSelection.installedVoices())
                hasOpenAIKey = KeychainStore.openAIKey.read() != nil
                cacheSize = SpeechAudioCache.standard.totalSize()
            }
            .onChange(of: engineChoice) { _, choice in
                stopPreview()
                Log.speech.info("Speech engine chosen: \(choice.rawValue, privacy: .public)")
            }
            .onDisappear(perform: stopPreview)
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            Picker("Read With", selection: $engineChoice) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Read With")
        } footer: {
            switch engineChoice {
            case .system:
                Text("Free and offline, with exact word highlighting.")
            case .openAI:
                Text("More natural voices. Needs an OpenAI API key and costs about $0.015 per minute of audio. Each paragraph is generated once, when it is first read, and kept for offline listening. Word highlighting is estimated.")
            }
        }
    }

    // MARK: - System voices

    private var hasPremiumVoice: Bool {
        voices.contains { $0.quality == .premium }
    }

    private var systemVoiceSection: some View {
        Section {
            if !hasPremiumVoice {
                Label {
                    Text("No Premium English voice is installed. For the most natural reading, download one in iPhone **Settings → Accessibility → Spoken Content → Voices → English** (called **Read & Speak** in newer iOS versions), then come back here.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.orange)
                }
            }

            Button {
                voiceIdentifier = nil
            } label: {
                voiceRowLabel(
                    title: "Automatic",
                    subtitle: VoiceSelection.bestEnglishVoice(voices).map { "Best available: \($0.name)" } ?? "No English voice installed",
                    isSelected: selectedVoiceIsAutomatic
                )
            }
            .tint(.primary)

            ForEach(voices, id: \.identifier) { voice in
                voiceRow(
                    title: voice.name,
                    subtitle: "\(voice.language) · \(voice.quality.label)",
                    isSelected: voiceIdentifier == voice.identifier,
                    select: {
                        voiceIdentifier = voice.identifier
                        Log.speech.info("Voice chosen: \(voice.name, privacy: .public) (\(voice.identifier, privacy: .public))")
                    },
                    previewID: voice.identifier,
                    makeEngine: { SystemSpeechEngine(voiceIdentifier: voice.identifier) }
                )
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("English voices installed on this device, best first.")
        }
    }

    /// "Automatic" is selected when nothing is chosen or the chosen voice was deleted.
    private var selectedVoiceIsAutomatic: Bool {
        guard let voiceIdentifier else { return true }
        return !voices.contains { $0.identifier == voiceIdentifier }
    }

    // MARK: - OpenAI

    private var openAIKeySection: some View {
        Section {
            if hasOpenAIKey {
                LabeledContent("API Key", value: "Saved")
                Button("Remove Key", role: .destructive) {
                    try? KeychainStore.openAIKey.delete()
                    hasOpenAIKey = false
                    Log.app.info("OpenAI key removed")
                }
            } else {
                SecureField("sk-…", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveKey)
                Button("Save Key", action: saveKey)
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("OpenAI API Key")
        } footer: {
            Text("Stored in the iPhone Keychain on this device only. Create a key at platform.openai.com.")
        }
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.openAIKey.save(key)
            hasOpenAIKey = true
            keyInput = ""
            Log.app.info("OpenAI key saved")  // never log the key itself
        } catch {
            Log.app.error("Saving OpenAI key failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var openAIVoiceSection: some View {
        Section {
            if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            ForEach(OpenAISpeechEngine.voices, id: \.self) { voice in
                voiceRow(
                    title: voice.capitalized,
                    subtitle: voice == OpenAISpeechEngine.defaultVoice ? "Recommended" : nil,
                    isSelected: openAIVoice == voice,
                    select: {
                        openAIVoice = voice
                        Log.speech.info("OpenAI voice chosen: \(voice, privacy: .public)")
                    },
                    previewID: "openai.\(voice)",
                    makeEngine: { OpenAISpeechEngine(voice: voice) }
                )
                .disabled(!hasOpenAIKey)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text(hasOpenAIKey ? "A sample costs a fraction of a cent the first time; after that it plays from the cache." : "Save an API key to hear samples.")
        }
    }

    private var openAICacheSection: some View {
        Section {
            LabeledContent("Saved Audio", value: cacheSize.formatted(.byteCount(style: .file)))
            Button("Delete Saved Audio", role: .destructive) {
                isConfirmingClearCache = true
            }
            .disabled(cacheSize == 0)
            .confirmationDialog("Delete all saved OpenAI audio?", isPresented: $isConfirmingClearCache, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    stopPreview()
                    try? SpeechAudioCache.standard.removeAll()
                    cacheSize = SpeechAudioCache.standard.totalSize()
                    Log.app.info("OpenAI audio cache cleared")
                }
            } message: {
                Text("Paragraphs will be generated and paid for again when read.")
            }
        } header: {
            Text("Storage")
        }
    }

    // MARK: - Voice rows and samples

    private func voiceRow(
        title: String, subtitle: String?, isSelected: Bool, select: @escaping () -> Void,
        previewID: String, makeEngine: @escaping () -> SpeechEngine
    ) -> some View {
        HStack {
            Button(action: select) {
                voiceRowLabel(title: title, subtitle: subtitle, isSelected: isSelected)
            }
            .tint(.primary)

            Button(previewingVoice == previewID ? "Stop" : "Play Sample",
                   systemImage: previewingVoice == previewID ? "stop.circle" : "play.circle") {
                togglePreview(previewID, makeEngine: makeEngine)
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.borderless)
        }
    }

    private func voiceRowLabel(title: String, subtitle: String?, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
    }

    private func togglePreview(_ id: String, makeEngine: () -> SpeechEngine) {
        let wasPreviewing = previewingVoice == id
        stopPreview()
        guard !wasPreviewing else { return }

        let engine = makeEngine()
        engine.onEvent = { event in
            switch event {
            case .finished:
                previewingVoice = nil
                cacheSize = SpeechAudioCache.standard.totalSize()
            case .failed(_, let message):
                previewingVoice = nil
                previewError = message
            case .started, .willSpeak:
                break
            }
        }
        previewError = nil
        engine.speak(SpeechUtterance(id: 1, text: Self.sampleText, rate: SpeechRate(rawValue: rateValue) ?? .normal))
        previewEngine = engine
        previewingVoice = id
    }

    private func stopPreview() {
        previewEngine?.stop()
        previewEngine = nil
        previewingVoice = nil
    }

    // MARK: - Speed

    private var speedSection: some View {
        Section {
            Picker("Default Speed", selection: $rateValue) {
                ForEach(SpeechRate.allCases, id: \.self) { rate in
                    Text(rate.label).tag(rate.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Default Speed")
        } footer: {
            Text("Changing the speed in the player also changes this.")
        }
    }

    // MARK: - Dictionary

    private var dictionarySection: some View {
        Section("Dictionary") {
            Text("To see Chinese definitions when you tap a word, enable an English–Chinese dictionary in iPhone **Settings → General → Dictionary**, for example **Simplified Chinese–English**.")
                .font(.callout)
        }
    }
}

#Preview {
    SettingsView()
}
