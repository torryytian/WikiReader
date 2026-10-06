import SwiftUI

/// Shown above the player bar when speech stopped because of an error (e.g. no key for a cloud voice).
struct SpeechErrorBanner: View {
    let title: String
    let failure: SpeechFailure
    var onOpenSettings: () -> Void
    var onRetry: () -> Void
    /// Offered only when a fallback exists, i.e. a cloud voice failed.
    var onUseSystemVoice: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    // The main way out depends on the problem: fix the key, or simply try again.
                    if failure.isFixableInSettings {
                        Button("Open Settings", action: onOpenSettings)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }
                    if let onUseSystemVoice {
                        Button("Use iPhone Voice", action: onUseSystemVoice)
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.orange.opacity(0.5), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

#Preview {
    VStack {
        Spacer()
        SpeechErrorBanner(
            title: "OpenAI voice unavailable",
            failure: OpenAITTSError.missingKey.failure,
            onOpenSettings: {},
            onRetry: {},
            onUseSystemVoice: {},
            onDismiss: {}
        )
        .background(.bar)
    }
}
