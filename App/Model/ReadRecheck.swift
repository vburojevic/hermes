import Foundation

/// When to ask Hermes again about read marks another device may have moved (`docs/inbox.md` §1),
/// for the Bots (`BotRoster`) and the chats (`UnreadStore`) alike.
///
/// Hermes' sessions moved (`sessions.changed`, which covers read marks) or the app came to the
/// front: ask at once, then at most every 3 s while changes keep coming (a turn streaming anywhere
/// moves them), the last change included. Between changes, each thing still unread is asked
/// about every 15 s at first, backing off to every 2 minutes while it stays unread.
final class ReadRecheck {
    private let check: (_ now: Bool) -> Void
    private var soon: Task<Void, Never>?
    private var lastSoon = Date.distantPast
    private var askedAt: [String: Date] = [:]
    private var asks: [String: Int] = [:]
    private var asking: Set<String> = []

    /// - Parameter check: asks about what's unread; `now` when something moved, so every key is
    ///   due regardless of its backoff.
    init(check: @escaping (_ now: Bool) -> Void) {
        self.check = check
    }

    /// Something may have moved: a check soon.
    func mayHaveMoved() {
        guard soon == nil else { return }
        let wait = max(0, 3 - Date.now.timeIntervalSince(lastSoon))
        soon = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.soon = nil
            self.lastSoon = .now
            self.check(true)
        }
    }

    /// Whether `key` is due a question now. If so it counts as asked until `answered(_:)`.
    func isDue(_ key: String, now: Bool) -> Bool {
        guard !asking.contains(key) else { return false }
        let count = asks[key] ?? 0
        let every = min(120, 15 * pow(2, Double(count)))
        guard now || Date.now.timeIntervalSince(askedAt[key] ?? .distantPast) > every else { return false }
        askedAt[key] = .now
        if !now { asks[key] = count + 1 }
        asking.insert(key)
        return true
    }

    func answered(_ key: String) {
        asking.remove(key)
    }

    /// Only these are still unread: the others' backoff starts over next time.
    func keep(_ keys: Set<String>) {
        asks = asks.filter { keys.contains($0.key) }
    }

    func cancel() {
        soon?.cancel()
        soon = nil
    }
}
