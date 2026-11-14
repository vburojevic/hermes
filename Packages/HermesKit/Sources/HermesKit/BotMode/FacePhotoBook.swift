import Foundation

/// When the app fetches a Bot's photo avatar (`profiles.get_asset`, docs/bots-groups-skills.md §1):
/// once per meta revision, and once more each time memory pressure drops the decoded photo while a
/// face still asks for it. A face that asks again while that fetch runs, or after the photo
/// turned out to be missing or unreadable, never starts another.
public struct FacePhotoBook: Sendable {
    public enum State: Equatable, Sendable {
        /// A fetch for this revision is running.
        case fetching(revision: Int, ticket: Int)
        /// The decoded photo is in the face cache.
        case shown(revision: Int)
        /// The gateway has no picture for this revision, or only Desktop's raster of a drawn face.
        case absent(revision: Int)
        /// The cache dropped the photo; the next look fetches it again.
        case dropped(revision: Int)
    }

    /// How a fetch ended.
    public enum Outcome: Sendable {
        case photo
        case absent
        /// The request failed or was cut short: asked again at the next roster refresh.
        case failed
    }

    private var states: [String: State] = [:]
    private var lastTicket = 0

    public init() {}

    public func state(of name: String) -> State? { states[name] }

    /// Whether a roster refresh should fetch this Bot's avatar now.
    public func needsFetch(_ name: String, revision: Int) -> Bool {
        switch states[name] {
        case nil, .dropped: true
        // One fetch at a time: a newer revision is picked up by the refresh after it ends.
        case .fetching: false
        case .shown(let seen), .absent(let seen): seen != revision
        }
    }

    /// Records a fetch starting; its ticket says whether it is still the current one when it ends.
    public mutating func begin(_ name: String, revision: Int) -> Int {
        lastTicket += 1
        states[name] = .fetching(revision: revision, ticket: lastTicket)
        return lastTicket
    }

    /// Records how a fetch ended. False when a reset or a newer fetch replaced it: then nothing changes.
    @discardableResult
    public mutating func finish(_ name: String, ticket: Int, outcome: Outcome) -> Bool {
        guard case .fetching(let revision, ticket)? = states[name] else { return false }
        switch outcome {
        case .photo: states[name] = .shown(revision: revision)
        case .absent: states[name] = .absent(revision: revision)
        case .failed: states[name] = nil
        }
        return true
    }

    /// A face asked for this photo and the cache no longer has it. True once per drop: that one
    /// call fetches it again; every later ask waits for that fetch.
    public mutating func missed(_ name: String, revision: Int) -> Bool {
        guard states[name] == .shown(revision: revision) else { return false }
        states[name] = .dropped(revision: revision)
        return true
    }

    /// The Bot has no avatar any more.
    public mutating func forget(_ name: String) {
        states[name] = nil
    }

    /// A reconnect: every avatar is fetched again, and fetches still running count for nothing.
    public mutating func reset() {
        states = [:]
    }

    /// The face cache key for a Bot's photo: scoped to its gateway, so two gateways' Bots of
    /// the same name never share a picture.
    public static func key(scope: String, name: String, revision: Int) -> String {
        "face://\(scope)/\(name)#\(revision)"
    }

    /// The Bot and revision behind a key `key(scope:name:revision:)` made for `scope`.
    public static func parse(_ key: String, scope: String) -> (name: String, revision: Int)? {
        let prefix = "face://\(scope)/"
        guard key.hasPrefix(prefix), let hash = key.lastIndex(of: "#"),
              let revision = Int(key[key.index(after: hash)...]) else { return nil }
        let name = String(key[key.index(key.startIndex, offsetBy: prefix.count)..<hash])
        return name.isEmpty ? nil : (name, revision)
    }
}
