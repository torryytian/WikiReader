import OSLog
import SwiftUI

/// Settings pages that can be pushed onto the settings navigation stack.
private enum SettingsPage: Hashable {
    case voice
    case backup
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.speechEngine) private var engineChoice = SpeechEngineChoice.system
    @AppStorage(SettingsKeys.voiceIdentifier) private var voiceIdentifier: String?
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice = OpenAISpeechEngine.defaultVoice
    @AppStorage(SettingsKeys.speechRate) private var rateValue = SpeechRate.normal.rawValue
    @AppStorage(SettingsKeys.appAppearance) private var appearance = AppAppearance.system

    @State private var path: [SettingsPage]
    @State private var voices: [VoiceInfo] = []
    @State private var hasOpenAIKey = false

    /// - Parameter opensVoicePage: Start on the voice page, for when reading failed and the fix is a voice or key.
    init(opensVoicePage: Bool = false) {
        _path = State(initialValue: opensVoicePage ? [.voice] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                appearanceSection
                voiceSection
                speedSection
                dictionarySection
                backupSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .voice:
                    VoiceSettingsView()
                case .backup:
                    LibraryBackupView()
                }
            }
            // Runs again when coming back from the voice page, which may have changed the voice or key.
            .onAppear {
                voices = VoiceSelection.rankedEnglishVoices(VoiceSelection.installedVoices())
                hasOpenAIKey = KeychainStore.openAIKey.read() != nil
                // OpenAI can't read without a key, so make the stored engine match what is really in use.
                if engineChoice == .openAI && !hasOpenAIKey { engineChoice = .system }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your iPhone's Light or Dark setting. The reader has its own theme in its top menu; its Auto follows this choice.")
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        let choice = VoiceChoice.current(
            engine: engineChoice, voiceIdentifier: voiceIdentifier, openAIVoice: openAIVoice,
            hasOpenAIKey: hasOpenAIKey, installedVoices: voices
        )
        return Section {
            NavigationLink(value: SettingsPage.voice) {
                LabeledContent("Voice", value: choice.summary(installedVoices: voices))
            }
        } header: {
            Text("Reading")
        } footer: {
            Text("Free iPhone voices work offline. OpenAI voices sound more natural and cost about $0.015 per minute.")
        }
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

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            NavigationLink(value: SettingsPage.backup) {
                Label("Backup & Transfer", systemImage: "arrow.left.arrow.right.circle")
            }
        } footer: {
            Text("Move your articles, saved words and generated audio to another iPhone, or keep a copy before reinstalling.")
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
