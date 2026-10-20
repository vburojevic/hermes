import Foundation
import Observation

/// Which messages were spoken in Talk, so the chat marks them "Spoken" (`docs/voice.md` §4.3).
/// Hermes doesn't keep a message's surface, so this device remembers the rows it sent (by the
/// `user_row_id` `prompt.submit` answers) and the local ids until the chat reloads.
@MainActor
@Observable
final class SpokenMessages {
    static let shared = SpokenMessages()

    /// Stored session id → row ids ("m<id>") and local ids.
    private(set) var spoken: [String: Set<String>]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "talk.spokenRows"
    /// Rows kept per chat: enough for any call.
    private static let perChat = 400

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        spoken = saved.mapValues(Set.init)
    }

    func markSent(localID: String?, rowID: Int?, session: String?) {
        let chat = session ?? "draft"
        var ids = spoken[chat, default: []]
        if let localID { ids.insert(localID) }
        if let rowID { ids.insert("m\(rowID)") }
        if ids.count > Self.perChat { ids = Set(ids.sorted().suffix(Self.perChat)) }
        spoken[chat] = ids
        defaults.set(spoken.mapValues { Array($0.filter { $0.hasPrefix("m") }) }, forKey: Self.key)
    }

    func isSpoken(_ entryID: String, session: String?) -> Bool {
        spoken[session ?? "draft"]?.contains(entryID) == true
    }
}
