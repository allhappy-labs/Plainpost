import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class AccountAPIClientTests: XCTestCase {
    func testSwiftDecoderAcceptsGoRecoveryPreparationFixtureWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["PLAINPOST_RECOVERY_PREPARATION_FIXTURE"],
              !path.isEmpty else {
            throw XCTSkip("Go recovery preparation fixture was not requested")
        }

        let preparation = try AccountWireCodec.decodeRecoveryPreparation(
            Data(contentsOf: URL(fileURLWithPath: path))
        )

        XCTAssertEqual(preparation.priorHistory.count, 1)
        XCTAssertEqual(preparation.authorization.platform, .macos)
    }

    func testRecoveryPreparationReportsMalformedSuccessfulResponseAsDecodingFailure() async throws {
        let store = AccountCredentialStore(
            secretStore: InMemoryAccountSecretStore(),
            service: "com.marynavdovenko.Plainpost.AccountTests.RecoveryDecoding"
        )
        let transport = RecordingAccountTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/account/recovery/prepare")
            return AccountHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            )
        }
        let client = try AccountAPIClient(
            transport: transport,
            credentialStore: store,
            manifestStore: try manifestStore()
        )

        do {
            _ = try await client.prepareRecovery(
                identityToken: "identity.token",
                appleNonce: Data(repeating: 7, count: 32),
                device: store.loadOrCreateDeviceIdentity()
            )
            XCTFail("malformed recovery preparation must fail")
        } catch let failure as AccountRecoveryFailure {
            XCTAssertEqual(failure, .responseDecoding)
        }
    }

    func testProductionTransportStopsStreamingResponsesAboveAccountRouteMaximum() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPURLProtocol.self]
        let transport = URLSessionAccountHTTPTransport(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://plainpost-api.olhapi.com/test")!)
        request.httpMethod = "POST"

        do {
            _ = try await transport.send(request)
            XCTFail("oversized streamed response must be rejected")
        } catch let error as AccountRuntimeError {
            XCTAssertEqual(error, .transportFailure)
        }
    }

    func testProductionTransportStopsAtTheRouteSpecificInventoryResponseBudget() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InventoryOversizedAccountHTTPURLProtocol.self]
        let transport = URLSessionAccountHTTPTransport(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://plainpost-api.olhapi.com/v1/account-records/inventory-proof")!)

        await XCTAssertThrowsErrorAsync {
            _ = try await transport.send(request, maximumResponseBytes: AccountWireCodec.maxRecordInventoryBodyBytes)
        }
    }

    func testInventoryRouteAcceptsProtocolTwoMiBResponseBudgetAndRejectsOneByteOver() async throws {
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.InventoryBudget")
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        let acceptedBody = Data(repeating: 0x61, count: AccountWireCodec.maxRecordInventoryBodyBytes)
        let accepted = try AccountAPIClient(transport: RecordingAccountTransport { _ in AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: acceptedBody) }, credentialStore: store, manifestStore: manifestStore())
        let acceptedResponse = try await accepted.sendAccountRequest(method: "POST", path: "/v1/account-records/inventory-proof", body: Data("{}".utf8), credentials: credentials, device: store.loadOrCreateDeviceIdentity(), maximumResponseBytes: AccountWireCodec.maxRecordInventoryBodyBytes)
        XCTAssertEqual(acceptedResponse.count, AccountWireCodec.maxRecordInventoryBodyBytes)
        let oversizedBody = Data(repeating: 0x61, count: AccountWireCodec.maxRecordInventoryBodyBytes + 1)
        let rejected = try AccountAPIClient(transport: RecordingAccountTransport { _ in AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: oversizedBody) }, credentialStore: store, manifestStore: manifestStore())
        await XCTAssertThrowsErrorAsync { _ = try await rejected.sendAccountRequest(method: "POST", path: "/v1/account-records/inventory-proof", body: Data("{}".utf8), credentials: credentials, device: store.loadOrCreateDeviceIdentity(), maximumResponseBytes: AccountWireCodec.maxRecordInventoryBodyBytes) }
    }

    func testAuthenticatedAccountRequestBindsMethodBearerQueryAndRouteBounds() async throws {
        let response = Data(repeating: 0x61, count: 65 * 1024)
        let transport = RecordingAccountTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            XCTAssertEqual(request.url?.path, "/v1/trust/chain")
            XCTAssertEqual(request.url?.query, "after=genesis&limit=32")
            let encodedProof = try XCTUnwrap(request.value(forHTTPHeaderField: "DPoP"))
            let proofData = try XCTUnwrap(Data(base64URLEncoded: encodedProof))
            let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: proofData) as? [String: String])
            XCTAssertEqual(proof["method"], "GET")
            XCTAssertEqual(proof["target"], "/v1/trust/chain?after=genesis&limit=32")
            XCTAssertEqual(proof["bodyDigest"], AccountWireCodec.encodeBase64URL(Data(SHA256.hash(data: Data()))))
            XCTAssertEqual(proof["accessTokenDigest"], AccountWireCodec.encodeBase64URL(Data(SHA256.hash(data: Data("access-token".utf8)))))
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: response)
        }
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.Authenticated")
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore(clock: Date(timeIntervalSince1970: 1_785_751_680)))
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        let identity = try store.loadOrCreateDeviceIdentity()
        let body = try await client.sendAccountRequest(method: "GET", path: "/v1/trust/chain", queryItems: [URLQueryItem(name: "after", value: "genesis"), URLQueryItem(name: "limit", value: "32")], credentials: credentials, device: identity, now: Date(timeIntervalSince1970: 1_786_100_000), maximumResponseBytes: 128 * 1024)
        XCTAssertEqual(body.count, response.count)
        await XCTAssertThrowsErrorAsync {
            _ = try await client.sendAccountRequest(method: "PATCH", path: "/v1/devices/x", credentials: credentials, device: identity)
        }
    }

    func testAuthenticatedServerFailureIsReportedAsAnUncertainTransportFailure() async throws {
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.ServerFailure")
        let transport = RecordingAccountTransport { _ in
            AccountHTTPResponse(statusCode: 503, headers: ["content-type": "application/problem+json"], body: Data("{}".utf8))
        }
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore())
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")

        do {
            _ = try await client.sendAccountRequest(method: "POST", path: "/v1/sync-nodes/enrollment/approve", body: Data("{}".utf8), credentials: credentials, device: store.loadOrCreateDeviceIdentity())
            XCTFail("expected 5xx to be treated as uncertain")
        } catch let error as AccountRuntimeError {
            XCTAssertEqual(error, .transportFailure)
        }
    }

    func testStatusPreservingRequestReturnsOnlyHTTPStatusForPermanentFailure() async throws {
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.StatusOnly")
        let transport = RecordingAccountTransport { _ in
            AccountHTTPResponse(statusCode: 409, headers: ["content-type": "text/plain"], body: Data("private server detail".utf8))
        }
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore())
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")

        let result = try await client.sendAccountRequestResult(
            method: "POST", path: "/v1/notifications", body: Data("{}".utf8), credentials: credentials,
            device: store.loadOrCreateDeviceIdentity()
        )
        guard case .httpFailure(let statusCode) = result else {
            return XCTFail("expected status-only failure")
        }
        XCTAssertEqual(statusCode, 409)
    }

    func testAccountLifecycleStepUpVerifiesFreshAuthorizationAtResponseReceiptTime() async throws {
        let requestStart = try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-14T12:00:00Z"))
        let responseReceipt = requestStart.addingTimeInterval(2)
        let serverSigner = try AccountDeviceIdentity(
            signingPrivateKey: Data(repeating: 0, count: 31) + Data([0x10]),
            agreementPrivateKey: Data(repeating: 0, count: 31) + Data([0x11])
        )
        let transport = RecordingAccountTransport { request in
            let stepUp = try AccountWireCodec.decodeStepUpRequest(try XCTUnwrap(request.httpBody))
            let unsigned = try AccountStepUpAuthorizationV1(
                authorizationID: AccountAuthorizationID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
                accountID: stepUp.accountID,
                actorDeviceID: stepUp.actorDeviceID,
                targetDeviceID: stepUp.targetDeviceID,
                action: stepUp.action,
                currentCommitDigest: stepUp.currentCommitDigest,
                requestDigest: Data(SHA256.hash(data: AccountTranscript.stepUpRequest(stepUp))),
                issuedAt: "2026-08-14T12:00:01Z",
                expiresAt: "2026-08-14T12:05:01Z",
                serverKeyID: "recovery-authorization-2026-01",
                serverSignature: Data(repeating: 1, count: 64)
            )
            let authorization = try AccountStepUpAuthorizationV1(
                authorizationID: unsigned.authorizationID,
                accountID: unsigned.accountID,
                actorDeviceID: unsigned.actorDeviceID,
                targetDeviceID: unsigned.targetDeviceID,
                action: unsigned.action,
                currentCommitDigest: unsigned.currentCommitDigest,
                requestDigest: unsigned.requestDigest,
                issuedAt: unsigned.issuedAt,
                expiresAt: unsigned.expiresAt,
                serverKeyID: unsigned.serverKeyID,
                serverSignature: serverSigner.signature(for: AccountTranscript.stepUpAuthorization(unsigned))
            )
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try AccountWireCodec.encodeStepUpAuthorization(authorization))
        }
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.LifecycleStepUpReceiptClock")
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore(clock: responseReceipt))
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")

        let authorization = try await client.issueStepUp(
            action: .deleteAccount,
            targetDeviceID: nil,
            currentCommitDigest: Data(repeating: 5, count: 32),
            identityToken: "acceptance-token",
            appleNonce: Data(repeating: 4, count: 32),
            credentials: credentials,
            device: store.loadOrCreateDeviceIdentity(),
            now: requestStart
        )

        XCTAssertEqual(authorization.issuedAt, "2026-08-14T12:00:01Z")
    }

    func testSyncNodeStepUpVerifiesFreshAuthorizationAtResponseReceiptTime() async throws {
        let requestStart = try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-14T12:00:00Z"))
        let responseReceipt = requestStart.addingTimeInterval(2)
        let serverSigner = try AccountDeviceIdentity(
            signingPrivateKey: Data(repeating: 0, count: 31) + Data([0x10]),
            agreementPrivateKey: Data(repeating: 0, count: 31) + Data([0x11])
        )
        let transport = RecordingAccountTransport { request in
            let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            let stepUpObject = try XCTUnwrap(outer["stepUp"])
            let stepUp = try AccountWireCodec.decodeStepUpRequest(JSONSerialization.data(withJSONObject: stepUpObject, options: [.sortedKeys, .withoutEscapingSlashes]))
            let unsigned = try AccountStepUpAuthorizationV1(
                authorizationID: AccountAuthorizationID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
                accountID: stepUp.accountID,
                actorDeviceID: stepUp.actorDeviceID,
                targetDeviceID: stepUp.targetDeviceID,
                action: stepUp.action,
                currentCommitDigest: stepUp.currentCommitDigest,
                requestDigest: Data(SHA256.hash(data: AccountTranscript.stepUpRequest(stepUp))),
                issuedAt: "2026-08-14T12:00:01Z",
                expiresAt: "2026-08-14T12:05:01Z",
                serverKeyID: "recovery-authorization-2026-01",
                serverSignature: Data(repeating: 1, count: 64)
            )
            let authorization = try AccountStepUpAuthorizationV1(
                authorizationID: unsigned.authorizationID,
                accountID: unsigned.accountID,
                actorDeviceID: unsigned.actorDeviceID,
                targetDeviceID: unsigned.targetDeviceID,
                action: unsigned.action,
                currentCommitDigest: unsigned.currentCommitDigest,
                requestDigest: unsigned.requestDigest,
                issuedAt: unsigned.issuedAt,
                expiresAt: unsigned.expiresAt,
                serverKeyID: unsigned.serverKeyID,
                serverSignature: serverSigner.signature(for: AccountTranscript.stepUpAuthorization(unsigned))
            )
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try AccountWireCodec.encodeStepUpAuthorization(authorization))
        }
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.SyncNodeStepUpReceiptClock")
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore(clock: responseReceipt))
        let fixture = try fixtureRoot()
        let genesis = try XCTUnwrap(((fixture["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any])
        let trustCommit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(genesis["genesisCommit"])))
        let credentials = try AccountSessionCredentials(accountID: trustCommit.state.accountID, deviceID: trustCommit.state.members[0].deviceID, accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        let owner = try store.loadOrCreateDeviceIdentity()
        let node = try AccountDeviceIdentity.generate()
        let claim = try AccountNodeEnrollmentPublicClaimV1(claimID: NodeEnrollmentClaimID("bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"), nodeDeviceID: AccountDeviceID("cccccccc-dddd-4eee-8fff-000000000001"), signingPublicKey: node.publicBundle.signingKey, agreementPublicKey: node.publicBundle.agreementKey, noiseStaticPublicKey: Data(repeating: 2, count: 32), endpointDigest: Data(repeating: 3, count: 32), createdAt: "2026-08-14T12:00:00Z", expiresAt: "2026-08-14T12:05:00Z")

        let authorization = try await client.issueSyncNodeStepUp(
            action: .enroll,
            claim: claim,
            replacedNodeID: nil,
            authorization: try SyncNodeEnrollmentAppleAuthorization(identityToken: "acceptance-token", nonce: Data(repeating: 4, count: 32)),
            credentials: credentials,
            device: owner,
            trustCommit: trustCommit,
            now: requestStart
        )

        XCTAssertEqual(authorization.issuedAt, "2026-08-14T12:00:01Z")
    }

    func testDeletionTransportRetryUsesByteIdenticalCanonicalRequest() async throws {
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.DeleteRetry")
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        let head = Data(repeating: 0x31, count: 32)
        let signature = Data(repeating: 0, count: 31) + Data([1]) + Data(repeating: 0, count: 31) + Data([1])
        let authorization = try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), accountID: credentials.accountID, actorDeviceID: credentials.deviceID, targetDeviceID: nil, action: .deleteAccount, currentCommitDigest: head, requestDigest: Data(repeating: 0x32, count: 32), issuedAt: "2026-08-09T12:00:00Z", expiresAt: "2026-08-09T12:05:00Z", serverKeyID: "recovery-2026-08", serverSignature: signature)
        let result = try AccountDeletionResultV1(accountID: credentials.accountID, deletionGeneration: PositiveUInt64(1), centralBackupExpiresAt: "2026-09-08T12:00:00Z", targets: [], deletedAt: "2026-08-09T12:00:01Z")
        let transport = RetryingDeletionTransport(response: try AccountWireCodec.encodeDeletionResult(result))
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: manifestStore())

        let decoded = try await client.deleteAccount(authorization: authorization, currentCommitDigest: head, credentials: credentials, device: store.loadOrCreateDeviceIdentity(), now: Date(timeIntervalSince1970: 1_786_273_201))

        XCTAssertEqual(decoded, result)
        let bodies = await transport.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
    }

    func testTrustHistoryFetchAuthenticatesPageThenPersistsOnlyVerifiedEntries() async throws {
        let fixture = try fixtureRoot()
        let pageObject = try XCTUnwrap((fixture["trustPagination"] as? [String: Any])?["page"])
        let pageWire = try JSONSerialization.data(withJSONObject: pageObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let transport = RecordingAccountTransport { request in
            XCTAssertEqual(request.url?.query, "after=genesis&limit=32")
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: pageWire)
        }
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.History")
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore(clock: Date(timeIntervalSince1970: 1_785_751_680)))
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        let applying = RecordingHistoryApplier()
        let result = try await client.synchronizeTrustHistory(credentials: credentials, device: store.loadOrCreateDeviceIdentity(), applying: applying, now: Date(timeIntervalSince1970: 1_786_017_600))
        XCTAssertEqual(result?.state.revision.value, 1)
        let acceptedCount = await applying.acceptedCount()
        XCTAssertEqual(acceptedCount, 3)

        var tampered = try XCTUnwrap(pageObject as? [String: Any])
        tampered["terminal"] = false
        let tamperedWire = try JSONSerialization.data(withJSONObject: tampered)
        let badTransport = RecordingAccountTransport { _ in AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: tamperedWire) }
        let badClient = try AccountAPIClient(transport: badTransport, credentialStore: store, manifestStore: try manifestStore(clock: Date(timeIntervalSince1970: 1_785_751_680)))
        let rejected = RecordingHistoryApplier()
        await XCTAssertThrowsErrorAsync { _ = try await badClient.synchronizeTrustHistory(credentials: credentials, device: store.loadOrCreateDeviceIdentity(), applying: rejected, now: Date(timeIntervalSince1970: 1_786_017_600)) }
        let rejectedCount = await rejected.acceptedCount()
        XCTAssertEqual(rejectedCount, 0)
    }

    func testTrustPageCodecAcceptsTheFullThirtyTwoEntryPage() throws {
        let fixture = try fixtureRoot()
        let pageObject = try XCTUnwrap((fixture["trustPagination"] as? [String: Any])?["page"] as? [String: Any])
        let published = try AccountWireCodec.decodeTrustStatePage(JSONSerialization.data(withJSONObject: pageObject, options: [.sortedKeys, .withoutEscapingSlashes]))
        let page = try signedPage(entries: Array(repeating: try XCTUnwrap(published.entries.first), count: 32), after: .genesis, snapshot: published.snapshotHead, terminal: false)

        let decoded = try AccountWireCodec.decodeTrustStatePage(AccountWireCodec.encodeTrustStatePage(page))

        XCTAssertEqual(decoded.entries.count, 32)
    }

    func testTrustHistoryCursorFailureRestartsFromPersistedHighWaterAndCancellationKeepsValidPrefix() async throws {
        let fixture = try fixtureRoot(), pageObject = try XCTUnwrap((fixture["trustPagination"] as? [String: Any])?["page"])
        let published = try AccountWireCodec.decodeTrustStatePage(JSONSerialization.data(withJSONObject: pageObject, options: [.sortedKeys, .withoutEscapingSlashes]))
        let first = try signedPage(entries: [published.entries[0]], after: .genesis, snapshot: published.snapshotHead, terminal: false)
        let firstCheckpoint = try AccountTrustPageCheckpointV1(epoch: published.entries[0].commit.state.epoch, revision: published.entries[0].commit.state.revision, commitDigest: AccountTranscript.trustCommitDigest(published.entries[0].commit))
        let final = try signedPage(entries: Array(published.entries.dropFirst()), after: .checkpoint(firstCheckpoint), snapshot: published.snapshotHead, terminal: true)
        let transport = RestartingHistoryTransport(first: try AccountWireCodec.encodeTrustStatePage(first), final: try AccountWireCodec.encodeTrustStatePage(final))
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.HistoryRestart")
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore(clock: Date(timeIntervalSince1970: 1_785_751_680)))
        let credentials = try AccountSessionCredentials(accountID: published.accountID, deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access-token", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        let applying = RecordingHistoryApplier()
        _ = try await client.synchronizeTrustHistory(credentials: credentials, device: store.loadOrCreateDeviceIdentity(), applying: applying, now: Date(timeIntervalSince1970: 1_785_751_680))
        let completedCount = await applying.acceptedCount()
        let targets = await transport.requestTargets()
        XCTAssertEqual(completedCount, 3)
        XCTAssertEqual(targets.first, "/v1/trust/chain?after=genesis&limit=32")
        XCTAssertTrue(targets[1].hasPrefix("/v1/trust/chain?cursor="))
        XCTAssertTrue(targets[2].hasPrefix("/v1/trust/chain?afterEpoch=1&afterRevision=1&afterCommitDigest="))

        let cancelled = RecordingHistoryApplier()
        let cancelTransport = CancellingAfterFirstHistoryTransport(first: try AccountWireCodec.encodeTrustStatePage(first))
        let cancelClient = try AccountAPIClient(transport: cancelTransport, credentialStore: store, manifestStore: try manifestStore(clock: Date(timeIntervalSince1970: 1_785_751_680)))
        await XCTAssertThrowsErrorAsync { _ = try await cancelClient.synchronizeTrustHistory(credentials: credentials, device: store.loadOrCreateDeviceIdentity(), applying: cancelled, now: Date(timeIntervalSince1970: 1_785_751_680)) }
        let cancelledCount = await cancelled.acceptedCount()
        XCTAssertEqual(cancelledCount, 1)
    }

    func testProductionEndpointIsFixedHTTPSAuthority() throws {
        XCTAssertEqual(AccountAPIClient.productionBaseURL.absoluteString, "https://plainpost-api.olhapi.com")
    }

    func testRealURLSessionTransportMapsHTTP423ToSuspended() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedAccountHTTPURLProtocol.self]
        let transport = URLSessionAccountHTTPTransport(configuration: configuration)
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.Suspended")
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore())
        let credentials = try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "expired", accessExpiresAt: Date(timeIntervalSince1970: 1), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        do { _ = try await client.refreshSession(credentials, device: store.loadOrCreateDeviceIdentity(), now: Date(timeIntervalSince1970: 1_786_100_000)); XCTFail("expected suspension") }
        catch let failure as AccountSessionRefreshFailure { guard case .suspended = failure else { return XCTFail("failure = \(failure)") } }
    }

    func testRefreshRequiresCanonicalAccountRefreshCredentialIDAndLiveOfflineLease() async throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let deviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let now = Date(timeIntervalSince1970: 1_786_100_000)
        let validBody: @Sendable (String, String) -> Data = { refreshID, leaseExpiry in
            try! JSONSerialization.data(withJSONObject: [
                "kind": "account.session-refresh.v1",
                "accessToken": "rotated-access",
                "accessExpiresAt": "2026-08-03T12:10:00Z",
                "refreshCredential": AccountWireCodec.encodeBase64URL(Data(repeating: 2, count: 32)),
                "refreshCredentialID": refreshID,
                "refreshExpiresAt": "2026-09-03T12:10:00Z",
                "offlineLease": "rotated-lease",
                "offlineLeaseExpiresAt": leaseExpiry,
            ], options: [.sortedKeys, .withoutEscapingSlashes])
        }
        for (refreshID, leaseExpiry) in [
            ("not-an-account-id", "2026-09-03T12:10:00Z"),
            (accountID.rawValue, "2026-08-03T11:59:59Z"),
        ] {
            let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.RefreshValidation.\(UUID().uuidString)")
            let transport = RecordingAccountTransport { _ in
                AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: validBody(refreshID, leaseExpiry))
            }
            let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore())
            let credentials = try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "expired", accessExpiresAt: now.addingTimeInterval(-1), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
            do {
                _ = try await client.refreshSession(credentials, device: store.loadOrCreateDeviceIdentity(), now: now)
                XCTFail("invalid refresh response must be rejected")
            } catch let error as AccountSessionRefreshFailure {
                if case .rejected = error {} else { XCTFail("unexpected error: \(error)") }
            }
        }
    }

    func testBootstrapRejectsChallengeWithSubstitutedRequestDigestBeforeFinalize() async throws {
        var substituted = try fixtureChallenge()
        substituted["exchangeRequestDigest"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let responseBody = try JSONSerialization.data(withJSONObject: substituted)
        let transport = RecordingAccountTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/account/bootstrap/apple/begin")
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: responseBody)
        }
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests")
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try self.manifestStore())
        let identity = try store.loadOrCreateDeviceIdentity()
        await XCTAssertThrowsErrorAsync {
            _ = try await client.bootstrapAppleCredential(identityToken: "a.b.c", nonce: Data(repeating: 7, count: 32), device: identity)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(try store.loadSession())
    }

    /// After a reinstall that changed the app's bundle ID at the same path, macOS can issue
    /// the Sign in with Apple token for the old app. Central would reject it with no detail;
    /// the client refuses it before sending anything, with an error that names both apps.
    func testBootstrapRefusesATokenAppleIssuedForAnotherAppWithoutSending() async throws {
        func token(audience: String) -> String {
            let payload = Data(#"{"iss":"https://appleid.apple.com","aud":"\#(audience)"}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "header.\(payload).signature"
        }
        let transport = RecordingAccountTransport { _ in
            AccountHTTPResponse(statusCode: 401, headers: ["content-type": "application/problem+json"], body: Data("{}".utf8))
        }
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.Audience")
        let client = try AccountAPIClient(
            transport: transport, credentialStore: store, manifestStore: try self.manifestStore(),
            appleAudience: "com.marynavdovenko.Plainpost"
        )
        let identity = try store.loadOrCreateDeviceIdentity()

        do {
            _ = try await client.bootstrapAppleCredential(
                identityToken: token(audience: "com.olhapi.Plainpost"), nonce: Data(repeating: 7, count: 32), device: identity
            )
            XCTFail("A token for another app must not be sent")
        } catch let error as AppleSignInIssuedForAnotherApp {
            XCTAssertEqual(error, AppleSignInIssuedForAnotherApp(issuedFor: "com.olhapi.Plainpost", runningApp: "com.marynavdovenko.Plainpost"))
        }
        let refusedCount = await transport.requestCount()
        XCTAssertEqual(refusedCount, 0)

        // The right app's token goes to Central as before.
        await XCTAssertThrowsErrorAsync {
            _ = try await client.bootstrapAppleCredential(
                identityToken: token(audience: "com.marynavdovenko.Plainpost"), nonce: Data(repeating: 7, count: 32), device: identity
            )
        }
        let sentCount = await transport.requestCount()
        XCTAssertEqual(sentCount, 1)
    }

    func testAppleTokenAudienceReadsTheClaimAndOnlyAnAppIsChecked() throws {
        let payload = Data(#"{"aud":"com.example.App"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "h.\(payload).s"
        XCTAssertEqual(AppleIdentityTokenAudience.audience(of: token), "com.example.App")
        XCTAssertNil(AppleIdentityTokenAudience.audience(of: "a.b.c"))
        XCTAssertNil(AppleIdentityTokenAudience.audience(of: "not-a-jwt"))
        XCTAssertNoThrow(try AppleIdentityTokenAudience.requireIssued(to: "com.example.App", identityToken: token))
        XCTAssertNoThrow(try AppleIdentityTokenAudience.requireIssued(to: nil, identityToken: token))
        XCTAssertNoThrow(try AppleIdentityTokenAudience.requireIssued(to: "com.example.Other", identityToken: "a.b.c"))
        XCTAssertThrowsError(try AppleIdentityTokenAudience.requireIssued(to: "com.example.Other", identityToken: token))
        // Tests run outside an app bundle, so the default client never checks.
        XCTAssertNil(AppleIdentityTokenAudience.runningApp)
    }

    func testBootstrapRejectsBadStatusContentTypeAndOversizedResponseWithoutPersisting() async throws {
        for response in [
            AccountHTTPResponse(statusCode: 302, headers: ["content-type": "application/json"], body: Data("{}".utf8)),
            AccountHTTPResponse(statusCode: 200, headers: ["content-type": "text/html"], body: Data("{}".utf8)),
            AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: Data(repeating: 0, count: AccountWireCodec.maxBodyBytes + 1)),
        ] {
            let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.\(UUID().uuidString)")
            let transport = RecordingAccountTransport { _ in response }
            let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try self.manifestStore())
            let identity = try store.loadOrCreateDeviceIdentity()
            await XCTAssertThrowsErrorAsync { _ = try await client.bootstrapAppleCredential(identityToken: "a.b.c", nonce: Data(repeating: 7, count: 32), device: identity) }
            XCTAssertNil(try store.loadSession())
        }
    }

    func testBootstrapPropagatesCancellationWithoutSavingSession() async throws {
        let store = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.Cancellation")
        let client = try AccountAPIClient(transport: CancelledAccountTransport(), credentialStore: store, manifestStore: try manifestStore())
        let identity = try store.loadOrCreateDeviceIdentity()
        await XCTAssertThrowsErrorAsync { _ = try await client.bootstrapAppleCredential(identityToken: "a.b.c", nonce: Data(repeating: 7, count: 32), device: identity) }
        XCTAssertNil(try store.loadSession())
    }

    private func manifestStore(clock: Date = Date(timeIntervalSince1970: 1_786_017_600)) throws -> BootstrapKeyManifestStore {
        let root = Data(base64URLEncoded: "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU")!
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/central-bootstrap-manifest-test-v1.json")
        return try BootstrapKeyManifestStore(bundledManifest: Data(contentsOf: file), offlineRootKeyID: "plainpost-root-2026-01", offlineRootPublicKey: root, secretStore: InMemoryAccountSecretStore(), clock: { clock })
    }

    private func fixtureChallenge() throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return try XCTUnwrap((object["genesisBootstrapChallenge"] as? [String: Any])?["message"] as? [String: Any])
    }
    private func fixtureRoot() throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    private func signedPage(entries: [AccountTrustHistoryEntryV1], after: AccountTrustAfterV1, snapshot: AccountTrustPageCheckpointV1, terminal: Bool) throws -> AccountTrustStatePageV1 {
        let signer = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([3]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([7]))
        let issued = "2026-08-03T10:07:00.123456789Z", expires = "2026-08-03T10:12:00.123456789Z", keyID = "pagination-2026-01", accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        func cursor(_ value: AccountTrustAfterV1) throws -> AccountTrustCursorV1 {
            let unsigned = try AccountTrustCursorV1(accountID: accountID, after: value, snapshotHead: snapshot, issuedAt: issued, expiresAt: expires, serverKeyID: keyID, signature: Data(repeating: 1, count: 64))
            return try AccountTrustCursorV1(accountID: accountID, after: value, snapshotHead: snapshot, issuedAt: issued, expiresAt: expires, serverKeyID: keyID, signature: signer.signature(for: AccountTrustTranscript.trustCursor(unsigned)))
        }
        let request = try cursor(after)
        let next: AccountTrustCursorV1?
        if terminal { next = nil }
        else {
            let last = try XCTUnwrap(entries.last?.commit)
            next = try cursor(.checkpoint(AccountTrustPageCheckpointV1(epoch: last.state.epoch, revision: last.state.revision, commitDigest: AccountTranscript.trustCommitDigest(last))))
        }
        let unsigned = try AccountTrustStatePageV1(requestCursor: request, accountID: accountID, snapshotHead: snapshot, entries: entries, nextCursor: next, terminal: terminal, issuedAt: issued, expiresAt: expires, serverKeyID: keyID, serverSignature: Data(repeating: 1, count: 64))
        return try AccountTrustStatePageV1(requestCursor: request, accountID: accountID, snapshotHead: snapshot, entries: entries, nextCursor: next, terminal: terminal, issuedAt: issued, expiresAt: expires, serverKeyID: keyID, serverSignature: signer.signature(for: AccountTrustTranscript.trustStatePage(unsigned)))
    }
}

private actor RecordingHistoryApplier: AccountTrustHistoryApplying {
    private var entries: [AccountTrustHistoryEntryV1] = []
    func currentTrustCommit() -> TrustStateCommitV1? { entries.last?.commit }
    func acceptHistory(_ values: [AccountTrustHistoryEntryV1]) { entries += values }
    func acceptedCount() -> Int { entries.count }
}

private actor RestartingHistoryTransport: AccountHTTPTransport {
    let first: Data, final: Data
    var step = 0, targets: [String] = []
    init(first: Data, final: Data) { self.first = first; self.final = final }
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        let target = request.url!.path + "?" + (request.url!.query ?? "")
        if step == 0 { targets.append(target); step += 1; return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: first) }
        if step == 1 { targets.append(target); step += 1; return AccountHTTPResponse(statusCode: 409, headers: ["content-type": "application/problem+json"], body: Data("{}".utf8)) }
        targets.append(target); step += 1
        return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: final)
    }
    func requestTargets() -> [String] { targets }
}

private actor CancellingAfterFirstHistoryTransport: AccountHTTPTransport {
    let first: Data; var step = 0
    init(first: Data) { self.first = first }
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse { defer { step += 1 }; if step == 0 { return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: first) }; throw CancellationError() }
}

private actor RecordingAccountTransport: AccountHTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> AccountHTTPResponse
    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        requests.append(request)
        return try handler(request)
    }
    func requestCount() -> Int { requests.count }
}

private actor RetryingDeletionTransport: AccountHTTPTransport {
    let response: Data
    var bodies: [Data] = []
    init(response: Data) { self.response = response }
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        if bodies.count == 1 { throw AccountRuntimeError.transportFailure }
        return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: response)
    }
    func requestBodies() -> [Data] { bodies }
}

private actor CancelledAccountTransport: AccountHTTPTransport {
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse { throw CancellationError() }
}

private final class AccountHTTPURLProtocol: URLProtocol {
    static let body = Data(repeating: 0x61, count: AccountAPIClient.maximumTransportResponseBytes + 1)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class InventoryOversizedAccountHTTPURLProtocol: URLProtocol {
    private static let body = Data(repeating: 0x61, count: AccountWireCodec.maxRecordInventoryBodyBytes + 1)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SuspendedAccountHTTPURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { let response = HTTPURLResponse(url: request.url!, statusCode: 423, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/problem+json"])!; client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() {}
}

private extension Data {
    init?(base64URLEncoded value: String) {
        self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
