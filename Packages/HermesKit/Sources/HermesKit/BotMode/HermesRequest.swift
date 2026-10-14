import Foundation

/// Something Hermes stopped to ask for mid-turn, other than an approval (`docs/quick-actions.md`):
/// a server request on the gateway socket (`clarify`, `secret`, `sudo`, `vault.*`,
/// `setup_choose`), or the `connection.request` event. Shapes from
/// `tui_gateway/contracts/server_requests.py` and `connectors_operation.py`.
public struct HermesRequest: Identifiable, Sendable, Hashable {
    public struct Question: Sendable, Hashable, Identifiable {
        public var id: String
        public var question: String
        public var choices: [String]
        public var multiSelect: Bool

        public init(id: String, question: String, choices: [String] = [], multiSelect: Bool = false) {
            self.id = id
            self.question = question
            self.choices = choices
            self.multiSelect = multiSelect
        }
    }

    public struct Option: Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String?
    }

    public struct Choice: Sendable, Hashable {
        /// `accent`, `theme`, `question`, `connectors`, `plugins`…
        public var kind: String
        public var question: String
        public var options: [Option]
        public var multiSelect: Bool
        public var preselected: [String]
    }

    public struct EnvField: Sendable, Hashable, Identifiable {
        public var name: String
        public var required: Bool
        public var secret: Bool
        public var defaultValue: String?
        public var prompt: String?

        public var id: String { name }
    }

    public struct Target: Sendable, Hashable, Identifiable {
        public var name: String
        /// `connector`, `mcp`, `plugin`, `skill`.
        public var kind: String
        /// `authorize`, `connect`, `enable`, `install`, `reconnect`.
        public var action: String
        public var state: String?
        public var connectURL: URL?
        public var requiredEnv: [EnvField]
        public var detail: String?
        /// Extra facts the card shows: origin ("official"), scan result.
        public var origin: String?
        public var scan: String?

        public var id: String { name }
        public var needsSignIn: Bool { connectURL != nil && requiredEnv.isEmpty }
        public var isAddOn: Bool { kind == "plugin" || kind == "skill" }
    }

    public struct Connection: Sendable, Hashable {
        public var opID: String
        public var targets: [Target]
    }

    public enum Kind: Sendable, Hashable {
        case clarify([Question])
        case secret(envVar: String, prompt: String?)
        case sudo(command: String)
        case vaultUnlock(backend: String?, displayName: String?)
        case vaultSaveLogin(origin: String?, site: String?)
        case vaultCode(site: String?, hint: String?)
        case choose(Choice)
        case connection(Connection)
    }

    /// The JSON-RPC id to answer (`srq-…`), or the connection's `op_id`.
    public var id: String
    public var method: String
    public var kind: Kind
    public var receivedAt: Date
    /// When Hermes stops waiting, if it said.
    public var deadline: Date?

    public init(id: String, method: String, kind: Kind, receivedAt: Date = .now, deadline: Date? = nil) {
        self.id = id
        self.method = method
        self.kind = kind
        self.receivedAt = receivedAt
        self.deadline = deadline
    }

    /// Requests only the desktop app can serve; answered as unsupported.
    public static let desktopOnly: Set<String> = ["terminal.read", "preview.read", "preview.act", "window.read", "tour", "display.install.sudo"]

    /// A server request this app answers with a card, or `nil`.
    public static func parse(_ request: GatewayServerRequest, now: Date = .now) -> HermesRequest? {
        let params = request.params
        let kind: Kind
        switch request.method {
        case "clarify":
            guard case .array(let rows)? = params["questions"] else { return nil }
            let questions = rows.enumerated().compactMap { index, row -> Question? in
                guard let text = row["question"]?.stringValue else { return nil }
                var choices: [String] = []
                if case .array(let values)? = row["choices"] { choices = values.compactMap(\.stringValue) }
                return Question(
                    id: row["qid"]?.stringValue ?? "q\(index)",
                    question: text,
                    choices: choices,
                    multiSelect: row["multi_select"]?.boolValue ?? false
                )
            }
            guard !questions.isEmpty else { return nil }
            kind = .clarify(questions)
        case "secret":
            kind = .secret(envVar: params["env_var"]?.stringValue ?? "SECRET", prompt: params["prompt"]?.stringValue)
        case "sudo":
            kind = .sudo(command: params["command"]?.stringValue ?? "")
        case "vault.unlock_prompt":
            kind = .vaultUnlock(backend: params["backend"]?.stringValue, displayName: params["display_name"]?.stringValue)
        case "vault.save_login":
            kind = .vaultSaveLogin(origin: params["origin"]?.stringValue, site: params["site"]?.stringValue)
        case "vault.code":
            kind = .vaultCode(site: params["site"]?.stringValue, hint: params["hint"]?.stringValue)
        case "setup_choose":
            var options: [Option] = []
            if case .array(let rows)? = params["options"] {
                options = rows.enumerated().compactMap { index, row in
                    guard let label = row["label"]?.stringValue ?? row.stringValue else { return nil }
                    return Option(id: row["id"]?.stringValue ?? row.stringValue ?? "o\(index)", label: label, detail: row["detail"]?.stringValue)
                }
            }
            var preselected: [String] = []
            if case .array(let values)? = params["preselected"] { preselected = values.compactMap(\.stringValue) }
            kind = .choose(Choice(
                kind: params["kind"]?.stringValue ?? "question",
                question: params["question"]?.stringValue ?? "",
                options: options,
                multiSelect: params["multi_select"]?.boolValue ?? false,
                preselected: preselected
            ))
        default:
            return nil
        }
        let timeout = params["timeout_seconds"]?.doubleValue ?? params["timeout"]?.doubleValue
        return HermesRequest(id: request.id, method: request.method, kind: kind, receivedAt: now, deadline: timeout.map { now.addingTimeInterval($0) })
    }

    /// The `connection.request` event's payload as a card.
    public static func connection(from payload: JSONValue, now: Date = .now) -> HermesRequest? {
        guard let opID = payload["op_id"]?.stringValue, case .array(let rows)? = payload["targets"] else { return nil }
        let targets = rows.compactMap { row -> Target? in
            guard let name = row["name"]?.stringValue else { return nil }
            var env: [EnvField] = []
            if case .array(let fields)? = row["required_env"] {
                env = fields.compactMap { field in
                    guard let name = field["name"]?.stringValue else { return nil }
                    return EnvField(
                        name: name,
                        required: field["required"]?.boolValue ?? true,
                        secret: field["secret"]?.boolValue ?? true,
                        defaultValue: field["default"]?.stringValue,
                        prompt: field["prompt"]?.stringValue
                    )
                }
            }
            return Target(
                name: name,
                kind: row["kind"]?.stringValue ?? "connector",
                action: row["action"]?.stringValue ?? "connect",
                state: row["state"]?.stringValue,
                connectURL: row["connect_url"]?.stringValue.flatMap(URL.init(string:)),
                requiredEnv: env,
                detail: row["detail"]?.stringValue ?? row["description"]?.stringValue,
                origin: row["origin"]?.stringValue,
                scan: row["scan"]?.stringValue ?? row["scan_status"]?.stringValue
            )
        }
        guard !targets.isEmpty else { return nil }
        var deadline: Date?
        if let at = payload["deadline_at"]?.doubleValue {
            deadline = Date(timeIntervalSince1970: at)
        } else if let seconds = payload["timeout_seconds"]?.doubleValue {
            deadline = now.addingTimeInterval(seconds)
        }
        return HermesRequest(id: opID, method: "connection.request", kind: .connection(Connection(opID: opID, targets: targets)), receivedAt: now, deadline: deadline)
    }

    /// The answer Hermes reads when the person skips or cancels.
    public var skipResult: JSONValue {
        switch kind {
        case .clarify: .object([:])
        case .choose: .object(["picked": .null])
        case .connection: .object([:])
        default: .object(["value": .string("")])
        }
    }
}
