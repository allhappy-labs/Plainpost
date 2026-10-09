import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// The endpoint itself is kept inside the existing opaque account metadata
/// envelope. Central receives neither a plaintext endpoint nor a setup code.
public struct SyncNodePublishedEndpointV1: Equatable, Sendable {
    public let accountID: PlainpostAccountID
    public let nodeID: AccountDeviceID
    public let trustEpoch: AccountTrustEpoch
    public let endpoint: URL

    public init(accountID: PlainpostAccountID, nodeID: AccountDeviceID, trustEpoch: AccountTrustEpoch, endpoint: URL) throws {
        let canonical = endpoint.absoluteString
        guard try NodeEndpointURL(canonical).url == endpoint else { throw AccountRuntimeError.untrustedResponse }
        self.accountID = accountID; self.nodeID = nodeID; self.trustEpoch = trustEpoch; self.endpoint = endpoint
    }

    func wire() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "account.sync-node-endpoint.v1", "accountID": accountID.rawValue, "nodeID": nodeID.rawValue, "trustEpoch": trustEpoch.wireValue, "endpoint": endpoint.absoluteString], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func decode(_ wire: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: wire) as? [String: Any], Set(object.keys) == Set(["kind", "accountID", "nodeID", "trustEpoch", "endpoint"]), object["kind"] as? String == "account.sync-node-endpoint.v1", let account = object["accountID"] as? String, let node = object["nodeID"] as? String, let epoch = object["trustEpoch"] as? String, let endpoint = object["endpoint"] as? String, let url = URL(string: endpoint) else { throw AccountRuntimeError.untrustedResponse }
        let value = try Self(accountID: PlainpostAccountID(account), nodeID: AccountDeviceID(node), trustEpoch: AccountTrustEpoch(wire: epoch), endpoint: url)
        guard try value.wire() == wire else { throw AccountRuntimeError.untrustedResponse }
        return value
    }
}

/// The fixed account-record slot is an ownership boundary, not a server-side
/// Node endpoint field. Its normal encrypted-record revision is the CAS.
public enum SyncNodeEndpointMetadata {
    public static let recordID = try! AccountRecordID("8a682d12-0b6e-4e59-8e4e-95f0f2914201")

    public static func discover(remote: any SyncNodeEndpointMetadataRemote, trust: AccountTrustCoordinator, accountID: PlainpostAccountID, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date = Date()) async throws -> SyncNodePublishedEndpointV1? {
        guard let record = try await remote.syncNodeEndpointRecord(accountID: accountID, recordID: recordID, credentials: credentials, device: device, now: now) else { return nil }
        return try SyncNodePublishedEndpointV1.decode(await trust.openAccountRecord(record))
    }

    static func publish(_ value: SyncNodePublishedEndpointV1, replacing replacedNodeID: AccountDeviceID?, remote: any SyncNodeEndpointMetadataRemote, trust: AccountTrustCoordinator, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws {
        if let existing = try await discover(remote: remote, trust: trust, accountID: value.accountID, credentials: credentials, device: device, now: now) {
            if existing == value { return }
            // A different endpoint may replace only the exact Node revoked by
            // the verified admission.  A second client can still converge by
            // discovering its authenticated winner after the CAS below.
            guard let replacedNodeID, existing.nodeID == replacedNodeID else { throw AccountRuntimeError.untrustedResponse }
        }
        // Do not advance local high water until Central has accepted a record
        // and we have opened the winner.  Otherwise a failed CAS could make
        // this device reject the actual concurrent winner as a rollback.
        let record = try await trust.prepareAccountRecordForRemoteCAS(id: recordID, plaintext: value.wire())
        do {
            try await remote.putSyncNodeEndpointRecord(record, credentials: credentials, device: device, now: now)
            guard try SyncNodePublishedEndpointV1.decode(await trust.openAccountRecord(record)) == value else { throw AccountRuntimeError.untrustedResponse }
        } catch {
            // A concurrent first/replacement client may have won.  Accept only
            // the exact authenticated endpoint; never take one from Central.
            guard let existing = try await discover(remote: remote, trust: trust, accountID: value.accountID, credentials: credentials, device: device, now: now), existing == value else { throw error }
        }
    }
}

/// Production activation owner. It decrypts the setup envelope transiently,
/// sends only V3 to the canonical MagicDNS endpoint, then persists ciphertext
/// plus signed documents in ThisDeviceOnly storage.
public actor PrivateSyncNodeEnrollmentActivator: SyncNodeEnrollmentActivating {
    private let remote: any SyncNodeEndpointMetadataRemote
    private let trust: AccountTrustCoordinator
    private let store: SyncNodeEndpointStore
    private let client: NodeTLSClient
    /// Fixes the owning account and device. Central requests read the
    /// current session through `currentCredentials()`.
    private let credentials: AccountSessionCredentials
    private let credentialsProvider: SyncNodeEnrollmentCredentialsProvider
    private let device: AccountDeviceIdentity
    private struct PendingActivation {
        let client: NodeActivationClient
        let published: SyncNodePublishedEndpointV1
        let signingKeyDigest: Data
        let replacedNodeID: AccountDeviceID?
        let reference: SyncNodeEndpointReference
        let session: SyncNodeStoredSession
    }

    /// Temporary ThisDeviceOnly recovery record. It contains the bounded V3
    /// documents required to replay activation plus publication/session inputs;
    /// no setup code or endpoint plaintext is retained.
    private struct CompletionJournal: Codable {
        let version: Int
        let reference: SyncNodeEndpointReference
        /// Purpose-separated AEAD envelope of the endpoint publication
        /// document. The raw journal must never contain an endpoint literal.
        let sealedPublishedWire: Data
        /// Canonical public-claim document: enough to recreate the signed
        /// proof transcript, but it contains neither setup material nor a
        /// Node private key.
        let claimProofWire: Data
        let replacedNodeID: String?
        let session: SyncNodeStoredSession
        let resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, cleanupCapabilityWire, claimProofSignature: Data

        init(pending: PendingActivation, request: ActivationRequestV3, claim: AccountNodeEnrollmentPublicClaimV1, device: AccountDeviceIdentity) throws {
            version = 2; reference = pending.reference; sealedPublishedWire = try Self.seal(pending.published.wire(), reference: pending.reference, device: device); claimProofWire = try AccountWireCodec.encodeNodeEnrollmentPublicClaim(claim); replacedNodeID = pending.replacedNodeID?.rawValue; session = pending.session
            resultWire = request.resultWire; refreshWire = request.refreshWire; leaseWire = request.leaseWire; trustCommitWire = request.trustCommitWire; admissionEvidenceWire = request.admissionEvidenceWire; cleanupCapabilityWire = request.cleanupCapabilityWire; claimProofSignature = request.claimProofSignature
            try Self.verifyBindings(reference: reference, published: pending.published, claim: claim, session: session, request: request, replacedNodeID: pending.replacedNodeID)
        }

        func pending(client: NodeTLSClient, accountID: PlainpostAccountID, device: AccountDeviceIdentity) throws -> (PendingActivation, ActivationRequestV3) {
            guard version == 2, reference.accountID == accountID, (29...4096).contains(sealedPublishedWire.count), claimProofWire.count <= 32 * 1024,
                  [resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, cleanupCapabilityWire, claimProofSignature].allSatisfy({ !$0.isEmpty && $0.count <= 64 * 1024 })
            else { throw AccountRuntimeError.corruptSecret }
            let published = try SyncNodePublishedEndpointV1.decode(try Self.open(sealedPublishedWire, reference: reference, device: device))
            let claim = try AccountWireCodec.decodeNodeEnrollmentPublicClaim(claimProofWire)
            guard try AccountWireCodec.encodeNodeEnrollmentPublicClaim(claim) == claimProofWire else { throw AccountRuntimeError.corruptSecret }
            let canonicalReference = try SyncNodeEndpointReference(accountID: reference.accountID, nodeID: reference.nodeID, trustEpoch: reference.trustEpoch, endpointCiphertext: reference.endpointCiphertext)
            let canonicalSession = try SyncNodeStoredSession(resultWire: session.resultWire, refreshWire: session.refreshWire, leaseWire: session.leaseWire, trustCommitWire: session.trustCommitWire, admissionEvidenceWire: session.admissionEvidenceWire, cleanupCapabilityWire: session.cleanupCapabilityWire, nextSequence: session.nextSequence)
            guard canonicalReference == reference, canonicalSession == session,
                  published.accountID == accountID, published.nodeID == reference.nodeID, published.trustEpoch == reference.trustEpoch,
                  session.resultWire == resultWire, session.refreshWire == refreshWire, session.leaseWire == leaseWire,
                  session.trustCommitWire == trustCommitWire, session.admissionEvidenceWire == admissionEvidenceWire,
                  session.cleanupCapabilityWire == cleanupCapabilityWire
            else { throw AccountRuntimeError.corruptSecret }
            let replaced: AccountDeviceID?
            if let replacedNodeID { replaced = try AccountDeviceID(replacedNodeID) }
            else { replaced = nil }
            let request = try ActivationRequestV3(resultWire: resultWire, refreshWire: refreshWire, leaseWire: leaseWire, trustCommitWire: trustCommitWire, admissionEvidenceWire: admissionEvidenceWire, cleanupCapabilityWire: cleanupCapabilityWire, claimProofSignature: claimProofSignature)
            try Self.verifyBindings(reference: reference, published: published, claim: claim, session: canonicalSession, request: request, replacedNodeID: replaced)
            return (PendingActivation(client: NodeActivationClient(endpoint: try NodeEndpointURL(published.endpoint.absoluteString), client: client), published: published, signingKeyDigest: Data(SHA256.hash(data: claim.signingPublicKey)), replacedNodeID: replaced, reference: reference, session: session), request)
        }

        private static func verifyBindings(reference: SyncNodeEndpointReference, published: SyncNodePublishedEndpointV1, claim: AccountNodeEnrollmentPublicClaimV1, session: SyncNodeStoredSession, request: ActivationRequestV3, replacedNodeID: AccountDeviceID?) throws {
            let evidence = try AccountWireCodec.decodeNodeEnrollmentAdmissionEvidence(request.admissionEvidenceWire)
            let trustCommit = try AccountWireCodec.decodeTrustCommit(request.trustCommitWire)
            let result = try AccountWireCodec.decodeNodeEnrollmentResultV2(request.resultWire)
            let refresh = try AccountWireCodec.decodeNodeRefreshCredentialV2(request.refreshWire)
            let lease = try AccountWireCodec.decodeNodeOfflineLeaseV2(request.leaseWire)
            let capability = try AccountWireCodec.decodeSyncNodeCleanupCapability(request.cleanupCapabilityWire)
            _ = try AccountNodeEnrollmentAdmissionResponseV2(result: result, refreshCredential: refresh, offlineLease: lease, cleanupCapability: capability)
            try AccountWireCodec.validateLowSSignature(request.claimProofSignature)
            let proofKey = try P256.Signing.PublicKey(x963Representation: claim.signingPublicKey)
            let proofSignature = try P256.Signing.ECDSASignature(rawRepresentation: request.claimProofSignature)
            let binding = result.binding.base
            guard proofKey.isValidSignature(proofSignature, for: AccountTranscript.nodeEnrollmentClaimProof(claim)),
                  claim.endpointCiphertext == reference.endpointCiphertext,
                  claim.claimID == evidence.claimID, claim.nodeDeviceID == reference.nodeID,
                  claim.signingPublicKey == evidence.signingPublicKey,
                  claim.agreementPublicKey == evidence.agreementPublicKey,
                  claim.noiseStaticPublicKey == evidence.noiseStaticPublicKey,
                  claim.endpointDigest == evidence.endpointDigest,
                  evidence.matchingTranscriptDigest == Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentMatchingConfirmation(claim, accountID: reference.accountID))),
                  evidence.accountID == reference.accountID, evidence.trustEpoch == reference.trustEpoch,
                  evidence.nodeDeviceID == reference.nodeID, evidence.replacedNodeID == replacedNodeID,
                  trustCommit.state.accountID == evidence.accountID, trustCommit.state.epoch == evidence.trustEpoch,
                  binding.accountID == evidence.accountID, binding.trustEpoch == evidence.trustEpoch,
                  binding.claimID == evidence.claimID, binding.nodeDeviceID == evidence.nodeDeviceID,
                  binding.action == evidence.action, binding.replacedNodeID == evidence.replacedNodeID,
                  binding.admissionEvidenceDigest == Data(SHA256.hash(data: request.admissionEvidenceWire)),
                  Data(SHA256.hash(data: Data(published.endpoint.absoluteString.utf8))) == evidence.endpointDigest,
                  session.resultWire == request.resultWire, session.refreshWire == request.refreshWire,
                  session.leaseWire == request.leaseWire, session.trustCommitWire == request.trustCommitWire,
                  session.admissionEvidenceWire == request.admissionEvidenceWire,
                  session.cleanupCapabilityWire == request.cleanupCapabilityWire
            else { throw AccountRuntimeError.corruptSecret }
        }

        private static func seal(_ plaintext: Data, reference: SyncNodeEndpointReference, device: AccountDeviceIdentity) throws -> Data {
            let key = try journalKey(reference: reference, device: device)
            do {
                let box = try AES.GCM.seal(plaintext, using: key, authenticating: journalAAD(reference))
                guard let combined = box.combined else { throw AccountRuntimeError.cryptographicFailure }
                return combined
            } catch let error as AccountRuntimeError { throw error }
            catch { throw AccountRuntimeError.cryptographicFailure }
        }

        private static func open(_ wire: Data, reference: SyncNodeEndpointReference, device: AccountDeviceIdentity) throws -> Data {
            do {
                return try AES.GCM.open(AES.GCM.SealedBox(combined: wire), using: try journalKey(reference: reference, device: device), authenticating: journalAAD(reference))
            } catch { throw AccountRuntimeError.corruptSecret }
        }

        private static func journalKey(reference: SyncNodeEndpointReference, device: AccountDeviceIdentity) throws -> SymmetricKey {
            let aad = journalAAD(reference)
            let shared = try device.sharedSecret(with: device.publicBundle.agreementKey)
            return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: aad)), sharedInfo: Data("Plainpost.SyncNodeActivationCompletion.Endpoint.v1".utf8), outputByteCount: 32)
        }

        private static func journalAAD(_ reference: SyncNodeEndpointReference) -> Data {
            Data("Plainpost.SyncNodeActivationCompletion.Endpoint.v1\\u{0}\(reference.accountID.rawValue)\\u{0}\(reference.nodeID.rawValue)\\u{0}\(reference.trustEpoch.wireValue)\\u{0}\(reference.endpointCiphertext.base64EncodedString())".utf8)
        }
    }
    private var pendingActivation: PendingActivation?
    private var pendingRequest: ActivationRequestV3?
    public var hasPendingActivation: Bool { pendingActivation != nil }

    /// The recovery journal may retire only the profile for the exact Node it
    /// is finishing. A newer imported setup remains available for its own
    /// explicit connection attempt.
    public func pendingActivationMatches(profile: SyncNodeBootstrapProfile) -> Bool {
        guard let pendingActivation else { return false }
        return pendingActivation.published.nodeID == profile.nodeDeviceID
            && pendingActivation.signingKeyDigest == profile.signingKeyDigest
            && pendingActivation.published.endpoint == profile.canonicalOrigin.url
    }

    public init(remote: any SyncNodeEndpointMetadataRemote, trust: AccountTrustCoordinator, store: SyncNodeEndpointStore, client: NodeTLSClient = NodeTLSClient(), credentials: AccountSessionCredentials, credentialsProvider: @escaping SyncNodeEnrollmentCredentialsProvider, device: AccountDeviceIdentity) throws {
        self.remote = remote; self.trust = trust; self.store = store; self.client = client; self.credentials = credentials; self.credentialsProvider = credentialsProvider; self.device = device
        if let wire = try store.loadActivationCompletionJournal(accountID: credentials.accountID) {
            let decoder = JSONDecoder()
            let journal = try decoder.decode(CompletionJournal.self, from: wire)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(journal) == wire else { throw AccountRuntimeError.corruptSecret }
            let restored = try journal.pending(client: client, accountID: credentials.accountID, device: device)
            pendingActivation = restored.0; pendingRequest = restored.1
        }
    }

    public func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {
        guard let ciphertext = claim.endpointCiphertext, credentials.accountID == request.evidence.accountID else { throw AccountRuntimeError.untrustedResponse }
        var setupBytes = Array(setupCode)
        defer { setupBytes.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; setupBytes.removeAll(keepingCapacity: false) }
        let endpoint = try NodeEndpointCipher.open(ciphertext: ciphertext, setupCode: Data(setupBytes), binding: try syncNodeEnrollmentClaimBinding(claim))
        guard try NodeEndpointURL(endpoint.absoluteString) == expectedOrigin else {
            throw AccountRuntimeError.untrustedResponse
        }
        let published = try SyncNodePublishedEndpointV1(accountID: credentials.accountID, nodeID: claim.nodeDeviceID, trustEpoch: request.evidence.trustEpoch, endpoint: endpoint)
        let requestV3 = try activationRequest(response: response, request: request)
        let reference = try SyncNodeEndpointReference(accountID: credentials.accountID, nodeID: claim.nodeDeviceID, trustEpoch: request.evidence.trustEpoch, endpointCiphertext: ciphertext)
        let session = try storedSession(response: response, request: request)
        let activationClient = NodeActivationClient(endpoint: try NodeEndpointURL(endpoint.absoluteString), client: client)
        let pending = PendingActivation(client: activationClient, published: published, signingKeyDigest: Data(SHA256.hash(data: claim.signingPublicKey)), replacedNodeID: request.evidence.replacedNodeID, reference: reference, session: session)
        let journal = try CompletionJournal(pending: pending, request: requestV3, claim: claim, device: device)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try store.saveActivationCompletionJournal(accountID: credentials.accountID, wire: try encoder.encode(journal))
        pendingActivation = pending; pendingRequest = requestV3
        do {
            try await activationClient.activate(requestV3)
            try await completePendingActivation()
        } catch let error as NodeActivationError where error == .rejected {
            await activationClient.completeActivation()
            pendingActivation = nil; pendingRequest = nil; try? store.clearActivationCompletionJournal(accountID: credentials.accountID)
            throw error
        } catch {
            // The Node may have accepted V3 before a metadata/Keychain error
            // or cancellation was observed.  Keep the exact request plus all
            // idempotent local publication inputs for recovery.
            throw NodeActivationError.uncertain
        }
    }

    public func retryUncertainActivation() async throws {
        guard let pendingActivation, let pendingRequest else { throw AccountRuntimeError.untrustedResponse }
        do {
            if await pendingActivation.client.hasPendingActivationReplay { try await pendingActivation.client.retryUncertainActivation() }
            else { try await pendingActivation.client.activate(pendingRequest) }
            try await completePendingActivation()
        } catch let error as NodeActivationError where error == .rejected {
            await pendingActivation.client.completeActivation()
            self.pendingActivation = nil; self.pendingRequest = nil; try? store.clearActivationCompletionJournal(accountID: credentials.accountID)
            throw error
        } catch { throw NodeActivationError.uncertain }
    }

    /// Factory-only restart hook. It runs before a fresh enrollment can be
    /// created, so a process death cannot silently strand a V3 acceptance
    /// between Node acknowledgement and the local publication/session steps.
    public func resumePendingActivation() async throws {
        guard pendingActivation != nil else { return }
        try await retryUncertainActivation()
    }

    public func cancelPendingActivation() async { await pendingActivation?.client.cancelPendingActivation() }

    private func completePendingActivation() async throws {
        guard let pendingActivation, let pendingRequest else { throw AccountRuntimeError.untrustedResponse }
        // Publish only after a V3 acceptance, then save exactly the documents
        // bound by that acceptance. Both operations are idempotent on retry.
        let sessionCredentials = try await currentCredentials()
        try await SyncNodeEndpointMetadata.publish(pendingActivation.published, replacing: pendingActivation.replacedNodeID, remote: remote, trust: trust, credentials: sessionCredentials, device: device, now: Date())
        try store.save(reference: pendingActivation.reference, session: pendingActivation.session)
        try store.saveEndpoint(pendingActivation.published.endpoint, for: pendingActivation.reference, identity: device)
        let successor = try AccountWireCodec.decodeTrustCommit(pendingRequest.trustCommitWire)
        let evidence = try AccountWireCodec.decodeNodeEnrollmentAdmissionEvidence(pendingRequest.admissionEvidenceWire)
        try await trust.acceptSyncNodeEnrollmentCommit(successor, evidence: evidence)
        await pendingActivation.client.completeActivation()
        try store.clearActivationCompletionJournal(accountID: credentials.accountID)
        self.pendingActivation = nil; self.pendingRequest = nil
    }

    /// The current session for the owning account and device; a session for
    /// another owner is refused and the recovery journal is kept.
    private func currentCredentials() async throws -> AccountSessionCredentials {
        let current = try await credentialsProvider()
        guard current.accountID == credentials.accountID, current.deviceID == credentials.deviceID else { throw AccountRuntimeError.untrustedResponse }
        return current
    }

    private func activationRequest(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest) throws -> ActivationRequestV3 {
        try ActivationRequestV3(resultWire: AccountWireCodec.encodeNodeEnrollmentResultV2(response.result), refreshWire: AccountWireCodec.encodeNodeRefreshCredentialV2(response.refreshCredential), leaseWire: AccountWireCodec.encodeNodeOfflineLeaseV2(response.offlineLease), trustCommitWire: AccountWireCodec.encodeTrustCommit(request.trustCommit), admissionEvidenceWire: AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence), cleanupCapabilityWire: AccountWireCodec.encodeSyncNodeCleanupCapability(response.cleanupCapability), claimProofSignature: request.claimProofSignature)
    }

    private func storedSession(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest) throws -> SyncNodeStoredSession {
        try SyncNodeStoredSession(resultWire: AccountWireCodec.encodeNodeEnrollmentResultV2(response.result), refreshWire: AccountWireCodec.encodeNodeRefreshCredentialV2(response.refreshCredential), leaseWire: AccountWireCodec.encodeNodeOfflineLeaseV2(response.offlineLease), trustCommitWire: AccountWireCodec.encodeTrustCommit(request.trustCommit), admissionEvidenceWire: AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence), cleanupCapabilityWire: AccountWireCodec.encodeSyncNodeCleanupCapability(response.cleanupCapability), nextSequence: 1)
    }

}
