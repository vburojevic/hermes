import Foundation

/// What the "/" menu offers in one profile, read from Hermes's `commands.catalog`
/// (`tui_gateway/methods_tools.py`; `docs/commands-and-references.md` §2): its skills, and its
/// commands with the app's words and symbols where it has them, Hermes's otherwise.
public struct SlashCommandCatalog: Equatable, Sendable {
    public struct Skill: Equatable, Sendable {
        public var name: String
        public var summary: String
        /// Where it comes from ("local", "hermes-skills"), for its preview.
        public var category: String?
    }

    public struct Command: Equatable, Sendable {
        public var info: SlashCommandInfo
        /// Why it can't run from the app, when Hermes says so; `nil` runs.
        public var unavailable: String?

        public var name: String { info.name }

        public init(info: SlashCommandInfo, unavailable: String? = nil) {
            self.info = info
            self.unavailable = unavailable
        }
    }

    public var skills: [Skill]
    /// Grouped and ordered for the menu: the app's groups, its own order within them, then by name.
    public var commands: [Command]

    /// - Parameters:
    ///   - descriptions: skill and command lines from `complete.slash {text: "/"}`, by name.
    ///   - hidden: commands the menu never lists (the app's own plumbing, like `/app-push`).
    ///   - appRuns: commands the app runs itself: listed however Hermes marks them.
    public static func parse(_ catalog: JSONValue, descriptions: [String: String] = [:],
                             hidden: Set<String> = [], appRuns: Set<String> = []) -> SlashCommandCatalog {
        var skills: [Skill] = []
        if case .object(let entries)? = catalog["skills"] {
            for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
                let name = bare(key)
                let summary = descriptions[name] ?? value["description"]?.stringValue ?? value["usage"]?.stringValue ?? ""
                skills.append(Skill(name: name, summary: summary, category: value["category"]?.stringValue ?? value["origin"]?.stringValue ?? value["source"]?.stringValue))
            }
        }
        let skillNames = Set(skills.map(\.name))

        // Hermes's category for each command, from its grouped pairs.
        var categories: [String: String] = [:]
        if case .array(let groups)? = catalog["categories"] {
            for group in groups {
                guard let title = group["name"]?.stringValue, case .array(let pairs)? = group["pairs"] else { continue }
                for case .array(let parts) in pairs {
                    if let key = parts.first?.stringValue { categories[bare(key)] = title }
                }
            }
        }

        var commands: [Command] = []
        var seen = Set<String>()
        if case .array(let pairs)? = catalog["pairs"] {
            for case .array(let parts) in pairs {
                guard let key = parts.first?.stringValue else { continue }
                let name = bare(key)
                let canonical = SlashCommands.canonical(name)
                guard !skillNames.contains(name), !seen.contains(canonical), !hidden.contains(canonical) else { continue }
                let desktop = catalog["commands"]?[key]?["desktop"]?.stringValue
                let availability = SlashAvailability(desktop: desktop)
                if availability == .hidden, !appRuns.contains(canonical) { continue }
                seen.insert(canonical)
                let hermesLine = parts.dropFirst().first?.stringValue ?? descriptions[name]
                let info = SlashCommands.known(name) ?? SlashCommands.info(name, summary: hermesLine, category: categories[name])
                let reason = appRuns.contains(canonical) ? nil : availability.reason
                commands.append(Command(info: info, unavailable: reason))
            }
        }
        return SlashCommandCatalog(skills: skills, commands: sorted(commands))
    }

    /// The app's groups in order, the app's own order within each, then names.
    public static func sorted(_ commands: [Command]) -> [Command] {
        let order = Dictionary(uniqueKeysWithValues: SlashCommands.all.enumerated().map { ($1.name, $0) })
        let groups = SlashCommandInfo.Group.allCases
        return commands.sorted { lhs, rhs in
            let left = (groups.firstIndex(of: lhs.info.group) ?? 9, order[lhs.name] ?? 999, lhs.name)
            let right = (groups.firstIndex(of: rhs.info.group) ?? 9, order[rhs.name] ?? 999, rhs.name)
            return left < right
        }
    }

    private static func bare(_ key: String) -> String {
        key.hasPrefix("/") ? String(key.dropFirst()) : key
    }
}

/// Where Hermes offers a command outside a terminal (`CommandDef.desktop` in
/// `hermes_cli/commands.py`): everywhere, kept out of the menu, or not here, for a reason.
public enum SlashAvailability: Equatable, Sendable {
    case offered
    /// Runs, but Hermes keeps it out of the menu (`/model` has its own picker).
    case hidden
    case unavailable(String)

    public init(desktop: String?) {
        switch desktop {
        case nil, "", "advanced": self = .offered
        case "hidden": self = .hidden
        case "terminal": self = .unavailable("Runs only in Hermes in a terminal")
        case "messaging": self = .unavailable("Runs only in messaging apps")
        case "settings": self = .unavailable("Set this up in Settings")
        case "composer-voice": self = .unavailable("Use the microphone in the composer")
        default: self = .unavailable("Not available in the app")
        }
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}
