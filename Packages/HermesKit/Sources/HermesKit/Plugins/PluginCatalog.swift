import Foundation

/// Hermes's reviewed plugin catalog, as its public feed publishes it
/// (`https://hermes-agent.nousresearch.com/docs/api/plugin-catalog.json`, built by Hermes's
/// `website/scripts/extract-plugins.py` from `plugin-catalog/*.yaml`; `docs/plugins.md` §4). The app
/// reads it for display only: installs go through the gateway by `catalog_name`, so the gateway's
/// own pin and kill list apply.
public struct PluginCatalog: Sendable, Hashable {
    /// A plugin pulled from the catalog (`plugin-catalog/removed.yaml`): installs are refused and
    /// installed copies don't load.
    public struct Removal: Sendable, Hashable {
        public let name: String
        public let repo: String?
        public let reason: String
        public let date: String
    }

    public let generatedAt: Date?
    public let entries: [PluginCatalogEntry]
    public let removed: [Removal]

    public init(generatedAt: Date? = nil, entries: [PluginCatalogEntry], removed: [Removal] = []) {
        self.generatedAt = generatedAt
        self.entries = entries
        self.removed = removed
    }

    /// Reads the feed. Entries without a name, repository or full SHA are dropped, as Hermes does.
    public init(data: Data) throws {
        let json = try JSONValue.decode(data)
        generatedAt = HermesDate.fromISO(json["generated_at"]?.stringValue)
        entries = json["entries"].items.compactMap(PluginCatalogEntry.init(json:))
        removed = json["removed"].items.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return Removal(name: name, repo: row["repo"]?.stringValue, reason: row["reason"]?.stringValue ?? "",
                           date: row["date"]?.stringValue ?? "")
        }
    }

    public func entry(named name: String) -> PluginCatalogEntry? { entries.first { $0.name == name } }

    /// Why an installed plugin was pulled, if it was: by its catalog name or name, or by its
    /// repository however it's spelled.
    public func removal(name: String, catalogName: String?, repo: String? = nil) -> Removal? {
        removed.first { removal in
            removal.name == name || removal.name == catalogName
                || (removal.repo.map(Self.normalized) != nil && removal.repo.map(Self.normalized) == repo.map(Self.normalized))
        }
    }

    /// "https://www.github.com/Owner/Repo.git" and "git@github.com:owner/repo" are the same.
    static func normalized(_ repo: String) -> String {
        var text = repo.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "git@", "www."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        text = text.replacingOccurrences(of: ":", with: "/")
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }
}

/// One plugin in the catalog.
public struct PluginCatalogEntry: Sendable, Hashable, Identifiable {
    public let name: String
    public let title: String
    public let repo: String
    public let sha: String
    public let description: String
    public let maintainer: String
    /// `official` or `community`.
    public let tier: String
    /// `desktop`, `memory`, `platform`, `web`, `tools`, `voice`, `automation`, `models` or `general`.
    public let category: String
    /// ">=0.21.4": the Hermes it needs, if it says.
    public let requiresHermes: String?
    public let version: String?
    /// `windows`, `macos`, `linux`; empty runs everywhere.
    public let platforms: [String]
    /// Curated for the first run (`plugins.manage onboarding` lists these).
    public let onboarding: Bool
    public let capabilities: PluginCapabilities
    public let knownIssues: [String]
    public let docsURL: URL?
    /// False for an entry known only from `plugins.catalog.lookup` (the feed couldn't be read):
    /// its capabilities aren't known, which isn't the same as having none.
    public let capabilitiesKnown: Bool

    public var id: String { name }

    public init(name: String, title: String, repo: String = "", sha: String = "", description: String = "", maintainer: String = "",
                tier: String = "community", category: String = "desktop", requiresHermes: String? = nil, version: String? = nil,
                platforms: [String] = [], onboarding: Bool = false, capabilities: PluginCapabilities = PluginCapabilities(),
                knownIssues: [String] = [], docsURL: URL? = nil, capabilitiesKnown: Bool = true) {
        self.name = name
        self.title = title
        self.repo = repo
        self.sha = sha
        self.description = description
        self.maintainer = maintainer
        self.tier = tier
        self.category = category
        self.requiresHermes = requiresHermes
        self.version = version
        self.platforms = platforms
        self.onboarding = onboarding
        self.capabilities = capabilities
        self.knownIssues = knownIssues
        self.docsURL = docsURL
        self.capabilitiesKnown = capabilitiesKnown
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty,
              let repo = json["repo"]?.stringValue, !repo.isEmpty,
              let sha = json["sha"]?.stringValue, sha.count == 40 else { return nil }
        let capabilities = json["capabilities"]
        self.init(
            name: name, title: json["title"]?.stringValue ?? name, repo: repo, sha: sha,
            description: json["description"]?.stringValue ?? "", maintainer: json["maintainer"]?.stringValue ?? "",
            tier: json["tier"]?.stringValue == "official" ? "official" : "community",
            category: json["category"]?.stringValue ?? "desktop",
            requiresHermes: json["requires_hermes"]?.stringValue,
            version: json["version"]?.stringValue ?? json["version"]?.doubleValue.map { String($0) },
            platforms: json["platforms"].strings, onboarding: json["onboarding"]?.boolValue ?? false,
            capabilities: PluginCapabilities(hooks: capabilities?["provides_hooks"].strings ?? [],
                                             tools: capabilities?["provides_tools"].strings ?? [],
                                             middleware: capabilities?["provides_middleware"].strings ?? [],
                                             env: capabilities?["requires_env"].strings ?? []),
            knownIssues: json["known_issues"].strings,
            docsURL: json["docs_url"]?.stringValue.flatMap(URL.init(string:))
        )
    }

    public var isOfficial: Bool { tier == "official" }

    /// The catalog's disclosure: the sentence after "Disclosure —" or "Disclosure:" in the
    /// description, the way Hermes reads it (`plugin_catalog_presence.py`).
    public var disclosure: String? {
        guard let marker = description.range(of: #"\bDisclosure\s*[:—]\s*"#, options: .regularExpression) else { return nil }
        let rest = description[marker.upperBound...]
        let sentence = rest.range(of: ". ").map { String(rest[..<$0.lowerBound]) + "." } ?? String(rest)
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// What the plugin is, before the disclosure: its first sentence.
    public var summary: String {
        var text = description
        if let marker = text.range(of: #"\bDisclosure\s*[:—]"#, options: .regularExpression) { text = String(text[..<marker.lowerBound]) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.range(of: ". ") { return String(trimmed[..<end.lowerBound]) + "." }
        return trimmed
    }

    /// Runs on the gateway's OS (`darwin`, `linux`, `win32` as Python names them, or `macos`…).
    public func runs(on os: String) -> Bool {
        guard !platforms.isEmpty else { return true }
        let wanted = Self.platform(os)
        return platforms.contains { Self.platform($0) == wanted }
    }

    static func platform(_ name: String) -> String {
        switch name.lowercased() {
        case "darwin", "macos", "mac", "macosx": "macos"
        case "win32", "windows", "win": "windows"
        default: name.lowercased()
        }
    }

    /// The gateway's Hermes is new enough: only ">=" and "==" forms are read; anything else passes,
    /// since Hermes checks again when it installs.
    public func supports(hermes version: String?) -> Bool {
        guard let spec = requiresHermes?.trimmingCharacters(in: .whitespaces), let version, !version.isEmpty else { return true }
        if spec.hasPrefix(">=") {
            return AppPlugin.version(version, isAtLeast: String(spec.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        return true
    }

    /// "0.23" from ">=0.23.0": what to say it needs.
    public var minimumHermes: String? {
        guard let spec = requiresHermes, spec.hasPrefix(">=") else { return nil }
        return String(spec.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
}
