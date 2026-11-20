import Foundation
import Network
import Observation

/// オフライン動作の確認用に、ネットワーク接続の有無を表示する。通信はしない。
@MainActor
@Observable
final class NetworkStatus {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkStatus"))
    }

    deinit {
        monitor.cancel()
    }
}
