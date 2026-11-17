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
        case markdown, code, tables
    }

    public static let id = "hermes-app"
    /// Everything but widgets, which the gateway's widget store answers for (`WidgetStore`).
    public static let alwaysRenders: [Render] = [.gatewayFileImages, .markdown, .code, .tables]

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

    public init() {}

    public func shouldAnnounce(profile: String?) -> Bool {
        !unsupported.contains(Self.key(profile))
    }

    public mutating func record(_ outcome: Outcome, profile: String?) {
        switch outcome {
        case .unsupported: unsupported.insert(Self.key(profile))
        case .announced: unsupported.remove(Self.key(profile))
        case .failed: break
        }
    }

    /// The plugin may have changed: every profile is asked again.
    public mutating func forgetUnsupported() {
        unsupported.removeAll()
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

    private static func key(_ profile: String?) -> String {
        profile ?? "default"
    }
}
