import Foundation
import PlainpostAI
import PlainpostCore

public struct EmailSummaryContext: Equatable, Sendable {
    public let messageID: MessageID
    public let contentFingerprint: String

    public init(messageID: MessageID, contentFingerprint: String) {
        self.messageID = messageID
        self.contentFingerprint = contentFingerprint
    }

    var cacheKey: String {
        "\(messageID.rawValue)|\(contentFingerprint)"
    }
}

public struct ThreadAIAssistantSummaryResult: Equatable, Sendable {
    public let summaryText: String
    public let providerName: String
    public let modelID: String
    public let localOnly: Bool
    public let contextMessageIDs: [String]

    public init(
        summaryText: String,
        providerName: String,
        modelID: String,
        localOnly: Bool,
        contextMessageIDs: [String]
    ) {
        self.summaryText = summaryText
        self.providerName = providerName
        self.modelID = modelID
        self.localOnly = localOnly
        self.contextMessageIDs = contextMessageIDs
    }
}

public struct ThreadAIAssistantChatTurn: Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    public let answer: String

    public init(id: String = UUID().uuidString, question: String, answer: String) {
        self.id = id
        self.question = question
        self.answer = answer
    }
}

public struct ThreadAIAssistantAnswerResult: Equatable, Sendable {
    public let answer: String
    public let providerName: String
    public let modelID: String
    public let localOnly: Bool

    public init(answer: String, providerName: String, modelID: String, localOnly: Bool) {
        self.answer = answer
        self.providerName = providerName
        self.modelID = modelID
        self.localOnly = localOnly
    }
}

public protocol ThreadAIAssistantHandling: Sendable {
    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult
    func answerQuestion(
        messageID: MessageID,
        question: String,
        priorTurns: [ThreadAIAssistantChatTurn]
    ) async throws -> ThreadAIAssistantAnswerResult
    /// Drafts a reply to `messageID` in `tone`, following `instructions` (empty for none).
    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft
}

public extension ThreadAIAssistantHandling {
    func answerQuestion(
        messageID: MessageID,
        question: String,
        priorTurns: [ThreadAIAssistantChatTurn]
    ) async throws -> ThreadAIAssistantAnswerResult {
        throw PlainpostError.validationFailed("Thread questions are unavailable.")
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        throw PlainpostError.validationFailed("AI reply drafting is unavailable.")
    }
}

public final class LocalThreadAIAssistantService<Store: LocalAIStore>: ThreadAIAssistantHandling, @unchecked Sendable {
    private let provider: AIProvider
    private let service: LocalAIService<Store>
    private let store: Store
    private let actor: Actor

    public init(provider: AIProvider, store: Store, actor: Actor) {
        self.provider = provider
        self.service = LocalAIService(provider: provider, store: store)
        self.store = store
        self.actor = actor
    }

    public func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        guard let selectedMessage = store.messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let conversationKey = MailThreading.conversationKey(for: selectedMessage)
        let threadMessages = store.messages
            .filter { MailThreading.conversationKey(for: $0) == conversationKey }
            .sorted {
                let lhsDate = $0.sentAt ?? .distantPast
                let rhsDate = $1.sentAt ?? .distantPast
                return lhsDate == rhsDate ? $0.id.rawValue < $1.id.rawValue : lhsDate < rhsDate
            }
        let summary = try await service.summarizeThread(
            SummarizeThreadInput(threadID: ThreadID(conversationKey), style: .short),
            actor: actor
        )
        return ThreadAIAssistantSummaryResult(
            summaryText: summary.summary,
            providerName: provider.displayName,
            modelID: summary.modelID,
            localOnly: summary.localOnly,
            contextMessageIDs: threadMessages.map(\.id.rawValue)
        )
    }

    public func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        guard let threadID = store.messages.first(where: { $0.id == messageID })?.threadID else {
            throw PlainpostError.notFound("Thread not found.")
        }
        return try await service.draftReply(
            DraftReplyInput(threadID: threadID, tone: tone, instructions: instructions, replyAll: false),
            actor: actor
        )
    }

    public func answerQuestion(
        messageID: MessageID,
        question: String,
        priorTurns: [ThreadAIAssistantChatTurn]
    ) async throws -> ThreadAIAssistantAnswerResult {
        guard let selectedMessage = store.messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let conversationKey = MailThreading.conversationKey(for: selectedMessage)
        let result = try await service.answerThreadQuestion(
            AskThreadQuestionInput(
                threadID: ThreadID(conversationKey),
                question: question,
                priorTurns: priorTurns.map { ThreadQuestionTurn(question: $0.question, answer: $0.answer) }
            ),
            actor: actor
        )
        return ThreadAIAssistantAnswerResult(
            answer: result.answer,
            providerName: provider.displayName,
            modelID: result.modelID,
            localOnly: result.localOnly
        )
    }
}

@MainActor
public final class ThreadAIAssistantViewModel: ObservableObject {
    @Published public private(set) var summaryText: String?
    @Published public private(set) var providerName: String
    @Published public private(set) var modelID: String
    @Published public private(set) var localOnly: Bool
    @Published public private(set) var contextMessageIDs: [String]
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isWorking: Bool
    @Published public private(set) var isDraftingReply: Bool
    @Published public private(set) var replyStatusMessage: String?
    @Published public var chatInput: String
    @Published public private(set) var chatTurns: [ThreadAIAssistantChatTurn]
    @Published public private(set) var isAnsweringQuestion: Bool
    @Published public private(set) var chatStatusMessage: String?
    @Published public private(set) var summaryAvailability: AIActionAvailability = .available
    @Published public private(set) var replyAvailability: AIActionAvailability = .available
    @Published public private(set) var chatAvailability: AIActionAvailability = .available
    @Published public private(set) var lastAvailabilityCheck: Date?
    /// The resolved AI provider (`foundation`, `ollama`, …), for the locality label.
    @Published public private(set) var providerID: String

    private var assistant: ThreadAIAssistantHandling
    private var availability: (AIActionOperation) -> AIActionAvailability
    private var activeContext: EmailSummaryContext?
    private var requestGeneration = 0
    private var chatRequestGeneration = 0
    private var draftRequestGeneration = 0
    private var sessionCache: [String: ThreadAIAssistantSummaryResult] = [:]

    public init(
        assistant: ThreadAIAssistantHandling,
        providerID: String = AIProviderSelection.defaultProviderID,
        availability: @escaping (AIActionOperation) -> AIActionAvailability = { _ in .available }
    ) {
        self.assistant = assistant
        self.providerID = providerID
        self.availability = availability
        self.summaryText = nil
        self.providerName = "On device"
        self.modelID = ""
        self.localOnly = true
        self.contextMessageIDs = []
        self.isWorking = false
        self.isDraftingReply = false
        self.replyStatusMessage = nil
        self.chatInput = ""
        self.chatTurns = []
        self.isAnsweringQuestion = false
        self.chatStatusMessage = nil
        refreshAvailability()
    }

    /// Where the AI runs, from the resolved provider: "On-device 🔒" for Apple's model (and the
    /// local test provider), "Ollama" for Ollama, "OpenRouter" for OpenRouter, "AI off" when AI is disabled.
    public var localityLabel: String { Self.localityLabel(providerID: providerID) }

    static func localityLabel(providerID: String) -> String {
        switch providerID {
        case "ollama": "Ollama"
        case OpenRouterConfiguration.providerID: "OpenRouter"
        case "disabled": "AI off"
        default: "On-device 🔒"
        }
    }

    public var canAskQuestion: Bool {
        activeContext != nil && chatAvailability.isAvailable && !isWorking && !isAnsweringQuestion
    }

    public func refreshAvailability() {
        let previousSummaryReason = summaryAvailability.reason
        let previousReplyReason = replyAvailability.reason
        let previousChatReason = chatAvailability.reason
        summaryAvailability = availability(.summary)
        replyAvailability = availability(.draftReply)
        chatAvailability = availability(.threadQuestion)
        if summaryAvailability.isAvailable && statusMessage == previousSummaryReason {
            statusMessage = nil
        }
        if replyAvailability.isAvailable && replyStatusMessage == previousReplyReason {
            replyStatusMessage = nil
        }
        if chatAvailability.isAvailable && chatStatusMessage == previousChatReason {
            chatStatusMessage = nil
        }
    }

    public func checkAvailability() {
        refreshAvailability()
        lastAvailabilityCheck = .now
    }

    public func prepareSummary(for context: EmailSummaryContext) {
        requestGeneration &+= 1
        activate(context)
        refreshAvailability()

        if let cached = sessionCache[context.cacheKey] {
            apply(cached)
            statusMessage = nil
        } else {
            summaryText = nil
            contextMessageIDs = []
            statusMessage = nil
        }
        isWorking = false
    }

    public func loadSummary(for context: EmailSummaryContext) async {
        requestGeneration &+= 1
        let generation = requestGeneration
        activate(context)
        let cached = sessionCache[context.cacheKey]
        if let cached {
            apply(cached)
        } else {
            summaryText = nil
            contextMessageIDs = []
        }
        refreshAvailability()
        guard summaryAvailability.isAvailable else {
            isWorking = false
            statusMessage = summaryAvailability.reason
            return
        }

        if cached != nil {
            statusMessage = nil
            isWorking = false
            return
        }

        statusMessage = nil
        isWorking = true
        do {
            let result = try await assistant.summarize(messageID: context.messageID)
            guard generation == requestGeneration, activeContext == context else {
                return
            }
            sessionCache[context.cacheKey] = result
            apply(result)
            isWorking = false
        } catch {
            guard generation == requestGeneration, activeContext == context else {
                return
            }
            isWorking = false
            statusMessage = Self.failureMessage(error, fallback: "Summary unavailable. Try again.")
        }
    }

    /// True when the summary state (text, spinner, status) is `context`'s. Until a view's
    /// context is prepared, that state is still the previous conversation's.
    public func isPrepared(for context: EmailSummaryContext) -> Bool {
        activeContext == context
    }

    /// Stops the summary load in flight: its answer is dropped and not cached, and the spinner
    /// goes. The caller cancels its own task too, so the provider can stop early. Asking for
    /// the summary again loads it anew.
    public func cancelSummaryLoad() {
        guard isWorking else { return }
        requestGeneration &+= 1
        isWorking = false
    }

    public func refreshCurrentSummary() async {
        guard let context = activeContext else {
            return
        }
        refreshAvailability()
        guard summaryAvailability.isAvailable else {
            statusMessage = summaryAvailability.reason
            return
        }
        sessionCache.removeValue(forKey: context.cacheKey)
        await loadSummary(for: context)
    }

    /// Drafts a reply to the current message in `tone`, following `instructions`, and returns
    /// it without opening Compose. Nil when no message is prepared, a draft is already being
    /// written, AI is unavailable (`replyStatusMessage` says why), or the message changed while
    /// drafting.
    public func draftReply(tone: DraftTone, instructions: String) async -> Draft? {
        guard let context = activeContext, !isDraftingReply else { return nil }
        refreshAvailability()
        guard replyAvailability.isAvailable else {
            replyStatusMessage = replyAvailability.reason
            return nil
        }
        isDraftingReply = true
        replyStatusMessage = "Drafting an editable reply…"
        let generation = draftRequestGeneration
        defer {
            if generation == draftRequestGeneration {
                isDraftingReply = false
            }
        }
        do {
            let draft = try await assistant.draftReply(
                messageID: context.messageID, tone: tone, instructions: instructions
            )
            guard generation == draftRequestGeneration, activeContext == context else { return nil }
            replyStatusMessage = "Reply draft is ready to review."
            return draft
        } catch {
            guard generation == draftRequestGeneration, activeContext == context else { return nil }
            replyStatusMessage = Self.failureMessage(error, fallback: "Reply draft unavailable. Try again.")
            return nil
        }
    }

    /// Drafts a reply to `messageID` for a composer that is already open. Unlike
    /// `draftReply(tone:instructions:)`, it doesn't depend on the reader's message and leaves the
    /// reader's reply state (`isDraftingReply`, `replyStatusMessage`) alone. A failure throws
    /// `ComposerAIDraftFailure` with a message the composer can show.
    func draftReplyBody(for messageID: MessageID) async throws -> Draft {
        refreshAvailability()
        guard replyAvailability.isAvailable else {
            throw ComposerAIDraftFailure(message: replyAvailability.reason ?? "Draft with AI isn't available right now.")
        }
        do {
            return try await assistant.draftReply(messageID: messageID, tone: .neutral, instructions: "")
        } catch {
            throw ComposerAIDraftFailure(message: Self.failureMessage(error, fallback: "Reply draft unavailable. Try again."))
        }
    }

    public func askCurrentQuestion() async {
        refreshAvailability()
        guard chatAvailability.isAvailable else {
            chatStatusMessage = chatAvailability.reason
            return
        }
        guard let context = activeContext, canAskQuestion else { return }
        let question = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let generation = chatRequestGeneration
        let priorTurns = Array(chatTurns.suffix(6))
        chatInput = ""
        chatStatusMessage = nil
        isAnsweringQuestion = true
        defer {
            if generation == chatRequestGeneration {
                isAnsweringQuestion = false
            }
        }
        do {
            let result = try await assistant.answerQuestion(
                messageID: context.messageID,
                question: question,
                priorTurns: priorTurns
            )
            guard generation == chatRequestGeneration, activeContext == context else { return }
            chatTurns.append(ThreadAIAssistantChatTurn(question: question, answer: result.answer))
            providerName = result.providerName
            modelID = result.modelID
            localOnly = result.localOnly
        } catch {
            guard generation == chatRequestGeneration, activeContext == context else { return }
            if chatInput.isEmpty {
                chatInput = question
            }
            chatStatusMessage = Self.failureMessage(error, fallback: "Answer unavailable. Try again.")
        }
    }

    public func configure(
        assistant: ThreadAIAssistantHandling,
        providerID: String = AIProviderSelection.defaultProviderID,
        availability: @escaping (AIActionOperation) -> AIActionAvailability = { _ in .available }
    ) {
        requestGeneration &+= 1
        chatRequestGeneration &+= 1
        draftRequestGeneration &+= 1
        self.assistant = assistant
        self.providerID = providerID
        self.availability = availability
        lastAvailabilityCheck = nil
        activeContext = nil
        sessionCache.removeAll()
        summaryText = nil
        providerName = "On device"
        modelID = ""
        contextMessageIDs = []
        statusMessage = nil
        isWorking = false
        isDraftingReply = false
        replyStatusMessage = nil
        resetChat()
        refreshAvailability()
    }

    private static func failureMessage(_ error: Error, fallback: String) -> String {
        switch error as? AIProviderError {
        case .unsupportedLanguageOrLocale:
            "This language is not supported by the selected AI provider. Try another language or provider."
        case .guardrailViolation:
            "The selected AI provider could not complete this request. Edit the request and try again."
        case .remoteEndpointDisallowed:
            "Remote AI is disabled. Choose a local AI provider."
        default:
            fallback
        }
    }

    public static func preview() -> ThreadAIAssistantViewModel {
        ThreadAIAssistantViewModel(assistant: PreviewThreadAIAssistant())
    }

    public static func designPreview() -> ThreadAIAssistantViewModel {
        let viewModel = ThreadAIAssistantViewModel(assistant: PreviewThreadAIAssistant())
        viewModel.summaryText = "Jessica Sun introduces Max Harper to Emily Jones for a possible strategic-finance conversation this week."
        viewModel.providerName = "Apple Foundation Models"
        viewModel.modelID = "system-language-model"
        viewModel.contextMessageIDs = ["jessica-intro"]
        return viewModel
    }

    private func apply(_ result: ThreadAIAssistantSummaryResult) {
        summaryText = result.summaryText
        providerName = result.providerName
        modelID = result.modelID
        localOnly = result.localOnly
        contextMessageIDs = result.contextMessageIDs
    }

    private func activate(_ context: EmailSummaryContext) {
        if activeContext != context {
            chatRequestGeneration &+= 1
            draftRequestGeneration &+= 1
            isDraftingReply = false
            replyStatusMessage = nil
            resetChat()
        }
        activeContext = context
    }

    private func resetChat() {
        chatInput = ""
        chatTurns = []
        isAnsweringQuestion = false
        chatStatusMessage = nil
    }
}

private struct PreviewThreadAIAssistant: ThreadAIAssistantHandling {
    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        ThreadAIAssistantSummaryResult(
            summaryText: "Alice asked about availability.",
            providerName: "On device",
            modelID: "preview",
            localOnly: true,
            contextMessageIDs: [messageID.rawValue]
        )
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        Draft(
            id: DraftID("drf_preview_reply"),
            accountID: AccountID("acc_preview"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Availability",
            bodyPlain: "Hi Alice,\n\nThanks for your message. Tuesday works for me.\n\nBest,",
            createdBy: "local-user",
            aiGenerated: true,
            sourceThreadID: nil
        )
    }

    func answerQuestion(
        messageID: MessageID,
        question: String,
        priorTurns: [ThreadAIAssistantChatTurn]
    ) async throws -> ThreadAIAssistantAnswerResult {
        ThreadAIAssistantAnswerResult(
            answer: "The thread says Tuesday works.",
            providerName: "On device",
            modelID: "preview",
            localOnly: true
        )
    }
}

/// Why Draft with AI couldn't fill an open composer, in words for the user.
struct ComposerAIDraftFailure: Error, Equatable {
    let message: String
}
