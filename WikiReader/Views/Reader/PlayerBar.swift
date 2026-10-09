import SwiftUI

/// The player in the reader's bottom menu, a row of its own, separate from the text settings:
/// play mode on the left; previous paragraph, back 10 s, play/pause, forward 10 s, next paragraph in the
/// middle; speed on the right. The play button is the one filled with the accent color.
struct PlayerBar: View {
    let session: ReadingSession
    @Binding var playbackMode: PlaybackMode
    let accent: Color
    let onAccent: Color

    var body: some View {
        HStack(spacing: 0) {
            modeMenu
            Spacer(minLength: 0)
            transportButton("Previous Paragraph", symbol: "backward.end.fill", size: 18, action: session.previous)
            transportButton("Back 10 Seconds", symbol: "gobackward.10", size: 23) { session.skip(seconds: -10) }
            playButton
            transportButton("Forward 10 Seconds", symbol: "goforward.10", size: 23) { session.skip(seconds: 10) }
            transportButton("Next Paragraph", symbol: "forward.end.fill", size: 18, action: session.next)
            Spacer(minLength: 0)
            speedMenu
        }
        .padding(.horizontal, 10)
        .buttonStyle(.plain)
    }

    private var playButton: some View {
        Button(action: session.togglePlayPause) {
            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 21))
                .foregroundStyle(onAccent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
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
        .padding(.horizontal, 4)
        .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
    }

    /// What happens when an article ends: next article, this one again, or a random one.
    private var modeMenu: some View {
        Menu {
            Picker("Play Mode", selection: $playbackMode) {
                ForEach(PlaybackMode.allCases, id: \.self) { mode in
                    Label(mode.menuTitle, systemImage: mode.symbol).tag(mode)
                }
            }
        } label: {
            Image(systemName: playbackMode.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Play mode: \(playbackMode.menuTitle)")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { session.rate }, set: { session.setRate($0) })) {
                ForEach(SpeechRate.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } label: {
            Text(session.rate.label)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Speed \(session.rate.label)")
    }

    private func transportButton(_ label: String, symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 42, height: 44)
        }
        .accessibilityLabel(label)
    }
}
