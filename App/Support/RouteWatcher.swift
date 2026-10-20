import Foundation
import HermesKit
import Network

/// The device's route to the network: up or down (and why, when a setting is in the way), and
/// a change worth acting on, reported once a handover has settled.
@MainActor
final class RouteWatcher {
    /// There's no route because of a setting, not for want of a network.
    enum Blocked: Equatable {
        /// Mobile Data is off for this app (Settings → Hermes), and there's no Wi-Fi.
        case mobileDataOff
        /// Wi-Fi is off for this app (WLAN & Mobile Data, on some devices).
        case wifiOff

        var reason: HermesError.Reason {
            switch self {
            case .mobileDataOff: .mobileDataOff
            case .wifiOff: .wifiOff
            }
        }
    }

    /// There is a route, or one that comes up when used (an on-demand VPN, cellular that
    /// activates on demand): only `unsatisfied` is down.
    private(set) var isUp = true
    private(set) var blocked: Blocked?
    private var signature: String?
    private var settle: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private let onChange: @MainActor (_ cameBack: Bool) -> Void

    /// - Parameter onChange: the route changed (`cameBack`: after there was none), 1.5 s after the
    ///   last report of a handover, which reports several states in a row.
    init(label: String, onChange: @escaping @MainActor (_ cameBack: Bool) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            // Only what changes the route: up or down, and which kinds of link carry it. iOS
            // reports VPN tunnels (Tailscale, iCloud Private Relay) and interface reshuffles all
            // the time; counting those as changes restarted connects until none could finish.
            let kinds = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet].filter { path.usesInterfaceType($0) }
            let signature = path.status == .satisfied ? "up:" + kinds.map { "\($0)" }.joined(separator: ",") : "down"
            let blocked: Blocked? = switch path.status == .satisfied ? nil : path.unsatisfiedReason {
            case .cellularDenied?: .mobileDataOff
            case .wifiDenied?: .wifiOff
            default: nil
            }
            let isUp = path.status != .unsatisfied
            Task { @MainActor in self?.update(signature, isUp: isUp, blocked: blocked) }
        }
        monitor.start(queue: DispatchQueue(label: label, qos: .utility))
    }

    func cancel() {
        monitor.cancel()
        settle?.cancel()
    }

    private func update(_ new: String, isUp: Bool, blocked: Blocked?) {
        if blocked != self.blocked { self.blocked = blocked }
        self.isUp = isUp
        guard new != signature else { return }
        let previous = signature
        signature = new
        // The first report is no change; a route going away has nothing to reconnect over (and
        // a change it interrupted is moot).
        if new == "down" { settle?.cancel() }
        guard let previous, new != "down" else { return }
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.onChange(previous == "down")
        }
    }
}

/// Local network privacy (TN3179): a gateway at a local address needs the person's permission,
/// and a denial looks like any unreachable host. A connection that waits with
/// `localNetworkDenied` tells them apart.
nonisolated enum LocalNetworkAccess {
    /// Whether this device is refused local network access to `url`'s host. False for hosts that
    /// aren't on a local network, and when it can't tell within a moment.
    static func isDenied(for url: URL) async -> Bool {
        guard let host = url.host(), HermesError.isLocalNetwork(host) else { return false }
        let port = UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)).flatMap(NWEndpoint.Port.init(rawValue:)) ?? .http
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let denied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .waiting:
                    once.resume(connection?.currentPath?.unsatisfiedReason == .localNetworkDenied)
                case .ready, .failed, .cancelled:
                    once.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "hermes.local-network-check", qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { once.resume(false) }
        }
        connection.cancel()
        return denied
    }

    nonisolated private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
