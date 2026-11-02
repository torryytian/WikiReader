import SwiftUI

/// One article's Google Drive backup in a line: an icon for the state and what it means in numbers.
struct BackupStatusLine: View {
    /// Nil while it is being worked out.
    let backup: DriveAudioStore.ArticleBackup?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var symbol: String {
        switch backup?.state {
        case nil: "ellipsis.circle"
        case .noAudio: "icloud"
        case .backedUp: "checkmark.icloud.fill"
        case .uploading: "arrow.up.circle"
        case .notBackedUp: "exclamationmark.icloud"
        }
    }

    private var color: Color {
        switch backup?.state {
        case nil, .noAudio: .secondary
        case .backedUp: .green
        case .uploading: .blue
        case .notBackedUp: .orange
        }
    }

    private var text: String {
        guard let backup else { return "Checking…" }
        var parts: [String] = []
        switch backup.state {
        case .noAudio:
            parts.append("No audio yet")
        case .backedUp:
            parts.append("Backed up")
            parts.append(backup.piecesHere == backup.pieces
                         ? "all \(backup.pieces) parts"
                         : "\(backup.piecesHere) of \(backup.pieces) parts downloaded")
        case .uploading:
            parts.append(backup.waiting == 1 ? "1 part waiting to upload" : "\(backup.waiting) parts waiting to upload")
        case .notBackedUp:
            parts.append(backup.missing == 1 ? "1 part not backed up yet" : "\(backup.missing) parts not backed up yet")
        }
        if backup.bytesHere > 0 { parts.append(AudioFormat.bytes(backup.bytesHere)) }
        if backup.otherVoicePieces > 0 { parts.append("+\(backup.otherVoicePieces) in other voices") }
        if backup.state != .noAudio && !backup.hasManifest { parts.append("article list not in Drive yet") }
        return parts.joined(separator: " · ")
    }
}
