import Foundation

/// Runs queued jobs in this process, for an app with no background helper to
/// launch (iOS). Each signal drains every job the runtime may claim that is due;
/// a signal during a drain runs one more pass, so no job waits for the next one.
public final class InProcessOperationWorkerSignal: OperationWorkerSignaling, @unchecked Sendable {
    private let runtime: LocalOperationRuntime
    private let lock = NSLock()
    private var isDraining = false
    private var drainAgain = false

    public init(runtime: LocalOperationRuntime) {
        self.runtime = runtime
    }

    /// Returns at once; the drain runs on its own task.
    public func signalWork() async throws {
        guard claimDrain() else { return }
        Task.detached(priority: .utility) { [self] in
            repeat {
                // A failed job is rescheduled with backoff, so the loop ends at the
                // first pass that finds nothing due.
                while (try? await runtime.processNextJobContinuingAfterFailure()) != nil {}
            } while finishDrain()
        }
    }

    /// Waits for the current drain, for tests.
    package func waitUntilIdle() async {
        while lock.withLock({ isDraining }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func claimDrain() -> Bool {
        lock.withLock {
            guard !isDraining else {
                drainAgain = true
                return false
            }
            isDraining = true
            return true
        }
    }

    /// True when a signal arrived during the drain and another pass must run.
    private func finishDrain() -> Bool {
        lock.withLock {
            if drainAgain {
                drainAgain = false
                return true
            }
            isDraining = false
            return false
        }
    }
}
