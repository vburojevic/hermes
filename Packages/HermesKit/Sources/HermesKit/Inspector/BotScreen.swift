import Foundation

/// `display.status` (`docs/inspector.md` §2.6): whether a Bot's own desktop on the gateway can run,
/// runs, and who holds its lease. Read from `tools/bot_desktop/runtime.py` (`DesktopStatus`) and
/// `lease.public_view` in the Hermes Agent source.
public struct BotScreenStatus: Equatable, Sendable {
    /// A Linux host. macOS and Windows hosts have a real display, and Hermes offers no Screen there.
    public var supported: Bool
    /// TigerVNC and the Xfce core are on the host.
    public var installed: Bool
    public var running: Bool
    /// The packages' binaries that are missing.
    public var missing: [String]
    /// The distro's install line, as the person would type it on the host; nil when there's no
    /// package manager, or the screen runs in a sandbox.
    public var installCommand: String?
    /// Why starting it would be refused right now (memory, a sandbox image without the desktop).
    public var blocker: String?
    public var geometry: String?
    /// `agent` or `human`.
    public var holder: String
    public var viewerHash: String?
    public var reason: String?

    public init(
        supported: Bool, installed: Bool, running: Bool, missing: [String] = [], installCommand: String? = nil,
        blocker: String? = nil, geometry: String? = nil, holder: String = "agent", viewerHash: String? = nil, reason: String? = nil
    ) {
        self.supported = supported
        self.installed = installed
        self.running = running
        self.missing = missing
        self.installCommand = installCommand
        self.blocker = blocker
        self.geometry = geometry
        self.holder = holder
        self.viewerHash = viewerHash
        self.reason = reason
    }

    public init(json: JSONValue) {
        supported = json["supported"]?.boolValue ?? false
        installed = json["installed"]?.boolValue ?? false
        running = json["running"]?.boolValue ?? false
        missing = json["missing"]?.arrayValue?.compactMap(\.stringValue) ?? []
        installCommand = json["install_command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        blocker = json["blocker"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        geometry = json["geometry"]?.stringValue
        holder = json["lease"]?["holder"]?.stringValue ?? "agent"
        viewerHash = json["lease"]?["viewer_hash"]?.stringValue
        reason = json["lease"]?["reason"]?.stringValue
    }

    /// `display.lease`, broadcast to every client when control moves.
    public mutating func apply(lease payload: JSONValue) {
        guard let lease = payload["lease"] else { return }
        holder = lease["holder"]?.stringValue ?? "agent"
        viewerHash = lease["viewer_hash"]?.stringValue
        reason = lease["reason"]?.stringValue
    }

    /// Open Screen in a Bot's ··· menu: on any host that can give the Bot a screen, running or
    /// not, since the Screen tab says what's missing and starts it. Hermes Desktop's roster menu
    /// has it always; this hides it where Hermes offers no Screen at all.
    public static func offersOpenScreen(_ status: BotScreenStatus?) -> Bool {
        status?.supported == true
    }
}
