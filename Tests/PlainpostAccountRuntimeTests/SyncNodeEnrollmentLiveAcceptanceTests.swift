import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class SyncNodeEnrollmentLiveAcceptanceTests: XCTestCase {
    func testResponseVerificationDiagnosticsUseTheWireVersionForLeaseSignatures() throws {
        let fixture = try liveFixtureJSON("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let vector = try XCTUnwrap(fixture["syncNodeEnrollmentV2"] as? [String: Any])
        var leaseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(vector["leaseCanonicalJSON"] as? String).utf8)) as? [String: Any])
        leaseObject["serverKeyID"] = "offline-test-1"
        var placeholderSignature = Data(repeating: 0, count: 64)
        placeholderSignature[31] = 1
        placeholderSignature[63] = 1
        leaseObject["signature"] = AccountWireCodec.encodeBase64URL(placeholderSignature)
        let unsignedLease = try AccountWireCodec.decodeNodeOfflineLeaseV2(JSONSerialization.data(withJSONObject: leaseObject, options: [.sortedKeys, .withoutEscapingSlashes]))
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3]))
        var leaseSignature = Data()
        for _ in 0 ..< 32 {
            let candidate = try signingKey.signature(for: AccountTranscript.nodeOfflineLeaseV2(unsignedLease)).rawRepresentation
            if (try? AccountWireCodec.validateLowSSignature(candidate)) != nil {
                leaseSignature = candidate
                break
            }
        }
        guard leaseSignature.count == 64 else { throw AccountRuntimeError.untrustedResponse }
        leaseObject["signature"] = AccountWireCodec.encodeBase64URL(leaseSignature)
        let responseObject: [String: Any] = [
            "kind": "account.sync-node-admission-response.v2",
            "result": try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(vector["resultCanonicalJSON"] as? String).utf8)),
            "refreshCredential": try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(vector["refreshCanonicalJSON"] as? String).utf8)),
            "offlineLease": leaseObject,
            "cleanupCapability": try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(vector["capabilityCanonicalJSON"] as? String).utf8))
        ]
        let response = try SyncNodeEnrollmentAdmissionResponse(v2: AccountWireCodec.decodeNodeEnrollmentAdmissionResponseV2(JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys, .withoutEscapingSlashes])))
        let session = try liveFixtureJSON("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json")
        let manifest = try SessionKeyManifestVerifier(
            document: JSONSerialization.data(withJSONObject: try XCTUnwrap(session["manifest"])),
            offlineRootKeyID: try XCTUnwrap(session["offlineRootKeyID"] as? String),
            offlineRootPublicKey: try AccountWireCodec.decodeBase64URL(try XCTUnwrap(session["offlineRootPublicKey"] as? String), exactBytes: 65),
            now: try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-14T12:06:01Z"))
        )

        XCTAssertFalse(responseLeaseVerificationFailure(response: response, manifest: manifest, now: try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-14T12:06:01Z"))))
    }

    func testPrivacyKDFMatchesGoLiveFixtureContract() {
        XCTAssertEqual(LiveClaimFixture.initial.claimID, "e492541f-64b0-4a6e-a9ac-8230eadade64")
        XCTAssertEqual(LiveClaimFixture.initial.setupCode, "LyxSGhjzMOTPaJjm2dnh01-tn63YzVDMz5jis8jpe34")
        XCTAssertEqual(privacyKDF("claim-1-matching-material", marker: PrivacyMarker.matchingMaterial, count: 32).map { String(format: "%02x", $0) }.joined(), "6f1c1baf6ae1ad300c5157ac66d89ee11a04497039d52956099d6bb569fb27c6")
        XCTAssertEqual(Data(SHA256.hash(data: LiveClaimFixture.initial.endpointPlaintext)).map { String(format: "%02x", $0) }.joined(), "a333555abf9f9db49e36ab336665a70bc8b855ec0a395508ae6dbf868599a4ff")
    }

    func testLiveHTTPRecorderRetainsEveryBoundedErrorBody() async throws {
        let recorder = LiveHTTPRecorder()
        let conflict = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://acceptance.invalid/conflict")!, statusCode: 409, httpVersion: nil, headerFields: ["Content-Type": "application/problem+json"]))
        let unauthorized = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://acceptance.invalid/fenced")!, statusCode: 401, httpVersion: nil, headerFields: nil))
        let success = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://acceptance.invalid/success")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        let oversized = Data(repeating: 0x61, count: LiveHTTPRecorder.maximumErrorBodyBytes + 17)
        let fenced = Data("private-fenced-body".utf8)

        await recorder.record(path: "/same", response: conflict, body: oversized)
        await recorder.record(path: "/same", response: unauthorized, body: fenced)
        await recorder.record(path: "/success", response: success, body: Data("ignored".utf8))

        let bodies = await recorder.errorResponseBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0].count, LiveHTTPRecorder.maximumErrorBodyBytes)
        XCTAssertEqual(bodies[1], fenced)

        for index in 0 ..< LiveHTTPRecorder.maximumErrorResponseCount {
            await recorder.record(path: "/bounded/\(index)", response: unauthorized, body: Data([UInt8(index)]))
        }
        let boundedBodies = await recorder.errorResponseBodies()
        XCTAssertEqual(boundedBodies.count, LiveHTTPRecorder.maximumErrorResponseCount)
        XCTAssertEqual(boundedBodies[0].count, LiveHTTPRecorder.maximumErrorBodyBytes)
        XCTAssertEqual(boundedBodies[1], fenced)
    }

    func testReturnedCredentialPrivacyRepresentationsIncludeAccountWireBase64URL() {
        let credential = Data([0xfb, 0xff, 0xef, 0x00, 0x01])
        let canonical = AccountWireCodec.encodeBase64URL(credential)
        let representations = returnedPrivacyRepresentations(credential)

        XCTAssertTrue(representations.contains(canonical))
        XCTAssertFalse(canonical.contains("="))
        XCTAssertTrue(canonical.contains("-") || canonical.contains("_"))
    }

    func testReturnedDatabasePrivacyPatternDocumentIsTyped() throws {
        let credential = Data((0..<32).map { UInt8($0) })
        let document = String(decoding: try returnedDatabasePrivacyPatternDocument(refreshValues: [credential], credentialIDs: ["11111111-1111-4111-8111-111111111111"], leaseIDs: ["22222222-2222-4222-8222-222222222222"]), as: UTF8.self)
        XCTAssertTrue(document.contains("refresh-credential-base64url\t\(AccountWireCodec.encodeBase64URL(credential))\n"))
        XCTAssertEqual(document.components(separatedBy: "refresh-credential-base64url\t").count - 1, 1)
        XCTAssertTrue(document.contains("credential-id\t11111111-1111-4111-8111-111111111111\n"))
        XCTAssertTrue(document.contains("lease-id\t22222222-2222-4222-8222-222222222222\n"))

        let duplicateDocument = String(decoding: try returnedDatabasePrivacyPatternDocument(
            refreshValues: [credential, credential],
            credentialIDs: ["11111111-1111-4111-8111-111111111111", "33333333-3333-4333-8333-333333333333"],
            leaseIDs: ["22222222-2222-4222-8222-222222222222", "44444444-4444-4444-8444-444444444444"]
        ), as: UTF8.self)
        XCTAssertEqual(duplicateDocument.components(separatedBy: "refresh-credential-base64url\t").count - 1, 2)
    }

    func testLiveTransportAcceptsOnlyClosedHarnessEndpoints() throws {
        let recorder = LiveHTTPRecorder()
        XCTAssertNoThrow(try LiveLoopbackTransport(recorder: recorder, environment: ["PLAINPOST_SYNC_NODE_ACCEPTANCE": "enabled", "PLAINPOST_SYNC_NODE_ACCEPTANCE_BASE_URL": "http://127.0.0.1:18080"]))
        XCTAssertNoThrow(try LiveLoopbackTransport(recorder: recorder, environment: ["PLAINPOST_SYNC_NODE_ACCEPTANCE": "enabled", "PLAINPOST_SYNC_NODE_ACCEPTANCE_BASE_URL": "http://192.168.215.2:8080"]))
        for endpoint in ["http://127.0.0.1:8080", "http://8.8.8.8:8080", "https://192.168.215.2:8080", "http://192.168.001.2:8080", "http://192.168.215.2:80/path"] {
            XCTAssertThrowsError(try LiveLoopbackTransport(recorder: recorder, environment: ["PLAINPOST_SYNC_NODE_ACCEPTANCE": "enabled", "PLAINPOST_SYNC_NODE_ACCEPTANCE_BASE_URL": endpoint]))
        }
    }

    func testSwiftApprovalClientExercisesLiveCentralEnrollmentReplayAndReplacement() async throws {
        guard ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_ACCEPTANCE"] == "enabled" else {
            throw XCTSkip("set PLAINPOST_SYNC_NODE_ACCEPTANCE=enabled only from the disposable Compose acceptance script")
        }
        let secrets = InMemoryAccountSecretStore()
        let credentialsStore = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.SyncNodeLiveAcceptance")
        let recorder = LiveHTTPRecorder()
        let transport = try LiveLoopbackTransport(recorder: recorder)
        let client = try AccountAPIClient(
            transport: transport,
            credentialStore: credentialsStore,
            manifestStore: try bootstrapManifestStore(),
            baseURL: URL(string: "https://acceptance.invalid")!
        )
        let owner = try AccountDeviceIdentity.generate()
        let bootstrapNonce = privacyKDF("bootstrap-apple-nonce", marker: PrivacyMarker.verifierInput, count: 32)
        let activation: AccountActivation
        do {
            activation = try await client.bootstrapAppleCredential(
                identityToken: try acceptanceToken(subject: "sync-node-live", audience: "acceptance.plainpost.macos", nonce: bootstrapNonce),
                nonce: bootstrapNonce,
                device: owner
            )
        } catch {
            let beginStatus = await recorder.last(path: "/v1/account/bootstrap/apple/begin")?.status ?? -1
            let finalizeStatus = await recorder.last(path: "/v1/account/bootstrap/apple/finalize")?.status ?? -1
            XCTFail("Apple bootstrap failed after begin/finalize statuses \(beginStatus)/\(finalizeStatus)")
            throw error
        }
        let initialHead = try XCTUnwrap(activation.currentTrustCommit)
        let session = try XCTUnwrap(credentialsStore.loadSession()?.credentials)
        let trust = try AccountTrustCoordinator(
            accountID: activation.accountID,
            deviceID: activation.deviceID,
            platform: .macos,
            deviceIdentity: owner,
            trustStore: AccountTrustStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.SyncNodeLiveAcceptance.trust"),
            offlineRootKeyID: "plainpost-root-2026-01",
            offlineRootPublicKey: try AccountWireCodec.decodeBase64URL("BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU", exactBytes: 65)
        )
        try await trust.accept(initialHead)

        let first: (request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, nodeIdentity: AccountDeviceIdentity)
        do {
            first = try await enrollmentRequest(client: client, trust: trust, session: session, owner: owner, fixture: .initial, action: .enroll, replacedNodeID: nil, idempotencyByte: 0x21)
        } catch {
            let lookupStatus = await recorder.last(path: "/v1/sync-nodes/claims/lookup")?.status ?? -1
            XCTFail("initial enrollment preparation failed after claim lookup status \(lookupStatus)")
            throw error
        }
        // Central must reject a declared audience other than its own before
        // any replay lookup or transaction, and leave the claim usable.
        let mismatched = try SyncNodeEnrollmentAdmissionRequest(evidence: first.request.evidence, claimProofSignature: first.request.claimProofSignature, matchingConfirmationSignature: first.request.matchingConfirmationSignature, admissionApprovalSignature: first.request.admissionApprovalSignature, idempotencyKey: first.request.idempotencyKey, trustCommit: first.request.trustCommit, expectedCentralAudience: "plainpost-api.olhapi.com")
        do {
            _ = try await client.commitSyncNodeAdmission(mismatched, credentials: session, device: owner)
            XCTFail("Central committed an admission declared for another audience")
        } catch {
            XCTAssertEqual(error as? SyncNodeEnrollmentCommitError, .audienceMismatch)
        }
        let mismatchStatus = await recorder.last(path: "/v1/sync-nodes/enrollment/approve")?.status
        XCTAssertEqual(mismatchStatus, 422, "a declared audience mismatch must be a definite pre-commit 422")
        let declared = try SyncNodeEnrollmentAdmissionRequest(evidence: first.request.evidence, claimProofSignature: first.request.claimProofSignature, matchingConfirmationSignature: first.request.matchingConfirmationSignature, admissionApprovalSignature: first.request.admissionApprovalSignature, idempotencyKey: first.request.idempotencyKey, trustCommit: first.request.trustCommit, expectedCentralAudience: "acceptance.plainpost.central")
        let firstResponse = try await client.commitSyncNodeAdmission(declared, credentials: session, device: owner)
        let firstManifest = try sessionManifest()
        let firstVerificationTime = Date().addingTimeInterval(5)
        let firstVerificationFailures = try responseVerificationFailures(response: firstResponse, request: first.request, manifest: firstManifest, now: firstVerificationTime)
        XCTAssertTrue(firstVerificationFailures.isEmpty, "initial response verification checks failed: \(firstVerificationFailures.joined(separator: ","))")
        try ManifestBackedSyncNodeEnrollmentResponseVerifier(manifest: firstManifest).verify(response: firstResponse, request: first.request, centralAudience: "acceptance.plainpost.central", now: firstVerificationTime)
        try await trust.acceptSyncNodeEnrollmentCommit(first.request.trustCommit, evidence: first.request.evidence)
        let firstReplay = try await client.commitSyncNodeAdmission(first.request, credentials: session, device: owner)
        XCTAssertEqual(firstReplay.result, firstResponse.result, "a lost response must replay the exact persisted enrollment result")
        XCTAssertEqual(firstReplay.refreshCredential, firstResponse.refreshCredential)
        XCTAssertEqual(firstReplay.offlineLease, firstResponse.offlineLease)
        let replacement: (request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, nodeIdentity: AccountDeviceIdentity)
        do {
            replacement = try await enrollmentRequest(client: client, trust: trust, session: session, owner: owner, fixture: .replacement, action: .replace, replacedNodeID: first.claim.nodeDeviceID, idempotencyByte: 0x23)
        } catch {
            let lookupStatus = await recorder.last(path: "/v1/sync-nodes/claims/lookup")?.status ?? -1
            let stepUpStatus = await recorder.last(path: "/v1/sync-nodes/step-up")?.status ?? -1
            XCTFail("replacement preparation failed after lookup/step-up statuses \(lookupStatus)/\(stepUpStatus)")
            throw error
        }
        let malformed = try SyncNodeEnrollmentAdmissionRequest(evidence: replacement.request.evidence, claimProofSignature: Data(repeating: 0, count: 64), matchingConfirmationSignature: replacement.request.matchingConfirmationSignature, admissionApprovalSignature: replacement.request.admissionApprovalSignature, idempotencyKey: replacement.request.idempotencyKey, trustCommit: replacement.request.trustCommit)
        await XCTAssertThrowsErrorAsync { _ = try await client.commitSyncNodeAdmission(malformed, credentials: session, device: owner) }
        let oldCredentials = try nodeCredentials(response: firstResponse)
        let oldSession: AccountSessionCredentials
        do {
            oldSession = try await client.refreshSession(oldCredentials, device: first.nodeIdentity)
            _ = try await client.sendAccountRequest(method: "GET", path: "/v1/account-records", queryItems: [URLQueryItem(name: "limit", value: "1")], credentials: oldSession, device: first.nodeIdentity)
        } catch {
            let refreshStatus = await recorder.last(path: "/v1/sessions/refresh")?.status ?? -1
            let bearerStatus = await recorder.last(path: "/v1/account-records")?.status ?? -1
            XCTFail("old-node access before replacement failed after refresh/bearer statuses \(refreshStatus)/\(bearerStatus)")
            throw error
        }

        let replacementResponse: SyncNodeEnrollmentAdmissionResponse
        do {
            replacementResponse = try await client.commitSyncNodeAdmission(replacement.request, credentials: session, device: owner)
        } catch {
            let replacementStatus = await recorder.last(path: "/v1/sync-nodes/replacement")?.status ?? -1
            XCTFail("replacement commit failed after status \(replacementStatus)")
            throw error
        }
        try ManifestBackedSyncNodeEnrollmentResponseVerifier(manifest: try sessionManifest()).verify(response: replacementResponse, request: replacement.request, centralAudience: "acceptance.plainpost.central", now: Date().addingTimeInterval(5))
        try await trust.acceptSyncNodeEnrollmentCommit(replacement.request.trustCommit, evidence: replacement.request.evidence)
        await XCTAssertThrowsErrorAsync { _ = try await client.refreshSession(oldCredentials, device: first.nodeIdentity) }
        await XCTAssertThrowsErrorAsync { _ = try await client.sendAccountRequest(method: "GET", path: "/v1/account-records", queryItems: [URLQueryItem(name: "limit", value: "1")], credentials: oldSession, device: first.nodeIdentity) }
        let fencedBearerStatus = await recorder.last(path: "/v1/account-records")?.status
        XCTAssertEqual(fencedBearerStatus, 401, "replacement must immediately fence the old bearer at an authenticated route")
        let replacementCredentials = try nodeCredentials(response: replacementResponse)
        do {
            _ = try await client.refreshSession(replacementCredentials, device: replacement.nodeIdentity)
        } catch {
            let refreshStatus = await recorder.last(path: "/v1/sessions/refresh")?.status ?? -1
            XCTFail("replacement-node refresh failed after status \(refreshStatus)")
            throw error
        }
        let replacementReplay = try await client.commitSyncNodeAdmission(replacement.request, credentials: session, device: owner)
        XCTAssertEqual(replacementReplay.result, replacementResponse.result, "a lost replacement response must replay without revoking the new node")
        XCTAssertEqual(replacementReplay.refreshCredential, replacementResponse.refreshCredential)
        XCTAssertEqual(replacementReplay.offlineLease, replacementResponse.offlineLease)

        // A new idempotency key makes this an ordinary second admission, not
        // replay. Keep the exact coordinator-built, signed successor and
        // re-sign the approval transcript so the request is cryptographically
        // self-consistent; Central's active-node fence must win before stale
        // claim/head validation and return the domain conflict.
        let secondIdempotencyKey = Data(repeating: 0x22, count: 32)
        let secondApproval = try owner.signature(for: AccountTranscript.nodeEnrollmentApproval(first.request.evidence, idempotencyKey: secondIdempotencyKey))
        let second = try SyncNodeEnrollmentAdmissionRequest(evidence: first.request.evidence, claimProofSignature: first.request.claimProofSignature, matchingConfirmationSignature: first.request.matchingConfirmationSignature, admissionApprovalSignature: secondApproval, idempotencyKey: secondIdempotencyKey, trustCommit: first.request.trustCommit)
        await XCTAssertThrowsErrorAsync { _ = try await client.commitSyncNodeAdmission(second, credentials: session, device: owner) }
        let recordedConflict = await recorder.last(path: "/v1/sync-nodes/enrollment/approve")
        let conflict = try XCTUnwrap(recordedConflict)
        XCTAssertEqual(conflict.status, 409)
        XCTAssertEqual(conflict.contentType, "application/problem+json")
        XCTAssertEqual(conflict.problemStatus, 409, "the second enrollment must be the inspected HTTP/domain conflict")

        try writeReturnedPrivacyPatterns([firstResponse, replacementResponse])
        let errorBodies = await recorder.errorResponseBodies()
        try writePrivateHTTPErrorBodies(errorBodies)
        for marker in PrivacyMarker.allCases {
            let returned = try AccountWireCodec.encodeNodeRefreshCredential(firstResponse.refreshCredential) + AccountWireCodec.encodeNodeOfflineLease(firstResponse.offlineLease) + AccountWireCodec.encodeNodeRefreshCredential(replacementResponse.refreshCredential) + AccountWireCodec.encodeNodeOfflineLease(replacementResponse.offlineLease)
            XCTAssertFalse(returned.range(of: Data(marker.rawValue.utf8)) != nil, "a raw synthetic marker reached an authorized returned document")
        }

        XCTAssertFalse(initialHead.state.members.contains(where: { $0.platform == .syncNode }), "generic Apple bootstrap must not manufacture a Sync Node")
    }

    private func enrollmentRequest(client: AccountAPIClient, trust: AccountTrustCoordinator, session: AccountSessionCredentials, owner: AccountDeviceIdentity, fixture: LiveClaimFixture, action: AccountNodeEnrollmentAction, replacedNodeID: AccountDeviceID?, idempotencyByte: UInt8) async throws -> (request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, nodeIdentity: AccountDeviceIdentity) {
        let nodeIdentity = try AccountDeviceIdentity(signingPrivateKey: fixture.signingScalar, agreementPrivateKey: fixture.agreementScalar)
        let claim = try await client.lookupSyncNodeClaim(setupCode: fixture.setupCode)
        XCTAssertEqual(claim.claimID.rawValue, fixture.claimID)
        XCTAssertEqual(claim.nodeDeviceID.rawValue, fixture.nodeDeviceID)
        XCTAssertEqual(claim.signingPublicKey, nodeIdentity.publicBundle.signingKey)
        XCTAssertEqual(claim.agreementPublicKey, nodeIdentity.publicBundle.agreementKey)
        var expectedNoiseStaticPublicKey = privacyKDF("claim-\(fixture.index)-matching-material", marker: PrivacyMarker.matchingMaterial, count: 32)
        expectedNoiseStaticPublicKey[31] &= 0x7f
        XCTAssertEqual(claim.noiseStaticPublicKey, expectedNoiseStaticPublicKey)
        XCTAssertEqual(claim.endpointDigest, Data(SHA256.hash(data: fixture.endpointPlaintext)))
        let optionalHead = try await trust.currentTrustCommit()
        let head = try XCTUnwrap(optionalHead)
        let nonce = privacyKDF("claim-\(fixture.index)-step-up-apple-nonce", marker: PrivacyMarker.verifierInput, count: 32)
        let stepUp = try await client.issueSyncNodeStepUp(
            action: action,
            claim: claim,
            replacedNodeID: replacedNodeID,
            authorization: try SyncNodeEnrollmentAppleAuthorization(identityToken: try acceptanceToken(subject: "sync-node-live", audience: "acceptance.plainpost.macos", nonce: nonce), nonce: nonce),
            credentials: session,
            device: owner,
            trustCommit: head
        )
        let matching = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentMatchingConfirmation(claim, accountID: session.accountID)))
        let evidence = try AccountNodeEnrollmentAdmissionEvidenceV1(accountID: session.accountID, trustEpoch: head.state.epoch, approverDeviceID: session.deviceID, claimID: claim.claimID, nodeDeviceID: claim.nodeDeviceID, action: action, replacedNodeID: replacedNodeID, signingPublicKey: claim.signingPublicKey, agreementPublicKey: claim.agreementPublicKey, noiseStaticPublicKey: claim.noiseStaticPublicKey, endpointDigest: claim.endpointDigest, matchingTranscriptDigest: matching, stepUp: stepUp)
        let successor = try await trust.makeSyncNodeEnrollmentCommit(evidence: evidence)
        let privateClaim = try AccountNodeEnrollmentClaimV1(claimID: claim.claimID, nodeDeviceID: claim.nodeDeviceID, signingPublicKey: claim.signingPublicKey, agreementPublicKey: claim.agreementPublicKey, noiseStaticPublicKey: claim.noiseStaticPublicKey, endpointCiphertext: fixture.endpointCiphertext, setupVerifier: fixture.setupVerifier, endpointDigest: claim.endpointDigest, createdAt: claim.createdAt, expiresAt: claim.expiresAt)
        let proof = try nodeIdentity.signature(for: AccountTranscript.nodeEnrollmentClaimProof(privateClaim))
        let matchingProof = try owner.signature(for: AccountTranscript.nodeEnrollmentMatchingConfirmation(claim, accountID: session.accountID))
        let idempotency = Data(repeating: idempotencyByte, count: 32)
        let approval = try owner.signature(for: AccountTranscript.nodeEnrollmentApproval(evidence, idempotencyKey: idempotency))
        return (try SyncNodeEnrollmentAdmissionRequest(evidence: evidence, claimProofSignature: proof, matchingConfirmationSignature: matchingProof, admissionApprovalSignature: approval, idempotencyKey: idempotency, trustCommit: successor), claim, nodeIdentity)
    }

    private func nodeCredentials(response: SyncNodeEnrollmentAdmissionResponse) throws -> AccountSessionCredentials {
        try AccountSessionCredentials(accountID: response.result.binding.accountID, deviceID: response.result.binding.nodeDeviceID, accessToken: "unused-for-refresh", accessExpiresAt: Date().addingTimeInterval(60), refreshCredential: response.refreshCredential.credential, offlineLease: response.offlineLease.leaseID)
    }

    private func responseVerificationFailures(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, manifest: SessionKeyManifestVerifier, now: Date) throws -> [String] {
        var failures: [String] = []
        let binding = response.result.binding
        if binding.accountID != request.evidence.accountID { failures.append("account") }
        if binding.trustEpoch != request.trustCommit.state.epoch { failures.append("epoch") }
        if binding.claimID != request.evidence.claimID { failures.append("claim") }
        if binding.nodeDeviceID != request.evidence.nodeDeviceID { failures.append("node") }
        if binding.action != request.evidence.action { failures.append("action") }
        if binding.replacedNodeID != request.evidence.replacedNodeID { failures.append("replacement") }
        if !binding.isForCentralAudience("acceptance.plainpost.central") { failures.append("audience") }
        if binding.admissionEvidenceDigest != Data(SHA256.hash(data: try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence))) { failures.append("evidence") }
        let committed = AccountWireCodec.parseTimestamp(response.result.committedAt)
        let refreshIssued = AccountWireCodec.parseTimestamp(response.refreshCredential.issuedAt)
        let refreshExpires = AccountWireCodec.parseTimestamp(response.refreshCredential.expiresAt)
        let leaseIssued = AccountWireCodec.parseTimestamp(response.offlineLease.issuedAt)
        let leaseExpires = AccountWireCodec.parseTimestamp(response.offlineLease.expiresAt)
        if committed == nil || committed! > now { failures.append("committed-time") }
        if refreshIssued == nil || refreshExpires == nil || refreshIssued! > now || !(now < refreshExpires!) { failures.append("refresh-time") }
        if leaseIssued == nil || leaseExpires == nil || leaseIssued! > now || !(now < leaseExpires!) { failures.append("lease-time") }
        if committed == nil || refreshIssued == nil || committed! > refreshIssued! { failures.append("ordering") }
        if refreshIssued != leaseIssued { failures.append("issued-equality") }
        if responseLeaseVerificationFailure(response: response, manifest: manifest, now: now) { failures.append("lease-signature") }
        return failures
    }

    private func bootstrapManifestStore() throws -> BootstrapKeyManifestStore {
        let fixture = try fixtureData("central-bootstrap-manifest-test-v1.json")
        return try BootstrapKeyManifestStore(bundledManifest: fixture, offlineRootKeyID: "plainpost-root-2026-01", offlineRootPublicKey: try AccountWireCodec.decodeBase64URL("BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU", exactBytes: 65), secretStore: InMemoryAccountSecretStore())
    }

    private func sessionManifest() throws -> SessionKeyManifestVerifier {
        let fixture = try JSONSerialization.jsonObject(with: fixtureData("session-crypto-vectors-v1.json")) as! [String: Any]
        let document = try JSONSerialization.data(withJSONObject: fixture["manifest"]!)
        let root = try AccountWireCodec.decodeBase64URL(fixture["offlineRootPublicKey"] as! String, exactBytes: 65)
        return try SessionKeyManifestVerifier(document: document, offlineRootKeyID: fixture["offlineRootKeyID"] as! String, offlineRootPublicKey: root)
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/\(name)"))
    }

    private func acceptanceToken(subject: String, audience: String, nonce: Data) throws -> String {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
        let payload = try JSONSerialization.data(withJSONObject: ["audience": audience, "expiresAt": expires, "nonce": AccountWireCodec.encodeBase64URL(nonce), "subject": subject], options: [.sortedKeys, .withoutEscapingSlashes])
        let encoded = AccountWireCodec.encodeBase64URL(payload)
        let signed = Data("plainpost-acceptance-v1.\(encoded)".utf8)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data("plainpost-acceptance-identity-pepper-2026".utf8))))
        return "plainpost-acceptance-v1.\(encoded).\(AccountWireCodec.encodeBase64URL(signature))"
    }

    private func writeReturnedPrivacyPatterns(_ responses: [SyncNodeEnrollmentAdmissionResponse]) throws {
        guard let path = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_RETURNED_PRIVACY_PATTERNS"], !path.isEmpty else { throw AccountRuntimeError.transportFailure }
        var patterns = Set<String>()
        func add(_ value: Data) { patterns.formUnion(returnedPrivacyRepresentations(value)) }
        for response in responses {
            add(response.refreshCredential.credential)
            patterns.insert(response.refreshCredential.credentialID)
            patterns.insert(response.offlineLease.leaseID)
        }
        let document = Data((patterns.sorted().joined(separator: "\n") + "\n").utf8)
        guard FileManager.default.createFile(atPath: path, contents: document, attributes: [.posixPermissions: 0o600]) else { throw AccountRuntimeError.transportFailure }
        guard let databasePath = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_RETURNED_DATABASE_PRIVACY_PATTERNS"], !databasePath.isEmpty else { throw AccountRuntimeError.transportFailure }
        let databaseDocument = try returnedDatabasePrivacyPatternDocument(
            refreshValues: responses.map(\.refreshCredential.credential),
            credentialIDs: responses.map(\.refreshCredential.credentialID),
            leaseIDs: responses.map(\.offlineLease.leaseID)
        )
        guard FileManager.default.createFile(atPath: databasePath, contents: databaseDocument, attributes: [.posixPermissions: 0o600]) else { throw AccountRuntimeError.transportFailure }
    }

    private func writePrivateHTTPErrorBodies(_ bodies: [Data]) throws {
        guard let path = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_PRIVATE_HTTP_SINKS"], !path.isEmpty, !bodies.isEmpty else { throw AccountRuntimeError.transportFailure }
        var document = Data()
        for body in bodies {
            var count = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &count) { document.append(contentsOf: $0) }
            document.append(body)
        }
        guard FileManager.default.createFile(atPath: path, contents: document, attributes: [.posixPermissions: 0o600]) else { throw AccountRuntimeError.transportFailure }
    }
}

private func liveFixtureJSON(_ path: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as? [String: Any])
}

private func responseLeaseVerificationFailure(response: SyncNodeEnrollmentAdmissionResponse, manifest: SessionKeyManifestVerifier, now: Date) -> Bool {
    if let v2 = response.v2 {
        return !manifest.verifiesNodeEnrollmentLeaseV2(v2.offlineLease, at: now)
    }
    return !manifest.verifiesNodeEnrollmentLease(response.offlineLease, at: now)
}

private func returnedDatabasePrivacyPatternDocument(refreshValues: [Data], credentialIDs: [String], leaseIDs: [String]) throws -> Data {
    guard !refreshValues.isEmpty, refreshValues.count == credentialIDs.count, refreshValues.count == leaseIDs.count else {
        throw AccountRuntimeError.transportFailure
    }
    var lines: [String] = []
    lines.reserveCapacity(refreshValues.count * 3)
    for index in refreshValues.indices {
        lines.append("refresh-credential-base64url\t\(AccountWireCodec.encodeBase64URL(refreshValues[index]))")
        lines.append("credential-id\t\(credentialIDs[index])")
        lines.append("lease-id\t\(leaseIDs[index])")
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private enum LiveClaimFixture {
    case initial, conflict, replacement

    var index: Int { switch self { case .initial: 1; case .conflict: 2; case .replacement: 3 } }
    var claimID: String { privacyUUID("claim-\(index)-identifier", marker: PrivacyMarker.identifier) }
    var nodeDeviceID: String { privacyUUID("claim-\(index)-node-identifier", marker: PrivacyMarker.identifier) }
    var setupSecret: Data { privacyKDF("claim-\(index)-setup-secret", marker: PrivacyMarker.setupSecret, count: 32) }
    var setupCode: String { setupSecret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    var setupVerifier: Data { Data(SHA256.hash(data: Data("Plainpost.SyncNodeSetupCodeVerifier.v1\0".utf8) + setupSecret)) }
    var signingScalar: Data { privacyScalar("claim-\(index)-signing-private") }
    var agreementScalar: Data { privacyScalar("claim-\(index)-agreement-private") }
    var endpointPlaintext: Data { privacyKDF("claim-\(index)-endpoint-plaintext", marker: PrivacyMarker.endpointPlaintext, count: 32) }
    var endpointCiphertext: Data { privacyKDF("claim-\(index)-endpoint-ciphertext", marker: Data(PrivacyMarker.endpointCiphertext.rawValue.utf8) + endpointPlaintext, count: 48) }

    private func privacyScalar(_ label: String) -> Data {
        var value = privacyKDF(label, marker: PrivacyMarker.privateKey, count: 32)
        value[0] &= 0x7f
        if value.allSatisfy({ $0 == 0 }) { value[31] = 1 }
        return value
    }
}

private enum PrivacyMarker: String, CaseIterable {
    case setupSecret = "sync-node-audit-setup-secret-6f2d"
    case verifierInput = "sync-node-audit-verifier-input-c4a8"
    case matchingMaterial = "sync-node-audit-matching-material-91be"
    case privateKey = "sync-node-audit-private-key-52d7"
    case endpointPlaintext = "sync-node-audit-endpoint-plaintext-8a0c"
    case endpointCiphertext = "sync-node-audit-endpoint-ciphertext-f13e"
    case refreshCredential = "sync-node-audit-refresh-credential-47b9"
    case offlineLease = "sync-node-audit-offline-lease-a6d1"
    case identifier = "sync-node-audit-identifier-3ce5"
}

private func privacyKDF(_ label: String, marker: PrivacyMarker, count: Int) -> Data { privacyKDF(label, marker: Data(marker.rawValue.utf8), count: count) }
private func privacyKDF(_ label: String, marker: Data, count: Int) -> Data {
    var result = Data(), counter: UInt32 = 1
    while result.count < count {
        var big = counter.bigEndian
        let suffix = withUnsafeBytes(of: &big) { Data($0) }
        result += Data(SHA256.hash(data: Data("Plainpost.SyncNodeAcceptancePrivacyKDF.v1\0".utf8) + Data(label.utf8) + Data([0]) + marker + suffix))
        counter += 1
    }
    return result.prefix(count)
}

private func privacyUUID(_ label: String, marker: PrivacyMarker) -> String {
    var value = privacyKDF(label, marker: marker, count: 16)
    value[6] = (value[6] & 0x0f) | 0x40; value[8] = (value[8] & 0x3f) | 0x80
    let hex = value.map { String(format: "%02x", $0) }.joined()
    return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
}

private func returnedPrivacyRepresentations(_ value: Data) -> Set<String> {
    [
        AccountWireCodec.encodeBase64URL(value),
        value.base64EncodedString(),
        value.map { String(format: "%02x", $0) }.joined(),
    ]
}

private actor LiveHTTPRecorder {
    static let maximumErrorBodyBytes = 64 * 1024
    static let maximumErrorResponseCount = 32
    struct Entry: Sendable { let status: Int; let contentType: String?; let problemStatus: Int? }
    private var entries: [String: Entry] = [:]
    private var errorBodies: [Data] = []
    func record(path: String, response: HTTPURLResponse, body: Data) {
        let problem = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        entries[path] = Entry(status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type")?.lowercased(), problemStatus: problem?["status"] as? Int)
        if !(200 ... 299).contains(response.statusCode), errorBodies.count < Self.maximumErrorResponseCount {
            errorBodies.append(Data(body.prefix(Self.maximumErrorBodyBytes)))
        }
    }
    func last(path: String) -> Entry? { entries[path] }
    func errorResponseBodies() -> [Data] { errorBodies }
}

private struct LiveLoopbackTransport: AccountHTTPTransport {
    private let session = URLSession(configuration: .ephemeral)
    private let recorder: LiveHTTPRecorder
    private let endpoint: URLComponents

    init(recorder: LiveHTTPRecorder, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard environment["PLAINPOST_SYNC_NODE_ACCEPTANCE"] == "enabled",
              let rawEndpoint = environment["PLAINPOST_SYNC_NODE_ACCEPTANCE_BASE_URL"],
              let endpoint = URLComponents(string: rawEndpoint),
              endpoint.scheme == "http", endpoint.user == nil, endpoint.password == nil,
              endpoint.percentEncodedPath.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
              let host = endpoint.host
        else { throw AccountRuntimeError.transportFailure }
        let allowedLoopback = host == "127.0.0.1" && endpoint.port == 18080
        let allowedPrivateContainer = acceptancePrivateIPv4(host) && endpoint.port == 8080
        guard allowedLoopback || allowedPrivateContainer else { throw AccountRuntimeError.transportFailure }
        self.recorder = recorder
        self.endpoint = endpoint
    }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        var mapped = request
        guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw AccountRuntimeError.transportFailure }
        components.scheme = endpoint.scheme; components.host = endpoint.host; components.port = endpoint.port
        mapped.url = components.url
        let (data, response) = try await session.data(for: mapped)
        guard let http = response as? HTTPURLResponse else { throw AccountRuntimeError.transportFailure }
        await recorder.record(path: mapped.url?.path ?? "", response: http, body: data)
        return AccountHTTPResponse(statusCode: http.statusCode, headers: http.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) }, body: data)
    }
}

private func acceptancePrivateIPv4(_ candidate: String) -> Bool {
    let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4 else { return false }
    var octets: [Int] = []
    for component in components {
        guard !component.isEmpty,
              component == "0" || component.first != "0",
              component.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(component), value <= 255
        else { return false }
        octets.append(value)
    }
    return octets[0] == 10 || (octets[0] == 172 && (16 ... 31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}
