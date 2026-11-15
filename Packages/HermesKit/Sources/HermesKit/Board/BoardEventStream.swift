import Foundation

/// The board's live events (`WS /api/plugins/kanban/events?board=&since=`): the gateway sends
/// `{events, cursor}` whenever cards change, and nothing while the board is quiet. The board is
/// pinned when the socket opens; another board needs another socket. `BackendClient.boardEvents`
/// opens it on the backend's own session, so it never follows a redirect to another server.
enum BoardEventStream {
    /// Batches until the socket closes or the caller stops iterating. The stream throws when the
    /// socket fails (refused, dropped, a ping unanswered), so the caller can poll or reconnect.
    static func batches(socket: URLSessionWebSocketTask) -> AsyncThrowingStream<BoardEventBatch, any Error> {
        AsyncThrowingStream { continuation in
            socket.maximumMessageSize = 8 * 1024 * 1024
            socket.resume()
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let text: String? = switch message {
                        case .string(let text): text
                        case .data(let data): String(data: data, encoding: .utf8)
                        @unknown default: nil
                        }
                        if let text, let json = JSONValue.parse(text), let batch = BoardEventBatch(json: json) {
                            continuation.yield(batch)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled
                        ? CancellationError() : AccessRefusal.refused(socket, error: error) ?? error)
                }
            }
            // A quiet board sends nothing, so a dead connection would go unnoticed without pings.
            // The wait ends once even when URLSession calls the ping's handler twice or never
            // (docs/board.md §1.2).
            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { return }
                    if await !socket.pingAnswered(within: .seconds(10)) {
                        socket.cancel(with: .abnormalClosure, reason: nil)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                receiver.cancel()
                pinger.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
