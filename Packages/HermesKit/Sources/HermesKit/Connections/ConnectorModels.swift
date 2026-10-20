import Foundation

// Apps: hosted connectors signed in through the person's Nous account
// (`tui_gateway/contracts/connectors.py`, `docs/connections.md` §3).

/// Where a connector account stands (`ConnectorAccountStatus`, `ConnectorRow.connection_status`).
public enum ConnectorStatus: String, Sendable, Hashable, CaseIterable {
    case pending, active, failed, expired, revoked, inactive

    /// Hermes can't use it until the person signs in again.
    public var needsAttention: Bool { self == .failed || self == .expired || self == .revoked }
}

/// One app on the gateway and its state (`ConnectorRow`).
public struct ConnectorRow: Sendable, Hashable, Identifiable {
    public var connector: String
    public var enabled: Bool
    public var connected: Bool
    public var status: ConnectorStatus?
    public var statusReason: String?
    /// Tools the gateway's own config turned off, whatever the policy says.
    public var gatewayDisabledTools: [String]

    public var id: String { connector }

    public init(connector: String, enabled: Bool = true, connected: Bool, status: ConnectorStatus? = nil, statusReason: String? = nil, gatewayDisabledTools: [String] = []) {
        self.connector = connector
        self.enabled = enabled
        self.connected = connected
        self.status = status
        self.statusReason = statusReason
        self.gatewayDisabledTools = gatewayDisabledTools
    }

    init?(json: JSONValue) {
        guard let connector = json["connector"]?.stringValue else { return nil }
        self.connector = connector
        enabled = json["enabled"]?.boolValue ?? true
        connected = json["connected"]?.boolValue ?? false
        status = json["connection_status"]?.stringValue.flatMap(ConnectorStatus.init(rawValue:))
        statusReason = json["status_reason"]?.stringValue
        gatewayDisabledTools = json["gateway_disabled_tools"].strings
    }

    public var needsAttention: Bool { status?.needsAttention ?? false }
}

/// An app that can be added (`ConnectorCatalogRow`).
public struct ConnectorCatalogEntry: Sendable, Hashable, Identifiable {
    public var slug: String
    public var name: String
    public var description: String
    public var category: String
    public var logoURL: URL?

    public var id: String { slug }

    public init(slug: String, name: String, description: String = "", category: String = "", logoURL: URL? = nil) {
        self.slug = slug
        self.name = name
        self.description = description
        self.category = category
        self.logoURL = logoURL
    }

    init?(json: JSONValue) {
        guard let slug = json["slug"]?.stringValue else { return nil }
        self.slug = slug
        name = json["name"]?.stringValue ?? slug
        description = json["description"]?.stringValue ?? ""
        category = json["category"]?.stringValue ?? ""
        logoURL = json["logo_url"]?.stringValue.flatMap(URL.init(string:))
    }
}

/// One signed-in account of an app (`ConnectorAccountRow`).
public struct ConnectorAccount: Sendable, Hashable, Identifiable {
    public var connectionID: String
    public var connector: String
    public var status: ConnectorStatus
    public var statusReason: String?
    /// What the app calls the account: an email or a handle.
    public var label: String
    /// The short name the person gave it ("personal", "work").
    public var alias: String?
    /// The account Hermes uses.
    public var active: Bool
    /// Replaced by a reconnect: kept for the record, never selectable.
    public var disabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public var id: String { connectionID }

    public init(connectionID: String, connector: String, status: ConnectorStatus = .active, label: String, alias: String? = nil, active: Bool = false, disabled: Bool = false, updatedAt: Date? = nil) {
        self.connectionID = connectionID
        self.connector = connector
        self.status = status
        self.label = label
        self.alias = alias
        self.active = active
        self.disabled = disabled
        self.updatedAt = updatedAt
    }

    init?(json: JSONValue) {
        guard let id = json["connection_id"]?.stringValue, let connector = json["connector"]?.stringValue else { return nil }
        connectionID = id
        self.connector = connector
        status = json["status"]?.stringValue.flatMap(ConnectorStatus.init(rawValue:)) ?? .inactive
        statusReason = json["status_reason"]?.stringValue
        label = json["label"]?.stringValue ?? ""
        alias = json["alias"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        active = json["active"]?.boolValue ?? false
        disabled = json["disabled"]?.boolValue ?? false
        createdAt = HermesDate.fromISO(json["created_at"]?.stringValue)
        updatedAt = HermesDate.fromISO(json["updated_at"]?.stringValue)
    }

    /// The alias, else the label.
    public var title: String { alias ?? label }
}

/// What a tool does to the app's data (`ConnectorToolFacet`).
public enum ToolFacet: String, Sendable, Hashable, CaseIterable {
    case read, write, destructive, unclassified
}

/// One tool an app brings (`ConnectorToolRow`).
public struct ConnectorTool: Sendable, Hashable, Identifiable {
    public var slug: String
    public var name: String
    public var description: String
    public var facet: ToolFacet
    public var deprecated: Bool

    public var id: String { slug }

    public init(slug: String, name: String, description: String = "", facet: ToolFacet, deprecated: Bool = false) {
        self.slug = slug
        self.name = name
        self.description = description
        self.facet = facet
        self.deprecated = deprecated
    }

    init?(json: JSONValue) {
        guard let slug = json["slug"]?.stringValue else { return nil }
        self.slug = slug
        name = json["name"]?.stringValue ?? slug
        description = json["description"]?.stringValue ?? ""
        facet = json["facet"]?.stringValue.flatMap(ToolFacet.init(rawValue:)) ?? .unclassified
        deprecated = json["deprecated"]?.boolValue ?? false
    }
}

/// An app's tool list (`ConnectorToolsResult`).
public struct ConnectorToolList: Sendable, Hashable {
    public var connector: String
    public var tools: [ConnectorTool]
    /// From the cache and not yet revalidated.
    public var stale: Bool

    public init(connector: String, tools: [ConnectorTool], stale: Bool = false) {
        self.connector = connector
        self.tools = tools
        self.stale = stale
    }

    init(json: JSONValue) {
        connector = json["connector"]?.stringValue ?? ""
        tools = json["tools"].items.compactMap(ConnectorTool.init(json:))
        stale = json["stale"]?.boolValue ?? false
    }
}

/// The layers that allow or block apps and tools, organization to member (`ConnectorPolicyGetResult`).
public struct ConnectorPolicy: Sendable, Hashable {
    public enum LayerKind: String, Sendable, Hashable { case org, role, member }

    /// One layer's rules. Both `allow` and `deny` bodies list each app's blocked tools.
    public struct Rules: Sendable, Hashable {
        /// `unrestricted`, `deny-all`, `allow` or `deny`.
        public var mode: String
        /// `allow`: the only apps it permits.
        public var allowedConnectors: [String]?
        /// `deny`: the apps it blocks.
        public var disabledConnectors: [String]
        /// Blocked tools by app.
        public var disabledTools: [String: [String]]

        public init(mode: String, allowedConnectors: [String]? = nil, disabledConnectors: [String] = [], disabledTools: [String: [String]] = [:]) {
            self.mode = mode
            self.allowedConnectors = allowedConnectors
            self.disabledConnectors = disabledConnectors
            self.disabledTools = disabledTools
        }

        init(json: JSONValue?) {
            mode = json?["mode"]?.stringValue ?? "unrestricted"
            allowedConnectors = mode == "allow" ? json?["connectors"].strings : nil
            disabledConnectors = json?["disabled_connectors"].strings ?? []
            var tools: [String: [String]] = [:]
            for (connector, names) in json?["tools"].fields ?? [:] { tools[connector] = names.strings }
            disabledTools = tools
        }

        public func blocks(connector: String) -> Bool {
            switch mode {
            case "deny-all": true
            case "allow": !(allowedConnectors ?? []).contains(connector)
            default: disabledConnectors.contains(connector)
            }
        }

        public func blocks(tool: String, of connector: String) -> Bool {
            mode == "deny-all" || (disabledTools[connector] ?? []).contains(tool)
        }
    }

    public struct Layer: Sendable, Hashable {
        public var kind: LayerKind
        public var revision: String
        public var rules: Rules

        public init(kind: LayerKind, revision: String, rules: Rules) {
            self.kind = kind
            self.revision = revision
            self.rules = rules
        }
    }

    public var layers: [Layer]
    public var effective: Rules
    public var effectiveRevision: String

    public init(layers: [Layer], effective: Rules, effectiveRevision: String) {
        self.layers = layers
        self.effective = effective
        self.effectiveRevision = effectiveRevision
    }

    init(json: JSONValue) {
        layers = json["layers"].items.compactMap { row in
            guard let kind = row["kind"]?.stringValue.flatMap(LayerKind.init(rawValue:)) else { return nil }
            return Layer(kind: kind, revision: row["revision"]?.stringValue ?? "", rules: Rules(json: row["body"]))
        }
        effective = Rules(json: json["effective"])
        effectiveRevision = json["effective"]?["revision"]?.stringValue ?? ""
    }

    public var member: Layer? { layers.first { $0.kind == .member } }

    /// The revision a change is checked against: the member's own layer, which the change rewrites.
    public var expectedRevision: String { member?.revision ?? effectiveRevision }

    /// Blocked above the member (organization or role): the person can't turn it back on.
    public func lockedByOrganization(tool: String, of connector: String) -> Bool {
        layers.contains { $0.kind != .member && ($0.rules.blocks(tool: tool, of: connector) || $0.rules.blocks(connector: connector)) }
    }

    public func lockedByOrganization(connector: String) -> Bool {
        layers.contains { $0.kind != .member && $0.rules.blocks(connector: connector) }
    }

    /// What the member layer blocks for one app.
    public func memberDisabledTools(of connector: String) -> [String] {
        member?.rules.disabledTools[connector] ?? []
    }

    /// The member layer says something about this app's tools (else defaults apply).
    public func memberHasRule(for connector: String) -> Bool {
        member?.rules.disabledTools[connector] != nil
    }

    public func allows(tool: String, of connector: String) -> Bool {
        !effective.blocks(tool: tool, of: connector) && !effective.blocks(connector: connector)
    }
}

/// One change to the member's policy (`ConnectorPolicyChange`).
public enum ConnectorPolicyChange: Sendable, Hashable {
    /// The full list of the app's tools the member blocks.
    case tools(connector: String, disabled: [String])
    case connector(String, enabled: Bool)

    var json: JSONValue {
        switch self {
        case .tools(let connector, let disabled):
            .object(["type": .string("tools"), "connector": .string(connector), "disabled_tools": .array(disabled.map(JSONValue.string))])
        case .connector(let connector, let enabled):
            .object(["type": .string("connector"), "connector": .string(connector), "enabled": .bool(enabled)])
        }
    }
}

/// Why a connector call failed (`ConnectorErrorReason`), in one plain line each.
public enum ConnectorErrorReason: String, Sendable, Hashable, CaseIterable {
    case invalidParams = "INVALID_PARAMS"
    case notOwner = "NOT_OWNER"
    case unsupportedRuntime = "UNSUPPORTED_RUNTIME"
    case connectorRequestFailed = "CONNECTOR_REQUEST_FAILED"
    case invalidConnectorResponse = "INVALID_CONNECTOR_RESPONSE"
    case unknownTarget = "UNKNOWN_TARGET"
    case linkStillValid = "LINK_STILL_VALID"
    case reissueRefused = "REISSUE_REFUSED"
    case unknownOperation = "UNKNOWN_OPERATION"
    case invalidAnswer = "INVALID_ANSWER"
    case needsNousAuth = "NEEDS_NOUS_AUTH"
    case connectorNotFound = "CONNECTOR_NOT_FOUND"
    case toolsUnavailable = "TOOLS_UNAVAILABLE"
    case connectorsUnavailable = "CONNECTORS_UNAVAILABLE"
    case catalogUnavailable = "CATALOG_UNAVAILABLE"
    case accountsUnavailable = "ACCOUNTS_UNAVAILABLE"
    case connectionNotFound = "CONNECTION_NOT_FOUND"
    case policyUnavailable = "POLICY_UNAVAILABLE"
    case policyConflict = "POLICY_CONFLICT"
    case forbiddenScope = "FORBIDDEN_SCOPE"
    case orgRequired = "ORG_REQUIRED"
    case orgAccessDenied = "ORG_ACCESS_DENIED"
    case invalidPolicy = "INVALID_POLICY"
    case aliasTaken = "ALIAS_TAKEN"

    /// The reason a gateway error carries in `data.reason`.
    public init?(error: any Error) {
        guard let error = error as? GatewayRPCError, let raw = error.data?["reason"]?.stringValue else { return nil }
        self.init(rawValue: raw)
    }

    public var line: String {
        switch self {
        case .invalidParams, .invalidAnswer: String(localized: "Hermes didn't accept that request. Try again.")
        case .notOwner: String(localized: "This chat belongs to another device now.")
        case .unsupportedRuntime: String(localized: "Apps can't be managed from this chat. Use Settings instead.")
        case .connectorRequestFailed: String(localized: "The app service didn't answer. Try again.")
        case .invalidConnectorResponse: String(localized: "The app service sent something Hermes couldn't read. Try again later.")
        case .unknownTarget, .connectorNotFound: String(localized: "Hermes doesn't know that app.")
        case .linkStillValid: String(localized: "The last sign-in link still works. Finish it in the browser.")
        case .reissueRefused: String(localized: "A new sign-in link can't be made yet. Wait a minute and try again.")
        case .unknownOperation: String(localized: "That sign-in has ended. Start it again.")
        case .needsNousAuth: String(localized: "Sign in to Nous to connect apps.")
        case .toolsUnavailable: String(localized: "This app's tools can't be listed right now.")
        case .connectorsUnavailable: String(localized: "Apps aren't available on this gateway.")
        case .catalogUnavailable: String(localized: "The list of apps can't be loaded right now.")
        case .accountsUnavailable: String(localized: "Accounts can't be loaded right now.")
        case .connectionNotFound: String(localized: "That account is gone. It may have been removed elsewhere.")
        case .policyUnavailable: String(localized: "Tool settings can't be loaded right now.")
        case .policyConflict: String(localized: "Tool settings changed somewhere else. Showing the latest.")
        case .forbiddenScope: String(localized: "Your Nous account isn't allowed to manage apps.")
        case .orgRequired: String(localized: "Apps need a Nous organization. Ask your admin to add you.")
        case .orgAccessDenied: String(localized: "Your organization doesn't let you change this.")
        case .invalidPolicy: String(localized: "That tool setting isn't allowed.")
        case .aliasTaken: String(localized: "Another account already has that name.")
        }
    }

    /// One line for any error from an Apps call: the reason's line, else the gateway's message.
    public static func line(for error: any Error) -> String {
        if let reason = ConnectorErrorReason(error: error) { return reason.line }
        return (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - The connection operation

/// A connect or reconnect in progress (`ConnectionOperationStatus`): the same snapshot the in-chat
/// cards follow through `connection.update`.
public struct ConnectionOperation: Sendable, Hashable, Identifiable {
    public var opID: String
    /// A frame whose `seq` isn't higher than the one held is older and changes nothing.
    public var seq: Int
    public var deadline: Date?
    public var settled: Bool
    /// `all_resolved`, `continue`, `deadline`, `interrupt`.
    public var settledBy: String?
    public var targets: [HermesRequest.Target]

    public var id: String { opID }

    public init(opID: String, seq: Int = 0, deadline: Date? = nil, settled: Bool = false, settledBy: String? = nil, targets: [HermesRequest.Target]) {
        self.opID = opID
        self.seq = seq
        self.deadline = deadline
        self.settled = settled
        self.settledBy = settledBy
        self.targets = targets
    }

    public init?(json: JSONValue) {
        guard let opID = json["op_id"]?.stringValue else { return nil }
        self.opID = opID
        seq = json["seq"]?.truncatedIntValue ?? 0
        deadline = json["deadline_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        settled = json["settled"]?.boolValue ?? false
        settledBy = json["settled_by"]?.stringValue
        targets = json["targets"].items.compactMap(HermesRequest.Target.init(json:))
    }

    /// The first row still waiting on the browser.
    public var signInTarget: HermesRequest.Target? {
        targets.first { $0.connectURL != nil && !$0.isFinished }
    }

    /// Every row is connected.
    public var succeeded: Bool { !targets.isEmpty && targets.allSatisfy { $0.state == "connected" } }

    /// Settled, or every row has an outcome.
    public var isFinished: Bool { settled || (!targets.isEmpty && targets.allSatisfy(\.isFinished)) }

    /// Keeps the newer of two snapshots.
    public func merged(with other: ConnectionOperation) -> ConnectionOperation {
        other.opID == opID && other.seq < seq ? self : other
    }
}

// MARK: - Helpers

extension JSONValue {
    var items: [JSONValue] {
        if case .array(let rows) = self { rows } else { [] }
    }

    var strings: [String] { items.compactMap(\.stringValue) }

    var fields: [String: JSONValue] {
        if case .object(let object) = self { object } else { [:] }
    }
}

extension Optional where Wrapped == JSONValue {
    var items: [JSONValue] { self?.items ?? [] }
    var strings: [String] { self?.strings ?? [] }
    var fields: [String: JSONValue] { self?.fields ?? [:] }
    var int: Int? { self?.truncatedIntValue }
}
