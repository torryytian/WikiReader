import SwiftUI

/// The player at the bottom of the reader, shown when the reader taps near the bottom edge:
/// speed, previous / play-pause / next, in one floating capsule.
struct PlayerBar: View {
    let session: ReadingSession

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Speed", selection: Binding(get: { session.rate }, set: { session.setRate($0) })) {
                    ForEach(SpeechRate.allCases, id: \.self) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
            } label: {
                Text(session.rate.label)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(width: 54, height: 44)
            }
            .accessibilityLabel("Speed \(session.rate.label)")

            Capsule()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: 24)
                .padding(.horizontal, 4)

            transportButton("Previous Paragraph", symbol: "backward.fill", action: session.previous)

            Button(action: session.togglePlayPause) {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .overlay {
                        // A cloud voice may take a moment to generate audio before sound starts.
                        if session.isPlaying && session.isWaitingForAudio {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.white)
                                .allowsHitTesting(false)
                                .accessibilityLabel("Loading audio")
                        }
                    }
            }
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")

            transportButton("Next Paragraph", symbol: "forward.fill", action: session.next)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .floatingGlass(in: Capsule())
        // Taps on the player's own parts must not reach the text underneath and toggle the menu.
        .contentShape(Capsule())
        .onTapGesture {}
        .padding(.horizontal, 16)
    }

    private func transportButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .frame(width: 52, height: 52)
        }
        .accessibilityLabel(label)
    }
}
