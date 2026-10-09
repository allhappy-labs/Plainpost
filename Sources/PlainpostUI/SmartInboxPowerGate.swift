import Combine
import Foundation
import PlainpostOperations

public enum SmartInboxPowerGateError: LocalizedError, Equatable {
    case lowPowerMode
    public var errorDescription: String? { "Smart Inbox is paused in Low Power Mode." }
}

/// iOS only: Smart Inbox does not start or continue sorting while Low Power Mode is on.
final class SmartInboxPowerGate: @unchecked Sendable {
    #if os(iOS)
    static let defaultAppliesLowPowerMode = true
    #else
    static let defaultAppliesLowPowerMode = false
    #endif

    private let isLowPowerModeEnabled: @Sendable () -> Bool
    private let appliesLowPowerMode: Bool
    private let notificationCenter: NotificationCenter
    private let subject = PassthroughSubject<Bool, Never>()
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private var subscriptions: [AnyCancellable] = []

    init(
        isLowPowerModeEnabled: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        notificationCenter: NotificationCenter = .default,
        appliesLowPowerMode: Bool = SmartInboxPowerGate.defaultAppliesLowPowerMode
    ) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.notificationCenter = notificationCenter
        self.appliesLowPowerMode = appliesLowPowerMode
        guard appliesLowPowerMode else { return }
        token = notificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.subject.send(self.allowsWork)
        }
    }

    deinit { token.map(notificationCenter.removeObserver) }

    var allowsWork: Bool {
        appliesLowPowerMode ? !isLowPowerModeEnabled() : true
    }

    /// Emits `allowsWork` on every power-state change, on the posting thread.
    var allowsWorkChanges: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }

    func observe(onChange: @escaping @Sendable (_ allowsWork: Bool) -> Void) {
        let subscription = subject.sink(receiveValue: onChange)
        lock.withLock { subscriptions.append(subscription) }
    }
}

/// Low Power Mode pauses a running Re-sort All with the durable "low-power"
/// pause reason, which the worker honors like the user's Pause. When Low Power
/// Mode ends, or at a launch outside it, every Low Power pause is lifted, so a
/// pause outlives neither a fast toggle nor a relaunch. A job the user paused
/// themselves stays paused.
@MainActor
final class SmartInboxLowPowerRerunPolicy {
    private let activeRerunJob: () -> PlainpostDurableJob?
    private let pause: (String) throws -> Void
    private let liftLowPowerPauses: () async throws -> Void
    private let liftRetryDelay: Duration
    private var pending: Task<Void, Never>?

    /// Pause reasons the system sets and later lifts by itself (or that the worker
    /// claims through). Low Power Mode takes them over so nothing resumes the job.
    static let systemPauseReasons: Set<String> = ["mail-sync", "mail-sync-failed", "interactive-ai"]

    /// `pause` must record a Low Power pause; `liftLowPowerPauses` lifts every one and is
    /// retried once after `liftRetryDelay` when it fails.
    init(
        activeRerunJob: @escaping () -> PlainpostDurableJob?,
        pause: @escaping (String) throws -> Void,
        liftLowPowerPauses: @escaping () async throws -> Void,
        liftRetryDelay: Duration = .seconds(2)
    ) {
        self.activeRerunJob = activeRerunJob
        self.pause = pause
        self.liftLowPowerPauses = liftLowPowerPauses
        self.liftRetryDelay = liftRetryDelay
    }

    /// Applies power changes in the order they arrive.
    func schedule(allowsWork: Bool) {
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value
            await self?.powerChanged(allowsWork: allowsWork)
        }
    }

    /// Waits for every scheduled change to finish.
    func settle() async {
        while let current = pending {
            await current.value
            if pending == current { return }
        }
    }

    func powerChanged(allowsWork: Bool) async {
        if allowsWork {
            do {
                try await liftLowPowerPauses()
            } catch {
                try? await Task.sleep(for: liftRetryDelay)
                try? await liftLowPowerPauses()
            }
            return
        }
        guard let job = activeRerunJob(), !job.cancellationRequested else { return }
        let pausable = (job.state == .queued || job.state == .running) && !job.pauseRequested
        let systemPaused = job.state == .paused
            && job.pauseReason.map(Self.systemPauseReasons.contains) == true
        guard pausable || systemPaused else { return }
        try? pause(job.id)
    }
}
