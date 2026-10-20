import Foundation

/// How a gateway answered its health check (`HermesClient.liveness`).
///
/// A machine that is off, asleep or out of reach never takes the connection, and a gateway that
/// isn't running refuses it. One that takes the connection and the question and then says nothing
/// is running on a machine too loaded to get to it: Hermes on a Mac at load 500 left its health
/// check unanswered for over 20 s while Telegram, queued in the cloud, only arrived late. That is
/// busy, not offline (`docs/connecting-and-voice.md` §8).
public enum GatewayLiveness: Sendable, Equatable {
    /// It answered.
    case answering
    /// It took the connection and the question but didn't answer in time.
    case busy
    /// It isn't there: refused, out of reach, or answered with an error.
    case unreachable(HermesError)

    /// It's there, answering or not.
    public var isThere: Bool {
        if case .unreachable = self { false } else { true }
    }

    /// What a health check that failed with `error` means, given how far its connection got.
    public static func after(_ error: URLError, connection: ConnectionProgress, host: String) -> GatewayLiveness {
        if error.code == .timedOut, connection.reachedServer { return .busy }
        return .unreachable(.from(urlError: error, host: host))
    }
}

/// How far a request's connection got before it ended, from its task metrics.
public struct ConnectionProgress: Sendable, Equatable {
    /// A new connection reached the server: its machine accepted it (the TLS handshake may still
    /// have been waiting). One taken from the pool doesn't count: a request written into a link
    /// that died meanwhile (a Mac that slept) also goes unanswered.
    public var reachedServer: Bool

    public init(reachedServer: Bool) {
        self.reachedServer = reachedServer
    }

    public static let none = ConnectionProgress(reachedServer: false)

    /// From a finished task's transactions: any fresh one that connected.
    public init(_ transactions: [URLSessionTaskTransactionMetrics]) {
        reachedServer = transactions.contains { transaction in
            !transaction.isReusedConnection
                && (transaction.connectEndDate != nil || transaction.secureConnectionStartDate != nil)
        }
    }
}

/// Collects one task's metrics, so a timeout can say whether the server had taken the connection.
final class ConnectionWitness: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var progress = ConnectionProgress.none

    var reached: ConnectionProgress {
        lock.withLock { progress }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let found = ConnectionProgress(metrics.transactionMetrics)
        lock.withLock { progress = found }
    }

    /// Health checks carry no key, but stay on their server all the same.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url else { return nil }
        return SameOriginRedirects.allows(from: from, to: to) ? request : nil
    }
}
