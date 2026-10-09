import Foundation
import CryptoKit
import XCTest
@testable import PlainpostAccountProtocol

final class AccountCodecTests: XCTestCase {
    func testLifecycleSubmissionAcceptsCanonicalAdmissionEvidence() throws {
        let page = try XCTUnwrap((try fixtureObject()["trustPagination"] as? [String: Any])?["page"] as? [String: Any])
        let entries = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let admission = try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: entries[1], options: [.sortedKeys, .withoutEscapingSlashes]))
        let target = try XCTUnwrap(admission.commit.state.transition.targetDeviceIDs.first)
        let previous = try XCTUnwrap(admission.commit.state.previousCommitDigest)
        let authorization = try AccountStepUpAuthorizationV1(
            authorizationID: AccountAuthorizationID("11111111-1111-4111-8111-111111111111"),
            accountID: admission.commit.state.accountID,
            actorDeviceID: admission.commit.state.signerDeviceID,
            targetDeviceID: target,
            action: .addDevice,
            currentCommitDigest: previous,
            requestDigest: Data(repeating: 2, count: 32),
            issuedAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z",
            serverKeyID: "recovery-2026-01",
            serverSignature: Data(repeating: 9, count: 64)
        )
        let submission = try AccountLifecycleSubmissionV1(authorization: authorization, entry: admission)
        let wire = try AccountWireCodec.encodeLifecycleSubmission(submission)
        XCTAssertEqual(try AccountWireCodec.decodeLifecycleSubmission(wire), submission)
    }

    func testSyncNodeLookupPreservesCanonicalEndpointCiphertext() throws {
        let wire = Data("{\"agreementPublicKey\":\"BHzyexiNA09-ilI4AwS1GsPAiWnid_IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E\",\"claimID\":\"11111111-1111-4111-8111-111111111111\",\"createdAt\":\"2026-08-14T12:00:00Z\",\"endpointCiphertext\":\"BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE\",\"endpointDigest\":\"BgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"expiresAt\":\"2026-08-14T12:05:00Z\",\"kind\":\"account.sync-node-claim-public.v1\",\"nodeDeviceID\":\"22222222-2222-4222-8222-222222222222\",\"noiseStaticPublicKey\":\"AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM\",\"signingPublicKey\":\"BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU\"}".utf8)
        let claim = try AccountWireCodec.decodeNodeEnrollmentPublicClaim(wire)
        XCTAssertEqual(claim.endpointCiphertext, Data(repeating: 4, count: 48))
        XCTAssertEqual(try AccountWireCodec.encodeNodeEnrollmentPublicClaim(claim), wire)
    }

    func testV2AdmissionResponseDecodesFrozenCanonicalArtifacts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as? [String: Any])
        let v2 = try XCTUnwrap(fixture["syncNodeEnrollmentV2"] as? [String: String])
        let wire = try JSONSerialization.data(withJSONObject: ["kind": "account.sync-node-admission-response.v2", "result": try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(v2["resultCanonicalJSON"]).utf8)), "refreshCredential": try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(v2["refreshCanonicalJSON"]).utf8)), "offlineLease": try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(v2["leaseCanonicalJSON"]).utf8)), "cleanupCapability": try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(v2["capabilityCanonicalJSON"]).utf8))], options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(try AccountWireCodec.encodeNodeEnrollmentAdmissionResponseV2(try AccountWireCodec.decodeNodeEnrollmentAdmissionResponseV2(wire)), wire)
    }
    func testPositiveUInt64AcceptsMaximumAndRejectsNonCanonicalValues() throws {
        XCTAssertEqual(try PositiveUInt64(wire: "18446744073709551615").value, UInt64.max)
        for invalid in ["0", "01", "+1", " 1", "18446744073709551616", "1.0", ""] {
            XCTAssertThrowsError(try PositiveUInt64(wire: invalid), invalid)
        }
    }

    func testAccountTrustEpochIsAComparableSingleValueWireWrapper() throws {
        let epoch = AccountTrustEpoch(rawValue: try PositiveUInt64(7))
        XCTAssertLessThan(try AccountTrustEpoch(rawValue: PositiveUInt64(6)), epoch)

        let wire = try JSONEncoder().encode(epoch)
        XCTAssertEqual(String(decoding: wire, as: UTF8.self), "\"7\"")
        XCTAssertEqual(try JSONDecoder().decode(AccountTrustEpoch.self, from: wire), epoch)
    }

    func testNominalIdentifiersCannotBypassCanonicalValidationThroughRawRepresentable() throws {
        XCTAssertNil(PlainpostAccountID(rawValue: "not-a-uuid"))
        XCTAssertNil(AccountDeviceID(rawValue: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        XCTAssertEqual(PlainpostAccountID(rawValue: "00112233-4455-6677-8899-aabbccddeeff")?.rawValue, "00112233-4455-6677-8899-aabbccddeeff")
    }

    func testNodeEnrollmentClaimIDIsASeparateCanonicalUUIDValue() throws {
        XCTAssertEqual(try NodeEnrollmentClaimID("00112233-4455-6677-8899-aabbccddeeff").rawValue, "00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertNil(NodeEnrollmentClaimID(rawValue: "00112233-4455-6677-8899-AABBCCDDEEFF"))
    }

    func testNodeEnrollmentEvidenceIsClosedCanonicalAndActionBound() throws {
        let signingKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let agreementKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let claim = try AccountNodeEnrollmentClaimV1(
            claimID: NodeEnrollmentClaimID("11111111-1111-4111-8111-111111111111"),
            nodeDeviceID: AccountDeviceID("22222222-2222-4222-8222-222222222222"),
            signingPublicKey: signingKey, agreementPublicKey: agreementKey, noiseStaticPublicKey: Data(repeating: 3, count: 32), endpointCiphertext: Data(repeating: 4, count: 48), setupVerifier: Data(repeating: 5, count: 32), endpointDigest: Data(repeating: 6, count: 32), createdAt: "2026-08-14T12:00:00Z", expiresAt: "2026-08-14T12:05:00Z"
        )
        let claimWire = try AccountWireCodec.encodeNodeEnrollmentClaim(claim)
        XCTAssertEqual(try AccountWireCodec.decodeNodeEnrollmentClaim(claimWire), claim)
        XCTAssertFalse(claim is any Encodable, "validated node claims must encode only through AccountWireCodec")

        let oldNodeID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let stepUp = try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("44444444-4444-4444-8444-444444444444"), accountID: PlainpostAccountID("55555555-5555-4555-8555-555555555555"), actorDeviceID: AccountDeviceID("66666666-6666-4666-8666-666666666666"), targetDeviceID: oldNodeID, action: .replaceSyncNode, currentCommitDigest: Data(repeating: 7, count: 32), requestDigest: Data(repeating: 8, count: 32), issuedAt: "2026-08-14T12:00:00Z", expiresAt: "2026-08-14T12:05:00Z", serverKeyID: "recovery-authorization-2026-08", serverSignature: Data(repeating: 9, count: 64))
        let evidence = try AccountNodeEnrollmentAdmissionEvidenceV1(accountID: stepUp.accountID, trustEpoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)), approverDeviceID: stepUp.actorDeviceID, claimID: claim.claimID, nodeDeviceID: claim.nodeDeviceID, action: .replace, replacedNodeID: oldNodeID, signingPublicKey: claim.signingPublicKey, agreementPublicKey: claim.agreementPublicKey, noiseStaticPublicKey: claim.noiseStaticPublicKey, endpointDigest: claim.endpointDigest, matchingTranscriptDigest: Data(repeating: 10, count: 32), stepUp: stepUp)
        let wire = try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(evidence)
        XCTAssertEqual(try AccountWireCodec.decodeNodeEnrollmentAdmissionEvidence(wire), evidence)
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustAdmissionEvidence(wire))
        XCTAssertThrowsError(try AccountWireCodec.decodeNodeEnrollmentAdmissionEvidence(Data((" " + String(decoding: wire, as: UTF8.self)).utf8)))
        XCTAssertThrowsError(try AccountNodeEnrollmentAdmissionEvidenceV1(accountID: stepUp.accountID, trustEpoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)), approverDeviceID: stepUp.actorDeviceID, claimID: claim.claimID, nodeDeviceID: claim.nodeDeviceID, action: .enroll, replacedNodeID: evidence.replacedNodeID, signingPublicKey: claim.signingPublicKey, agreementPublicKey: claim.agreementPublicKey, noiseStaticPublicKey: claim.noiseStaticPublicKey, endpointDigest: claim.endpointDigest, matchingTranscriptDigest: Data(repeating: 10, count: 32), stepUp: stepUp))
    }

    func testNodeIssuanceDocumentsShareOneAtomicOperationBinding() throws {
        let binding = try AccountNodeOperationBindingV1(accountID: PlainpostAccountID("55555555-5555-4555-8555-555555555555"), trustEpoch: AccountTrustEpoch(rawValue: PositiveUInt64(2)), claimID: NodeEnrollmentClaimID("11111111-1111-4111-8111-111111111111"), nodeDeviceID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), centralAudience: "central.plainpost.test", action: .replace, replacedNodeID: AccountDeviceID("33333333-3333-4333-8333-333333333333"), replacementRevocationDigest: Data([4]) + Data(repeating: 0, count: 31), admissionEvidenceDigest: Data([5]) + Data(repeating: 0, count: 31), issuanceDigest: Data([6]) + Data(repeating: 0, count: 31))
        let result = try AccountNodeEnrollmentResultV1(binding: binding, committedAt: "2026-08-14T12:06:00Z")
        let lease = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: "88888888-8888-4888-8888-888888888888", issuedAt: "2026-08-14T12:06:01Z", expiresAt: "2026-08-14T12:11:01Z", serverKeyID: "sync-node-issuance-2026-08", signature: Data(repeating: 9, count: 64))
        let refresh = try AccountNodeRefreshCredentialV1(binding: binding, credentialID: "99999999-9999-4999-8999-999999999999", issuedAt: "2026-08-14T12:06:01Z", expiresAt: "2026-08-14T12:11:01Z", credential: Data([7]) + Data(repeating: 0, count: 31))
        XCTAssertEqual(try AccountWireCodec.decodeNodeEnrollmentResult(AccountWireCodec.encodeNodeEnrollmentResult(result)), result)
        XCTAssertEqual(try AccountWireCodec.decodeNodeOfflineLease(AccountWireCodec.encodeNodeOfflineLease(lease)), lease)
        XCTAssertEqual(try AccountWireCodec.decodeNodeRefreshCredential(AccountWireCodec.encodeNodeRefreshCredential(refresh)), refresh)
        let substituted = try AccountNodeOperationBindingV1(accountID: binding.accountID, trustEpoch: binding.trustEpoch, claimID: binding.claimID, nodeDeviceID: binding.nodeDeviceID, centralAudience: "central.backup.plainpost.test", action: binding.action, replacedNodeID: binding.replacedNodeID, replacementRevocationDigest: binding.replacementRevocationDigest, admissionEvidenceDigest: binding.admissionEvidenceDigest, issuanceDigest: binding.issuanceDigest)
        XCTAssertNotEqual(AccountTranscript.nodeOperationBinding(binding), AccountTranscript.nodeOperationBinding(substituted))
        let substitutedResult = try AccountNodeEnrollmentResultV1(binding: substituted, committedAt: result.committedAt)
        let substitutedLease = try AccountNodeOfflineLeaseV1(binding: substituted, leaseID: lease.leaseID, issuedAt: lease.issuedAt, expiresAt: lease.expiresAt, serverKeyID: lease.serverKeyID, signature: lease.signature)
        let substitutedRefresh = try AccountNodeRefreshCredentialV1(binding: substituted, credentialID: refresh.credentialID, issuedAt: refresh.issuedAt, expiresAt: refresh.expiresAt, credential: refresh.credential)
        XCTAssertNotEqual(Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentResult(result))), Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentResult(substitutedResult))))
        XCTAssertNotEqual(Data(SHA256.hash(data: AccountTranscript.nodeOfflineLease(lease))), Data(SHA256.hash(data: AccountTranscript.nodeOfflineLease(substitutedLease))))
        XCTAssertNotEqual(Data(SHA256.hash(data: AccountTranscript.nodeRefreshCredential(refresh))), Data(SHA256.hash(data: AccountTranscript.nodeRefreshCredential(substitutedRefresh))))
        XCTAssertFalse(binding.isForCentralAudience(substituted.centralAudience))
        for invalidAudience in ["", String(repeating: "a", count: 256), "central\nother"] {
            XCTAssertThrowsError(try AccountNodeOperationBindingV1(accountID: binding.accountID, trustEpoch: binding.trustEpoch, claimID: binding.claimID, nodeDeviceID: binding.nodeDeviceID, centralAudience: invalidAudience, action: binding.action, replacedNodeID: binding.replacedNodeID, replacementRevocationDigest: binding.replacementRevocationDigest, admissionEvidenceDigest: binding.admissionEvidenceDigest, issuanceDigest: binding.issuanceDigest))
        }
        XCTAssertThrowsError(try AccountNodeOperationBindingV1(accountID: binding.accountID, trustEpoch: binding.trustEpoch, claimID: binding.claimID, nodeDeviceID: binding.nodeDeviceID, centralAudience: binding.centralAudience, action: .replace, replacedNodeID: binding.replacedNodeID, replacementRevocationDigest: nil, admissionEvidenceDigest: binding.admissionEvidenceDigest, issuanceDigest: binding.issuanceDigest))
        XCTAssertThrowsError(try AccountNodeRefreshCredentialV1(binding: binding, credentialID: refresh.credentialID, issuedAt: refresh.issuedAt, expiresAt: "2026-09-14T12:06:02Z", credential: refresh.credential))
    }

    func testCanonicalBase64URLRejectsPaddingAndNonCanonicalEncodings() throws {
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL("AA", exactBytes: 1), Data([0]))
        for invalid in ["AA=", "AA\n", "AB", "A"] {
            XCTAssertThrowsError(try AccountWireCodec.decodeBase64URL(invalid, exactBytes: 1), invalid)
        }
    }

    func testChallengeFixtureDecodesClosedWireAndRebuildsExactTranscript() throws {
        let fixture = try fixtureObject()
        let message = try XCTUnwrap((fixture["genesisBootstrapChallenge"] as? [String: Any])?["message"])
        let challenge = try AccountWireCodec.decodeBootstrapChallenge(try JSONSerialization.data(withJSONObject: message))
        let actual = AccountTranscript.bootstrapChallenge(challenge)
        let expected = try XCTUnwrap((fixture["genesisBootstrapChallenge"] as? [String: Any])?["canonicalTranscriptHex"] as? String)
        XCTAssertEqual(actual.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testClosedChallengeDecoderRejectsUnknownDuplicateAndNumberFields() throws {
        let challenge = try challengeJSONObject()
        var unknown = challenge
        unknown["unexpected"] = "field"
        XCTAssertThrowsError(try AccountWireCodec.decodeBootstrapChallenge(try JSONSerialization.data(withJSONObject: unknown)))

        let duplicate = """
        {"kind":"account.bootstrap-challenge.v1","kind":"account.bootstrap-challenge.v1"}
        """
        XCTAssertThrowsError(try AccountWireCodec.decodeBootstrapChallenge(Data(duplicate.utf8)))

        var numeric = challenge
        numeric["createdAt"] = 1
        XCTAssertThrowsError(try AccountWireCodec.decodeBootstrapChallenge(try JSONSerialization.data(withJSONObject: numeric)))
    }

    func testFinalizeFixturePreservesNullCommitForPendingAndRejectsWrongModeCommit() throws {
        let fixture = try fixtureObject()
        let pending = try XCTUnwrap(((fixture["bootstrapFinalize"] as? [String: Any])?["pending"] as? [String: Any])?["message"])
        let finalize = try AccountWireCodec.decodeBootstrapFinalize(try JSONSerialization.data(withJSONObject: pending))
        XCTAssertNil(finalize.genesisCommit)

        var invalid = pending as! [String: Any]
        invalid["genesisCommit"] = ((fixture["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any]
        XCTAssertThrowsError(try AccountWireCodec.decodeBootstrapFinalize(try JSONSerialization.data(withJSONObject: invalid)))
    }

    func testManifestAllowsOmittedOptionalPredecessorButRejectsUnknownFields() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/central-bootstrap-manifest-v1.json")
        var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        manifest.removeValue(forKey: "previousManifestDigest")
        XCTAssertNoThrow(try AccountWireCodec.decodeManifest(JSONSerialization.data(withJSONObject: manifest)))
        manifest["attacker"] = true
        XCTAssertThrowsError(try AccountWireCodec.decodeManifest(JSONSerialization.data(withJSONObject: manifest)))
    }

    func testManifestEncoderPreservesNullPredecessorForCrossLanguageCanonicalization() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/central-bootstrap-manifest-test-v1.json")
        let manifest = try AccountWireCodec.decodeManifest(Data(contentsOf: url))

        let encoded = try AccountWireCodec.encodeManifest(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertTrue(object["previousManifestDigest"] is NSNull)
    }

    func testManifestResponseIsClosedAndLimitsOverlapToFour() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/central-bootstrap-manifest-v1.json")
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let response: [String: Any] = [
            "kind": "central.bootstrap-key-manifest-response.v1",
            "current": manifest,
            "overlap": [],
        ]
        XCTAssertEqual(try AccountWireCodec.decodeManifestResponse(try JSONSerialization.data(withJSONObject: response)).all.count, 1)

        var oversized = response
        oversized["overlap"] = Array(repeating: manifest, count: 5)
        XCTAssertThrowsError(try AccountWireCodec.decodeManifestResponse(try JSONSerialization.data(withJSONObject: oversized)))

        var extra = response
        extra["unexpected"] = true
        XCTAssertThrowsError(try AccountWireCodec.decodeManifestResponse(try JSONSerialization.data(withJSONObject: extra)))
    }

    func testSharedExchangeAndFinalizeFixturesRebuildExactTranscripts() throws {
        let fixture = try fixtureObject()
        let exchange = try XCTUnwrap((fixture["genesisExchangeCorrelation"] as? [String: Any])?["request"])
        let request = try AccountWireCodec.decodeExchangeRequest(try JSONSerialization.data(withJSONObject: exchange))
        let tokenDigest = Data(SHA256.hash(data: Data(request.appleIdentityToken.utf8)))
        let proof = AccountTranscript.exchangeProof(tokenDigest: tokenDigest, nonce: request.nonce, bundle: request.deviceBundle)
        XCTAssertEqual(hex(proof), try XCTUnwrap((fixture["genesisExchangeCorrelation"] as? [String: Any])?["proofTranscriptHex"] as? String))
        XCTAssertEqual(hex(AccountTranscript.exchangeRequest(tokenDigest: tokenDigest, nonce: request.nonce, bundle: request.deviceBundle, proof: request.deviceProof)), try XCTUnwrap((fixture["genesisExchangeCorrelation"] as? [String: Any])?["requestTranscriptHex"] as? String))

        let genesis = try XCTUnwrap(((fixture["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"])
        let finalize = try AccountWireCodec.decodeBootstrapFinalize(try JSONSerialization.data(withJSONObject: genesis))
        let commit = try XCTUnwrap(finalize.genesisCommit)
        let packageDigests = commit.keyPackages.map { Data(SHA256.hash(data: $0.nonce + $0.encryptedKeyMaterial)) }
        let commitDigest = Data(SHA256.hash(data: AccountTranscript.trustCommit(commit, encryptedDigests: packageDigests)))
        XCTAssertEqual(hex(AccountTranscript.finalize(finalize, commitDigest: commitDigest)), try XCTUnwrap(((fixture["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["canonicalTranscriptHex"] as? String))

        let pending = try XCTUnwrap(((fixture["bootstrapFinalize"] as? [String: Any])?["pending"] as? [String: Any])?["message"])
        let pendingFinalize = try AccountWireCodec.decodeBootstrapFinalize(try JSONSerialization.data(withJSONObject: pending))
        XCTAssertEqual(hex(AccountTranscript.finalize(pendingFinalize, commitDigest: nil)), try XCTUnwrap(((fixture["bootstrapFinalize"] as? [String: Any])?["pending"] as? [String: Any])?["canonicalTranscriptHex"] as? String))
    }

    func testPendingAndRecoveryAuthorizationFixturesDecodeClosedWireAndRebuildTranscripts() throws {
        let fixture = try fixtureObject()
        let pendingMessage = try XCTUnwrap((fixture["pendingDeviceAuthorization"] as? [String: Any])?["message"])
        let pending = try AccountWireCodec.decodePendingDevice(try JSONSerialization.data(withJSONObject: pendingMessage))
        XCTAssertEqual(hex(AccountTranscript.pendingDeviceAuthorization(pending)), try XCTUnwrap((fixture["pendingDeviceAuthorization"] as? [String: Any])?["canonicalTranscriptHex"] as? String))

        let recoveryMessage = try XCTUnwrap((fixture["recoveryAuthorization"] as? [String: Any])?["message"])
        let recovery = try AccountWireCodec.decodeRecoveryAuthorization(try JSONSerialization.data(withJSONObject: recoveryMessage))
        XCTAssertEqual(hex(AccountTranscript.recoveryAuthorization(recovery)), try XCTUnwrap((fixture["recoveryAuthorization"] as? [String: Any])?["canonicalTranscriptHex"] as? String))
    }

    func testTrustCommitRejectsAKeyPackageForANonMemberAndAStateSignerOutsideTheMemberSet() throws {
        let fixture = try fixtureObject()
        let genesis = try XCTUnwrap(((fixture["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any])
        let commit = try XCTUnwrap(genesis["genesisCommit"] as? [String: Any])

        var nonMemberPackage = commit
        var packages = try XCTUnwrap(nonMemberPackage["keyPackages"] as? [[String: Any]])
        packages[0]["recipientDeviceID"] = "00112233-4455-6677-8899-aabbccddeeff"
        nonMemberPackage["keyPackages"] = packages
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustCommit(try JSONSerialization.data(withJSONObject: nonMemberPackage)))

        var outsiderSigner = commit
        var state = try XCTUnwrap(outsiderSigner["state"] as? [String: Any])
        state["signerDeviceID"] = "00112233-4455-6677-8899-aabbccddeeff"
        outsiderSigner["state"] = state
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustCommit(try JSONSerialization.data(withJSONObject: outsiderSigner)))
    }

    func testAdmissionCommitRetainsAnOlderUnchangedSurvivorAndRevisesOnlyTheNewMember() throws {
        let commit = try syntheticCommit(kind: .admission)
        XCTAssertEqual(commit.state.members.map(\.revision.wireValue), ["1", "2"])
        XCTAssertEqual(commit.state.revision.wireValue, "2")
    }

    func testRemovalCommitsRetainOlderUnchangedSurvivorsForRevocationAndSuspension() throws {
        for kind in [AccountTrustTransitionKind.revocation, .suspension] {
            let commit = try syntheticCommit(kind: kind)
            XCTAssertEqual(commit.state.members.map(\.revision.wireValue), ["1"])
            XCTAssertEqual(commit.state.revision.wireValue, "3")
        }
    }

    func testSyncNodeReplacementCommitCanRevokeTheExactOldMemberAndIntroduceOneNewNode() throws {
        let commit = try syntheticSyncNodeReplacementCommit()
        XCTAssertEqual(commit.state.transition.kind, .revocation)
        XCTAssertEqual(commit.state.transition.targetDeviceIDs.map(\.rawValue), ["00000000-0000-0000-0000-000000000002"])
        XCTAssertEqual(commit.state.members.map(\.deviceID.rawValue), ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000003"])
        XCTAssertEqual(commit.state.members.map(\.revision.wireValue), ["3", "3"])
        XCTAssertEqual(commit.state.members.last?.platform, .syncNode)
    }

    func testTrustCommitBindsEveryPackageToTheDigestOfItsEnclosedSignedState() throws {
        let valid = try syntheticCommit(kind: .admission)
        XCTAssertEqual(valid.keyPackages.first?.stateDigest, Data(SHA256.hash(data: AccountTranscript.signedTrustState(valid.state))))
        let packages = try valid.keyPackages.map { package in
            try AccountGroupKeyPackage(
                accountID: package.accountID,
                epoch: package.epoch,
                stateRevision: package.stateRevision,
                keyGeneration: package.keyGeneration,
                stateDigest: Data(repeating: 0x55, count: 32),
                keyCommitment: package.keyCommitment,
                recipientDeviceID: package.recipientDeviceID,
                senderDeviceID: package.senderDeviceID,
                senderEphemeralPublicKey: package.senderEphemeralPublicKey,
                nonce: package.nonce,
                encryptedKeyMaterial: package.encryptedKeyMaterial,
                signature: package.signature
            )
        }
        XCTAssertThrowsError(try AccountTrustStateCommit(state: valid.state, keyPackages: packages))
    }

    func testPublicKeyModelsRejectOffCurveAndFieldOutOfRangeSEC1Points() throws {
        let validSigning = P256.Signing.PrivateKey().publicKey.x963Representation
        let validAgreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let offCurve = Data([0x04]) + Data(repeating: 0, count: 64)
        let fieldPrime = try XCTUnwrap(Data(hexPoint: "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"))
        let fieldOutOfRange = Data([0x04]) + fieldPrime + Data(repeating: 0, count: 31) + Data([1])

        XCTAssertThrowsError(try AccountPublicKeyBundle(signingKey: offCurve, agreementKey: validAgreement))
        XCTAssertThrowsError(try AccountPublicKeyBundle(signingKey: validSigning, agreementKey: fieldOutOfRange))
        XCTAssertThrowsError(try syntheticPackage(senderEphemeralPublicKey: offCurve))
        XCTAssertThrowsError(try syntheticPackage(senderEphemeralPublicKey: fieldOutOfRange))
    }

    func testBootstrapManifestKeysRejectOffCurveAndFieldOutOfRangeSEC1Points() throws {
        let validKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let offCurve = Data([0x04]) + Data(repeating: 0, count: 64)
        let fieldPrime = try XCTUnwrap(Data(hexPoint: "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"))
        let fieldOutOfRange = Data([0x04]) + fieldPrime + Data(repeating: 0, count: 31) + Data([1])

        XCTAssertNoThrow(try AccountBootstrapKey(keyID: "bootstrap-2026-08", purpose: .bootstrapChallenge, publicKey: validKey, notBefore: "2026-08-04T00:00:00Z", expiresAt: "2027-08-04T00:00:00Z", status: .active))
        XCTAssertThrowsError(try AccountBootstrapKey(keyID: "bootstrap-2026-08", purpose: .bootstrapChallenge, publicKey: offCurve, notBefore: "2026-08-04T00:00:00Z", expiresAt: "2027-08-04T00:00:00Z", status: .active))
        XCTAssertThrowsError(try AccountBootstrapKey(keyID: "bootstrap-2026-08", purpose: .bootstrapChallenge, publicKey: fieldOutOfRange, notBefore: "2026-08-04T00:00:00Z", expiresAt: "2027-08-04T00:00:00Z", status: .active))
    }

    func testRecoveryProducesExactlyOneFreshSelfSignedReplacementOutsidePriorTargets() throws {
        let state = try syntheticRecoveryState(replacementRevision: 1, includePriorMember: false)
        XCTAssertEqual(state.revision.wireValue, "1")
        XCTAssertEqual(state.keyGeneration.wireValue, "1")
        XCTAssertEqual(state.members.count, 1)
        XCTAssertEqual(state.members[0].revision, state.revision)
        XCTAssertEqual(state.members[0].deviceID, state.members[0].signerDeviceID)
        XCTAssertFalse(state.transition.targetDeviceIDs.contains(state.members[0].deviceID))
    }

    func testRecoveryRejectsAStaleRevisionReplacementOrMultipleResultingMembers() throws {
        XCTAssertThrowsError(try syntheticRecoveryState(replacementRevision: 2, includePriorMember: false))
        XCTAssertThrowsError(try syntheticRecoveryState(replacementRevision: 1, includePriorMember: true))
    }

    func testRecoveryRejectsNonInitialStateRevisionAndKeyGeneration() throws {
        XCTAssertThrowsError(try syntheticRecoveryState(replacementRevision: 2, includePriorMember: false, stateRevision: 2)) {
            XCTAssertEqual($0 as? AccountProtocolError, .invalidTransition)
        }
        XCTAssertThrowsError(try syntheticRecoveryState(replacementRevision: 1, includePriorMember: false, keyGeneration: 2)) {
            XCTAssertEqual($0 as? AccountProtocolError, .invalidTransition)
        }
    }

    func testAccountProtocolTargetUsesOnlyApprovedSystemImports() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/PlainpostAccountProtocol")
        let files = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let imports = try files.flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init).filter { $0.hasPrefix("import ") }
        }
        XCTAssertEqual(Set(imports), ["import CryptoKit", "import Foundation", "import Security"])
    }

    private func fixtureObject() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func challengeJSONObject() throws -> [String: Any] {
        let fixture = try fixtureObject()
        return try XCTUnwrap((fixture["genesisBootstrapChallenge"] as? [String: Any])?["message"] as? [String: Any])
    }

    private func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }

    private func syntheticCommit(kind: AccountTrustTransitionKind) throws -> AccountTrustStateCommit {
        let accountID = try PlainpostAccountID("00000000-0000-0000-0000-000000000010")
        let survivorID = try AccountDeviceID("00000000-0000-0000-0000-000000000001")
        let targetID = try AccountDeviceID("00000000-0000-0000-0000-000000000002")
        let epoch = AccountTrustEpoch(rawValue: try PositiveUInt64(1))
        let stateRevision = try PositiveUInt64(kind == .admission ? 2 : 3)
        let survivor = try AccountDeviceTrustRecord(accountID: accountID, epoch: epoch, revision: try PositiveUInt64(1), deviceID: survivorID, platform: .macos, publicBundle: syntheticBundle(1, 2), signerDeviceID: survivorID, signature: Data(repeating: 1, count: 64))
        let members: [AccountDeviceTrustRecord]
        let transition: AccountTrustTransition
        if kind == .admission {
            let admitted = try AccountDeviceTrustRecord(accountID: accountID, epoch: epoch, revision: stateRevision, deviceID: targetID, platform: .ios, publicBundle: syntheticBundle(3, 4), signerDeviceID: survivorID, signature: Data(repeating: 2, count: 64))
            members = [survivor, admitted]
            transition = try AccountTrustTransition(kind: .admission, targetDeviceIDs: [targetID], priorRecordDigests: [], handshakeDigest: Data(repeating: 3, count: 32), pendingDeviceDigest: Data(repeating: 4, count: 32))
        } else {
            members = [survivor]
            transition = try AccountTrustTransition(kind: kind, targetDeviceIDs: [targetID], priorRecordDigests: [try AccountPriorRecordDigest(deviceID: targetID, recordDigest: Data(repeating: 5, count: 32))])
        }
        let state = try AccountTrustState(accountID: accountID, epoch: epoch, revision: stateRevision, previousCommitDigest: Data(repeating: 6, count: 32), transition: transition, keyGeneration: try PositiveUInt64(2), keyCommitment: Data(repeating: 7, count: 32), members: members, signerDeviceID: survivorID, signature: Data(repeating: 8, count: 64))
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let packages = try members.map { member in
            try syntheticPackage(accountID: accountID, epoch: epoch, stateRevision: stateRevision, stateDigest: stateDigest, keyCommitment: state.keyCommitment, recipientDeviceID: member.deviceID, senderDeviceID: survivorID)
        }
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }

    private func syntheticSyncNodeReplacementCommit() throws -> AccountTrustStateCommit {
        let accountID = try PlainpostAccountID("00000000-0000-0000-0000-000000000010")
        let survivorID = try AccountDeviceID("00000000-0000-0000-0000-000000000001")
        let revokedID = try AccountDeviceID("00000000-0000-0000-0000-000000000002")
        let replacementID = try AccountDeviceID("00000000-0000-0000-0000-000000000003")
        let epoch = AccountTrustEpoch(rawValue: try PositiveUInt64(1))
        let revision = try PositiveUInt64(3)
        let survivor = try AccountDeviceTrustRecord(accountID: accountID, epoch: epoch, revision: revision, deviceID: survivorID, platform: .macos, publicBundle: syntheticBundle(1, 2), signerDeviceID: survivorID, signature: Data(repeating: 1, count: 64))
        let replacement = try AccountDeviceTrustRecord(accountID: accountID, epoch: epoch, revision: revision, deviceID: replacementID, platform: .syncNode, publicBundle: syntheticBundle(3, 4), signerDeviceID: survivorID, signature: Data(repeating: 2, count: 64))
        let transition = try AccountTrustTransition(kind: .revocation, targetDeviceIDs: [revokedID], priorRecordDigests: [try AccountPriorRecordDigest(deviceID: revokedID, recordDigest: Data(repeating: 5, count: 32))])
        let state = try AccountTrustState(accountID: accountID, epoch: epoch, revision: revision, previousCommitDigest: Data(repeating: 6, count: 32), transition: transition, keyGeneration: try PositiveUInt64(2), keyCommitment: Data(repeating: 7, count: 32), members: [survivor, replacement], signerDeviceID: survivorID, signature: Data(repeating: 8, count: 64))
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let packages = try state.members.map { member in
            try syntheticPackage(accountID: accountID, epoch: epoch, stateRevision: revision, stateDigest: stateDigest, keyCommitment: state.keyCommitment, recipientDeviceID: member.deviceID, senderDeviceID: survivorID)
        }
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }

    private func syntheticPackage(
        accountID: PlainpostAccountID = try! PlainpostAccountID("00000000-0000-0000-0000-000000000010"),
        epoch: AccountTrustEpoch = AccountTrustEpoch(rawValue: try! PositiveUInt64(1)),
        stateRevision: PositiveUInt64 = try! PositiveUInt64(2),
        stateDigest: Data = Data(repeating: 1, count: 32),
        keyCommitment: Data = Data(repeating: 7, count: 32),
        recipientDeviceID: AccountDeviceID = try! AccountDeviceID("00000000-0000-0000-0000-000000000001"),
        senderDeviceID: AccountDeviceID = try! AccountDeviceID("00000000-0000-0000-0000-000000000001"),
        senderEphemeralPublicKey: Data = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    ) throws -> AccountGroupKeyPackage {
        try AccountGroupKeyPackage(accountID: accountID, epoch: epoch, stateRevision: stateRevision, keyGeneration: try PositiveUInt64(2), stateDigest: stateDigest, keyCommitment: keyCommitment, recipientDeviceID: recipientDeviceID, senderDeviceID: senderDeviceID, senderEphemeralPublicKey: senderEphemeralPublicKey, nonce: Data(repeating: 9, count: 12), encryptedKeyMaterial: Data(repeating: 10, count: 80), signature: Data(repeating: 11, count: 64))
    }

    private func syntheticBundle(_ signing: UInt8, _ agreement: UInt8) throws -> AccountPublicKeyBundle {
        try AccountPublicKeyBundle(signingKey: P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([signing])).publicKey.x963Representation, agreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([agreement])).publicKey.x963Representation)
    }

    private func syntheticRecoveryState(replacementRevision: UInt64, includePriorMember: Bool, stateRevision: UInt64 = 1, keyGeneration: UInt64 = 1) throws -> AccountTrustState {
        let accountID = try PlainpostAccountID("00000000-0000-0000-0000-000000000010")
        let priorID = try AccountDeviceID("00000000-0000-0000-0000-000000000001")
        let replacementID = try AccountDeviceID("00000000-0000-0000-0000-000000000003")
        let epoch = AccountTrustEpoch(rawValue: try PositiveUInt64(2))
        let revision = try PositiveUInt64(stateRevision)
        let replacement = try AccountDeviceTrustRecord(accountID: accountID, epoch: epoch, revision: try PositiveUInt64(replacementRevision), deviceID: replacementID, platform: .macos, publicBundle: syntheticBundle(5, 6), signerDeviceID: replacementID, signature: Data(repeating: 12, count: 64))
        var members = [replacement]
        if includePriorMember {
            members.insert(try AccountDeviceTrustRecord(accountID: accountID, epoch: epoch, revision: try PositiveUInt64(1), deviceID: priorID, platform: .ios, publicBundle: syntheticBundle(7, 8), signerDeviceID: priorID, signature: Data(repeating: 13, count: 64)), at: 0)
        }
        let transition = try AccountTrustTransition(kind: .recovery, targetDeviceIDs: [priorID], priorRecordDigests: [try AccountPriorRecordDigest(deviceID: priorID, recordDigest: Data(repeating: 14, count: 32))], recoveryAuthorizationDigest: Data(repeating: 15, count: 32))
        return try AccountTrustState(accountID: accountID, epoch: epoch, revision: revision, previousCommitDigest: Data(repeating: 16, count: 32), transition: transition, keyGeneration: try PositiveUInt64(keyGeneration), keyCommitment: Data(repeating: 17, count: 32), members: members, signerDeviceID: replacementID, signature: Data(repeating: 18, count: 64))
    }
}

private extension Data {
    init?(hexPoint: String) { guard hexPoint.count.isMultiple(of: 2) else { return nil }; self = Data(stride(from: 0, to: hexPoint.count, by: 2).compactMap { UInt8(hexPoint.dropFirst($0).prefix(2), radix: 16) }); guard count == hexPoint.count / 2 else { return nil } }
}
