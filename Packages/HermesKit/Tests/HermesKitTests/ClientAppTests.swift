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

    // MARK: What the app draws (`gateway-files`) and an older plugin

    private static let drawsFiles = ClientApp(version: "1.1", build: "2611230900", device: .mac, osVersion: "27.2",
                                          renders: ClientApp.alwaysRenders + [.widgets])

    /// A plugin as 1.6.0 checks `client.renders` (`core.py` `_client_args`): any value it doesn't
    /// know refuses the whole client.
    private final class Sent: Sendable {
        let renders = Mutex<[[String]]>([])
    }

    private static func plugin160(_ sent: Sent) -> AppWidgetsClient {
        AppWidgetsClient { _, params in
            let arg = params["arg"]?.stringValue ?? ""
            let arguments = JSONValue.parse(Data(arg.dropFirst("client ".count).utf8))
            let renders = arguments?["client"]?["renders"]?.arrayValue?.compactMap(\.stringValue) ?? []
            sent.renders.withLock { $0.append(renders) }
            let known: Set = ["widgets", "gateway-file-images", "markdown", "code", "tables"]
            if !renders.allSatisfy(known.contains) {
                return ["type": "plugin", "output": #"{"ok":false,"error":"client.renders must list distinct values from widgets, gateway-file-images, markdown, code, tables"}"#]
            }
            return ["type": "plugin", "output": #"{"ok":true,"pending":1}"#]
        }
    }

    @Test func theAppSaysItDrawsGatewayFiles() {
        #expect(Self.drawsFiles.json["renders"]?.arrayValue?.compactMap(\.stringValue)
                == ["widgets", "gateway-file-images", "gateway-files", "markdown", "code", "tables",
                    "diagrams", "math", "svg", "live-pages", "office-files", "link-cards"])
        #expect(Self.drawsFiles.withRendersKnownSince160.renders == [.widgets, .gatewayFileImages, .markdown, .code, .tables])
    }

    /// Every value fits what a tolerant plugin keeps (`RENDER_VALUE`, at most 16 in its `core.py`), so
    /// a newer plugin never refuses the client for one of them, and the app names everything it draws.
    @Test func everyRenderValueFitsThePluginsCheck() throws {
        let pattern = try Regex("^[a-z][a-z0-9-]{0,31}$")
        #expect(ClientApp.Render.allCases.count <= 16)
        for render in ClientApp.Render.allCases {
            #expect(render.rawValue.wholeMatch(of: pattern) != nil, "\(render.rawValue)")
        }
        #expect(Set(ClientApp.alwaysRenders + [.widgets]) == Set(ClientApp.Render.allCases))
    }

    @Test func aPluginThatRefusesTheNewValueStillGetsTheClient() async throws {
        let sent = Sent()
        let older = try await Self.plugin160(sent).announceClientKnownRenders(
            runtimeID: "rt", storedID: "st", client: Self.drawsFiles, textHash: ClientApp.textHash("hi"))
        #expect(older)
        #expect(sent.renders.withLock { $0 } == [
            ["widgets", "gateway-file-images", "gateway-files", "markdown", "code", "tables",
             "diagrams", "math", "svg", "live-pages", "office-files", "link-cards"],
            ["widgets", "gateway-file-images", "markdown", "code", "tables"],
        ])
        // Remembered for that profile, until the plugin may have changed.
        var announcements = ClientAnnouncements()
        announcements.recordOlderRenders(profile: "ops")
        #expect(announcements.client(Self.drawsFiles, profile: "ops").renders == Self.drawsFiles.withRendersKnownSince160.renders)
        #expect(announcements.client(Self.drawsFiles, profile: nil).renders == Self.drawsFiles.renders)
        announcements.forgetUnsupported()
        #expect(announcements.client(Self.drawsFiles, profile: "ops").renders == Self.drawsFiles.renders)
    }

    @Test func aPluginThatKnowsTheValueIsToldOnce() async throws {
        let sent = Sent()
        let widgets = AppWidgetsClient { _, params in
            sent.renders.withLock { $0.append([params["arg"]?.stringValue ?? ""]) }
            return ["type": "plugin", "output": #"{"ok":true,"pending":1}"#]
        }
        let older = try await widgets.announceClientKnownRenders(runtimeID: "rt", storedID: "st", client: Self.drawsFiles, textHash: ClientApp.textHash("hi"))
        #expect(!older)
        #expect(sent.renders.withLock { $0.count } == 1)
        // Other refusals aren't retried.
        let refusing = AppWidgetsClient { _, _ in ["type": "plugin", "output": #"{"ok":false,"error":"turn must be {\"text_sha256\": ...}"}"#] }
        await #expect(throws: AppWidgetsClient.Failure.self) {
            try await refusing.announceClientKnownRenders(runtimeID: "rt", storedID: "st", client: Self.drawsFiles, textHash: "x")
        }
    }
}
