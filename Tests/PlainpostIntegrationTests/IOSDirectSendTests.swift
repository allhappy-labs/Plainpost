import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime
import PlainpostSecrets
import PlainpostIOSRuntime
import PlainpostTestSupport
import PlainpostUI

final class IOSDirectSendTests: XCTestCase {
    func testAcceptedSMTPRecordsOneSentCopyAndBlocksDuplicate() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try await Fixture(port: smtp.port)
        let sender = IOSDirectComposerSender(store: fixture.store, credentials: fixture.vault)

        let result = try await sender.send(draft: fixture.draft)
        XCTAssertEqual(fixture.store.messages.filter { $0.id.rawValue == result.messageID }.count, 1)
        XCTAssertEqual(try fixture.store.directSendIntent(draftID: fixture.draft.id, contentHash: fixture.draft.contentHash)?.state, .sent)
        XCTAssertThrowsError(try fixture.store.draft(id: fixture.draft.id)) { error in
            XCTAssertEqual(error as? PlainpostError, .notFound("Draft not found."))
        }
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()
        XCTAssertThrowsError(try reopened.draft(id: fixture.draft.id))
        do {
            _ = try await sender.send(draft: fixture.draft)
            XCTFail("A sent draft was resubmitted")
        } catch DirectSendIntentError.alreadySubmitted(.sent) {}
        catch { XCTFail("Expected sent intent refusal, got \(error)") }
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testLostFinalReplyRemainsUncertainAfterReopen() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret", disconnectAfterData: true)
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try await Fixture(port: smtp.port)
        let sender = IOSDirectComposerSender(store: fixture.store, credentials: fixture.vault)
        do {
            _ = try await sender.send(draft: fixture.draft)
            XCTFail("Lost DATA acknowledgement was treated as sent")
        } catch DirectSendIntentError.alreadySubmitted(.uncertain) {}
        catch { XCTFail("Expected uncertain outcome, got \(error)") }
        XCTAssertEqual(try fixture.store.directSendIntent(draftID: fixture.draft.id, contentHash: fixture.draft.contentHash)?.state, .uncertain)
        XCTAssertEqual(try fixture.store.draft(id: fixture.draft.id), fixture.draft)
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()
        XCTAssertEqual(try reopened.directSendIntent(draftID: fixture.draft.id, contentHash: fixture.draft.contentHash)?.state, .uncertain)
        do {
            _ = try await IOSDirectComposerSender(store: reopened, credentials: fixture.vault).send(draft: fixture.draft)
            XCTFail("An uncertain draft was resubmitted")
        } catch DirectSendIntentError.alreadySubmitted(.uncertain) {}
        catch { XCTFail("Expected persisted uncertain refusal, got \(error)") }
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testSubmittingAtRestartIsVisibleAsUncertainAndCannotRetry() async throws {
        let fixture = try await Fixture(port: 9)
        _ = try fixture.store.reserveDirectSend(draftID: fixture.draft.id, contentHash: fixture.draft.contentHash, accountID: fixture.account.id)
        try fixture.store.markDirectSendSubmitting(draftID: fixture.draft.id, contentHash: fixture.draft.contentHash)
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()
        XCTAssertEqual(try reopened.directSendIntent(draftID: fixture.draft.id, contentHash: fixture.draft.contentHash)?.state, .submitting)
        XCTAssertEqual(try reopened.uncertainDirectSendIntents(accountID: fixture.account.id).map(\.draftID), [fixture.draft.id])
        do {
            _ = try await IOSDirectComposerSender(store: reopened, credentials: fixture.vault).send(draft: fixture.draft)
            XCTFail("An in-flight or interrupted draft was resubmitted")
        } catch DirectSendIntentError.alreadySubmitted(.submitting) {}
        catch { XCTFail("Expected persisted no-retry refusal, got \(error)") }
        let direct = try reopened.mailSource(accountID: fixture.account.id)
        let node = direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: fixture.account.email.rawValue
        )
        do {
            _ = try reopened.replaceMailSource(node, expectedGeneration: direct.generation)
            XCTFail("Uncertain send permitted source handover")
        } catch NodeMailModeStoreError.directSendUnresolved {}
        catch { XCTFail("Expected unresolved-send refusal, got \(error)") }
        XCTAssertEqual(try reopened.mailSource(accountID: fixture.account.id), direct)
    }

    func testSettlingSentIntentPreservesANewerDraftRevision() async throws {
        let fixture = try await Fixture(port: 9)
        let original = fixture.draft
        let intent = try fixture.store.reserveDirectSend(
            draftID: original.id, contentHash: original.contentHash, accountID: original.accountID
        )
        try fixture.store.markDirectSendSubmitting(intent, allowImplicitDirectSource: false)
        let edited = try fixture.store.updateDraft(
            id: original.id, patch: DraftPatch(bodyPlain: "A newer edit"),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        )

        try fixture.store.markDirectSendSent(intent, allowImplicitDirectSource: false)

        XCTAssertEqual(try fixture.store.draft(id: original.id), edited)
        XCTAssertEqual(try fixture.store.directSendIntent(
            draftID: original.id, contentHash: original.contentHash
        )?.state, .sent)
    }

    func testMacLegacyImplicitDirectUsesTheSameDurableIntent() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try await Fixture(port: smtp.port, explicitSource: false)
        let service = LocalDraftDeliveryService(store: fixture.store, credentials: fixture.vault)
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        _ = try await service.deliver(draftID: fixture.draft.id, expectedHash: fixture.draft.contentHash, actor: actor)
        XCTAssertEqual(try fixture.store.directSendIntent(draftID: fixture.draft.id, contentHash: fixture.draft.contentHash)?.state, .sent)
        XCTAssertThrowsError(try fixture.store.draft(id: fixture.draft.id))
        do {
            _ = try await service.deliver(draftID: fixture.draft.id, expectedHash: fixture.draft.contentHash, actor: actor)
            XCTFail("Mac legacy send submitted twice")
        } catch DirectSendIntentError.alreadySubmitted(.sent) {}
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testSourceSwitchDuringCredentialWaitPreventsSMTP() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try await Fixture(port: smtp.port)
        let vault = SuspendingCredentialVault(backing: fixture.vault)
        let sender = IOSDirectComposerSender(store: fixture.store, credentials: vault)
        let sending = Task { try await sender.send(draft: fixture.draft) }
        await vault.waitUntilBlocked()
        let direct = try fixture.store.mailSource(accountID: fixture.account.id)
        try fixture.store.replaceMailSource(direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: fixture.account.email.rawValue
        ), expectedGeneration: direct.generation)
        await vault.release()
        do {
            _ = try await sending.value
            XCTFail("Source switch reached SMTP")
        } catch NodeMailModeStoreError.generationConflict {}
        let accepted = await smtp.acceptedMessages()
        XCTAssertTrue(accepted.isEmpty)
    }

    func testSourceHandoverIsRefusedWhileSMTPDataIsInFlightThenAllowedAfterSend() async throws {
        let dataReceived = DispatchSemaphore(value: 0)
        let releaseReply = DispatchSemaphore(value: 0)
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret", onDataReceived: {
            dataReceived.signal()
            releaseReply.wait()
        })
        try await smtp.start()
        defer {
            releaseReply.signal()
            smtp.stop()
        }
        let fixture = try await Fixture(port: smtp.port)
        let sender = IOSDirectComposerSender(store: fixture.store, credentials: fixture.vault)
        let sending = Task { try await sender.send(draft: fixture.draft) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                dataReceived.wait()
                continuation.resume()
            }
        }
        XCTAssertEqual(try fixture.store.directSendIntent(
            draftID: fixture.draft.id, contentHash: fixture.draft.contentHash
        )?.state, .submitting)
        let direct = try fixture.store.mailSource(accountID: fixture.account.id)
        let node = direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: fixture.account.email.rawValue
        )
        do {
            _ = try fixture.store.replaceMailSource(node, expectedGeneration: direct.generation)
            XCTFail("Source handover succeeded during SMTP DATA")
        } catch NodeMailModeStoreError.directSendUnresolved {}
        catch { XCTFail("Expected active send refusal, got \(error)") }
        XCTAssertEqual(try fixture.store.mailSource(accountID: fixture.account.id), direct)
        releaseReply.signal()
        _ = try await sending.value
        XCTAssertEqual(try fixture.store.directSendIntent(
            draftID: fixture.draft.id, contentHash: fixture.draft.contentHash
        )?.state, .sent)
        XCTAssertEqual(try fixture.store.replaceMailSource(node, expectedGeneration: direct.generation), node)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testSecondHandleLeavesActiveSendSubmittingUntilOriginalSettles() async throws {
        let dataReceived = DispatchSemaphore(value: 0)
        let releaseReply = DispatchSemaphore(value: 0)
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret", onDataReceived: {
            dataReceived.signal()
            releaseReply.wait()
        })
        try await smtp.start()
        defer {
            releaseReply.signal()
            smtp.stop()
        }
        let fixture = try await Fixture(port: smtp.port)
        let sender = IOSDirectComposerSender(store: fixture.store, credentials: fixture.vault)
        let sending = Task { try await sender.send(draft: fixture.draft) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                dataReceived.wait()
                continuation.resume()
            }
        }
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()
        XCTAssertEqual(try reopened.directSendIntent(
            draftID: fixture.draft.id, contentHash: fixture.draft.contentHash
        )?.state, .submitting)
        let direct = try reopened.mailSource(accountID: fixture.account.id)
        let node = direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: fixture.account.email.rawValue
        )
        do {
            _ = try reopened.replaceMailSource(node, expectedGeneration: direct.generation)
            XCTFail("Second handle changed source while original SMTP send remained active")
        } catch NodeMailModeStoreError.directSendUnresolved {}
        catch { XCTFail("Expected unresolved-send refusal, got \(error)") }
        XCTAssertEqual(try reopened.mailSource(accountID: fixture.account.id), direct)
        releaseReply.signal()
        _ = try await sending.value
        XCTAssertEqual(try reopened.directSendIntent(
            draftID: fixture.draft.id, contentHash: fixture.draft.contentHash
        )?.state, .sent)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testRecipientRejectionIsRetryableWithoutAnSMTPDataSubmission() async throws {
        let smtp = LocalSMTPServer(
            username: "me@example.com", password: "secret",
            rejectedRecipients: [EmailAddress("friend@example.com")]
        )
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try await Fixture(port: smtp.port)
        do {
            _ = try await IOSDirectComposerSender(store: fixture.store, credentials: fixture.vault)
                .send(draft: fixture.draft)
            XCTFail("A rejected recipient was reported as sent")
        } catch {
            guard case SMTPClientError.recipientRejected = error else {
                return XCTFail("Expected a proven pre-DATA rejection, got \(error)")
            }
        }
        XCTAssertNil(try fixture.store.directSendIntent(
            draftID: fixture.draft.id, contentHash: fixture.draft.contentHash
        ))
        XCTAssertEqual(try fixture.store.draft(id: fixture.draft.id), fixture.draft)
        let accepted = await smtp.acceptedMessages()
        XCTAssertTrue(accepted.isEmpty)
    }

    func testForeignAccountAndNodeSourceNeverReachSMTP() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try await Fixture(port: smtp.port)
        let sender = IOSDirectComposerSender(store: fixture.store, credentials: fixture.vault)
        let foreign = Draft(
            id: fixture.draft.id, accountID: AccountID("other"), from: fixture.draft.from,
            to: fixture.draft.to, cc: [], bcc: [], subject: "Foreign", bodyPlain: "body",
            createdBy: fixture.draft.createdBy, aiGenerated: false, sourceThreadID: nil
        )
        do { _ = try await sender.send(draft: foreign); XCTFail("Foreign account draft sent") }
        catch DirectSendIntentError.draftMismatch {}
        catch { XCTFail("Expected draft ownership mismatch, got \(error)") }
        let direct = try fixture.store.mailSource(accountID: fixture.account.id)
        try fixture.store.replaceMailSource(direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: fixture.account.email.rawValue
        ), expectedGeneration: direct.generation)
        do { _ = try await sender.send(draft: fixture.draft); XCTFail("Node draft sent") }
        catch NodeMailModeStoreError.generationConflict {}
        catch { XCTFail("Expected Node source conflict, got \(error)") }
        do {
            _ = try await LocalDraftDeliveryService(store: fixture.store, credentials: fixture.vault)
                .deliver(draftID: fixture.draft.id, expectedHash: fixture.draft.contentHash,
                         actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
            XCTFail("Mac legacy entry point sent a Node draft")
        } catch NodeMailModeStoreError.generationConflict {}
        catch { XCTFail("Expected Node source conflict from Mac path, got \(error)") }
        let accepted = await smtp.acceptedMessages()
        XCTAssertTrue(accepted.isEmpty)
    }

    private struct Fixture {
        let url: URL
        let store: SQLiteMailStore
        let vault: InMemoryCredentialVault
        let account: Account
        let draft: Draft

        init(port: Int, explicitSource: Bool = true) async throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-direct-send-\(UUID().uuidString).sqlite")
            store = try SQLiteMailStore(path: url.path)
            try store.migrate()
            account = Account(id: AccountID("acc_send"), displayName: "Me", email: EmailAddress("me@example.com"), imapHost: "127.0.0.1", smtpHost: "127.0.0.1", smtpPort: port)
            let inbox = Mailbox(id: MailboxID("mbx_send_inbox"), accountID: account.id, name: "INBOX", path: "INBOX", specialUse: "\\Inbox")
            let source = try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
            if explicitSource {
                try store.cacheAccountSetup(account: account, inbox: inbox, source: source)
            } else {
                try store.cacheAccountSetup(account: account, inbox: inbox)
            }
            vault = InMemoryCredentialVault()
            try await vault.store(Data("secret".utf8), for: MailCredentialKeys.smtpPassword(account.id))
            let proposed = Draft(id: DraftID("drf_send"), accountID: account.id, from: account.email, to: [EmailAddress("friend@example.com")], cc: [], bcc: [], subject: "Hello", bodyPlain: "Body", createdBy: "local-user", aiGenerated: false, sourceThreadID: nil)
            draft = try store.createDraft(proposed, actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
        }
    }
}

private actor SuspendingCredentialVault: CredentialVault {
    private let backing: InMemoryCredentialVault
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(backing: InMemoryCredentialVault) { self.backing = backing }
    func store(_ secret: Data, for key: CredentialRecordKey) async throws { try await backing.store(secret, for: key) }
    func load(_ key: CredentialRecordKey) async throws -> Data? {
        if blocked == nil {
            await withCheckedContinuation { continuation in
                blocked = continuation
                waiter?.resume()
                waiter = nil
            }
        }
        return try await backing.load(key)
    }
    func remove(_ key: CredentialRecordKey) async throws { try await backing.remove(key) }
    func loadOrCreate(_ keys: [CredentialRecordKey], create: @escaping @Sendable () throws -> [Data]) async throws -> [Data?] {
        try await backing.loadOrCreate(keys, create: create)
    }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}
