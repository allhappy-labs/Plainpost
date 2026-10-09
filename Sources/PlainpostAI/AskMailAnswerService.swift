import Foundation
import PlainpostCore

public final class AskMailAnswerService<Store: LocalAIStore & MailKnowledgeRepository>: @unchecked Sendable {
    private let provider: any AIProvider
    private let store: Store
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(provider: any AIProvider, store: Store, now: @escaping @Sendable () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.provider = provider
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    public func answer(_ input: AskMailboxQuestionInput, actor: Actor) async throws -> MailboxQuestionAnswer {
        try AIUsagePolicy.validateSemanticSearch(actor: actor)
        let question = input.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw PlainpostError.validationFailed("Question cannot be empty.") }
        let date = now()
        var plan = AskMailQueryInterpreter.plan(question: question, now: date, calendar: calendar)
        if input.scope == .activeConversation, plan.intent != .draft { plan.intent = .answer }
        if let override = input.filterOverride { plan = plan.widened(by: override, question: question) }

        let answer: AskMailAnswer
        switch plan.intent {
        case .list: answer = try list(plan, question: question, accountID: input.accountID)
        case .answer: answer = try await evidence(plan, input: input, question: question, actor: actor)
        case .upcoming: answer = try await upcoming(plan, question: question, accountID: input.accountID, now: date)
        case .draft: answer = try await draft(plan, input: input, question: question)
        }
        let cardSources = answer.blocks.compactMap { block -> MailKnowledgeSource? in
            if case .card(let card) = block { return card.source } else { return nil }
        }
        return MailboxQuestionAnswer(
            answer: answer.text,
            sources: answer.citations.map(\.source) + cardSources.filter { s in !answer.citations.contains { $0.source.messageID == s.messageID } },
            insufficientEvidence: answer.insufficientEvidence,
            providerName: provider.displayName,
            modelID: provider.chatModelID,
            localOnly: provider.capabilities.runsLocally,
            retrievalMode: .lexical,
            askMailAnswer: answer
        )
    }

    private func list(_ plan: AskMailQueryPlan, question: String, accountID: AccountID?) throws -> AskMailAnswer {
        var result = try store.filteredMailMessages(plan.filter, accountID: accountID, limit: 1_000)
        guard !result.messages.isEmpty else { return AskMailListComposer.noMatch(plan: plan, question: question) }
        guard plan.grouping == .category else { return AskMailListComposer.answer(plan: plan, result: result) }
        let counts = try store.filteredMailCategoryCounts(plan.filter, accountID: accountID)
        // Mail from people can be older than the newest 1,000 automated rows; fetch it on its own
        // so the "From people" block is never missing when the counts say it exists.
        let peopleCategories = plan.filter.categories.isEmpty
            ? Array(AskMailListComposer.peopleCategories)
            : plan.filter.categories.filter(AskMailListComposer.peopleCategories.contains)
        if !peopleCategories.isEmpty {
            var peopleFilter = plan.filter
            peopleFilter.categories = peopleCategories.sorted { $0.rawValue < $1.rawValue }
            let fetchedIDs = Set(result.messages.map(\.id))
            let people = try store.filteredMailMessages(peopleFilter, accountID: accountID, limit: AskMailLimits.rowsPerSection)
                .messages.filter { !fetchedIDs.contains($0.id) }
            result = MailFilterResult(totalCount: result.totalCount, messages: result.messages + people)
        }
        return AskMailListComposer.answer(plan: plan, result: result, categoryCounts: counts)
    }

    private func evidence(_ plan: AskMailQueryPlan, input: AskMailboxQuestionInput, question: String,
                          actor: Actor) async throws -> AskMailAnswer {
        let service = LocalMailQuestionAnsweringService(provider: provider, store: store)
        var result = try await service.answer(
            questionInput(input, question: question, filter: plan.filter), actor: actor)
        var searchedPlan = plan
        if result.insufficientEvidence, !plan.filter.isEmpty {
            result = try await service.answer(
                questionInput(input, question: question, filter: .none), actor: actor)
            // Every filter was already dropped, so widening options would re-run this same search.
            searchedPlan.filter = .none
        }
        if result.insufficientEvidence {
            return AskMailListComposer.noMatch(plan: searchedPlan, question: question)
        }
        return AskMailEvidenceComposer.answer(from: result, question: question, searched: plan.searched)
    }

    private func questionInput(_ input: AskMailboxQuestionInput, question: String,
                               filter: MailKnowledgeFilter) -> AskMailboxQuestionInput {
        AskMailboxQuestionInput(
            question: question,
            scope: input.scope,
            activeConversationKey: input.activeConversationKey,
            accountID: input.accountID,
            filter: filter,
            priorTurns: input.priorTurns,
            evidenceLimit: input.evidenceLimit
        )
    }

    private func upcoming(_ plan: AskMailQueryPlan, question: String, accountID: AccountID?,
                          now date: Date) async throws -> AskMailAnswer {
        let candidatesFilter = MailKnowledgeFilter(
            sentAfter: plan.filter.sentAfter,
            categories: [.travel, .finance, .invitation]
        )
        let candidates = try store.filteredMailMessages(candidatesFilter, accountID: accountID, limit: 12)
        let extractor = AskMailCardExtractor(provider: provider, now: date, calendar: calendar)
        let startOfToday = calendar.startOfDay(for: date)
        var cards: [AskMailCardBlock] = []
        for message in candidates.messages {
            if cards.count >= AskMailLimits.maxCards { break }
            // "Coming up" means dated from today on; undated and past cards are left out.
            if let card = await extractor.card(for: message), let when = Self.cardDate(card), when >= startOfToday {
                cards.append(card)
            }
        }
        cards.sort { (Self.cardDate($0) ?? .distantFuture) < (Self.cardDate($1) ?? .distantFuture) }
        let cardedMessageIDs = Set(cards.map(\.source.messageID))
        let waitingFilter = MailKnowledgeFilter(unreadOnly: true, mailbox: .inbox, categories: [.personal])
        let waitingResult = try store.filteredMailMessages(waitingFilter, accountID: accountID, limit: 5)
        let waitingMessages = waitingResult.messages.filter { !cardedMessageIDs.contains($0.id) }
        let waitingExcludedCount = waitingResult.messages.count - waitingMessages.count
        let waitingTotalCount = waitingResult.totalCount - waitingExcludedCount

        var blocks: [AskMailBlock] = cards.map { .card($0) }
        if !waitingMessages.isEmpty {
            let rows = waitingMessages.map { AskMailListComposer.row($0, tag: nil) }
            blocks.append(.messages(AskMailMessageListBlock(
                id: "waiting", title: "Also waiting on you", icon: .person, tint: .purple,
                sections: [AskMailMessageSection(
                    id: "waiting", title: "Also waiting on you", tint: .purple,
                    totalCount: waitingTotalCount,
                    summary: waitingMessages.prefix(3).map { AskMailListComposer.senderName($0) }.joined(separator: ", "),
                    rows: rows, actionMessageIDs: waitingMessages.map(\.id)
                )],
                bulkActions: [], rowAction: .reply
            )))
        }

        guard !cards.isEmpty || !waitingMessages.isEmpty else {
            return AskMailListComposer.noMatch(plan: plan, question: question)
        }

        let citations = cards.enumerated().map { offset, card in
            AskMailCitation(number: offset + 1, source: card.source)
        }

        let text: String
        if cards.isEmpty {
            text = waitingTotalCount == 1
                ? "Nothing has a date coming up, but 1 message from people is still unread."
                : "Nothing has a date coming up, but \(waitingTotalCount) messages from people are still unread."
        } else {
            let itemTexts = cards.enumerated().map { offset, card -> String in
                let label = card.badge ?? card.hero
                return "**\(card.title)** (\(label)) [\(offset + 1)]"
            }
            let joined = joinWithAnd(itemTexts)
            let countWord = cards.count == 1 ? "1 thing has" : "\(cards.count) things have"
            text = "\(countWord) a date coming up: \(joined)."
        }

        return AskMailAnswer(text: text, citations: citations, blocks: blocks, searched: plan.searched)
    }

    /// The message a draft replies to: the newest message from a named sender, else the newest
    /// message in the open conversation, never one the account sent itself.
    private func draftTarget(_ plan: AskMailQueryPlan, input: AskMailboxQuestionInput) throws -> MessageSummary? {
        let ownAddresses = Set(store.accounts
            .filter { account in input.accountID.map { account.id == $0 } ?? true }
            .map { $0.email.rawValue.lowercased() })
        func isReplyTarget(_ message: MessageSummary) -> Bool {
            !MailMailboxFilter.sent.matches(message.mailboxPath)
                && !ownAddresses.contains(message.from.rawValue.lowercased())
        }
        if let sender = plan.filter.senderContains, !sender.isEmpty {
            let fromSender = try store.filteredMailMessages(
                MailKnowledgeFilter(senderContains: sender), accountID: input.accountID, limit: 20)
            if let newest = fromSender.messages.first(where: isReplyTarget) { return newest }
        }
        guard let activeKey = input.activeConversationKey else { return nil }
        return try store.conversationMessages(conversationKey: activeKey, accountID: input.accountID)
            .filter(isReplyTarget)
            .max { ($0.sentAt ?? .distantPast, $0.id.rawValue) < ($1.sentAt ?? .distantPast, $1.id.rawValue) }
    }

    private func draft(_ plan: AskMailQueryPlan, input: AskMailboxQuestionInput,
                       question: String) async throws -> AskMailAnswer {
        let target = try draftTarget(plan, input: input)
        guard let target else {
            return AskMailAnswer(
                text: "Open the email you want to reply to, then ask again.",
                searched: plan.searched,
                insufficientEvidence: true
            )
        }

        let recipientName = AskMailListComposer.senderName(target)
        let recipientAddress = (target.replyTo ?? target.from).rawValue
        let subject = target.subject
        let normalizedSubject = subject.trimmingCharacters(in: .whitespaces)
        let replySubject = normalizedSubject.lowercased().hasPrefix("re:")
            ? normalizedSubject
            : "Re: \(normalizedSubject)"

        let prompt = """
        Write a short, friendly email reply. Only the body, no subject line, no placeholders. Sign off with the user's first name only if it appears in the thread.
        Instruction: \(question)
        Email from \(recipientName), subject \(subject):
        \(String(target.body.prefix(1_600)))
        """
        let generation = try await provider.generate(AIGenerationRequest(prompt: prompt))

        let draftBlock = AskMailDraftBlock(
            id: "draft-\(target.id.rawValue)",
            replyToMessageID: target.id,
            recipientName: recipientName,
            recipientAddress: recipientAddress,
            subject: replySubject,
            body: generation.text
        )
        return AskMailAnswer(
            text: "Here's a draft reply to **\(recipientName)**.",
            blocks: [.draft(draftBlock)],
            searched: plan.searched
        )
    }

    private static func cardDate(_ card: AskMailCardBlock) -> Date? {
        card.calendarItem?.start ?? card.reminderItem?.due
    }

    private func joinWithAnd(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
