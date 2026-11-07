import Foundation

/// One read of a list at a time, the newest one winning. A page reads again when the gateway comes
/// online, when the person pulls to refresh or taps Try Again: a new read cancels the one still on
/// its way, so a read that failed while the gateway was offline can't land after the one that
/// worked and empty the list again (`docs/tasks.md` §1).
@MainActor
public final class LatestRead<Value: Sendable> {
    private var current: Task<Result<Value, any Error>, Never>?
    private var generation = 0

    /// A read is on its way.
    public private(set) var isReading = false

    public init() {}

    /// Runs `body`, cancelling the read still on its way. Answers nil when this read was cancelled
    /// or a newer one replaced it: the caller keeps what it has and leaves the answer to the newer one.
    public func read(_ body: @escaping @Sendable () async throws -> Value) async -> Result<Value, any Error>? {
        current?.cancel()
        generation += 1
        let mine = generation
        let task = Task<Result<Value, any Error>, Never> {
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        current = task
        isReading = true
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard mine == generation else { return nil }
        current = nil
        isReading = false
        if task.isCancelled { return nil }
        if case .failure(let error) = result, error is CancellationError { return nil }
        return result
    }
}
