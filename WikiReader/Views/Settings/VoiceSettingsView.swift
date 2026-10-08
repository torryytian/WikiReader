import OSLog
import SwiftUI

/// Every voice that can read articles, OpenAI and iPhone, in one list with a single checkmark.
/// Tapping a voice picks it and the engine that speaks it.
struct VoiceSettingsView: View {
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

    private var choice: VoiceChoice {
        VoiceChoice.current(
            engine: engineChoice, voiceIdentifier: voiceIdentifier, openAIVoice: openAIVoice,
            hasOpenAIKey: hasOpenAIKey, installedVoices: voices
        )
    }

    var body: some View {
        Form {
            openAISection
            iPhoneSection
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            voices = VoiceSelection.rankedEnglishVoices(VoiceSelection.installedVoices())
            hasOpenAIKey = KeychainStore.openAIKey.read() != nil
            cacheSize = SpeechAudioCache.standard.totalSize()
            // OpenAI can't read without a key, so make the stored engine match what is really in use.
            if engineChoice == .openAI && !hasOpenAIKey { engineChoice = .system }
        }
        .onDisappear(perform: stopPreview)
    }

    private func select(_ choice: VoiceChoice) {
        engineChoice = choice.engine
        switch choice {
        case .iPhone(let identifier):
            voiceIdentifier = identifier
            Log.speech.info("Voice chosen: iPhone \(identifier ?? "automatic", privacy: .public)")
        case .openAI(let voice):
            openAIVoice = voice
            Log.speech.info("Voice chosen: OpenAI \(voice, privacy: .public)")
        }
    }

    // MARK: - OpenAI

    private var openAISection: some View {
        Section {
            if hasOpenAIKey {
                LabeledContent("API Key", value: "Saved")
            } else {
                SecureField("sk-…", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveKey)
                Button("Save Key", action: saveKey)
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            ForEach(OpenAISpeechEngine.voices, id: \.self) { voice in
                voiceRow(
                    title: voice.capitalized,
                    subtitle: voice == OpenAISpeechEngine.defaultVoice ? "Recommended" : nil,
                    isSelected: choice == .openAI(voice: voice),
                    isLocked: !hasOpenAIKey,
                    select: { select(.openAI(voice: voice)) },
                    previewID: "openai.\(voice)",
                    makeEngine: { OpenAISpeechEngine(voice: voice) }
                )
            }

            if hasOpenAIKey {
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

                Button("Remove Key", role: .destructive, action: removeKey)
            }
        } header: {
            sectionHeader("OpenAI", detail: "natural, needs internet")
        } footer: {
            if hasOpenAIKey {
                Text("About $0.015 per minute of audio. Each paragraph is generated once, when it is first read, and kept for offline listening; samples are kept the same way. Word highlighting is estimated. The key is stored in this iPhone's Keychain only.")
            } else {
                Text("Save an API key to use OpenAI voices. Create one at platform.openai.com. About $0.015 per minute of audio.")
            }
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

    private func removeKey() {
        stopPreview()
        try? KeychainStore.openAIKey.delete()
        hasOpenAIKey = false
        // Without a key the OpenAI voice can't read; go back to the iPhone voice.
        if engineChoice == .openAI { engineChoice = .system }
        Log.app.info("OpenAI key removed")
    }

    // MARK: - iPhone voices

    private var hasPremiumVoice: Bool {
        voices.contains { $0.quality == .premium }
    }

    private var iPhoneSection: some View {
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
                select(.iPhone(identifier: nil))
            } label: {
                voiceRowLabel(
                    title: "Automatic",
                    subtitle: VoiceSelection.bestEnglishVoice(voices).map { "Best available: \($0.name)" } ?? "No English voice installed",
                    isSelected: choice == .iPhone(identifier: nil),
                    isLocked: false
                )
            }
            .tint(.primary)

            ForEach(voices, id: \.identifier) { voice in
                voiceRow(
                    title: voice.name,
                    subtitle: "\(voice.language) · \(voice.quality.label)",
                    isSelected: choice == .iPhone(identifier: voice.identifier),
                    isLocked: false,
                    select: { select(.iPhone(identifier: voice.identifier)) },
                    previewID: voice.identifier,
                    makeEngine: { SystemSpeechEngine(voiceIdentifier: voice.identifier) }
                )
            }
        } header: {
            sectionHeader("iPhone", detail: "free, offline")
        } footer: {
            Text("English voices installed on this iPhone, best first. Word highlighting is exact.")
        }
    }

    // MARK: - Rows and samples

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .textCase(nil)
        }
    }

    private func voiceRow(
        title: String, subtitle: String?, isSelected: Bool, isLocked: Bool, select: @escaping () -> Void,
        previewID: String, makeEngine: @escaping () -> SpeechEngine
    ) -> some View {
        HStack {
            Button(action: select) {
                voiceRowLabel(title: title, subtitle: subtitle, isSelected: isSelected, isLocked: isLocked)
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
        // Samples need the key too: they are generated by OpenAI.
        .disabled(isLocked)
    }

    private func voiceRowLabel(title: String, subtitle: String?, isSelected: Bool, isLocked: Bool) -> some View {
        HStack(spacing: 10) {
            // Fixed width, so titles line up whether or not the row is selected.
            Group {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Locked")
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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
            case .failed(_, let failure):
                previewingVoice = nil
                previewError = failure.message
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
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
    }
}
