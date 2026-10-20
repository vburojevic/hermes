import Foundation

/// A memory provider's settings as Hermes describes them (`GET /api/memory/providers/{name}/config`),
/// for setting one up from the app (`docs/setup.md` §4.4). Secret values never come back, only
/// whether each is set.
public struct MemoryProviderForm: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case secret, text, select, toggle, number
            /// JSON and anything newer: set up on the gateway.
            case other
        }

        public var key: String
        public var label: String
        public var kind: Kind
        public var description: String
        public var placeholder: String
        public var required: Bool
        /// The value on the gateway; "" for a secret.
        public var value: String
        public var isSet: Bool
        public var options: [(value: String, label: String)]
        public var url: URL?
        /// Shown only while each named field has that value (Hermes's `when`).
        public var when: [String: String]
        public var id: String { key }

        public static func == (lhs: Field, rhs: Field) -> Bool {
            lhs.key == rhs.key && lhs.label == rhs.label && lhs.kind == rhs.kind && lhs.value == rhs.value
                && lhs.isSet == rhs.isSet && lhs.when == rhs.when && lhs.required == rhs.required
                && lhs.options.map(\.value) == rhs.options.map(\.value)
        }
    }

    /// What the provider needs installed on the gateway, as its plugin declares it (the route's
    /// `setup`, `_memory_provider_setup_info`).
    public struct Setup: Sendable, Equatable {
        public struct Command: Sendable, Equatable, Identifiable {
            public var name: String
            /// A shell command Hermes runs on the gateway to install it.
            public var install: String
            public var id: String { name + install }
        }

        /// Python packages, installed with `hermes pm install`.
        public var packages: [String]
        public var commands: [Command]
        public var installed: Bool

        /// Whether installing would run anything.
        public var hasSteps: Bool { !packages.isEmpty || !commands.isEmpty }

        init?(json: JSONValue?) {
            guard case .object? = json, let json else { return nil }
            packages = json["pip_dependencies"].strings
            commands = json["external_dependencies"].items.compactMap { row in
                guard let install = row["install"]?.stringValue, !install.isEmpty else { return nil }
                return Command(name: row["name"]?.stringValue ?? install, install: install)
            }
            installed = json["dependencies_installed"]?.boolValue ?? true
        }
    }

    public var name: String
    public var label: String
    public var fields: [Field]
    public var setup: Setup?

    public init(json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        label = json["label"]?.stringValue ?? name
        setup = Setup(json: json["setup"])
        fields = json["fields"].items.compactMap { row in
            guard let key = row["key"]?.stringValue, !key.isEmpty else { return nil }
            let kind: Field.Kind = switch row["kind"]?.stringValue {
            case "secret", "password": .secret
            case "text", "string", "url", nil: .text
            case "select": .select
            case "bool", "boolean": .toggle
            case "number", "integer": .number
            default: .other
            }
            var when: [String: String] = [:]
            if case .object(let conditions)? = row["when"] {
                for (field, expected) in conditions { when[field] = expected.stringValue ?? expected.boolValue.map { $0 ? "True" : "False" } ?? expected.doubleValue.map { String($0) } ?? "" }
            }
            let value = row["value"]?.stringValue ?? row["value"]?.boolValue.map { $0 ? "true" : "false" } ?? row["value"]?.doubleValue.map { String($0) } ?? ""
            return Field(
                key: key, label: row["label"]?.stringValue ?? key, kind: kind,
                description: row["description"]?.stringValue ?? "", placeholder: row["placeholder"]?.stringValue ?? "",
                required: row["required"]?.boolValue ?? false, value: value, isSet: row["is_set"]?.boolValue ?? false,
                options: row["options"].items.compactMap { option in
                    guard let value = option["value"]?.stringValue else { return nil }
                    return (value, option["label"]?.stringValue ?? value)
                },
                url: row["url"]?.stringValue.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                when: when
            )
        }
    }

    /// The fields to show with `edits` laid over what's on the gateway: a field whose `when`
    /// doesn't hold is hidden, as Hermes hides it.
    public func visibleFields(edits: [String: String]) -> [Field] {
        let current = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, edits[$0.key] ?? $0.value) })
        return fields.filter { field in
            field.when.allSatisfy { key, expected in (current[key] ?? "").caseInsensitiveCompare(expected) == .orderedSame }
        }
    }

    /// Whether every required field shown has a value, new or already set.
    public func isComplete(edits: [String: String]) -> Bool {
        visibleFields(edits: edits).allSatisfy { field in
            !field.required || field.isSet || !(edits[field.key] ?? field.value).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// What to send: only what changed, secrets only when typed.
    public func changes(_ edits: [String: String]) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for field in visibleFields(edits: edits) {
            guard let edit = edits[field.key]?.trimmingCharacters(in: .whitespaces), edit != field.value else { continue }
            if field.kind == .secret, edit.isEmpty { continue }
            values[field.key] = field.kind == .toggle ? .bool(edit == "true") : .string(edit)
        }
        return values
    }
}

extension BackendClient {
    public func memoryProviderForm(_ name: String, profile: String?) async throws -> MemoryProviderForm {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        return MemoryProviderForm(json: try await rest("api/memory/providers/" + Self.escape(name) + "/config", query: query))
    }

    /// Saves a provider's settings (`PUT /api/memory/providers/{name}/config`); Hermes keeps the
    /// secrets in the gateway's `.env` and the rest in its config.
    public func saveMemoryProvider(_ name: String, values: [String: JSONValue], profile: String?) async throws {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        _ = try await rest("api/memory/providers/" + Self.escape(name) + "/config", method: "PUT", query: query,
                           body: .object(["values": .object(values)]))
    }
}

/// What `POST /api/memory/providers/{name}/setup` did: each step Hermes ran (`_command_result`),
/// and the provider's status after.
public struct MemoryProviderInstall: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        /// `pip`, `external_check`, `external_install`, `setup`.
        public var kind: String
        public var name: String
        /// `installed`, `already_installed`, `verified`, `missing`, `failed`, `no_declared_steps`…
        public var status: String
        public var command: String
        /// Hermes's trimmed stderr, else stdout.
        public var output: String
        public var failed: Bool { status == "failed" }
    }

    public var ok: Bool
    public var steps: [Step]
    /// `ready`, `needs_config`, `unavailable`…
    public var providerStatus: String?

    public init(json: JSONValue) {
        ok = json["ok"]?.boolValue ?? false
        steps = json["results"].items.map { row in
            let stderr = row["stderr"]?.stringValue ?? ""
            return Step(
                kind: row["kind"]?.stringValue ?? "", name: row["name"]?.stringValue ?? "",
                status: row["status"]?.stringValue ?? "", command: row["command"]?.stringValue ?? "",
                output: (stderr.isEmpty ? row["stdout"]?.stringValue ?? "" : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        providerStatus = json["status"]?["status"]?.stringValue
    }
}

extension BackendClient {
    /// Installs what a provider needs on the gateway (`POST /api/memory/providers/{name}/setup`):
    /// its Python packages, then each command its plugin declares, up to five minutes each.
    /// Hermes answers when it's done, so the request waits up to ten minutes. Only on the
    /// person's tap, after they've seen the commands.
    public func installMemoryProvider(_ name: String, profile: String?) async throws -> MemoryProviderInstall {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        return MemoryProviderInstall(json: try await rest("api/memory/providers/" + Self.escape(name) + "/setup", method: "POST",
                                                          query: query, body: .object(["values": .object([:])]), timeout: 600))
    }
}
