#if os(macOS)
import AppKit

/// Whether the Mac's screen is locked or asleep: a chat on screen then isn't being read, so it
/// doesn't mark anything read (`docs/inbox.md` §4).
@MainActor
enum ScreenLock {
    private(set) static var isLocked = false
    private static var locked = false
    private static var asleep = false
    private static var observers: [any NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { set(locked: true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { set(locked: false) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { set(asleep: true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { set(asleep: false) }
        })
    }

    private static func set(locked: Bool? = nil, asleep: Bool? = nil) {
        if let locked { self.locked = locked }
        if let asleep { self.asleep = asleep }
        isLocked = self.locked || self.asleep
    }
}
#endif
