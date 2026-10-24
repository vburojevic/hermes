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

    @ObservationIgnored private weak var inspector: InspectorModel?
    private(set) var status: BotScreenStatus?
    /// Starting the screen (`display.start`), and why it didn't.
    private(set) var isStarting = false
    var startError: String?
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

    /// What's missing while it doesn't run: stopped, not installed, or no screen on this host
    /// (`docs/setup.md` §4.21).
    var setup: SetupStatus? {
        guard let status, let inspector else { return nil }
        return GatewaySetup.screen(status, profile: inspector.profile, gatewayName: inspector.gatewayMachineName)
    }

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
        status?.apply(lease: payload)
    }

    private func apply(status json: JSONValue) {
        status = BotScreenStatus(json: json)
    }

    /// Start Screen (`display.start`): Hermes starts the Bot's desktop and answers with its
    /// status, or says why it can't (missing packages, too little memory).
    func start() async {
        guard let roster = inspector?.workspace?.roster, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let result = try await roster.request("display.start", profileParams, timeout: .seconds(45))
            apply(status: result)
            startError = nil
        } catch {
            startError = error.localizedDescription
            await refreshStatus()
            return
        }
        if isAvailable {
            phase = .idle
            await connect()
        }
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

    /// Bumped by every disconnect: a connect still waiting on the gateway doesn't open a socket
    /// after the person left.
    @ObservationIgnored private var attempts = 0

    func connect() async {
        guard phase != .connecting, phase != .live else { return }
        guard let roster = inspector?.workspace?.roster, let backend = inspector?.backend else { return }
        attempts += 1
        let attempt = attempts
        phase = .connecting
        var params = profileParams
        if let viewerID { params["viewer_id"] = .string(viewerID) }
        do {
            let observed = try await roster.request("display.observe", params, timeout: .seconds(20))
            guard attempt == attempts else { return }
            guard let ticket = observed["ticket"]?.stringValue else {
                phase = .closed(String(localized: "The gateway didn't open the screen."))
                return
            }
            viewerID = observed["viewer_id"]?.stringValue ?? viewerID
            apply(status: observed)
            let url = await backend.displaySocketURL(ticket: ticket, path: observed["path"]?.stringValue ?? "api/display/ws")
            guard attempt == attempts else { return }
            open(url)
        } catch {
            guard attempt == attempts else { return }
            phase = .closed(error.localizedDescription)
            // Refused because it isn't running: the tab says so, with Start Screen.
            await refreshStatus()
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
            // The tab shows Start Screen in its place.
            status?.running = false
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
        attempts += 1
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

    /// Keys from the person's keyboard (`ScreenKeyboard`), in order.
    func send(_ strokes: [ScreenKeyboard.Stroke]) {
        guard personInControl else { return }
        for stroke in strokes {
            socket?.send(.data(RFBMessages.key(stroke.keysym, down: stroke.down))) { _ in }
        }
    }

    private func releaseButtons() {
        guard buttons != 0 else { return }
        buttons = 0
        socket?.send(.data(RFBMessages.pointer(x: 0, y: 0, buttons: 0))) { _ in }
    }
}
