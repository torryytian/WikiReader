import SwiftUI

/// Shown above the player bar when speech stopped because of an error (e.g. no network for a cloud voice).
struct SpeechErrorBanner: View {
    let message: String
    /// Offered only when a fallback exists, i.e. a cloud voice failed.
    var onUseSystemVoice: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.multicolor)
            HStack {
                Text("Press Play to try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onUseSystemVoice {
                    Button("Use iPhone Voice", action: onUseSystemVoice)
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15))
    }
}
