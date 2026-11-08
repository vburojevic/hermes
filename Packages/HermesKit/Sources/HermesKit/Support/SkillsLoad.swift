import Foundation

/// What Skills reads its list again for: another gateway, a new address for it, or the gateway
/// coming online or going offline (`docs/bots-groups-skills.md` §3). Skills opened before the
/// gateway connected fills in once it does.
public struct SkillsLoadTrigger: Equatable, Sendable {
    public let workspace: UUID
    public let address: URL
    public let isOnline: Bool

    public init(workspace: UUID, address: URL, isOnline: Bool) {
        self.workspace = workspace
        self.address = address
        self.isOnline = isOnline
    }

    /// Whether this trigger reads the list. Online it always does. Offline a read only says why
    /// the page is empty, so a list already shown stays as it is.
    public func reads(showing skills: [Skill]) -> Bool {
        isOnline || skills.isEmpty
    }
}

/// The skills Skills shows and why the last read failed.
public struct SkillsList: Equatable, Sendable {
    public private(set) var skills: [Skill]
    public private(set) var error: HermesError?

    public init(skills: [Skill] = [], error: HermesError? = nil) {
        self.skills = skills
        self.error = error
    }

    /// Takes a read's answer from `LatestRead`. No answer (a newer read replaced it, or Skills
    /// closed) changes nothing. A failed read keeps the skills shown and only records why.
    public mutating func take(_ answer: Result<[Skill], any Error>?) {
        switch answer {
        case nil:
            return
        case .success(let skills)?:
            self.skills = skills
            error = nil
        case .failure(let failure)?:
            error = failure as? HermesError ?? .invalidResponse(failure.localizedDescription)
        }
    }
}
