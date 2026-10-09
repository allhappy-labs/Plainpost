import Foundation
import CryptoKit
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
@testable import PlainpostNodeTransport

final class PlainpostNodeMailAuthorityTests: XCTestCase {
    func testFactoryIsTheSingleAuthorizedAndCachedAuthorityAssembly() throws {
        let sender = AuthorityTestSender(response: NodeHTTPResponse(
            statusCode: 200,
            url: URL(string: "https://node.example.ts.net:443")!,
            headers: [:], body: Data()
        ))
        let client = NodeSyncClient(sender: sender)
        let accountID = AccountID("factory-account")

        let authorized = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: accountID, access: .authorized
        )
        XCTAssertTrue(authorized is PlainpostNodeMailAuthority)

        let cached = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: accountID, access: .cachedReadOnly
        )
        XCTAssertFalse(cached is PlainpostNodeMailAuthority)
    }

    func testStatusRefreshActivatesRetainedAuthoritySender() async throws {
        let status = try NodeSyncStatusResult(
            revision: "1", state: "ready", version: "node-sync-v1", reachability: "reachable",
            syncLag: "0", storage: "managed", providerIdentity: "user@example.com", assignments: [],
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
        let sender = AuthorityTestSender(response: NodeHTTPResponse(
            statusCode: 200,
            url: URL(string: "https://node.example.ts.net:443")!,
            headers: [:], body: try NodeSyncCodec.encodeStatusResult(status)
        ))
        let authority = PlainpostNodeMailAuthority(client: NodeSyncClient(sender: sender), accountID: AccountID("account-1"))

        XCTAssertNil(authority.senderAddress)
        _ = try await authority.status()
        XCTAssertEqual(authority.senderAddress, EmailAddress("user@example.com"))
    }

    func testNotificationTapWakeUsesAuthenticatedProviderSyncRoute() async throws {
        let sender = ProviderSyncWakeTestSender()
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: AccountID("account-1")
        )

        try await authority.requestProviderSyncForNotification()

        let requests = await sender.requests()
        XCTAssertEqual(requests.map(\.path), ["/v1/provider-sync"])
        XCTAssertEqual(requests.map(\.method), ["POST"])
        XCTAssertEqual(try NodeSyncCodec.decodeProviderSyncRequest(requests[0].body), NodeSyncProviderSyncRequest())
    }

    func testExistingAuthorityIdentityRejectsMismatchedOAuthWithoutPublishingOrAssigning() async throws {
        let sender = ProviderAuthorityTestSender(configuredIdentity: "provider-b@example.com")
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: AccountID("account-1"),
            senderAddress: EmailAddress("provider-a@example.com")
        )
        let request = try authority.providerController.makeGoogleAuthorizationRequest(
            clientID: "ios-client", redirectURI: "https://mail.example.test/oauth/google"
        )
        let callback = URL(string: "https://mail.example.test/oauth/google?code=one-time-code&state=\(request.state)")!

        do {
            _ = try await authority.providerController.completeGoogleAuthorization(callbackURL: callback)
            XCTFail("OAuth must not replace the authenticated authority identity")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        XCTAssertEqual(authority.senderAddress, EmailAddress("provider-a@example.com"))
        let statusCount = await sender.statusCount()
        let assignmentCount = await sender.assignmentCount()
        XCTAssertEqual(statusCount, 0, "mismatched configure must not publish unchecked status")
        XCTAssertEqual(assignmentCount, 0, "mismatched configure must not reach assignment")
    }

    func testExistingAuthorityIdentityAcceptsMatchingOAuthAndPublishesAuthenticatedStatus() async throws {
        let sender = ProviderAuthorityTestSender(configuredIdentity: "provider-a@example.com")
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: AccountID("account-1"),
            senderAddress: EmailAddress("provider-a@example.com")
        )
        let request = try authority.providerController.makeGoogleAuthorizationRequest(
            clientID: "ios-client", redirectURI: "https://mail.example.test/oauth/google"
        )
        let callback = URL(string: "https://mail.example.test/oauth/google?code=one-time-code&state=\(request.state)")!

        let result = try await authority.providerController.completeGoogleAuthorization(callbackURL: callback)

        XCTAssertEqual(result.providerIdentity, "provider-a@example.com")
        XCTAssertEqual(authority.senderAddress, EmailAddress("provider-a@example.com"))
        let statusCount = await sender.statusCount()
        XCTAssertEqual(statusCount, 1, "matching OAuth must publish the authenticated status")
    }

    func testStatusRefreshRejectsProviderIdentityDriftWithoutPublishingNewSender() async throws {
        let sender = AuthorityStatusDriftTestSender()
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: AccountID("account-1"),
            senderAddress: EmailAddress("provider-a@example.com")
        )
        let publicationProbe = StatusPublicationProbe()
        authority.onStatusRefresh = { _ in publicationProbe.markPublished() }

        do {
            _ = try await authority.status()
            XCTFail("a status from a different provider must fail closed")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        XCTAssertNil(authority.senderAddress, "identity drift must disable the authority")
        XCTAssertFalse(publicationProbe.wasPublished(), "the unchecked provider status must not be published")
    }

    func testStatusCallbackAndSenderProjectionAreSafeDuringConcurrentRefreshes() async throws {
        let status = try NodeSyncStatusResult(
            revision: "1", state: "ready", version: "node-sync-v1", reachability: "reachable",
            syncLag: "0", storage: "managed", providerIdentity: "user@example.com", assignments: [],
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
        let sender = AuthorityTestSender(response: NodeHTTPResponse(
            statusCode: 200,
            url: URL(string: "https://node.example.ts.net:443")!,
            headers: [:], body: try NodeSyncCodec.encodeStatusResult(status)
        ))
        let authority = PlainpostNodeMailAuthority(client: NodeSyncClient(sender: sender), accountID: AccountID("account-1"))
        authority.onStatusRefresh = { _ in }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    _ = try? await authority.status()
                    _ = authority.senderAddress
                    authority.onStatusRefresh = { _ in }
                    _ = authority.onStatusRefresh
                }
            }
        }
        XCTAssertEqual(authority.senderAddress, EmailAddress("user@example.com"))
    }

    func testMutationIntentIsBuiltByCapabilityFactoryAndSentThroughNodeClient() async throws {
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "00112233-4455-6677-8899-aabbccddeeff",
            authorityEpoch: "1",
            clientID: "11111111-2222-3333-8444-555555555555",
            idempotencyKey: "node-mutation-1",
            issuedAt: "2026-08-26T10:00:00Z",
            logicalMailboxID: try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 1, count: 32))),
            nodeID: "aaaaaaaa-bbbb-cccc-8ddd-eeeeeeeeeeee",
            operation: .setRead(messageIDs: ["message-1"], read: true),
            trustEpoch: "1"
        )
        let canonicalOperation = try NodeSyncCodec.encodeOperation(
            try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64))
        )
        let mutationResult = try NodeSyncMutationResult(idempotencyKey: "node-mutation-1", state: "applied")
        let sender = MutationAuthorityTestSender(response: NodeHTTPResponse(
            statusCode: 200,
            url: URL(string: "https://node.example.ts.net:443")!,
            headers: [:],
            body: try NodeSyncCodec.encodeMutationResult(mutationResult)
        ))
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender),
            accountID: AccountID("00112233-4455-6677-8899-aabbccddeeff"),
            mutationOperationFactory: { intent in
                guard case .setRead(messageIDs: [MessageID("message-1")], read: true) = intent else {
                    throw PlainpostError.validationFailed("unexpected mutation intent")
                }
                return canonicalOperation
            }
        )

        let result = try await authority.mutations.perform(
            .setRead(messageIDs: [MessageID("message-1")], read: true)
        )
        XCTAssertEqual(result, MailMutationResult(idempotencyKey: "node-mutation-1", state: "applied"))
        let requestValue = await sender.request()
        let request = try XCTUnwrap(requestValue)
        let sentOperation = try NodeSyncCodec.decodeMutationRequest(request.body).canonicalOperation
        XCTAssertEqual(try NodeSyncCodec.decodeOperation(sentOperation), try NodeSyncCodec.decodeOperation(canonicalOperation))
    }

    func testDraftCASUsesNewDraftZeroAndItsDurablePostSaveRevision() async throws {
        let accountID = AccountID("00112233-4455-6677-8899-aabbccddeeff")
        let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let sender = DraftCASAuthorityTestSender(accountID: accountID.rawValue, logicalMailboxID: logicalMailboxID)
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: accountID,
            senderAddress: EmailAddress("acceptance@example.test")
        )
        let draft = Draft(
            id: DraftID("draft-cas-authority"), accountID: accountID,
            from: EmailAddress("acceptance@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "CAS", bodyPlain: "body", createdBy: "acceptance",
            aiGenerated: false, sourceThreadID: nil
        )

        let saved = try await authority.mutations.perform(.saveDraft(draft))
        XCTAssertEqual(saved.state, "applied")
        let sent = try await authority.mutations.perform(.send(draft))
        XCTAssertEqual(sent.state, "applied")

        let variants = await sender.variants()
        XCTAssertEqual(variants.count, 2)
        guard case let .saveDraft(_, saveRevision, _, _) = variants[0] else {
            return XCTFail("expected save_draft operation")
        }
        guard case let .send(_, sendRevision) = variants[1] else {
            return XCTFail("expected send operation")
        }
        XCTAssertEqual(saveRevision, "0")
        XCTAssertEqual(sendRevision, "2")
    }

    func testDraftDeleteUsesSavedRevisionThroughMutationCapability() async throws {
        let accountID = AccountID("00112233-4455-6677-8899-aabbccddeeff")
        let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let sender = DraftCASAuthorityTestSender(accountID: accountID.rawValue, logicalMailboxID: logicalMailboxID)
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: accountID,
            senderAddress: EmailAddress("acceptance@example.test")
        )
        let draft = Draft(
            id: DraftID("draft-delete-authority"), accountID: accountID,
            from: EmailAddress("acceptance@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Delete", bodyPlain: "body", createdBy: "acceptance",
            aiGenerated: false, sourceThreadID: nil
        )

        let saved = try await authority.mutations.perform(.saveDraft(draft))
        let deleted = try await authority.mutations.perform(.deleteDraft(draft.id))
        XCTAssertEqual(saved.state, "applied")
        XCTAssertEqual(deleted.state, "applied")
        let variants = await sender.variants()
        guard variants.count == 2, case let .deleteDraft(deletedID, revision) = variants[1] else {
            return XCTFail("expected save followed by delete_draft")
        }
        XCTAssertEqual(deletedID, draft.id.rawValue)
        XCTAssertEqual(revision, "2")
    }

    func testRecreatedAuthorityHydratesExistingDraftRevisionFromAuthenticatedNode() async throws {
        let accountID = AccountID("00112233-4455-6677-8899-aabbccddeeff")
        let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let sender = DraftCASAuthorityTestSender(accountID: accountID.rawValue, logicalMailboxID: logicalMailboxID, initialDraftRevision: 2)
        let draft = Draft(
            id: DraftID("existing-draft"), accountID: accountID,
            from: EmailAddress("acceptance@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Existing", bodyPlain: "body", createdBy: "acceptance",
            aiGenerated: false, sourceThreadID: nil
        )

        let firstAuthority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: accountID,
            senderAddress: EmailAddress("acceptance@example.test")
        )
        let saved = try await firstAuthority.mutations.perform(.saveDraft(draft))
        XCTAssertEqual(saved.state, "applied")

        // A new authority has no process-local ledger. It must read the
        // durable draft revision before signing send, rather than infer 2.
        let recreatedAuthority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: accountID,
            senderAddress: EmailAddress("acceptance@example.test")
        )
        let sent = try await recreatedAuthority.mutations.perform(.send(draft))
        XCTAssertEqual(sent.state, "applied")

        let variants = await sender.variants()
        guard case let .saveDraft(_, saveRevision, _, _) = variants[0],
              case let .send(_, sendRevision) = variants[1] else {
            return XCTFail("expected save followed by send")
        }
        XCTAssertEqual(saveRevision, "2")
        XCTAssertEqual(sendRevision, "4")
    }

    func testDraftRevisionLedgerDoesNotRegressWhenAnOlderSaveIsReplayed() async throws {
        let accountID = AccountID("00112233-4455-6677-8899-aabbccddeeff")
        let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let sender = DraftCASAuthorityTestSender(accountID: accountID.rawValue, logicalMailboxID: logicalMailboxID)
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: accountID,
            senderAddress: EmailAddress("acceptance@example.test")
        )
        let draft = Draft(
            id: DraftID("draft-cas-replay"), accountID: accountID,
            from: EmailAddress("acceptance@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "CAS replay", bodyPlain: "body", createdBy: "acceptance",
            aiGenerated: false, sourceThreadID: nil
        )

        _ = try await authority.mutations.perform(.saveDraft(draft))
        _ = try await authority.mutations.perform(.saveDraft(draft))
        let operations = await sender.operations()
        XCTAssertEqual(operations.count, 2)

        _ = try await authority.mutations.apply(canonicalOperation: try XCTUnwrap(operations.first))
        _ = try await authority.mutations.perform(.saveDraft(draft))
        _ = try await authority.mutations.perform(.send(draft))

        let variants = await sender.variants()
        guard case let .saveDraft(_, thirdSaveRevision, _, _) = variants[3] else {
            return XCTFail("expected third save_draft operation")
        }
        guard case let .send(_, sendRevision) = variants[4] else {
            return XCTFail("expected send operation")
        }
        XCTAssertEqual(thirdSaveRevision, "4", "replaying the first applied save must not lower the durable CAS head")
        XCTAssertEqual(sendRevision, "6")
    }

    func testMutationCapabilityReconcilesPendingWithTheSameCanonicalOperation() async throws {
        let sender = SequencedMutationAuthorityTestSender(states: ["pending", "applied"])
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: AccountID("mutation-reconcile")
        )
        let canonicalOperation = try makeCanonicalSetReadOperation()

        let result = try await authority.mutations.apply(canonicalOperation: canonicalOperation)

        XCTAssertEqual(result.state, "applied")
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].body, requests[1].body, "pending reconciliation must replay exact canonical bytes")
    }

    func testMutationRejectsAuthenticatedResultForAnotherOperation() async throws {
        let sender = MismatchedMutationResultSender()
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: AccountID("mutation-reconcile")
        )
        do {
            _ = try await authority.mutations.apply(canonicalOperation: makeCanonicalSetReadOperation())
            XCTFail("A result for another idempotency key must not confirm this operation")
        } catch let error as PlainpostError {
            guard case .validationFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRestartReplaysJournaledSendWithoutSigningAnotherOperation() async throws {
        let accountID = AccountID("11111111-1111-4111-8111-111111111111")
        let draft = Draft(
            id: DraftID("journal-draft"), accountID: accountID,
            from: EmailAddress("sender@example.test"), to: [EmailAddress("receiver@example.test")],
            cc: [], bcc: [], subject: "Journal", bodyPlain: "body",
            createdBy: "test", aiGenerated: false, sourceThreadID: nil
        )
        let mailbox = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: accountID.rawValue, authorityEpoch: "2",
            clientID: "22222222-2222-4222-8222-222222222222", idempotencyKey: "retained-send",
            issuedAt: "2026-08-20T12:34:56Z", logicalMailboxID: mailbox,
            nodeID: "33333333-3333-4333-8333-333333333333",
            operation: .send(draftID: draft.id.rawValue, expectedRevision: "1"), trustEpoch: "1"
        )
        let operation = try NodeSyncCodec.encodeOperation(try NodeSyncOperation(
            unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)
        ))
        let journal = JournalTestStore(operation: operation)
        let sender = SequencedMutationAuthorityTestSender(states: ["applied"])
        let service = NodeMutationService(
            client: NodeSyncClient(sender: sender),
            operationFactory: { _, _ in XCTFail("restart must not sign a second send"); return Data() },
            draftRevisions: NodeDraftRevisionLedger(), accountID: accountID,
            nodeSendJournal: journal, requiresSendJournal: true
        )

        let result = try await service.perform(.send(draft))

        XCTAssertEqual(result.idempotencyKey, "retained-send")
        XCTAssertEqual(journal.settled, .applied)
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try NodeSyncCodec.decodeMutationRequest(requests[0].body).canonicalOperation, operation)
    }

    func testScopedSendWithoutJournalFailsBeforeNetworkDispatch() async throws {
        let mailbox = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "11111111-1111-4111-8111-111111111111", authorityEpoch: "2",
            clientID: "22222222-2222-4222-8222-222222222222", idempotencyKey: "unreserved-send",
            issuedAt: "2026-08-20T12:34:56Z", logicalMailboxID: mailbox,
            nodeID: "33333333-3333-4333-8333-333333333333",
            operation: .send(draftID: "journal-draft", expectedRevision: "1"), trustEpoch: "1"
        )
        let operation = try NodeSyncCodec.encodeOperation(try NodeSyncOperation(
            unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)
        ))
        let sender = SequencedMutationAuthorityTestSender(states: ["applied"])
        let service = NodeMutationService(client: NodeSyncClient(sender: sender),
                                          operationFactory: nil, draftRevisions: NodeDraftRevisionLedger(),
                                          requiresSendJournal: true)

        do {
            _ = try await service.apply(canonicalOperation: operation)
            XCTFail("A scoped send must fail without durable reservation")
        } catch let error as PlainpostError {
            guard case .permissionDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await sender.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testNonSendMutationChecksJournalSourceBeforeDispatch() async throws {
        let operation = try makeCanonicalSetReadOperation()
        let journal = JournalTestStore(operation: operation)
        let sender = SequencedMutationAuthorityTestSender(states: ["applied"])
        let service = NodeMutationService(
            client: NodeSyncClient(sender: sender), operationFactory: nil,
            draftRevisions: NodeDraftRevisionLedger(), nodeSendJournal: journal
        )
        journal.invalidateSource()
        XCTAssertThrowsError(try journal.requireCurrentSource())
        do {
            _ = try await service.apply(canonicalOperation: operation)
            XCTFail("A stale non-send mutation reached the Node")
        } catch let error as PlainpostError {
            guard case .permissionDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await sender.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testMutationCapabilityThrowsForTerminalFailureStatesWithoutRetrying() async throws {
        for state in ["conflicted", "rejected", "delivery_uncertain"] {
            let sender = SequencedMutationAuthorityTestSender(states: [state])
            let authority = PlainpostNodeMailAuthority(
                client: NodeSyncClient(sender: sender), accountID: AccountID("mutation-(state)")
            )
            do {
                _ = try await authority.mutations.apply(canonicalOperation: try makeCanonicalSetReadOperation())
                XCTFail("(state) must not be reported as a successful mutation")
            } catch let error as PlainpostError {
                guard case .validationFailed = error else {
                    return XCTFail("unexpected mapped error for (state): \(error)")
                }
            }
            let requests = await sender.requests()
            XCTAssertEqual(requests.count, 1, "(state) must not be retried")
        }
    }

    func testMutationCapabilitySettlesRetainedPendingBeforeSigningNewIntent() async throws {
        let sender = PerformReconciliationTestSender(states: ["pending", "applied"])
        let operation = try makeCanonicalSetReadOperation()
        let service = NodeMutationService(
            client: NodeSyncClient(sender: sender),
            operationFactory: { _, _ in operation },
            draftRevisions: NodeDraftRevisionLedger(),
            reconciliationPolicy: NodeMutationReconciliationPolicy(maximumPendingAttempts: 2, pendingRetryDelay: .milliseconds(1))
        )

        let result = try await service.perform(.setRead(messageIDs: [MessageID("message-1")], read: true))

        XCTAssertEqual(result.state, "applied")
        let reconciliationCalls = await sender.reconciliationCalls()
        let dispatchCalls = await sender.dispatchCalls()
        XCTAssertEqual(reconciliationCalls, 2)
        XCTAssertEqual(dispatchCalls, 1)
    }

    func testMutationCapabilityDoesNotSignAfterRetainedTerminalFailure() async throws {
        let sender = PerformReconciliationTestSender(states: ["conflicted"])
        let operation = try makeCanonicalSetReadOperation()
        let factoryCalls = MutationFactoryCallCounter()
        let service = NodeMutationService(
            client: NodeSyncClient(sender: sender),
            operationFactory: { _, _ in factoryCalls.increment(); return operation },
            draftRevisions: NodeDraftRevisionLedger()
        )

        do {
            _ = try await service.perform(.setRead(messageIDs: [MessageID("message-1")], read: true))
            XCTFail("retained terminal conflict must block new work")
        } catch let error as PlainpostError {
            guard case .validationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(factoryCalls.value, 0)
        let dispatchCalls = await sender.dispatchCalls()
        XCTAssertEqual(dispatchCalls, 0)
    }

    func testMutationCapabilityPerformRejectsEveryRetainedTerminalStateBeforeFactory() async throws {
        for state in ["conflicted", "rejected", "delivery_uncertain"] {
            let sender = PerformReconciliationTestSender(states: [state])
            let factoryCalls = MutationFactoryCallCounter()
            let operation = try makeCanonicalSetReadOperation()
            let service = NodeMutationService(
                client: NodeSyncClient(sender: sender),
                operationFactory: { _, _ in factoryCalls.increment(); return operation },
                draftRevisions: NodeDraftRevisionLedger()
            )

            do {
                _ = try await service.perform(.setRead(messageIDs: [MessageID("message-1")], read: true))
                XCTFail("retained \(state) must block new work")
            } catch let error as PlainpostError {
                guard case .validationFailed = error else { return XCTFail("unexpected \(state) error: \(error)") }
            }
            XCTAssertEqual(factoryCalls.value, 0, "\(state) must not sign new work")
            let dispatchCalls = await sender.dispatchCalls()
            XCTAssertEqual(dispatchCalls, 0, "\(state) must not dispatch new work")
        }
    }

    func testMutationCapabilityPropagatesCancellationWhilePending() async throws {
        let sender = SequencedMutationAuthorityTestSender(states: ["pending"])
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: sender), accountID: AccountID("mutation-cancel")
        )
        let canonicalOperation = try makeCanonicalSetReadOperation()
        let task = Task {
            try await authority.mutations.apply(canonicalOperation: canonicalOperation)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled pending reconciliation must not report success")
        } catch is CancellationError {
            // Expected: cancellation is never converted into a terminal mutation result.
        }
    }

    func testMutationCapabilityTimesOutPendingReconciliationWithinConfiguredBound() async throws {
        let sender = SequencedMutationAuthorityTestSender(states: ["pending"])
        let service = NodeMutationService(
            client: NodeSyncClient(sender: sender), operationFactory: nil,
            draftRevisions: NodeDraftRevisionLedger(),
            reconciliationPolicy: NodeMutationReconciliationPolicy(
                maximumPendingAttempts: 1, pendingRetryDelay: .milliseconds(1)
            )
        )

        do {
            _ = try await service.apply(canonicalOperation: try makeCanonicalSetReadOperation())
            XCTFail("pending reconciliation must fail at its configured bound")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .validationFailed("The Node mutation confirmation timed out."))
        }
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 2, "the bound permits one exact replay before timing out")
    }

    private func makeCanonicalSetReadOperation() throws -> Data {
        let mailbox = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "11111111-1111-4111-8111-111111111111", authorityEpoch: "2",
            clientID: "22222222-2222-4222-8222-222222222222", idempotencyKey: "mutation-reconcile",
            issuedAt: "2026-08-20T12:34:56Z", logicalMailboxID: mailbox,
            nodeID: "33333333-3333-4333-8333-333333333333",
            operation: .setRead(messageIDs: ["message-1"], read: true), trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(
            unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)
        ))
    }

    func testAttachmentCapabilityCanBeConsumedAndChecksDeclaredSize() async throws {
        let stream = PlainpostByteStream(capacity: 1)
        let producer = stream.producer
        Task {
            try? await producer.send(Data("hello".utf8))
            producer.finish()
        }
        let value = MailAttachmentStream(
            metadata: MailAttachment(
                id: "att-1", filename: "hello.txt", mimeType: "text/plain",
                disposition: "attachment", byteCount: 5, contentDigest: nil
            ), bytes: stream
        )

        let bytes = try await value.readAll()
        XCTAssertEqual(bytes, Data("hello".utf8))
    }

    func testAttachmentCapabilityChecksDeclaredDigestAfterFullConsumption() async throws {
        let bytes = Data("hello".utf8)
        let digest = Data(SHA256.hash(data: bytes)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let stream = PlainpostByteStream(capacity: 1)
        Task {
            try? await stream.producer.send(bytes)
            stream.producer.finish()
        }
        let value = MailAttachmentStream(
            metadata: MailAttachment(
                id: "att-1", filename: "hello.txt", mimeType: "text/plain",
                disposition: "attachment", byteCount: bytes.count, contentDigest: digest
            ), bytes: stream
        )

        let consumed = try await value.readAll()
        XCTAssertEqual(consumed, bytes)

        let badStream = PlainpostByteStream(capacity: 1)
        Task {
            try? await badStream.producer.send(bytes)
            badStream.producer.finish()
        }
        let badValue = MailAttachmentStream(
            metadata: MailAttachment(
                id: "att-1", filename: "hello.txt", mimeType: "text/plain",
                disposition: "attachment", byteCount: bytes.count, contentDigest: String(repeating: "A", count: 43)
            ), bytes: badStream
        )
        do {
            _ = try await badValue.readAll()
            XCTFail("expected digest mismatch")
        } catch {
            XCTAssertTrue(String(describing: error).contains("digest"))
        }
    }

    func testNodeAuthorityMapsACompleteMessageWithoutCreatingProviderCredentials() async throws {
        let message = NodeSyncMessage(
            attachments: [NodeSyncAttachment(
                contentDigest: nil,
                contentID: "cid-1",
                disposition: "attachment",
                filename: "invoice.pdf",
                id: "attachment-1",
                mime: "application/pdf",
                size: "12"
            )], bcc: [], cc: [], flags: ["seen"],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.com")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-1",
            inReplyTo: [], labels: ["inbox"], receivedAt: "2026-08-26T10:00:00Z", references: [],
            replyTo: [], sentAt: "2026-08-26T10:00:00Z", subject: "Hello",
            textBody: NodeSyncBody(state: .complete, value: "Body"), threadID: "thread-1",
            to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.com")]
        )
        let page = try NodeSyncMessageResult(message: message)
        let sender = AuthorityTestSender(response: NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeMessageResult(page)))
        let client = NodeSyncClient(sender: sender)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("account-1"))

        XCTAssertEqual(authority.accountID, AccountID("account-1"))
        let mapped = try await authority.messages.message(id: MessageID("message-1"))
        XCTAssertEqual(mapped.id, MessageID("message-1"))
        XCTAssertEqual(mapped.body, "Body")
        XCTAssertEqual(mapped.from, EmailAddress("sender@example.com"))
        XCTAssertEqual(mapped.labels, ["inbox"])
        XCTAssertEqual(mapped.attachments, [MailAttachment(
            id: "attachment-1",
            filename: "invoice.pdf",
            mimeType: "application/pdf",
            disposition: "attachment",
            byteCount: 12,
            contentDigest: nil
        )])
    }

    func testSearchUsesInjectedAccountAndCanonicalLogicalMailboxByteOrder() async throws {
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.com")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-1",
            inReplyTo: [], labels: [], receivedAt: "2026-08-26T10:00:00Z", references: [],
            replyTo: [], sentAt: "2026-08-26T10:00:00Z", subject: "Hello",
            textBody: NodeSyncBody(state: .complete, value: "Body"), threadID: "thread-1", to: []
        )
        let page = try NodeSyncSearchPage(messages: [message], nextCursor: "", revision: "1")
        let sender = SearchAuthorityTestSender(response: NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeSearchPage(page)))
        let authority = PlainpostNodeMailAuthority(client: NodeSyncClient(sender: sender), accountID: AccountID("account-1"))
        let highBytes = MailboxID(rawValue: rawBase64URL(Data(repeating: 0xff, count: 32)))
        let lowBytes = MailboxID(rawValue: rawBase64URL(Data(repeating: 0x80, count: 32)))
        let request = MailSearchRequest(query: "subject:test", scope: MailSearchSelectionScope(mailboxIDs: [highBytes, lowBytes]))

        let response = try await authority.search.search(request)
        let sentRequest = await sender.searchRequest()
        let sent = try XCTUnwrap(sentRequest)
        let decoded = try NodeSyncCodec.decodeSearchRequest(sent.body)
        XCTAssertEqual(decoded.logicalMailboxIDs.map(\.rawValue), [lowBytes.rawValue, highBytes.rawValue].compactMap { try? NodeSyncCodec.decodeLogicalMailboxID($0) }.map(\.rawValue))
        guard case let .conversation(hit) = try XCTUnwrap(response.hits.first) else { return XCTFail("expected conversation hit") }
        XCTAssertEqual(hit.accountID, AccountID("account-1"))
    }

    func testSearchProjectsCanonicalFlaggedLabel() async throws {
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.com")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-flagged",
            inReplyTo: [], labels: ["FLAGGED"], receivedAt: "2026-08-26T10:00:00Z", references: [],
            replyTo: [], sentAt: "2026-08-26T10:00:00Z", subject: "Flagged",
            textBody: NodeSyncBody(state: .complete, value: "Body"), threadID: "thread-flagged", to: []
        )
        let page = try NodeSyncSearchPage(messages: [message], nextCursor: "", revision: "1")
        let sender = SearchAuthorityTestSender(response: NodeHTTPResponse(
            statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:],
            body: try NodeSyncCodec.encodeSearchPage(page)
        ))
        let authority = PlainpostNodeMailAuthority(client: NodeSyncClient(sender: sender), accountID: AccountID("account-1"))
        let request = MailSearchRequest(query: "is:flagged", scope: MailSearchSelectionScope(mailboxIDs: []), mode: .messages)

        let response = try await authority.search.search(request)

        guard case let .message(hit) = try XCTUnwrap(response.hits.first) else { return XCTFail("expected message hit") }
        XCTAssertTrue(hit.isFlagged)
    }

    private func rawBase64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

actor AuthorityTestSender: NodeSessionRequestSending {
    let response: NodeHTTPResponse

    init(response: NodeHTTPResponse) { self.response = response }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        response
    }
}

private actor ProviderSyncWakeTestSender: NodeSessionRequestSending {
    private var captured: [NodeHTTPRequest] = []

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        captured.append(NodeHTTPRequest(
            endpoint: try NodeEndpointURL("https://node.example.ts.net:443"),
            method: method,
            path: path,
            body: body
        ))
        return NodeHTTPResponse(
            statusCode: 204,
            url: URL(string: "https://node.example.ts.net:443")!,
            headers: [:],
            body: Data()
        )
    }

    func requests() -> [NodeHTTPRequest] { captured }
}

private actor ProviderAuthorityTestSender: NodeSessionRequestSending {
    private let configuredIdentity: String
    private var statuses = 0
    private var assignments = 0

    init(configuredIdentity: String) { self.configuredIdentity = configuredIdentity }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let endpoint = URL(string: "https://node.example.ts.net:443")!
        switch path {
        case "/v1/providers/google":
            let result = try NodeSyncGoogleProvisionResult(discoveredMailboxes: [], providerIdentity: configuredIdentity)
            return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeGoogleProvisionResult(result))
        case "/v1/status":
            statuses += 1
            let result = try NodeSyncStatusResult(
                revision: "1", state: "ready", version: "node-sync-v1", reachability: "reachable",
                syncLag: "0", storage: "managed", providerIdentity: configuredIdentity, assignments: [],
                backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
            )
            return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeStatusResult(result))
        case "/v1/mailboxes/assignments":
            assignments += 1
            throw NodeSyncClientError.invalidResponse
        default:
            throw NodeSyncClientError.invalidResponse
        }
    }

    func statusCount() -> Int { statuses }
    func assignmentCount() -> Int { assignments }
}

private actor AuthorityStatusDriftTestSender: NodeSessionRequestSending {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        guard path == "/v1/status" else { throw NodeSyncClientError.invalidResponse }
        let result = try NodeSyncStatusResult(
            revision: "1", state: "ready", version: "node-sync-v1", reachability: "reachable",
            syncLag: "0", storage: "managed", providerIdentity: "provider-b@example.com", assignments: [],
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
        return NodeHTTPResponse(
            statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:],
            body: try NodeSyncCodec.encodeStatusResult(result)
        )
    }
}

private final class StatusPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var published = false

    func markPublished() { lock.withLock { published = true } }
    func wasPublished() -> Bool { lock.withLock { published } }
}

actor SearchAuthorityTestSender: NodeSessionRequestSending {
    let response: NodeHTTPResponse
    private var request: NodeHTTPRequest?

    init(response: NodeHTTPResponse) { self.response = response }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        request = NodeHTTPRequest(endpoint: try NodeEndpointURL("https://node.example.ts.net:443"), method: method, path: path, body: body)
        return response
    }

    func searchRequest() -> NodeHTTPRequest? { request }
}

actor MutationAuthorityTestSender: NodeSessionRequestSending {
    let response: NodeHTTPResponse
    private var lastRequest: NodeHTTPRequest?

    init(response: NodeHTTPResponse) { self.response = response }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        lastRequest = NodeHTTPRequest(
            endpoint: try NodeEndpointURL("https://node.example.ts.net:443"),
            method: method,
            path: path,
            body: body
        )
        return response
    }

    func request() -> NodeHTTPRequest? { lastRequest }
}

actor DraftCASAuthorityTestSender: NodeSessionRequestSending, NodeMutationOperationSigning {
    private let accountID: String
    private let logicalMailboxID: LogicalMailboxID
    private var recordedVariants: [NodeSyncOperationVariant] = []
    private var recordedOperations: [Data] = []
    private var draftRevisions: [String: UInt64] = [:]

    init(accountID: String, logicalMailboxID: LogicalMailboxID, initialDraftRevision: UInt64 = 0) {
        self.accountID = accountID
        self.logicalMailboxID = logicalMailboxID
        self.draftRevisions["existing-draft"] = initialDraftRevision
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let endpoint = URL(string: "https://node.example.ts.net:443")!
        switch (path) {
        case "/v1/mailboxes/assignments":
            let assignment = try NodeSyncDiscoveredMailbox(
                displayName: "Drafts", logicalMailboxID: logicalMailboxID,
                mailboxHandle: "drafts", role: "drafts"
            )
            let result = try NodeSyncMailboxAssignmentsResult(assignments: [assignment])
            return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeMailboxAssignmentsResult(result))
        case "/v1/status":
            let result = try NodeSyncStatusResult(revision: "99", state: "ready", providerIdentity: "acceptance@example.test")
            return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeStatusResult(result))
        case let path where path.hasPrefix("/v1/drafts/"):
            let draftID = String(path.dropFirst("/v1/drafts/".count))
            let revision = draftRevisions[draftID] ?? 0
            let result = try NodeSyncDraftState(draftID: draftID, revision: String(revision), state: revision == 0 ? "local" : "appended")
            return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeDraftState(result))
        case "/v1/mutations":
            let request = try NodeSyncCodec.decodeMutationRequest(body)
            let operation = try NodeSyncCodec.decodeOperation(request.canonicalOperation)
            recordedVariants.append(operation.unsigned.operation)
            recordedOperations.append(request.canonicalOperation)
            if case let .saveDraft(draftID, expectedRevision, _, _) = operation.unsigned.operation,
               let expected = UInt64(expectedRevision) {
                draftRevisions[draftID] = expected + 2
            }
            let result = try NodeSyncMutationResult(idempotencyKey: operation.unsigned.idempotencyKey, state: "applied")
            return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeMutationResult(result))
        default:
            throw NodeSyncClientError.invalidResponse
        }
    }

    nonisolated func signMutation(
        variant: NodeSyncOperationVariant,
        logicalMailboxID: LogicalMailboxID,
        idempotencyKey: String,
        issuedAt: String
    ) throws -> Data {
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: accountID, authorityEpoch: "1", clientID: "11111111-2222-3333-8444-555555555555",
            idempotencyKey: idempotencyKey, issuedAt: issuedAt, logicalMailboxID: logicalMailboxID,
            nodeID: "aaaaaaaa-bbbb-cccc-8ddd-eeeeeeeeeeee", operation: variant, trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)))
    }

    func variants() -> [NodeSyncOperationVariant] {
        return recordedVariants
    }

    func operations() -> [Data] {
        recordedOperations
    }
}

private actor SequencedMutationAuthorityTestSender: NodeSessionRequestSending {
    private let endpoint = URL(string: "https://node.example.ts.net:443")!
    private let states: [String]
    private var index = 0
    private var captured: [NodeHTTPRequest] = []

    init(states: [String]) { self.states = states }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        captured.append(NodeHTTPRequest(
            endpoint: try NodeEndpointURL(endpoint.absoluteString), method: method, path: path, body: body
        ))
        let request = try NodeSyncCodec.decodeMutationRequest(body)
        let operation = try NodeSyncCodec.decodeOperation(request.canonicalOperation)
        let state = states[min(index, states.count - 1)]
        index += 1
        let result = try NodeSyncMutationResult(idempotencyKey: operation.unsigned.idempotencyKey, state: state)
        return NodeHTTPResponse(
            statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeMutationResult(result)
        )
    }

    func requests() -> [NodeHTTPRequest] { captured }
}

private actor MismatchedMutationResultSender: NodeSessionRequestSending {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let result = try NodeSyncMutationResult(idempotencyKey: "another-operation", state: "applied")
        return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!,
                                headers: [:], body: try NodeSyncCodec.encodeMutationResult(result))
    }
}

private final class JournalTestStore: NodeSendJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var unresolved: [Data]
    private var lastSettlement: NodeSendOutcome?
    private var sourceIsCurrent = true

    init(operation: Data) { unresolved = [operation] }

    var settled: NodeSendOutcome? {
        lock.lock(); defer { lock.unlock() }
        return lastSettlement
    }

    func invalidateSource() { lock.withLock { sourceIsCurrent = false } }

    func requireCurrentSource() throws {
        guard lock.withLock({ sourceIsCurrent }) else {
            throw PlainpostError.permissionDenied("Selected Node source changed.")
        }
    }

    func unresolvedSendOperations(accountID: AccountID) throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return unresolved
    }

    func reserveSend(canonicalOperation: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard unresolved.contains(canonicalOperation) else {
            throw PlainpostError.validationFailed("Unexpected send operation")
        }
    }

    func settleSend(canonicalOperation: Data, state: NodeSendOutcome) throws {
        lock.lock(); defer { lock.unlock() }
        lastSettlement = state
        if case .applied = state { unresolved.removeAll { $0 == canonicalOperation } }
    }
}

private actor PerformReconciliationTestSender: NodeSessionRequestSending, NodePendingRequestReconciling {
    private let endpoint = URL(string: "https://node.example.ts.net:443")!
    private let states: [String]
    private var reconciliationIndex = 0
    private var reconciliationCount = 0
    private var dispatchCount = 0

    init(states: [String]) { self.states = states }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        guard reconciliationIndex < states.count else { return nil }
        var state = states[reconciliationIndex]
        while state == "pending" && reconciliationIndex + 1 < states.count {
            reconciliationIndex += 1
            reconciliationCount += 1
            state = states[reconciliationIndex]
        }
        reconciliationIndex += 1
        reconciliationCount += 1
        let result = try NodeSyncMutationResult(idempotencyKey: "retained", state: state)
        return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeMutationResult(result))
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        dispatchCount += 1
        let operation = try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest(body).canonicalOperation)
        let result = try NodeSyncMutationResult(idempotencyKey: operation.unsigned.idempotencyKey, state: "applied")
        return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: try NodeSyncCodec.encodeMutationResult(result))
    }

    func reconciliationCalls() -> Int { reconciliationCount }
    func dispatchCalls() -> Int { dispatchCount }
}

private final class MutationFactoryCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
