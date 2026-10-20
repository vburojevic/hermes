import Foundation
import Testing
@testable import HermesKit

private func json(_ text: String) -> JSONValue {
    JSONValue.parse(text) ?? .null
}

private actor Calls {
    var list: [(method: String, params: [String: JSONValue])] = []
    func add(_ method: String, _ params: [String: JSONValue]) { list.append((method, params)) }
}

private let ulidA = "01JABCDEFGHJKMNPQRSTVWXYZ0"
private let ulidB = "01JABCDEFGHJKMNPQRSTVWXYZ1"

@Suite("Apps and Tools")
struct ConnectionsTests {
    @Test func readsAppsAccountsAndTools() throws {
        let list = json("""
        {"available": true, "connectors": [
          {"connector": "github", "enabled": true, "connected": true, "connection_status": "active", "status_reason": null, "gateway_disabled_tools": []},
          {"connector": "linear", "enabled": true, "connected": true, "connection_status": "expired", "status_reason": "token revoked", "gateway_disabled_tools": ["linear_delete_issue"]}
        ]}
        """)
        let rows = list["connectors"].items.compactMap(ConnectorRow.init(json:))
        #expect(rows.map(\.connector) == ["github", "linear"])
        #expect(!rows[0].needsAttention && rows[1].needsAttention)
        #expect(rows[1].gatewayDisabledTools == ["linear_delete_issue"])

        let account = try #require(ConnectorAccount(json: json("""
        {"connection_id": "ca_1", "connector": "github", "status": "active", "label": "sam-rivera", "alias": "personal", "active": true, "created_at": "2026-10-01T09:00:00Z", "updated_at": "2026-10-12T09:00:00.123456+00:00"}
        """)))
        #expect(account.title == "personal" && account.active && account.updatedAt != nil)

        let tools = ConnectorToolList(json: json("""
        {"connector": "github", "toolkit_version": "1", "etag": "x", "fetched_at": 0, "source": "cache", "stale": false, "tools": [
          {"slug": "GITHUB_LIST_ISSUES", "name": "List issues", "description": "", "facet": "read", "hints": [], "categories": [], "no_auth": false, "deprecated": false},
          {"slug": "GITHUB_DELETE_REPO", "name": "Delete repository", "description": "", "facet": "destructive", "hints": [], "categories": [], "no_auth": false, "deprecated": false},
          {"slug": "GITHUB_ODD", "name": "Odd", "facet": "something-new"}
        ]}
        """))
        #expect(tools.tools.map(\.facet) == [.read, .destructive, .unclassified])
    }

    @Test func policyLayersLockAndUnlock() {
        let policy = ConnectorPolicy(json: json("""
        {"layers": [
          {"kind": "org", "revision": "\(ulidA)", "body": {"mode": "deny", "disabled_connectors": [], "tools": {"github": ["GITHUB_DELETE_REPO"]}}},
          {"kind": "member", "revision": "\(ulidB)", "body": {"mode": "deny", "disabled_connectors": [], "tools": {"github": ["GITHUB_MERGE"]}}}
        ], "effective": {"version": 1, "revision": "\(ulidB)", "issued_at_ms": 0, "mode": "deny", "disabled_connectors": [], "tools": {"github": ["GITHUB_DELETE_REPO", "GITHUB_MERGE"]}}}
        """))
        #expect(policy.lockedByOrganization(tool: "GITHUB_DELETE_REPO", of: "github"))
        #expect(!policy.lockedByOrganization(tool: "GITHUB_MERGE", of: "github"))
        #expect(!policy.allows(tool: "GITHUB_MERGE", of: "github"))
        #expect(policy.allows(tool: "GITHUB_LIST_ISSUES", of: "github"))
        #expect(policy.memberDisabledTools(of: "github") == ["GITHUB_MERGE"])
        #expect(policy.memberHasRule(for: "github") && !policy.memberHasRule(for: "gmail"))
        #expect(policy.expectedRevision == ulidB)
    }

    /// Someone else changed the policy: the client re-reads and rebuilds the change from the fresh
    /// member layer, then retries once with its revision.
    @Test func policyConflictRereadsAndRetries() async throws {
        let calls = Calls()
        let fresh = json("""
        {"layers": [{"kind": "member", "revision": "\(ulidB)", "body": {"mode": "deny", "disabled_connectors": [], "tools": {"github": ["GITHUB_MERGE"]}}}],
         "effective": {"version": 1, "revision": "\(ulidB)", "issued_at_ms": 0, "mode": "deny", "disabled_connectors": [], "tools": {"github": ["GITHUB_MERGE"]}}}
        """)
        let client = ConnectionsClient(profile: "cofounder") { method, params in
            await calls.add(method, params)
            if method == "connectors.policy.set", params["expected_revision"] == .string(ulidA) {
                var error = GatewayRPCError(code: 4090, message: "conflict")
                error.data = .object(["reason": .string("POLICY_CONFLICT")])
                throw error
            }
            return method == "connectors.policy.get" ? fresh : .object(["revision": .string(ulidB)])
        }
        let stale = ConnectorPolicy(layers: [.init(kind: .member, revision: ulidA, rules: .init(mode: "deny"))], effective: .init(mode: "deny"), effectiveRevision: ulidA)
        let result = try await client.setPolicy(stale) { policy in
            .tools(connector: "github", disabled: policy.memberDisabledTools(of: "github") + ["GITHUB_DELETE_REPO"])
        }
        #expect(result.memberDisabledTools(of: "github") == ["GITHUB_MERGE"])
        let sets = await calls.list.filter { $0.method == "connectors.policy.set" }
        #expect(sets.count == 2)
        #expect(sets[1].params["expected_revision"] == .string(ulidB))
        // The retry kept what the other writer blocked.
        #expect(sets[1].params["change"]?["disabled_tools"] == .array([.string("GITHUB_MERGE"), .string("GITHUB_DELETE_REPO")]))
        #expect(await calls.list.allSatisfy { $0.params["profile"] == .string("cofounder") })
    }

    @Test func connectSendsTheAccountOwnerAndOneAccount() async throws {
        let calls = Calls()
        let client = ConnectionsClient(profile: nil) { method, params in
            await calls.add(method, params)
            return json(#"{"op_id": "op_1", "seq": 1, "deadline_at": 2000000000, "settled": false, "targets": [{"name": "github", "kind": "connector", "action": "connect", "state": "initiated", "connect_url": "https://connect.example/x", "alias": "work"}]}"#)
        }
        let operation = try await client.connect("github", alias: "work")
        #expect(operation.signInTarget?.connectURL?.host() == "connect.example")
        #expect(operation.signInTarget?.alias == "work")
        _ = try await client.connect("linear", reconnect: true, connectionID: "ca_9")
        let list = await calls.list
        #expect(list[0].params["owner"] == .object(["type": .string("account")]))
        #expect(list[0].params["alias"] == .string("work") && list[0].params["reconnect"] == nil)
        #expect(list[1].params["reconnect"] == .bool(true) && list[1].params["connection_id"] == .string("ca_9"))
        #expect(list.allSatisfy { $0.params["profile"] == nil })
    }

    @Test func operationsKeepTheNewerFrame() throws {
        let older = try #require(ConnectionOperation(json: json(#"{"op_id": "op", "seq": 5, "deadline_at": 0, "settled": false, "targets": [{"name": "gmail", "kind": "connector", "action": "connect", "state": "initiated"}]}"#)))
        let newer = try #require(ConnectionOperation(json: json(#"{"op_id": "op", "seq": 6, "deadline_at": 0, "settled": true, "settled_by": "all_resolved", "targets": [{"name": "gmail", "kind": "connector", "action": "connect", "state": "connected"}]}"#)))
        #expect(older.merged(with: newer).succeeded)
        #expect(newer.merged(with: older).seq == 6)
        #expect(newer.isFinished && !older.isFinished)
    }

    @Test func chatCardsReadTierAndScan() throws {
        let target = try #require(HermesRequest.Target(json: json(#"{"name": "xcode", "kind": "plugin", "action": "install", "state": "pending", "tier": "official", "scan": {"status": "passed", "summary": "ok"}}"#)))
        #expect(target.origin == "official" && target.scan == "passed" && target.isAddOn)
    }

    @Test func mcpServersJoinTheirLiveStateAndToggleWholeServers() async throws {
        let calls = Calls()
        let client = ConnectionsClient(profile: "engineer") { method, params in
            await calls.add(method, params)
            switch method {
            case "mcp.servers.list":
                return json(#"{"servers": [{"name": "sentry", "transport": "http", "url": "https://mcp.sentry.dev/sse", "args": [], "env": ["SENTRY_TOKEN"], "auth": "header", "enabled": true, "source": "config"}, {"name": "github", "transport": "stdio", "command": "npx", "args": ["-y", "@github/mcp"], "env": [], "enabled": true, "source": "plugin", "plugin": "github-tools"}]}"#)
            case "mcp.servers.status":
                return json(#"{"servers": [{"name": "sentry", "transport": "http", "tools": 0, "connected": false, "disabled": false, "status": "failed", "source": "config"}, {"name": "github", "transport": "stdio", "tools": 26, "connected": true, "disabled": false, "status": "connected", "source": "plugin"}], "checked_at": 0}"#)
            case "toolsets.list":
                return json(#"{"toolsets": [{"name": "terminal", "description": "Run commands", "tool_count": 3, "enabled": true}]}"#)
            default:
                return .object(["ok": .bool(true)])
            }
        }
        let servers = try await client.mcpServers()
        #expect(servers[0].status == .failed && servers[0].envKeys == ["SENTRY_TOKEN"])
        #expect(servers[1].isFromPlugin && servers[1].toolCount == 26 && servers[1].address == "npx -y @github/mcp")
        try await client.setEnabledServers(["github"])
        try await client.reloadMCP()
        _ = try await client.toolsets()
        let list = await calls.list
        let configure = try #require(list.first { $0.method == "profiles.configure" })
        #expect(configure.params["enabled_mcp_servers"] == .array([.string("github")]))
        #expect(configure.params["profile"] == .string("engineer"))
        // Their params have no `profile`: Hermes would answer 4000.
        #expect(list.first { $0.method == "reload.mcp" }?.params["profile"] == nil)
        #expect(list.first { $0.method == "toolsets.list" }?.params["profile"] == nil)
    }

    /// Hermes answers a widening update with the lines to show and changes nothing.
    @Test func pluginUpdateAsksBeforeWideningAccess() throws {
        let update = PluginActionResult(json: json(#"{"ok": false, "consent_required": true, "delta": {"shell": ["run"]}, "delta_lines": ["Run shell commands on Studio Mac", "Add a hook that runs before every turn"]}"#))
        #expect(update.consentRequired && !update.ok && update.deltaLines.count == 2)

        let plugin = try #require(HermesPlugin(json: json(#"{"name": "blender", "key": "blender", "version": "2.1", "description": "", "source": "user", "status": "enabled", "portable": true, "install_dir": "", "has_desktop_half": true, "servers": [{"name": "blender", "state": "app_not_running", "sentence": "Blender isn't running on Studio Mac"}], "catalog_tier": "official", "update_available": false, "settings_schema": [{"key": "api_key", "type": "secret", "label": "API key", "description": "", "required": true, "value": "should-never-be-read", "env": "BLENDER_KEY", "has_value": true}]}"#)))
        #expect(plugin.problem == "Blender isn't running on Studio Mac")
        #expect(plugin.settings[0].value == nil && plugin.settings[0].hasValue && plugin.settings[0].env == "BLENDER_KEY")
    }

    /// The live gateway sends each preset's transport as the Python object's repr.
    @Test func presetsReadTheTransportRepr() throws {
        let live = try #require(McpPreset(json: json(#"{"name": "notion", "description": "Pages", "requires": [], "transport": "TransportSpec(type='http', url='https://mcp.notion.com/mcp', command=None)", "installed": false, "enabled": false}"#)))
        #expect(live.transport == "http")
        let plain = try #require(McpPreset(json: json(#"{"name": "brave-search", "requires": ["BRAVE_API_KEY"], "transport": "stdio"}"#)))
        #expect(plain.transport == "stdio" && plain.requires == ["BRAVE_API_KEY"])
        #expect(McpPreset.transport(nil) == "stdio")
    }

    /// Plugin rows as the live gateway writes them: `not enabled`, and bundled ones can't be removed.
    @Test func pluginsReadStatusAndSource() throws {
        let bundled = try #require(HermesPlugin(json: json(#"{"name": "memory", "key": "memory", "source": "bundled", "status": "not enabled"}"#)))
        #expect(!bundled.isEnabled && bundled.isBundled && !bundled.canRemove)
        let git = try #require(HermesPlugin(json: json(#"{"name": "homeassistant", "key": "homeassistant", "source": "git", "status": "enabled", "update_available": true}"#)))
        #expect(git.isEnabled && git.canRemove && git.updateAvailable)
    }

    @Test func everyReasonHasAPlainLine() {
        for reason in ConnectorErrorReason.allCases {
            #expect(!reason.line.isEmpty)
            #expect(!reason.line.contains(reason.rawValue))
        }
        var error = GatewayRPCError(code: 4032, message: "Sign in to use connectors.")
        error.data = .object(["reason": .string("NEEDS_NOUS_AUTH")])
        #expect(ConnectorErrorReason(error: error) == .needsNousAuth)
        #expect(ConnectorErrorReason.line(for: error) == ConnectorErrorReason.needsNousAuth.line)
    }
}
