import SwiftUI

/// Bottom bar: previous / play-pause / next, and a speed menu.
struct PlayerBar: View {
    let session: ReadingSession

    var body: some View {
        HStack {
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
            }
            .accessibilityLabel("Speed \(session.rate.label)")

            Spacer()

            Button("Previous Paragraph", systemImage: "backward.end.fill", action: session.previous)
                .font(.title2)
                .frame(width: 56, height: 44)

            Button(session.isPlaying ? "Pause" : "Play",
                   systemImage: session.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                   action: session.togglePlayPause)
                .font(.system(size: 48))
                .frame(width: 72, height: 56)
                .contentTransition(.symbolEffect(.replace))
                .overlay {
                    // A cloud voice may take a moment to generate audio before sound starts.
                    if session.isPlaying && session.isWaitingForAudio {
                        ProgressView()
                            .controlSize(.large)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Loading audio")
                    }
                }

            Button("Next Paragraph", systemImage: "forward.end.fill", action: session.next)
                .font(.title2)
                .frame(width: 56, height: 44)

            Spacer()

            // Balances the speed menu so the transport buttons stay centered.
            Color.clear.frame(width: 56, height: 44)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
