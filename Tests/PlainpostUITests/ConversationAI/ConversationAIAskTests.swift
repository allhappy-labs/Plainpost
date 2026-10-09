import AppKit
import SwiftUI
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostUI

@MainActor
final class ConversationAIAskTests: XCTestCase {
    func testAskIsScopedToThisConversationAndOpensTheAskRoute() async {
        let handler = ScopedAskMailHandler()
        let model = makeAskModel(handler: handler)
        model.setConversation(planContext(selected: "m2"))

        await model.ask("What do they need?")?.value

        XCTAssertEqual(model.route, .ask)
        XCTAssertEqual(handler.requests, [
            .init(question: "What do they need?", scope: .activeConversation, conversationKey: "thread-plan"),
        ])
        XCTAssertEqual(model.askMail.turns.count, 1)
    }

    func testBlankQuestionAsksNothing() {
        let handler = ScopedAskMailHandler()
        let model = makeAskModel(handler: handler)
        model.setConversation(planContext(selected: "m2"))

        XCTAssertNil(model.ask("   "))

        XCTAssertEqual(model.route, .overview)
        XCTAssertTrue(handler.requests.isEmpty)
    }

    func testBackKeepsTheTurnsUntilTheConversationChanges() async {
        let model = makeAskModel(handler: ScopedAskMailHandler())
        model.setConversation(planContext(selected: "m2"))
        await model.ask("What do they need?")?.value

        model.showOverview()
        XCTAssertEqual(model.askMail.turns.count, 1)

        model.setConversation(dinnerContext())
        XCTAssertTrue(model.askMail.turns.isEmpty)
        XCTAssertEqual(model.askMail.activeContext?.conversationKey, "thread-dinner")
        XCTAssertEqual(model.askMail.scope, .activeConversation)
    }

    func testSwitchingConversationDropsALateAnswer() async {
        let handler = ScopedAskMailHandler(gated: true)
        let model = makeAskModel(handler: handler)
        model.setConversation(planContext(selected: "m2"))
        let pending = model.ask("What do they need?")
        await handler.waitUntilAsked()

        model.setConversation(dinnerContext())
        handler.release()
        await pending?.value

        XCTAssertTrue(model.askMail.turns.isEmpty)
        XCTAssertEqual(model.route, .overview)
    }

    func testConversationAskMailHostClosesThePaneBeforeOpeningAMessage() {
        let session = MailSession.make()
        let closed = PaneCloseCounter()
        session.attachConversationAskMailHost(beforeOpening: { closed.value += 1 })

        session.conversationAskMail.host.openMessage(MailKnowledgeSource(
            id: "S1", messageID: MessageID("m2"), conversationKey: "thread-plan", mailboxPath: "INBOX",
            subject: "Quarterly planning", sender: "Maria Chen", sentAt: nil, snippet: "Good catch"
        ))

        XCTAssertEqual(closed.value, 1)
        XCTAssertTrue(session.conversationAI.askMail === session.conversationAskMail)
        XCTAssertFalse(session.conversationAskMail === session.askMail, "the pane never mixes with global Ask Mail")
    }

    /// A reply or draft to a message of the open conversation goes through the host's own
    /// compose path, the one Edit in Compose uses, which waits for the pane to close.
    func testConversationAskMailComposesInThisConversationThroughTheHostsComposePath() async throws {
        let session = MailSession.make(viewModel: .designPreview())
        let messageID = try XCTUnwrap(session.inboxSnapshot.model.selectedThread.messages.last?.id)
        session.openMailboxMessage(messageID, destination: .allInboxes, from: session.mailbox.currentListContext())
        await session.inboxSnapshot.refresh(selectedMessageID: messageID)
        let closed = PaneCloseCounter()
        var requests: [ComposeRequest] = []
        session.attachConversationAskMailHost(
            beforeOpening: { closed.value += 1 },
            openCompose: { requests.append($0) }
        )

        session.conversationAskMail.host.reply(MessageID(messageID))
        session.conversationAskMail.host.openDraft(AskMailDraftBlock(
            id: "draft", replyToMessageID: MessageID(messageID), recipientName: "Maria Chen",
            recipientAddress: "maria@northwind.example", subject: "Re: Quarterly planning", body: "Thursday works."
        ))

        XCTAssertEqual(requests, [
            .reply(messageID: messageID),
            .aiDraftReply(messageID: messageID, bodyMarkdown: "Thursday works.", recipient: "maria@northwind.example"),
        ])
        XCTAssertEqual(closed.value, 0, "the compose path closes the pane itself")
        XCTAssertFalse(session.compose.isPresented, "Compose waits for the pane to close")
    }

    /// A reply target outside the open conversation is looked up in the pane's own Ask Mail.
    func testConversationAskMailFindsItsReplyTargetInItsOwnAnswers() async {
        let session = MailSession.make(
            conversationAskMail: AskMailViewModel(handler: CitingAskMailHandler(
                messageID: "m9", mailboxPath: "[Gmail]/Sent Mail"
            )),
            composerPresentationPolicy: .runtimeWindow
        )
        session.conversationAI.setConversation(planContext(selected: "m2"))
        await session.conversationAI.ask("Who sent it?")?.value
        session.attachConversationAskMailHost(beforeOpening: {}, openCompose: { _ in })

        session.conversationAskMail.host.reply(MessageID("m9"))

        XCTAssertEqual(session.mailbox.selectedMessageID, "m9")
        XCTAssertEqual(session.mailbox.selectedDestination, .sent)
    }

    /// The pane reports a reply target it couldn't open; the hidden global Ask Mail doesn't.
    func testConversationAskMailReportsAnUnopenableReplyTargetInThePane() async {
        let session = MailSession.make()
        session.attachConversationAskMailHost(beforeOpening: {}, openCompose: { _ in })

        session.conversationAskMail.host.reply(MessageID("missing"))

        for _ in 0..<200 where session.conversationAskMail.statusMessage == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.conversationAskMail.statusMessage, "Couldn't open that message to reply.")
        XCTAssertNil(session.askMail.statusMessage)
    }

    /// The hosted pane opens the Ask route on this conversation's scoped Ask Mail, with the
    /// asked turn, and tells its host so the iPhone sheet can grow.
    func testPaneRendersTheAskRoute() async {
        let model = makeAskModel(handler: ScopedAskMailHandler())
        model.setConversation(planContext(selected: "m2"))
        let enteredAsk = PaneCloseCounter()
        let host = NSHostingView(rootView: ConversationAIPane(
            model: model, translationLanguage: TranslationLanguageOption(id: "en", localizedName: "English"),
            readOnlyReason: nil, dismissAfterTranslate: nil, openCompose: { _ in },
            didEnterAsk: { enteredAsk.value += 1 }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 640)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(enteredAsk.value, 0)

        await model.ask("What do they need?")?.value
        for _ in 0..<100 where enteredAsk.value == 0 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.route, .ask)
        XCTAssertEqual(enteredAsk.value, 1, "entering the Ask route tells the host")
        XCTAssertEqual(model.askMail.scope, .activeConversation)
        XCTAssertEqual(model.askMail.activeContext?.conversationKey, "thread-plan")
        XCTAssertEqual(model.askMail.turns.map(\.question), ["What do they need?"])
        XCTAssertEqual(model.askMail.turns.first?.answer.text, "They need the salary certificate.")
    }
}

@MainActor
private final class PaneCloseCounter {
    var value = 0
}

@MainActor
func makeAskModel(handler: any AskMailHandling) -> ConversationAIPaneModel {
    ConversationAIPaneModel(
        assistant: ThreadAIAssistantViewModel(assistant: PaneAssistant()),
        translation: ThreadTranslationViewModel(handler: UnconfiguredThreadTranslationHandler()),
        askMail: AskMailViewModel(handler: handler)
    )
}

/// Records each question's scope and conversation; when `gated`, holds the answer until `release()`.
final class ScopedAskMailHandler: AskMailHandling, @unchecked Sendable {
    struct Request: Equatable {
        let question: String
        let scope: MailRetrievalScope
        let conversationKey: String?
    }

    private let lock = NSLock()
    private let gated: Bool
    private var storage: [Request] = []
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    private var askedWaiters: [CheckedContinuation<Void, Never>] = []

    init(gated: Bool = false) { self.gated = gated }

    var requests: [Request] { lock.withLock { storage } }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            storage.append(Request(question: question, scope: scope, conversationKey: activeContext?.conversationKey))
            defer { askedWaiters = [] }
            return askedWaiters
        }
        waiters.forEach { $0.resume() }
        if gated {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return MailboxQuestionAnswer(
            answer: "They need the salary certificate.", sources: [], insufficientEvidence: false,
            providerName: "Stub", modelID: "stub", localOnly: true, retrievalMode: .lexical
        )
    }

    func waitUntilAsked() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if !storage.isEmpty { return true }
                askedWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}

/// Answers citing one message, filed in `mailboxPath`.
private struct CitingAskMailHandler: AskMailHandling {
    let messageID: String
    let mailboxPath: String

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        MailboxQuestionAnswer(
            answer: "Maria sent it [S1].",
            sources: [MailKnowledgeSource(
                id: "S1", messageID: MessageID(messageID), conversationKey: "thread-plan", mailboxPath: mailboxPath,
                subject: "Quarterly planning", sender: "Maria Chen", sentAt: nil, snippet: "Sent the certificate."
            )],
            insufficientEvidence: false,
            providerName: "Stub", modelID: "stub", localOnly: true, retrievalMode: .lexical
        )
    }
}
