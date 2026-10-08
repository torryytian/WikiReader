import SwiftUI

/// The player at the bottom of the reader, shown when the reader taps near the bottom edge:
/// speed on the left, previous / play-pause / next in the middle, on a full-width bar in the page color.
struct PlayerBar: View {
    let session: ReadingSession

    var body: some View {
        HStack(spacing: 20) {
            Menu {
                Picker("Speed", selection: Binding(get: { session.rate }, set: { session.setRate($0) })) {
                    ForEach(SpeechRate.allCases, id: \.self) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
            } label: {
                Text(session.rate.label)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(width: 56, height: 44)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .accessibilityLabel("Speed \(session.rate.label)")

            Spacer(minLength: 0)

            transportButton("Previous Paragraph", symbol: "backward.fill", action: session.previous)

            Button(action: session.togglePlayPause) {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 54, height: 54)
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

            Spacer(minLength: 0)

            // Balances the speed control so the transport buttons sit in the middle.
            Color.clear.frame(width: 56, height: 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .readerBar(edge: .bottom)
        // Taps on the player's own parts must not reach the text underneath and toggle the menu.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func transportButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel(label)
    }
}
