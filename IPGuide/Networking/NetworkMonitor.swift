import Foundation
import Network

@MainActor
final class NetworkMonitor {
    enum Reachability: Sendable, Equatable {
        case unknown
        case offline
        case online(interfaces: Set<NWInterface.InterfaceType>)
    }

    enum Event: Sendable, Equatable {
        case becameReachable
        case becameUnreachable
        case interfaceChanged
    }

    private(set) var reachability: Reachability = .unknown
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.ipguide.network-monitor")
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        for c in continuations.values { c.finish() }
        continuations.removeAll()
        started = false
    }

    func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        let previous = reachability
        let newValue: Reachability
        if path.status == .satisfied {
            let ifaces = Set(Self.interfaceTypes.filter { path.usesInterfaceType($0) })
            newValue = .online(interfaces: ifaces)
        } else {
            newValue = .offline
        }
        reachability = newValue

        switch (previous, newValue) {
        case (.offline, .online), (.unknown, .online):
            emit(.becameReachable)
        case (.online, .offline):
            emit(.becameUnreachable)
        case (.online(let a), .online(let b)) where a != b:
            emit(.interfaceChanged)
        default:
            break
        }
    }

    private func emit(_ event: Event) {
        for c in continuations.values { c.yield(event) }
    }

    private static let interfaceTypes: [NWInterface.InterfaceType] = [
        .wifi, .wiredEthernet, .cellular, .loopback, .other
    ]
}
