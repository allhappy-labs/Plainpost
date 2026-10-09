import Foundation
import PlainpostAccountProtocol

public protocol NodeSessionRequestSending: Sendable {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse
}

public protocol NodeSessionRequestScopedSending: NodeSessionRequestSending {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse
}

public protocol NodeSessionStreamingRequestSending: NodeSessionRequestSending {
    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse
}

/// A session sender that owns the device signing key may expose the
/// node-sync operation signer without exposing that key or the session
/// transport itself to UI code.
public protocol NodeMutationOperationSigning: Sendable {
    func signMutation(
        variant: NodeSyncOperationVariant,
        logicalMailboxID: LogicalMailboxID,
        idempotencyKey: String,
        issuedAt: String
    ) throws -> Data
}

/// A session transport can cache the authenticated authority epoch returned
/// by the assignment read model for later synchronous operation signing.
/// Authority epochs only increase per logical mailbox, so implementations
/// must install atomically and monotonically: an older epoch from a read that
/// completed late never replaces a newer one.
public protocol NodeAuthorityEpochUpdating: Sendable {
    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws
}

/// A durable session sender may retain an exact mutation after a response was
/// lost. Callers must reconcile that request before signing/dispatching a new
/// mutation, so a process restart cannot turn an ambiguous delivery into a
/// duplicate or strand the strict session sequence.
public protocol NodePendingMutationReconciling: Sendable {
    func reconcilePendingMutation() async throws -> NodeHTTPResponse?
}

/// A strict session may retain any authenticated request whose response was
/// ambiguous. Before a different request is sent, the owner must replay that
/// exact request through the same sequence and idempotency record.
public protocol NodePendingRequestReconciling: Sendable {
    func reconcilePendingRequest() async throws -> NodeHTTPResponse?
}

public enum NodeSyncClientError: Error, Equatable, Sendable {
    case cancelled
    case conflict
    case invalidResponse
    case notFound
    case problem(NodeSyncProblem)
    case transport
    case transportAfterDispatch
    case cancelledAfterDispatch
}

public struct NodeSyncAttachmentDownload: Sendable {
    public let metadata: NodeSyncAttachment?
    public let bytes: PlainpostByteStream

    public init(metadata: NodeSyncAttachment?, bytes: PlainpostByteStream) {
        self.metadata = metadata
        self.bytes = bytes
    }
}

/// The source-neutral client for the closed node-sync-v1 HTTP family.
/// Authentication, endpoint validation, and sequence handling remain owned by
/// the session sender; this type owns only canonical DTOs and retry policy.
public final class NodeSyncClient: @unchecked Sendable {
    /// Calendar requests retain the authenticated session boundary without exposing it.
    public func calendarClient() -> NodeCalendarClient { NodeCalendarClient(sender: sender) }
    private let sender: any NodeSessionRequestSending
    private let maximumAttempts: Int

    public init(sender: any NodeSessionRequestSending, maximumAttempts: Int = 2) {
        self.sender = sender
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public func snapshot(after cursor: String? = nil, limit: Int = 50) async throws -> NodeSyncSnapshotPage {
        let request = try NodeSyncSnapshotRequest(after: cursor ?? "", limit: try pageSize(limit))
        let response = try await execute(method: "POST", path: "/v1/snapshot", body: NodeSyncCodec.encodeSnapshotRequest(request), retryable: true)
        return try NodeSyncCodec.decodeSnapshotPage(response.body)
    }

    public func snapshot(_ request: NodeSyncSnapshotRequest) async throws -> NodeSyncSnapshotPage {
        let response = try await execute(method: "POST", path: "/v1/snapshot", body: NodeSyncCodec.encodeSnapshotRequest(request), retryable: true)
        return try NodeSyncCodec.decodeSnapshotPage(response.body)
    }

    public func delta(after cursor: String = "", limit: Int = 50) async throws -> NodeSyncDeltaPage {
        let request = try NodeSyncDeltaRequest(after: cursor, limit: try pageSize(limit))
        return try await delta(request)
    }

    public func delta(_ request: NodeSyncDeltaRequest) async throws -> NodeSyncDeltaPage {
        let response = try await execute(method: "POST", path: "/v1/deltas", body: NodeSyncCodec.encodeDeltaRequest(request), retryable: true)
        return try NodeSyncCodec.decodeDeltaPage(response.body)
    }

    public func search(after cursor: String, limit: Int, logicalMailboxIDs: [LogicalMailboxID], query: String) async throws -> NodeSyncSearchPage {
        let request = try NodeSyncSearchRequest(after: cursor, limit: try pageSize(limit), logicalMailboxIDs: logicalMailboxIDs, query: query)
        return try await search(request)
    }

    public func search(_ request: NodeSyncSearchRequest) async throws -> NodeSyncSearchPage {
        let response = try await execute(method: "POST", path: "/v1/search", body: NodeSyncCodec.encodeSearchRequest(request), retryable: true)
        return try NodeSyncCodec.decodeSearchPage(response.body)
    }

    public func message(id: String) async throws -> NodeSyncMessage {
        let request = try NodeSyncMessageRequest(messageID: id)
        let response = try await execute(method: "GET", path: try encodedMessagePath(request.messageID), body: Data(), retryable: true)
        return try NodeSyncCodec.decodeMessageResult(response.body).message
    }

    public func attachment(id: String, metadata: NodeSyncAttachment? = nil) async throws -> NodeSyncAttachmentDownload {
        let request = try NodeSyncAttachmentRequest(attachmentID: id)
        return try await attachment(id: id, metadata: metadata, path: try pathSegment("/v1/attachments/", request.attachmentID))
    }

    /// Streams one attachment through `path`, the legacy account-wide route or
    /// the mail-mode route scoped to one logical mailbox.
    func attachment(id: String, metadata: NodeSyncAttachment?, path: String) async throws -> NodeSyncAttachmentDownload {
        guard let streamingSender = sender as? any NodeSessionStreamingRequestSending else { throw NodeSyncClientError.transport }
        let response = try await executeStream(sender: streamingSender, method: "GET", path: path, body: Data())
        let declaredSize = response.headers.firstValue(for: "Content-Length").flatMap(Int.init)
        let responseMetadata = Self.attachmentMetadata(id: id, headers: response.headers)
        let effectiveMetadata: NodeSyncAttachment?
        do {
            effectiveMetadata = try Self.mergeAttachmentMetadata(provided: metadata, response: responseMetadata, id: id)
        } catch {
            response.bytes.cancel()
            throw error
        }
        // The returned stream is the consumer-facing cancellation boundary. It
        // must cancel both the pump task and the transport-owned response stream;
        // canceling only the pump can leave the underlying socket reading forever.
        let cancellation = NodeTaskCancellationBox(onCancel: response.bytes.cancel)
        let stream = PlainpostByteStream(capacity: 2, onCancellation: { cancellation.cancel() })
        let producer = stream.producer
        let transfer = Task {
            do {
                var count = 0
                for try await chunk in response.bytes {
                    guard chunk.count <= Self.maximumAttachmentBytes - count else { throw NodeSyncClientError.invalidResponse }
                    count += chunk.count
                    try await producer.send(chunk)
                }
                if let declaredSize, count != declaredSize { throw NodeSyncClientError.invalidResponse }
                producer.finish()
            } catch is CancellationError {
                producer.fail(CancellationError())
            } catch let error as NodeSyncClientError {
                producer.fail(error)
            } catch {
                producer.fail(NodeSyncClientError.transport)
            }
        }
        cancellation.set(transfer)
        return NodeSyncAttachmentDownload(metadata: effectiveMetadata, bytes: stream)
    }

    public func mutation(canonicalOperation: Data) async throws -> NodeSyncMutationResult {
        let request = try NodeSyncMutationRequest(canonicalOperation: canonicalOperation)
        let body = try NodeSyncCodec.encodeMutationRequest(request)
        if let recovered = try await reconcilePendingMutation(),
           let operation = try? NodeSyncCodec.decodeOperation(canonicalOperation),
           recovered.idempotencyKey == operation.unsigned.idempotencyKey {
            return recovered
        }
        let response = try await execute(method: "POST", path: "/v1/mutations", body: body, retryable: true)
        return try NodeSyncCodec.decodeMutationResult(response.body)
    }

    public func draftState(id: String) async throws -> NodeSyncDraftState {
        let request = try NodeSyncMessageRequest(messageID: id)
        let response = try await execute(method: "GET", path: try pathSegment("/v1/drafts/", request.messageID), body: Data(), retryable: true)
        return try NodeSyncCodec.decodeDraftState(response.body)
    }

    /// Settles a device-retained mutation before a new operation is admitted.
    /// The returned result is only informational to a caller creating a new
    /// operation; `mutation(canonicalOperation:)` returns it directly when
    /// its idempotency key proves this is the exact replay.
    public func reconcilePendingMutation() async throws -> NodeSyncMutationResult? {
        let response: NodeHTTPResponse?
        if sender is any NodePendingRequestReconciling {
            response = try await admitPendingRequest()
        } else if let reconciler = sender as? any NodePendingMutationReconciling {
            response = try await reconciler.reconcilePendingMutation()
        } else {
            return nil
        }
        guard let response else { return nil }
        guard (200...299).contains(response.statusCode) else { throw map(response) }
        guard let result = try? NodeSyncCodec.decodeMutationResult(response.body) else { return nil }
        return result
    }

    /// Reconciles a retained request of any route. The response is deliberately
    /// left as transport data because callers know the route they are about to
    /// resume; no new request may be admitted until this completes.
    public func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        try await admitPendingRequest()
    }

    public func signMutation(
        variant: NodeSyncOperationVariant,
        logicalMailboxID: LogicalMailboxID,
        idempotencyKey: String = UUID().uuidString.lowercased(),
        issuedAt: String? = nil
    ) throws -> Data {
        guard let signer = sender as? any NodeMutationOperationSigning else {
            throw NodeSyncClientError.transport
        }
        return try signer.signMutation(
            variant: variant,
            logicalMailboxID: logicalMailboxID,
            idempotencyKey: idempotencyKey,
            issuedAt: issuedAt ?? Self.timestamp(Date())
        )
    }

    public func status(cancellation: NodeHTTPTransportRequestCancellation? = nil) async throws -> NodeSyncStatusResult {
        let response = try await execute(
            method: "GET", path: "/v1/status",
            body: Data(), retryable: true, cancellation: cancellation
        )
        return try NodeSyncCodec.decodeStatusResult(response.body)
    }

    /// Requests a bounded wake of the Node-owned provider workers. The
    /// authenticated session sender remains responsible for account and
    /// sequence authority; no provider or mailbox identity crosses this API.
    public func requestProviderSync() async throws {
        let request = NodeSyncProviderSyncRequest()
        _ = try await execute(method: "POST", path: "/v1/provider-sync", body: try NodeSyncCodec.encodeProviderSyncRequest(request), retryable: true)
    }

    /// Transfers the current device's dedicated notification recipient
    /// authority through the already-authenticated Node session.
    public func applyNotificationRecipient(_ request: NodeSyncNotificationRecipientRequest) async throws -> NodeSyncNotificationRecipientResult {
        let response = try await execute(method: "PUT", path: "/v1/notifications/recipient", body: try NodeSyncCodec.encodeNotificationRecipientRequest(request), retryable: true)
        return try NodeSyncCodec.decodeNotificationRecipientResult(response.body)
    }

    /// Removes the authenticated device's Node recipient. The route derives
    /// account/device identity from the session principal, so no stale route
    /// coordinate can be supplied by the caller.
    public func removeNotificationRecipient() async throws {
        let request = NodeSyncNotificationRecipientRemovalRequest()
        _ = try await execute(method: "DELETE", path: "/v1/notifications/recipient", body: try NodeSyncCodec.encodeNotificationRecipientRemovalRequest(request), retryable: true)
    }

    public func notificationPolicy(for logicalMailboxID: LogicalMailboxID? = nil) async throws -> NodeSyncNotificationPolicy {
        let request = try NodeSyncNotificationPolicyReadRequest(logicalMailboxID: logicalMailboxID)
        let response = try await execute(method: "POST", path: "/v1/notifications/policy/read", body: try NodeSyncCodec.encodeNotificationPolicyReadRequest(request), retryable: true)
        return try NodeSyncCodec.decodeNotificationPolicy(response.body)
    }

    public func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        // Revalidate at the transport boundary as well as at construction so
        // a future Central bridge cannot send a version-zero bootstrap here.
        guard UInt64(request.expectedVersion).map({ (1...65_535).contains($0) }) ?? false else {
            throw NodeSyncClientError.invalidResponse
        }
        let response = try await execute(method: "PUT", path: "/v1/notifications/policy", body: try NodeSyncCodec.encodeNotificationPolicyUpdateRequest(request), retryable: true)
        return try NodeSyncCodec.decodeNotificationPolicy(response.body)
    }

    public func clearNotificationMailboxPolicy(_ logicalMailboxID: LogicalMailboxID, expectedVersion: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> NodeSyncNotificationPolicy {
        let request = try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: logicalMailboxID, clear: true, expectedVersion: expectedVersion, idempotencyKey: idempotencyKey)
        return try await updateNotificationPolicy(request)
    }

    public func backup() async throws -> NodeSyncOperationResult {
        let response = try await execute(method: "POST", path: "/v1/operations/backup", body: try NodeSyncCodec.encodeBackupRequest(), retryable: false)
        return try NodeSyncCodec.decodeOperationResult(response.body, expectedKind: "node-sync.backup-result.v1")
    }

    public func erase(confirmation: String) async throws -> NodeSyncOperationResult {
        let response = try await execute(method: "POST", path: "/v1/operations/erase", body: try NodeSyncCodec.encodeEraseRequest(confirmation: confirmation), retryable: false)
        return try NodeSyncCodec.decodeOperationResult(response.body, expectedKind: "node-sync.erase-result.v1")
    }

    public func mailboxAssignments() async throws -> NodeSyncMailboxAssignmentsResult {
        let response = try await execute(
            method: "GET", path: "/v1/mailboxes/assignments",
            body: Data(), retryable: true
        )
        let result = try NodeSyncCodec.decodeMailboxAssignmentsResult(response.body)
        try installAuthorityEpochs(from: result)
        return result
    }

    public func assignMailbox(_ request: NodeSyncMailboxAssignmentsRequest) async throws -> NodeSyncMailboxAssignmentsResult {
        let response = try await execute(
            method: "PUT", path: "/v1/mailboxes/assignments",
            body: NodeSyncCodec.encodeMailboxAssignmentsRequest(request), retryable: true
        )
        let result = try NodeSyncCodec.decodeMailboxAssignmentsResult(response.body)
        try installAuthorityEpochs(from: result)
        return result
    }

    private func installAuthorityEpochs(from result: NodeSyncMailboxAssignmentsResult) throws {
        try installAuthorityEpochs(from: result.assignments)
    }

    /// Installs the authenticated authority epochs of active assignments for
    /// later operation signing. Both the legacy assignments read model and the
    /// multi-account `/v1/mail/accounts` listing carry them.
    func installAuthorityEpochs(from assignments: [NodeSyncDiscoveredMailbox]) throws {
        guard let updater = sender as? any NodeAuthorityEpochUpdating else { return }
        for assignment in assignments {
            if let logicalMailboxID = assignment.logicalMailboxID, let authorityEpoch = assignment.authorityEpoch {
                try updater.setAuthorityEpoch(authorityEpoch, for: logicalMailboxID)
            }
        }
    }

    /// Sends the single-use provider authorization exchange without retrying
    /// the OAuth code. The Node owns all provider credentials and token
    /// persistence; this client receives only the bounded discovery result.
    public func configureGoogle(
        authorizationCode: String,
        clientID: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> NodeSyncGoogleProvisionResult {
        let request = try NodeSyncGoogleProvisionRequest(
            authorizationCode: authorizationCode,
            clientID: clientID,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
        let response = try await providerRequest(
            path: "/v1/providers/google",
            body: NodeSyncCodec.encodeGoogleProvisionRequest(request)
        )
        return try NodeSyncCodec.decodeGoogleProvisionResult(response.body)
    }

    /// A provider authorization code is single-use. This narrow hook lets the
    /// account-runtime provider controller send it exactly once without
    /// exposing the authenticated session sender or retrying the code.
    func providerRequest(path: String, body: Data) async throws -> NodeHTTPResponse {
        try Task.checkCancellation()
        do {
            let response = try await sender.send(
                method: "POST", path: path, body: body,
                maximumResponseBytes: NodeTLSClient.maximumResponseBytes
            )
            guard (200 ... 299).contains(response.statusCode) else {
                throw map(response)
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NodeSessionError where error == .transportFailureAfterDispatch {
            throw NodeSyncClientError.transportAfterDispatch
        } catch let error as NodeSessionError where error == .transportCancellationAfterDispatch {
            throw NodeSyncClientError.cancelledAfterDispatch
        } catch let error as NodeSyncClientError {
            throw error
        } catch let error as NodeSessionError where error == .authenticationRejected {
            throw NodeSyncClientError.problem(.unauthorized)
        } catch {
            throw NodeSyncClientError.transport
        }
    }

    private func pageSize(_ limit: Int) throws -> UInt16 {
        guard (1...Int(NodeSyncLimits.maximumPageSize)).contains(limit) else { throw NodeSyncClientError.invalidResponse }
        return UInt16(limit)
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: value.timeIntervalSince1970.rounded(.towardZero)))
    }

    private static let maximumAttachmentBytes = 50 * 1_048_576

    private func executeStream(sender: any NodeSessionStreamingRequestSending, method: String, path: String, body: Data) async throws -> NodeHTTPStreamResponse {
        _ = try await admitPendingRequest()
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let response = try await sender.stream(method: method, path: path, body: body, maximumResponseBytes: Self.maximumAttachmentBytes)
                guard (200...299).contains(response.statusCode) else {
                    response.bytes.cancel()
                    throw map(statusCode: response.statusCode)
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NodeSessionError where error == .transportFailureAfterDispatch {
                throw NodeSyncClientError.transportAfterDispatch
            } catch let error as NodeSessionError where error == .transportCancellationAfterDispatch {
                throw NodeSyncClientError.cancelledAfterDispatch
            } catch let error as NodeSessionError where error == .authenticationRejected {
                throw NodeSyncClientError.problem(.unauthorized)
            } catch let error as NodeSyncClientError {
                guard attempt + 1 < maximumAttempts, error.isRetryable else { throw error }
                attempt += 1
            } catch {
                guard attempt + 1 < maximumAttempts else { throw NodeSyncClientError.transport }
                attempt += 1
            }
        }
    }

    private static func attachmentMetadata(id: String, headers: [String: String]) -> NodeSyncAttachment? {
        guard let mime = headers.firstValue(for: "Content-Type"),
              let size = headers.firstValue(for: "Content-Length"),
              let sizeValue = Int(size), sizeValue >= 0, sizeValue <= maximumAttachmentBytes,
              let dispositionHeader = headers.firstValue(for: "Content-Disposition"),
              !dispositionHeader.isEmpty else { return nil }

        // Foundation owns RFC 6266/5987 parameter parsing, including quoted
        // Unicode and filename*. A response URL is a permitted fallback for
        // suggestedFilename, so use a separate no-header response to reject
        // that fallback while retaining Foundation's parser.
        let fallbackURL = URL(string: "https://plainpost.invalid/__plainpost_missing_filename__")!
        guard let response = HTTPURLResponse(url: fallbackURL, statusCode: 200, httpVersion: nil, headerFields: headers),
              let disposition = response.value(forHTTPHeaderField: "Content-Disposition")?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines),
              ["inline", "attachment"].contains(where: { disposition.caseInsensitiveCompare($0) == .orderedSame }),
              dispositionHeader.range(of: #"(?i)(?:^|;)[ \t]*filename\*?[ \t]*="#, options: .regularExpression) != nil else { return nil }
        let fallbackFilename = HTTPURLResponse(url: fallbackURL, statusCode: 200, httpVersion: nil, headerFields: [:])?.suggestedFilename
        let filename = response.suggestedFilename
        guard let filename, !filename.isEmpty, filename != fallbackFilename else { return nil }

        let digest = headers.firstValue(for: "Content-Digest").flatMap { value -> String? in
            let prefix = "sha-256=:"
            guard value.lowercased().hasPrefix(prefix), value.last == ":" else { return nil }
            let encoded = String(value.dropFirst(prefix.count).dropLast())
            guard !encoded.isEmpty, let data = Data(base64Encoded: encoded), data.count == 32,
                  data.base64EncodedString() == encoded else { return nil }
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        if headers.firstValue(for: "Content-Digest") != nil && digest == nil { return nil }
        return NodeSyncAttachment(contentDigest: digest, contentID: nil, disposition: String(disposition), filename: filename, id: id, mime: mime, size: size)
    }

    private static func mergeAttachmentMetadata(provided: NodeSyncAttachment?, response: NodeSyncAttachment?, id: String) throws -> NodeSyncAttachment? {
        guard let provided else { return response }
        guard provided.id == id else { throw NodeSyncClientError.invalidResponse }
        guard let response else { return provided }
        let providedDisposition = provided.disposition == "none" ? "attachment" : provided.disposition
        guard provided.filename == response.filename,
              provided.mime == response.mime,
              provided.size == response.size,
              providedDisposition == response.disposition else {
            throw NodeSyncClientError.invalidResponse
        }
        if let providedDigest = provided.contentDigest,
           let responseDigest = response.contentDigest,
           providedDigest != responseDigest {
            throw NodeSyncClientError.invalidResponse
        }
        return NodeSyncAttachment(
            contentDigest: provided.contentDigest ?? response.contentDigest,
            contentID: provided.contentID ?? response.contentID,
            disposition: provided.disposition,
            filename: provided.filename,
            id: provided.id,
            mime: provided.mime,
            size: provided.size
        )
    }

    private func map(statusCode: Int) -> NodeSyncClientError {
        if statusCode == 404 { return .notFound }
        if statusCode == 401 || statusCode == 403 { return .problem(.unauthorized) }
        if statusCode == 409 { return .conflict }
        if statusCode >= 500 { return .problem(.unavailable) }
        return .invalidResponse
    }

    func pathSegment(_ prefix: String, _ value: String) throws -> String {
        guard !value.isEmpty, !value.contains("/"), !value.contains("?"), !value.contains("#"), value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw NodeSyncClientError.invalidResponse
        }
        return prefix + value
    }

    private func encodedMessagePath(_ value: String) throws -> String {
        "/v1/messages/" + (try messagePathToken(value))
    }

    /// The canonical raw base64url path token of a message identifier, shared
    /// by the legacy and the logical-mailbox-scoped message routes.
    func messagePathToken(_ value: String) throws -> String {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw NodeSyncClientError.invalidResponse
        }
        let token = Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard !token.isEmpty else { throw NodeSyncClientError.invalidResponse }
        return token
    }

    func execute(method: String, path: String, body: Data, retryable: Bool, cancellation: NodeHTTPTransportRequestCancellation? = nil) async throws -> NodeHTTPResponse {
        defer { cancellation?.markCompleted() }
        _ = try await admitPendingRequest()
        var attempt = 0
        while true {
            try Task.checkCancellation()
            if let cancellation { try cancellation.throwIfCancelled() }
            do {
                let response: NodeHTTPResponse
                if let cancellation, let scoped = sender as? any NodeSessionRequestScopedSending {
                    guard let attemptCancellation = cancellation.makeChild() else { throw CancellationError() }
                    response = try await scoped.send(method: method, path: path, body: body, maximumResponseBytes: NodeTLSClient.maximumResponseBytes, cancellation: attemptCancellation)
                } else {
                    response = try await sender.send(method: method, path: path, body: body, maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
                }
                guard (200...299).contains(response.statusCode) else { throw map(response) }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NodeSessionError where error == .transportFailureAfterDispatch {
                throw NodeSyncClientError.transportAfterDispatch
            } catch let error as NodeSessionError where error == .transportCancellationAfterDispatch {
                throw NodeSyncClientError.cancelledAfterDispatch
            } catch let error as NodeSessionError where error == .authenticationRejected {
                throw NodeSyncClientError.problem(.unauthorized)
            } catch let error as NodeSyncClientError {
                guard retryable, attempt + 1 < maximumAttempts, error.isRetryable else { throw error }
                attempt += 1
            } catch {
                guard retryable, attempt + 1 < maximumAttempts else { throw NodeSyncClientError.transport }
                attempt += 1
            }
        }
    }

    private func admitPendingRequest() async throws -> NodeHTTPResponse? {
        guard let reconciler = sender as? any NodePendingRequestReconciling else { return nil }
        do {
            return try await reconciler.reconcilePendingRequest()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NodeSyncClientError {
            throw error
        } catch let error as NodeSessionError where error == .transportCancellationAfterDispatch {
            throw NodeSyncClientError.cancelledAfterDispatch
        } catch let error as NodeSessionError where error == .transportFailureAfterDispatch {
            throw NodeSyncClientError.transportAfterDispatch
        } catch let error as NodeSessionError where error == .authenticationRejected {
            throw NodeSyncClientError.problem(.unauthorized)
        } catch {
            throw NodeSyncClientError.transport
        }
    }

    private func map(_ response: NodeHTTPResponse) -> NodeSyncClientError {
        if response.statusCode == 404 { return .notFound }
        if let problem = try? NodeSyncCodec.decodeProblem(response.body) {
            switch problem.category {
            case .conflict: return .conflict
            case .staleCursor: return .problem(.staleCursor)
            case .unauthorized: return .problem(.unauthorized)
            case .invalidRequest: return .problem(.invalidRequest)
            case .unavailable: return .problem(.unavailable)
            }
        }
        if response.statusCode >= 500 { return .problem(.unavailable) }
        return .invalidResponse
    }
}

private extension Dictionary where Key == String, Value == String {
    func firstValue(for key: String) -> String? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

private extension NodeSyncClientError {
    var isRetryable: Bool {
        switch self {
        case .transport, .problem(.unavailable): return true
        case .transportAfterDispatch: return false
        case .cancelledAfterDispatch: return false
        case .cancelled, .conflict, .invalidResponse, .notFound, .problem: return false
        }
    }
}

private final class NodeTaskCancellationBox: @unchecked Sendable {
	private let lock = NSLock()
	private var task: Task<Void, Never>?
	private let onCancel: (@Sendable () -> Void)?
	private var didCancel = false

	init(onCancel: (@Sendable () -> Void)? = nil) {
		self.onCancel = onCancel
	}

	func set(_ task: Task<Void, Never>) {
		lock.lock()
		self.task = task
		let cancelImmediately = didCancel
		lock.unlock()
		if cancelImmediately { task.cancel() }
	}

	func cancel() {
		lock.lock()
		guard !didCancel else {
			lock.unlock()
			return
		}
		didCancel = true
		let task = self.task
		lock.unlock()
		task?.cancel()
		onCancel?()
	}
}
