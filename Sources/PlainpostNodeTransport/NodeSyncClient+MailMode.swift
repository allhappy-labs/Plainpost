import Foundation
import PlainpostAccountProtocol

/// Additive `/v1/mail/*` routes. Reads retry like the legacy read routes.
/// Credential-bearing and provider-changing requests use `providerRequest`,
/// which dispatches exactly once, so a secret-bearing body is never replayed
/// automatically under new request signing.
public extension NodeSyncClient {
    func mailCapabilities() async throws -> NodeSyncMailCapabilities {
        let response = try await execute(method: "GET", path: "/v1/mail/capabilities", body: Data(), retryable: true)
        return try NodeSyncMailModeCodec.decodeMailCapabilities(response.body)
    }

    /// Every provider account of the session's Plainpost account. Like
    /// `mailboxAssignments()`, it installs each account's authenticated
    /// authority epoch so mutations can be signed for any listed account.
    func mailAccounts() async throws -> NodeSyncMailAccountsResult {
        let response = try await execute(method: "GET", path: "/v1/mail/accounts", body: Data(), retryable: true)
        let result = try NodeSyncMailModeCodec.decodeMailAccountsResult(response.body)
        try installAuthorityEpochs(from: result.accounts.flatMap(\.assignments))
        return result
    }

    /// One message, only when it belongs to `logicalMailboxID`. The Node
    /// answers 404 (`notFound`) for a message of another provider account
    /// exactly as for an unknown one, so a scoped authority never shows or
    /// acts on another account's mail. Retries like the legacy read.
    func mailMessage(id: String, logicalMailboxID: LogicalMailboxID) async throws -> NodeSyncMessage {
        let request = try NodeSyncMessageRequest(messageID: id)
        let path = "/v1/mail/messages/" + (try NodeSyncCodec.encodeLogicalMailboxID(logicalMailboxID)) + "/" + (try messagePathToken(request.messageID))
        let response = try await execute(method: "GET", path: path, body: Data(), retryable: true)
        return try NodeSyncCodec.decodeMessageResult(response.body).message
    }

    /// One attachment, only when its message belongs to `logicalMailboxID`;
    /// otherwise 404 (`notFound`), as for an unknown capability.
    func mailAttachment(id: String, logicalMailboxID: LogicalMailboxID, metadata: NodeSyncAttachment? = nil) async throws -> NodeSyncAttachmentDownload {
        let request = try NodeSyncAttachmentRequest(attachmentID: id)
        let prefix = "/v1/mail/attachments/" + (try NodeSyncCodec.encodeLogicalMailboxID(logicalMailboxID)) + "/"
        return try await attachment(id: id, metadata: metadata, path: try pathSegment(prefix, request.attachmentID))
    }

    func importGoogleToken(_ request: NodeSyncGoogleTokenImportRequest) async throws -> NodeSyncProviderImportResult {
        let response = try await providerRequest(path: "/v1/mail/providers/google/import", body: NodeSyncMailModeCodec.encodeGoogleTokenImportRequest(request))
        return try NodeSyncMailModeCodec.decodeProviderImportResult(response.body)
    }

    func importIMAPProvider(_ request: NodeSyncIMAPProviderImportRequest) async throws -> NodeSyncProviderImportResult {
        let response = try await providerRequest(path: "/v1/mail/providers/imap/import", body: NodeSyncMailModeCodec.encodeIMAPProviderImportRequest(request))
        return try NodeSyncMailModeCodec.decodeProviderImportResult(response.body)
    }

    func removeProvider(_ request: NodeSyncProviderRemoveRequest) async throws -> NodeSyncProviderRemoveResult {
        let response = try await providerRequest(path: "/v1/mail/providers/remove", body: NodeSyncMailModeCodec.encodeProviderRemoveRequest(request))
        return try NodeSyncMailModeCodec.decodeProviderRemoveResult(response.body)
    }

    func mirrorCoordinates(messageIDs: [String]) async throws -> NodeSyncMirrorCoordinatesResult {
        let request = try NodeSyncMirrorCoordinatesRequest(messageIDs: messageIDs)
        let response = try await execute(method: "POST", path: "/v1/mail/mirror/coordinates", body: NodeSyncMailModeCodec.encodeMirrorCoordinatesRequest(request), retryable: true)
        return try NodeSyncMailModeCodec.decodeMirrorCoordinatesResult(response.body)
    }

    /// One account's snapshot page; the cursor is bound to that account.
    func mailSnapshot(_ request: NodeSyncAccountSnapshotRequest) async throws -> NodeSyncSnapshotPage {
        let response = try await execute(method: "POST", path: "/v1/mail/snapshot", body: NodeSyncMailModeCodec.encodeAccountSnapshotRequest(request), retryable: true)
        return try NodeSyncCodec.decodeSnapshotPage(response.body)
    }

    /// Changes of every account; each change carries its logical mailbox.
    /// Accounts still waiting for their first import are listed separately.
    /// On `stale_cursor`, recover in order: bootstrap with `after: ""`, then
    /// `mailSnapshot` every non-waiting account from `mailAccounts()`, then
    /// continue from the fresh cursor. Snapshotting only the account that
    /// finished its first import loses other accounts' changes.
    func mailDeltas(after cursor: String, limit: Int) async throws -> NodeSyncMailDeltaPage {
        guard (1...Int(NodeSyncLimits.maximumPageSize)).contains(limit) else { throw NodeSyncClientError.invalidResponse }
        let request = try NodeSyncDeltaRequest(after: cursor, limit: UInt16(limit))
        let response = try await execute(method: "POST", path: "/v1/mail/deltas", body: NodeSyncCodec.encodeDeltaRequest(request), retryable: true)
        return try NodeSyncMailModeCodec.decodeMailDeltaPage(response.body)
    }
}
