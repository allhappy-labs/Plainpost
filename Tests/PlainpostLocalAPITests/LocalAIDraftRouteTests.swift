import Foundation
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostLocalAPI
@testable import PlainpostLocalServer
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets

final class LocalAIDraftRouteTests: XCTestCase {
    func testDurableAIDraftsForSameSourceKeepDistinctOperationOutputs() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-distinct-outputs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("account-1"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        try store.cacheThread(MailThread(
            id: ThreadID("thread-1"),
            accountID: account.id,
            subjectNormalized: "Status",
            participantEmails: [account.email, EmailAddress("team@example.com")]
        ))
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("m-1"),
            threadID: ThreadID("thread-1"),
            from: EmailAddress("team@example.com"),
            subject: "Status",
            preview: "Can you confirm?",
            body: "Can you confirm Friday?",
            smartCategory: .personal
        ))
        let provider = PromptRecordingAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )
        let client = LocalOperationClient(runtime: runtime)

        async let firstResult = client.executeAI(PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "thread-1",
            conversationReferenceKind: .thread,
            accountID: account.id,
            providerID: provider.id,
            question: "First operation"
        ))
        async let secondResult = client.executeAI(PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "thread-1",
            conversationReferenceKind: .thread,
            accountID: account.id,
            providerID: provider.id,
            question: "Second operation"
        ))
        let (first, second) = try await (firstResult, secondResult)

        let firstPayload = try artifactPayload(id: first.artifactID, store: store)
        let secondPayload = try artifactPayload(id: second.artifactID, store: store)
        let firstDraftID = try XCTUnwrap(firstPayload.resultRecordID)
        let secondDraftID = try XCTUnwrap(secondPayload.resultRecordID)
        XCTAssertNotEqual(firstDraftID, secondDraftID)
        XCTAssertEqual(try store.draft(id: DraftID(firstDraftID)).bodyPlain, "First generated reply.")
        XCTAssertEqual(try store.draft(id: DraftID(secondDraftID)).bodyPlain, "Second generated reply.")
    }

    func testDurableRuntimePassesAIReplyInstructionIntoPrompt() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-instruction-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("account-1"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        try store.cacheThread(MailThread(
            id: ThreadID("thread-1"),
            accountID: account.id,
            subjectNormalized: "Status",
            participantEmails: [account.email, EmailAddress("team@example.com")]
        ))
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("m-1"),
            threadID: ThreadID("thread-1"),
            from: EmailAddress("team@example.com"),
            subject: "Status",
            preview: "Can you confirm?",
            body: "Can you confirm Friday?",
            smartCategory: .personal
        ))
        let provider = PromptRecordingAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )

        _ = try await LocalOperationClient(runtime: runtime).executeAI(PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "thread-1",
            conversationReferenceKind: .thread,
            accountID: account.id,
            providerID: provider.id,
            question: "Confirm Friday"
        ))

        let prompts = await provider.prompts
        XCTAssertTrue(try XCTUnwrap(prompts.last).contains("User instructions: Confirm Friday"))
    }

    func testDurableRuntimePassesTheChosenDraftToneIntoPrompt() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-tone-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("account-1"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        try store.cacheThread(MailThread(
            id: ThreadID("thread-1"),
            accountID: account.id,
            subjectNormalized: "Status",
            participantEmails: [account.email, EmailAddress("team@example.com")]
        ))
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("m-1"),
            threadID: ThreadID("thread-1"),
            from: EmailAddress("team@example.com"),
            subject: "Status",
            preview: "Can you confirm?",
            body: "Can you confirm Friday?",
            smartCategory: .personal
        ))
        let provider = PromptRecordingAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )

        _ = try await LocalOperationClient(runtime: runtime).executeAI(PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "thread-1",
            conversationReferenceKind: .thread,
            accountID: account.id,
            providerID: provider.id,
            question: "Confirm Friday",
            draftTone: "formal"
        ))

        let prompts = await provider.prompts
        let prompt = try XCTUnwrap(prompts.last)
        XCTAssertTrue(prompt.contains("Write an editable formal email reply"), prompt)
        XCTAssertTrue(prompt.contains("User instructions: Confirm Friday"), prompt)
    }

    func testDurableRuntimeDraftsReplyForThreadlessMessageID() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-threadless-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("account-1"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("threadless-message"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Status",
            preview: "Can you confirm?",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Can you confirm Friday?",
            rfcMessageID: "<threadless@example.com>",
            replyTo: EmailAddress("team@example.com"),
            to: [account.email]
        ))
        try store.recordCachedUID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: MessageID("threadless-message")
        )
        let provider = PromptRecordingAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )

        let input = PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "threadless-message",
            conversationReferenceKind: .message,
            accountID: account.id,
            providerID: provider.id,
            question: "Confirm Friday"
        )
        let job = try store.enqueueJob(PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: input.operation.priority,
            maxAttempts: 1,
            idempotencyKey: "threadless-ai-draft"
        ))

        let completed = try await runtime.runUntilTerminal(jobID: job.id)

        let artifact = try store.durableOperationArtifact(id: try XCTUnwrap(completed.resultArtifactID))
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        let generatedID = try XCTUnwrap(payload.resultRecordID)
        let generated = try store.draft(id: DraftID(generatedID))
        XCTAssertEqual(generated.to, [EmailAddress("team@example.com")])
        XCTAssertEqual(generated.bodyPlain, "Friday is confirmed.")
        XCTAssertEqual(generated.inReplyTo, "<threadless@example.com>")
        XCTAssertTrue(generated.aiGenerated)
    }

    func testDurableRuntimeUsesMailboxMembershipForThreadlessMultiAccountDraft() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-threadless-account-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let firstAccount = Account(
            id: AccountID("account-1"),
            displayName: "First",
            email: EmailAddress("first@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let receivingAccount = Account(
            id: AccountID("account-2"),
            displayName: "Receiving",
            email: EmailAddress("receiving@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([firstAccount, receivingAccount])
        try store.cacheThread(MailThread(
            id: ThreadID("bcc-message"),
            accountID: firstAccount.id,
            subjectNormalized: "colliding thread",
            participantEmails: [firstAccount.email]
        ))
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("bcc-message"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Status",
            preview: "Private recipient",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Can you confirm Friday?",
            rfcMessageID: "<bcc@example.com>",
            replyTo: EmailAddress("team@example.com")
        ))
        try store.recordCachedUID(
            accountID: receivingAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: MessageID("bcc-message")
        )
        let provider = PromptRecordingAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )
        let input = PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "bcc-message",
            conversationReferenceKind: .message,
            accountID: receivingAccount.id,
            providerID: provider.id,
            question: "Confirm Friday"
        )
        let job = try store.enqueueJob(PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: input.operation.priority,
            maxAttempts: 1,
            idempotencyKey: "threadless-multi-account-ai-draft"
        ))

        let completed = try await runtime.runUntilTerminal(jobID: job.id)

        let artifact = try store.durableOperationArtifact(id: try XCTUnwrap(completed.resultArtifactID))
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        let generated = try store.draft(id: DraftID(try XCTUnwrap(payload.resultRecordID)))
        XCTAssertEqual(generated.accountID, receivingAccount.id)
        XCTAssertEqual(generated.from, receivingAccount.email)
    }

    func testReplyBeginPersistsBrowserOwnedThreadedDraft() async throws {
        let harness = try DraftRouteHarness.make()

        let draft = try await harness.beginReply(messageID: "m-1")

        XCTAssertTrue(draft.id.hasPrefix("drf_browser_"))
        XCTAssertEqual(draft.id, draft.id.lowercased())
        XCTAssertEqual(draft.to, ["team@example.com"])
        XCTAssertEqual(draft.subject, "Re: Status")
        XCTAssertEqual(draft.body, "")
        XCTAssertFalse(draft.aiGenerated)
        let persisted = try harness.store.draft(id: DraftID(draft.id))
        XCTAssertEqual(persisted.accountID, AccountID("account-1"))
        XCTAssertEqual(persisted.createdBy, "browser-extension-user")
        XCTAssertEqual(persisted.inReplyTo, "<source@example.com>")
        XCTAssertEqual(persisted.references, ["<older@example.com>", "<source@example.com>"])
        XCTAssertEqual(
            harness.store.auditEntries.filter { $0.targetID == draft.id }.map(\.action),
            ["draft.create"]
        )
    }

    func testDraftReadReturnsPersistedDraft() async throws {
        let harness = try DraftRouteHarness.make()
        let begun = try await harness.beginReply(messageID: "m-1")

        let read = try await harness.readDraft(draftID: begun.id)

        XCTAssertEqual(read, begun)
    }

    func testDraftUpdateRejectsStaleHash() async throws {
        let harness = try DraftRouteHarness.make()
        let draft = try await harness.beginReply(messageID: "m-1")

        await XCTAssertThrowsLocalAPIError(.conflict) {
            _ = try await harness.updateDraft(
                draftID: draft.id,
                body: "Changed",
                expectedHash: "stale-hash"
            )
        }
        XCTAssertEqual(try harness.store.draft(id: DraftID(draft.id)).bodyPlain, "")
    }

    func testDraftUpdatePersistsPlainAndMarkdownBodyWithoutChangingAIRisk() async throws {
        let harness = try DraftRouteHarness.make()
        let draft = try await harness.beginReply(messageID: "m-1")

        let updated = try await harness.updateDraft(
            draftID: draft.id,
            body: "Changed",
            expectedHash: draft.contentHash
        )

        let persisted = try harness.store.draft(id: DraftID(draft.id))
        XCTAssertEqual(updated.body, "Changed")
        XCTAssertEqual(persisted.bodyPlain, "Changed")
        XCTAssertEqual(persisted.bodyMarkdown, "Changed")
        XCTAssertFalse(persisted.aiGenerated)
        XCTAssertEqual(updated.contentHash, persisted.contentHash)
        XCTAssertEqual(
            harness.store.auditEntries.filter { $0.targetID == draft.id }.map(\.action),
            ["draft.create", "draft.update"]
        )
    }

    func testDraftRoutesRejectDraftsNotOwnedByBrowserActor() async throws {
        let harness = try DraftRouteHarness.make()
        let foreign = Draft(
            id: DraftID("drf_browser_foreign"),
            accountID: AccountID("account-1"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("team@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Status",
            bodyPlain: "Private Mac draft",
            createdBy: "mac-user",
            aiGenerated: false,
            sourceThreadID: ThreadID("thread-1")
        )
        _ = try harness.store.createDraft(foreign, actor: browserActor)

        await XCTAssertThrowsLocalAPIError(.permissionDenied) {
            _ = try await harness.readDraft(draftID: foreign.id.rawValue)
        }
        await XCTAssertThrowsLocalAPIError(.permissionDenied) {
            _ = try await harness.updateDraft(
                draftID: foreign.id.rawValue,
                body: "Overwrite",
                expectedHash: foreign.contentHash
            )
        }
        await XCTAssertThrowsLocalAPIError(.permissionDenied) {
            _ = try await harness.aiDraft(
                draftID: foreign.id.rawValue,
                messageID: "m-1",
                instruction: "Overwrite",
                expectedHash: foreign.contentHash
            )
        }
    }

    func testDraftRoutesRejectNonBrowserDraftIDEvenWithBrowserActor() async throws {
        let harness = try DraftRouteHarness.make()
        let foreign = Draft(
            id: DraftID("drf_mac_1"),
            accountID: AccountID("account-1"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("team@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Status",
            bodyPlain: "Private Mac draft",
            createdBy: browserActor.id,
            aiGenerated: false,
            sourceThreadID: ThreadID("thread-1")
        )
        _ = try harness.store.createDraft(foreign, actor: browserActor)

        await XCTAssertThrowsLocalAPIError(.permissionDenied) {
            _ = try await harness.readDraft(draftID: foreign.id.rawValue)
        }
    }

    func testSummaryUsesThreadWhenPresentAndSelectedProvider() async throws {
        let harness = try DraftRouteHarness.make(selectedProviderID: "ollama")

        let result = try await harness.summarize(messageID: "m-1")

        XCTAssertEqual(result.summary, "Thread summary")
        let inputs = await harness.aiClient.inputs
        let input = try XCTUnwrap(inputs.last)
        XCTAssertEqual(input.operation, .summarizeThread)
        XCTAssertEqual(input.recordID, "thread-1")
        XCTAssertEqual(input.providerID, "ollama")
    }

    func testSummaryUsesMessageWhenThreadIsMissing() async throws {
        let harness = try DraftRouteHarness.make(messageThreadID: nil)

        _ = try await harness.summarize(messageID: "m-1")

        let inputs = await harness.aiClient.inputs
        let input = try XCTUnwrap(inputs.last)
        XCTAssertEqual(input.operation, .summarizeMessage)
        XCTAssertEqual(input.recordID, "m-1")
    }

    func testAIDraftUsesSelectedProviderInstructionAndReturnsPersistedBrowserDraft() async throws {
        let harness = try DraftRouteHarness.make(selectedProviderID: "ollama")
        let draft = try await harness.beginReply(messageID: "m-1")

        let result = try await harness.aiDraft(
            draftID: draft.id,
            messageID: "m-1",
            instruction: "Confirm Friday",
            expectedHash: draft.contentHash
        )

        let inputs = await harness.aiClient.inputs
        let input = try XCTUnwrap(inputs.last)
        XCTAssertEqual(input.operation, .draftReply)
        XCTAssertEqual(input.recordID, "thread-1")
        XCTAssertEqual(input.providerID, "ollama")
        XCTAssertEqual(input.question, "Confirm Friday")
        XCTAssertEqual(result.id, draft.id)
        let persisted = try harness.store.draft(id: DraftID(result.id))
        XCTAssertEqual(persisted.contentHash, result.contentHash)
        XCTAssertEqual(persisted.bodyPlain, "Friday is confirmed.")
        XCTAssertEqual(persisted.bodyMarkdown, "Friday is confirmed.")
        XCTAssertTrue(persisted.aiGenerated)
    }

    func testAIDraftUsesMessageReferenceForLegacySyntheticThreadID() async throws {
        let harness = try DraftRouteHarness.make(
            messageThreadID: ThreadID("thr_uid_INBOX_1_78"),
            cacheThread: false
        )
        let draft = try await harness.beginReply(messageID: "m-1")

        _ = try await harness.aiDraft(
            draftID: draft.id,
            messageID: "m-1",
            instruction: "Confirm Friday",
            expectedHash: draft.contentHash
        )

        let inputs = await harness.aiClient.inputs
        let input = try XCTUnwrap(inputs.last)
        XCTAssertEqual(input.recordID, "m-1")
        XCTAssertEqual(input.conversationReferenceKind, .message)
        XCTAssertEqual(input.accountID, AccountID("account-1"))
    }

    func testAIDraftRejectsStaleHashWithoutReplacingManualText() async throws {
        let harness = try DraftRouteHarness.make()
        let draft = try await harness.beginReply(messageID: "m-1")
        let manuallyUpdated = try await harness.updateDraft(
            draftID: draft.id,
            body: "Keep my manual text",
            expectedHash: draft.contentHash
        )

        await XCTAssertThrowsLocalAPIError(.conflict) {
            _ = try await harness.aiDraft(
                draftID: draft.id,
                messageID: "m-1",
                instruction: "Replace it",
                expectedHash: draft.contentHash
            )
        }

        let persisted = try harness.store.draft(id: DraftID(draft.id))
        XCTAssertEqual(persisted.bodyPlain, "Keep my manual text")
        XCTAssertEqual(persisted.contentHash, manuallyUpdated.contentHash)
    }

    func testAIDraftRejectsManualEditMadeWhileGenerationIsInFlight() async throws {
        let harness = try DraftRouteHarness.make()
        let draft = try await harness.beginReply(messageID: "m-1")
        let client = SuspendingAIClient(store: harness.store)
        let route = AIDraftReplyRoute(
            store: harness.store,
            aiClient: client,
            selectedProviderID: { "foundation" }
        )

        let generation = Task {
            try await harness.aiDraft(
                using: route,
                draftID: draft.id,
                messageID: "m-1",
                instruction: "Replace it",
                expectedHash: draft.contentHash
            )
        }
        await client.waitUntilStarted()
        let manuallyUpdated = try await harness.updateDraft(
            draftID: draft.id,
            body: "Keep the edit made during generation",
            expectedHash: draft.contentHash
        )
        await client.resume()

        do {
            _ = try await generation.value
            XCTFail("Expected an edit conflict")
        } catch let error as LocalAPIRouteError {
            XCTAssertEqual(error.code, .conflict)
        }
        let persisted = try harness.store.draft(id: DraftID(draft.id))
        XCTAssertEqual(persisted.bodyPlain, "Keep the edit made during generation")
        XCTAssertEqual(persisted.contentHash, manuallyUpdated.contentHash)
        XCTAssertEqual(
            harness.store.auditEntries.filter { $0.targetID == draft.id }.map(\.action),
            ["draft.create", "draft.update"]
        )
    }

    func testAIDraftRejectsMessageThatDoesNotMatchBrowserDraftSource() async throws {
        let harness = try DraftRouteHarness.make()
        let draft = try await harness.beginReply(messageID: "m-1")
        try harness.cacheSecondSourceMessage()

        await XCTAssertThrowsLocalAPIError(.invalidRequest) {
            _ = try await harness.aiDraft(
                draftID: draft.id,
                messageID: "m-2",
                instruction: "Wrong source",
                expectedHash: draft.contentHash
            )
        }
        let inputs = await harness.aiClient.inputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testAIDraftRejectsDifferentThreadlessMessageWhenRFCIdentityIsMissing() async throws {
        let harness = try DraftRouteHarness.make(messageThreadID: nil, rfcMessageID: nil)
        let draft = try await harness.beginReply(messageID: "m-1")
        try harness.cacheSecondThreadlessMessageWithoutRFCIdentity()

        await XCTAssertThrowsLocalAPIError(.invalidRequest) {
            _ = try await harness.aiDraft(
                draftID: draft.id,
                messageID: "m-2",
                instruction: "Wrong source",
                expectedHash: draft.contentHash
            )
        }
        let inputs = await harness.aiClient.inputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testAIFailureIsRedactedAndManualDraftRemainsUsable() async throws {
        let harness = try DraftRouteHarness.make(aiFailure: true)
        let draft = try await harness.beginReply(messageID: "m-1")
        let request = LocalAPIRequest(
            requestID: "ai-failure",
            method: .aiDraftReply,
            parameters: LocalAPIAIDraftReplyParameters(
                draftID: draft.id,
                messageID: "m-1",
                instruction: "Confirm Friday",
                expectedHash: draft.contentHash
            )
        )
        let router = LocalAPIRouter(routes: [harness.aiDraftRoute])

        let response = await router.handle(try JSONEncoder().encode(request), caller: .browserExtension)

        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: response)
        XCTAssertEqual(failure.error.code, .operationFailed)
        XCTAssertEqual(failure.error.message, "The local operation failed.")
        let manuallyUpdated = try await harness.updateDraft(
            draftID: draft.id,
            body: "Manual fallback",
            expectedHash: draft.contentHash
        )
        XCTAssertEqual(manuallyUpdated.body, "Manual fallback")
    }
}

private final class DraftRouteHarness: @unchecked Sendable {
    let store: SQLiteMailStore
    let aiClient: RecordingAIClient
    let summaryRoute: AISummarizeRoute
    let beginRoute: ReplyBeginRoute
    let readRoute: DraftReadRoute
    let updateRoute: DraftUpdateRoute
    let aiDraftRoute: AIDraftReplyRoute
    private let databaseURL: URL

    deinit {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    static func make(
        selectedProviderID: String = "foundation",
        messageThreadID: ThreadID? = ThreadID("thread-1"),
        cacheThread: Bool = true,
        rfcMessageID: String? = "<source@example.com>",
        aiFailure: Bool = false
    ) throws -> DraftRouteHarness {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-local-ai-draft-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("account-1"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("m-1"),
            threadID: messageThreadID,
            from: EmailAddress("sender@example.com"),
            subject: "Status",
            preview: "Can you confirm?",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Can you confirm Friday?",
            rfcMessageID: rfcMessageID,
            references: ["<older@example.com>"],
            replyTo: EmailAddress("team@example.com")
        ))
        try store.recordCachedUID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: MessageID("m-1")
        )
        if let messageThreadID, cacheThread {
            try store.cacheThreads([MailThread(
                id: messageThreadID,
                accountID: account.id,
                subjectNormalized: "Status",
                participantEmails: [account.email, EmailAddress("team@example.com")]
            )])
        }
        let client = RecordingAIClient(store: store, shouldFail: aiFailure)
        let selectedProvider = { @Sendable in selectedProviderID }
        return DraftRouteHarness(
            store: store,
            aiClient: client,
            selectedProviderID: selectedProvider,
            databaseURL: databaseURL
        )
    }

    private init(
        store: SQLiteMailStore,
        aiClient: RecordingAIClient,
        selectedProviderID: @escaping @Sendable () -> String,
        databaseURL: URL
    ) {
        self.store = store
        self.aiClient = aiClient
        self.databaseURL = databaseURL
        summaryRoute = AISummarizeRoute(store: store, aiClient: aiClient, selectedProviderID: selectedProviderID)
        beginRoute = ReplyBeginRoute(store: store)
        readRoute = DraftReadRoute(store: store)
        updateRoute = DraftUpdateRoute(store: store)
        aiDraftRoute = AIDraftReplyRoute(store: store, aiClient: aiClient, selectedProviderID: selectedProviderID)
    }

    func beginReply(messageID: String) async throws -> LocalAPIDraftResult {
        try await invoke(beginRoute, parameters: LocalAPIReplyBeginParameters(messageID: messageID))
    }

    func readDraft(draftID: String) async throws -> LocalAPIDraftResult {
        try await invoke(readRoute, parameters: LocalAPIDraftReadParameters(draftID: draftID))
    }

    func updateDraft(draftID: String, body: String, expectedHash: String) async throws -> LocalAPIDraftResult {
        try await invoke(
            updateRoute,
            parameters: LocalAPIDraftUpdateParameters(
                draftID: draftID,
                body: body,
                expectedHash: expectedHash
            )
        )
    }

    func summarize(messageID: String) async throws -> LocalAPISummaryResult {
        try await invoke(summaryRoute, parameters: LocalAPIAISummarizeParameters(messageID: messageID))
    }

    func aiDraft(
        draftID: String,
        messageID: String,
        instruction: String,
        expectedHash: String
    ) async throws -> LocalAPIDraftResult {
        try await invoke(
            aiDraftRoute,
            parameters: LocalAPIAIDraftReplyParameters(
                draftID: draftID,
                messageID: messageID,
                instruction: instruction,
                expectedHash: expectedHash
            )
        )
    }

    func aiDraft(
        using route: AIDraftReplyRoute,
        draftID: String,
        messageID: String,
        instruction: String,
        expectedHash: String
    ) async throws -> LocalAPIDraftResult {
        try await invoke(
            route,
            parameters: LocalAPIAIDraftReplyParameters(
                draftID: draftID,
                messageID: messageID,
                instruction: instruction,
                expectedHash: expectedHash
            )
        )
    }

    func cacheSecondSourceMessage() throws {
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("m-2"),
            threadID: ThreadID("thread-2"),
            from: EmailAddress("other@example.com"),
            subject: "Different",
            preview: "Different source",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Different source body",
            rfcMessageID: "<other@example.com>",
            replyTo: EmailAddress("other@example.com")
        ))
        try store.cacheThread(MailThread(
            id: ThreadID("thread-2"),
            accountID: AccountID("account-1"),
            subjectNormalized: "Different",
            participantEmails: [EmailAddress("me@example.com"), EmailAddress("other@example.com")]
        ))
        try store.recordCachedUID(
            accountID: AccountID("account-1"),
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            messageID: MessageID("m-2")
        )
    }

    func cacheSecondThreadlessMessageWithoutRFCIdentity() throws {
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID("m-2"),
            threadID: nil,
            from: EmailAddress("other@example.com"),
            subject: "Different",
            preview: "Different source",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Different source body",
            rfcMessageID: nil,
            replyTo: EmailAddress("other@example.com")
        ))
        try store.recordCachedUID(
            accountID: AccountID("account-1"),
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            messageID: MessageID("m-2")
        )
    }

    private func invoke<Parameters, Result>(
        _ route: some LocalAPIRoute,
        parameters: Parameters
    ) async throws -> Result where Parameters: Codable & Sendable, Result: Codable & Sendable {
        let request = LocalAPIRequest(requestID: "test-request", method: route.method, parameters: parameters)
        let response = try await route.handle(
            requestData: JSONEncoder().encode(request),
            requestID: "test-request"
        )
        return try JSONDecoder().decode(LocalAPISuccess<Result>.self, from: response).result
    }
}

private actor RecordingAIClient: PlainpostOperationClientProtocol {
    private let store: SQLiteMailStore
    private let shouldFail: Bool
    private(set) var inputs: [PlainpostAIOperationInput] = []

    init(store: SQLiteMailStore, shouldFail: Bool) {
        self.store = store
        self.shouldFail = shouldFail
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        inputs.append(input)
        if shouldFail { throw RecordingAIError.failed }

        let artifactID = "artifact-\(inputs.count)"
        let payload: PlainpostLocalAIArtifactPayload
        if input.operation == .draftReply {
            let generatedDraftID = DraftID("drf_ai_generated_\(inputs.count)")
            let generated = Draft(
                id: generatedDraftID,
                accountID: AccountID("account-1"),
                from: EmailAddress("me@example.com"),
                to: [EmailAddress("team@example.com")],
                cc: [],
                bcc: [],
                subject: "Re: Status",
                bodyPlain: "Friday is confirmed.",
                createdBy: "local-operation-agent",
                aiGenerated: true,
                sourceThreadID: ThreadID("thread-1")
            )
            _ = try store.createDraft(generated, actor: browserActor)
            payload = PlainpostLocalAIArtifactPayload(resultRecordID: generatedDraftID.rawValue)
        } else {
            payload = PlainpostLocalAIArtifactPayload(
                text: "Thread summary",
                resultRecordID: input.recordID
            )
        }
        try store.saveTypedAIOperationArtifact(DurableOperationArtifact(
            id: artifactID,
            kind: input.operation.rawValue,
            recordID: input.recordID,
            payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self),
            createdAt: Date()
        ), input: input)
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: artifactID,
            jobID: "job-\(inputs.count)"
        )
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        throw RecordingAIError.failed
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw RecordingAIError.failed
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw RecordingAIError.failed
    }

    private var browserActor: Actor {
        Actor(
            id: "browser-extension-user",
            kind: .user,
            displayName: "Plainpost Browser Extension",
            permissions: .guiUser
        )
    }
}

private actor SuspendingAIClient: PlainpostOperationClientProtocol {
    private let store: SQLiteMailStore
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationContinuation: CheckedContinuation<Void, Never>?

    init(store: SQLiteMailStore) {
        self.store = store
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        generationContinuation?.resume()
        generationContinuation = nil
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            generationContinuation = continuation
        }

        let generatedDraftID = DraftID("drf_ai_suspended")
        let generated = Draft(
            id: generatedDraftID,
            accountID: AccountID("account-1"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("team@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Status",
            bodyPlain: "Generated after the manual edit.",
            createdBy: "local-operation-agent",
            aiGenerated: true,
            sourceThreadID: ThreadID("thread-1")
        )
        _ = try store.createDraft(generated, actor: browserActor)
        let payload = PlainpostLocalAIArtifactPayload(resultRecordID: generatedDraftID.rawValue)
        let artifactID = "artifact-suspended"
        try store.saveTypedAIOperationArtifact(DurableOperationArtifact(
            id: artifactID,
            kind: input.operation.rawValue,
            recordID: input.recordID,
            payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self),
            createdAt: Date()
        ), input: input)
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: artifactID,
            jobID: "job-suspended"
        )
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        throw RecordingAIError.failed
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw RecordingAIError.failed
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw RecordingAIError.failed
    }
}

private enum RecordingAIError: Error {
    case failed
}

private let browserActor = Actor(
    id: "browser-extension-user",
    kind: .user,
    displayName: "Plainpost Browser Extension",
    permissions: .guiUser
)

private final class PromptRecordingAIProvider: AIProvider, @unchecked Sendable {
    let id = "prompt-recording"
    let displayName = "Prompt Recording"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let recorder = PromptRecorder()

    var prompts: [String] {
        get async { await recorder.prompts }
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        await recorder.append(request.prompt)
        let text: String
        if request.prompt.contains("First operation") {
            text = "First generated reply."
        } else if request.prompt.contains("Second operation") {
            text = "Second generated reply."
        } else {
            text = "Friday is confirmed."
        }
        return AIGenerationResponse(text: text, modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        throw AIProviderError.unavailable
    }
}

private func artifactPayload(
    id: String,
    store: SQLiteMailStore
) throws -> PlainpostLocalAIArtifactPayload {
    let artifact = try store.durableOperationArtifact(id: id)
    return try JSONDecoder().decode(
        PlainpostLocalAIArtifactPayload.self,
        from: Data(artifact.payloadJSON.utf8)
    )
}

private actor PromptRecorder {
    private(set) var prompts: [String] = []

    func append(_ prompt: String) {
        prompts.append(prompt)
    }
}

private func XCTAssertThrowsLocalAPIError<T>(
    _ expectedCode: LocalAPIErrorCode,
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected LocalAPIRouteError", file: file, line: line)
    } catch let error as LocalAPIRouteError {
        XCTAssertEqual(error.code, expectedCode, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
