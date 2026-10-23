import Foundation

/// The two places Hermes keeps what it learns, per Bot (profile) (`docs/memory.md`): About You
/// (`USER.md`, gateway source "profile", memory-tool target "user") and Hermes's Notes
/// (`MEMORY.md`, source "memory", target "memory"). Both are read once, at the start of a chat.
public enum MemoryStoreKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case about
    case notes

    public var id: String { rawValue }

    /// The learning graph's `source`.
    public var source: String {
        switch self {
        case .about: "profile"
        case .notes: "memory"
        }
    }

    /// The memory tool's and `/api/memory/reset`'s `target`.
    public var target: String {
        switch self {
        case .about: "user"
        case .notes: "memory"
        }
    }

    public var fileName: String {
        switch self {
        case .about: "USER.md"
        case .notes: "MEMORY.md"
        }
    }

    /// `memory.user_char_limit` / `memory.memory_char_limit` when the gateway doesn't say.
    public var defaultLimit: Int {
        switch self {
        case .about: 1375
        case .notes: 2200
        }
    }

    public init?(source: String) {
        guard let kind = Self.allCases.first(where: { $0.source == source }) else { return nil }
        self = kind
    }

    public init?(target: String) {
        switch target.lowercased() {
        case "user", "user profile", "profile": self = .about
        case "memory": self = .notes
        default: return nil
        }
    }
}

/// One remembered thing: a `§`-delimited entry of `USER.md` or `MEMORY.md`.
public struct MemoryEntry: Identifiable, Hashable, Sendable {
    /// `memory:<source>:<index>:<fingerprint>`: the position names the occurrence, the
    /// fingerprint the text. An entry that changed since it was loaded is "stale" to edit and
    /// delete.
    public var id: String
    public var store: MemoryStoreKind
    /// The entry as the graph carries it: its first 1,200 characters (`body`).
    public var text: String
    public var fingerprint: String

    /// The graph cut the text; the full entry comes from `GET /api/learning/node`.
    public var isTruncated: Bool { text.unicodeScalars.count >= MemoryList.bodyLimit }

    public init(id: String, store: MemoryStoreKind, text: String, fingerprint: String) {
        self.id = id
        self.store = store
        self.text = text
        self.fingerprint = fingerprint
    }
}

/// Every entry of both stores, in the order the files keep them (newest last), from
/// `GET /api/learning/graph`. Skill nodes are ignored.
public struct MemoryList: Sendable, Hashable {
    /// The graph's `body` is the entry's first 1,200 characters.
    static let bodyLimit = 1200

    public var about: [MemoryEntry]
    public var notes: [MemoryEntry]

    public init(about: [MemoryEntry] = [], notes: [MemoryEntry] = []) {
        self.about = about
        self.notes = notes
    }

    /// `memory[]` is `MEMORY.md`'s cards then `USER.md`'s; a card's index in that combined list
    /// is the one in its id. The graph's memory nodes carry the same ids in the same order: use
    /// theirs, and mint the id the same way when a node is missing.
    public init(graph: JSONValue) {
        let nodeIDs = graph["nodes"].items
            .filter { $0["kind"]?.stringValue == "memory" }
            .compactMap { $0["id"]?.stringValue }
        var about: [MemoryEntry] = []
        var notes: [MemoryEntry] = []
        for (index, card) in graph["memory"].items.enumerated() {
            guard let source = card["source"]?.stringValue, let store = MemoryStoreKind(source: source) else { continue }
            let fingerprint = card["fingerprint"]?.stringValue ?? ""
            let minted = fingerprint.isEmpty ? "memory:\(source):\(index)" : "memory:\(source):\(index):\(fingerprint)"
            let nodeID = nodeIDs.indices.contains(index) ? nodeIDs[index] : nil
            // A node id names the same card only if it carries the same source and fingerprint.
            let id = nodeID.flatMap { $0.hasPrefix("memory:\(source):") && (fingerprint.isEmpty || $0.hasSuffix(":\(fingerprint)")) ? $0 : nil } ?? minted
            let text = (card["body"]?.stringValue ?? card["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = MemoryEntry(id: id, store: store, text: text, fingerprint: fingerprint)
            switch store {
            case .about: about.append(entry)
            case .notes: notes.append(entry)
            }
        }
        self.about = about
        self.notes = notes
    }

    public func entries(in store: MemoryStoreKind) -> [MemoryEntry] {
        switch store {
        case .about: about
        case .notes: notes
        }
    }

    public var isEmpty: Bool { about.isEmpty && notes.isEmpty }

    /// Takes a change the gateway made but no list read has shown yet: the entry with `id`
    /// replaced in place, or gone (`nil`).
    public mutating func replace(_ id: String, with entry: MemoryEntry?) {
        for keyPath in [\MemoryList.about, \MemoryList.notes] {
            guard let index = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { continue }
            if let entry {
                self[keyPath: keyPath][index] = entry
            } else {
                self[keyPath: keyPath].remove(at: index)
            }
        }
    }

    public func entry(id: String) -> MemoryEntry? {
        about.first { $0.id == id } ?? notes.first { $0.id == id }
    }

    /// The entry holding `text` (a memory note's words), first by equality, then by containment.
    public func entry(matching text: String, in store: MemoryStoreKind? = nil) -> MemoryEntry? {
        let wanted = MemoryUsage.normalized(text)
        guard !wanted.isEmpty else { return nil }
        let pool = store.map { entries(in: $0) } ?? (about + notes)
        return pool.first { MemoryUsage.normalized($0.text) == wanted }
            ?? pool.first { MemoryUsage.normalized($0.text).contains(wanted) }
            ?? pool.first { wanted.contains(MemoryUsage.normalized($0.text)) && $0.text.count > 12 }
    }
}

/// How full a store is: the gateway counts characters (code points) of the entries joined by
/// `\n§\n` against the store's limit.
public enum MemoryUsage {
    public static let delimiter = "\n§\n"

    /// Characters the entries take on disk, as the memory tool counts them.
    public static func characters(_ texts: [String]) -> Int {
        guard !texts.isEmpty else { return 0 }
        return texts.reduce(0) { $0 + $1.unicodeScalars.count } + (texts.count - 1) * delimiter.unicodeScalars.count
    }

    /// The share of the limit in use, 0…1 (more than 1 when hand edits overfilled it).
    public static func fraction(used: Int, limit: Int) -> Double {
        limit > 0 ? Double(used) / Double(limit) : 0
    }

    /// From 90% the store is nearly full: Hermes merges older entries to make room.
    public static func isNearlyFull(used: Int, limit: Int) -> Bool {
        fraction(used: used, limit: limit) >= 0.9
    }

    /// Characters left if `entry` became `replacement` (negative: over the cap).
    public static func room(entries: [String], replacing index: Int?, with replacement: String, limit: Int) -> Int {
        var texts = entries
        if let index, texts.indices.contains(index) {
            texts[index] = replacement
        } else {
            texts.append(replacement)
        }
        return limit - characters(texts)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// The `memory` section of the profile's config (`GET /api/config`): the store switches, Ask
/// Before Saving (`write_approval`), the limits and the provider.
public struct MemorySettings: Sendable, Hashable {
    public var memoryEnabled: Bool
    public var userProfileEnabled: Bool
    public var askBeforeSaving: Bool
    public var memoryCharLimit: Int
    public var userCharLimit: Int
    /// "" for built-in memory.
    public var provider: String

    public init(memoryEnabled: Bool = true, userProfileEnabled: Bool = true, askBeforeSaving: Bool = false,
                memoryCharLimit: Int = MemoryStoreKind.notes.defaultLimit, userCharLimit: Int = MemoryStoreKind.about.defaultLimit,
                provider: String = "") {
        self.memoryEnabled = memoryEnabled
        self.userProfileEnabled = userProfileEnabled
        self.askBeforeSaving = askBeforeSaving
        self.memoryCharLimit = memoryCharLimit
        self.userCharLimit = userCharLimit
        self.provider = provider
    }

    /// The whole config document, or its `memory` section.
    public init(config: JSONValue) {
        let section = config["memory"] ?? config
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            switch section[key] {
            case .bool(let value)?: value
            case .string(let value)?: ["on", "true", "yes", "1", "enabled", "approve"].contains(value.lowercased())
            case .number(let value)?: value != 0
            default: fallback
            }
        }
        memoryEnabled = flag("memory_enabled", true)
        userProfileEnabled = flag("user_profile_enabled", true)
        askBeforeSaving = flag("write_approval", false)
        memoryCharLimit = section["memory_char_limit"]?.truncatedIntValue ?? MemoryStoreKind.notes.defaultLimit
        userCharLimit = section["user_char_limit"]?.truncatedIntValue ?? MemoryStoreKind.about.defaultLimit
        provider = section["provider"]?.stringValue ?? ""
    }

    public var isOff: Bool { !memoryEnabled && !userProfileEnabled }

    public func limit(for store: MemoryStoreKind) -> Int {
        switch store {
        case .about: userCharLimit
        case .notes: memoryCharLimit
        }
    }

    public func isEnabled(_ store: MemoryStoreKind) -> Bool {
        switch store {
        case .about: userProfileEnabled
        case .notes: memoryEnabled
        }
    }

    /// The config key that turns a store on or off.
    public static func enabledKey(for store: MemoryStoreKind) -> String {
        switch store {
        case .about: "user_profile_enabled"
        case .notes: "memory_enabled"
        }
    }
}

/// A memory provider the gateway can use instead of (or beside) the built-in files.
public struct MemoryProvider: Identifiable, Sendable, Hashable {
    public var name: String
    public var description: String
    /// `ready`, `needs_config`, `unavailable` or `missing`.
    public var status: String

    public var id: String { name }
    public var isReady: Bool { status == "ready" }

    /// "Honcho", "Mem0".
    public var title: String {
        switch name.lowercased() {
        case "mem0": "Mem0"
        case "retaindb": "RetainDB"
        case "byterover": "ByteRover"
        case "openviking": "OpenViking"
        case "supermemory": "Supermemory"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    public init(name: String, description: String = "", status: String) {
        self.name = name
        self.description = description
        self.status = status
    }
}

/// `GET /api/memory`: the provider in use, the ones on the gateway, and the files' sizes.
public struct MemoryStatus: Sendable, Hashable {
    /// "" for built-in.
    public var active: String
    public var providers: [MemoryProvider]
    /// Bytes on disk, `memory` and `user`.
    public var fileSizes: [String: Int]

    public init(active: String = "", providers: [MemoryProvider] = [], fileSizes: [String: Int] = [:]) {
        self.active = active
        self.providers = providers
        self.fileSizes = fileSizes
    }

    public init(json: JSONValue) {
        active = json["active"]?.stringValue ?? ""
        providers = json["providers"].items.compactMap { item in
            guard let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
            return MemoryProvider(name: name, description: item["description"]?.stringValue ?? "", status: item["status"]?.stringValue ?? "unavailable")
        }
        var sizes: [String: Int] = [:]
        if case .object(let files)? = json["builtin_files"] {
            for (key, value) in files { sizes[key] = value.truncatedIntValue ?? 0 }
        }
        fileSizes = sizes
    }

    /// The provider's name for the page: "Built-in" or the provider's.
    public var activeTitle: String {
        guard !active.isEmpty else { return String(localized: "Built-in") }
        return providers.first { $0.name == active }?.title ?? MemoryProvider(name: active, status: "").title
    }
}
