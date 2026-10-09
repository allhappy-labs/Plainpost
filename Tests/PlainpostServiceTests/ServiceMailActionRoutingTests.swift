import Foundation
import GRDB
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNodeMailMode
@testable import PlainpostNodeTransport
@testable import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
import PlainpostTestSupport
@testable import PlainpostService

final class ServiceMailActionRoutingTests: XCTestCase {
    func testServiceArchiveForNodeAccountUsesRouterAndDirectAccountUsesIMAP() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.direct("acc-direct"), .node("acc-node")])
        defer { harness.cleanUp() }
        _ = try await harness.operations.perform(.archive(harness.archivePayload(account: "acc-direct")))
        let nodeResult = try await harness.operations.perform(.archive(harness.archivePayload(account: "acc-node")))
        XCTAssertEqual(harness.imapArchiveCount(account: "acc-direct"), 1)
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
        let mutationCount = await harness.nodeSender.mutationCount
        XCTAssertEqual(mutationCount, 1)
        guard case let .archive(mailAction) = nodeResult else { return XCTFail("expected an archive result") }
        XCTAssertEqual(mailAction.waitingForNode, false)
        XCTAssertEqual(mailAction.mailboxPath, "Archive")
        XCTAssertEqual(try harness.store.messageSummary(id: harness.messageID(account: "acc-node"))?.mailboxPath, "Archive")
    }

    func testDirectAccountNeverTouchesTheJournalOrTheNode() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.direct("acc-direct")])
        defer { harness.cleanUp() }
        _ = try await harness.operations.perform(.archive(harness.archivePayload(account: "acc-direct")))
        XCTAssertEqual(try harness.journal(account: "acc-direct"), [])
        let posts = await harness.nodeSender.mutationPostCount
        XCTAssertEqual(posts, 0)
    }

    func testLabelsStayLocalOnlyAndAreNeverJournaled() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        try harness.store.saveMailLabel(try MailLabelDefinition.validated(
            id: "routing-label", title: "Routing", description: "", isSmartInboxEnabled: false, scope: .allAccounts))
        let payload = PlainpostLabelMutationPayload(labelID: "routing-label", messageID: harness.messageID(account: "acc-node").rawValue, selected: true)
        _ = try await harness.operations.perform(.addLabel(payload))
        _ = try await harness.operations.perform(.removeLabel(payload))
        XCTAssertEqual(try harness.journal(account: "acc-node"), [])
        let posts = await harness.nodeSender.mutationPostCount
        XCTAssertEqual(posts, 0)
    }

    func testNodeMarkReadIsSeenLocallyWithoutADirectFlagJob() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let result = try await harness.operations.perform(.markRead(
            PlainpostMailActionPayload(messageID: harness.messageID(account: "acc-node").rawValue)))
        guard case let .markRead(mailAction) = result else { return XCTFail("expected a mark-read result") }
        XCTAssertEqual(mailAction.seen, true)
        XCTAssertFalse(mailAction.waitingForNode)
        XCTAssertEqual(try harness.store.jobs(limit: 50).filter { $0.kind == .mailboxFlag }.count, 0)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["set_read"])
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testNodeFlagAndMoveGoToTheNodeAndTheMoveShowsInItsFolder() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let messageID = harness.messageID(account: "acc-node").rawValue
        let flag = try await harness.operations.perform(.flag(PlainpostMailActionPayload(messageID: messageID)))
        guard case .flag = flag else { return XCTFail("expected a flag result") }
        let move = try await harness.operations.perform(.move(PlainpostMailActionPayload(messageID: messageID, archiveMailbox: "Receipts")))
        guard case let .move(moved) = move else { return XCTFail("expected a move result") }
        XCTAssertEqual(moved.mailboxPath, "Receipts")
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["set_flagged", "move"])
        XCTAssertEqual(try harness.store.messageSummary(id: MessageID(messageID))?.mailboxPath, "Receipts")
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testAFallbackFlagWaitsForTheNodeInsteadOfFailing() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-node")])
        defer { harness.cleanUp() }
        let messageID = harness.messageID(account: "acc-node").rawValue
        let result = try await harness.operations.perform(.flag(PlainpostMailActionPayload(messageID: messageID)))
        guard case let .flag(flagged) = result else { return XCTFail("expected a flag result") }
        XCTAssertTrue(flagged.waitingForNode)
        XCTAssertEqual(try harness.journal(account: "acc-node").map(\.state), [.pending])
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testFallbackNodeAccountArchivesDirectlyUnderTheJournal() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-node")])
        defer { harness.cleanUp() }
        _ = try await harness.operations.perform(.archive(harness.archivePayload(account: "acc-node")))
        XCTAssertEqual(harness.imapArchiveCount(account: "acc-node"), 1)
        let journal = try harness.journal(account: "acc-node")
        XCTAssertEqual(journal.map(\.state), [.confirmed])
        XCTAssertEqual(journal.map(\.route), [.direct])
        let posts = await harness.nodeSender.mutationPostCount
        XCTAssertEqual(posts, 0)
    }

    func testAFallbackDeleteRepliesWithTheTrashMoveAndPassesTheXPCCheck() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-node")])
        defer { harness.cleanUp() }
        try harness.store.cacheMailboxes([Mailbox(
            id: MailboxID("acc-node-trash"), accountID: AccountID("acc-node"), name: "Trash", path: "Trash", specialUse: "\\Trash"
        )])
        let operation = PlainpostForegroundOperation.delete(harness.archivePayload(account: "acc-node"))

        let reply = try await harness.operations.perform(operation)

        guard case .delete(let result) = reply else { return XCTFail("expected a delete result") }
        XCTAssertEqual(result.deleteOutcome, .movedToTrash)
        XCTAssertEqual(result.mailboxPath, "Trash")
        XCTAssertFalse(result.isDeleted)
        XCTAssertTrue(reply.isSemanticallyCorrelated(with: operation), "the listener and client accept it")
        let held = await harness.operations.heldDirectDeleteOutcomeCount
        XCTAssertEqual(held, 0, "the reply consumed its outcome")
        let server = try XCTUnwrap(harness.imapServer(account: "acc-node"))
        XCTAssertEqual(server.copyAttempts, [LocalIMAPCopyAttempt(uid: 42, mailbox: "Trash")])
        XCTAssertEqual(try harness.journal(account: "acc-node").map(\.route), [.direct])
    }

    func testANodeAccountWithoutTheJournalCannotRouteAndNeverFallsBackDirect() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let operations = try await harness.operationsOverStoreWithoutJournal()
        await XCTAssertThrowsErrorAsync(try await operations.perform(.archive(harness.archivePayload(account: "acc-node")))) {
            XCTAssertEqual($0 as? PlainpostServiceClientError, .nodeSession(.unavailable))
        }
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
        let posts = await harness.nodeSender.mutationPostCount
        XCTAssertEqual(posts, 0)
    }

    func testALeaseOnlySessionRefusesServiceMutationsWithATypedError() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")], readOnlySession: true)
        defer { harness.cleanUp() }
        let messageID = harness.messageID(account: "acc-node")
        await XCTAssertThrowsErrorAsync(try await harness.operations.perform(.markRead(
            PlainpostMailActionPayload(messageID: messageID.rawValue)))) {
            XCTAssertEqual($0 as? PlainpostServiceClientError, .nodeSession(.readOnly))
        }
        XCTAssertEqual(try harness.journal(account: "acc-node").map(\.state), [.failed])
        XCTAssertEqual(try harness.store.messageSummary(id: messageID)?.isSeen, false, "the optimistic seen change is reverted")
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testANodeSendUsesSaveThenSendAndNeverSMTP() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let draft = try harness.createDraft(account: "acc-node")
        let result = try await harness.operations.perform(.deliverDirectDraft(
            PlainpostDirectDraftDeliveryPayload(draftID: draft.id.rawValue, expectedHash: draft.contentHash, actorID: "local-user")))
        guard case let .deliverDirectDraft(delivery) = result else { return XCTFail("expected a delivery result") }
        XCTAssertTrue(delivery.remoteSentCopyAppended)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["save_draft", "send"])
        let journal = try harness.journal(account: "acc-node")
        XCTAssertEqual(journal.map(\.kind), [.send])
        XCTAssertEqual(journal.map(\.state), [.confirmed])
        let keys = await harness.nodeSender.idempotencyKeys
        XCTAssertEqual(keys.last, journal.first?.operationID, "the send's idempotency key is the operation ID")
    }

    func testANodeDraftSaveUsesTheRouterNotIMAP() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let draft = try harness.createDraft(account: "acc-node")
        let synced = try await harness.operations.syncDraftToServer(draftID: draft.id.rawValue, mailbox: "Drafts")
        XCTAssertNil(synced.serverDraftUID)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["save_draft"])
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testAQueuedFlagJobOfANodeModeAccountBecomesOneNodeIntent() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let messageID = harness.messageID(account: "acc-node")
        // As the app's message opening (or a job queued before the flip) does.
        _ = try harness.store.markSeen(messageID, seen: true, actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
        let job = try XCTUnwrap(harness.store.jobs(limit: 50).first { $0.kind == .mailboxFlag })

        _ = try await harness.operations.processBackgroundJobs()

        XCTAssertEqual(try harness.store.job(id: job.id).state, .completed)
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["set_read"])
        // A retried job is the same intent and the same Node operation.
        _ = try await harness.operations.handOffNodeModeMailboxWork(.flag(jobID: job.id, messageID: messageID, seen: true))
        XCTAssertEqual(try harness.journal(account: "acc-node").count, 1)
        let count = await harness.nodeSender.mutationCount
        XCTAssertEqual(count, 1)
    }

    func testAQueuedArchiveJobOfANodeModeAccountIsHandedToTheRouter() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let input = PlainpostMailboxArchiveInput(
            messageID: harness.messageID(account: "acc-node"), accountID: AccountID("acc-node"),
            sourceMailboxPath: "INBOX", destinationMailboxPath: "Archive", uidValidity: 7, uid: 42)
        let job = try harness.store.enqueueMailboxArchive(input)

        _ = try await harness.operations.processBackgroundJobs()

        XCTAssertEqual(try harness.store.job(id: job.id).state, .completed)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["archive"])
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testReaddingANodeModeAccountRunsNoDirectInitialSync() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let setup = AccountSetupService(store: harness.store, credentials: harness.assembly.vault)
        let account = try XCTUnwrap(harness.store.accounts.first { $0.id == AccountID("acc-node") })

        let result = try await setup.syncInbox(for: account)

        XCTAssertEqual(result.syncedMessageCount, 0)
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testOnlyPreEffectDirectFailuresAreRefusals() {
        let refused: [any Error] = [
            PlainpostError.validationFailed("IMAP credentials are not available."),
            CredentialVaultError.locked,
            MailCredentialError.unavailable,
            DraftOptimisticUpdateError.conflict,
            SMTPClientError.authenticationFailed,
            SMTPClientError.recipientRejected(EmailAddress("x@example.test"), code: 550, message: "no"),
            IMAPClientError.authenticationFailed,
            IMAPClientError.throttled,
            SMTPClientError.refusedBeforeData("553 5.1.3 bad recipient"),
            SMTPClientError.unreachableBeforeData,
            MailAuthenticationError.rejected,
            MailAuthenticationError.mechanismUnavailable,
            GoogleOAuthError.invalidGrant,
            GoogleOAuthError.unavailable,
        ]
        for error in refused {
            XCTAssertNotNil(ServiceDirectMailDispatcher.refusal(for: error), "\(error) happens before any provider effect")
        }
        let ambiguous: [any Error] = [
            SMTPClientError.deliveryUncertain,
            SMTPClientError.connectionFailed,
            SMTPClientError.unexpectedResponse("451"),
            PostSMTPPersistenceError.localPersistenceFailed,
            IMAPClientError.connectionFailed,
            IMAPClientError.timedOut,
            IMAPClientError.protocolError("lost"),
            CancellationError(),
            URLError(.networkConnectionLost),
        ]
        for error in ambiguous {
            XCTAssertNil(ServiceDirectMailDispatcher.refusal(for: error), "\(error) may have reached the provider")
        }
    }

    func testAnUnreachableMailServerLeavesAFallbackSendPendingNotFailed() async throws {
        // The harness's SMTP port (1) refuses every connection.
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-fb")])
        defer { harness.cleanUp() }
        let draft = try harness.createDraft(account: "acc-fb")

        let result = try await harness.operations.perform(.deliverDirectDraft(
            PlainpostDirectDraftDeliveryPayload(draftID: draft.id.rawValue, expectedHash: draft.contentHash, actorID: "local-user")))

        guard case let .deliverDirectDraft(delivery) = result else { return XCTFail("expected a delivery result") }
        XCTAssertTrue(delivery.waitingForNode, "a network failure before DATA is a wait, not a failure")
        let journal = try harness.journal(account: "acc-fb")
        XCTAssertEqual(journal.map(\.state), [.pending])
        XCTAssertEqual(journal.map(\.route), [nil])
    }

    func testTransientPreEffectDirectFailuresAreDeferralsNotRefusals() {
        let transient: [(any Error, String, Bool)] = [
            (SMTPClientError.unreachableBeforeData, "Plainpost couldn't reach your mail server.", true),
            (MailAuthenticationError.temporarilyRefused, "Your mail server refused sign-in for now.", true),
            (GoogleOAuthError.unavailable, "Plainpost couldn't reach Google to sign in.", true),
            (CredentialVaultError.locked, "Plainpost is locked.", false),
        ]
        for (error, reason, retried) in transient {
            XCTAssertEqual(ServiceDirectMailDispatcher.deferral(for: error)?.reason, reason, "\(error)")
            XCTAssertEqual(ServiceDirectMailDispatcher.deferral(for: error)?.transient, retried, "\(error)")
            XCTAssertFalse(SMTPDeliveryAmbiguity.isAmbiguous(error))
        }
        let definite: [any Error] = [
            SMTPClientError.refusedBeforeData("553 5.1.3 bad recipient"),
            MailAuthenticationError.rejected,
            MailAuthenticationError.mechanismUnavailable,
            GoogleOAuthError.invalidGrant,
        ]
        for error in definite {
            XCTAssertNil(ServiceDirectMailDispatcher.deferral(for: error), "\(error) is a refusal, not a wait")
            XCTAssertNotNil(ServiceDirectMailDispatcher.refusal(for: error))
        }
        XCTAssertEqual(ServiceDirectMailDispatcher.refusal(for: SMTPClientError.refusedBeforeData("553"))?.message,
                       "Your mail provider refused this message.")
        XCTAssertEqual(ServiceDirectMailDispatcher.refusal(for: SMTPClientError.tlsFailed)?.message,
                       "Plainpost couldn't establish a secure connection to your mail server. Nothing was sent.")
        XCTAssertEqual(ServiceDirectMailDispatcher.refusal(for: SMTPClientError.authenticationFailed)?.message,
                       "Your mail server didn't accept the sign-in. Nothing was sent.")
    }

    func testAQueuedNodeSendIsReportedWaitingAndItsDraftIsLocked() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let draft = try harness.createDraft(account: "acc-node")
        harness.sessions.setReachable(false)
        let payload = PlainpostDirectDraftDeliveryPayload(draftID: draft.id.rawValue, expectedHash: draft.contentHash, actorID: "local-user")

        let result = try await harness.operations.perform(.deliverDirectDraft(payload))
        guard case let .deliverDirectDraft(delivery) = result else { return XCTFail("expected a delivery result") }
        XCTAssertTrue(delivery.waitingForNode, "a queued send is never reported as sent")
        XCTAssertFalse(delivery.remoteSentCopyAppended)
        XCTAssertNil(try harness.store.messageSummary(id: MessageID(IMAPSyncService.canonicalMessageID(
            accountID: AccountID("acc-node"), rfcMessageID: "<\(draft.id.rawValue)@plainpost.local>"))), "no local Sent record yet")
        // A resend from Drafts while it waits is refused: one send only.
        await XCTAssertThrowsErrorAsync(try await harness.operations.perform(.deliverDirectDraft(payload))) {
            XCTAssertEqual($0 as? PlainpostError, .validationFailed(PlainpostServiceOperations.sendInProgressMessage))
        }
        harness.sessions.setReachable(true)
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["save_draft", "send"])
    }

    func testABusyStoreDuringASendNeverSurfacesAFailureThatInvitesAResend() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let draft = try harness.createDraft(account: "acc-node")
        await harness.router.setBeginFailpoint { _ in throw ServiceRoutingBusyStore() }
        let payload = PlainpostDirectDraftDeliveryPayload(draftID: draft.id.rawValue, expectedHash: draft.contentHash, actorID: "local-user")

        let result = try await harness.operations.perform(.deliverDirectDraft(payload))
        guard case let .deliverDirectDraft(delivery) = result else { return XCTFail("expected a delivery result") }
        XCTAssertTrue(delivery.waitingForNode)
        await XCTAssertThrowsErrorAsync(try await harness.operations.perform(.deliverDirectDraft(payload)))
        await harness.router.setBeginFailpoint(nil)
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))

        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["save_draft", "send"], "sent exactly once")
        XCTAssertEqual(try harness.journal(account: "acc-node").map(\.state), [.confirmed])
    }

    func testARuleArchiveQueuedWhileTheNodeIsAwayArchivesToItsDestinationInFallback() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let messageID = harness.messageID(account: "acc-node")
        harness.sessions.setReachable(false)
        let input = PlainpostMailboxArchiveInput(
            messageID: messageID, accountID: AccountID("acc-node"),
            sourceMailboxPath: "INBOX", destinationMailboxPath: "Processed/Rules", uidValidity: 7, uid: 42)
        let job = try harness.store.enqueueMailboxArchive(input)

        _ = try await harness.operations.processBackgroundJobs()

        XCTAssertEqual(try harness.store.job(id: job.id).state, .completed)
        XCTAssertEqual(try harness.store.messageSummary(id: messageID)?.mailboxPath, "INBOX", "not archived locally while pending")
        XCTAssertEqual(try harness.journal(account: "acc-node").map(\.state), [.pending])
        try harness.setMode(.fallback, account: "acc-node")
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))

        XCTAssertEqual(harness.imapServer(account: "acc-node")?.copyAttempts, [LocalIMAPCopyAttempt(uid: 42, mailbox: "Processed/Rules")])
        XCTAssertEqual(try harness.store.messageSummary(id: messageID)?.mailboxPath, "Processed/Rules")
        XCTAssertEqual(try harness.journal(account: "acc-node").map(\.state), [.confirmed])
    }

    func testAFallbackMarkReadIsConfirmedOnlyAfterTheProviderWrite() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-node")])
        defer { harness.cleanUp() }
        _ = try await harness.operations.perform(.markRead(
            PlainpostMailActionPayload(messageID: harness.messageID(account: "acc-node").rawValue)))

        XCTAssertFalse(harness.imapServer(account: "acc-node")?.storeCommands.isEmpty ?? true, "the flag reached the provider")
        XCTAssertEqual(try harness.store.jobs(limit: 50).filter { $0.kind == .mailboxFlag }.count, 0, "no deferred job stands in for it")
        let journal = try harness.journal(account: "acc-node")
        XCTAssertEqual(journal.map(\.state), [.confirmed])
        XCTAssertEqual(journal.map(\.route), [.direct])
    }

    // MARK: - Approved sends (Task 17 fix round 1)

    func testAnApprovedSendOfANodeAccountIsQueuedThenSentThroughTheNodeAndTheRequestFollows() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (_, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        harness.sessions.setReachable(false)

        try await harness.approve(request)

        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sending, "queued: not sent, not failed")
        let queued = try harness.journal(account: "acc-node")
        XCTAssertEqual(queued.map(\.kind), [.send])
        XCTAssertEqual(queued.map(\.state), [.pending])
        XCTAssertEqual(queued.first?.operationID, try harness.store.sendRequest(id: request).deliveryOperationID,
                       "the approval records the intent it was claimed for")
        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router)
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sending)

        harness.sessions.setReachable(true)
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))
        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router)

        XCTAssertEqual(try harness.journal(account: "acc-node").map(\.state), [.confirmed])
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sent)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["save_draft", "send"])
    }

    func testAnApprovedSendRejectedByTheNodeLaterFailsItsRequest() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (_, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        await harness.nodeSender.answerNewMutations(with: "rejected")

        try await harness.approve(request)

        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .failed)
    }

    func testAnApprovedSendInFallbackIsDeliveredDirectlyOnce() async throws {
        let smtp = LocalSMTPServer(username: "acc-fb@example.test", password: "pw-acc-fb")
        try await smtp.start()
        defer { smtp.stop() }
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-fb")], smtpPort: Int(smtp.port))
        defer { harness.cleanUp() }
        let (_, requestID) = try harness.createApprovalDraft(account: "acc-fb")
        let request = try XCTUnwrap(requestID)

        try await harness.approve(request)

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sent)
        let journal = try harness.journal(account: "acc-fb")
        XCTAssertEqual(journal.map(\.state), [.confirmed])
        XCTAssertEqual(journal.map(\.route), [.direct])
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, [])
    }

    func testAConfirmedFallbackSendSettlesAfterItsDraftWasRemoved() async throws {
        let smtp = LocalSMTPServer(username: "acc-fb@example.test", password: "pw-acc-fb")
        try await smtp.start()
        defer { smtp.stop() }
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-fb")], smtpPort: Int(smtp.port))
        defer { harness.cleanUp() }
        let (draft, requestID) = try harness.createApprovalDraft(account: "acc-fb")
        let request = try XCTUnwrap(requestID)
        let operationID = UUID().uuidString.lowercased()
        _ = try harness.store.claimSendRequestForDelivery(
            id: request, currentDraftHash: draft.contentHash, actor: PlainpostFixtures.guiUser,
            deliveryOperationID: operationID)

        let dispatch = try await harness.router.sendIntent(
            draft, approvedContentHash: draft.contentHash, operationID: operationID)
        XCTAssertEqual(dispatch.state, .confirmed)
        XCTAssertNil(try? harness.store.draft(id: draft.id), "a sent draft is removed before request reconciliation")
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sending)

        await ServiceApprovedSendRouting.reconcileRequest(id: request, store: harness.store, router: harness.router)

        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sent)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testALeaseRecoveredApprovedDeliveryWithAJournaledIntentIsSentOnceAndNeverDirectly() async throws {
        let smtp = LocalSMTPServer(username: "acc-node@example.test", password: "pw-acc-node")
        try await smtp.start()
        defer { smtp.stop() }
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")], smtpPort: Int(smtp.port))
        defer { harness.cleanUp() }
        let (draft, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        harness.sessions.setReachable(false)
        // A delivery job that journaled its intent, then lost its lease (the
        // service died): the request is `sending`, the intent `pending`.
        let job = try harness.store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery,
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostApprovalDecisionInput(requestID: request, actorID: "local-user")), as: UTF8.self),
            priority: 100, maxAttempts: 3, idempotencyKey: "approved-delivery:\(request.rawValue)"))
        _ = try XCTUnwrap(try harness.store.claimNextJob(allowedKinds: [.approvedDelivery]))
        let operationID = UUID().uuidString.lowercased()
        _ = try harness.store.claimSendRequestForDelivery(id: request, currentDraftHash: draft.contentHash, actor: PlainpostFixtures.guiUser,
                                                          deliveryOperationID: operationID)
        _ = try await harness.router.sendIntent(draft, approvedContentHash: draft.contentHash, operationID: operationID)
        _ = try harness.store.recoverBackgroundAgentJobs(allowedKinds: [.approvedDelivery], now: Date().addingTimeInterval(3_600))
        XCTAssertEqual(try harness.store.job(id: job.id).state, .deliveryUncertain)
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .deliveryUncertain, "recovery acts on missing information")

        // A second delivery job for the same request (a retry) reuses the intent.
        _ = try harness.store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery,
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostApprovalDecisionInput(requestID: request, actorID: "local-user")), as: UTF8.self),
            priority: 100, maxAttempts: 3, idempotencyKey: "approved-delivery-retry:\(request.rawValue)"))
        _ = try await harness.operations.processBackgroundJobs()
        harness.sessions.setReachable(true)
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))
        await harness.router.settleAdmittedIntents(accountID: AccountID("acc-node"))

        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router)

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 0, "never also sent over direct SMTP")
        XCTAssertEqual(try harness.journal(account: "acc-node").count, 1, "one approval, one intent")
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sent, "the journal's confirmation is authoritative")
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds.filter { $0 == "send" }.count, 1)
    }

    func testABrowserReplyOfANodeAccountReportsWaitingForNodeAndIsSentOnce() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (draft, _) = try harness.createApprovalDraft(account: "acc-node", browser: true)
        harness.sessions.setReachable(false)
        await harness.operations.setBrowserReplySettleTiming(timeout: .milliseconds(200), poll: .milliseconds(20))

        let result = try await harness.operations.perform(.deliverBrowserReply(PlainpostBrowserReplyDeliveryPayload(
            draftID: draft.id.rawValue, expectedHash: draft.contentHash, idempotencyKey: "browser-reply-1")))

        guard case let .deliverBrowserReply(reply) = result else { return XCTFail("expected a browser reply result") }
        XCTAssertEqual(reply.state, "waitingForNode")
        harness.sessions.setReachable(true)
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))
        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router)
        XCTAssertEqual(try harness.store.sendRequest(id: SendRequestID(reply.requestID)).status, .sent)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, ["save_draft", "send"])
    }

    // MARK: - Approved sends (Task 17 fix round 2)

    func testABrowserReplyThatSettlesWithinTheWaitReportsSent() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (draft, _) = try harness.createApprovalDraft(account: "acc-node", browser: true)
        harness.sessions.setReachable(false)
        await harness.operations.setBrowserReplySettleTiming(timeout: .seconds(10), poll: .milliseconds(20))
        let operations = harness.operations
        let reply = Task {
            try await operations.perform(.deliverBrowserReply(PlainpostBrowserReplyDeliveryPayload(
                draftID: draft.id.rawValue, expectedHash: draft.contentHash, idempotencyKey: "browser-reply-2")))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while try harness.journal(account: "acc-node").isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.sessions.setReachable(true)
        await harness.router.dispatchPending(accountID: AccountID("acc-node"))

        guard case let .deliverBrowserReply(result) = try await reply.value else { return XCTFail("expected a browser reply") }
        XCTAssertEqual(result.state, "sent", "held for the outcome instead of answering uncertain")
    }

    func testAReApprovedSendAfterAFailureGetsItsOwnIntentAndIsSentOnce() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (draft, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        await harness.nodeSender.answerNewMutations(with: "rejected")
        try await harness.approve(request)
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .failed)
        let failed = try XCTUnwrap(try harness.journal(account: "acc-node").first)
        XCTAssertEqual(failed.state, .failed)

        // The user fixes the draft and the agent asks again: a new approval.
        _ = try harness.store.updateDraft(id: draft.id, patch: DraftPatch(bodyPlain: "Fixed body"), actor: PlainpostFixtures.codexActor)
        let again = try harness.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Agent reply")
        XCTAssertEqual(again.id, request, "the request ID is reused")
        await harness.nodeSender.answerNewMutations(with: "applied")
        try await harness.approve(again.id)

        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sent)
        let journal = try harness.journal(account: "acc-node")
        XCTAssertEqual(journal.count, 2)
        XCTAssertEqual(try harness.store.mailIntent(operationID: failed.operationID), failed, "the earlier approval's intent is untouched")
        XCTAssertEqual(journal.first { $0.operationID != failed.operationID }?.state, .confirmed)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds.filter { $0 == "send" }.count, 1)
    }

    func testARequestClaimedByAnUnroutedAttemptBecomesUncertainNotResent() async throws {
        let smtp = LocalSMTPServer(username: "acc-node@example.test", password: "pw-acc-node")
        try await smtp.start()
        defer { smtp.stop() }
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")], smtpPort: Int(smtp.port))
        defer { harness.cleanUp() }
        let (draft, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        // The direct SMTP path claimed it (no operation ID) before the account
        // became Node-backed; its job then died.
        _ = try harness.store.claimSendRequestForDelivery(id: request, currentDraftHash: draft.contentHash, actor: PlainpostFixtures.guiUser)
        _ = try harness.store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery,
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostApprovalDecisionInput(requestID: request, actorID: "local-user")), as: UTF8.self),
            priority: 100, maxAttempts: 1, idempotencyKey: "approved-delivery-retry:\(request.rawValue)"))

        _ = try await harness.operations.processBackgroundJobs()

        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .deliveryUncertain, "it may have been sent")
        XCTAssertEqual(try harness.journal(account: "acc-node"), [])
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 0)
        let kinds = await harness.nodeSender.mutationKinds
        XCTAssertEqual(kinds, [])
    }

    func testAReconcileTickDuringASlowDirectSendNeverMarksItUncertain() async throws {
        let smtp = LocalSMTPServer(username: "acc-fb@example.test", password: "pw-acc-fb")
        try await smtp.start()
        defer { smtp.stop() }
        let holding = RoutingFlag()
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-fb")], smtpPort: Int(smtp.port), onIMAPSessionStart: {
            guard holding.isSet else { return }
            arrived.signal()
            _ = release.wait(timeout: .now() + 10)
        })
        defer { harness.cleanUp() }
        let (_, requestID) = try harness.createApprovalDraft(account: "acc-fb")
        let request = try XCTUnwrap(requestID)
        holding.set()
        // The direct send's Sent-copy append (after SMTP) is held on the wire.
        let approving = Task { try await harness.approve(request) }
        XCTAssertEqual(arrived.wait(timeout: .now() + 10), .success)
        let inFlight = try XCTUnwrap(try harness.journal(account: "acc-fb").first)
        XCTAssertEqual(inFlight.state, .dispatching)
        XCTAssertEqual(inFlight.route, .direct)

        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router)

        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sending, "still on the wire, not uncertain")
        release.signal()
        try await approving.value
        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router)
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sent)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testOnlyOneCallerWinsTheRoutedSentTransition() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (draft, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        let operationID = UUID().uuidString.lowercased()
        _ = try harness.store.claimSendRequestForDelivery(id: request, currentDraftHash: draft.contentHash, actor: PlainpostFixtures.guiUser,
                                                          deliveryOperationID: operationID)
        XCTAssertFalse(try harness.store.settleRoutedSendRequest(id: request, operationID: UUID().uuidString.lowercased(), to: .sent),
                       "only the approval's own operation")
        XCTAssertTrue(try harness.store.settleRoutedSendRequest(id: request, operationID: operationID, to: .sent))
        XCTAssertFalse(try harness.store.settleRoutedSendRequest(id: request, operationID: operationID, to: .sent), "the second caller records nothing")
    }

    // MARK: - Approved sends (Task 17 fix round 3)

    func testAVaultLockDuringTheBrowserReplyWaitCompletesPromptly() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (draft, _) = try harness.createApprovalDraft(account: "acc-node", browser: true)
        harness.sessions.setReachable(false)
        await harness.operations.setBrowserReplySettleTiming(timeout: .seconds(20), poll: .milliseconds(20))
        let operations = harness.operations
        let started = ContinuousClock.now
        let reply = Task {
            try await operations.perform(.deliverBrowserReply(PlainpostBrowserReplyDeliveryPayload(
                draftID: draft.id.rawValue, expectedHash: draft.contentHash, idempotencyKey: "browser-reply-lock")))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while try harness.journal(account: "acc-node").isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))   // inside the wait now

        let lockStarted = ContinuousClock.now
        await operations.beginVaultLockdown()
        XCTAssertLessThan(lockStarted.duration(to: .now), .seconds(3), "the lockdown never waits on the browser wait")
        guard case let .deliverBrowserReply(result) = try await reply.value else { return XCTFail("expected a browser reply") }
        XCTAssertLessThan(started.duration(to: .now), .seconds(5), "the wait ends with the lock")
        XCTAssertEqual(result.state, "waitingForNode")
    }

    func testAPossiblySentRequestFailsOnlyWhenItsOwnIntentAuthoritativelyFailed() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (draft, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        harness.sessions.setReachable(false)
        let operationID = UUID().uuidString.lowercased()
        _ = try harness.store.claimSendRequestForDelivery(id: request, currentDraftHash: draft.contentHash, actor: PlainpostFixtures.guiUser,
                                                          deliveryOperationID: operationID)
        _ = try await harness.router.sendIntent(draft, approvedContentHash: draft.contentHash, operationID: operationID)
        _ = try harness.store.updateSendRequest(id: request, status: .deliveryUncertain, approvedBy: "local-user", approvedDraftHash: draft.contentHash)

        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router)
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .deliveryUncertain, "a pending intent decides nothing")

        _ = try harness.store.refuseUnroutedMailIntent(operationID: operationID, now: Date())   // provably never sent
        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router, changedAfter: Date().addingTimeInterval(60))
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .deliveryUncertain,
                       "only intents that changed since the last sweep are looked at")
        await ServiceApprovedSendRouting.reconcile(store: harness.store, router: harness.router, changedAfter: Date().addingTimeInterval(-60))
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .failed)
    }

    func testTheSettleWriteChecksTheApprovalsOwnOperation() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let (draft, requestID) = try harness.createApprovalDraft(account: "acc-node")
        let request = try XCTUnwrap(requestID)
        let operationID = UUID().uuidString.lowercased()
        _ = try harness.store.claimSendRequestForDelivery(id: request, currentDraftHash: draft.contentHash, actor: PlainpostFixtures.guiUser,
                                                          deliveryOperationID: operationID)
        for status in [SendRequestStatus.failed, .deliveryUncertain, .sent] {
            XCTAssertFalse(try harness.store.settleRoutedSendRequest(id: request, operationID: UUID().uuidString.lowercased(), to: status))
        }
        XCTAssertEqual(try harness.store.sendRequest(id: request).status, .sending)
        XCTAssertTrue(try harness.store.settleRoutedSendRequest(id: request, operationID: operationID, to: .deliveryUncertain))
        XCTAssertFalse(try harness.store.settleRoutedSendRequest(id: request, operationID: operationID, to: .deliveryUncertain),
                       "uncertain never moves to uncertain again")
    }

    // MARK: - Approved sends (Task 17 fix round 4)

    func testTheSweepWatermarkFollowsTheNewestChangeSeenNotTheClock() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.node("acc-node")])
        defer { harness.cleanUp() }
        let past = Date().addingTimeInterval(-3_600)
        func uncertainRequest(account: String, draftSuffix: String, confirmedAt: Date) throws -> SendRequestID {
            let draft = try harness.store.createDraft(
                Draft(id: DraftID("drf_agent_\(draftSuffix)"), accountID: AccountID(account), from: EmailAddress("\(account)@example.test"),
                      to: [EmailAddress("to@example.test")], cc: [], bcc: [], subject: "Watermark", bodyPlain: draftSuffix,
                      createdBy: "codex", aiGenerated: true, sourceThreadID: nil),
                actor: PlainpostFixtures.codexActor)
            let request = try harness.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Agent reply")
            let operationID = UUID().uuidString.lowercased()
            _ = try harness.store.claimSendRequestForDelivery(id: request.id, currentDraftHash: draft.contentHash,
                                                              actor: PlainpostFixtures.guiUser, deliveryOperationID: operationID)
            _ = try harness.store.journalMailIntent(operationID: operationID, accountID: AccountID(account), kind: .send, messageID: nil,
                                                    draftID: draft.id, contentHash: draft.contentHash, now: confirmedAt)
            _ = try harness.store.beginMailIntentDispatch(operationID: operationID, route: .node, now: confirmedAt)
            _ = try harness.store.recordMailIntentOutcome(operationID: operationID, state: .confirmed, now: confirmedAt)
            _ = try harness.store.updateSendRequest(id: request.id, status: .deliveryUncertain, approvedBy: "local-user",
                                                    approvedDraftHash: draft.contentHash)
            return request.id
        }
        let first = try uncertainRequest(account: "acc-node", draftSuffix: "first", confirmedAt: past)
        let reconciler = ServiceApprovedSendReconciler(store: harness.store, router: harness.router)
        await reconciler.sweep()
        XCTAssertEqual(try harness.store.sendRequest(id: first).status, .sent)
        let watermark = await reconciler.watermark
        XCTAssertEqual(watermark.timeIntervalSince1970, past.addingTimeInterval(-1).timeIntervalSince1970, accuracy: 0.01,
                       "the newest change seen, less the overlap, not the wall clock")

        // A row committed after that sweep but stamped just before the newest
        // change it saw is still read.
        let late = try uncertainRequest(account: "acc-node", draftSuffix: "late", confirmedAt: past.addingTimeInterval(-0.5))
        await reconciler.sweep()
        XCTAssertEqual(try harness.store.sendRequest(id: late).status, .sent)
    }

    // MARK: - Vault gate and stale mode (Task 17 fix round 1)

    func testAVaultLockdownWaitsForAnInFlightDirectDispatch() async throws {
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-fb")], onIMAPSessionStart: {
            arrived.signal()
            _ = release.wait(timeout: .now() + 10)
        })
        defer { harness.cleanUp() }
        let operations = harness.operations
        let message = harness.messageID(account: "acc-fb")
        let dispatch = Task { try await operations.performDirectMailIntent(.archive, messageID: message, archiveMailbox: nil) }
        XCTAssertEqual(arrived.wait(timeout: .now() + 10), .success)
        let lockdownDone = RoutingFlag()
        let lockdown = Task {
            await operations.beginVaultLockdown()
            lockdownDone.set()
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(lockdownDone.isSet, "lockdown waits for the direct write in flight")
        release.signal()
        try await dispatch.value
        await lockdown.value
        XCTAssertTrue(lockdownDone.isSet)
        XCTAssertEqual(harness.imapArchiveCount(account: "acc-fb"), 1)
    }

    func testAnUnreachableIMAPServerLeavesAFallbackArchivePendingNotStranded() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-fb")])
        defer { harness.cleanUp() }
        harness.imapServer(account: "acc-fb")?.stop()

        let result = try await harness.operations.perform(.archive(harness.archivePayload(account: "acc-fb")))

        guard case let .archive(archive) = result else { return XCTFail("expected an archive result") }
        XCTAssertTrue(archive.waitingForNode, "a sign-in that never reached the server is a wait")
        let journal = try harness.journal(account: "acc-fb")
        XCTAssertEqual(journal.map(\.state), [.pending], "never left in dispatching(direct), which is never resent")
        XCTAssertEqual(journal.map(\.route), [nil])
        XCTAssertEqual(journal.first?.deferralReason, .mailServerUnreachable)
    }

    func testIMAPFailuresBeforeAnyCommandDeferAndLaterOnesStayAmbiguous() {
        let deferral = ServiceDirectMailDispatcher.deferral(for: IMAPClientError.unreachableBeforeCommand)
        XCTAssertEqual(deferral?.code, .mailServerUnreachable)
        XCTAssertEqual(deferral?.transient, true)
        for error in [IMAPClientError.connectionFailed, .timedOut, .protocolError("lost")] {
            XCTAssertNil(ServiceDirectMailDispatcher.deferral(for: error), "\(error) may follow a STORE, MOVE or EXPUNGE")
            XCTAssertNil(ServiceDirectMailDispatcher.refusal(for: error), "\(error) may follow a STORE, MOVE or EXPUNGE")
        }
    }

    func testDirectRouteDefersWhileLockedOrOnceTheAccountLeftFallback() async throws {
        let harness = try await ServiceRoutingHarness.make(accounts: [.fallback("acc-fb")])
        defer { harness.cleanUp() }
        let message = harness.messageID(account: "acc-fb")
        XCTAssertNotNil(ServiceDirectMailDispatcher.deferral(for: CredentialVaultError.locked))
        XCTAssertNil(ServiceDirectMailDispatcher.deferral(for: SMTPClientError.authenticationFailed))

        try harness.setMode(.node, account: "acc-fb")
        await XCTAssertThrowsErrorAsync(try await harness.operations.performDirectMailIntent(.archive, messageID: message, archiveMailbox: nil)) {
            XCTAssertTrue($0 is DirectMailDispatchDeferral, "a stale fallback route defers, never fails: \($0)")
        }
        try harness.setMode(.fallback, account: "acc-fb")
        await harness.operations.beginVaultLockdown()
        await XCTAssertThrowsErrorAsync(try await harness.operations.performDirectMailIntent(.archive, messageID: message, archiveMailbox: nil)) {
            XCTAssertTrue($0 is DirectMailDispatchDeferral, "a locked runtime defers: \($0)")
        }
        XCTAssertEqual(harness.imapArchiveCount(account: "acc-fb"), 0)
    }

    func testMailActionReplyCarriesOnlyItsSemanticFields() throws {
        let result = PlainpostMailActionSemanticResult(messageID: "m1", mailboxPath: "Archive", isDeleted: false, waitingForNode: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["messageID", "mailboxPath", "isDeleted", "waitingForNode"])
        let older = try JSONDecoder().decode(
            PlainpostMailActionSemanticResult.self, from: Data(#"{"messageID":"m1","isDeleted":false}"#.utf8))
        XCTAssertFalse(older.waitingForNode, "an older peer's payload decodes as not waiting")
        XCTAssertTrue(PlainpostForegroundOperationResult.archive(result)
            .isSemanticallyCorrelated(with: .archive(PlainpostMailActionPayload(messageID: "m1"))))
    }
}

// MARK: - Harness

private final class ServiceRoutingHarness: @unchecked Sendable {
    enum AccountSpec {
        case direct(String), node(String), fallback(String)
        var id: String {
            switch self { case let .direct(id), let .node(id), let .fallback(id): id }
        }
    }

    static let nodeID = "50000000-0000-4000-8000-000000000916"

    let directory: URL
    let store: SQLiteMailStore
    let assembly: SQLiteCredentialVaultAssembly
    let operations: PlainpostServiceOperations
    let nodeSender: RecordingNodeMutationSender
    let sessions: StubNodeMailSessionProvider
    let router: MailIntentRouter
    private let servers: [String: LocalIMAPServer]
    private let messages: [String: MessageID]

    private init(directory: URL, store: SQLiteMailStore, assembly: SQLiteCredentialVaultAssembly, operations: PlainpostServiceOperations,
                 nodeSender: RecordingNodeMutationSender, sessions: StubNodeMailSessionProvider, router: MailIntentRouter,
                 servers: [String: LocalIMAPServer], messages: [String: MessageID]) {
        self.router = router
        self.directory = directory
        self.store = store
        self.assembly = assembly
        self.operations = operations
        self.nodeSender = nodeSender
        self.sessions = sessions
        self.servers = servers
        self.messages = messages
    }

    static func make(
        accounts specs: [AccountSpec], readOnlySession: Bool = false, smtpPort: Int = 1,
        onIMAPSessionStart: @escaping @Sendable () -> Void = {}
    ) async throws -> ServiceRoutingHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("plainpost.sqlite").path)
        try store.migrate()
        let assembly = SQLiteCredentialVaultAssembly(store: store, provider: RoutingVaultKeyProvider())
        try await assembly.unlockForeground(prompt: "Test-only in-memory vault unlock")

        var servers: [String: LocalIMAPServer] = [:]
        var messages: [String: MessageID] = [:]
        var summaries: [String: MessageSummary] = [:]
        var accounts: [Account] = []
        for spec in specs {
            let id = spec.id
            let rfcMessageID = "<routing-\(id)@example.test>"
            let message = MessageSummary(
                id: MessageID(IMAPSyncService.canonicalMessageID(accountID: AccountID(id), rfcMessageID: rfcMessageID)),
                threadID: nil, from: EmailAddress("sender@example.test"), subject: "Routing", preview: "Routing",
                smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                body: "Routing", rfcMessageID: rfcMessageID)
            let server = LocalIMAPServer(username: "\(id)@example.test", password: "pw-\(id)", message: message,
                                         uidValidity: 7, messageUID: 42, extraMailboxes: [.init(path: "Archive")],
                                         onSessionStart: onIMAPSessionStart)
            try await server.start()
            servers[id] = server
            messages[id] = message.id
            summaries[id] = message
            accounts.append(Account(
                id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.test"),
                username: "\(id)@example.test", sentMailbox: "Sent", imapHost: "127.0.0.1", imapPort: server.port,
                smtpHost: "127.0.0.1", smtpPort: smtpPort))
        }
        try store.cacheAccounts(accounts)
        var listed: [RecordingNodeMutationSender.Listed] = []
        for (index, spec) in specs.enumerated() {
            let id = spec.id
            _ = try store.commitIncomingMessage(
                summaries[id]!,
                metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: AccountID(id), mailboxPath: "INBOX", uidValidity: 7, uid: 42, notificationDisposition: .ineligible)
            try await assembly.vault.store(Data("pw-\(id)".utf8), for: CredentialRecordKey(rawValue: "account:\(id):imap-password"))
            try await assembly.vault.store(Data("pw-\(id)".utf8), for: CredentialRecordKey(rawValue: "account:\(id):smtp-password"))
            let mode: NodeBackedMode
            switch spec {
            case .direct: continue
            case .node: mode = .node
            case .fallback: mode = .fallback
            }
            let logical = LogicalMailboxID(rawValue: Data(repeating: UInt8(0x41 + index), count: 32))!
            listed.append(.init(logicalMailboxID: logical, providerIdentity: "\(id)@example.test"))
            let current = try store.mailSource(accountID: AccountID(id))
            let backed = try store.replaceMailSource(
                current.nodeBacked(nodeID: nodeID, logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(logical),
                                   providerIdentity: "\(id)@example.test"),
                expectedGeneration: current.generation)
            if mode == .fallback {
                _ = try store.replaceMailSource(backed.withMode(.fallback), expectedGeneration: backed.generation)
            }
            let messageID = messages[id]!
            try await store.databasePool.write { database in
                try database.execute(sql: """
                    INSERT INTO node_mirror_message_links (account_id, node_message_id, message_id, hydration_state)
                    VALUES (?, ?, ?, 'complete')
                    """, arguments: [id, "n-\(id)", messageID.rawValue])
            }
        }
        let nodeSender = RecordingNodeMutationSender(listed: listed, nodeID: nodeID, readOnly: readOnlySession)
        let sessions = StubNodeMailSessionProvider(sender: nodeSender, nodeID: nodeID)
        let direct = ServiceDirectMailDispatcher()
        let router = PlainpostServiceComposition.makeMailIntentRouter(store: store, direct: direct)
        await router.attach(sessions: sessions)
        let operations = PlainpostServiceOperations(
            applicationSupportURL: directory, store: store, assembly: assembly,
            backgroundJobWakeScheduler: RoutingNoopWakeScheduler(),
            mailMonitorFactory: { _ in RoutingNoopMailMonitor() },
            mailIntentRouter: router)
        direct.bind(operations)
        await operations.reopenRuntimeConstruction()
        return ServiceRoutingHarness(directory: directory, store: store, assembly: assembly, operations: operations,
                                     nodeSender: nodeSender, sessions: sessions, router: router, servers: servers, messages: messages)
    }

    func cleanUp() {
        servers.values.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    func messageID(account: String) -> MessageID { messages[account]! }

    func archivePayload(account: String) -> PlainpostMailActionPayload {
        PlainpostMailActionPayload(messageID: messageID(account: account).rawValue)
    }

    func imapArchiveCount(account: String) -> Int {
        guard let server = servers[account] else { return 0 }
        return server.archivedUIDs.count
    }

    func imapLoginCount(account: String) -> Int { servers[account]?.loginAttempts.count ?? 0 }
    func imapServer(account: String) -> LocalIMAPServer? { servers[account] }

    func setMode(_ mode: NodeBackedMode, account: String) throws {
        let current = try store.mailSource(accountID: AccountID(account))
        _ = try store.replaceMailSource(current.withMode(mode), expectedGeneration: current.generation)
    }

    func journal(account: String) throws -> [MailIntentRecord] {
        try store.mailIntents(accountID: AccountID(account), states: Set(MailIntentState.allCases))
    }

    /// An agent draft with a pending send request (or, for `browser`, a
    /// browser-extension draft the delivery route authorizes itself).
    func createApprovalDraft(account: String, browser: Bool = false) throws -> (draft: Draft, requestID: SendRequestID?) {
        let author = browser
            ? Actor(id: "browser-extension-user", kind: .user, displayName: "Plainpost Browser Extension", permissions: .guiUser)
            : PlainpostFixtures.codexActor
        let draft = try store.createDraft(
            Draft(id: DraftID(browser ? "drf_browser_\(account)" : "drf_agent_\(account)"), accountID: AccountID(account),
                  from: EmailAddress("\(account)@example.test"), to: [EmailAddress("to@example.test")], cc: [], bcc: [],
                  subject: "Approved", bodyPlain: "Approved body", createdBy: author.id, aiGenerated: !browser, sourceThreadID: nil),
            actor: author)
        guard !browser else { return (draft, nil) }
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Agent reply")
        return (draft, request.id)
    }

    func approve(_ requestID: SendRequestID) async throws {
        _ = try await operations.perform(.approveSend(PlainpostApprovalDecisionInput(requestID: requestID, actorID: "local-user")))
    }

    func createDraft(account: String) throws -> Draft {
        try store.createDraft(
            Draft(id: DraftID("drf_routing_\(account)"), accountID: AccountID(account), from: EmailAddress("\(account)@example.test"),
                  to: [EmailAddress("to@example.test")], cc: [], bcc: [], subject: "Routing", bodyPlain: "Body",
                  createdBy: "local-user", aiGenerated: false, sourceThreadID: nil),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
    }

    /// Operations over another process's view of the store after the
    /// journal table disappeared (v2 absent).
    func operationsOverStoreWithoutJournal() async throws -> PlainpostServiceOperations {
        try await store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_intent_journal")
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'node-mode-v2-mail-intent-journal'")
        }
        let reopened = try SQLiteMailStore(path: directory.appendingPathComponent("plainpost.sqlite").path)
        let direct = ServiceDirectMailDispatcher()
        let router = PlainpostServiceComposition.makeMailIntentRouter(store: reopened, direct: direct)
        await router.attach(sessions: sessions)
        let operations = PlainpostServiceOperations(
            applicationSupportURL: directory, store: reopened, assembly: assembly,
            backgroundJobWakeScheduler: RoutingNoopWakeScheduler(),
            mailMonitorFactory: { _ in RoutingNoopMailMonitor() },
            mailIntentRouter: router)
        direct.bind(operations)
        await operations.reopenRuntimeConstruction()
        return operations
    }
}

private struct ServiceRoutingBusyStore: Error {}

private final class RoutingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private actor RoutingVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x61, count: 32)
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { key }
    func countMatchingItems() async throws -> Int { 1 }
}

private actor RoutingNoopMailMonitor: ServiceMailMonitoring {
    func start() {}
    func stop() {}
}

private actor RoutingNoopWakeScheduler: BackgroundJobWakeScheduling {
    func replaceWake(at date: Date?, action: @escaping @Sendable () async -> Void) {}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
