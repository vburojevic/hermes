import CryptoKit
import Foundation

/// Which Hermes app sends a turn, as the widgets plugin's `/app-widgets client` takes it
/// (`docs/widgets.md` §11): the app, its version, the system and the kind of device, and what it
/// draws. The plugin tells the model only how to format; it never grants anything.
///
/// It holds nothing that names a person or a device: no device name, no identifier and nothing
/// typed. The plugin checks each value against a short list or pattern and refuses anything else.
public struct ClientApp: Sendable, Hashable {
    public enum Device: String, Sendable, Hashable, CaseIterable {
        case iphone, ipad, mac

        /// The system's name as the plugin lists it: an iPad says iPadOS.
        public var os: String {
            switch self {
            case .iphone: "iOS"
            case .ipad: "iPadOS"
            case .mac: "macOS"
            }
        }
    }

    /// What the app draws in a reply, in the plugin's words (`CLIENT_RENDERS` in its `core.py`).
    public enum Render: String, Sendable, Hashable, CaseIterable {
        case widgets
        case gatewayFileImages = "gateway-file-images"
        /// Files sent with `MEDIA:` lines: pictures and videos drawn in the reply, other files as
        /// cards that open or save them (`docs/chat.md` §3a).
        case gatewayFiles = "gateway-files"
        case markdown, code, tables
        /// A ```` ```mermaid ```` fence drawn as the diagram (`docs/chat.md` §3b).
        case diagrams
        /// A `$$…$$` or `\[…\]` block drawn as a formula; inline `$…$` stays words (§3b).
        case math
        /// A ```` ```svg ```` fence or one whole `<svg>` paragraph drawn as a picture (§3b).
        case svg
        /// A `::preview{file=…}` line shown as a live page (§3c).
        case livePages = "live-pages"
        /// Word, Excel, PowerPoint, rich text and iWork files opened in Quick Look (§3a).
        case officeFiles = "office-files"
        /// A link alone on its line to YouTube, Vimeo, Spotify, SoundCloud, GitHub or Bilibili
        /// shown as a card (§3d).
        case linkCards = "link-cards"

        /// The values plugin 1.6.0 knows. It refuses a client that names any other, and its
        /// client line is lost with it (`ClientAnnouncements`).
        public static let knownSince160: Set<Render> = [.widgets, .gatewayFileImages, .markdown, .code, .tables]
    }

    public static let id = "hermes-app"
    /// Everything but widgets, which the gateway's widget store answers for (`WidgetStore`).
    public static let alwaysRenders: [Render] = [.gatewayFileImages, .gatewayFiles, .markdown, .code, .tables,
                                                 .diagrams, .math, .svg, .livePages, .officeFiles, .linkCards]

    public let version: String
    public let build: String
    public let device: Device
    public let osVersion: String
    public let renders: [Render]

    public init(version: String, build: String, device: Device, osVersion: String, renders: [Render]) {
        self.version = version
        self.build = build
        self.device = device
        self.osVersion = osVersion
        // In the plugin's order, each once: it refuses a list that repeats one.
        self.renders = Render.allCases.filter(renders.contains)
    }

    /// The same client naming only what plugin 1.6.0 knows.
    public var withRendersKnownSince160: ClientApp {
        ClientApp(version: version, build: build, device: device, osVersion: osVersion,
                  renders: renders.filter(Render.knownSince160.contains))
    }

    /// "26.1", or "26.1.2" when there is a patch.
    public static func osVersion(_ version: OperatingSystemVersion) -> String {
        let parts = [version.majorVersion, version.minorVersion] + (version.patchVersion > 0 ? [version.patchVersion] : [])
        return parts.map(String.init).joined(separator: ".")
    }

    /// The `client` object of `/app-widgets client`.
    public var json: [String: JSONValue] {
        [
            "id": .string(Self.id),
            "version": .string(version),
            "build": .string(build),
            "os": .string(device.os),
            "os_version": .string(osVersion),
            "device": .string(device.rawValue),
            "renders": .array(renders.map { .string($0.rawValue) }),
        ]
    }

    /// The hash the plugin matches a turn by: SHA-256 of the text's UTF-8 bytes exactly as it goes
    /// to `prompt.submit`, nothing trimmed or normalised, as lowercase hex
    /// (`Tools/hermes-app-widgets/tests/client_vectors.json`).
    public static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Which profiles of one gateway can't be told the client (`docs/widgets.md` §11): a plugin older
/// than 1.6.0 doesn't know the command, and a profile without the plugin answers 4018. Those
/// aren't asked again every turn, only once the plugin may have changed (an install, an update, a
/// new connection).
public struct ClientAnnouncements: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case announced
        /// The plugin is missing or older than 1.6.0.
        case unsupported
        /// Anything else (a timeout, a refusal, a dropped socket): the turn goes on, and the next asks again.
        case failed
    }

    private var unsupported: Set<String> = []
    /// Profiles whose plugin refused a render value it doesn't know (1.6.0): told only the ones
    /// it knows, until the plugin may have changed.
    private var olderRenders: Set<String> = []

    public init() {}

    public func shouldAnnounce(profile: String?) -> Bool {
        !unsupported.contains(Self.key(profile))
    }

    /// The client as `profile`'s plugin takes it: without the render values a plugin that
    /// refused them doesn't know.
    public func client(_ client: ClientApp, profile: String?) -> ClientApp {
        olderRenders.contains(Self.key(profile)) ? client.withRendersKnownSince160 : client
    }

    public mutating func record(_ outcome: Outcome, profile: String?) {
        switch outcome {
        case .unsupported: unsupported.insert(Self.key(profile))
        case .announced: unsupported.remove(Self.key(profile))
        case .failed: break
        }
    }

    /// `profile`'s plugin refused a render value it doesn't know.
    public mutating func recordOlderRenders(profile: String?) {
        olderRenders.insert(Self.key(profile))
    }

    /// The plugin may have changed: every profile is asked again, with everything the app draws.
    public mutating func forgetUnsupported() {
        unsupported.removeAll()
        olderRenders.removeAll()
    }

    public static func outcome(of error: any Error) -> Outcome {
        switch error as? AppWidgetsClient.Failure {
        case .notInstalled?:
            return .unsupported
        case .refused(let message)? where message.hasPrefix("unknown command"):
            return .unsupported
        default:
            return .failed
        }
    }

    /// The plugin refused the client for its render values: 1.6.0 refuses any it doesn't know
    /// ("client.renders must list distinct values from …").
    public static func refusesRenders(_ error: any Error) -> Bool {
        if case .refused(let message)? = error as? AppWidgetsClient.Failure { return message.hasPrefix("client.renders") }
        return false
    }

    private static func key(_ profile: String?) -> String {
        profile ?? "default"
    }
}
