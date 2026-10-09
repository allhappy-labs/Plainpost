import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport
@testable import PlainpostNotificationRuntime

private actor RegistrationRefreshTransport: AccountHTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> AccountHTTPResponse
    private let handler: Handler
    private var count = 0

    init(handler: @escaping Handler) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        count += 1
        return try handler(request)
    }

    func requestCount() -> Int { count }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw AccountRuntimeError.untrustedResponse }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw AccountRuntimeError.untrustedResponse }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

@MainActor
final class NotificationRegistrationTests: XCTestCase {
    func testDirectRegistrationMaterializesAbsentRichDefaultBeforeClaimingRegistered() async throws {
        let remote = DirectRegistrationPolicyRemote()
        let mailbox = LogicalMailboxID(rawValue: Data(repeating: 0x40, count: 32))!
        let producer = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: mailbox.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32)
        )
        let assignmentRemote = NotificationAssignmentPolicyRemote(
            assignments: { [assignment] }, direct: remote, syncNode: DirectConflictPolicyRemote()
        )
        let model = try makeModel(
            trust: try NotificationTrustSnapshot(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                epoch: 1, revision: 1, trustHead: Data(repeating: 0x40, count: 32)
            ), permission: AlwaysAuthorizedNotificationPermission(), attest: RecordingAppAttest(keyID: "materialize-key"),
            policyDefaultPersistence: { mode in try await assignmentRemote.persistDefaultPolicy(mode: mode) }
        )
        await model.configure()
        let requests = await remote.requestsSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].expectedVersion, "0")
        XCTAssertEqual(model.status, .registered)
    }

    func testDirectRegistrationDoesNotClaimRegisteredWhenAssignmentMaterializationLeavesV0() async throws {
        let remote = DirectRegistrationPolicyRemote(materializes: false)
        let mailbox = LogicalMailboxID(rawValue: Data(repeating: 0x45, count: 32))!
        let producer = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: mailbox.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32)
        )
        let assignmentRemote = NotificationAssignmentPolicyRemote(
            assignments: { [assignment] }, direct: remote, syncNode: DirectConflictPolicyRemote()
        )
        let model = try makeModel(
            trust: try NotificationTrustSnapshot(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                epoch: 1, revision: 1, trustHead: Data(repeating: 0x46, count: 32)
            ), permission: AlwaysAuthorizedNotificationPermission(), attest: RecordingAppAttest(keyID: "unchanged-v0-key"),
            policyDefaultPersistence: { mode in try await assignmentRemote.persistDefaultPolicy(mode: mode) }
        )

        await model.configure()

        XCTAssertNotEqual(model.status, .registered)
        let finalDefault = try await remote.directDefaultPolicy()
        XCTAssertEqual(finalDefault.version, "0")
    }

    func testMixedRegistrationDoesNotClaimRegisteredWhenSecondAuthorityFails() async throws {
        let direct = DirectRegistrationPolicyRemote()
        let macMailbox = LogicalMailboxID(rawValue: Data(repeating: 0x47, count: 32))!
        let nodeMailbox = LogicalMailboxID(rawValue: Data(repeating: 0x48, count: 32))!
        let macID = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let nodeID = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let assignments = [
            NotificationProducerAssignment(logicalMailboxID: macMailbox.rawValue, producerDeviceID: macID, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32)),
            NotificationProducerAssignment(logicalMailboxID: nodeMailbox.rawValue, producerDeviceID: nodeID, kind: .syncNode, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 2, count: 32))
        ]
        let assignmentRemote = NotificationAssignmentPolicyRemote(
            assignments: { assignments }, direct: direct, syncNode: FailingDefaultPolicyRemote()
        )
        let model = try makeModel(
            trust: try NotificationTrustSnapshot(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                epoch: 1, revision: 1, trustHead: Data(repeating: 0x49, count: 32)
            ), permission: AlwaysAuthorizedNotificationPermission(), attest: RecordingAppAttest(keyID: "mixed-authority-failure-key"),
            policyDefaultPersistence: { mode in try await assignmentRemote.persistDefaultPolicy(mode: mode) }
        )

        await model.configure()

        XCTAssertNotEqual(model.status, .registered)
        let directRequests = await direct.requestsSnapshot()
        XCTAssertEqual(directRequests.count, 1)
    }

    func testRegistrationFallbackVerifiesPositiveMutationAndFinalRead() async throws {
        let remote = RecordingPolicyRemote()
        let model = try makeModel(
            trust: try NotificationTrustSnapshot(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                epoch: 1, revision: 1, trustHead: Data(repeating: 0x41, count: 32)
            ), permission: AlwaysAuthorizedNotificationPermission(), attest: RecordingAppAttest(keyID: "verify-key"),
            policyRemoteFactory: { _ in remote }
        )
        model.setPreviewPolicy(.generic)
        await model.configure()

        XCTAssertEqual(model.status, .registered)
        let requests = await remote.requestsSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].expectedVersion, "1")
    }

    func testConfigureCancellationDoesNotPublishDegradedUnavailable() async throws {
        let model = try NotificationRegistrationModel(
            trust: { throw CancellationError() },
            identitySignature: { _ in Data(repeating: 0x77, count: 64) },
            permission: AlwaysAuthorizedNotificationPermission(),
            apns: FixedAPNSTokenProvider(token: Data(repeating: 0xC4, count: 32)),
            attest: RecordingAppAttest(keyID: "cancel-key"),
            remote: RecordingNotificationRemote(challenge: Data(repeating: 0xC4, count: 32)),
            store: InMemoryNotificationRegistrationStore(), topic: "com.marynavdovenko.Plainpost.iOS", environment: .sandbox,
            mailPairingState: .unpaired
        )
        await model.configure()
        XCTAssertEqual(model.status, .registering)
    }

    func testRegistrationPolicyRemoteFactoryCanSelectDirectAuthorityPerMailbox() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x3A, count: 32)
        )
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x3B, count: 32)))
        let remote = RecordingPolicyRemote()
        let model = try makeModel(
            trust: trust,
            permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "direct-policy-key"),
            policyRemoteFactory: { logicalMailboxID in
                XCTAssertEqual(logicalMailboxID, mailbox)
                return remote
            }
        )

        try await model.setPreviewPolicy(.generic, for: mailbox)

        let requests = await remote.requestsSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].mode, .generic)
        XCTAssertEqual(requests[0].expectedVersion, "1")
    }

    func testDirectMailboxRegistrationUsesRetainedScopeVersionAsCASPredecessor() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x3C, count: 32)
        )
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x3D, count: 32)))
        let remote = DirectMailboxRegistrationPolicyRemote(mailbox: mailbox)
        let producer = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: mailbox.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32)
        )
        let assignmentRemote = NotificationAssignmentPolicyRemote(
            assignments: { [assignment] }, direct: remote, syncNode: DirectConflictPolicyRemote()
        )
        let model = try makeModel(
            trust: trust,
            permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "direct-scope-key"),
            policyRemoteFactory: { _ in assignmentRemote }
        )

        try await model.setPreviewPolicy(.generic, for: mailbox)

        let requests = await remote.requestsSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].expectedVersion, "4")
        XCTAssertEqual(requests[0].logicalMailboxID, mailbox)
    }

    func testSharedPPR2FixtureMatchesSwiftWireTranscriptAndPPN2Version() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = root.appendingPathComponent("Protocol/node-notification-v1/fixtures/envelope-v1.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let ppr2 = try XCTUnwrap(document["ppr2"] as? [String: Any])
        let account = try PlainpostAccountID(XCTUnwrap(ppr2["account_uuid"] as? String))
        let device = try AccountDeviceID(XCTUnwrap(ppr2["recipient_device_uuid"] as? String))
        let mailbox = try XCTUnwrap(Data(hex: XCTUnwrap(ppr2["logical_mailbox_hex"] as? String)))
        let route = try XCTUnwrap(Data(hex: XCTUnwrap(ppr2["routing_handle_hex"] as? String)))
        let head = try XCTUnwrap(Data(hex: XCTUnwrap(ppr2["trust_head_hex"] as? String)))
        let agreement = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(ppr2["agreement_public_key_base64"] as? String)))
        let signature = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(ppr2["signature_base64"] as? String)))
        let generation = try XCTUnwrap((ppr2["assignment_generation"] as? NSNumber)?.uint64Value)
        let epoch = try XCTUnwrap((ppr2["trust_epoch"] as? NSNumber)?.uint64Value)
        let revision = try XCTUnwrap((ppr2["trust_revision"] as? NSNumber)?.uint64Value)
        let record = try NotificationRecipientRegistration(
            accountID: account, deviceID: device, epoch: epoch, revision: revision,
            trustHead: head, routingHandle: route, agreementPublicKey: agreement,
            deviceSignature: signature, logicalMailboxID: mailbox, assignmentGeneration: generation
        )

        XCTAssertEqual(record.signedRecord.count, 285)
        XCTAssertEqual(record.signedRecord, try XCTUnwrap(Data(base64Encoded: XCTUnwrap(ppr2["record_base64"] as? String))))
        XCTAssertEqual(record.signingTranscript, try XCTUnwrap(Data(base64Encoded: XCTUnwrap(ppr2["transcript_base64"] as? String))))
        let signingKey = try P256.Signing.PublicKey(x963Representation: try XCTUnwrap(Data(base64Encoded: XCTUnwrap(ppr2["signing_public_key_base64"] as? String))))
        let rawSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(signingKey.isValidSignature(rawSignature, for: record.signingTranscript))

        let outer = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(document["wire_base64"] as? String)))
        XCTAssertGreaterThanOrEqual(outer.count, 5)
        XCTAssertEqual(Data(outer.prefix(4)), Data("PPN2".utf8))
        XCTAssertEqual(outer[4], 2)
    }

    func testPPR2RecipientRecordBindsMailboxAndGenerationInExactWireAndTranscript() throws {
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let device = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let mailbox = Data(repeating: 0x31, count: 32)
        let route = Data(repeating: 0x41, count: 32)
        let agreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let signature = Data(repeating: 0x51, count: 64)
        let record = try NotificationRecipientRegistration(
            accountID: account, deviceID: device, epoch: 7, revision: 8,
            trustHead: Data(repeating: 0x21, count: 32), routingHandle: route,
            agreementPublicKey: agreement, deviceSignature: signature,
            logicalMailboxID: mailbox, assignmentGeneration: 9
        )
        XCTAssertEqual(record.signedRecord.count, 285)
        XCTAssertEqual(record.signedRecord.prefix(4), Data("PPR2".utf8))
        XCTAssertEqual(Data(record.signedRecord[36..<68]), mailbox)
        XCTAssertEqual(Data(record.signedRecord[68..<76]), Data([0, 0, 0, 0, 0, 0, 0, 9]))
        XCTAssertEqual(
            record.signingTranscript,
            frame([
                Data("Plainpost.NotificationRecipientRegistration.v1".utf8), uuidBytes(account.rawValue), uuidBytes(device.rawValue),
                mailbox, u64(9), u64(7), u64(8), Data(repeating: 0x21, count: 32), route, agreement
            ])
        )
    }

    func testDelayedRegistrationRefreshesExpiredSessionBeforeChallenge() async throws {
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let device = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let secretStore = InMemoryAccountSecretStore()
        let credentialStore = AccountCredentialStore(secretStore: secretStore, service: "com.marynavdovenko.Plainpost.AccountTests.NotificationRefresh")
        let expired = try AccountSessionCredentials(
            accountID: account, deviceID: device, accessToken: "expired",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshCredential: Data(repeating: 0x11, count: 32), offlineLease: "lease-old"
        )
        try credentialStore.saveSession(AccountSession(credentials: expired))
        let identity = try credentialStore.loadOrCreateDeviceIdentity()
        let transport = RegistrationRefreshTransport { request in
            switch request.url?.path {
            case "/v1/sessions/refresh":
                return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: [
                    "kind": "account.session-refresh.v1", "accessToken": "rotated",
                    "accessExpiresAt": "2999-01-01T00:00:00Z",
                    "refreshCredential": AccountWireCodec.encodeBase64URL(Data(repeating: 0x22, count: 32)),
                    "refreshCredentialID": account.rawValue, "refreshExpiresAt": "2999-01-01T00:00:00Z",
                    "offlineLease": "lease-new", "offlineLeaseExpiresAt": "2999-01-01T00:00:00Z"
                ], options: [.sortedKeys, .withoutEscapingSlashes]))
            case "/v1/notifications/registrations/challenge":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
                return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: Data(#"{"kind":"ios.notification-registration-challenge.v1","challenge":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"}"#.utf8))
            default:
                throw AccountRuntimeError.untrustedResponse
            }
        }
        let api = try AccountAPIClient(transport: transport, credentialStore: credentialStore, manifestStore: BootstrapKeyManifestStore(secretStore: secretStore))
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-registration-refresh-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let session = NotificationAccountSession(api: api, store: credentialStore, refreshLockURL: lockURL)
        let remote = AccountNotificationRegistrationRemote(client: api, credentials: expired, device: identity, currentSession: {
            let current = try await session.current()
            return (current.credentials, current.device)
        })

        let challenge = try await remote.issueChallenge()
        XCTAssertEqual(challenge, Data(repeating: 1, count: 32))
        let requests = await transport.requestCount()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(try credentialStore.loadSession()?.credentials?.accessToken, "rotated")
    }

    func testRecoveryActionsNameTheStateSpecificUserOperation() {
        XCTAssertEqual(NotificationRegistrationStatus.degraded(.permissionDenied).recoveryAction, .openSettings)
        XCTAssertEqual(NotificationRegistrationStatus.unavailable(.noActiveProducer).recoveryAction, .selectProducer)
        XCTAssertEqual(NotificationRegistrationStatus.degraded(.reapprovalRequired).recoveryAction, .reapprove)
        XCTAssertEqual(NotificationRegistrationStatus.degraded(.tokenInvalid).recoveryAction, .refreshToken)
        XCTAssertEqual(NotificationRegistrationStatus.degraded(.relayUnavailable).recoveryAction, .retry)
        XCTAssertNil(NotificationRegistrationStatus.unavailable(.appAttestUnsupported).recoveryAction)
    }

    func testRegistrationAttestsExactClientDataAndTransfersOpaqueRecipient() async throws {
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let device = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let trust = try NotificationTrustSnapshot(
            accountID: account, deviceID: device, epoch: 2, revision: 7,
            trustHead: Data(repeating: 0x21, count: 32)
        )
        let attest = RecordingAppAttest(keyID: "app-key-1", attestation: Data(repeating: 0xA5, count: 8192))
        let challenge = Data(repeating: 0xC1, count: 32)
        let remote = RecordingNotificationRemote(challenge: challenge)
        let transfer = RecordingRecipientTransfer()
        let store = InMemoryNotificationRegistrationStore()
        let model = try await MainActor.run {
            try NotificationRegistrationModel(
                trust: { trust },
                identitySignature: { Data(SHA256.hash(data: $0)) + Data(repeating: 0x44, count: 32) },
                permission: AlwaysAuthorizedNotificationPermission(),
                apns: FixedAPNSTokenProvider(token: Data(repeating: 0xA1, count: 32)),
                attest: attest,
                remote: remote,
                transfer: transfer,
                store: store,
                topic: "com.marynavdovenko.Plainpost.iOS",
                environment: .sandbox,
                mailPairingState: .paired
            )
        }

        await model.configure()

        let recordedRequest = await remote.currentAttestation()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.accountID, account)
        XCTAssertEqual(request.deviceID, device)
        XCTAssertEqual(request.topic, "com.marynavdovenko.Plainpost.iOS")
        XCTAssertEqual(request.environment, NotificationEnvironment.sandbox)
        XCTAssertEqual(request.appAttestKeyID, "app-key-1")
        XCTAssertEqual(request.attestationObject.count, 8192)
        XCTAssertFalse(request.clientData.isEmpty)
        XCTAssertFalse(request.clientData.contains(Data("PRIVATE".utf8)))
        let attestedHashes = await attest.attestedHashesSnapshot()
        let transferCount = await transfer.count()
        XCTAssertEqual(attestedHashes, [Data(SHA256.hash(data: request.clientData))])
        XCTAssertEqual(transferCount, 1)
        XCTAssertEqual(model.status, NotificationRegistrationStatus.registered)
        XCTAssertEqual(model.mailPairingState, NotificationMailPairingState.paired)
        XCTAssertEqual(try store.load(.agreementPrivateKey)?.count, 32)
        XCTAssertEqual(String(data: try store.load(.attestKeyID) ?? Data(), encoding: .utf8), "app-key-1")
        XCTAssertTrue((try store.load(.agreementPublicKey))?.count == 65)
        let clientDataText = String(decoding: request.clientData, as: UTF8.self)
        XCTAssertFalse(clientDataText.contains(String(decoding: challenge, as: UTF8.self)))
        XCTAssertTrue(clientDataText.contains(AccountWireCodec.encodeBase64URL(challenge)))
        XCTAssertTrue(clientDataText.contains("app-key-1"))
    }

    func testDirectModeRegistrationUploadsSignedRecipientAndPersistsExtensionAuthority() async throws {
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let device = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let trust = try NotificationTrustSnapshot(
            accountID: account, deviceID: device, epoch: 4, revision: 11,
            trustHead: Data(repeating: 0xA1, count: 32)
        )
        let store = InMemoryNotificationRegistrationStore()
        let uploader = RecordingRecipientUploader()
        let model = try await MainActor.run {
            try NotificationRegistrationModel(
                trust: { trust },
                identitySignature: { _ in Data(repeating: 0xB2, count: 64) },
                permission: AlwaysAuthorizedNotificationPermission(),
                apns: FixedAPNSTokenProvider(token: Data(repeating: 0xC3, count: 32)),
                attest: RecordingAppAttest(keyID: "direct-mode-key"),
                remote: RecordingNotificationRemote(challenge: Data(repeating: 0xD4, count: 32)),
                recipientUploader: uploader,
                recipientCoordinates: {
                    [(logicalMailboxID: Data(repeating: 0xE5, count: 32), assignmentGeneration: UInt64(13))]
                },
                store: store,
                topic: "com.marynavdovenko.Plainpost.iOS",
                environment: .sandbox,
                mailPairingState: .unpaired
            )
        }

        await model.configure()

        let registrationValue = await uploader.registration()
        let registration = try XCTUnwrap(registrationValue)
        XCTAssertEqual(registration.signedRecord.count, 285)
        XCTAssertEqual(Data(registration.signedRecord[36..<68]), Data(repeating: 0xE5, count: 32))
        XCTAssertEqual(try store.load(.recipientDeviceID), Data(device.rawValue.utf8))
        XCTAssertEqual(try store.load(.trustEpoch), Data([0, 0, 0, 0, 0, 0, 0, 4]))
        XCTAssertEqual(try store.load(.trustRevision), Data([0, 0, 0, 0, 0, 0, 0, 11]))
        XCTAssertEqual(try store.load(.trustHead), Data(repeating: 0xA1, count: 32))
        XCTAssertEqual(model.status, NotificationRegistrationStatus.registered)

        model.setPreviewPolicy(.senderAndSubject)
        XCTAssertEqual(model.status, NotificationRegistrationStatus.degraded(.unavailable))
    }

    func testEmptyAuthoritativeRecipientCoordinatesRemainNoActiveProducer() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 4, revision: 11, trustHead: Data(repeating: 0xA1, count: 32)
        )
        let store = InMemoryNotificationRegistrationStore()
        let uploader = RecordingRecipientUploader()
        let model = try await MainActor.run {
            try NotificationRegistrationModel(
                trust: { trust }, identitySignature: { _ in Data(repeating: 0xB2, count: 64) },
                permission: AlwaysAuthorizedNotificationPermission(),
                apns: FixedAPNSTokenProvider(token: Data(repeating: 0xC3, count: 32)),
                attest: RecordingAppAttest(keyID: "empty-coordinate-key"),
                remote: RecordingNotificationRemote(challenge: Data(repeating: 0xD4, count: 32)),
                recipientUploader: uploader, recipientCoordinates: { [] }, store: store,
                topic: "com.marynavdovenko.Plainpost.iOS", environment: .sandbox, mailPairingState: .unpaired
            )
        }

        await model.configure()

        XCTAssertEqual(model.status, NotificationRegistrationStatus.degraded(.noActiveProducer))
        let registration = await uploader.registration()
        XCTAssertNil(registration)
        XCTAssertNil(try store.load(.routingHandle))
    }

    func testRetryReloadsRotatedTrustForRecipientAndExtensionContext() async throws {
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let recipient = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let producer = try AccountDeviceID("66666666-7777-4888-8999-aaaaaaaaaaaa")
        let first = try NotificationTrustSnapshot(
            accountID: account, deviceID: recipient, epoch: 1, revision: 1,
            trustHead: Data(repeating: 0x31, count: 32)
        )
        let rotated = try NotificationTrustSnapshot(
            accountID: account, deviceID: recipient, epoch: 2, revision: 3,
            trustHead: Data(repeating: 0x32, count: 32)
        )
        let trustSource = RotatingNotificationTrustSource(first)
        let mailbox = Data(repeating: 0x45, count: 32)
        let store = InMemoryNotificationRegistrationStore()
        let uploader = RecordingRecipientUploader()
        let model = try NotificationRegistrationModel(
            trust: { try await trustSource.current() },
            identitySignature: { _ in Data(repeating: 0x51, count: 64) },
            permission: AlwaysAuthorizedNotificationPermission(),
            apns: FixedAPNSTokenProvider(token: Data(repeating: 0x61, count: 32)),
            attest: RecordingAppAttest(keyID: "rotating-trust-key"),
            remote: RecordingNotificationRemote(challenge: Data(repeating: 0x71, count: 32)),
            recipientUploader: uploader,
            recipientCoordinates: { [(logicalMailboxID: mailbox, assignmentGeneration: UInt64(4))] },
            recipientContexts: {
                [try NotificationRecipientProducerContext(
                    logicalMailboxID: mailbox, assignmentGeneration: 4,
                    producerDeviceID: producer,
                    producerSigningPublicKey: P256.Signing.PrivateKey().publicKey.x963Representation
                )]
            },
            store: store, topic: "com.marynavdovenko.Plainpost.iOS", environment: .sandbox,
            mailPairingState: .unpaired
        )

        await model.configure()
        await trustSource.set(rotated)
        await model.retry()

        let uploadedValue = await uploader.registration()
        let uploaded = try XCTUnwrap(uploadedValue)
        XCTAssertEqual(uploaded.epoch, 2)
        XCTAssertEqual(uploaded.revision, 3)
        XCTAssertEqual(uploaded.trustHead, rotated.trustHead)
        let encodedContexts = try XCTUnwrap(store.load(.mailboxContexts))
        let contexts = try JSONDecoder().decode([NotificationMailboxContextRecord].self, from: encodedContexts)
        XCTAssertEqual(contexts.first?.trustEpoch, 2)
        XCTAssertEqual(contexts.first?.trustRevision, 3)
        XCTAssertEqual(contexts.first?.trustHead, rotated.trustHead)
    }

    func testPersistedRegistrationRestoresAndReRegistersAfterLaunch() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x28, count: 32)
        )
        let store = InMemoryNotificationRegistrationStore()
        let privateKey = P256.KeyAgreement.PrivateKey()
        try store.save(privateKey.rawRepresentation, for: .agreementPrivateKey)
        try store.save(privateKey.publicKey.x963Representation, for: .agreementPublicKey)
        try store.save(Data("persisted-attest".utf8), for: .attestKeyID)
        try store.save(Data(repeating: 0xAB, count: 32), for: .routingHandle)
        try store.save(Data("registered".utf8), for: .registrationState)
        let remote = RecordingNotificationRemote(challenge: Data(repeating: 0xD1, count: 32))
        let model = try makeModel(
            trust: trust, permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "persisted-attest"), remote: remote,
            mailPairingState: .paired, store: store
        )

        XCTAssertEqual(model.status, .registered)
        XCTAssertTrue(model.needsLaunchReconciliation)
        await model.reconcileOnLaunch()

        XCTAssertEqual(model.status, .registered)
        XCTAssertFalse(model.needsLaunchReconciliation)
        let assertionCount = await remote.assertions().count
        XCTAssertEqual(assertionCount, 1)
    }

    func testExistingKeyUsesAssertionAndTokenReplacementWithoutTouchingMailPairing() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x22, count: 32)
        )
        let store = InMemoryNotificationRegistrationStore()
        try store.save(Data(repeating: 0x08, count: 32), for: .agreementPrivateKey)
        try store.save(Data(repeating: 0x09, count: 65), for: .agreementPublicKey)
        try store.save(Data("existing-attest".utf8), for: .attestKeyID)
        let attest = RecordingAppAttest(keyID: "existing-attest")
        let remote = RecordingNotificationRemote(challenge: Data(repeating: 0xC2, count: 32))
        let model = try await MainActor.run {
            try NotificationRegistrationModel(
                trust: { trust }, identitySignature: { _ in Data(repeating: 0x55, count: 64) },
                permission: AlwaysAuthorizedNotificationPermission(),
                apns: FixedAPNSTokenProvider(token: Data(repeating: 0xB2, count: 48)), attest: attest,
                remote: remote, transfer: RecordingRecipientTransfer(), store: store,
                topic: "com.marynavdovenko.Plainpost.iOS", environment: .production, mailPairingState: .paired
            )
        }
        await model.configure()

        let generatedKeyCount = await attest.generatedKeyCountSnapshot()
        let assertionCount = await attest.assertionCount()
        XCTAssertEqual(generatedKeyCount, 0)
        XCTAssertEqual(assertionCount, 1)
        XCTAssertEqual(model.status, NotificationRegistrationStatus.registered)
        XCTAssertEqual(model.mailPairingState, NotificationMailPairingState.paired)
        XCTAssertEqual(try store.load(.agreementPrivateKey), Data(repeating: 0x08, count: 32))
    }

    func testAttestationResponseLossRetriesExactPendingProofBeforeAnyAssertion() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x27, count: 32)
        )
        let store = InMemoryNotificationRegistrationStore()
        let attest = RecordingAppAttest(keyID: "durable-attest", attestation: Data(repeating: 0xD7, count: 4096))
        let remote = RecordingNotificationRemote(challenge: Data(repeating: 0xD8, count: 32), attestationFailuresRemaining: 1)
        let model = try makeModel(trust: trust, permission: AlwaysAuthorizedNotificationPermission(), attest: attest, remote: remote, mailPairingState: .paired, store: store)

        await model.configure()
        XCTAssertEqual(model.status, .degraded(.relayUnavailable))
        XCTAssertNotNil(try store.load(.pendingAttestation))

        await model.retry()
        XCTAssertEqual(model.status, .registered)
        let attestations = await remote.attestations()
        XCTAssertEqual(attestations.count, 2)
        XCTAssertEqual(attestations[0], attestations[1])
        let generatedKeyCount = await attest.generatedKeyCountSnapshot()
        let assertionCount = await attest.assertionCount()
        XCTAssertEqual(generatedKeyCount, 1)
        XCTAssertEqual(assertionCount, 0)
        XCTAssertNil(try store.load(.pendingAttestation))
    }

    func testRetryAutomaticallyBoundsTemporaryRelayFailureAndConverges() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x29, count: 32)
        )
        let remote = RecordingNotificationRemote(
            challenge: Data(repeating: 0xD8, count: 32), attestationFailuresRemaining: 1
        )
        let model = try makeModel(
            trust: trust, permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "bounded-retry-key"), remote: remote,
            mailPairingState: .paired
        )

        await model.retry()

        XCTAssertEqual(model.status, .registered)
        let attestations = await remote.attestations()
        XCTAssertEqual(attestations.count, 2)
    }

    func testRegistrationExposesReapprovalRequiredForAuthenticatedNodeConflict() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x2C, count: 32)
        )
        let model = try makeModel(
            trust: trust, permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "reapproval-key"),
            remote: FailingNotificationRemote(error: NodeSyncClientError.conflict),
            mailPairingState: .paired
        )

        await model.configure()

        XCTAssertEqual(model.status, .degraded(.reapprovalRequired))
        XCTAssertEqual(model.mailPairingState, .paired)
    }

    func testRegistrationExposesReapprovalRequiredForDirectPolicyConflict() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x2D, count: 32)
        )
        let model = try makeModel(
            trust: trust, permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "direct-reapproval-key"),
            policyRemoteFactory: { _ in DirectConflictPolicyRemote() }
        )

        await model.configure()

        XCTAssertEqual(model.status, .degraded(.reapprovalRequired))
    }

    func testCancellationDoesNotRegisterOrChangeMailPairing() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x25, count: 32)
        )
        let remote = RecordingNotificationRemote(challenge: Data(repeating: 0xCC, count: 16))
        let model = try makeModel(trust: trust, permission: AlwaysAuthorizedNotificationPermission(), attest: RecordingAppAttest(keyID: "cancel-key"), apns: BlockingAPNSTokenProvider(), remote: remote, mailPairingState: .paired)
        let task = Task { await model.configure() }
        while model.status != .registering { await Task.yield() }
        task.cancel()
        await task.value

        // Cancellation leaves the superseded registering operation's state
        // untouched; it must not be remapped to degraded unavailable.
        XCTAssertEqual(model.status, NotificationRegistrationStatus.registering)
        XCTAssertEqual(model.mailPairingState, NotificationMailPairingState.paired)
        let registration = await remote.currentAttestation()
        XCTAssertNil(registration)
    }

    func testDuplicateTokenCallbacksUseLatestTokenOnRetry() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x26, count: 32)
        )
        let remote = RecordingNotificationRemote(challenge: Data(repeating: 0xCD, count: 32))
        let model = try makeModel(trust: trust, permission: AlwaysAuthorizedNotificationPermission(), attest: RecordingAppAttest(keyID: "token-key"), apns: SequenceAPNSTokenProvider(tokens: [Data(repeating: 0x01, count: 32), Data(repeating: 0x02, count: 32)]), remote: remote, mailPairingState: .paired)

        await model.configure()
        await model.configure()

        let attestations = await remote.attestations()
        let assertions = await remote.assertions()
        XCTAssertEqual(attestations.map(\.apnsDeviceToken), [Data(repeating: 0x01, count: 32)])
        XCTAssertEqual(assertions.map(\.apnsDeviceToken), [Data(repeating: 0x02, count: 32)])
    }

    func testUnsupportedAttestAndDeniedPermissionDoNotBreakMailPairing() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x23, count: 32)
        )
        let unsupported = try makeModel(trust: trust, permission: AlwaysAuthorizedNotificationPermission(), attest: RecordingAppAttest(keyID: "", supported: false))
        await unsupported.configure()
        XCTAssertEqual(unsupported.status, NotificationRegistrationStatus.unavailable(.appAttestUnsupported))
        XCTAssertEqual(unsupported.mailPairingState, NotificationMailPairingState.unpaired)

        let denied = try makeModel(trust: trust, permission: DeniedNotificationPermission(), attest: RecordingAppAttest(keyID: "key"))
        await denied.configure()
        XCTAssertEqual(denied.status, NotificationRegistrationStatus.degraded(.permissionDenied))
        XCTAssertEqual(denied.mailPairingState, NotificationMailPairingState.unpaired)
    }

    func testPreviewPolicyPersistsBeforePermissionPromptAndOffDoesNotPrompt() async throws {
        let store = InMemoryNotificationRegistrationStore()
        let permission = CountingNotificationPermission()
        let model = try makeModel(
            trust: try NotificationTrustSnapshot(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                epoch: 1, revision: 1, trustHead: Data(repeating: 0x31, count: 32)
            ),
            permission: permission,
            attest: RecordingAppAttest(keyID: "policy-key"),
            store: store
        )
        model.setPreviewPolicy(.off)
        XCTAssertEqual(model.previewPolicy, .off)
        XCTAssertEqual(String(data: try store.load(.previewPolicy) ?? Data(), encoding: .utf8), "off")
        await model.configure()
        let permissionRequests = await permission.count()
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(model.status, .unconfigured)
    }

    func testOffPersistsGlobalNodePolicyBeforeDisablingLocalRegistration() async throws {
        let remote = RecordingPolicyRemote()
        let updater = AccountNotificationPolicyUpdater(remote: remote)
        let model = try makeModel(
            trust: try NotificationTrustSnapshot(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                epoch: 1, revision: 1, trustHead: Data(repeating: 0x32, count: 32)
            ),
            permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "off-policy-key"),
            remote: RecordingNotificationRemote(challenge: Data(repeating: 0x33, count: 32)),
            policyUpdater: updater
        )

        await model.configure()
        XCTAssertEqual(model.status, .registered)
        model.setPreviewPolicy(.off)
        for _ in 0..<20 { await Task.yield() }

        let requests = await remote.requestsSnapshot()
        XCTAssertEqual(requests.last?.mode, .off)
        XCTAssertEqual(model.status, .revoked)
    }

    func testPreviewPersistenceFailureBlocksRemoteMutationAndSurfacesDegradedState() async throws {
        let remote = RecordingPolicyRemote()
        let model = try makeModel(
            trust: try NotificationTrustSnapshot(
                accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                epoch: 1, revision: 1, trustHead: Data(repeating: 0x35, count: 32)
            ),
            permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "persistence-failure-key"),
            remote: RecordingNotificationRemote(challenge: Data(repeating: 0x36, count: 32)),
            store: FailingNotificationRegistrationStore(),
            policyUpdater: AccountNotificationPolicyUpdater(remote: remote)
        )

        await model.configure()
        model.setPreviewPolicy(.off)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(model.previewPolicy, .rich)
        XCTAssertEqual(model.status, .degraded(.unavailable))
        let requests = await remote.requestsSnapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPerMailboxPolicyOverrideAndClearUseNodeVersionFence() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x2A, count: 32)
        )
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x44, count: 32)))
        let remote = RecordingPolicyRemote()
        let model = try makeModel(
            trust: trust,
            permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "policy-key"),
            remote: RecordingNotificationRemote(challenge: Data(repeating: 0xCC, count: 32)),
            mailPairingState: .paired,
            policyUpdater: AccountNotificationPolicyUpdater(remote: remote)
        )

        try await model.setPreviewPolicy(.senderAndSubject, for: mailbox)
        try await model.clearPreviewPolicy(for: mailbox)

        let requests = await remote.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].logicalMailboxID, mailbox)
        XCTAssertEqual(requests[0].mode, .senderSubject)
        XCTAssertFalse(requests[0].clear)
        XCTAssertEqual(requests[0].expectedVersion, "1")
        XCTAssertTrue(requests[1].clear)
        XCTAssertEqual(requests[1].logicalMailboxID, mailbox)
        XCTAssertEqual(requests[1].expectedVersion, "2")
    }

    func testRetryRepeatsFailedOffPolicyWriteBeforeMarkingRevoked() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x2B, count: 32)
        )
        let remote = RecordingPolicyRemote()
        let model = try makeModel(
            trust: trust,
            permission: AlwaysAuthorizedNotificationPermission(),
            attest: RecordingAppAttest(keyID: "policy-retry-key"),
            remote: RecordingNotificationRemote(challenge: Data(repeating: 0xCD, count: 32)),
            mailPairingState: .paired,
            policyUpdater: AccountNotificationPolicyUpdater(remote: remote)
        )
        await model.configure()
        await remote.failNextUpdate()

        model.setPreviewPolicy(.off)
        for _ in 0..<50 { if model.status == .degraded(.revocationPending) { break }; await Task.yield() }
        XCTAssertEqual(model.status, .degraded(.revocationPending))

        await model.retry()

        XCTAssertEqual(model.status, .revoked)
        let lastMode = (await remote.requestsSnapshot()).last?.mode
        XCTAssertEqual(lastMode, .off)
    }

    func testRevocationRetainsOnlyRouteForRetryUntilRelaySucceeds() async throws {
        let trust = try NotificationTrustSnapshot(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            epoch: 1, revision: 1, trustHead: Data(repeating: 0x24, count: 32)
        )
        let store = InMemoryNotificationRegistrationStore()
        try store.save(Data(repeating: 0x07, count: 32), for: .agreementPrivateKey)
        try store.save(Data(repeating: 0x08, count: 65), for: .agreementPublicKey)
        try store.save(Data("attest".utf8), for: .attestKeyID)
        try store.save(Data(repeating: 0x0A, count: 32), for: .routingHandle)
        let remote = RetryingRevokeRemote(failuresRemaining: 1)
        let model = try await MainActor.run {
            try NotificationRegistrationModel(
                trust: { trust }, identitySignature: { _ in Data(repeating: 0x66, count: 64) },
                permission: AlwaysAuthorizedNotificationPermission(), apns: FixedAPNSTokenProvider(token: Data(repeating: 0xC3, count: 32)),
                attest: RecordingAppAttest(keyID: "attest"), remote: remote, transfer: RecordingRecipientTransfer(), store: store,
                topic: "com.marynavdovenko.Plainpost.iOS", environment: .sandbox, mailPairingState: .paired
            )
        }
        await model.revoke()
        XCTAssertEqual(model.status, NotificationRegistrationStatus.degraded(.revocationPending))
        XCTAssertNil(try store.load(.agreementPrivateKey))
        XCTAssertNil(try store.load(.agreementPublicKey))
        XCTAssertNil(try store.load(.attestKeyID))
        XCTAssertEqual(try store.load(.routingHandle), Data(repeating: 0x0A, count: 32))
        XCTAssertEqual(model.mailPairingState, .paired)

        await model.retry()
        XCTAssertEqual(model.status, .revoked)
        XCTAssertNil(try store.load(.routingHandle))
    }

    @MainActor
    private func makeModel(
        trust: NotificationTrustSnapshot,
        permission: any NotificationPermissionProviding,
        attest: any AppAttestProviding,
        apns: any APNSTokenProviding = FixedAPNSTokenProvider(token: Data(repeating: 0xC4, count: 32)),
        remote: any NotificationRegistrationRemote = RecordingNotificationRemote(challenge: Data(repeating: 0xC4, count: 32)),
        mailPairingState: NotificationMailPairingState = .unpaired,
        store: NotificationRegistrationStoring = InMemoryNotificationRegistrationStore(),
        policyUpdater: AccountNotificationPolicyUpdater? = nil,
        policyRemoteFactory: (@Sendable (LogicalMailboxID?) async throws -> any NotificationPolicyRemote)? = nil,
        policyDefaultPersistence: (@Sendable (NodeSyncNotificationPolicyMode) async throws -> Void)? = nil
    ) throws -> NotificationRegistrationModel {
        try NotificationRegistrationModel(
            trust: { trust }, identitySignature: { _ in Data(repeating: 0x77, count: 64) }, permission: permission,
            apns: apns, attest: attest,
            remote: remote, transfer: RecordingRecipientTransfer(),
            store: store, topic: "com.marynavdovenko.Plainpost.iOS", environment: .sandbox,
            mailPairingState: mailPairingState, policyUpdater: policyUpdater,
            policyRemoteFactory: policyRemoteFactory, policyDefaultPersistence: policyDefaultPersistence
        )
    }
}

private func uuidBytes(_ value: String) -> Data {
    var uuid = UUID(uuidString: value)!.uuid
    return withUnsafeBytes(of: &uuid) { Data($0) }
}

private func u64(_ value: UInt64) -> Data {
    Data((0..<8).map { UInt8((value >> UInt64(56 - $0 * 8)) & 0xff) })
}

private func frame(_ parts: [Data]) -> Data {
    parts.reduce(into: Data()) { result, part in
        var length = UInt32(part.count).bigEndian
        result.append(Data(bytes: &length, count: 4)); result.append(part)
    }
}

private struct FailingNotificationRegistrationStore: NotificationRegistrationStoring {
    func load(_ key: NotificationRegistrationStoreKey) throws -> Data? { nil }
    func save(_ value: Data, for key: NotificationRegistrationStoreKey) throws { throw TestStoreError.failed }
    func delete(_ key: NotificationRegistrationStoreKey) throws {}
}

private enum TestStoreError: Error { case failed }

private actor RecordingAppAttest: AppAttestProviding {
    let supported: Bool
    let keyID: String
    let attestation: Data
    private(set) var generatedKeyCount = 0
    private(set) var attestedHashes: [Data] = []
    private(set) var assertionHashes: [Data] = []

    init(keyID: String, supported: Bool = true, attestation: Data = Data("attestation".utf8)) { self.keyID = keyID; self.supported = supported; self.attestation = attestation }
    nonisolated var isSupported: Bool { supported }
    func generateKey() async throws -> String { generatedKeyCount += 1; return keyID }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { attestedHashes.append(clientDataHash); return attestation }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { assertionHashes.append(clientDataHash); return Data("assertion".utf8) }
    func attestedHashesSnapshot() -> [Data] { attestedHashes }
    func generatedKeyCountSnapshot() -> Int { generatedKeyCount }
    func assertionCount() -> Int { assertionHashes.count }
}

private actor RecordingNotificationRemote: NotificationRegistrationRemote {
    let challenge: Data
    let revokeError: Error?
    private var attestationFailuresRemaining: Int
    private(set) var attestationRequests: [NotificationAttestationRegistrationRequest] = []
    private(set) var assertionRequests: [NotificationAssertionRegistrationRequest] = []
    init(challenge: Data, revokeError: Error? = nil, attestationFailuresRemaining: Int = 0) { self.challenge = challenge; self.revokeError = revokeError; self.attestationFailuresRemaining = attestationFailuresRemaining }
    func issueChallenge() async throws -> Data { challenge }
    func registerAttestation(_ request: NotificationAttestationRegistrationRequest) async throws -> NotificationRegistrationResponse {
        attestationRequests.append(request)
        if attestationFailuresRemaining > 0 {
            attestationFailuresRemaining -= 1
            throw AccountRuntimeError.transportFailure
        }
        return try NotificationRegistrationResponse(routingHandle: Data(repeating: 0xAB, count: 32))
    }
    func registerAssertion(_ request: NotificationAssertionRegistrationRequest) async throws -> NotificationRegistrationResponse {
        assertionRequests.append(request)
        return try NotificationRegistrationResponse(routingHandle: Data(repeating: 0xAB, count: 32))
    }
    func revoke(routingHandle: Data) async throws { if let revokeError { throw revokeError } }
    func currentAttestation() -> NotificationAttestationRegistrationRequest? { attestationRequests.last }
    func attestations() -> [NotificationAttestationRegistrationRequest] { attestationRequests }
    func assertions() -> [NotificationAssertionRegistrationRequest] { assertionRequests }
}

private struct FailingNotificationRemote: NotificationRegistrationRemote {
    let error: Error
    func issueChallenge() async throws -> Data { throw error }
    func registerAttestation(_ request: NotificationAttestationRegistrationRequest) async throws -> NotificationRegistrationResponse { throw error }
    func registerAssertion(_ request: NotificationAssertionRegistrationRequest) async throws -> NotificationRegistrationResponse { throw error }
    func revoke(routingHandle: Data) async throws { throw error }
}

private struct DirectConflictPolicyRemote: NotificationPolicyRemote {
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.conflict
    }

    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.conflict
    }
}

private struct FailingDefaultPolicyRemote: NotificationPolicyRemote {
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.conflict
    }

    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.conflict
    }
}

private actor DirectRegistrationPolicyRemote: DirectNotificationPolicyAccess {
    private var state: DirectNotificationPolicyState
    private let materializes: Bool
    private var requests: [DirectNotificationPolicyUpdateRequest] = []

    init(materializes: Bool = true) {
        self.materializes = materializes
        state = try! DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "0", scopeVersion: "0", override: false)
    }

    func directDefaultPolicy() async throws -> DirectNotificationPolicyState { state }
    func directPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> DirectNotificationPolicyState {
        try DirectNotificationPolicyState(logicalMailboxID: logicalMailboxID, mode: state.mode, version: state.version, scopeVersion: "0", override: false)
    }
    func updateDirectNotificationPolicy(_ request: DirectNotificationPolicyUpdateRequest) async throws -> DirectNotificationPolicyState {
        guard request.logicalMailboxID == nil, !request.clear, request.expectedVersion == state.version else { throw NotificationPolicyRemoteError.conflict }
        requests.append(request)
        guard materializes else { return state }
        state = try DirectNotificationPolicyState(logicalMailboxID: nil, mode: request.mode, version: "1", scopeVersion: "0", override: false)
        return state
    }
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.invalidResponse
    }
    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.invalidResponse
    }
    func requestsSnapshot() -> [DirectNotificationPolicyUpdateRequest] { requests }
}

private actor DirectMailboxRegistrationPolicyRemote: DirectNotificationPolicyAccess {
    private let mailbox: LogicalMailboxID
    private var state: DirectNotificationPolicyState
    private var requests: [DirectNotificationPolicyUpdateRequest] = []

    init(mailbox: LogicalMailboxID) {
        self.mailbox = mailbox
        state = try! DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: .richPreview, version: "7", scopeVersion: "4", override: false)
    }

    func directDefaultPolicy() async throws -> DirectNotificationPolicyState {
        try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .generic, version: "3", scopeVersion: "0", override: false)
    }
    func directPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> DirectNotificationPolicyState {
        guard logicalMailboxID == mailbox else { throw NotificationPolicyRemoteError.conflict }
        return state
    }
    func updateDirectNotificationPolicy(_ request: DirectNotificationPolicyUpdateRequest) async throws -> DirectNotificationPolicyState {
        guard request.logicalMailboxID == mailbox, request.expectedVersion == "4", request.mode == .generic, !request.clear else { throw NotificationPolicyRemoteError.conflict }
        requests.append(request)
        state = try DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: .generic, version: "5", scopeVersion: "5", override: true)
        return state
    }
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.invalidResponse
    }
    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.invalidResponse
    }
    func requestsSnapshot() -> [DirectNotificationPolicyUpdateRequest] { requests }
}

private actor RetryingRevokeRemote: NotificationRegistrationRemote {
    private var failuresRemaining: Int
    init(failuresRemaining: Int) { self.failuresRemaining = failuresRemaining }
    func issueChallenge() async throws -> Data { Data(repeating: 1, count: 32) }
    func registerAttestation(_ request: NotificationAttestationRegistrationRequest) async throws -> NotificationRegistrationResponse { try NotificationRegistrationResponse(routingHandle: Data(repeating: 2, count: 32)) }
    func registerAssertion(_ request: NotificationAssertionRegistrationRequest) async throws -> NotificationRegistrationResponse { try NotificationRegistrationResponse(routingHandle: Data(repeating: 2, count: 32)) }
    func revoke(routingHandle: Data) async throws {
        if failuresRemaining > 0 { failuresRemaining -= 1; throw AccountRuntimeError.transportFailure }
    }
}

private actor RecordingPolicyRemote: NotificationPolicyRemote {
    private var requests: [NodeSyncNotificationPolicyUpdateRequest] = []
    private var failNext = false
    private var policy: NodeSyncNotificationPolicy

    init(initial: NodeSyncNotificationPolicy? = nil) {
        policy = initial ?? (try! NodeSyncNotificationPolicy(logicalMailboxID: nil, mode: .richPreview, version: "1", scopeVersion: "1", override: false))
    }

    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy { policy }
    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        requests.append(request)
        if failNext { failNext = false; throw AccountRuntimeError.transportFailure }
        let nextVersion = String((UInt64(policy.version) ?? 0) + 1)
        policy = try NodeSyncNotificationPolicy(
            logicalMailboxID: request.logicalMailboxID,
            mode: request.clear ? .richPreview : request.mode,
            version: nextVersion,
            scopeVersion: request.logicalMailboxID == nil ? "1" : nextVersion,
            override: request.logicalMailboxID != nil
        )
        return policy
    }
    func failNextUpdate() { failNext = true }
    func requestsSnapshot() -> [NodeSyncNotificationPolicyUpdateRequest] { requests }
}

private actor RecordingRecipientTransfer: NotificationRecipientTransfer {
    private(set) var records: [NotificationRecipientRegistration] = []
    func transfer(_ registration: NotificationRecipientRegistration) async throws { records.append(registration) }
    func count() -> Int { records.count }
}

private actor RecordingRecipientUploader: NotificationRecipientRegistrationUploading {
    private var records: [NotificationRecipientRegistration] = []
    func upload(_ registration: NotificationRecipientRegistration) async throws {
        records.append(registration)
    }
    func registration() -> NotificationRecipientRegistration? { records.last }
}

private actor RotatingNotificationTrustSource {
    private var snapshot: NotificationTrustSnapshot
    init(_ snapshot: NotificationTrustSnapshot) { self.snapshot = snapshot }
    func current() -> NotificationTrustSnapshot { snapshot }
    func set(_ snapshot: NotificationTrustSnapshot) { self.snapshot = snapshot }
}

private struct AlwaysAuthorizedNotificationPermission: NotificationPermissionProviding {
    func requestAuthorization() async throws -> Bool { true }
}
private actor CountingNotificationPermission: NotificationPermissionProviding {
    private var requests = 0
    func requestAuthorization() async throws -> Bool { requests += 1; return true }
    func count() -> Int { requests }
}
private struct DeniedNotificationPermission: NotificationPermissionProviding {
    func requestAuthorization() async throws -> Bool { false }
}
private struct FixedAPNSTokenProvider: APNSTokenProviding {
    let token: Data
    func token() async throws -> Data { token }
}

private struct BlockingAPNSTokenProvider: APNSTokenProviding {
    func token() async throws -> Data {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return Data(repeating: 0xFE, count: 32)
    }
}

private actor SequenceAPNSTokenProvider: APNSTokenProviding {
    private var tokens: [Data]
    init(tokens: [Data]) { self.tokens = tokens }
    func token() async throws -> Data {
        guard !tokens.isEmpty else { throw NotificationRegistrationFailure.invalidDeviceToken }
        return tokens.removeFirst()
    }
}

final class NotificationEnvironmentProvisioningTests: XCTestCase {
    /// A Release build signed with a development profile gets sandbox tokens; Central must
    /// send its pushes to the sandbox, so the profile decides, not the build configuration.
    func testTheEmbeddedProfileDecidesTheAPNsEnvironment() {
        func profile(apsEnvironment: String?) -> Data {
            let entitlement = apsEnvironment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
            // A CMS envelope around the plist: binary bytes on both sides.
            return Data([0x30, 0x82, 0x01]) + Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlement)</dict></dict></plist>
                """.utf8) + Data([0xA0, 0x00])
        }
        XCTAssertEqual(NotificationEnvironment.provisioned(embeddedProfile: profile(apsEnvironment: "development")), .sandbox)
        XCTAssertEqual(NotificationEnvironment.provisioned(embeddedProfile: profile(apsEnvironment: "production")), .production)
        XCTAssertEqual(NotificationEnvironment.provisioned(embeddedProfile: profile(apsEnvironment: nil)), .production)
        XCTAssertEqual(NotificationEnvironment.provisioned(embeddedProfile: nil), .production)
        XCTAssertEqual(NotificationEnvironment.provisioned(embeddedProfile: Data("not a profile".utf8)), .production)
    }
}
