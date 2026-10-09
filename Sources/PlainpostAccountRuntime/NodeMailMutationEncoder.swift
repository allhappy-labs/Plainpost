import Foundation
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostNodeTransport

/// Encodes and signs one mail intent as a node-sync operation for an explicit
/// logical mailbox. The signature binds that logical mailbox; the encoder
/// never chooses another one. Before signing it proves, from an authenticated
/// read, that the logical mailbox is an account of this session (and, for
/// drafts, that the account has a drafts mailbox), which also installs the
/// account's authority epoch for the session signer.
///
/// It owns the draft-local CAS revisions, keyed by logical mailbox and draft.
/// Callers that dispatch operations themselves report applied operations with
/// `recordApplied(canonicalOperation:)`.
public actor NodeMailMutationEncoder {
    /// How `operation` proves the logical mailbox before signing.
    enum Resolution: Sendable {
        /// `/v1/mail/accounts`, falling back to the legacy assignments read
        /// model when an older Node answers 404.
        case automatic
        /// `/v1/mail/accounts` only.
        case accountCatalog
        /// Legacy `/v1/mailboxes/assignments` only.
        case legacyAssignments
        /// The caller already resolved the logical mailbox from an
        /// authenticated assignments read in this session.
        case resolved
    }

    private let client: NodeSyncClient
    nonisolated let draftRevisions: NodeDraftRevisionLedger

    public init(client: NodeSyncClient) {
        self.init(client: client, draftRevisions: NodeDraftRevisionLedger())
    }

    init(client: NodeSyncClient, draftRevisions: NodeDraftRevisionLedger) {
        self.client = client
        self.draftRevisions = draftRevisions
    }

    public func operation(for intent: MailMutationIntent, logicalMailboxID: LogicalMailboxID, idempotencyKey: String) async throws -> Data {
        try await operation(for: intent, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey, resolution: .automatic)
    }

    /// Signs a send of `draftID` at exactly `expectedRevision`, the revision
    /// the approved draft save produced, instead of the Node's current one.
    /// If the draft changed on the Node since (another device edited it), the
    /// Node's revision check answers `conflicted` and nothing is sent.
    public func sendOperation(
        draftID: DraftID, expectedRevision: String, logicalMailboxID: LogicalMailboxID, idempotencyKey: String
    ) async throws -> Data {
        guard UInt64(expectedRevision) != nil else { throw PlainpostError.validationFailed("Invalid draft revision.") }
        let accounts: NodeSyncMailAccountsResult
        do {
            accounts = try await client.mailAccounts()
        } catch NodeSyncClientError.notFound {
            try Self.requireOwned(logicalMailboxID, role: "drafts", in: try await client.mailboxAssignments().assignments)
            return try sign(.send(draftID: draftID.rawValue, expectedRevision: expectedRevision), logicalMailboxID, idempotencyKey)
        }
        try Self.requireOwned(logicalMailboxID, role: "drafts", in: accounts, admit: nil)
        return try sign(.send(draftID: draftID.rawValue, expectedRevision: expectedRevision), logicalMailboxID, idempotencyKey)
    }

    /// The Node draft revision an applied `save_draft` operation produces
    /// (append-pending, then provider-appended: expected + 2), as
    /// `NodeDraftRevisionLedger.recordApplied` computes it.
    public static func revisionAfterSave(canonicalOperation: Data) -> String? {
        guard let operation = try? NodeSyncCodec.decodeOperation(canonicalOperation),
              case let .saveDraft(_, expectedRevision, _, _) = operation.unsigned.operation,
              let expected = UInt64(expectedRevision)
        else { return nil }
        let (appended, overflow) = expected.addingReportingOverflow(2)
        return overflow ? nil : String(appended)
    }

    private func sign(_ variant: NodeSyncOperationVariant, _ logicalMailboxID: LogicalMailboxID, _ idempotencyKey: String) throws -> Data {
        do {
            return try client.signMutation(variant: variant, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey)
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }

    public func recordApplied(canonicalOperation: Data) async {
        await draftRevisions.recordApplied(canonicalOperation: canonicalOperation)
    }

    public func resetDraftRevisions() async {
        await draftRevisions.reset()
    }

    /// Called with the account's fresh catalog entry from the authenticated
    /// `/v1/mail/accounts` read, before anything is signed. Throwing refuses
    /// the mutation (for example, an account that now needs reauthorization).
    typealias CatalogAdmission = @Sendable (NodeMailAccount) throws -> Void

    func operation(
        for intent: MailMutationIntent,
        logicalMailboxID: LogicalMailboxID,
        idempotencyKey: String,
        resolution: Resolution,
        admitCatalogEntry: CatalogAdmission? = nil
    ) async throws -> Data {
        let requiredRole: String? = switch intent {
        case .saveDraft, .deleteDraft, .send: "drafts"
        case .setRead, .archive, .delete, .setLabels, .setFlagged, .move: nil
        }
        switch resolution {
        case .automatic:
            let accounts: NodeSyncMailAccountsResult
            do {
                accounts = try await client.mailAccounts()
            } catch NodeSyncClientError.notFound {
                try Self.requireOwned(logicalMailboxID, role: requiredRole, in: try await client.mailboxAssignments().assignments)
                break
            }
            try Self.requireOwned(logicalMailboxID, role: requiredRole, in: accounts, admit: admitCatalogEntry)
        case .accountCatalog:
            try Self.requireOwned(logicalMailboxID, role: requiredRole, in: try await client.mailAccounts(), admit: admitCatalogEntry)
        case .legacyAssignments:
            try Self.requireOwned(logicalMailboxID, role: requiredRole, in: try await client.mailboxAssignments().assignments)
        case .resolved:
            break
        }
        let variant = try await variant(for: intent, logicalMailboxID: logicalMailboxID)
        do {
            return try client.signMutation(variant: variant, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey)
        } catch let error as NodeSyncClientError {
            throw NodeSyncCoreMapping.error(error)
        }
    }

    private func variant(for intent: MailMutationIntent, logicalMailboxID: LogicalMailboxID) async throws -> NodeSyncOperationVariant {
        switch intent {
        case let .saveDraft(draft):
            // A retried save reuses its idempotency key, so these bytes must not
            // change between attempts: keep the Date header these saves always carried.
            let rendered = try DraftRenderer(dateHeader: DraftRenderer.stableSaveDateHeader).render(draft)
            let rfc5322 = Data("\(rendered.headers)\r\n\r\n\(rendered.body)".utf8)
            let draftID = draft.id.rawValue
            let expectedRevision: String
            if let cachedRevision = await draftRevisions.revision(for: draftID, in: logicalMailboxID) {
                expectedRevision = cachedRevision
            } else {
                do {
                    let state = try await client.draftState(id: draftID)
                    await draftRevisions.hydrate(draftID: draftID, in: logicalMailboxID, revision: state.revision)
                    expectedRevision = state.revision
                } catch NodeSyncClientError.notFound {
                    expectedRevision = "0"
                }
            }
            return .saveDraft(draftID: draftID, expectedRevision: expectedRevision, rfc5322: rfc5322, bcc: draft.bcc.map(\.rawValue))
        case let .send(draft):
            let state = try await client.draftState(id: draft.id.rawValue)
            await draftRevisions.hydrate(draftID: draft.id.rawValue, in: logicalMailboxID, revision: state.revision)
            return .send(draftID: draft.id.rawValue, expectedRevision: state.revision)
        case let .deleteDraft(draftID):
            // Deletion is authorized only for the revision this composer
            // saved. Refuse restored drafts without a known CAS head; reading
            // the latest revision alone could erase unseen remote edits.
            guard let savedRevision = await draftRevisions.revision(for: draftID.rawValue, in: logicalMailboxID) else {
                throw PlainpostError.validationFailed("Save this draft before deleting it from the Sync Node.")
            }
            let state = try await client.draftState(id: draftID.rawValue)
            guard state.state == "appended", UInt64(state.revision).map({ $0 > 0 }) == true else {
                throw PlainpostError.validationFailed("The Sync Node draft is not ready to delete.")
            }
            guard state.revision == savedRevision else {
                throw PlainpostError.validationFailed("This draft changed on another device. Reopen it before deleting.")
            }
            return .deleteDraft(draftID: draftID.rawValue, expectedRevision: savedRevision)
        case let .setRead(messageIDs, read):
            return .setRead(messageIDs: messageIDs.map(\.rawValue).sorted(), read: read)
        case let .archive(messageIDs):
            return .archive(messageIDs: messageIDs.map(\.rawValue).sorted())
        case let .delete(messageIDs):
            return .delete(messageIDs: messageIDs.map(\.rawValue).sorted())
        case let .setLabels(messageIDs, addLabelIDs, removeLabelIDs):
            return .setLabels(
                messageIDs: messageIDs.map(\.rawValue).sorted(),
                addLabelIDs: addLabelIDs.sorted(),
                removeLabelIDs: removeLabelIDs.sorted()
            )
        case let .setFlagged(messageIDs, flagged):
            return .setFlagged(messageIDs: messageIDs.map(\.rawValue).sorted(), flagged: flagged)
        case let .move(messageIDs, path):
            return .move(messageIDs: messageIDs.map(\.rawValue).sorted(), destinationMailboxPath: path)
        }
    }

    private static func requireOwned(_ logicalMailboxID: LogicalMailboxID, role: String?, in result: NodeSyncMailAccountsResult, admit: CatalogAdmission?) throws {
        guard let account = result.accounts.first(where: { $0.logicalMailboxID == logicalMailboxID }) else {
            throw PlainpostError.notFound("The Sync Node no longer lists this mail account.")
        }
        try admit?(NodeMailAccount(account))
        try requireOwned(logicalMailboxID, role: role, in: account.assignments)
    }

    private static func requireOwned(_ logicalMailboxID: LogicalMailboxID, role: String?, in assignments: [NodeSyncDiscoveredMailbox]) throws {
        let owned = assignments.filter { $0.logicalMailboxID == logicalMailboxID }
        guard !owned.isEmpty else {
            throw PlainpostError.notFound("Node mailbox assignment was unavailable.")
        }
        if let role, !owned.contains(where: { $0.role == role }) {
            throw PlainpostError.notFound("The mail account has no Sync Node \(role) mailbox.")
        }
    }
}

/// The Node draft state machine persists two revisions for each successful
/// save: append-pending, then provider-appended. Keep that draft-local CAS
/// head, per logical mailbox, instead of incorrectly using the account-wide
/// projection revision. This cache is process-local; a new process must
/// save/reconcile through the durable draft API before it can submit an
/// unknown draft.
internal actor NodeDraftRevisionLedger {
    private struct Key: Hashable {
        let logicalMailboxID: LogicalMailboxID
        let draftID: String
    }

    private var revisions: [Key: String] = [:]

    func revision(for draftID: String, in logicalMailboxID: LogicalMailboxID) -> String? {
        revisions[Key(logicalMailboxID: logicalMailboxID, draftID: draftID)]
    }

    func hydrate(draftID: String, in logicalMailboxID: LogicalMailboxID, revision: String) {
        guard let incoming = UInt64(revision) else { return }
        let key = Key(logicalMailboxID: logicalMailboxID, draftID: draftID)
        if let current = revisions[key].flatMap(UInt64.init), current >= incoming {
            return
        }
        revisions[key] = revision
    }

    /// Records the CAS head after an applied `save_draft` operation; other
    /// operations leave the ledger unchanged.
    func recordApplied(canonicalOperation: Data) {
        guard let operation = try? NodeSyncCodec.decodeOperation(canonicalOperation),
              case let .saveDraft(draftID, expectedRevision, _, _) = operation.unsigned.operation,
              let expected = UInt64(expectedRevision) else { return }
        let (pending, pendingOverflow) = expected.addingReportingOverflow(1)
        let (appended, appendedOverflow) = pending.addingReportingOverflow(1)
        guard !pendingOverflow, !appendedOverflow else { return }
        let key = Key(logicalMailboxID: operation.unsigned.logicalMailboxID, draftID: draftID)
        if let current = revisions[key].flatMap(UInt64.init), current >= appended {
            return
        }
        revisions[key] = String(appended)
    }

    func reset() {
        revisions.removeAll()
    }
}
