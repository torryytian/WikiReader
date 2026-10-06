import OSLog
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.voiceIdentifier) private var voiceIdentifier: String?
    @AppStorage(SettingsKeys.speechRate) private var rateValue = SpeechRate.normal.rawValue

    @State private var voices: [VoiceInfo] = []
    /// Kept alive while a sample plays; an engine speaks with the voice it was created with.
    @State private var previewEngine: SystemSpeechEngine?
    @State private var previewingVoice: String?

    private static let sampleText = "This is how Wikipedia articles will sound with this voice."

    var body: some View {
        NavigationStack {
            Form {
                voiceSection
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
            }
            .onDisappear {
                previewEngine?.stop()
            }
        }
    }

    // MARK: - Voice

    private var hasPremiumVoice: Bool {
        voices.contains { $0.quality == .premium }
    }

    private var voiceSection: some View {
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
                HStack {
                    Button {
                        voiceIdentifier = voice.identifier
                        Log.speech.info("Voice chosen: \(voice.name, privacy: .public) (\(voice.identifier, privacy: .public))")
                    } label: {
                        voiceRowLabel(
                            title: voice.name,
                            subtitle: "\(voice.language) · \(voice.quality.label)",
                            isSelected: voiceIdentifier == voice.identifier
                        )
                    }
                    .tint(.primary)

                    Button(previewingVoice == voice.identifier ? "Stop" : "Play Sample",
                           systemImage: previewingVoice == voice.identifier ? "stop.circle" : "play.circle") {
                        togglePreview(voice)
                    }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                }
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

    private func voiceRowLabel(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func togglePreview(_ voice: VoiceInfo) {
        previewEngine?.stop()
        guard previewingVoice != voice.identifier else {
            previewingVoice = nil
            return
        }
        let engine = SystemSpeechEngine(voiceIdentifier: voice.identifier)
        engine.onEvent = { event in
            if case .finished = event { previewingVoice = nil }
        }
        engine.speak(SpeechUtterance(id: 1, text: Self.sampleText, rate: SpeechRate(rawValue: rateValue) ?? .normal))
        previewEngine = engine
        previewingVoice = voice.identifier
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
