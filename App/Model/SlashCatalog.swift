import Foundation
import HermesKit
import Observation

/// What the "/" menu offers in one gateway profile (`blocks/slash.elyx`): its skills, then its
/// commands by group. Over the gateway protocol both come from `commands.catalog` (with skill
/// descriptions from `complete.slash`); without it, only the commands the app runs itself.
@MainActor
@Observable
final class SlashCatalog {
    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable { case skill, command }

        var name: String
        var kind: Kind
        var summary: String
        var info: SlashCommandInfo?
        /// Where a skill comes from ("hermes-skills"), for its preview.
        var category: String?
        /// Why the command can't run from the app (Hermes keeps it for a terminal, say): shown
        /// greyed with the reason rather than left out.
        var unavailable: String?

        var id: String { "\(kind)-\(name)" }
        var symbol: String { kind == .skill ? "book.closed" : info?.symbol ?? SlashCommands.fallbackSymbol }
        var argument: String? { kind == .skill ? nil : info?.argument }
        var group: SlashCommandInfo.Group { info?.group ?? .more }
    }

    /// A value for a command's argument (`slashMenuArgs`): a model, a reasoning level.
    struct Value: Identifiable, Hashable {
        var value: String
        var title: String
        var detail: String?
        var symbol: String
        var isCurrent = false

        var id: String { value }
    }

    private(set) var skills: [Entry] = []
    private(set) var commands: [Entry] = []
    private(set) var isLoaded = false
    private(set) var skillNames: Set<String> = []

    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Commands the app runs itself, so they work without the gateway protocol too.
    static let appCommands: Set<String> = ["new", "retry", "title", "branch", "model", "reasoning", "stop", "steer", "queue"]
    /// Commands the app runs through the dashboard, though Hermes keeps them for a terminal or a
    /// messaging platform: listed once the gateway protocol answers.
    static let dashboardCommands: Set<String> = ["update", "restart"]

    init() {
        commands = Self.localCommands
    }

    private static var localCommands: [Entry] {
        SlashCommands.all
            .filter { appCommands.contains($0.name) }
            .map { Entry(name: $0.name, kind: .command, summary: $0.summary, info: $0) }
    }

    /// Commands only the app runs: the push plugin's `/app-push` (through `command.dispatch`).
    static let hiddenCommands: Set<String> = ["app-push"]

    /// Loads the profile's commands and skills over the gateway protocol, once.
    func load(roster: BotRoster, profile: String?) {
        guard loading == nil, !isLoaded else { return }
        loading = Task {
            defer { loading = nil }
            var params: [String: JSONValue] = [:]
            if let profile { params["profile"] = .string(profile) }
            guard let catalog = try? await roster.request("commands.catalog", params) else { return }
            var descriptions: [String: String] = [:]
            var slashParams = params
            slashParams["text"] = .string("/")
            if let completions = try? await roster.request("complete.slash", slashParams), case .array(let items)? = completions["items"] {
                for item in items {
                    guard let text = item["text"]?.stringValue else { continue }
                    let name = text.hasPrefix("/") ? String(text.dropFirst()) : text
                    if let meta = item["meta"]?.stringValue { descriptions[name] = meta }
                }
            }
            apply(catalog: catalog, descriptions: descriptions)
        }
    }

    private func apply(catalog: JSONValue, descriptions: [String: String]) {
        let runs = Self.appCommands.union(Self.dashboardCommands)
        let parsed = SlashCommandCatalog.parse(catalog, descriptions: descriptions, hidden: Self.hiddenCommands, appRuns: runs)
        var listed = parsed.commands
        // The app's own commands are always there, even if the gateway's list leaves one out
        // (`/restart` is only ever offered to messaging platforms).
        for name in runs.sorted() where !listed.contains(where: { $0.name == name }) {
            if let info = SlashCommands.known(name) { listed.append(.init(info: info)) }
        }
        commands = SlashCommandCatalog.sorted(listed).map {
            Entry(name: $0.name, kind: .command, summary: $0.info.summary, info: $0.info, unavailable: $0.unavailable)
        }
        skills = parsed.skills.map { Entry(name: $0.name, kind: .skill, summary: $0.summary, category: $0.category) }
        skillNames = Set(parsed.skills.map(\.name))
        isLoaded = true
    }

    // MARK: Filtering

    /// Entries for what's typed after "/": names starting with it; failing that, names with a
    /// word starting with it ("pr" → github-pr-workflow); failing that, names containing it.
    func matches(_ query: String, includeSkills: Bool) -> (skills: [Entry], commands: [Entry]) {
        let query = query.lowercased()
        let skillPool = includeSkills ? skills : []
        guard !query.isEmpty else { return (skillPool, commands) }
        let tests: [(String) -> Bool] = [
            { $0.hasPrefix(query) },
            { $0.split(whereSeparator: { "-_:.".contains($0) }).contains { $0.hasPrefix(query) } },
            { $0.contains(query) },
        ]
        for test in tests {
            let foundSkills = skillPool.filter { test($0.name.lowercased()) }
            let foundCommands = commands.filter { test($0.name.lowercased()) }
            if !foundSkills.isEmpty || !foundCommands.isEmpty { return (foundSkills, foundCommands) }
        }
        return ([], [])
    }

    /// Values for `/model ` and `/reasoning `.
    func values(for command: String, workspace: BotWorkspace, conversation: ConversationModel, query: String) -> [Value] {
        let query = query.lowercased()
        var values: [Value] = []
        switch SlashCommands.canonical(command) {
        case "model":
            let defaults = workspace.modelOptions.flatMap { options in
                options.model.map { ModelSelection(provider: options.provider ?? "", model: $0) }
            }
            let current = conversation.model ?? defaults
            for provider in workspace.modelOptions?.usableProviders ?? [] {
                for model in provider.models where !provider.isUnavailable(model) {
                    let isCurrent = current.map { $0.model == model && (provider.matches(provider: $0.provider) || $0.provider.isEmpty) } ?? false
                    var detail = provider.name
                    if let price = provider.pricing?[model] {
                        if price.free == true {
                            detail += " · Free"
                        } else if let input = price.input, let output = price.output {
                            detail += " · \(input) / \(output)"
                        }
                    }
                    values.append(Value(
                        value: "\(model) --provider \(provider.slug)",
                        title: ModelNames.display(model),
                        detail: isCurrent ? String(localized: "Current · \(provider.name)") : detail,
                        symbol: "cpu",
                        isCurrent: isCurrent
                    ))
                }
            }
        case "reasoning":
            let current = conversation.reasoningEffort
            for level in ReasoningEffort.allCases {
                values.append(Value(
                    value: level.rawValue,
                    title: ReasoningNames.title(for: level),
                    detail: level == current ? String(localized: "Current") : nil,
                    symbol: "lightbulb",
                    isCurrent: level == current
                ))
            }
        default:
            break
        }
        guard !query.isEmpty else { return values.sorted { $0.isCurrent && !$1.isCurrent } }
        return values.filter { $0.title.lowercased().contains(query) || $0.value.lowercased().contains(query) }
    }
}

/// Human names for model ids: `anthropic/claude-sonnet-4.6` → "Claude Sonnet 4.6".
nonisolated enum ModelNames {
    static func display(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        let words = last.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word -> String in
            let lower = word.lowercased()
            if ["gpt", "glm", "ai"].contains(lower) { return lower.uppercased() }
            if word.first?.isNumber == true { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }
}

nonisolated enum ReasoningNames {
    static func title(for level: ReasoningEffort) -> String {
        switch level {
        case .off: String(localized: "Off")
        case .minimal: String(localized: "Minimal")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra High")
        case .max: String(localized: "Max")
        }
    }
}
