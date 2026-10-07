import SwiftUI

/// A tapped word, as a fresh item each time so tapping the same word twice shows the card again.
struct WordCard: Identifiable {
    let id = UUID()
    let request: WordLookupRequest
}

/// The small card shown after a word is tapped: the word, a button to hear it, and a way into the
/// system dictionary (whose own screen can't hold a pronunciation button).
struct WordCardView: View {
    let request: WordLookupRequest
    let voiceIdentifier: String?
    // Created when the card first speaks rather than in init, which SwiftUI may run many times.
    @State private var pronouncer: WordPronouncer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.word)
                        .font(.largeTitle.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let baseForm = request.baseForm {
                        Text("→ \(baseForm)")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: speak) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title2)
                        .symbolEffect(.variableColor.iterative, isActive: pronouncer?.isSpeaking ?? false)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel("Pronounce")
            }

            Button {
                pronouncer?.stop()
                DictionaryPresenter.present(request)
            } label: {
                Label("Open Dictionary", systemImage: "character.book.closed")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(220)])
        // The article behind stays tappable: tapping another word swaps the card's content.
        .presentationBackgroundInteraction(.enabled)
        // Runs when the card appears and again when another word is tapped; speaks each once.
        .task(id: request.word) { speak() }
        .onDisappear { pronouncer?.stop() }
    }

    private func speak() {
        let pronouncer = pronouncer ?? WordPronouncer(voiceIdentifier: voiceIdentifier)
        self.pronouncer = pronouncer
        pronouncer.speak(request.word)
    }
}
