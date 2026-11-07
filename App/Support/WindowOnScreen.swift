#if os(macOS)
import AppKit

/// Waits for the app's first window to be on screen. A view's `onAppear` and `task` run before
/// the window's first frame is drawn, so work held back for that frame waits here instead.
@MainActor
enum WindowOnScreen {
    /// Returns at once when a window is already on screen, else when one turns visible, or after
    /// `limit` at most, so nothing waits on a window that never shows.
    static func wait(atMost limit: TimeInterval = 3) async {
        if NSApp.windows.contains(where: { $0.occlusionState.contains(.visible) }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = Waiter(continuation)
            waiter.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    if window.occlusionState.contains(.visible) { waiter.finish() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                MainActor.assumeIsolated { waiter.finish() }
            }
        }
    }

    /// Resumes the wait once, whichever comes first, and stops listening.
    @MainActor
    private final class Waiter {
        var observer: (any NSObjectProtocol)?
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            continuation.resume()
        }
    }
}
#endif
