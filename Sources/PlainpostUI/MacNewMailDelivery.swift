@preconcurrency import Foundation
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB

protocol MacNewMailDelivering: Sendable {
    func start() async
    func stop() async
    /// One bounded pass for a short-lived process (the iPhone's background refresh):
    /// delivers what is due, waiting out aggregation deadlines up to `maxWait`.
    func deliverPending(maxWait: Duration) async
}

public actor MacNewMailDelivery: MacNewMailDelivering {
    private struct ActiveLease {
        let id: String
        let token: String
        var submissionStarted: Bool
    }

    private enum RenderResult {
        case notification(PlainpostNotification)
        case suppress(MacNewMailSuppressionReason)
    }

    private let store: SQLiteMailStore
    private let center: any SystemNotificationCenterAdapting
    private let newMailEnabled: @Sendable () -> Bool
    private let previewEnabled: @Sendable () -> Bool
    private let soundsEnabled: @Sendable () -> Bool
    private let dateProvider: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var isRunning = false
    private var rerunRequested = false
    private var activeLease: ActiveLease?
    private var observer: MacNewMailChangeObserver?
    private var fallbackTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    init(
        store: SQLiteMailStore,
        center: any SystemNotificationCenterAdapting,
        newMailEnabled: @escaping @Sendable () -> Bool = {
            PlainpostNotificationPreference.newMailEnabled
        },
        previewEnabled: @escaping @Sendable () -> Bool = {
            PlainpostNotificationPreference.newMailPreviewEnabled
        },
        soundsEnabled: @escaping @Sendable () -> Bool = {
            PlainpostNotificationPreference.notificationSoundsEnabled
        },
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.store = store
        self.center = center
        self.newMailEnabled = newMailEnabled
        self.previewEnabled = previewEnabled
        self.soundsEnabled = soundsEnabled
        self.dateProvider = dateProvider
        self.sleep = sleep
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        observer = MacNewMailChangeObserver { [weak self] in
            Task { await self?.requestDrain() }
        }
        do {
            try store.recoverMacNewMailNotifications(now: dateProvider())
            _ = try store.cleanupMacNewMailNotifications(
                before: dateProvider().addingTimeInterval(-30 * 24 * 60 * 60)
            )
        } catch {
            // The periodic pass retries local recovery. No content is logged.
        }
        requestDrain()
        if let drainTask { await drainTask.value }
        fallbackTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(.seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.recoverAndRequestDrain()
            }
        }
    }

    public func stop() async {
        guard isRunning || drainTask != nil || fallbackTask != nil || deadlineTask != nil else {
            return
        }
        isRunning = false
        observer?.invalidate()
        observer = nil
        let fallback = fallbackTask
        fallbackTask = nil
        fallback?.cancel()
        let deadline = deadlineTask
        deadlineTask = nil
        deadline?.cancel()
        if let activeLease, !activeLease.submissionStarted {
            _ = try? store.releaseMacNewMailDelivery(
                id: activeLease.id,
                leaseToken: activeLease.token,
                now: dateProvider()
            )
        }
        let drain = drainTask
        drain?.cancel()
        await fallback?.value
        await deadline?.value
        await drain?.value
    }

    func deliverPending(maxWait: Duration) async {
        let deadline = dateProvider().addingTimeInterval(
            Double(maxWait.components.seconds) + Double(maxWait.components.attoseconds) / 1e18
        )
        try? store.recoverMacNewMailNotifications(now: dateProvider())
        while !Task.isCancelled {
            requestDrain()
            if let drainTask { await drainTask.value }
            // A just-ready event waits for its two-second aggregation window.
            guard let wake = try? store.nextMacNewMailDeliveryWakeDate(now: dateProvider()),
                  wake <= deadline else { return }
            do {
                try await sleep(.seconds(max(0.05, wake.timeIntervalSince(dateProvider()))))
            } catch {
                return
            }
        }
    }

    func drainNowForTesting() async {
        requestDrain()
        if let drainTask { await drainTask.value }
    }

    private func recoverAndRequestDrain() {
        guard drainTask == nil, activeLease == nil else {
            rerunRequested = true
            return
        }
        try? store.recoverMacNewMailNotifications(now: dateProvider())
        requestDrain()
    }

    private func requestDrain() {
        rerunRequested = true
        deadlineTask?.cancel()
        deadlineTask = nil
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.runDrainFlight()
        }
    }

    private func runDrainFlight() async {
        repeat {
            rerunRequested = false
            await performDrainPass()
        } while rerunRequested && !Task.isCancelled
        drainTask = nil
        scheduleDeadlineWake()
    }

    private func scheduleDeadlineWake() {
        guard isRunning,
              let deadline = try? store.nextMacNewMailDeliveryWakeDate(
                  now: dateProvider()
              ) else { return }
        // A timer may resume a fraction before SQLite's persisted deadline.
        // Give an already-due retry a bounded grace interval instead of
        // spinning drain flights against the same sub-millisecond timestamp.
        let delay = max(0.05, deadline.timeIntervalSince(dateProvider()))
        deadlineTask = Task { [weak self, sleep] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.deadlineElapsed()
        }
    }

    private func deadlineElapsed() {
        deadlineTask = nil
        requestDrain()
    }

    private func performDrainPass() async {
        let now = dateProvider()
        do {
            _ = try store.formMacNewMailDeliveries(now: now)
            while !Task.isCancelled,
                  let claim = try store.claimMacNewMailDelivery(
                      now: dateProvider(),
                      leaseDuration: 30
                  ) {
                activeLease = ActiveLease(
                    id: claim.id,
                    token: claim.leaseToken,
                    submissionStarted: false
                )
                await deliver(claim)
                activeLease = nil
            }
        } catch {
            if let activeLease, !activeLease.submissionStarted {
                _ = try? store.releaseMacNewMailDelivery(
                    id: activeLease.id,
                    leaseToken: activeLease.token,
                    now: dateProvider()
                )
                self.activeLease = nil
            }
        }
    }

    private func deliver(_ claim: MacNewMailDeliveryClaim) async {
        guard newMailEnabled() else {
            suppress(claim, reason: .notificationsDisabled)
            return
        }
        let authorization = await center.authorizationStatus()
        guard !Task.isCancelled else {
            release(claim)
            return
        }
        switch authorization {
        case .authorized:
            break
        case .denied:
            suppress(claim, reason: .authorizationDenied)
            return
        case .notDetermined:
            suppress(claim, reason: .authorizationNotDetermined)
            return
        case .unavailable:
            suppress(claim, reason: .authorizationUnavailable)
            return
        }

        let renderResult: RenderResult
        do {
            renderResult = try render(claim.contentSource)
        } catch {
            release(claim)
            return
        }
        guard case .notification(let notification) = renderResult else {
            if case .suppress(let reason) = renderResult {
                suppress(claim, reason: reason)
            }
            return
        }
        // A Mac producer's pushes (the iPhone's Direct accounts) already alerted for every
        // message here, one or a summary's; both devices name a message by the same token.
        let delivered = await center.deliveredMessageTokens()
        if !delivered.isEmpty, !claim.messageIDs.isEmpty, claim.messageIDs.allSatisfy({
            delivered.contains(NotificationOpaqueIdentities.messageToken(for: $0.rawValue))
        }) {
            suppress(claim, reason: .pushDelivered)
            return
        }
        guard !Task.isCancelled else {
            release(claim)
            return
        }
        do {
            guard try store.beginMacNewMailSubmission(
                id: claim.id,
                leaseToken: claim.leaseToken,
                now: dateProvider()
            ) else {
                return
            }
            activeLease?.submissionStarted = true
        } catch {
            release(claim)
            return
        }

        do {
            try await center.add(notification)
            _ = try? store.completeMacNewMailSubmission(
                id: claim.id,
                leaseToken: claim.leaseToken,
                now: dateProvider()
            )
        } catch {
            guard !Task.isCancelled else {
                // The request outcome is ambiguous; startup recovery terminalizes it.
                return
            }
            let category: MacNewMailSubmissionErrorCategory
            let retryAt: Date?
            if (error as? SystemNotificationCenterFailure) == .transient {
                category = .systemTemporarilyUnavailable
                let exponent = min(claim.attemptCount, 4)
                retryAt = dateProvider().addingTimeInterval(
                    min(60, 5 * pow(2, Double(exponent)))
                )
            } else if (error as? SystemNotificationCenterFailure) == .permanent {
                category = .systemRejected
                retryAt = nil
            } else {
                category = .unknown
                retryAt = nil
            }
            _ = try? store.failMacNewMailSubmission(
                id: claim.id,
                leaseToken: claim.leaseToken,
                errorCategory: category,
                retryAt: retryAt,
                now: dateProvider()
            )
        }
    }

    private func render(
        _ source: MacNewMailDeliveryContentSource
    ) throws -> RenderResult {
        guard let account = store.accounts.first(where: { $0.id == source.accountID }) else {
            return .suppress(.accountUnavailable)
        }
        let playsSound = soundsEnabled()
        switch source.kind {
        case .individual:
            guard source.messageIDs.count == 1,
                  let message = try store.messageSummaries(ids: source.messageIDs).first,
                  !message.isDeleted
            else {
                return .suppress(.messageUnavailable)
            }
            // Read on another device (or here) before the alert went out.
            guard !message.isSeen else { return .suppress(.messageSeen) }
            let showsPreview = previewEnabled()
            let sender = message.fromDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonempty ?? message.from.rawValue
            let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = message.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = [subject.isEmpty ? "(No subject)" : subject, preview]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            return .notification(PlainpostNotification(
                id: source.deliveryID,
                title: showsPreview ? sender : "New message",
                body: showsPreview ? detail : "Open Plainpost to view it.",
                categoryIdentifier: "new_mail",
                userInfo: [
                    "plainpost.openToken": NotificationOpaqueIdentities.messageToken(
                        for: message.id.rawValue
                    )
                ],
                playsSound: playsSound
            ))
        case .summary:
            guard !source.messageIDs.isEmpty else {
                return .suppress(.messageUnavailable)
            }
            let count = source.eventCount > 500 ? "500+" : String(source.eventCount)
            return .notification(PlainpostNotification(
                id: source.deliveryID,
                title: "New mail",
                body: "\(count) new messages arrived for \(account.email.rawValue).",
                categoryIdentifier: "new_mail",
                userInfo: [
                    "plainpost.openToken": NotificationOpaqueIdentities.accountInboxToken(
                        for: account.id.rawValue
                    )
                ],
                playsSound: playsSound
            ))
        }
    }

    private func suppress(
        _ claim: MacNewMailDeliveryClaim,
        reason: MacNewMailSuppressionReason
    ) {
        _ = try? store.suppressMacNewMailDelivery(
            id: claim.id,
            leaseToken: claim.leaseToken,
            reason: reason,
            now: dateProvider()
        )
    }

    private func release(_ claim: MacNewMailDeliveryClaim) {
        _ = try? store.releaseMacNewMailDelivery(
            id: claim.id,
            leaseToken: claim.leaseToken,
            now: dateProvider()
        )
    }
}

private final class MacNewMailChangeObserver: @unchecked Sendable {
    private let localToken: NSObjectProtocol
#if os(macOS)
    private let distributedToken: NSObjectProtocol
#endif

    init(onChange: @escaping @Sendable () -> Void) {
        localToken = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            if scope == .operations || scope == .all { onChange() }
        }
#if os(macOS)
        distributedToken = DistributedNotificationCenter.default().addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            if scope == .operations || scope == .all { onChange() }
        }
#endif
    }

    func invalidate() {
        NotificationCenter.default.removeObserver(localToken)
#if os(macOS)
        DistributedNotificationCenter.default().removeObserver(distributedToken)
#endif
    }

    deinit { invalidate() }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
