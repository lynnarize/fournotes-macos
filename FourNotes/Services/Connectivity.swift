import Foundation
import Network

// Whether this Mac can reach the internet right now. The cloud is only
// offered when it can: an offer that fails with "you're offline" is noise.

@MainActor
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "fournotes.connectivity"))
    }
}
