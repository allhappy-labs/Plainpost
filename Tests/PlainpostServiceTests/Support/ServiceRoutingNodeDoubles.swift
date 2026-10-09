import Foundation
import PlainpostAccountProtocol
import PlainpostNodeMailMode
@testable import PlainpostNodeTransport

/// Supplies a `NodeSyncClient` over `RecordingNodeMutationSender` for the
/// service's router, the way the reachability supervisor will (Task 17).
final class StubNodeMailSessionProvider: NodeMailSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let client: NodeSyncClient
    private let nodeID: String
    private var reachable = true

    init(sender: RecordingNodeMutationSender, nodeID: String) {
        client = NodeSyncClient(sender: sender)
        self.nodeID = nodeID
    }

    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }

    func reachableClient(nodeID: String) async -> NodeSyncClient? {
        lock.withLock { reachable && nodeID == self.nodeID ? client : nil }
    }
}

/// A minimal Sync Node for the service routing tests: it lists the
/// Node-backed accounts (with inbox and drafts assignments and an authority
/// epoch), answers draft state, and answers `/v1/mutations` with a canonical
/// receipt. Like the Node it dedupes by idempotency key. It signs like the
/// session transport, and in read-only mode refuses to sign as a lease-only
/// broker session does.
actor RecordingNodeMutationSender: NodeSessionRequestSending, NodeMutationOperationSigning, NodeAuthorityEpochUpdating {
    struct Listed: Sendable {
        let logicalMailboxID: LogicalMailboxID
        let providerIdentity: String
    }

    private let listed: [Listed]
    private nonisolated let signer: RoutingTestSigner
    private var receipts: [String: String] = [:]
    private var keys: [String] = []
    private var kinds: [String] = []
    private var posts = 0
    private var draftRevisions: [String: UInt64] = [:]
    private var nextState = "applied"
    private static let url = URL(string: "https://node.example.ts.net:443")!

    init(listed: [Listed], nodeID: String, readOnly: Bool = false) {
        self.listed = listed
        signer = RoutingTestSigner(readOnly: readOnly, nodeID: nodeID)
    }

    /// Distinct operations the Node accepted.
    var mutationCount: Int { keys.count }
    var mutationPostCount: Int { posts }
    var idempotencyKeys: [String] { keys }
    var mutationKinds: [String] { kinds }
    func answerNewMutations(with state: String) { nextState = state }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        switch (method, path) {
        case ("GET", "/v1/mail/accounts"):
            let accounts = try listed.enumerated().map { index, account in
                try NodeSyncMailAccount(
                    assignments: [
                        NodeSyncDiscoveredMailbox(displayName: "Inbox", logicalMailboxID: account.logicalMailboxID, mailboxHandle: "INBOX",
                                                  role: "inbox", authorityEpoch: "1"),
                        NodeSyncDiscoveredMailbox(displayName: "Drafts", logicalMailboxID: account.logicalMailboxID, mailboxHandle: "Drafts",
                                                  role: "drafts", authorityEpoch: "1"),
                    ],
                    logicalMailboxID: account.logicalMailboxID, primary: index == 0,
                    providerIdentity: account.providerIdentity, providerKind: "gmail", state: .ready)
            }
            return ok(try NodeSyncMailModeCodec.encodeMailAccountsResult(
                NodeSyncMailAccountsResult(accounts: accounts, primaryState: accounts.isEmpty ? .none : .available)))
        case ("GET", _) where path.hasPrefix("/v1/drafts/"):
            let draftID = String(path.dropFirst("/v1/drafts/".count))
            guard let revision = draftRevisions[draftID] else {
                return NodeHTTPResponse(statusCode: 404, url: Self.url, headers: [:], body: Data())
            }
            return ok(try NodeSyncCodec.encodeDraftState(NodeSyncDraftState(draftID: draftID, revision: String(revision), state: "appended")))
        case ("POST", "/v1/mutations"):
            posts += 1
            let canonical = try NodeSyncCodec.decodeMutationRequest(body).canonicalOperation
            let operation = try NodeSyncCodec.decodeOperation(canonical)
            let key = operation.unsigned.idempotencyKey
            let state: String
            if let stored = receipts[key] {
                state = stored
            } else {
                state = nextState
                receipts[key] = state
                keys.append(key)
                kinds.append(Self.kind(operation.unsigned.operation))
                if case let .saveDraft(draftID, _, _, _) = operation.unsigned.operation, state == "applied" {
                    draftRevisions[draftID, default: 0] += 2
                }
            }
            return ok(try NodeSyncCodec.encodeMutationResult(NodeSyncMutationResult(idempotencyKey: key, state: state)))
        default:
            return NodeHTTPResponse(statusCode: 404, url: Self.url, headers: [:], body: Data())
        }
    }

    nonisolated func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        signer.setAuthorityEpoch(epoch, for: logicalMailboxID)
    }

    nonisolated func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        try signer.sign(variant: variant, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey, issuedAt: issuedAt)
    }

    private func ok(_ body: Data) -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 200, url: Self.url, headers: [:], body: body)
    }

    private static func kind(_ variant: NodeSyncOperationVariant) -> String {
        switch variant {
        case .saveDraft: "save_draft"
        case .deleteDraft: "delete_draft"
        case .send: "send"
        case let .setRead(_, read): read ? "set_read" : "set_unread"
        case .archive: "archive"
        case .delete: "delete"
        case .setLabels: "set_labels"
        case let .setFlagged(_, flagged): flagged ? "set_flagged" : "set_unflagged"
        case .move: "move"
        }
    }
}

final class RoutingTestSigner: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [LogicalMailboxID: String] = [:]
    private let readOnly: Bool
    private let nodeID: String

    init(readOnly: Bool, nodeID: String) {
        self.readOnly = readOnly
        self.nodeID = nodeID
    }

    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) {
        lock.withLock { epochs[logicalMailboxID] = epoch }
    }

    func sign(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        // A lease-only broker session refuses to sign any mutation.
        if readOnly { throw NodeSessionBrokerError.readOnly }
        guard let epoch = lock.withLock({ epochs[logicalMailboxID] }) else { throw NodeSyncClientError.invalidResponse }
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "00112233-4455-6677-8899-aabbccddeeff", authorityEpoch: epoch,
            clientID: "11111111-2222-3333-8444-555555555555", idempotencyKey: idempotencyKey,
            issuedAt: issuedAt, logicalMailboxID: logicalMailboxID,
            nodeID: nodeID, operation: variant, trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)))
    }
}
