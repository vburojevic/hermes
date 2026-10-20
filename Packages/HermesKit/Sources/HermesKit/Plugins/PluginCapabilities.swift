import Foundation

/// What a plugin can do inside Hermes, as its manifest and its `register()` declare it
/// (`docs/plugins.md` §5): the hooks it listens to, the tools, commands and delivery platforms it
/// adds, where it sends data and the keys it needs. The app keeps one list per pinned version of
/// its own plugins, and reads the catalog's for everyone else's.
public struct PluginCapabilities: Sendable, Hashable, Codable {
    /// `provides_hooks`: names from Hermes's `VALID_HOOKS`.
    public var hooks: [String]
    /// `provides_tools`.
    public var tools: [String]
    /// `provides_middleware`: code that runs inside Hermes's request pipeline.
    public var middleware: [String]
    /// Slash commands (`ctx.register_command`), without the slash.
    public var commands: [String]
    /// Delivery platforms (`ctx.register_platform`), such as `apppush`.
    public var platforms: [String]
    /// Hosts it sends data to. Empty means it sends nothing off the gateway.
    public var networkHosts: [String]
    /// `requires_env`: keys it needs before it works.
    public var env: [String]
    /// Skills it brings (`ctx.register_skill`).
    public var skills: [String]
    /// Prompt sections it adds to Hermes's instructions (`ctx.register_system_prompt_section`).
    public var promptSections: [String]

    public init(hooks: [String] = [], tools: [String] = [], middleware: [String] = [], commands: [String] = [],
                platforms: [String] = [], networkHosts: [String] = [], env: [String] = [], skills: [String] = [],
                promptSections: [String] = []) {
        self.hooks = hooks
        self.tools = tools
        self.middleware = middleware
        self.commands = commands
        self.platforms = platforms
        self.networkHosts = networkHosts
        self.env = env
        self.skills = skills
        self.promptSections = promptSections
    }

    public var isEmpty: Bool { self == PluginCapabilities() }

    /// What this list has that `older` doesn't: an update to it widens the plugin's access when
    /// any of it is new. Keys, skills and prompt sections don't count as access on their own,
    /// but they are listed so the person sees everything that changes.
    public func additions(since older: PluginCapabilities) -> PluginCapabilities {
        func new(_ mine: [String], _ theirs: [String]) -> [String] {
            let known = Set(theirs)
            return mine.filter { !known.contains($0) }
        }
        return PluginCapabilities(
            hooks: new(hooks, older.hooks), tools: new(tools, older.tools), middleware: new(middleware, older.middleware),
            commands: new(commands, older.commands), platforms: new(platforms, older.platforms),
            networkHosts: new(networkHosts, older.networkHosts), env: new(env, older.env), skills: new(skills, older.skills),
            promptSections: new(promptSections, older.promptSections)
        )
    }

    /// An update to `self` from `older` needs the person's yes first (`docs/plugins.md` §7): it
    /// adds hooks, tools, middleware, a command, a platform or a network host.
    public func widens(_ older: PluginCapabilities) -> Bool {
        let added = additions(since: older)
        return !(added.hooks.isEmpty && added.tools.isEmpty && added.middleware.isEmpty && added.commands.isEmpty
                 && added.platforms.isEmpty && added.networkHosts.isEmpty)
    }
}

/// One line of "What it can do on <gateway>" (`capabilityRow`): plain words, the manifest's own
/// names in mono underneath, and a glyph that says how far it reaches.
public struct CapabilityLine: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Only watches (eye).
        case sees
        /// Can change or block something (orange shield).
        case reaches
        /// Adds tools Hermes can call (wrench).
        case tools
        /// Where data goes (network).
        case network
        /// Keys it needs (key).
        case keys
        /// Good news: no keys, nothing sent anywhere (green shield).
        case safe
        /// Adds to Hermes's instructions (page).
        case prompt
        /// Keeps files on the gateway (folder).
        case files
        /// Uses an app on the gateway (computer).
        case app
        /// Adds a skill (book).
        case skill

        public var symbol: String {
            switch self {
            case .sees: "eye"
            case .reaches: "exclamationmark.shield"
            case .tools: "wrench.and.screwdriver"
            case .network: "network"
            case .keys: "key.horizontal"
            case .safe: "checkmark.shield"
            case .prompt: "doc.text"
            case .files: "folder"
            case .app: "desktopcomputer"
            case .skill: "book.closed"
            }
        }
    }

    public let kind: Kind
    public let words: String
    /// The manifest's names this line covers (hooks, tools, `command app-push`…), shown in mono.
    public let names: [String]

    public var id: String { words }

    public init(_ kind: Kind, _ words: String, names: [String] = []) {
        self.kind = kind
        self.words = words
        self.names = names
    }

    /// "pre_approval_request · post_approval_response · on_human_input_*": hooks that share a
    /// prefix of two words or more fold into one name with a star.
    public var mono: String {
        var shown: [String] = []
        var folded = Set<String>()
        for name in names where !folded.contains(name) {
            let parts = name.split(separator: "_")
            guard parts.count >= 3 else {
                shown.append(name)
                continue
            }
            let prefix = parts.dropLast().joined(separator: "_") + "_"
            let siblings = names.filter { $0.hasPrefix(prefix) && $0.split(separator: "_").count == parts.count }
            if siblings.count > 1 {
                shown.append(prefix + "*")
                folded.formUnion(siblings)
            } else {
                shown.append(name)
            }
        }
        return shown.joined(separator: " · ")
    }
}

/// Hooks and the rest of a capability list in plain words (`docs/plugins.md` §5's table, from
/// `VALID_HOOKS` in `hermes_cli/plugins.py`). Hooks that read alike group into one line; a hook
/// the table doesn't know reads "Uses the <name> hook" with the orange shield, so every hook in a
/// manifest shows on the review.
public enum CapabilityWords {
    struct Group: Sendable {
        let kind: CapabilityLine.Kind
        let words: String
        let matches: @Sendable (String) -> Bool
    }

    static func exact(_ names: String...) -> @Sendable (String) -> Bool {
        let set = Set(names)
        return { set.contains($0) }
    }

    static func prefix(_ prefix: String) -> @Sendable (String) -> Bool {
        { $0.hasPrefix(prefix) }
    }

    /// In the order the review lists them.
    static var groups: [Group] {
        [
            Group(kind: .reaches, words: String(localized: "Sees every incoming message before Hermes and can change or drop it"),
                  matches: exact("pre_gateway_dispatch")),
            Group(kind: .sees, words: String(localized: "Sees incoming messages"), matches: exact("post_gateway_admission")),
            Group(kind: .reaches, words: String(localized: "Can change Hermes’s replies before they’re saved"),
                  matches: exact("transform_llm_output")),
            Group(kind: .reaches, words: String(localized: "Can change what tools return"),
                  matches: exact("transform_tool_result", "transform_terminal_output")),
            Group(kind: .reaches, words: String(localized: "Sees tool calls and can block one"), matches: exact("pre_tool_call")),
            Group(kind: .sees, words: String(localized: "Sees tool calls and results"), matches: exact("post_tool_call")),
            Group(kind: .sees, words: String(localized: "Sees what’s sent to the model and what comes back"),
                  matches: exact("pre_llm_call", "post_llm_call", "pre_api_request", "post_api_request", "api_request_error",
                                 "pre_auxiliary_call", "post_auxiliary_call")),
            Group(kind: .reaches, words: String(localized: "Can change how model errors are handled"),
                  matches: exact("transform_api_error_classification")),
            Group(kind: .sees, words: String(localized: "Reads replies as they stream"),
                  matches: exact("on_stream_start", "on_stream_delta", "on_stream_end", "on_interim_message")),
            Group(kind: .sees, words: String(localized: "Knows when chats start and end"),
                  matches: exact("on_session_start", "on_session_end", "on_session_finalize", "on_session_reset")),
            Group(kind: .sees, words: String(localized: "Sees approval requests and your answers (can’t answer them)"),
                  matches: exact("pre_approval_request", "post_approval_response")),
            Group(kind: .sees, words: String(localized: "Sees questions and when they’re answered"),
                  matches: exact("on_human_input_request", "on_human_input_resolved")),
            Group(kind: .sees, words: String(localized: "Knows when helpers start and stop"), matches: exact("subagent_start", "subagent_stop")),
            Group(kind: .sees, words: String(localized: "Knows when skills change"), matches: exact("on_skill_lifecycle")),
            Group(kind: .reaches, words: String(localized: "Can keep a turn going before it finishes"), matches: exact("pre_verify")),
            Group(kind: .sees, words: String(localized: "Knows when a turn is stopped"), matches: exact("agent_loop_stopped")),
            Group(kind: .sees, words: String(localized: "Sees group chat messages and Board cards"),
                  matches: { $0 == "on_room_member_activity" || $0.hasPrefix("kanban_task_") || $0.hasPrefix("on_kanban_") }),
            Group(kind: .reaches, words: String(localized: "Sees commands before they run and can change or block one"),
                  matches: exact("pre_command")),
        ]
    }

    /// Every line for a capability list: hooks first (grouped, unknown ones each on their own
    /// line), then middleware, tools, commands and platforms, network, then keys. A list that
    /// sends nothing anywhere and needs no keys ends with the good news.
    /// `knowsNetwork`: the list is known to name every host it sends to (the app's own plugins).
    /// A catalog entry doesn't list its network, so it never gets "sends nothing off".
    public static func lines(for capabilities: PluginCapabilities, gateway: String, knowsNetwork: Bool = true) -> [CapabilityLine] {
        var lines = hookLines(capabilities.hooks)
        if !capabilities.middleware.isEmpty {
            lines.append(CapabilityLine(.reaches, String(localized: "Runs inside Hermes’s request pipeline"), names: capabilities.middleware))
        }
        if !capabilities.tools.isEmpty {
            let count = capabilities.tools.count
            lines.append(CapabilityLine(.tools, count == 1 ? String(localized: "Adds 1 tool Hermes can call")
                                                           : String(localized: "Adds \(count) tools Hermes can call"),
                                        names: capabilities.tools))
        }
        if !capabilities.commands.isEmpty || !capabilities.platforms.isEmpty {
            lines.append(CapabilityLine(.tools, commandWords(capabilities),
                                        names: capabilities.commands.map { "command \($0)" } + capabilities.platforms.map { "platform \($0)" }))
        }
        for host in capabilities.networkHosts {
            lines.append(CapabilityLine(.network, String(localized: "Sends data to \(host)"), names: [host]))
        }
        if !capabilities.env.isEmpty {
            let count = capabilities.env.count
            lines.append(CapabilityLine(.keys, count == 1 ? String(localized: "Needs 1 key, added after it installs")
                                                          : String(localized: "Needs \(count) keys, added after it installs"),
                                        names: capabilities.env))
        }
        if capabilities.env.isEmpty, capabilities.networkHosts.isEmpty, knowsNetwork {
            lines.append(CapabilityLine(.safe, String(localized: "Needs no keys and sends nothing off \(gateway)"), names: ["no network", "no keys"]))
        } else if capabilities.env.isEmpty, !knowsNetwork {
            lines.append(CapabilityLine(.safe, String(localized: "Needs no keys"), names: ["no keys"]))
        }
        return lines
    }

    /// The hooks alone, grouped by the table.
    public static func hookLines(_ hooks: [String]) -> [CapabilityLine] {
        var lines: [CapabilityLine] = []
        var covered = Set<String>()
        for group in groups {
            let names = hooks.filter(group.matches)
            guard !names.isEmpty else { continue }
            lines.append(CapabilityLine(group.kind, group.words, names: names))
            covered.formUnion(names)
        }
        for hook in hooks where !covered.contains(hook) {
            lines.append(CapabilityLine(.reaches, String(localized: "Uses the \(hook) hook"), names: [hook]))
        }
        return lines
    }

    /// The consent card's lines (`pluginUpdate`, one `capabilityLine` per addition).
    public static func consentLines(for added: PluginCapabilities, gateway: String) -> [CapabilityLine] {
        // Good news isn't an addition.
        lines(for: added, gateway: gateway).filter { $0.kind != .safe }
    }

    private static func commandWords(_ capabilities: PluginCapabilities) -> String {
        let commands = capabilities.commands.map { "/" + $0 }.joined(separator: ", ")
        switch (capabilities.commands.isEmpty, capabilities.platforms.isEmpty) {
        case (false, true): return String(localized: "Adds the \(commands) command")
        case (true, false): return String(localized: "Adds a delivery for scheduled tasks")
        default: return String(localized: "Adds \(commands) and a delivery for scheduled tasks")
        }
    }
}
