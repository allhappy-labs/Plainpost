import Foundation
import PlainpostDB
import PlainpostOperations

enum SmartInboxYieldDirective: Equatable, Sendable {
    case cancellation
    case manualPause
    case schedulerPause(reason: String)
    case leaseLost
}

final class OperationChangePulseStream: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let localObserver: NSObjectProtocol
#if os(macOS)
    private let distributedObserver: NSObjectProtocol
#endif
    private let ticker: Task<Void, Never>

    init(pollInterval: Duration) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
        localObserver = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            if scope == .operations || scope == .all { pair.continuation.yield() }
        }
#if os(macOS)
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            if scope == .operations || scope == .all { pair.continuation.yield() }
        }
#endif
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if !Task.isCancelled { pair.continuation.yield() }
            }
        }
    }

    deinit {
        ticker.cancel()
        continuation.finish()
        NotificationCenter.default.removeObserver(localObserver)
#if os(macOS)
        DistributedNotificationCenter.default().removeObserver(distributedObserver)
#endif
    }
}

struct SmartInboxPreemptionWatcher: Sendable {
    let store: SQLiteMailStore
    let jobID: String
    let leaseToken: String
    let priority: Int
    let allowedKinds: Set<PlainpostOperationKind>
    let pollInterval: Duration

    func directive(now: Date = Date()) throws -> SmartInboxYieldDirective? {
        let current = try store.job(id: jobID)
        if current.cancellationRequested { return .cancellation }
        if current.pauseRequested { return .manualPause }
        guard current.state == .running, current.leaseToken == leaseToken else {
            return .leaseLost
        }
        guard try store.smartInboxEnabled() else { return .schedulerPause(reason: "smart-inbox-disabled") }
        guard let pending = try store.nextPendingJob(
            higherPriorityThan: priority,
            now: now,
            allowedKinds: allowedKinds
        ) else { return nil }
        let input = try? JSONDecoder().decode(
            PlainpostAIOperationInput.self,
            from: Data(pending.payloadJSON.utf8)
        )
        return .schedulerPause(reason: input?.operation.schedulerPauseReason ?? "interactive-ai")
    }

    func waitForDirective() async throws -> SmartInboxYieldDirective {
        if let directive = try directive() { return directive }
        let pulses = OperationChangePulseStream(pollInterval: pollInterval)
        for await _ in pulses.events {
            try Task.checkCancellation()
            if let directive = try directive() { return directive }
        }
        throw CancellationError()
    }
}
