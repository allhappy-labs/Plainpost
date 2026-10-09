import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// Serializes the complete session-owned request lane, including durable
/// admission, reservation, dispatch, and commit. It deliberately does not
/// use an NSLock across network callbacks or stream consumption.
private actor NodeSessionLane {
    private var occupied = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    order.append(id)
                }
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })
    }

    func release() {
        while let id = order.first {
            order.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume()
                return
            }
        }
        occupied = false
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.resume(throwing: CancellationError())
    }
}

/// Authenticated private Node sender. A sequence is reserved only after its
/// canonical transcript is built. Ambiguous delivery retains its public
/// whole-second timestamp and digest; a retry rebuilds and re-signs the
/// caller's exact semantic request.
public final class NodeSessionTransport: @unchecked Sendable {
    private let reference: SyncNodeEndpointReference
    private let clientID: AccountDeviceID
    private let endpoint: NodeEndpointURL
    private let store: SyncNodeEndpointStore
    private let identity: AccountDeviceIdentity
    private let client: NodeTLSClient
    private let lane = NodeSessionLane()
    private let authorityEpochLock = NSLock()
    private var authorityEpochs: [LogicalMailboxID: String] = [:]

    public init(reference: SyncNodeEndpointReference, clientID: AccountDeviceID, endpoint: NodeEndpointURL, store: SyncNodeEndpointStore, identity: AccountDeviceIdentity, client: NodeTLSClient = NodeTLSClient()) throws {
        guard clientID != reference.nodeID,
              let host = endpoint.url.host,
              let port = endpoint.url.port,
              endpoint.url.scheme == "https"
        else { throw AccountRuntimeError.untrustedResponse }
        _ = host
        _ = port
        self.reference = reference; self.clientID = clientID; self.endpoint = endpoint
        self.store = store; self.identity = identity; self.client = client
    }

    private func withLane<T>(_ operation: () async throws -> T) async throws -> T {
        try await lane.acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await lane.release()
            return value
        } catch {
            await lane.release()
            throw error
        }
    }

    public func send(method: String, path: String, body: Data, now: Date = Date(), maximumResponseBytes: Int = NodeTLSClient.maximumResponseBytes, cancellation: NodeHTTPTransportRequestCancellation? = nil) async throws -> NodeHTTPResponse {
        try await withLane {
            try await self.sendSerialized(method: method, path: path, body: body, now: now, maximumResponseBytes: maximumResponseBytes, cancellation: cancellation)
        }
    }

    private func sendSerialized(method: String, path: String, body: Data, now: Date, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation? = nil) async throws -> NodeHTTPResponse {
        try Task.checkCancellation()
        guard maximumResponseBytes > 0,
              maximumResponseBytes <= NodeTLSClient.maximumBufferedResponseBytes(method: method, path: path) else { throw NodeSessionError.invalidValue }
        guard body.count <= NodeSessionLimits.maximumRequestBodyBytes,
              let host = endpoint.url.host,
              let port = endpoint.url.port
        else { throw AccountRuntimeError.transportFailure }
        try await admitBeforeDispatch(method: method, path: path, body: body)
        guard let epoch = UInt64(reference.trustEpoch.wireValue) else { throw AccountRuntimeError.untrustedResponse }
        let sequence = try store.load(for: reference).nextSequence
        let candidate = try Self.pending(sequence: sequence, accountID: reference.accountID.rawValue, clientID: clientID.rawValue, nodeID: reference.nodeID.rawValue, epoch: epoch, audience: "\(host):\(port)", method: method, path: path, body: body, issuedAt: Self.timestamp(now), identity: identity)
        let reservation = try store.reservePending(for: reference, sequence: sequence, issuedAt: candidate.issuedAt, requestTranscriptDigest: candidate.requestTranscriptDigest, method: method, path: path, body: body)
        let pending = try reservation.reservation.issuedAt == candidate.issuedAt ? candidate : Self.pending(sequence: sequence, accountID: reference.accountID.rawValue, clientID: clientID.rawValue, nodeID: reference.nodeID.rawValue, epoch: epoch, audience: "\(host):\(port)", method: method, path: path, body: body, issuedAt: reservation.reservation.issuedAt, identity: identity)
        guard reservation.reservation.sequence == sequence, reservation.reservation.requestTranscriptDigest == pending.requestTranscriptDigest else { throw NodeSessionError.applicationResultUncertain }
        return try await dispatch(pending, maximumResponseBytes: maximumResponseBytes, cancellation: cancellation)
    }

    private func admitBeforeDispatch(method: String, path: String, body: Data) async throws {
        let retainedRequest = try store.loadPending(for: reference)
        let retainedMutation = try store.loadRetainedMutation(for: reference)
        let isRetryOfRetainedRequest = retainedRequest?.method == method
            && retainedRequest?.path == path
            && retainedRequest?.body == body
        let isAmbiguousAssignment = retainedRequest?.path == "/v1/mailboxes/assignments"
            && !isRetryOfRetainedRequest
        if isAmbiguousAssignment {
            _ = try await reconcilePendingRequestUnlocked()
            // The replay settles the previous exact request; the caller must
            // retry its different request after that strict boundary. Never
            // let one send call leapfrog the retained sequence.
            throw NodeSessionError.applicationResultUncertain
        }
        if retainedMutation != nil {
            _ = try await reconcilePendingRequestUnlocked()
        }
    }

    private func dispatch(_ pending: PreparedRequest, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation? = nil) async throws -> NodeHTTPResponse {
        let response: NodeHTTPResponse
        let boundary = DispatchBoundary()
        do {
            response = try await client.send(NodeHTTPRequest(endpoint: endpoint, method: pending.method, path: pending.path, body: pending.body, additionalHeaders: ["Plainpost-Signed-Request": pending.signedHeader]), maximumResponseBytes: maximumResponseBytes, onDispatch: { boundary.markDispatched() }, cancellation: cancellation)
        } catch is CancellationError {
            if boundary.isDispatched { throw NodeSessionError.transportCancellationAfterDispatch }
            throw CancellationError()
        }
        catch let error as NodeSessionError {
            if boundary.isDispatched { throw NodeSessionError.transportFailureAfterDispatch }
            throw error
        }
        catch {
            if boundary.isDispatched { throw NodeSessionError.transportFailureAfterDispatch }
            throw NodeSessionError.transportFailure
        }
        switch ServerDisposition(response) {
        case .dispatched:
            let retainMutation: Bool
            if pending.path == "/v1/mutations" {
                // A response that crossed dispatch but cannot be decoded is
                // not a deterministic terminal disposition. The operation
                // may already have committed, so preserve the validated
                // canonical replay until an authenticated result settles it.
                guard let expectedKey = Self.mutationIdempotencyKey(in: pending.body),
                      let result = try? NodeSyncCodec.decodeMutationResult(response.body),
                      result.idempotencyKey == expectedKey else {
                    throw NodeSessionError.transportFailureAfterDispatch
                }
                retainMutation = result.state == "pending"
            } else {
                retainMutation = false
            }
            try store.commitPending(for: reference, sequence: pending.sequence, retainMutation: retainMutation)
            return response
        case .exactSequenceConsumed:
            try store.commitPending(for: reference, sequence: pending.sequence, retainMutation: true)
            throw NodeSessionError.applicationResultUncertain
        case .definitiveRejection:
            try store.rollbackPending(for: reference, sequence: pending.sequence, requestTranscriptDigest: pending.requestTranscriptDigest)
            throw NodeSessionError.invalidValue
        case .authenticationRejected:
            try store.rollbackPending(for: reference, sequence: pending.sequence, requestTranscriptDigest: pending.requestTranscriptDigest)
            throw NodeSessionError.authenticationRejected
        case .uncertain:
            throw NodeSessionError.transportFailure
        }
    }

    private struct PreparedRequest { let sequence: UInt64; let requestTranscriptDigest, body: Data; let method, path, issuedAt, signedHeader: String }

    private static func mutationIdempotencyKey(in body: Data) -> String? {
        guard let request = try? NodeSyncCodec.decodeMutationRequest(body),
              let operation = try? NodeSyncCodec.decodeOperation(request.canonicalOperation) else { return nil }
        return operation.unsigned.idempotencyKey
    }

    private static func pending(sequence: UInt64, accountID: String, clientID: String, nodeID: String, epoch: UInt64, audience: String, method: String, path: String, body: Data, issuedAt: String, identity: AccountDeviceIdentity) throws -> PreparedRequest {
        let unsigned = try SignedRequestV1(accountID: accountID, clientID: clientID, nodeID: nodeID, trustEpoch: epoch, audience: audience, sequence: sequence, method: method, path: path, bodySHA256: Data(SHA256.hash(data: body)), issuedAt: issuedAt, signature: Data(repeating: 0, count: 64))
        let signature = try identity.signature(for: try NodeSessionTranscript.request(unsigned))
        let signed = try SignedRequestV1(accountID: unsigned.accountID, clientID: unsigned.clientID, nodeID: unsigned.nodeID, trustEpoch: unsigned.trustEpoch, audience: unsigned.audience, sequence: unsigned.sequence, method: unsigned.method, path: unsigned.path, bodySHA256: unsigned.bodySHA256, issuedAt: unsigned.issuedAt, signature: signature)
		return PreparedRequest(sequence: sequence, requestTranscriptDigest: Data(SHA256.hash(data: try NodeSessionTranscript.request(unsigned))), body: body, method: method, path: path, issuedAt: issuedAt, signedHeader: try header(signed))
    }

    private static func header(_ value: SignedRequestV1) throws -> String {
        let fields: [String: String] = [
            "kind": "node.signed-request.v1", "accountID": value.accountID, "clientID": value.clientID,
            "nodeID": value.nodeID, "trustEpoch": String(value.trustEpoch), "audience": value.audience,
            "sequence": String(value.sequence), "method": value.method, "path": value.path,
            "bodySHA256": NodeSessionWire.encodeBase64URL(value.bodySHA256), "issuedAt": value.issuedAt,
            "signature": NodeSessionWire.encodeBase64URL(value.signature),
        ]
        let wire = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        guard wire.count <= 8_192, let header = String(data: wire, encoding: .utf8) else { throw AccountRuntimeError.transportFailure }
        return header
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: value.timeIntervalSince1970.rounded(.towardZero)))
    }
}

private final class DispatchBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatched = false
    func markDispatched() { lock.lock(); dispatched = true; lock.unlock() }
    var isDispatched: Bool { lock.lock(); defer { lock.unlock() }; return dispatched }
}

extension NodeSessionTransport: NodeMutationOperationSigning, NodeAuthorityEpochUpdating {
    /// Installs an authority epoch only after the authenticated assignments
    /// response has supplied it. Trust epoch remains endpoint/session scoped.
    ///
    /// A logical mailbox's authority epoch only increases on the Node, so the
    /// install is monotonic: concurrent reads (`/v1/mail/accounts`, legacy
    /// assignments) whose responses complete out of order can never replace
    /// a newer epoch with an older one. The compare and the write happen under
    /// one lock.
    public func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        guard let value = UInt64(epoch), value > 0, String(value) == epoch else { throw AccountRuntimeError.untrustedResponse }
        authorityEpochLock.lock()
        if let installed = authorityEpochs[logicalMailboxID].flatMap(UInt64.init), installed >= value {
            authorityEpochLock.unlock()
            return
        }
        authorityEpochs[logicalMailboxID] = epoch
        authorityEpochLock.unlock()
    }

    public func signMutation(
        variant: NodeSyncOperationVariant,
        logicalMailboxID: LogicalMailboxID,
        idempotencyKey: String,
        issuedAt: String
    ) throws -> Data {
        authorityEpochLock.lock()
        let authorityEpoch = authorityEpochs[logicalMailboxID]
        authorityEpochLock.unlock()
        guard let authorityEpoch else { throw AccountRuntimeError.untrustedResponse }
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: reference.accountID.rawValue,
            authorityEpoch: authorityEpoch,
            clientID: clientID.rawValue,
            idempotencyKey: idempotencyKey,
            issuedAt: issuedAt,
            logicalMailboxID: logicalMailboxID,
            nodeID: reference.nodeID.rawValue,
            operation: variant,
            trustEpoch: reference.trustEpoch.wireValue
        )
        let signature = try identity.signature(for: NodeSyncCodec.operationTranscript(unsigned))
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(unsigned: unsigned, signature: signature))
    }
}

extension NodeSessionTransport: NodePendingRequestReconciling, NodePendingMutationReconciling {
    /// Replays the exact authenticated request retained by the device-only
    /// pending record. This is deliberately separate from `send`: a caller
    /// must settle any ambiguous prior request before it can reserve a new
    /// sequence or sign a different request.
    public func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        try await withLane {
            try await self.reconcilePendingRequestUnlocked()
        }
    }

    private func reconcilePendingRequestUnlocked() async throws -> NodeHTTPResponse? {
        var attempts = 0
        while let response = try await reconcileOnePendingRequest() {
            guard Self.isPendingMutation(response) else { return response }
            guard attempts < Self.maximumPendingReconciliationAttempts else {
                throw NodeSessionError.applicationResultUncertain
            }
            attempts += 1
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    /// Compatibility narrowing for mutation callers that need the decoded
    /// result. Non-mutation pending requests are left to the generic request
    /// reconciliation path used by reads and provider assignments.
    public func reconcilePendingMutation() async throws -> NodeHTTPResponse? {
        guard let response = try await reconcilePendingRequest(),
              (try? NodeSyncCodec.decodeMutationResult(response.body)) != nil else { return nil }
        return response
    }

    private static let maximumPendingReconciliationAttempts = 120

    private func reconcileOnePendingRequest() async throws -> NodeHTTPResponse? {
        if let pending = try store.loadPending(for: reference) {
            return try await reconcile(pending)
        }
        guard let retained = try store.loadRetainedMutation(for: reference) else { return nil }
        return try await dispatchRetainedMutation(retained)
    }

    private static func isPendingMutation(_ response: NodeHTTPResponse) -> Bool {
        guard (200...299).contains(response.statusCode),
              let result = try? NodeSyncCodec.decodeMutationResult(response.body) else { return false }
        return result.state == "pending"
    }

    private func reconcile(_ pending: SyncNodePendingRequest) async throws -> NodeHTTPResponse? {
        guard let method = pending.method,
              ["GET", "POST", "PUT", "DELETE"].contains(method),
              let path = pending.path,
              !path.isEmpty,
              let host = endpoint.url.host,
              let port = endpoint.url.port,
              let epoch = UInt64(reference.trustEpoch.wireValue)
        else { throw NodeSessionError.applicationResultUncertain }
        // GET has no body and can be safely reconstructed after restart. A
        // body-bearing generic request is intentionally not durable; if its
        // process-local copy is gone, fail closed rather than inventing bytes.
        let body = pending.body ?? Data()
        let prepared = try Self.pending(
            sequence: pending.sequence,
            accountID: reference.accountID.rawValue,
            clientID: clientID.rawValue,
            nodeID: reference.nodeID.rawValue,
            epoch: epoch,
            audience: "\(host):\(port)",
            method: method,
            path: path,
            body: body,
            issuedAt: pending.issuedAt,
            identity: identity
        )
        guard prepared.requestTranscriptDigest == pending.requestTranscriptDigest else {
            throw NodeSessionError.applicationResultUncertain
        }
        // Method/path are bound to the retained transcript digest above, so the
        // request-class ceiling survives replay without persisting secret bodies
        // or accepting an arbitrary caller-supplied larger allowance.
        return try await dispatch(prepared, maximumResponseBytes: NodeTLSClient.maximumBufferedResponseBytes(method: method, path: path))
    }

    private func dispatchRetainedMutation(_ retained: SyncNodePendingRequest) async throws -> NodeHTTPResponse {
        guard let method = retained.method, method == "POST", let path = retained.path, path == "/v1/mutations", let body = retained.body,
              let host = endpoint.url.host, let port = endpoint.url.port,
              let epoch = UInt64(reference.trustEpoch.wireValue) else {
            throw NodeSessionError.applicationResultUncertain
        }
        let sequence = try store.load(for: reference).nextSequence
        let candidate = try Self.pending(
            sequence: sequence, accountID: reference.accountID.rawValue,
            clientID: clientID.rawValue, nodeID: reference.nodeID.rawValue,
            epoch: epoch, audience: "\(host):\(port)", method: method,
            path: path, body: body, issuedAt: Self.timestamp(Date()), identity: identity
        )
        let reservation = try store.reservePending(for: reference, sequence: sequence, issuedAt: candidate.issuedAt, requestTranscriptDigest: candidate.requestTranscriptDigest, method: candidate.method, path: candidate.path, body: candidate.body)
        guard reservation.reservation.sequence == sequence,
              reservation.reservation.requestTranscriptDigest == candidate.requestTranscriptDigest else {
            throw NodeSessionError.applicationResultUncertain
        }
        return try await dispatch(candidate, maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
    }
}

extension NodeSessionTransport: NodeSessionRequestSending, NodeSessionRequestScopedSending {
    public func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        try await send(method: method, path: path, body: body, now: Date(), maximumResponseBytes: maximumResponseBytes)
    }

    public func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        try await withLane {
            try await self.sendSerialized(method: method, path: path, body: body, now: Date(), maximumResponseBytes: maximumResponseBytes, cancellation: cancellation)
        }
    }
}

extension NodeSessionTransport: NodeSessionStreamingRequestSending {
    public func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        try await withLane {
            try await self.streamSerialized(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
        }
    }

    private func streamSerialized(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        try Task.checkCancellation()
        guard body.count <= NodeSessionLimits.maximumRequestBodyBytes,
              let host = endpoint.url.host,
              let port = endpoint.url.port,
              let epoch = UInt64(reference.trustEpoch.wireValue) else {
            throw AccountRuntimeError.transportFailure
        }
        try await admitBeforeDispatch(method: method, path: path, body: body)
        let sequence = try store.load(for: reference).nextSequence
        let candidate = try Self.pending(sequence: sequence, accountID: reference.accountID.rawValue, clientID: clientID.rawValue, nodeID: reference.nodeID.rawValue, epoch: epoch, audience: "\(host):\(port)", method: method, path: path, body: body, issuedAt: Self.timestamp(Date()), identity: identity)
        let reservation = try store.reservePending(for: reference, sequence: sequence, issuedAt: candidate.issuedAt, requestTranscriptDigest: candidate.requestTranscriptDigest, method: method, path: path, body: body)
        let pending = try reservation.reservation.issuedAt == candidate.issuedAt ? candidate : Self.pending(sequence: sequence, accountID: reference.accountID.rawValue, clientID: clientID.rawValue, nodeID: reference.nodeID.rawValue, epoch: epoch, audience: "\(host):\(port)", method: method, path: path, body: body, issuedAt: reservation.reservation.issuedAt, identity: identity)
        guard reservation.reservation.sequence == sequence, reservation.reservation.requestTranscriptDigest == pending.requestTranscriptDigest else { throw NodeSessionError.applicationResultUncertain }
        let request = NodeHTTPRequest(endpoint: endpoint, method: pending.method, path: pending.path, body: pending.body, additionalHeaders: ["Plainpost-Signed-Request": pending.signedHeader])
        let response: NodeHTTPStreamResponse
        let boundary = DispatchBoundary()
        do {
            response = try await client.stream(request, maximumResponseBytes: maximumResponseBytes, onDispatch: { boundary.markDispatched() })
        } catch is CancellationError {
            if boundary.isDispatched { throw NodeSessionError.transportCancellationAfterDispatch }
            throw CancellationError()
        } catch let error as NodeSessionError {
            if boundary.isDispatched { throw NodeSessionError.transportFailureAfterDispatch }
            throw error
        } catch {
            if boundary.isDispatched { throw NodeSessionError.transportFailureAfterDispatch }
            throw NodeSessionError.transportFailure
        }
        guard !(200...299).contains(response.statusCode) else {
            do {
                try store.commitPending(for: reference, sequence: pending.sequence, retainMutation: false)
            } catch {
                response.bytes.cancel()
                throw error
            }
            return response
        }
		let body: Data
		do {
			body = try await Self.collect(response.bytes, maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
		} catch is CancellationError {
			throw NodeSessionError.transportCancellationAfterDispatch
		} catch is NodeSessionError {
			throw NodeSessionError.transportFailureAfterDispatch
		} catch {
			throw NodeSessionError.transportFailureAfterDispatch
		}
        let buffered = NodeHTTPResponse(statusCode: response.statusCode, url: response.url, headers: response.headers, body: body)
        switch ServerDisposition(buffered) {
        case .dispatched:
            try store.commitPending(for: reference, sequence: pending.sequence, retainMutation: false)
            return NodeHTTPStreamResponse(statusCode: response.statusCode, url: response.url, headers: response.headers, bytes: Self.oneShot(body))
        case .exactSequenceConsumed:
            try store.commitPending(for: reference, sequence: pending.sequence, retainMutation: true)
            throw NodeSessionError.applicationResultUncertain
        case .definitiveRejection:
            try store.rollbackPending(for: reference, sequence: pending.sequence, requestTranscriptDigest: pending.requestTranscriptDigest)
            throw NodeSessionError.invalidValue
        case .authenticationRejected:
            try store.rollbackPending(for: reference, sequence: pending.sequence, requestTranscriptDigest: pending.requestTranscriptDigest)
            throw NodeSessionError.authenticationRejected
        case .uncertain:
            throw NodeSessionError.transportFailure
        }
    }

    private static func collect(_ input: PlainpostByteStream, maximumResponseBytes: Int) async throws -> Data {
        var result = Data()
        for try await chunk in input {
            guard chunk.count <= maximumResponseBytes - result.count else { throw NodeSessionError.invalidValue }
            result.append(chunk)
        }
        return result
    }

    private static func oneShot(_ body: Data) -> PlainpostByteStream {
        let stream = PlainpostByteStream(capacity: 1)
        let producer = stream.producer
        Task {
            do {
                try await producer.send(body)
                producer.finish()
            } catch {
                producer.fail(error)
            }
        }
        return stream
    }
}

/// A received response has passed through the Node transport. The only
/// pre-dispatch outcomes are the closed, fixed middleware problem documents;
/// every other response was emitted by the application after Consume and must
/// advance the reservation, regardless of its HTTP status.
private enum ServerDisposition {
    case dispatched
    case exactSequenceConsumed
    case definitiveRejection
    case authenticationRejected
    case uncertain

    init(_ response: NodeHTTPResponse) {
        guard let problem = Self.fixedProblem(response) else { self = .dispatched; return }
        switch (problem.type, problem.status) {
        case ("urn:plainpost:node-sequence-consumed", 409): self = .exactSequenceConsumed
        case ("urn:plainpost:node-auth-rejected", 401): self = .authenticationRejected
        case ("urn:plainpost:node-request-too-large", 413),
             ("urn:plainpost:node-sequence-rejected", 409): self = .definitiveRejection
        case ("urn:plainpost:node-sequence-unavailable", 503): self = .uncertain
        default: self = .dispatched
        }
    }

    private static func fixedProblem(_ response: NodeHTTPResponse) -> (type: String, status: Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              object.count == 2,
              let type = object["type"] as? String,
              let status = object["status"] as? Int,
              response.statusCode == status
        else { return nil }
        return (type, status)
    }
}
