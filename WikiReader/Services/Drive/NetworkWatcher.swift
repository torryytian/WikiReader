import Foundation
import Network
import Observation

/// Whether the current connection may cost money: any cellular connection, a personal hotspot, or Low Data Mode.
/// Uploads to Google Drive wait for a free connection when the reader asked for Wi-Fi only.
///
/// Cellular is checked by interface, not only by `isExpensive`: with an unlimited plan and "Allow More Data on 5G",
/// iOS stops calling 5G expensive, but the setting is about not uploading over cellular at all.
@Observable
final class NetworkWatcher {
    static let shared = NetworkWatcher()

    private(set) var isExpensive = false
    /// Called when the connection changes, e.g. to restart uploads that waited for Wi-Fi.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained
            Task { @MainActor in
                guard let self, self.isExpensive != expensive else { return }
                self.isExpensive = expensive
                self.onChange()
            }
        }
        monitor.start(queue: DispatchQueue(label: "tik.tian.com.WikiReader.network"))
    }
}
