import Foundation
import Synchronization
import Testing
@testable import HermesKit

/// Which app sends a turn (`/app-widgets client`, plugin 1.6.0, `docs/widgets.md` §11): the text's
/// hash, what the client carries, and how an older plugin is remembered.
@Suite("Which app sends a turn")
struct ClientAppTests {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let text: String
            let sha256: String
        }
        let cases: [Case]
    }

    private static let client = ClientApp(
        version: "1.0", build: "2611170727", device: .ipad, osVersion: "26.1",
        renders: [.tables, .widgets, .markdown, .tables, .code, .gatewayFileImages])

    /// The plugin hashes the same bytes: both sides read the plugin's vectors.
    @Test func theHashMatchesThePluginsVectors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../Tools/hermes-app-widgets/tests/client_vectors.json").standardizedFileURL
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        #expect(vectors.cases.count >= 5)
        for vector in vectors.cases {
            #expect(ClientApp.textHash(vector.text) == vector.sha256, "\(vector.name)")
        }
    }

    @Test func theClientCarriesOnlyThePluginsFields() throws {
        let json = Self.client.json
        #expect(Set(json.keys) == ["id", "version", "build", "os", "os_version", "device", "renders"])
        #expect(json["id"]?.stringValue == "hermes-app")
        #expect(json["os"]?.stringValue == "iPadOS")
        #expect(json["device"]?.stringValue == "ipad")
        // In the plugin's order, each once: it refuses a list that repeats one.
        #expect(json["renders"]?.arrayValue?.compactMap(\.stringValue) == ["widgets", "gateway-file-images", "markdown", "code", "tables"])
        // Each value passes the plugin's pattern (`CLIENT_FIELDS` in its `core.py`).
        let patterns = [
            "version": #"[0-9][0-9A-Za-z.+-]{0,19}"#, "build": #"[0-9A-Za-z.]{1,20}"#,
            "os_version": #"[0-9]{1,3}(\.[0-9]{1,3}){0,2}"#, "os": "iOS|iPadOS|macOS", "device": "iphone|ipad|mac",
        ]
        for (key, pattern) in patterns {
            let value = try #require(json[key]?.stringValue)
            #expect(value.wholeMatch(of: try Regex(pattern)) != nil, "\(key)")
        }
        #expect(ClientApp.Device.allCases.map(\.os) == ["iOS", "iPadOS", "macOS"])
    }

    @Test func theSystemVersionNamesAPatchOnlyWhenThereIsOne() {
        #expect(ClientApp.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)) == "26.1")
        #expect(ClientApp.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 2)) == "26.0.2")
    }

    /// The command and its arguments: both of the chat's ids, the client and the turn's hash, and
    /// nothing that names the device or what was typed.
    @Test func theAnnouncementSendsTheHashNotTheText() async throws {
        let sent = Mutex<[[String: JSONValue]]>([])
        let widgets = AppWidgetsClient(profile: "ops") { method, params in
            #expect(method == "command.dispatch")
            sent.withLock { $0.append(params) }
            return ["type": "plugin", "output": #"{"ok":true,"pending":1}"#]
        }
        let text = "Plan the offsite in Lisbon"
        let pending = try await widgets.announceClient(runtimeID: "rt-1", storedID: "st-1", client: Self.client, textHash: ClientApp.textHash(text))
        #expect(pending == 1)
        let params = try #require(sent.withLock { $0.first })
        #expect(params["name"] == "app-widgets")
        #expect(params["profile"] == "ops")
        #expect(params["session_id"]?.stringValue == "rt-1")
        let arg = try #require(params["arg"]?.stringValue)
        #expect(arg.hasPrefix("client {"))
        #expect(!arg.contains("Lisbon"), "the text itself never goes")
        let arguments = try #require(JSONValue.parse(Data(arg.dropFirst("client ".count).utf8)))
        #expect(arguments["session_id"]?.stringValue == "rt-1")
        #expect(arguments["stored_session_id"]?.stringValue == "st-1")
        #expect(arguments["turn"] == .object(["text_sha256": .string(ClientApp.textHash(text))]))
        #expect(arguments["client"] == .object(Self.client.json))
        if case .object(let object) = arguments { #expect(Set(object.keys) == ["session_id", "stored_session_id", "client", "turn"]) }
    }

    @Test func theAnswersAreRead() async throws {
        func announce(_ answer: @escaping @Sendable () throws -> JSONValue) async -> ClientAnnouncements.Outcome {
            let widgets = AppWidgetsClient { _, _ in try answer() }
            do {
                try await widgets.announceClient(runtimeID: "rt", storedID: "st", client: Self.client, textHash: ClientApp.textHash(""))
                return .announced
            } catch {
                return ClientAnnouncements.outcome(of: error)
            }
        }
        #expect(await announce { ["type": "plugin", "output": #"{"ok":true,"pending":2}"#] } == .announced)
        // Plugins older than 1.6.0 don't know the command; a profile without the plugin answers 4018.
        #expect(await announce { ["type": "plugin", "output": #"{"ok":false,"error":"unknown command 'client'"}"#] } == .unsupported)
        #expect(await announce { throw GatewayRPCError(code: 4018, message: "not a quick/plugin/bundle/skill command") } == .unsupported)
        // Anything else is this turn's problem only: the next turn asks again.
        #expect(await announce { ["type": "plugin", "output": #"{"ok":false,"error":"turn.text_sha256 must be 64 lowercase hex characters"}"#] } == .failed)
        #expect(await announce { throw URLError(.timedOut) } == .failed)
        #expect(await announce { ["type": "plugin", "output": "no json"] } == .failed)
    }

    @Test func anUnsupportedProfileIsAskedAgainOnlyOnceThePluginMayHaveChanged() {
        var announcements = ClientAnnouncements()
        #expect(announcements.shouldAnnounce(profile: nil))
        announcements.record(.unsupported, profile: nil)
        #expect(!announcements.shouldAnnounce(profile: nil))
        #expect(!announcements.shouldAnnounce(profile: "default"), "the root profile is one profile")
        #expect(announcements.shouldAnnounce(profile: "ops"), "each profile has its own plugin")
        announcements.record(.failed, profile: "ops")
        #expect(announcements.shouldAnnounce(profile: "ops"), "a failure is asked again next turn")
        announcements.record(.unsupported, profile: "ops")
        announcements.forgetUnsupported()
        #expect(announcements.shouldAnnounce(profile: nil) && announcements.shouldAnnounce(profile: "ops"))
        announcements.record(.unsupported, profile: "ops")
        announcements.record(.announced, profile: "ops")
        #expect(announcements.shouldAnnounce(profile: "ops"))
    }
}
