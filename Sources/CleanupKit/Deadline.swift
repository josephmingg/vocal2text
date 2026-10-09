import Foundation

/// A deadline that holds even when the work ignores cancellation (docs/17
/// §11). A task group cannot give that — it always waits for its children,
/// so a provider that never checks for cancellation (Apple's on-device model
/// takes no timeout) kept the command preview spinning past its limit.
public enum Deadline {
    /// Returns `operation`'s result, or throws `CleanupError.timedOut` once
    /// `limit` passes — immediately, without waiting for the operation, which
    /// is cancelled and left to finish (or not) on its own. Cancelling the
    /// caller cancels the operation and throws `CancellationError`.
    public static func run<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                gate.add(Task {
                    do {
                        gate.finish(.success(try await operation()))
                    } catch {
                        gate.finish(.failure(error))
                    }
                })
                gate.add(Task {
                    try? await Task.sleep(for: limit)
                    gate.finish(.failure(CleanupError.timedOut))
                })
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Resumes the continuation exactly once, with whichever side finished
    /// first, and cancels the rest.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var tasks: [Task<Void, Never>] = []
        private var outcome: Result<T, Error>?

        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func add(_ task: Task<Void, Never>) {
            lock.lock()
            let finished = outcome != nil
            if !finished { tasks.append(task) }
            lock.unlock()
            if finished { task.cancel() }
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = result
            let continuation = self.continuation
            self.continuation = nil
            let pending = tasks
            tasks = []
            lock.unlock()
            continuation?.resume(with: result)
            for task in pending { task.cancel() }
        }
    }
}
