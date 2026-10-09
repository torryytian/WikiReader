import SwiftUI

/// The transport row of the reader's bottom menu: previous paragraph, back 10 s, play/pause, forward 10 s,
/// next paragraph. The play button is the one filled with the accent color.
struct PlayerBar: View {
    let session: ReadingSession
    let accent: Color
    let onAccent: Color

    var body: some View {
        HStack(spacing: 4) {
            transportButton("Previous Paragraph", symbol: "backward.end.fill", size: 19, action: session.previous)
            transportButton("Back 10 Seconds", symbol: "gobackward.10", size: 25) { session.skip(seconds: -10) }

            Button(action: session.togglePlayPause) {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(onAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 50, height: 50)
                    .background(accent, in: Circle())
                    .overlay {
                        // A cloud voice may take a moment to generate audio before sound starts.
                        if session.isPlaying && session.isWaitingForAudio {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(onAccent)
                                .allowsHitTesting(false)
                                .accessibilityLabel("Loading audio")
                        }
                    }
            }
            .padding(.horizontal, 6)
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")

            transportButton("Forward 10 Seconds", symbol: "goforward.10", size: 25) { session.skip(seconds: 10) }
            transportButton("Next Paragraph", symbol: "forward.end.fill", size: 19, action: session.next)
        }
        .buttonStyle(.plain)
    }

    private func transportButton(_ label: String, symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}
