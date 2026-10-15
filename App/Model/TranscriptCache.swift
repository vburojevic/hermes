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

    static func save(_ key: String, sessionID: String, messages: [SessionMessage], hasEarlier: Bool) {
        guard let url = file(key), !messages.isEmpty else { return }
        let kept = messages.suffix(maxRows)
        let entry = Entry(sessionID: sessionID, messages: Array(kept), hasEarlier: hasEarlier || kept.count < messages.count)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(entry), data.count <= maxBytes else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(_ key: String) {
        guard let url = file(key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every chat of one gateway (its keys start with the gateway's id, Bot Chats with `bot-` and it).
    static func removeAll(gateway id: UUID) {
        guard let root else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(id.uuidString) || name.hasPrefix("bot-\(id.uuidString)") {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }
}
