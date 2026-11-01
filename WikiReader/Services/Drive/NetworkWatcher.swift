import Foundation
import Network
import Observation

/// Whether the current connection costs money: cellular, a personal hotspot, or Low Data Mode. Uploads to Google
/// Drive wait for a free connection when the reader asked for Wi-Fi only.
@Observable
final class NetworkWatcher {
    static let shared = NetworkWatcher()

    private(set) var isExpensive = false
    /// Called when the connection changes, e.g. to restart uploads that waited for Wi-Fi.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in
                guard let self, self.isExpensive != expensive else { return }
                self.isExpensive = expensive
                self.onChange()
            }
        }
        monitor.start(queue: DispatchQueue(label: "tik.tian.com.WikiReader.network"))
    }
}
