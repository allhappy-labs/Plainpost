import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

// Deterministic in-memory Sync Nodes for the account-scoped mail authority
// tests. Responses are encoded with the production codecs. The signer behaves
// like `NodeSessionTransport`: it signs only for a logical mailbox whose
// authority epoch an authenticated assignments/accounts response installed.
//
// Pre-approved copy (controller ruling C7) of
// `Tests/PlainpostAccountRuntimeTests/Support/NodeMailTestSenders.swift`:
// the Xcode iOS test bundle cannot link SwiftPM test targets. Types carry a
// `Mobile` prefix and import PlainpostNodeTransport non-testably; behavior is
// identical. Change both copies together.

struct MobileNodeMailTestRequest: Equatable, Sendable {
    let method: String
    let path: String
    let body: Data
}

enum MobileNodeMailTestSenderError: Error, Equatable {
    case missingAuthorityEpoch
    case noMutation
}

/// A multi-account Node: `ada@example.test` (primary, logical mailbox 0x01…)
/// and `grace@example.test` (secondary, logical mailbox 0x02…, namespaced
/// `gm2.` message IDs).
actor MobileTwoAccountNodeSender: NodeSessionRequestSending, NodeMutationOperationSigning, NodeAuthorityEpochUpdating {
    static let adaLogicalMailboxID = LogicalMailboxID(rawValue: Data(repeating: 1, count: 32))!
    static let graceLogicalMailboxID = LogicalMailboxID(rawValue: Data(repeating: 2, count: 32))!

    private var backend: MobileNodeMailTestBackend
    private nonisolated let signer = MobileNodeMailTestSigner()

    init(graceState: NodeSyncMailAccountState = .ready, graceHasDrafts: Bool = true) {
        backend = MobileNodeMailTestBackend(multiAccount: true, accounts: [
            MobileNodeMailTestAccount(
                logicalMailboxID: Self.adaLogicalMailboxID, identity: "ada@example.test", kind: "gmail",
                primary: true, state: .ready, authorityEpoch: "7", hasDrafts: true
            ),
            MobileNodeMailTestAccount(
                logicalMailboxID: Self.graceLogicalMailboxID, identity: "grace@example.test", kind: "gmail",
                primary: false, state: graceState, authorityEpoch: "3", hasDrafts: graceHasDrafts
            ),
        ])
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        try backend.handle(method: method, path: path, body: body)
    }

    nonisolated func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        signer.setAuthorityEpoch(epoch, for: logicalMailboxID)
    }

    nonisolated func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        try signer.sign(variant: variant, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey, issuedAt: issuedAt)
    }

    func requests() -> [MobileNodeMailTestRequest] { backend.requests }
    func mutationLogicalMailboxIDs() -> [LogicalMailboxID] { backend.mutationLogicalMailboxIDs }
    func lastMutationLogicalMailboxID() throws -> LogicalMailboxID {
        guard let last = backend.mutationLogicalMailboxIDs.last else { throw MobileNodeMailTestSenderError.noMutation }
        return last
    }
    func draftStateReads(_ draftID: String) -> Int { backend.draftStateReads[draftID, default: 0] }
    func setState(_ state: NodeSyncMailAccountState, for logicalMailboxID: LogicalMailboxID) { backend.setState(state, for: logicalMailboxID) }
    /// Removes an account; removing the primary promotes the next account, as the Node does.
    func removeAccount(_ logicalMailboxID: LogicalMailboxID) { backend.removeAccount(logicalMailboxID) }
}

/// An older Node without the mail-mode routes (`/v1/mail/*` answer 404). Its
/// legacy routes project one Gmail account on logical mailbox 0x01….
actor MobileLegacySingleAccountNodeSender: NodeSessionRequestSending, NodeMutationOperationSigning, NodeAuthorityEpochUpdating {
    static let logicalMailboxID = LogicalMailboxID(rawValue: Data(repeating: 1, count: 32))!

    private var backend: MobileNodeMailTestBackend
    private nonisolated let signer = MobileNodeMailTestSigner()

    init(identity: String) {
        backend = MobileNodeMailTestBackend(multiAccount: false, accounts: [
            MobileNodeMailTestAccount(
                logicalMailboxID: Self.logicalMailboxID, identity: identity, kind: "gmail",
                primary: true, state: .ready, authorityEpoch: "5", hasDrafts: true
            ),
        ])
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        try backend.handle(method: method, path: path, body: body)
    }

    nonisolated func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        signer.setAuthorityEpoch(epoch, for: logicalMailboxID)
    }

    nonisolated func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        try signer.sign(variant: variant, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey, issuedAt: issuedAt)
    }

    func requests() -> [MobileNodeMailTestRequest] { backend.requests }
    func lastMutationLogicalMailboxID() throws -> LogicalMailboxID {
        guard let last = backend.mutationLogicalMailboxIDs.last else { throw MobileNodeMailTestSenderError.noMutation }
        return last
    }
}

struct MobileNodeMailTestAccount: Sendable {
    let logicalMailboxID: LogicalMailboxID
    let identity: String
    let kind: String
    var primary: Bool
    var state: NodeSyncMailAccountState
    let authorityEpoch: String
    let hasDrafts: Bool

    func assignments() throws -> [NodeSyncDiscoveredMailbox] {
        var result = [try NodeSyncDiscoveredMailbox(
            displayName: "Inbox", logicalMailboxID: logicalMailboxID, mailboxHandle: "INBOX", role: "inbox", authorityEpoch: authorityEpoch
        )]
        if hasDrafts {
            result.append(try NodeSyncDiscoveredMailbox(
                displayName: "Drafts", logicalMailboxID: logicalMailboxID, mailboxHandle: "[Gmail]/Drafts", role: "drafts", authorityEpoch: authorityEpoch
            ))
        }
        return result
    }
}

final class MobileNodeMailTestSigner: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [LogicalMailboxID: String] = [:]

    /// Monotonic, like `NodeSessionTransport`.
    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) {
        lock.lock(); defer { lock.unlock() }
        if let installed = epochs[logicalMailboxID].flatMap(UInt64.init), let incoming = UInt64(epoch), installed >= incoming { return }
        epochs[logicalMailboxID] = epoch
    }

    func sign(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        lock.lock()
        let epoch = epochs[logicalMailboxID]
        lock.unlock()
        guard let epoch else { throw MobileNodeMailTestSenderError.missingAuthorityEpoch }
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "00112233-4455-6677-8899-aabbccddeeff", authorityEpoch: epoch,
            clientID: "11111111-2222-3333-8444-555555555555", idempotencyKey: idempotencyKey,
            issuedAt: issuedAt, logicalMailboxID: logicalMailboxID,
            nodeID: "aaaaaaaa-bbbb-cccc-8ddd-eeeeeeeeeeee", operation: variant, trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)))
    }
}

struct MobileNodeMailTestBackend: Sendable {
    let multiAccount: Bool
    private(set) var accounts: [MobileNodeMailTestAccount]
    private(set) var requests: [MobileNodeMailTestRequest] = []
    private(set) var mutationLogicalMailboxIDs: [LogicalMailboxID] = []
    private(set) var draftStateReads: [String: Int] = [:]
    private var draftRevisions: [String: UInt64] = [:]
    private let url = URL(string: "https://node.example.ts.net:443")!

    init(multiAccount: Bool, accounts: [MobileNodeMailTestAccount]) {
        self.multiAccount = multiAccount
        self.accounts = accounts
    }

    mutating func setState(_ state: NodeSyncMailAccountState, for logicalMailboxID: LogicalMailboxID) {
        guard let index = accounts.firstIndex(where: { $0.logicalMailboxID == logicalMailboxID }) else { return }
        accounts[index].state = state
    }

    mutating func removeAccount(_ logicalMailboxID: LogicalMailboxID) {
        guard let index = accounts.firstIndex(where: { $0.logicalMailboxID == logicalMailboxID }) else { return }
        let removed = accounts.remove(at: index)
        if removed.primary, !accounts.isEmpty { accounts[0].primary = true }
    }

    mutating func handle(method: String, path: String, body: Data) throws -> NodeHTTPResponse {
        requests.append(MobileNodeMailTestRequest(method: method, path: path, body: body))
        if path.hasPrefix("/v1/mail/") && !multiAccount { return response(404, Data()) }
        switch path {
        case "/v1/mail/capabilities":
            return response(200, try NodeSyncMailModeCodec.encodeMailCapabilities(NodeSyncMailCapabilities(
                googleImport: true, imapImport: true, mirrorCoordinates: true, multiAccount: true
            )))
        case "/v1/mail/accounts":
            let listed = try accounts.map {
                try NodeSyncMailAccount(
                    assignments: try $0.assignments(), logicalMailboxID: $0.logicalMailboxID, primary: $0.primary,
                    providerIdentity: $0.identity, providerKind: $0.kind, state: $0.state
                )
            }
            let result = try NodeSyncMailAccountsResult(accounts: listed, primaryState: listed.isEmpty ? .none : .available)
            return response(200, try NodeSyncMailModeCodec.encodeMailAccountsResult(result))
        case "/v1/mail/snapshot":
            let request = try NodeSyncMailModeCodec.decodeAccountSnapshotRequest(body)
            guard account(request.logicalMailboxID) != nil else { return try problem(403, .unauthorized) }
            return response(200, try NodeSyncCodec.encodeSnapshotPage(try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "1")))
        case "/v1/snapshot":
            _ = try NodeSyncCodec.decodeSnapshotRequest(body)
            return response(200, try NodeSyncCodec.encodeSnapshotPage(try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "1")))
        case "/v1/search":
            let request = try NodeSyncCodec.decodeSearchRequest(body)
            guard request.logicalMailboxIDs.allSatisfy({ account($0) != nil }) else { return try problem(403, .unauthorized) }
            return response(200, try NodeSyncCodec.encodeSearchPage(try NodeSyncSearchPage(messages: [], nextCursor: "", revision: "1")))
        case "/v1/status":
            let primary = accounts.first(where: \.primary)
            let status = try NodeSyncStatusResult(
                revision: "1", state: primary == nil ? "unavailable" : "ready", version: "node-sync-v1",
                reachability: "reachable", syncLag: "0", storage: "managed", providerIdentity: primary?.identity,
                assignments: try primary?.assignments() ?? [], backup: "not_reported", endpoint: "session-scoped",
                updateStatus: "current"
            )
            return response(200, try NodeSyncCodec.encodeStatusResult(status))
        case "/v1/mailboxes/assignments":
            let assignments = try accounts.first(where: \.primary)?.assignments() ?? []
            return response(200, try NodeSyncCodec.encodeMailboxAssignmentsResult(try NodeSyncMailboxAssignmentsResult(assignments: assignments)))
        case "/v1/mutations":
            let operation = try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest(body).canonicalOperation)
            guard let owner = account(operation.unsigned.logicalMailboxID),
                  owner.authorityEpoch == operation.unsigned.authorityEpoch else { return try problem(403, .unauthorized) }
            mutationLogicalMailboxIDs.append(operation.unsigned.logicalMailboxID)
            if case let .saveDraft(draftID, expectedRevision, _, _) = operation.unsigned.operation, let expected = UInt64(expectedRevision) {
                draftRevisions[draftID] = expected + 2
            }
            let result = try NodeSyncMutationResult(idempotencyKey: operation.unsigned.idempotencyKey, state: "applied")
            return response(200, try NodeSyncCodec.encodeMutationResult(result))
        case let path where path.hasPrefix("/v1/drafts/"):
            let draftID = String(path.dropFirst("/v1/drafts/".count))
            draftStateReads[draftID, default: 0] += 1
            let revision = draftRevisions[draftID] ?? 0
            let state = try NodeSyncDraftState(draftID: draftID, revision: String(revision), state: revision == 0 ? "local" : "appended")
            return response(200, try NodeSyncCodec.encodeDraftState(state))
        default:
            return response(404, Data())
        }
    }

    private func account(_ logicalMailboxID: LogicalMailboxID) -> MobileNodeMailTestAccount? {
        accounts.first { $0.logicalMailboxID == logicalMailboxID }
    }

    private func response(_ statusCode: Int, _ body: Data) -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: statusCode, url: url, headers: [:], body: body)
    }

    private func problem(_ statusCode: Int, _ category: NodeSyncProblem) throws -> NodeHTTPResponse {
        response(statusCode, try NodeSyncCodec.encodeProblem(NodeSyncProblemResult(category: category)))
    }
}
