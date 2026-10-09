import Foundation

/// Public peer-control input relayed by the central rendezvous. Its closed
/// canonical envelope is defined by `AccountWireCodec`; the service never
/// computes the matching code or receives private material.
public struct TrustHandshakeOfferV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let existingDeviceID: AccountDeviceID
    public let pendingDeviceID: AccountDeviceID
    public let existingPublicBundle: AccountPublicKeyBundle
    public let pendingPublicBundle: AccountPublicKeyBundle
    public let existingNonce: Data
    public let createdAtUnixMilliseconds: PositiveUInt64
    public let expiresAtUnixMilliseconds: PositiveUInt64

    public init(
        accountID: PlainpostAccountID,
        existingDeviceID: AccountDeviceID,
        pendingDeviceID: AccountDeviceID,
        existingPublicBundle: AccountPublicKeyBundle,
        pendingPublicBundle: AccountPublicKeyBundle,
        existingNonce: Data,
        createdAtUnixMilliseconds: PositiveUInt64,
        expiresAtUnixMilliseconds: PositiveUInt64
    ) throws {
        guard existingDeviceID != pendingDeviceID,
              existingPublicBundle != pendingPublicBundle,
              existingNonce.count == 32,
              createdAtUnixMilliseconds < expiresAtUnixMilliseconds,
              expiresAtUnixMilliseconds.value - createdAtUnixMilliseconds.value <= 300_000
        else { throw AccountProtocolError.invalidTrustHandshake }
        self.accountID = accountID
        self.existingDeviceID = existingDeviceID
        self.pendingDeviceID = pendingDeviceID
        self.existingPublicBundle = existingPublicBundle
        self.pendingPublicBundle = pendingPublicBundle
        self.existingNonce = existingNonce
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
    }
}

/// The pending device adds its nonce to a previously received offer. The
/// response deliberately contains no private material.
public struct TrustHandshakeResponseV1: Hashable, Sendable {
    public let offer: TrustHandshakeOfferV1
    public let pendingNonce: Data

    public init(offer: TrustHandshakeOfferV1, pendingNonce: Data) throws {
        guard pendingNonce.count == 32, pendingNonce != offer.existingNonce else { throw AccountProtocolError.invalidTrustHandshake }
        self.offer = offer
        self.pendingNonce = pendingNonce
    }
}

public struct AccountTrustAdmissionOfferEnvelopeV1: Hashable, Sendable {
    public let offerDigest: Data
    public let offer: TrustHandshakeOfferV1
    public init(offerDigest: Data, offer: TrustHandshakeOfferV1) throws {
        guard offerDigest.count == 32 else { throw AccountProtocolError.malformedWire }
        self.offerDigest = offerDigest; self.offer = offer
    }
}

public struct AccountTrustAdmissionResponseEnvelopeV1: Hashable, Sendable {
    public let offerDigest: Data
    public let response: TrustHandshakeResponseV1
    public init(offerDigest: Data, response: TrustHandshakeResponseV1) throws {
        guard offerDigest.count == 32 else { throw AccountProtocolError.malformedWire }
        self.offerDigest = offerDigest; self.response = response
    }
}

public struct AccountTrustAdmissionCancelEnvelopeV1: Hashable, Sendable {
    public let offerDigest: Data
    public init(offerDigest: Data) throws {
        guard offerDigest.count == 32 else { throw AccountProtocolError.malformedWire }
        self.offerDigest = offerDigest
    }
}

/// Complete, transportable authority for one admission transition. The
/// response contains the complete offer; no private key material is present.
public struct AccountTrustAdmissionEvidenceV1: Hashable, Sendable {
    public let pendingDevice: AccountPendingDevice
    public let response: TrustHandshakeResponseV1

    public init(pendingDevice: AccountPendingDevice, response: TrustHandshakeResponseV1) {
        self.pendingDevice = pendingDevice
        self.response = response
    }
}

/// Complete, transportable authority for one recovery transition. The
/// historical manifest is independently signed by the pinned offline root and
/// remains verifiable after online-key overlap eviction.
public struct AccountTrustRecoveryEvidenceV1: Hashable, Sendable {
    public let authorization: AccountRecoveryAuthorization
    public let historicalManifest: AccountBootstrapManifest

    public init(authorization: AccountRecoveryAuthorization, historicalManifest: AccountBootstrapManifest) {
        self.authorization = authorization
        self.historicalManifest = historicalManifest
    }
}

public enum AccountTrustTransitionEvidenceV1: Hashable, Sendable {
    case admission(AccountTrustAdmissionEvidenceV1)
    case recovery(AccountTrustRecoveryEvidenceV1)
    /// The dedicated Sync Node route is the only producer of this evidence.
    /// It is intentionally not a generic Apple-device admission evidence.
    case syncNodeEnrollment(AccountNodeEnrollmentAdmissionEvidenceV1)
}

/// Task 7 transports history as exact commit/evidence pairs. Evidence is
/// mandatory only for authority-bearing admission and recovery transitions.
public struct AccountTrustHistoryEntryV1: Hashable, Sendable {
    public let commit: AccountTrustStateCommit
    public let evidence: AccountTrustTransitionEvidenceV1?

    public init(commit: AccountTrustStateCommit, evidence: AccountTrustTransitionEvidenceV1?) throws {
        switch (commit.state.transition.kind, evidence) {
        case (.admission, .admission), (.recovery, .recovery),
             (.genesis, nil), (.revocation, nil), (.suspension, nil):
            break
        case (.admission, .syncNodeEnrollment(let evidence)) where evidence.action == .enroll,
             (.revocation, .syncNodeEnrollment(let evidence)) where evidence.action == .replace:
            break
        default:
            throw AccountProtocolError.invalidTransition
        }
        self.commit = commit
        self.evidence = evidence
    }
}

public typealias PendingAccountDevice = AccountPendingDevice
public typealias AccountTrustStateV1 = AccountTrustState
public typealias AccountGroupKeyPackageV1 = AccountGroupKeyPackage
public typealias TrustStateCommitV1 = AccountTrustStateCommit

public struct AccountTrustCheckpointV1: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let epoch: AccountTrustEpoch
    public let revision: PositiveUInt64
    public let commitDigest: Data

    public init(accountID: PlainpostAccountID, epoch: AccountTrustEpoch, revision: PositiveUInt64, commitDigest: Data) throws {
        guard commitDigest.count == 32 else { throw AccountProtocolError.malformedWire }
        self.accountID = accountID
        self.epoch = epoch
        self.revision = revision
        self.commitDigest = commitDigest
    }
}

public struct AccountTrustPageCheckpointV1: Hashable, Sendable {
    public let epoch: AccountTrustEpoch
    public let revision: PositiveUInt64
    public let commitDigest: Data
    public init(epoch: AccountTrustEpoch, revision: PositiveUInt64, commitDigest: Data) throws {
        guard commitDigest.count == 32 else { throw AccountProtocolError.malformedWire }
        self.epoch = epoch; self.revision = revision; self.commitDigest = commitDigest
    }
}

public enum AccountTrustAfterV1: Hashable, Sendable {
    case genesis
    case checkpoint(AccountTrustPageCheckpointV1)
}

public struct AccountTrustCursorV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let after: AccountTrustAfterV1
    public let snapshotHead: AccountTrustPageCheckpointV1
    public let issuedAt: String
    public let expiresAt: String
    public let serverKeyID: String
    public let signature: Data
    public init(accountID: PlainpostAccountID, after: AccountTrustAfterV1, snapshotHead: AccountTrustPageCheckpointV1, issuedAt: String, expiresAt: String, serverKeyID: String, signature: Data) throws {
        guard let issued = AccountWireCodec.parseTrustTimestamp(issuedAt), let expires = AccountWireCodec.parseTrustTimestamp(expiresAt), issued < expires, expires.timeIntervalSince(issued) <= 300, AccountWireCodec.isKeyID(serverKeyID) else { throw AccountProtocolError.malformedWire }
        try AccountWireCodec.validateLowSSignature(signature)
        self.accountID = accountID; self.after = after; self.snapshotHead = snapshotHead; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.serverKeyID = serverKeyID; self.signature = signature
    }
}

public struct AccountTrustStatePageV1: Hashable, Sendable {
    public let requestCursor: AccountTrustCursorV1
    public let accountID: PlainpostAccountID
    public let snapshotHead: AccountTrustPageCheckpointV1
    public let entries: [AccountTrustHistoryEntryV1]
    public let nextCursor: AccountTrustCursorV1?
    public let terminal: Bool
    public let issuedAt: String
    public let expiresAt: String
    public let serverKeyID: String
    public let serverSignature: Data
    public init(requestCursor: AccountTrustCursorV1, accountID: PlainpostAccountID, snapshotHead: AccountTrustPageCheckpointV1, entries: [AccountTrustHistoryEntryV1], nextCursor: AccountTrustCursorV1?, terminal: Bool, issuedAt: String, expiresAt: String, serverKeyID: String, serverSignature: Data) throws {
        guard entries.count <= 32, (terminal ? nextCursor == nil : (!entries.isEmpty && nextCursor != nil)), requestCursor.accountID == accountID, requestCursor.snapshotHead == snapshotHead, requestCursor.issuedAt == issuedAt, requestCursor.expiresAt == expiresAt, requestCursor.serverKeyID == serverKeyID else { throw AccountProtocolError.malformedWire }
        guard entries.allSatisfy({ $0.commit.state.accountID == accountID }) else { throw AccountProtocolError.malformedWire }
        if let last = entries.last {
            let checkpoint = try AccountTrustPageCheckpointV1(epoch: last.commit.state.epoch, revision: last.commit.state.revision, commitDigest: AccountTranscript.trustCommitDigest(last.commit))
            if terminal { guard checkpoint == snapshotHead else { throw AccountProtocolError.malformedWire } }
            else { guard nextCursor?.after == .checkpoint(checkpoint) else { throw AccountProtocolError.malformedWire } }
        } else {
            guard terminal, requestCursor.after == .checkpoint(snapshotHead) else { throw AccountProtocolError.malformedWire }
        }
        try AccountWireCodec.validateLowSSignature(serverSignature)
        self.requestCursor = requestCursor; self.accountID = accountID; self.snapshotHead = snapshotHead; self.entries = entries; self.nextCursor = nextCursor; self.terminal = terminal; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.serverKeyID = serverKeyID; self.serverSignature = serverSignature
    }
}

public struct EncryptedAccountRecordPageV1: Hashable, Sendable {
    public let records: [EncryptedAccountRecordV1]
    public let nextCursor: Data?
    public let terminal: Bool
    public init(records: [EncryptedAccountRecordV1], nextCursor: Data?, terminal: Bool) throws {
        guard records.count <= 32, nextCursor.map({ $0.count == 8 }) ?? true, terminal ? nextCursor == nil : (!records.isEmpty && nextCursor != nil) else { throw AccountProtocolError.malformedWire }
        self.records = records; self.nextCursor = nextCursor; self.terminal = terminal
    }
}

public struct EncryptedAccountRecordV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let recordID: AccountRecordID
    public let epoch: AccountTrustEpoch
    public let keyGeneration: PositiveUInt64
    public let trustRevision: PositiveUInt64
    public let recordRevision: PositiveUInt64
    /// nonce(12) || ciphertext(1...65,508) || tag(16)
    public let envelope: Data
    public let signerDeviceID: AccountDeviceID
    public let signature: Data

    public init(
        accountID: PlainpostAccountID,
        recordID: AccountRecordID,
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        trustRevision: PositiveUInt64,
        recordRevision: PositiveUInt64,
        envelope: Data,
        signerDeviceID: AccountDeviceID,
        signature: Data
    ) throws {
        guard envelope.count >= 29, envelope.count <= 65_536 else { throw AccountProtocolError.oversized }
        try AccountWireCodec.validateLowSSignature(signature)
        self.accountID = accountID
        self.recordID = recordID
        self.epoch = epoch
        self.keyGeneration = keyGeneration
        self.trustRevision = trustRevision
        self.recordRevision = recordRevision
        self.envelope = envelope
        self.signerDeviceID = signerDeviceID
        self.signature = signature
    }
}

public struct AccountRecordInventoryEntryV1: Hashable, Sendable {
    public let recordID: AccountRecordID
    public let epoch: AccountTrustEpoch
    public let keyGeneration: PositiveUInt64
    public let trustRevision: PositiveUInt64
    public let recordRevision: PositiveUInt64
    public let envelopeDigest: Data
    public let signatureDigest: Data

    public init(
        recordID: AccountRecordID,
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        trustRevision: PositiveUInt64,
        recordRevision: PositiveUInt64,
        envelopeDigest: Data,
        signatureDigest: Data
    ) throws {
        guard envelopeDigest.count == 32, signatureDigest.count == 32 else { throw AccountProtocolError.malformedWire }
        self.recordID = recordID
        self.epoch = epoch
        self.keyGeneration = keyGeneration
        self.trustRevision = trustRevision
        self.recordRevision = recordRevision
        self.envelopeDigest = envelopeDigest
        self.signatureDigest = signatureDigest
    }
}

public struct AccountRecordInventoryProofV1: Hashable, Sendable {
    public static let maximumEntries = 4_096

    public let accountID: PlainpostAccountID
    public let trustCommitDigest: Data
    public let epoch: AccountTrustEpoch
    public let keyGeneration: PositiveUInt64
    public let entries: [AccountRecordInventoryEntryV1]
    public let issuedAt: String
    public let expiresAt: String
    public let serverKeyID: String
    public let serverSignature: Data

    public init(
        accountID: PlainpostAccountID,
        trustCommitDigest: Data,
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        entries: [AccountRecordInventoryEntryV1],
        issuedAt: String,
        expiresAt: String,
        serverKeyID: String,
        serverSignature: Data
    ) throws {
        guard trustCommitDigest.count == 32,
              entries.count <= Self.maximumEntries,
              entries.map(\.recordID.rawValue) == entries.map(\.recordID.rawValue).sorted(),
              Set(entries.map(\.recordID)).count == entries.count,
              entries.allSatisfy({ $0.epoch == epoch && $0.keyGeneration == keyGeneration }),
              let issued = AccountWireCodec.parseTimestamp(issuedAt),
              let expires = AccountWireCodec.parseTimestamp(expiresAt),
              issued < expires,
              expires.timeIntervalSince(issued) <= 300,
              AccountWireCodec.isKeyID(serverKeyID)
        else { throw AccountProtocolError.malformedWire }
        try AccountWireCodec.validateLowSSignature(serverSignature)
        self.accountID = accountID
        self.trustCommitDigest = trustCommitDigest
        self.epoch = epoch
        self.keyGeneration = keyGeneration
        self.entries = entries
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.serverKeyID = serverKeyID
        self.serverSignature = serverSignature
    }
}

public enum AccountTrustTranscript {
    public static func handshake(_ response: TrustHandshakeResponseV1) -> Data {
        let offer = response.offer
        return AccountTranscript.parts([
            Data("Plainpost.AccountTrust.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(offer.accountID.rawValue),
            AccountTranscript.uuid(offer.existingDeviceID.rawValue),
            AccountTranscript.uuid(offer.pendingDeviceID.rawValue),
            offer.existingPublicBundle.signingKey,
            offer.existingPublicBundle.agreementKey,
            offer.pendingPublicBundle.signingKey,
            offer.pendingPublicBundle.agreementKey,
            offer.existingNonce,
            response.pendingNonce,
            AccountTranscript.u64(offer.expiresAtUnixMilliseconds.value),
        ])
    }

    public static func groupKeyPackageKDF(
        accountID: PlainpostAccountID,
        epoch: AccountTrustEpoch,
        stateRevision: PositiveUInt64,
        keyGeneration: PositiveUInt64,
        stateDigest: Data,
        recipientDeviceID: AccountDeviceID,
        senderDeviceID: AccountDeviceID
    ) -> Data {
        AccountTranscript.parts([
            Data("Plainpost.AccountGroupKeyPackage.KDF.v1".utf8),
            AccountTranscript.uuid(accountID.rawValue),
            AccountTranscript.u64(epoch.value),
            AccountTranscript.u64(stateRevision.value),
            AccountTranscript.u64(keyGeneration.value),
            stateDigest,
            AccountTranscript.uuid(recipientDeviceID.rawValue),
            AccountTranscript.uuid(senderDeviceID.rawValue),
        ])
    }

    public static func groupKeyPackageAAD(
        accountID: PlainpostAccountID,
        epoch: AccountTrustEpoch,
        stateRevision: PositiveUInt64,
        keyGeneration: PositiveUInt64,
        stateDigest: Data,
        keyCommitment: Data,
        recipientDeviceID: AccountDeviceID,
        senderDeviceID: AccountDeviceID,
        senderEphemeralPublicKey: Data
    ) -> Data {
        AccountTranscript.parts([
            Data("Plainpost.AccountGroupKeyPackage.AAD.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(accountID.rawValue),
            AccountTranscript.u64(epoch.value),
            AccountTranscript.u64(stateRevision.value),
            AccountTranscript.u64(keyGeneration.value),
            stateDigest,
            keyCommitment,
            AccountTranscript.uuid(recipientDeviceID.rawValue),
            AccountTranscript.uuid(senderDeviceID.rawValue),
            senderEphemeralPublicKey,
        ])
    }

    public static func encryptedRecordAAD(
        accountID: PlainpostAccountID,
        recordID: AccountRecordID,
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        trustRevision: PositiveUInt64,
        recordRevision: PositiveUInt64
    ) -> Data {
        AccountTranscript.parts([
            Data("Plainpost.EncryptedAccountRecord.AAD.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(accountID.rawValue),
            AccountTranscript.uuid(recordID.rawValue),
            AccountTranscript.u64(epoch.value),
            AccountTranscript.u64(keyGeneration.value),
            AccountTranscript.u64(trustRevision.value),
            AccountTranscript.u64(recordRevision.value),
        ])
    }

    public static func encryptedRecordSignature(_ record: EncryptedAccountRecordV1, envelopeDigest: Data) -> Data {
        AccountTranscript.parts([
            Data("Plainpost.EncryptedAccountRecord.Signature.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(record.accountID.rawValue),
            AccountTranscript.uuid(record.recordID.rawValue),
            AccountTranscript.u64(record.epoch.value),
            AccountTranscript.u64(record.keyGeneration.value),
            AccountTranscript.u64(record.trustRevision.value),
            AccountTranscript.u64(record.recordRevision.value),
            envelopeDigest,
            AccountTranscript.uuid(record.signerDeviceID.rawValue),
        ])
    }

    public static func recordInventoryEntry(_ entry: AccountRecordInventoryEntryV1) -> Data {
        AccountTranscript.parts([
            Data("Plainpost.AccountRecordInventoryEntry.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(entry.recordID.rawValue),
            AccountTranscript.u64(entry.epoch.value),
            AccountTranscript.u64(entry.keyGeneration.value),
            AccountTranscript.u64(entry.trustRevision.value),
            AccountTranscript.u64(entry.recordRevision.value),
            entry.envelopeDigest,
            entry.signatureDigest,
        ])
    }

    public static func recordInventoryProof(_ proof: AccountRecordInventoryProofV1) -> Data {
        var values = [
            Data("Plainpost.AccountRecordInventoryProof.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(proof.accountID.rawValue),
            proof.trustCommitDigest,
            AccountTranscript.u64(proof.epoch.value),
            AccountTranscript.u64(proof.keyGeneration.value),
            AccountTranscript.u16(UInt16(proof.entries.count)),
        ]
        values += proof.entries.map(recordInventoryEntry)
        values += [Data(proof.issuedAt.utf8), Data(proof.expiresAt.utf8), Data(proof.serverKeyID.utf8)]
        return AccountTranscript.parts(values)
    }

    public static func historyEntryDigest(_ entry: AccountTrustHistoryEntryV1) -> Data {
        let commit = AccountTranscript.trustCommitDigest(entry.commit)
        let kind: Data, evidence: Data
        switch entry.evidence {
        case .admission(let value):
            kind = Data("account.trust-admission-evidence.v1".utf8)
            let pending = AccountSHA256.hash(AccountTranscript.pendingDeviceAuthorization(value.pendingDevice))
            evidence = AccountSHA256.hash(AccountTranscript.parts([pending, AccountTrustAuthentication.handshakeDigest(value.response)]))
        case .recovery(let value):
            kind = Data("account.trust-recovery-evidence.v1".utf8)
            let manifest = AccountSHA256.hash(AccountTranscript.manifest(rootKeyID: value.historicalManifest.rootKeyID, version: value.historicalManifest.manifestVersion, notBefore: value.historicalManifest.notBefore, expiresAt: value.historicalManifest.expiresAt, previousDigest: value.historicalManifest.previousManifestDigest, keys: value.historicalManifest.keys) + AccountTranscript.part(value.historicalManifest.rootSignature))
            evidence = AccountSHA256.hash(AccountTranscript.parts([AccountTranscript.recoveryAuthorizationDigest(value.authorization), manifest]))
        case .syncNodeEnrollment(let value):
            kind = Data("account.sync-node-admission-evidence.v1".utf8)
            evidence = AccountSHA256.hash(try! AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(value))
        case nil: kind = Data(); evidence = Data()
        }
        return AccountSHA256.hash(AccountTranscript.parts([commit, kind, evidence]))
    }

    public static func trustCursor(_ cursor: AccountTrustCursorV1) -> Data {
        let after: Data
        switch cursor.after { case .genesis: after = AccountTranscript.parts([Data("genesis".utf8)]); case .checkpoint(let value): after = AccountTranscript.parts([checkpoint(value)]) }
        return AccountTranscript.parts([Data("Plainpost.TrustCursor.v1".utf8), AccountTranscript.u16(1), AccountTranscript.uuid(cursor.accountID.rawValue), after, checkpoint(cursor.snapshotHead), Data(cursor.issuedAt.utf8), Data(cursor.expiresAt.utf8), Data(cursor.serverKeyID.utf8)])
    }

    public static func trustCursorDigest(_ cursor: AccountTrustCursorV1) -> Data { AccountSHA256.hash(trustCursor(cursor) + AccountTranscript.part(cursor.signature)) }

    public static func trustStatePage(_ page: AccountTrustStatePageV1) -> Data {
        var values = [Data("Plainpost.TrustStatePage.v1".utf8), AccountTranscript.u16(1), trustCursorDigest(page.requestCursor), AccountTranscript.uuid(page.accountID.rawValue), checkpoint(page.snapshotHead), AccountTranscript.u16(UInt16(page.entries.count))]
        values += page.entries.map(historyEntryDigest)
        values += [page.nextCursor.map(trustCursorDigest) ?? Data(), AccountTranscript.u16(page.terminal ? 1 : 0), Data(page.issuedAt.utf8), Data(page.expiresAt.utf8), Data(page.serverKeyID.utf8)]
        return AccountTranscript.parts(values)
    }

    private static func checkpoint(_ value: AccountTrustPageCheckpointV1) -> Data { AccountTranscript.parts([AccountTranscript.u64(value.epoch.value), AccountTranscript.u64(value.revision.value), value.commitDigest]) }
}

public enum AccountTrustAuthentication {
    public static func handshakeDigest(_ response: TrustHandshakeResponseV1) -> Data {
        AccountSHA256.hash(AccountTrustTranscript.handshake(response))
    }

    public static func authenticationString(for response: TrustHandshakeResponseV1) throws -> String {
        let initial = handshakeDigest(response)
        var digest = initial
        var retry: UInt32 = 0
        while true {
            let candidate = Int(digest[0]) << 12 | Int(digest[1]) << 4 | Int(digest[2]) >> 4
            if candidate < 1_000_000 { return String(format: "%06d", candidate) }
            guard retry < UInt32.max else { throw AccountProtocolError.invalidTrustHandshake }
            retry += 1
            digest = AccountSHA256.hash(AccountTranscript.parts([
                Data("Plainpost.AccountTrust.SASRetry.v1".utf8),
                initial,
                u32(retry),
            ]))
        }
    }

    private static func u32(_ value: UInt32) -> Data {
        var bytes = value.bigEndian
        return Data(bytes: &bytes, count: 4)
    }
}
