import Foundation

/// Resumes a continuation once, whichever caller comes first: an SDK callback that may run twice,
/// or a deadline racing a callback that may never run. A checked continuation resumed twice traps.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension URLSessionWebSocketTask {
    /// Whether a WebSocket ping comes back within `timeout`. A ping the server never answers
    /// stays pending until the socket closes, which on a half-open connection is never.
    func pingAnswered(within timeout: Duration) async -> Bool {
        await awaitPingAnswer(within: timeout) { done in
            sendPing { error in done(error == nil) }
        }
    }
}

/// Sends a ping through `send` and waits at most `timeout` for its answer, ending once whatever
/// the callback does: answer, fail, run twice, run late from another thread or never run.
func awaitPingAnswer(within timeout: Duration, send: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let once = ResumeOnce(continuation)
        send { once.resume($0) }
        Task {
            try? await Task.sleep(for: timeout)
            once.resume(false)
        }
    }
}
