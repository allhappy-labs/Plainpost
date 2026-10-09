import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI
import PlainpostRuntimeTestSupport
import PlainpostSecrets
import PlainpostTestSupport
import PlainpostAccountProtocol
import PlainpostOperations
import PlainpostOperationRuntime
import PlainpostAI
import XCTest
import CryptoKit

/// The iOS runtime built with Direct dependencies and no selected account: one runtime
/// for every Direct account on the device.
@MainActor
final class DeviceWideDirectRuntimeTests: XCTestCase {
    func testDeviceWideRuntimeListsEveryAccountsInbox() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let model = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertEqual(model.classicRows.map(\.id), ["msg_node_1", "msg_first_2", "msg_second_1", "msg_first_1"])
        XCTAssertEqual(Set(model.classicRows.compactMap(\.accountID)), [fixture.first.id, fixture.second.id, fixture.node!.id])
    }

    func testDirectoryHasOneSectionPerAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let sections = await runtime.mailboxDirectorySections()
        XCTAssertEqual(Set(sections.map(\.id)), [fixture.first.id, fixture.second.id, fixture.node!.id])
        let rows = try await runtime.folderRows(accountID: fixture.second.id, path: "INBOX", limit: 10)
        XCTAssertEqual(rows.map(\.id), ["msg_second_1"])
    }

    func testAccountSetupListsEveryAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertEqual(
            Set(runtime.makeAccountSetupViewModel().accounts.map(\.id)), [fixture.first.id, fixture.second.id, fixture.node!.id]
        )
    }

    func testOnlyTheDeviceWideIOSRuntimeDeliversNewMailAlerts() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertNotNil(runtime.macNewMailDelivery)

        let selected = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: fixture.databaseURL, selectedAccountID: fixture.first.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(credentials: InMemoryCredentialVault())
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await selected.shutdown() } }
        XCTAssertNil(selected.macNewMailDelivery)
    }

    // MARK: - Actions route to the owning account

    func testArchiveOnSecondAccountsRowRoutesToSecondAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let recorder = RecordingActionHandler()
        let handler = OwnerBoundInboxMailActionHandler(
            store: try fixture.store(),
            readGeneration: { [state = runtime.latestDeviceMailSources] _, owner in state?.generations[owner] },
            underlying: recorder
        )
        _ = try await handler.perform(.archive, messageID: MessageID("msg_second_1"), shownIn: "INBOX")
        XCTAssertEqual(recorder.performed, [MessageID("msg_second_1")])
    }

    func testActionOnRowReadBeforeSourceSwitchIsRefused() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let read = runtime.latestDeviceMailSources?.generations
        XCTAssertEqual(read, [fixture.first.id: 1, fixture.second.id: 1])
        let recorder = RecordingActionHandler()
        let handler = OwnerBoundInboxMailActionHandler(
            store: try fixture.store(), readGeneration: { _, owner in read?[owner] }, underlying: recorder
        )
        try fixture.switchToNode(fixture.second)
        do {
            _ = try await handler.perform(.markRead, messageID: MessageID("msg_second_1"), shownIn: "INBOX")
            XCTFail("expected generationConflict")
        } catch NodeMailModeStoreError.generationConflict {}
        XCTAssertTrue(recorder.performed.isEmpty)
    }

    func testActionOnRemovedAccountsRowFailsWithoutTouchingOthers() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let store = try fixture.store()
        let recorder = RecordingActionHandler()
        let handler = OwnerBoundInboxMailActionHandler(
            store: store, readGeneration: { _, owner in [fixture.first.id: 1, fixture.second.id: 1][owner] }, underlying: recorder
        )
        try await store.deleteAccountData(accountID: fixture.second.id, credentials: InMemoryCredentialVault())
        do {
            _ = try await handler.perform(.archive, messageID: MessageID("msg_second_1"), shownIn: "INBOX")
            XCTFail("expected an error for the removed account's message")
        } catch {}
        XCTAssertTrue(recorder.performed.isEmpty)
    }

    func testActionWithNoReadYetIsRefused() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let recorder = RecordingActionHandler()
        let handler = OwnerBoundInboxMailActionHandler(
            store: try fixture.store(), readGeneration: { _, _ in nil }, underlying: recorder
        )
        do {
            _ = try await handler.perform(.archive, messageID: MessageID("msg_first_1"), shownIn: "INBOX")
            XCTFail("expected generationConflict")
        } catch NodeMailModeStoreError.generationConflict {}
        XCTAssertTrue(recorder.performed.isEmpty)
    }

    func testRuntimeActionViewModelUsesTheOwnerBoundHandler() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertTrue(runtime.makeInboxMailActionViewModel().handler is OwnerBoundInboxMailActionHandler)
    }

    func testOpeningAMessageMarksItReadOnItsOwnAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        try await runtime.openOwnedDirectMessage(MessageID("msg_second_1"))
        XCTAssertEqual(try fixture.store().messageSummary(id: MessageID("msg_second_1"))?.isSeen, true)
        XCTAssertEqual(try fixture.store().messageSummary(id: MessageID("msg_first_1"))?.isSeen, false)
    }

    /// The open path reads the thread alone, then refreshes the list only when the open
    /// changed something: an already-read message keeps the projection it was read from.
    func testOpeningReportsWhetherItChangedReadStateAndTheThreadReadsAlone() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let id = MessageID("msg_second_1")
        let thread = await runtime.selectedThreadDetailAsync(messageID: id.rawValue)
        XCTAssertEqual(thread?.messages.map(\.id), [id.rawValue])
        let full = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: id.rawValue)
        XCTAssertEqual(thread, full.selectedThread, "the thread read alone is the one the full refresh shows")

        let firstOpen = try await runtime.openOwnedDirectMessage(id)
        let secondOpen = try await runtime.openOwnedDirectMessage(id)
        XCTAssertTrue(firstOpen)
        XCTAssertFalse(secondOpen, "an already-read message changes nothing")
    }

    /// Through the session, as the iPhone opens a row. The row stands for its conversation,
    /// unread while any of it is: opening it marks every message in it read, not only the
    /// newest one the row opens (which was already read here).
    func testOpeningAConversationMarksAllOfItReadInTheList() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let store = try fixture.store()
        let reply = MessageID("msg_second_reply")
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: reply, threadID: ThreadID("thr_msg_second_1"),
                from: EmailAddress("sender@example.com"), subject: "Re: Hello \(fixture.second.id.rawValue)",
                preview: "Reply", smartCategory: .personal, sentAt: Date(timeIntervalSince1970: 5)
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [fixture.second.email], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: fixture.second.id, mailboxPath: "INBOX", uidValidity: 1, uid: 10,
            notificationEligible: false
        )
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let session = runtime.makeMailSession(
            composerPresentationPolicy: .embedded, commitDelay: .zero, providerOnboarding: nil, accountSessionModel: nil,
            initialDestination: .allInboxes, initialSelectedMessageID: nil, onAccountSetupConnected: { _ in },
            contactDirectory: nil
        )
        await session.inboxSnapshot.refresh(selectedMessageID: nil)
        try await runtime.openOwnedDirectMessage(reply)
        await session.inboxSnapshot.refresh(selectedMessageID: nil)
        let row = try XCTUnwrap(session.inboxSnapshot.model.classicRows.first { $0.id == reply.rawValue })
        XCTAssertTrue(row.isUnread, "the earlier message keeps the conversation unread")

        session.openMailboxMessage(
            reply.rawValue, destination: .allInboxes, from: .mailbox(destination: .allInboxes, mode: .focusedList)
        )
        var failed = false
        await session.markOpenedMessageRead(reportFailure: { failed = true })
        XCTAssertFalse(failed)
        XCTAssertEqual(Set(session.inboxSnapshot.model.selectedThread.messages.map(\.id)), ["msg_second_1", reply.rawValue])
        XCTAssertEqual(try store.messageSummary(id: MessageID("msg_second_1"))?.isSeen, true)
        XCTAssertEqual(session.inboxSnapshot.model.classicRows.first { $0.id == reply.rawValue }?.isUnread, false)
    }

    func testOpeningAMessageAfterItsAccountMovedToSyncNodeIsRefused() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        try fixture.switchToNode(fixture.second)
        do {
            try await runtime.openOwnedDirectMessage(MessageID("msg_second_1"))
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(try fixture.store().messageSummary(id: MessageID("msg_second_1"))?.isSeen, false)
    }

    // MARK: - Approvals, audit and notifications cover every Direct account

    /// A pending approval and an audit entry per account, the Node-backed one included.
    private func seedApprovals(
        _ fixture: TwoDirectAccountsFixture
    ) throws -> [AccountID: SendRequestID] {
        let store = try fixture.store()
        var requests: [AccountID: SendRequestID] = [:]
        for account in [fixture.first, fixture.second] + (fixture.node.map { [$0] } ?? []) {
            let draft = try store.createDraft(
                Draft(
                    id: DraftID("audit-draft-\(account.id.rawValue)"),
                    accountID: account.id, from: account.email,
                    to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                    subject: "Approval \(account.id.rawValue)", bodyPlain: "Body",
                    createdBy: PlainpostFixtures.codexActor.id, aiGenerated: false, sourceThreadID: nil
                ),
                actor: PlainpostFixtures.codexActor
            )
            requests[account.id] = try store.requestSend(
                draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Review"
            ).id
        }
        return requests
    }

    func testApprovalsListEveryAccountsDraftsAndRefuseOneTheDeviceDoesntServe() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let requests = try seedApprovals(fixture)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let queue = runtime.makeApprovalQueueViewModel()
        try await queue.refresh()
        XCTAssertEqual(
            Set(queue.items.map(\.id)),
            [requests[fixture.first.id]!.rawValue, requests[fixture.second.id]!.rawValue, requests[fixture.node!.id]!.rawValue]
        )
        // An account with no explicit source isn't served: nothing is reviewed for it.
        let store = try fixture.store()
        let unserved = Account(
            id: AccountID("acc_unserved"), displayName: "Unserved", email: EmailAddress("unserved@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([unserved])
        let draft = try store.createDraft(
            Draft(
                id: DraftID("audit-draft-unserved"), accountID: unserved.id, from: unserved.email,
                to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                subject: "Approval unserved", bodyPlain: "Body",
                createdBy: PlainpostFixtures.codexActor.id, aiGenerated: false, sourceThreadID: nil
            ),
            actor: PlainpostFixtures.codexActor
        )
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Review").id
        do {
            try await queue.deny(requestID: request.rawValue, reason: "not served")
            XCTFail("An account this device doesn't serve had its approval reviewed")
        } catch {
            XCTAssertEqual(try store.sendRequest(id: request).status, .pending)
            XCTAssertEqual(try store.draft(id: draft.id).accountID, unserved.id)
        }
    }

    func testAuditLogShowsEveryDirectAccountAndNoNodeEntries() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        _ = try seedApprovals(fixture)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let audit = runtime.makeAuditLogViewModel()
        try await audit.refresh()
        XCTAssertNil(audit.auditLogURL)
        for account in [fixture.first, fixture.second] {
            XCTAssertTrue(audit.rows.contains { $0.targetSummary.contains("audit-draft-\(account.id.rawValue)") })
        }
        XCTAssertFalse(audit.rows.contains { $0.targetSummary.contains("audit-draft-\(fixture.node!.id.rawValue)") })
        let exportedURL = try XCTUnwrap(audit.exportAuditLog?())
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let exported = try String(contentsOf: exportedURL, encoding: .utf8)
        XCTAssertTrue(exported.contains("audit-draft-\(fixture.first.id.rawValue)"))
        XCTAssertTrue(exported.contains("audit-draft-\(fixture.second.id.rawValue)"))
        XCTAssertFalse(exported.contains("audit-draft-\(fixture.node!.id.rawValue)"))
    }

    func testNotificationTokensCarryEachMessagesOwnAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let generation = try fixture.store().mailSource(accountID: fixture.second.id).generation
        XCTAssertEqual(
            runtime.notificationMessageToken(for: "msg_second_1"),
            NotificationOpaqueIdentities.messageToken(
                for: "msg_second_1", accountID: fixture.second.id.rawValue,
                sourceKind: AccountMailSourceKind.direct.rawValue, sourceGeneration: generation
            )
        )
        let nodeGeneration = try fixture.store().mailSource(accountID: fixture.node!.id).generation
        XCTAssertEqual(
            runtime.notificationMessageToken(for: "msg_node_1"),
            NotificationOpaqueIdentities.messageToken(
                for: "msg_node_1", accountID: fixture.node!.id.rawValue,
                sourceKind: AccountMailSourceKind.nodeBacked.rawValue, sourceGeneration: nodeGeneration
            ),
            "a Sync Node account's token names its Node source"
        )
        XCTAssertNotNil(runtime.notificationInboxScope(for: fixture.first.id.rawValue))
        XCTAssertNotNil(runtime.notificationInboxScope(for: fixture.second.id.rawValue))
        XCTAssertNotNil(runtime.notificationInboxScope(for: fixture.node!.id.rawValue))
    }

    // MARK: - Search

    private func waitForSearch(_ model: MailSearchViewModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while case .searching = model.state, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(400))
        while case .searching = model.state, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testSearchCoversEveryAccountByDefault() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let model = runtime.makeMailSearchViewModel()
        XCTAssertEqual(Set(model.accounts.map(\.id)), [fixture.first.id, fixture.second.id, fixture.node!.id])
        model.reset(query: "Hello", accounts: model.accounts, accountScope: [])
        await waitForSearch(model)
        XCTAssertEqual(
            Set(model.rows.map { model.messageToOpen(for: $0) }),
            [MessageID("msg_first_2"), MessageID("msg_second_1"), MessageID("msg_first_1"), MessageID("msg_node_1")]
        )
    }

    func testFolderScopedSearchStaysInsideItsAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let model = runtime.makeMailSearchViewModel()
        model.reset(query: "Hello", accounts: model.accounts, accountScope: [fixture.second.id])
        await runtime.refreshMailSearchMailboxes(in: model, forceReload: true)
        XCTAssertFalse(model.mailboxes.isEmpty)
        XCTAssertTrue(model.mailboxes.allSatisfy { $0.accountID == fixture.second.id })
        await waitForSearch(model)
        XCTAssertEqual(model.rows.map { model.messageToOpen(for: $0) }, [MessageID("msg_second_1")])
    }

    // MARK: - AI runs under the message's own account

    func testThreadAIRunsUnderTheMessagesOwnAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let client = RecordingAIClient()
        let service = LocalOperationThreadAIAssistantService(
            client: client, store: try fixture.store(), providerID: "deterministic", providerName: "Test",
            requiresAccountScope: true, isDeviceWide: true
        )
        _ = try? await service.summarize(messageID: MessageID("msg_second_1"))
        let input = await client.lastInput
        XCTAssertEqual(input?.accountID, fixture.second.id)
        XCTAssertEqual(input?.expectedDirectSourceGeneration, try fixture.store().mailSource(accountID: fixture.second.id).generation)
    }

    /// The device mirrors a Sync Node account's mail, so its AI runs under the account's
    /// Node source as of the request.
    func testThreadAIRunsUnderTheSourceTheAccountHasNow() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let client = RecordingAIClient()
        let service = LocalOperationThreadAIAssistantService(
            client: client, store: try fixture.store(), providerID: "deterministic", providerName: "Test",
            requiresAccountScope: true, isDeviceWide: true
        )
        try fixture.switchToNode(fixture.second)
        _ = try? await service.summarize(messageID: MessageID("msg_second_1"))
        let input = await client.lastInput
        XCTAssertEqual(input?.accountID, fixture.second.id)
        XCTAssertEqual(input?.expectedDirectSourceGeneration, try fixture.store().mailSource(accountID: fixture.second.id).generation)
    }

    func testThreadAIRefusesAMessageWhoseAccountWasRemoved() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let client = RecordingAIClient()
        let store = try fixture.store()
        let service = LocalOperationThreadAIAssistantService(
            client: client, store: store, providerID: "deterministic", providerName: "Test",
            requiresAccountScope: true, isDeviceWide: true
        )
        try await store.deleteAccountData(accountID: fixture.second.id, credentials: InMemoryCredentialVault())
        _ = try? await service.summarize(messageID: MessageID("msg_second_1"))
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    func testTranslationRunsUnderTheMessagesOwnAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let client = RecordingAIClient()
        let service = LocalOperationThreadTranslationService(
            client: client, store: try fixture.store(), provider: DisabledAIProvider(),
            requiresAccountScope: true, isDeviceWide: true
        )
        _ = try? await service.translate(messageID: MessageID("msg_first_1"), targetLanguageID: "de", targetLanguageName: "German")
        let input = await client.lastInput
        XCTAssertEqual(input?.accountID, fixture.first.id)
        XCTAssertNotNil(input?.expectedDirectSourceGeneration)
    }

    func testAskMailCoversEveryDirectAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let client = RecordingAIClient()
        let service = LocalOperationAskMailService(
            client: client, store: try fixture.store(), providerID: "deterministic", providerName: "Test",
            requiresAccountScope: true, isDeviceWide: true
        )
        _ = try? await service.ask(question: "Any news?", scope: .allMail, activeContext: nil, priorTurns: [])
        let calls = await client.callCount
        XCTAssertEqual(calls, 1, "the device-wide runtime asks across accounts instead of refusing")
        let input = await client.lastInput
        XCTAssertNil(input?.accountID)
    }

    // MARK: - Attachments

    private func seedAttachment(_ account: Account, uid: Int, in fixture: TwoDirectAccountsFixture) throws -> MailAttachment {
        let store = try fixture.store()
        let payload = IncomingMessageAttachmentPayload(
            partPath: "2", filename: "report.txt", mimeType: "text/plain", data: Data("attached".utf8)
        )
        _ = try store.commitIncomingMessage(
            MessageSummary(id: MessageID("attachment-\(account.id.rawValue)"), threadID: nil,
                           from: account.email, subject: "Report", preview: "Attached", smartCategory: .personal),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [],
                attachments: [.init(filename: payload.filename, mimeType: payload.mimeType)],
                messageIdentifiers: []
            ),
            attachments: [payload], accountID: account.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: uid, notificationEligible: false
        )
        let generation = try store.mailSource(accountID: account.id).generation
        return MailAttachment(
            id: DirectIncomingAttachmentID(
                accountID: account.id, messageID: MessageID("attachment-\(account.id.rawValue)"),
                partPath: "2", sourceGeneration: generation
            ).encoded,
            filename: payload.filename, mimeType: "text/plain", disposition: "attachment",
            byteCount: payload.byteCount,
            contentDigest: Data(SHA256.hash(data: payload.data)).base64EncodedString()
        )
    }

    func testAttachmentsOpenForEveryDirectAccountButNotANodeOne() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let second = try seedAttachment(fixture.second, uid: 90, in: fixture)
        let node = try seedAttachment(fixture.node!, uid: 91, in: fixture)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertNoThrow(try runtime.saveDirectAttachmentArtifact(second))
        XCTAssertThrowsError(try runtime.saveDirectAttachmentArtifact(node))
    }

    // MARK: - Rules and labels

    func testRulesApplyToEveryDirectAccountsMailButNotANodeOnes() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let store = try fixture.store()
        let rule = try MailRule.validated(
            id: "mark-example", name: "Mark example", scope: .allAccounts,
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")],
            actions: [.markAsRead], labelIDs: []
        )
        try store.saveMailRule(rule)
        let processor = MailRuleProcessor(store: store, requireDirectSourceGeneration: true, perAccountDirectSource: true)
        let preview = try processor.previewExisting(rule: rule)
        XCTAssertEqual(Set(preview.matches.map(\.accountID)), [fixture.first.id, fixture.second.id])
        let run = try processor.applyExisting(rule: rule, preview: preview)
        XCTAssertEqual(run.failedItemCount, 0)
        XCTAssertEqual(run.totalItemCount, 3)
    }

    func testRulesAndLabelsOfferOnlyDirectAccounts() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertEqual(Set(runtime.makeMailRulesViewModel().accounts.map(\.id)), [fixture.first.id, fixture.second.id])
        XCTAssertEqual(Set(runtime.makeMailLabelsViewModel().accounts.map(\.id)), [fixture.first.id, fixture.second.id])
    }

    /// Sent lists every Direct account's sent mail and none of a Sync Node account's, on both
    /// inbox paths.
    func testSentRowsCoverDirectAccountsOnly() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let store = try fixture.store()
        for (index, account) in [fixture.second, fixture.node!].enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID("sent-\(account.id.rawValue)"), threadID: nil,
                               from: account.email, subject: "Sent", preview: "Sent", smartCategory: .personal,
                               sentAt: Date(timeIntervalSince1970: 10)),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: "Sent", uidValidity: 1, uid: 200 + index,
                notificationEligible: false
            )
        }
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertEqual(runtime.makeInboxViewModel().sentRows.map(\.id), ["sent-acc_two_second"])
        let async = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertEqual(async.sentRows.map(\.id), ["sent-acc_two_second"])
    }

    /// Search suggestions (people, folders) come from Direct accounts only.
    func testSearchSuggestionsCoverEveryAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let store = try fixture.store()
        for (index, (account, sender)) in [(fixture.first, "directonly@example.org"), (fixture.node!, "nodeonly@example.org")].enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID("suggest-\(index)"), threadID: nil, from: EmailAddress(sender),
                               subject: "Hi", preview: "Hi", smartCategory: .personal),
                metadata: .init(to: [account.email], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: 300 + index,
                notificationEligible: false
            )
        }
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        func people(_ query: String) async throws -> String {
            let sections = try await runtime.mailSearchService.suggestions(MailSearchSuggestionRequest(
                query: query, recentQueries: [], activeRange: .init(location: 0, length: query.utf16.count)
            ))
            return String(decoding: try JSONEncoder().encode(sections.filter { $0.kind == .people }), as: UTF8.self)
        }
        let direct = try await people("directonly")
        XCTAssertTrue(direct.contains("directonly"), direct)
        let node = try await people("nodeonly")
        XCTAssertTrue(node.contains("nodeonly"), node)
    }

    // MARK: - Each row is checked against the read that listed it

    /// A folder list is its own read: its rows are acted on against the source generation it
    /// was read at, not an older inbox read's.
    func testAFolderRowIsCheckedAgainstTheFolderRead() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        try fixture.switchToNode(fixture.second)
        try fixture.switchToDirect(fixture.second)
        let current = try fixture.store().mailSource(accountID: fixture.second.id).generation
        _ = try await runtime.folderRows(accountID: fixture.second.id, path: "INBOX", limit: 10)
        XCTAssertEqual(runtime.deviceDirectReadGeneration(for: MessageID("msg_second_1"), owner: fixture.second.id), current)
        XCTAssertEqual(runtime.deviceDirectReadGeneration(for: MessageID("msg_first_1"), owner: fixture.first.id), 1)
        let recorder = RecordingActionHandler()
        let handler = OwnerBoundInboxMailActionHandler(
            store: try fixture.store(),
            readGeneration: { [runtime] messageID, owner in runtime.deviceDirectReadGeneration(for: messageID, owner: owner) },
            underlying: recorder
        )
        _ = try await handler.perform(.markRead, messageID: MessageID("msg_second_1"), shownIn: "INBOX")
        XCTAssertEqual(recorder.performed, [MessageID("msg_second_1")])
    }

    /// Search results are reads too.
    func testASearchHitIsCheckedAgainstTheSearchRead() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        try fixture.switchToNode(fixture.second)
        try fixture.switchToDirect(fixture.second)
        let current = try fixture.store().mailSource(accountID: fixture.second.id).generation
        _ = try await runtime.mailSearchService.search(MailSearchRequest(query: "Hello", mode: .messages))
        XCTAssertEqual(runtime.deviceDirectReadGeneration(for: MessageID("msg_second_1"), owner: fixture.second.id), current)
    }

    /// Listed rows name their account without a database lookup per row.
    func testListedRowsResolveTheirAccountFromTheRead() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertEqual(runtime.deviceDirectReadOwner(of: MessageID("msg_second_1")), fixture.second.id)
        XCTAssertEqual(runtime.account(forMessageID: "msg_second_1")?.id, fixture.second.id)
        XCTAssertEqual(runtime.account(forMessageID: "msg_first_2")?.id, fixture.first.id)
    }

    // MARK: - Sync status across Direct accounts

    private func seedSyncState(_ account: Account, phase: String, complete: Bool, updatedAt: Double,
                               in store: SQLiteMailStore) throws {
        try store.databasePool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO mailbox_sync_state (account_id, mailbox_path, phase, downloaded_count, estimated_total, complete, updated_at)
                    VALUES (?, 'INBOX', ?, 10, 100, ?, ?)
                    """,
                arguments: [account.id.rawValue, phase, complete ? 1 : 0, updatedAt]
            )
        }
    }

    /// After a relaunch the iPhone finds the Direct account whose complete history is still
    /// downloading, so its page shows the progress again.
    func testAHistoryDownloadInProgressIsFoundAfterRelaunch() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let store = try fixture.store()
        for account in [fixture.second, fixture.node!] {
            var preferences = try store.syncPreferences(accountID: account.id)
            preferences.downloadCompleteHistory = true
            try store.saveSyncPreferences(preferences)
            try seedSyncState(account, phase: "backfill", complete: false, updatedAt: 5, in: store)
        }
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertEqual(runtime.directAccountWithHistoryInProgress(), fixture.second.id)
    }

    /// "Last synced" is the newest sync of a Direct account, never a Sync Node account's
    /// leftover state.
    func testLastSuccessfulSyncCoversDirectAccountsOnly() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let store = try fixture.store()
        try seedSyncState(fixture.first, phase: "incremental", complete: true, updatedAt: 100, in: store)
        try seedSyncState(fixture.node!, phase: "incremental", complete: true, updatedAt: 900, in: store)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        XCTAssertEqual(runtime.lastSuccessfulDirectSync(), Date(timeIntervalSince1970: 100))
    }
}

private actor RecordingAIClient: PlainpostOperationClientProtocol {
    private(set) var callCount = 0
    private(set) var lastInput: PlainpostAIOperationInput?
    struct Stopped: Error {}

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult { throw Stopped() }
    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        callCount += 1
        lastInput = input
        throw Stopped()
    }
    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {}
    func approveSend(requestID: SendRequestID, approvedBy: String) async throws { throw Stopped() }
    func denySend(requestID: SendRequestID, deniedBy: String) async throws { throw Stopped() }
}

private final class RecordingActionHandler: InboxMailActionHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var messageIDs: [MessageID] = []
    var performed: [MessageID] { lock.withLock { messageIDs } }

    func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        lock.withLock { messageIDs.append(messageID) }
        return InboxMailActionResult(messageID: messageID, action: action)
    }
}
