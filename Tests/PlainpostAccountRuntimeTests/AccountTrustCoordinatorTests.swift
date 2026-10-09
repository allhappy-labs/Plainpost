import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport

final class AccountTrustCoordinatorTests: XCTestCase {
    func testApprovalRejectsSubstitutedPendingBundleAndCannotBeConfirmedTwice() async throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let existingDeviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let pendingDeviceID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let identity = try AccountDeviceIdentity(signingPrivateKey: scalar(10), agreementPrivateKey: scalar(11))
        let pendingBundle = try AccountPublicKeyBundle(
            signingKey: try publicKey(scalar(12), agreement: false),
            agreementKey: try publicKey(scalar(13), agreement: true)
        )
        let now = Date(timeIntervalSince1970: 1_735_689_660.003)
        let coordinator = try AccountTrustCoordinator(
            accountID: accountID,
            deviceID: existingDeviceID,
            platform: .macos,
            deviceIdentity: identity,
            trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust"),
            now: { now },
            random: { count in Data(repeating: 0x42, count: count) }
        )
        let pending = try PendingAccountDevice(
            accountID: accountID,
            deviceID: pendingDeviceID,
            platform: .ios,
            publicBundle: pendingBundle,
            exchangeRequestDigest: Data(repeating: 0x11, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let offer = try await coordinator.beginApproval(of: pending)
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: 0x24, count: 32))
        let authenticationString = try await coordinator.authenticationString(for: response)
        XCTAssertEqual(authenticationString.count, 6)

        let substituted = try TrustHandshakeOfferV1(
            accountID: offer.accountID,
            existingDeviceID: offer.existingDeviceID,
            pendingDeviceID: offer.pendingDeviceID,
            existingPublicBundle: offer.existingPublicBundle,
            pendingPublicBundle: try AccountPublicKeyBundle(signingKey: try publicKey(scalar(14), agreement: false), agreementKey: offer.pendingPublicBundle.agreementKey),
            existingNonce: offer.existingNonce,
            createdAtUnixMilliseconds: offer.createdAtUnixMilliseconds,
            expiresAtUnixMilliseconds: offer.expiresAtUnixMilliseconds
        )
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.authenticationString(for: TrustHandshakeResponseV1(offer: substituted, pendingNonce: response.pendingNonce)) }
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.approve(response, authenticationConfirmed: false) }
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.authenticationString(for: response) }
    }

    func testAcceptedPackageRestoresMaterialButRejectsTamperedSignature() async throws {
        let commit = try forkCommit("forkB")
        let identity = try fixtureIdentity()
        let firstSecrets = InMemoryAccountSecretStore()
        let firstTrustStore = testTrustStore(secretStore: firstSecrets, service: "test.trust.hmac")
        let first = try AccountTrustCoordinator(
            accountID: commit.state.accountID,
            deviceID: commit.state.signerDeviceID,
            platform: .macos,
            deviceIdentity: identity,
            trustStore: firstTrustStore,
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x41, count: $0) }
        )
        try await first.accept(commit)
        let restored = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await restored.accept(commit)
        let firstMailbox = try await first.logicalMailboxID(provider: "Gmail", accountIdentity: "alice@example.com")
        let restoredMailbox = try await restored.logicalMailboxID(provider: " Gmail ", accountIdentity: " ALICE@EXAMPLE.COM ")
        XCTAssertEqual(firstMailbox, restoredMailbox)
        let material = try XCTUnwrap(firstTrustStore.loadKeyMaterial(for: commit.state.accountID))
        XCTAssertEqual(material.mailboxMatchingKey, try fixtureRoleFreeKey("mailboxMatchingKeyHex"))
        XCTAssertEqual(material.metadataKey, try fixtureRoleFreeKey("metadataKeyHex"))
        XCTAssertTrue(firstSecrets.records.values.allSatisfy { $0.attributes == .deviceOnly })
        XCTAssertNotNil(try firstTrustStore.loadCheckpoint(for: commit.state.accountID))
        let expectedMailbox = Data(HMAC<SHA256>.authenticationCode(
            for: AccountTranscript.parts([
                Data("Plainpost.LogicalMailboxID.v1".utf8),
                Data("gmail".utf8),
                Data("alice@example.com".utf8),
            ]),
            using: SymmetricKey(data: material.mailboxMatchingKey)
        ))
        XCTAssertEqual(firstMailbox.rawValue, expectedMailbox)
        XCTAssertEqual(firstMailbox.rawValue, try trustMailboxVector())

        let package = commit.keyPackages[0]
        let tamperedPackage = try AccountGroupKeyPackage(
            accountID: package.accountID,
            epoch: package.epoch,
            stateRevision: package.stateRevision,
            keyGeneration: package.keyGeneration,
            stateDigest: package.stateDigest,
            keyCommitment: package.keyCommitment,
            recipientDeviceID: package.recipientDeviceID,
            senderDeviceID: package.senderDeviceID,
            senderEphemeralPublicKey: package.senderEphemeralPublicKey,
            nonce: package.nonce,
            encryptedKeyMaterial: package.encryptedKeyMaterial,
            signature: Data(repeating: 1, count: 64)
        )
        let tamperedCommit = try AccountTrustStateCommit(state: commit.state, keyPackages: [tamperedPackage])
        let receiver = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        await XCTAssertThrowsErrorAsync { try await receiver.accept(tamperedCommit) }
    }

    func testPackageOnlyForkRejectsSuccessorBoundToOtherCommitDigest() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await coordinator.acceptHistory([try forkCommit("forkB")])
        await XCTAssertThrowsErrorAsync { try await coordinator.acceptHistory([try forkCommit("successorC")]) }
    }

    func testDirectInboxMailboxIDIsSharedAcrossDevicesAndDistinctPerAccount() async throws {
        let commit = try forkCommit("forkB")
        let identity = try fixtureIdentity()
        let mac = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        let iPhone = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await mac.accept(commit)
        try await iPhone.accept(commit)

        let onMac = try await mac.directInboxMailboxID(imapHost: "imap.gmail.com", email: "Alice@Example.com")
        let onIPhone = try await iPhone.directInboxMailboxID(imapHost: "IMAP.Gmail.com ", email: "alice@example.com")
        XCTAssertEqual(onMac, onIPhone)
        let otherAccount = try await mac.directInboxMailboxID(imapHost: "imap.gmail.com", email: "bob@example.com")
        XCTAssertNotEqual(onMac, otherAccount)
        // A Direct Inbox never collides with a mailbox derived for another purpose.
        let generic = try await mac.logicalMailboxID(provider: "imap.gmail.com", accountIdentity: "alice@example.com")
        XCTAssertNotEqual(onMac, generic)
    }

    func testApprovedAdmissionThenRevocationRotatesMailboxKeyAndRetainsOldRecordsForMigration() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await coordinator.accept(try forkCommit("forkB"))
        let before = try await coordinator.logicalMailboxID(provider: " Gmail ", accountIdentity: "ALICE@example.com")
        let oldRecord = try await coordinator.sealAccountRecord(id: try AccountRecordID("22222222-2222-2222-2222-222222222222"), plaintext: Data("old metadata".utf8))

        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pending = try PendingAccountDevice(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: pendingID,
            platform: .ios,
            publicBundle: try AccountPublicKeyBundle(signingKey: try publicKey(scalar(12), agreement: false), agreementKey: try publicKey(scalar(13), agreement: true)),
            exchangeRequestDigest: Data(repeating: 0x23, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let offer = try await coordinator.beginApproval(of: pending)
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: 0x39, count: 32))
        _ = try await coordinator.approve(response, authenticationConfirmed: true)
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.approve(response, authenticationConfirmed: true) }
        let revoked = try await coordinator.revoke(pendingID)
        XCTAssertEqual(revoked.state.keyGeneration.value, 2)
        XCTAssertFalse(revoked.state.members.contains(where: { $0.deviceID == pendingID }))
        let after = try await coordinator.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        XCTAssertNotEqual(before, after)
        let retainedOld = try await coordinator.openAccountRecord(oldRecord)
        XCTAssertEqual(retainedOld, Data("old metadata".utf8))
    }

    func testAdmissionCandidateDoesNotAdvanceLocalHeadUntilExactAcceptedEntryIsInstalled() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        let predecessor = try forkCommit("forkB")
        try await coordinator.accept(predecessor)
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let pending = try PendingAccountDevice(
            accountID: predecessor.state.accountID,
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            platform: .ios,
            publicBundle: pendingIdentity.publicBundle,
            exchangeRequestDigest: Data(repeating: 0x51, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let offer = try await coordinator.beginApproval(of: pending)
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: 0x52, count: 32))

        let candidate = try await coordinator.makeAdmissionCandidate(response, authenticationConfirmed: true)

        let beforeInstall = try await coordinator.currentTrustCommit()
        XCTAssertEqual(beforeInstall, predecessor)
        try await coordinator.acceptHistory([candidate])
        let afterInstall = try await coordinator.currentTrustCommit()
        XCTAssertEqual(afterInstall, candidate.commit)
    }

    func testSyncNodeEnrollmentBuildsAndAcceptsSignedInitialAndReplacementSuccessors() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await coordinator.accept(try forkCommit("forkB"))

        let firstNodeID = try AccountDeviceID("aaaaaaaa-bbbb-4aaa-8aaa-aaaaaaaaaaa1")
        let optionalInitialHead = try await coordinator.currentTrustCommit()
        let initialHead = try XCTUnwrap(optionalInitialHead)
        let initialEvidence = try syncNodeEvidence(
            predecessor: initialHead,
            identity: identity,
            claimID: NodeEnrollmentClaimID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1"),
            nodeDeviceID: firstNodeID,
            action: .enroll,
            replacedNodeID: nil
        )
        let initial = try await coordinator.makeSyncNodeEnrollmentCommit(evidence: initialEvidence)
        XCTAssertEqual(initial.state.transition.kind, .admission)
        XCTAssertEqual(initial.state.transition.targetDeviceIDs, [firstNodeID])
        XCTAssertEqual(initial.state.revision.value, initialHead.state.revision.value + 1)
        XCTAssertEqual(initial.state.members.first(where: { $0.deviceID == firstNodeID })?.platform, .syncNode)
        let unmodifiedHead = try await coordinator.currentTrustCommit()
        XCTAssertEqual(unmodifiedHead, initialHead)
        try await coordinator.acceptSyncNodeEnrollmentCommit(initial, evidence: initialEvidence)

        let optionalReplacementHead = try await coordinator.currentTrustCommit()
        let replacementHead = try XCTUnwrap(optionalReplacementHead)
        let replacementNodeID = try AccountDeviceID("cccccccc-cccc-4ccc-8ccc-ccccccccccc1")
        let replacementEvidence = try syncNodeEvidence(
            predecessor: replacementHead,
            identity: identity,
            claimID: NodeEnrollmentClaimID("dddddddd-dddd-4ddd-8ddd-ddddddddddd1"),
            nodeDeviceID: replacementNodeID,
            action: .replace,
            replacedNodeID: firstNodeID
        )
        let replacement = try await coordinator.makeSyncNodeEnrollmentCommit(evidence: replacementEvidence)
        XCTAssertEqual(replacement.state.transition.kind, .revocation)
        XCTAssertEqual(replacement.state.transition.targetDeviceIDs, [firstNodeID])
        XCTAssertEqual(replacement.state.revision.value, replacementHead.state.revision.value + 1)
        XCTAssertFalse(replacement.state.members.contains(where: { $0.deviceID == firstNodeID }))
        XCTAssertEqual(replacement.state.members.first(where: { $0.deviceID == replacementNodeID })?.platform, .syncNode)
        try await coordinator.acceptSyncNodeEnrollmentCommit(replacement, evidence: replacementEvidence)
        let acceptedReplacement = try await coordinator.currentTrustCommit()
        XCTAssertEqual(acceptedReplacement, replacement)
    }

    @MainActor func testActiveAdmissionRequiresAppleStepUpBeforeIssuingCapabilityAndRefreshCancelsAttempt() async throws {
        let ownerIdentity = try fixtureIdentity()
        let owner = try fixtureCoordinator(identity: ownerIdentity, store: InMemoryAccountSecretStore())
        let predecessor = try forkCommit("forkB")
        try await owner.accept(predecessor)
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let pending = try PendingAccountDevice(
            accountID: predecessor.state.accountID,
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            platform: .ios,
            publicBundle: pendingIdentity.publicBundle,
            exchangeRequestDigest: Data(repeating: 0x58, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let credentials = try AccountSessionCredentials(accountID: predecessor.state.accountID, deviceID: predecessor.state.signerDeviceID, accessToken: "owner-access", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 0x59, count: 32), offlineLease: "owner-lease")
        let rendezvous = ImmediateOwnerAdmissionRendezvous(pending: pending)
        let transport = RejectingCountingAccountTransport()
        let credentialStore = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "test.active.capability.client")
        let manifest = try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore(), clock: { Date(timeIntervalSince1970: 1_788_696_000) })
        let client = try AccountAPIClient(transport: transport, credentialStore: credentialStore, manifestStore: manifest)
        let controller = AccountActiveAdmissionController(rendezvous: rendezvous, coordinator: owner, client: client, credentials: credentials, identity: ownerIdentity)

        controller.refresh()
        var prompt: AccountActiveAdmissionController.PendingPrompt?
        for _ in 0 ..< 300 {
            if case .idle(let pendingPrompts) = controller.state, let first = pendingPrompts.first { prompt = first; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.begin(try XCTUnwrap(prompt))
        for _ in 0 ..< 300 {
            if case .awaitingConfirmation = controller.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(controller.currentApprovalCapability())

        controller.refresh()
        await rendezvous.waitForCancellation()
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testActiveAdmissionFailureReasonsStayBoundedToExpiredUnreachableOrGeneric() {
        typealias Reason = AccountActiveAdmissionController.FailureReason
        XCTAssertEqual(Reason(classifying: AccountProtocolError.invalidTrustHandshake), .expired)
        XCTAssertEqual(Reason(classifying: AccountRuntimeError.transportFailure), .unreachable)
        XCTAssertEqual(Reason(classifying: URLError(.notConnectedToInternet)), .unreachable)
        XCTAssertEqual(Reason(classifying: URLError(.timedOut)), .unreachable)
        XCTAssertEqual(Reason(classifying: AccountRuntimeError.untrustedResponse), .other)
        XCTAssertEqual(Reason(classifying: AccountProtocolError.malformedWire), .other)
    }

    @MainActor func testActiveAdmissionReportsExpiredPendingRequestWhenApprovalBegins() async throws {
        let fixture = try await ActiveAdmissionFailureFixture(createdAt: "2024-12-31T23:54:00Z", expiresAt: "2024-12-31T23:59:00Z")
        let controller = fixture.controller()
        let reason = try await fixture.beginAndAwaitFailure(controller)
        XCTAssertEqual(reason, .expired)
    }

    @MainActor func testActiveAdmissionReportsUnreachableDeviceWhenOfferCannotBeDelivered() async throws {
        let fixture = try await ActiveAdmissionFailureFixture(submitFailure: .transportFailure)
        let controller = fixture.controller()
        let reason = try await fixture.beginAndAwaitFailure(controller)
        XCTAssertEqual(reason, .unreachable)
    }

    @MainActor func testActiveAdmissionStopsWaitingAndReportsExpiryOnceTheOfferWindowCloses() async throws {
        let fixture = try await ActiveAdmissionFailureFixture(responds: false)
        // The offer expires at the pending request's 2025-01-01T00:05:00Z bound.
        let controller = fixture.controller(now: { Date(timeIntervalSince1970: 1_735_689_900) })
        let reason = try await fixture.beginAndAwaitFailure(controller)
        XCTAssertEqual(reason, .expired)
    }

    func testPendingAdmissionTrustAndSessionRecoverAtomicallyAtEveryJournalStep() async throws {
        let ownerIdentity = try fixtureIdentity()
        let owner = try fixtureCoordinator(identity: ownerIdentity, store: InMemoryAccountSecretStore())
        let predecessor = try forkCommit("forkB")
        try await owner.accept(predecessor)
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pending = try PendingAccountDevice(
            accountID: predecessor.state.accountID,
            deviceID: pendingID,
            platform: .ios,
            publicBundle: pendingIdentity.publicBundle,
            exchangeRequestDigest: Data(repeating: 0x61, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let offer = try await owner.beginApproval(of: pending)
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: 0x62, count: 32))
        let candidate = try await owner.makeAdmissionCandidate(response, authenticationConfirmed: true)
        let temporaryTrustStore = testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.pending.prepared")
        let receiver = try AccountTrustCoordinator(accountID: predecessor.state.accountID, deviceID: pendingID, platform: .ios, deviceIdentity: pendingIdentity, trustStore: temporaryTrustStore)
        try await receiver.acceptHistory([try AccountTrustHistoryEntryV1(commit: predecessor, evidence: nil), candidate])
        let prepared = try await receiver.preparedTrustActivation()
        let activation = AccountActivation(accountID: predecessor.state.accountID, deviceID: pendingID, mode: .pending)
        let credentials = try AccountSessionCredentials(accountID: activation.accountID, deviceID: activation.deviceID, accessToken: "pending-accepted", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 0x63, count: 32), offlineLease: "pending-lease")

        for step in ["journal", "trust", "session", "marker"] {
            let backing = InMemoryAccountSecretStore()
            let credentialService = "test.pending.activation.\(step)"
            let trustService = credentialService + ".trust"
            let durableTrust = testTrustStore(secretStore: backing, service: trustService)
            let store = AccountCredentialStore(secretStore: backing, service: credentialService, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: durableTrust)
            try store.commitPendingActivation(activation, credentials: credentials)
            store.testAfterActivationStep = { if $0 == step { throw AccountRuntimeError.transportFailure } }
            XCTAssertThrowsError(try store.commitPendingTrustActivation(activation, credentials: credentials, prepared: prepared))

            let relaunchedTrust = testTrustStore(secretStore: backing, service: trustService)
            let relaunched = AccountCredentialStore(secretStore: backing, service: credentialService, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: relaunchedTrust)
            XCTAssertEqual(try relaunched.loadSession()?.credentials, credentials)
            XCTAssertEqual(try relaunchedTrust.loadCheckpoint(for: activation.accountID)?.commitDigest, AccountTranscript.trustCommitDigest(candidate.commit))
            XCTAssertEqual(try relaunchedTrust.loadKeyMaterial(for: activation.accountID)?.combined, prepared.material.combined)
            XCTAssertNil(backing.records[.init(service: credentialService, account: "activation.journal.v1")])
        }
    }

    func testPendingActivationJournalRejectsSignatureAndEvidenceMutationBeforeAnyPublication() async throws {
        let fixture = try await pendingPreparedActivationFixture()

        for mutation in [PendingJournalMutation.signature, .evidence] {
            let backing = InMemoryAccountSecretStore()
            let credentialService = "test.pending.activation.mutated.\(mutation)"
            let trustService = credentialService + ".trust"
            let durableTrust = testTrustStore(secretStore: backing, service: trustService)
            let store = AccountCredentialStore(
                secretStore: backing,
                service: credentialService,
                secureEnclaveIdentityProvider: nil,
                secureEnclaveIdentityResolver: nil,
                secureEnclaveAgreementProvider: nil,
                secureEnclaveAgreementResolver: nil,
                trustStore: durableTrust
            )
            try store.commitPendingActivation(fixture.activation, credentials: fixture.credentials)
            store.testAfterActivationStep = { if $0 == "journal" { throw AccountRuntimeError.transportFailure } }
            XCTAssertThrowsError(try store.commitPendingTrustActivation(fixture.activation, credentials: fixture.credentials, prepared: fixture.prepared))

            let journalKey = AccountSecretKey(service: credentialService, account: "activation.journal.v1")
            try mutatePendingActivationJournal(backing, key: journalKey, mutation: mutation)
            let relaunchedTrust = testTrustStore(secretStore: backing, service: trustService)
            let relaunched = AccountCredentialStore(
                secretStore: backing,
                service: credentialService,
                secureEnclaveIdentityProvider: nil,
                secureEnclaveIdentityResolver: nil,
                secureEnclaveAgreementProvider: nil,
                secureEnclaveAgreementResolver: nil,
                trustStore: relaunchedTrust
            )

            XCTAssertThrowsError(try relaunched.loadSession())
            XCTAssertNil(try relaunchedTrust.loadState(for: fixture.activation.accountID))
            XCTAssertNil(backing.records[.init(service: credentialService, account: "session-credentials-v1")])
            XCTAssertNil(backing.records[.init(service: credentialService, account: "activation.committed.v1")])
        }
    }

    func testEncryptedRecordRoundTripsAndRejectsRollbackAndSameCoordinateEquivocation() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await coordinator.accept(try forkCommit("forkB"))
        let recordID = try AccountRecordID("33333333-3333-3333-3333-333333333333")
        let first = try await coordinator.sealAccountRecord(id: recordID, plaintext: Data("first".utf8))
        let second = try await coordinator.sealAccountRecord(id: recordID, plaintext: Data("second".utf8))
        let third = try await coordinator.sealAccountRecord(id: recordID, plaintext: Data("third".utf8))
        XCTAssertEqual(second.recordRevision.value, 2)
        XCTAssertEqual(third.recordRevision.value, 3)
        let openedThird = try await coordinator.openAccountRecord(third)
        XCTAssertEqual(openedThird, Data("third".utf8))
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.openAccountRecord(first) }

        var alteredEnvelope = second.envelope
        alteredEnvelope[12] ^= 0x01
        let unsigned = try EncryptedAccountRecordV1(
            accountID: second.accountID,
            recordID: second.recordID,
            epoch: second.epoch,
            keyGeneration: second.keyGeneration,
            trustRevision: second.trustRevision,
            recordRevision: second.recordRevision,
            envelope: alteredEnvelope,
            signerDeviceID: second.signerDeviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let alteredSignature = try identity.signature(for: AccountTrustTranscript.encryptedRecordSignature(unsigned, envelopeDigest: Data(SHA256.hash(data: alteredEnvelope))))
        let equivocated = try EncryptedAccountRecordV1(
            accountID: unsigned.accountID,
            recordID: unsigned.recordID,
            epoch: unsigned.epoch,
            keyGeneration: unsigned.keyGeneration,
            trustRevision: unsigned.trustRevision,
            recordRevision: unsigned.recordRevision,
            envelope: unsigned.envelope,
            signerDeviceID: unsigned.signerDeviceID,
            signature: alteredSignature
        )
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.openAccountRecord(equivocated) }
    }

    func testPreparedRemoteCASRecordDoesNotAdvanceHighWaterBeforeWinnerIsOpened() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await coordinator.accept(try forkCommit("forkB"))
        let recordID = try AccountRecordID("33333333-3333-3333-3333-333333333334")

        let unsent = try await coordinator.prepareAccountRecordForRemoteCAS(id: recordID, plaintext: Data("unsent".utf8))
        let winner = try await coordinator.sealAccountRecord(id: recordID, plaintext: Data("winner".utf8))

        XCTAssertEqual(unsent.recordRevision.value, 1)
        XCTAssertEqual(winner.recordRevision.value, 1)
        let openedWinner = try await coordinator.openAccountRecord(winner)
        XCTAssertEqual(openedWinner, Data("winner".utf8))
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.openAccountRecord(unsent) }
    }

    func testConcurrentEndpointPublishConvergesFirstAndSecondClientsWithoutRollback() async throws {
        let identity = try fixtureIdentity()
        let first = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        let second = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        let commit = try forkCommit("forkB")
        try await first.accept(commit)
        try await second.accept(commit)
        let credentials = try AccountSessionCredentials(accountID: commit.state.accountID, deviceID: commit.state.signerDeviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 0x11, count: 32), offlineLease: "lease")
        let published = try SyncNodePublishedEndpointV1(accountID: commit.state.accountID, nodeID: try AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: commit.state.epoch, endpoint: URL(string: "https://node.tail1234.ts.net:8443")!)
        let remote = EndpointMetadataCASFixture()

        async let firstPublish: Void = SyncNodeEndpointMetadata.publish(published, replacing: nil, remote: remote, trust: first, credentials: credentials, device: identity, now: Date(timeIntervalSince1970: 1_786_260_000))
        async let secondPublish: Void = SyncNodeEndpointMetadata.publish(published, replacing: nil, remote: remote, trust: second, credentials: credentials, device: identity, now: Date(timeIntervalSince1970: 1_786_260_000))
        try await firstPublish
        try await secondPublish

        let current = await remote.current()
        let winner = try XCTUnwrap(current)
        let firstPlaintext = try await first.openAccountRecord(winner)
        let secondPlaintext = try await second.openAccountRecord(winner)
        XCTAssertEqual(try SyncNodePublishedEndpointV1.decode(firstPlaintext), published)
        XCTAssertEqual(try SyncNodePublishedEndpointV1.decode(secondPlaintext), published)
    }

    func testEndpointReplacementRequiresExactRevokedNodeAndAdvancesRecordRevision() async throws {
        let identity = try fixtureIdentity()
        let trust = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        let commit = try forkCommit("forkB")
        try await trust.accept(commit)
        let credentials = try AccountSessionCredentials(accountID: commit.state.accountID, deviceID: commit.state.signerDeviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 0x12, count: 32), offlineLease: "lease")
        let oldNode = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let replacementNode = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let initial = try SyncNodePublishedEndpointV1(accountID: commit.state.accountID, nodeID: oldNode, trustEpoch: commit.state.epoch, endpoint: URL(string: "https://node.tail1234.ts.net:8443")!)
        let replacement = try SyncNodePublishedEndpointV1(accountID: commit.state.accountID, nodeID: replacementNode, trustEpoch: commit.state.epoch, endpoint: URL(string: "https://node.tail5678.ts.net:8443")!)
        let remote = EndpointMetadataCASFixture()
        try await SyncNodeEndpointMetadata.publish(initial, replacing: nil, remote: remote, trust: trust, credentials: credentials, device: identity, now: Date(timeIntervalSince1970: 1_786_260_000))
        let initialCurrent = await remote.current()
        let initialRecord = try XCTUnwrap(initialCurrent)

        await XCTAssertThrowsErrorAsync {
            try await SyncNodeEndpointMetadata.publish(replacement, replacing: nil, remote: remote, trust: trust, credentials: credentials, device: identity, now: Date(timeIntervalSince1970: 1_786_260_001))
        }
        try await SyncNodeEndpointMetadata.publish(replacement, replacing: oldNode, remote: remote, trust: trust, credentials: credentials, device: identity, now: Date(timeIntervalSince1970: 1_786_260_001))
        let current = await remote.current()
        let winner = try XCTUnwrap(current)
        XCTAssertEqual(winner.recordRevision.value, initialRecord.recordRevision.value + 1)
        let winnerPlaintext = try await trust.openAccountRecord(winner)
        XCTAssertEqual(try SyncNodePublishedEndpointV1.decode(winnerPlaintext), replacement)
    }

    // Catches a regression that exposes Central account metadata before the
    // private Node has accepted V3, or saves a session before that publication.
    func testPrivateActivatorRejectsUnexpectedOriginBeforeJournalOrNetwork() async throws {
        let fixture = try await PrivateActivationFixture()

        await XCTAssertThrowsErrorAsync {
            try await fixture.activator.activate(
                response: fixture.response,
                request: fixture.request,
                claim: fixture.claim,
                setupCode: fixture.setupCode,
                expectedOrigin: try NodeEndpointURL("https://other.tail1234.ts.net:8443")
            )
        }

        XCTAssertNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        let events = await fixture.events.values()
        XCTAssertEqual(events, [])
    }

    func testPrivateActivatorOrdersV3ThenMetadataThenDeviceOnlySession() async throws {
        let fixture = try await PrivateActivationFixture()
        try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))

        let events = await fixture.events.values()
        XCTAssertEqual(events, [.v3, .metadata])
        XCTAssertEqual(try fixture.store.load(for: fixture.reference).nextSequence, 1)
        let record = await fixture.remote.current()
        XCTAssertNotNil(record)
    }

    // The endpoint publication after V3 is an authenticated Central request.
    // It must use the current session, not the one captured at construction.
    func testPrivateActivatorPublishesWithCurrentSessionCredentials() async throws {
        let fixture = try await PrivateActivationFixture()
        let rotated = try AccountSessionCredentials(accountID: fixture.credentials.accountID, deviceID: fixture.credentials.deviceID, accessToken: "rotated-access", accessExpiresAt: fixture.credentials.accessExpiresAt, refreshCredential: fixture.credentials.refreshCredential, offlineLease: fixture.credentials.offlineLease)
        let activator = try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { rotated }, device: fixture.identity)

        try await activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))

        let tokens = await fixture.remote.accessTokens()
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertEqual(Set(tokens), ["rotated-access"])
        XCTAssertNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
    }

    // A session that now belongs to another device is refused. The Node may
    // already have accepted V3, so the recovery journal stays for a retry.
    func testPrivateActivatorRefusesSessionForAnotherOwnerAndKeepsRecovery() async throws {
        let fixture = try await PrivateActivationFixture(statuses: [204, 204])
        let foreign = try AccountSessionCredentials(accountID: fixture.credentials.accountID, deviceID: AccountDeviceID("33333333-3333-4333-8333-333333333333"), accessToken: "foreign-access", accessExpiresAt: fixture.credentials.accessExpiresAt, refreshCredential: fixture.credentials.refreshCredential, offlineLease: fixture.credentials.offlineLease)
        let session = PrivateActivationSessionBox(foreign)
        let activator = try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { session.value }, device: fixture.identity)

        do {
            try await activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))
            XCTFail("foreign session accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        let tokensWhileForeign = await fixture.remote.accessTokens()
        XCTAssertEqual(tokensWhileForeign, [])
        XCTAssertNotNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))

        session.value = fixture.credentials
        try await activator.retryUncertainActivation()
        XCTAssertNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        let currentTrust = try await fixture.trust.currentTrustCommit()
        XCTAssertEqual(currentTrust, fixture.request.trustCommit)
    }

    func testPrivateActivatorRestoresJournalAfterMetadataFailure() async throws {
        let fixture = try await PrivateActivationFixture(statuses: [204, 204])
        await fixture.remote.failNextPut()
        do {
            try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))
            XCTFail("metadata failure accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        XCTAssertNotNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        let restarted = try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { [credentials = fixture.credentials] in credentials }, device: fixture.identity)
        try await restarted.resumePendingActivation()
        XCTAssertNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        XCTAssertEqual(try fixture.store.load(for: fixture.reference).nextSequence, 1)
        let currentTrust = try await fixture.trust.currentTrustCommit()
        XCTAssertEqual(currentTrust, fixture.request.trustCommit)
    }

    func testPrivateActivatorMatchesRecoveryJournalOnlyToExactImportedProfile() async throws {
        let fixture = try await PrivateActivationFixture(statuses: [503])
        do {
            try await fixture.activator.activate(
                response: fixture.response,
                request: fixture.request,
                claim: fixture.claim,
                setupCode: fixture.setupCode,
                expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443")
            )
            XCTFail("unavailable activation accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        let restarted = try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { [credentials = fixture.credentials] in credentials }, device: fixture.identity)
        let correct = try SyncNodeBootstrapProfile(
            canonicalOrigin: NodeEndpointURL("https://node.tail1234.ts.net:8443"),
            nodeDeviceID: fixture.claim.nodeDeviceID,
            signingKeyDigest: Data(SHA256.hash(data: fixture.claim.signingPublicKey)),
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "central.test"
        )
        let wrongNode = try SyncNodeBootstrapProfile(canonicalOrigin: correct.canonicalOrigin, nodeDeviceID: AccountDeviceID("90000000-0000-4000-8000-000000000099"), signingKeyDigest: correct.signingKeyDigest, capabilityID: Data(repeating: 9, count: 16), capability: Data(repeating: 10, count: 32), centralAudience: "central.test")
        let wrongKey = try SyncNodeBootstrapProfile(canonicalOrigin: correct.canonicalOrigin, nodeDeviceID: correct.nodeDeviceID, signingKeyDigest: Data(repeating: 11, count: 32), capabilityID: Data(repeating: 12, count: 16), capability: Data(repeating: 13, count: 32), centralAudience: "central.test")
        let wrongOrigin = try SyncNodeBootstrapProfile(canonicalOrigin: NodeEndpointURL("https://other.tail1234.ts.net:8443"), nodeDeviceID: correct.nodeDeviceID, signingKeyDigest: correct.signingKeyDigest, capabilityID: Data(repeating: 14, count: 16), capability: Data(repeating: 15, count: 32), centralAudience: "central.test")

        let correctMatches = await restarted.pendingActivationMatches(profile: correct)
        let wrongNodeMatches = await restarted.pendingActivationMatches(profile: wrongNode)
        let wrongKeyMatches = await restarted.pendingActivationMatches(profile: wrongKey)
        let wrongOriginMatches = await restarted.pendingActivationMatches(profile: wrongOrigin)
        XCTAssertTrue(correctMatches)
        XCTAssertFalse(wrongNodeMatches)
        XCTAssertFalse(wrongKeyMatches)
        XCTAssertFalse(wrongOriginMatches)
    }

    func testPrivateActivatorRetainsJournalAcrossV3ServiceUnavailableThenReplays() async throws {
        let fixture = try await PrivateActivationFixture(statuses: [503, 204])
        do {
            try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))
            XCTFail("503 activation accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        XCTAssertNotNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        try await fixture.activator.retryUncertainActivation()
        XCTAssertNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        let events = await fixture.events.values()
        XCTAssertEqual(events.filter { $0 == .v3 }.count, 2)
    }

    // Catches a regression that clears recovery after V3 succeeds but the
    // device-only session record cannot be saved. A relaunch must replay the
    // exact accepted activation and complete the local publication.
    func testPrivateActivatorRecoversAfterDirectDeviceOnlySessionSaveFailure() async throws {
        let backing = InMemoryAccountSecretStore()
        let fixture = try await PrivateActivationFixture(
            statuses: [204, 204],
            secretStore: FailOnceSessionSaveSecretStore(backing: backing)
        )
        do {
            try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))
            XCTFail("session save failure accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        XCTAssertNotNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))

        let restarted = try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { [credentials = fixture.credentials] in credentials }, device: fixture.identity)
        try await restarted.resumePendingActivation()
        XCTAssertNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        XCTAssertEqual(try fixture.store.load(for: fixture.reference).nextSequence, 1)
    }

    // Catches a recovery record whose parsed V3 documents no longer bind to
    // one exact account/node/claim/evidence digest before any retry can run.
    func testPrivateActivatorRejectsCompletionJournalWithMismatchedV3BindingBeforeNetwork() async throws {
        let backing = InMemoryAccountSecretStore()
        let fixture = try await PrivateActivationFixture(statuses: [503], secretStore: backing)
        do {
            try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))
            XCTFail("unavailable activation accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        let key = AccountSecretKey(service: "test.private-activation", account: "activation-completion.v1.\(fixture.credentials.accountID.rawValue)")
        let record = try XCTUnwrap(backing.records[key])
        let journal = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.value) as? [String: Any])
        let originalResultWire = try XCTUnwrap(journal["resultWire"] as? String)
        let result = try AccountWireCodec.decodeNodeEnrollmentResultV2(try XCTUnwrap(Data(base64Encoded: originalResultWire)))
        let base = result.binding.base
        let alteredBase = try AccountNodeOperationBindingV1(accountID: base.accountID, trustEpoch: base.trustEpoch, claimID: base.claimID, nodeDeviceID: base.nodeDeviceID, centralAudience: base.centralAudience, action: base.action, replacedNodeID: base.replacedNodeID, replacementRevocationDigest: base.replacementRevocationDigest, admissionEvidenceDigest: Data(repeating: 0x7f, count: 32), issuanceDigest: base.issuanceDigest)
        let altered = try AccountNodeEnrollmentResultV2(binding: AccountNodeOperationBindingV2(base: alteredBase, cleanupCapabilityDigest: result.binding.cleanupCapabilityDigest), committedAt: result.committedAt)
        let alteredResultWire = try AccountWireCodec.encodeNodeEnrollmentResultV2(altered).base64EncodedString()
        let rawJournal = try XCTUnwrap(String(data: record.value, encoding: .utf8))
        let alteredJournal = rawJournal.replacingOccurrences(of: originalResultWire, with: alteredResultWire)
        XCTAssertNotEqual(alteredJournal, rawJournal)
        try backing.replace(Data(alteredJournal.utf8), key: key, attributes: .deviceOnly)

        XCTAssertThrowsError(try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { [credentials = fixture.credentials] in credentials }, device: fixture.identity))
        let events = await fixture.events.values()
        XCTAssertEqual(events, [.v3])
    }

    // The journal is a recovery boundary, not a cache: it must retain the
    // exact bounded public claim transcript needed to authenticate the Node's
    // proof before a restart can send V3 again.
    func testPrivateActivatorRejectsCompletionJournalWithSubstitutedClaimProofBeforeNetwork() async throws {
        let backing = InMemoryAccountSecretStore()
        let fixture = try await PrivateActivationFixture(statuses: [503], secretStore: backing)
        do {
            try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))
            XCTFail("unavailable activation accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        let key = AccountSecretKey(service: "test.private-activation", account: "activation-completion.v1.\(fixture.credentials.accountID.rawValue)")
        let record = try XCTUnwrap(backing.records[key])
        var journal = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.value) as? [String: Any])
        XCTAssertNotNil(journal["claimProofWire"])
        journal["claimProofSignature"] = Data(repeating: 0x7f, count: 64).base64EncodedString()
        try backing.replace(try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys, .withoutEscapingSlashes]), key: key, attributes: .deviceOnly)

        XCTAssertThrowsError(try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { [credentials = fixture.credentials] in credentials }, device: fixture.identity))
        let events = await fixture.events.values()
        XCTAssertEqual(events, [.v3])
    }

    func testPrivateActivatorCompletionJournalRetainsOnlyCanonicalPublicClaimMaterial() async throws {
        let backing = InMemoryAccountSecretStore()
        let fixture = try await PrivateActivationFixture(statuses: [503], secretStore: backing)
        do {
            try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443"))
            XCTFail("unavailable activation accepted")
        } catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        let key = AccountSecretKey(service: "test.private-activation", account: "activation-completion.v1.\(fixture.credentials.accountID.rawValue)")
        let journal = try XCTUnwrap(backing.records[key]).value
        let text = try XCTUnwrap(String(data: journal, encoding: .utf8))
        let setupRaw = String(decoding: fixture.setupCode, as: UTF8.self)
        let endpointRaw = "https://node.tail1234.ts.net:8443"
        XCTAssertFalse(text.contains(setupRaw))
        XCTAssertFalse(text.contains(fixture.setupCode.base64EncodedString()))
        XCTAssertFalse(text.contains(fixture.setupCode.hexEncodedString()))
        XCTAssertFalse(text.contains(endpointRaw))
        XCTAssertFalse(text.contains(Data(endpointRaw.utf8).base64EncodedString()))
        XCTAssertFalse(text.contains(Data(endpointRaw.utf8).hexEncodedString()))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: journal) as? [String: Any])
        XCTAssertNil(object["publishedWire"])
        let wire = try XCTUnwrap(object["claimProofWire"] as? String)
        XCTAssertEqual(try AccountWireCodec.decodeNodeEnrollmentPublicClaim(try XCTUnwrap(Data(base64Encoded: wire))), fixture.claim)
    }

    func testPrivateActivatorInFlightCancelRetainsAuthenticatedJournalForRestart() async throws {
        let backing = InMemoryAccountSecretStore()
        let endpoint = URL(string: "https://node.tail1234.ts.net:8443")!
        let blocked = BlockingPrivateActivationV3Transport(endpoint: endpoint)
        let fixture = try await PrivateActivationFixture(secretStore: backing, transport: blocked)
        let activation = Task { try await fixture.activator.activate(response: fixture.response, request: fixture.request, claim: fixture.claim, setupCode: fixture.setupCode, expectedOrigin: try NodeEndpointURL("https://node.tail1234.ts.net:8443")) }
        await blocked.waitUntilStarted()

        await fixture.activator.cancelPendingActivation()
        activation.cancel()
        await blocked.release()
        do { try await activation.value; XCTFail("cancelled in-flight activation completed") }
        catch { XCTAssertEqual(error as? NodeActivationError, .uncertain) }
        XCTAssertNotNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))

        let resumedClient = NodeTLSClient(transport: PrivateActivationV3Transport(endpoint: endpoint, events: fixture.events))
        let restarted = try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: resumedClient, credentials: fixture.credentials, credentialsProvider: { [credentials = fixture.credentials] in credentials }, device: fixture.identity)
        try await restarted.resumePendingActivation()
        XCTAssertNil(try fixture.store.loadActivationCompletionJournal(accountID: fixture.credentials.accountID))
        XCTAssertEqual(try fixture.store.load(for: fixture.reference).nextSequence, 1)
    }

    func testPrivateActivatorRejectsMalformedAndOversizedCompletionJournalBeforeNetwork() async throws {
        let fixture = try await PrivateActivationFixture()
        try fixture.store.saveActivationCompletionJournal(accountID: fixture.credentials.accountID, wire: Data("not-a-journal".utf8))
        XCTAssertThrowsError(try PrivateSyncNodeEnrollmentActivator(remote: fixture.remote, trust: fixture.trust, store: fixture.store, client: fixture.client, credentials: fixture.credentials, credentialsProvider: { [credentials = fixture.credentials] in credentials }, device: fixture.identity))
        XCTAssertThrowsError(try fixture.store.saveActivationCompletionJournal(accountID: fixture.credentials.accountID, wire: Data(repeating: 1, count: 512 * 1024 + 1)))
        let events = await fixture.events.values()
        XCTAssertEqual(events, [])
    }

    func testMetadataNonceUsesKeyedDeviceNamespaceAndMonotonicCounterWithoutPerNonceRows() async throws {
        let secrets = InMemoryAccountSecretStore()
        let commit = try forkCommit("forkB")
        let coordinator = try AccountTrustCoordinator(
            accountID: commit.state.accountID,
            deviceID: commit.state.signerDeviceID,
            platform: .macos,
            deviceIdentity: try fixtureIdentity(),
            trustStore: testTrustStore(secretStore: secrets, service: "test.trust.nonce"),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xA1, count: $0) }
        )
        try await coordinator.accept(commit)
        let first = try await coordinator.sealAccountRecord(id: try AccountRecordID("55555555-5555-4555-8555-555555555555"), plaintext: Data("one".utf8))
        let second = try await coordinator.sealAccountRecord(id: try AccountRecordID("66666666-6666-4666-8666-666666666666"), plaintext: Data("two".utf8))

        XCTAssertEqual(Data(first.envelope.prefix(8)), Data(second.envelope.prefix(8)))
        XCTAssertEqual(Data(first.envelope[8..<12]), Data(repeating: 0, count: 4))
        XCTAssertEqual(Data(second.envelope[8..<12]), Data(repeating: 0, count: 3) + Data([1]))
        XCTAssertNotEqual(Data(first.envelope.prefix(12)), Data(second.envelope.prefix(12)))
        XCTAssertEqual(secrets.records.keys.filter { $0.account.hasPrefix("metadata-nonce.v2.") }.count, 1)
        XCTAssertFalse(secrets.records.keys.contains { $0.account.hasPrefix("metadata-nonce.v1.") })
    }

    func testDevicesSharingMetadataMaterialUseDistinctNonceStreamsAndReadmissionIdentityChangesNamespace() async throws {
        let genesis = try forkCommit("forkB")
        let originalIdentity = try fixtureIdentity()
        let original = try fixtureCoordinator(
            identity: originalIdentity,
            store: InMemoryAccountSecretStore(),
            service: "test.trust.nonce-device-original"
        )
        try await original.acceptHistory([genesis])
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pendingIdentity = try AccountDeviceIdentity(
            signingPrivateKey: scalar(12),
            agreementPrivateKey: scalar(13)
        )
        let admission = try await admit(
            deviceID: pendingID,
            identity: pendingIdentity,
            to: original,
            digestByte: 0xD5,
            nonceByte: 0xD6
        )
        let pending = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: pendingID,
            platform: .ios,
            deviceIdentity: pendingIdentity,
            trustStore: testTrustStore(
                secretStore: InMemoryAccountSecretStore(),
                service: "test.trust.nonce-device-pending"
            ),
            initialCommit: genesis,
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xD7, count: $0) }
        )
        try await pending.acceptHistory(
            [admission.commit],
            authorizationContext: AccountTrustAuthorizationContext(admissions: [admission.evidence])
        )

        let originalRecord = try await original.sealAccountRecord(
            id: try AccountRecordID("90000000-0000-4000-8000-000000000001"),
            plaintext: Data("original".utf8)
        )
        let pendingRecord = try await pending.sealAccountRecord(
            id: try AccountRecordID("90000000-0000-4000-8000-000000000002"),
            plaintext: Data("pending".utf8)
        )
        XCTAssertNotEqual(Data(originalRecord.envelope.prefix(8)), Data(pendingRecord.envelope.prefix(8)))
        XCTAssertEqual(Data(originalRecord.envelope[8..<12]), Data(repeating: 0, count: 4))
        XCTAssertEqual(Data(pendingRecord.envelope[8..<12]), Data(repeating: 0, count: 4))

        let originalMember = try XCTUnwrap(admission.commit.state.members.first {
            $0.deviceID == genesis.state.signerDeviceID
        })
        let readmittedMember = try AccountDeviceTrustRecord(
            accountID: originalMember.accountID,
            epoch: originalMember.epoch,
            revision: try PositiveUInt64(originalMember.revision.value + 1),
            deviceID: originalMember.deviceID,
            platform: originalMember.platform,
            publicBundle: try AccountPublicKeyBundle(
                signingKey: try publicKey(scalar(14), agreement: false),
                agreementKey: try publicKey(scalar(15), agreement: true)
            ),
            signerDeviceID: originalMember.signerDeviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let metadataKey = try fixtureRoleFreeKey("metadataKeyHex")
        let generation = admission.commit.state.keyGeneration
        XCTAssertNotEqual(
            AccountTrustCoordinator.metadataNonceNamespace(metadataKey: metadataKey, keyGeneration: generation, member: originalMember),
            AccountTrustCoordinator.metadataNonceNamespace(metadataKey: metadataKey, keyGeneration: generation, member: readmittedMember)
        )

        let resignedMember = try AccountDeviceTrustRecord(
            accountID: originalMember.accountID,
            epoch: originalMember.epoch,
            revision: try PositiveUInt64(originalMember.revision.value + 1),
            deviceID: originalMember.deviceID,
            platform: originalMember.platform,
            publicBundle: originalMember.publicBundle,
            signerDeviceID: originalMember.signerDeviceID,
            signature: Data(repeating: 2, count: 64)
        )
        XCTAssertNotEqual(
            AccountTranscript.signedTrustRecord(originalMember),
            AccountTranscript.signedTrustRecord(resignedMember)
        )
        XCTAssertEqual(
            AccountTrustCoordinator.metadataNonceNamespace(metadataKey: metadataKey, keyGeneration: generation, member: originalMember),
            AccountTrustCoordinator.metadataNonceNamespace(metadataKey: metadataKey, keyGeneration: generation, member: resignedMember),
            "trust revisions must not change the namespace for one unchanged device identity"
        )
    }

    func testMetadataNonceCounterOverflowFailsClosedWithoutReusingNonce() throws {
        let secrets = InMemoryAccountSecretStore()
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let service = "test.trust.nonce-overflow"
        let store = AccountTrustStore(
            secretStore: secrets,
            service: service,
            operationFence: ImmediateAccountOperationFence()
        )
        _ = try store.nextMetadataNonce(
            accountID: accountID,
            epoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            keyGeneration: try PositiveUInt64(1),
            namespace: Data(repeating: 0xA2, count: 8)
        )
        let key = AccountSecretKey(
            service: service,
            account: "metadata-nonce.v2.\(accountID.rawValue).1.1"
        )
        try secrets.replace(
            JSONEncoder().encode(MetadataNonceState(version: 2, namespace: Data(repeating: 0xA2, count: 8), nextCounter: .max)),
            key: key,
            attributes: .deviceOnly
        )
        XCTAssertThrowsError(try store.nextMetadataNonce(
            accountID: accountID,
            epoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            keyGeneration: try PositiveUInt64(1),
            namespace: Data(repeating: 0xA2, count: 8)
        ))
        let unchanged = try XCTUnwrap(secrets.load(key))
        XCTAssertEqual(try JSONDecoder().decode(MetadataNonceState.self, from: unchanged.value).nextCounter, .max)
    }

    func testRecordHighWaterIndexCountsNewIDsOnceAndCapsDistinctRows() throws {
        let backing = InMemoryAccountSecretStore()
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let service = "test.trust.record-index"
        let store = AccountTrustStore(secretStore: backing, service: service, operationFence: ImmediateAccountOperationFence())
        let firstID = try AccountRecordID("55555555-5555-4555-8555-555555555555")
        try store.saveRecordHighWater(try recordHighWater(revision: 1), accountID: accountID, recordID: firstID)
        try store.saveRecordHighWater(try recordHighWater(revision: 2), accountID: accountID, recordID: firstID)
        let indexKey = AccountSecretKey(service: service, account: "account-record-high-water-index.v1.\(accountID.rawValue)")
        XCTAssertEqual(try JSONDecoder().decode(StoredRecordHighWaterIndex.self, from: try XCTUnwrap(backing.load(indexKey)).value).recordIDs, [firstID.rawValue])

        var full = StoredRecordHighWaterIndex()
        full.recordIDs = (0..<AccountRecordInventoryProofV1.maximumEntries).map {
            String(format: "00000000-0000-4000-8000-%012x", $0)
        }
        try backing.replace(JSONEncoder().encode(full), key: indexKey, attributes: .deviceOnly)
        XCTAssertThrowsError(try store.saveRecordHighWater(
            try recordHighWater(revision: 1),
            accountID: accountID,
            recordID: try AccountRecordID("ffffffff-ffff-4fff-8fff-ffffffffffff")
        ))
        XCTAssertEqual(backing.records.keys.filter { $0.account.hasPrefix("account-record-high-water.v1.") }.count, 1)
    }

    func testRecordHighWaterReservationCrashStaysBoundedAndSameIDRetries() throws {
        let backing = InMemoryAccountSecretStore()
        let crashing = HighWaterWriteCrashSecretStore(backing: backing)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let service = "test.trust.record-index-crash"
        let recordID = try AccountRecordID("66666666-6666-4666-8666-666666666666")
        let failed = AccountTrustStore(secretStore: crashing, service: service, operationFence: ImmediateAccountOperationFence())
        XCTAssertThrowsError(try failed.saveRecordHighWater(try recordHighWater(revision: 1), accountID: accountID, recordID: recordID))
        let indexKey = AccountSecretKey(service: service, account: "account-record-high-water-index.v1.\(accountID.rawValue)")
        XCTAssertEqual(try JSONDecoder().decode(StoredRecordHighWaterIndex.self, from: try XCTUnwrap(backing.load(indexKey)).value).recordIDs, [recordID.rawValue])
        XCTAssertEqual(backing.records.count, 1)

        let retry = AccountTrustStore(secretStore: backing, service: service, operationFence: ImmediateAccountOperationFence())
        try retry.saveRecordHighWater(try recordHighWater(revision: 1), accountID: accountID, recordID: recordID)
        XCTAssertEqual(try JSONDecoder().decode(StoredRecordHighWaterIndex.self, from: try XCTUnwrap(backing.load(indexKey)).value).recordIDs, [recordID.rawValue])
        XCTAssertEqual(backing.records.count, 2)
    }

    func testMalformedAndOverCapRecordHighWaterIndexesFailClosed() throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        var overCap = StoredRecordHighWaterIndex()
        overCap.recordIDs = (0...AccountRecordInventoryProofV1.maximumEntries).map {
            String(format: "00000000-0000-4000-8000-%012x", $0)
        }
        for (service, value) in [
            ("test.trust.record-index-malformed", Data("not-json".utf8)),
            ("test.trust.record-index-over-cap", try JSONEncoder().encode(overCap)),
        ] {
            let backing = InMemoryAccountSecretStore()
            try backing.replace(value, key: AccountSecretKey(service: service, account: "account-record-high-water-index.v1.\(accountID.rawValue)"), attributes: .deviceOnly)
            let store = AccountTrustStore(secretStore: backing, service: service, operationFence: ImmediateAccountOperationFence())
            XCTAssertThrowsError(try store.saveRecordHighWater(
                try recordHighWater(revision: 1),
                accountID: accountID,
                recordID: try AccountRecordID("77777777-7777-4777-8777-777777777777")
            ))
            XCTAssertEqual(backing.records.count, 1)
        }
    }

    func testExpiredApprovalAndSyncNodeAuthorizationsFailBeforeStateChange() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        try await coordinator.accept(try forkCommit("forkB"))
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let bundle = try AccountPublicKeyBundle(signingKey: try publicKey(scalar(12), agreement: false), agreementKey: try publicKey(scalar(13), agreement: true))
        let expired = try PendingAccountDevice(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: pendingID,
            platform: .ios,
            publicBundle: bundle,
            exchangeRequestDigest: Data(repeating: 0x25, count: 32),
            createdAt: "2024-12-31T23:54:00Z",
            expiresAt: "2024-12-31T23:59:00Z"
        )
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.beginApproval(of: expired) }
        let unchangedCommit = try await coordinator.currentTrustCommit()
        XCTAssertEqual(unchangedCommit, try forkCommit("forkB"))

        XCTAssertThrowsError(try PendingAccountDevice(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: pendingID,
            platform: .syncNode,
            publicBundle: bundle,
            exchangeRequestDigest: Data(repeating: 0x25, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        ))
    }

    func testApprovalAnchorsOfferCreationToCentralPendingTimestamp() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try AccountTrustCoordinator(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: identity,
            trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust.central-pending-time"),
            now: { Date(timeIntervalSince1970: 1_735_689_690.003) },
            random: { Data(repeating: 0x42, count: $0) }
        )
        let pending = try PendingAccountDevice(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            platform: .ios,
            publicBundle: try AccountPublicKeyBundle(
                signingKey: try publicKey(scalar(12), agreement: false),
                agreementKey: try publicKey(scalar(13), agreement: true)
            ),
            exchangeRequestDigest: Data(repeating: 0x25, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )

        let offer = try await coordinator.beginApproval(of: pending)

        XCTAssertEqual(offer.createdAtUnixMilliseconds.value, 1_735_689_600_000)
    }

    func testAdmissionPackagesCurrentMaterialToNewDeviceAndSurvivorCanRemoveFormerSigner() async throws {
        let originalIdentity = try fixtureIdentity()
        let original = try fixtureCoordinator(identity: originalIdentity, store: InMemoryAccountSecretStore())
        let predecessor = try forkCommit("forkB")
        try await original.accept(predecessor)
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let pending = try PendingAccountDevice(
            accountID: predecessor.state.accountID,
            deviceID: pendingID,
            platform: .ios,
            publicBundle: pendingIdentity.publicBundle,
            exchangeRequestDigest: Data(repeating: 0x71, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let offer = try await original.beginApproval(of: pending)
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: 0x72, count: 32))
        _ = try await original.approve(response, authenticationConfirmed: true)
        let currentAdmission = try await original.currentTrustCommit()
        let admission = try XCTUnwrap(currentAdmission)
        XCTAssertEqual(admission.keyPackages.count, 2)
        XCTAssertEqual(admission.keyPackages.map(\.recipientDeviceID), admission.state.members.map(\.deviceID))
        XCTAssertEqual(admission.state.transition.kind, .admission)
        XCTAssertEqual(admission.state.transition.targetDeviceIDs, [pendingID])
        XCTAssertEqual(admission.state.transition.pendingDeviceDigest, Data(SHA256.hash(data: AccountTranscript.pendingDeviceAuthorization(pending))))
        XCTAssertEqual(admission.state.transition.handshakeDigest, AccountTrustAuthentication.handshakeDigest(response))

        let pendingCoordinator = try AccountTrustCoordinator(
            accountID: predecessor.state.accountID,
            deviceID: pendingID,
            platform: .ios,
            deviceIdentity: pendingIdentity,
            trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust.pending.\(UUID().uuidString)"),
            initialCommit: predecessor,
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x73, count: $0) }
        )
        try await pendingCoordinator.acceptHistory(
            [admission],
            authorizationContext: AccountTrustAuthorizationContext(
                admissions: [AccountTrustAdmissionEvidence(pendingDevice: pending, response: response)]
            )
        )
        let pendingMailbox = try await pendingCoordinator.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        let originalMailbox = try await original.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        XCTAssertEqual(pendingMailbox, originalMailbox)

        let survivorBefore = try XCTUnwrap(admission.state.members.first(where: { $0.deviceID == pendingID }))
        let removal = try await pendingCoordinator.revoke(predecessor.state.signerDeviceID)
        let survivorAfter = try XCTUnwrap(removal.state.members.first)
        XCTAssertEqual(AccountTranscript.signedTrustRecord(survivorAfter), AccountTranscript.signedTrustRecord(survivorBefore))
        XCTAssertEqual(removal.state.signerDeviceID, pendingID)
        XCTAssertEqual(removal.state.keyGeneration.value, 2)
        XCTAssertFalse(removal.state.members.contains(where: { $0.deviceID == predecessor.state.signerDeviceID }))
    }

    func testCheckpointRejectsSameCoordinatePackageForkAfterRelaunch() async throws {
        let identity = try fixtureIdentity()
        let secrets = InMemoryAccountSecretStore()
        let trustStore = testTrustStore(secretStore: secrets, service: "test.trust.checkpoint")
        let first = try AccountTrustCoordinator(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: identity,
            trustStore: trustStore,
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x74, count: $0) }
        )
        let forkB = try forkCommit("forkB")
        try await first.accept(forkB)
        await XCTAssertThrowsErrorAsync { try await first.accept(try forkCommit("forkA")) }
        XCTAssertThrowsError(try AccountTrustCoordinator(
            accountID: forkB.state.accountID,
            deviceID: forkB.state.signerDeviceID,
            platform: .macos,
            deviceIdentity: identity,
            trustStore: trustStore,
            initialCommit: try forkCommit("forkA"),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x74, count: $0) }
        ))
    }

    func testActiveMemberPlatformCapRejectsSixthMacAdmissionBeforePersisting() async throws {
        let coordinator = try fixtureCoordinator(identity: fixtureIdentity(), store: InMemoryAccountSecretStore())
        try await coordinator.accept(try forkCommit("forkB"))
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        for index in 1...5 {
            let deviceID = try AccountDeviceID(String(format: "20000000-0000-4000-8000-%012d", index))
            let identity = try AccountDeviceIdentity(
                signingPrivateKey: scalar(UInt8(20 + index * 2)),
                agreementPrivateKey: scalar(UInt8(21 + index * 2))
            )
            let pending = try PendingAccountDevice(
                accountID: accountID,
                deviceID: deviceID,
                platform: .macos,
                publicBundle: identity.publicBundle,
                exchangeRequestDigest: Data(repeating: UInt8(index), count: 32),
                createdAt: "2025-01-01T00:00:00Z",
                expiresAt: "2025-01-01T00:05:00Z"
            )
            let offer = try await coordinator.beginApproval(of: pending)
            let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: UInt8(50 + index), count: 32))
            if index == 5 {
                await XCTAssertThrowsErrorAsync { _ = try await coordinator.approve(response, authenticationConfirmed: true) }
            } else {
                _ = try await coordinator.approve(response, authenticationConfirmed: true)
            }
        }
        let currentCommit = try await coordinator.currentTrustCommit()
        let current = try XCTUnwrap(currentCommit)
        XCTAssertEqual(current.state.members.count, 5)
        XCTAssertEqual(current.state.members.filter({ $0.platform == .macos }).count, 5)
    }

    func testRecoveryRequiresLivePurposeAuthorizationAndCreatesFreshEpochMaterial() async throws {
        let root = try fixtureRoot()
        let authorizationMessage = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let predecessor = try forkCommit("forkB")
        let authorization = try recoveryAuthorization(try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: authorizationMessage)), replacing: predecessor)
        let replacementIdentity = try AccountDeviceIdentity(
            signingPrivateKey: try fixtureRoleScalar("exchangeSigning"),
            agreementPrivateKey: try fixtureRoleScalar("exchangeAgreement")
        )
        let coordinator = try recoveryCoordinator(identity: replacementIdentity, predecessor: predecessor)
        let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.recover(
                with: authorization,
                expectedExchangeRequestDigest: Data(repeating: 0, count: 32),
                manifestStore: manifest
            )
        }
        let unchangedPredecessor = try await coordinator.currentTrustCommit()
        XCTAssertEqual(unchangedPredecessor, predecessor)

        let wrongPlatform = try AccountRecoveryAuthorization(
            authorizationID: authorization.authorizationID,
            accountID: authorization.accountID,
            epoch: authorization.epoch,
            deviceID: authorization.deviceID,
            platform: .ios,
            publicBundle: authorization.publicBundle,
            priorCommitDigest: authorization.priorCommitDigest,
            exchangeRequestDigest: authorization.exchangeRequestDigest,
            issuedAt: authorization.issuedAt,
            expiresAt: authorization.expiresAt,
            serverKeyID: authorization.serverKeyID,
            serverSignature: authorization.serverSignature
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.recover(
                with: wrongPlatform,
                expectedExchangeRequestDigest: authorization.exchangeRequestDigest,
                manifestStore: manifest
            )
        }
        XCTAssertThrowsError(try AccountRecoveryAuthorization(
            authorizationID: authorization.authorizationID,
            accountID: authorization.accountID,
            epoch: authorization.epoch,
            deviceID: authorization.deviceID,
            platform: .syncNode,
            publicBundle: authorization.publicBundle,
            priorCommitDigest: authorization.priorCommitDigest,
            exchangeRequestDigest: authorization.exchangeRequestDigest,
            issuedAt: authorization.issuedAt,
            expiresAt: authorization.expiresAt,
            serverKeyID: authorization.serverKeyID,
            serverSignature: authorization.serverSignature
        ))

        let recovered = try await coordinator.recover(
            with: authorization,
            expectedExchangeRequestDigest: authorization.exchangeRequestDigest,
            manifestStore: manifest
        )
        XCTAssertEqual(recovered.state.epoch.value, 2)
        XCTAssertEqual(recovered.state.revision.value, 1)
        XCTAssertEqual(recovered.state.keyGeneration.value, 1)
        XCTAssertEqual(recovered.state.members.count, 1)
        XCTAssertEqual(recovered.keyPackages.count, 1)
        XCTAssertEqual(recovered.state.previousCommitDigest, commitDigest(predecessor))
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.recover(
                with: authorization,
                expectedExchangeRequestDigest: authorization.exchangeRequestDigest,
                manifestStore: manifest
            )
        }

        let expiredCoordinator = try recoveryCoordinator(identity: replacementIdentity, predecessor: predecessor)
        let expiredManifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_860) })
        await XCTAssertThrowsErrorAsync {
            _ = try await expiredCoordinator.recover(
                with: authorization,
                expectedExchangeRequestDigest: authorization.exchangeRequestDigest,
                manifestStore: expiredManifest
            )
        }
        let expiredPredecessor = try await expiredCoordinator.currentTrustCommit()
        XCTAssertEqual(expiredPredecessor, predecessor)
    }

    func testRotationRetainsOldMaterialUntilEveryDeclaredRecordIsResealedAndRetired() async throws {
        let identity = try fixtureIdentity()
        let secrets = InMemoryAccountSecretStore()
        let coordinator = try fixtureCoordinator(identity: identity, store: secrets, service: "test.trust.migration")
        try await coordinator.acceptHistory([try forkCommit("forkB")])
        let firstID = try AccountRecordID("70000000-0000-4000-8000-000000000001")
        let secondID = try AccountRecordID("70000000-0000-4000-8000-000000000002")
        let firstOld = try await coordinator.sealAccountRecord(id: firstID, plaintext: Data("first old".utf8))
        let secondOld = try await coordinator.sealAccountRecord(id: secondID, plaintext: Data("second old".utf8))

        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let admission = try await admit(
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            identity: pendingIdentity,
            to: coordinator,
            digestByte: 0x71,
            nonceByte: 0x72
        )
        _ = admission
        _ = try await coordinator.revoke(try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"))

        let openedFirstOld = try await coordinator.openAccountRecord(firstOld)
        let openedSecondOld = try await coordinator.openAccountRecord(secondOld)
        XCTAssertEqual(openedFirstOld, Data("first old".utf8))
        XCTAssertEqual(openedSecondOld, Data("second old".utf8))
        let firstNew = try await coordinator.resealAccountRecordForCurrentGeneration(firstOld)
        let secondNew = try await coordinator.resealAccountRecordForCurrentGeneration(secondOld)
        XCTAssertEqual(firstNew.keyGeneration.value, 2)
        XCTAssertEqual(secondNew.keyGeneration.value, 2)

        let migrationProof = try await signedInventoryProof(records: [firstNew, secondNew], coordinator: coordinator)
        let inventoryManifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_786_183_260) })
        await XCTAssertThrowsErrorAsync {
            try await coordinator.retireAccountKeyGeneration(
                epoch: firstOld.epoch,
                keyGeneration: firstOld.keyGeneration,
                afterMigrating: [firstNew],
                inventoryProof: migrationProof,
                manifestStore: inventoryManifest
            )
        }
        try await coordinator.retireAccountKeyGeneration(
            epoch: firstOld.epoch,
            keyGeneration: firstOld.keyGeneration,
            afterMigrating: [firstNew, secondNew],
            inventoryProof: migrationProof,
            manifestStore: inventoryManifest
        )
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.openAccountRecord(firstOld) }
        let openedFirstNew = try await coordinator.openAccountRecord(firstNew)
        let openedSecondNew = try await coordinator.openAccountRecord(secondNew)
        XCTAssertEqual(openedFirstNew, Data("first old".utf8))
        XCTAssertEqual(openedSecondNew, Data("second old".utf8))
        XCTAssertEqual(secrets.records.keys.filter({ $0.account.contains("trust-material.v3") }).count, 2)
        XCTAssertEqual(secrets.records.keys.filter({ $0.account.hasPrefix("trust-snapshot.v3.") }).count, 1)
        let pruned = try XCTUnwrap(testTrustStore(secretStore: secrets, service: "test.trust.migration").loadState(for: firstOld.accountID))
        XCTAssertTrue(pruned.retiredMaterialReferences.isEmpty)
        XCTAssertTrue(pruned.verifiedEntries.allSatisfy { $0.commit.state.keyGeneration.value == 2 })
    }

    func testRetirementRequiresLiveSignedExactFrozenInventoryProof() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore(), service: "test.trust.inventory-proof")
        try await coordinator.acceptHistory([try forkCommit("forkB")])
        let old = try await coordinator.sealAccountRecord(
            id: try AccountRecordID("70900000-0000-4000-8000-000000000001"),
            plaintext: Data("migrate me".utf8)
        )
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        _ = try await admit(
            deviceID: pendingID,
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: coordinator,
            digestByte: 0xE1,
            nonceByte: 0xE2
        )
        _ = try await coordinator.revoke(pendingID)
        let migrated = try await coordinator.resealAccountRecordForCurrentGeneration(old)
        let liveManifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_786_183_260) })

        let omitted = try await signedInventoryProof(records: [], coordinator: coordinator)
        await XCTAssertThrowsErrorAsync {
            try await coordinator.retireAccountKeyGeneration(
                epoch: old.epoch,
                keyGeneration: old.keyGeneration,
                afterMigrating: [migrated],
                inventoryProof: omitted,
                manifestStore: liveManifest
            )
        }

        let wrongPurpose = try await signedInventoryProof(
            records: [migrated],
            coordinator: coordinator,
            signingRole: "recoveryAuthorization",
            serverKeyID: "recovery-authorization-2026-01"
        )
        await XCTAssertThrowsErrorAsync {
            try await coordinator.retireAccountKeyGeneration(
                epoch: old.epoch,
                keyGeneration: old.keyGeneration,
                afterMigrating: [migrated],
                inventoryProof: wrongPurpose,
                manifestStore: liveManifest
            )
        }


        let expired = try await signedInventoryProof(
            records: [migrated],
            coordinator: coordinator,
            issuedAt: "2026-08-08T09:00:00Z",
            expiresAt: "2026-08-08T09:05:00Z"
        )
        await XCTAssertThrowsErrorAsync {
            try await coordinator.retireAccountKeyGeneration(
                epoch: old.epoch,
                keyGeneration: old.keyGeneration,
                afterMigrating: [migrated],
                inventoryProof: expired,
                manifestStore: liveManifest
            )
        }

        let staleHead = try await signedInventoryProof(
            records: [migrated],
            coordinator: coordinator,
            trustCommitDigestOverride: Data(repeating: 0xEE, count: 32)
        )
        await XCTAssertThrowsErrorAsync {
            try await coordinator.retireAccountKeyGeneration(
                epoch: old.epoch,
                keyGeneration: old.keyGeneration,
                afterMigrating: [migrated],
                inventoryProof: staleHead,
                manifestStore: liveManifest
            )
        }

        let valid = try await signedInventoryProof(records: [migrated], coordinator: coordinator)
        try await coordinator.retireAccountKeyGeneration(
            epoch: old.epoch,
            keyGeneration: old.keyGeneration,
            afterMigrating: [migrated],
            inventoryProof: valid,
            manifestStore: liveManifest
        )
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.openAccountRecord(old) }
    }

    func testZeroRecordGenerationCanBeRetiredAndStaleCoordinatorReconcilesBeforeSealAndOpen() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.stale-retirement"
        let first = try fixtureCoordinator(identity: identity, store: backing, service: service)
        try await first.acceptHistory([try forkCommit("forkB")])
        let stale = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let old = try await first.sealAccountRecord(
            id: try AccountRecordID("71000000-0000-4000-8000-000000000001"),
            plaintext: Data("old".utf8)
        )
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        _ = try await admit(
            deviceID: pendingID,
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: first,
            digestByte: 0x81,
            nonceByte: 0x82
        )
        _ = try await first.revoke(pendingID)
        let migrated = try await first.resealAccountRecordForCurrentGeneration(old)
        try await retireWithSignedInventory(coordinator: first, epoch: old.epoch, keyGeneration: old.keyGeneration, records: [migrated])

        let fresh = try await stale.sealAccountRecord(
            id: try AccountRecordID("71000000-0000-4000-8000-000000000002"),
            plaintext: Data("fresh".utf8)
        )
        XCTAssertEqual(fresh.keyGeneration.value, 2)
        await XCTAssertThrowsErrorAsync { _ = try await stale.openAccountRecord(old) }

        // A complete authenticated empty inventory is valid for a generation
        // that has no account records, not only as an idempotent retry.
        let emptyBacking = InMemoryAccountSecretStore()
        let empty = try fixtureCoordinator(identity: identity, store: emptyBacking, service: "test.trust.empty-retirement")
        let genesis = try forkCommit("forkB")
        try await empty.acceptHistory([genesis])
        _ = try await admit(
            deviceID: pendingID,
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: empty,
            digestByte: 0x85,
            nonceByte: 0x86
        )
        _ = try await empty.revoke(pendingID)
        try await retireWithSignedInventory(coordinator: empty, epoch: genesis.state.epoch, keyGeneration: genesis.state.keyGeneration, records: [])
        XCTAssertEqual(emptyBacking.records.keys.filter { $0.account.hasPrefix("trust-material.v3.") }.count, 2)
    }

    func testPostCASCleanupFailureReturnsCommittedStateAndRetriesWithoutUsingRetiredMaterial() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let failing = DeleteOnceSecretStore(backing: backing)
        let service = "test.trust.cleanup-failure"
        let coordinator = try fixtureCoordinator(identity: identity, secretStore: failing, service: service)
        try await coordinator.acceptHistory([try forkCommit("forkB")])
        let old = try await coordinator.sealAccountRecord(
            id: try AccountRecordID("72000000-0000-4000-8000-000000000001"),
            plaintext: Data("old".utf8)
        )
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        _ = try await admit(
            deviceID: pendingID,
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: coordinator,
            digestByte: 0x83,
            nonceByte: 0x84
        )
        _ = try await coordinator.revoke(pendingID)
        let migrated = try await coordinator.resealAccountRecordForCurrentGeneration(old)

        try await retireWithSignedInventory(coordinator: coordinator, epoch: old.epoch, keyGeneration: old.keyGeneration, records: [migrated])
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.openAccountRecord(old) }
        let openedMigrated = try await coordinator.openAccountRecord(migrated)
        XCTAssertEqual(openedMigrated, Data("old".utf8))

        // A later operation retries tombstone cleanup and garbage collection.
        _ = try await coordinator.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        XCTAssertEqual(backing.records.keys.filter { $0.account.hasPrefix("trust-snapshot.v3.") }.count, 1)
        XCTAssertEqual(backing.records.keys.filter { $0.account.hasPrefix("trust-material.v3.") }.count, 2)
    }

    func testImmutableVersionRecordsMakeAHeadCASCrashRetryable() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let crash = HeadCASCrashSecretStore(backing: backing)
        let failed = try fixtureCoordinator(identity: identity, secretStore: crash, service: "test.trust.crash")
        await XCTAssertThrowsErrorAsync { try await failed.acceptHistory([try forkCommit("forkB")]) }
        let journalKey = AccountSecretKey(
            service: "test.trust.crash",
            account: "trust-gc-index.v1.00112233-4455-6677-8899-aabbccddeeff"
        )
        let stranded = try JSONDecoder().decode(
            StoredTrustGCIndex.self,
            from: try XCTUnwrap(backing.load(journalKey)).value
        )
        XCTAssertEqual(stranded.snapshots.count, 1)
        XCTAssertEqual(stranded.material.count, 2)
        XCTAssertTrue(backing.records.keys.contains(where: { $0.account.contains("trust-material.v3") }))

        // A new fenced read after the failed writer releases the operation
        // fence deletes the exact journaled orphan set before reporting no head.
        let failedHead = try await failed.currentTrustCommit()
        XCTAssertNil(failedHead)
        XCTAssertFalse(backing.records.keys.contains(where: { $0.account.contains("trust-material.v3") }))
        XCTAssertFalse(backing.records.keys.contains(where: { $0.account.contains("trust-snapshot.v3") }))
        XCTAssertFalse(backing.records.keys.contains(where: { $0.account == "trust-head.v3.00112233-4455-6677-8899-aabbccddeeff" }))

        let retry = try fixtureCoordinator(identity: identity, store: backing, service: "test.trust.crash")
        try await retry.acceptHistory([try forkCommit("forkB")])
        let retryHead = try await retry.currentTrustCommit()
        XCTAssertNotNil(retryHead)
        _ = try await retry.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        XCTAssertEqual(backing.records.keys.filter({ $0.account.hasPrefix("trust-snapshot.v3.") }).count, 1)
        XCTAssertEqual(backing.records.keys.filter({ $0.account.hasPrefix("trust-material.v3.") }).count, 2)
    }

    func testGCJournalDeleteFailureRetainsBoundedRetryStateAndBlocksNewWrites() async throws {
        let backing = InMemoryAccountSecretStore()
        let failing = DeleteAlwaysSecretStore(backing: backing)
        let service = "test.trust.gc-retry"
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let orphan = AccountSecretKey(
            service: service,
            account: "trust-snapshot.v3.\(accountID.rawValue).\(AccountWireCodec.encodeBase64URL(Data(repeating: 0xF1, count: 32)))"
        )
        var journal = StoredTrustGCIndex()
        try journal.insert(
            orphan.account,
            kind: .snapshot,
            accountID: accountID,
            maximumRetainedGenerations: 1
        )
        let journalKey = AccountSecretKey(service: service, account: "trust-gc-index.v1.\(accountID.rawValue)")
        try backing.replace(Data("orphan".utf8), key: orphan, attributes: .deviceOnly)
        try backing.replace(JSONEncoder().encode(journal), key: journalKey, attributes: .deviceOnly)
        let store = AccountTrustStore(
            secretStore: failing,
            service: service,
            maximumRetainedGenerations: 1,
            operationFence: testAccountOperationFence
        )

        XCTAssertThrowsError(try store.loadState(for: accountID))
        XCTAssertNotNil(try backing.load(orphan))
        XCTAssertEqual(try JSONDecoder().decode(
            StoredTrustGCIndex.self,
            from: try XCTUnwrap(backing.load(journalKey)).value
        ), journal)

        XCTAssertThrowsError(try AccountTrustCoordinator(
            accountID: accountID,
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: try fixtureIdentity(),
            trustStore: store,
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xB1, count: $0) }
        ))
        XCTAssertEqual(backing.records.count, 2)
    }

    func testMalformedAndOverCapGCJournalsFailClosedBeforeProcessing() throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        for (service, value) in [
            ("test.trust.gc-malformed", Data("not-json".utf8)),
            ("test.trust.gc-over-cap", try overCapGCJournalData(accountID: accountID)),
        ] {
            let backing = InMemoryAccountSecretStore()
            try backing.replace(
                value,
                key: AccountSecretKey(service: service, account: "trust-gc-index.v1.\(accountID.rawValue)"),
                attributes: .deviceOnly
            )
            let store = AccountTrustStore(
                secretStore: backing,
                service: service,
                maximumRetainedGenerations: 1,
                operationFence: testAccountOperationFence
            )
            XCTAssertThrowsError(try store.loadState(for: accountID))
            XCTAssertEqual(backing.records.count, 1)
        }
    }

    func testGCJournalRejectsCrossAccountMismatchedKindAndNearPrefixBeforeAnyDelete() throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let otherAccountID = try PlainpostAccountID("10112233-4455-6677-8899-aabbccddeeff")
        let locator = AccountWireCodec.encodeBase64URL(Data(repeating: 0xA1, count: 32))
        let invalidAccounts = [
            "trust-snapshot.v3.\(otherAccountID.rawValue).\(locator)",
            "trust-material.v3.\(accountID.rawValue).\(locator).matching",
            "trust-snapshot.v3.\(accountID.rawValue)x.\(locator)",
        ]

        for (index, invalidAccount) in invalidAccounts.enumerated() {
            let service = "test.trust.gc-scope-\(index)"
            let backing = InMemoryAccountSecretStore()
            let victim = AccountSecretKey(service: service, account: invalidAccount)
            try backing.replace(Data("must-survive".utf8), key: victim, attributes: .deviceOnly)
            var journal = StoredTrustGCIndex()
            journal.snapshots = [invalidAccount]
            try backing.replace(
                JSONEncoder().encode(journal),
                key: AccountSecretKey(service: service, account: "trust-gc-index.v1.\(accountID.rawValue)"),
                attributes: .deviceOnly
            )
            let store = AccountTrustStore(
                secretStore: backing,
                service: service,
                maximumRetainedGenerations: 1,
                operationFence: testAccountOperationFence
            )

            XCTAssertThrowsError(try store.loadState(for: accountID))
            XCTAssertEqual(try backing.load(victim)?.value, Data("must-survive".utf8))
            XCTAssertEqual(backing.records.count, 2)
        }
    }

    func testCrossAccountRetiredMaterialReferenceFailsBeforeCleanupDeletesAnything() async throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let otherAccountID = try PlainpostAccountID("10112233-4455-6677-8899-aabbccddeeff")
        let service = "test.trust.retired-reference-scope"
        let backing = InMemoryAccountSecretStore()
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try AccountTrustCoordinator(
            accountID: accountID,
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: try fixtureIdentity(),
            trustStore: trustStore,
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xA1, count: $0) }
        )
        try await coordinator.accept(try forkCommit("forkB"))

        let headKey = AccountSecretKey(service: service, account: "trust-head.v3.\(accountID.rawValue)")
        var head = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(backing.load(headKey)).value
        ) as? [String: Any])
        let oldSnapshotKey = try XCTUnwrap(backing.records.keys.first {
            $0.account.hasPrefix("trust-snapshot.v3.\(accountID.rawValue).")
        })
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(backing.load(oldSnapshotKey)).value
        ) as? [String: Any])
        var reference = try XCTUnwrap((snapshot["materialReferences"] as? [[String: Any]])?.first)
        reference["accountID"] = otherAccountID.rawValue
        snapshot["materialReferences"] = []
        snapshot["retiredMaterialReferences"] = [reference]
        let corruptedSnapshot = try JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let corruptedDigest = Data(SHA256.hash(data: corruptedSnapshot))
        let corruptedSnapshotKey = AccountSecretKey(
            service: service,
            account: "trust-snapshot.v3.\(accountID.rawValue).\(AccountWireCodec.encodeBase64URL(corruptedDigest))"
        )
        try backing.replace(corruptedSnapshot, key: corruptedSnapshotKey, attributes: .deviceOnly)
        head["snapshotDigest"] = corruptedDigest.base64EncodedString()
        try backing.replace(
            JSONSerialization.data(withJSONObject: head, options: [.sortedKeys, .withoutEscapingSlashes]),
            key: headKey,
            attributes: .deviceOnly
        )

        let locator = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(reference["locator"] as? String)))
        XCTAssertEqual(locator.count, 32)
        let victimKeys = [
            AccountSecretKey(service: service, account: "trust-material.v3.\(otherAccountID.rawValue).\(AccountWireCodec.encodeBase64URL(locator)).matching"),
            AccountSecretKey(service: service, account: "trust-material.v3.\(otherAccountID.rawValue).\(AccountWireCodec.encodeBase64URL(locator)).metadata"),
            AccountSecretKey(service: service, account: "metadata-nonce.v2.\(otherAccountID.rawValue).1.1"),
        ]
        for key in victimKeys {
            try backing.replace(Data("must-survive".utf8), key: key, attributes: .deviceOnly)
        }

        XCTAssertThrowsError(try trustStore.loadState(for: accountID))
        for key in victimKeys {
            XCTAssertEqual(try backing.load(key)?.value, Data("must-survive".utf8))
        }
    }

    func testRetiredReferencesCannotAliasAnActiveOrAnotherRetiredLocatorBeforeCleanup() async throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        for retiredCount in [1] {
            let service = "test.trust.retired-locator-alias-\(retiredCount)"
            let backing = InMemoryAccountSecretStore()
            let trustStore = testTrustStore(secretStore: backing, service: service)
            let coordinator = try AccountTrustCoordinator(
                accountID: accountID,
                deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                platform: .macos,
                deviceIdentity: try fixtureIdentity(),
                trustStore: trustStore,
                now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
                random: { Data(repeating: 0xA1, count: $0) }
            )
            try await coordinator.accept(try forkCommit("forkB"))

            let headKey = AccountSecretKey(service: service, account: "trust-head.v3.\(accountID.rawValue)")
            var head = try XCTUnwrap(JSONSerialization.jsonObject(
                with: try XCTUnwrap(backing.load(headKey)).value
            ) as? [String: Any])
            let oldSnapshotKey = try XCTUnwrap(backing.records.keys.first {
                $0.account.hasPrefix("trust-snapshot.v3.\(accountID.rawValue).")
            })
            var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(
                with: try XCTUnwrap(backing.load(oldSnapshotKey)).value
            ) as? [String: Any])
            let activeReference = try XCTUnwrap((snapshot["materialReferences"] as? [[String: Any]])?.first)
            snapshot["retiredMaterialReferences"] = (0..<retiredCount).map { index in
                var retired = activeReference
                retired["epoch"] = String(index + 2)
                retired["keyGeneration"] = String(index + 2)
                return retired
            }
            let corruptedSnapshot = try JSONSerialization.data(
                withJSONObject: snapshot,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let corruptedDigest = Data(SHA256.hash(data: corruptedSnapshot))
            try backing.replace(
                corruptedSnapshot,
                key: AccountSecretKey(
                    service: service,
                    account: "trust-snapshot.v3.\(accountID.rawValue).\(AccountWireCodec.encodeBase64URL(corruptedDigest))"
                ),
                attributes: .deviceOnly
            )
            head["snapshotDigest"] = corruptedDigest.base64EncodedString()
            try backing.replace(
                JSONSerialization.data(withJSONObject: head, options: [.sortedKeys, .withoutEscapingSlashes]),
                key: headKey,
                attributes: .deviceOnly
            )
            let activeMaterialKeys = backing.records.keys.filter {
                $0.account.hasPrefix("trust-material.v3.\(accountID.rawValue).")
            }
            XCTAssertEqual(activeMaterialKeys.count, 2)

            XCTAssertThrowsError(try trustStore.loadState(for: accountID))
            for key in activeMaterialKeys {
                XCTAssertNotNil(try backing.load(key))
            }
        }
    }

    func testTwoRetiredReferencesCannotShareANewLocatorBeforeCleanupDeletesVictims() async throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let service = "test.trust.retired-locator-duplicate"
        let backing = InMemoryAccountSecretStore()
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try AccountTrustCoordinator(
            accountID: accountID,
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: try fixtureIdentity(),
            trustStore: trustStore,
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xA1, count: $0) }
        )
        try await coordinator.accept(try forkCommit("forkB"))

        let headKey = AccountSecretKey(service: service, account: "trust-head.v3.\(accountID.rawValue)")
        var head = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(backing.load(headKey)).value
        ) as? [String: Any])
        let oldSnapshotKey = try XCTUnwrap(backing.records.keys.first {
            $0.account.hasPrefix("trust-snapshot.v3.\(accountID.rawValue).")
        })
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(backing.load(oldSnapshotKey)).value
        ) as? [String: Any])
        let activeReference = try XCTUnwrap((snapshot["materialReferences"] as? [[String: Any]])?.first)
        let sharedLocator = Data(repeating: 0xB2, count: 32)
        snapshot["retiredMaterialReferences"] = (0..<2).map { index in
            var retired = activeReference
            retired["epoch"] = String(index + 2)
            retired["keyGeneration"] = String(index + 2)
            retired["locator"] = sharedLocator.base64EncodedString()
            return retired
        }
        let corruptedSnapshot = try JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let corruptedDigest = Data(SHA256.hash(data: corruptedSnapshot))
        try backing.replace(
            corruptedSnapshot,
            key: AccountSecretKey(
                service: service,
                account: "trust-snapshot.v3.\(accountID.rawValue).\(AccountWireCodec.encodeBase64URL(corruptedDigest))"
            ),
            attributes: .deviceOnly
        )
        head["snapshotDigest"] = corruptedDigest.base64EncodedString()
        try backing.replace(
            JSONSerialization.data(withJSONObject: head, options: [.sortedKeys, .withoutEscapingSlashes]),
            key: headKey,
            attributes: .deviceOnly
        )

        let locatorWire = AccountWireCodec.encodeBase64URL(sharedLocator)
        let victims = [
            AccountSecretKey(service: service, account: "trust-material.v3.\(accountID.rawValue).\(locatorWire).matching"),
            AccountSecretKey(service: service, account: "trust-material.v3.\(accountID.rawValue).\(locatorWire).metadata"),
        ]
        for (index, key) in victims.enumerated() {
            try backing.replace(Data("victim-\(index)".utf8), key: key, attributes: .deviceOnly)
        }
        let before = try Dictionary(uniqueKeysWithValues: victims.map { key in
            (key, try XCTUnwrap(backing.load(key)).value)
        })

        XCTAssertThrowsError(try trustStore.loadState(for: accountID))
        let after = try Dictionary(uniqueKeysWithValues: victims.map { key in
            (key, try XCTUnwrap(backing.load(key)).value)
        })
        XCTAssertEqual(after, before)
    }

    func testHistoryPageCrashLeavesOnlyAVerifiedResumablePrefix() async throws {
        let genesis = try forkCommit("forkB")
        let source = try fixtureCoordinator(identity: fixtureIdentity(), store: InMemoryAccountSecretStore(), service: "test.trust.page.source")
        try await source.acceptHistory([genesis])
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let admission = try await admit(deviceID: pendingID, identity: pendingIdentity, to: source, digestByte: 0x31, nonceByte: 0x32)
        let context = AccountTrustAuthorizationContext(admissions: [admission.evidence])

        let backing = InMemoryAccountSecretStore()
        let crashing = HeadCASCrashSecretStore(backing: backing, crashOnHeadCAS: 2)
        let receiver = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: pendingID,
            platform: .ios,
            deviceIdentity: pendingIdentity,
            trustStore: testTrustStore(secretStore: crashing, service: "test.trust.page.receiver"),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x33, count: $0) }
        )
        await XCTAssertThrowsErrorAsync {
            try await receiver.acceptHistory([genesis, admission.commit], authorizationContext: context)
        }

        let relaunched = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: pendingID,
            platform: .ios,
            deviceIdentity: pendingIdentity,
            trustStore: testTrustStore(secretStore: backing, service: "test.trust.page.receiver"),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x34, count: $0) }
        )
        let prefix = try await relaunched.currentTrustCommit()
        XCTAssertEqual(prefix, genesis)
        try await relaunched.acceptHistory([admission.commit], authorizationContext: context)
        let resumed = try await relaunched.currentTrustCommit()
        XCTAssertEqual(resumed, admission.commit)
    }

    func testRacingRotationControllersCannotCorruptTheWinningHeadOrMaterial() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.race"
        let source = try fixtureCoordinator(identity: identity, store: backing, service: service)
        try await source.acceptHistory([try forkCommit("forkB")])
        let secondID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let thirdID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000d")
        _ = try await admit(deviceID: secondID, identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)), to: source, digestByte: 0x41, nonceByte: 0x42)
        _ = try await admit(deviceID: thirdID, identity: try AccountDeviceIdentity(signingPrivateKey: scalar(14), agreementPrivateKey: scalar(15)), to: source, digestByte: 0x43, nonceByte: 0x44)

        let left = try AccountTrustCoordinator(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: identity,
            trustStore: testTrustStore(secretStore: backing, service: service),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xA1, count: $0) }
        )
        let right = try AccountTrustCoordinator(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: identity,
            trustStore: testTrustStore(secretStore: backing, service: service),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xB2, count: $0) }
        )

        let firstRotation = try await left.revoke(secondID)
        let winner = try await right.revoke(thirdID)
        XCTAssertEqual(winner.state.previousCommitDigest, commitDigest(firstRotation))
        let winnerRecord = try await right.sealAccountRecord(id: try AccountRecordID("80000000-0000-4000-8000-000000000001"), plaintext: Data("winner".utf8))

        let relaunched = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let restoredWinner = try await relaunched.currentTrustCommit()
        XCTAssertEqual(restoredWinner, winner)
        let openedWinner = try await relaunched.openAccountRecord(winnerRecord)
        XCTAssertEqual(openedWinner, Data("winner".utf8))
    }

    func testSameHeadRetirementsReconcileDistinctSnapshotContentWithoutFalseIdempotence() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.same-head-retire"
        let source = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await source.acceptHistory([genesis])
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        _ = try await admit(deviceID: pendingID, identity: pendingIdentity, to: source, digestByte: 0x91, nonceByte: 0x92)
        _ = try await source.revoke(pendingID)
        _ = try await admit(deviceID: pendingID, identity: pendingIdentity, to: source, digestByte: 0x93, nonceByte: 0x94)
        let generationThree = try await source.revoke(pendingID)
        XCTAssertEqual(generationThree.state.keyGeneration.value, 3)

        let left = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let right = try fixtureCoordinator(identity: identity, store: backing, service: service)
        try await retireWithSignedInventory(coordinator: left, epoch: genesis.state.epoch, keyGeneration: try PositiveUInt64(1), records: [])
        try await retireWithSignedInventory(coordinator: right, epoch: genesis.state.epoch, keyGeneration: try PositiveUInt64(2), records: [])

        let restored = try XCTUnwrap(testTrustStore(secretStore: backing, service: service).loadState(for: genesis.state.accountID))
        XCTAssertEqual(restored.materialReferences.map(\.keyGeneration.value), [3])
        XCTAssertEqual(restored.materials.count, 1)
        XCTAssertEqual(backing.records.keys.filter({ $0.account.hasPrefix("trust-material.v3.") }).count, 2)
        XCTAssertEqual(backing.records.keys.filter({ $0.account.hasPrefix("trust-snapshot.v3.") }).count, 1)
    }

    func testRetainedGenerationAndAuthorityHistoryBoundRejectsBeforeHeadCAS() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.retained-bound"
        let trustStore = AccountTrustStore(
            secretStore: backing,
            service: service,
            maximumRetainedGenerations: 2,
            operationFence: testAccountOperationFence
        )
        let random = FixtureRandom()
        let coordinator = try AccountTrustCoordinator(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            platform: .macos,
            deviceIdentity: identity,
            trustStore: trustStore,
            offlineRootKeyID: fixtureOfflineRootKeyID,
            offlineRootPublicKey: try fixtureOfflineRootKey(),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { random.bytes(count: $0) }
        )
        let genesis = try forkCommit("forkB")
        try await coordinator.acceptHistory([genesis])
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        _ = try await admit(deviceID: pendingID, identity: pendingIdentity, to: coordinator, digestByte: 0x95, nonceByte: 0x96)
        _ = try await coordinator.revoke(pendingID)
        _ = try await admit(deviceID: pendingID, identity: pendingIdentity, to: coordinator, digestByte: 0x97, nonceByte: 0x98)

        let beforeRejectedRotationValue = try await coordinator.currentTrustCommit()
        let beforeRejectedRotation = try XCTUnwrap(beforeRejectedRotationValue)
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.revoke(pendingID) }
        let afterRejectedRotation = try await coordinator.currentTrustCommit()
        XCTAssertEqual(afterRejectedRotation, beforeRejectedRotation)
        let state = try XCTUnwrap(trustStore.loadState(for: genesis.state.accountID))
        XCTAssertEqual(state.materialReferences.count, 2)
        XCTAssertLessThanOrEqual(state.verifiedEntries.count, 22)
        XCTAssertEqual(backing.records.keys.filter({ $0.account.hasPrefix("trust-material.v3.") }).count, 4)
    }

    func testThirdDeviceVerifiesPreMembershipHistoryThenRestoresWithoutAnInitialCommit() async throws {
        let sourceIdentity = try fixtureIdentity()
        let source = try fixtureCoordinator(identity: sourceIdentity, store: InMemoryAccountSecretStore(), service: "test.trust.history.source")
        let genesis = try forkCommit("forkB")
        try await source.acceptHistory([genesis])
        let secondIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let thirdIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(14), agreementPrivateKey: scalar(15))
        let beforeAdmission = try await source.sealAccountRecord(
            id: try AccountRecordID("73000000-0000-4000-8000-000000000001"),
            plaintext: Data("before third-device membership".utf8)
        )
        let second = try await admit(deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"), identity: secondIdentity, to: source, digestByte: 0x51, nonceByte: 0x52)
        let thirdID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000d")
        let third = try await admit(deviceID: thirdID, identity: thirdIdentity, to: source, digestByte: 0x53, nonceByte: 0x54)
        let history = [
            try AccountTrustHistoryEntryV1(commit: genesis, evidence: nil),
            try AccountTrustHistoryEntryV1(commit: second.commit, evidence: .admission(second.evidence)),
            try AccountTrustHistoryEntryV1(commit: third.commit, evidence: .admission(third.evidence)),
        ]
        let localSecrets = InMemoryAccountSecretStore()
        let service = "test.trust.history.third"
        let thirdDevice = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: thirdID,
            platform: .ios,
            deviceIdentity: thirdIdentity,
            trustStore: testTrustStore(secretStore: localSecrets, service: service),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x55, count: $0) }
        )
        try await thirdDevice.acceptHistory(history)
        let acceptedHead = try await thirdDevice.currentTrustCommit()
        XCTAssertEqual(acceptedHead, third.commit)
        let expectedMailbox = try await source.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        let acceptedMailbox = try await thirdDevice.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        XCTAssertEqual(acceptedMailbox, expectedMailbox)
        let openedBeforeAdmission = try await thirdDevice.openAccountRecord(beforeAdmission)
        XCTAssertEqual(openedBeforeAdmission, Data("before third-device membership".utf8))

        let relaunched = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: thirdID,
            platform: .ios,
            deviceIdentity: thirdIdentity,
            trustStore: testTrustStore(secretStore: localSecrets, service: service),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x56, count: $0) }
        )
        let restoredHead = try await relaunched.currentTrustCommit()
        XCTAssertEqual(restoredHead, third.commit)
        let restoredState = try XCTUnwrap(testTrustStore(secretStore: localSecrets, service: service).loadState(for: genesis.state.accountID))
        XCTAssertEqual(restoredState.verifiedEntries.count, 3)
        XCTAssertEqual(restoredState.verifiedEntries.compactMap(\.evidence).count, 2)
        let restoredMailbox = try await relaunched.logicalMailboxID(provider: "gmail", accountIdentity: "alice@example.com")
        XCTAssertEqual(restoredMailbox, expectedMailbox)
        let restoredBeforeAdmission = try await relaunched.openAccountRecord(beforeAdmission)
        XCTAssertEqual(restoredBeforeAdmission, Data("before third-device membership".utf8))
    }

    func testAdmissionRelaunchRestoresHistoricalSignerAuthorityForSameGenerationRecord() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.authority.restore"
        let source = try fixtureCoordinator(identity: identity, store: backing, service: service)
        try await source.acceptHistory([try forkCommit("forkB")])
        let old = try await source.sealAccountRecord(id: try AccountRecordID("90000000-0000-4000-8000-000000000001"), plaintext: Data("before admission".utf8))
        _ = try await admit(deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"), identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)), to: source, digestByte: 0x61, nonceByte: 0x62)

        let relaunched = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let opened = try await relaunched.openAccountRecord(old)
        XCTAssertEqual(opened, Data("before admission".utf8))
    }

    func testHistoryRejectsAdmissionAndRecoveryWithoutExactIndependentAuthorizationEvidence() async throws {
        let source = try fixtureCoordinator(identity: fixtureIdentity(), store: InMemoryAccountSecretStore(), service: "test.trust.authority.source")
        let genesis = try forkCommit("forkB")
        try await source.acceptHistory([genesis])
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let admission = try await admit(deviceID: pendingID, identity: pendingIdentity, to: source, digestByte: 0x63, nonceByte: 0x64)
        let receiver = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: pendingID,
            platform: .ios,
            deviceIdentity: pendingIdentity,
            trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust.authority.receiver"),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0x65, count: $0) }
        )
        let otherPending = try PendingAccountDevice(
            accountID: genesis.state.accountID,
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000e"),
            platform: .ios,
            publicBundle: pendingIdentity.publicBundle,
            exchangeRequestDigest: Data(repeating: 0x63, count: 32),
            createdAt: "2025-01-01T00:00:00Z",
            expiresAt: "2025-01-01T00:05:00Z"
        )
        let wrongEvidence = AccountTrustAdmissionEvidence(pendingDevice: otherPending, response: admission.evidence.response)
        await XCTAssertThrowsErrorAsync {
            try await receiver.acceptHistory([genesis, admission.commit], authorizationContext: AccountTrustAuthorizationContext(admissions: [wrongEvidence]))
        }
        let rejectedAdmissionHead = try await receiver.currentTrustCommit()
        XCTAssertNil(rejectedAdmissionHead)

        let root = try fixtureRoot()
        let authorizationMessage = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try recoveryAuthorization(try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: authorizationMessage)), replacing: genesis)
        let replacementIdentity = try AccountDeviceIdentity(signingPrivateKey: try fixtureRoleScalar("exchangeSigning"), agreementPrivateKey: try fixtureRoleScalar("exchangeAgreement"))
        let recoverySource = try recoveryCoordinator(identity: replacementIdentity, predecessor: genesis)
        let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })
        let recovered = try await recoverySource.recover(with: authorization, expectedExchangeRequestDigest: authorization.exchangeRequestDigest, manifestStore: manifest)
        let recoveryReceiver = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: authorization.deviceID,
            platform: authorization.platform,
            deviceIdentity: replacementIdentity,
            trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust.authority.recovery"),
            offlineRootKeyID: fixtureOfflineRootKeyID,
            offlineRootPublicKey: try fixtureOfflineRootKey(),
            now: { Date(timeIntervalSince1970: 1_785_751_620) },
            random: { Data(repeating: 0x66, count: $0) }
        )
        let wrongRecovery = AccountTrustRecoveryEvidence(
            authorization: authorization,
            historicalManifest: try AccountWireCodec.decodeManifest(BootstrapKeyManifestStore.bundledManifest)
        )
        await XCTAssertThrowsErrorAsync {
            try await recoveryReceiver.acceptHistory([genesis, recovered], authorizationContext: AccountTrustAuthorizationContext(recoveries: [wrongRecovery]))
        }
        let rejectedRecoveryHead = try await recoveryReceiver.currentTrustCommit()
        XCTAssertNil(rejectedRecoveryHead)
        let correctRecovery = AccountTrustRecoveryEvidence(
            authorization: authorization,
            historicalManifest: manifest.currentManifest()
        )
        try await recoveryReceiver.acceptHistory([genesis, recovered], authorizationContext: AccountTrustAuthorizationContext(recoveries: [correctRecovery]))
        let recoveredHead = try await recoveryReceiver.currentTrustCommit()
        XCTAssertEqual(recoveredHead, recovered)
    }

    func testRecoveryFromPersistedMultiRevisionHeadSurvivesRelaunch() async throws {
        let originalIdentity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.recovery.multirevision"
        let original = try fixtureCoordinator(identity: originalIdentity, store: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await original.acceptHistory([genesis])
        _ = try await admit(
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: original,
            digestByte: 0x67,
            nonceByte: 0x68
        )
        let persistedHead = try await original.currentTrustCommit()
        let multiRevisionHead = try XCTUnwrap(persistedHead)
        XCTAssertEqual(multiRevisionHead.state.revision.value, 2)

        let root = try fixtureRoot()
        let authorizationMessage = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try recoveryAuthorization(try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: authorizationMessage)), replacing: multiRevisionHead)
        let replacementIdentity = try AccountDeviceIdentity(
            signingPrivateKey: try fixtureRoleScalar("exchangeSigning"),
            agreementPrivateKey: try fixtureRoleScalar("exchangeAgreement")
        )
        let recoveredDevice = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: authorization.deviceID,
            platform: authorization.platform,
            deviceIdentity: replacementIdentity,
            trustStore: testTrustStore(secretStore: backing, service: service),
            offlineRootKeyID: fixtureOfflineRootKeyID,
            offlineRootPublicKey: try fixtureOfflineRootKey(),
            now: { Date(timeIntervalSince1970: 1_785_751_620) },
            random: { Data(repeating: 0x69, count: $0) }
        )
        let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })
        let recovered = try await recoveredDevice.recover(
            with: authorization,
            expectedExchangeRequestDigest: authorization.exchangeRequestDigest,
            manifestStore: manifest
        )
        XCTAssertEqual(recovered.state.previousCommitDigest, commitDigest(multiRevisionHead))

        let relaunched = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: authorization.deviceID,
            platform: authorization.platform,
            deviceIdentity: replacementIdentity,
            trustStore: testTrustStore(secretStore: backing, service: service),
            now: { Date(timeIntervalSince1970: 1_785_751_620) },
            random: { Data(repeating: 0x6A, count: $0) }
        )
        let restored = try await relaunched.currentTrustCommit()
        XCTAssertEqual(restored, recovered)
        XCTAssertEqual(backing.records.keys.filter({ $0.account.contains("trust-material.v3") }).count, 2)
    }

    func testAcceptedRecoveryJournalsTrustAndReplacementSessionAcrossEveryCrashCut() async throws {
        let root = try fixtureRoot()
        let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        let page = try XCTUnwrap(pagination["page"] as? [String: Any])
        let objects = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let priorHistory = try objects.prefix(2).map { try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: $0)) }
        let authorizationMessage = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: authorizationMessage))
        let replacementIdentity = try AccountDeviceIdentity(signingPrivateKey: fixtureRoleScalar("exchangeSigning"), agreementPrivateKey: fixtureRoleScalar("exchangeAgreement"))
        let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })

        for cut in ["journal", "trust", "session", "marker"] {
            let backing = InMemoryAccountSecretStore()
            let service = "test.trust.recovery.activation.\(cut)"
            let trustStore = testTrustStore(secretStore: backing, service: service)
            let coordinator = try AccountTrustCoordinator(
                accountID: authorization.accountID,
                deviceID: authorization.deviceID,
                platform: authorization.platform,
                deviceIdentity: replacementIdentity,
                trustStore: trustStore,
                offlineRootKeyID: fixtureOfflineRootKeyID,
                offlineRootPublicKey: fixtureOfflineRootKey(),
                now: { Date(timeIntervalSince1970: 1_785_751_620) },
                random: { Data(repeating: 0x73, count: $0) }
            )
            try await coordinator.acceptHistory(Array(priorHistory))
            let candidate = try await coordinator.makeRecoveryCandidate(with: authorization, expectedExchangeRequestDigest: authorization.exchangeRequestDigest, manifestStore: manifest)
            let prepared = try await coordinator.prepareRecoveryActivation(candidate)
            let store = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
            let oldCredentials = try AccountSessionCredentials(accountID: authorization.accountID, deviceID: priorHistory[0].commit.state.signerDeviceID, accessToken: "old-access", accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000), refreshCredential: Data(repeating: 0x31, count: 32), offlineLease: "old-lease")
            try store.saveSession(AccountSession(credentials: oldCredentials))
            let replacement = try AccountSessionCredentials(accountID: authorization.accountID, deviceID: authorization.deviceID, accessToken: "replacement-access", accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_100), refreshCredential: Data(repeating: 0x32, count: 32), offlineLease: "replacement-lease")
            store.testAfterActivationStep = { if $0 == cut { throw AccountRuntimeError.secretUnavailable } }
            XCTAssertThrowsError(try store.commitRecoveryTrustActivation(credentials: replacement, prepared: prepared), "cut \(cut)")

            let relaunchedTrust = testTrustStore(secretStore: backing, service: service)
            let relaunched = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: relaunchedTrust)
            XCTAssertEqual(try relaunched.loadSession()?.credentials, replacement, "cut \(cut)")
            XCTAssertEqual(try relaunchedTrust.loadState(for: authorization.accountID)?.currentCommit, candidate.commit, "cut \(cut)")
            XCTAssertNil(try backing.load(AccountSecretKey(service: service, account: "activation.journal.v1")), "cut \(cut)")
        }
    }

    func testFreshRecoverySkipsExactHistoryAlreadyStoredLocally() async throws {
        let root = try fixtureRoot()
        let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        let page = try XCTUnwrap(pagination["page"] as? [String: Any])
        let objects = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let priorHistory = try objects.prefix(2).map {
            try AccountWireCodec.decodeTrustHistoryEntry(
                JSONSerialization.data(withJSONObject: $0)
            )
        }
        let authorizationMessage = try XCTUnwrap(
            (try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"]
        )
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(
            JSONSerialization.data(withJSONObject: authorizationMessage)
        )
        let replacementIdentity = try AccountDeviceIdentity(
            signingPrivateKey: fixtureRoleScalar("exchangeSigning"),
            agreementPrivateKey: fixtureRoleScalar("exchangeAgreement")
        )
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.recovery.existing-history"
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let existingCoordinator = try AccountTrustCoordinator(
            accountID: authorization.accountID,
            deviceID: priorHistory[0].commit.state.signerDeviceID,
            platform: .macos,
            deviceIdentity: fixtureIdentity(),
            trustStore: trustStore,
            offlineRootKeyID: fixtureOfflineRootKeyID,
            offlineRootPublicKey: fixtureOfflineRootKey(),
            now: { Date(timeIntervalSince1970: 1_785_751_620) },
            random: { Data(repeating: 0x7A, count: $0) }
        )
        try await existingCoordinator.acceptHistory([priorHistory[0]])

        let preparation = try AccountRecoveryPreparationV1(
            authorization: authorization,
            historicalManifest: AccountWireCodec.decodeManifest(
                BootstrapKeyManifestStore.bundledManifest
            ),
            priorHistory: Array(priorHistory)
        )
        let remote = FreshRecoveryRemoteStub(
            preparation: preparation,
            exchangeRequestDigest: authorization.exchangeRequestDigest
        )
        let credentialStore = AccountCredentialStore(
            secretStore: backing,
            service: service,
            secureEnclaveIdentityProvider: nil,
            secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil,
            secureEnclaveAgreementResolver: nil,
            trustStore: trustStore
        )
        let controller = try AccountLifecycleController(
            remote: remote,
            credentialStore: credentialStore,
            device: replacementIdentity,
            platform: .macos,
            recoveryCoordinatorFactory: { accountID, deviceID, platform, identity in
                try AccountTrustCoordinator(
                    accountID: accountID,
                    deviceID: deviceID,
                    platform: platform,
                    deviceIdentity: identity,
                    trustStore: trustStore,
                    offlineRootKeyID: fixtureOfflineRootKeyID,
                    offlineRootPublicKey: try fixtureOfflineRootKey(),
                    now: { Date(timeIntervalSince1970: 1_785_751_620) },
                    random: { Data(repeating: 0x7B, count: $0) }
                )
            },
            manifestStore: try recoveryManifestStore(
                clock: { Date(timeIntervalSince1970: 1_785_751_620) }
            ),
            authenticate: { _ in true },
            clock: { Date(timeIntervalSince1970: 1_785_751_620) }
        )

        let session = try await controller.recover(
            identityToken: "fresh-apple-token",
            appleNonce: Data(repeating: 0x7C, count: 32)
        )

        XCTAssertEqual(session.credentials?.accountID, authorization.accountID)
        XCTAssertEqual(session.credentials?.deviceID, authorization.deviceID)
        let preparationCount = await remote.prepareCount()
        let commitCount = await remote.commitCount()
        let committedCandidate = await remote.committedCandidate()
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(
            committedCandidate?.commit.state.previousCommitDigest,
            commitDigest(priorHistory[1].commit),
            "Recovery must reconcile the missing history suffix before deriving its candidate."
        )
    }

    func testRecoveryHistoryReconciliationRejectsDivergentLocalHead() async throws {
        let identity = try fixtureIdentity()
        let coordinator = try fixtureCoordinator(
            identity: identity,
            secretStore: InMemoryAccountSecretStore(),
            service: "test.lifecycle.recovery.divergent-history"
        )
        let trusted = try forkCommit("forkB")
        try await coordinator.acceptHistory([trusted])
        let divergent = try AccountTrustHistoryEntryV1(
            commit: forkCommit("forkA"),
            evidence: nil
        )

        await XCTAssertThrowsErrorAsync {
            try await coordinator.acceptRecoveryHistory([divergent])
        }

        let unchanged = try await coordinator.currentTrustCommit()
        XCTAssertEqual(unchanged, trusted)
    }

    func testRecoverySubmissionJournalSurvivesRelaunchAndRejectsTamperingBeforeCentralRetry() async throws {
        let root = try fixtureRoot()
        let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        let page = try XCTUnwrap(pagination["page"] as? [String: Any])
        let objects = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let priorHistory = try objects.prefix(2).map { try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: $0)) }
        let authorizationMessage = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: authorizationMessage))
        let identity = try AccountDeviceIdentity(signingPrivateKey: fixtureRoleScalar("exchangeSigning"), agreementPrivateKey: fixtureRoleScalar("exchangeAgreement"))
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.recovery.submission"
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try AccountTrustCoordinator(
            accountID: authorization.accountID,
            deviceID: authorization.deviceID,
            platform: authorization.platform,
            deviceIdentity: identity,
            trustStore: trustStore,
            offlineRootKeyID: fixtureOfflineRootKeyID,
            offlineRootPublicKey: fixtureOfflineRootKey(),
            now: { Date(timeIntervalSince1970: 1_785_751_620) },
            random: { Data(repeating: 0x74, count: $0) }
        )
        try await coordinator.acceptHistory(Array(priorHistory))
        let candidate = try await coordinator.makeRecoveryCandidate(with: authorization, expectedExchangeRequestDigest: authorization.exchangeRequestDigest, manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }))
        let prepared = try await coordinator.prepareRecoveryActivation(candidate)
        let store = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)

        try store.beginRecoverySubmission(authorizationID: authorization.authorizationID, candidate: candidate, prepared: prepared)
        let relaunched = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
        let recovered = try XCTUnwrap(relaunched.loadRecoverySubmission())
        XCTAssertEqual(recovered.authorizationID, authorization.authorizationID)
        XCTAssertEqual(recovered.candidate, candidate)
        XCTAssertEqual(recovered.prepared.entries, prepared.entries)
        XCTAssertEqual(recovered.prepared.material, prepared.material)

        try backing.replace(Data(repeating: 0xFF, count: 128), key: AccountSecretKey(service: service, account: "recovery.submission.v1"), attributes: .deviceOnly)
        XCTAssertThrowsError(try relaunched.loadRecoverySubmission())
    }

    func testRecoveryRelaunchRetriesPersistedCandidateWithoutSecondApplePreparationOrKeyset() async throws {
        let root = try fixtureRoot()
        let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        let page = try XCTUnwrap(pagination["page"] as? [String: Any])
        let objects = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let priorHistory = try objects.prefix(2).map { try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: $0)) }
        let authorizationMessage = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: authorizationMessage))
        let identity = try AccountDeviceIdentity(signingPrivateKey: fixtureRoleScalar("exchangeSigning"), agreementPrivateKey: fixtureRoleScalar("exchangeAgreement"))
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.recovery.resume"
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try AccountTrustCoordinator(accountID: authorization.accountID, deviceID: authorization.deviceID, platform: authorization.platform, deviceIdentity: identity, trustStore: trustStore, offlineRootKeyID: fixtureOfflineRootKeyID, offlineRootPublicKey: fixtureOfflineRootKey(), now: { Date(timeIntervalSince1970: 1_785_751_620) }, random: { Data(repeating: 0x75, count: $0) })
        try await coordinator.acceptHistory(Array(priorHistory))
        let candidate = try await coordinator.makeRecoveryCandidate(with: authorization, expectedExchangeRequestDigest: authorization.exchangeRequestDigest, manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }))
        let prepared = try await coordinator.prepareRecoveryActivation(candidate)
        let store = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
        try store.beginRecoverySubmission(authorizationID: authorization.authorizationID, candidate: candidate, prepared: prepared)
        let remote = RecoveryResumeRemoteStub(candidate: candidate)
		let deniedAuthenticator = LifecycleAuthenticationProbe(approved: false)
		let deniedController = try AccountLifecycleController(remote: remote, credentialStore: store, device: identity, platform: .macos, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }), authenticate: { action in await deniedAuthenticator.authenticate(action) })
		do {
			_ = try await deniedController.recover(identityToken: "new-token-must-not-be-sent", appleNonce: Data(repeating: 0x76, count: 32))
			XCTFail("biometric denial committed recovery")
		} catch {}
		XCTAssertNil(try store.loadRecoverySubmission())
		let deniedCommitCount = await remote.commitCount()
		XCTAssertEqual(deniedCommitCount, 0)
		try store.beginRecoverySubmission(authorizationID: authorization.authorizationID, candidate: candidate, prepared: prepared)

		let authenticator = LifecycleAuthenticationProbe(approved: true)
        let controller = try AccountLifecycleController(remote: remote, credentialStore: store, device: identity, platform: .macos, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }), authenticate: { action in await authenticator.authenticate(action) })

        let session = try await controller.recover(identityToken: "new-token-must-not-be-sent", appleNonce: Data(repeating: 0x76, count: 32))

        XCTAssertEqual(session.credentials?.accountID, authorization.accountID)
        XCTAssertNil(try store.loadRecoverySubmission())
        let prepareCount = await remote.prepareCount()
        let commitCount = await remote.commitCount()
        let committedCandidate = await remote.committedCandidate()
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(committedCandidate, candidate)
		let authenticatedActions = await authenticator.actions()
		XCTAssertEqual(authenticatedActions, [.recoverAccount])
    }

    func testHistoricalRecoveryVerificationSurvivesManifestExpiryAndOverlapEvictionWithoutWeakeningLiveRecovery() async throws {
        let genesis = try forkCommit("forkB")
        let root = try fixtureRoot()
        let authorizationMessage = try XCTUnwrap((try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorization = try recoveryAuthorization(try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: authorizationMessage)), replacing: genesis)
        let replacementIdentity = try AccountDeviceIdentity(
            signingPrivateKey: try fixtureRoleScalar("exchangeSigning"),
            agreementPrivateKey: try fixtureRoleScalar("exchangeAgreement")
        )
        let liveManifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })
        let source = try recoveryCoordinator(identity: replacementIdentity, predecessor: genesis)
        let recovered = try await source.recover(
            with: authorization,
            expectedExchangeRequestDigest: authorization.exchangeRequestDigest,
            manifestStore: liveManifest
        )

        let longAfterManifestExpiry = Date(timeIntervalSince1970: 1_830_297_600)
        let receiver = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: authorization.deviceID,
            platform: authorization.platform,
            deviceIdentity: replacementIdentity,
            trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust.recovery.historical-expiry"),
            offlineRootKeyID: fixtureOfflineRootKeyID,
            offlineRootPublicKey: try fixtureOfflineRootKey(),
            now: { longAfterManifestExpiry },
            random: { Data(repeating: 0x6B, count: $0) }
        )
        let evidence = AccountTrustRecoveryEvidence(
            authorization: authorization,
            historicalManifest: liveManifest.currentManifest()
        )
        try await receiver.acceptHistory(
            [genesis, recovered],
            authorizationContext: AccountTrustAuthorizationContext(recoveries: [evidence])
        )
        let accepted = try await receiver.currentTrustCommit()
        XCTAssertEqual(accepted, recovered)

        let liveAttemptAfterExpiry = try recoveryCoordinator(identity: replacementIdentity, predecessor: genesis)
        let afterAuthorizationExpiry = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_860) })
        await XCTAssertThrowsErrorAsync {
            _ = try await liveAttemptAfterExpiry.recover(
                with: authorization,
                expectedExchangeRequestDigest: authorization.exchangeRequestDigest,
                manifestStore: afterAuthorizationExpiry
            )
        }
    }

    func testHistoryRejectsSwappedAdmissionEvidenceEvenWhenBothEvidenceValuesArePresent() async throws {
        let genesis = try forkCommit("forkB")
        let source = try fixtureCoordinator(identity: try fixtureIdentity(), store: InMemoryAccountSecretStore(), service: "test.trust.paired.source")
        try await source.acceptHistory([genesis])
        let second = try await admit(
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: source,
            digestByte: 0xD1,
            nonceByte: 0xD2
        )
        let thirdID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000d")
        let thirdIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(14), agreementPrivateKey: scalar(15))
        let third = try await admit(deviceID: thirdID, identity: thirdIdentity, to: source, digestByte: 0xD3, nonceByte: 0xD4)
        let receiver = try AccountTrustCoordinator(
            accountID: genesis.state.accountID,
            deviceID: thirdID,
            platform: .ios,
            deviceIdentity: thirdIdentity,
            trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust.paired.receiver"),
            offlineRootKeyID: fixtureOfflineRootKeyID,
            offlineRootPublicKey: try fixtureOfflineRootKey(),
            now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
            random: { Data(repeating: 0xD5, count: $0) }
        )

        await XCTAssertThrowsErrorAsync {
            try await receiver.acceptHistory([
                try AccountTrustHistoryEntryV1(commit: genesis, evidence: nil),
                try AccountTrustHistoryEntryV1(commit: second.commit, evidence: .admission(third.evidence)),
                try AccountTrustHistoryEntryV1(commit: third.commit, evidence: .admission(second.evidence)),
            ])
        }
        let rejectedHead = try await receiver.currentTrustCommit()
        XCTAssertNil(rejectedHead)
    }

    func testMidSealRotationLinearizesAcrossCoordinatorAndStoreInstances() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.fence.mid-seal"
        let source = try fixtureCoordinator(identity: identity, store: backing, service: service)
        try await source.acceptHistory([try forkCommit("forkB")])
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        _ = try await admit(
            deviceID: pendingID,
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: source,
            digestByte: 0xF1,
            nonceByte: 0xF2
        )

        let pausing = PausingSecretStore(backing: backing)
        let writer = try fixtureCoordinator(identity: identity, secretStore: pausing, service: service)
        let rotator = try fixtureCoordinator(identity: identity, store: backing, service: service)
        pausing.arm(.compareAndSwap(prefix: "metadata-nonce.v2."))
        let sealTask = Task.detached {
            try await writer.sealAccountRecord(
                id: try AccountRecordID("79900000-0000-4000-8000-000000000001"),
                plaintext: Data("linearized".utf8)
            )
        }
        XCTAssertEqual(pausing.entered.wait(timeout: .now() + 2), .success)

        let rotationFinished = DispatchSemaphore(value: 0)
        let rotationTask = Task.detached {
            defer { rotationFinished.signal() }
            return try await rotator.revoke(pendingID)
        }
        XCTAssertEqual(rotationFinished.wait(timeout: .now() + 0.1), .timedOut)
        pausing.release.signal()
        let sealed = try await sealTask.value
        let rotated = try await rotationTask.value
        XCTAssertEqual(sealed.keyGeneration.value, 1)
        XCTAssertEqual(rotated.state.keyGeneration.value, 2)

        let fresh = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let opened = try await fresh.openAccountRecord(sealed)
        XCTAssertEqual(opened, Data("linearized".utf8))
    }

    func testInFlightRetirementGCCannotDeleteMaterialUsedByConcurrentWriter() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.trust.fence.gc"
        let source = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await source.acceptHistory([genesis])
        let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
        _ = try await admit(
            deviceID: pendingID,
            identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
            to: source,
            digestByte: 0xF3,
            nonceByte: 0xF4
        )
        _ = try await source.revoke(pendingID)

        let pausing = PausingSecretStore(backing: backing)
        let retiring = try fixtureCoordinator(identity: identity, secretStore: pausing, service: service)
        let writer = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let proof = try await signedInventoryProof(records: [], coordinator: retiring)
        let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_786_183_260) })
        pausing.arm(.delete(prefix: "trust-material.v3."))
        let retireTask = Task.detached {
            try await retiring.retireAccountKeyGeneration(
                epoch: genesis.state.epoch,
                keyGeneration: genesis.state.keyGeneration,
                afterMigrating: [],
                inventoryProof: proof,
                manifestStore: manifest
            )
        }
        XCTAssertEqual(pausing.entered.wait(timeout: .now() + 2), .success)

        let writerFinished = DispatchSemaphore(value: 0)
        let writerTask = Task.detached {
            defer { writerFinished.signal() }
            return try await writer.sealAccountRecord(
                id: try AccountRecordID("79900000-0000-4000-8000-000000000002"),
                plaintext: Data("after gc".utf8)
            )
        }
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 0.1), .timedOut)
        pausing.release.signal()
        try await retireTask.value
        let record = try await writerTask.value
        XCTAssertEqual(record.keyGeneration.value, 2)
        let fresh = try fixtureCoordinator(identity: identity, store: backing, service: service)
        let opened = try await fresh.openAccountRecord(record)
        XCTAssertEqual(opened, Data("after gc".utf8))
    }

    func testRoundThreePaginationVectorIsCompleteAndCanBeRegenerated() async throws {
        guard ProcessInfo.processInfo.environment["PLAINPOST_GENERATE_TASK6_VECTOR"] == "1" else {
            let root = try fixtureRoot()
            let pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
            let page = try XCTUnwrap(pagination["page"] as? [String: Any])
            let entries = try XCTUnwrap(page["entries"] as? [[String: Any]])
            XCTAssertEqual(entries.compactMap { (($0["commit"] as? [String: Any])?["state"] as? [String: Any])?["transition"] as? [String: Any] }.compactMap { $0["kind"] as? String }, ["genesis", "admission", "recovery"])
            XCTAssertEqual((pagination["pageEntryDigests"] as? [String])?.count, 3)
            XCTAssertEqual((pagination["mutationCases"] as? [[String: Any]])?.count, 3)
            return
        }
        let fixture = try fixtureRoot()
        let authorizationObject = try XCTUnwrap((try XCTUnwrap(fixture["recoveryAuthorization"] as? [String: Any]))["message"])
        let authorizationWire = try XCTUnwrap(authorizationObject as? [String: Any])
        let authorizationBundle = try XCTUnwrap(authorizationWire["publicBundle"] as? [String: Any])
        let existingPagination = try XCTUnwrap(fixture["trustPagination"] as? [String: Any])
        let existingPage = try XCTUnwrap(existingPagination["page"] as? [String: Any])
        let existingObjects = try XCTUnwrap(existingPage["entries"] as? [[String: Any]])
        let existingEntries = try existingObjects.map {
            try AccountWireCodec.decodeTrustHistoryEntry(
                JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])
            )
        }
        let genesisEntry = existingEntries[0]
        let admissionEntry = existingEntries[1]
        let oldRecoveryEntry = existingEntries[2]
        guard case .recovery(let recoveryEvidence) = oldRecoveryEntry.evidence else {
            throw AccountProtocolError.malformedWire
        }
        let recoveryCommit = try rebindRecoveryCommitToSignedAuthorization(
            oldRecoveryEntry.commit,
            authorization: recoveryEvidence.authorization
        )
        let recoveryEntry = try AccountTrustHistoryEntryV1(commit: recoveryCommit, evidence: .recovery(recoveryEvidence))
        let entries = [
            genesisEntry,
            admissionEntry,
            recoveryEntry,
        ]
        let entryDigests = entries.map(historyEntryDigest)
        let headDigest = AccountTranscript.trustCommitDigest(recoveryCommit)
        let checkpoint = AccountTranscript.parts([
            AccountTranscript.u64(recoveryCommit.state.epoch.value),
            AccountTranscript.u64(recoveryCommit.state.revision.value),
            headDigest,
        ])
        let issuedAt = "2026-08-03T10:07:00Z"
        let expiresAt = "2026-08-03T10:12:00Z"
        let keyID = "pagination-2026-01"
        let cursorTranscript = AccountTranscript.parts([
            Data("Plainpost.TrustCursor.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(recoveryCommit.state.accountID.rawValue),
            AccountTranscript.part(Data("genesis".utf8)),
            checkpoint,
            Data(issuedAt.utf8),
            Data(expiresAt.utf8),
            Data(keyID.utf8),
        ])
        let paginationSigner = try AccountDeviceIdentity(
            signingPrivateKey: try fixtureRoleScalar("pagination"),
            agreementPrivateKey: try fixtureRoleScalar("deviceAgreement")
        )
        let cursorSignature = try paginationSigner.signature(for: cursorTranscript)
        let cursorDigest = Data(SHA256.hash(data: cursorTranscript + AccountTranscript.part(cursorSignature)))
        let pageTranscript = AccountTranscript.parts([
            Data("Plainpost.TrustStatePage.v1".utf8),
            AccountTranscript.u16(1),
            cursorDigest,
            AccountTranscript.uuid(recoveryCommit.state.accountID.rawValue),
            checkpoint,
            AccountTranscript.u16(UInt16(entries.count)),
        ] + entryDigests + [
            Data(),
            AccountTranscript.u16(1),
            Data(issuedAt.utf8),
            Data(expiresAt.utf8),
            Data(keyID.utf8),
        ])
        let pageSignature = try paginationSigner.signature(for: pageTranscript)
        let checkpointObject: [String: Any] = [
            "epoch": recoveryCommit.state.epoch.wireValue,
            "revision": recoveryCommit.state.revision.wireValue,
            "commitDigest": AccountWireCodec.encodeBase64URL(headDigest),
        ]
        let cursorObject: [String: Any] = [
            "kind": "account.trust-cursor.v1",
            "accountID": recoveryCommit.state.accountID.rawValue,
            "after": ["kind": "genesis"],
            "snapshotHead": checkpointObject,
            "issuedAt": issuedAt,
            "expiresAt": expiresAt,
            "serverKeyID": keyID,
            "signature": AccountWireCodec.encodeBase64URL(cursorSignature),
        ]
        let entryObjects = try entries.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: AccountWireCodec.encodeTrustHistoryEntry($0)) as? [String: Any])
        }
        let vector: [String: Any] = [
            "requestCursor": cursorObject,
            "requestCursorTranscriptHex": cursorTranscript.hexEncodedString(),
            "requestCursorDigest": AccountWireCodec.encodeBase64URL(cursorDigest),
            "pageEntryDigests": entryDigests.map(AccountWireCodec.encodeBase64URL),
            "admissionHistoryEntryDigest": AccountWireCodec.encodeBase64URL(entryDigests[1]),
            "recoveryHistoryEntryDigest": AccountWireCodec.encodeBase64URL(entryDigests[2]),
            "page": [
                "kind": "account.trust-state-page.v1",
                "requestCursor": cursorObject,
                "accountID": recoveryCommit.state.accountID.rawValue,
                "snapshotHead": checkpointObject,
                "entries": entryObjects,
                "nextCursor": NSNull(),
                "terminal": true,
                "issuedAt": issuedAt,
                "expiresAt": expiresAt,
                "serverKeyID": keyID,
                "serverSignature": AccountWireCodec.encodeBase64URL(pageSignature),
            ],
            "pageTranscriptHex": pageTranscript.hexEncodedString(),
            "mutationCases": [
                ["name": "swap-admission-recovery-evidence", "operation": "swapEvidence", "entryIndexes": [1, 2], "expected": "reject"],
                ["name": "substitute-admission-pending-bundle", "operation": "replace", "entryIndex": 1, "jsonPointer": "/evidence/pendingDevice/publicBundle/signingKey", "replacement": try XCTUnwrap(authorizationBundle["signingKey"]), "expected": "reject"],
                ["name": "substitute-recovery-historical-manifest", "operation": "replace", "entryIndex": 2, "jsonPointer": "/evidence/historicalManifest/rootSignature", "replacement": try XCTUnwrap(authorizationWire["serverSignature"]), "expected": "reject"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: vector, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: "/private/tmp/plainpost-task6-trust-pagination.json"), options: .atomic)
    }

    func testTaskNineRecoveryVectorBindsThePriorHeadAndCanBeRegenerated() throws {
        guard ProcessInfo.processInfo.environment["PLAINPOST_GENERATE_TASK9_RECOVERY_VECTOR"] == "1" else {
            let root = try fixtureRoot()
            let message = try XCTUnwrap((root["recoveryAuthorization"] as? [String: Any])?["message"] as? [String: Any])
            XCTAssertNotNil(message["priorCommitDigest"])
            return
        }

        var root = try fixtureRoot()
        var pagination = try XCTUnwrap(root["trustPagination"] as? [String: Any])
        var page = try XCTUnwrap(pagination["page"] as? [String: Any])
        let oldEntries = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let genesisEntry = try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: oldEntries[0]))
        let admissionEntry = try AccountWireCodec.decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: oldEntries[1]))
        let oldRecoveryCommit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(oldEntries[2]["commit"] as? [String: Any])))
        let oldRecoveryEvidence = try XCTUnwrap(oldEntries[2]["evidence"] as? [String: Any])
        let historicalManifest = try AccountWireCodec.decodeManifest(JSONSerialization.data(withJSONObject: try XCTUnwrap(oldRecoveryEvidence["historicalManifest"] as? [String: Any])))
        let priorDigest = AccountTranscript.trustCommitDigest(admissionEntry.commit)

        func signedAuthorization(_ source: [String: Any]) throws -> AccountRecoveryAuthorization {
            let bundle = try XCTUnwrap(source["publicBundle"] as? [String: Any])
            let publicBundle = try AccountPublicKeyBundle(
                signingKey: AccountWireCodec.decodeBase64URL(try XCTUnwrap(bundle["signingKey"] as? String), exactBytes: 65),
                agreementKey: AccountWireCodec.decodeBase64URL(try XCTUnwrap(bundle["agreementKey"] as? String), exactBytes: 65)
            )
            let unsigned = try AccountRecoveryAuthorization(
                authorizationID: AccountAuthorizationID(try XCTUnwrap(source["authorizationID"] as? String)),
                accountID: PlainpostAccountID(try XCTUnwrap(source["accountID"] as? String)),
                epoch: AccountTrustEpoch(rawValue: PositiveUInt64(wire: try XCTUnwrap(source["epoch"] as? String))),
                deviceID: AccountDeviceID(try XCTUnwrap(source["deviceID"] as? String)),
                platform: try XCTUnwrap(AccountPlatform(rawValue: try XCTUnwrap(source["platform"] as? String))),
                publicBundle: publicBundle,
                priorCommitDigest: priorDigest,
                exchangeRequestDigest: AccountWireCodec.decodeBase64URL(try XCTUnwrap(source["exchangeRequestDigest"] as? String), exactBytes: 32),
                issuedAt: try XCTUnwrap(source["issuedAt"] as? String),
                expiresAt: try XCTUnwrap(source["expiresAt"] as? String),
                serverKeyID: try XCTUnwrap(source["serverKeyID"] as? String),
                serverSignature: Data(repeating: 1, count: 64)
            )
            return try AccountRecoveryAuthorization(
                authorizationID: unsigned.authorizationID, accountID: unsigned.accountID, epoch: unsigned.epoch,
                deviceID: unsigned.deviceID, platform: unsigned.platform, publicBundle: unsigned.publicBundle,
                priorCommitDigest: unsigned.priorCommitDigest, exchangeRequestDigest: unsigned.exchangeRequestDigest,
                issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt, serverKeyID: unsigned.serverKeyID,
                serverSignature: try fixtureDeterministicSignature(role: "recoveryAuthorization", transcript: AccountTranscript.recoveryAuthorization(unsigned))
            )
        }
        func authorizationObject(_ value: AccountRecoveryAuthorization) throws -> [String: Any] {
            let evidence = AccountTrustRecoveryEvidenceV1(authorization: value, historicalManifest: historicalManifest)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: AccountWireCodec.encodeTrustRecoveryEvidence(evidence)) as? [String: Any])
            return try XCTUnwrap(object["authorization"] as? [String: Any])
        }
        func vector(_ value: AccountRecoveryAuthorization, preserving existing: [String: Any]) throws -> [String: Any] {
            var result = existing
            result["message"] = try authorizationObject(value)
            result["canonicalTranscriptHex"] = AccountTranscript.recoveryAuthorization(value).hexEncodedString()
            result["digest"] = AccountWireCodec.encodeBase64URL(AccountTranscript.recoveryAuthorizationDigest(value))
            return result
        }

        let existingRecoveryVector = try XCTUnwrap(root["recoveryAuthorization"] as? [String: Any])
        let mainAuthorization = try signedAuthorization(try XCTUnwrap(existingRecoveryVector["message"] as? [String: Any]))
        root["recoveryAuthorization"] = try vector(mainAuthorization, preserving: existingRecoveryVector)

        var forkVector = try XCTUnwrap(root["predecessorCommitForkVector"] as? [String: Any])
        var successor = try XCTUnwrap(forkVector["successorC"] as? [String: Any])
        let oldSuccessor = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(successor["commit"] as? [String: Any])))
        let reboundSuccessor = try rebindRecoveryCommitToSignedAuthorization(oldSuccessor, authorization: mainAuthorization)
        successor["commit"] = try XCTUnwrap(JSONSerialization.jsonObject(with: AccountWireCodec.encodeTrustCommit(reboundSuccessor)) as? [String: Any])
        forkVector["successorC"] = successor
        root["predecessorCommitForkVector"] = forkVector

        var crossInputs = try XCTUnwrap(root["crossAuthorizationInputs"] as? [String: Any])
        let existingCrossVector = try XCTUnwrap(crossInputs["recovery"] as? [String: Any])
        let crossAuthorization = try signedAuthorization(try XCTUnwrap(existingCrossVector["message"] as? [String: Any]))
        crossInputs["recovery"] = try vector(crossAuthorization, preserving: existingCrossVector)
        root["crossAuthorizationInputs"] = crossInputs

        let recoveryCommit = try rebindRecoveryCommitToSignedAuthorization(oldRecoveryCommit, authorization: mainAuthorization)
        let recoveryEvidence = AccountTrustRecoveryEvidenceV1(authorization: mainAuthorization, historicalManifest: historicalManifest)
        let recoveryEntry = try AccountTrustHistoryEntryV1(commit: recoveryCommit, evidence: .recovery(recoveryEvidence))
        let entries = [genesisEntry, admissionEntry, recoveryEntry]
        let entryDigests = entries.map(historyEntryDigest)
        let headDigest = AccountTranscript.trustCommitDigest(recoveryCommit)
        let checkpoint = AccountTranscript.parts([AccountTranscript.u64(recoveryCommit.state.epoch.value), AccountTranscript.u64(recoveryCommit.state.revision.value), headDigest])
        let issuedAt = "2026-08-03T10:07:00Z"
        let expiresAt = "2026-08-03T10:12:00Z"
        let keyID = "pagination-2026-01"
        let cursorTranscript = AccountTranscript.parts([Data("Plainpost.TrustCursor.v1".utf8), AccountTranscript.u16(1), AccountTranscript.uuid(recoveryCommit.state.accountID.rawValue), AccountTranscript.part(Data("genesis".utf8)), checkpoint, Data(issuedAt.utf8), Data(expiresAt.utf8), Data(keyID.utf8)])
        let cursorSignature = try fixtureDeterministicSignature(role: "pagination", transcript: cursorTranscript)
        let cursorDigest = AccountSHA256.hash(cursorTranscript + AccountTranscript.part(cursorSignature))
        let pageTranscript = AccountTranscript.parts([Data("Plainpost.TrustStatePage.v1".utf8), AccountTranscript.u16(1), cursorDigest, AccountTranscript.uuid(recoveryCommit.state.accountID.rawValue), checkpoint, AccountTranscript.u16(UInt16(entries.count))] + entryDigests + [Data(), AccountTranscript.u16(1), Data(issuedAt.utf8), Data(expiresAt.utf8), Data(keyID.utf8)])
        let pageSignature = try fixtureDeterministicSignature(role: "pagination", transcript: pageTranscript)
        let checkpointObject: [String: Any] = ["epoch": recoveryCommit.state.epoch.wireValue, "revision": recoveryCommit.state.revision.wireValue, "commitDigest": AccountWireCodec.encodeBase64URL(headDigest)]
        let cursorObject: [String: Any] = ["kind": "account.trust-cursor.v1", "accountID": recoveryCommit.state.accountID.rawValue, "after": ["kind": "genesis"], "snapshotHead": checkpointObject, "issuedAt": issuedAt, "expiresAt": expiresAt, "serverKeyID": keyID, "signature": AccountWireCodec.encodeBase64URL(cursorSignature)]
        let entryObjects = try entries.map { try XCTUnwrap(JSONSerialization.jsonObject(with: AccountWireCodec.encodeTrustHistoryEntry($0)) as? [String: Any]) }
        page["requestCursor"] = cursorObject
        page["snapshotHead"] = checkpointObject
        page["entries"] = entryObjects
        page["serverSignature"] = AccountWireCodec.encodeBase64URL(pageSignature)
        pagination["requestCursor"] = cursorObject
        pagination["requestCursorTranscriptHex"] = cursorTranscript.hexEncodedString()
        pagination["requestCursorDigest"] = AccountWireCodec.encodeBase64URL(cursorDigest)
        pagination["pageEntryDigests"] = entryDigests.map(AccountWireCodec.encodeBase64URL)
        pagination["admissionHistoryEntryDigest"] = AccountWireCodec.encodeBase64URL(entryDigests[1])
        pagination["recoveryHistoryEntryDigest"] = AccountWireCodec.encodeBase64URL(entryDigests[2])
        pagination["page"] = page
        pagination["pageTranscriptHex"] = pageTranscript.hexEncodedString()
        root["trustPagination"] = pagination

        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: "/private/tmp/plainpost-task9-crypto-vectors-v1.json"), options: .atomic)
    }

    func testLifecycleRemovalRejectionDoesNotAdvanceLocalTrust() async throws {
        let fixture = try await lifecycleRemovalFixture(remoteMode: .reject)
        let before = try await fixture.coordinator.currentTrustCommit()
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.controller.revokeDevice(
                fixture.targetDeviceID,
                identityToken: "apple-token-method-local",
                appleNonce: Data(repeating: 0x91, count: 32)
            )
        }
        let after = try await fixture.coordinator.currentTrustCommit()
        let submitCount = await fixture.remote.submitCount()
        let synchronizeCount = await fixture.remote.synchronizeCount()
        XCTAssertEqual(after, before)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(synchronizeCount, 1)
    }

    func testLifecycleRemovalLostResponseConvergesThroughAcceptedHistoryWithoutSecondStepUp() async throws {
        let fixture = try await lifecycleRemovalFixture(remoteMode: .acceptThenLoseResponse)
        let accepted = try await fixture.controller.revokeDevice(
            fixture.targetDeviceID,
            identityToken: "apple-token-method-local",
            appleNonce: Data(repeating: 0x92, count: 32)
        )
        let head = try await fixture.coordinator.currentTrustCommit()
        let issueCount = await fixture.remote.issueCount()
        let submitCount = await fixture.remote.submitCount()
        let synchronizeCount = await fixture.remote.synchronizeCount()
        XCTAssertEqual(head, accepted.commit)
        XCTAssertEqual(accepted.commit.state.transition.kind, .revocation)
        XCTAssertEqual(issueCount, 1)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(synchronizeCount, 1)
    }

    func testAccountAuthorityPurgeRemovesBoundedTrustMaterialNonceAndRecordHighWater() async throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.purge"
        let coordinator = try fixtureCoordinator(identity: fixtureIdentity(), secretStore: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await coordinator.acceptHistory([genesis])
        let store = testTrustStore(secretStore: backing, service: service)
        let accountID = genesis.state.accountID
        let recordID = try AccountRecordID("91000000-0000-4000-8000-000000000009")
        try store.saveRecordHighWater(
            try AccountRecordHighWater(epoch: genesis.state.epoch, keyGeneration: genesis.state.keyGeneration, recordRevision: PositiveUInt64(1), envelopeDigest: Data(repeating: 0x97, count: 32)),
            accountID: accountID,
            recordID: recordID
        )
        _ = try store.nextMetadataNonce(accountID: accountID, epoch: genesis.state.epoch, keyGeneration: genesis.state.keyGeneration, namespace: Data(repeating: 0x98, count: 8))
        XCTAssertNotNil(try store.loadCheckpoint(for: accountID))

        try store.purgeAccountAuthority(for: accountID)

        XCTAssertNil(try store.loadCheckpoint(for: accountID))
        XCTAssertNil(try store.loadKeyMaterial(for: accountID))
        XCTAssertNil(try store.loadRecordHighWater(accountID: accountID, recordID: recordID))
        XCTAssertFalse(backing.records.keys.contains { key in
            key.service == service && key.account.contains(accountID.rawValue)
        })
        try store.purgeAccountAuthority(for: accountID)
    }

    func testActiveLifecycleRegistersItsCleanupCapabilityBeforeDeletion() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.cleanup-registration"
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try fixtureCoordinator(identity: identity, secretStore: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await coordinator.acceptHistory([genesis])
        let credentials = try AccountSessionCredentials(
            accountID: genesis.state.accountID,
            deviceID: genesis.state.signerDeviceID,
            accessToken: "access",
            accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            refreshCredential: Data(repeating: 0xA0, count: 32),
            offlineLease: "lease"
        )
        let store = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
        try store.saveSession(AccountSession(credentials: credentials))
        let remote = DeletionRemoteStub(signer: identity)
        let controller = try AccountLifecycleController(remote: remote, credentialStore: store, device: identity, platform: .macos, credentials: credentials, coordinator: coordinator, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }), authenticate: { _ in false }, clock: { Date(timeIntervalSince1970: 1_785_751_620) })

        let receipt = try await controller.registerCurrentCleanupTarget()
        let registered = await remote.registeredCleanup()

        XCTAssertEqual(receipt.targetHandle, registered?.targetHandle)
        XCTAssertEqual(receipt.nextDeletionGeneration.rawValue, 1)
        XCTAssertEqual(registered?.targetKind, .macos)
    }

    func testAccountDeletionJournalsBeforeRemoteDisablePurgesAuthorityAndResumesAcknowledgement() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.deletion"
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try fixtureCoordinator(identity: identity, secretStore: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await coordinator.acceptHistory([genesis])
        let credentials = try AccountSessionCredentials(accountID: genesis.state.accountID, deviceID: genesis.state.signerDeviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000), refreshCredential: Data(repeating: 0xA1, count: 32), offlineLease: "lease")
        let store = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
        try store.saveSession(AccountSession(credentials: credentials))
        let remote = DeletionRemoteStub(signer: identity)
        let purger = ManagedDataPurgeCounter()
        let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })
        let controller = try AccountLifecycleController(remote: remote, credentialStore: store, device: identity, platform: .macos, credentials: credentials, coordinator: coordinator, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: manifest, authenticate: { _ in true }, clock: { Date(timeIntervalSince1970: 1_785_751_620) }, purgeManagedData: { accountID in await purger.purge(accountID) })

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.deleteAccount(identityToken: "apple-token-method-local", appleNonce: Data(repeating: 0xA2, count: 32))
        }
        XCTAssertNil(try store.loadSession())
        XCTAssertNil(try trustStore.loadCheckpoint(for: genesis.state.accountID))
        XCTAssertEqual(try store.loadLocalDeletion()?.phase, .localPurged)
        let firstPurgeCount = await purger.count()
        XCTAssertEqual(firstPurgeCount, 1)

        let relaunched = try AccountLifecycleController(remote: remote, credentialStore: store, device: identity, platform: .macos, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: manifest, authenticate: { _ in true }, clock: { Date(timeIntervalSince1970: 1_785_751_620) }, purgeManagedData: { accountID in await purger.purge(accountID) })
        try await relaunched.resumeLocalDeletion()
        XCTAssertNil(try store.loadLocalDeletion())
        XCTAssertNotNil(try store.loadCompletedDeletionReceipt())
        let finalPurgeCount = await purger.count()
        let acknowledgementCount = await remote.ackCount()
        XCTAssertEqual(finalPurgeCount, 1)
        XCTAssertEqual(acknowledgementCount, 2)
        XCTAssertFalse(backing.records.keys.contains { $0.service == service && ($0.account == "cleanup.capability.v1" || $0.account == "cleanup.journal.v1") })
    }

    func testAccountDeletionBiometricDenialLeavesNoCleanupJournalOrAuthorityMutation() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.deletion.denied"
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try fixtureCoordinator(identity: identity, secretStore: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await coordinator.acceptHistory([genesis])
        let credentials = try AccountSessionCredentials(accountID: genesis.state.accountID, deviceID: genesis.state.signerDeviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000), refreshCredential: Data(repeating: 0xB1, count: 32), offlineLease: "lease")
        let store = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
        try store.saveSession(AccountSession(credentials: credentials))
        let controller = try AccountLifecycleController(remote: DeletionRemoteStub(signer: identity), credentialStore: store, device: identity, platform: .macos, credentials: credentials, coordinator: coordinator, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }), authenticate: { _ in false }, clock: { Date(timeIntervalSince1970: 1_785_751_620) }, purgeManagedData: { _ in Data(repeating: 1, count: 32) })

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.deleteAccount(identityToken: "apple-token-method-local", appleNonce: Data(repeating: 0xB2, count: 32))
        }

        XCTAssertNil(try store.loadLocalDeletion())
        XCTAssertEqual(try store.loadSession()?.credentials, credentials)
        XCTAssertEqual(try trustStore.loadCheckpoint(for: genesis.state.accountID)?.commitDigest, AccountTranscript.trustCommitDigest(genesis))
    }

    func testAccountDeletionLostCentralResponseResumesThroughCleanupCredentialWithoutRepeatingPurge() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.deletion.lost-response"
        let trustStore = testTrustStore(secretStore: backing, service: service)
        let coordinator = try fixtureCoordinator(identity: identity, secretStore: backing, service: service)
        let genesis = try forkCommit("forkB")
        try await coordinator.acceptHistory([genesis])
        let credentials = try AccountSessionCredentials(accountID: genesis.state.accountID, deviceID: genesis.state.signerDeviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000), refreshCredential: Data(repeating: 0xB3, count: 32), offlineLease: "lease")
        let store = AccountCredentialStore(secretStore: backing, service: service, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
        try store.saveSession(AccountSession(credentials: credentials))
        let remote = DeletionRemoteStub(signer: identity, loseDeleteResponse: true, failFirstAcknowledgement: false)
        let purger = ManagedDataPurgeCounter()
        let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })
        let controller = try AccountLifecycleController(remote: remote, credentialStore: store, device: identity, platform: .macos, credentials: credentials, coordinator: coordinator, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: manifest, authenticate: { _ in true }, clock: { Date(timeIntervalSince1970: 1_785_751_620) }, purgeManagedData: { accountID in await purger.purge(accountID) })

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.deleteAccount(identityToken: "apple-token-method-local", appleNonce: Data(repeating: 0xB4, count: 32))
        }
        XCTAssertEqual(try store.loadLocalDeletion()?.phase, .prepared)
        let beforeResumePurgeCount = await purger.count()
        XCTAssertEqual(beforeResumePurgeCount, 0)

        let relaunched = try AccountLifecycleController(remote: remote, credentialStore: store, device: identity, platform: .macos, credentials: credentials, coordinator: coordinator, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse }, manifestStore: manifest, authenticate: { _ in false }, clock: { Date(timeIntervalSince1970: 1_785_751_620) }, purgeManagedData: { accountID in await purger.purge(accountID) })
        try await relaunched.resumeLocalDeletion()
        XCTAssertNil(try store.loadLocalDeletion())
        let afterResumePurgeCount = await purger.count()
        XCTAssertEqual(afterResumePurgeCount, 1)
        XCTAssertNil(try store.loadSession())
        XCTAssertNotNil(try store.loadCompletedDeletionReceipt())
    }

    func testSecuritySnapshotReconcilesTrustBeforeProjectingDevices() async throws {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.security-snapshot"
        let coordinator = try fixtureCoordinator(
            identity: identity,
            secretStore: backing,
            service: service
        )
        let genesis = try forkCommit("forkB")
        let credentials = try AccountSessionCredentials(
            accountID: genesis.state.accountID,
            deviceID: genesis.state.signerDeviceID,
            accessToken: "access",
            accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            refreshCredential: Data(repeating: 0xC1, count: 32),
            offlineLease: "lease"
        )
        let credentialStore = AccountCredentialStore(
            secretStore: backing,
            service: service,
            secureEnclaveIdentityProvider: nil,
            secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil,
            secureEnclaveAgreementResolver: nil,
            trustStore: testTrustStore(secretStore: backing, service: service)
        )
        let remote = SecuritySnapshotRemoteStub(
            entry: try AccountTrustHistoryEntryV1(commit: genesis, evidence: nil)
        )
        let controller = try AccountLifecycleController(
            remote: remote,
            credentialStore: credentialStore,
            device: identity,
            platform: .macos,
            credentials: credentials,
            coordinator: coordinator,
            recoveryCoordinatorFactory: { _, _, _, _ in
                throw AccountRuntimeError.untrustedResponse
            },
            manifestStore: try recoveryManifestStore(
                clock: { Date(timeIntervalSince1970: 1_785_751_620) }
            ),
            authenticate: { _ in false },
            clock: { Date(timeIntervalSince1970: 1_785_751_620) }
        )

        let snapshot = try await controller.securitySnapshot(limit: 32)

        XCTAssertEqual(snapshot.events, [])
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(snapshot.devices.first?.id, genesis.state.signerDeviceID)
        let operations = await remote.operations()
        XCTAssertEqual(operations, [.trustHistory, .securityEvents])
    }

    func testSecuritySnapshotIdentifiesTrustHistoryFailureStage() async throws {
        let fixture = try await securitySnapshotFailureFixture(mode: .trustHistoryFailure)

        do {
            _ = try await fixture.controller.securitySnapshot(limit: 32)
            XCTFail("trust history failure must be reported")
        } catch let failure as AccountSecuritySnapshotFailure {
            XCTAssertEqual(failure.stage, .trustHistory)
        }
    }

    func testSecuritySnapshotIdentifiesSecurityEventsFailureStage() async throws {
        let fixture = try await securitySnapshotFailureFixture(mode: .securityEventsFailure)

        do {
            _ = try await fixture.controller.securitySnapshot(limit: 32)
            XCTFail("security event failure must be reported")
        } catch let failure as AccountSecuritySnapshotFailure {
            XCTAssertEqual(failure.stage, .securityEvents)
        }
    }

    private func securitySnapshotFailureFixture(
        mode: SecuritySnapshotRemoteStub.Mode
    ) async throws -> (controller: AccountLifecycleController, remote: SecuritySnapshotRemoteStub) {
        let identity = try fixtureIdentity()
        let backing = InMemoryAccountSecretStore()
        let service = "test.lifecycle.security-snapshot.failure.\(UUID().uuidString)"
        let coordinator = try fixtureCoordinator(identity: identity, secretStore: backing, service: service)
        let genesis = try forkCommit("forkB")
        let credentials = try AccountSessionCredentials(
            accountID: genesis.state.accountID,
            deviceID: genesis.state.signerDeviceID,
            accessToken: "access",
            accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            refreshCredential: Data(repeating: 0xC1, count: 32),
            offlineLease: "lease"
        )
        let credentialStore = AccountCredentialStore(
            secretStore: backing,
            service: service,
            secureEnclaveIdentityProvider: nil,
            secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil,
            secureEnclaveAgreementResolver: nil,
            trustStore: testTrustStore(secretStore: backing, service: service)
        )
        let remote = SecuritySnapshotRemoteStub(
            entry: try AccountTrustHistoryEntryV1(commit: genesis, evidence: nil),
            mode: mode
        )
        return (
            try AccountLifecycleController(
                remote: remote,
                credentialStore: credentialStore,
                device: identity,
                platform: .macos,
                credentials: credentials,
                coordinator: coordinator,
                recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse },
                manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }),
                authenticate: { _ in false },
                clock: { Date(timeIntervalSince1970: 1_785_751_620) }
            ),
            remote
        )
    }
}

private actor SecuritySnapshotRemoteStub: AccountLifecycleRemote {
    enum Mode: Equatable, Sendable {
        case success
        case trustHistoryFailure
        case securityEventsFailure
    }

    enum Operation: Equatable, Sendable {
        case trustHistory
        case securityEvents
    }

    private let entry: AccountTrustHistoryEntryV1
    private let mode: Mode
    private var recordedOperations: [Operation] = []

    init(entry: AccountTrustHistoryEntryV1, mode: Mode = .success) {
        self.entry = entry
        self.mode = mode
    }

    func synchronizeTrustHistory(
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        applying: any AccountTrustHistoryApplying,
        now: Date
    ) async throws -> TrustStateCommitV1? {
        recordedOperations.append(.trustHistory)
        if mode == .trustHistoryFailure { throw AccountRuntimeError.untrustedResponse }
        try await applying.acceptHistory([entry])
        return entry.commit
    }

    func securityEvents(
        cursor: String?,
        limit: Int,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        now: Date
    ) async throws -> AccountSecurityEventPageV1 {
        guard limit == 32 else { throw AccountRuntimeError.untrustedResponse }
        recordedOperations.append(.securityEvents)
        if mode == .securityEventsFailure { throw AccountRuntimeError.untrustedResponse }
        return try AccountSecurityEventPageV1(events: [], nextCursor: nil)
    }

    func operations() -> [Operation] { recordedOperations }

    func issueStepUp(action: AccountLifecycleAction, targetDeviceID: AccountDeviceID?, currentCommitDigest: Data, identityToken: String, appleNonce: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.untrustedResponse }
    func submitLifecycle(authorization: AccountStepUpAuthorizationV1, candidate: AccountTrustHistoryEntryV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountTrustHistoryEntryV1 { throw AccountRuntimeError.untrustedResponse }
    func deleteAccount(authorization: AccountStepUpAuthorizationV1, currentCommitDigest: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountDeletionResultV1 { throw AccountRuntimeError.untrustedResponse }
    func registerCleanup(_ registration: AccountCleanupRegistrationV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountCleanupRegistrationReceiptV1 { throw AccountRuntimeError.untrustedResponse }
    func checkCleanup(_ check: AccountCleanupCheckV1) async throws -> AccountCleanupDirectiveV1 { throw AccountRuntimeError.untrustedResponse }
    func acknowledgeCleanup(_ acknowledgement: AccountCleanupAcknowledgementV1, cleanupCredential: Data) async throws { throw AccountRuntimeError.untrustedResponse }
    func prepareRecovery(identityToken: String, appleNonce: Data, device: AccountDeviceIdentity) async throws -> (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data) { throw AccountRuntimeError.untrustedResponse }
    func commitRecovery(candidate: AccountTrustHistoryEntryV1, authorizationID: AccountAuthorizationID, device: AccountDeviceIdentity) async throws -> AccountRecoveryActivationV1 { throw AccountRuntimeError.untrustedResponse }
}

private struct LifecycleRemovalFixture {
    let controller: AccountLifecycleController
    let coordinator: AccountTrustCoordinator
    let remote: LifecycleRemoteStub
    let targetDeviceID: AccountDeviceID
}

private func lifecycleRemovalFixture(remoteMode: LifecycleRemoteStub.Mode) async throws -> LifecycleRemovalFixture {
    let identity = try fixtureIdentity()
    let backing = InMemoryAccountSecretStore()
    let service = "test.lifecycle.removal.\(UUID().uuidString)"
    let coordinator = try fixtureCoordinator(identity: identity, secretStore: backing, service: service)
    try await coordinator.acceptHistory([try forkCommit("forkB")])
    let targetDeviceID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
    _ = try await admit(
        deviceID: targetDeviceID,
        identity: try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13)),
        to: coordinator,
        digestByte: 0x93,
        nonceByte: 0x94
    )
    let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
    let actorDeviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
    let credentials = try AccountSessionCredentials(
        accountID: accountID,
        deviceID: actorDeviceID,
        accessToken: "access",
        accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        refreshCredential: Data(repeating: 0x95, count: 32),
        offlineLease: "lease"
    )
    let remote = LifecycleRemoteStub(mode: remoteMode, signer: identity)
    let credentialStore = AccountCredentialStore(
        secretStore: backing,
        service: service,
        secureEnclaveIdentityProvider: nil,
        secureEnclaveIdentityResolver: nil,
        secureEnclaveAgreementProvider: nil,
        secureEnclaveAgreementResolver: nil,
        trustStore: testTrustStore(secretStore: backing, service: service)
    )
    let controller = try AccountLifecycleController(
        remote: remote,
        credentialStore: credentialStore,
        device: identity,
        platform: .macos,
        credentials: credentials,
        coordinator: coordinator,
        recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.untrustedResponse },
        manifestStore: try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) }),
        authenticate: { _ in true },
        clock: { Date(timeIntervalSince1970: 1_785_751_620) }
    )
    return LifecycleRemovalFixture(controller: controller, coordinator: coordinator, remote: remote, targetDeviceID: targetDeviceID)
}

private actor LifecycleRemoteStub: AccountLifecycleRemote {
    enum Mode: Sendable { case reject, acceptThenLoseResponse }
    private let mode: Mode
    private let signer: AccountDeviceIdentity
    private var submitted: AccountTrustHistoryEntryV1?
    private var issues = 0
    private var submissions = 0
    private var synchronizations = 0

    init(mode: Mode, signer: AccountDeviceIdentity) { self.mode = mode; self.signer = signer }

    func issueStepUp(action: AccountLifecycleAction, targetDeviceID: AccountDeviceID?, currentCommitDigest: Data, identityToken: String, appleNonce: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        issues += 1
        return try AccountStepUpAuthorizationV1(
            authorizationID: AccountAuthorizationID("91000000-0000-4000-8000-000000000001"),
            accountID: credentials.accountID,
            actorDeviceID: credentials.deviceID,
            targetDeviceID: targetDeviceID,
            action: action,
            currentCommitDigest: currentCommitDigest,
            requestDigest: Data(repeating: 0x96, count: 32),
            issuedAt: "2026-08-03T10:00:00Z",
            expiresAt: "2026-08-03T10:05:00Z",
            serverKeyID: "recovery-2026-01",
            serverSignature: try signer.signature(for: Data("test-step-up".utf8))
        )
    }

    func submitLifecycle(authorization: AccountStepUpAuthorizationV1, candidate: AccountTrustHistoryEntryV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountTrustHistoryEntryV1 {
        submissions += 1
        submitted = candidate
        throw AccountRuntimeError.transportFailure
    }

    func synchronizeTrustHistory(credentials: AccountSessionCredentials, device: AccountDeviceIdentity, applying: any AccountTrustHistoryApplying, now: Date) async throws -> TrustStateCommitV1? {
        synchronizations += 1
        if case .acceptThenLoseResponse = mode, let submitted {
            try await applying.acceptHistory([submitted])
        }
        return try await applying.currentTrustCommit()
    }

    func issueCount() -> Int { issues }
    func submitCount() -> Int { submissions }
    func synchronizeCount() -> Int { synchronizations }

    func securityEvents(cursor: String?, limit: Int, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountSecurityEventPageV1 { throw AccountRuntimeError.untrustedResponse }
    func deleteAccount(authorization: AccountStepUpAuthorizationV1, currentCommitDigest: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountDeletionResultV1 { throw AccountRuntimeError.untrustedResponse }
    func registerCleanup(_ registration: AccountCleanupRegistrationV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountCleanupRegistrationReceiptV1 { throw AccountRuntimeError.untrustedResponse }
    func checkCleanup(_ check: AccountCleanupCheckV1) async throws -> AccountCleanupDirectiveV1 { throw AccountRuntimeError.untrustedResponse }
    func acknowledgeCleanup(_ acknowledgement: AccountCleanupAcknowledgementV1, cleanupCredential: Data) async throws { throw AccountRuntimeError.untrustedResponse }
    func prepareRecovery(identityToken: String, appleNonce: Data, device: AccountDeviceIdentity) async throws -> (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data) { throw AccountRuntimeError.untrustedResponse }
    func commitRecovery(candidate: AccountTrustHistoryEntryV1, authorizationID: AccountAuthorizationID, device: AccountDeviceIdentity) async throws -> AccountRecoveryActivationV1 { throw AccountRuntimeError.untrustedResponse }
}

private actor LifecycleAuthenticationProbe {
    private let approved: Bool
    private var recorded: [AccountLifecycleAction] = []

    init(approved: Bool) { self.approved = approved }

    func authenticate(_ action: AccountLifecycleAction) -> Bool {
        recorded.append(action)
        return approved
    }

    func actions() -> [AccountLifecycleAction] { recorded }
}

private actor ManagedDataPurgeCounter {
    private var calls = 0
    func purge(_ accountID: PlainpostAccountID) -> Data { calls += 1; return Data(SHA256.hash(data: Data(accountID.rawValue.utf8))) }
    func count() -> Int { calls }
}

private actor RecoveryResumeRemoteStub: AccountLifecycleRemote {
    private let candidate: AccountTrustHistoryEntryV1
    private var preparations = 0
    private var commits = 0
    private var lastCandidate: AccountTrustHistoryEntryV1?

    init(candidate: AccountTrustHistoryEntryV1) { self.candidate = candidate }

    func prepareRecovery(identityToken: String, appleNonce: Data, device: AccountDeviceIdentity) async throws -> (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data) {
        preparations += 1
        throw AccountRuntimeError.untrustedResponse
    }

    func commitRecovery(candidate: AccountTrustHistoryEntryV1, authorizationID: AccountAuthorizationID, device: AccountDeviceIdentity) async throws -> AccountRecoveryActivationV1 {
        commits += 1
        lastCandidate = candidate
        guard candidate == self.candidate else { throw AccountRuntimeError.untrustedResponse }
        return try AccountRecoveryActivationV1(
            acceptedEntry: candidate,
            accessToken: "replacement-access",
            accessExpiresAt: "2026-08-03T10:05:00Z",
            refreshCredential: Data(repeating: 0x77, count: 32),
            offlineLease: "replacement-offline-lease",
            offlineLeaseExpiresAt: "2026-08-04T10:05:00Z"
        )
    }

    func prepareCount() -> Int { preparations }
    func commitCount() -> Int { commits }
    func committedCandidate() -> AccountTrustHistoryEntryV1? { lastCandidate }

    func issueStepUp(action: AccountLifecycleAction, targetDeviceID: AccountDeviceID?, currentCommitDigest: Data, identityToken: String, appleNonce: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.untrustedResponse }
    func submitLifecycle(authorization: AccountStepUpAuthorizationV1, candidate: AccountTrustHistoryEntryV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountTrustHistoryEntryV1 { throw AccountRuntimeError.untrustedResponse }
    func securityEvents(cursor: String?, limit: Int, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountSecurityEventPageV1 { throw AccountRuntimeError.untrustedResponse }
    func deleteAccount(authorization: AccountStepUpAuthorizationV1, currentCommitDigest: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountDeletionResultV1 { throw AccountRuntimeError.untrustedResponse }
    func registerCleanup(_ registration: AccountCleanupRegistrationV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountCleanupRegistrationReceiptV1 { throw AccountRuntimeError.untrustedResponse }
    func checkCleanup(_ check: AccountCleanupCheckV1) async throws -> AccountCleanupDirectiveV1 { throw AccountRuntimeError.untrustedResponse }
    func acknowledgeCleanup(_ acknowledgement: AccountCleanupAcknowledgementV1, cleanupCredential: Data) async throws { throw AccountRuntimeError.untrustedResponse }
    func synchronizeTrustHistory(credentials: AccountSessionCredentials, device: AccountDeviceIdentity, applying: any AccountTrustHistoryApplying, now: Date) async throws -> TrustStateCommitV1? { throw AccountRuntimeError.untrustedResponse }
}

private actor FreshRecoveryRemoteStub: AccountLifecycleRemote {
    private let preparation: AccountRecoveryPreparationV1
    private let exchangeRequestDigest: Data
    private var preparations = 0
    private var commits = 0
    private var lastCandidate: AccountTrustHistoryEntryV1?

    init(preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data) {
        self.preparation = preparation
        self.exchangeRequestDigest = exchangeRequestDigest
    }

    func prepareRecovery(
        identityToken: String,
        appleNonce: Data,
        device: AccountDeviceIdentity
    ) async throws -> (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data) {
        guard identityToken == "fresh-apple-token",
              appleNonce == Data(repeating: 0x7C, count: 32),
              device.publicBundle == preparation.authorization.publicBundle
        else { throw AccountRuntimeError.untrustedResponse }
        preparations += 1
        return (preparation, exchangeRequestDigest)
    }

    func commitRecovery(
        candidate: AccountTrustHistoryEntryV1,
        authorizationID: AccountAuthorizationID,
        device: AccountDeviceIdentity
    ) async throws -> AccountRecoveryActivationV1 {
        guard authorizationID == preparation.authorization.authorizationID,
              device.publicBundle == preparation.authorization.publicBundle
        else { throw AccountRuntimeError.untrustedResponse }
        commits += 1
        lastCandidate = candidate
        return try AccountRecoveryActivationV1(
            acceptedEntry: candidate,
            accessToken: "replacement-access",
            accessExpiresAt: "2026-08-03T10:05:00Z",
            refreshCredential: Data(repeating: 0x7D, count: 32),
            offlineLease: "replacement-offline-lease",
            offlineLeaseExpiresAt: "2026-08-04T10:05:00Z"
        )
    }

    func prepareCount() -> Int { preparations }
    func commitCount() -> Int { commits }
    func committedCandidate() -> AccountTrustHistoryEntryV1? { lastCandidate }

    func issueStepUp(action: AccountLifecycleAction, targetDeviceID: AccountDeviceID?, currentCommitDigest: Data, identityToken: String, appleNonce: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.untrustedResponse }
    func submitLifecycle(authorization: AccountStepUpAuthorizationV1, candidate: AccountTrustHistoryEntryV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountTrustHistoryEntryV1 { throw AccountRuntimeError.untrustedResponse }
    func securityEvents(cursor: String?, limit: Int, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountSecurityEventPageV1 { throw AccountRuntimeError.untrustedResponse }
    func deleteAccount(authorization: AccountStepUpAuthorizationV1, currentCommitDigest: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountDeletionResultV1 { throw AccountRuntimeError.untrustedResponse }
    func registerCleanup(_ registration: AccountCleanupRegistrationV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountCleanupRegistrationReceiptV1 { throw AccountRuntimeError.untrustedResponse }
    func checkCleanup(_ check: AccountCleanupCheckV1) async throws -> AccountCleanupDirectiveV1 { throw AccountRuntimeError.untrustedResponse }
    func acknowledgeCleanup(_ acknowledgement: AccountCleanupAcknowledgementV1, cleanupCredential: Data) async throws { throw AccountRuntimeError.untrustedResponse }
    func synchronizeTrustHistory(credentials: AccountSessionCredentials, device: AccountDeviceIdentity, applying: any AccountTrustHistoryApplying, now: Date) async throws -> TrustStateCommitV1? { throw AccountRuntimeError.untrustedResponse }
}

private actor DeletionRemoteStub: AccountLifecycleRemote {
    private let signer: AccountDeviceIdentity
    private let loseDeleteResponse: Bool
    private let failFirstAcknowledgement: Bool
    private var registration: AccountCleanupRegistrationV1?
    private var acknowledgements = 0
    private var deletionAttempts = 0
    init(signer: AccountDeviceIdentity, loseDeleteResponse: Bool = false, failFirstAcknowledgement: Bool = true) { self.signer = signer; self.loseDeleteResponse = loseDeleteResponse; self.failFirstAcknowledgement = failFirstAcknowledgement }
    func registerCleanup(_ value: AccountCleanupRegistrationV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountCleanupRegistrationReceiptV1 { registration = value; return try AccountCleanupRegistrationReceiptV1(targetHandle: value.targetHandle, nextDeletionGeneration: PositiveUInt64(1)) }
    func registeredCleanup() -> AccountCleanupRegistrationV1? { registration }
    func issueStepUp(action: AccountLifecycleAction, targetDeviceID: AccountDeviceID?, currentCommitDigest: Data, identityToken: String, appleNonce: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountStepUpAuthorizationV1 { try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("92000000-0000-4000-8000-000000000001"), accountID: credentials.accountID, actorDeviceID: credentials.deviceID, targetDeviceID: nil, action: .deleteAccount, currentCommitDigest: currentCommitDigest, requestDigest: Data(repeating: 0xA3, count: 32), issuedAt: "2026-08-03T10:00:00Z", expiresAt: "2026-08-03T10:05:00Z", serverKeyID: "recovery-2026-01", serverSignature: try signer.signature(for: Data("delete-step-up".utf8))) }
    func deleteAccount(authorization: AccountStepUpAuthorizationV1, currentCommitDigest: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountDeletionResultV1 { guard let registration else { throw AccountRuntimeError.untrustedResponse }; deletionAttempts += 1; if loseDeleteResponse && deletionAttempts == 1 { throw AccountRuntimeError.transportFailure }; return try AccountDeletionResultV1(accountID: credentials.accountID, deletionGeneration: PositiveUInt64(1), centralBackupExpiresAt: "2026-09-02T10:00:00Z", targets: [try AccountCleanupTargetStatusV1(handle: registration.targetHandle, kind: registration.targetKind, status: .erasurePending)], deletedAt: "2026-08-03T10:00:00Z") }
    func checkCleanup(_ check: AccountCleanupCheckV1) async throws -> AccountCleanupDirectiveV1 { guard let registration, check.targetHandle == registration.targetHandle else { throw AccountRuntimeError.untrustedResponse }; return try AccountCleanupDirectiveV1(targetHandle: check.targetHandle, deletionGeneration: check.deletionGeneration, targetKind: registration.targetKind, status: .erasurePending, centralBackupExpiresAt: "2026-09-02T10:00:00Z") }
    func acknowledgeCleanup(_ acknowledgement: AccountCleanupAcknowledgementV1, cleanupCredential: Data) async throws { acknowledgements += 1; if failFirstAcknowledgement && acknowledgements == 1 { throw AccountRuntimeError.transportFailure } }
    func ackCount() -> Int { acknowledgements }
    func submitLifecycle(authorization: AccountStepUpAuthorizationV1, candidate: AccountTrustHistoryEntryV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountTrustHistoryEntryV1 { throw AccountRuntimeError.untrustedResponse }
    func synchronizeTrustHistory(credentials: AccountSessionCredentials, device: AccountDeviceIdentity, applying: any AccountTrustHistoryApplying, now: Date) async throws -> TrustStateCommitV1? { throw AccountRuntimeError.untrustedResponse }
    func securityEvents(cursor: String?, limit: Int, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountSecurityEventPageV1 { throw AccountRuntimeError.untrustedResponse }
    func prepareRecovery(identityToken: String, appleNonce: Data, device: AccountDeviceIdentity) async throws -> (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data) { throw AccountRuntimeError.untrustedResponse }
    func commitRecovery(candidate: AccountTrustHistoryEntryV1, authorizationID: AccountAuthorizationID, device: AccountDeviceIdentity) async throws -> AccountRecoveryActivationV1 { throw AccountRuntimeError.untrustedResponse }
}

@MainActor
final class AccountActiveAdmissionOwnRequestTests: XCTestCase {
    /// After a device recovers its account it gets a new device ID, but its own earlier,
    /// abandoned approval request (same keys) is still pending. It must never ask the
    /// device to approve itself, which would only end in "This sign-in request expired".
    func testADeviceIsNeverAskedToApproveItsOwnEarlierRequest() async throws {
        let fixture = try await ActiveAdmissionFailureFixture(pendingIsOwnersOwnRequest: true)
        let controller = fixture.controller()

        controller.refresh()
        var prompts: [AccountActiveAdmissionController.PendingPrompt]?
        for _ in 0 ..< 300 {
            if case .idle(let listed) = controller.state, listed.isEmpty == false || prompts == nil {
                prompts = listed
            }
            if prompts != nil { try await Task.sleep(for: .milliseconds(30)); break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .idle(let listed) = controller.state else { return XCTFail("Expected the pending list") }
        XCTAssertEqual(listed, [])
    }
}

private struct AdmissionFixture {
    let commit: AccountTrustStateCommit
    let evidence: AccountTrustAdmissionEvidence
}

private actor ImmediateOwnerAdmissionRendezvous: AccountAdmissionRendezvous {
    private let pending: PendingAccountDevice
    private let submitFailure: AccountRuntimeError?
    private let responds: Bool
    private var offer: AccountTrustAdmissionOfferEnvelopeV1?
    private var cancellationCount = 0
    init(pending: PendingAccountDevice, submitFailure: AccountRuntimeError? = nil, responds: Bool = true) {
        self.pending = pending; self.submitFailure = submitFailure; self.responds = responds
    }
    func listPending() async throws -> [PendingAccountDevice] { [pending] }
    func submitOffer(_ offer: TrustHandshakeOfferV1, for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 {
        if let submitFailure { throw submitFailure }
        guard pendingDeviceID == pending.deviceID else { throw AccountRuntimeError.untrustedResponse }
        let envelope = try AccountWireCodec.decodeAdmissionOfferEnvelope(AccountWireCodec.encodeAdmissionOfferEnvelope(offer))
        self.offer = envelope
        return envelope
    }
    func fetchOffer(for _: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 { throw AccountRuntimeError.untrustedResponse }
    func submitResponse(_: AccountTrustAdmissionResponseEnvelopeV1, for _: AccountDeviceID) async throws { throw AccountRuntimeError.untrustedResponse }
    func fetchResponse(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionResponseEnvelopeV1 {
        guard responds else { throw AccountRuntimeError.transportFailure }
        guard pendingDeviceID == pending.deviceID, let offer else { throw AccountRuntimeError.untrustedResponse }
        return try AccountTrustAdmissionResponseEnvelopeV1(offerDigest: offer.offerDigest, response: TrustHandshakeResponseV1(offer: offer.offer, pendingNonce: Data(repeating: 0x5a, count: 32)))
    }
    func cancel(_ attempt: AccountTrustAdmissionCancelEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws {
        guard pendingDeviceID == pending.deviceID, attempt.offerDigest == offer?.offerDigest else { throw AccountRuntimeError.untrustedResponse }
        cancellationCount += 1
    }
    func waitForCancellation() async { while cancellationCount == 0 { await Task.yield() } }
}

@MainActor
private struct ActiveAdmissionFailureFixture {
    let owner: AccountTrustCoordinator
    let ownerIdentity: AccountDeviceIdentity
    let rendezvous: ImmediateOwnerAdmissionRendezvous
    let client: AccountAPIClient
    let credentials: AccountSessionCredentials

    init(
        createdAt: String = "2025-01-01T00:00:00Z",
        expiresAt: String = "2025-01-01T00:05:00Z",
        submitFailure: AccountRuntimeError? = nil,
        responds: Bool = true,
        pendingIsOwnersOwnRequest: Bool = false
    ) async throws {
        ownerIdentity = try fixtureIdentity()
        owner = try fixtureCoordinator(identity: ownerIdentity, store: InMemoryAccountSecretStore())
        let predecessor = try forkCommit("forkB")
        try await owner.accept(predecessor)
        let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
        let pending = try PendingAccountDevice(
            accountID: predecessor.state.accountID,
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            platform: .ios,
            publicBundle: pendingIsOwnersOwnRequest ? ownerIdentity.publicBundle : pendingIdentity.publicBundle,
            exchangeRequestDigest: Data(repeating: 0x5b, count: 32),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        credentials = try AccountSessionCredentials(accountID: predecessor.state.accountID, deviceID: predecessor.state.signerDeviceID, accessToken: "owner-access", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 0x59, count: 32), offlineLease: "owner-lease")
        rendezvous = ImmediateOwnerAdmissionRendezvous(pending: pending, submitFailure: submitFailure, responds: responds)
        let credentialStore = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "test.active.failure.client")
        let manifest = try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore(), clock: { Date(timeIntervalSince1970: 1_788_696_000) })
        client = try AccountAPIClient(transport: RejectingCountingAccountTransport(), credentialStore: credentialStore, manifestStore: manifest)
    }

    func controller(now: @escaping @Sendable () -> Date = { Date() }) -> AccountActiveAdmissionController {
        AccountActiveAdmissionController(rendezvous: rendezvous, coordinator: owner, client: client, credentials: credentials, identity: ownerIdentity, now: now)
    }

    func beginAndAwaitFailure(_ controller: AccountActiveAdmissionController) async throws -> AccountActiveAdmissionController.FailureReason? {
        controller.refresh()
        var prompt: AccountActiveAdmissionController.PendingPrompt?
        for _ in 0 ..< 300 {
            if case .idle(let prompts) = controller.state, let first = prompts.first { prompt = first; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.begin(try XCTUnwrap(prompt))
        for _ in 0 ..< 300 {
            if case .failed(let reason) = controller.state { return reason }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The active admission attempt never reported a failure.")
        return nil
    }
}

private actor RejectingCountingAccountTransport: AccountHTTPTransport {
    private var requests = 0
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        requests += 1
        throw AccountRuntimeError.transportFailure
    }
    func requestCount() -> Int { requests }
}

private struct PendingPreparedActivationFixture {
    let activation: AccountActivation
    let credentials: AccountSessionCredentials
    let prepared: AccountPreparedTrustActivation
}

private enum PendingJournalMutation: String, CustomStringConvertible {
    case signature
    case evidence
    var description: String { rawValue }
}

private func pendingPreparedActivationFixture() async throws -> PendingPreparedActivationFixture {
    let ownerIdentity = try fixtureIdentity()
    let owner = try fixtureCoordinator(identity: ownerIdentity, store: InMemoryAccountSecretStore())
    let predecessor = try forkCommit("forkB")
    try await owner.accept(predecessor)
    let pendingIdentity = try AccountDeviceIdentity(signingPrivateKey: scalar(12), agreementPrivateKey: scalar(13))
    let pendingID = try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c")
    let pending = try PendingAccountDevice(
        accountID: predecessor.state.accountID,
        deviceID: pendingID,
        platform: .ios,
        publicBundle: pendingIdentity.publicBundle,
        exchangeRequestDigest: Data(repeating: 0x71, count: 32),
        createdAt: "2025-01-01T00:00:00Z",
        expiresAt: "2025-01-01T00:05:00Z"
    )
    let offer = try await owner.beginApproval(of: pending)
    let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: 0x72, count: 32))
    let candidate = try await owner.makeAdmissionCandidate(response, authenticationConfirmed: true)
    let temporaryTrustStore = testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.pending.mutation.prepared")
    let receiver = try AccountTrustCoordinator(accountID: predecessor.state.accountID, deviceID: pendingID, platform: .ios, deviceIdentity: pendingIdentity, trustStore: temporaryTrustStore)
    try await receiver.acceptHistory([try AccountTrustHistoryEntryV1(commit: predecessor, evidence: nil), candidate])
    let activation = AccountActivation(accountID: predecessor.state.accountID, deviceID: pendingID, mode: .pending)
    let credentials = try AccountSessionCredentials(accountID: activation.accountID, deviceID: activation.deviceID, accessToken: "pending-mutation", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 0x73, count: 32), offlineLease: "pending-mutation-lease")
    return PendingPreparedActivationFixture(activation: activation, credentials: credentials, prepared: try await receiver.preparedTrustActivation())
}

private func mutatePendingActivationJournal(
    _ store: InMemoryAccountSecretStore,
    key: AccountSecretKey,
    mutation: PendingJournalMutation
) throws {
    let record = try XCTUnwrap(store.records[key])
    var journal = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.value) as? [String: Any])
    var history = try XCTUnwrap(journal["history"] as? [String])
    let lastIndex = try XCTUnwrap(history.indices.last)
    let entryData = try XCTUnwrap(Data(base64Encoded: history[lastIndex]))
    var entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: entryData) as? [String: Any])
    switch mutation {
    case .signature:
        var commit = try XCTUnwrap(entry["commit"] as? [String: Any])
        var state = try XCTUnwrap(commit["state"] as? [String: Any])
        var signature = try AccountWireCodec.decodeBase64URL(try XCTUnwrap(state["signature"] as? String))
        signature[signature.startIndex] ^= 1
        state["signature"] = AccountWireCodec.encodeBase64URL(signature)
        commit["state"] = state
        entry["commit"] = commit
    case .evidence:
        var evidence = try XCTUnwrap(entry["evidence"] as? [String: Any])
        var response = try XCTUnwrap(evidence["response"] as? [String: Any])
        response["pendingNonce"] = AccountWireCodec.encodeBase64URL(Data(repeating: 0x7f, count: 32))
        evidence["response"] = response
        entry["evidence"] = evidence
    }
    history[lastIndex] = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]).base64EncodedString()
    journal["history"] = history
    try store.replace(try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys, .withoutEscapingSlashes]), key: key, attributes: .deviceOnly)
}

private func admit(
    deviceID: AccountDeviceID,
    identity: AccountDeviceIdentity,
    to coordinator: AccountTrustCoordinator,
    digestByte: UInt8,
    nonceByte: UInt8
) async throws -> AdmissionFixture {
    let pending = try PendingAccountDevice(
        accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
        deviceID: deviceID,
        platform: .ios,
        publicBundle: identity.publicBundle,
        exchangeRequestDigest: Data(repeating: digestByte, count: 32),
        createdAt: "2025-01-01T00:00:00Z",
        expiresAt: "2025-01-01T00:05:00Z"
    )
    let offer = try await coordinator.beginApproval(of: pending)
    let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: Data(repeating: nonceByte, count: 32))
    _ = try await coordinator.approve(response, authenticationConfirmed: true)
    guard let commit = try await coordinator.currentTrustCommit() else { throw AccountProtocolError.invalidTransition }
    return AdmissionFixture(commit: commit, evidence: AccountTrustAdmissionEvidence(pendingDevice: pending, response: response))
}

private func rebindRecoveryCommitToSignedAuthorization(
    _ old: AccountTrustStateCommit,
    authorization: AccountRecoveryAuthorization
) throws -> AccountTrustStateCommit {
    guard old.state.transition.kind == .recovery, old.keyPackages.count == 1 else {
        throw AccountProtocolError.invalidTransition
    }
    let transition = try AccountTrustTransition(
        kind: .recovery,
        targetDeviceIDs: old.state.transition.targetDeviceIDs,
        priorRecordDigests: old.state.transition.priorRecordDigests,
        recoveryAuthorizationDigest: AccountTranscript.recoveryAuthorizationDigest(authorization)
    )
    let unsignedState = try AccountTrustState(
        accountID: old.state.accountID,
        epoch: old.state.epoch,
        revision: old.state.revision,
        previousCommitDigest: old.state.previousCommitDigest,
        transition: transition,
        keyGeneration: old.state.keyGeneration,
        keyCommitment: old.state.keyCommitment,
        members: old.state.members,
        signerDeviceID: old.state.signerDeviceID,
        signature: Data(repeating: 1, count: 64)
    )
    let state = try AccountTrustState(
        accountID: unsignedState.accountID,
        epoch: unsignedState.epoch,
        revision: unsignedState.revision,
        previousCommitDigest: unsignedState.previousCommitDigest,
        transition: unsignedState.transition,
        keyGeneration: unsignedState.keyGeneration,
        keyCommitment: unsignedState.keyCommitment,
        members: unsignedState.members,
        signerDeviceID: unsignedState.signerDeviceID,
        signature: try fixtureDeterministicSignature(role: "exchangeSigning", transcript: AccountTranscript.trustState(unsignedState))
    )
    let package = old.keyPackages[0]
    let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: fixtureRoleScalar("exchangeAgreement"))
    let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: package.senderEphemeralPublicKey)
    let shared = try agreement.sharedSecretFromKeyAgreement(with: ephemeral)

    func kdfInfo(stateDigest: Data) -> Data {
        AccountTranscript.parts([
            Data("Plainpost.AccountGroupKeyPackage.KDF.v1".utf8),
            AccountTranscript.uuid(package.accountID.rawValue),
            AccountTranscript.u64(package.epoch.value),
            AccountTranscript.u64(package.stateRevision.value),
            AccountTranscript.u64(package.keyGeneration.value),
            stateDigest,
            AccountTranscript.uuid(package.recipientDeviceID.rawValue),
            AccountTranscript.uuid(package.senderDeviceID.rawValue),
        ])
    }
    func aad(stateDigest: Data) -> Data {
        AccountTranscript.parts([
            Data("Plainpost.AccountGroupKeyPackage.AAD.v1".utf8),
            AccountTranscript.u16(1),
            AccountTranscript.uuid(package.accountID.rawValue),
            AccountTranscript.u64(package.epoch.value),
            AccountTranscript.u64(package.stateRevision.value),
            AccountTranscript.u64(package.keyGeneration.value),
            stateDigest,
            package.keyCommitment,
            AccountTranscript.uuid(package.recipientDeviceID.rawValue),
            AccountTranscript.uuid(package.senderDeviceID.rawValue),
            package.senderEphemeralPublicKey,
        ])
    }
    let oldKey = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: package.stateDigest,
        sharedInfo: kdfInfo(stateDigest: package.stateDigest),
        outputByteCount: 32
    )
    let oldBox = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: package.nonce),
        ciphertext: package.encryptedKeyMaterial.dropLast(16),
        tag: package.encryptedKeyMaterial.suffix(16)
    )
    let material = try AES.GCM.open(oldBox, using: oldKey, authenticating: aad(stateDigest: package.stateDigest))
    let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
    let newKey = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: stateDigest,
        sharedInfo: kdfInfo(stateDigest: stateDigest),
        outputByteCount: 32
    )
    let sealed = try AES.GCM.seal(
        material,
        using: newKey,
        nonce: AES.GCM.Nonce(data: package.nonce),
        authenticating: aad(stateDigest: stateDigest)
    )
    let encrypted = sealed.ciphertext + sealed.tag
    let unsignedPackage = try AccountGroupKeyPackage(
        accountID: package.accountID,
        epoch: package.epoch,
        stateRevision: package.stateRevision,
        keyGeneration: package.keyGeneration,
        stateDigest: stateDigest,
        keyCommitment: package.keyCommitment,
        recipientDeviceID: package.recipientDeviceID,
        senderDeviceID: package.senderDeviceID,
        senderEphemeralPublicKey: package.senderEphemeralPublicKey,
        nonce: package.nonce,
        encryptedKeyMaterial: encrypted,
        signature: Data(repeating: 1, count: 64)
    )
    let encryptedDigest = Data(SHA256.hash(data: package.nonce + encrypted))
    let reboundPackage = try AccountGroupKeyPackage(
        accountID: unsignedPackage.accountID,
        epoch: unsignedPackage.epoch,
        stateRevision: unsignedPackage.stateRevision,
        keyGeneration: unsignedPackage.keyGeneration,
        stateDigest: unsignedPackage.stateDigest,
        keyCommitment: unsignedPackage.keyCommitment,
        recipientDeviceID: unsignedPackage.recipientDeviceID,
        senderDeviceID: unsignedPackage.senderDeviceID,
        senderEphemeralPublicKey: unsignedPackage.senderEphemeralPublicKey,
        nonce: unsignedPackage.nonce,
        encryptedKeyMaterial: unsignedPackage.encryptedKeyMaterial,
        signature: try fixtureDeterministicSignature(role: "exchangeSigning", transcript: AccountTranscript.groupKeyPackage(
            unsignedPackage,
            encryptedDigest: encryptedDigest
        ))
    )
    return try AccountTrustStateCommit(state: state, keyPackages: [reboundPackage])
}

private func recoveryAuthorization(
    _ source: AccountRecoveryAuthorization,
    replacing predecessor: AccountTrustStateCommit
) throws -> AccountRecoveryAuthorization {
    let priorDigest = AccountTranscript.trustCommitDigest(predecessor)
    let unsigned = try AccountRecoveryAuthorization(
        authorizationID: source.authorizationID, accountID: source.accountID, epoch: source.epoch,
        deviceID: source.deviceID, platform: source.platform, publicBundle: source.publicBundle,
        priorCommitDigest: priorDigest, exchangeRequestDigest: source.exchangeRequestDigest,
        issuedAt: source.issuedAt, expiresAt: source.expiresAt, serverKeyID: source.serverKeyID,
        serverSignature: Data(repeating: 1, count: 64)
    )
    let signer = try AccountDeviceIdentity(
        signingPrivateKey: fixtureRoleScalar("recoveryAuthorization"),
        agreementPrivateKey: fixtureRoleScalar("deviceAgreement")
    )
    return try AccountRecoveryAuthorization(
        authorizationID: unsigned.authorizationID, accountID: unsigned.accountID, epoch: unsigned.epoch,
        deviceID: unsigned.deviceID, platform: unsigned.platform, publicBundle: unsigned.publicBundle,
        priorCommitDigest: unsigned.priorCommitDigest, exchangeRequestDigest: unsigned.exchangeRequestDigest,
        issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt, serverKeyID: unsigned.serverKeyID,
        serverSignature: signer.signature(for: AccountTranscript.recoveryAuthorization(unsigned))
    )
}

private final class HeadCASCrashSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore
    private let lock = NSLock()
    private let crashOnHeadCAS: Int
    private var headCASCount = 0

    init(backing: InMemoryAccountSecretStore, crashOnHeadCAS: Int = 1) {
        self.backing = backing
        self.crashOnHeadCAS = crashOnHeadCAS
    }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws { try backing.replace(value, key: key, attributes: attributes) }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        lock.lock()
        if key.account.hasPrefix("trust-head.v3.") { headCASCount += 1 }
        let shouldCrash = key.account.hasPrefix("trust-head.v3.") && headCASCount == crashOnHeadCAS
        lock.unlock()
        if shouldCrash { throw AccountRuntimeError.secretUnavailable }
        return try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws { try backing.delete(key) }
}

private struct ImmediateAccountOperationFence: AccountOperationFencing {
    func withLock<T>(accountID _: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        try operation()
    }
}

private final class TestAccountOperationFence: AccountOperationFencing, @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(accountID _: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private let testAccountOperationFence: any AccountOperationFencing = TestAccountOperationFence()

private func testTrustStore(secretStore: any AccountSecretStoring, service: String) -> AccountTrustStore {
    AccountTrustStore(secretStore: secretStore, service: service, operationFence: testAccountOperationFence)
}

private final class DeleteOnceSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore
    private let lock = NSLock()
    private var failed = false

    init(backing: InMemoryAccountSecretStore) { self.backing = backing }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        try backing.replace(value, key: key, attributes: attributes)
    }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws {
        lock.lock()
        let shouldFail = !failed && key.account.hasPrefix("trust-material.v3.")
        if shouldFail { failed = true }
        lock.unlock()
        if shouldFail { throw AccountRuntimeError.secretUnavailable }
        try backing.delete(key)
    }
}

private final class DeleteAlwaysSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore

    init(backing: InMemoryAccountSecretStore) { self.backing = backing }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        try backing.replace(value, key: key, attributes: attributes)
    }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_: AccountSecretKey) throws { throw AccountRuntimeError.secretUnavailable }
}

private final class HighWaterWriteCrashSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore
    private var crashed = false
    private let lock = NSLock()

    init(backing: InMemoryAccountSecretStore) { self.backing = backing }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        try backing.replace(value, key: key, attributes: attributes)
    }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        lock.lock()
        let shouldCrash = !crashed && key.account.hasPrefix("account-record-high-water.v1.")
        if shouldCrash { crashed = true }
        lock.unlock()
        if shouldCrash { throw AccountRuntimeError.secretUnavailable }
        return try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws { try backing.delete(key) }
}

private final class FailOnceSessionSaveSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore
    private let lock = NSLock()
    private var failed = false

    init(backing: InMemoryAccountSecretStore) { self.backing = backing }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws { try backing.replace(value, key: key, attributes: attributes) }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        lock.lock()
        let shouldFail = !failed && key.account.hasPrefix("v1.")
        if shouldFail { failed = true }
        lock.unlock()
        if shouldFail { throw AccountRuntimeError.secretUnavailable }
        return try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws { try backing.delete(key) }
}

private final class PausingSecretStore: AccountSecretStoring, @unchecked Sendable {
    enum Point {
        case compareAndSwap(prefix: String)
        case delete(prefix: String)
    }

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let backing: InMemoryAccountSecretStore
    private let lock = NSLock()
    private var point: Point?
    private var consumed = false

    init(backing: InMemoryAccountSecretStore) { self.backing = backing }
    func arm(_ point: Point) { lock.lock(); self.point = point; consumed = false; lock.unlock() }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws { try backing.replace(value, key: key, attributes: attributes) }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        pauseIfNeeded(.compareAndSwap(prefix: key.account))
        return try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws {
        pauseIfNeeded(.delete(prefix: key.account))
        try backing.delete(key)
    }
    private func pauseIfNeeded(_ actual: Point) {
        lock.lock()
        let shouldPause: Bool
        if consumed { shouldPause = false }
        else {
            switch (point, actual) {
            case (.compareAndSwap(let expected)?, .compareAndSwap(let actual)): shouldPause = actual.hasPrefix(expected)
            case (.delete(let expected)?, .delete(let actual)): shouldPause = actual.hasPrefix(expected)
            default: shouldPause = false
            }
        }
        if shouldPause { consumed = true }
        lock.unlock()
        if shouldPause {
            entered.signal()
            release.wait()
        }
    }
}

private func scalar(_ value: UInt8) -> Data { Data(repeating: 0, count: 31) + Data([value]) }

private func overCapGCJournalData(accountID: PlainpostAccountID) throws -> Data {
    var journal = StoredTrustGCIndex()
    journal.snapshots = (0..<5).map {
        "trust-snapshot.v3.\(accountID.rawValue).\(AccountWireCodec.encodeBase64URL(Data(repeating: UInt8($0), count: 32)))"
    }
    return try JSONEncoder().encode(journal)
}

private func recordHighWater(revision: UInt64) throws -> AccountRecordHighWater {
    try AccountRecordHighWater(
        epoch: AccountTrustEpoch(rawValue: PositiveUInt64(1)),
        keyGeneration: PositiveUInt64(1),
        recordRevision: PositiveUInt64(revision),
        envelopeDigest: Data(repeating: UInt8(truncatingIfNeeded: revision), count: 32)
    )
}

private func historyEntryDigest(_ entry: AccountTrustHistoryEntryV1) -> Data {
    let commitDigest = AccountTranscript.trustCommitDigest(entry.commit)
    let kind: Data
    let evidenceDigest: Data
    switch entry.evidence {
    case .admission(let evidence):
        kind = Data("account.trust-admission-evidence.v1".utf8)
        let pending = Data(SHA256.hash(data: AccountTranscript.pendingDeviceAuthorization(evidence.pendingDevice)))
        let handshake = AccountTrustAuthentication.handshakeDigest(evidence.response)
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
    return Data(SHA256.hash(data: AccountTranscript.parts([commitDigest, kind, evidenceDigest])))
}

private extension Data {
    func hexEncodedString() -> String { map { String(format: "%02x", $0) }.joined() }
}

private func publicKey(_ scalar: Data, agreement: Bool) throws -> Data {
    if agreement { return try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation }
    return try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}

private final class FixtureRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt8 = 40
    func bytes(count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        next &+= 1
        return Data(repeating: next, count: count)
    }
}

private func fixtureCoordinator(
    identity: AccountDeviceIdentity,
    store: InMemoryAccountSecretStore,
    service: String = "test.trust.\(UUID().uuidString)"
) throws -> AccountTrustCoordinator {
    try fixtureCoordinator(identity: identity, secretStore: store, service: service)
}

private func fixtureCoordinator(
    identity: AccountDeviceIdentity,
    secretStore: any AccountSecretStoring,
    service: String
) throws -> AccountTrustCoordinator {
    let random = FixtureRandom()
    return try AccountTrustCoordinator(
        accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
        deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
        platform: .macos,
        deviceIdentity: identity,
        trustStore: testTrustStore(secretStore: secretStore, service: service),
        offlineRootKeyID: fixtureOfflineRootKeyID,
        offlineRootPublicKey: try fixtureOfflineRootKey(),
        now: { Date(timeIntervalSince1970: 1_735_689_660.003) },
        random: { count in random.bytes(count: count) }
    )
}

private actor EndpointMetadataCASFixture: SyncNodeEndpointMetadataRemote {
    private var record: EncryptedAccountRecordV1?

    func syncNodeEndpointRecord(accountID: PlainpostAccountID, recordID: AccountRecordID, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> EncryptedAccountRecordV1? {
        guard accountID == credentials.accountID, recordID == SyncNodeEndpointMetadata.recordID else { throw AccountRuntimeError.untrustedResponse }
        return record
    }

    func putSyncNodeEndpointRecord(_ proposed: EncryptedAccountRecordV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws {
        guard proposed.accountID == credentials.accountID, proposed.recordID == SyncNodeEndpointMetadata.recordID else { throw AccountRuntimeError.untrustedResponse }
        if let record, proposed.recordRevision <= record.recordRevision { throw AccountRuntimeError.transportFailure }
        record = proposed
    }

    func current() -> EncryptedAccountRecordV1? { record }
}

private actor PrivateActivationEvents {
    enum Value: Equatable { case v3, metadata }
    private var recorded: [Value] = []
    func record(_ value: Value) { recorded.append(value) }
    func values() -> [Value] { recorded }
}

private actor PrivateActivationMetadataFixture: SyncNodeEndpointMetadataRemote {
    private let events: PrivateActivationEvents
    private var record: EncryptedAccountRecordV1?
	private var failNext = false
    private var tokens: [String] = []
    init(events: PrivateActivationEvents) { self.events = events }
	func failNextPut() { failNext = true }
    func accessTokens() -> [String] { tokens }
    func syncNodeEndpointRecord(accountID: PlainpostAccountID, recordID: AccountRecordID, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> EncryptedAccountRecordV1? { tokens.append(credentials.accessToken); return record }
    func putSyncNodeEndpointRecord(_ proposed: EncryptedAccountRecordV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws {
        tokens.append(credentials.accessToken)
		if failNext { failNext = false; throw AccountRuntimeError.transportFailure }
        guard record == nil else { throw AccountRuntimeError.transportFailure }
        record = proposed
        await events.record(.metadata)
    }
    func current() -> EncryptedAccountRecordV1? { record }
}

private final class PrivateActivationSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AccountSessionCredentials
    init(_ value: AccountSessionCredentials) { current = value }
    var value: AccountSessionCredentials {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private actor PrivateActivationV3Transport: NodeHTTPTransport {
    private let endpoint: URL
    private let events: PrivateActivationEvents
    private var statuses: [Int]
    init(endpoint: URL, events: PrivateActivationEvents, statuses: [Int] = [204]) { self.endpoint = endpoint; self.events = events; self.statuses = statuses }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        guard request.url?.path == "/v1/activate", request.httpMethod == "POST" else { throw NodeSessionError.invalidValue }
        await events.record(.v3)
        return NodeHTTPResponse(statusCode: statuses.removeFirst(), url: endpoint, headers: [:], body: Data())
    }
}

private actor BlockingPrivateActivationV3Transport: NodeHTTPTransport {
    private let endpoint: URL
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    init(endpoint: URL) { self.endpoint = endpoint }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        guard request.url?.path == "/v1/activate", request.httpMethod == "POST" else { throw NodeSessionError.invalidValue }
        started = true; waiters.forEach { $0.resume() }; waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        return NodeHTTPResponse(statusCode: 204, url: endpoint, headers: [:], body: Data())
    }
    func waitUntilStarted() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct PrivateActivationFixture {
    let activator: PrivateSyncNodeEnrollmentActivator
    let response: AccountNodeEnrollmentAdmissionResponseV2
    let request: SyncNodeEnrollmentAdmissionRequest
    let claim: AccountNodeEnrollmentPublicClaimV1
    let setupCode: Data
    let reference: SyncNodeEndpointReference
    let store: SyncNodeEndpointStore
    let remote: PrivateActivationMetadataFixture
    let events: PrivateActivationEvents
	let credentials: AccountSessionCredentials
	let identity: AccountDeviceIdentity
	let trust: AccountTrustCoordinator
	let client: NodeTLSClient

    init(statuses: [Int] = [204], secretStore: any AccountSecretStoring = InMemoryAccountSecretStore(), transport: (any NodeHTTPTransport)? = nil) async throws {
        identity = try fixtureIdentity()
        trust = try fixtureCoordinator(identity: identity, store: InMemoryAccountSecretStore())
        let commit = try forkCommit("forkB")
        try await trust.accept(commit)
        let account = commit.state.accountID
        let nodeID = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let claimID = try NodeEnrollmentClaimID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let signingPrivate = P256.Signing.PrivateKey()
        let signing = signingPrivate.publicKey.x963Representation
        let agreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let endpoint = "https://node.tail1234.ts.net:8443"
        setupCode = Data(repeating: 0x11, count: 32)
        guard let uuid = UUID(uuidString: nodeID.rawValue) else { throw AccountRuntimeError.untrustedResponse }
        var raw = uuid.uuid
        let binding = try NodeEndpointClaimBinding(nodeID: withUnsafeBytes(of: &raw) { Data($0) }, signingPublicKey: signing, agreementPublicKey: agreement, noiseStaticPublicKey: Data(repeating: 7, count: 32), endpointDigest: Data(SHA256.hash(data: Data(endpoint.utf8))), expiresAt: "2026-08-05T12:05:00Z")
        let ciphertext = try NodeEndpointCipher.sealForTesting(endpoint: endpoint, setupCode: setupCode, binding: binding, nonce: Data(repeating: 4, count: 12))
        claim = try AccountNodeEnrollmentPublicClaimV1(claimID: claimID, nodeDeviceID: nodeID, signingPublicKey: signing, agreementPublicKey: agreement, noiseStaticPublicKey: binding.noiseStaticPublicKey, endpointCiphertext: ciphertext, endpointDigest: binding.endpointDigest, createdAt: "2026-08-05T12:00:00Z", expiresAt: binding.expiresAt)
        let matchingDigest = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentMatchingConfirmation(claim, accountID: account)))
        let evidence = try syncNodeEvidence(
            predecessor: commit, identity: identity, claimID: claimID, nodeDeviceID: nodeID,
            action: .enroll, replacedNodeID: nil, signingPublicKey: signing,
            agreementPublicKey: agreement, noiseStaticPublicKey: binding.noiseStaticPublicKey,
            endpointDigest: binding.endpointDigest,
            matchingTranscriptDigest: matchingDigest
        )
        let proofClaim = try AccountNodeEnrollmentClaimV1(claimID: claimID, nodeDeviceID: nodeID, signingPublicKey: signing, agreementPublicKey: agreement, noiseStaticPublicKey: binding.noiseStaticPublicKey, endpointCiphertext: ciphertext, setupVerifier: Data(repeating: 0x0a, count: 32), endpointDigest: binding.endpointDigest, createdAt: claim.createdAt, expiresAt: claim.expiresAt)
        let proofSignature = privateActivationLowSSignature(try signingPrivate.signature(for: AccountTranscript.nodeEnrollmentClaimProof(proofClaim)).rawRepresentation)
        let successor = try await trust.makeSyncNodeEnrollmentCommit(evidence: evidence)
        request = try SyncNodeEnrollmentAdmissionRequest(evidence: evidence, claimProofSignature: proofSignature, matchingConfirmationSignature: Data(repeating: 4, count: 64), admissionApprovalSignature: Data(repeating: 5, count: 64), idempotencyKey: Data(repeating: 6, count: 32), trustCommit: successor)
        let capability = try AccountSyncNodeCleanupCapabilityV1(accountID: account, claimID: claimID, nodeDeviceID: nodeID, targetHandle: Data(repeating: 8, count: 32), cleanupCredential: Data(repeating: 9, count: 32), deletionGeneration: try PositiveUInt64(1), issuedAt: "2026-08-05T12:00:00Z")
        let base = try AccountNodeOperationBindingV1(accountID: account, trustEpoch: commit.state.epoch, claimID: claimID, nodeDeviceID: nodeID, centralAudience: "central.test", action: .enroll, replacedNodeID: nil, replacementRevocationDigest: nil, admissionEvidenceDigest: Data(SHA256.hash(data: try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(evidence))), issuanceDigest: Data(repeating: 2, count: 32))
        let operation = try AccountNodeOperationBindingV2(base: base, cleanupCapabilityDigest: Data(SHA256.hash(data: try AccountWireCodec.encodeSyncNodeCleanupCapability(capability))))
        let result = try AccountNodeEnrollmentResultV2(binding: operation, committedAt: "2026-08-05T12:00:00Z")
        let refresh = try AccountNodeRefreshCredentialV2(binding: operation, credentialID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z", credential: Data(repeating: 10, count: 32))
        let unsigned = try AccountNodeOfflineLeaseV2(binding: operation, leaseID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z", serverKeyID: "offline-test-1", signature: Data(repeating: 1, count: 64))
        let signature = privateActivationLowSSignature(try P256.Signing.PrivateKey(rawRepresentation: scalar(3)).signature(for: AccountTranscript.nodeOfflineLeaseV2(unsigned)).rawRepresentation)
        let lease = try AccountNodeOfflineLeaseV2(binding: operation, leaseID: unsigned.leaseID, issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt, serverKeyID: unsigned.serverKeyID, signature: signature)
        response = try AccountNodeEnrollmentAdmissionResponseV2(result: result, refreshCredential: refresh, offlineLease: lease, cleanupCapability: capability)
		credentials = try AccountSessionCredentials(accountID: account, deviceID: commit.state.signerDeviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 11, count: 32), offlineLease: "lease")
        store = try SyncNodeEndpointStore(secretStore: secretStore, service: "test.private-activation")
        reference = try SyncNodeEndpointReference(accountID: account, nodeID: nodeID, trustEpoch: commit.state.epoch, endpointCiphertext: ciphertext)
        events = PrivateActivationEvents()
        remote = PrivateActivationMetadataFixture(events: events)
		client = NodeTLSClient(transport: transport ?? PrivateActivationV3Transport(endpoint: URL(string: endpoint)!, events: events, statuses: statuses))
        activator = try PrivateSyncNodeEnrollmentActivator(remote: remote, trust: trust, store: store, client: client, credentials: credentials, credentialsProvider: { [credentials] in credentials }, device: identity)
    }
}

private func privateActivationLowSSignature(_ signature: Data) -> Data {
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

private func fixtureIdentity() throws -> AccountDeviceIdentity {
    let root = try fixtureRoot()
    let roles = (((root["testOnlyInputs"] as? [String: Any])?["roles"] as? [String: Any]) ?? [:])
    let signing = ((roles["deviceSigning"] as? [String: Any])?["privateScalarHex"] as? String) ?? ""
    let agreement = ((roles["deviceAgreement"] as? [String: Any])?["privateScalarHex"] as? String) ?? ""
    return try AccountDeviceIdentity(signingPrivateKey: try Data(hex: signing), agreementPrivateKey: try Data(hex: agreement))
}

private func syncNodeEvidence(
    predecessor: AccountTrustStateCommit,
    identity: AccountDeviceIdentity,
    claimID: NodeEnrollmentClaimID,
    nodeDeviceID: AccountDeviceID,
    action: AccountNodeEnrollmentAction,
    replacedNodeID: AccountDeviceID?,
    signingPublicKey: Data? = nil,
    agreementPublicKey: Data? = nil,
    noiseStaticPublicKey: Data? = nil,
    endpointDigest: Data? = nil,
    matchingTranscriptDigest: Data? = nil
) throws -> AccountNodeEnrollmentAdmissionEvidenceV1 {
    let signing = signingPublicKey ?? P256.Signing.PrivateKey().publicKey.x963Representation
    let agreement = agreementPublicKey ?? P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let stepUp = try AccountStepUpAuthorizationV1(
        authorizationID: AccountAuthorizationID(action == .enroll ? "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1" : "ffffffff-ffff-4fff-8fff-fffffffffff1"),
        accountID: predecessor.state.accountID,
        actorDeviceID: predecessor.state.signerDeviceID,
        targetDeviceID: action == .enroll ? nodeDeviceID : replacedNodeID,
        action: action == .enroll ? .enrollSyncNode : .replaceSyncNode,
        currentCommitDigest: AccountTranscript.trustCommitDigest(predecessor),
        requestDigest: Data(repeating: action == .enroll ? 0x51 : 0x52, count: 32),
        issuedAt: "2025-01-01T00:00:00Z",
        expiresAt: "2025-01-01T00:05:00Z",
        serverKeyID: "test-key",
        serverSignature: try identity.signature(for: Data("sync-node-step-up".utf8))
    )
    return try AccountNodeEnrollmentAdmissionEvidenceV1(
        accountID: predecessor.state.accountID,
        trustEpoch: predecessor.state.epoch,
        approverDeviceID: predecessor.state.signerDeviceID,
        claimID: claimID,
        nodeDeviceID: nodeDeviceID,
        action: action,
        replacedNodeID: replacedNodeID,
        signingPublicKey: signing,
        agreementPublicKey: agreement,
        noiseStaticPublicKey: noiseStaticPublicKey ?? Data(repeating: action == .enroll ? 0x61 : 0x62, count: 32),
        endpointDigest: endpointDigest ?? Data(repeating: action == .enroll ? 0x71 : 0x72, count: 32),
        matchingTranscriptDigest: matchingTranscriptDigest ?? Data(repeating: action == .enroll ? 0x81 : 0x82, count: 32),
        stepUp: stepUp
    )
}

private func fixtureRoleScalar(_ role: String) throws -> Data {
    let root = try fixtureRoot()
    let roles = try XCTUnwrap((try XCTUnwrap(root["testOnlyInputs"] as? [String: Any]))["roles"] as? [String: Any])
    let item = try XCTUnwrap(roles[role] as? [String: Any])
    return try Data(hex: try XCTUnwrap(item["privateScalarHex"] as? String))
}

private func fixtureDeterministicSignature(role: String, transcript: Data) throws -> Data {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Services/PlainpostGo/scripts/rfc6979_sign.go")
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["go", "run", script.path, try fixtureRoleScalar(role).hexEncodedString(), transcript.hexEncodedString()]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let encoded = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    else {
        let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "deterministic signer failed"
        throw NSError(domain: "PlainpostFixtureSigner", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return try Data(hex: encoded.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func fixtureRoleFreeKey(_ key: String) throws -> Data {
    let root = try fixtureRoot()
    let inputs = try XCTUnwrap(root["testOnlyInputs"] as? [String: Any])
    return try Data(hex: try XCTUnwrap(inputs[key] as? String))
}

private func recoveryCoordinator(identity: AccountDeviceIdentity, predecessor: AccountTrustStateCommit) throws -> AccountTrustCoordinator {
    let random = FixtureRandom()
    return try AccountTrustCoordinator(
        accountID: predecessor.state.accountID,
        deviceID: try AccountDeviceID("44444444-5555-4666-8777-888888888888"),
        platform: .macos,
        deviceIdentity: identity,
        trustStore: testTrustStore(secretStore: InMemoryAccountSecretStore(), service: "test.trust.recovery.\(UUID().uuidString)"),
        initialCommit: predecessor,
        offlineRootKeyID: fixtureOfflineRootKeyID,
        offlineRootPublicKey: try fixtureOfflineRootKey(),
        now: { Date(timeIntervalSince1970: 1_785_751_620) },
        random: { count in random.bytes(count: count) }
    )
}

private func recoveryManifestStore(clock: @escaping @Sendable () -> Date) throws -> BootstrapKeyManifestStore {
    let rootKey = try fixtureOfflineRootKey()
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Protocol/account-v1/fixtures/central-bootstrap-manifest-test-v1.json")
    return try BootstrapKeyManifestStore(
        bundledManifest: Data(contentsOf: url),
        offlineRootKeyID: fixtureOfflineRootKeyID,
        offlineRootPublicKey: rootKey,
        secretStore: InMemoryAccountSecretStore(),
        clock: clock
    )
}

private func signedInventoryProof(
    records: [EncryptedAccountRecordV1],
    coordinator: AccountTrustCoordinator,
    signingRole: String = "pagination",
    serverKeyID: String = "pagination-2026-01",
    issuedAt: String = "2026-08-08T10:00:00Z",
    expiresAt: String = "2026-08-08T10:05:00Z",
    trustCommitDigestOverride: Data? = nil
) async throws -> AccountRecordInventoryProofV1 {
    let current = try await coordinator.currentTrustCommit()
    let commit = try XCTUnwrap(current)
    let entries = try records.sorted { $0.recordID.rawValue < $1.recordID.rawValue }.map { record in
        try AccountRecordInventoryEntryV1(
            recordID: record.recordID,
            epoch: record.epoch,
            keyGeneration: record.keyGeneration,
            trustRevision: record.trustRevision,
            recordRevision: record.recordRevision,
            envelopeDigest: Data(SHA256.hash(data: record.envelope)),
            signatureDigest: Data(SHA256.hash(data: record.signature))
        )
    }
    let unsigned = try AccountRecordInventoryProofV1(
        accountID: commit.state.accountID,
        trustCommitDigest: trustCommitDigestOverride ?? AccountTranscript.trustCommitDigest(commit),
        epoch: commit.state.epoch,
        keyGeneration: commit.state.keyGeneration,
        entries: entries,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        serverKeyID: serverKeyID,
        serverSignature: Data(repeating: 1, count: 64)
    )
    let signing = try AccountDeviceIdentity(
        signingPrivateKey: try fixtureRoleScalar(signingRole),
        agreementPrivateKey: try fixtureRoleScalar("deviceAgreement")
    )
    return try AccountRecordInventoryProofV1(
        accountID: unsigned.accountID,
        trustCommitDigest: unsigned.trustCommitDigest,
        epoch: unsigned.epoch,
        keyGeneration: unsigned.keyGeneration,
        entries: unsigned.entries,
        issuedAt: unsigned.issuedAt,
        expiresAt: unsigned.expiresAt,
        serverKeyID: unsigned.serverKeyID,
        serverSignature: signing.signature(for: AccountTrustTranscript.recordInventoryProof(unsigned))
    )
}

private func retireWithSignedInventory(
    coordinator: AccountTrustCoordinator,
    epoch: AccountTrustEpoch,
    keyGeneration: PositiveUInt64,
    records: [EncryptedAccountRecordV1]
) async throws {
    let proof = try await signedInventoryProof(records: records, coordinator: coordinator)
    let manifest = try recoveryManifestStore(clock: { Date(timeIntervalSince1970: 1_786_183_260) })
    try await coordinator.retireAccountKeyGeneration(
        epoch: epoch,
        keyGeneration: keyGeneration,
        afterMigrating: records,
        inventoryProof: proof,
        manifestStore: manifest
    )
}

private let fixtureOfflineRootKeyID = "plainpost-root-2026-01"
private func fixtureOfflineRootKey() throws -> Data {
    try AccountWireCodec.decodeBase64URL("BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU", exactBytes: 65)
}

private func commitDigest(_ commit: AccountTrustStateCommit) -> Data {
    AccountTranscript.trustCommitDigest(commit)
}

private func forkCommit(_ name: String) throws -> AccountTrustStateCommit {
    let root = try fixtureRoot()
    guard let vector = root["predecessorCommitForkVector"] as? [String: Any],
          let section = vector[name] as? [String: Any],
          let commit = section["commit"]
    else { throw AccountProtocolError.malformedWire }
    return try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: commit, options: [.sortedKeys, .withoutEscapingSlashes]))
}

private func fixtureRoot() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
    guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw AccountProtocolError.malformedWire }
    return root
}

private func trustMailboxVector() throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Protocol/account-v1/fixtures/trust-v1.json")
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let mailbox = try XCTUnwrap(root["mailboxMatching"] as? [String: Any])
    return try Data(hex: try XCTUnwrap(mailbox["expectedLogicalMailboxID"] as? String))
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw AccountProtocolError.malformedWire }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { throw AccountProtocolError.malformedWire }
            result.append(value)
            index = next
        }
        self = result
    }
}
