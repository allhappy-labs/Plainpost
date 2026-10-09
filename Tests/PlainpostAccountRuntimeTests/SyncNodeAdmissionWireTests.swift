import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class SyncNodeAdmissionWireTests: XCTestCase {
    func testAdmissionBodyDeclaresPinnedAudienceOnlyWhenPresent() throws {
        let legacy = try Self.admissionRequest(expectedCentralAudience: nil)
        let declared = try Self.admissionRequest(expectedCentralAudience: "plainpost-central-private-beta")
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: AccountAPIClient.syncNodeAdmissionBody(legacy)) as? [String: Any])
        let declaredObject = try XCTUnwrap(JSONSerialization.jsonObject(with: AccountAPIClient.syncNodeAdmissionBody(declared)) as? [String: Any])
        XCTAssertEqual(Set(legacyObject.keys), ["kind", "evidence", "claimProofSignature", "matchingConfirmationSignature", "admissionApprovalSignature", "idempotencyKey", "trustCommit"])
        XCTAssertEqual(Set(declaredObject.keys), Set(legacyObject.keys).union(["expectedCentralAudience"]))
        XCTAssertEqual(declaredObject["expectedCentralAudience"] as? String, "plainpost-central-private-beta")
        XCTAssertThrowsError(try Self.admissionRequest(expectedCentralAudience: "bad\naudience"))
        XCTAssertThrowsError(try Self.admissionRequest(expectedCentralAudience: ""))

        // The declared body is the legacy body plus exactly one key; nothing
        // else in the signed bytes moves.
        // `admissionRequest` generates fresh claim keys, so pin one request.
        let sameDeclared = try SyncNodeEnrollmentAdmissionRequest(evidence: legacy.evidence, claimProofSignature: legacy.claimProofSignature, matchingConfirmationSignature: legacy.matchingConfirmationSignature, admissionApprovalSignature: legacy.admissionApprovalSignature, idempotencyKey: legacy.idempotencyKey, trustCommit: legacy.trustCommit, expectedCentralAudience: "plainpost-central-private-beta")
        let legacyBody = try AccountAPIClient.syncNodeAdmissionBody(legacy)
        let declaredText = String(decoding: try AccountAPIClient.syncNodeAdmissionBody(sameDeclared), as: UTF8.self)
        let declaredKey = #""expectedCentralAudience":"plainpost-central-private-beta","#
        XCTAssertTrue(declaredText.contains(declaredKey))
        XCTAssertEqual(Data(declaredText.replacingOccurrences(of: declaredKey, with: "").utf8), legacyBody)
    }

    func testAdmissionTransportClassifiesMalformedSuccessAsUndecodableSuccess() async throws {
        let request = try Self.admissionRequest(expectedCentralAudience: "plainpost-central-private-beta")
        let identity = try AccountDeviceIdentity.generate()
        let credentials = try AccountSessionCredentials(accountID: request.evidence.accountID, deviceID: request.evidence.approverDeviceID, accessToken: "access-token", accessExpiresAt: Date().addingTimeInterval(300), refreshCredential: Data(repeating: 7, count: 32), offlineLease: "offline-lease")
        let responses: [(String, AccountHTTPResponse)] = [
            ("200 with an empty body", AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: Data())),
            ("200 with text/plain", AccountHTTPResponse(statusCode: 200, headers: ["content-type": "text/plain"], body: Data("ok".utf8))),
            ("200 without a content type", AccountHTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))),
        ]
        for (name, response) in responses {
            let secretStore = InMemoryAccountSecretStore()
            let credentialStore = AccountCredentialStore(secretStore: secretStore, service: "com.marynavdovenko.Plainpost.AccountTests.SyncNodeAdmissionWire")
            let client = try AccountAPIClient(transport: FixedAdmissionTransport(response: response), credentialStore: credentialStore, manifestStore: BootstrapKeyManifestStore(secretStore: secretStore))
            do {
                _ = try await client.commitSyncNodeAdmission(request, credentials: credentials, device: identity)
                XCTFail("\(name) was accepted")
            } catch {
                XCTAssertEqual(error as? SyncNodeEnrollmentCommitError, .undecodableSuccess, name)
            }
        }
    }

    func testAdmissionResponseClassificationSeparatesPreCommitRejectionFromUncertainty() throws {
        XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.httpFailure(statusCode: 422))) {
            XCTAssertEqual($0 as? SyncNodeEnrollmentCommitError, .audienceMismatch)
        }
        XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.httpFailure(statusCode: 503))) {
            XCTAssertEqual($0 as? AccountRuntimeError, .transportFailure)
        }
        XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.httpFailure(statusCode: 409))) {
            XCTAssertEqual($0 as? AccountRuntimeError, .untrustedResponse)
        }
        XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.success(Data("{}".utf8)))) {
            XCTAssertEqual($0 as? SyncNodeEnrollmentCommitError, .undecodableSuccess)
        }
        XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.success(Data("not json".utf8)))) {
            XCTAssertEqual($0 as? SyncNodeEnrollmentCommitError, .undecodableSuccess)
        }
        // Definite rejections before any 2xx.
        for status in [300, 304, 399, 400, 401, 403, 409, 421, 423, 499, 600] {
            XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.httpFailure(statusCode: status)), "\(status)") {
                XCTAssertEqual($0 as? AccountRuntimeError, .untrustedResponse, "\(status)")
            }
        }
        // Every 5xx may follow a commit.
        for status in [500, 502, 599] {
            XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.httpFailure(statusCode: status)), "\(status)") {
                XCTAssertEqual($0 as? AccountRuntimeError, .transportFailure, "\(status)")
            }
        }
        // `sendAccountRequestResult` expects exactly 200, so any other 2xx
        // arrives as `.httpFailure`. Central may have committed it: keep the claim.
        for status in [201, 202, 204, 299] {
            XCTAssertThrowsError(try AccountAPIClient.classifySyncNodeAdmission(.httpFailure(statusCode: status)), "\(status)") {
                XCTAssertEqual($0 as? SyncNodeEnrollmentCommitError, .undecodableSuccess)
            }
        }
        let response = try AccountAPIClient.classifySyncNodeAdmission(.success(Self.v2ResponseWire()))
        XCTAssertNotNil(response.v2)
    }

    func testNodeEnrollmentLeaseWindowRequiresThirtyDaysOfOfflineLeaseKey() throws {
        let session = try Self.fixtureJSON("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json")
        let issued = try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-05T12:00:01Z"))
        let manifest = try SessionKeyManifestVerifier(
            document: JSONSerialization.data(withJSONObject: try XCTUnwrap(session["manifest"])),
            offlineRootKeyID: "session-root-test-1",
            offlineRootPublicKey: try AccountWireCodec.decodeBase64URL(try XCTUnwrap(session["offlineRootPublicKey"] as? String), exactBytes: 65),
            now: issued
        )
        // The fixture offline_lease key expires 2027-08-01T00:00:00Z.
        XCTAssertTrue(manifest.canVerifyNodeEnrollmentLease(at: issued))
        XCTAssertTrue(manifest.canVerifyNodeEnrollmentLease(at: try XCTUnwrap(AccountWireCodec.parseTimestamp("2027-07-02T00:00:00Z"))))
        XCTAssertFalse(manifest.canVerifyNodeEnrollmentLease(at: try XCTUnwrap(AccountWireCodec.parseTimestamp("2027-07-02T00:00:01Z"))))
        XCTAssertFalse(manifest.canVerifyNodeEnrollmentLease(at: try XCTUnwrap(AccountWireCodec.parseTimestamp("2027-08-01T00:00:00Z"))))
        XCTAssertFalse(manifest.canVerifyNodeEnrollmentLease(at: try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-07-31T23:59:59Z"))))
    }

    static func admissionRequest(expectedCentralAudience: String?) throws -> SyncNodeEnrollmentAdmissionRequest {
        let root = try fixtureJSON("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let genesis = try XCTUnwrap(((root["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any])
        let trustCommit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(genesis["genesisCommit"])))
        let claim = try AccountNodeEnrollmentPublicClaimV1(claimID: NodeEnrollmentClaimID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), nodeDeviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), signingPublicKey: P256.Signing.PrivateKey().publicKey.x963Representation, agreementPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, noiseStaticPublicKey: Data(repeating: 7, count: 32), endpointDigest: Data(repeating: 8, count: 32), createdAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z")
        let stepUp = try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("cccccccc-cccc-4ccc-8ccc-cccccccccccc"), accountID: trustCommit.state.accountID, actorDeviceID: trustCommit.state.members[0].deviceID, targetDeviceID: claim.nodeDeviceID, action: .enrollSyncNode, currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit), requestDigest: Data(repeating: 1, count: 32), issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z", serverKeyID: "access-test-1", serverSignature: Data(repeating: 2, count: 64))
        let evidence = try AccountNodeEnrollmentAdmissionEvidenceV1(accountID: trustCommit.state.accountID, trustEpoch: trustCommit.state.epoch, approverDeviceID: trustCommit.state.members[0].deviceID, claimID: claim.claimID, nodeDeviceID: claim.nodeDeviceID, action: .enroll, replacedNodeID: nil, signingPublicKey: claim.signingPublicKey, agreementPublicKey: claim.agreementPublicKey, noiseStaticPublicKey: claim.noiseStaticPublicKey, endpointDigest: claim.endpointDigest, matchingTranscriptDigest: Data(repeating: 3, count: 32), stepUp: stepUp)
        return try SyncNodeEnrollmentAdmissionRequest(evidence: evidence, claimProofSignature: Data(repeating: 4, count: 64), matchingConfirmationSignature: Data(repeating: 5, count: 64), admissionApprovalSignature: Data(repeating: 6, count: 64), idempotencyKey: Data(repeating: 7, count: 32), trustCommit: trustCommit, expectedCentralAudience: expectedCentralAudience)
    }

    static func v2ResponseWire() throws -> Data {
        let root = try fixtureJSON("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let vector = try XCTUnwrap(root["syncNodeEnrollmentV2"] as? [String: Any])
        func object(_ key: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(vector[key] as? String).utf8)) }
        return try JSONSerialization.data(withJSONObject: [
            "kind": "account.sync-node-admission-response.v2",
            "result": try object("resultCanonicalJSON"),
            "refreshCredential": try object("refreshCanonicalJSON"),
            "offlineLease": try object("leaseCanonicalJSON"),
            "cleanupCapability": try object("capabilityCanonicalJSON"),
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func fixtureJSON(_ path: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as? [String: Any])
    }
}

private struct FixedAdmissionTransport: AccountHTTPTransport {
    let response: AccountHTTPResponse
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse { response }
}
