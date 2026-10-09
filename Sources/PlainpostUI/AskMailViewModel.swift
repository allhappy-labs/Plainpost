import Foundation
import PlainpostAI
import PlainpostCore

public struct AskMailActiveContext: Equatable, Sendable {
    public let conversationKey: String
    public let subject: String
    public let messageIDs: [MessageID]

    public init(conversationKey: String, subject: String, messageIDs: [MessageID]) {
        self.conversationKey = conversationKey
        self.subject = subject
        self.messageIDs = messageIDs
    }
}

public struct AskMailTurn: Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    public let answer: AskMailAnswer

    public init(id: String = UUID().uuidString, question: String, answer: AskMailAnswer) {
        self.id = id
        self.question = question
        self.answer = answer
    }

    /// Every message source the answer cites, derived from its numbered citations.
    public var sources: [MailKnowledgeSource] { answer.citations.map(\.source) }
}

/// A starter question shown in the Ask Mail empty state (e.g. "12 unread — Show unread mail").
public struct AskMailStarter: Equatable, Identifiable, Sendable {
    public let id: String
    public let count: String
    public let title: String
    public let detail: String
    public let question: String

    public init(id: String, count: String, title: String, detail: String, question: String) {
        self.id = id
        self.count = count
        self.title = title
        self.detail = detail
        self.question = question
    }
}

/// Builds the empty-state starters from mailbox counts: unread and people waiting appear only
/// when there is something to show; "This week" is always last with an icon-only count.
public enum AskMailStarterBuilder {
    /// Counts unread inbox mail and unread personal inbox mail with `count`. A runtime that must
    /// scope mail to one account but has none selected shows only "This week" (no cross-account counts).
    public static func starters(
        requiresAccountScope: Bool,
        accountID: AccountID?,
        count: (MailKnowledgeFilter, AccountID?) -> Int
    ) -> [AskMailStarter] {
        guard !requiresAccountScope || accountID != nil else {
            return starters(unread: 0, peopleUnread: 0)
        }
        return starters(
            unread: count(MailKnowledgeFilter(unreadOnly: true, mailbox: .inbox), accountID),
            peopleUnread: count(MailKnowledgeFilter(unreadOnly: true, mailbox: .inbox, categories: [.personal]), accountID)
        )
    }

    public static func starters(unread: Int, peopleUnread: Int) -> [AskMailStarter] {
        var starters: [AskMailStarter] = []
        if unread > 0 {
            starters.append(AskMailStarter(
                id: "unread",
                count: "\(unread)",
                title: "Unread messages",
                detail: "Group them so you can clear the noise",
                question: "Group my unread emails so I can clean them up"
            ))
        }
        if peopleUnread > 0 {
            starters.append(AskMailStarter(
                id: "people",
                count: "\(peopleUnread)",
                title: "People waiting on you",
                detail: "Unread mail from people",
                question: "Who is waiting on a reply from me?"
            ))
        }
        starters.append(AskMailStarter(
            id: "week",
            count: "",
            title: "This week",
            detail: "Bills, trips and events with a date",
            question: "What do I need to deal with this week?"
        ))
        return starters
    }
}

/// Actions Ask Mail delegates back to the hosting screen: opening a message, replying, opening a
/// draft in the composer, and performing a mail mutation. `mailAction` and `allowsMutations`
/// return `false` until the host is attached with `setHost`, so nothing mutates mail before then.
@MainActor
public struct AskMailHostActions {
    public var openMessage: @MainActor (MailKnowledgeSource) -> Void
    public var reply: @MainActor (MessageID) -> Void
    public var openDraft: @MainActor (AskMailDraftBlock) -> Void
    public var mailAction: @MainActor (InboxMailAction, MessageID) async -> Bool
    public var allowsMutations: @MainActor () -> Bool
    /// Called once after each bulk-action section finishes, so the host refreshes once per batch.
    public var mailActionsSettled: @MainActor () -> Void

    public init(
        openMessage: @escaping @MainActor (MailKnowledgeSource) -> Void,
        reply: @escaping @MainActor (MessageID) -> Void,
        openDraft: @escaping @MainActor (AskMailDraftBlock) -> Void,
        mailAction: @escaping @MainActor (InboxMailAction, MessageID) async -> Bool,
        allowsMutations: @escaping @MainActor () -> Bool,
        mailActionsSettled: @escaping @MainActor () -> Void = {}
    ) {
        self.openMessage = openMessage
        self.reply = reply
        self.openDraft = openDraft
        self.mailAction = mailAction
        self.allowsMutations = allowsMutations
        self.mailActionsSettled = mailActionsSettled
    }

    public static let preview = AskMailHostActions(
        openMessage: { _ in },
        reply: { _ in },
        openDraft: { _ in },
        mailAction: { _, _ in true },
        allowsMutations: { true }
    )

    /// Refuses every mutation; the default until `setHost` attaches a real host.
    static let disabled = AskMailHostActions(
        openMessage: { _ in },
        reply: { _ in },
        openDraft: { _ in },
        mailAction: { _, _ in false },
        allowsMutations: { false }
    )
}

public enum AskMailCalendarAction: String, Sendable { case event, reminder }

/// Result of a card's "Add to Calendar" or "Remind me" action.
public enum AskMailCalendarStatus: Equatable, Sendable {
    case eventAdded
    case reminderAdded
    case failed(String)
}

public protocol AskMailHandling: Sendable {
    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer

    /// Asks with a "Try instead" filter override. Handlers that cannot widen filters ignore it.
    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn],
        filterOverride: AskMailFilterOverride?
    ) async throws -> MailboxQuestionAnswer
}

public extension AskMailHandling {
    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn],
        filterOverride: AskMailFilterOverride?
    ) async throws -> MailboxQuestionAnswer {
        try await ask(question: question, scope: scope, activeContext: activeContext, priorTurns: priorTurns)
    }
}

@MainActor
public final class AskMailViewModel: ObservableObject {
    @Published public var input = ""
    @Published public var scope: MailRetrievalScope = .allMail
    @Published public private(set) var activeContext: AskMailActiveContext?
    @Published public private(set) var turns: [AskMailTurn] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var pendingQuestion: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var providerName: String
    @Published public private(set) var modelID = ""
    /// Whether the provider runs on this device: from configure (provider capability), then from
    /// each answer; `nil` until known, so the privacy copy never claims "this device" early.
    @Published public private(set) var localOnly: Bool?
    @Published public private(set) var actionAvailability: AIActionAvailability = .available
    @Published public private(set) var lastAvailabilityCheck: Date?
    @Published public private(set) var starters: [AskMailStarter] = []
    /// Outcome of "Add to Calendar" / "Remind me", keyed by `calendarStatusKey(turnID:cardID:action:)`
    /// so each action on each answer's card keeps its own status.
    @Published public private(set) var calendarStatuses: [String: AskMailCalendarStatus] = [:]

    /// Owns pending bulk actions across the view model's lifetime so a commit scheduled while
    /// the panel is open still runs to completion after the panel closes.
    public private(set) lazy var actions: AskMailActionCoordinator = AskMailActionCoordinator(
        graceDelay: actionGraceDelay,
        perform: { [weak self] action, messageID in
            await self?.host.mailAction(action, messageID) ?? false
        },
        onBatchSettled: { [weak self] in self?.host.mailActionsSettled() }
    )
    /// Undo window for bulk actions; read once when `actions` is first used (tests shorten it).
    var actionGraceDelay: Duration = .seconds(5)
    @Published public private(set) var host: AskMailHostActions = .disabled
    public var calendarWriter: any AskMailCalendarWriting = EventKitAskMailCalendarWriter()

    private var handler: any AskMailHandling
    private var availability: () -> AIActionAvailability
    private var requestGeneration = 0
    private var starterSource: @MainActor () -> [AskMailStarter] = { [] }

    public init(
        handler: any AskMailHandling,
        providerName: String = "On-device model",
        availability: @escaping () -> AIActionAvailability = { .available }
    ) {
        self.handler = handler
        self.providerName = providerName
        self.availability = availability
        refreshAvailability()
    }

    public var canSend: Bool {
        actionAvailability.isAvailable && !isWorking
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (scope != .activeConversation || activeContext != nil)
    }

    public func setActiveContext(_ context: AskMailActiveContext?) {
        activeContext = context
    }

    public func clearActiveContext() {
        activeContext = nil
        scope = .allMail
    }

    /// Attaches the hosting screen's actions. Until called, `mailAction` and `allowsMutations`
    /// refuse every mutation (see `AskMailHostActions.disabled`).
    public func setHost(_ host: AskMailHostActions) {
        self.host = host
    }

    /// Shows a problem from a host action (e.g. a reply target that could not be opened).
    public func reportHostProblem(_ message: String) {
        statusMessage = message
    }

    public func setStarterSource(_ source: @escaping @MainActor () -> [AskMailStarter]) {
        starterSource = source
        refreshStarters()
    }

    public func refreshStarters() {
        starters = starterSource()
    }

    /// The newest answer's source for `messageID` (citation, row, card or quote), so the host can
    /// open a reply or draft target in the mailbox it lives in.
    public func source(for messageID: MessageID) -> MailKnowledgeSource? {
        for turn in turns.reversed() {
            let answer = turn.answer
            if let citation = answer.citations.first(where: { $0.source.messageID == messageID }) {
                return citation.source
            }
            for block in answer.blocks {
                switch block {
                case .messages(let list):
                    for section in list.sections {
                        if let row = section.rows.first(where: { $0.messageID == messageID }) { return row.source }
                    }
                case .card(let card) where card.source.messageID == messageID:
                    return card.source
                case .quotes(let quotes):
                    if let quote = quotes.quotes.first(where: { $0.source.messageID == messageID }) { return quote.source }
                case .card, .draft, .options:
                    break
                }
            }
        }
        return nil
    }

    public func newConversation() {
        cancelAskTask()
        requestGeneration &+= 1
        turns = []
        input = ""
        statusMessage = nil
        isWorking = false
        pendingQuestion = nil
        // Pending/applying bulk actions belong to the view model, not the conversation; a reset
        // never cancels an in-flight action, it only forgets receipts that already finished.
        actions.reset()
    }

    /// Sets `input` to `question` and asks it, e.g. for a tapped starter or option chip.
    /// `override` widens the interpreted filters for a chosen "Try instead" option.
    public func ask(_ question: String, override: AskMailFilterOverride? = nil) async {
        input = question
        await askCurrentQuestion(filterOverride: override)
    }

    /// Cancels the in-flight request and its queued AI job: the question is restored so the
    /// person can edit or resend it. Leaving Ask Mail stops it too.
    public func stop() {
        cancelAskTask()
        requestGeneration &+= 1
        if let pendingQuestion {
            input = pendingQuestion
        }
        pendingQuestion = nil
        isWorking = false
        statusMessage = nil
    }

    public func askCurrentQuestion() async {
        await askCurrentQuestion(filterOverride: nil)
    }

    /// The running question. Cancelling it cancels its AI job, so an abandoned question
    /// never waits in the queue.
    private var askTask: Task<Void, Never>?

    private func cancelAskTask() {
        askTask?.cancel()
        askTask = nil
    }

    private func askCurrentQuestion(filterOverride: AskMailFilterOverride?) async {
        cancelAskTask()
        let task = Task { await performAsk(filterOverride: filterOverride) }
        askTask = task
        await task.value
    }

    private func performAsk(filterOverride: AskMailFilterOverride?) async {
        refreshAvailability()
        guard actionAvailability.isAvailable else {
            statusMessage = actionAvailability.reason
            return
        }
        guard canSend else { return }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedContext = activeContext
        let capturedScope = scope
        let capturedTurns = turns
        requestGeneration &+= 1
        let generation = requestGeneration
        input = ""
        pendingQuestion = question
        statusMessage = "Searching mail…"
        isWorking = true
        do {
            let result = try await handler.ask(
                question: question,
                scope: capturedScope,
                activeContext: capturedContext,
                priorTurns: capturedTurns,
                filterOverride: filterOverride
            )
            guard generation == requestGeneration else { return }
            let answer = result.askMailAnswer ?? AskMailEvidenceComposer.answer(
                from: result, question: question, searched: []
            )
            turns.append(AskMailTurn(question: question, answer: answer))
            providerName = result.providerName
            modelID = result.modelID
            localOnly = result.localOnly
            statusMessage = nil
            isWorking = false
            pendingQuestion = nil
        } catch {
            guard generation == requestGeneration else { return }
            if input.isEmpty { input = question }
            if let providerError = error as? AIProviderError {
                switch providerError {
                case .unsupportedLanguageOrLocale:
                    statusMessage = "This language is not supported by the selected AI provider. Try another language or provider."
                case .guardrailViolation:
                    statusMessage = "The selected AI provider could not complete this request. Edit the question and try again."
                case .remoteEndpointDisallowed:
                    statusMessage = "Remote AI is disabled. Choose a local AI provider."
                default:
                    statusMessage = "Answer unavailable. Try again."
                }
            } else {
                statusMessage = "Answer unavailable. Try again."
            }
            isWorking = false
            pendingQuestion = nil
        }
    }

    public func addToCalendar(_ card: AskMailCardBlock, turnID: String) async {
        guard let item = card.calendarItem else { return }
        let key = Self.calendarStatusKey(turnID: turnID, cardID: card.id, action: .event)
        do {
            try await calendarWriter.addEvent(item)
            calendarStatuses[key] = .eventAdded
        } catch AskMailCalendarError.accessDenied {
            calendarStatuses[key] = .failed("Allow calendar access in Settings to add events.")
        } catch {
            calendarStatuses[key] = .failed("Couldn't add it. Try again.")
        }
    }

    public func addReminder(_ card: AskMailCardBlock, turnID: String) async {
        guard let item = card.reminderItem else { return }
        let key = Self.calendarStatusKey(turnID: turnID, cardID: card.id, action: .reminder)
        do {
            try await calendarWriter.addReminder(item)
            calendarStatuses[key] = .reminderAdded
        } catch AskMailCalendarError.accessDenied {
            calendarStatuses[key] = .failed("Allow reminders access in Settings to add reminders.")
        } catch {
            calendarStatuses[key] = .failed("Couldn't add it. Try again.")
        }
    }

    /// The event and reminder status for one card in one answer.
    public func calendarStatus(turnID: String, cardID: String) -> (event: AskMailCalendarStatus?, reminder: AskMailCalendarStatus?) {
        (calendarStatuses[Self.calendarStatusKey(turnID: turnID, cardID: cardID, action: .event)],
         calendarStatuses[Self.calendarStatusKey(turnID: turnID, cardID: cardID, action: .reminder)])
    }

    static func calendarStatusKey(turnID: String, cardID: String, action: AskMailCalendarAction) -> String {
        "\(turnID)/\(cardID)/\(action.rawValue)"
    }

    public func configure(
        handler: any AskMailHandling,
        providerName: String,
        localOnly: Bool? = nil,
        availability: @escaping () -> AIActionAvailability = { .available }
    ) {
        requestGeneration &+= 1
        self.handler = handler
        self.providerName = providerName
        self.availability = availability
        lastAvailabilityCheck = nil
        modelID = ""
        self.localOnly = localOnly
        newConversation()
        refreshAvailability()
    }

    public func refreshAvailability() {
        let previousReason = actionAvailability.reason
        actionAvailability = availability()
        if actionAvailability.isAvailable && statusMessage == previousReason {
            statusMessage = nil
        }
    }

    public func checkAvailability() {
        refreshAvailability()
        lastAvailabilityCheck = .now
    }

    public static func preview() -> AskMailViewModel {
        AskMailViewModel(handler: PreviewAskMailHandler(), providerName: "Apple Foundation Models")
    }

    public static func designPreview() -> AskMailViewModel {
        let viewModel = AskMailViewModel(handler: PreviewAskMailHandler(), providerName: "Apple Foundation Models")
        viewModel.host = .preview
        viewModel.localOnly = true
        viewModel.activeContext = AskMailActiveContext(
            conversationKey: "thr_intro",
            subject: "Introduction: Max and Emily",
            messageIDs: [MessageID("jessica-intro")]
        )
        let introSource = MailKnowledgeSource(
            id: "S1",
            messageID: MessageID("jessica-intro"),
            conversationKey: "thr_intro",
            mailboxPath: "INBOX",
            subject: "Introduction: Max and Emily",
            sender: "Jessica Sun",
            sentAt: Date(),
            snippet: "Would love to see if there’s a fit for a quick intro this week."
        )
        let cleanupPlan = AskMailQueryInterpreter.plan(
            question: "Clean up my unread mail", now: Date(), calendar: .current
        )
        let cleanupMessages = designPreviewMessages + designPreviewBulkMessages
        let cleanupResult = MailFilterResult(totalCount: cleanupMessages.count, messages: cleanupMessages)
        let cleanupAnswer = AskMailListComposer.answer(plan: cleanupPlan, result: cleanupResult)
        viewModel.turns = [
            AskMailTurn(
                question: "What is this introduction about?",
                answer: AskMailAnswer(
                    text: "Jessica introduced Max Harper to Emily Jones for a possible strategic-finance conversation this week. [1]",
                    citations: [AskMailCitation(number: 1, source: introSource)]
                )
            ),
            AskMailTurn(question: "Clean up my unread mail", answer: cleanupAnswer)
        ]
        return viewModel
    }

    /// Design fixture: fixed turns (or a pending question in the working state) with every
    /// action enabled so block controls render.
    @_spi(DesignPreview)
    public static func designPreview(
        turns: [AskMailTurn],
        pendingQuestion: String? = nil,
        starters: [AskMailStarter] = []
    ) -> AskMailViewModel {
        let viewModel = AskMailViewModel(handler: PreviewAskMailHandler(), providerName: "Apple Foundation Models")
        viewModel.host = .preview
        viewModel.localOnly = true
        viewModel.turns = turns
        viewModel.setStarterSource { starters }
        if let pendingQuestion {
            viewModel.pendingQuestion = pendingQuestion
            viewModel.isWorking = true
            viewModel.statusMessage = "Searching your mail…"
        }
        return viewModel
    }

    /// Extra unread automated mail so the design preview shows capped sections ("Show all 21").
    private static let designPreviewBulkMessages: [MessageSummary] = {
        let senders: [(name: String, address: String, category: SmartCategory, count: Int)] = [
            ("GitHub", "notifications@github.com", .notification, 20),
            ("Weekly Digest", "news@example.com", .newsletter, 17),
            ("Stripe", "receipts@stripe.com", .receipt, 6)
        ]
        return senders.flatMap { sender in
            (1...sender.count).map { index in
                MessageSummary(
                    id: MessageID("preview-\(sender.category.rawValue)-bulk-\(index)"), threadID: nil,
                    from: EmailAddress(sender.address), fromDisplayName: sender.name,
                    subject: "\(sender.name) update \(index)", preview: "Automated message \(index).",
                    smartCategory: sender.category, isSeen: false,
                    sentAt: Date().addingTimeInterval(TimeInterval(-index * 3_600))
                )
            }
        }
    }()

    private static let designPreviewMessages: [MessageSummary] = [
        MessageSummary(
            id: MessageID("preview-newsletter-1"), threadID: nil,
            from: EmailAddress("news@example.com"), fromDisplayName: "Weekly Digest",
            subject: "This week in design", preview: "Five links worth your time.",
            smartCategory: .newsletter, isSeen: false, sentAt: Date()
        ),
        MessageSummary(
            id: MessageID("preview-newsletter-2"), threadID: nil,
            from: EmailAddress("updates@example.com"), fromDisplayName: "Product Updates",
            subject: "New features shipped", preview: "See what changed this release.",
            smartCategory: .newsletter, isSeen: false, sentAt: Date()
        ),
        MessageSummary(
            id: MessageID("preview-notification-1"), threadID: nil,
            from: EmailAddress("no-reply@service.example.com"), fromDisplayName: "Service Alerts",
            subject: "Your report is ready", preview: "Download it from the dashboard.",
            smartCategory: .notification, isSeen: false, sentAt: Date()
        ),
        MessageSummary(
            id: MessageID("preview-personal-1"), threadID: nil,
            from: EmailAddress("max@example.com"), fromDisplayName: "Max Harper",
            subject: "Quick question", preview: "Do you have a minute this week?",
            smartCategory: .personal, isSeen: false, sentAt: Date()
        )
    ]
}

private struct PreviewAskMailHandler: AskMailHandling {
    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        let source = MailKnowledgeSource(
            id: "S1",
            messageID: MessageID("msg_alice_1"),
            conversationKey: "availability",
            mailboxPath: "INBOX",
            subject: "Availability next Tuesday",
            sender: "Alice",
            sentAt: Date(),
            snippet: "Are you available next Tuesday?"
        )
        return MailboxQuestionAnswer(
            answer: "Alice proposed meeting next Tuesday and asked you to confirm a time. [S1]",
            sources: [source],
            insufficientEvidence: false,
            providerName: "Apple Foundation Models",
            modelID: "preview",
            localOnly: true,
            retrievalMode: .lexical,
            askMailAnswer: AskMailAnswer(
                text: "Alice proposed meeting next Tuesday and asked you to confirm a time. [1]",
                citations: [AskMailCitation(number: 1, source: source)]
            )
        )
    }
}
