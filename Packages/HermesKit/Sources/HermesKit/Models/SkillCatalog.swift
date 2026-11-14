import Foundation

/// The Skills page's list (`docs/bots-groups-skills.md` §3). It is read once per gateway address and
/// kept with the window's workspace, so Skills opened again shows its list at once instead of asking
/// the gateway each time the page appears.
public struct SkillCatalog: Sendable, Equatable {
    /// Skills of one category, sorted by name.
    public struct Group: Sendable, Equatable, Identifiable {
        public var title: String
        public var skills: [Skill]
        public var id: String { title }
    }

    public private(set) var skills: [Skill] = []
    /// Why the last read failed, while nothing newer has arrived.
    public private(set) var failure: HermesError?
    /// The gateway address the list was read from; nil until the first answer.
    private var source: URL?
    /// A turn wrote a skill since the list was read.
    private var isStale = false

    public init() {}

    /// Whether Skills asks the gateway: once per address, and again after a read that failed or a
    /// turn that wrote a skill. While the gateway is offline it waits until it comes online.
    public func needsLoad(from address: URL, isOnline: Bool) -> Bool {
        isOnline && (source != address || failure != nil || isStale)
    }

    /// Nothing has been read from this address yet: the page shows placeholders, not an empty list.
    public func isWaiting(for address: URL) -> Bool {
        source != address
    }

    public mutating func received(_ skills: [Skill], from address: URL) {
        self.skills = skills
        failure = nil
        source = address
        isStale = false
    }

    /// A turn wrote a skill: the next open reads the list again, showing the one it has meanwhile.
    public mutating func markStale() {
        isStale = true
    }

    /// A failed read keeps a list already read from the same address, and drops one from another.
    public mutating func failed(_ error: HermesError, from address: URL) {
        if source != address { skills = [] }
        failure = error
        source = address
    }

    /// The skills whose name or description contains `query`, by category (sorted by title), with
    /// uncategorised skills under `generalTitle`.
    public func groups(matching query: String, generalTitle: String) -> [Group] {
        let matches = query.isEmpty ? skills : skills.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return Dictionary(grouping: matches) { $0.category?.replacingOccurrences(of: "-", with: " ").capitalized ?? generalTitle }
            .map { Group(title: $0.key, skills: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.title < $1.title }
    }
}
