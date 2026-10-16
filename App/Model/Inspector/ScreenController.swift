import CoreGraphics
import CryptoKit
import Foundation
import HermesKit
import Observation

/// The Screen tab (`docs/inspector.md` §2): the Bot Screen, Hermes's own desktop on the gateway,
/// live. `display.observe` gives a single-use ticket for `WS /api/display/ws`, which carries raw
/// RFB; this app is the VNC viewer. Take Control and Hand Back move the lease
/// (`display.lease.acquire` / `release`); while Hermes holds it, the person's input is dropped.
@MainActor
@Observable
final class ScreenController {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        /// Closed, and why (4000 control taken, 4001 desktop gone, a refusal).
        case closed(String)
    }

    struct Status: Equatable {
        var supported: Bool
        var installed: Bool
        var running: Bool
        var geometry: String?
        var holder: String
        var viewerHash: String?
        var reason: String?
    }

    @ObservationIgnored private weak var inspector: InspectorModel?
    private(set) var status: Status?
    private(set) var phase = Phase.idle
    private(set) var image: CGImage?
    private(set) var size = CGSize.zero
    private(set) var desktopName = ""
    private(set) var isChangingLease = false
    var leaseError: String?

    @ObservationIgnored private var viewerID: String?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiver: Task<Void, Never>?
    @ObservationIgnored private var decoder = RFBDecoder()
    @ObservationIgnored private var framebuffer = RFBFramebuffer()
    @ObservationIgnored private var buttons: UInt8 = 0
    @ObservationIgnored private var retriedTicket = false

    init(inspector: InspectorModel) {
        self.inspector = inspector
    }

    /// The person holds the lease (their input reaches the screen).
    var personInControl: Bool {
        guard let status, status.holder == "human", let viewerID, let hash = status.viewerHash else { return false }
        return Self.hash(viewerID) == hash
    }

    /// Someone (another device) holds it.
    var someoneElseInControl: Bool {
        status?.holder == "human" && !personInControl
    }

    /// The screen is worth a tab: the gateway can run one and it's running.
    var isAvailable: Bool { status?.running == true }

    private static func hash(_ viewerID: String) -> String {
        SHA256.hash(data: Data(viewerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    // MARK: Status and lease

    func refreshStatus() async {
        guard let roster = inspector?.workspace?.roster else { return }
        guard let result = try? await roster.request("display.status", profileParams, timeout: .seconds(15)) else { return }
        apply(status: result)
    }

    /// `display.lease`, broadcast to every client when control moves.
    func leaseChanged(_ payload: JSONValue) {
        guard let lease = payload["lease"], status != nil else { return }
        status?.holder = lease["holder"]?.stringValue ?? "agent"
        status?.viewerHash = lease["viewer_hash"]?.stringValue
        status?.reason = lease["reason"]?.stringValue
    }

    private func apply(status json: JSONValue) {
        status = Status(
            supported: json["supported"]?.boolValue ?? false,
            installed: json["installed"]?.boolValue ?? false,
            running: json["running"]?.boolValue ?? false,
            geometry: json["geometry"]?.stringValue,
            holder: json["lease"]?["holder"]?.stringValue ?? "agent",
            viewerHash: json["lease"]?["viewer_hash"]?.stringValue,
            reason: json["lease"]?["reason"]?.stringValue
        )
    }

    private var profileParams: [String: JSONValue] {
        guard let profile = inspector?.profile else { return [:] }
        return ["profile": .string(profile)]
    }

    func takeControl() async {
        guard let roster = inspector?.workspace?.roster, let viewerID else { return }
        isChangingLease = true
        defer { isChangingLease = false }
        var params = profileParams
        params["viewer_id"] = .string(viewerID)
        params["reason"] = .string(String(localized: "Taken from the Hermes app"))
        do {
            let result = try await roster.request("display.lease.acquire", params, timeout: .seconds(15))
            leaseChanged(result)
            leaseError = nil
        } catch {
            leaseError = error.localizedDescription
        }
    }

    func handBack() async {
        guard let roster = inspector?.workspace?.roster, let viewerID else { return }
        isChangingLease = true
        defer { isChangingLease = false }
        releaseButtons()
        var params = profileParams
        params["viewer_id"] = .string(viewerID)
        do {
            let result = try await roster.request("display.lease.release", params, timeout: .seconds(15))
            leaseChanged(result)
            leaseError = nil
        } catch {
            leaseError = error.localizedDescription
        }
    }

    // MARK: The stream

    func connect() async {
        guard phase != .connecting, phase != .live else { return }
        guard let roster = inspector?.workspace?.roster, let backend = inspector?.backend else { return }
        phase = .connecting
        var params = profileParams
        if let viewerID { params["viewer_id"] = .string(viewerID) }
        do {
            let observed = try await roster.request("display.observe", params, timeout: .seconds(20))
            guard let ticket = observed["ticket"]?.stringValue else {
                phase = .closed(String(localized: "The gateway didn't open the screen."))
                return
            }
            viewerID = observed["viewer_id"]?.stringValue ?? viewerID
            apply(status: observed)
            let url = await backend.displaySocketURL(ticket: ticket, path: observed["path"]?.stringValue ?? "api/display/ws")
            open(url)
        } catch {
            phase = .closed(error.localizedDescription)
        }
    }

    private func open(_ url: URL) {
        decoder = RFBDecoder()
        framebuffer = RFBFramebuffer()
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 64 * 1024 * 1024
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard case .data(let data) = message else { continue }
                    self?.feed(data)
                } catch {
                    self?.socketEnded(socket)
                    return
                }
            }
        }
    }

    private func feed(_ data: Data) {
        var drew = false
        for event in decoder.feed(data) {
            switch event {
            case .send(let bytes):
                socket?.send(.data(bytes)) { _ in }
            case .ready(let width, let height, let name):
                framebuffer.apply(event)
                size = CGSize(width: width, height: height)
                desktopName = name
                phase = .live
                retriedTicket = false
            case .resized(let width, let height):
                framebuffer.apply(event)
                size = CGSize(width: width, height: height)
            case .updateDone:
                drew = true
            case .failed(let reason):
                phase = .closed(reason)
                socket?.cancel(with: .normalClosure, reason: nil)
            default:
                framebuffer.apply(event)
            }
        }
        if drew { image = Self.makeImage(framebuffer) }
    }

    private func socketEnded(_ ended: URLSessionWebSocketTask) {
        guard ended === socket else { return }
        let code = ended.closeCode.rawValue
        socket = nil
        switch code {
        case 4000:
            phase = .closed(String(localized: "Someone else took control of the screen."))
        case 4001:
            phase = .closed(String(localized: "Hermes's screen stopped."))
        case 4401 where !retriedTicket:
            // The ticket expired on the way: ask for another once.
            retriedTicket = true
            phase = .idle
            Task { await connect() }
        case 4403:
            phase = .closed(String(localized: "The gateway doesn't allow viewing its screen from here."))
        default:
            if case .closed = phase { return }
            phase = .closed(String(localized: "The screen disconnected."))
        }
    }

    func disconnect() {
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if phase == .live || phase == .connecting { phase = .idle }
    }

    private static func makeImage(_ framebuffer: RFBFramebuffer) -> CGImage? {
        guard framebuffer.width > 0, framebuffer.height > 0 else { return nil }
        let data = Data(framebuffer.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: framebuffer.width, height: framebuffer.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: framebuffer.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: Input (only while the person holds the lease)

    /// A pointer at a point in screen pixels, with buttons held.
    func pointer(at point: CGPoint, buttons: UInt8) {
        guard personInControl else { return }
        self.buttons = buttons
        socket?.send(.data(RFBMessages.pointer(x: Int(point.x), y: Int(point.y), buttons: buttons))) { _ in }
    }

    func click(at point: CGPoint) {
        pointer(at: point, buttons: 1)
        pointer(at: point, buttons: 0)
    }

    /// A scroll step: wheel up (bit 3) or down (bit 4).
    func scroll(at point: CGPoint, up: Bool) {
        let bit: UInt8 = up ? 8 : 16
        pointer(at: point, buttons: bit)
        pointer(at: point, buttons: 0)
    }

    func type(_ text: String) {
        for character in text {
            guard let keysym = RFBMessages.keysym(for: character) else { continue }
            key(keysym)
        }
    }

    func key(_ keysym: UInt32) {
        guard personInControl else { return }
        socket?.send(.data(RFBMessages.key(keysym, down: true))) { _ in }
        socket?.send(.data(RFBMessages.key(keysym, down: false))) { _ in }
    }

    private func releaseButtons() {
        guard buttons != 0 else { return }
        buttons = 0
        socket?.send(.data(RFBMessages.pointer(x: 0, y: 0, buttons: 0))) { _ in }
    }
}
