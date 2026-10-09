import Foundation
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostOperations
import PlainpostTestSupport
@testable import PlainpostUI

@MainActor
final class TemporalUIAdapterTests: XCTestCase {
    func testSyncCompletionSkipsOnlySmartInboxWhenFeatureDisabled() async {
        let client = FakeOperationClient()
        let organizer = SmartInboxSyncCompletionOrganizer(client: client,
            selectedAIProviderID: { "foundation" }, aiGenerationAvailable: { true },
            smartInboxEnabled: { false })
        await organizer.requestIncrementalOrganization()
        XCTAssertTrue(client.incrementalInputs.isEmpty)
    }

    func testSyncCompletionSkipsIncrementalAIWhenGenerationUnavailable() async {
        let client = FakeOperationClient()
        let organizer = SmartInboxSyncCompletionOrganizer(
            client: client,
            selectedAIProviderID: { "foundation" },
            aiGenerationAvailable: { false }
        )

        await organizer.requestIncrementalOrganization()

        XCTAssertTrue(client.incrementalInputs.isEmpty)
    }

    func testSyncCompletionRetainsIncrementalAIWhenGenerationAvailable() async {
        let client = FakeOperationClient()
        let organizer = SmartInboxSyncCompletionOrganizer(
            client: client,
            selectedAIProviderID: { "foundation" },
            aiGenerationAvailable: { true }
        )

        await organizer.requestIncrementalOrganization()

        XCTAssertEqual(client.incrementalInputs.count, 1)
        XCTAssertEqual(client.incrementalInputs.first?.operation, .recategorizeInbox)
        XCTAssertEqual(client.incrementalInputs.first?.smartInboxRunMode, .incremental)
    }

    func testRetainedDirectThreadAssistantRefusesAIAfterNodeHandoff() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-thread-source-fence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let message = MessageSummary(
            id: MessageID("thread_source_fence"), threadID: ThreadID("thread_source_fence"),
            from: account.email, subject: "Source fence", preview: "Private body",
            smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message, metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationEligible: false
        )
        let direct = try store.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let client = FakeOperationClient()
        let assistant = LocalOperationThreadAIAssistantService(
            client: client, store: store, providerID: "deterministic",
            providerName: "Deterministic Local", selectedAccountID: account.id,
            requiresAccountScope: true
        )
        _ = try store.replaceMailSource(
            direct.nodeBacked(
                nodeID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: "imap.example.com"
            ), expectedGeneration: direct.generation
        )

        for operation in 0..<3 {
            do {
                switch operation {
                case 0: _ = try await assistant.summarize(messageID: message.id)
                case 1: _ = try await assistant.answerQuestion(
                    messageID: message.id, question: "What happened?", priorTurns: []
                )
                default: _ = try await assistant.draftReply(messageID: message.id, tone: .neutral, instructions: "")
                }
                XCTFail("A retained Direct adapter submitted thread AI after Node handoff")
            } catch {
                XCTAssertNil(client.lastAIInput)
            }
        }
    }

    func testRetainedDirectAskMailRefusesAIAfterNodeHandoff() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ask-source-fence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let direct = try store.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let client = FakeOperationClient()
        let askMail = LocalOperationAskMailService(
            client: client, store: store, providerID: "deterministic",
            providerName: "Deterministic Local", selectedAccountID: account.id,
            requiresAccountScope: true
        )
        _ = try store.replaceMailSource(
            direct.nodeBacked(
                nodeID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: "imap.example.com"
            ), expectedGeneration: direct.generation
        )

        do {
            _ = try await askMail.ask(
                question: "What happened?", scope: .allMail,
                activeContext: nil, priorTurns: []
            )
            XCTFail("A retained Direct adapter submitted Ask Mail after Node handoff")
        } catch {
            XCTAssertNil(client.lastAIInput)
        }
    }

    func testInFlightThreadAndAskMailRefuseResultsAfterDirectNodeDirectTransition() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-inflight-source-fence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let message = MessageSummary(
            id: MessageID("inflight_source_fence"), threadID: ThreadID("inflight_source_fence"),
            from: account.email, subject: "In-flight source fence", preview: "Private body",
            smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message, metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationEligible: false
        )
        let direct = try store.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let threadGate = AICompletionGate()
        let askGate = AICompletionGate()
        let threadArtifactID = "inflight-thread-artifact"
        let askArtifactID = "inflight-ask-artifact"
        let threadInput = PlainpostAIOperationInput(
            operation: .summarizeThread, recordID: message.id.rawValue,
            conversationReferenceKind: .message, accountID: account.id,
            providerID: "deterministic"
        )
        let askInput = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox",
            accountID: account.id, providerID: "deterministic", retrievalScope: .allMail
        )
        let artifactPayload = String(
            decoding: try JSONEncoder().encode(PlainpostLocalAIArtifactPayload(
                text: "Stale Direct answer", modelID: "deterministic-local",
                resultRecordID: message.id.rawValue
            )), as: UTF8.self
        )
        for (id, input) in [(threadArtifactID, threadInput), (askArtifactID, askInput)] {
            try store.saveTypedAIOperationArtifact(
                DurableOperationArtifact(
                    id: id, kind: input.operation.rawValue,
                    recordID: input.recordID, payloadJSON: artifactPayload
                ), input: input
            )
        }
        let threadAssistant = LocalOperationThreadAIAssistantService(
            client: FakeOperationClient(aiArtifactID: threadArtifactID, completionGate: threadGate), store: store,
            providerID: "deterministic", providerName: "Deterministic Local",
            selectedAccountID: account.id, requiresAccountScope: true
        )
        let askMail = LocalOperationAskMailService(
            client: FakeOperationClient(aiArtifactID: askArtifactID, completionGate: askGate), store: store,
            providerID: "deterministic", providerName: "Deterministic Local",
            selectedAccountID: account.id, requiresAccountScope: true
        )
        let summaryTask = Task { try await threadAssistant.summarize(messageID: message.id) }
        let answerTask = Task {
            try await askMail.ask(question: "What happened?", scope: .allMail,
                                  activeContext: nil, priorTurns: [])
        }
        await threadGate.waitUntilEntered()
        await askGate.waitUntilEntered()
        let node = try store.replaceMailSource(
            direct.nodeBacked(
                nodeID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: "imap.example.com"
            ), expectedGeneration: direct.generation
        )
        _ = try store.replaceMailSource(node.revertedToDirect(), expectedGeneration: node.generation)
        await threadGate.release()
        await askGate.release()

        do {
            _ = try await summaryTask.value
            XCTFail("In-flight thread AI displayed a result from an earlier source generation")
        } catch PlainpostError.permissionDenied {
            // The retained adapter must reject even after Direct is restored.
        }
        do {
            _ = try await answerTask.value
            XCTFail("In-flight Ask Mail displayed a result from an earlier source generation")
        } catch PlainpostError.permissionDenied {
            // The retained adapter must reject even after Direct is restored.
        }
    }

    func testThreadAssistantScopesRequestsContextArtifactsAndDraftsToSelectedAccount() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-thread-account-scope-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let selected = PlainpostFixtures.personalAccount
        let foreign = Account(
            id: AccountID("thread_foreign"), displayName: "Foreign",
            email: EmailAddress("foreign@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([selected, foreign])
        _ = try store.replaceMailSource(
            AccountMailSource(
                accountID: selected.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let ownMessage = MessageSummary(
            id: MessageID("thread_own_message"), threadID: ThreadID("thr_uid_own"),
            from: EmailAddress("alice@example.com"), subject: "Shared subject",
            preview: "Own account context", smartCategory: .personal
        )
        let foreignMessage = MessageSummary(
            id: MessageID("thread_foreign_message"), threadID: ThreadID("thr_uid_foreign"),
            from: EmailAddress("alice@example.com"), subject: "Re: Shared subject",
            preview: "Foreign account context", smartCategory: .personal
        )
        for (message, accountID) in [(ownMessage, selected.id), (foreignMessage, foreign.id)] {
            _ = try store.commitIncomingMessage(
                message,
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: accountID, mailboxPath: "INBOX", uidValidity: 1,
                uid: accountID == selected.id ? 1 : 2, notificationEligible: false
            )
        }
        let ownInput = PlainpostAIOperationInput(
            operation: .summarizeThread, recordID: ownMessage.id.rawValue,
            conversationReferenceKind: .message, accountID: selected.id,
            providerID: "deterministic"
        )
        let foreignInput = PlainpostAIOperationInput(
            operation: .summarizeThread, recordID: foreignMessage.id.rawValue,
            conversationReferenceKind: .message, accountID: foreign.id,
            providerID: "deterministic"
        )
        func artifact(_ id: String, input: PlainpostAIOperationInput, draftID: String? = nil) throws {
            let payload = PlainpostLocalAIArtifactPayload(
                text: "Scoped result", modelID: "deterministic-local",
                resultRecordID: draftID ?? input.recordID
            )
            try store.saveTypedAIOperationArtifact(
                DurableOperationArtifact(
                    id: id, kind: input.operation.rawValue, recordID: input.recordID,
                    payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                ),
                input: input
            )
        }
        try artifact("own_thread_artifact", input: ownInput)
        try artifact("foreign_thread_artifact", input: foreignInput)
        let client = FakeOperationClient(aiArtifactID: "own_thread_artifact")
        let assistant = LocalOperationThreadAIAssistantService(
            client: client, store: store, providerID: "deterministic",
            providerName: "Deterministic Local", selectedAccountID: selected.id,
            requiresAccountScope: true
        )

        for operation in 0..<3 {
            do {
                switch operation {
                case 0: _ = try await assistant.summarize(messageID: foreignMessage.id)
                case 1: _ = try await assistant.answerQuestion(
                    messageID: foreignMessage.id, question: "Foreign?", priorTurns: [])
                default: _ = try await assistant.draftReply(messageID: foreignMessage.id, tone: .neutral, instructions: "")
                }
                XCTFail("Foreign message must be rejected before AI execution")
            } catch {
                XCTAssertTrue(error is PlainpostError)
            }
            XCTAssertNil(client.lastAIInput)
        }

        let summary = try await assistant.summarize(messageID: ownMessage.id)
        XCTAssertEqual(summary.contextMessageIDs, [ownMessage.id.rawValue])
        XCTAssertEqual(client.lastAIInput?.accountID, selected.id)
        XCTAssertEqual(client.lastAIInput?.expectedDirectSourceGeneration, 1)
        XCTAssertEqual(client.lastAIInput?.recordID, ownMessage.id.rawValue)

        let answerInput = PlainpostAIOperationInput(
            operation: .answerThreadQuestion, recordID: ownMessage.id.rawValue,
            conversationReferenceKind: .message, accountID: selected.id,
            providerID: "deterministic", question: "Own?"
        )
        try artifact("own_answer_artifact", input: answerInput)
        client.aiArtifactID = "own_answer_artifact"
        let answer = try await assistant.answerQuestion(
            messageID: ownMessage.id, question: "Own?", priorTurns: [])
        XCTAssertEqual(answer.answer, "Scoped result")
        XCTAssertEqual(client.lastAIInput?.accountID, selected.id)

        client.aiArtifactID = "foreign_thread_artifact"
        do {
            _ = try await assistant.answerQuestion(
                messageID: ownMessage.id, question: "Own?", priorTurns: [])
            XCTFail("Foreign artifact must be rejected")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }

        let ownDraft = try store.createDraft(
            Draft(
                id: DraftID("own_ai_draft"), accountID: selected.id,
                from: selected.email, to: [EmailAddress("alice@example.com")],
                cc: [], bcc: [],
                subject: "Re: Shared subject", bodyPlain: "Own reply",
                createdBy: "test", aiGenerated: true, sourceThreadID: nil
            ),
            actor: PlainpostFixtures.codexActor
        )
        let draftInput = PlainpostAIOperationInput(
            operation: .draftReply, recordID: ownMessage.id.rawValue,
            conversationReferenceKind: .message, accountID: selected.id,
            providerID: "deterministic"
        )
        try artifact("own_draft_artifact", input: draftInput, draftID: ownDraft.id.rawValue)
        client.aiArtifactID = "own_draft_artifact"
        let resultDraft = try await assistant.draftReply(
            messageID: ownMessage.id, tone: .formal, instructions: "Confirm Friday"
        )
        XCTAssertEqual(resultDraft.id, ownDraft.id)
        XCTAssertEqual(resultDraft.accountID, selected.id)
        XCTAssertEqual(client.lastAIInput?.accountID, selected.id)
        XCTAssertEqual(client.lastAIInput?.question, "Confirm Friday")
        XCTAssertEqual(client.lastAIInput?.draftTone, "formal")

        let missingScopeClient = FakeOperationClient(aiArtifactID: "own_thread_artifact")
        let missingScopeAssistant = LocalOperationThreadAIAssistantService(
            client: missingScopeClient, store: store, providerID: "deterministic",
            providerName: "Deterministic Local", requiresAccountScope: true
        )
        do {
            _ = try await missingScopeAssistant.summarize(messageID: ownMessage.id)
            XCTFail("iOS thread AI must require a selected account")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
        XCTAssertNil(missingScopeClient.lastAIInput)
    }

    func testLocalOperationSummaryReadsGeneratedTextFromLocalArtifactStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-local-operation-ui-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try store.cacheThread(MailThread(
            id: ThreadID("thr_ui"),
            accountID: PlainpostFixtures.personalAccount.id,
            subjectNormalized: "local operation summary",
            participantEmails: []
        ))
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_ui_first"),
                threadID: ThreadID("thr_ui"),
                from: EmailAddress("alice@example.com"),
                subject: "Local operation summary",
                preview: "Please review the first message.",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 1)
            )
        )
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_ui_second"),
                threadID: ThreadID("thr_ui"),
                from: EmailAddress("bob@example.com"),
                subject: "Re: Local operation summary",
                preview: "This is the second message.",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 2)
            )
        )
        let payload = PlainpostLocalAIArtifactPayload(
            text: "Durable local summary",
            items: ["Reply tomorrow"],
            modelID: "deterministic-local",
            resultRecordID: "thr_ui"
        )
        let input = PlainpostAIOperationInput(
            operation: .summarizeThread,
            recordID: "thr_ui",
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: "deterministic"
        )
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "tai_ui",
                kind: PlainpostAIOperationKind.summarizeThread.rawValue,
                recordID: input.recordID,
                payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            ),
            input: input
        )
        let client = FakeOperationClient(aiArtifactID: "tai_ui")
        let assistant = LocalOperationThreadAIAssistantService(
            client: client,
            store: store,
            providerID: "deterministic",
            providerName: "Deterministic Local"
        )

        let result = try await assistant.summarize(messageID: MessageID("msg_ui_second"))

        XCTAssertEqual(result.summaryText, "Durable local summary")
        XCTAssertEqual(result.modelID, "deterministic-local")
        XCTAssertEqual(result.contextMessageIDs, ["msg_ui_first", "msg_ui_second"])
        XCTAssertEqual(client.lastAIInput?.operation, .summarizeThread)
        XCTAssertEqual(client.lastAIInput?.recordID, "thr_ui")

        let answer = try await assistant.answerQuestion(
            messageID: MessageID("msg_ui_second"),
            question: "What changed?",
            priorTurns: [
                ThreadAIAssistantChatTurn(
                    id: "turn_1",
                    question: "Who replied?",
                    answer: "Bob replied."
                )
            ]
        )

        XCTAssertEqual(answer.answer, "Durable local summary")
        XCTAssertEqual(client.lastAIInput?.operation, .answerThreadQuestion)
        XCTAssertEqual(client.lastAIInput?.question, "What changed?")
        XCTAssertEqual(
            client.lastAIInput?.conversation,
            [PlainpostAIConversationTurn(question: "Who replied?", answer: "Bob replied.")]
        )
    }

    func testThreadAssistantUsesMessageReferenceForUnthreadedConversation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-unthreaded-operation-ui-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let message = MessageSummary(
            id: MessageID("msg_ui_unthreaded"), threadID: nil,
            from: EmailAddress("alice@example.com"), subject: "Unthreaded",
            preview: "One message", smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 77,
            notificationEligible: false
        )
        let storedInput = PlainpostAIOperationInput(
            operation: .summarizeThread,
            recordID: message.id.rawValue,
            conversationReferenceKind: .message,
            accountID: account.id,
            providerID: "deterministic"
        )
        let payload = PlainpostLocalAIArtifactPayload(
            text: "Unthreaded result", modelID: "deterministic-local",
            resultRecordID: message.id.rawValue
        )
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "tai_ui_unthreaded",
                kind: storedInput.operation.rawValue,
                recordID: storedInput.recordID,
                payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            ),
            input: storedInput
        )
        let client = FakeOperationClient(aiArtifactID: "tai_ui_unthreaded")
        let assistant = LocalOperationThreadAIAssistantService(
            client: client, store: store,
            providerID: "deterministic", providerName: "Deterministic Local"
        )

        _ = try await assistant.summarize(messageID: message.id)
        XCTAssertEqual(client.lastAIInput?.recordID, message.id.rawValue)
        XCTAssertEqual(client.lastAIInput?.conversationReferenceKind, .message)

        _ = try await assistant.answerQuestion(
            messageID: message.id, question: "What happened?", priorTurns: []
        )
        XCTAssertEqual(client.lastAIInput?.recordID, message.id.rawValue)
        XCTAssertEqual(client.lastAIInput?.conversationReferenceKind, .message)

        do {
            _ = try await assistant.draftReply(messageID: message.id, tone: .neutral, instructions: "")
            XCTFail("Expected the fixture artifact to reference no stored draft.")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
        XCTAssertEqual(client.lastAIInput?.recordID, message.id.rawValue)
        XCTAssertEqual(client.lastAIInput?.conversationReferenceKind, .message)

        let legacy = MessageSummary(
            id: MessageID("msg_ui_legacy_thread"),
            threadID: ThreadID("thr_uid_INBOX_1_78"),
            from: EmailAddress("bob@example.com"), subject: "Legacy subject",
            preview: "Legacy message", smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            legacy,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 78,
            notificationEligible: false
        )

        _ = try await assistant.summarize(messageID: legacy.id)
        XCTAssertEqual(client.lastAIInput?.recordID, legacy.id.rawValue)
        XCTAssertEqual(client.lastAIInput?.conversationReferenceKind, .message)
        _ = try await assistant.answerQuestion(
            messageID: legacy.id, question: "What is legacy?", priorTurns: []
        )
        XCTAssertEqual(client.lastAIInput?.recordID, legacy.id.rawValue)
        XCTAssertEqual(client.lastAIInput?.conversationReferenceKind, .message)
        do {
            _ = try await assistant.draftReply(messageID: legacy.id, tone: .neutral, instructions: "")
            XCTFail("Expected the fixture artifact to reference no stored draft.")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
        XCTAssertEqual(client.lastAIInput?.recordID, legacy.id.rawValue)
        XCTAssertEqual(client.lastAIInput?.conversationReferenceKind, .message)
    }

    func testAskMailAdapterReadsStructuredSourcesAndForwardsScope() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ask-mail-adapter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let selectedAccountID = AccountID("ask_selected")
        let foreignAccountID = AccountID("ask_foreign")
        try store.cacheAccounts([
            Account(id: selectedAccountID, displayName: "Selected",
                    email: EmailAddress("selected@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com"),
            Account(id: foreignAccountID, displayName: "Foreign",
                    email: EmailAddress("foreign@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com"),
        ])
        _ = try store.replaceMailSource(
            AccountMailSource(
                accountID: selectedAccountID, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        _ = try store.commitIncomingMessage(
            MessageSummary(id: MessageID("msg_source"), threadID: ThreadID("thr_source"),
                           from: EmailAddress("alice@example.com"), subject: "Archived source",
                           preview: "The archived evidence.", smartCategory: .personal),
            metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: selectedAccountID, mailboxPath: "Archive", uidValidity: 1, uid: 1,
            notificationEligible: false)
        let source = MailKnowledgeSource(
            id: "S1",
            messageID: MessageID("msg_source"),
            conversationKey: "thr_source",
            mailboxPath: "Archive",
            subject: "Archived source",
            sender: "Alice",
            sentAt: Date(timeIntervalSince1970: 10),
            snippet: "The archived evidence."
        )
        let payload = PlainpostLocalAIArtifactPayload(
            text: "The answer is in the archive. [S1]",
            modelID: "local-model",
            sources: [source],
            insufficientEvidence: false,
            retrievalMode: "lexical"
        )
        let input = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion,
            recordID: "mailbox",
            accountID: selectedAccountID,
            providerID: "foundation",
            retrievalScope: .allMail
        )
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "ai_ask_adapter",
                kind: PlainpostAIOperationKind.answerMailboxQuestion.rawValue,
                recordID: "mailbox",
                payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            ),
            input: input
        )
        let client = FakeOperationClient(aiArtifactID: "ai_ask_adapter")
        let service = LocalOperationAskMailService(
            client: client,
            store: store,
            providerID: "foundation",
            providerName: "Apple Foundation Models",
            selectedAccountID: selectedAccountID,
            requiresAccountScope: true
        )
        let context = AskMailActiveContext(
            conversationKey: "thr_active",
            subject: "Active",
            messageIDs: [MessageID("msg_active")]
        )

        let result = try await service.ask(
            question: "Where is the answer?",
            scope: .activeConversation,
            activeContext: context,
            priorTurns: [
                AskMailTurn(question: "Old account", answer: AskMailAnswer(
                    text: "Foreign fact [1]",
                    citations: [AskMailCitation(number: 1, source: MailKnowledgeSource(
                        id: "S1", messageID: MessageID("foreign"),
                        conversationKey: "foreign", mailboxPath: "INBOX",
                        subject: "Foreign", sender: "Other", sentAt: nil, snippet: "Secret"))]
                )),
                AskMailTurn(question: "Selected account", answer: AskMailAnswer(
                    text: "Selected fact [1]",
                    citations: [AskMailCitation(number: 1, source: source)]
                )),
            ]
        )

        XCTAssertEqual(result.sources, [source])
        XCTAssertEqual(client.lastAIInput?.operation, .answerMailboxQuestion)
        XCTAssertEqual(client.lastAIInput?.retrievalScope, .activeConversation)
        XCTAssertEqual(client.lastAIInput?.activeConversationKey, "thr_active")
        XCTAssertEqual(client.lastAIInput?.accountID, selectedAccountID)
        XCTAssertEqual(client.lastAIInput?.conversation.map(\.question), ["Selected account"])

        let unselectedService = LocalOperationAskMailService(
            client: FakeOperationClient(aiArtifactID: "ai_ask_adapter"), store: store,
            providerID: "foundation", providerName: "Apple Foundation Models",
            requiresAccountScope: true)
        do {
            _ = try await unselectedService.ask(question: "What happened?", scope: .allMail,
                                                activeContext: nil, priorTurns: [])
            XCTFail("Direct Ask Mail ran without a selected account")
        } catch PlainpostError.permissionDenied {
            // Direct iPhone Ask Mail must bind an account before enqueuing.
        }

        let foreignSource = MailKnowledgeSource(
            id: "S1", messageID: MessageID("foreign"), conversationKey: "thr_foreign",
            mailboxPath: "INBOX", subject: "Foreign", sender: "Other", sentAt: nil,
            snippet: "Another account's mail")
        let foreignPayload = PlainpostLocalAIArtifactPayload(
            text: "Foreign answer [S1]", modelID: "local-model", sources: [foreignSource],
            insufficientEvidence: false, retrievalMode: "lexical")
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "ai_ask_adapter_foreign", kind: PlainpostAIOperationKind.answerMailboxQuestion.rawValue,
                recordID: "mailbox",
                payloadJSON: String(decoding: try JSONEncoder().encode(foreignPayload), as: UTF8.self)
            ), input: input)
        let foreignService = LocalOperationAskMailService(
            client: FakeOperationClient(aiArtifactID: "ai_ask_adapter_foreign"), store: store,
            providerID: "foundation", providerName: "Apple Foundation Models",
            selectedAccountID: selectedAccountID, requiresAccountScope: true)
        do {
            _ = try await foreignService.ask(question: "What happened?", scope: .allMail,
                                             activeContext: nil, priorTurns: [])
            XCTFail("A foreign artifact source was exposed")
        } catch PlainpostError.permissionDenied {
            // The local artifact remains bounded to the selected account.
        }

        let sourceFreeForeignPayload = PlainpostLocalAIArtifactPayload(
            text: "Foreign account secret", modelID: "local-model", sources: [],
            insufficientEvidence: false, retrievalMode: "lexical")
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "ai_ask_adapter_foreign_owner",
                kind: PlainpostAIOperationKind.answerMailboxQuestion.rawValue,
                recordID: "mailbox",
                payloadJSON: String(decoding: try JSONEncoder().encode(sourceFreeForeignPayload), as: UTF8.self)
            ),
            input: PlainpostAIOperationInput(
                operation: .answerMailboxQuestion, recordID: "mailbox",
                accountID: foreignAccountID, providerID: "foundation", retrievalScope: .allMail)
        )
        let foreignOwnerService = LocalOperationAskMailService(
            client: FakeOperationClient(aiArtifactID: "ai_ask_adapter_foreign_owner"), store: store,
            providerID: "foundation", providerName: "Apple Foundation Models",
            selectedAccountID: selectedAccountID, requiresAccountScope: true)
        do {
            _ = try await foreignOwnerService.ask(question: "What happened?", scope: .allMail,
                                                  activeContext: nil, priorTurns: [])
            XCTFail("A source-free artifact from another account was exposed")
        } catch PlainpostError.permissionDenied {
            // Artifact ownership is checked before source validation.
        }

        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "ai_ask_adapter_wrong_record",
                kind: PlainpostAIOperationKind.answerMailboxQuestion.rawValue,
                recordID: "other-mailbox",
                payloadJSON: String(decoding: try JSONEncoder().encode(sourceFreeForeignPayload), as: UTF8.self)
            ),
            input: PlainpostAIOperationInput(
                operation: .answerMailboxQuestion, recordID: "other-mailbox",
                accountID: selectedAccountID, providerID: "foundation", retrievalScope: .allMail)
        )
        let wrongRecordService = LocalOperationAskMailService(
            client: FakeOperationClient(aiArtifactID: "ai_ask_adapter_wrong_record"), store: store,
            providerID: "foundation", providerName: "Apple Foundation Models",
            selectedAccountID: selectedAccountID, requiresAccountScope: true)
        do {
            _ = try await wrongRecordService.ask(question: "What happened?", scope: .allMail,
                                                 activeContext: nil, priorTurns: [])
            XCTFail("A different AI operation artifact was presented as a mailbox answer")
        } catch PlainpostError.validationFailed {
            // The result must match the requested mailbox answer operation.
        }
    }

    func testForeignRowIDsAreRejected() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ask-mail-foreign-rows-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let selectedAccountID = AccountID("ask_rows_selected")
        try store.cacheAccounts([
            Account(id: selectedAccountID, displayName: "Selected",
                    email: EmailAddress("selected@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com"),
        ])
        let foreignRow = AskMailMessageRow(
            messageID: MessageID("foreign_row"), conversationKey: "thr_foreign", mailboxPath: "INBOX",
            sender: "Other", senderAddress: "other@example.com", subject: "Foreign", snippet: "Not yours",
            sentAt: nil, isUnread: false, tag: nil)
        let listBlock = AskMailMessageListBlock(
            id: "list", title: "Unread", icon: .tray, tint: .blue,
            sections: [AskMailMessageSection(id: "s1", title: "Unread", tint: .blue, totalCount: 1,
                                             summary: "1 message", rows: [foreignRow],
                                             actionMessageIDs: [foreignRow.messageID])],
            bulkActions: [], rowAction: nil)
        let answer = AskMailAnswer(text: "Found **1** message.", blocks: [.messages(listBlock)])
        let payload = PlainpostLocalAIArtifactPayload(
            text: answer.text, modelID: "local-model", sources: [], insufficientEvidence: false,
            retrievalMode: "lexical", askMailAnswer: answer)
        let input = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox", accountID: selectedAccountID,
            providerID: "foundation", retrievalScope: .allMail)
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "ai_ask_adapter_foreign_rows",
                kind: PlainpostAIOperationKind.answerMailboxQuestion.rawValue,
                recordID: "mailbox",
                payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            ),
            input: input
        )
        let service = LocalOperationAskMailService(
            client: FakeOperationClient(aiArtifactID: "ai_ask_adapter_foreign_rows"), store: store,
            providerID: "foundation", providerName: "Apple Foundation Models",
            selectedAccountID: selectedAccountID, requiresAccountScope: true)
        do {
            _ = try await service.ask(question: "What's unread?", scope: .allMail,
                                      activeContext: nil, priorTurns: [])
            XCTFail("An answer referencing another account's message row was exposed")
        } catch PlainpostError.permissionDenied {
            // Block-level message IDs are checked against the current account's ownership.
        }
    }

    func testTranslationAdapterReturnsValidatedCacheWithoutEnqueuingOperation() async throws {
        let fixture = try TranslationAdapterFixture()
        defer { fixture.removeStore() }
        let translation = fixture.cachedTranslation(translatedBody: "Bonjour")
        XCTAssertEqual(
            try fixture.store.compareAndSaveCachedTranslation(
                translation,
                expectedSourceFingerprint: translation.sourceFingerprint
            ),
            .saved
        )
        let client = TranslationOperationClient(store: fixture.store)
        let service = LocalOperationThreadTranslationService(
            client: client,
            store: fixture.store,
            provider: fixture.provider
        )

        let cached = try service.cachedTranslation(
            messageID: fixture.message.id,
            targetLanguageID: "fr"
        )
        let translated = try await service.translate(
            messageID: fixture.message.id,
            targetLanguageID: "fr",
            targetLanguageName: "French"
        )

        XCTAssertEqual(cached?.renderedBody.safeText, "Bonjour")
        XCTAssertEqual(translated.renderedBody.safeText, "Bonjour")
        XCTAssertTrue(translated.wasCached)
        XCTAssertEqual(client.executeAICallCount, 0)
    }

    func testSelectedAccountTranslationRejectsForeignCacheAndOperation() async throws {
        let fixture = try TranslationAdapterFixture()
        defer { fixture.removeStore() }
        let selected = PlainpostFixtures.personalAccount
        _ = try fixture.store.replaceMailSource(
            AccountMailSource(accountID: selected.id, kind: .direct, mode: nil,
                              nodeID: nil, logicalMailboxID: nil,
                              providerIdentity: nil, generation: 1),
            expectedGeneration: 0
        )
        let foreign = Account(
            id: AccountID("acc_translation_foreign"), displayName: "Foreign",
            email: EmailAddress("foreign@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try fixture.store.cacheAccounts([foreign])
        let foreignThread = ThreadID("thr_translation_foreign")
        try fixture.store.cacheThread(MailThread(
            id: foreignThread, accountID: foreign.id,
            subjectNormalized: "foreign translation", participantEmails: []
        ))
        let foreignMessage = MessageSummary(
            id: MessageID("msg_translation_foreign"), threadID: foreignThread,
            from: foreign.email, subject: "Foreign translation",
            preview: "Private", body: "Private body", smartCategory: .personal
        )
        try fixture.store.cacheMessage(foreignMessage)
        let foreignTranslation = CachedMessageTranslation(
            messageID: foreignMessage.id, targetLanguageID: "fr",
            sourceFingerprint: MailTranslationFingerprint.message(foreignMessage),
            providerID: fixture.provider.id, modelID: fixture.provider.chatModelID,
            contractVersion: MailTranslationContract.version, bodyKind: .plainText,
            translatedBody: "Privé", createdAt: Date(), updatedAt: Date()
        )
        XCTAssertEqual(
            try fixture.store.compareAndSaveCachedTranslation(
                foreignTranslation, expectedSourceFingerprint: foreignTranslation.sourceFingerprint
            ),
            .saved
        )
        let client = TranslationOperationClient(store: fixture.store)
        let service = LocalOperationThreadTranslationService(
            client: client, store: fixture.store, provider: fixture.provider,
            selectedAccountID: selected.id, requiresAccountScope: true
        )

        XCTAssertThrowsError(try service.cachedTranslation(
            messageID: foreignMessage.id, targetLanguageID: "fr"
        ))
        do {
            _ = try await service.translate(
                messageID: foreignMessage.id, targetLanguageID: "fr", targetLanguageName: "French"
            )
            XCTFail("Translation read another account's cached message")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
        XCTAssertEqual(client.executeAICallCount, 0)
        let foreignUncached = MessageSummary(
            id: MessageID("msg_translation_foreign_uncached"), threadID: foreignThread,
            from: foreign.email, subject: "Foreign translation",
            preview: "Also private", body: "Another private body", smartCategory: .personal
        )
        try fixture.store.cacheMessage(foreignUncached)
        XCTAssertThrowsError(try service.cachedTranslation(
            messageID: foreignUncached.id, targetLanguageID: "fr"
        ))
        do {
            _ = try await service.translate(
                messageID: foreignUncached.id, targetLanguageID: "fr", targetLanguageName: "French"
            )
            XCTFail("Translation sent another account's message to AI")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
        XCTAssertEqual(client.executeAICallCount, 0)
        XCTAssertNil(try service.cachedTranslation(messageID: fixture.message.id, targetLanguageID: "fr"))
        let unselected = LocalOperationThreadTranslationService(
            client: client, store: fixture.store, provider: fixture.provider,
            selectedAccountID: nil, requiresAccountScope: true
        )
        XCTAssertThrowsError(try unselected.cachedTranslation(
            messageID: fixture.message.id, targetLanguageID: "fr"
        ))
    }

    func testRetainedDirectTranslationRejectsRestoredSourceGeneration() async throws {
        let fixture = try TranslationAdapterFixture()
        defer { fixture.removeStore() }
        let accountID = PlainpostFixtures.personalAccount.id
        let direct = try fixture.store.replaceMailSource(
            AccountMailSource(
                accountID: accountID, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let client = TranslationOperationClient(store: fixture.store)
        let translation = LocalOperationThreadTranslationService(
            client: client, store: fixture.store, provider: fixture.provider,
            selectedAccountID: accountID, requiresAccountScope: true
        )
        let node = try fixture.store.replaceMailSource(
            direct.nodeBacked(
                nodeID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: "imap.example.com"
            ), expectedGeneration: direct.generation
        )
        _ = try fixture.store.replaceMailSource(
            node.revertedToDirect(), expectedGeneration: node.generation
        )

        XCTAssertThrowsError(try translation.cachedTranslation(
            messageID: fixture.message.id, targetLanguageID: "fr"
        ))
        do {
            _ = try await translation.translate(
                messageID: fixture.message.id,
                targetLanguageID: "fr", targetLanguageName: "French"
            )
            XCTFail("A retained Direct translation submitted AI after source handoff")
        } catch {
            XCTAssertEqual(client.executeAICallCount, 0)
        }
    }

    func testTranslationAdapterSubmitsOperationThenReturnsFreshlyValidatedCache() async throws {
        let fixture = try TranslationAdapterFixture()
        defer { fixture.removeStore() }
        let client = TranslationOperationClient(
            store: fixture.store,
            cachedTranslation: fixture.cachedTranslation(translatedBody: "Bonjour"),
            artifactPayloadJSON: fixture.artifactPayloadJSON(translatedBody: "Bonjour")
        )
        let service = LocalOperationThreadTranslationService(
            client: client,
            store: fixture.store,
            provider: fixture.provider
        )

        let result = try await service.translate(
            messageID: fixture.message.id,
            targetLanguageID: "fr",
            targetLanguageName: "French"
        )

        XCTAssertEqual(result.renderedBody.safeText, "Bonjour")
        XCTAssertTrue(result.wasCached)
        XCTAssertEqual(client.executeAICallCount, 1)
        XCTAssertEqual(client.lastAIInput?.operation, .translateMessage)
        XCTAssertEqual(client.lastAIInput?.recordID, fixture.message.id.rawValue)
        XCTAssertEqual(client.lastAIInput?.providerID, fixture.provider.id)
        XCTAssertEqual(client.lastAIInput?.modelID, fixture.provider.chatModelID)
        XCTAssertEqual(client.lastAIInput?.targetLanguageIdentifier, "fr")
        XCTAssertEqual(client.lastAIInput?.targetLanguageName, "French")
    }

    func testTranslationAdapterRejectsMalformedOperationArtifactBeforeReturningCache() async throws {
        let fixture = try TranslationAdapterFixture()
        defer { fixture.removeStore() }
        let client = TranslationOperationClient(
            store: fixture.store,
            cachedTranslation: fixture.cachedTranslation(translatedBody: "Bonjour"),
            artifactPayloadJSON: "{malformed"
        )
        let service = LocalOperationThreadTranslationService(
            client: client,
            store: fixture.store,
            provider: fixture.provider
        )

        do {
            _ = try await service.translate(
                messageID: fixture.message.id,
                targetLanguageID: "fr",
                targetLanguageName: "French"
            )
            XCTFail("Expected malformed operation artifact to fail")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
    }
}

private final class FakeOperationClient: PlainpostOperationClientProtocol, @unchecked Sendable {
    var aiArtifactID: String
    private(set) var lastAIInput: PlainpostAIOperationInput?
    private(set) var incrementalInputs: [PlainpostAIOperationInput] = []
    private let completionGate: AICompletionGate?

    init(aiArtifactID: String = "tai_fake", completionGate: AICompletionGate? = nil) {
        self.aiArtifactID = aiArtifactID
        self.completionGate = completionGate
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        PlainpostInboxSyncResult(accountID: input.accountID, syncedMessageCount: 3, jobID: "job_fake")
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        lastAIInput = input
        await completionGate?.pauseBeforeCompletion()
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: aiArtifactID,
            jobID: "job_fake"
        )
    }

    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        incrementalInputs.append(input)
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {}
    func denySend(requestID: SendRequestID, deniedBy: String) async throws {}
}

private actor AICompletionGate {
    private var didEnter = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseBeforeCompletion() async {
        didEnter = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class TranslationOperationClient: PlainpostOperationClientProtocol, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let cachedTranslation: CachedMessageTranslation?
    private let artifactPayloadJSON: String?
    private(set) var executeAICallCount = 0
    private(set) var lastAIInput: PlainpostAIOperationInput?

    init(
        store: SQLiteMailStore,
        cachedTranslation: CachedMessageTranslation? = nil,
        artifactPayloadJSON: String? = nil
    ) {
        self.store = store
        self.cachedTranslation = cachedTranslation
        self.artifactPayloadJSON = artifactPayloadJSON
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        PlainpostInboxSyncResult(accountID: input.accountID, syncedMessageCount: 0, jobID: "unused")
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        executeAICallCount += 1
        lastAIInput = input
        if let cachedTranslation {
            _ = try store.compareAndSaveCachedTranslation(
                cachedTranslation,
                expectedSourceFingerprint: cachedTranslation.sourceFingerprint
            )
        }
        if let artifactPayloadJSON {
            try store.saveTypedAIOperationArtifact(
                DurableOperationArtifact(
                    id: "translation-artifact",
                    kind: PlainpostAIOperationKind.translateMessage.rawValue,
                    recordID: input.recordID,
                    payloadJSON: artifactPayloadJSON
                ),
                input: input
            )
        }
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: "translation-artifact",
            jobID: "translation-job"
        )
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {}
    func denySend(requestID: SendRequestID, deniedBy: String) async throws {}
}

private final class TranslationAdapterFixture {
    let url: URL
    let store: SQLiteMailStore
    let provider = DeterministicAIProvider()
    let message: MessageSummary

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-translation-adapter-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        message = MessageSummary(
            id: MessageID("msg_translation_adapter"),
            threadID: ThreadID("thr_translation_adapter"),
            from: EmailAddress("sender@example.com"),
            subject: "Translate this",
            preview: "Bonjour",
            body: "Hallo",
            smartCategory: .personal
        )
        try store.cacheMessage(message)
        try store.cacheThread(MailThread(
            id: ThreadID("thr_translation_adapter"),
            accountID: PlainpostFixtures.personalAccount.id,
            subjectNormalized: "translate this",
            participantEmails: []
        ))
    }

    func cachedTranslation(translatedBody: String) -> CachedMessageTranslation {
        CachedMessageTranslation(
            messageID: message.id,
            targetLanguageID: "fr",
            sourceFingerprint: MailTranslationFingerprint.message(message),
            providerID: provider.id,
            modelID: provider.chatModelID,
            contractVersion: MailTranslationContract.version,
            bodyKind: .plainText,
            translatedBody: translatedBody,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    func artifactPayloadJSON(translatedBody: String) -> String {
        let payload = PlainpostLocalAIArtifactPayload(
            modelID: provider.chatModelID,
            resultRecordID: message.id.rawValue,
            translatedBodyKind: EmailBodyKind.plainText.rawValue,
            translatedBody: translatedBody,
            sourceFingerprint: MailTranslationFingerprint.message(message)
        )
        return String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)
    }

    func removeStore() {
        try? FileManager.default.removeItem(at: url)
    }
}
