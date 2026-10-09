import Foundation
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostNodeTransport

public enum NodeSendOutcome: Sendable, Equatable {
    case pending, applied, rejected, conflicted, deliveryUncertain
}

/// The store adapter validates account, source generation, Node and mailbox
/// when it atomically reserves exact signed bytes before network dispatch.
public protocol NodeSendJournal: Sendable {
    func requireCurrentSource() throws
    func unresolvedSendOperations(accountID: AccountID) throws -> [Data]
    func reserveSend(canonicalOperation: Data) throws
    func settleSend(canonicalOperation: Data, state: NodeSendOutcome) throws
}

public extension NodeSendJournal {
    func requireCurrentSource() throws {}
}

/// Authenticated Node-backed authorities implement this narrow wake before a
/// notification tap re-reads the projection. Local fixture authorities may
/// omit it; production resolution must never substitute an unauthenticated
/// provider endpoint.
public protocol PlainpostNotificationProviderSynchronizing: Sendable {
    func requestProviderSyncForNotification() async throws
}

/// The one native mail authority backed by an authenticated private Node.
/// Capability objects are independent actors, but all share the same client
/// and therefore the same authenticated session and endpoint.
///
/// A scoped authority (`init(client:accountID:mailAccount:multiAccount:)`) is
/// bound to one provider account (one logical mailbox): snapshots and search
/// read only that account, mutations are signed only for it, and its sender
/// and status come from the account catalog rather than `/v1/status`, which
/// projects the primary account.
public final class PlainpostNodeMailAuthority: PlainpostMailAuthority, SyncNodeStatusProviding, PlainpostNotificationProviderSynchronizing, @unchecked Sendable {
    /// A caller-supplied factory owns its operation bytes, including their
    /// idempotency key.
    public typealias MutationOperationFactory = @Sendable (MailMutationIntent) async throws -> Data
    /// Encodes an intent under the caller's idempotency key.
    typealias KeyedMutationOperationFactory = @Sendable (MailMutationIntent, String) async throws -> Data
    public let accountID: AccountID?
    private let senderLock = NSLock()
    private var currentSenderAddress: EmailAddress?
    private var currentScope: NodeMailAuthorityScope?
    public var senderAddress: EmailAddress? {
        senderLock.lock(); defer { senderLock.unlock() }
        return currentSenderAddress
    }
    /// The provider account a scoped authority is bound to, refreshed by
    /// `status()`; nil for an unscoped authority.
    public var mailAccount: NodeMailAccount? {
        senderLock.lock(); defer { senderLock.unlock() }
        return currentScope?.account
    }
    private let authorityState: NodeAuthorityState
    public let snapshots: any MailSnapshotServing
    public let search: any MailSearchService
    public let messages: any MailMessageServing
    public let mutations: any MailMutationServing
    public let attachments: any MailAttachmentServing
    public let providerController: SyncNodeProviderController
    public let operationsController: SyncNodeOperationsController
    private let callbackLock = NSLock()
    private var statusRefreshCallback: (@Sendable (SyncNodeStatus) -> Void)?
    public var onStatusRefresh: (@Sendable (SyncNodeStatus) -> Void)? {
        get {
            callbackLock.lock(); defer { callbackLock.unlock() }
            return statusRefreshCallback
        }
        set {
            callbackLock.lock(); statusRefreshCallback = newValue; callbackLock.unlock()
        }
    }
    private let client: NodeSyncClient

    public convenience init(
        client: NodeSyncClient,
        accountID: AccountID,
        senderAddress: EmailAddress? = nil,
        mutationOperationFactory: MutationOperationFactory? = nil,
        nodeSendJournal: (any NodeSendJournal)? = nil,
        requiresSendJournal: Bool = false
    ) {
        self.init(
            client: client, accountID: accountID, senderAddress: senderAddress,
            mutationOperationFactory: mutationOperationFactory, scope: nil,
            nodeSendJournal: nodeSendJournal, requiresSendJournal: requiresSendJournal
        )
    }

    init(
        client: NodeSyncClient,
        accountID: AccountID,
        senderAddress: EmailAddress?,
        mutationOperationFactory: MutationOperationFactory?,
        scope: NodeMailAuthorityScope?,
        nodeSendJournal: (any NodeSendJournal)? = nil,
        requiresSendJournal: Bool = false
    ) {
        self.accountID = accountID
        self.client = client
        self.currentSenderAddress = senderAddress
        self.currentScope = scope
        let authorityState = NodeAuthorityState(availability: Self.availability(
            usable: senderAddress != nil, account: scope?.account
        ))
        self.authorityState = authorityState
        let providerController = SyncNodeProviderController(
            client: client, trustedProviderIdentity: senderAddress?.rawValue
        )
        providerController.setGoogleOnboardingAllowed(Self.allowsGoogleOnboarding(scope))
        self.providerController = providerController
        self.operationsController = SyncNodeOperationsController(client: client)
        let snapshotService = NodeSnapshotService(client: client, scope: scope)
        let searchService = NodeSearchService(client: client, accountID: accountID, scopedLogicalMailboxID: scope?.account.logicalMailboxID)
        // On a multi-account Node, message and attachment reads name the
        // account's logical mailbox, so the Node answers 404 for another
        // account's message. An older single-account Node has no scoped
        // routes; its legacy routes serve only its one account.
        let readScope = scope.flatMap { $0.multiAccount ? $0.account.logicalMailboxID : nil }
        let messageService = NodeMessageService(client: client, scopedLogicalMailboxID: readScope)
        let encoder = NodeMailMutationEncoder(client: client)
        let admission = NodeCatalogAdmissionTarget()
        let operationFactory: KeyedMutationOperationFactory
        if let mutationOperationFactory {
            operationFactory = { intent, _ in try await mutationOperationFactory(intent) }
        } else if let scope {
            operationFactory = Self.scopedMutationOperationFactory(encoder: encoder, scope: scope, state: authorityState, admission: admission)
        } else {
            operationFactory = Self.defaultMutationOperationFactory(client: client, encoder: encoder, state: authorityState)
        }
        let mutationService = NodeMutationService(
            client: client, operationFactory: operationFactory, draftRevisions: encoder.draftRevisions,
            accountID: accountID, nodeSendJournal: nodeSendJournal,
            requiresSendJournal: requiresSendJournal
        )
        let attachmentService = NodeAttachmentService(client: client, scopedLogicalMailboxID: readScope)
        snapshots = snapshotService
        search = searchService
        messages = messageService
        mutations = mutationService
        attachments = attachmentService
        providerController.onStatusRefresh = { [weak self] status in
            self?.publish(status)
        }
        providerController.onAssignmentOutcomeAmbiguous = { [weak self] in
            self?.invalidateAfterAmbiguousAssignment()
        }
        admission.setAuthority(self)
    }

    public func status() async throws -> SyncNodeStatus {
        let status = try await client.status()
        if let scope = scopeSnapshot() {
            return try await publishScopedStatus(nodeStatus: status, scope: scope)
        }
        let mapped = status.syncNodeStatus()
        do {
            try providerController.publishTrustedStatus(mapped)
        } catch {
            // A changed provider identity must never replace the existing
            // sender or capability projection. Fail closed while retaining
            // the controller's original identity fence for future recovery.
            invalidateAfterAmbiguousAssignment()
            throw SyncNodeProviderController.Error.providerUnavailable
        }
        return mapped
    }

    public func requestProviderSyncForNotification() async throws {
        try await client.requestProviderSync()
    }

    /// `/v1/status` projects the primary account, so a scoped authority keeps
    /// only its Node-wide diagnostics and takes identity, state and mailboxes
    /// from its own catalog entry. A removed account or a changed identity
    /// fails closed.
    private func publishScopedStatus(nodeStatus: NodeSyncStatusResult, scope: NodeMailAuthorityScope) async throws -> SyncNodeStatus {
        let entry = try await NodeMailAccountCatalog.account(
            scope.account.logicalMailboxID, client: client, multiAccount: scope.multiAccount, legacyStatus: nodeStatus
        )
        guard let entry, entry.providerIdentity == scope.account.providerIdentity else {
            invalidateAfterAmbiguousAssignment()
            throw SyncNodeProviderController.Error.providerUnavailable
        }
        // An older Node reports the whole (single-account) projection in
        // /v1/status. `unavailable` there fails closed exactly like the
        // unscoped authority: the sender is cleared and mutations wait for
        // the next usable status.
        let legacyUnavailable = !scope.multiAccount && nodeStatus.state == "unavailable"
        let mapped = SyncNodeStatus(
            revision: nodeStatus.revision, state: legacyUnavailable ? "unavailable" : (entry.state == .ready ? "ready" : "degraded"),
            version: nodeStatus.version, reachability: nodeStatus.reachability, syncLag: nodeStatus.syncLag,
            storage: nodeStatus.storage, providerIdentity: entry.providerIdentity, assignments: entry.mailboxes,
            backup: nodeStatus.backup, endpoint: nodeStatus.endpoint, updateStatus: nodeStatus.updateStatus
        )
        replaceScope(NodeMailAuthorityScope(account: entry, multiAccount: scope.multiAccount))
        do {
            try providerController.publishTrustedStatus(mapped)
        } catch {
            invalidateAfterAmbiguousAssignment()
            throw SyncNodeProviderController.Error.providerUnavailable
        }
        return mapped
    }

    private func publish(_ status: SyncNodeStatus) {
        let usable = status.state != "unavailable" && status.providerIdentity != nil
        senderLock.lock()
        currentSenderAddress = status.state == "unavailable" ? nil : status.providerIdentity.map { EmailAddress($0) }
        let account = currentScope?.account
        senderLock.unlock()
        authorityState.setAvailability(Self.availability(usable: usable, account: account))
        onStatusRefresh?(status)
    }

    private func replaceScope(_ scope: NodeMailAuthorityScope) {
        senderLock.lock(); currentScope = scope; senderLock.unlock()
        providerController.setGoogleOnboardingAllowed(Self.allowsGoogleOnboarding(scope))
    }

    /// Google configure and mailbox assignment read and write `/v1/status` and
    /// `/v1/mailboxes/assignments`, which project only the primary account.
    /// On a non-primary scoped authority they would configure or assign the
    /// primary account and then fail this authority's identity fence, so the
    /// provider controller refuses them. Unscoped and legacy (single-account)
    /// authorities, and the primary account, keep the onboarding flow.
    private static func allowsGoogleOnboarding(_ scope: NodeMailAuthorityScope?) -> Bool {
        guard let scope, scope.multiAccount else { return true }
        return scope.account.isPrimary
    }

    /// Applies the account's fresh catalog entry, read by the encoder right
    /// before signing. A changed identity fails closed, an account that now
    /// needs reauthorization stops mutating, and the scope (for example a
    /// primary promotion) is refreshed. Recovery from reauthorization happens
    /// only through `status()`.
    fileprivate func admitCatalogEntry(_ entry: NodeMailAccount) throws {
        guard let scope = scopeSnapshot(), entry.logicalMailboxID == scope.account.logicalMailboxID else {
            throw PlainpostError.permissionDenied("The Node authority is awaiting authenticated status confirmation.")
        }
        guard entry.providerIdentity == scope.account.providerIdentity else {
            invalidateAfterAmbiguousAssignment()
            // Throw directly instead of relying on requireAvailable(): a
            // concurrent status() could flip availability back to .available
            // between the invalidation above and a subsequent check, which
            // would let this admission silently succeed against a mismatched
            // identity.
            throw PlainpostError.permissionDenied("The Node authority is awaiting authenticated status confirmation.")
        }
        replaceScope(NodeMailAuthorityScope(account: entry, multiAccount: scope.multiAccount))
        if entry.state == .authenticationRequired {
            authorityState.requireReauthorization()
        }
        try authorityState.requireAvailable()
    }

    private func scopeSnapshot() -> NodeMailAuthorityScope? {
        senderLock.lock(); defer { senderLock.unlock() }
        return currentScope
    }

    /// An assignment may have committed even when its response/status
    /// acknowledgement was lost. Until an authenticated status proves the
    /// resulting authority, no sender or mutation capability is usable.
    public func invalidateAfterAmbiguousAssignment() {
        senderLock.lock()
        currentSenderAddress = nil
        senderLock.unlock()
        authorityState.setAvailability(.awaitingStatus)
    }

    private static func availability(usable: Bool, account: NodeMailAccount?) -> NodeAuthorityState.Availability {
        guard usable else { return .awaitingStatus }
        return account?.state == .authenticationRequired ? .reauthorizationRequired : .available
    }

    private static func scopedMutationOperationFactory(
        encoder: NodeMailMutationEncoder,
        scope: NodeMailAuthorityScope,
        state: NodeAuthorityState,
        admission: NodeCatalogAdmissionTarget
    ) -> KeyedMutationOperationFactory {
        let logicalMailboxID = scope.account.logicalMailboxID
        let resolution: NodeMailMutationEncoder.Resolution = scope.multiAccount ? .accountCatalog : .legacyAssignments
        return { intent, idempotencyKey in
            try state.requireAvailable()
            return try await encoder.operation(
                for: intent, logicalMailboxID: logicalMailboxID,
                idempotencyKey: idempotencyKey, resolution: resolution,
                admitCatalogEntry: { entry in try admission.admit(entry) }
            )
        }
    }

    private static func defaultMutationOperationFactory(
        client: NodeSyncClient,
        encoder: NodeMailMutationEncoder,
        state: NodeAuthorityState
    ) -> KeyedMutationOperationFactory {
        { intent, idempotencyKey in
            try state.requireAvailable()
            let assignments = try await client.mailboxAssignments().assignments
            let role: String
            switch intent {
            case .saveDraft, .deleteDraft, .send: role = "drafts"
            case .setRead, .archive, .delete, .setLabels, .setFlagged, .move: role = "inbox"
            }
            let mailbox = assignments
                .filter { $0.role == role }
                .compactMap { assignment -> (LogicalMailboxID, String)? in
                    guard let logicalMailboxID = assignment.logicalMailboxID else { return nil }
                    return (logicalMailboxID, assignment.mailboxHandle)
                }
                .sorted { $0.0.rawValue.lexicographicallyPrecedes($1.0.rawValue) }
                .first
                ?? assignments.compactMap { assignment -> (LogicalMailboxID, String)? in
                    guard let logicalMailboxID = assignment.logicalMailboxID else { return nil }
                    return (logicalMailboxID, assignment.mailboxHandle)
                }
                .sorted { $0.0.rawValue.lexicographicallyPrecedes($1.0.rawValue) }
                .first
            guard let logicalMailboxID = mailbox?.0 else {
                throw PlainpostError.notFound("Node mailbox assignment was unavailable.")
            }
            return try await encoder.operation(
                for: intent, logicalMailboxID: logicalMailboxID,
                idempotencyKey: idempotencyKey, resolution: .resolved
            )
        }
    }
}

public extension PlainpostNodeMailAuthority {
    /// Snapshots use /v1/mail/snapshot for this account (legacy /v1/snapshot when multiAccount == false), search passes
    /// [logicalMailboxID], mutations are encoded for this logical mailbox, senderAddress = account.providerIdentity,
    /// status is published from the catalog entry.
    convenience init(client: NodeSyncClient, accountID: AccountID, mailAccount: NodeMailAccount,
                     multiAccount: Bool, nodeSendJournal: (any NodeSendJournal)? = nil,
                     requiresSendJournal: Bool = true) {
        self.init(
            client: client, accountID: accountID,
            senderAddress: EmailAddress(mailAccount.providerIdentity),
            mutationOperationFactory: nil,
            scope: NodeMailAuthorityScope(account: mailAccount, multiAccount: multiAccount),
            nodeSendJournal: nodeSendJournal, requiresSendJournal: requiresSendJournal
        )
    }
}

/// Lets the scoped mutation factory, built before the authority finishes
/// initializing, apply fresh catalog entries to its authority. A released
/// authority admits nothing.
private final class NodeCatalogAdmissionTarget: @unchecked Sendable {
    private let lock = NSLock()
    private weak var authority: PlainpostNodeMailAuthority?

    func setAuthority(_ authority: PlainpostNodeMailAuthority) {
        lock.lock(); self.authority = authority; lock.unlock()
    }

    func admit(_ entry: NodeMailAccount) throws {
        lock.lock()
        let authority = self.authority
        lock.unlock()
        guard let authority else {
            throw PlainpostError.permissionDenied("The Node authority is awaiting authenticated status confirmation.")
        }
        try authority.admitCatalogEntry(entry)
    }
}

struct NodeMailAuthorityScope: Sendable {
    let account: NodeMailAccount
    /// False for an older Node without the mail-mode routes; its legacy
    /// routes project this (single, primary) account.
    let multiAccount: Bool
}

internal struct NodeMutationReconciliationPolicy: Sendable {
    let maximumPendingAttempts: Int
    let pendingRetryDelay: Duration

    static let production = NodeMutationReconciliationPolicy(
        maximumPendingAttempts: 120, pendingRetryDelay: .seconds(1)
    )
}

private final class NodeAuthorityState: @unchecked Sendable {
    enum Availability: Sendable {
        case available
        case awaitingStatus
        case reauthorizationRequired
    }

    private let lock = NSLock()
    private var availability: Availability

    init(availability: Availability) { self.availability = availability }

    func setAvailability(_ value: Availability) {
        lock.lock(); availability = value; lock.unlock()
    }

    /// An available authority stops mutating until a status refresh; one
    /// already awaiting status keeps waiting for it.
    func requireReauthorization() {
        lock.lock()
        if availability == .available { availability = .reauthorizationRequired }
        lock.unlock()
    }

    func requireAvailable() throws {
        lock.lock()
        let current = availability
        lock.unlock()
        switch current {
        case .available:
            return
        case .awaitingStatus:
            throw PlainpostError.permissionDenied("The Node authority is awaiting authenticated status confirmation.")
        case .reauthorizationRequired:
            throw PlainpostError.permissionDenied("This mail account needs attention on the Sync Node. Sign in again on your Mac.")
        }
    }
}

private actor NodeSnapshotService: MailSnapshotServing {
    let client: NodeSyncClient
    let scope: NodeMailAuthorityScope?

    init(client: NodeSyncClient, scope: NodeMailAuthorityScope?) {
        self.client = client
        self.scope = scope
    }

    func snapshot(after cursor: MailSearchCursor?, limit: Int) async throws -> MailSnapshotPage {
        do {
            let page: NodeSyncSnapshotPage
            if let scope, scope.multiAccount {
                // Legacy /v1/snapshot projects the primary account; a scoped
                // authority on a multi-account Node reads only its own account.
                guard (1...Int(NodeSyncLimits.maximumPageSize)).contains(limit) else { throw NodeSyncClientError.invalidResponse }
                page = try await client.mailSnapshot(try NodeSyncAccountSnapshotRequest(
                    after: cursor?.rawValue ?? "", limit: UInt16(limit), logicalMailboxID: scope.account.logicalMailboxID
                ))
            } else {
                page = try await client.snapshot(after: cursor?.rawValue, limit: limit)
            }
            return MailSnapshotPage(
                messages: try page.messages.map(NodeSyncCoreMapping.message),
                nextCursor: page.nextCursor.isEmpty ? nil : MailSearchCursor(rawValue: page.nextCursor),
                revision: page.revision
            )
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }
}

private actor NodeMessageService: MailMessageServing {
    let client: NodeSyncClient
    let scopedLogicalMailboxID: LogicalMailboxID?

    init(client: NodeSyncClient, scopedLogicalMailboxID: LogicalMailboxID?) {
        self.client = client
        self.scopedLogicalMailboxID = scopedLogicalMailboxID
    }

    func message(id: MessageID) async throws -> MessageSummary {
        do {
            if let scopedLogicalMailboxID {
                return try NodeSyncCoreMapping.message(try await client.mailMessage(id: id.rawValue, logicalMailboxID: scopedLogicalMailboxID))
            }
            return try NodeSyncCoreMapping.message(try await client.message(id: id.rawValue))
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }
}

internal actor NodeMutationService: MailMutationServing {
    let client: NodeSyncClient
    let operationFactory: PlainpostNodeMailAuthority.KeyedMutationOperationFactory?
    let draftRevisions: NodeDraftRevisionLedger
    let reconciliationPolicy: NodeMutationReconciliationPolicy
    let accountID: AccountID?
    let nodeSendJournal: (any NodeSendJournal)?
    let requiresSendJournal: Bool

    init(
        client: NodeSyncClient,
        operationFactory: PlainpostNodeMailAuthority.KeyedMutationOperationFactory?,
        draftRevisions: NodeDraftRevisionLedger,
        reconciliationPolicy: NodeMutationReconciliationPolicy = .production,
        accountID: AccountID? = nil,
        nodeSendJournal: (any NodeSendJournal)? = nil,
        requiresSendJournal: Bool = false
    ) {
        self.client = client
        self.operationFactory = operationFactory
        self.draftRevisions = draftRevisions
        self.reconciliationPolicy = reconciliationPolicy
        self.accountID = accountID
        self.nodeSendJournal = nodeSendJournal
        self.requiresSendJournal = requiresSendJournal
    }

    func apply(canonicalOperation: Data) async throws -> MailMutationResult {
        do {
            try nodeSendJournal?.requireCurrentSource()
            let operation = try NodeSyncCodec.decodeOperation(canonicalOperation)
            let isSend: Bool
            if case .send = operation.unsigned.operation { isSend = true } else { isSend = false }
            if isSend {
                guard !requiresSendJournal || nodeSendJournal != nil else {
                    throw PlainpostError.permissionDenied("Node send persistence is unavailable.")
                }
                try nodeSendJournal?.reserveSend(canonicalOperation: canonicalOperation)
            }
            var result = try await client.mutation(canonicalOperation: canonicalOperation)
            guard result.idempotencyKey == operation.unsigned.idempotencyKey else {
                throw PlainpostError.validationFailed("The Node returned a result for another operation.")
            }
            var pendingAttempts = 0
            while result.state == "pending" {
                if isSend { try nodeSendJournal?.settleSend(canonicalOperation: canonicalOperation, state: .pending) }
                guard pendingAttempts < reconciliationPolicy.maximumPendingAttempts else {
                    throw PlainpostError.validationFailed("The Node mutation confirmation timed out.")
                }
                try await Task.sleep(for: reconciliationPolicy.pendingRetryDelay)
                try Task.checkCancellation()
                try nodeSendJournal?.requireCurrentSource()
                pendingAttempts += 1
                result = try await client.mutation(canonicalOperation: canonicalOperation)
                guard result.idempotencyKey == operation.unsigned.idempotencyKey else {
                    throw PlainpostError.validationFailed("The Node returned a result for another operation.")
                }
            }
            if isSend, let outcome = Self.sendOutcome(for: result.state) {
                try nodeSendJournal?.settleSend(canonicalOperation: canonicalOperation, state: outcome)
            }
            guard result.state == "applied" else {
                throw Self.error(for: result.state)
            }
            await rememberSuccessfulDraftSave(canonicalOperation: canonicalOperation, state: result.state)
            return MailMutationResult(idempotencyKey: result.idempotencyKey, state: result.state)
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }

    /// One user action is one key: minted once here, never per attempt.
    func perform(_ intent: MailMutationIntent) async throws -> MailMutationResult {
        try await perform(intent, idempotencyKey: UUID().uuidString.lowercased())
    }

    func perform(_ intent: MailMutationIntent, idempotencyKey: String) async throws -> MailMutationResult {
        guard let operationFactory else {
            throw PlainpostError.permissionDenied("The Node mutation capability is not configured.")
        }
        do {
            if let nodeSendJournal, let accountID {
                for retainedBytes in try nodeSendJournal.unresolvedSendOperations(accountID: accountID) {
                    let retained = try NodeSyncCodec.decodeOperation(retainedBytes)
                    guard case .send(let retainedDraftID, _) = retained.unsigned.operation else {
                        throw PlainpostError.validationFailed("The Node send journal contains an invalid operation.")
                    }
                    let result = try await apply(canonicalOperation: retainedBytes)
                    if case .send(let draft) = intent, draft.id.rawValue == retainedDraftID {
                        return result
                    }
                }
            }
            // A prior dispatch may have reached the Node without returning a
            // response. Settle its exact device-retained canonical operation
            // before signing this intent, so a recreated authority cannot
            // wedge the session or issue a duplicate with new idempotency
            // bytes.
            if nodeSendJournal == nil,
               let retained = try await client.reconcilePendingMutation(), retained.state != "applied" {
                throw Self.error(for: retained.state)
            }
            let operation = try await operationFactory(intent, idempotencyKey)
            return try await apply(canonicalOperation: operation)
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }

    private static func sendOutcome(for state: String) -> NodeSendOutcome? {
        switch state {
        case "pending": .pending
        case "applied": .applied
        case "rejected": .rejected
        case "conflicted": .conflicted
        case "delivery_uncertain": .deliveryUncertain
        default: nil
        }
    }

    private func rememberSuccessfulDraftSave(canonicalOperation: Data, state: String) async {
        guard state == "applied" else { return }
        await draftRevisions.recordApplied(canonicalOperation: canonicalOperation)
    }

    private static func error(for state: String) -> PlainpostError {
        switch state {
        case "conflicted":
            return .validationFailed("The Node mutation conflicted with durable mail state.")
        case "rejected":
            return .validationFailed("The Node rejected the mail mutation.")
        case "delivery_uncertain":
            return .validationFailed("The Node could not confirm mail delivery.")
        default:
            return .validationFailed("The Node returned an invalid mutation state.")
        }
    }
}

private actor NodeAttachmentService: MailAttachmentServing {
    let client: NodeSyncClient
    let scopedLogicalMailboxID: LogicalMailboxID?

    init(client: NodeSyncClient, scopedLogicalMailboxID: LogicalMailboxID?) {
        self.client = client
        self.scopedLogicalMailboxID = scopedLogicalMailboxID
    }

    func attachment(id: String) async throws -> MailAttachmentStream {
        do {
            let download: NodeSyncAttachmentDownload
            if let scopedLogicalMailboxID {
                download = try await client.mailAttachment(id: id, logicalMailboxID: scopedLogicalMailboxID)
            } else {
                download = try await client.attachment(id: id)
            }
            guard let metadata = download.metadata.map(NodeSyncCoreMapping.attachment) else {
                throw PlainpostError.validationFailed("Node attachment metadata was missing.")
            }
            return MailAttachmentStream(metadata: metadata, bytes: download.bytes)
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }
}

private actor NodeSearchService: MailSearchService {
    let client: NodeSyncClient
    let accountID: AccountID
    let scopedLogicalMailboxID: LogicalMailboxID?
    let parser = MailSearchQueryParser()

    init(client: NodeSyncClient, accountID: AccountID, scopedLogicalMailboxID: LogicalMailboxID?) {
        self.client = client
        self.accountID = accountID
        self.scopedLogicalMailboxID = scopedLogicalMailboxID
    }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        do {
            let parsed = try parser.parse(request)
            let requestedMailboxIDs = try request.scope.mailboxIDs.map { try NodeSyncCodec.decodeLogicalMailboxID($0.rawValue) }
            let mailboxIDs: [LogicalMailboxID]
            if let scopedLogicalMailboxID {
                // An empty filter would search the primary account on the
                // Node; a scoped authority always names exactly its own.
                guard requestedMailboxIDs.allSatisfy({ $0 == scopedLogicalMailboxID }) else {
                    throw PlainpostError.permissionDenied("Search is limited to this mail account.")
                }
                mailboxIDs = [scopedLogicalMailboxID]
            } else {
                mailboxIDs = requestedMailboxIDs.sorted { $0.rawValue.lexicographicallyPrecedes($1.rawValue) }
            }
            let page = try await client.search(
                after: request.cursor?.rawValue ?? "",
                limit: request.limit,
                logicalMailboxIDs: mailboxIDs,
                query: request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "*" : request.query
            )
            let hits = try page.messages.map { message -> MailSearchHit in
                let summary = try NodeSyncCoreMapping.message(message)
                let snippet = try MailSearchSnippet(text: summary.preview, highlights: [])
                switch request.mode {
                case .messages:
                    return .message(MailMessageSearchHit(
                        stableID: MailSearchStableIdentity.message(accountID: accountID, messageID: summary.id),
                        messageID: summary.id,
                        threadID: summary.threadID ?? ThreadID(summary.id.rawValue),
                        accountID: accountID,
                        sender: summary.from,
                        senderDisplayName: summary.fromDisplayName,
                        recipients: summary.to,
                        subject: summary.subject,
                        sentAt: summary.sentAt,
                        snippet: snippet,
                        isUnread: !summary.isSeen,
                        isFlagged: summary.labels.contains("FLAGGED"),
                        isDelegated: false,
                        mailboxIDs: request.scope.mailboxIDs,
                        hasAttachments: !message.attachments.isEmpty,
                        hasDocuments: false
                    ))
                case .conversations:
                    let threadID = summary.threadID ?? ThreadID(summary.id.rawValue)
                    return .conversation(MailConversationSearchHit(
                        stableID: MailSearchStableIdentity.thread(accountID: accountID, threadID: threadID),
                        threadID: threadID,
                        accountID: accountID,
                        bestMatchingMessageID: summary.id,
                        subject: summary.subject,
                        participants: summary.to.map(\.rawValue) + [summary.from.rawValue],
                        latestActivity: summary.sentAt,
                        snippet: snippet,
                        matchingMessageCount: 1,
                        totalMessageCount: 1,
                        unreadMessageCount: summary.isSeen ? 0 : 1,
                        hasAttachments: !message.attachments.isEmpty,
                        hasDocuments: false,
                        bestMatchSender: summary.from,
                        bestMatchSenderDisplayName: summary.fromDisplayName
                    ))
                }
            }
            return MailSearchResponse(
                parsedQuery: parsed,
                mode: request.mode,
                scope: request.scope,
                hits: hits,
                nextCursor: page.nextCursor.isEmpty ? nil : MailSearchCursor(rawValue: page.nextCursor),
                indexRevision: page.revision
            )
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }

    func suggestions(_ request: MailSearchSuggestionRequest) async throws -> [MailSearchSuggestionSection] {
        []
    }

    func indexState() async -> MailSearchIndexState { .ready }

    func rebuildIndex() async throws { throw MailSearchError.unavailable }

    func performMaintenanceIfDue(now: Date) async throws {}
}

enum NodeSyncCoreMapping {
    static func message(_ value: NodeSyncMessage) throws -> MessageSummary {
        guard let from = value.from.first else { throw PlainpostError.notFound("Node message has no sender.") }
        let body = value.textBody.value ?? ""
        let preview = body.isEmpty ? value.subject : body
        return MessageSummary(
            id: MessageID(value.id),
            threadID: ThreadID(value.threadID),
            from: EmailAddress(from.mailbox),
            fromDisplayName: from.displayName,
            subject: value.subject,
            preview: preview,
            smartCategory: .unknown,
            labels: value.labels,
            isSeen: value.flags.contains("seen"),
            mailboxPath: "INBOX",
            isDeleted: value.flags.contains("deleted"),
            body: body,
            bodyHTML: value.htmlBody.value,
            sentAt: parseDate(value.sentAt ?? value.receivedAt),
            rfcMessageID: value.references.first,
            inReplyTo: value.inReplyTo.first,
            references: value.references,
            replyTo: value.replyTo.first.map { EmailAddress($0.mailbox) },
            to: value.to.map { EmailAddress($0.mailbox) },
            cc: value.cc.map { EmailAddress($0.mailbox) },
            attachments: value.attachments.map(attachment)
        )
    }

    static func attachment(_ value: NodeSyncAttachment) -> MailAttachment {
        MailAttachment(id: value.id, filename: value.filename, mimeType: value.mime, disposition: value.disposition, byteCount: Int(value.size) ?? 0, contentDigest: value.contentDigest)
    }

    static func error(_ error: NodeSyncClientError) -> Error {
        switch error {
        case .cancelled: return CancellationError()
        case .notFound: return PlainpostError.notFound("Node resource was not found.")
        case .conflict, .problem(.staleCursor): return PlainpostError.validationFailed("The Node session or cursor is stale.")
        case .problem(.unauthorized): return PlainpostError.permissionDenied("The Node session is not authorized.")
        case .problem(.invalidRequest), .problem(.conflict), .invalidResponse: return PlainpostError.validationFailed("The Node response was invalid.")
        case .problem(.unavailable), .transport, .transportAfterDispatch, .cancelledAfterDispatch: return PlainpostError.validationFailed("The Node is unavailable.")
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
