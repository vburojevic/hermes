import CryptoKit
import Foundation
import HermesKit

/// Widget payloads kept on the device per gateway (Caches), so a reopened chat draws its cards
/// at once (`docs/widgets.md` §4). Private payloads are sealed with a key that never leaves this
/// device's Keychain, and nothing here is ever indexed (§8). Like the transcript cache, it only
/// saves a wait: everything in it is on the gateway too.
nonisolated enum WidgetCache {
    private static let writes = DispatchQueue(label: "co.caffeinatedcode.hermes.widget-cache", qos: .utility)
    private static let keychain = KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "co.caffeinatedcode.hermes").widgets")

    private static func folder(_ gateway: UUID) -> URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Widgets", directoryHint: .isDirectory)
            .appending(path: gateway.uuidString, directoryHint: .isDirectory)
    }

    /// A widget id is `w_` and letters or digits: safe as a file name as it is.
    private static func file(_ id: String, gateway: UUID, sealed: Bool) -> URL? {
        guard WidgetDirective.isWidgetID(id) else { return nil }
        return folder(gateway)?.appending(path: "\(id).\(sealed ? "sealed" : "json")")
    }

    static func save(_ json: JSONValue, result: WidgetReader.Result, gateway: UUID) {
        guard let id = result.id, let data = try? JSONEncoder().encode(json) else { return }
        let sealed = result.isPrivate
        guard let url = file(id, gateway: gateway, sealed: sealed), let other = file(id, gateway: gateway, sealed: !sealed) else { return }
        writes.async {
            let bytes: Data
            if sealed {
                guard let key = key(), let box = try? ChaChaPoly.seal(data, using: key) else { return }
                bytes = box.combined
            } else {
                bytes = data
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // A revision that changed its sensitivity leaves no copy in the other form.
            try? FileManager.default.removeItem(at: other)
        }
    }

    static func load(_ id: String, gateway: UUID) async -> JSONValue? {
        guard let plain = file(id, gateway: gateway, sealed: false), let sealed = file(id, gateway: gateway, sealed: true) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: plain) { return JSONValue.parse(data) }
            guard let data = try? Data(contentsOf: sealed), let key = key(),
                  let box = try? ChaChaPoly.SealedBox(combined: data), let opened = try? ChaChaPoly.open(box, using: key) else { return nil }
            return JSONValue.parse(opened)
        }.value
    }

    /// The gateway was removed: its widgets go too.
    static func removeAll(gateway: UUID) {
        guard let folder = folder(gateway) else { return }
        writes.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// The sealing key: made once, kept in the Keychain on this device only.
    private static func key() -> SymmetricKey? {
        if let stored = try? keychain.string(for: "cache-key"), let data = Data(base64Encoded: stored), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        guard (try? keychain.setString(data.base64EncodedString(), for: "cache-key")) != nil else { return nil }
        return key
    }

    // MARK: - This device's answers and view state

    /// Mids this device sent: the newest few hundred are enough to know its own answers.
    static func loadMine(gateway: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "widgets.mine.\(gateway.uuidString)") ?? [])
    }

    static func saveMine(_ mids: Set<String>, gateway: UUID) {
        UserDefaults.standard.set(Array(mids.prefix(400)), forKey: "widgets.mine.\(gateway.uuidString)")
    }

    /// What the person has typed and picked in cards so far, sealed like private payloads: a form's
    /// draft answers are the private part of a private widget (security scan F35). Builds before
    /// this kept them in the clear in `views.json`, read once and then removed.
    static func loadViews(gateway: UUID) -> [String: WidgetViewState] {
        guard let folder = folder(gateway) else { return [:] }
        let legacy = folder.appending(path: "views.json")
        var data: Data?
        if let bytes = try? Data(contentsOf: folder.appending(path: "views.sealed")), let key = key(),
           let box = try? ChaChaPoly.SealedBox(combined: bytes) {
            data = try? ChaChaPoly.open(box, using: key)
        }
        if data == nil { data = try? Data(contentsOf: legacy) }
        try? FileManager.default.removeItem(at: legacy)
        return data.flatMap { try? JSONDecoder().decode([String: WidgetViewState].self, from: $0) } ?? [:]
    }

    static func saveViews(_ views: [String: WidgetViewState], gateway: UUID) {
        guard let folder = folder(gateway), let data = try? JSONEncoder().encode(views) else { return }
        writes.async {
            guard let key = key(), let box = try? ChaChaPoly.seal(data, using: key) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? box.combined.write(to: folder.appending(path: "views.sealed"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? FileManager.default.removeItem(at: folder.appending(path: "views.json"))
        }
    }
}
