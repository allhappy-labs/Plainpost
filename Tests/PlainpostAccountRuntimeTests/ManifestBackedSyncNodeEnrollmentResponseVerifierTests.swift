import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class ManifestBackedSyncNodeEnrollmentResponseVerifierTests: XCTestCase {
    func testAcceptsExactlyBoundAndManifestSignedEnrollmentResponse() throws {
        let fixture = try DirectVerifierFixture()
        XCTAssertNoThrow(try fixture.verify(fixture.response()))
    }

    func testRejectsEveryIndependentOperationAndSessionSubstitution() throws {
        let fixture = try DirectVerifierFixture()
        let response = try fixture.response()
        let binding = response.result.binding
        let otherAccount = try PlainpostAccountID("99999999-9999-4999-8999-999999999999")
        let otherClaim = try NodeEnrollmentClaimID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab")
        let otherNode = try AccountDeviceID("22222222-2222-4222-8222-222222222222")

        let substitutions: [AccountNodeOperationBindingV1] = [
            try fixture.binding(from: binding, accountID: otherAccount),
            try fixture.binding(from: binding, centralAudience: "other.central"),
            try fixture.binding(from: binding, trustEpoch: AccountTrustEpoch(rawValue: PositiveUInt64(binding.trustEpoch.value + 1))),
            try fixture.binding(from: binding, claimID: otherClaim),
            try fixture.binding(from: binding, nodeDeviceID: otherNode),
            try fixture.binding(from: binding, admissionEvidenceDigest: Data(repeating: 3, count: 32)),
            try fixture.binding(from: binding, issuanceDigest: Data(repeating: 4, count: 32)),
        ]
        for substituted in substitutions {
            XCTAssertThrowsError(try fixture.verify(fixture.response(binding: substituted)))
        }

        let changedRefresh = try fixture.response(binding: binding, refreshCredential: Data(repeating: 9, count: 32))
        XCTAssertThrowsError(try fixture.verify(changedRefresh), "refresh credential changes must alter the session digest")
        let changedLeaseID = try fixture.response(binding: binding, leaseID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbc")
        XCTAssertThrowsError(try fixture.verify(changedLeaseID), "lease ID changes must alter the session digest")

        XCTAssertThrowsError(try fixture.verify(fixture.response(committedAt: "2026-08-05T12:00:02Z")))
        XCTAssertThrowsError(try fixture.verify(fixture.response(refreshIssuedAt: "2026-08-05T12:00:02Z")))
        XCTAssertThrowsError(try fixture.verify(fixture.response(refreshExpiresAt: "2026-08-05T12:00:00Z")))
        XCTAssertThrowsError(try fixture.verify(fixture.response(leaseExpiresAt: "2026-08-05T12:00:00Z")))
        XCTAssertThrowsError(try fixture.verify(fixture.response(refreshIssuedAt: "2026-08-05T12:00:01Z")), "refresh and lease issuance times must agree")
        XCTAssertThrowsError(try fixture.verify(fixture.response(leaseIssuedAt: "2026-08-05T12:00:02Z")))
        XCTAssertThrowsError(try fixture.verify(fixture.response(leaseIssuedAt: "2026-08-05T11:59:59Z")))
        XCTAssertThrowsError(try fixture.verify(fixture.response(serverKeyID: "access-test-1")))
        XCTAssertThrowsError(try fixture.verify(fixture.response(corruptLeaseSignature: true)))
    }

    func testRejectsReplacementActionAndReplacedNodeSubstitution() throws {
        let fixture = try DirectVerifierFixture()
        let replacement = try fixture.replacementMaterial()
        XCTAssertNoThrow(try replacement.verify(replacement.response()))
        let differentOldNode = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let oldBinding = try replacement.response().result.binding
        XCTAssertThrowsError(try replacement.verify(replacement.response(binding: try fixture.binding(from: oldBinding, replacementRevocationDigest: Data(repeating: 1, count: 32)))))
        XCTAssertThrowsError(try replacement.verify(replacement.response(binding: try fixture.binding(from: oldBinding, replacementRevocationDigest: Data(repeating: 2, count: 32)))))
        let nilDigest: Data?? = .some(nil)
        XCTAssertThrowsError(try fixture.binding(from: oldBinding, replacementRevocationDigest: nilDigest), "nil replacement revocation digest is malformed before it can reach the verifier")
        XCTAssertThrowsError(try replacement.verify(replacement.response(binding: try fixture.binding(from: oldBinding, replacedNodeID: differentOldNode))))
        let enrollBinding = try fixture.response().result.binding
        XCTAssertThrowsError(try replacement.verify(replacement.response(binding: try fixture.binding(from: oldBinding, action: .enroll, replacedNodeID: nil, replacementRevocationDigest: nil))))
        XCTAssertThrowsError(try fixture.verify(fixture.response(binding: try fixture.binding(from: enrollBinding, action: .replace, replacedNodeID: fixture.currentNode, replacementRevocationDigest: Data(repeating: 6, count: 32)))))
    }

    // Catches a regression where the shipping V2 admission shape bypasses the
    // same manifest, audience, capability, timestamp, and lease checks as V1.
    func testV2VerifierRejectsBoundDocumentMutation() throws {
        let fixture = try DirectVerifierFixture()
        let material = try fixture.v2Material()
        XCTAssertNoThrow(try material.verify(material.responseV2()))
        XCTAssertThrowsError(try material.verify(material.responseV2(centralAudience: "wrong.central")))
        XCTAssertThrowsError(try material.verify(material.responseV2(corruptLeaseSignature: true)))
        XCTAssertThrowsError(try material.verify(material.responseV2(committedAt: "2026-08-05T12:00:01Z")))
    }

    // The installed Mac compared a host-derived audience with a label bound by
    // Central. The verifier must classify that exact case.
    func testV2VerifierClassifiesHostDerivedAudienceAsAudienceMismatch() throws {
        let fixture = try DirectVerifierFixture()
        let material = try fixture.v2Material()
        let response = try material.responseV2(centralAudience: "plainpost-central-private-beta")
        XCTAssertThrowsError(try material.verifier.verify(response: response, request: material.request, centralAudience: "plainpost-api.olhapi.com", now: material.now)) {
            XCTAssertEqual($0 as? SyncNodeEnrollmentVerificationError, .audienceMismatch)
        }
        XCTAssertNoThrow(try material.verifier.verify(response: response, request: material.request, centralAudience: "plainpost-central-private-beta", now: material.now))
        XCTAssertThrowsError(try material.verifier.verify(response: try material.responseV2(corruptLeaseSignature: true), request: material.request, centralAudience: "central.test", now: material.now)) {
            XCTAssertEqual($0 as? AccountRuntimeError, .untrustedResponse)
        }
    }
}

private struct DirectVerifierFixture {
    let now = try! XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-05T12:00:01Z"))
    let centralAudience = "central.test"
    let trustCommit: AccountTrustStateCommit
    let claim: AccountNodeEnrollmentPublicClaimV1
    let currentNode = try! AccountDeviceID("11111111-2222-3333-4444-555555555555")
    let manifest: SessionKeyManifestVerifier

    init() throws {
        let root = try fixtureJSON("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let genesis = try XCTUnwrap(((root["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any])
        trustCommit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(genesis["genesisCommit"])))
        let signing = P256.Signing.PrivateKey().publicKey.x963Representation
        let agreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        claim = try AccountNodeEnrollmentPublicClaimV1(claimID: NodeEnrollmentClaimID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), nodeDeviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), signingPublicKey: signing, agreementPublicKey: agreement, noiseStaticPublicKey: Data(repeating: 7, count: 32), endpointDigest: Data(repeating: 8, count: 32), createdAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z")
        let session = try fixtureJSON("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json")
        manifest = try SessionKeyManifestVerifier(document: JSONSerialization.data(withJSONObject: try XCTUnwrap(session["manifest"])), offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: try XCTUnwrap(Data(base64URL: try XCTUnwrap(session["offlineRootPublicKey"] as? String))), now: now)
    }

    func replacementMaterial() throws -> DirectVerifierMaterial {
        try material(action: .replace, replacedNodeID: currentNode)
    }
    func v2Material() throws -> DirectVerifierMaterial { try material() }
    func verify(_ response: SyncNodeEnrollmentAdmissionResponse) throws { try material().verify(response) }
    func response(binding: AccountNodeOperationBindingV1? = nil, refreshCredential: Data = Data(repeating: 5, count: 32), leaseID: String = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", committedAt: String = "2026-08-05T12:00:00Z", refreshIssuedAt: String = "2026-08-05T12:00:00Z", refreshExpiresAt: String = "2026-08-05T12:05:00Z", leaseIssuedAt: String = "2026-08-05T12:00:00Z", leaseExpiresAt: String = "2026-08-05T12:05:00Z", serverKeyID: String = "offline-test-1", corruptLeaseSignature: Bool = false) throws -> SyncNodeEnrollmentAdmissionResponse { try material().response(binding: binding, refreshCredential: refreshCredential, leaseID: leaseID, committedAt: committedAt, refreshIssuedAt: refreshIssuedAt, refreshExpiresAt: refreshExpiresAt, leaseIssuedAt: leaseIssuedAt, leaseExpiresAt: leaseExpiresAt, serverKeyID: serverKeyID, corruptLeaseSignature: corruptLeaseSignature) }
    func binding(from binding: AccountNodeOperationBindingV1, accountID: PlainpostAccountID? = nil, centralAudience: String? = nil, trustEpoch: AccountTrustEpoch? = nil, claimID: NodeEnrollmentClaimID? = nil, nodeDeviceID: AccountDeviceID? = nil, action: AccountNodeEnrollmentAction? = nil, replacedNodeID: AccountDeviceID?? = nil, replacementRevocationDigest: Data?? = nil, admissionEvidenceDigest: Data? = nil, issuanceDigest: Data? = nil) throws -> AccountNodeOperationBindingV1 {
        try AccountNodeOperationBindingV1(accountID: accountID ?? binding.accountID, trustEpoch: trustEpoch ?? binding.trustEpoch, claimID: claimID ?? binding.claimID, nodeDeviceID: nodeDeviceID ?? binding.nodeDeviceID, centralAudience: centralAudience ?? binding.centralAudience, action: action ?? binding.action, replacedNodeID: replacedNodeID ?? binding.replacedNodeID, replacementRevocationDigest: replacementRevocationDigest ?? binding.replacementRevocationDigest, admissionEvidenceDigest: admissionEvidenceDigest ?? binding.admissionEvidenceDigest, issuanceDigest: issuanceDigest ?? binding.issuanceDigest)
    }

    private func material(action: AccountNodeEnrollmentAction = .enroll, replacedNodeID: AccountDeviceID? = nil) throws -> DirectVerifierMaterial {
        let stepUp = try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("cccccccc-cccc-4ccc-8ccc-cccccccccccc"), accountID: trustCommit.state.accountID, actorDeviceID: trustCommit.state.members[0].deviceID, targetDeviceID: action == .enroll ? claim.nodeDeviceID : replacedNodeID, action: action == .enroll ? .enrollSyncNode : .replaceSyncNode, currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit), requestDigest: Data(repeating: 1, count: 32), issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z", serverKeyID: "access-test-1", serverSignature: Data(repeating: 2, count: 64))
        let evidence = try AccountNodeEnrollmentAdmissionEvidenceV1(accountID: trustCommit.state.accountID, trustEpoch: trustCommit.state.epoch, approverDeviceID: trustCommit.state.members[0].deviceID, claimID: claim.claimID, nodeDeviceID: claim.nodeDeviceID, action: action, replacedNodeID: replacedNodeID, signingPublicKey: claim.signingPublicKey, agreementPublicKey: claim.agreementPublicKey, noiseStaticPublicKey: claim.noiseStaticPublicKey, endpointDigest: claim.endpointDigest, matchingTranscriptDigest: Data(repeating: 3, count: 32), stepUp: stepUp)
        let request = try SyncNodeEnrollmentAdmissionRequest(evidence: evidence, claimProofSignature: Data(repeating: 4, count: 64), matchingConfirmationSignature: Data(repeating: 5, count: 64), admissionApprovalSignature: Data(repeating: 6, count: 64), idempotencyKey: Data(repeating: 7, count: 32), trustCommit: trustCommit)
        return DirectVerifierMaterial(verifier: ManifestBackedSyncNodeEnrollmentResponseVerifier(manifest: manifest), request: request, centralAudience: centralAudience, now: now)
    }
}

private struct DirectVerifierMaterial {
    let verifier: ManifestBackedSyncNodeEnrollmentResponseVerifier; let request: SyncNodeEnrollmentAdmissionRequest; let centralAudience: String; let now: Date
    func verify(_ response: SyncNodeEnrollmentAdmissionResponse) throws { try verifier.verify(response: response, request: request, centralAudience: centralAudience, now: now) }
    func response(binding suppliedBinding: AccountNodeOperationBindingV1? = nil, refreshCredential: Data = Data(repeating: 5, count: 32), leaseID: String = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", committedAt: String = "2026-08-05T12:00:00Z", refreshIssuedAt: String = "2026-08-05T12:00:00Z", refreshExpiresAt: String = "2026-08-05T12:05:00Z", leaseIssuedAt: String = "2026-08-05T12:00:00Z", leaseExpiresAt: String = "2026-08-05T12:05:00Z", serverKeyID: String = "offline-test-1", corruptLeaseSignature: Bool = false) throws -> SyncNodeEnrollmentAdmissionResponse {
        let evidenceDigest = Data(SHA256.hash(data: try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence)))
        let sessionDigest = AccountTranscript.nodeEnrollmentSessionDigest(refreshCredential: refreshCredential, offlineLeaseID: leaseID)
        let issuanceDigest = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentSessionIssuance(request.evidence, centralAudience: centralAudience, sessionDigest: sessionDigest)))
        let replacementDigest = request.evidence.replacedNodeID.map { Data(SHA256.hash(data: Data("Plainpost.SyncNodeReplacementRevocation.v1\u{0000}\(request.evidence.accountID.rawValue)\u{0000}\($0.rawValue)\u{0000}\(committedAt)".utf8))) }
        let binding = try suppliedBinding ?? AccountNodeOperationBindingV1(accountID: request.evidence.accountID, trustEpoch: request.evidence.trustEpoch, claimID: request.evidence.claimID, nodeDeviceID: request.evidence.nodeDeviceID, centralAudience: centralAudience, action: request.evidence.action, replacedNodeID: request.evidence.replacedNodeID, replacementRevocationDigest: replacementDigest, admissionEvidenceDigest: evidenceDigest, issuanceDigest: issuanceDigest)
        let refresh = try AccountNodeRefreshCredentialV1(binding: binding, credentialID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", issuedAt: refreshIssuedAt, expiresAt: refreshExpiresAt, credential: refreshCredential)
        let unsigned = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: leaseID, issuedAt: leaseIssuedAt, expiresAt: leaseExpiresAt, serverKeyID: serverKeyID, signature: Data(repeating: 0, count: 64))
        let signingScalar: UInt8 = serverKeyID == "offline-test-1" ? 3 : 2
        var signature = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([signingScalar])).signature(for: AccountTranscript.nodeOfflineLease(unsigned)).rawRepresentation
        if corruptLeaseSignature { signature[0] ^= 1 }
        let lease = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: leaseID, issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt, serverKeyID: serverKeyID, signature: signature)
        return try SyncNodeEnrollmentAdmissionResponse(result: AccountNodeEnrollmentResultV1(binding: binding, committedAt: committedAt), refreshCredential: refresh, offlineLease: lease)
    }

    func responseV2(centralAudience suppliedAudience: String? = nil, committedAt: String = "2026-08-05T12:00:00Z", corruptLeaseSignature: Bool = false) throws -> SyncNodeEnrollmentAdmissionResponse {
        let audience = suppliedAudience ?? centralAudience
        let capability = try AccountSyncNodeCleanupCapabilityV1(accountID: request.evidence.accountID, claimID: request.evidence.claimID, nodeDeviceID: request.evidence.nodeDeviceID, targetHandle: Data(repeating: 8, count: 32), cleanupCredential: Data(repeating: 9, count: 32), deletionGeneration: try PositiveUInt64(1), issuedAt: committedAt)
        let capabilityDigest = Data(SHA256.hash(data: try AccountWireCodec.encodeSyncNodeCleanupCapability(capability)))
        let refreshCredential = Data(repeating: 5, count: 32)
        let leaseID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let sessionDigest = AccountTranscript.nodeEnrollmentSessionDigestV2(refreshCredential: refreshCredential, offlineLeaseID: leaseID, cleanupCapabilityDigest: capabilityDigest)
        let issuanceDigest = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentSessionIssuanceV2(request.evidence, centralAudience: audience, sessionDigest: sessionDigest)))
        let replacementDigest = request.evidence.replacedNodeID.map { Data(SHA256.hash(data: Data("Plainpost.SyncNodeReplacementRevocation.v1\u{0000}\(request.evidence.accountID.rawValue)\u{0000}\($0.rawValue)\u{0000}\(committedAt)".utf8))) }
        let base = try AccountNodeOperationBindingV1(accountID: request.evidence.accountID, trustEpoch: request.evidence.trustEpoch, claimID: request.evidence.claimID, nodeDeviceID: request.evidence.nodeDeviceID, centralAudience: audience, action: request.evidence.action, replacedNodeID: request.evidence.replacedNodeID, replacementRevocationDigest: replacementDigest, admissionEvidenceDigest: Data(SHA256.hash(data: try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence))), issuanceDigest: issuanceDigest)
        let binding = try AccountNodeOperationBindingV2(base: base, cleanupCapabilityDigest: capabilityDigest)
        let result = try AccountNodeEnrollmentResultV2(binding: binding, committedAt: committedAt)
        let refresh = try AccountNodeRefreshCredentialV2(binding: binding, credentialID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z", credential: refreshCredential)
        let unsigned = try AccountNodeOfflineLeaseV2(binding: binding, leaseID: leaseID, issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z", serverKeyID: "offline-test-1", signature: Data(repeating: 1, count: 64))
        var signature = lowSSignature(try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3])).signature(for: AccountTranscript.nodeOfflineLeaseV2(unsigned)).rawRepresentation)
        if corruptLeaseSignature { signature[0] ^= 1 }
        let lease = try AccountNodeOfflineLeaseV2(binding: binding, leaseID: unsigned.leaseID, issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt, serverKeyID: unsigned.serverKeyID, signature: signature)
        return try SyncNodeEnrollmentAdmissionResponse(v2: AccountNodeEnrollmentAdmissionResponseV2(result: result, refreshCredential: refresh, offlineLease: lease, cleanupCapability: capability))
    }
}

private func fixtureJSON(_ path: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as? [String: Any])
}

private extension Data {
    init?(base64URL value: String) { self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)) }
}

private func lowSSignature(_ signature: Data) -> Data {
    let halfOrder = Data([0x7f, 0xff, 0xff, 0xff, 0x80, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xe7, 0x37, 0xd5, 0x6d, 0x38, 0xbc, 0xf4, 0x27, 0x9d, 0xce, 0x56, 0x1, 0x7e, 0x31, 0x92, 0xa8])
    guard signature.count == 64, halfOrder.lexicographicallyPrecedes(signature.suffix(32)) else { return signature }
    let order = [UInt8]([0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51])
    let high = [UInt8](signature.suffix(32))
    var result = Array(repeating: UInt8(0), count: 32), borrow = 0
    for index in stride(from: 31, through: 0, by: -1) {
        let value = Int(order[index]) - Int(high[index]) - borrow
        result[index] = UInt8(value < 0 ? value + 256 : value)
        borrow = value < 0 ? 1 : 0
    }
    return signature.prefix(32) + Data(result)
}
