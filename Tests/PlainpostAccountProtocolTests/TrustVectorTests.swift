import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol

final class TrustVectorTests: XCTestCase {
    func testSyncNodeEnrollmentVectorsMatchGoCanonicalWireAndTranscripts() throws {
        let root = try cryptoFixture()
        let vector = try XCTUnwrap(root["syncNodeEnrollment"] as? [String: Any])
        let claimWire = Data(try fixtureString(vector, "claimCanonicalJSON").utf8)
        let evidenceWire = Data(try fixtureString(vector, "evidenceCanonicalJSON").utf8)
        let claim = try AccountWireCodec.decodeNodeEnrollmentClaim(claimWire)
        let evidence = try AccountWireCodec.decodeNodeEnrollmentAdmissionEvidence(evidenceWire)
        XCTAssertEqual(try AccountWireCodec.encodeNodeEnrollmentClaim(claim), claimWire)
        XCTAssertEqual(try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(evidence), evidenceWire)
        XCTAssertEqual(AccountTranscript.nodeEnrollmentClaimProof(claim), try Data(hex: fixtureString(vector, "claimProofTranscriptHex")))
        XCTAssertEqual(AccountTranscript.nodeEnrollmentMatchingConfirmation(claim, accountID: evidence.accountID), try Data(hex: fixtureString(vector, "matchingTranscriptHex")))
        XCTAssertEqual(AccountTranscript.nodeEnrollmentAdmissionApproval(evidence, idempotencyKey: Data("request-idempotency-key".utf8)), try Data(hex: fixtureString(vector, "admissionTranscriptHex")))
        let replacementDigest = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentReplacementApproval(evidence, idempotencyKey: Data("request-idempotency-key".utf8))))
        XCTAssertEqual(replacementDigest, try Data(hex: fixtureString(vector, "replacementTranscriptSHA256")))
        XCTAssertEqual(Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentApproval(evidence, idempotencyKey: Data("request-idempotency-key".utf8)))), replacementDigest)
        let resultWire = Data(try fixtureString(vector, "resultCanonicalJSON").utf8), leaseWire = Data(try fixtureString(vector, "leaseCanonicalJSON").utf8), refreshWire = Data(try fixtureString(vector, "refreshCanonicalJSON").utf8)
        let result = try AccountWireCodec.decodeNodeEnrollmentResult(resultWire), lease = try AccountWireCodec.decodeNodeOfflineLease(leaseWire), refresh = try AccountWireCodec.decodeNodeRefreshCredential(refreshWire)
        XCTAssertEqual(result.binding.admissionEvidenceDigest, Data(SHA256.hash(data: evidenceWire)))
        let sessionDigest = AccountTranscript.nodeEnrollmentSessionDigest(refreshCredential: refresh.credential, offlineLeaseID: lease.leaseID)
        XCTAssertEqual(sessionDigest, try AccountWireCodec.decodeBase64URL(fixtureString(vector, "sessionDigest"), exactBytes: 32))
        XCTAssertEqual(sessionDigest, Data(SHA256.hash(data: try Data(hex: fixtureString(vector, "sessionDigestTranscriptHex")))))
        XCTAssertNotEqual(sessionDigest, AccountTranscript.nodeEnrollmentSessionDigest(refreshCredential: Data(repeating: 8, count: 32), offlineLeaseID: lease.leaseID))
        XCTAssertNotEqual(sessionDigest, AccountTranscript.nodeEnrollmentSessionDigest(refreshCredential: refresh.credential, offlineLeaseID: "88888888-8888-4888-8888-888888888887"))
        XCTAssertEqual(result.binding.issuanceDigest, Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentSessionIssuance(evidence, centralAudience: result.binding.centralAudience, sessionDigest: sessionDigest))))
        XCTAssertNotEqual(result.binding.issuanceDigest, Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentSessionIssuance(evidence, centralAudience: "central.backup.plainpost.test", sessionDigest: sessionDigest))))
        XCTAssertEqual(try AccountWireCodec.encodeNodeEnrollmentResult(result), resultWire)
        XCTAssertEqual(try AccountWireCodec.encodeNodeOfflineLease(lease), leaseWire)
        XCTAssertEqual(try AccountWireCodec.encodeNodeRefreshCredential(refresh), refreshWire)
        XCTAssertEqual(AccountTranscript.nodeOperationBinding(result.binding), try Data(hex: fixtureString(vector, "operationBindingTranscriptHex")))
        XCTAssertEqual(AccountTranscript.nodeEnrollmentResult(result), try Data(hex: fixtureString(vector, "resultTranscriptHex")))
        XCTAssertEqual(AccountTranscript.nodeOfflineLease(lease), try Data(hex: fixtureString(vector, "leaseTranscriptHex")))
        XCTAssertEqual(AccountTranscript.nodeRefreshCredential(refresh), try Data(hex: fixtureString(vector, "refreshTranscriptHex")))
        var evidenceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: evidenceWire) as? [String: Any]), stepUp = try XCTUnwrap(evidenceObject["stepUp"] as? [String: Any])
        stepUp["serverSignature"] = AccountWireCodec.encodeBase64URL(try Data(hex: fixtureString(vector, "nonCanonicalHighSSignatureHex"))); evidenceObject["stepUp"] = stepUp
        let highSWire = try JSONSerialization.data(withJSONObject: evidenceObject, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try AccountWireCodec.decodeNodeEnrollmentAdmissionEvidence(highSWire))
    }

    func testSecurityEventPageRejectsOpenStatusAndNoncanonicalCursor() throws {
        let event = try AccountSecurityEventV1(
            handle: Data(repeating: 0x11, count: 32),
            category: .deviceAdded,
            actorHandle: Data(repeating: 0x22, count: 32),
            targetHandle: Data(repeating: 0x33, count: 32),
            platform: .ios,
            status: "active",
            occurredAt: "2026-08-09T16:00:00Z"
        )
        let valid = try AccountWireCodec.encodeSecurityEventPage(try AccountSecurityEventPageV1(events: [event], nextCursor: nil))
        let openStatus = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"status\":\"active\"", with: "\"status\":\"opaque\"").utf8)
        XCTAssertThrowsError(try AccountWireCodec.decodeSecurityEventPage(openStatus))

        let cursor = AccountWireCodec.encodeBase64URL(Data(repeating: 0x44, count: 8))
        _ = try AccountSecurityEventPageV1(events: [event], nextCursor: cursor)
        XCTAssertThrowsError(try AccountSecurityEventPageV1(events: [event], nextCursor: "not_cursor!"))
    }

    func testLifecycleSharedVectorMatchesGoCanonicalJSONAndRecoverySignature() throws {
        let root = try cryptoFixture()
        let lifecycle = try XCTUnwrap(root["accountLifecycle"] as? [String: Any])
        let requestVector = try XCTUnwrap(lifecycle["stepUpRequest"] as? [String: Any])
        let requestWire = Data(try fixtureString(requestVector, "canonicalJSON").utf8)
        let request = try AccountWireCodec.decodeStepUpRequest(requestWire)
        XCTAssertEqual(try AccountWireCodec.encodeStepUpRequest(request), requestWire)
        let requestTranscript = AccountTranscript.stepUpRequest(request)
        XCTAssertEqual(requestTranscript, try Data(hex: fixtureString(requestVector, "transcriptHex")))
        XCTAssertEqual(Data(SHA256.hash(data: requestTranscript)), try AccountWireCodec.decodeBase64URL(fixtureString(requestVector, "requestDigest"), exactBytes: 32))

        let authorizationVector = try XCTUnwrap(lifecycle["stepUpAuthorization"] as? [String: Any])
        let authorizationWire = Data(try fixtureString(authorizationVector, "canonicalJSON").utf8)
        let authorization = try AccountWireCodec.decodeStepUpAuthorization(authorizationWire)
        XCTAssertEqual(try AccountWireCodec.encodeStepUpAuthorization(authorization), authorizationWire)
        XCTAssertEqual(authorization.requestDigest, Data(SHA256.hash(data: requestTranscript)))
        let authorizationTranscript = AccountTranscript.stepUpAuthorization(authorization)
        XCTAssertEqual(authorizationTranscript, try Data(hex: fixtureString(authorizationVector, "transcriptHex")))
        let publicKey = try P256.Signing.PublicKey(x963Representation: rolePublicKey(fixtureString(authorizationVector, "signingRole"), in: root))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: authorization.serverSignature)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: authorizationTranscript))
        XCTAssertThrowsError(try AccountStepUpAuthorizationV1(
            authorizationID: authorization.authorizationID,
            accountID: authorization.accountID,
            actorDeviceID: authorization.actorDeviceID,
            targetDeviceID: nil,
            action: .recoverAccount,
            currentCommitDigest: authorization.currentCommitDigest,
            requestDigest: authorization.requestDigest,
            issuedAt: authorization.issuedAt,
            expiresAt: authorization.expiresAt,
            serverKeyID: authorization.serverKeyID,
            serverSignature: authorization.serverSignature
        ))
    }

    func testOpaqueSecurityDeviceHandleMatchesCentralVector() throws {
        let accountID = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let deviceID = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(
            AccountWireCodec.encodeBase64URL(AccountTranscript.securityDeviceHandle(accountID: accountID, deviceID: deviceID)),
            "8HxU2-NJc2OtBfeDElecSliMSmIr8xr24fmtQ1YIcDU"
        )
    }
    func testAccountRequestProofSharedVectorBindsEveryRequestAndPrincipalField() throws {
        let root = try cryptoFixture(), vector = try XCTUnwrap(root["accountRequestProof"] as? [String: Any])
        let accountID = try PlainpostAccountID(fixtureString(vector, "accountID")), deviceID = try AccountDeviceID(fixtureString(vector, "deviceID"))
        let method = try fixtureString(vector, "method"), target = try fixtureString(vector, "target")
        let bodyDigest = Data(SHA256.hash(data: Data(try fixtureString(vector, "bodyUTF8").utf8)))
        let tokenDigest = Data(SHA256.hash(data: Data(try fixtureString(vector, "accessTokenUTF8").utf8)))
        let nonce = try AccountWireCodec.decodeBase64URL(fixtureString(vector, "nonce"), exactBytes: 32)
        let timestamp = UInt64(try XCTUnwrap(AccountWireCodec.parseTimestamp(fixtureString(vector, "timestamp"))).timeIntervalSince1970)
        let transcript = AccountTranscript.accountRequestProof(accountID: accountID, deviceID: deviceID, method: method, target: target, bodyDigest: bodyDigest, accessTokenDigest: tokenDigest, timestamp: timestamp, nonce: nonce)
        XCTAssertEqual(transcript, try Data(hex: fixtureString(vector, "transcriptHex")))
        XCTAssertEqual(bodyDigest, try AccountWireCodec.decodeBase64URL(fixtureString(vector, "bodyDigest"), exactBytes: 32))
        XCTAssertEqual(tokenDigest, try AccountWireCodec.decodeBase64URL(fixtureString(vector, "accessTokenDigest"), exactBytes: 32))
        let publicKey = try P256.Signing.PublicKey(x963Representation: rolePublicKey(fixtureString(vector, "signingRole"), in: root))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: AccountWireCodec.decodeBase64URL(fixtureString(vector, "signature"), exactBytes: 64))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: transcript))
        let mutations = try XCTUnwrap(vector["mutationCases"] as? [[String: Any]])
        XCTAssertEqual(mutations.count, 8)
        for mutation in mutations where mutation["field"] as? String != "replay" {
            var changedAccount = accountID, changedDevice = deviceID, changedMethod = method, changedTarget = target, changedBody = bodyDigest, changedToken = tokenDigest, changedNonce = nonce
            let field = try fixtureString(mutation, "field"), replacement = try fixtureString(mutation, "replacement")
            switch field {
            case "accountID": changedAccount = try PlainpostAccountID(replacement)
            case "deviceID": changedDevice = try AccountDeviceID(replacement)
            case "method": changedMethod = replacement
            case "target": changedTarget = replacement
            case "bodyDigest": changedBody = try AccountWireCodec.decodeBase64URL(replacement, exactBytes: 32)
            case "accessTokenDigest": changedToken = try AccountWireCodec.decodeBase64URL(replacement, exactBytes: 32)
            case "nonce": changedNonce = try AccountWireCodec.decodeBase64URL(replacement, exactBytes: 32)
            default: return XCTFail("unknown mutation \(field)")
            }
            XCTAssertFalse(publicKey.isValidSignature(signature, for: AccountTranscript.accountRequestProof(accountID: changedAccount, deviceID: changedDevice, method: changedMethod, target: changedTarget, bodyDigest: changedBody, accessTokenDigest: changedToken, timestamp: timestamp, nonce: changedNonce)), field)
        }
    }
    func testTrustAndRecordPagesUseClosedCanonicalSwiftCodecs() throws {
        let root = try cryptoFixture()
        let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        let pageObject = try XCTUnwrap(pagination["page"])
        let pageWire = try JSONSerialization.data(withJSONObject: pageObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let page = try AccountWireCodec.decodeTrustStatePage(pageWire)
        XCTAssertEqual(try AccountWireCodec.encodeTrustStatePage(page), pageWire)
        XCTAssertEqual(page.entries.count, 3)

        var unknown = try XCTUnwrap(pageObject as? [String: Any])
        unknown["unknown"] = true
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustStatePage(JSONSerialization.data(withJSONObject: unknown)))

        var record = try XCTUnwrap(root["encryptedAccountRecord"] as? [String: Any])
        for key in ["aadHex", "envelopeDigest", "plaintextHex", "signatureTranscriptHex", "signerRole"] { record.removeValue(forKey: key) }
        record["kind"] = "account.encrypted-record.v1"
        let recordPage: [String: Any] = [
            "kind": "account.encrypted-record-page.v1",
            "records": [record],
            "nextCursor": AccountWireCodec.encodeBase64URL(Data(repeating: 0xA5, count: 8)),
            "terminal": false,
        ]
        let decoded = try AccountWireCodec.decodeEncryptedAccountRecordPage(JSONSerialization.data(withJSONObject: recordPage, options: [.sortedKeys, .withoutEscapingSlashes]))
        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.nextCursor, Data(repeating: 0xA5, count: 8))
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecordPage(Data("{\"kind\":\"account.encrypted-record-page.v1\",\"records\":[],\"nextCursor\":null,\"terminal\":true,\"terminal\":false}".utf8)))
    }

    func testTrustCursorAcceptsCanonicalGoRFC3339NanoTimestamps() throws {
        let checkpoint = try AccountTrustPageCheckpointV1(
            epoch: AccountTrustEpoch(rawValue: try PositiveUInt64(6)),
            revision: try PositiveUInt64(1),
            commitDigest: Data(repeating: 0x51, count: 32)
        )

        XCTAssertNoThrow(
            try AccountTrustCursorV1(
                accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"),
                after: .checkpoint(checkpoint),
                snapshotHead: checkpoint,
                issuedAt: "2026-09-12T17:03:05.321456789Z",
                expiresAt: "2026-09-12T17:08:05.321456789Z",
                serverKeyID: "pagination-2026-09",
                signature: Data(repeating: 0x01, count: 64)
            )
        )
    }

    func testTrustCommitDigestHasOneCanonicalProtocolPrimitive() throws {
        let root = try cryptoFixture()
        let vector = try XCTUnwrap(root["genesisTrustCommit"] as? [String: Any])
        let commit = try AccountWireCodec.decodeTrustCommit(
            JSONSerialization.data(withJSONObject: try XCTUnwrap(vector["commit"]), options: [.sortedKeys, .withoutEscapingSlashes])
        )
        let independent = Data(SHA256.hash(data: AccountTranscript.trustCommit(
            commit,
            encryptedDigests: commit.keyPackages.map { Data(SHA256.hash(data: $0.nonce + $0.encryptedKeyMaterial)) }
        )))
        XCTAssertEqual(AccountTranscript.trustCommitDigest(commit), independent)
    }

    func testRecoveryAuthorizationDigestBindsTheExactServerSignature() throws {
        let root = try cryptoFixture()
        let message = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(
            JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        )
        let substituted = try AccountRecoveryAuthorization(
            authorizationID: authorization.authorizationID,
            accountID: authorization.accountID,
            epoch: authorization.epoch,
            deviceID: authorization.deviceID,
            platform: authorization.platform,
            publicBundle: authorization.publicBundle,
            priorCommitDigest: authorization.priorCommitDigest,
            exchangeRequestDigest: authorization.exchangeRequestDigest,
            issuedAt: authorization.issuedAt,
            expiresAt: authorization.expiresAt,
            serverKeyID: authorization.serverKeyID,
            serverSignature: Data(repeating: 2, count: 64)
        )

        XCTAssertEqual(
            AccountTranscript.recoveryAuthorization(authorization),
            AccountTranscript.recoveryAuthorization(substituted)
        )
        XCTAssertNotEqual(
            AccountTranscript.recoveryAuthorizationDigest(authorization),
            AccountTranscript.recoveryAuthorizationDigest(substituted)
        )

        let forkVector = try XCTUnwrap(root["predecessorCommitForkVector"] as? [String: Any])
        let successor = try XCTUnwrap((try XCTUnwrap(forkVector["successorC"] as? [String: Any]))["commit"])
        let successorCommit = try AccountWireCodec.decodeTrustCommit(
            JSONSerialization.data(withJSONObject: successor, options: [.sortedKeys, .withoutEscapingSlashes])
        )
        XCTAssertEqual(
            successorCommit.state.transition.recoveryAuthorizationDigest,
            AccountTranscript.recoveryAuthorizationDigest(authorization)
        )

        let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        let page = try XCTUnwrap(pagination["page"] as? [String: Any])
        let entries = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let recoveryEntry = try AccountWireCodec.decodeTrustHistoryEntry(
            JSONSerialization.data(withJSONObject: entries[2], options: [.sortedKeys, .withoutEscapingSlashes])
        )
        XCTAssertEqual(
            recoveryEntry.commit.state.transition.recoveryAuthorizationDigest,
            AccountTranscript.recoveryAuthorizationDigest(authorization)
        )
    }

    func testRecordInventoryProofWireIsClosedSortedAndBindsExactRecordDigests() throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let entry = try AccountRecordInventoryEntryV1(
            recordID: try AccountRecordID("22222222-2222-2222-2222-222222222222"),
            epoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            keyGeneration: try PositiveUInt64(2),
            trustRevision: try PositiveUInt64(3),
            recordRevision: try PositiveUInt64(1),
            envelopeDigest: Data(repeating: 0xA1, count: 32),
            signatureDigest: Data(repeating: 0xA2, count: 32)
        )
        let proof = try AccountRecordInventoryProofV1(
            accountID: accountID,
            trustCommitDigest: Data(repeating: 0xB1, count: 32),
            epoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            keyGeneration: try PositiveUInt64(2),
            entries: [entry],
            issuedAt: "2026-08-08T10:00:00Z",
            expiresAt: "2026-08-08T10:05:00Z",
            serverKeyID: "pagination-2026-01",
            serverSignature: Data(repeating: 1, count: 64)
        )
        let wire = try AccountWireCodec.encodeRecordInventoryProof(proof)
        XCTAssertEqual(try AccountWireCodec.decodeRecordInventoryProof(wire), proof)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        object["unexpected"] = true
        XCTAssertThrowsError(try AccountWireCodec.decodeRecordInventoryProof(JSONSerialization.data(withJSONObject: object)))

        let second = try AccountRecordInventoryEntryV1(
            recordID: try AccountRecordID("11111111-2222-2222-2222-222222222222"),
            epoch: entry.epoch,
            keyGeneration: entry.keyGeneration,
            trustRevision: entry.trustRevision,
            recordRevision: entry.recordRevision,
            envelopeDigest: entry.envelopeDigest,
            signatureDigest: entry.signatureDigest
        )
        XCTAssertThrowsError(try AccountRecordInventoryProofV1(
            accountID: accountID,
            trustCommitDigest: proof.trustCommitDigest,
            epoch: proof.epoch,
            keyGeneration: proof.keyGeneration,
            entries: [entry, second],
            issuedAt: proof.issuedAt,
            expiresAt: proof.expiresAt,
            serverKeyID: proof.serverKeyID,
            serverSignature: proof.serverSignature
        ))
    }

    func testRecordInventoryProofDuplicateScannerHonorsTheCodecSpecific4096EntryLimit() throws {
        func proof(entryCount: Int) throws -> AccountRecordInventoryProofV1 {
            let entries = try (0..<entryCount).map { index in
                try AccountRecordInventoryEntryV1(
                    recordID: AccountRecordID(String(format: "00000000-0000-4000-8000-%012x", index)),
                    epoch: AccountTrustEpoch(rawValue: PositiveUInt64(1)),
                    keyGeneration: PositiveUInt64(2),
                    trustRevision: PositiveUInt64(3),
                    recordRevision: PositiveUInt64(1),
                    envelopeDigest: Data(repeating: UInt8(truncatingIfNeeded: index), count: 32),
                    signatureDigest: Data(repeating: UInt8(truncatingIfNeeded: index &+ 1), count: 32)
                )
            }
            return try AccountRecordInventoryProofV1(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                trustCommitDigest: Data(repeating: 0xB1, count: 32),
                epoch: AccountTrustEpoch(rawValue: PositiveUInt64(1)),
                keyGeneration: PositiveUInt64(2),
                entries: entries,
                issuedAt: "2026-08-08T10:00:00Z",
                expiresAt: "2026-08-08T10:05:00Z",
                serverKeyID: "pagination-2026-01",
                serverSignature: Data(repeating: 1, count: 64)
            )
        }

        for count in [65, AccountRecordInventoryProofV1.maximumEntries] {
            let value = try proof(entryCount: count)
            let wire = try AccountWireCodec.encodeRecordInventoryProof(value)
            XCTAssertEqual(try AccountWireCodec.decodeRecordInventoryProof(wire), value)
        }

        var overCap = try XCTUnwrap(JSONSerialization.jsonObject(
            with: AccountWireCodec.encodeRecordInventoryProof(try proof(entryCount: AccountRecordInventoryProofV1.maximumEntries))
        ) as? [String: Any])
        var entries = try XCTUnwrap(overCap["entries"] as? [Any])
        entries.append(try XCTUnwrap(entries.last))
        overCap["entries"] = entries
        XCTAssertThrowsError(try AccountWireCodec.decodeRecordInventoryProof(
            JSONSerialization.data(withJSONObject: overCap, options: [.sortedKeys, .withoutEscapingSlashes])
        ))
        XCTAssertThrowsError(try AccountWireCodec.validateUniqueJSONKeys(
            JSONSerialization.data(withJSONObject: Array(repeating: 1, count: 65))
        ))
    }

    func testSharedSASVectorRebuildsExactTranscriptAndSixDigits() throws {
        let fixture = try trustFixture().sas
        let existing = try AccountPublicKeyBundle(
            signingKey: try Data(hex: fixture.existingSigningPublicKey),
            agreementKey: try Data(hex: fixture.existingAgreementPublicKey)
        )
        let pending = try AccountPublicKeyBundle(
            signingKey: try Data(hex: fixture.pendingSigningPublicKey),
            agreementKey: try Data(hex: fixture.pendingAgreementPublicKey)
        )
        let offer = try TrustHandshakeOfferV1(
            accountID: try PlainpostAccountID(fixture.accountID),
            existingDeviceID: try AccountDeviceID(fixture.existingDeviceID),
            pendingDeviceID: try AccountDeviceID(fixture.pendingDeviceID),
            existingPublicBundle: existing,
            pendingPublicBundle: pending,
            existingNonce: try Data(hex: fixture.existingNonce),
            createdAtUnixMilliseconds: try PositiveUInt64(wire: fixture.createdAtUnixMilliseconds),
            expiresAtUnixMilliseconds: try PositiveUInt64(wire: fixture.expiresAtUnixMilliseconds)
        )
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: try Data(hex: fixture.pendingNonce))

        XCTAssertEqual(AccountTrustTranscript.handshake(response), try Data(hex: fixture.transcript))
        XCTAssertEqual(AccountTrustAuthentication.handshakeDigest(response), try Data(hex: fixture.handshakeDigest))
        XCTAssertEqual(try AccountTrustAuthentication.authenticationString(for: response), fixture.authenticationString)
    }

    func testLogicalMailboxIDRequiresExactlyThirtyTwoOpaqueBytes() throws {
        let bytes = Data(repeating: 0xA5, count: 32)
        XCTAssertEqual(LogicalMailboxID(rawValue: bytes)?.rawValue, bytes)
        XCTAssertNil(LogicalMailboxID(rawValue: Data(repeating: 0xA5, count: 31)))
        XCTAssertEqual(try JSONDecoder().decode(LogicalMailboxID.self, from: JSONEncoder().encode(LogicalMailboxID(rawValue: bytes)!)), LogicalMailboxID(rawValue: bytes))
    }

    func testGroupPackageVectorIndependentlyRebuildsECDHHKDFAndAESGCM() throws {
        let root = try cryptoFixture()
        let vector = try XCTUnwrap(root["genesisTrustCommit"] as? [String: Any])
        let commitObject = try XCTUnwrap(vector["commit"])
        let packageVector = try XCTUnwrap(vector["package"] as? [String: Any])
        let commit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: commitObject, options: [.sortedKeys, .withoutEscapingSlashes]))
        let package = try XCTUnwrap(commit.keyPackages.first)

        XCTAssertEqual(
            AccountTrustTranscript.groupKeyPackageKDF(
                accountID: commit.state.accountID,
                epoch: commit.state.epoch,
                stateRevision: commit.state.revision,
                keyGeneration: commit.state.keyGeneration,
                stateDigest: package.stateDigest,
                recipientDeviceID: package.recipientDeviceID,
                senderDeviceID: package.senderDeviceID
            ),
            try Data(hex: try fixtureString(packageVector, "kdfInfoHex"))
        )
        XCTAssertEqual(
            AccountTrustTranscript.groupKeyPackageAAD(
                accountID: commit.state.accountID,
                epoch: commit.state.epoch,
                stateRevision: commit.state.revision,
                keyGeneration: commit.state.keyGeneration,
                stateDigest: package.stateDigest,
                keyCommitment: package.keyCommitment,
                recipientDeviceID: package.recipientDeviceID,
                senderDeviceID: package.senderDeviceID,
                senderEphemeralPublicKey: package.senderEphemeralPublicKey
            ),
            try Data(hex: try fixtureString(packageVector, "aadHex"))
        )

        let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: try roleScalar("deviceAgreement", in: root))
        let shared = try agreement.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: package.senderEphemeralPublicKey))
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: package.stateDigest,
            sharedInfo: AccountTrustTranscript.groupKeyPackageKDF(
                accountID: commit.state.accountID,
                epoch: commit.state.epoch,
                stateRevision: commit.state.revision,
                keyGeneration: commit.state.keyGeneration,
                stateDigest: package.stateDigest,
                recipientDeviceID: package.recipientDeviceID,
                senderDeviceID: package.senderDeviceID
            ),
            outputByteCount: 32
        )
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, try Data(hex: try fixtureString(packageVector, "derivedPackageKeyHex")))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: package.nonce),
            ciphertext: Data(package.encryptedKeyMaterial.dropLast(16)),
            tag: Data(package.encryptedKeyMaterial.suffix(16))
        )
        let plaintext = try AES.GCM.open(
            box,
            using: key,
            authenticating: AccountTrustTranscript.groupKeyPackageAAD(
                accountID: commit.state.accountID,
                epoch: commit.state.epoch,
                stateRevision: commit.state.revision,
                keyGeneration: commit.state.keyGeneration,
                stateDigest: package.stateDigest,
                keyCommitment: package.keyCommitment,
                recipientDeviceID: package.recipientDeviceID,
                senderDeviceID: package.senderDeviceID,
                senderEphemeralPublicKey: package.senderEphemeralPublicKey
            )
        )
        XCTAssertEqual(plaintext, try Data(hex: try accountKeyPlaintext(in: root)))

        let signing = try P256.Signing.PrivateKey(rawRepresentation: try roleScalar("deviceSigning", in: root))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: package.signature)
        XCTAssertTrue(signing.publicKey.isValidSignature(signature, for: AccountTranscript.groupKeyPackage(package, encryptedDigest: Data(SHA256.hash(data: package.nonce + package.encryptedKeyMaterial)))))
        let record = try XCTUnwrap(commit.state.members.first)
        let wrongRecordSigning = try P256.Signing.PrivateKey(rawRepresentation: try roleScalar("deviceAgreement", in: root))
        XCTAssertFalse(try wrongRecordSigning.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: record.signature), for: AccountTranscript.trustRecord(record)))
        let wrongStateSigning = try P256.Signing.PrivateKey(rawRepresentation: try roleScalar("metadataSigning", in: root))
        XCTAssertFalse(try wrongStateSigning.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: commit.state.signature), for: AccountTranscript.trustState(commit.state)))
        XCTAssertFalse(wrongStateSigning.publicKey.isValidSignature(signature, for: AccountTranscript.groupKeyPackage(package, encryptedDigest: Data(SHA256.hash(data: package.nonce + package.encryptedKeyMaterial)))))

        let wrongAgreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: try roleScalar("deviceSigning", in: root))
        let wrongKey = try wrongAgreement.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: package.senderEphemeralPublicKey)).hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: package.stateDigest,
            sharedInfo: AccountTrustTranscript.groupKeyPackageKDF(accountID: commit.state.accountID, epoch: commit.state.epoch, stateRevision: commit.state.revision, keyGeneration: commit.state.keyGeneration, stateDigest: package.stateDigest, recipientDeviceID: package.recipientDeviceID, senderDeviceID: package.senderDeviceID),
            outputByteCount: 32
        )
        XCTAssertThrowsError(try AES.GCM.open(box, using: wrongKey, authenticating: AccountTrustTranscript.groupKeyPackageAAD(accountID: commit.state.accountID, epoch: commit.state.epoch, stateRevision: commit.state.revision, keyGeneration: commit.state.keyGeneration, stateDigest: package.stateDigest, keyCommitment: package.keyCommitment, recipientDeviceID: package.recipientDeviceID, senderDeviceID: package.senderDeviceID, senderEphemeralPublicKey: package.senderEphemeralPublicKey)))
    }

    func testEncryptedRecordVectorRebuildsAADSignatureAndAESGCM() throws {
        let root = try cryptoFixture()
        let vector = try XCTUnwrap(root["encryptedAccountRecord"] as? [String: Any])
        let accountID = try PlainpostAccountID(try fixtureString(vector, "accountID"))
        let recordID = try AccountRecordID(try fixtureString(vector, "recordID"))
        let envelope = try AccountWireCodec.decodeBase64URL(try fixtureString(vector, "envelope"))
        let record = try EncryptedAccountRecordV1(
            accountID: accountID,
            recordID: recordID,
            epoch: try AccountTrustEpoch(wire: try fixtureString(vector, "epoch")),
            keyGeneration: try PositiveUInt64(wire: try fixtureString(vector, "keyGeneration")),
            trustRevision: try PositiveUInt64(wire: try fixtureString(vector, "trustRevision")),
            recordRevision: try PositiveUInt64(wire: try fixtureString(vector, "recordRevision")),
            envelope: envelope,
            signerDeviceID: try AccountDeviceID(try fixtureString(vector, "signerDeviceID")),
            signature: try AccountWireCodec.decodeBase64URL(try fixtureString(vector, "signature"), exactBytes: 64)
        )
        let aad = AccountTrustTranscript.encryptedRecordAAD(accountID: accountID, recordID: recordID, epoch: record.epoch, keyGeneration: record.keyGeneration, trustRevision: record.trustRevision, recordRevision: record.recordRevision)
        XCTAssertEqual(aad, try Data(hex: try fixtureString(vector, "aadHex")))
        let envelopeDigest = Data(SHA256.hash(data: envelope))
        XCTAssertEqual(envelopeDigest, try AccountWireCodec.decodeBase64URL(try fixtureString(vector, "envelopeDigest"), exactBytes: 32))
        let signatureTranscript = AccountTrustTranscript.encryptedRecordSignature(record, envelopeDigest: envelopeDigest)
        XCTAssertEqual(signatureTranscript, try Data(hex: try fixtureString(vector, "signatureTranscriptHex")))

        let signing = try P256.Signing.PrivateKey(rawRepresentation: try roleScalar("metadataSigning", in: root))
        XCTAssertTrue(try signing.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: record.signature), for: signatureTranscript))
        let wrongSigning = try P256.Signing.PrivateKey(rawRepresentation: try roleScalar("deviceSigning", in: root))
        XCTAssertFalse(try wrongSigning.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: record.signature), for: signatureTranscript))

        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(envelope.prefix(12))),
            ciphertext: Data(envelope.dropFirst(12).dropLast(16)),
            tag: Data(envelope.suffix(16))
        )
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: try Data(hex: try metadataKey(in: root))), authenticating: aad)
        XCTAssertEqual(plaintext, try Data(hex: try fixtureString(vector, "plaintextHex")))
    }

    func testEncryptedRecordWireIsClosedCanonicalAndMatchesTheSharedVector() throws {
        let root = try cryptoFixture()
        let vector = try XCTUnwrap(root["encryptedAccountRecord"] as? [String: Any])
        let expectedObject: [String: Any] = [
            "kind": "account.encrypted-record.v1",
            "accountID": try fixtureString(vector, "accountID"),
            "recordID": try fixtureString(vector, "recordID"),
            "epoch": try fixtureString(vector, "epoch"),
            "keyGeneration": try fixtureString(vector, "keyGeneration"),
            "trustRevision": try fixtureString(vector, "trustRevision"),
            "recordRevision": try fixtureString(vector, "recordRevision"),
            "envelope": try fixtureString(vector, "envelope"),
            "signerDeviceID": try fixtureString(vector, "signerDeviceID"),
            "signature": try fixtureString(vector, "signature"),
        ]
        let expectedWire = try JSONSerialization.data(withJSONObject: expectedObject, options: [.sortedKeys, .withoutEscapingSlashes])

        let record = try AccountWireCodec.decodeEncryptedAccountRecord(expectedWire)
        XCTAssertEqual(try AccountWireCodec.encodeEncryptedAccountRecord(record), expectedWire)

        var unknown = expectedObject
        unknown["unexpected"] = true
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: unknown)))

        var missing = expectedObject
        missing.removeValue(forKey: "recordRevision")
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: missing)))

        var wrongKind = expectedObject
        wrongKind["kind"] = "account.encrypted-record.v2"
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: wrongKind)))

        var padded = expectedObject
        padded["envelope"] = try fixtureString(vector, "envelope") + "="
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: padded)))

        var numericRevision = expectedObject
        numericRevision["recordRevision"] = 1
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: numericRevision)))

        var tooShort = expectedObject
        tooShort["envelope"] = AccountWireCodec.encodeBase64URL(Data(repeating: 0, count: 28))
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: tooShort)))

        var maximum = expectedObject
        maximum["envelope"] = AccountWireCodec.encodeBase64URL(Data(repeating: 0, count: 65_536))
        XCTAssertNoThrow(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: maximum)))

        var tooLarge = expectedObject
        tooLarge["envelope"] = AccountWireCodec.encodeBase64URL(Data(repeating: 0, count: 65_537))
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: tooLarge)))

        let canonical = String(decoding: expectedWire, as: UTF8.self)
        let duplicate = Data(("{\"kind\":\"account.encrypted-record.v1\"," + canonical.dropFirst()).utf8)
        XCTAssertThrowsError(try AccountWireCodec.decodeEncryptedAccountRecord(duplicate))
    }

    func testTrustHistoryEvidenceWireIsClosedCanonicalAndCarriesCompleteAuthorityProofs() throws {
        let fixture = try trustFixture().sas
        let existing = try AccountPublicKeyBundle(
            signingKey: try Data(hex: fixture.existingSigningPublicKey),
            agreementKey: try Data(hex: fixture.existingAgreementPublicKey)
        )
        let pendingBundle = try AccountPublicKeyBundle(
            signingKey: try Data(hex: fixture.pendingSigningPublicKey),
            agreementKey: try Data(hex: fixture.pendingAgreementPublicKey)
        )
        let offer = try TrustHandshakeOfferV1(
            accountID: try PlainpostAccountID(fixture.accountID),
            existingDeviceID: try AccountDeviceID(fixture.existingDeviceID),
            pendingDeviceID: try AccountDeviceID(fixture.pendingDeviceID),
            existingPublicBundle: existing,
            pendingPublicBundle: pendingBundle,
            existingNonce: try Data(hex: fixture.existingNonce),
            createdAtUnixMilliseconds: try PositiveUInt64(wire: fixture.createdAtUnixMilliseconds),
            expiresAtUnixMilliseconds: try PositiveUInt64(wire: fixture.expiresAtUnixMilliseconds)
        )
        let pending = try PendingAccountDevice(
            accountID: offer.accountID,
            deviceID: offer.pendingDeviceID,
            platform: .ios,
            publicBundle: offer.pendingPublicBundle,
            exchangeRequestDigest: Data(repeating: 0x44, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let response = try TrustHandshakeResponseV1(
            offer: offer,
            pendingNonce: try Data(hex: fixture.pendingNonce)
        )
        let admission = AccountTrustAdmissionEvidenceV1(pendingDevice: pending, response: response)
        let admissionWire = try AccountWireCodec.encodeTrustAdmissionEvidence(admission)
        XCTAssertEqual(try AccountWireCodec.decodeTrustAdmissionEvidence(admissionWire), admission)

        var admissionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: admissionWire) as? [String: Any])
        admissionObject["unexpected"] = true
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustAdmissionEvidence(JSONSerialization.data(withJSONObject: admissionObject)))
        let admissionText = String(decoding: admissionWire, as: UTF8.self)
        let duplicateAdmission = Data(("{\"kind\":\"account.trust-admission-evidence.v1\"," + admissionText.dropFirst()).utf8)
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustAdmissionEvidence(duplicateAdmission))

        let root = try cryptoFixture()
        let recoveryObject = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: recoveryObject))
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Protocol/account-v1/fixtures/central-bootstrap-manifest-test-v1.json")
        let manifest = try AccountWireCodec.decodeManifest(Data(contentsOf: manifestURL))
        let recovery = AccountTrustRecoveryEvidenceV1(authorization: authorization, historicalManifest: manifest)
        let recoveryWire = try AccountWireCodec.encodeTrustRecoveryEvidence(recovery)
        XCTAssertEqual(try AccountWireCodec.decodeTrustRecoveryEvidence(recoveryWire), recovery)

        var recoveryWireObject = try XCTUnwrap(JSONSerialization.jsonObject(with: recoveryWire) as? [String: Any])
        recoveryWireObject["historicalManifest"] = NSNull()
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustRecoveryEvidence(JSONSerialization.data(withJSONObject: recoveryWireObject)))

        let genesisObject = try XCTUnwrap((try XCTUnwrap(root["genesisTrustCommit"] as? [String: Any]))["commit"])
        let genesis = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: genesisObject))
        let entry = try AccountTrustHistoryEntryV1(commit: genesis, evidence: nil)
        let entryWire = try AccountWireCodec.encodeTrustHistoryEntry(entry)
        XCTAssertEqual(try AccountWireCodec.decodeTrustHistoryEntry(entryWire), entry)
        var entryObject = try XCTUnwrap(JSONSerialization.jsonObject(with: entryWire) as? [String: Any])
        entryObject["evidence"] = try JSONSerialization.jsonObject(with: admissionWire)
        XCTAssertThrowsError(try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: entryObject)))
    }

    func testAdmissionRendezvousEnvelopeUsesCanonicalOfferAsImmutableAttemptIdentity() throws {
        let fixture = try trustFixture().sas
        let offer = try TrustHandshakeOfferV1(
            accountID: PlainpostAccountID(fixture.accountID),
            existingDeviceID: AccountDeviceID(fixture.existingDeviceID),
            pendingDeviceID: AccountDeviceID(fixture.pendingDeviceID),
            existingPublicBundle: AccountPublicKeyBundle(signingKey: Data(hex: fixture.existingSigningPublicKey), agreementKey: Data(hex: fixture.existingAgreementPublicKey)),
            pendingPublicBundle: AccountPublicKeyBundle(signingKey: Data(hex: fixture.pendingSigningPublicKey), agreementKey: Data(hex: fixture.pendingAgreementPublicKey)),
            existingNonce: Data(hex: fixture.existingNonce),
            createdAtUnixMilliseconds: PositiveUInt64(wire: fixture.createdAtUnixMilliseconds),
            expiresAtUnixMilliseconds: PositiveUInt64(wire: fixture.expiresAtUnixMilliseconds)
        )
        let offerWire = try AccountWireCodec.encodeAdmissionOfferEnvelope(offer)
        let envelope = try AccountWireCodec.decodeAdmissionOfferEnvelope(offerWire)
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(hex: fixture.pendingNonce))
        let responseWire = try AccountWireCodec.encodeAdmissionResponseEnvelope(AccountTrustAdmissionResponseEnvelopeV1(offerDigest: envelope.offerDigest, response: response))
        XCTAssertEqual(try AccountWireCodec.decodeAdmissionResponseEnvelope(responseWire).response, response)
        let cancelWire = try AccountWireCodec.encodeAdmissionCancelEnvelope(AccountTrustAdmissionCancelEnvelopeV1(offerDigest: envelope.offerDigest))
        XCTAssertNoThrow(try AccountWireCodec.decodeAdmissionCancelEnvelope(cancelWire))
        let cancelDigest = AccountWireCodec.encodeBase64URL(envelope.offerDigest)
        for mutation in [
            " {\"kind\":\"account.trust-admission-cancel.v1\",\"offerDigest\":\"\(cancelDigest)\"}",
            "{\"offerDigest\":\"\(cancelDigest)\",\"kind\":\"account.trust-admission-cancel.v1\"}",
            "{\"kind\":\"account.trust-admission-cancel.v1\",\"offerDigest\":\"\(cancelDigest)\",\"unknown\":true}",
            "{\"kind\":\"account.trust-admission-cancel.v1\",\"kind\":\"account.trust-admission-cancel.v1\",\"offerDigest\":\"\(cancelDigest)\"}",
            "{\"kind\":\"account.trust-admission-cancel.v1\",\"offerDigest\":\"\(cancelDigest)=\"}",
        ] {
            XCTAssertThrowsError(try AccountWireCodec.decodeAdmissionCancelEnvelope(Data(mutation.utf8)))
        }

        let reordered = Data(String(decoding: offerWire, as: UTF8.self).replacingOccurrences(of: "{\"kind\":\"account.trust-admission-offer.v1\",\"offer\":", with: "{ \"kind\":\"account.trust-admission-offer.v1\",\"offer\":" ).utf8)
        XCTAssertThrowsError(try AccountWireCodec.decodeAdmissionOfferEnvelope(reordered))
        var mutated = try XCTUnwrap(JSONSerialization.jsonObject(with: offerWire) as? [String: Any])
        mutated["offerDigest"] = AccountWireCodec.encodeBase64URL(Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try AccountWireCodec.decodeAdmissionOfferEnvelope(JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])))
    }

    func testTrustPageVectorBindsExactHistoryEntryDigest() throws {
        let root = try cryptoFixture()
        let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        let page = try XCTUnwrap(pagination["page"] as? [String: Any])
        let entries = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let decodedEntries = try entries.map {
            try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: $0))
        }
        XCTAssertEqual(decodedEntries.map { $0.commit.state.transition.kind }, [.genesis, .admission, .recovery])
        let entryDigests = decodedEntries.map(protocolHistoryEntryDigest)
        let expectedDigests = try XCTUnwrap(pagination["pageEntryDigests"] as? [String]).map {
            try AccountWireCodec.decodeBase64URL($0, exactBytes: 32)
        }
        XCTAssertEqual(entryDigests, expectedDigests)
        XCTAssertEqual(entryDigests[1], try AccountWireCodec.decodeBase64URL(try fixtureString(pagination, "admissionHistoryEntryDigest"), exactBytes: 32))
        XCTAssertEqual(entryDigests[2], try AccountWireCodec.decodeBase64URL(try fixtureString(pagination, "recoveryHistoryEntryDigest"), exactBytes: 32))
        XCTAssertEqual(decodedEntries[1].commit.state.previousCommitDigest, AccountTranscript.trustCommitDigest(decodedEntries[0].commit))
        XCTAssertEqual(decodedEntries[2].commit.state.previousCommitDigest, AccountTranscript.trustCommitDigest(decodedEntries[1].commit))
        let mutations = try XCTUnwrap(pagination["mutationCases"] as? [[String: Any]])
        XCTAssertEqual(mutations.count, 3)
        XCTAssertTrue(mutations.allSatisfy { $0["expected"] as? String == "reject" })

        let swap = mutations[0]
        XCTAssertEqual(swap["operation"] as? String, "swapEvidence")
        XCTAssertEqual(swap["entryIndexes"] as? [Int], [1, 2])
        XCTAssertThrowsError(try AccountTrustHistoryEntryV1(commit: decodedEntries[1].commit, evidence: decodedEntries[2].evidence))
        XCTAssertThrowsError(try AccountTrustHistoryEntryV1(commit: decodedEntries[2].commit, evidence: decodedEntries[1].evidence))

        let admissionMutation = mutations[1]
        XCTAssertEqual(admissionMutation["jsonPointer"] as? String, "/evidence/pendingDevice/publicBundle/signingKey")
        var substitutedAdmissionObject = entries[1]
        var admissionEvidenceObject = try XCTUnwrap(substitutedAdmissionObject["evidence"] as? [String: Any])
        var pendingObject = try XCTUnwrap(admissionEvidenceObject["pendingDevice"] as? [String: Any])
        var pendingBundle = try XCTUnwrap(pendingObject["publicBundle"] as? [String: Any])
        pendingBundle["signingKey"] = try XCTUnwrap(admissionMutation["replacement"] as? String)
        pendingObject["publicBundle"] = pendingBundle
        admissionEvidenceObject["pendingDevice"] = pendingObject
        substitutedAdmissionObject["evidence"] = admissionEvidenceObject
        let substitutedAdmission = try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: substitutedAdmissionObject))
        guard case .admission(let substitutedEvidence)? = substitutedAdmission.evidence else { return XCTFail("expected admission evidence") }
        XCTAssertNotEqual(
            Data(SHA256.hash(data: AccountTranscript.pendingDeviceAuthorization(substitutedEvidence.pendingDevice))),
            substitutedAdmission.commit.state.transition.pendingDeviceDigest
        )
        XCTAssertNotEqual(protocolHistoryEntryDigest(substitutedAdmission), entryDigests[1])

        let recoveryMutation = mutations[2]
        XCTAssertEqual(recoveryMutation["jsonPointer"] as? String, "/evidence/historicalManifest/rootSignature")
        var substitutedRecoveryObject = entries[2]
        var recoveryEvidenceObject = try XCTUnwrap(substitutedRecoveryObject["evidence"] as? [String: Any])
        var historicalManifest = try XCTUnwrap(recoveryEvidenceObject["historicalManifest"] as? [String: Any])
        historicalManifest["rootSignature"] = try XCTUnwrap(recoveryMutation["replacement"] as? String)
        recoveryEvidenceObject["historicalManifest"] = historicalManifest
        substitutedRecoveryObject["evidence"] = recoveryEvidenceObject
        let substitutedRecovery = try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: substitutedRecoveryObject))
        guard case .recovery(let substitutedEvidence)? = substitutedRecovery.evidence else { return XCTFail("expected recovery evidence") }
        let manifestTranscript = AccountTranscript.manifest(
            rootKeyID: substitutedEvidence.historicalManifest.rootKeyID,
            version: substitutedEvidence.historicalManifest.manifestVersion,
            notBefore: substitutedEvidence.historicalManifest.notBefore,
            expiresAt: substitutedEvidence.historicalManifest.expiresAt,
            previousDigest: substitutedEvidence.historicalManifest.previousManifestDigest,
            keys: substitutedEvidence.historicalManifest.keys
        )
        let rootKey = try P256.Signing.PublicKey(x963Representation: try rolePublicKey("root", in: root))
        let rootSignature = try P256.Signing.ECDSASignature(rawRepresentation: substitutedEvidence.historicalManifest.rootSignature)
        XCTAssertFalse(rootKey.isValidSignature(rootSignature, for: manifestTranscript))
        XCTAssertNotEqual(protocolHistoryEntryDigest(substitutedRecovery), entryDigests[2])

        let snapshot = try XCTUnwrap(page["snapshotHead"] as? [String: Any])
        let checkpoint = AccountTranscript.parts([
            AccountTranscript.u64(try XCTUnwrap(UInt64(try fixtureString(snapshot, "epoch")))),
            AccountTranscript.u64(try XCTUnwrap(UInt64(try fixtureString(snapshot, "revision")))),
            try AccountWireCodec.decodeBase64URL(try fixtureString(snapshot, "commitDigest"), exactBytes: 32),
        ])
        let transcript = AccountTranscript.parts([
            Data("Plainpost.TrustStatePage.v1".utf8),
            AccountTranscript.u16(1),
            try AccountWireCodec.decodeBase64URL(try fixtureString(pagination, "requestCursorDigest"), exactBytes: 32),
            AccountTranscript.uuid(try fixtureString(page, "accountID")),
            checkpoint,
            AccountTranscript.u16(UInt16(entryDigests.count)),
        ] + entryDigests + [
            Data(),
            AccountTranscript.u16(1),
            Data(try fixtureString(page, "issuedAt").utf8),
            Data(try fixtureString(page, "expiresAt").utf8),
            Data(try fixtureString(page, "serverKeyID").utf8),
        ])
        XCTAssertEqual(transcript, try Data(hex: try fixtureString(pagination, "pageTranscriptHex")))
        let paginationKey = try P256.Signing.PublicKey(x963Representation: try rolePublicKey("pagination", in: root))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try AccountWireCodec.decodeBase64URL(try fixtureString(page, "serverSignature"), exactBytes: 64))
        XCTAssertTrue(paginationKey.isValidSignature(signature, for: transcript))
    }

    func testEveryStructuredWrongRoleReferencesPublicTestOnlyInput() throws {
        let root = try cryptoFixture()
        let roles = try XCTUnwrap((try XCTUnwrap(root["testOnlyInputs"] as? [String: Any]))["roles"] as? [String: Any])
        let cases = try XCTUnwrap(root["wrongRoleCases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            XCTAssertEqual(item["expected"] as? String, "reject")
            let role = try XCTUnwrap(item["attemptedKeyRole"] as? String)
            XCTAssertNotNil(roles[role], "undefined role \(role)")
        }
    }
}

private func protocolHistoryEntryDigest(_ entry: AccountTrustHistoryEntryV1) -> Data {
    let kind: Data
    let evidenceDigest: Data
    switch entry.evidence {
    case .admission(let evidence):
        kind = Data("account.trust-admission-evidence.v1".utf8)
        let pending = Data(SHA256.hash(data: AccountTranscript.pendingDeviceAuthorization(evidence.pendingDevice)))
        let handshake = Data(SHA256.hash(data: AccountTrustTranscript.handshake(evidence.response)))
        evidenceDigest = Data(SHA256.hash(data: AccountTranscript.parts([pending, handshake])))
    case .recovery(let evidence):
        kind = Data("account.trust-recovery-evidence.v1".utf8)
        let authorization = AccountTranscript.recoveryAuthorizationDigest(evidence.authorization)
        let manifestTranscript = AccountTranscript.manifest(
            rootKeyID: evidence.historicalManifest.rootKeyID,
            version: evidence.historicalManifest.manifestVersion,
            notBefore: evidence.historicalManifest.notBefore,
            expiresAt: evidence.historicalManifest.expiresAt,
            previousDigest: evidence.historicalManifest.previousManifestDigest,
            keys: evidence.historicalManifest.keys
        ) + AccountTranscript.part(evidence.historicalManifest.rootSignature)
        let manifest = Data(SHA256.hash(data: manifestTranscript))
        evidenceDigest = Data(SHA256.hash(data: AccountTranscript.parts([authorization, manifest])))
    case .syncNodeEnrollment(let evidence):
        kind = Data("account.sync-node-admission-evidence.v1".utf8)
        evidenceDigest = Data(SHA256.hash(data: try! AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(evidence)))
    case nil:
        kind = Data()
        evidenceDigest = Data()
    }
    return Data(SHA256.hash(data: AccountTranscript.parts([
        AccountTranscript.trustCommitDigest(entry.commit),
        kind,
        evidenceDigest,
    ])))
}

private struct TrustFixture: Decodable {
    struct SAS: Decodable {
        let accountID: String
        let existingDeviceID: String
        let pendingDeviceID: String
        let existingSigningPublicKey: String
        let existingAgreementPublicKey: String
        let pendingSigningPublicKey: String
        let pendingAgreementPublicKey: String
        let existingNonce: String
        let pendingNonce: String
        let createdAtUnixMilliseconds: String
        let expiresAtUnixMilliseconds: String
        let transcript: String
        let handshakeDigest: String
        let authenticationString: String
    }
    let sas: SAS
}

private func trustFixture() throws -> TrustFixture {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Protocol/account-v1/fixtures/trust-v1.json")
    return try JSONDecoder().decode(TrustFixture.self, from: Data(contentsOf: url))
}

private func cryptoFixture() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func fixtureString(_ object: [String: Any], _ key: String) throws -> String {
    try XCTUnwrap(object[key] as? String, "missing string \(key)")
}

private func roleScalar(_ role: String, in root: [String: Any]) throws -> Data {
    let testInputs = try XCTUnwrap(root["testOnlyInputs"] as? [String: Any])
    let roles = try XCTUnwrap(testInputs["roles"] as? [String: Any])
    let item = try XCTUnwrap(roles[role] as? [String: Any])
    return try Data(hex: try fixtureString(item, "privateScalarHex"))
}

private func rolePublicKey(_ role: String, in root: [String: Any]) throws -> Data {
    let testInputs = try XCTUnwrap(root["testOnlyInputs"] as? [String: Any])
    let roles = try XCTUnwrap(testInputs["roles"] as? [String: Any])
    let item = try XCTUnwrap(roles[role] as? [String: Any])
    return try AccountWireCodec.decodeBase64URL(try fixtureString(item, "publicKey"), exactBytes: 65)
}

private func accountKeyPlaintext(in root: [String: Any]) throws -> String {
    try fixtureString(try XCTUnwrap(root["testOnlyInputs"] as? [String: Any]), "accountKeyPlaintextHex")
}

private func metadataKey(in root: [String: Any]) throws -> String {
    try fixtureString(try XCTUnwrap(root["testOnlyInputs"] as? [String: Any]), "metadataKeyHex")
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw AccountProtocolError.malformedWire }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw AccountProtocolError.malformedWire }
            result.append(byte)
            index = next
        }
        self = result
    }
}
