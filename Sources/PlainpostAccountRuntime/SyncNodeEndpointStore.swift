import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// The reference intentionally contains endpoint ciphertext only. Endpoint
/// plaintext is held just long enough to build a direct TLS request.
public struct SyncNodeEndpointReference: Codable, Equatable, Sendable {
    public let accountID: PlainpostAccountID
    public let nodeID: AccountDeviceID
    public let trustEpoch: AccountTrustEpoch
    public let endpointCiphertext: Data

    public init(accountID: PlainpostAccountID, nodeID: AccountDeviceID, trustEpoch: AccountTrustEpoch, endpointCiphertext: Data) throws {
        guard (29...16_384).contains(endpointCiphertext.count) else { throw AccountRuntimeError.corruptSecret }
        self.accountID = accountID; self.nodeID = nodeID; self.trustEpoch = trustEpoch; self.endpointCiphertext = endpointCiphertext
    }
}

/// Durable documents needed to restart an already-activated private session.
/// Mutable activation signatures and the setup code are deliberately absent.
public struct SyncNodeStoredSession: Codable, Equatable, Sendable {
    public let resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, cleanupCapabilityWire: Data
    public let nextSequence: UInt64

    public init(resultWire: Data, refreshWire: Data, leaseWire: Data, trustCommitWire: Data, admissionEvidenceWire: Data, cleanupCapabilityWire: Data, nextSequence: UInt64) throws {
        let fields = [resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, cleanupCapabilityWire]
        guard nextSequence > 0, fields.allSatisfy({ !$0.isEmpty && $0.count <= 64 * 1024 }), fields.reduce(0, { $0 + $1.count }) <= 128 * 1024 else { throw AccountRuntimeError.corruptSecret }
        self.resultWire = resultWire; self.refreshWire = refreshWire; self.leaseWire = leaseWire; self.trustCommitWire = trustCommitWire
        self.admissionEvidenceWire = admissionEvidenceWire; self.cleanupCapabilityWire = cleanupCapabilityWire; self.nextSequence = nextSequence
    }
}

/// The durable reservation for an ambiguous Node request. Only public request
/// metadata is durable. Request bodies are deliberately process-local: a
/// restart must fail closed for a generic request rather than persist provider
/// credentials, OAuth codes, PKCE verifiers, or arbitrary mail content.
public struct SyncNodePendingRequest: Codable, Equatable, Sendable {
    public let sequence: UInt64
    /// Canonical public request metadata needed to reconstruct the exact
    /// signed transcript after an ambiguous delivery or process restart.
    public let issuedAt: String
    public let requestTranscriptDigest: Data
    public let method: String?
    public let path: String?
    public let body: Data?

    public init(sequence: UInt64, issuedAt: String, requestTranscriptDigest: Data, method: String? = nil, path: String? = nil, body: Data? = nil) throws {
        guard sequence > 0,
              NodeSessionWire.parseWholeSecondTimestamp(issuedAt) != nil,
              requestTranscriptDigest.count == 32,
              ((method == nil && path == nil) ||
                  ((method.map { !$0.isEmpty && $0.utf8.count <= 16 } ?? false) &&
                   (path.map { !$0.isEmpty && $0.utf8.count <= 4_096 } ?? false))),
              (body.map { $0.count <= NodeSessionLimits.maximumRequestBodyBytes } ?? true)
        else { throw AccountRuntimeError.corruptSecret }
        self.sequence = sequence; self.issuedAt = issuedAt; self.requestTranscriptDigest = requestTranscriptDigest
        self.method = method; self.path = path; self.body = body
    }

    private enum CodingKeys: String, CodingKey { case sequence, issuedAt, requestTranscriptDigest, method, path }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(UInt64.self, forKey: .sequence),
            issuedAt: container.decode(String.self, forKey: .issuedAt),
            requestTranscriptDigest: container.decode(Data.self, forKey: .requestTranscriptDigest),
            method: container.decodeIfPresent(String.self, forKey: .method),
            path: container.decodeIfPresent(String.self, forKey: .path),
            body: nil
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(requestTranscriptDigest, forKey: .requestTranscriptDigest)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(path, forKey: .path)
        // Never encode body. The in-memory value exists only to finish an
        // already-running request and is intentionally lost on restart.
    }

    fileprivate func withBody(_ body: Data?) throws -> SyncNodePendingRequest {
        try SyncNodePendingRequest(sequence: sequence, issuedAt: issuedAt, requestTranscriptDigest: requestTranscriptDigest, method: method, path: path, body: body)
    }
}

/// The sole durable replay payload: a canonical Node mutation. It contains no
/// provider configuration, endpoint, credential, or generic HTTP body.
private struct SyncNodeRetainedMutation: Codable, Equatable {
    let sequence: UInt64
    let issuedAt: String
    let requestTranscriptDigest: Data
    let canonicalOperation: Data

    init(sequence: UInt64, issuedAt: String, requestTranscriptDigest: Data, canonicalOperation: Data) throws {
        guard sequence > 0, NodeSessionWire.parseWholeSecondTimestamp(issuedAt) != nil,
              requestTranscriptDigest.count == 32,
              (1...NodeSessionLimits.maximumRequestBodyBytes).contains(canonicalOperation.count)
        else { throw AccountRuntimeError.corruptSecret }
        self.sequence = sequence; self.issuedAt = issuedAt
        self.requestTranscriptDigest = requestTranscriptDigest
        self.canonicalOperation = canonicalOperation
    }
}

private struct SyncNodeEndpointState: Codable, Equatable {
    let version: Int
    let reference: SyncNodeEndpointReference
    let session: SyncNodeStoredSession
    let pending: SyncNodePendingRequest?
    let retainedMutation: SyncNodeRetainedMutation?
}

private struct SyncNodeEndpointStateV2: Codable, Equatable {
    let version: Int
    let reference: SyncNodeEndpointReference
    let session: SyncNodeStoredSession
    let pending: SyncNodePendingRequest?
}

// Before version 4.1 retainedMutation had the generic pending-request shape.
// Decode its legacy body in this private migration type only, so the one
// allowlisted canonical mutation can survive; all other bodies are discarded.
private struct LegacyPendingRequest: Codable {
    let sequence: UInt64
    let issuedAt: String
    let requestTranscriptDigest: Data
    let method: String?
    let path: String?
    let body: Data?
}

private struct SyncNodeEndpointStateLegacyV4: Codable {
    let version: Int
    let reference: SyncNodeEndpointReference
    let session: SyncNodeStoredSession
    let pending: SyncNodePendingRequest?
    let retainedMutation: LegacyPendingRequest?
}

/// ThisDeviceOnly Keychain owner for endpoint ciphertext and the signed
/// Central session documents. Consumption uses the Keychain CAS primitive, so
/// two processes cannot reuse or reorder a client sequence.
public final class SyncNodeEndpointStore: @unchecked Sendable {
    private let secretStore: any AccountSecretStoring
    private let service: String
    /// The Keychain access group every record of this store uses; nil uses
    /// the platform default group (macOS).
    public let accessGroup: String?
    /// The group earlier builds wrote to. Its records move to `accessGroup`
    /// on first use and are then deleted there.
    public let legacyAccessGroup: String?
    private let transientLock = NSLock()
    private var transientBodies: [String: Data] = [:]

    /// iOS passes `PlainpostIOSAppKeychain.accessGroup` with the notifications
    /// group as `legacyAccessGroup`: the Notification Service extension shares
    /// that group and never needs the Node credential.
    public init(secretStore: any AccountSecretStoring = KeychainAccountSecretStore(), service: String = "com.marynavdovenko.Plainpost.SyncNode", accessGroup: String? = nil, legacyAccessGroup: String? = nil) throws {
        guard !service.isEmpty, service.utf8.count <= 128,
              accessGroup.map({ !$0.isEmpty }) ?? true,
              legacyAccessGroup.map({ !$0.isEmpty && accessGroup != nil && $0 != accessGroup }) ?? true
        else { throw AccountRuntimeError.corruptSecret }
        if let accessGroup, let legacyAccessGroup {
            self.secretStore = SyncNodeKeychainGroupMigration(backing: secretStore, accessGroup: accessGroup, legacyAccessGroup: legacyAccessGroup)
        } else {
            self.secretStore = secretStore
        }
        self.service = service; self.accessGroup = accessGroup; self.legacyAccessGroup = legacyAccessGroup
    }

    public func save(reference: SyncNodeEndpointReference, session: SyncNodeStoredSession) throws {
        let key = key(for: reference)
        for _ in 0..<16 {
            let record = try secretStore.load(key)
            if let record {
                guard record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
                let previous = try decodeStored(record.value)
                guard previous.reference == reference else { throw AccountRuntimeError.corruptSecret }
                // V3 documents are bound to the already accepted activation.
                // A repeated completion may advance only its sequence, never
                // exchange a signed document under the same reference.
                guard documentsEqual(previous.session, session) else { throw AccountRuntimeError.corruptSecret }
                let next = max(session.nextSequence, previous.session.nextSequence)
                let merged = try SyncNodeStoredSession(resultWire: session.resultWire, refreshWire: session.refreshWire, leaseWire: session.leaseWire, trustCommitWire: session.trustCommitWire, admissionEvidenceWire: session.admissionEvidenceWire, cleanupCapabilityWire: session.cleanupCapabilityWire, nextSequence: next)
                let replacement: Data
                if previous.terminal { replacement = try encode(TerminalState(reference: reference, session: merged)) }
                else { replacement = try encode(SyncNodeEndpointState(version: 4, reference: reference, session: merged, pending: previous.pending, retainedMutation: previous.retainedMutation)) }
                if try secretStore.compareAndSwap(expected: record.value, replacement: replacement, key: key, attributes: .deviceOnly) { return }
            } else {
                let replacement = try encode(SyncNodeEndpointState(version: 4, reference: reference, session: session, pending: nil, retainedMutation: nil))
                if try secretStore.compareAndSwap(expected: nil, replacement: replacement, key: key, attributes: .deviceOnly) { return }
            }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    public func load(for reference: SyncNodeEndpointReference) throws -> SyncNodeStoredSession {
        let record = try secretStore.load(key(for: reference))
        guard let record, record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        let state = try decode(record.value)
        guard state.reference == reference else { throw AccountRuntimeError.corruptSecret }
        return state.session
    }

    /// Returns the exact unsigned request reserved by an ambiguous dispatch,
    /// when one is present. Generic body data is available only to the live
    /// process which reserved it; the dedicated canonical mutation slot is
    /// also available after restart.
    public func loadPending(for reference: SyncNodeEndpointReference) throws -> SyncNodePendingRequest? {
        let record = try secretStore.load(key(for: reference))
        guard let record, record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        let state = try decode(record.value)
        guard state.reference == reference else { throw AccountRuntimeError.corruptSecret }
        guard let pending = state.pending else { return nil }
        let body = transientBody(for: reference, sequence: pending.sequence)
            ?? (state.retainedMutation?.canonicalOperation)
        return try pending.withBody(body)
    }

    /// Returns the exact canonical mutation retained after a committed
    /// response reported `pending` or its response was ambiguous. It remains
    /// device-only so recovery can reuse the original idempotency bytes.
    public func loadRetainedMutation(for reference: SyncNodeEndpointReference) throws -> SyncNodePendingRequest? {
        let record = try secretStore.load(key(for: reference))
        guard let record, record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        let state = try decode(record.value)
        guard state.reference == reference else { throw AccountRuntimeError.corruptSecret }
        guard let retained = state.retainedMutation else { return nil }
        return try SyncNodePendingRequest(sequence: retained.sequence, issuedAt: retained.issuedAt, requestTranscriptDigest: retained.requestTranscriptDigest, method: "POST", path: "/v1/mutations", body: retained.canonicalOperation)
    }

    /// Restores the opaque reference after account metadata authenticates the
    /// Node ID and epoch. The endpoint ciphertext itself stays device-only;
    /// callers cannot fabricate it from Central's record.
    public func loadReference(accountID: PlainpostAccountID, nodeID: AccountDeviceID, trustEpoch: AccountTrustEpoch) throws -> (reference: SyncNodeEndpointReference, session: SyncNodeStoredSession) {
        let key = key(accountID: accountID, nodeID: nodeID, trustEpoch: trustEpoch)
        guard let record = try secretStore.load(key), record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        let state = try decode(record.value)
        guard state.reference.accountID == accountID, state.reference.nodeID == nodeID, state.reference.trustEpoch == trustEpoch else { throw AccountRuntimeError.corruptSecret }
        return (state.reference, state.session)
    }

    /// Stores the already-authenticated endpoint in a separate ThisDeviceOnly
    /// record. The endpoint is encrypted with the device agreement key, so a
    /// cached read-only restart never needs to ask Central for endpoint
    /// metadata and never stores endpoint plaintext in Keychain.
    public func saveEndpoint(_ endpoint: URL, for reference: SyncNodeEndpointReference, identity: AccountDeviceIdentity) throws {
        let canonical = try NodeEndpointURL(endpoint.absoluteString).url
        let aad = endpointAAD(reference)
        let key = try endpointKey(reference: reference, identity: identity)
        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(Data(canonical.absoluteString.utf8), using: key, authenticating: aad).combined else { throw AccountRuntimeError.cryptographicFailure }
            sealed = combined
        } catch let error as AccountRuntimeError { throw error }
        catch { throw AccountRuntimeError.cryptographicFailure }

        let secretKey = endpointKey(for: reference)
        for _ in 0..<16 {
            if let record = try secretStore.load(secretKey) {
                guard record.attributes == .deviceOnly, record.value == sealed else {
                    guard try loadEndpoint(for: reference, identity: identity) == canonical else { throw AccountRuntimeError.corruptSecret }
                    return
                }
                return
            }
            if try secretStore.compareAndSwap(expected: nil, replacement: sealed, key: secretKey, attributes: .deviceOnly) { return }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    /// Loads only the endpoint sealed by `saveEndpoint`. This method is
    /// intentionally independent of Central metadata for offline reads.
    public func loadEndpoint(for reference: SyncNodeEndpointReference, identity: AccountDeviceIdentity) throws -> URL {
        let key = endpointKey(for: reference)
        guard let record = try secretStore.load(key), record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        do {
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: record.value), using: try endpointKey(reference: reference, identity: identity), authenticating: endpointAAD(reference))
            guard let string = String(data: plaintext, encoding: .utf8) else { throw AccountRuntimeError.corruptSecret }
            return try NodeEndpointURL(string).url
        } catch let error as AccountRuntimeError { throw error }
        catch { throw AccountRuntimeError.corruptSecret }
    }

    /// Returns the sequence permanently consumed by this request. `UInt64.max`
    /// is usable once; no wrap or reset is possible inside a trust epoch.
    public func consumeNextSequence(for reference: SyncNodeEndpointReference) throws -> UInt64 {
        let key = key(for: reference)
        for _ in 0..<16 {
            guard let record = try secretStore.load(key), record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            let state = try decode(record.value)
            guard state.reference == reference else { throw AccountRuntimeError.corruptSecret }
            guard state.pending == nil else { throw AccountRuntimeError.secretUnavailable }
            let sequence = state.session.nextSequence
            let replacementSession: SyncNodeStoredSession
            if sequence == UInt64.max {
                replacementSession = try SyncNodeStoredSession(resultWire: state.session.resultWire, refreshWire: state.session.refreshWire, leaseWire: state.session.leaseWire, trustCommitWire: state.session.trustCommitWire, admissionEvidenceWire: state.session.admissionEvidenceWire, cleanupCapabilityWire: state.session.cleanupCapabilityWire, nextSequence: UInt64.max)
                // Store a terminal sentinel after returning max. The following
                // caller detects it through the explicit terminal bit below.
                let terminal = try encode(TerminalState(reference: reference, session: replacementSession))
                guard try secretStore.compareAndSwap(expected: record.value, replacement: terminal, key: key, attributes: .deviceOnly) else { continue }
                return sequence
            }
            replacementSession = try SyncNodeStoredSession(resultWire: state.session.resultWire, refreshWire: state.session.refreshWire, leaseWire: state.session.leaseWire, trustCommitWire: state.session.trustCommitWire, admissionEvidenceWire: state.session.admissionEvidenceWire, cleanupCapabilityWire: state.session.cleanupCapabilityWire, nextSequence: sequence + 1)
            let replacement = try encode(SyncNodeEndpointState(version: 4, reference: reference, session: replacementSession, pending: nil, retainedMutation: state.retainedMutation))
            if try secretStore.compareAndSwap(expected: record.value, replacement: replacement, key: key, attributes: .deviceOnly) { return sequence }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    /// Reserves only the public canonical timestamp and transcript digest.
    /// Full envelopes remain unsupported and fail closed during decode.
    public func reservePending(for reference: SyncNodeEndpointReference, sequence: UInt64, issuedAt: String, requestTranscriptDigest: Data, method: String? = nil, path: String? = nil, body: Data? = nil) throws -> (reservation: SyncNodePendingRequest, newlyReserved: Bool) {
		guard sequence > 0, NodeSessionWire.parseWholeSecondTimestamp(issuedAt) != nil, requestTranscriptDigest.count == 32 else { throw AccountRuntimeError.corruptSecret }
        // Only the canonical mutation envelope is eligible for the dedicated
        // durable replay slot. Generic request bodies remain process-local.
        if path == "/v1/mutations" {
            guard method == "POST", let body else { throw AccountRuntimeError.corruptSecret }
            _ = try validateCanonicalMutationPayload(body)
        }
        let key = key(for: reference)
        for _ in 0..<16 {
            guard let record = try secretStore.load(key), record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            let state = try decode(record.value)
            guard state.reference == reference else { throw AccountRuntimeError.corruptSecret }
            if let pending = state.pending {
                let existingBody = transientBody(for: reference, sequence: pending.sequence)
                    ?? state.retainedMutation?.canonicalOperation
                if let method, let path, let body,
                   let pendingMethod = pending.method, let pendingPath = pending.path,
                   (method != pendingMethod || path != pendingPath || body != existingBody) {
                    throw AccountRuntimeError.secretUnavailable
                }
                return (try pending.withBody(existingBody), false)
            }
            guard sequence == state.session.nextSequence else { throw AccountRuntimeError.secretUnavailable }
            let pending = try SyncNodePendingRequest(sequence: sequence, issuedAt: issuedAt, requestTranscriptDigest: requestTranscriptDigest, method: method, path: path, body: body)
            let durablePending = try pending.withBody(nil)
            let retainedMutation: SyncNodeRetainedMutation?
            if path == "/v1/mutations", let body {
                retainedMutation = try SyncNodeRetainedMutation(sequence: sequence, issuedAt: issuedAt, requestTranscriptDigest: requestTranscriptDigest, canonicalOperation: body)
            } else {
                retainedMutation = state.retainedMutation
            }
            let replacement = try encode(SyncNodeEndpointState(version: 4, reference: reference, session: state.session, pending: durablePending, retainedMutation: retainedMutation))
            if try secretStore.compareAndSwap(expected: record.value, replacement: replacement, key: key, attributes: .deviceOnly) {
                if let body { setTransientBody(body, for: reference, sequence: sequence) }
                return (pending, true)
            }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    public func commitPending(for reference: SyncNodeEndpointReference, sequence: UInt64, retainMutation: Bool = true) throws {
        let key = key(for: reference)
        for _ in 0..<16 {
            guard let record = try secretStore.load(key), record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            let state = try decode(record.value)
            guard state.reference == reference, let pending = state.pending, pending.sequence == sequence else { throw AccountRuntimeError.corruptSecret }
            let session = try advanced(state.session, after: sequence)
            let replacement: Data
            if sequence == UInt64.max { replacement = try encode(TerminalState(reference: reference, session: session)) }
            else {
                let retainedMutation: SyncNodeRetainedMutation?
                if retainMutation, pending.path == "/v1/mutations", let body = transientBody(for: reference, sequence: pending.sequence) {
                    retainedMutation = try SyncNodeRetainedMutation(sequence: pending.sequence, issuedAt: pending.issuedAt, requestTranscriptDigest: pending.requestTranscriptDigest, canonicalOperation: body)
                } else if retainMutation, pending.path == "/v1/mutations" { retainedMutation = state.retainedMutation }
                else if pending.path == "/v1/mutations" { retainedMutation = nil }
                else { retainedMutation = state.retainedMutation }
                replacement = try encode(SyncNodeEndpointState(version: 4, reference: reference, session: session, pending: nil, retainedMutation: retainedMutation))
            }
            if try secretStore.compareAndSwap(expected: record.value, replacement: replacement, key: key, attributes: .deviceOnly) {
                clearTransientBody(for: reference, sequence: pending.sequence)
                return
            }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    /// Releases a request that the Node definitively rejected before sequence
    /// consumption. The digest fence prevents a concurrent/different caller
    /// from releasing a reservation it does not own.
    public func rollbackPending(for reference: SyncNodeEndpointReference, sequence: UInt64, requestTranscriptDigest: Data) throws {
        guard requestTranscriptDigest.count == 32 else { throw AccountRuntimeError.corruptSecret }
        let key = key(for: reference)
        for _ in 0..<16 {
            guard let record = try secretStore.load(key), record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            let state = try decode(record.value)
            guard state.reference == reference,
                  let pending = state.pending,
                  pending.sequence == sequence,
                  pending.requestTranscriptDigest == requestTranscriptDigest
            else { throw AccountRuntimeError.corruptSecret }
            let retainedMutation = state.pending?.path == "/v1/mutations" ? nil : state.retainedMutation
            let replacement = try encode(SyncNodeEndpointState(version: 4, reference: reference, session: state.session, pending: nil, retainedMutation: retainedMutation))
            if try secretStore.compareAndSwap(expected: record.value, replacement: replacement, key: key, attributes: .deviceOnly) {
                clearTransientBody(for: reference, sequence: sequence)
                return
            }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    public func clearRetainedMutation(for reference: SyncNodeEndpointReference) throws {
        let key = key(for: reference)
        for _ in 0..<16 {
            guard let record = try secretStore.load(key), record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            let state = try decode(record.value)
            guard state.reference == reference else { throw AccountRuntimeError.corruptSecret }
            guard state.retainedMutation != nil else { return }
            let replacement = try encode(SyncNodeEndpointState(version: 4, reference: reference, session: state.session, pending: state.pending, retainedMutation: nil))
            if try secretStore.compareAndSwap(expected: record.value, replacement: replacement, key: key, attributes: .deviceOnly) { return }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    public func remove(for reference: SyncNodeEndpointReference) throws {
        clearAllTransientBodies(for: reference)
        try secretStore.delete(key(for: reference))
        try secretStore.delete(endpointKey(for: reference))
    }

    /// Temporary, purpose-separated recovery slot for a V3 accepted-or-
    /// uncertain activation. It is deliberately separate from the durable
    /// session record and is removed only after publication and session save.
    public func saveActivationCompletionJournal(accountID: PlainpostAccountID, wire: Data) throws {
        guard (1 ... 512 * 1024).contains(wire.count) else { throw AccountRuntimeError.corruptSecret }
        let journalKey = activationJournalKey(accountID: accountID)
        for _ in 0..<16 {
            let existing = try secretStore.load(journalKey)
            if let existing {
                guard existing.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
                guard existing.value == wire else { throw AccountRuntimeError.corruptSecret }
                return
            }
            if try secretStore.compareAndSwap(expected: nil, replacement: wire, key: journalKey, attributes: .deviceOnly) { return }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    public func loadActivationCompletionJournal(accountID: PlainpostAccountID) throws -> Data? {
        let record = try secretStore.load(activationJournalKey(accountID: accountID))
        guard record == nil || record?.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        return record?.value
    }

    public func clearActivationCompletionJournal(accountID: PlainpostAccountID) throws { try secretStore.delete(activationJournalKey(accountID: accountID)) }

    private func documentsEqual(_ lhs: SyncNodeStoredSession, _ rhs: SyncNodeStoredSession) -> Bool {
        lhs.resultWire == rhs.resultWire && lhs.refreshWire == rhs.refreshWire && lhs.leaseWire == rhs.leaseWire && lhs.trustCommitWire == rhs.trustCommitWire && lhs.admissionEvidenceWire == rhs.admissionEvidenceWire && lhs.cleanupCapabilityWire == rhs.cleanupCapabilityWire
    }

    private func transientKey(for reference: SyncNodeEndpointReference, sequence: UInt64) -> String {
        "\(reference.accountID.rawValue)/\(reference.nodeID.rawValue)/\(reference.trustEpoch.wireValue)/\(sequence)"
    }

    private func transientBody(for reference: SyncNodeEndpointReference, sequence: UInt64) -> Data? {
        transientLock.lock(); defer { transientLock.unlock() }
        return transientBodies[transientKey(for: reference, sequence: sequence)]
    }

    private func setTransientBody(_ body: Data, for reference: SyncNodeEndpointReference, sequence: UInt64) {
        transientLock.lock(); transientBodies[transientKey(for: reference, sequence: sequence)] = body; transientLock.unlock()
    }

    private func clearTransientBody(for reference: SyncNodeEndpointReference, sequence: UInt64) {
        transientLock.lock(); transientBodies.removeValue(forKey: transientKey(for: reference, sequence: sequence)); transientLock.unlock()
    }

    private func clearAllTransientBodies(for reference: SyncNodeEndpointReference) {
        transientLock.lock(); transientBodies = transientBodies.filter { !$0.key.hasPrefix("\(reference.accountID.rawValue)/\(reference.nodeID.rawValue)/\(reference.trustEpoch.wireValue)/") }; transientLock.unlock()
    }
    private func advanced(_ session: SyncNodeStoredSession, after sequence: UInt64) throws -> SyncNodeStoredSession {
        try SyncNodeStoredSession(resultWire: session.resultWire, refreshWire: session.refreshWire, leaseWire: session.leaseWire, trustCommitWire: session.trustCommitWire, admissionEvidenceWire: session.admissionEvidenceWire, cleanupCapabilityWire: session.cleanupCapabilityWire, nextSequence: sequence == UInt64.max ? UInt64.max : sequence + 1)
    }
    private struct TerminalState: Codable {
        let version: Int
        let reference: SyncNodeEndpointReference
        let session: SyncNodeStoredSession
        init(reference: SyncNodeEndpointReference, session: SyncNodeStoredSession) { version = 3; self.reference = reference; self.session = session }
    }
    private func key(for reference: SyncNodeEndpointReference) -> AccountSecretKey { key(accountID: reference.accountID, nodeID: reference.nodeID, trustEpoch: reference.trustEpoch) }
    private func endpointKey(for reference: SyncNodeEndpointReference) -> AccountSecretKey { AccountSecretKey(service: service, account: "endpoint.v1.\(reference.accountID.rawValue).\(reference.nodeID.rawValue).\(reference.trustEpoch.wireValue)", accessGroup: accessGroup) }
    private func key(accountID: PlainpostAccountID, nodeID: AccountDeviceID, trustEpoch: AccountTrustEpoch) -> AccountSecretKey { AccountSecretKey(service: service, account: "v1.\(accountID.rawValue).\(nodeID.rawValue).\(trustEpoch.wireValue)", accessGroup: accessGroup) }
    private func activationJournalKey(accountID: PlainpostAccountID) -> AccountSecretKey { AccountSecretKey(service: service, account: "activation-completion.v1.\(accountID.rawValue)", accessGroup: accessGroup) }
    private func endpointKey(reference: SyncNodeEndpointReference, identity: AccountDeviceIdentity) throws -> SymmetricKey {
        let shared = try identity.sharedSecret(with: identity.publicBundle.agreementKey)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: endpointAAD(reference))), sharedInfo: Data("Plainpost.SyncNodeCachedEndpoint.v1".utf8), outputByteCount: 32)
    }
    private func endpointAAD(_ reference: SyncNodeEndpointReference) -> Data {
        Data("Plainpost.SyncNodeCachedEndpoint.v1\u{0}\(reference.accountID.rawValue)\u{0}\(reference.nodeID.rawValue)\u{0}\(reference.trustEpoch.wireValue)\u{0}\(reference.endpointCiphertext.base64EncodedString())".utf8)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func decode(_ wire: Data) throws -> SyncNodeEndpointState {
        if let state = try? JSONDecoder().decode(SyncNodeEndpointState.self, from: wire),
           state.version == 4, (try? encode(state)) == wire {
            return state
        }
        if let legacy = try? JSONDecoder().decode(SyncNodeEndpointStateLegacyV4.self, from: wire),
           legacy.version == 4, (try? encode(legacy)) == wire {
            let retained: SyncNodeRetainedMutation?
            if let old = legacy.retainedMutation, old.method == "POST", old.path == "/v1/mutations", let body = old.body,
               (try? validateCanonicalMutationPayload(body)) == body {
                retained = try SyncNodeRetainedMutation(sequence: old.sequence, issuedAt: old.issuedAt, requestTranscriptDigest: old.requestTranscriptDigest, canonicalOperation: body)
            } else { retained = nil }
            return SyncNodeEndpointState(version: 4, reference: legacy.reference, session: legacy.session, pending: legacy.pending, retainedMutation: retained)
        }
        guard let legacy = try? JSONDecoder().decode(SyncNodeEndpointStateV2.self, from: wire),
              legacy.version == 2, (try? encode(legacy)) == wire else {
            throw AccountRuntimeError.corruptSecret
        }
        return SyncNodeEndpointState(version: legacy.version, reference: legacy.reference, session: legacy.session, pending: legacy.pending, retainedMutation: nil)
    }
    private func validateCanonicalMutationPayload(_ body: Data) throws -> Data {
        do {
            let request = try NodeSyncCodec.decodeMutationRequest(body)
            guard try NodeSyncCodec.encodeMutationRequest(request) == body else { throw AccountRuntimeError.corruptSecret }
            let operation = try NodeSyncCodec.decodeOperation(request.canonicalOperation)
            guard try NodeSyncCodec.encodeOperation(operation) == request.canonicalOperation else { throw AccountRuntimeError.corruptSecret }
            return body
        } catch let error as AccountRuntimeError { throw error }
        catch { throw AccountRuntimeError.corruptSecret }
    }
    private func decodeStored(_ wire: Data) throws -> (reference: SyncNodeEndpointReference, session: SyncNodeStoredSession, pending: SyncNodePendingRequest?, retainedMutation: SyncNodeRetainedMutation?, terminal: Bool) {
        if let state = try? decode(wire) { return (state.reference, state.session, state.pending, state.retainedMutation, false) }
        guard let terminal = try? JSONDecoder().decode(TerminalState.self, from: wire), terminal.version == 3, (try? encode(terminal)) == wire else { throw AccountRuntimeError.corruptSecret }
        return (terminal.reference, terminal.session, nil, nil, true)
    }
}

/// Moves each record from a legacy Keychain access group into the store's
/// group the first time it is read. The legacy item is deleted only after the
/// copy is present in the new group, so a failed write keeps the credential.
/// A record already present in the new group always wins: the legacy copy is
/// then stale, and reviving it could reuse a consumed client sequence.
private final class SyncNodeKeychainGroupMigration: AccountSecretStoring, @unchecked Sendable {
    /// Serializes migration with deletion across store instances, so an
    /// in-flight copy cannot revive a record another instance just removed.
    private static let migrationLock = NSLock()
    private let backing: any AccountSecretStoring
    private let accessGroup: String
    private let legacyAccessGroup: String
    private var clearedLegacyKeys: Set<AccountSecretKey> = []

    init(backing: any AccountSecretStoring, accessGroup: String, legacyAccessGroup: String) {
        self.backing = backing; self.accessGroup = accessGroup; self.legacyAccessGroup = legacyAccessGroup
    }

    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? {
        guard let legacyKey = legacyKey(for: key) else { return try backing.load(key) }
        Self.migrationLock.lock()
        guard !clearedLegacyKeys.contains(legacyKey) else {
            Self.migrationLock.unlock()
            return try backing.load(key)
        }
        defer { Self.migrationLock.unlock() }
        if let current = try backing.load(key) {
            clearLegacy(legacyKey)
            return current
        }
        guard let legacy = try backing.load(legacyKey) else {
            clearedLegacyKeys.insert(legacyKey)
            return nil
        }
        guard legacy.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        // A false result means a copy appeared meanwhile; it wins either way.
        _ = try backing.compareAndSwap(expected: nil, replacement: legacy.value, key: key, attributes: legacy.attributes)
        guard let migrated = try backing.load(key) else { throw AccountRuntimeError.secretUnavailable }
        clearLegacy(legacyKey)
        return migrated
    }

    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        try backing.replace(value, key: key, attributes: attributes)
    }

    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }

    /// Deletes the legacy copy first, so a removed record cannot come back
    /// from the legacy group on the next read.
    func delete(_ key: AccountSecretKey) throws {
        guard let legacyKey = legacyKey(for: key) else { return try backing.delete(key) }
        Self.migrationLock.lock(); defer { Self.migrationLock.unlock() }
        try backing.delete(legacyKey)
        clearedLegacyKeys.insert(legacyKey)
        try backing.delete(key)
    }

    private func legacyKey(for key: AccountSecretKey) -> AccountSecretKey? {
        guard key.accessGroup == accessGroup else { return nil }
        return AccountSecretKey(service: key.service, account: key.account, accessGroup: legacyAccessGroup)
    }

    /// The copy is already durable in the new group; a failed delete is
    /// retried on the next read.
    private func clearLegacy(_ legacyKey: AccountSecretKey) {
        guard (try? backing.delete(legacyKey)) != nil else { return }
        clearedLegacyKeys.insert(legacyKey)
    }
}
