import Combine
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostUI

@MainActor
final class AskMailViewModelTests: XCTestCase {
    func testSetHostPublishesSoAskMailViewsRerender() {
        let viewModel = AskMailViewModel(handler: RecordingAskMailHandler())
        var changes = 0
        let subscription = viewModel.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        XCTAssertFalse(viewModel.host.allowsMutations())

        viewModel.setHost(.preview)

        XCTAssertEqual(changes, 1)
        XCTAssertTrue(viewModel.host.allowsMutations())
    }

    func testPrivacyCopyClaimsThisDeviceOnlyForKnownLocalProviders() {
        XCTAssertEqual(AskMailPrivacyCopy.title(localOnly: true), "Private to this device")
        XCTAssertEqual(AskMailPrivacyCopy.title(localOnly: false), "About your data")
        XCTAssertEqual(AskMailPrivacyCopy.title(localOnly: nil), "About your data")
        XCTAssertEqual(AskMailPrivacyCopy.body(providerName: "OpenRouter", localOnly: false), "Your question and the mail used to answer it are sent to OpenRouter.")
        XCTAssertEqual(AskMailPrivacyCopy.body(providerName: "OpenAI", localOnly: nil), "Answers use OpenAI.")
        XCTAssertEqual(AskMailPrivacyCopy.body(providerName: "Apple Foundation Models", localOnly: true),
                       "Questions and answers are processed on this device with Apple Foundation Models. Nothing is sent to a server.")
    }

    func testLocalOnlyComesFromConfigureThenFromAnswers() async {
        let viewModel = AskMailViewModel(handler: RecordingAskMailHandler())
        XCTAssertNil(viewModel.localOnly, "unknown before configure or an answer")
        viewModel.configure(handler: RecordingAskMailHandler(), providerName: "Remote", localOnly: false)
        XCTAssertEqual(viewModel.localOnly, false)
        viewModel.configure(handler: RecordingAskMailHandler(), providerName: "Unknown")
        XCTAssertNil(viewModel.localOnly)
        await viewModel.ask("Where is the contract?")
        XCTAssertEqual(viewModel.localOnly, true, "the answer reports its provider ran locally")
    }

    func testDisabledHostRefusesEveryMutation() async {
        let disabled = AskMailHostActions.disabled
        XCTAssertFalse(disabled.allowsMutations())
        for action in [InboxMailAction.markRead, .markUnread, .archive] {
            let performed = await disabled.mailAction(action, MessageID("m"))
            XCTAssertFalse(performed)
        }
    }

    func testBulkActionPerformsNothingBeforeSetHostAndRunsOnceAttached() async {
        let viewModel = AskMailViewModel(handler: RecordingAskMailHandler())
        viewModel.actionGraceDelay = .zero
        let section = [(id: "n", noun: "notifications", messageIDs: [MessageID("a"), MessageID("b")], total: 2)]

        viewModel.actions.apply(.archive, blockID: "before", sections: section)
        await viewModel.actions.waitForIdle()
        XCTAssertEqual(viewModel.actions.receipts["before/n"]?.phase, .done(applied: 0))

        var performed: [MessageID] = []
        viewModel.setHost(AskMailHostActions(
            openMessage: { _ in }, reply: { _ in }, openDraft: { _ in },
            mailAction: { _, id in performed.append(id); return true },
            allowsMutations: { true }))
        viewModel.actions.apply(.archive, blockID: "after", sections: section)
        await viewModel.actions.waitForIdle()
        XCTAssertEqual(performed, [MessageID("a"), MessageID("b")])
        XCTAssertEqual(viewModel.actions.receipts["after/n"]?.phase, .done(applied: 2))
    }

    func testChosenOptionSendsItsFilterOverride() async {
        let handler = RecordingAskMailHandler()
        let viewModel = AskMailViewModel(handler: handler)
        await viewModel.ask("unread from Tom today", override: .dropDates)
        await viewModel.ask("Where is the contract?")
        XCTAssertEqual(handler.requests.map(\.question), ["unread from Tom today", "Where is the contract?"])
        XCTAssertEqual(handler.requests.map(\.filterOverride), [.dropDates, nil])
    }

    func testHostProblemShowsInStatusLine() {
        let viewModel = AskMailViewModel(handler: RecordingAskMailHandler())
        viewModel.reportHostProblem("Couldn't open that message to reply.")
        XCTAssertEqual(viewModel.statusMessage, "Couldn't open that message to reply.")
    }

    func testCheckingUnchangedModelAvailabilityShowsFeedback() {
        let viewModel = AskMailViewModel(
            handler: RecordingAskMailHandler(),
            availability: { AIActionAvailability(
                isAvailable: false, reason: "Model not ready", canCheckAgain: true
            ) }
        )

        XCTAssertNil(viewModel.lastAvailabilityCheck)
        viewModel.checkAvailability()
        XCTAssertNotNil(viewModel.lastAvailabilityCheck)
        XCTAssertEqual(viewModel.actionAvailability.reason, "Model not ready")
        viewModel.configure(handler: RecordingAskMailHandler(), providerName: "Another provider")
        XCTAssertNil(viewModel.lastAvailabilityCheck)
    }

    func testUnavailableModelKeepsQuestionAndDoesNotDispatchAskMail() async {
        let handler = RecordingAskMailHandler()
        let viewModel = AskMailViewModel(
            handler: handler,
            availability: { AIActionAvailability.resolve(
                provider: FoundationModelsAIProvider(),
                status: AIProviderStatusService.foundation(availability: .modelNotReady),
                operation: .askMail
            ) }
        )
        viewModel.input = "Where is the contract?"

        await viewModel.askCurrentQuestion()

        XCTAssertTrue(handler.requests.isEmpty)
        XCTAssertEqual(viewModel.input, "Where is the contract?")
        XCTAssertFalse(viewModel.actionAvailability.isAvailable)
        XCTAssertTrue(viewModel.actionAvailability.canCheckAgain)
    }

    func testCheckingAgainEnablesAskMailAfterModelBecomesReady() async {
        let handler = RecordingAskMailHandler()
        var ready = false
        let viewModel = AskMailViewModel(
            handler: handler,
            availability: { AIActionAvailability(
                isAvailable: ready, reason: ready ? nil : "Model downloading", canCheckAgain: !ready
            ) }
        )
        viewModel.input = "Where is the contract?"
        await viewModel.askCurrentQuestion()
        XCTAssertEqual(viewModel.statusMessage, "Model downloading")

        ready = true
        viewModel.refreshAvailability()
        XCTAssertNil(viewModel.statusMessage)
        await viewModel.askCurrentQuestion()

        XCTAssertEqual(handler.requests.map(\.question), ["Where is the contract?"])
    }


    func testUnsupportedLanguageDoesNotSuggestBlindRetry() async {
        let viewModel = AskMailViewModel(handler: ProviderErrorAskMailHandler())
        viewModel.input = "What happened?"

        await viewModel.askCurrentQuestion()

        XCTAssertEqual(viewModel.input, "What happened?")
        XCTAssertTrue(viewModel.statusMessage?.contains("language") == true)
        XCTAssertFalse(viewModel.statusMessage?.contains("Try again.") == true)
    }

    func testMailboxChatWorksWithoutSelectionAndKeepsConversationAcrossContextChanges() async {
        let handler = RecordingAskMailHandler()
        let viewModel = AskMailViewModel(handler: handler)
        viewModel.input = "Find the latest travel details"

        await viewModel.askCurrentQuestion()
        viewModel.setActiveContext(
            AskMailActiveContext(
                conversationKey: "thr_trip",
                subject: "Zurich trip",
                messageIDs: [MessageID("msg_trip_1"), MessageID("msg_trip_2")]
            )
        )

        XCTAssertEqual(viewModel.turns.count, 1)
        XCTAssertEqual(viewModel.activeContext?.messageIDs.count, 2)
        XCTAssertNil(handler.requests.first?.activeContext)
    }

    func testFailedQuestionIsRestoredForRetry() async {
        let viewModel = AskMailViewModel(handler: FailingAskMailHandler())
        viewModel.input = "Where is the contract?"

        await viewModel.askCurrentQuestion()

        XCTAssertEqual(viewModel.input, "Where is the contract?")
        XCTAssertEqual(viewModel.statusMessage, "Answer unavailable. Try again.")
        XCTAssertTrue(viewModel.turns.isEmpty)
    }

    func testClearingContextFallsBackFromConversationScope() {
        let viewModel = AskMailViewModel(handler: RecordingAskMailHandler())
        viewModel.setActiveContext(
            AskMailActiveContext(
                conversationKey: "thr_one",
                subject: "One",
                messageIDs: [MessageID("msg_one")]
            )
        )
        viewModel.scope = .activeConversation

        viewModel.clearActiveContext()

        XCTAssertEqual(viewModel.scope, .allMail)
    }

    func testTransientMissingContextDoesNotLoseConversationScope() {
        let viewModel = AskMailViewModel(handler: RecordingAskMailHandler())
        viewModel.setActiveContext(
            AskMailActiveContext(
                conversationKey: "thr_one",
                subject: "One",
                messageIDs: [MessageID("msg_one")]
            )
        )
        viewModel.scope = .activeConversation

        viewModel.setActiveContext(nil)

        XCTAssertEqual(viewModel.scope, .activeConversation)
    }

    @MainActor
    func testTurnKeepsStructuredAnswer() async {
        let answer = AskMailAnswer(text: "Found **2** messages.", searched: [.init(label: "Unread")])
        let handler = FixedAskMailHandler(result: MailboxQuestionAnswer(
            answer: answer.text, sources: [], insufficientEvidence: false, providerName: "P", modelID: "m",
            localOnly: true, retrievalMode: .lexical, askMailAnswer: answer))
        let model = AskMailViewModel(handler: handler)
        await model.ask("Show unread")
        XCTAssertEqual(model.turns.first?.answer, answer)
    }

    @MainActor
    func testSourceForMessageFindsRowsAndCitationsInTurns() async {
        let cited = MailKnowledgeSource(id: "S1", messageID: MessageID("cited"), conversationKey: "c1",
                                        mailboxPath: "Archive", subject: "s", sender: "x", sentAt: nil, snippet: "")
        let row = AskMailMessageRow(messageID: MessageID("row"), conversationKey: "c2", mailboxPath: "INBOX",
                                    sender: "Tom", senderAddress: "tom@example.com", subject: "Lunch",
                                    snippet: "", sentAt: nil, isUnread: true, tag: nil)
        let list = AskMailMessageListBlock(
            id: "b", title: "People", icon: .person, tint: .blue,
            sections: [AskMailMessageSection(id: "p", title: "People", tint: .blue, totalCount: 1, summary: "",
                                             rows: [row], actionMessageIDs: [row.messageID])],
            bulkActions: [], rowAction: .reply)
        let answer = AskMailAnswer(text: "Two [1].", citations: [AskMailCitation(number: 1, source: cited)],
                                   blocks: [.messages(list)])
        let model = AskMailViewModel(handler: FixedAskMailHandler(result: MailboxQuestionAnswer(
            answer: answer.text, sources: [], insufficientEvidence: false, providerName: "P", modelID: "m",
            localOnly: true, retrievalMode: .lexical, askMailAnswer: answer)))
        await model.ask("q")

        XCTAssertEqual(model.source(for: MessageID("cited"))?.mailboxPath, "Archive")
        XCTAssertEqual(model.source(for: MessageID("row"))?.mailboxPath, "INBOX")
        XCTAssertNil(model.source(for: MessageID("unknown")))
    }

    @MainActor
    func testLegacyAnswerIsWrappedWithNumberedCitations() async {
        let source = MailKnowledgeSource(id: "S1", messageID: MessageID("m"), conversationKey: "c", mailboxPath: "INBOX",
                                         subject: "s", sender: "x", sentAt: nil, snippet: "")
        let handler = FixedAskMailHandler(result: MailboxQuestionAnswer(
            answer: "Yes [S1].", sources: [source], insufficientEvidence: false, providerName: "P", modelID: "m",
            localOnly: true, retrievalMode: .lexical))
        let model = AskMailViewModel(handler: handler)
        await model.ask("q")
        XCTAssertEqual(model.turns.first?.answer.text, "Yes [1].")
        XCTAssertEqual(model.turns.first?.answer.citations.first?.number, 1)
    }

    @MainActor
    func testStopRestoresQuestionAndIgnoresLateResult() async {
        let handler = SlowAskMailHandler()
        let model = AskMailViewModel(handler: handler)
        model.input = "Slow question"
        let task = Task { await model.askCurrentQuestion() }
        await handler.waitUntilStarted()
        model.stop()
        XCTAssertEqual(model.input, "Slow question")
        XCTAssertFalse(model.isWorking)
        handler.finish()
        await task.value
        XCTAssertTrue(model.turns.isEmpty)
    }

    /// Stop (and leaving Ask Mail) cancels the question's work, which cancels its AI job;
    /// ignoring the late answer alone left the job queued with no one waiting for it.
    @MainActor
    func testStopCancelsTheQuestionsWork() async {
        let handler = CancellationRecordingAskMailHandler()
        let model = AskMailViewModel(handler: handler)
        model.input = "Help me clean up unread mail"
        let task = Task { await model.askCurrentQuestion() }
        await handler.waitUntilStarted()
        model.stop()
        await task.value
        let cancelled = await handler.wasCancelled
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.input, "Help me clean up unread mail")
        XCTAssertTrue(model.turns.isEmpty)
    }

    @MainActor
    func testCalendarStatusReportsDeniedAccess() async {
        let model = AskMailViewModel(handler: FixedAskMailHandler(result: .init(answer: "", sources: [], insufficientEvidence: true, providerName: "", modelID: "", localOnly: true, retrievalMode: .lexical)))
        model.calendarWriter = DenyingCalendarWriter()
        let card = AskMailCardBlock(id: "card-1", kind: .event, title: "Viewing", badge: nil, hero: "Sat", subtitle: "",
                                    fields: [], source: MailKnowledgeSource(id: "1", messageID: MessageID("1"), conversationKey: "c",
                                    mailboxPath: "INBOX", subject: "", sender: "", sentAt: nil, snippet: ""),
                                    calendarItem: AskMailCalendarItem(title: "Viewing", start: .now, end: nil, location: nil, notes: nil),
                                    reminderItem: nil)
        await model.addToCalendar(card, turnID: "turn-1")
        XCTAssertEqual(model.calendarStatus(turnID: "turn-1", cardID: "card-1").event,
                       .failed("Allow calendar access in Settings to add events."))
    }

    @MainActor
    func testCalendarStatusIsTypedPerActionAndTurnScoped() async {
        let model = AskMailViewModel(handler: FixedAskMailHandler(result: .init(answer: "", sources: [], insufficientEvidence: true, providerName: "", modelID: "", localOnly: true, retrievalMode: .lexical)))
        model.calendarWriter = AcceptingCalendarWriter()
        let card = AskMailCardBlock(id: "card-1", kind: .flight, title: "LX 318", badge: nil, hero: "ZRH → LHR", subtitle: "",
                                    fields: [], source: MailKnowledgeSource(id: "1", messageID: MessageID("1"), conversationKey: "c",
                                    mailboxPath: "INBOX", subject: "", sender: "", sentAt: nil, snippet: ""),
                                    calendarItem: AskMailCalendarItem(title: "LX 318", start: .now, end: nil, location: nil, notes: nil),
                                    reminderItem: AskMailReminderItem(title: "Check in", due: .now, notes: nil))
        await model.addReminder(card, turnID: "turn-1")
        XCTAssertEqual(model.calendarStatus(turnID: "turn-1", cardID: "card-1").reminder, .reminderAdded)
        XCTAssertNil(model.calendarStatus(turnID: "turn-1", cardID: "card-1").event)
        await model.addToCalendar(card, turnID: "turn-1")
        XCTAssertEqual(model.calendarStatus(turnID: "turn-1", cardID: "card-1").event, .eventAdded)
        XCTAssertEqual(model.calendarStatus(turnID: "turn-1", cardID: "card-1").reminder, .reminderAdded)
        XCTAssertNil(model.calendarStatus(turnID: "turn-2", cardID: "card-1").event)
    }
}

private struct ProviderErrorAskMailHandler: AskMailHandling {
    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        throw AIProviderError.unsupportedLanguageOrLocale
    }
}

private final class RecordingAskMailHandler: AskMailHandling, @unchecked Sendable {
    struct Request {
        let question: String
        let activeContext: AskMailActiveContext?
        var filterOverride: AskMailFilterOverride?
    }

    private let lock = NSLock()
    private var storage: [Request] = []
    var requests: [Request] { lock.withLock { storage } }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        try await ask(question: question, scope: scope, activeContext: activeContext, priorTurns: priorTurns,
                      filterOverride: nil)
    }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn],
        filterOverride: AskMailFilterOverride?
    ) async throws -> MailboxQuestionAnswer {
        lock.withLock {
            storage.append(Request(question: question, activeContext: activeContext, filterOverride: filterOverride))
        }
        return MailboxQuestionAnswer(
            answer: "The train leaves at 09:12. [S1]",
            sources: [],
            insufficientEvidence: false,
            providerName: "On device",
            modelID: "test",
            localOnly: true,
            retrievalMode: .lexical
        )
    }
}

private struct FailingAskMailHandler: AskMailHandling {
    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        throw PlainpostError.validationFailed("Test failure")
    }
}

private struct FixedAskMailHandler: AskMailHandling {
    let result: MailboxQuestionAnswer

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        result
    }
}

/// An `AskMailHandling` that suspends until `finish()` is called, so a test can observe the
/// view model's "working" state deterministically instead of racing a sleep.
private final class SlowAskMailHandler: AskMailHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        lock.withLock {
            started = true
            let waiters = startContinuations
            startContinuations = []
            for waiter in waiters { waiter.resume() }
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if finished {
                    continuation.resume()
                } else {
                    finishContinuation = continuation
                }
            }
        }
        return MailboxQuestionAnswer(
            answer: "Done", sources: [], insufficientEvidence: false, providerName: "P", modelID: "m",
            localOnly: true, retrievalMode: .lexical
        )
    }

    func waitUntilStarted() async {
        let alreadyStarted = lock.withLock { started }
        if alreadyStarted { return }
        await withCheckedContinuation { continuation in
            lock.withLock { startContinuations.append(continuation) }
        }
    }

    func finish() {
        lock.withLock {
            finished = true
            finishContinuation?.resume()
            finishContinuation = nil
        }
    }
}

private struct AcceptingCalendarWriter: AskMailCalendarWriting {
    func addEvent(_ item: AskMailCalendarItem) async throws {}
    func addReminder(_ item: AskMailReminderItem) async throws {}
}

private struct DenyingCalendarWriter: AskMailCalendarWriting {
    func addEvent(_ item: AskMailCalendarItem) async throws { throw AskMailCalendarError.accessDenied }
    func addReminder(_ item: AskMailReminderItem) async throws { throw AskMailCalendarError.accessDenied }
}

private actor CancellationRecordingAskMailHandler: AskMailHandling {
    private(set) var wasCancelled = false
    private var started = false

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            wasCancelled = true
            throw error
        }
        return MailboxQuestionAnswer(
            answer: "Late", sources: [], insufficientEvidence: false, providerName: "P", modelID: "m",
            localOnly: true, retrievalMode: .lexical
        )
    }
}
