import Foundation
import HermesKit

/// The last transcript seen for each chat, kept on the device (Caches) so opening a chat shows it
/// at once, before the gateway has answered; the fresh copy replaces it when it arrives.
///
/// Reading and writing happen off the main thread. The cache can be purged by the system at any
/// time: it only ever saves a wait, never holds anything that isn't on the gateway.
nonisolated enum TranscriptCache {
    struct Entry: Codable, Sendable {
        var sessionID: String
        var messages: [SessionMessage]
        var hasEarlier: Bool
    }

    /// The newest rows kept per chat: a few screens, not the whole history.
    private static let maxRows = 400
    /// Rows with inline images can be huge; past this a chat isn't cached.
    private static let maxBytes = 8 * 1024 * 1024

    private static var root: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Transcripts", directoryHint: .isDirectory)
    }

    private static func file(_ key: String) -> URL? {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return root?.appending(path: "\(safe).json")
    }

    static func load(_ key: String) async -> Entry? {
        guard let url = file(key) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }.value
    }

    /// Writes and removals, in the order they were asked for: an older save never lands over a
    /// newer one, nor brings back a chat that was just removed.
    private static let writes = DispatchQueue(label: "co.caffeinatedcode.hermes.transcript-cache", qos: .utility)

    /// Saves a chat's newest rows. A private widget's payload is never written here: it goes to
    /// the sealed widget cache of `gateway`, and the rows keep only a pointer to it
    /// (`docs/widgets.md` §8).
    static func save(_ key: String, gateway: UUID, sessionID: String, messages: [SessionMessage], hasEarlier: Bool) {
        guard let url = file(key), !messages.isEmpty else { return }
        let kept = messages.suffix(maxRows)
        writes.async {
            let (rows, payloads) = WidgetPrivacy.atRest(Array(kept))
            var newest: [String: JSONValue] = [:]
            for json in payloads { if let id = json["id"]?.stringValue { newest[id] = json } }
            for json in newest.values { WidgetCache.save(json, result: WidgetReader.read(json), gateway: gateway) }
            let entry = Entry(sessionID: sessionID, messages: rows, hasEarlier: hasEarlier || kept.count < messages.count)
            guard let data = try? JSONEncoder().encode(entry), data.count <= maxBytes else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(_ key: String) {
        guard let url = file(key) else { return }
        writes.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Every chat of one gateway (its keys start with the gateway's id, Bot Chats with `bot-` and it).
    static func removeAll(gateway id: UUID) {
        guard let root else { return }
        writes.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where name.hasPrefix(id.uuidString) || name.hasPrefix("bot-\(id.uuidString)") {
                try? FileManager.default.removeItem(at: root.appending(path: name))
            }
        }
    }
}

/// The last Bot roster seen for each gateway (`profiles.list` rows, as they came), kept the same
/// way: an app that iOS ended in the background opens on its Bots, not on "Connecting to your
/// Bots…" for as long as a busy Mac takes to answer.
nonisolated enum RosterCache {
    private static var root: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Rosters", directoryHint: .isDirectory)
    }

    private static func file(_ gateway: UUID) -> URL? {
        root?.appending(path: "\(gateway.uuidString).json")
    }

    private static let writes = DispatchQueue(label: "co.caffeinatedcode.hermes.roster-cache", qos: .utility)

    static func load(_ gateway: UUID) async -> [JSONValue]? {
        guard let url = file(gateway) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([JSONValue].self, from: data)
        }.value
    }

    static func save(_ gateway: UUID, rows: [JSONValue]) {
        guard let url = file(gateway), !rows.isEmpty else { return }
        writes.async {
            guard let data = try? JSONEncoder().encode(rows) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(_ gateway: UUID) {
        guard let url = file(gateway) else { return }
        writes.async { try? FileManager.default.removeItem(at: url) }
    }
}

/// The last chat list seen for each gateway (`GET /api/sessions` rows), kept the same way: a cold
/// launch while the gateway's Mac is too busy to answer opens on its chats, not an empty sidebar.
nonisolated enum SessionsCache {
    /// The rows kept: the newest page, as far as a sidebar shows before scrolling for more.
    private static let maxRows = 200

    private static var root: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Sessions", directoryHint: .isDirectory)
    }

    private static func file(_ gateway: UUID) -> URL? {
        root?.appending(path: "\(gateway.uuidString).json")
    }

    private static let writes = DispatchQueue(label: "co.caffeinatedcode.hermes.sessions-cache", qos: .utility)

    static func load(_ gateway: UUID) async -> [HermesSession]? {
        guard let url = file(gateway) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([HermesSession].self, from: data)
        }.value
    }

    static func save(_ gateway: UUID, sessions: [HermesSession]) {
        guard let url = file(gateway), !sessions.isEmpty else { return }
        let kept = Array(sessions.prefix(maxRows))
        writes.async {
            guard let data = try? JSONEncoder().encode(kept) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(_ gateway: UUID) {
        guard let url = file(gateway) else { return }
        writes.async { try? FileManager.default.removeItem(at: url) }
    }
}

/// The last model list seen for each gateway (`GET /api/model/options`, as it came), kept the same
/// way: the model picker opens on it while a busy Mac takes its time over the providers.
nonisolated enum ModelOptionsCache {
    private static func file(_ gateway: UUID) -> URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: "\(gateway.uuidString).json")
    }

    private static let writes = DispatchQueue(label: "co.caffeinatedcode.hermes.models-cache", qos: .utility)

    static func load(_ gateway: UUID) async -> Data? {
        guard let url = file(gateway) else { return nil }
        return await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
    }

    static func save(_ gateway: UUID, data: Data) {
        guard let url = file(gateway), !data.isEmpty else { return }
        writes.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(_ gateway: UUID) {
        guard let url = file(gateway) else { return }
        writes.async { try? FileManager.default.removeItem(at: url) }
    }
}
