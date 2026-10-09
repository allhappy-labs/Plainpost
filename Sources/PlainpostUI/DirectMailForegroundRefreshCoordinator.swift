import Foundation
import PlainpostCore
import PlainpostOperations
import PlainpostOperationRuntime

/// Runtime-owned history execution and independently cancellable UI observers.
@MainActor
final class DirectMailForegroundRefreshCoordinator {
    private let client: LocalOperationClient
    private let didFinish: @Sendable (Account, Result<PlainpostInboxSyncResult, Error>) async -> Void
    // Execution admission ends before terminal callbacks finish, but every
    // callback-bearing task remains retained and joined by shutdown.
    private var activeDrivers: [String: UUID] = [:]
    private var drivers: [UUID: Task<Void, Never>] = [:]
    private var driverFailures: [String: Error] = [:]
    private var waiters: [UUID: Task<PlainpostForegroundInboxRefreshReceipt, Error>] = [:]
    private var drain: Task<Void, Never>?
    private var closed = false

    init(client: LocalOperationClient,
         didFinish: @escaping @Sendable (Account, Result<PlainpostInboxSyncResult, Error>) async -> Void) {
        self.client = client
        self.didFinish = didFinish
    }

    func refresh(account: Account, sourceGeneration: Int64) async throws -> IMAPSyncResult {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let request = try client.requestForegroundInboxRefresh(.init(
            accountID: account.id, trigger: .manual, scope: .recent,
            expectedDirectSourceGeneration: sourceGeneration
        ))
        if activeDrivers[request.jobID] == nil {
            driverFailures[request.jobID] = nil
            let driverID = UUID()
            activeDrivers[request.jobID] = driverID
            drivers[driverID] = Task { [weak self, client, didFinish] in
                let outcome = await client.driveForegroundInboxRefreshJob(request)
                let result = outcome.result
                if self?.activeDrivers[request.jobID] == driverID {
                    self?.activeDrivers[request.jobID] = nil
                    if case .failure(let error) = result { self?.driverFailures[request.jobID] = error }
                }
                // Actual terminal execution ownership includes adopting an
                // orphan queued job, but excludes observing another driver.
                if outcome.ownsTerminalEffects, !Task.isCancelled { await didFinish(account, result) }
                self?.drivers[driverID] = nil
            }
        }
        let id = UUID()
        let waiter = Task { [weak self, client] in
            while true {
                try Task.checkCancellation()
                guard self?.closed == false else { throw CancellationError() }
                if let receipt = try client.foregroundInboxRefreshReceipt(request) { return receipt }
                if let error = self?.driverFailures[request.jobID] { throw error }
                // SQLite is authority; polling has no observer registration race.
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        waiters[id] = waiter
        defer { waiters[id] = nil }
        let receipt = try await withTaskCancellationHandler {
            try await waiter.value
        } onCancel: {
            waiter.cancel()
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return IMAPSyncResult(
            syncedMessageCount: receipt.committedMessageCount,
            newlyDiscoveredMessageCount: receipt.newlyDiscoveredMessageCount,
            source: .recentImport
        )
    }

    func shutdown() async {
        if let drain { await drain.value; return }
        closed = true
        let observers = Array(waiters.values)
        let owners = Array(drivers.values)
        observers.forEach { $0.cancel() }
        owners.forEach { $0.cancel() }
        let task = Task {
            for observer in observers { _ = await observer.result }
            for owner in owners { await owner.value }
        }
        drain = task
        await task.value
        waiters.removeAll()
        drivers.removeAll()
        activeDrivers.removeAll()
        driverFailures.removeAll()
    }
}
