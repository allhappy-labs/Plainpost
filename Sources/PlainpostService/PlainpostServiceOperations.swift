import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostNodeMailMode
import PlainpostNotificationRuntime
import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
import os

private let serviceMailModeLogger = Logger(
    subsystem: "com.marynavdovenko.Plainpost", category: "service-mail-mode"
)

actor PlainpostServiceOperations {
    private let applicationSupportURL: URL
    private let store: SQLiteMailStore
    private let assembly: SQLiteCredentialVaultAssembly
    private let mailboxFlagScheduler: any MailboxFlagScheduling
    private let backgroundJobWakeScheduler:
        any BackgroundJobWakeScheduling
    private let dateProvider: @Sendable () -> Date
    private let credentialResolver: MailCredentialResolver
    private let accountRuntimeFactory: @Sendable () -> AccountSetupService
    private let operationRuntimeFactory: @Sendable () -> LocalOperationRuntime
    private let mailMonitorFactory:
        @Sendable (@escaping IMAPIdleSupervisor.Signal)
            -> any ServiceMailMonitoring
    private let notificationDrain: (any NotificationDraining)?
    private let installNotificationConfiguration: (@Sendable () async -> Void)?
    /// Routes Node-backed accounts' mail changes (journal, then Node or
    /// fallback direct). Direct accounts never reach it.
    private let mailIntentRouter: MailIntentRouter?
    /// Approved sends of Node-backed accounts go through the router.
    private let approvedSendHandoff: NodeModeApprovedSendHandoff?
    /// The draft mailbox a synchronous draft-sync request named, read by
    /// the router's direct route while that request runs.
    private var requestedDraftMailboxes: [DraftID: String] = [:]
    /// Direct deliveries the router's direct route completed, by draft.
    private var directDeliveries: [DraftID: LocalDraftDeliveryResult] = [:]
    /// What the router's direct route did for a delete, by message, read once
    /// by `routedMailAction` for its reply.
    private var directDeleteOutcomes: [MessageID: (outcome: DeleteOutcome, trashMailbox: String?)] = [:]
    /// Messages whose `routedMailAction` delete waits for the direct route's
    /// outcome; only those record one, and each wait clears its own entry, so
    /// a queued or replayed intent never leaves a stale outcome behind.
    private var awaitingDirectDeleteOutcomes: Set<MessageID> = []
    /// Tests only: how many direct delete outcomes are held.
    var heldDirectDeleteOutcomeCount: Int { directDeleteOutcomes.count }
    /// Drafts whose `routedDraftDelivery` waits for the direct route's
    /// result; only those record one (an approved send's handoff never reads it).
    private var awaitingDirectDeliveries: Set<DraftID> = []
    private var runtimeConstructionIsOpen = false
    private var vaultLockdownOwnsRuntimeTransition = false
    private var accountRuntime: AccountSetupService?
    private var operationRuntime: LocalOperationRuntime?
    private var backgroundOperationRuntime: LocalOperationRuntime?
    private var operationClient: LocalOperationClient?
    private var browserDeliveryRuntime: BrowserReplyDeliveryService?
    private var localDraftDeliveryRuntime: LocalDraftDeliveryService?
    private var mailMonitor: (any ServiceMailMonitoring)?
    private var backgroundJobDrainFlight: (
        id: UUID,
        task: Task<PlainpostBackgroundJobResult, Error>
    )?
    private var backgroundJobDrainRerunRequested = false
    private var activeOperationCount = 0
    private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var accountDeletionIsInProgress = false
    private var accountDeletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        applicationSupportURL: URL,
        store: SQLiteMailStore,
        assembly: SQLiteCredentialVaultAssembly,
        mailboxFlagScheduler: (any MailboxFlagScheduling)? = nil,
        backgroundJobWakeScheduler:
            (any BackgroundJobWakeScheduling)? = nil,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        accountRuntimeFactory: (@Sendable () -> AccountSetupService)? = nil,
        operationRuntimeFactory: (@Sendable () -> LocalOperationRuntime)? = nil,
        mailMonitorFactory: (
            @Sendable (@escaping IMAPIdleSupervisor.Signal)
                -> any ServiceMailMonitoring
        )? = nil,
        notificationDrain: (any NotificationDraining)? = nil,
        installNotificationConfiguration: (@Sendable () async -> Void)? = nil,
        credentialResolver: MailCredentialResolver? = nil,
        googleOAuthTokens: GoogleOAuthTokenClient? = nil,
        mailIntentRouter: MailIntentRouter? = nil
    ) {
        self.mailIntentRouter = mailIntentRouter
        let credentialResolver = credentialResolver
            ?? .withoutGoogleOAuth(store: store, credentials: assembly.vault)
        self.credentialResolver = credentialResolver
        self.applicationSupportURL = applicationSupportURL
        self.store = store
        self.assembly = assembly
        self.mailboxFlagScheduler =
            mailboxFlagScheduler ?? DurableMailboxFlagScheduler(store: store)
        self.backgroundJobWakeScheduler =
            backgroundJobWakeScheduler
                ?? TaskBackgroundJobWakeScheduler()
        self.dateProvider = dateProvider
        self.notificationDrain = notificationDrain
        self.installNotificationConfiguration = installNotificationConfiguration
        self.accountRuntimeFactory = accountRuntimeFactory ?? {
            AccountSetupService(
                store: store,
                credentials: assembly.vault,
                googleOAuthTokens: googleOAuthTokens,
                credentialResolver: credentialResolver
            )
        }
        let approvedSendHandoff = mailIntentRouter.map {
            ServiceApprovedSendRouting.handoff(router: $0, store: store)
        }
        self.approvedSendHandoff = approvedSendHandoff
        self.operationRuntimeFactory = operationRuntimeFactory ?? {
            LocalOperationRuntime(
                store: store,
                credentials: assembly.vault,
                credentialResolver: credentialResolver,
                nodeModeApprovedSendHandoff: approvedSendHandoff
            )
        }
        self.mailMonitorFactory = mailMonitorFactory ?? { signal in
            let idleSupervisor = IMAPIdleSupervisor(
                store: store,
                credentials: assembly.vault,
                credentialResolver: credentialResolver,
                signal: signal
            )
            return ServiceMailMonitor(
                store: store,
                idleSupervisor: idleSupervisor,
                signal: signal
            )
        }
    }

    func reopenRuntimeConstruction() async {
        vaultLockdownOwnsRuntimeTransition = false
        runtimeConstructionIsOpen = true
        if mailMonitor == nil {
            let monitor = mailMonitorFactory { [weak self] accountID in
                guard let self else { return }
                try await self.handleRealtimeMailSignal(
                    accountID: accountID
                )
            }
            mailMonitor = monitor
            await monitor.start()
        }
        try? await replaceBackgroundJobWakeFromPersistedQueue()
    }

    func beginVaultLockdown() async {
        vaultLockdownOwnsRuntimeTransition = true
        runtimeConstructionIsOpen = false
        // Access tokens are secrets derived from the vault; none outlive lockdown.
        await credentialResolver.forgetAllAccessTokens()
        let monitor = mailMonitor
        mailMonitor = nil
        await monitor?.stop()
        if accountDeletionIsInProgress {
            await withCheckedContinuation {
                accountDeletionWaiters.append($0)
            }
        }
        if activeOperationCount > 0 {
            await withCheckedContinuation {
                operationDrainWaiters.append($0)
            }
        }
        await backgroundJobWakeScheduler.replaceWake(
            at: nil,
            action: {}
        )
        accountRuntime = nil
        operationRuntime = nil
        backgroundOperationRuntime = nil
        operationClient = nil
        browserDeliveryRuntime = nil
        localDraftDeliveryRuntime = nil
    }

    /// True while the service runtime is open: the vault is unlocked and no
    /// lockdown is in progress. The reachability supervisor dispatches mail
    /// intents only then, because a fallback dispatch with the vault locked
    /// would meet the direct paths' credential refusal and fail the intent.
    var runtimeIsOpen: Bool {
        runtimeConstructionIsOpen && !vaultLockdownOwnsRuntimeTransition
    }

    var hasBackgroundOperationRuntimeForTesting: Bool {
        backgroundOperationRuntime != nil
    }

    func handleRealtimeMailSignal(
        accountID: AccountID
    ) async throws {
        guard runtimeConstructionIsOpen,
              !accountDeletionIsInProgress
        else { return }
        do {
            guard try store.mailSource(accountID: accountID).runsDirectSync else { return }
        } catch {
            // Dropped, not refused: the monitor's fallback poll signals again.
            serviceMailModeLogger.error(
                "Realtime mail signal skipped: the account mail source could not be read."
            )
            return
        }
        let runtime = try backgroundOperationRuntimeForUse()
        try runtime.enqueueRealtimeSyncIfNeeded(accountID: accountID)
        _ = try await processBackgroundJobs()
    }

    /// Enqueues an inbox sync for a reauthorized account. The coalesced
    /// enqueue resumes a sync paused while the grant was refused, and the
    /// background wake runs it. Reauthorization already succeeded, so a
    /// failure here only leaves the paused job for the next sync.
    private func resumeInboxSyncAfterReauthorization(accountID: AccountID) async {
        guard runtimeConstructionIsOpen, !accountDeletionIsInProgress else { return }
        do {
            try backgroundOperationRuntimeForUse().enqueueRealtimeSyncIfNeeded(accountID: accountID)
            try await replaceBackgroundJobWakeFromPersistedQueue()
        } catch {}
    }

    func confirmVaultLocked() {
        precondition(!runtimeConstructionIsOpen)
        precondition(activeOperationCount == 0)
        precondition(!accountDeletionIsInProgress)
    }

    func perform(_ operation: PlainpostForegroundOperation) async throws
        -> PlainpostForegroundOperationResult
    {
        try operation.validate()
        if case .deleteAccount(let input) = operation {
            return try await performAccountDeletion(input)
        }
        if case .deliverBrowserReply(let input) = operation {
            return try await performBrowserReplyDelivery(input)
        }
        try beginOperation()
        defer { finishOperation() }
        switch operation {
        case .inboxSync(let input):
            await installNotificationConfiguration?()
            return .inboxSync(
                syncResultWithMetadata(
                    try await operationClientForUse()
                        .executeInboxSync(input)
                )
            )
        case .historicalSync(let input):
            await installNotificationConfiguration?()
            return .historicalSync(
                syncResultWithMetadata(
                    try await operationClientForUse()
                        .executeInboxSync(input)
                )
            )
        case .ai(let input):
            if input.enqueueOnly {
                guard input.operation == .recategorizeInbox, input.smartInboxRunMode == .incremental else {
                    throw PlainpostServiceClientError.invalidRequest
                }
                try await operationClientForUse().enqueueIncrementalSmartInbox(input)
                return .ai(.init(
                    operation: input.operation,
                    recordID: input.recordID,
                    artifactID: "",
                    jobID: "smart-inbox-enqueued"
                ))
            }
            return .ai(try await operationClientForUse().executeAI(input))
        case .translateMessage(let input):
            return .translateMessage(try await operationClientForUse().executeAI(input))
        case .approveSend(let input):
            try await operationClientForUse().approveSend(
                requestID: input.requestID, approvedBy: input.actorID)
            return .approveSend
        case .denySend(let input):
            try await operationClientForUse().denySend(
                requestID: input.requestID, deniedBy: input.actorID)
            return .denySend
        case .accountAdd(let input):
            let result = try await accountRuntimeForUse().addAccount(Self.accountRequest(input))
            return .accountAdd(
                PlainpostAccountSetupSemanticResult(
                    accountID: result.account.id.rawValue, email: result.account.email.rawValue,
                    isIMAPVerified: result.imapVerified, isSMTPVerified: result.smtpVerified,
                    syncedMessageCount: result.syncedMessageCount))
        case .accountTest(let input):
            let result = try await accountRuntimeForUse().testAccount(Self.accountRequest(input))
            return .accountTest(
                PlainpostAccountTestSemanticResult(
                    isIMAPVerified: result.imapVerified, isSMTPVerified: result.smtpVerified))
        case .replaceAccountCredentials(let input):
            try await accountRuntimeForUse().replaceCredentials(
                accountID: AccountID(input.accountID), imapPassword: input.imapPassword,
                smtpPassword: input.smtpPassword)
            return .replaceAccountCredentials
        case .googleAccountAdd(let input):
            return try await Self.performGoogleAccountAdd(input, runtime: accountRuntimeForUse())
        case .replaceGoogleAccountCredential(let input):
            let result = try await Self.performReplaceGoogleAccountCredential(input, runtime: accountRuntimeForUse())
            await resumeInboxSyncAfterReauthorization(accountID: AccountID(input.accountID))
            return result
        case .deleteAccount:
            throw PlainpostServiceClientError.operationFailed
        case .deliverDirectDraft(let input):
            // An unreadable draft refuses too; the check is never skipped.
            let draft = try store.draft(id: DraftID(input.draftID))
            if try store.mailSource(accountID: draft.accountID).kind == .nodeBacked {
                return .deliverDirectDraft(try await routedDraftDelivery(input, draft: draft))
            }
            try refuseNodeModeAccount(draft.accountID)
            let result = try await localDraftDeliveryRuntimeForUse().deliver(
                draftID: DraftID(input.draftID), expectedHash: input.expectedHash,
                actor: Actor(id: input.actorID, kind: .user, displayName: "Local User", permissions: .guiUser)
            )
            return .deliverDirectDraft(
                PlainpostDirectDraftDeliverySemanticResult(
                    messageID: result.messageID, remoteSentCopyAppended: result.remoteSentCopyAppended
                )
            )
        case .deliverBrowserReply:
            // Handled before the operation count (`performBrowserReplyDelivery`).
            throw PlainpostServiceClientError.invalidRequest
        case .archive(let input):
            return .archive(
                try await mailAction(
                    .archive,
                    messageID: input.messageID,
                    archiveMailbox: input.archiveMailbox,
                    shownIn: input.sourceMailbox, shownUID: input.sourceUID
                )
            )
        case .delete(let input):
            return .delete(try await mailAction(
                .delete, messageID: input.messageID, permanent: input.permanent,
                shownIn: input.sourceMailbox, shownUID: input.sourceUID
            ))
        case .markRead(let input):
            return .markRead(try await mailAction(.markRead, messageID: input.messageID))
        case .markUnread(let input):
            return .markUnread(try await mailAction(.markUnread, messageID: input.messageID))
        case .flag(let input):
            return .flag(try await mailAction(.flag, messageID: input.messageID,
                                              shownIn: input.sourceMailbox, shownUID: input.sourceUID))
        case .unflag(let input):
            return .unflag(try await mailAction(.unflag, messageID: input.messageID,
                                                shownIn: input.sourceMailbox, shownUID: input.sourceUID))
        case .move(let input):
            return .move(try await mailAction(.move, messageID: input.messageID, archiveMailbox: input.archiveMailbox,
                                              shownIn: input.sourceMailbox, shownUID: input.sourceUID))
        case .addLabel(let input):
            try applyLabel(input, selected: true)
            return .addLabel
        case .removeLabel(let input):
            try applyLabel(input, selected: false)
            return .removeLabel
        case .labelCommand(let input):
            try applyLabel(input, selected: input.selected)
            return .labelCommand
        }
    }

    func processBackgroundJobs() async throws
        -> PlainpostBackgroundJobResult
    {
        if let backgroundJobDrainFlight {
            // A caller can arrive after the active pass's final empty claim.
            // Keep one successor pass attached to the shared result.
            backgroundJobDrainRerunRequested = true
            return try await backgroundJobDrainFlight.task.value
        }
        let flightID = UUID()
        backgroundJobDrainRerunRequested = false
        let task = Task { [weak self] in
            guard let self else {
                throw PlainpostServiceClientError.serviceUnavailable
            }
            return try await self.performBackgroundJobDrainFlight(
                id: flightID
            )
        }
        backgroundJobDrainFlight = (flightID, task)
        return try await task.value
    }

    private func performBackgroundJobDrainFlight(
        id flightID: UUID
    ) async throws -> PlainpostBackgroundJobResult {
        var recoveredJobCount = 0
        var processedJobCount = 0
        do {
            while true {
                let result = try await performBackgroundJobDrain()
                recoveredJobCount += result.recoveredJobCount
                processedJobCount += result.processedJobCount
                guard backgroundJobDrainRerunRequested else {
                    clearBackgroundJobDrainFlight(id: flightID)
                    return PlainpostBackgroundJobResult(
                        recoveredJobCount: recoveredJobCount,
                        processedJobCount: processedJobCount
                    )
                }
                backgroundJobDrainRerunRequested = false
            }
        } catch {
            clearBackgroundJobDrainFlight(id: flightID)
            throw error
        }
    }

    private func performBackgroundJobDrain() async throws
        -> PlainpostBackgroundJobResult
    {
        try beginOperation()
        defer { finishOperation() }
        await installNotificationConfiguration?()
        try recoverMacNewMailRulePolicy(now: dateProvider())
        let recovery = try store.recoverBackgroundAgentJobs(
            allowedKinds: PlainpostBackgroundAgentJobPolicy.allowedKinds
        )
        let runtime = try backgroundOperationRuntimeForUse()
        var processedJobCount = 0
        var readyCutoff = dateProvider()
        var wakeQueryTime = readyCutoff
        var nextQueuedAt: Date?
        while true {
            while try await runtime
                .processNextJobContinuingAfterFailure(
                    now: readyCutoff
                ) != nil
            {
                processedJobCount += 1
                readyCutoff = dateProvider()
            }
            wakeQueryTime = dateProvider()
            // Keep the cutoff from the final empty claim. A fresh cutoff
            // would exclude work that became due while the drain unwound.
            nextQueuedAt =
                try store.earliestQueuedJobAvailability(
                    strictlyAfterReadyCutoff: readyCutoff,
                    allowedKinds:
                        PlainpostBackgroundAgentJobPolicy.allowedKinds
                )
            guard let nextQueuedAt,
                  nextQueuedAt <= wakeQueryTime
            else {
                break
            }
            readyCutoff = wakeQueryTime
        }
        var nextNotificationAt: Date?
        if let notificationDrain {
            let notificationResult = try await notificationDrain.drain()
            nextNotificationAt = notificationResult.retryAt
        }
        let nextWake = [nextQueuedAt, nextNotificationAt].compactMap { $0 }.min()
        await replaceBackgroundJobWake(at: nextWake)
        try store.pruneTerminalJobs(
            before: wakeQueryTime.addingTimeInterval(-3_600)
        )
        return PlainpostBackgroundJobResult(
            recoveredJobCount:
                recovery.requeuedExpiredCount
                + recovery.cancelledDuplicateCount
                + recovery.cancelledExpiredCount,
            processedJobCount: processedJobCount
        )
    }

    private func recoverMacNewMailRulePolicy(now: Date) throws {
        for batch in try store.awaitingMacNewMailEventMessageIDs(limit: 500, now: now) {
            do {
                let suppressed = try MailRuleNotificationPolicy.evaluate(
                    messageIDs: batch.messageIDs,
                    accountID: batch.accountID,
                    store: store
                )
                try store.resolveMacNewMailEvents(
                    accountID: batch.accountID,
                    messageIDs: batch.messageIDs,
                    suppressedIDs: suppressed,
                    now: now
                )
            } catch {
                for messageID in batch.messageIDs {
                    try? store.recordMailRuleEvaluationFailure(messageID: messageID, error: error)
                }
                try store.failMacNewMailRuleEvaluation(
                    accountID: batch.accountID,
                    messageIDs: batch.messageIDs,
                    now: now
                )
            }
        }
    }

    private func clearBackgroundJobDrainFlight(id: UUID) {
        guard backgroundJobDrainFlight?.id == id else { return }
        backgroundJobDrainFlight = nil
        backgroundJobDrainRerunRequested = false
    }

    private func performAccountDeletion(
        _ input: PlainpostAccountDeletionPayload
    ) async throws -> PlainpostForegroundOperationResult {
        try requireRuntimeConstruction()
        guard !accountDeletionIsInProgress else {
            throw PlainpostServiceClientError.operationFailed
        }
        accountDeletionIsInProgress = true
        let deletionRuntime: AccountSetupService
        do {
            deletionRuntime = try accountRuntimeForUse()
        } catch {
            accountDeletionIsInProgress = false
            throw error
        }

        var interruptedIncrementalJobIDs: [String] = []
        do {
            if activeOperationCount > 0 {
                await withCheckedContinuation {
                    operationDrainWaiters.append($0)
                }
            }
            interruptedIncrementalJobIDs =
                await operationClient?.cancelAndWaitForIncrementalSmartInbox() ?? []
            if let backgroundJobDrainFlight {
                backgroundJobDrainFlight.task.cancel()
                _ = try? await backgroundJobDrainFlight.task.value
                clearBackgroundJobDrainFlight(id: backgroundJobDrainFlight.id)
            }
            await backgroundJobWakeScheduler.replaceWake(at: nil, action: {})
            try await deletionRuntime.deleteAccount(
                accountID: AccountID(input.accountID)
            )
        } catch {
            await operationClient?.resumeIncrementalSmartInbox(
                jobIDs: interruptedIncrementalJobIDs
            )
            await finishAccountDeletion()
            throw error
        }

        await operationClient?.resumeIncrementalSmartInbox(
            jobIDs: interruptedIncrementalJobIDs
        )
        await finishAccountDeletion()
        return .deleteAccount
    }

    private func finishAccountDeletion() async {
        accountDeletionIsInProgress = false
        let waiters = accountDeletionWaiters
        accountDeletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !vaultLockdownOwnsRuntimeTransition
            && runtimeConstructionIsOpen
        {
            try? await replaceBackgroundJobWakeFromPersistedQueue()
        }
    }

    private func replaceBackgroundJobWakeFromPersistedQueue()
        async throws
    {
        let nextQueuedAt =
            try store.earliestQueuedJobAvailability(
                allowedKinds:
                    PlainpostBackgroundAgentJobPolicy.allowedKinds
            )
        await replaceBackgroundJobWake(at: nextQueuedAt)
    }

    private func replaceBackgroundJobWake(
        at nextQueuedAt: Date?
    ) async {
        await backgroundJobWakeScheduler.replaceWake(
            at: nextQueuedAt
        ) { [weak self] in
            _ = try? await self?.processBackgroundJobs()
        }
    }

    func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequest
    ) async throws -> PlainpostSmartInboxBatchResult {
        try beginOperation()
        defer { finishOperation() }
        guard PlainpostSmartInboxBatchContract.categories.contains(
                  request.category
              ),
              PlainpostSmartInboxBatchContract.actions.contains(
                  request.action
              )
        else {
            throw PlainpostServiceClientError.invalidRequest
        }
        let accountID = AccountID(request.accountID)
        guard let account = store.accounts.first(where: {
            $0.id == accountID
        }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        try refuseNodeModeAccount(account.id)
        let matching = store.messages
            .filter {
                store.accountID(forMessageID: $0.id) == accountID
                    && Self.smartInboxBatchMatches(
                        $0,
                        category: request.category
                    )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        guard matching.count
                <= PlainpostSmartInboxBatchContract
                    .maximumAffectedMessageCount
        else {
            throw PlainpostServiceClientError.invalidRequest
        }
        let actor = Actor(
            id: "plainpost-cli",
            kind: .cli,
            displayName: "Plainpost CLI",
            permissions: .guiUser
        )
        let store = self.store
        let accountMailboxes = store.mailboxes.filter { $0.accountID == accountID }
        let (archiveMailbox, affectedMessageIDs) = try await withAuthenticatedIMAPClient(
            for: account,
            missingCredentialError: CredentialVaultError.keyMissing
        ) { client in
            // The account's own Archive (Gmail: All Mail); none refuses before
            // any change. An empty batch needs none.
            let archiveMailbox = matching.isEmpty ? request.archiveMailbox : try await ArchiveMailbox.resolve(
                requested: request.archiveMailbox, client: client, cachedMailboxes: accountMailboxes
            )
            var selectedMailbox: String?
            var affectedMessageIDs: [String] = []
            for message in matching {
                let membership = try store.membership(for: message.id)
                guard membership.accountID == accountID else {
                    throw PlainpostServiceClientError.operationFailed
                }
                // Only an Inbox copy is archived; a seen message whose copy is in
                // Trash, Sent or Spam (or already in the Archive) stays put.
                let archivable = membership.mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
                    && membership.mailboxPath.caseInsensitiveCompare(archiveMailbox) != .orderedSame
                if archivable, selectedMailbox != membership.mailboxPath {
                    _ = try await client.selectMailbox(
                        membership.mailboxPath
                    )
                    selectedMailbox = membership.mailboxPath
                }
                // A move that reports where the copy landed (COPYUID), so the
                // Archive copy never keeps the source UID.
                let moved = archivable ? try await client.move(uid: membership.uid, to: archiveMailbox) : nil
                let movedDuplicates = moved == nil ? [] : await client.moveDuplicates(
                    try store.duplicateCopyUIDs(of: membership), to: archiveMailbox
                )
                _ = try store.markSeen(
                    message.id,
                    seen: true,
                    actor: actor
                )
                if let moved {
                    _ = try? store.recordConfirmedMove(
                        membership: membership, to: moved.mailbox,
                        uidValidity: moved.uidValidity, uid: moved.uid,
                        duplicateUIDs: movedDuplicates, actor: actor
                    )
                }
                affectedMessageIDs.append(message.id.rawValue)
            }
            return (archiveMailbox, affectedMessageIDs)
        }
        return PlainpostSmartInboxBatchResult(
            accountID: request.accountID,
            category: request.category,
            action: request.action,
            affectedMessageIDs: affectedMessageIDs,
            archiveMailbox: archiveMailbox
        )
    }

    /// The delivery runs as a counted operation; a reply queued for the
    /// Sync Node then waits for its outcome outside the count, so a vault
    /// lockdown never waits on it.
    private func performBrowserReplyDelivery(
        _ input: PlainpostBrowserReplyDeliveryPayload
    ) async throws -> PlainpostForegroundOperationResult {
        let result: LocalAPIDeliveryResult
        do {
            try beginOperation()
            defer { finishOperation() }
            result = try await browserDeliveryRuntimeForUse().send(
                draftID: input.draftID, expectedHash: input.expectedHash,
                idempotencyKey: input.idempotencyKey)
        }
        var state = result.state
        if state == .waitingForNode {
            state = await settledBrowserReply(requestID: SendRequestID(result.requestID)) ?? .waitingForNode
        }
        return .deliverBrowserReply(
            PlainpostBrowserReplyDeliverySemanticResult(
                requestID: result.requestID, jobID: result.jobID, state: state.rawValue))
    }

    /// How long a browser reply queued for the Sync Node is held for its
    /// outcome before the reply answers "waiting" (shown to the extension as
    /// "may have been sent", locked).
    private var browserReplySettleTimeout: Duration = .seconds(20)
    private var browserReplySettlePoll: Duration = .milliseconds(250)

    func setBrowserReplySettleTiming(timeout: Duration, poll: Duration) {
        browserReplySettleTimeout = timeout
        browserReplySettlePoll = poll
    }

    /// Waits, bounded, for a routed browser reply to settle: reconciles the
    /// request against its intent until it is sent, failed or uncertain.
    private func settledBrowserReply(requestID: SendRequestID) async -> LocalAPIDeliveryState? {
        guard let router = mailIntentRouter else { return nil }
        let deadline = ContinuousClock.now + browserReplySettleTimeout
        while true {
            // A lock, lockdown or account deletion ends the wait at once: the reply stays
            // waiting (locked in the extension) and settles later.
            guard runtimeConstructionIsOpen, !accountDeletionIsInProgress else { return nil }
            await ServiceApprovedSendRouting.reconcileRequest(id: requestID, store: store, router: router)
            if let request = try? store.sendRequest(id: requestID) {
                let state = LocalAPIDeliveryState.completedDelivery(requestStatus: request.status)
                if state != .waitingForNode { return state }
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: browserReplySettlePoll)
        }
    }

    func sendBrowserApprovedReply(
        jobID: String
    ) async throws -> PlainpostBrowserApprovedReplyResult {
        let result = try await sendBrowserApprovedReplyCounted(jobID: jobID)
        guard result.state == LocalAPIDeliveryState.waitingForNode.rawValue else { return result }
        // Outside the operation count: the wait only reads the store, and a
        // vault lockdown must not wait for it.
        let settled = await settledBrowserReply(requestID: SendRequestID(result.requestID)) ?? .waitingForNode
        return PlainpostBrowserApprovedReplyResult(requestID: result.requestID, jobID: result.jobID, state: settled.rawValue)
    }

    private func sendBrowserApprovedReplyCounted(
        jobID: String
    ) async throws -> PlainpostBrowserApprovedReplyResult {
        try beginOperation()
        defer { finishOperation() }
        let job = try store.job(id: jobID)
        guard job.kind == .approvedDelivery,
              job.idempotencyKey.hasPrefix("browser-send:"),
              let input = try? JSONDecoder().decode(
                PlainpostApprovalDecisionInput.self,
                from: Data(job.payloadJSON.utf8)
              ),
              input.actorID == "browser-extension-user"
        else {
            throw PlainpostServiceClientError.invalidRequest
        }
        let request = try store.sendRequest(id: input.requestID)
        let draft = try store.draft(id: request.draftID)
        guard request.id == input.requestID,
              request.draftID == draft.id,
              request.requestedBy == input.actorID,
              request.reason
                == "Direct reply authorized in Plainpost browser extension",
              request.requestedDraftHash == draft.contentHash,
              draft.id.rawValue.hasPrefix("drf_browser_"),
              draft.createdBy == input.actorID,
              Self.browserRequestStateIsValid(
                request.status,
                for: job.state
              )
        else {
            throw PlainpostServiceClientError.invalidRequest
        }

        let terminal: PlainpostDurableJob
        switch job.state {
        case .completed, .failed, .cancelled, .deliveryUncertain:
            terminal = job
        case .queued, .running, .paused:
            terminal = try await browserApprovedDeliveryRuntimeForUse()
                .runUntilTerminalState(jobID: job.id)
        }
        let state: String
        switch terminal.state {
        case .completed:
            // A send routed through the journal completes its job while the
            // request may still wait for the Sync Node.
            let settled = (try? store.sendRequest(id: input.requestID))?.status ?? .sent
            state = LocalAPIDeliveryState.completedDelivery(requestStatus: settled).rawValue
        case .failed, .cancelled:
            state = "failed"
        case .deliveryUncertain:
            state = "deliveryUncertain"
        case .queued, .running, .paused:
            throw PlainpostServiceClientError.operationFailed
        }
        return PlainpostBrowserApprovedReplyResult(
            requestID: input.requestID.rawValue,
            jobID: terminal.id,
            state: state
        )
    }

    func syncDraftToServer(
        draftID: String,
        mailbox: String
    ) async throws -> PlainpostDraftSyncResult {
        try beginOperation()
        defer { finishOperation() }
        let draft = try store.draft(id: DraftID(draftID))
        guard let account = store.accounts.first(where: {
            $0.id == draft.accountID
        }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        if try store.mailSource(accountID: account.id).kind == .nodeBacked {
            return try await routedDraftSync(draft, mailbox: mailbox)
        }
        try refuseNodeModeAccount(account.id)
        let append = try await appendDraftToServer(draft, account: account, mailbox: mailbox)
        let synced = try store.recordServerDraft(
            id: draft.id,
            uid: append.uid,
            mailboxID: append.mailbox,
            actor: Actor(
                id: "plainpost-service",
                kind: .system,
                displayName: "Plainpost Service",
                permissions: .guiUser
            )
        )
        return PlainpostDraftSyncResult(
            draftID: synced.id.rawValue,
            mailbox: append.mailbox,
            serverDraftUID: append.uid
        )
    }

    private func appendDraftToServer(_ draft: Draft, account: Account, mailbox: String) async throws -> IMAPAppendResult {
        let rendered = try DraftRenderer().render(draft)
        let messageData = "\(rendered.headers)\r\n\r\n\(rendered.body)"
        return try await withAuthenticatedIMAPClient(
            for: account,
            missingCredentialError: CredentialVaultError.keyMissing
        ) { client in
            try await client.appendMessage(
                to: mailbox,
                flags: ["\\Draft"],
                data: messageData
            )
        }
    }

    /// Runs `body` on a freshly authenticated IMAP client from the one
    /// service credential resolver and always disconnects it. Each attempt
    /// connects anew, so the resolver's single OAuth retry precedes any work.
    private func withAuthenticatedIMAPClient<T: Sendable>(
        for account: Account,
        missingCredentialError: any Error & Sendable,
        _ body: @escaping @Sendable (any IMAPClientProtocol) async throws -> T
    ) async throws -> T {
        do {
            return try await credentialResolver.withIMAPAuthentication(for: account) { authentication in
                let client = MailTransportClientFactory.imapClient(
                    host: account.imapHost,
                    port: account.imapPort
                )
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
            throw missingCredentialError
        }
    }

    private func accountRuntimeForUse() throws -> AccountSetupService {
        try requireRuntimeConstruction()
        if let accountRuntime {
            return accountRuntime
        }
        let runtime = accountRuntimeFactory()
        accountRuntime = runtime
        return runtime
    }

    private func operationRuntimeForUse() throws -> LocalOperationRuntime {
        try requireRuntimeConstruction()
        if let operationRuntime {
            return operationRuntime
        }
        let runtime = operationRuntimeFactory()
        operationRuntime = runtime
        return runtime
    }

    private func backgroundOperationRuntimeForUse() throws
        -> LocalOperationRuntime
    {
        try requireRuntimeConstruction()
        if let backgroundOperationRuntime {
            return backgroundOperationRuntime
        }
        var handoff: NodeModeMailboxHandoff?
        if mailIntentRouter != nil {
            handoff = { [weak self] (work: NodeModeMailboxWork) async throws -> Bool in
                guard let self else { throw PlainpostServiceClientError.serviceUnavailable }
                return try await self.handOffNodeModeMailboxWork(work)
            }
        }
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: assembly.vault,
            allowedJobKinds:
                PlainpostBackgroundAgentJobPolicy.allowedKinds,
            credentialResolver: credentialResolver,
            failureDateProvider: dateProvider,
            nodeModeMailboxHandoff: handoff,
            nodeModeApprovedSendHandoff: approvedSendHandoff
        )
        backgroundOperationRuntime = runtime
        return runtime
    }

    private func browserApprovedDeliveryRuntimeForUse() throws
        -> LocalOperationRuntime
    {
        try requireRuntimeConstruction()
        return LocalOperationRuntime(
            store: store,
            credentials: assembly.vault,
            allowedJobKinds: [.approvedDelivery],
            credentialResolver: credentialResolver,
            nodeModeApprovedSendHandoff: approvedSendHandoff
        )
    }

    private func operationClientForUse() throws -> LocalOperationClient {
        try requireRuntimeConstruction()
        if let operationClient { return operationClient }
        let client = LocalOperationClient(runtime: try operationRuntimeForUse())
        operationClient = client
        return client
    }

    private func syncResultWithMetadata(
        _ result: PlainpostInboxSyncResult
    ) -> PlainpostInboxSyncResult {
        let messageMetadata = store.messages
            .filter {
                store.accountID(forMessageID: $0.id)
                    == result.accountID
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map {
                PlainpostInboxSyncMessageMetadata(
                    messageID: $0.id,
                    subject: $0.subject,
                    preview: $0.preview,
                    path: $0.mailboxPath
                )
            }
        let mailboxMetadata = store.mailboxes
            .filter { $0.accountID == result.accountID }
            .map(\.path)
            .sorted()
            .map(PlainpostInboxSyncMailboxMetadata.init(path:))
        return PlainpostInboxSyncResult(
            accountID: result.accountID,
            syncedMessageCount: result.syncedMessageCount,
            newlyDiscoveredMessageCount:
                result.newlyDiscoveredMessageCount,
            source: result.source,
            newMessageIDs: result.newMessageIDs,
            suppressedNotificationMessageIDs:
                result.suppressedNotificationMessageIDs,
            jobID: result.jobID,
            mailboxes: mailboxMetadata,
            messages: messageMetadata
        )
    }

    private func localDraftDeliveryRuntimeForUse() throws -> LocalDraftDeliveryService {
        try requireRuntimeConstruction()
        if let localDraftDeliveryRuntime { return localDraftDeliveryRuntime }
        let runtime = LocalDraftDeliveryService(
            store: store, credentials: assembly.vault, credentialResolver: credentialResolver)
        localDraftDeliveryRuntime = runtime
        return runtime
    }

    private func browserDeliveryRuntimeForUse() throws -> BrowserReplyDeliveryService {
        try requireRuntimeConstruction()
        if let browserDeliveryRuntime { return browserDeliveryRuntime }
        let runtime = BrowserReplyDeliveryService(
            store: store, runtime: try operationRuntimeForUse())
        browserDeliveryRuntime = runtime
        return runtime
    }

    private func mailAction(
        _ action: ServiceMailAction,
        messageID: String,
        archiveMailbox: String? = nil,
        permanent: Bool = false,
        shownIn shownMailbox: String? = nil,
        shownUID: Int? = nil
    ) async throws
        -> PlainpostMailActionSemanticResult
    {
        try requireRuntimeConstruction()
        let id = MessageID(messageID)
        if let accountID = store.accountID(forMessageID: id),
           try store.mailSource(accountID: accountID).kind == .nodeBacked {
            // The Sync Node never erases, and its fallback route mustn't either.
            guard !permanent else {
                throw PlainpostError.validationFailed(MailActionRefusal.noPermanentDeleteWithSyncNode.message)
            }
            // The Node's intents name a message, not a copy; say so rather than ignore it.
            guard shownMailbox == nil, shownUID == nil else {
                throw PlainpostError.validationFailed(MailActionRefusal.noSourceMailboxWithSyncNode.message)
            }
            return try await routedMailAction(action, messageID: id, archiveMailbox: archiveMailbox)
        }
        let directAction: DirectMailboxAction
        switch action {
        case .markRead: directAction = .markRead
        case .markUnread: directAction = .markUnread
        case .archive: directAction = .archive
        case .delete: directAction = permanent ? .deletePermanently : .delete
        case .flag: directAction = .flag
        case .unflag: directAction = .unflag
        case .move:
            guard let archiveMailbox else { throw PlainpostServiceClientError.invalidRequest }
            directAction = .move(to: archiveMailbox)
        }
        let scheduler = mailboxFlagScheduler
        let sharedActions = DirectMailboxActionService(
            store: store, credentials: credentialResolver,
            requireExplicitDirectSource: false,
            signalFlagWork: { try await scheduler.signalWork() }
        )
        let result = try await sharedActions.perform(
            directAction, messageID: id, archiveMailbox: archiveMailbox,
            shownIn: shownMailbox, shownUID: shownUID
        )
        let message = result.message
        return PlainpostMailActionSemanticResult(
            messageID: message.id.rawValue,
            seen: action == .markRead || action == .markUnread ? message.isSeen : nil,
            // A Delete that left the message in Trash reports where it is.
            mailboxPath: action == .archive || (action == .delete && !message.isDeleted) ? message.mailboxPath : nil,
            isDeleted: message.isDeleted,
            deleteOutcome: result.deleteOutcome
        )
    }

    /// The Mac's direct provider write for a Node-backed account in fallback.
    /// Delete follows the same rules as a Direct account's (`TrashDelete`):
    /// it moves to Trash, leaves a message already there alone, refuses
    /// without a Trash, and never erases (the Sync Node never does either).
    @discardableResult
    func performRemoteMailAction(
        _ action: ServiceMailAction,
        messageID: MessageID,
        archiveMailbox: String?
    ) async throws -> (
        membership: MailboxMessageMembership, deleteStep: TrashDelete.Step?, archived: IMAPMoveResult?,
        movedDuplicates: [Int]
    ) {
        // Archive and delete act on the copy the user sees.
        let membership = action == .archive || action == .delete
            ? try store.displayedMembership(for: messageID)
            : try store.membership(for: messageID)
        guard membership.messageID == messageID else {
            throw PlainpostServiceClientError.invalidRequest
        }
        if let threadID = store.messages.first(where: {
            $0.id == messageID
        })?.threadID,
           let thread = store.threads.first(where: { $0.id == threadID }),
           thread.accountID != membership.accountID
        {
            throw PlainpostServiceClientError.invalidRequest
        }
        guard let account = store.accounts.first(where: {
            $0.id == membership.accountID
        }) else {
            throw PlainpostError.notFound(
                "Message account was not found."
            )
        }
        try refuseNodeModeAccount(account.id)
        let accountMailboxes = store.mailboxes.filter { $0.accountID == account.id }
        if action == .delete,
           let settled = TrashDelete.precheck(
               sourceMailbox: membership.mailboxPath, cachedMailboxes: accountMailboxes, permanent: false
           ) {
            return (membership, settled, nil, [])
        }
        if action == .archive,
           ArchiveMailbox.isAlreadyArchived(
               sourceMailbox: membership.mailboxPath, requested: archiveMailbox, cachedMailboxes: accountMailboxes
           ) {
            // Already in the Archive: no move into its own mailbox, no store change.
            return (membership, nil, nil, [])
        }
        let duplicates = action == .archive || action == .delete ? try store.duplicateCopyUIDs(of: membership) : []
        return try await withAuthenticatedIMAPClient(
            for: account,
            missingCredentialError: PlainpostError.validationFailed(
                "IMAP credentials are not available."
            )
        ) { client in
            let selection = try await client.selectMailbox(
                membership.mailboxPath
            )
            guard IMAPSyncService.uidValidity(from: selection)
                    == membership.uidValidity
            else {
                throw IMAPClientError.protocolError(
                    "Selected mailbox UIDVALIDITY no longer matches local membership."
                )
            }
            switch action {
            case .archive:
                // The account's own Archive (Gmail: All Mail); none refuses
                // before any UID command. A move that reports the Archive
                // copy's new UID (COPYUID).
                let destination = try await ArchiveMailbox.resolve(
                    requested: archiveMailbox, client: client, cachedMailboxes: accountMailboxes
                )
                guard destination.caseInsensitiveCompare(membership.mailboxPath) != .orderedSame else {
                    return (membership, nil, nil, [])
                }
                let moved = try await client.move(uid: membership.uid, to: destination)
                return (membership, nil, moved, await client.moveDuplicates(duplicates, to: destination))
            case .delete:
                let plan = try await TrashDelete.plan(
                    client: client, sourceMailbox: membership.mailboxPath,
                    cachedMailboxes: accountMailboxes, permanent: false
                )
                let step = try await TrashDelete.execute(plan, client: client, uid: membership.uid)
                guard case .moved(let moved) = step else { return (membership, step, nil, []) }
                return (membership, step, nil, await client.moveDuplicates(duplicates, to: moved.mailbox))
            case .markRead:
                try await client.markRead(uid: membership.uid)
            case .markUnread:
                try await client.markUnread(uid: membership.uid)
            case .flag, .unflag, .move:
                // Never reached: a fallback flag or move waits for the Node.
                throw DirectMailDispatchDeferral(reason: "This change waits for your Sync Node.")
            }
            return (membership, nil, nil, [])
        }
    }

    /// Direct provider writes are refused for an account the Sync Node
    /// handles; Direct and fallback accounts pass. A source read error
    /// propagates as itself instead of posing as a refusal.
    private func refuseNodeModeAccount(_ accountID: AccountID) throws {
        guard try store.mailSource(accountID: accountID).runsDirectSync else {
            throw PlainpostServiceClientError.invalidRequest
        }
    }

    private func applyLabel(_ input: PlainpostLabelMutationPayload, selected: Bool) throws {
        try requireRuntimeConstruction()
        let actor = Actor(
            id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        if selected {
            try store.establishUserLabel(
                labelID: input.labelID, on: MessageID(input.messageID), actor: actor)
        } else {
            try store.removeUserOrSmartInboxLabel(
                labelID: input.labelID, from: MessageID(input.messageID), actor: actor)
        }
    }

    static func accountRequest(_ input: PlainpostAccountSetupPayload) -> AccountSetupRequest
    {
        AccountSetupRequest(
            displayName: input.displayName, email: EmailAddress(input.email),
            imapHost: input.imapHost, imapPort: input.imapPort, smtpHost: input.smtpHost,
            smtpPort: input.smtpPort, username: input.username, sentMailbox: input.sentMailbox,
            imapPassword: input.imapPassword, smtpPassword: input.smtpPassword)
    }

    private static func browserRequestStateIsValid(
        _ requestState: SendRequestStatus,
        for jobState: PlainpostOperationState
    ) -> Bool {
        switch jobState {
        case .queued, .running, .paused:
            requestState == .pending
                || requestState == .approved
                || requestState == .sending
        case .completed:
            // `sending` (queued for the Sync Node) and a later settled
            // failure are possible when the send was routed.
            [.sent, .sending, .failed, .deliveryUncertain].contains(requestState)
        case .failed, .cancelled:
            requestState == .failed || requestState == .cancelled
        case .deliveryUncertain:
            requestState == .deliveryUncertain
        }
    }

    private static func smartInboxBatchMatches(
        _ message: MessageSummary,
        category: String
    ) -> Bool {
        switch category {
        case "personal":
            message.smartCategory == .personal && !message.isSeen
        case "notification":
            message.smartCategory == .notification && !message.isSeen
        case "newsletter":
            message.smartCategory == .newsletter && !message.isSeen
        case "seen":
            message.isSeen
        default:
            false
        }
    }

    private func requireRuntimeConstruction() throws {
        guard runtimeConstructionIsOpen else {
            throw CredentialVaultError.locked
        }
    }

    private func beginOperation() throws {
        try requireRuntimeConstruction()
        guard !accountDeletionIsInProgress else {
            throw PlainpostServiceClientError.operationFailed
        }
        activeOperationCount += 1
    }

    private func finishOperation() {
        precondition(activeOperationCount > 0)
        activeOperationCount -= 1
        guard activeOperationCount == 0 else {
            return
        }
        let waiters = operationDrainWaiters
        operationDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - Node-backed routing

extension PlainpostServiceOperations {
    private static let localUser = Actor(
        id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
    static let mayHaveReachedProviderMessage =
        "This change may already have reached your mail provider. It will show after the next sync."
    static let mayHaveBeenSentMessage =
        "This message may have been sent. Check Sent before sending it again."
    static let sendInProgressMessage =
        "This message is already being sent. Check Sent before sending it again."

    private func requireMailIntentRouter() throws -> MailIntentRouter {
        // A Node-backed account is never handled directly without the router.
        guard let mailIntentRouter else { throw PlainpostServiceClientError.nodeSession(.unavailable) }
        return mailIntentRouter
    }

    /// The router's typed refusals as XPC errors. Nothing here falls back.
    private static func routingError(_ error: any Error) -> any Error {
        switch error {
        case MailIntentRouterError.readOnly: PlainpostServiceClientError.nodeSession(.readOnly)
        case MailIntentRouterError.journalUnavailable: PlainpostServiceClientError.nodeSession(.unavailable)
        case MailIntentRouterError.notNodeBacked, MailIntentRouterError.invalidIntent: PlainpostServiceClientError.invalidRequest
        case MailIntentRouterError.sendInProgress: PlainpostError.validationFailed(sendInProgressMessage)
        default: error
        }
    }

    /// A Node-backed account's archive, delete or seen change. The optimistic
    /// store change stays where the direct path makes it: seen before the
    /// dispatch (without a direct flag job), a move or deletion after an
    /// accepted Node dispatch. A pending (unrouted) archive or delete leaves
    /// the store alone so a later direct dispatch still finds the INBOX
    /// membership; the reply carries the requested state.
    func routedMailAction(
        _ action: ServiceMailAction,
        messageID: MessageID,
        archiveMailbox: String?
    ) async throws -> PlainpostMailActionSemanticResult {
        let router = try requireMailIntentRouter()
        let kind: MailIntentKind = switch action {
        case .archive: .archive
        case .delete: .delete
        case .markRead: .markRead
        case .markUnread: .markUnread
        case .flag: .flag
        case .unflag: .unflag
        case .move: .move
        }
        let seenChange: Bool? = switch action {
        case .markRead: true
        case .markUnread: false
        case .archive, .delete, .flag, .unflag, .move: nil
        }
        let previousSeen = seenChange == nil ? nil : try store.messageSummary(id: messageID)?.isSeen
        if let seenChange {
            _ = try store.markSeen(messageID, seen: seenChange, actor: Self.localUser, schedulesDirectFlag: false)
        }
        let revertSeen = { [store] in
            guard seenChange != nil, let previousSeen else { return }
            _ = try? store.markSeen(messageID, seen: previousSeen, actor: Self.localUser, schedulesDirectFlag: false)
        }
        if action == .delete {
            directDeleteOutcomes[messageID] = nil
            awaitingDirectDeleteOutcomes.insert(messageID)
        }
        defer {
            if action == .delete {
                awaitingDirectDeleteOutcomes.remove(messageID)
                directDeleteOutcomes[messageID] = nil
            }
        }
        let dispatch: MailIntentDispatch
        do {
            let folder: String? = switch action {
            case .archive: archiveMailbox ?? "Archive"
            case .move: archiveMailbox
            default: nil
            }
            dispatch = try await router.performIntent(kind, messageID: messageID, archiveMailbox: folder)
        } catch {
            revertSeen()
            throw Self.routingError(error)
        }
        if case let .failed(message) = dispatch.outcome {
            revertSeen()
            throw PlainpostError.validationFailed(message)
        }
        let waiting = dispatch.outcome == .waitingForNode || dispatch.outcome == .uncertain
        switch action {
        case .flag, .unflag:
            // The mirror brings the Node's flag back; nothing is written here.
            let message = try requireMessage(messageID)
            return PlainpostMailActionSemanticResult(
                messageID: messageID.rawValue, isDeleted: message.isDeleted, waitingForNode: waiting)
        case .move:
            // Shown in its new folder until the mirror confirms it.
            let destination = archiveMailbox ?? ""
            let message = dispatch.route == .node
                ? try store.moveMessage(messageID, toMailboxPath: destination, actor: Self.localUser)
                : try requireMessage(messageID)
            return PlainpostMailActionSemanticResult(
                messageID: messageID.rawValue, mailboxPath: message.mailboxPath,
                isDeleted: message.isDeleted, waitingForNode: waiting)
        case .markRead, .markUnread:
            let message = try requireMessage(messageID)
            return PlainpostMailActionSemanticResult(
                messageID: messageID.rawValue, seen: message.isSeen, isDeleted: message.isDeleted,
                waitingForNode: dispatch.route != .direct && waiting)
        case .archive, .delete:
            // Where the Node's archive shows locally until its sync: the account's
            // own Archive when the cached folder list names one.
            let accountMailboxes = store.accountID(forMessageID: messageID).map { accountID in
                store.mailboxes.filter { $0.accountID == accountID }
            } ?? []
            let destination = ArchiveMailbox.destination(requested: archiveMailbox, in: accountMailboxes)
                ?? archiveMailbox ?? ArchiveMailbox.defaultName
            switch dispatch.route {
            case .direct?:
                // The direct route made the provider and store change.
                guard dispatch.outcome == .confirmed else {
                    throw PlainpostError.validationFailed(Self.mayHaveReachedProviderMessage)
                }
                let message = try requireMessage(messageID)
                if action == .delete, let direct = directDeleteOutcomes.removeValue(forKey: messageID) {
                    // What the provider did, even if the local write after it failed.
                    return PlainpostMailActionSemanticResult(
                        messageID: messageID.rawValue, mailboxPath: direct.trashMailbox,
                        isDeleted: false, deleteOutcome: direct.outcome)
                }
                return PlainpostMailActionSemanticResult(
                    messageID: messageID.rawValue,
                    mailboxPath: action == .archive ? message.mailboxPath : nil,
                    isDeleted: message.isDeleted)
            case .node?:
                let message = action == .archive
                    ? try store.moveMessage(messageID, toMailboxPath: destination, actor: Self.localUser)
                    : try store.markDeleted(messageID, deleted: true, actor: Self.localUser)
                return PlainpostMailActionSemanticResult(
                    messageID: messageID.rawValue, mailboxPath: action == .archive ? message.mailboxPath : nil,
                    isDeleted: message.isDeleted, waitingForNode: waiting)
            case nil:
                return PlainpostMailActionSemanticResult(
                    messageID: messageID.rawValue, mailboxPath: action == .archive ? destination : nil,
                    isDeleted: action == .delete, waitingForNode: true)
            }
        }
    }

    /// A Node-backed account's send: one journal row for the draft save and
    /// the send. In fallback the direct route delivers with a Mac-owned
    /// Sent copy and never retries through the Node.
    func routedDraftDelivery(
        _ input: PlainpostDirectDraftDeliveryPayload,
        draft: Draft
    ) async throws -> PlainpostDirectDraftDeliverySemanticResult {
        let router = try requireMailIntentRouter()
        guard draft.contentHash == input.expectedHash else { throw DraftOptimisticUpdateError.conflict }
        guard draft.createdBy == input.actorID else {
            throw PlainpostError.permissionDenied("This actor cannot deliver that draft.")
        }
        let dispatch: MailIntentDispatch
        do {
            // The approved hash is journaled; every later dispatch sends only
            // that content, and the draft is locked against a second send.
            awaitingDirectDeliveries.insert(draft.id)
            dispatch = try await router.sendIntent(draft, approvedContentHash: input.expectedHash)
        } catch {
            awaitingDirectDeliveries.remove(draft.id)
            directDeliveries[draft.id] = nil
            throw Self.routingError(error)
        }
        defer {
            awaitingDirectDeliveries.remove(draft.id)
            directDeliveries[draft.id] = nil
        }
        switch (dispatch.outcome, dispatch.route) {
        case let (.failed(message), _):
            throw PlainpostError.validationFailed(message)
        case (.uncertain, _):
            throw PlainpostError.validationFailed(Self.mayHaveBeenSentMessage)
        case (.confirmed, .direct?):
            guard let delivered = directDeliveries[draft.id] else {
                throw PlainpostError.validationFailed(Self.mayHaveBeenSentMessage)
            }
            return PlainpostDirectDraftDeliverySemanticResult(
                messageID: delivered.messageID, remoteSentCopyAppended: delivered.remoteSentCopyAppended)
        case (.confirmed, _):
            // The Node sent it and owns the Sent copy; the local record shares
            // its canonical ID (`<draftID@plainpost.local>`), so the mirrored
            // copy lands on the same message.
            let message = try? store.recordDirectSentMessage(
                draft: draft,
                actor: Actor(id: input.actorID, kind: .user, displayName: "Local User", permissions: .guiUser))
            return PlainpostDirectDraftDeliverySemanticResult(
                messageID: message?.id.rawValue ?? draft.id.rawValue, remoteSentCopyAppended: true)
        case (.waitingForNode, _):
            // Queued (not dispatched yet) or admitted but unfinished: never
            // reported as sent. The draft stays locked meanwhile.
            return PlainpostDirectDraftDeliverySemanticResult(
                messageID: draft.id.rawValue, remoteSentCopyAppended: false, waitingForNode: true)
        }
    }

    /// A Node-backed account's draft save. In fallback the direct route
    /// appends to the server drafts mailbox as `syncDraftToServer` does.
    func routedDraftSync(_ draft: Draft, mailbox: String) async throws -> PlainpostDraftSyncResult {
        let router = try requireMailIntentRouter()
        requestedDraftMailboxes[draft.id] = mailbox
        defer { requestedDraftMailboxes[draft.id] = nil }
        let dispatch: MailIntentDispatch
        do {
            dispatch = try await router.saveDraftIntent(draft)
        } catch {
            throw Self.routingError(error)
        }
        switch (dispatch.outcome, dispatch.route) {
        case let (.failed(message), _):
            throw PlainpostError.validationFailed(message)
        case (.uncertain, .direct?):
            throw PlainpostError.validationFailed(Self.mayHaveReachedProviderMessage)
        case (.confirmed, .direct?):
            let synced = try store.draft(id: draft.id)
            return PlainpostDraftSyncResult(
                draftID: draft.id.rawValue, mailbox: synced.serverDraftMailboxID ?? mailbox,
                serverDraftUID: synced.serverDraftUID)
        default:
            return PlainpostDraftSyncResult(draftID: draft.id.rawValue, mailbox: mailbox, serverDraftUID: nil)
        }
    }

    // MARK: Direct route (fallback)

    /// Runs `body` for the router's direct route as a counted operation, so
    /// a vault lockdown waits for it. A failure before any provider effect
    /// becomes a `DirectMailDispatchRefusal`, or a `DirectMailDispatchDeferral`
    /// (the intent returns to `pending`) when the reason passes: the runtime
    /// is closed or locked, or the account left fallback since the router
    /// chose the direct route. Anything else stays ambiguous.
    private func directDispatch<T: Sendable>(accountID: AccountID, _ body: () async throws -> T) async throws -> T {
        do {
            try beginOperation()
        } catch {
            throw DirectMailDispatchDeferral(reason: "Plainpost is locked.")
        }
        defer { finishOperation() }
        do {
            guard try store.mailSource(accountID: accountID).runsDirectSync else {
                throw DirectMailDispatchDeferral(reason: "This account's mail is handled by the Sync Node again.")
            }
            return try await body()
        } catch {
            if let deferral = ServiceDirectMailDispatcher.deferral(for: error) { throw deferral }
            if let refusal = ServiceDirectMailDispatcher.refusal(for: error) {
                // A refusal is pre-effect; one caused by the account leaving
                // fallback meanwhile is only a deferral.
                if let source = try? store.mailSource(accountID: accountID), !source.runsDirectSync {
                    throw DirectMailDispatchDeferral(reason: "This account's mail is handled by the Sync Node again.")
                }
                throw refusal
            }
            throw error
        }
    }

    func performDirectMailIntent(_ kind: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws {
        guard let accountID = store.accountID(forMessageID: messageID) else {
            throw DirectMailDispatchRefusal(message: "Message not found.")
        }
        switch kind {
        case .flag, .unflag, .move:
            // A Node-backed account in fallback flags and moves through its Node: the change
            // waits, journaled, until the Node is back.
            throw DirectMailDispatchDeferral(reason: "This change waits for your Sync Node.")
        case .markRead, .markUnread:
            // The provider write itself, not a queued job, so `confirmed`
            // means the flag reached the provider.
            let seen = kind == .markRead
            try await directDispatch(accountID: accountID) {
                try await self.performRemoteMailAction(seen ? .markRead : .markUnread, messageID: messageID, archiveMailbox: nil)
            }
            _ = try? store.markSeen(messageID, seen: seen, actor: Self.localUser, schedulesDirectFlag: false)
        case .archive, .delete:
            let action: ServiceMailAction = kind == .archive ? .archive : .delete
            let performed = try await directDispatch(accountID: accountID) {
                try await self.performRemoteMailAction(action, messageID: messageID, archiveMailbox: archiveMailbox)
            }
            // The provider changed; a local write failure must not look like
            // a failed change (the next sync reconciles the store).
            switch performed.deleteStep {
            case nil:
                // Keyed by the Archive copy's UID (COPYUID), never the old Inbox UID.
                if let archived = performed.archived {
                    _ = try? store.recordConfirmedMove(
                        membership: performed.membership, to: archived.mailbox,
                        uidValidity: archived.uidValidity, uid: archived.uid,
                        duplicateUIDs: performed.movedDuplicates, actor: Self.localUser
                    )
                }
            case .moved(let moved)?:
                // Keyed by the Trash UID (COPYUID), never the old Inbox UID.
                _ = try? store.recordConfirmedTrashMove(
                    membership: performed.membership, to: moved.mailbox,
                    uidValidity: moved.uidValidity, uid: moved.uid,
                    duplicateUIDs: performed.movedDuplicates, actor: Self.localUser
                )
            case .alreadyInTrash?, .erased?:
                break
            }
            // Recorded only for a waiting `routedMailAction`, which clears it.
            switch awaitingDirectDeleteOutcomes.contains(messageID) ? performed.deleteStep : nil {
            case .moved(let moved)?:
                directDeleteOutcomes[messageID] = (.movedToTrash, moved.mailbox)
            case .alreadyInTrash?:
                directDeleteOutcomes[messageID] = (.alreadyInTrash, performed.membership.mailboxPath)
            default:
                break // the fallback never erases
            }
        case .saveDraft, .send, .credentialPush:
            throw DirectMailDispatchRefusal(message: "This change can't be sent directly.")
        }
    }

    func saveDraftDirectly(_ draft: Draft) async throws {
        guard let account = store.accounts.first(where: { $0.id == draft.accountID }) else {
            throw DirectMailDispatchRefusal(message: "Account not found.")
        }
        let mailbox = requestedDraftMailboxes[draft.id] ?? draftsMailboxPath(for: account.id)
        let append = try await directDispatch(accountID: account.id) {
            try self.refuseNodeModeAccount(account.id)
            return try await self.appendDraftToServer(draft, account: account, mailbox: mailbox)
        }
        _ = try? store.recordServerDraft(
            id: draft.id, uid: append.uid, mailboxID: append.mailbox,
            actor: Actor(id: "plainpost-service", kind: .system, displayName: "Plainpost Service", permissions: .guiUser))
    }

    func sendDraftDirectly(_ draft: Draft, approvedContentHash: String) async throws {
        let delivered = try await directDispatch(accountID: draft.accountID) {
            try self.refuseNodeModeAccount(draft.accountID)
            // Delivery re-checks the stored draft against the approved hash.
            return try await self.localDraftDeliveryRuntimeForUse().deliverRoutedFallback(
                draftID: draft.id, expectedHash: approvedContentHash,
                actor: Actor(id: draft.createdBy, kind: .user, displayName: "Local User", permissions: .guiUser))
        }
        if awaitingDirectDeliveries.contains(draft.id) {
            directDeliveries[draft.id] = delivered
        }
    }

    /// A durable flag or archive job for an account now in Node mode (queued
    /// before the flip, or by the app opening a message): it becomes one
    /// journaled intent whose operation ID derives from the job, so a retried
    /// job never adds a second intent or a second Node operation.
    func handOffNodeModeMailboxWork(_ work: NodeModeMailboxWork) async throws -> Bool {
        let router = try requireMailIntentRouter()
        let kind: MailIntentKind
        let messageID: MessageID
        let jobID: String
        var archiveMailbox: String?
        switch work {
        case let .flag(id, message, seen):
            (jobID, messageID, kind) = (id, message, seen ? .markRead : .markUnread)
        case let .archive(id, message, destination):
            (jobID, messageID, kind) = (id, message, .archive)
            archiveMailbox = destination
        }
        do {
            let dispatch = try await router.performIntent(
                kind, messageID: messageID, archiveMailbox: archiveMailbox,
                operationID: MailIntentRouter.operationID(derivedFrom: "mailbox-job\u{0}" + jobID))
            // The local archive follows `routedMailAction`'s rule: only once
            // the Node took the change, or the direct write is confirmed. A
            // pending intent leaves the store for its later dispatch.
            switch (dispatch.route, dispatch.outcome) {
            case (_, .failed): return false
            case (.node?, _): return true
            case (.direct?, .confirmed): return true
            default: return false
            }
        } catch MailIntentRouterError.readOnly {
            return false
        }
    }

    private func requireMessage(_ messageID: MessageID) throws -> MessageSummary {
        guard let message = try store.messageSummary(id: messageID) else { throw PlainpostError.notFound("Message not found.") }
        return message
    }

    private func draftsMailboxPath(for accountID: AccountID) -> String {
        store.mailboxes.first { $0.accountID == accountID && $0.specialUse?.caseInsensitiveCompare("\\Drafts") == .orderedSame }?.path
            ?? "Drafts"
    }
}

enum ServiceMailAction {
    case archive
    case delete
    case markRead
    case markUnread
    case flag
    case unflag
    /// To the folder passed as `archiveMailbox`.
    case move
}

/// The service's notification drain: the durable outbox's `NotificationDrain`, or the
/// production one that follows the Plainpost Account session.
protocol NotificationDraining: Sendable {
    func drain() async throws -> NotificationDrainResult
}

extension NotificationDrain: NotificationDraining {}
