import Foundation
import PlainpostAI
import PlainpostCore

/// One conversation as the ✦ pane sees it: the summary context (the selected message and a
/// content fingerprint), Ask Mail's scope, and the messages, oldest first.
struct ConversationAIContext: Sendable {
    let summary: EmailSummaryContext
    let askMail: AskMailActiveContext
    let messages: [ThreadMessageModel]

    /// Identifies the conversation: a different key is a different conversation.
    var conversationKey: String { askMail.conversationKey }
    /// The message a draft replies to: the selected one.
    var replyMessageID: MessageID { summary.messageID }
    /// The newest message: the one detected actions come from.
    var newestMessage: ThreadMessageModel? { messages.last }

    /// The context for `thread` with `selectedMessageID` selected, or nil while the thread
    /// doesn't hold that message yet.
    static func make(selectedMessageID: String, thread: ThreadDetailModel) -> ConversationAIContext? {
        guard let summary = PlainpostRootView.summaryContext(selectedMessageID: selectedMessageID, thread: thread),
              let askMail = PlainpostRootView.askMailContext(selectedMessageID: selectedMessageID, thread: thread)
        else { return nil }
        return ConversationAIContext(summary: summary, askMail: askMail, messages: thread.messages)
    }
}

extension ConversationAIContext: Equatable {
    /// The summary context's fingerprint already covers the messages' IDs and bodies.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.summary == rhs.summary && lhs.askMail == rhs.askMail
    }
}

/// Where the pane is: the overview, the draft preview, or Ask about this conversation.
enum ConversationAIRoute: Equatable, Sendable {
    case overview
    case draft
    case ask
}

/// A Draft reply tone chip. Custom… drafts with the person's own instructions, in a neutral tone.
enum ConversationDraftTone: String, CaseIterable, Identifiable, Sendable {
    case short, friendly, formal, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: "Short"
        case .friendly: "Friendly"
        case .formal: "Formal"
        case .custom: "Custom…"
        }
    }

    var draftTone: DraftTone {
        switch self {
        case .short: .concise
        case .friendly: .friendly
        case .formal: .formal
        case .custom: .neutral
        }
    }
}

/// The draft preview's state. A draft arrives whole; nothing streams.
enum ConversationDraftState: Equatable, Sendable {
    case idle
    case drafting
    case ready
    case failed(String)
}

/// Coordinates the existing AI models for the conversation the ✦ pane shows; it holds no AI
/// logic of its own. The summary and drafts come from `ThreadAIAssistantViewModel`, Translate
/// from `ThreadTranslationViewModel`, and Ask from an `AskMailViewModel` scoped to the
/// conversation. Another conversation cancels in-flight work, drops late results, and resets
/// the route, the draft and the Ask turns.
@MainActor
final class ConversationAIPaneModel: ObservableObject {
    @Published private(set) var route: ConversationAIRoute = .overview
    @Published private(set) var context: ConversationAIContext?
    @Published private(set) var draftTone: ConversationDraftTone?
    @Published var draftInstructions = ""
    @Published private(set) var draftPreview: Draft?
    @Published private(set) var draftState: ConversationDraftState = .idle
    /// The language of the conversation's original bodies ("German"), for the translation pill;
    /// nil when it can't be told.
    @Published private(set) var sourceLanguageName: String?
    /// Chips under the summary; empty while detecting or when nothing was found.
    @Published private(set) var detectedActions: [ConversationDetectedAction] = []
    @Published private(set) var isDetectingActions = false
    /// Chips whose event or reminder is being written; a second tap writes nothing.
    @Published private(set) var performingActionIDs: Set<ConversationDetectedAction.ID> = []

    /// The turn ID detected-action statuses are kept under in `askMail`.
    static let detectedActionsTurnID = "conversation-detected"

    let assistant: ThreadAIAssistantViewModel
    let translation: ThreadTranslationViewModel
    /// Ask Mail scoped to this conversation, separate from the global Ask Mail.
    let askMail: AskMailViewModel

    /// Advances on every conversation change; work started before it is dropped.
    private var conversationGeneration = 0
    private var isPaneVisible = false
    private var summaryTask: Task<Void, Never>?
    /// The conversation whose summary the person asked for. Opening the pane never summarizes.
    @Published private(set) var summaryRequestedKey: String?
    private var summaryTaskKey: String?
    /// Advances with every summary load the pane starts.
    private var summaryTaskGeneration = 0
    private var draftTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private let detector: any ConversationActionDetecting
    private var detectionTask: Task<Void, Never>?
    private var detectionKey: String?
    /// Detected chips per newest message and content fingerprint.
    private var detectionCache: [String: [ConversationDetectedAction]] = [:]
    private let languageName: ([String]) -> String?

    init(
        assistant: ThreadAIAssistantViewModel,
        translation: ThreadTranslationViewModel,
        askMail: AskMailViewModel,
        detector: any ConversationActionDetecting = NoConversationActionDetector(),
        languageName: @escaping ([String]) -> String? = { ConversationLanguage.dominantLanguageName(of: $0) }
    ) {
        self.assistant = assistant
        self.translation = translation
        self.askMail = askMail
        self.detector = detector
        self.languageName = languageName
        askMail.scope = .activeConversation
    }

    var localityLabel: String { assistant.localityLabel }

    /// The assistant's summary state is this conversation's. Until it's prepared, it is still the
    /// previous conversation's and must not show, even for a frame.
    var summaryIsCurrent: Bool {
        context.map { assistant.isPrepared(for: $0.summary) } ?? false
    }

    /// This conversation's summary failed to load although AI is available (a provider error,
    /// a timeout): the pane offers "Check again", which loads it again.
    var summaryFailed: Bool {
        summaryIsCurrent && !assistant.isWorking && assistant.summaryText == nil
            && assistant.summaryAvailability.isAvailable && assistant.statusMessage != nil
    }

    // MARK: Conversation

    /// Points the pane at `newContext`. A different conversation resets the pane; the same
    /// conversation with another selected message or a new reply only updates the context, and a
    /// draft still being written is written again for the new context (preparing it drops the
    /// draft in flight).
    func setConversation(_ newContext: ConversationAIContext?) {
        guard newContext != context else { return }
        let isNewConversation = newContext?.conversationKey != context?.conversationKey
        context = newContext
        sourceLanguageName = newContext.flatMap { languageName($0.messages.map(\.safeBodyText)) }
        if isNewConversation {
            resetForNewConversation()
        }
        askMail.scope = .activeConversation
        askMail.setActiveContext(newContext?.askMail)
        if let newContext, !assistant.isPrepared(for: newContext.summary) {
            assistant.prepareSummary(for: newContext.summary)
            if !isNewConversation, draftState == .drafting {
                regenerateDraft()
            }
        }
        if isPaneVisible {
            startPaneWork()
        }
    }

    /// The assistant was configured again (launch, or another AI provider): it forgot the
    /// prepared conversation, its summaries and any draft in flight. Prepares this conversation
    /// again, reloads its summary and detects actions again while the pane shows, and writes a
    /// draft in flight again.
    func assistantDidReconfigure() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryTaskKey = nil
        // Detections came from the previous provider, and "nothing found" may only mean it
        // was unavailable: detect again with this one.
        detectionTask?.cancel()
        detectionTask = nil
        detectionKey = nil
        detectionCache = [:]
        guard let context else { return }
        assistant.prepareSummary(for: context.summary)
        if draftState == .drafting {
            regenerateDraft()
        }
        if isPaneVisible {
            startPaneWork()
        }
    }

    /// The conversation screen for `messageID` went away: clear the pane, unless another
    /// conversation already took its place.
    func leave(messageID: String) {
        guard context?.replyMessageID.rawValue == messageID else { return }
        setConversation(nil)
    }

    func paneDidAppear() {
        isPaneVisible = true
        assistant.refreshAvailability()
        translation.refreshAvailability()
        askMail.refreshAvailability()
        startPaneWork()
    }

    /// Closing the pane cancels nothing: a summary still loading is ready next time.
    func paneDidDisappear() {
        isPaneVisible = false
    }

    /// "Check again" after AI was unavailable: reloads the summary and detects the newest
    /// message's actions again.
    func checkAgain() {
        assistant.checkAvailability()
        translation.refreshAvailability()
        askMail.checkAvailability()
        if summaryWasRequested {
            ensureSummaryLoad()
        }
        if let key = detectionCacheKey {
            detectionCache[key] = nil
        }
        ensureDetection()
    }

    /// Summaries cost a model run, so the pane waits for "Summarize" instead of starting one.
    private func startPaneWork() {
        if summaryWasRequested {
            ensureSummaryLoad()
        }
        ensureDetection()
    }

    private func resetForNewConversation() {
        conversationGeneration &+= 1
        summaryTask?.cancel()
        summaryTask = nil
        summaryTaskKey = nil
        summaryRequestedKey = nil
        assistant.cancelSummaryLoad()
        draftTask?.cancel()
        draftTask = nil
        askTask?.cancel()
        askTask = nil
        // Drops a late answer and forgets the previous conversation's turns.
        askMail.newConversation()
        detectionTask?.cancel()
        detectionTask = nil
        detectionKey = nil
        detectedActions = []
        isDetectingActions = false
        route = .overview
        draftTone = nil
        draftInstructions = ""
        draftPreview = nil
        draftState = .idle
    }

    // MARK: Summary

    private var summaryWasRequested: Bool {
        summaryRequestedKey != nil && summaryRequestedKey == context?.summary.cacheKey
    }

    /// No summary was asked for this conversation yet: the pane offers "Summarize".
    var offersSummarize: Bool {
        summaryIsCurrent && !summaryWasRequested && !assistant.isWorking && assistant.summaryText == nil
            && assistant.summaryAvailability.isAvailable
    }

    /// "Summarize": the person asked for this conversation's summary.
    func summarize() {
        summaryRequestedKey = context?.summary.cacheKey
        ensureSummaryLoad()
    }

    /// Starts loading this conversation's summary unless it's loaded or loading. The load
    /// answers from the assistant's session cache when nothing changed.
    @discardableResult
    func ensureSummaryLoad() -> Task<Void, Never>? {
        guard let summaryContext = context?.summary else { return nil }
        if summaryTaskKey == summaryContext.cacheKey, let summaryTask {
            return summaryTask
        }
        if assistant.isPrepared(for: summaryContext), assistant.summaryText != nil {
            return nil
        }
        summaryTaskKey = summaryContext.cacheKey
        summaryTaskGeneration &+= 1
        let generation = summaryTaskGeneration
        let task = Task { [weak self, assistant] in
            await assistant.loadSummary(for: summaryContext)
            self?.summaryTaskDidFinish(generation: generation)
        }
        summaryTask = task
        return task
    }

    /// A cancelled load can finish after a newer one for the same key started; only the newest
    /// clears the slot.
    private func summaryTaskDidFinish(generation: Int) {
        guard summaryTaskGeneration == generation else { return }
        summaryTask = nil
        summaryTaskKey = nil
    }

    // MARK: Detected actions

    /// The detection cache's key for the newest message and its content.
    private var detectionCacheKey: String? {
        context?.newestMessage.map { "\($0.id)|\($0.translationSourceFingerprint)" }
    }

    /// Detects actions in the newest message, once per message and content; an answer, even
    /// "nothing found", is cached after that. A failed detection isn't cached: opening the pane
    /// or "Check again" detects again.
    @discardableResult
    func ensureDetection() -> Task<Void, Never>? {
        guard let newest = context?.newestMessage, let key = detectionCacheKey else { return nil }
        if let cached = detectionCache[key] {
            detectedActions = cached
            isDetectingActions = false
            return nil
        }
        if detectionKey == key, let detectionTask {
            return detectionTask
        }
        detectionTask?.cancel()
        detectionKey = key
        detectedActions = []
        isDetectingActions = true
        let generation = conversationGeneration
        let messageID = MessageID(newest.id)
        let task = Task { [weak self, detector] in
            let card: AskMailCardBlock?
            let failed: Bool
            do {
                card = try await detector.detectedCard(messageID: messageID)
                failed = false
            } catch {
                card = nil
                failed = true
            }
            guard let self, !Task.isCancelled, generation == self.conversationGeneration,
                  self.detectionKey == key else { return }
            let actions = ConversationDetectedAction.actions(from: card, now: Date(), calendar: .current, locale: .current)
            if !failed {
                self.detectionCache[key] = actions
            }
            self.detectedActions = actions
            self.isDetectingActions = false
            self.detectionTask = nil
        }
        detectionTask = task
        return task
    }

    /// Adds the event or reminder through Ask Mail's writer: the same permission flow and wording.
    /// While one write for `action` runs, another returns without writing.
    func perform(_ action: ConversationDetectedAction) async {
        guard performingActionIDs.insert(action.id).inserted else { return }
        defer { performingActionIDs.remove(action.id) }
        switch action.kind {
        case .calendar: await askMail.addToCalendar(action.card, turnID: Self.detectedActionsTurnID)
        case .reminder: await askMail.addReminder(action.card, turnID: Self.detectedActionsTurnID)
        }
    }

    func isPerforming(_ action: ConversationDetectedAction) -> Bool {
        performingActionIDs.contains(action.id)
    }

    func status(for action: ConversationDetectedAction) -> AskMailCalendarStatus? {
        let status = askMail.calendarStatus(turnID: Self.detectedActionsTurnID, cardID: action.card.id)
        return action.kind == .calendar ? status.event : status.reminder
    }

    // MARK: Routes

    func showOverview() {
        route = .overview
    }

    func showDraft() {
        guard context != nil else { return }
        route = .draft
    }

    /// Asks about this conversation and opens the Ask route. Blank questions ask nothing.
    @discardableResult
    func ask(_ question: String) -> Task<Void, Never>? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context != nil, !trimmed.isEmpty, !askMail.isWorking else { return nil }
        route = .ask
        let task = Task { [askMail] in
            await askMail.ask(trimmed)
        }
        askTask = task
        return task
    }

    // MARK: Draft

    /// Picks a tone. Short, Friendly and Formal draft at once; Custom… waits for instructions.
    @discardableResult
    func chooseTone(_ tone: ConversationDraftTone) -> Task<Void, Never>? {
        draftTone = tone
        guard tone != .custom else {
            draftTask?.cancel()
            draftTask = nil
            draftPreview = nil
            draftState = .idle
            return nil
        }
        return regenerateDraft()
    }

    @discardableResult
    func submitCustomInstructions() -> Task<Void, Never>? {
        guard draftTone == .custom else { return nil }
        return regenerateDraft()
    }

    /// Drafts again with the same tone and instructions. Custom… with blank instructions drafts
    /// nothing.
    @discardableResult
    func regenerateDraft() -> Task<Void, Never>? {
        guard context != nil, let tone = draftTone else { return nil }
        let instructions = tone == .custom
            ? draftInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard tone != .custom || !instructions.isEmpty else { return nil }
        draftTask?.cancel()
        let generation = conversationGeneration
        draftPreview = nil
        draftState = .drafting
        let task = Task { [weak self, assistant] in
            let draft = await assistant.draftReply(tone: tone.draftTone, instructions: instructions)
            guard let self, !Task.isCancelled, generation == self.conversationGeneration else { return }
            if let draft {
                self.draftPreview = draft
                self.draftState = .ready
            } else {
                self.draftState = .failed(assistant.replyStatusMessage ?? "Reply draft unavailable. Try again.")
            }
        }
        draftTask = task
        return task
    }

    /// Draft reply's availability: a read-only account can't reply (the same reason Compose
    /// shows); otherwise the AI provider decides.
    func draftAvailability(readOnlyReason: String?) -> AIActionAvailability {
        if let readOnlyReason {
            return AIActionAvailability(isAvailable: false, reason: readOnlyReason)
        }
        return assistant.replyAvailability
    }

    /// The compose request that opens the previewed draft in Compose, filled in, through the
    /// same path as Ask Mail's draft block. Nil while read-only or without a preview.
    func editInComposeRequest(readOnlyReason: String?) -> ComposeRequest? {
        guard readOnlyReason == nil, let context, let draft = draftPreview else { return nil }
        return .aiDraftReply(
            messageID: context.replyMessageID.rawValue,
            bodyMarkdown: draft.bodyMarkdown ?? draft.bodyPlain,
            recipient: draft.to.map(\.rawValue).joined(separator: ", ")
        )
    }

    // MARK: Translate

    func translateButtonTitle(targetLanguageName: String) -> String {
        if let progress = translation.progressText {
            return "Translating \(progress)…"
        }
        return translation.displayMode == .translated ? "Show original" : "Translate to \(targetLanguageName)"
    }

    /// Translates the conversation's bodies in place, or shows the originals again.
    @discardableResult
    func toggleTranslation(configuration: ThreadTranslationConfiguration) -> Task<Void, Never>? {
        if translation.displayMode == .translated {
            translation.showOriginal()
            return nil
        }
        guard let messages = context?.messages, !messages.isEmpty else { return nil }
        return Task { [translation] in
            await translation.translate(messages: messages, configuration: configuration)
        }
    }
}
