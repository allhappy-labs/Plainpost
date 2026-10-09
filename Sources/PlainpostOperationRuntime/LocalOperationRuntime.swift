import Foundation
import PlainpostAccounts
import PlainpostAI
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostSecrets

/// A durable direct mailbox job whose account is now in Node mode.
public enum NodeModeMailboxWork: Equatable, Sendable {
    case flag(jobID: String, messageID: MessageID, seen: Bool)
    case archive(jobID: String, messageID: MessageID, destinationMailboxPath: String)
}

/// Converts a Node-mode account's queued flag or archive job into a routed
/// mail intent. Returns true only when the local store may apply the change
/// now (the Node took it, or its direct write is confirmed); an archive job
/// then completes locally. Throwing retries the job.
public typealias NodeModeMailboxHandoff = @Sendable (NodeModeMailboxWork) async throws -> Bool

/// An approved send (agent approval or browser reply) of a Node-backed
/// account, or one whose intent is already journaled.
public struct NodeModeApprovedSend: Equatable, Sendable {
    public let jobID: String
    public let requestID: SendRequestID
    public let actorID: String

    public init(jobID: String, requestID: SendRequestID, actorID: String) {
        self.jobID = jobID
        self.requestID = requestID
        self.actorID = actorID
    }
}

/// Routes an approved send through the mail-intent router (the Node, or the
/// provider directly in fallback) and records the outcome on the send
/// request. Returning completes the job. It throws only before anything is
/// journaled; the job then fails (approval jobs have one attempt) and the
/// request is `failed`, so a new approval starts over.
public typealias NodeModeApprovedSendHandoff = @Sendable (NodeModeApprovedSend) async throws -> Void

/// An approved send that must go through the mail-intent router, in a
/// runtime that has no route to it. Nothing was sent: the job fails as a
/// transient error would (approval jobs have a single attempt), the request
/// becomes `failed`, and the user may approve it again.
public struct NodeModeApprovedSendUnroutable: Error, Equatable, Sendable {}

public final class LocalOperationRuntime: @unchecked Sendable {
    public let store: SQLiteMailStore
    private let credentials: any CredentialVault
    private let credentialResolver: MailCredentialResolver
    private let environment: [String: String]
    private let allowedJobKinds: Set<PlainpostOperationKind>?
    private let requireExplicitDirectSource: Bool
    private let selectedDirectAccountID: AccountID?
    private let expectedDirectSourceGeneration: Int64?
    private let requireSelectedDirectClaimScope: Bool
    private let aiProviderResolver: (@Sendable (PlainpostAIOperationInput) throws -> any AIProvider)?
    private let mailboxFlagClientFactory: @Sendable (Account) -> any IMAPClientProtocol
    private let inboxSyncClientFactory: @Sendable (String, UInt16) -> any IMAPClientProtocol
    private let workerSignal: any OperationWorkerSignaling
    private let failureDateProvider: @Sendable () -> Date
    private var beforeJobExecution: (@Sendable (PlainpostDurableJob) throws -> Void)?
    /// Set by the service's background runtime: a queued direct flag or
    /// archive job of an account now in Node mode goes to the mutation
    /// router instead of failing permanently at the flip.
    private let nodeModeMailboxHandoff: NodeModeMailboxHandoff?
    /// Set by the service: approved sends of Node-backed accounts go to
    /// the mutation router instead of direct SMTP.
    private let nodeModeApprovedSendHandoff: NodeModeApprovedSendHandoff?
    private var afterSmartInboxProviderFailureSelected: (@Sendable () async -> Void)?
    private let executionGate = RuntimeExecutionGate()
    private let smartInboxProviderCache = SmartInboxProviderResolutionCache()
    private let smartInboxPreemptionPollInterval: Duration = .milliseconds(25)
    /// Lease length and heartbeat cadence for claimed jobs. Tests shorten
    /// the heartbeat; production keeps 180 s leases renewed every 30 s.
    var leaseTiming = LeaseTiming.production
    /// Test failpoint that runs just before the post-gate lease fence.
    var beforeLeaseFence: (@Sendable (PlainpostDurableJob) throws -> Void)?

    struct LeaseTiming: Sendable {
        var duration: TimeInterval
        var heartbeatInterval: Duration

        static let production = LeaseTiming(duration: 180, heartbeatInterval: .seconds(30))
    }

    /// The store's answer when a lease token no longer owns a running job.
    static let leaseLostError = PlainpostError.validationFailed("Local operation lease is no longer valid.")

    private enum JobExecutionOutcome {
        case completed(String?)
        case syncCompleted
        case credentialsPaused
        case yielded
    }

    private enum SmartInboxClassificationRaceResult: Sendable {
        case response(AIClassificationBatchResponse)
        case failure(SmartInboxProviderFailure)
        case yield(SmartInboxYieldDirective)
    }

    private struct SmartInboxProviderFailure: Error, @unchecked Sendable {
        let underlying: any Error

        init(_ underlying: any Error) {
            self.underlying = underlying
        }
    }

    static let credentialsUnavailablePauseReason = "credentials-unavailable"
    static let nodeModeSkippedPhase = "skipped-node-mode"
    static let nodeModeRefusal = "This account's mail is handled by the Sync Node."

    public init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowedJobKinds: Set<PlainpostOperationKind>? = nil,
        requireExplicitDirectSource: Bool = false,
        selectedDirectAccountID: AccountID? = nil,
        expectedDirectSourceGeneration: Int64? = nil,
        requireSelectedDirectClaimScope: Bool = false,
        inboxSyncClientFactory: @escaping @Sendable (String, UInt16) -> any IMAPClientProtocol = {
            MailTransportClientFactory.imapClient(host: $0, port: $1)
        },
        aiProviderResolver: (@Sendable (PlainpostAIOperationInput) throws -> any AIProvider)? = nil,
        credentialResolver: MailCredentialResolver? = nil,
        failureDateProvider: @escaping @Sendable () -> Date = { Date() },
        nodeModeMailboxHandoff: NodeModeMailboxHandoff? = nil,
        nodeModeApprovedSendHandoff: NodeModeApprovedSendHandoff? = nil
    ) {
        self.store = store
        self.nodeModeMailboxHandoff = nodeModeMailboxHandoff
        self.nodeModeApprovedSendHandoff = nodeModeApprovedSendHandoff
        self.credentials = credentials
        self.credentialResolver = credentialResolver
            ?? .withoutGoogleOAuth(store: store, credentials: credentials)
        self.environment = environment
        self.allowedJobKinds = allowedJobKinds
        self.requireExplicitDirectSource = requireExplicitDirectSource
        self.selectedDirectAccountID = selectedDirectAccountID
        self.expectedDirectSourceGeneration = expectedDirectSourceGeneration
        self.requireSelectedDirectClaimScope = requireSelectedDirectClaimScope
        self.inboxSyncClientFactory = inboxSyncClientFactory
        self.aiProviderResolver = aiProviderResolver
        // Write-back reaches the provider the same way sync does.
        self.mailboxFlagClientFactory = { account in
            inboxSyncClientFactory(account.imapHost, account.imapPort)
        }
        self.workerSignal = NoopOperationWorkerSignal()
        self.failureDateProvider = failureDateProvider
    }

    convenience init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowedJobKinds: Set<PlainpostOperationKind>? = nil,
        aiProviderResolver: (@Sendable (PlainpostAIOperationInput) throws -> any AIProvider)? = nil,
        beforeJobExecution: @escaping @Sendable (PlainpostDurableJob) throws -> Void,
        failureDateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            store: store,
            credentials: credentials,
            environment: environment,
            allowedJobKinds: allowedJobKinds,
            aiProviderResolver: aiProviderResolver,
            failureDateProvider: failureDateProvider
        )
        self.beforeJobExecution = beforeJobExecution
    }

    package convenience init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowedJobKinds: Set<PlainpostOperationKind>? = nil,
        aiProviderResolver: (@Sendable (PlainpostAIOperationInput) throws -> any AIProvider)? = nil,
        afterSmartInboxProviderFailureSelected: @escaping @Sendable () async -> Void,
        failureDateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            store: store,
            credentials: credentials,
            environment: environment,
            allowedJobKinds: allowedJobKinds,
            aiProviderResolver: aiProviderResolver,
            failureDateProvider: failureDateProvider
        )
        self.afterSmartInboxProviderFailureSelected = afterSmartInboxProviderFailureSelected
    }

    public init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowedJobKinds: Set<PlainpostOperationKind>? = nil,
        requireExplicitDirectSource: Bool = false,
        selectedDirectAccountID: AccountID? = nil,
        expectedDirectSourceGeneration: Int64? = nil,
        requireSelectedDirectClaimScope: Bool = false,
        aiProviderResolver: (@Sendable (PlainpostAIOperationInput) throws -> any AIProvider)? = nil,
        mailboxFlagClientFactory: @escaping @Sendable (Account) -> any IMAPClientProtocol,
        inboxSyncClientFactory: @escaping @Sendable (String, UInt16) -> any IMAPClientProtocol = {
            MailTransportClientFactory.imapClient(host: $0, port: $1)
        },
        workerSignal: any OperationWorkerSignaling = NoopOperationWorkerSignal(),
        credentialResolver: MailCredentialResolver? = nil,
        failureDateProvider: @escaping @Sendable () -> Date = { Date() },
        nodeModeMailboxHandoff: NodeModeMailboxHandoff? = nil,
        nodeModeApprovedSendHandoff: NodeModeApprovedSendHandoff? = nil
    ) {
        self.store = store
        self.nodeModeMailboxHandoff = nodeModeMailboxHandoff
        self.nodeModeApprovedSendHandoff = nodeModeApprovedSendHandoff
        self.credentials = credentials
        self.credentialResolver = credentialResolver
            ?? .withoutGoogleOAuth(store: store, credentials: credentials)
        self.environment = environment
        self.allowedJobKinds = allowedJobKinds
        self.requireExplicitDirectSource = requireExplicitDirectSource
        self.selectedDirectAccountID = selectedDirectAccountID
        self.expectedDirectSourceGeneration = expectedDirectSourceGeneration
        self.requireSelectedDirectClaimScope = requireSelectedDirectClaimScope
        self.aiProviderResolver = aiProviderResolver
        self.mailboxFlagClientFactory = mailboxFlagClientFactory
        self.inboxSyncClientFactory = inboxSyncClientFactory
        self.workerSignal = workerSignal
        self.failureDateProvider = failureDateProvider
    }

    @discardableResult
    public func processNextJob(
        now: Date = Date()
    ) async throws -> PlainpostDurableJob? {
        try await processNextJob(
            now: now,
            propagatingExecutionFailure: true,
            releaseLeaseOnCancellation: false
        )
    }

    @discardableResult
    package func processNextJobContinuingAfterFailure(
        now: Date = Date()
    ) async throws -> PlainpostDurableJob? {
        try await processNextJob(
            now: now,
            propagatingExecutionFailure: false,
            releaseLeaseOnCancellation: false
        )
    }

    private func processNextJob(
        now: Date,
        propagatingExecutionFailure: Bool,
        releaseLeaseOnCancellation: Bool,
        didFinishOwnedJob: (@Sendable (String, Bool) -> Void)? = nil,
        onlyJobID: String? = nil
    ) async throws -> PlainpostDurableJob? {
        let leaseTiming = self.leaseTiming
        // A scoped worker with no selected account is the device-wide iOS worker: it claims
        // for every Direct account, each job at its own account's generation.
        guard let job = try store.claimNextJob(
            now: now,
            leaseDuration: leaseTiming.duration,
            allowedKinds: allowedJobKinds,
            selectedDirectAccountID: selectedDirectAccountID,
            expectedDirectSourceGeneration: expectedDirectSourceGeneration,
            everyDirectAccount: requireSelectedDirectClaimScope && selectedDirectAccountID == nil,
            onlyJobID: onlyJobID
        ),
              let leaseToken = job.leaseToken else {
            return nil
        }
        // Renew from the claim onward. The wait for the execution gate below
        // can outlast the lease when a long sync or AI job holds the gate.
        let heartbeat = Task { [store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: leaseTiming.heartbeatInterval)
                guard !Task.isCancelled else { return }
                try? store.renewJobLease(
                    id: job.id,
                    leaseToken: leaseToken,
                    now: Date(),
                    leaseDuration: leaseTiming.duration
                )
            }
        }
        let executionKey = runtimeExecutionKey(for: job)
        var ownsPermit = false
        var deliveryAdmitted = false
        let result: Result<PlainpostDurableJob?, Error>
        do {
            try await executionGate.acquire(executionKey)
            ownsPermit = true
            try Task.checkCancellation()
            result = .success(try await processClaimedJob(
                job, leaseToken: leaseToken, now: now, leaseTiming: leaseTiming,
                propagatingExecutionFailure: propagatingExecutionFailure,
                deliveryAdmitted: &deliveryAdmitted,
                didFinishOwnedJob: didFinishOwnedJob
            ))
        } catch {
            result = .failure(error)
        }
        // Join the heartbeat before cancellation settlement, and return the
        // permit before the caller returns. Only successful acquire owns it.
        heartbeat.cancel()
        await heartbeat.value
        if case .failure(let error) = result, error is CancellationError,
           releaseLeaseOnCancellation, !deliveryAdmitted {
            // Preserve the caller's retry policy. The token-checked update
            // cannot release a replacement owner's lease. Once a delivery
            // provider is admitted, cancellation must retain uncertain recovery.
            _ = try? store.releaseJobLeaseForRetry(id: job.id, leaseToken: leaseToken)
        }
        if ownsPermit {
            await executionGate.release(executionKey)
        }
        return try result.get()
    }

    private func processClaimedJob(
        _ job: PlainpostDurableJob,
        leaseToken: String,
        now: Date,
        leaseTiming: LeaseTiming,
        propagatingExecutionFailure: Bool,
        deliveryAdmitted: inout Bool,
        didFinishOwnedJob: (@Sendable (String, Bool) -> Void)?
    ) async throws -> PlainpostDurableJob? {
        // Fence: confirm this runtime still owns the job after the gate wait.
        // Renewing from the later clock never shortens a lease that was
        // claimed with an injected future `now`.
        let fenced: PlainpostDurableJob
        do {
            try beforeLeaseFence?(job)
            try store.renewJobLease(
                id: job.id,
                leaseToken: leaseToken,
                now: max(now, Date()),
                leaseDuration: leaseTiming.duration
            )
            fenced = try store.job(id: job.id)
        } catch let error as PlainpostError where error == Self.leaseLostError {
            // Another drainer recovered the job during the wait. Running it
            // anyway could send mail that the record already calls uncertain.
            return try store.job(id: job.id)
        } catch {
            // Ownership is unknown, for example the database was busy. Hand
            // the lease back so the job stays retryable instead of sitting
            // `running` until recovery treats it as abandoned. Nothing ran,
            // so the attempt is refunded.
            _ = try? store.releaseJobLeaseForRetry(id: job.id, leaseToken: leaseToken)
            throw error
        }
        // A cancellation requested while the job waited for the gate wins
        // over execution: the user may have cancelled a queued send.
        if fenced.cancellationRequested {
            try store.acknowledgeJobCancellation(id: job.id, leaseToken: leaseToken)
            didFinishOwnedJob?(job.id, false)
            return try store.job(id: job.id)
        }
        do {
            try Task.checkCancellation()
            try beforeJobExecution?(job)
            try Task.checkCancellation()
            if job.cancellationRequested {
                try store.requestJobCancellation(id: job.id)
                return try store.job(id: job.id)
            }
            switch try await execute(job: job, leaseToken: leaseToken, deliveryAdmitted: &deliveryAdmitted) {
            case .completed(let artifactID):
                try store.completeJob(id: job.id, leaseToken: leaseToken, resultArtifactID: artifactID)
                didFinishOwnedJob?(job.id, true)
            case .syncCompleted:
                // syncInbox already performed the successful token-fenced
                // terminal transition. A fence skip can never reach this case.
                didFinishOwnedJob?(job.id, true)
            case .credentialsPaused:
                didFinishOwnedJob?(job.id, false)
            case .yielded:
                break
            }
        } catch {
            let policyError = (error as? SmartInboxSchedulerControlError)?.underlying ?? error
            if policyError is SmartInboxPolicyError {
                _ = try store.acknowledgeSmartInboxBoundary(jobID: job.id, leaseToken: leaseToken,
                    priority: job.priority, allowedKinds: [.aiOperation, .searchRebuild])
                return try store.job(id: job.id)
            }
            if error is CancellationError {
                throw error
            }
            if let refreshed = try? store.job(id: job.id) {
                if refreshed.cancellationRequested, refreshed.state == .running {
                    try? store.acknowledgeJobCancellation(id: job.id, leaseToken: leaseToken)
                    return try? store.job(id: job.id)
                }
                if refreshed.state == .paused || refreshed.state == .cancelled {
                    return refreshed
                }
            }
            if job.kind == .approvedDelivery,
               Self.isDeliveryAmbiguous(error) {
                try? store.markDeliveryUncertain(
                    id: job.id,
                    leaseToken: leaseToken,
                    message: "SMTP delivery may have crossed the server acceptance boundary. Review before retrying."
                )
                if propagatingExecutionFailure {
                    throw error
                }
                return try store.job(id: job.id)
            }
            let disposition = LocalOperationFailurePolicy.disposition(
                error: error,
                job: job,
                now: failureDateProvider()
            )
            do {
                try store.failJob(
                    id: job.id, leaseToken: leaseToken, code: disposition.code,
                    message: disposition.message, retryAt: disposition.retryAt
                )
                if disposition.retryAt == nil { didFinishOwnedJob?(job.id, false) }
            } catch {
                // Preserve the original failure if persistence/ownership failed;
                // an unsuccessful write does not confer completion ownership.
            }
            if propagatingExecutionFailure {
                throw error
            }
            return try store.job(id: job.id)
        }
        return try store.job(id: job.id)
    }

    private func runtimeExecutionKey(for job: PlainpostDurableJob) -> RuntimeExecutionKey {
        guard job.kind == .inboxSync || job.kind == .historicalSync,
              let input = try? decode(PlainpostInboxSyncInput.self, from: job.payloadJSON) else {
            return .exclusive
        }
        return .syncAccount(input.accountID.rawValue)
    }

    public func enqueueScheduledSyncJobs(now: Date = Date(), interval _: TimeInterval = 60) throws {
        let accounts: [Account]
        if requireSelectedDirectClaimScope, let selectedDirectAccountID {
            guard let expectedDirectSourceGeneration else {
                throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
            }
            try requireJobDirectSource(
                accountID: selectedDirectAccountID,
                generation: expectedDirectSourceGeneration
            )
            accounts = store.accounts.filter { $0.id == selectedDirectAccountID }
        } else if requireSelectedDirectClaimScope {
            // Every account this device syncs (Direct, or a Node account in fallback), each at its own generation.
            accounts = store.directSyncAccounts.filter {
                (try? store.requireDirectSyncSource(accountID: $0.id)) != nil
            }
        } else {
            accounts = store.directSyncAccounts
        }
        for account in accounts {
            let preferences = try store.syncPreferences(accountID: account.id)
            guard preferences.realTimeMonitoringEnabled else { continue }
            let input = PlainpostInboxSyncInput(
                accountID: account.id, trigger: .schedule, scope: .incremental,
                expectedDirectSourceGeneration: try scopedGeneration(for: account.id)
            )
            _ = try store.enqueueCoalescedInboxSyncJob(input)
        }
        try store.pruneTerminalJobs(before: now.addingTimeInterval(-3_600))
    }

    public func enqueueRealtimeSyncIfNeeded(accountID: AccountID) throws {
        let generation = try scopedGeneration(for: accountID)
        try requireJobDirectSource(accountID: accountID, generation: generation)
        let input = PlainpostInboxSyncInput(
            accountID: accountID, trigger: .realTimeSignal, scope: .incremental,
            expectedDirectSourceGeneration: generation
        )
        _ = try store.enqueueCoalescedInboxSyncJob(input)
    }

    public func runUntilTerminal(jobID: String) async throws -> PlainpostDurableJob {
        try await runUntilTerminal(jobID: jobID, releaseLeaseOnCancellation: false)
    }

    /// Cancels interactive AI work (a question, translation, summary or draft) that no one is
    /// waiting for: unfinished and untouched for `idle`. Only the screen that asked runs such a
    /// job, so after the app was closed mid-answer it would otherwise stay queued for good.
    @discardableResult
    public static func cancelAbandonedInteractiveAIJobs(
        in store: SQLiteMailStore, idle: TimeInterval = 600, now: Date = Date()
    ) throws -> Int {
        var cancelled = 0
        for job in try store.jobs(limit: 1_000) where job.kind == .aiOperation
            && (job.state == .queued || job.state == .paused
                || (job.state == .running && (job.leaseExpiresAt ?? .distantPast) < now))
            && job.updatedAt < now.addingTimeInterval(-idle) {
            guard let input = try? JSONDecoder().decode(
                PlainpostAIOperationInput.self, from: Data(job.payloadJSON.utf8)
            ),
                  input.operation.serviceClass == .interactive else { continue }
            try store.requestJobCancellation(id: job.id)
            cancelled += 1
        }
        return cancelled
    }

    /// Runs only `jobID`. A person waiting on a question or translation must not first run
    /// an older job someone else queued and abandoned.
    public func runOwnJobUntilTerminal(jobID: String) async throws -> PlainpostDurableJob {
        try await runUntilTerminal(jobID: jobID, releaseLeaseOnCancellation: false, onlyOwnJob: true)
    }

    func runUntilTerminalReleasingLeaseOnCancellation(
        jobID: String,
        didFinishOwnedJob: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> PlainpostDurableJob {
        try await runUntilTerminal(jobID: jobID, releaseLeaseOnCancellation: true, didFinishOwnedJob: didFinishOwnedJob)
    }

    private func runUntilTerminal(
        jobID: String,
        releaseLeaseOnCancellation: Bool,
        didFinishOwnedJob: (@Sendable (String, Bool) -> Void)? = nil,
        onlyOwnJob: Bool = false
    ) async throws -> PlainpostDurableJob {
        while true {
            let current = try store.job(id: jobID)
            if current.state == .queued && requireSelectedDirectClaimScope {
                try requireQueuedSelectedDirectJobSource(current)
            }
            switch current.state {
            case .completed:
                return current
            case .failed, .cancelled, .deliveryUncertain:
                throw PlainpostError.validationFailed(current.errorMessage ?? "Local operation did not complete.")
            case .paused where current.pauseReason == Self.credentialsUnavailablePauseReason:
                throw PlainpostError.validationFailed(
                    "Mail credentials are unavailable. Unlock the Keychain and retry the sync."
                )
            case .queued, .running, .paused:
                do {
                    if try await processNextJob(
                        now: Date(),
                        propagatingExecutionFailure: true,
                        releaseLeaseOnCancellation: releaseLeaseOnCancellation,
                        didFinishOwnedJob: didFinishOwnedJob,
                        onlyJobID: onlyOwnJob ? jobID : nil
                    ) == nil {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let refreshed = try store.job(id: jobID)
                    switch refreshed.state {
                    case .queued:
                        let delay = max(0.05, min(1, refreshed.availableAt.timeIntervalSinceNow))
                        try await Task.sleep(for: .seconds(delay))
                    case .paused where refreshed.pauseReason == Self.credentialsUnavailablePauseReason:
                        throw PlainpostError.validationFailed(
                            "Mail credentials are unavailable. Unlock the Keychain and retry the sync."
                        )
                    case .running, .paused:
                        continue
                    case .completed:
                        return refreshed
                    case .failed, .cancelled, .deliveryUncertain:
                        throw error
                    }
                }
            }
        }
    }

    private func requireQueuedSelectedDirectJobSource(_ job: PlainpostDurableJob) throws {
        switch job.kind {
        case .inboxSync, .historicalSync:
            let input = try decode(PlainpostInboxSyncInput.self, from: job.payloadJSON)
            try requireJobDirectSource(
                accountID: input.accountID,
                generation: input.expectedDirectSourceGeneration
            )
        case .mailboxFlag:
            let input = try decode(PlainpostMailboxFlagInput.self, from: job.payloadJSON)
            guard let accountID = input.accountID else {
                throw NodeMailModeStoreError.generationConflict
            }
            try requireJobDirectSource(
                accountID: accountID,
                generation: input.expectedDirectSourceGeneration
            )
        case .mailboxArchive:
            let input = try decode(PlainpostMailboxArchiveInput.self, from: job.payloadJSON)
            try requireJobDirectSource(
                accountID: input.accountID,
                generation: input.expectedDirectSourceGeneration
            )
        case .aiOperation, .approvedDelivery, .denySend, .searchRebuild:
            break
        }
    }

    public func runUntilTerminalState(
        jobID: String,
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> PlainpostDurableJob {
        while true {
            try Task.checkCancellation()
            let current = try store.job(id: jobID)
            switch current.state {
            case .completed, .failed, .cancelled, .deliveryUncertain:
                return current
            case .queued, .running, .paused:
                do {
                    if try await processNextJob() == nil {
                        try await Task.sleep(for: pollInterval)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let refreshed = try store.job(id: jobID)
                    switch refreshed.state {
                    case .completed, .failed, .cancelled, .deliveryUncertain:
                        return refreshed
                    case .queued:
                        let delay = max(0.05, min(1, refreshed.availableAt.timeIntervalSinceNow))
                        try await Task.sleep(for: .seconds(delay))
                    case .running, .paused:
                        try await Task.sleep(for: pollInterval)
                    }
                }
            }
        }
    }

    private func execute(
        job: PlainpostDurableJob,
        leaseToken: String,
        deliveryAdmitted: inout Bool
    ) async throws -> JobExecutionOutcome {
        switch job.kind {
        case .inboxSync, .historicalSync:
            let input = try decode(PlainpostInboxSyncInput.self, from: job.payloadJSON)
            try requireJobDirectSource(
                accountID: input.accountID, generation: input.expectedDirectSourceGeneration
            )
            return try await syncInbox(input: input, jobID: job.id, leaseToken: leaseToken)
        case .aiOperation, .searchRebuild:
            let decodedInput = try decode(PlainpostAIOperationInput.self, from: job.payloadJSON)
            let input = decodedInput.operation == .recategorizeInbox
                ? decodedInput.resolvingSmartInboxClassifierIdentity(environment: environment)
                : decodedInput
            return try await runAI(input: input, job: job, leaseToken: leaseToken)
        case .approvedDelivery:
            if requireExplicitDirectSource {
                throw PlainpostError.permissionDenied("Direct delivery requires durable send intent.")
            }
            let input = try decode(PlainpostApprovalDecisionInput.self, from: job.payloadJSON)
            try await deliverApprovedSend(input: input, jobID: job.id, deliveryAdmitted: &deliveryAdmitted)
            return .completed(nil)
        case .denySend:
            let input = try decode(PlainpostApprovalDecisionInput.self, from: job.payloadJSON)
            try denySend(input: input)
            return .completed(nil)
        case .mailboxFlag:
            let input = try decode(PlainpostMailboxFlagInput.self, from: job.payloadJSON)
            guard let accountID = input.accountID else {
                throw PlainpostError.validationFailed("A mailbox flag requires an account.")
            }
            try requireJobDirectSource(
                accountID: accountID, generation: input.expectedDirectSourceGeneration
            )
            try await reconcileMailboxFlag(input, sourceJobID: job.id)
            return .completed(nil)
        case .mailboxArchive:
            let input = try decode(PlainpostMailboxArchiveInput.self, from: job.payloadJSON)
            try requireJobDirectSource(
                accountID: input.accountID, generation: input.expectedDirectSourceGeneration
            )
            try await reconcileMailboxArchive(input, sourceJobID: job.id)
            return .completed(nil)
        }
    }

    private func requireDirectSource(accountID: AccountID) throws {
        if requireExplicitDirectSource {
            try store.requireDirectSyncSource(accountID: accountID)
        }
    }

    /// The generation a scoped worker's sync job carries: the selected one, or (device-wide)
    /// the account's own current Direct generation. Unscoped workers carry none.
    private func scopedGeneration(for accountID: AccountID) throws -> Int64? {
        guard requireSelectedDirectClaimScope else { return nil }
        if selectedDirectAccountID != nil { return expectedDirectSourceGeneration }
        try store.requireDirectSyncSource(accountID: accountID)
        return try store.mailSource(accountID: accountID).generation
    }

    private func requireJobDirectSource(accountID: AccountID, generation: Int64?) throws {
        if requireSelectedDirectClaimScope, let selectedDirectAccountID {
            guard accountID == selectedDirectAccountID,
                  let generation,
                  generation == expectedDirectSourceGeneration else {
                throw NodeMailModeStoreError.generationConflict
            }
        } else if requireSelectedDirectClaimScope {
            // Device-wide: every job names its own account's generation.
            guard generation != nil else { throw NodeMailModeStoreError.generationConflict }
        }
        if let generation {
            try requireUnchangedDirectSource(accountID: accountID, generation: generation)
        } else {
            try requireDirectSource(accountID: accountID)
        }
    }

    private func directSourceGeneration(accountID: AccountID) throws -> Int64? {
        guard requireExplicitDirectSource else { return nil }
        try store.requireDirectSyncSource(accountID: accountID)
        return try store.mailSource(accountID: accountID).generation
    }

    private func requireUnchangedDirectSource(accountID: AccountID, generation: Int64?) throws {
        guard let generation else { return }
        try store.requireDirectSyncSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
    }

    private func reconcileMailboxFlag(
        _ input: PlainpostMailboxFlagInput,
        sourceJobID: String
    ) async throws {
        let desiredSeenAtStart = try store.desiredSeenState(messageID: input.messageID)
        if let desiredSeenAtStart, desiredSeenAtStart != input.desiredSeen {
            return
        }
        let beganWithDurableIntent = desiredSeenAtStart != nil
        guard let accountID = input.accountID,
              let mailboxPath = input.mailboxPath,
              let uidValidity = input.uidValidity,
              let uid = input.uid else {
            throw PlainpostError.validationFailed("A mailbox flag requires an exact mailbox membership.")
        }
        let membership = try store.membership(
            for: input.messageID,
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid
        )
        guard let account = store.accounts.first(where: { $0.id == membership.accountID }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        if let nodeModeMailboxHandoff, try !store.mailSource(accountID: account.id).runsDirectSync {
            _ = try await nodeModeMailboxHandoff(.flag(jobID: sourceJobID, messageID: input.messageID, seen: input.desiredSeen))
            return
        }
        try refuseNodeModeAccount(account.id)
        try await withAuthenticatedIMAPClient(
            for: account, expectedSourceGeneration: input.expectedDirectSourceGeneration
        ) { client in
            let selection = try await client.selectMailbox(membership.mailboxPath)
            guard let selectedUIDValidity = IMAPSyncService.uidValidity(from: selection),
                  selectedUIDValidity == membership.uidValidity else {
                throw PlainpostError.validationFailed(
                    "Mailbox state changed. Sync is required before updating message status."
                )
            }
            try self.requireJobDirectSource(
                accountID: account.id, generation: input.expectedDirectSourceGeneration
            )
            if input.desiredSeen {
                try await client.markRead(uid: membership.uid)
            } else {
                try await client.markUnread(uid: membership.uid)
            }
            try await self.enqueueLatestMailboxFlagIfSuperseded(
                completedInput: input,
                sourceJobID: sourceJobID,
                beganWithDurableIntent: beganWithDurableIntent
            )
        }
    }

    private func reconcileMailboxArchive(_ input: PlainpostMailboxArchiveInput, sourceJobID: String) async throws {
        guard let account = store.accounts.first(where: { $0.id == input.accountID }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        if let nodeModeMailboxHandoff, try !store.mailSource(accountID: account.id).runsDirectSync {
            if try await nodeModeMailboxHandoff(.archive(
                jobID: sourceJobID, messageID: input.messageID, destinationMailboxPath: input.destinationMailboxPath)) {
                try store.completeMailboxArchive(input)
            }
            return
        }
        try refuseNodeModeAccount(account.id)
        try requireJobDirectSource(
            accountID: account.id, generation: input.expectedDirectSourceGeneration
        )
        let accountMailboxes = store.mailboxes.filter { $0.accountID == account.id }
        if ArchiveMailbox.isAlreadyArchived(
            sourceMailbox: input.sourceMailboxPath, requested: input.destinationMailboxPath,
            cachedMailboxes: accountMailboxes
        ) {
            // Already in the Archive: no server command and no store change.
            return
        }
        let destination: String? = try await withAuthenticatedIMAPClient(
            for: account, expectedSourceGeneration: input.expectedDirectSourceGeneration
        ) { client -> String? in
            let selection = try await client.selectMailbox(input.sourceMailboxPath)
            guard let selectedUIDValidity = IMAPSyncService.uidValidity(from: selection),
                  selectedUIDValidity == input.uidValidity else {
                throw PlainpostError.validationFailed(
                    "Mailbox state changed. Sync is required before archiving the message."
                )
            }
            // The account's own Archive (Gmail: All Mail), also for a job queued
            // with the old default; none refuses before any UID command.
            let destination = try await ArchiveMailbox.resolve(
                requested: input.destinationMailboxPath, client: client, cachedMailboxes: accountMailboxes
            )
            // Already in the Archive: no move into its own mailbox.
            guard destination.caseInsensitiveCompare(input.sourceMailboxPath) != .orderedSame else { return nil }
            try self.requireJobDirectSource(
                accountID: account.id, generation: input.expectedDirectSourceGeneration
            )
            _ = try await client.move(uid: input.uid, to: destination)
            return destination
        }
        // Nothing moved, so the source copy stays in the store too.
        guard let destination else { return }
        try store.completeMailboxArchive(PlainpostMailboxArchiveInput(
            messageID: input.messageID, accountID: input.accountID,
            sourceMailboxPath: input.sourceMailboxPath, destinationMailboxPath: destination,
            uidValidity: input.uidValidity, uid: input.uid,
            expectedDirectSourceGeneration: input.expectedDirectSourceGeneration
        ))
    }

    /// Direct provider writes are only for accounts that run direct sync; the
    /// mutation router sends a Node-mode account's changes to the Node instead.
    /// A source read error propagates as itself, so the job retries rather
    /// than failing permanently with the (permanent) Node-mode refusal.
    private func refuseNodeModeAccount(_ accountID: AccountID) throws {
        guard try store.mailSource(accountID: accountID).runsDirectSync else {
            throw PlainpostError.validationFailed(Self.nodeModeRefusal)
        }
    }

    private func enqueueLatestMailboxFlagIfSuperseded(
        completedInput: PlainpostMailboxFlagInput,
        sourceJobID: String,
        beganWithDurableIntent: Bool
    ) async throws {
        guard try store.enqueueMailboxFlagRecoveryIfSuperseded(
            completedInput: completedInput,
            sourceJobID: sourceJobID,
            beganWithDurableIntent: beganWithDurableIntent
        ) != nil else {
            return
        }
        try? await workerSignal.signalWork()
    }

    private func syncInbox(
        input: PlainpostInboxSyncInput,
        jobID: String,
        leaseToken: String
    ) async throws -> JobExecutionOutcome {
        guard let account = store.accounts.first(where: { $0.id == input.accountID }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        // A Node-mode account's mail arrives through the Node mirror. A sync
        // queued before the handover completes without touching credentials.
        // An unreadable source throws instead, so the job fails and retries
        // rather than being recorded as skipped.
        guard try store.mailSource(accountID: account.id).runsDirectSync else {
            try? store.updateJobProgress(
                id: jobID,
                leaseToken: leaseToken,
                progress: .init(phase: Self.nodeModeSkippedPhase)
            )
            let artifactID = "sync_\(jobID)"
            try saveArtifact(
                id: artifactID,
                kind: "inbox-sync",
                recordID: account.id.rawValue,
                jobID: jobID,
                value: PlainpostInboxSyncResult(
                    accountID: account.id, syncedMessageCount: 0,
                    source: Self.syncSource(for: input.scope), jobID: jobID)
            )
            return .completed(artifactID)
        }
        let sourceGeneration: Int64?
        if let expected = input.expectedDirectSourceGeneration {
            sourceGeneration = expected
        } else {
            sourceGeneration = try directSourceGeneration(accountID: account.id)
        }
        try requireJobDirectSource(
            accountID: account.id, generation: input.expectedDirectSourceGeneration
        )
        // Resolved once up front so a locked vault, a missing credential or a
        // Google grant awaiting reauthorization pauses the job instead of
        // failing it; the resolver is consulted again for the IMAP login.
        do {
            _ = try await credentialResolver.imapAuthentication(for: account)
        } catch CredentialVaultError.locked,
                MailCredentialError.unavailable,
                MailCredentialError.reauthorizationRequired {
            try pauseForUnavailableCredentials(jobID: jobID, leaseToken: leaseToken)
            return .credentialsPaused
        }
        while true {
            let observedReconciliationGeneration = try store.inboxSyncReconciliationGeneration(
                id: jobID,
                leaseToken: leaseToken
            )
            let persistedScope = try store.syncExecutionScope(jobID: jobID)
            let fallbackPreferences = try store.syncPreferences(accountID: account.id)
            let fallbackMailboxPreferences = try store.mailboxSyncPreferences(accountID: account.id)
            let fallbackSelectedPaths = MailboxSyncSelection.selectedMailboxPaths(
                availableMailboxes: store.mailboxes
                    .filter { $0.accountID == account.id },
                preferences: fallbackMailboxPreferences
            )
            // The Mac service is the Direct Mode producer.  Once its
            // authenticated assignment has been installed, an incremental
            // Inbox sync may freeze fresh publications locally; an absent or
            // stale configuration remains explicitly ineligible.
            let notificationConfiguration = try? store.notificationProducerConfiguration(
                accountID: account.id, mailboxPath: "INBOX"
            )
            let options = IMAPSyncOptions(
                mailboxPaths: persistedScope?.mailboxPaths ?? fallbackSelectedPaths,
                recentMessageLimit: persistedScope?.recentMessageLimit ?? fallbackPreferences.recentMessageLimit,
                downloadCompleteHistory: persistedScope?.downloadCompleteHistory
                    ?? (input.scope == .completeHistory || fallbackPreferences.downloadCompleteHistory),
                incrementalOnly: persistedScope?.incrementalOnly
                    ?? (input.scope == .incremental && !fallbackPreferences.downloadCompleteHistory),
                reconcileRemoteState: Self.shouldReconcileRemoteState(for: input.trigger)
                    || observedReconciliationGeneration > 0,
                notificationEligible: notificationConfiguration != nil,
                notificationConfiguration: notificationConfiguration
            )
            let existingInboxMessageIDs = Set(try store.mailboxListMessageIDs(
                accountID: account.id,
                inMailboxPath: "INBOX"
            ))
            let result: IMAPSyncResult
            do {
                // Authentication is the first network step of a sync, so an
                // OAuth rejection retries the whole pass on a fresh connection
                // before any mailbox state is read or written.
                result = try await credentialResolver.withIMAPAuthentication(for: account) { [store] authentication in
                    try self.requireUnchangedDirectSource(
                        accountID: account.id, generation: sourceGeneration
                    )
                    let client = self.inboxSyncClientFactory(account.imapHost, account.imapPort)
                    return try await IMAPSyncService(client: client, cache: store).syncInbox(
                        credentials: IMAPAccountCredentials(
                            accountID: account.id,
                            email: account.email,
                            username: account.username,
                            authentication: authentication
                        ),
                        options: options,
                        foregroundCheckpoint: IMAPForegroundRefreshCheckpointHooks(
                            capture: {
                                try store.captureForegroundInboxRefresh(jobID: jobID, leaseToken: leaseToken)
                            },
                            publish: { demand, path, validity, targets, newlyDiscovered in
                                try store.publishForegroundInboxRefresh(
                                    jobID: jobID, leaseToken: leaseToken, demand: demand,
                                    mailboxPath: path, uidValidity: validity,
                                    targetUIDs: targets, newlyDiscoveredCount: newlyDiscovered
                                )
                            }
                        )
                    ) { progress in
                        let operationProgress: PlainpostOperationProgress
                        switch progress {
                        case .connecting:
                            operationProgress = .init(phase: "connecting")
                        case .discoveringMailboxes:
                            operationProgress = .init(phase: "mailbox-discovery")
                        case .discoveringMessages:
                            operationProgress = .init(phase: "message-discovery")
                        case .downloading(let completed, let total):
                            operationProgress = .init(current: completed, total: total, phase: "downloading")
                        case .syncingMailbox(let path, let phase, let completed, let total):
                            operationProgress = .init(current: completed, total: total, phase: phase, label: path)
                        }
                        try? store.updateJobProgress(id: jobID, leaseToken: leaseToken, progress: operationProgress)
                    }
                }
            } catch CredentialVaultError.locked,
                    MailCredentialError.unavailable,
                    MailCredentialError.reauthorizationRequired {
                try pauseForUnavailableCredentials(jobID: jobID, leaseToken: leaseToken)
                return .credentialsPaused
            }
            let newMessageIDs = try store.mailboxListMessageIDs(
                accountID: account.id,
                inMailboxPath: "INBOX"
            )
            .filter { !existingInboxMessageIDs.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
            var ruleResult: MailRuleProcessingResult
            do {
                ruleResult = try MailRuleProcessor(
                    store: store,
                    workerSignal: workerSignal,
                    expectedDirectSourceGeneration: sourceGeneration
                ).processNewMessages(newMessageIDs, accountID: account.id)
                try store.resolveMacNewMailEvents(
                    accountID: account.id,
                    messageIDs: newMessageIDs,
                    suppressedIDs: ruleResult.suppressedNotificationMessageIDs,
                    now: failureDateProvider()
                )
            } catch {
                for messageID in newMessageIDs {
                    try? store.recordMailRuleEvaluationFailure(messageID: messageID, error: error)
                }
                try? store.failMacNewMailRuleEvaluation(
                    accountID: account.id,
                    messageIDs: newMessageIDs,
                    now: failureDateProvider()
                )
                ruleResult = MailRuleProcessingResult(
                    newMessageIDs: newMessageIDs,
                    suppressedNotificationMessageIDs: Set(newMessageIDs)
                )
            }
            let artifactID = "sync_\(jobID)"
            let payload = PlainpostInboxSyncResult(
                accountID: account.id,
                syncedMessageCount: result.syncedMessageCount,
                newlyDiscoveredMessageCount: result.newlyDiscoveredMessageCount,
                source: result.source,
                newMessageIDs: ruleResult.newMessageIDs,
                suppressedNotificationMessageIDs: ruleResult.suppressedNotificationMessageIDs
                    .sorted { $0.rawValue < $1.rawValue },
                jobID: jobID
            )
            try saveArtifact(
                id: artifactID,
                kind: "inbox-sync",
                recordID: account.id.rawValue,
                jobID: jobID,
                value: payload
            )
            let needsRerun = try store.completeInboxSyncPass(
                id: jobID,
                leaseToken: leaseToken,
                observedReconciliationGeneration: observedReconciliationGeneration,
                resultArtifactID: artifactID
            )
            if needsRerun {
                continue
            }
            return .syncCompleted
        }
    }

    private func pauseForUnavailableCredentials(jobID: String, leaseToken: String) throws {
        try store.pauseJob(
            id: jobID,
            leaseToken: leaseToken,
            reason: Self.credentialsUnavailablePauseReason,
            progress: .init(phase: "waiting-for-credentials", label: "Waiting for Mail Keychain"),
            restoreAttempt: true
        )
    }

    /// The source a pass of this scope would report, for a skipped pass.
    static func syncSource(for scope: PlainpostSyncScope) -> IMAPSyncSource {
        switch scope {
        case .incremental: .incremental
        case .completeHistory: .historicalBackfill
        case .recent: .recentImport
        }
    }

    static func shouldReconcileRemoteState(for trigger: PlainpostInboxSyncTrigger) -> Bool {
        trigger != .realTimeSignal
    }

    private func conversationKey(for input: PlainpostAIOperationInput) throws -> String {
        try Self.resolveConversationKey(
            for: input,
            messages: store.messages(accountID: input.accountID)
        )
    }

    static func resolveConversationKey(
        for input: PlainpostAIOperationInput,
        messages: [MessageSummary]
    ) throws -> String {
        switch input.conversationReferenceKind {
        case .thread:
            if input.recordID.hasPrefix("thr_uid_") {
                guard let message = messages.first(where: {
                    $0.threadID?.rawValue == input.recordID
                }) else {
                    throw PlainpostError.notFound("Thread not found.")
                }
                return MailThreading.conversationKey(for: message)
            }
            return input.recordID
        case .message:
            guard let message = messages.first(where: { $0.id.rawValue == input.recordID }) else {
                throw PlainpostError.notFound("Message not found.")
            }
            return MailThreading.conversationKey(for: message)
        case nil:
            throw PlainpostError.validationFailed(
                "An AI conversation operation requires an explicit reference kind."
            )
        }
    }

    private func runAI(
        input: PlainpostAIOperationInput,
        job: PlainpostDurableJob,
        leaseToken: String
    ) async throws -> JobExecutionOutcome {
        let jobID = job.id
        updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "preparing", label: input.operation.activityTitle)
        let translationTarget: (identifier: String, name: String)?
        if input.operation == .translateMessage {
            guard let identifier = input.targetLanguageIdentifier,
                  !identifier.isEmpty,
                  let name = input.targetLanguageName,
                  !name.isEmpty else {
                throw PlainpostError.validationFailed("Translation target language is required.")
            }
            translationTarget = (identifier, name)
        } else {
            translationTarget = nil
        }
        let smartInboxClassifierIdentity = input.operation == .recategorizeInbox
            ? input.resolvedSmartInboxClassifierIdentity
            : nil
        if input.operation == .recategorizeInbox {
            try store.requireSmartInboxDirectSource(input)
        }
        let provider = try resolveAIProvider(
            input,
            smartInboxClassifierIdentity: smartInboxClassifierIdentity
        )
        guard provider.isPermittedMailProcessor else {
            throw AIProviderError.remoteEndpointDisallowed
        }
        let actor = Actor(
            id: "local-operation-agent",
            kind: .system,
            displayName: "Local Operation Agent",
            permissions: .guiUser
        )
        let service = LocalAIService(
            provider: provider,
            store: store,
            selectedMessages: input.accountID.map { store.messages(accountID: $0) }
        )
        let payload: PlainpostLocalAIArtifactPayload

        switch input.operation {
        case .summarizeThread:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "generating", label: "Summarizing thread")
            let conversationKey = try conversationKey(for: input)
            let value = try await service.summarizeThread(
                SummarizeThreadInput(threadID: ThreadID(conversationKey), style: .actionPoints), actor: actor
            )
            payload = .init(text: value.summary, items: value.actionItems.map(\.text), modelID: value.modelID,
                            localOnly: value.localOnly, resultRecordID: input.recordID)
        case .summarizeMessage:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "generating", label: "Summarizing message")
            let value = try await service.summarizeMessage(
                SummarizeMessageInput(messageID: MessageID(input.recordID), style: .short), actor: actor
            )
            payload = .init(text: value.summary, modelID: value.modelID, localOnly: value.localOnly,
                            resultRecordID: value.messageID.rawValue)
        case .translateMessage:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "generating", label: "Translating message")
            guard let translationTarget else {
                throw PlainpostError.validationFailed("Translation target language is required.")
            }
            let value = try await LocalMailTranslationService(provider: provider, store: store)
                .translateMessage(
                    TranslateMessageInput(
                        messageID: MessageID(input.recordID),
                        targetLanguageID: translationTarget.identifier,
                        targetLanguageName: translationTarget.name
                    ),
                    actor: actor,
                    expectedDirectSourceGeneration: input.expectedDirectSourceGeneration
                )
            payload = .init(
                modelID: value.modelID,
                localOnly: provider.capabilities.runsLocally,
                resultRecordID: value.messageID.rawValue,
                translatedBodyKind: value.renderedBody.kind.rawValue,
                translatedBody: value.renderedBody.safeHTML ?? value.renderedBody.safeText,
                sourceFingerprint: value.sourceFingerprint
            )
        case .answerThreadQuestion:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "generating", label: "Answering thread question")
            guard let question = input.question else {
                throw PlainpostError.validationFailed("Question is required.")
            }
            let conversationKey = try conversationKey(for: input)
            let value = try await service.answerThreadQuestion(
                AskThreadQuestionInput(
                    threadID: ThreadID(conversationKey),
                    question: question,
                    priorTurns: input.conversation.map {
                        ThreadQuestionTurn(question: $0.question, answer: $0.answer)
                    }
                ),
                actor: actor
            )
            payload = .init(text: value.answer, modelID: value.modelID, localOnly: value.localOnly,
                            resultRecordID: input.recordID)
        case .answerMailboxQuestion:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "searching", label: "Searching mail")
            guard let question = input.question else {
                throw PlainpostError.validationFailed("Question is required.")
            }
            let value = try await AskMailAnswerService(provider: provider, store: store).answer(
                AskMailboxQuestionInput(
                    question: question,
                    scope: input.retrievalScope ?? .allMail,
                    activeConversationKey: input.activeConversationKey,
                    accountID: input.accountID,
                    priorTurns: input.conversation.map {
                        MailboxConversationTurn(question: $0.question, answer: $0.answer)
                    },
                    filterOverride: input.askMailFilterOverride
                ),
                actor: actor
            )
            payload = .init(
                text: value.answer,
                modelID: value.modelID,
                localOnly: value.localOnly,
                sources: value.sources,
                insufficientEvidence: value.insufficientEvidence,
                retrievalMode: value.retrievalMode.rawValue,
                askMailAnswer: value.askMailAnswer
            )
        case .draftReply:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "generating", label: "Drafting reply")
            let replyInput: DraftReplyInput
            guard let accountID = input.accountID else {
                throw PlainpostError.validationFailed("A reply draft requires an account context.")
            }
            let tone = input.draftTone.flatMap(DraftTone.init(rawValue:)) ?? .neutral
            switch input.conversationReferenceKind {
            case .thread:
                replyInput = DraftReplyInput(
                    threadID: ThreadID(input.recordID),
                    outputDraftID: DraftID("drf_ai_\(job.id)"),
                    tone: tone,
                    instructions: input.question ?? "",
                    replyAll: false
                )
            case .message:
                let messageID = MessageID(input.recordID)
                let validatedAccountID = try store.operationAccountID(
                    forMessageID: messageID,
                    explicitAccountID: accountID
                )
                replyInput = DraftReplyInput(
                    messageID: messageID,
                    accountID: validatedAccountID,
                    outputDraftID: DraftID("drf_ai_\(job.id)"),
                    tone: tone,
                    instructions: input.question ?? "",
                    replyAll: false
                )
            case nil:
                throw PlainpostError.validationFailed("A reply draft requires an explicit conversation reference kind.")
            }
            let value = try await service.draftReply(
                replyInput,
                actor: actor,
                expectedDirectSourceGeneration: input.expectedDirectSourceGeneration
            )
            payload = .init(modelID: provider.id, localOnly: provider.capabilities.runsLocally,
                            resultRecordID: value.id.rawValue)
        case .rewriteDraft:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "generating", label: "Rewriting draft")
            let value = try await service.rewriteDraft(
                RewriteDraftInput(draftID: DraftID(input.recordID), mode: .makeClearer), actor: actor
            )
            payload = .init(text: value.body, modelID: value.modelID, localOnly: value.localOnly,
                            resultRecordID: value.draftID.rawValue)
        case .classifyMessage:
            updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "classifying", label: "Classifying message")
            let value = try await service.classifyMessage(
                ClassifyMessageInput(messageID: MessageID(input.recordID)), actor: actor
            )
            payload = .init(text: value.reason, localOnly: value.localOnly,
                            resultRecordID: value.messageID.rawValue, category: value.category.rawValue,
                            confidence: value.confidence)
        case .recategorizeInbox:
            return try await runSmartInboxRecategorization(
                input: input,
                job: job,
                leaseToken: leaseToken,
                provider: provider,
                actor: actor
            )
        case .rebuildIndex:
            if provider.capabilities.supportsEmbeddings {
                let indexedCount = try await DurableMailEmbeddingIndexer(provider: provider, store: store)
                    .rebuild { [store] current, total in
                    try? store.updateJobProgress(
                        id: jobID,
                        leaseToken: leaseToken,
                        progress: .init(current: current, total: total, phase: "indexing", label: "Semantic index")
                    )
                }
                payload = .init(
                    modelID: input.diagnosticsModelID,
                    localOnly: provider.capabilities.runsLocally,
                    resultRecordID: input.recordID,
                    indexedMessageCount: indexedCount
                )
            } else {
                let value = try await LocalAIIndexService(provider: provider, store: store)
                    .rebuild(accountID: input.recordID.isEmpty ? nil : input.recordID, actor: actor)
                payload = .init(modelID: value.modelID, localOnly: value.localOnly,
                                resultRecordID: input.recordID, indexedMessageCount: value.indexedMessageCount)
            }
        }

        updateAIProgress(jobID: jobID, leaseToken: leaseToken, phase: "finalizing", label: input.operation.activityTitle)
        let artifactID = "ai_\(UUID().uuidString.lowercased())"
        try saveAIArtifact(
            id: artifactID,
            kind: input.operation.rawValue,
            recordID: input.recordID,
            jobID: jobID,
            value: payload
        )
        return .completed(artifactID)
    }

    func resolveAIProvider(
        _ input: PlainpostAIOperationInput,
        smartInboxClassifierIdentity: SmartInboxClassifierIdentity? = nil
    ) throws -> any AIProvider {
        let resolve = {
            try self.aiProviderResolver?(input) ?? LocalAIProviderResolver.resolve(
                LocalAIProviderSelection(
                    providerID: input.providerID,
                    ollamaBaseURL: self.environment["PLAINPOST_OLLAMA_URL"].flatMap(URL.init(string:)),
                    ollamaChatModelID: smartInboxClassifierIdentity?.modelID
                        ?? self.environment["PLAINPOST_OLLAMA_CHAT_MODEL"]
                        ?? "qwen3:8b",
                    ollamaEmbeddingModelID: self.environment["PLAINPOST_OLLAMA_EMBEDDING_MODEL"]
                        ?? "mxbai-embed-large"
                )
            )
        }
        guard let smartInboxClassifierIdentity else {
            return try resolve()
        }
        return try smartInboxProviderCache.resolve(
            discriminator: smartInboxClassifierIdentity.discriminator,
            using: resolve
        )
    }

    private func runSmartInboxRecategorization(
        input: PlainpostAIOperationInput,
        job: PlainpostDurableJob,
        leaseToken: String,
        provider: any AIProvider,
        actor: Actor
    ) async throws -> JobExecutionOutcome {
        try store.requireSmartInboxDirectSource(input)
        guard provider.isPermittedMailProcessor else {
            throw AIProviderError.unavailable
        }
        let classifierIdentity = input.resolvedSmartInboxClassifierIdentity
        let classifierModelID = classifierIdentity.modelID
        let classifierDiscriminator = classifierIdentity.discriminator
        let runRequest = input.smartInboxRunRequest
        let catalog = try store.smartInboxLabelCatalogSnapshot(jobID: job.id)
            ?? store.smartInboxLabelCatalogSnapshot()
        let classificationInputs = try store.smartInboxClassificationInputs(
            scope: runRequest.scope
        ).sorted { $0.message.id.rawValue < $1.message.id.rawValue }
        let inputsByID = Dictionary(
            uniqueKeysWithValues: classificationInputs.map { ($0.message.id, $0) }
        )
        let workInputs = runRequest.mode == .incremental
            ? try store.eligibleIncrementalSmartInboxInputs(
                classificationInputs,
                classifierDiscriminator: classifierDiscriminator,
                catalogFingerprint: catalog.fingerprint
            )
            : classificationInputs
        let seeds = workInputs.enumerated().map { index, classificationInput in
            PlainpostSmartInboxWorkSeed(
                ordinal: index,
                messageID: classificationInput.message.id.rawValue,
                sourceFingerprint: SmartInboxClassificationFingerprint.message(
                    classificationInput,
                    classifierDiscriminator: classifierDiscriminator
                )
            )
        }
        try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: seeds,
            catalogSnapshot: catalog
        )
        try store.clearSmartInboxPreemptionProgress(id: job.id, leaseToken: leaseToken)

        let profile = try store.smartInboxBatchProfile(
            providerID: classifierIdentity.providerID,
            modelID: classifierModelID,
            classifierDiscriminator: classifierDiscriminator
        )
        let limits = profile.map {
            SmartInboxBatchLimits(
                maxMessages: $0.maxMessageCount,
                maxPromptCharacters: $0.maxPromptCharacters
            )
        } ?? SmartInboxBatchLimits(
            maxMessages: 1,
            maxPromptCharacters: min(
                6_000,
                SmartInboxPromptBudget.characters(
                    maxContextTokens: provider.capabilities.maxContextTokens
                )
            )
        )
        var failureDiagnosticCounts: [String: Int] = [:]
        while true {
            try Task.checkCancellation()
            if try yieldSmartInboxIfNeeded(job: job, leaseToken: leaseToken, actor: actor) {
                return .yielded
            }
            let claimedItems = try store.nextSmartInboxWorkItems(
                jobID: job.id,
                leaseToken: leaseToken,
                limit: limits.maxMessages
            )
            guard !claimedItems.isEmpty else { break }

            var runnableItems: [PlainpostSmartInboxWorkItem] = []
            runnableItems.reserveCapacity(claimedItems.count)
            for item in claimedItems {
                let classificationInput = inputsByID[MessageID(item.messageID)]
                let isCurrent = classificationInput.map {
                    SmartInboxClassificationFingerprint.message(
                        $0,
                        classifierDiscriminator: classifierDiscriminator
                    ) == item.sourceFingerprint
                } ?? false
                guard isCurrent else {
                    _ = try store.recordSmartInboxWorkItem(
                        jobID: job.id,
                        leaseToken: leaseToken,
                        ordinal: item.ordinal,
                        state: .skipped,
                        classifierDiscriminator: classifierDiscriminator
                    )
                    continue
                }
                runnableItems.append(item)
            }
            guard !runnableItems.isEmpty else { continue }

            let report: SmartInboxBatchRunReport
            do {
                report = try await SmartInboxBatchRunner().run(
                    items: runnableItems,
                    inputsByID: inputsByID,
                    catalog: catalog,
                    limits: limits,
                    classify: { [self] request in
                        try store.requireSmartInboxDirectSource(input)
                        return try await classifySmartInboxBatchPreemptibly(
                            request: request,
                            job: job,
                            leaseToken: leaseToken,
                            actor: actor,
                            provider: provider
                        )
                    },
                    persist: { [store] item, classification in
                        _ = try store.recordSmartInboxClassification(
                            jobID: job.id,
                            leaseToken: leaseToken,
                            ordinal: item.ordinal,
                            classification: classification,
                            providerID: classifierIdentity.providerID,
                            modelID: classifierModelID,
                            classifierDiscriminator: classifierDiscriminator,
                            actor: actor
                        )
                    },
                    shouldYield: { [self] in
                        do {
                            return try self.yieldSmartInboxIfNeeded(
                                job: job,
                                leaseToken: leaseToken,
                                actor: actor
                            )
                        } catch {
                            throw SmartInboxSchedulerControlError(error)
                        }
                    }
                )
            } catch SmartInboxBatchRunnerError.yieldRequested {
                return .yielded
            }

            for item in report.terminalFailures {
                let diagnosticCodes = report.terminalFailureDiagnostics[item.messageID]
                    ?? ["validation.invalid_response"]
                for code in diagnosticCodes {
                    failureDiagnosticCounts[code, default: 0] += 1
                }
                _ = try store.recordSmartInboxWorkItem(
                    jobID: job.id,
                    leaseToken: leaseToken,
                    ordinal: item.ordinal,
                    state: .failed,
                    classifierDiscriminator: classifierDiscriminator,
                    diagnosticCodes: diagnosticCodes,
                    errorMessage: "Smart Inbox classification remained invalid after bounded recovery."
                )
            }
        }

        try Task.checkCancellation()
        if try yieldSmartInboxIfNeeded(job: job, leaseToken: leaseToken, actor: actor) {
            return .yielded
        }
        let summary = try store.applySmartInboxWork(jobID: job.id, leaseToken: leaseToken, actor: actor)
        let allFailuresAreNonRetryableProviderRejections = !failureDiagnosticCounts.isEmpty
            && failureDiagnosticCounts.keys.allSatisfy {
                $0 == "provider.guardrail_violation"
                    || $0 == "provider.unsupported_language_or_locale"
            }
        if summary.total > 0,
           summary.failed == summary.total,
           !allFailuresAreNonRetryableProviderRejections {
            throw AIProviderError.unavailable
        }
        let payload = PlainpostLocalAIArtifactPayload(
            modelID: classifierModelID,
            localOnly: provider.capabilities.runsLocally,
            categorizedMessageCount: summary.categorized,
            unchangedMessageCount: summary.unchanged,
            failedMessageCount: summary.failed,
            smartInboxFailureDiagnostics: failureDiagnosticCounts.isEmpty
                ? nil
                : failureDiagnosticCounts
                    .map { PlainpostSmartInboxFailureDiagnostic(code: $0.key, count: $0.value) }
                    .sorted { $0.code < $1.code }
        )
        try store.updateJobProgress(
            id: job.id,
            leaseToken: leaseToken,
            progress: .init(
                current: summary.processed,
                total: summary.total,
                phase: "finalizing",
                label: input.operation.activityTitle
            )
        )
        let artifactID = "ai_\(UUID().uuidString.lowercased())"
        try store.requireSmartInboxDirectSource(input)
        try saveAIArtifact(
            id: artifactID,
            kind: input.operation.rawValue,
            recordID: input.recordID,
            jobID: job.id,
            value: payload
        )
        return .completed(artifactID)
    }

    private func yieldSmartInboxIfNeeded(
        job: PlainpostDurableJob,
        leaseToken: String,
        actor: Actor
    ) throws -> Bool {
        switch try store.acknowledgeSmartInboxBoundary(
            jobID: job.id,
            leaseToken: leaseToken,
            priority: job.priority,
            allowedKinds: allowedJobKinds ?? [.aiOperation, .searchRebuild]
        ) {
        case .continueRunning:
            return false
        case .yielded, .leaseLost:
            return true
        }
    }

    private func smartInboxPreemptionWatcher(
        for job: PlainpostDurableJob,
        leaseToken: String
    ) -> SmartInboxPreemptionWatcher {
        SmartInboxPreemptionWatcher(
            store: store,
            jobID: job.id,
            leaseToken: leaseToken,
            priority: job.priority,
            allowedKinds: allowedJobKinds ?? [.aiOperation, .searchRebuild],
            pollInterval: smartInboxPreemptionPollInterval
        )
    }

    private func classifySmartInboxBatchPreemptibly(
        request: AIClassificationBatchRequest,
        job: PlainpostDurableJob,
        leaseToken: String,
        actor: Actor,
        provider: any AIProvider
    ) async throws -> AIClassificationBatchResponse {
        while true {
            let watcher = smartInboxPreemptionWatcher(for: job, leaseToken: leaseToken)
            let winner = try await withThrowingTaskGroup(of: SmartInboxClassificationRaceResult.self) { group in
                group.addTask {
                    do {
                        return .response(try await provider.classifyBatch(request))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return .failure(SmartInboxProviderFailure(error))
                    }
                }
                group.addTask {
                    do {
                        return .yield(try await watcher.waitForDirective())
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw SmartInboxSchedulerControlError(error)
                    }
                }
                guard let winner = try await group.next() else {
                    throw CancellationError()
                }
                if case .yield(let directive) = winner,
                   case .schedulerPause = directive {
                    do {
                        _ = try store.updateSmartInboxPreemptionProgress(
                            id: job.id,
                            leaseToken: leaseToken,
                            phase: "pausing"
                        )
                    } catch {
                        throw SmartInboxSchedulerControlError(error)
                    }
                }
                group.cancelAll()
                if case .yield = winner {
                    while !group.isEmpty { _ = try? await group.next() }
                }
                return winner
            }
            if case .failure = winner,
               let afterSmartInboxProviderFailureSelected {
                await afterSmartInboxProviderFailureSelected()
            }
            try Task.checkCancellation()
            switch winner {
            case .response(let response):
                let shouldYield: Bool
                do {
                    shouldYield = try yieldSmartInboxIfNeeded(job: job, leaseToken: leaseToken, actor: actor)
                } catch let error as SmartInboxBatchRunnerError {
                    throw error
                } catch {
                    throw SmartInboxSchedulerControlError(error)
                }
                try Task.checkCancellation()
                if shouldYield {
                    throw SmartInboxBatchRunnerError.yieldRequested
                }
                return response
            case .failure(let failure):
                let shouldYield: Bool
                do {
                    shouldYield = try yieldSmartInboxIfNeeded(job: job, leaseToken: leaseToken, actor: actor)
                } catch let error as SmartInboxBatchRunnerError {
                    throw error
                } catch {
                    throw SmartInboxSchedulerControlError(error)
                }
                try Task.checkCancellation()
                if shouldYield {
                    throw SmartInboxBatchRunnerError.yieldRequested
                }
                throw failure.underlying
            case .yield:
                do {
                    try Task.checkCancellation()
                    guard try store.renewSmartInboxLease(id: job.id, leaseToken: leaseToken) else {
                        throw SmartInboxBatchRunnerError.yieldRequested
                    }
                    let shouldYield = try yieldSmartInboxIfNeeded(job: job, leaseToken: leaseToken, actor: actor)
                    try Task.checkCancellation()
                    if shouldYield {
                        throw SmartInboxBatchRunnerError.yieldRequested
                    }
                    try store.clearSmartInboxPreemptionProgress(id: job.id, leaseToken: leaseToken)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as SmartInboxBatchRunnerError {
                    throw error
                } catch {
                    throw SmartInboxSchedulerControlError(error)
                }
            }
        }
    }

    private func updateAIProgress(
        jobID: String,
        leaseToken: String,
        phase: String,
        label: String
    ) {
        try? store.updateJobProgress(
            id: jobID,
            leaseToken: leaseToken,
            progress: .init(phase: phase, label: label)
        )
    }

    private func deliverApprovedSend(
        input: PlainpostApprovalDecisionInput,
        jobID: String,
        deliveryAdmitted: inout Bool
    ) async throws {
        let request = try store.sendRequest(id: input.requestID)
        let draft = try store.draft(id: request.draftID)
        let sourceGeneration = try directSourceGeneration(accountID: draft.accountID)
        let account = store.accounts.first(where: { $0.id == draft.accountID })
            ?? (requireExplicitDirectSource ? nil : store.accounts.first(where: { $0.email == draft.from }))
        guard let account else {
            throw PlainpostError.validationFailed("No configured account matches this draft.")
        }
        // A Node-backed account's approved send, or one whose intent is
        // already journaled (an earlier attempt or lease), goes through the
        // mutation router: to the Node, or directly in fallback. It never
        // also takes the direct SMTP path below. A source read error
        // propagates as itself, so the job retries.
        // This approval's intent (the claim records its operation ID).
        let journaled = try request.deliveryOperationID.map { try store.mailIntent(operationID: $0) != nil } ?? false
        let nodeBacked = try store.mailSource(accountID: account.id).kind == .nodeBacked
        if journaled || nodeBacked {
            guard let nodeModeApprovedSendHandoff else { throw NodeModeApprovedSendUnroutable() }
            deliveryAdmitted = true
            try await nodeModeApprovedSendHandoff(
                NodeModeApprovedSend(jobID: jobID, requestID: request.id, actorID: input.actorID)
            )
            return
        }
        let smtpAuthentication: MailAuthentication
        do {
            smtpAuthentication = try await credentialResolver.smtpAuthentication(for: account)
        } catch MailCredentialError.unavailable {
            throw PlainpostError.validationFailed("SMTP credentials are not available.")
        }
        let actor = Actor(id: input.actorID, kind: .user, displayName: "Authenticated Local User", permissions: .guiUser)
        // A refused OAuth token is refreshed and retried once, in place,
        // before `MAIL FROM`; nothing is retried after the envelope starts.
        let smtpClient = credentialResolver.tokenRefreshingSMTPClient(for: account) {
            MailTransportClientFactory.smtpClient(host: account.smtpHost, port: account.smtpPort)
        }
        let imapAuthentication: MailAuthentication?
        if MailProviderProfile.gmail.storesSentMessagesAutomatically(for: account) {
            imapAuthentication = nil
        } else {
            do {
                imapAuthentication = try await credentialResolver.imapAuthentication(for: account)
            } catch MailCredentialError.unavailable {
                imapAuthentication = nil
            }
        }
        try requireUnchangedDirectSource(accountID: draft.accountID, generation: sourceGeneration)
        let imapClient = imapAuthentication.map { _ in
            MailTransportClientFactory.imapClient(host: account.imapHost, port: account.imapPort)
        }
        let sentAppend = imapAuthentication.map {
            RemoteSentAppendConfiguration(username: account.username, authentication: $0, mailbox: account.sentMailbox)
        }
        deliveryAdmitted = true
        try await ApprovalSMTPService(store: store, smtpClient: smtpClient, sentAppendClient: imapClient)
            .approveAndSend(
                requestID: input.requestID,
                actor: actor,
                configuration: SMTPDeliveryConfiguration(username: account.username, authentication: smtpAuthentication),
                sentAppend: sentAppend
            )
    }

    /// Runs `body` on a freshly authenticated mailbox client and always
    /// disconnects it. Each authentication attempt uses a new connection, so
    /// the resolver's single OAuth retry happens before any mailbox work.
    @discardableResult
    private func withAuthenticatedIMAPClient<T: Sendable>(
        for account: Account,
        expectedSourceGeneration: Int64?,
        _ body: @escaping @Sendable (any IMAPClientProtocol) async throws -> T
    ) async throws -> T {
        let sourceGeneration: Int64?
        if let expectedSourceGeneration {
            sourceGeneration = expectedSourceGeneration
        } else {
            sourceGeneration = try directSourceGeneration(accountID: account.id)
        }
        try requireJobDirectSource(
            accountID: account.id, generation: expectedSourceGeneration
        )
        do {
            return try await credentialResolver.withIMAPAuthentication(for: account) { [mailboxFlagClientFactory] authentication in
                try self.requireUnchangedDirectSource(
                    accountID: account.id, generation: sourceGeneration
                )
                let client = mailboxFlagClientFactory(account)
                do {
                    try await client.authenticate(username: account.username, authentication: authentication)
                    let result = try await body(client)
                    await client.disconnect()
                    return result
                } catch {
                    await client.disconnect()
                    throw error
                }
            }
        } catch MailCredentialError.unavailable {
            throw PlainpostError.validationFailed("IMAP credentials are not available.")
        }
    }

    private func denySend(input: PlainpostApprovalDecisionInput) throws {
        _ = try store.updateSendRequest(
            id: input.requestID,
            status: .denied,
            approvedBy: input.actorID,
            approvedDraftHash: nil
        )
    }

    private func saveAIArtifact<T: Encodable>(
        id: String,
        kind: String,
        recordID: String,
        jobID: String,
        value: T
    ) throws {
        let data = try JSONEncoder().encode(value)
        try store.saveDurableOperationArtifact(
            DurableOperationArtifact(
                id: id,
                kind: kind,
                recordID: recordID,
                payloadJSON: String(decoding: data, as: UTF8.self)
            ),
            forJobID: jobID
        )
    }

    private func saveArtifact<T: Encodable>(
        id: String,
        kind: String,
        recordID: String,
        jobID: String,
        value: T
    ) throws {
        let data = try JSONEncoder().encode(value)
        try store.saveDurableOperationArtifact(
            DurableOperationArtifact(
                id: id,
                kind: kind,
                recordID: recordID,
                payloadJSON: String(decoding: data, as: UTF8.self)
            ),
            forJobID: jobID
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// The same rule `ApprovalSMTPService` applies to the send request.
    private static func isDeliveryAmbiguous(_ error: Error) -> Bool {
        SMTPDeliveryAmbiguity.isAmbiguous(error)
    }
}

private final class SmartInboxProviderResolutionCache: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var providers: [String: any AIProvider] = [:]
    private var resolvingDiscriminators = Set<String>()

    func resolve(
        discriminator: String,
        using resolver: () throws -> any AIProvider
    ) throws -> any AIProvider {
        try lock.withLock {
            if let provider = providers[discriminator] {
                return provider
            }
            guard resolvingDiscriminators.insert(discriminator).inserted else {
                throw PlainpostError.validationFailed(
                    "Smart Inbox provider resolution cannot re-enter."
                )
            }
            defer { resolvingDiscriminators.remove(discriminator) }
            let provider = try resolver()
            if provider.capabilities.runsLocally {
                providers[discriminator] = provider
            }
            return provider
        }
    }
}

private extension PlainpostAIOperationKind {
    var activityTitle: String {
        switch self {
        case .summarizeThread: "Summarizing thread"
        case .summarizeMessage: "Summarizing message"
        case .translateMessage: "Translating message"
        case .answerThreadQuestion: "Answering thread question"
        case .answerMailboxQuestion: "Searching and answering mail"
        case .draftReply: "Drafting reply"
        case .rewriteDraft: "Rewriting draft"
        case .classifyMessage: "Classifying message"
        case .recategorizeInbox: "Organizing Smart Inbox"
        case .rebuildIndex: "Rebuilding semantic index"
        }
    }
}

private enum RuntimeExecutionKey: Equatable, Sendable {
    case syncAccount(String)
    case exclusive
}

private actor RuntimeExecutionGate {
    private struct Waiter {
        let id: UUID
        let key: RuntimeExecutionKey
        let continuation: CheckedContinuation<Void, Error>
    }

    private var activeSyncAccounts = Set<String>()
    private var exclusiveIsActive = false
    private var waiters: [Waiter] = []

    func acquire(_ key: RuntimeExecutionKey) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if canAcquire(key), !hasWaitingExclusive {
                    markAcquired(key)
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, key: key, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Grant may win the actor race with cancellation. In that case this
        // acquire owns the permit and must return it before throwing.
        if Task.isCancelled {
            release(key)
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        resumeEligibleWaiters()
    }

    func release(_ key: RuntimeExecutionKey) {
        switch key {
        case .syncAccount(let accountID):
            activeSyncAccounts.remove(accountID)
        case .exclusive:
            exclusiveIsActive = false
        }
        resumeEligibleWaiters()
    }

    private var hasWaitingExclusive: Bool {
        waiters.contains { $0.key == .exclusive }
    }

    private func canAcquire(_ key: RuntimeExecutionKey) -> Bool {
        switch key {
        case .syncAccount(let accountID):
            return !exclusiveIsActive && !activeSyncAccounts.contains(accountID)
        case .exclusive:
            return !exclusiveIsActive && activeSyncAccounts.isEmpty
        }
    }

    private func markAcquired(_ key: RuntimeExecutionKey) {
        switch key {
        case .syncAccount(let accountID):
            activeSyncAccounts.insert(accountID)
        case .exclusive:
            exclusiveIsActive = true
        }
    }

    private func resumeEligibleWaiters() {
        while let waiter = waiters.first, canAcquire(waiter.key) {
            waiters.removeFirst()
            markAcquired(waiter.key)
            waiter.continuation.resume()
            if waiter.key == .exclusive { return }
        }
    }
}
