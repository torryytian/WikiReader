import SwiftUI

/// A backup to Google Drive asked for by hand: how far it got, with Stop, or that it finished, with OK. Shown in the
/// library and on the Google Drive page, like the download's row.
struct DriveBackupStatusRow: View {
    @State private var drive = DriveAudioStore.shared

    var body: some View {
        if let run = drive.backupRun {
            if run.isFinished {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Backed up to Google Drive")
                            .font(.subheadline.weight(.semibold))
                        Text(run.total == 1 ? "1 part uploaded." : "\(run.total) parts uploaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("OK") { drive.dismissBackupRun() }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Backing up to Google Drive", systemImage: "icloud.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Stop") { drive.stopBackupRun() }
                            .buttonStyle(.borderless)
                    }
                    ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                    Text(detail(run))
                        .font(.caption)
                        .foregroundStyle(drive.lastError == nil ? Color.secondary : Color.orange)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func detail(_ run: DriveAudioStore.BackupRun) -> String {
        let progress = "\(run.done) of \(run.total) parts"
        if drive.isWaitingForFreeNetwork {
            return progress + " · waiting for Wi-Fi (or turn on Upload over Cellular in Settings → Google Drive)"
        }
        if let error = drive.lastError { return progress + " · \(error)" }
        return progress + " · screen stays on"
    }
}
