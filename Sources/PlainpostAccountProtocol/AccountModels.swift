import Foundation

public enum AccountProtocolError: Error, Equatable, Sendable {
    case malformedWire
    case nonCanonicalValue
    case invalidIdentifier
    case invalidTimestamp
    case invalidSignature
    case invalidPublicKey
    case invalidTransition
    case invalidTrustHandshake
    case invalidRecord
    case rollback
    case equivocation
    case oversized
}

public struct PositiveUInt64: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let value: UInt64
    public init(wire: String) throws {
        guard !wire.isEmpty, wire.count <= 20, wire.first != "0" else { throw AccountProtocolError.nonCanonicalValue }
        var result: UInt64 = 0
        for byte in wire.utf8 {
            guard byte >= 48 && byte <= 57 else { throw AccountProtocolError.nonCanonicalValue }
            let digit = UInt64(byte - 48)
            let (multiplied, overflowOne) = result.multipliedReportingOverflow(by: 10)
            let (next, overflowTwo) = multiplied.addingReportingOverflow(digit)
            guard !overflowOne, !overflowTwo else { throw AccountProtocolError.nonCanonicalValue }
            result = next
        }
        guard result > 0 else { throw AccountProtocolError.nonCanonicalValue }
        value = result
    }
    public init(_ value: UInt64) throws { guard value > 0 else { throw AccountProtocolError.nonCanonicalValue }; self.value = value }
    public init?(rawValue: UInt64) { guard rawValue > 0 else { return nil }; value = rawValue }
    public var rawValue: UInt64 { value }
    public var wireValue: String { String(value) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public init(from decoder: Decoder) throws { try self.init(wire: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(wireValue) }
}

private func canonicalUUID(_ wire: String) throws -> String {
    guard wire.count == 36, UUID(uuidString: wire)?.uuidString.lowercased() == wire else { throw AccountProtocolError.invalidIdentifier }
    return wire
}
public struct PlainpostAccountID: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String; public init?(rawValue: String) { guard let value = try? canonicalUUID(rawValue) else { return nil }; self.rawValue = value }; public init(_ wire: String) throws { rawValue = try canonicalUUID(wire) }; public init(from decoder: Decoder) throws { try self.init(try decoder.singleValueContainer().decode(String.self)) }; public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) } }
public struct AccountDeviceID: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String; public init?(rawValue: String) { guard let value = try? canonicalUUID(rawValue) else { return nil }; self.rawValue = value }; public init(_ wire: String) throws { rawValue = try canonicalUUID(wire) }; public init(from decoder: Decoder) throws { try self.init(try decoder.singleValueContainer().decode(String.self)) }; public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) } }
public struct NodeEnrollmentClaimID: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String; public init?(rawValue: String) { guard let value = try? canonicalUUID(rawValue) else { return nil }; self.rawValue = value }; public init(_ wire: String) throws { rawValue = try canonicalUUID(wire) }; public init(from decoder: Decoder) throws { try self.init(try decoder.singleValueContainer().decode(String.self)) }; public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) } }
public struct AccountChallengeID: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String; public init?(rawValue: String) { guard let value = try? canonicalUUID(rawValue) else { return nil }; self.rawValue = value }; public init(_ wire: String) throws { rawValue = try canonicalUUID(wire) }; public init(from decoder: Decoder) throws { try self.init(try decoder.singleValueContainer().decode(String.self)) }; public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) } }
public struct AccountAuthorizationID: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String; public init?(rawValue: String) { guard let value = try? canonicalUUID(rawValue) else { return nil }; self.rawValue = value }; public init(_ wire: String) throws { rawValue = try canonicalUUID(wire) }; public init(from decoder: Decoder) throws { try self.init(try decoder.singleValueContainer().decode(String.self)) }; public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) } }
public struct AccountRecordID: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String; public init?(rawValue: String) { guard let value = try? canonicalUUID(rawValue) else { return nil }; self.rawValue = value }; public init(_ wire: String) throws { rawValue = try canonicalUUID(wire) }; public init(from decoder: Decoder) throws { try self.init(try decoder.singleValueContainer().decode(String.self)) }; public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) } }
/// Opaque 32-byte HMAC output. It deliberately has no UUID/text representation.
public struct LogicalMailboxID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Data
    public init?(rawValue: Data) { guard rawValue.count == 32 else { return nil }; self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        let value = try AccountWireCodec.decodeBase64URL(try decoder.singleValueContainer().decode(String.self), exactBytes: 32)
        guard let result = Self(rawValue: value) else { throw AccountProtocolError.malformedWire }
        self = result
    }
    public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(AccountWireCodec.encodeBase64URL(rawValue)) }
}
/// A positive, monotonically increasing account-trust epoch. It preserves the
/// `PositiveUInt64` single-string wire representation while preventing it from
/// being confused with revisions, key generations, or provider counters.
public struct AccountTrustEpoch: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: PositiveUInt64
    public init(rawValue: PositiveUInt64) { self.rawValue = rawValue }
    public init(wire: String) throws { try self.init(rawValue: PositiveUInt64(wire: wire)) }
    public var value: UInt64 { rawValue.value }
    public var wireValue: String { rawValue.wireValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: Decoder) throws { try self.init(rawValue: PositiveUInt64(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
}

public enum AccountPlatform: String, Codable, Sendable { case macos, ios, syncNode = "sync_node" }
public enum AccountBootstrapMode: String, Codable, Sendable { case genesis, pending }
public enum AccountKeyPurpose: String, Codable, Sendable { case bootstrapChallenge = "bootstrap_challenge", trustPagination = "trust_pagination", recoveryAuthorization = "recovery_authorization" }
public enum AccountKeyStatus: String, Codable, Sendable { case active, revoked }
public enum AccountTrustTransitionKind: String, Codable, Sendable { case genesis, admission, revocation, suspension, recovery }
public enum AccountNodeEnrollmentAction: String, Codable, Sendable { case enroll, replace }

/// The approving client receives endpoint ciphertext only after proving the
/// short-lived setup code to the lookup route. It never receives plaintext,
/// the setup verifier, or Node private material.
public struct AccountNodeEnrollmentPublicClaimV1: Hashable, Sendable {
    public let claimID: NodeEnrollmentClaimID; public let nodeDeviceID: AccountDeviceID
    public let signingPublicKey, agreementPublicKey, noiseStaticPublicKey, endpointDigest: Data
    public let endpointCiphertext: Data?
    public let createdAt, expiresAt: String
    public init(claimID: NodeEnrollmentClaimID, nodeDeviceID: AccountDeviceID, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data, endpointCiphertext: Data? = nil, endpointDigest: Data, createdAt: String, expiresAt: String) throws {
        guard AccountP256SEC1Validator.isValidUncompressedPoint(signingPublicKey), AccountP256SEC1Validator.isValidUncompressedPoint(agreementPublicKey), noiseStaticPublicKey.count == 32, endpointCiphertext.map({ (29...16 * 1024).contains($0.count) }) ?? true, endpointDigest.count == 32, !endpointDigest.allSatisfy({ $0 == 0 }), let created = AccountWireCodec.parseTimestamp(createdAt), let expires = AccountWireCodec.parseTimestamp(expiresAt), created < expires, expires.timeIntervalSince(created) <= 300 else { throw AccountProtocolError.malformedWire }
        self.claimID = claimID; self.nodeDeviceID = nodeDeviceID; self.signingPublicKey = signingPublicKey; self.agreementPublicKey = agreementPublicKey; self.noiseStaticPublicKey = noiseStaticPublicKey; self.endpointCiphertext = endpointCiphertext; self.endpointDigest = endpointDigest; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

public struct AccountNodeEnrollmentClaimV1: Hashable, Sendable {
    public let claimID: NodeEnrollmentClaimID; public let nodeDeviceID: AccountDeviceID
    public let signingPublicKey, agreementPublicKey, noiseStaticPublicKey: Data
    public let endpointCiphertext, setupVerifier, endpointDigest: Data
    public let createdAt, expiresAt: String
    public init(claimID: NodeEnrollmentClaimID, nodeDeviceID: AccountDeviceID, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data, endpointCiphertext: Data, setupVerifier: Data, endpointDigest: Data, createdAt: String, expiresAt: String) throws {
        guard AccountP256SEC1Validator.isValidUncompressedPoint(signingPublicKey), AccountP256SEC1Validator.isValidUncompressedPoint(agreementPublicKey), noiseStaticPublicKey.count == 32, !endpointCiphertext.isEmpty, endpointCiphertext.count <= 16 * 1024, (32...64).contains(setupVerifier.count), endpointDigest.count == 32, !endpointDigest.allSatisfy({ $0 == 0 }), let created = AccountWireCodec.parseTimestamp(createdAt), let expires = AccountWireCodec.parseTimestamp(expiresAt), created < expires, expires.timeIntervalSince(created) <= 300 else { throw AccountProtocolError.malformedWire }
        self.claimID = claimID; self.nodeDeviceID = nodeDeviceID; self.signingPublicKey = signingPublicKey; self.agreementPublicKey = agreementPublicKey; self.noiseStaticPublicKey = noiseStaticPublicKey; self.endpointCiphertext = endpointCiphertext; self.setupVerifier = setupVerifier; self.endpointDigest = endpointDigest; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

public struct AccountNodeEnrollmentAdmissionEvidenceV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let trustEpoch: AccountTrustEpoch; public let approverDeviceID: AccountDeviceID; public let claimID: NodeEnrollmentClaimID; public let nodeDeviceID: AccountDeviceID; public let action: AccountNodeEnrollmentAction; public let replacedNodeID: AccountDeviceID?
    public let signingPublicKey, agreementPublicKey, noiseStaticPublicKey, endpointDigest, matchingTranscriptDigest: Data
    public let stepUp: AccountStepUpAuthorizationV1
    public init(accountID: PlainpostAccountID, trustEpoch: AccountTrustEpoch, approverDeviceID: AccountDeviceID, claimID: NodeEnrollmentClaimID, nodeDeviceID: AccountDeviceID, action: AccountNodeEnrollmentAction, replacedNodeID: AccountDeviceID?, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data, endpointDigest: Data, matchingTranscriptDigest: Data, stepUp: AccountStepUpAuthorizationV1) throws {
        let stepUpBound = action == .enroll ? replacedNodeID == nil && stepUp.action == .enrollSyncNode && stepUp.targetDeviceID == nodeDeviceID : replacedNodeID != nil && stepUp.action == .replaceSyncNode && stepUp.targetDeviceID == replacedNodeID
        guard stepUpBound, AccountP256SEC1Validator.isValidUncompressedPoint(signingPublicKey), AccountP256SEC1Validator.isValidUncompressedPoint(agreementPublicKey), noiseStaticPublicKey.count == 32, endpointDigest.count == 32, matchingTranscriptDigest.count == 32, !endpointDigest.allSatisfy({ $0 == 0 }), !matchingTranscriptDigest.allSatisfy({ $0 == 0 }), stepUp.accountID == accountID, stepUp.actorDeviceID == approverDeviceID else { throw AccountProtocolError.malformedWire }
        self.accountID = accountID; self.trustEpoch = trustEpoch; self.approverDeviceID = approverDeviceID; self.claimID = claimID; self.nodeDeviceID = nodeDeviceID; self.action = action; self.replacedNodeID = replacedNodeID; self.signingPublicKey = signingPublicKey; self.agreementPublicKey = agreementPublicKey; self.noiseStaticPublicKey = noiseStaticPublicKey; self.endpointDigest = endpointDigest; self.matchingTranscriptDigest = matchingTranscriptDigest; self.stepUp = stepUp
    }
}

/// Central audience rules. `isValid` is the wire rule shared with Central
/// and Node configuration. `isPortableLabel` is required wherever Swift,
/// Go, and Python compare canonical bytes (Server Setup profile, verifier).
public enum AccountCentralAudience {
    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 })
    }

    public static func isPortableLabel(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1 ... 255).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == 0x2d || $0 == 0x2e || $0 == 0x3a || $0 == 0x5f }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5a).contains(byte) || (0x61 ... 0x7a).contains(byte)
    }
}

public struct AccountNodeOperationBindingV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let trustEpoch: AccountTrustEpoch; public let claimID: NodeEnrollmentClaimID; public let nodeDeviceID: AccountDeviceID
    public let centralAudience: String
    public let action: AccountNodeEnrollmentAction; public let replacedNodeID: AccountDeviceID?; public let replacementRevocationDigest: Data?
    public let admissionEvidenceDigest, issuanceDigest: Data
    public init(accountID: PlainpostAccountID, trustEpoch: AccountTrustEpoch, claimID: NodeEnrollmentClaimID, nodeDeviceID: AccountDeviceID, centralAudience: String, action: AccountNodeEnrollmentAction, replacedNodeID: AccountDeviceID?, replacementRevocationDigest: Data?, admissionEvidenceDigest: Data, issuanceDigest: Data) throws {
        let replacementShape = action == .enroll ? replacedNodeID == nil && replacementRevocationDigest == nil : replacedNodeID != nil && replacementRevocationDigest?.count == 32 && replacementRevocationDigest?.contains(where: { $0 != 0 }) == true
        guard AccountCentralAudience.isValid(centralAudience), replacementShape, admissionEvidenceDigest.count == 32, issuanceDigest.count == 32, admissionEvidenceDigest.contains(where: { $0 != 0 }), issuanceDigest.contains(where: { $0 != 0 }) else { throw AccountProtocolError.malformedWire }
        self.accountID = accountID; self.trustEpoch = trustEpoch; self.claimID = claimID; self.nodeDeviceID = nodeDeviceID; self.centralAudience = centralAudience; self.action = action; self.replacedNodeID = replacedNodeID; self.replacementRevocationDigest = replacementRevocationDigest; self.admissionEvidenceDigest = admissionEvidenceDigest; self.issuanceDigest = issuanceDigest
    }
    public func isForCentralAudience(_ expected: String) -> Bool { centralAudience == expected && AccountCentralAudience.isValid(expected) }
}

public struct AccountNodeEnrollmentResultV1: Hashable, Sendable {
    public let binding: AccountNodeOperationBindingV1; public let committedAt: String
    public init(binding: AccountNodeOperationBindingV1, committedAt: String) throws { guard AccountWireCodec.parseTimestamp(committedAt) != nil else { throw AccountProtocolError.invalidTimestamp }; self.binding = binding; self.committedAt = committedAt }
}

public struct AccountNodeOfflineLeaseV1: Hashable, Sendable {
    public let binding: AccountNodeOperationBindingV1; public let leaseID, issuedAt, expiresAt, serverKeyID: String; public let signature: Data
    public init(binding: AccountNodeOperationBindingV1, leaseID: String, issuedAt: String, expiresAt: String, serverKeyID: String, signature: Data) throws {
        guard (try? canonicalUUID(leaseID)) == leaseID, let issued = AccountWireCodec.parseTimestamp(issuedAt), let expires = AccountWireCodec.parseTimestamp(expiresAt), issued < expires, expires.timeIntervalSince(issued) <= 30 * 24 * 60 * 60, AccountWireCodec.isKeyID(serverKeyID), signature.count == 64 else { throw AccountProtocolError.malformedWire }
        self.binding = binding; self.leaseID = leaseID; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.serverKeyID = serverKeyID; self.signature = signature
    }
}

public struct AccountNodeRefreshCredentialV1: Hashable, Sendable {
    public let binding: AccountNodeOperationBindingV1; public let credentialID, issuedAt, expiresAt: String; public let credential: Data
    public init(binding: AccountNodeOperationBindingV1, credentialID: String, issuedAt: String, expiresAt: String, credential: Data) throws {
        guard (try? canonicalUUID(credentialID)) == credentialID, let issued = AccountWireCodec.parseTimestamp(issuedAt), let expires = AccountWireCodec.parseTimestamp(expiresAt), issued < expires, expires.timeIntervalSince(issued) <= 30 * 24 * 60 * 60, credential.count == 32, credential.contains(where: { $0 != 0 }) else { throw AccountProtocolError.malformedWire }
        self.binding = binding; self.credentialID = credentialID; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.credential = credential
    }
}

/// V2 binds all issued session documents to Central's Node-only cleanup
/// capability. V1 remains available for historical-vector decoding only.
public struct AccountNodeOperationBindingV2: Hashable, Sendable {
    public let base: AccountNodeOperationBindingV1
    public let cleanupCapabilityDigest: Data
    public init(base: AccountNodeOperationBindingV1, cleanupCapabilityDigest: Data) throws {
        guard cleanupCapabilityDigest.count == 32, cleanupCapabilityDigest.contains(where: { $0 != 0 }) else { throw AccountProtocolError.malformedWire }
        self.base = base; self.cleanupCapabilityDigest = cleanupCapabilityDigest
    }
}
public struct AccountNodeEnrollmentResultV2: Hashable, Sendable { public let binding: AccountNodeOperationBindingV2; public let committedAt: String; public init(binding: AccountNodeOperationBindingV2, committedAt: String) throws { guard AccountWireCodec.parseTimestamp(committedAt) != nil else { throw AccountProtocolError.invalidTimestamp }; self.binding = binding; self.committedAt = committedAt } }
public struct AccountNodeOfflineLeaseV2: Hashable, Sendable {
    public let binding: AccountNodeOperationBindingV2; public let leaseID, issuedAt, expiresAt, serverKeyID: String; public let signature: Data
    public init(binding: AccountNodeOperationBindingV2, leaseID: String, issuedAt: String, expiresAt: String, serverKeyID: String, signature: Data) throws { try AccountWireCodec.validateLowSSignature(signature); guard (try? canonicalUUID(leaseID)) == leaseID, let issued = AccountWireCodec.parseTimestamp(issuedAt), let expires = AccountWireCodec.parseTimestamp(expiresAt), issued < expires, expires.timeIntervalSince(issued) <= 30 * 24 * 60 * 60, AccountWireCodec.isKeyID(serverKeyID) else { throw AccountProtocolError.malformedWire }; self.binding = binding; self.leaseID = leaseID; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.serverKeyID = serverKeyID; self.signature = signature }
}
public struct AccountNodeRefreshCredentialV2: Hashable, Sendable {
    public let binding: AccountNodeOperationBindingV2; public let credentialID, issuedAt, expiresAt: String; public let credential: Data
    public init(binding: AccountNodeOperationBindingV2, credentialID: String, issuedAt: String, expiresAt: String, credential: Data) throws { guard (try? canonicalUUID(credentialID)) == credentialID, let issued = AccountWireCodec.parseTimestamp(issuedAt), let expires = AccountWireCodec.parseTimestamp(expiresAt), issued < expires, expires.timeIntervalSince(issued) <= 30 * 24 * 60 * 60, credential.count == 32, credential.contains(where: { $0 != 0 }) else { throw AccountProtocolError.malformedWire }; self.binding = binding; self.credentialID = credentialID; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.credential = credential }
}
public struct AccountSyncNodeCleanupCapabilityV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let claimID: NodeEnrollmentClaimID; public let nodeDeviceID: AccountDeviceID; public let targetHandle, cleanupCredential: Data; public let deletionGeneration: PositiveUInt64; public let issuedAt: String
    public init(accountID: PlainpostAccountID, claimID: NodeEnrollmentClaimID, nodeDeviceID: AccountDeviceID, targetHandle: Data, cleanupCredential: Data, deletionGeneration: PositiveUInt64, issuedAt: String) throws { guard targetHandle.count == 32, cleanupCredential.count == 32, targetHandle != cleanupCredential, targetHandle.contains(where: { $0 != 0 }), cleanupCredential.contains(where: { $0 != 0 }), AccountWireCodec.parseTimestamp(issuedAt) != nil else { throw AccountProtocolError.malformedWire }; self.accountID = accountID; self.claimID = claimID; self.nodeDeviceID = nodeDeviceID; self.targetHandle = targetHandle; self.cleanupCredential = cleanupCredential; self.deletionGeneration = deletionGeneration; self.issuedAt = issuedAt }
}
public struct AccountNodeEnrollmentAdmissionResponseV2: Hashable, Sendable {
    public let result: AccountNodeEnrollmentResultV2; public let refreshCredential: AccountNodeRefreshCredentialV2; public let offlineLease: AccountNodeOfflineLeaseV2; public let cleanupCapability: AccountSyncNodeCleanupCapabilityV1
    public init(result: AccountNodeEnrollmentResultV2, refreshCredential: AccountNodeRefreshCredentialV2, offlineLease: AccountNodeOfflineLeaseV2, cleanupCapability: AccountSyncNodeCleanupCapabilityV1) throws { guard result.binding == refreshCredential.binding, result.binding == offlineLease.binding, cleanupCapability.accountID == result.binding.base.accountID, cleanupCapability.claimID == result.binding.base.claimID, cleanupCapability.nodeDeviceID == result.binding.base.nodeDeviceID, AccountSHA256.hash(try AccountWireCodec.encodeSyncNodeCleanupCapability(cleanupCapability)) == result.binding.cleanupCapabilityDigest else { throw AccountProtocolError.malformedWire }; self.result = result; self.refreshCredential = refreshCredential; self.offlineLease = offlineLease; self.cleanupCapability = cleanupCapability }
}

public struct AccountPublicKeyBundle: Codable, Hashable, Sendable {
    public let signingKey: Data
    public let agreementKey: Data
    public init(signingKey: Data, agreementKey: Data) throws {
        guard signingKey != agreementKey, AccountP256SEC1Validator.isValidUncompressedPoint(signingKey), AccountP256SEC1Validator.isValidUncompressedPoint(agreementKey) else { throw AccountProtocolError.invalidPublicKey }
        self.signingKey = signingKey; self.agreementKey = agreementKey
    }
    private enum CodingKeys: String, CodingKey { case signingKey, agreementKey }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(signingKey: AccountWireCodec.decodeBase64URL(try box.decode(String.self, forKey: .signingKey), exactBytes: 65), agreementKey: AccountWireCodec.decodeBase64URL(try box.decode(String.self, forKey: .agreementKey), exactBytes: 65))
    }
    public func encode(to encoder: Encoder) throws { var box = encoder.container(keyedBy: CodingKeys.self); try box.encode(AccountWireCodec.encodeBase64URL(signingKey), forKey: .signingKey); try box.encode(AccountWireCodec.encodeBase64URL(agreementKey), forKey: .agreementKey) }
}

public struct AccountExchangeRequest: Codable, Sendable {
    public let appleIdentityToken: String
    public let nonce: Data
    public let deviceBundle: AccountPublicKeyBundle
    public let deviceProof: Data
    public init(appleIdentityToken: String, nonce: Data, deviceBundle: AccountPublicKeyBundle, deviceProof: Data) throws {
        guard nonce.count == 32, deviceProof.count == 64, appleIdentityToken.count <= 16_384, !appleIdentityToken.isEmpty, appleIdentityToken.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || [46, 95, 126, 45].contains($0) }) else { throw AccountProtocolError.malformedWire }
        self.appleIdentityToken = appleIdentityToken; self.nonce = nonce; self.deviceBundle = deviceBundle; self.deviceProof = deviceProof
    }
}

public struct AccountBootstrapChallenge: Codable, Hashable, Sendable {
    public let challengeID: AccountChallengeID
    public let challengeNonce: Data
    public let exchangeRequestDigest: Data
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let mode: AccountBootstrapMode
    public let platform: AccountPlatform
    public let publicBundle: AccountPublicKeyBundle
    public let createdAt: String
    public let expiresAt: String
    public let serverKeyID: String
    public let serverSignature: Data
    public init(challengeID: AccountChallengeID, challengeNonce: Data, exchangeRequestDigest: Data, accountID: PlainpostAccountID, deviceID: AccountDeviceID, mode: AccountBootstrapMode, platform: AccountPlatform, publicBundle: AccountPublicKeyBundle, createdAt: String, expiresAt: String, serverKeyID: String, serverSignature: Data) throws {
        guard challengeNonce.count == 32, exchangeRequestDigest.count == 32, serverSignature.count == 64, AccountWireCodec.isKeyID(serverKeyID), platform != .syncNode, let created = AccountWireCodec.parseTimestamp(createdAt), let expiry = AccountWireCodec.parseTimestamp(expiresAt), created < expiry, expiry.timeIntervalSince(created) <= 300 else { throw AccountProtocolError.malformedWire }
        self.challengeID = challengeID; self.challengeNonce = challengeNonce; self.exchangeRequestDigest = exchangeRequestDigest; self.accountID = accountID; self.deviceID = deviceID; self.mode = mode; self.platform = platform; self.publicBundle = publicBundle; self.createdAt = createdAt; self.expiresAt = expiresAt; self.serverKeyID = serverKeyID; self.serverSignature = serverSignature
    }
}

public struct AccountPendingDevice: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let deviceID: AccountDeviceID; public let platform: AccountPlatform; public let publicBundle: AccountPublicKeyBundle; public let exchangeRequestDigest: Data; public let createdAt: String; public let expiresAt: String
    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, platform: AccountPlatform, publicBundle: AccountPublicKeyBundle, exchangeRequestDigest: Data, createdAt: String, expiresAt: String) throws {
        guard platform != .syncNode, exchangeRequestDigest.count == 32, let created = AccountWireCodec.parseTimestamp(createdAt), let expiry = AccountWireCodec.parseTimestamp(expiresAt), created < expiry, expiry.timeIntervalSince(created) <= 300 else { throw AccountProtocolError.malformedWire }
        self.accountID = accountID; self.deviceID = deviceID; self.platform = platform; self.publicBundle = publicBundle; self.exchangeRequestDigest = exchangeRequestDigest; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

public struct AccountRecoveryAuthorization: Codable, Hashable, Sendable {
    public let authorizationID: AccountAuthorizationID; public let accountID: PlainpostAccountID; public let epoch: AccountTrustEpoch; public let deviceID: AccountDeviceID; public let platform: AccountPlatform; public let publicBundle: AccountPublicKeyBundle; public let priorCommitDigest: Data; public let exchangeRequestDigest: Data; public let issuedAt: String; public let expiresAt: String; public let serverKeyID: String; public let serverSignature: Data
    public init(authorizationID: AccountAuthorizationID, accountID: PlainpostAccountID, epoch: AccountTrustEpoch, deviceID: AccountDeviceID, platform: AccountPlatform, publicBundle: AccountPublicKeyBundle, priorCommitDigest: Data, exchangeRequestDigest: Data, issuedAt: String, expiresAt: String, serverKeyID: String, serverSignature: Data) throws {
        guard platform != .syncNode, priorCommitDigest.count == 32, exchangeRequestDigest.count == 32, serverSignature.count == 64, AccountWireCodec.isKeyID(serverKeyID), let issued = AccountWireCodec.parseTimestamp(issuedAt), let expiry = AccountWireCodec.parseTimestamp(expiresAt), issued < expiry, expiry.timeIntervalSince(issued) <= 300 else { throw AccountProtocolError.malformedWire }
        self.authorizationID = authorizationID; self.accountID = accountID; self.epoch = epoch; self.deviceID = deviceID; self.platform = platform; self.publicBundle = publicBundle; self.priorCommitDigest = priorCommitDigest; self.exchangeRequestDigest = exchangeRequestDigest; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.serverKeyID = serverKeyID; self.serverSignature = serverSignature
    }
}

public struct AccountTrustTransition: Codable, Hashable, Sendable {
    public let kind: AccountTrustTransitionKind
    public let targetDeviceIDs: [AccountDeviceID]
    public let priorRecordDigests: [AccountPriorRecordDigest]
    public let handshakeDigest: Data?
    public let pendingDeviceDigest: Data?
    public let recoveryAuthorizationDigest: Data?
    public init(kind: AccountTrustTransitionKind, targetDeviceIDs: [AccountDeviceID], priorRecordDigests: [AccountPriorRecordDigest], handshakeDigest: Data? = nil, pendingDeviceDigest: Data? = nil, recoveryAuthorizationDigest: Data? = nil) throws {
        guard !targetDeviceIDs.isEmpty, targetDeviceIDs.count <= 11, targetDeviceIDs == targetDeviceIDs.sorted(by: { $0.rawValue < $1.rawValue }), Set(targetDeviceIDs).count == targetDeviceIDs.count, handshakeDigest?.count == 32 || handshakeDigest == nil, pendingDeviceDigest?.count == 32 || pendingDeviceDigest == nil, recoveryAuthorizationDigest?.count == 32 || recoveryAuthorizationDigest == nil else { throw AccountProtocolError.invalidTransition }
        switch kind {
        case .genesis: guard targetDeviceIDs.count == 1, priorRecordDigests.isEmpty, handshakeDigest == nil, pendingDeviceDigest == nil, recoveryAuthorizationDigest == nil else { throw AccountProtocolError.invalidTransition }
        case .admission: guard targetDeviceIDs.count == 1, priorRecordDigests.isEmpty, handshakeDigest != nil, pendingDeviceDigest != nil, recoveryAuthorizationDigest == nil else { throw AccountProtocolError.invalidTransition }
        case .recovery: guard !priorRecordDigests.isEmpty, priorRecordDigests.map(\.deviceID) == priorRecordDigests.map(\.deviceID).sorted(by: { $0.rawValue < $1.rawValue }), Set(priorRecordDigests.map(\.deviceID)).count == priorRecordDigests.count, Set(targetDeviceIDs) == Set(priorRecordDigests.map(\.deviceID)), recoveryAuthorizationDigest != nil, handshakeDigest == nil, pendingDeviceDigest == nil else { throw AccountProtocolError.invalidTransition }
        case .revocation, .suspension: guard targetDeviceIDs.count == 1, priorRecordDigests.count == 1, handshakeDigest == nil, pendingDeviceDigest == nil, recoveryAuthorizationDigest == nil else { throw AccountProtocolError.invalidTransition }
        }
        self.kind = kind; self.targetDeviceIDs = targetDeviceIDs; self.priorRecordDigests = priorRecordDigests; self.handshakeDigest = handshakeDigest; self.pendingDeviceDigest = pendingDeviceDigest; self.recoveryAuthorizationDigest = recoveryAuthorizationDigest
    }
}

public struct AccountPriorRecordDigest: Codable, Hashable, Sendable { public let deviceID: AccountDeviceID; public let recordDigest: Data; public init(deviceID: AccountDeviceID, recordDigest: Data) throws { guard recordDigest.count == 32 else { throw AccountProtocolError.malformedWire }; self.deviceID = deviceID; self.recordDigest = recordDigest } }

public struct AccountDeviceTrustRecord: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let epoch: AccountTrustEpoch; public let revision: PositiveUInt64; public let deviceID: AccountDeviceID; public let platform: AccountPlatform; public let publicBundle: AccountPublicKeyBundle; public let signerDeviceID: AccountDeviceID; public let signature: Data
    public init(accountID: PlainpostAccountID, epoch: AccountTrustEpoch, revision: PositiveUInt64, deviceID: AccountDeviceID, platform: AccountPlatform, publicBundle: AccountPublicKeyBundle, signerDeviceID: AccountDeviceID, signature: Data) throws { guard signature.count == 64 else { throw AccountProtocolError.invalidSignature }; self.accountID = accountID; self.epoch = epoch; self.revision = revision; self.deviceID = deviceID; self.platform = platform; self.publicBundle = publicBundle; self.signerDeviceID = signerDeviceID; self.signature = signature }
}

public struct AccountTrustState: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let epoch: AccountTrustEpoch; public let revision: PositiveUInt64; public let previousCommitDigest: Data?; public let transition: AccountTrustTransition; public let keyGeneration: PositiveUInt64; public let keyCommitment: Data; public let members: [AccountDeviceTrustRecord]; public let signerDeviceID: AccountDeviceID; public let signature: Data
    public init(accountID: PlainpostAccountID, epoch: AccountTrustEpoch, revision: PositiveUInt64, previousCommitDigest: Data?, transition: AccountTrustTransition, keyGeneration: PositiveUInt64, keyCommitment: Data, members: [AccountDeviceTrustRecord], signerDeviceID: AccountDeviceID, signature: Data) throws {
        guard previousCommitDigest?.count == 32 || previousCommitDigest == nil, keyCommitment.count == 32, signature.count == 64, !members.isEmpty, members.count <= 11, members.map(\.deviceID) == members.map(\.deviceID).sorted(by: { $0.rawValue < $1.rawValue }), Set(members.map(\.deviceID)).count == members.count, members.allSatisfy({ $0.accountID == accountID && $0.epoch == epoch && $0.revision <= revision }), members.contains(where: { $0.deviceID == signerDeviceID }) else { throw AccountProtocolError.malformedWire }
        guard transition.kind == .genesis ? previousCommitDigest == nil : previousCommitDigest != nil else { throw AccountProtocolError.invalidTransition }
        let targets = Set(transition.targetDeviceIDs)
        switch transition.kind {
        case .genesis:
            guard members.count == 1, members[0].deviceID == transition.targetDeviceIDs[0], members[0].revision == revision else { throw AccountProtocolError.invalidTransition }
        case .admission:
            // Generic Apple-device admission preserves prior records. The
            // dedicated Sync Node admission path additionally re-signs the
            // unchanged current membership at the successor revision, which
            // Central verifies against the exact predecessor and evidence.
            guard members.filter({ targets.contains($0.deviceID) }).allSatisfy({ $0.revision == revision }), members.filter({ !targets.contains($0.deviceID) }).allSatisfy({ $0.revision <= revision }), targets.isSubset(of: Set(members.map(\.deviceID))) else { throw AccountProtocolError.invalidTransition }
        case .revocation:
            // A Sync Node replacement is an atomic revocation: the target is
            // absent while Central's specialized admission path may introduce
            // exactly one separately-authorized successor at this revision.
            // Generic lifecycle validation remains stricter about which such
            // successor is permitted.
            guard targets.isDisjoint(with: Set(members.map(\.deviceID))), members.allSatisfy({ $0.revision <= revision }) else { throw AccountProtocolError.invalidTransition }
        case .suspension:
            guard targets.isDisjoint(with: Set(members.map(\.deviceID))), members.allSatisfy({ $0.revision < revision }) else { throw AccountProtocolError.invalidTransition }
        case .recovery:
            guard revision.value == 1, keyGeneration.value == 1, members.count == 1, let replacement = members.first, replacement.revision == revision, !targets.contains(replacement.deviceID), replacement.signerDeviceID == replacement.deviceID, signerDeviceID == replacement.deviceID else { throw AccountProtocolError.invalidTransition }
        }
        self.accountID = accountID; self.epoch = epoch; self.revision = revision; self.previousCommitDigest = previousCommitDigest; self.transition = transition; self.keyGeneration = keyGeneration; self.keyCommitment = keyCommitment; self.members = members; self.signerDeviceID = signerDeviceID; self.signature = signature
    }
}

public struct AccountGroupKeyPackage: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let epoch: AccountTrustEpoch; public let stateRevision: PositiveUInt64; public let keyGeneration: PositiveUInt64; public let stateDigest: Data; public let keyCommitment: Data; public let recipientDeviceID: AccountDeviceID; public let senderDeviceID: AccountDeviceID; public let senderEphemeralPublicKey: Data; public let nonce: Data; public let encryptedKeyMaterial: Data; public let signature: Data
    public init(accountID: PlainpostAccountID, epoch: AccountTrustEpoch, stateRevision: PositiveUInt64, keyGeneration: PositiveUInt64, stateDigest: Data, keyCommitment: Data, recipientDeviceID: AccountDeviceID, senderDeviceID: AccountDeviceID, senderEphemeralPublicKey: Data, nonce: Data, encryptedKeyMaterial: Data, signature: Data) throws { guard stateDigest.count == 32, keyCommitment.count == 32, AccountP256SEC1Validator.isValidUncompressedPoint(senderEphemeralPublicKey), nonce.count == 12, encryptedKeyMaterial.count == 80, signature.count == 64 else { throw AccountProtocolError.malformedWire }; self.accountID = accountID; self.epoch = epoch; self.stateRevision = stateRevision; self.keyGeneration = keyGeneration; self.stateDigest = stateDigest; self.keyCommitment = keyCommitment; self.recipientDeviceID = recipientDeviceID; self.senderDeviceID = senderDeviceID; self.senderEphemeralPublicKey = senderEphemeralPublicKey; self.nonce = nonce; self.encryptedKeyMaterial = encryptedKeyMaterial; self.signature = signature }
}

public struct AccountTrustStateCommit: Codable, Hashable, Sendable { public let state: AccountTrustState; public let keyPackages: [AccountGroupKeyPackage]; public init(state: AccountTrustState, keyPackages: [AccountGroupKeyPackage]) throws { let recipients = keyPackages.map(\.recipientDeviceID); let stateDigest = AccountSHA256.hash(AccountTranscript.signedTrustState(state)); guard !keyPackages.isEmpty, keyPackages.count <= 11, recipients == recipients.sorted(by: { $0.rawValue < $1.rawValue }), Set(recipients).count == recipients.count, recipients == state.members.map(\.deviceID), keyPackages.allSatisfy({ $0.accountID == state.accountID && $0.epoch == state.epoch && $0.stateRevision == state.revision && $0.stateDigest == stateDigest && $0.keyGeneration == state.keyGeneration && $0.keyCommitment == state.keyCommitment && $0.senderDeviceID == state.signerDeviceID }) else { throw AccountProtocolError.malformedWire }; self.state = state; self.keyPackages = keyPackages } }

public struct AccountBootstrapFinalize: Codable, Hashable, Sendable { public let challenge: AccountBootstrapChallenge; public let challengeDigest: Data; public let exchangeRequestDigest: Data; public let genesisCommit: AccountTrustStateCommit?; public let deviceSignature: Data; public init(challenge: AccountBootstrapChallenge, challengeDigest: Data, exchangeRequestDigest: Data, genesisCommit: AccountTrustStateCommit?, deviceSignature: Data) throws { guard challengeDigest.count == 32, exchangeRequestDigest.count == 32, deviceSignature.count == 64, (challenge.mode == .genesis) == (genesisCommit != nil) else { throw AccountProtocolError.malformedWire }; self.challenge = challenge; self.challengeDigest = challengeDigest; self.exchangeRequestDigest = exchangeRequestDigest; self.genesisCommit = genesisCommit; self.deviceSignature = deviceSignature } }

public struct AccountActivation: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let deviceID: AccountDeviceID; public let mode: AccountBootstrapMode
    public let accessToken: String?; public let accessExpiresAt: Date?; public let refreshCredential: Data?; public let offlineLease: String?; public let offlineLeaseExpiresAt: Date?
    public let currentTrustCommit: AccountTrustStateCommit?
    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, mode: AccountBootstrapMode, accessToken: String? = nil, accessExpiresAt: Date? = nil, refreshCredential: Data? = nil, offlineLease: String? = nil, offlineLeaseExpiresAt: Date? = nil, currentTrustCommit: AccountTrustStateCommit? = nil) { self.accountID = accountID; self.deviceID = deviceID; self.mode = mode; self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt; self.refreshCredential = refreshCredential; self.offlineLease = offlineLease; self.offlineLeaseExpiresAt = offlineLeaseExpiresAt; self.currentTrustCommit = currentTrustCommit }
}
public enum AccountSessionState: Codable, Hashable, Sendable {
    // Provisional remains storage-only until the trusted-device admission task
    // converts a bootstrap activation into issued device credentials.
    case provisional(AccountActivation)
    case active
    case offlineLease(expiresAt: Date)
    case signInRequired
    case suspended
    case cleanupRequired
    case deleted
    case expired
}

public enum AccountTranscript {
    public static func part(_ value: Data) -> Data { var count = UInt32(value.count).bigEndian; return Data(bytes: &count, count: 4) + value }
    public static func parts(_ values: [Data]) -> Data { values.reduce(into: Data()) { $0 += part($1) } }
    public static func u16(_ value: UInt16) -> Data { var item = value.bigEndian; return Data(bytes: &item, count: 2) }
    public static func u64(_ value: UInt64) -> Data { var item = value.bigEndian; return Data(bytes: &item, count: 8) }
    public static func uuid(_ value: String) -> Data { var uuid = UUID(uuidString: value)!.uuid; return withUnsafeBytes(of: &uuid) { Data($0) } }
    public static func securityDeviceHandle(accountID: PlainpostAccountID, deviceID: AccountDeviceID) -> Data {
        AccountSHA256.hash(Data("Plainpost.DeviceSecurityHandle.v1".utf8) + uuid(accountID.rawValue) + uuid(deviceID.rawValue))
    }
    public static func exchangeProof(tokenDigest: Data, nonce: Data, bundle: AccountPublicKeyBundle) -> Data { parts([Data("Plainpost.AccountExchangeProof.v1".utf8), u16(1), tokenDigest, nonce, bundle.signingKey, bundle.agreementKey]) }
    public static func exchangeRequest(tokenDigest: Data, nonce: Data, bundle: AccountPublicKeyBundle, proof: Data) -> Data { parts([Data("Plainpost.AccountExchangeRequest.v1".utf8), u16(1), tokenDigest, nonce, bundle.signingKey, bundle.agreementKey, proof]) }
    public static func sessionProof(accountID: PlainpostAccountID, deviceID: AccountDeviceID, method: String, path: String, bodyDigest: Data, timestamp: UInt64, nonce: Data) -> Data { parts([Data("Plainpost.DeviceSessionProof.v1".utf8), u16(1), Data(method.utf8), Data(path.utf8), bodyDigest, u64(timestamp), nonce, uuid(accountID.rawValue), uuid(deviceID.rawValue)]) }
    public static func accountRequestProof(accountID: PlainpostAccountID, deviceID: AccountDeviceID, method: String, target: String, bodyDigest: Data, accessTokenDigest: Data, timestamp: UInt64, nonce: Data) -> Data { parts([Data("Plainpost.DeviceAccountRequestProof.v1".utf8), u16(1), Data(method.utf8), Data(target.utf8), bodyDigest, accessTokenDigest, u64(timestamp), nonce, uuid(accountID.rawValue), uuid(deviceID.rawValue)]) }
    public static func stepUpRequest(_ value: AccountStepUpRequestV1) -> Data {
        let target = value.targetDeviceID.map { uuid($0.rawValue) } ?? Data()
        let tokenDigest = AccountSHA256.hash(Data(value.identityToken.utf8))
        return parts([Data("Plainpost.AccountStepUpRequest.v1".utf8), u16(1), uuid(value.accountID.rawValue), uuid(value.actorDeviceID.rawValue), target, Data(value.action.rawValue.utf8), value.currentCommitDigest, value.requestNonce, value.appleNonce, tokenDigest])
    }
    public static func stepUpAuthorization(_ value: AccountStepUpAuthorizationV1) -> Data {
        let target = value.targetDeviceID.map { uuid($0.rawValue) } ?? Data()
        return parts([Data("Plainpost.AccountStepUpAuthorization.v1".utf8), u16(1), uuid(value.authorizationID.rawValue), uuid(value.accountID.rawValue), uuid(value.actorDeviceID.rawValue), target, Data(value.action.rawValue.utf8), value.currentCommitDigest, value.requestDigest, Data(value.issuedAt.utf8), Data(value.expiresAt.utf8), Data(value.serverKeyID.utf8)])
    }
    public static func nodeEnrollmentClaimProof(_ value: AccountNodeEnrollmentClaimV1) -> Data { parts([Data("Plainpost.SyncNodeClaimProof.v1".utf8), u16(1), uuid(value.claimID.rawValue), uuid(value.nodeDeviceID.rawValue), value.signingPublicKey, value.agreementPublicKey, value.noiseStaticPublicKey, value.endpointDigest, Data(value.createdAt.utf8), Data(value.expiresAt.utf8)]) }
    /// Claim proof deliberately excludes the setup verifier and endpoint
    /// ciphertext, so recovery may reconstruct and verify it from the public
    /// claim projection alone.
    public static func nodeEnrollmentClaimProof(_ value: AccountNodeEnrollmentPublicClaimV1) -> Data { parts([Data("Plainpost.SyncNodeClaimProof.v1".utf8), u16(1), uuid(value.claimID.rawValue), uuid(value.nodeDeviceID.rawValue), value.signingPublicKey, value.agreementPublicKey, value.noiseStaticPublicKey, value.endpointDigest, Data(value.createdAt.utf8), Data(value.expiresAt.utf8)]) }
    public static func nodeEnrollmentMatchingConfirmation(_ value: AccountNodeEnrollmentClaimV1, accountID: PlainpostAccountID) -> Data { parts([Data("Plainpost.SyncNodeMatchingConfirmation.v1".utf8), u16(1), uuid(accountID.rawValue), nodeEnrollmentClaimProof(value)]) }
    public static func nodeEnrollmentMatchingConfirmation(_ value: AccountNodeEnrollmentPublicClaimV1, accountID: PlainpostAccountID) -> Data { parts([Data("Plainpost.SyncNodeMatchingConfirmation.v1".utf8), u16(1), uuid(accountID.rawValue), parts([Data("Plainpost.SyncNodeClaimProof.v1".utf8), u16(1), uuid(value.claimID.rawValue), uuid(value.nodeDeviceID.rawValue), value.signingPublicKey, value.agreementPublicKey, value.noiseStaticPublicKey, value.endpointDigest, Data(value.createdAt.utf8), Data(value.expiresAt.utf8)])]) }
    public static func nodeEnrollmentAdmissionApproval(_ value: AccountNodeEnrollmentAdmissionEvidenceV1, idempotencyKey: Data) -> Data { parts([Data("Plainpost.SyncNodeAdmissionApproval.v1".utf8), u16(1), uuid(value.accountID.rawValue), u64(value.trustEpoch.value), uuid(value.approverDeviceID.rawValue), uuid(value.claimID.rawValue), uuid(value.nodeDeviceID.rawValue), Data(value.action.rawValue.utf8), value.replacedNodeID.map { uuid($0.rawValue) } ?? Data(), value.signingPublicKey, value.agreementPublicKey, value.noiseStaticPublicKey, value.endpointDigest, value.matchingTranscriptDigest, stepUpAuthorization(value.stepUp), idempotencyKey]) }
    public static func nodeEnrollmentReplacementApproval(_ value: AccountNodeEnrollmentAdmissionEvidenceV1, idempotencyKey: Data) -> Data { parts([Data("Plainpost.SyncNodeReplacementApproval.v1".utf8), u16(1), nodeEnrollmentAdmissionApproval(value, idempotencyKey: idempotencyKey)]) }
    public static func nodeEnrollmentApproval(_ value: AccountNodeEnrollmentAdmissionEvidenceV1, idempotencyKey: Data) -> Data { value.action == .replace ? nodeEnrollmentReplacementApproval(value, idempotencyKey: idempotencyKey) : nodeEnrollmentAdmissionApproval(value, idempotencyKey: idempotencyKey) }
    /// A deterministic Task 1 session linkage: Central and the Apple approver
    /// both possess these exact values, avoiding any opaque token dependency.
    public static func nodeEnrollmentSessionDigest(refreshCredential: Data, offlineLeaseID: String) -> Data {
        AccountSHA256.hash(parts([Data("Plainpost.SyncNodeSessionDigest.v1".utf8), u16(1), refreshCredential, uuid(offlineLeaseID)]))
    }
    public static func nodeEnrollmentSessionIssuance(_ value: AccountNodeEnrollmentAdmissionEvidenceV1, centralAudience: String, sessionDigest: Data) -> Data { parts([Data("Plainpost.SyncNodeSessionIssuance.v1".utf8), u16(1), nodeEnrollmentAdmissionApproval(value, idempotencyKey: Data()), Data(centralAudience.utf8), sessionDigest]) }
    public static func nodeEnrollmentReplayLookup(accountID: PlainpostAccountID, claimID: NodeEnrollmentClaimID, idempotencyKey: Data) -> Data { parts([Data("Plainpost.SyncNodeReplayLookup.v1".utf8), u16(1), uuid(accountID.rawValue), uuid(claimID.rawValue), idempotencyKey]) }
    public static func nodeOperationBinding(_ value: AccountNodeOperationBindingV1) -> Data { parts([Data("Plainpost.SyncNodeOperationBinding.v1".utf8), u16(1), uuid(value.accountID.rawValue), u64(value.trustEpoch.value), uuid(value.claimID.rawValue), uuid(value.nodeDeviceID.rawValue), Data(value.centralAudience.utf8), Data(value.action.rawValue.utf8), value.replacedNodeID.map { uuid($0.rawValue) } ?? Data(), value.replacementRevocationDigest ?? Data(), value.admissionEvidenceDigest, value.issuanceDigest]) }
    public static func nodeEnrollmentResult(_ value: AccountNodeEnrollmentResultV1) -> Data { parts([Data("Plainpost.SyncNodeEnrollmentResult.v1".utf8), u16(1), nodeOperationBinding(value.binding), Data(value.committedAt.utf8)]) }
    public static func nodeOfflineLease(_ value: AccountNodeOfflineLeaseV1) -> Data { parts([Data("Plainpost.SyncNodeOfflineLease.v1".utf8), u16(1), nodeOperationBinding(value.binding), uuid(value.leaseID), Data(value.issuedAt.utf8), Data(value.expiresAt.utf8), Data(value.serverKeyID.utf8)]) }
    public static func nodeRefreshCredential(_ value: AccountNodeRefreshCredentialV1) -> Data { parts([Data("Plainpost.SyncNodeRefreshCredential.v1".utf8), u16(1), nodeOperationBinding(value.binding), uuid(value.credentialID), Data(value.issuedAt.utf8), Data(value.expiresAt.utf8), value.credential]) }
    public static func nodeOperationBindingV2(_ value: AccountNodeOperationBindingV2) -> Data { parts([Data("Plainpost.SyncNodeOperationBinding.v2".utf8), u16(2), nodeOperationBinding(value.base), value.cleanupCapabilityDigest]) }
    public static func nodeOfflineLeaseV2(_ value: AccountNodeOfflineLeaseV2) -> Data { parts([Data("Plainpost.SyncNodeOfflineLease.v2".utf8), u16(2), nodeOperationBindingV2(value.binding), uuid(value.leaseID), Data(value.issuedAt.utf8), Data(value.expiresAt.utf8), Data(value.serverKeyID.utf8)]) }
    public static func nodeEnrollmentSessionDigestV2(refreshCredential: Data, offlineLeaseID: String, cleanupCapabilityDigest: Data) -> Data { AccountSHA256.hash(parts([Data("Plainpost.SyncNodeSessionDigest.v2".utf8), u16(2), refreshCredential, uuid(offlineLeaseID), cleanupCapabilityDigest])) }
    public static func nodeEnrollmentSessionIssuanceV2(_ value: AccountNodeEnrollmentAdmissionEvidenceV1, centralAudience: String, sessionDigest: Data) -> Data { parts([Data("Plainpost.SyncNodeSessionIssuance.v2".utf8), u16(2), nodeEnrollmentAdmissionApproval(value, idempotencyKey: Data()), Data(centralAudience.utf8), sessionDigest]) }
    public static func recoveryCommitProof(_ value: AccountRecoveryCommitRequestV1) throws -> Data {
        var submission = try JSONSerialization.jsonObject(with: AccountWireCodec.encodeTrustHistoryEntry(value.entry)) as! [String: Any]
        submission["kind"] = "account.trust-commit-submission.v1"
        let wire = try JSONSerialization.data(withJSONObject: submission, options: [.sortedKeys, .withoutEscapingSlashes])
        return parts([Data("Plainpost.RecoveryCommitRequest.v1".utf8), u16(1), uuid(value.authorizationID.rawValue), value.requestNonce, AccountSHA256.hash(wire)])
    }
    public static func bootstrapChallenge(_ value: AccountBootstrapChallenge) -> Data { parts([Data("Plainpost.AccountBootstrapChallenge.v1".utf8), u16(1), uuid(value.challengeID.rawValue), value.challengeNonce, value.exchangeRequestDigest, uuid(value.accountID.rawValue), uuid(value.deviceID.rawValue), Data(value.mode.rawValue.utf8), Data(value.platform.rawValue.utf8), value.publicBundle.signingKey, value.publicBundle.agreementKey, Data(value.createdAt.utf8), Data(value.expiresAt.utf8), Data(value.serverKeyID.utf8)]) }
    public static func pendingDeviceAuthorization(_ value: AccountPendingDevice) -> Data { parts([Data("Plainpost.PendingDeviceAuthorization.v1".utf8), u16(1), uuid(value.accountID.rawValue), uuid(value.deviceID.rawValue), Data(value.platform.rawValue.utf8), value.publicBundle.signingKey, value.publicBundle.agreementKey, value.exchangeRequestDigest, Data(value.createdAt.utf8), Data(value.expiresAt.utf8)]) }
    public static func recoveryAuthorization(_ value: AccountRecoveryAuthorization) -> Data { parts([Data("Plainpost.RecoveryAuthorization.v1".utf8), u16(1), uuid(value.authorizationID.rawValue), uuid(value.accountID.rawValue), u64(value.epoch.value), uuid(value.deviceID.rawValue), Data(value.platform.rawValue.utf8), value.publicBundle.signingKey, value.publicBundle.agreementKey, value.priorCommitDigest, value.exchangeRequestDigest, Data(value.issuedAt.utf8), Data(value.expiresAt.utf8), Data(value.serverKeyID.utf8)]) }
    public static func recoveryAuthorizationDigest(_ value: AccountRecoveryAuthorization) -> Data {
        AccountSHA256.hash(recoveryAuthorization(value) + part(value.serverSignature))
    }
    public static func trustRecord(_ value: AccountDeviceTrustRecord) -> Data { parts([Data("Plainpost.DeviceTrustRecord.v1".utf8), u16(1), uuid(value.accountID.rawValue), u64(value.epoch.value), u64(value.revision.value), uuid(value.deviceID.rawValue), Data(value.platform.rawValue.utf8), value.publicBundle.signingKey, value.publicBundle.agreementKey, uuid(value.signerDeviceID.rawValue)]) }
    public static func signedTrustRecord(_ value: AccountDeviceTrustRecord) -> Data { trustRecord(value) + part(value.signature) }
    public static func transition(_ value: AccountTrustTransition) -> Data { var partsValue = [Data(value.kind.rawValue.utf8), u16(UInt16(value.targetDeviceIDs.count))]; partsValue += value.targetDeviceIDs.map { uuid($0.rawValue) }; partsValue.append(u16(UInt16(value.priorRecordDigests.count))); value.priorRecordDigests.forEach { partsValue += [uuid($0.deviceID.rawValue), $0.recordDigest] }; partsValue += [value.handshakeDigest ?? Data(), value.pendingDeviceDigest ?? Data(), value.recoveryAuthorizationDigest ?? Data()]; return parts(partsValue) }
    public static func trustState(_ value: AccountTrustState) -> Data { var values = [Data("Plainpost.TrustState.v1".utf8), u16(1), uuid(value.accountID.rawValue), u64(value.epoch.value), u64(value.revision.value), value.previousCommitDigest ?? Data(), transition(value.transition), u64(value.keyGeneration.value), value.keyCommitment, u16(UInt16(value.members.count))]; values += value.members.map(signedTrustRecord); values.append(uuid(value.signerDeviceID.rawValue)); return parts(values) }
    public static func signedTrustState(_ value: AccountTrustState) -> Data { trustState(value) + part(value.signature) }
    public static func groupKeyPackage(_ value: AccountGroupKeyPackage, encryptedDigest: Data) -> Data { parts([Data("Plainpost.AccountGroupKeyPackage.Signature.v1".utf8), u16(1), uuid(value.accountID.rawValue), u64(value.epoch.value), u64(value.stateRevision.value), u64(value.keyGeneration.value), value.stateDigest, value.keyCommitment, uuid(value.recipientDeviceID.rawValue), uuid(value.senderDeviceID.rawValue), value.senderEphemeralPublicKey, encryptedDigest]) }
    public static func signedGroupKeyPackage(_ value: AccountGroupKeyPackage, encryptedDigest: Data) -> Data { groupKeyPackage(value, encryptedDigest: encryptedDigest) + part(value.signature) }
    public static func trustCommit(_ value: AccountTrustStateCommit, encryptedDigests: [Data]) -> Data { var values = [Data("Plainpost.TrustStateCommit.v1".utf8), u16(1), signedTrustState(value.state), u16(UInt16(value.keyPackages.count))]; for (item, digest) in zip(value.keyPackages, encryptedDigests) { values.append(signedGroupKeyPackage(item, encryptedDigest: digest)) }; return parts(values) }
    public static func trustCommitDigest(_ value: AccountTrustStateCommit) -> Data {
        let encryptedDigests = value.keyPackages.map { AccountSHA256.hash($0.nonce + $0.encryptedKeyMaterial) }
        return AccountSHA256.hash(trustCommit(value, encryptedDigests: encryptedDigests))
    }
    public static func finalize(_ value: AccountBootstrapFinalize, commitDigest: Data?) -> Data { parts([Data("Plainpost.AccountBootstrapFinalize.v1".utf8), u16(1), value.exchangeRequestDigest, value.challengeDigest, uuid(value.challenge.challengeID.rawValue), value.challenge.challengeNonce, uuid(value.challenge.accountID.rawValue), uuid(value.challenge.deviceID.rawValue), Data(value.challenge.mode.rawValue.utf8), Data(value.challenge.platform.rawValue.utf8), value.challenge.publicBundle.signingKey, value.challenge.publicBundle.agreementKey, commitDigest ?? Data()]) }
    public static func manifest(rootKeyID: String, version: PositiveUInt64, notBefore: String, expiresAt: String, previousDigest: Data?, keys: [AccountBootstrapKey]) -> Data { var values = [Data("Plainpost.CentralBootstrapKeyManifest.v1".utf8), u16(1), Data(rootKeyID.utf8), u64(version.value), Data(notBefore.utf8), Data(expiresAt.utf8), previousDigest ?? Data(), u16(UInt16(keys.count))]; for key in keys { values += [Data(key.keyID.utf8), Data(key.purpose.rawValue.utf8), key.publicKey, Data(key.notBefore.utf8), Data(key.expiresAt.utf8), Data(key.status.rawValue.utf8)] }; return parts(values) }
}

public struct AccountBootstrapKey: Codable, Hashable, Sendable { public let keyID: String; public let purpose: AccountKeyPurpose; public let publicKey: Data; public let notBefore: String; public let expiresAt: String; public let status: AccountKeyStatus; public init(keyID: String, purpose: AccountKeyPurpose, publicKey: Data, notBefore: String, expiresAt: String, status: AccountKeyStatus) throws { guard AccountWireCodec.isKeyID(keyID), AccountP256SEC1Validator.isValidUncompressedPoint(publicKey), let start = AccountWireCodec.parseTimestamp(notBefore), let end = AccountWireCodec.parseTimestamp(expiresAt), start < end else { throw AccountProtocolError.malformedWire }; self.keyID = keyID; self.purpose = purpose; self.publicKey = publicKey; self.notBefore = notBefore; self.expiresAt = expiresAt; self.status = status } }
public struct AccountBootstrapManifest: Codable, Hashable, Sendable { public let rootKeyID: String; public let manifestVersion: PositiveUInt64; public let notBefore: String; public let expiresAt: String; public let previousManifestDigest: Data?; public let keys: [AccountBootstrapKey]; public let rootSignature: Data; public init(rootKeyID: String, manifestVersion: PositiveUInt64, notBefore: String, expiresAt: String, previousManifestDigest: Data?, keys: [AccountBootstrapKey], rootSignature: Data) throws { guard AccountWireCodec.isKeyID(rootKeyID), rootSignature.count == 64, !keys.isEmpty, keys.count <= 8, keys.map(\.keyID) == keys.map(\.keyID).sorted(), Set(keys.map(\.keyID)).count == keys.count, let start = AccountWireCodec.parseTimestamp(notBefore), let end = AccountWireCodec.parseTimestamp(expiresAt), start < end else { throw AccountProtocolError.malformedWire }; self.rootKeyID = rootKeyID; self.manifestVersion = manifestVersion; self.notBefore = notBefore; self.expiresAt = expiresAt; self.previousManifestDigest = previousManifestDigest; self.keys = keys; self.rootSignature = rootSignature } }

/// An unauthenticated transport container. Each member still has to be
/// verified directly against the app-shipped offline root before use.
public struct AccountBootstrapManifestResponse: Hashable, Sendable {
    public let current: AccountBootstrapManifest
    public let overlap: [AccountBootstrapManifest]
    public init(current: AccountBootstrapManifest, overlap: [AccountBootstrapManifest]) throws {
        guard overlap.count <= 4 else { throw AccountProtocolError.oversized }
        self.current = current
        self.overlap = overlap
    }
    public var all: [AccountBootstrapManifest] { [current] + overlap }
}
