import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

private struct ScriptedProvider: AIProvider {
    let id = "scripted"; let displayName = "Scripted"; let chatModelID = "scripted-1"
    let capabilities = AICapabilities(supportsChat: true, supportsEmbeddings: false, supportsJSONMode: true,
                                      supportsStreaming: false, maxContextTokens: 4096, runsLocally: true)
    var text: String = "Thanks, see you Saturday."
    var cardJSON: String = #"{"relevant":false,"kind":"other","title":"","hero":"","subtitle":"","fields":[]}"#
    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        AIGenerationResponse(text: text, modelID: chatModelID, localOnly: true)
    }
    func generateStructured(_ request: AIStructuredGenerationRequest) async throws -> AIStructuredGenerationResponse {
        AIStructuredGenerationResponse(json: Data(cardJSON.utf8), modelID: chatModelID, localOnly: true)
    }
    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse { throw AIProviderError.unavailable }
    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse { throw AIProviderError.unavailable }
    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse { throw AIProviderError.unavailable }
}

final class AskMailAnswerServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func msg(_ id: String, _ category: SmartCategory, seen: Bool = false, subject: String = "S",
                     from: String = "noreply@github.com", name: String = "GitHub", thread: String? = nil) -> MessageSummary {
        MessageSummary(id: MessageID(id), threadID: thread.map { ThreadID($0) }, from: EmailAddress(from), fromDisplayName: name,
                       subject: subject, preview: subject, smartCategory: category, labels: [], isSeen: seen,
                       mailboxPath: "INBOX", isDeleted: false, sentAt: now.addingTimeInterval(-3_600))
    }
    private func service(_ store: InMemoryMailStore, _ provider: ScriptedProvider = ScriptedProvider()) -> AskMailAnswerService<InMemoryMailStore> {
        AskMailAnswerService(provider: provider, store: store, now: { [now] in now })
    }

    func testUnreadCleanupBuildsListBlocksWithoutCallingTheModel() async throws {
        let store = InMemoryMailStore(messages: [msg("n1", .notification), msg("n2", .notification),
                                                 msg("read", .notification, seen: true),
                                                 msg("p1", .personal, from: "lena@example.com", name: "Lena")])
        let result = try await service(store).answer(
            AskMailboxQuestionInput(question: "Group my unread emails, I want to clean some of them"),
            actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertEqual(answer.blocks.count, 2)
        XCTAssertEqual(answer.searched.map(\.label), ["Unread", "Inbox"])
        XCTAssertTrue(answer.text.hasPrefix("**2 of your 3**"))
        XCTAssertEqual(result.answer, answer.text)
    }

    func testEmptyFilterResultIsNoMatch() async throws {
        let store = InMemoryMailStore(messages: [msg("read", .notification, seen: true)])
        let result = try await service(store).answer(
            AskMailboxQuestionInput(question: "Group my unread emails"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertTrue(answer.insufficientEvidence)
        guard case .options = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
    }

    func testDraftUsesActiveConversation() async throws {
        let lena = msg("lena", .personal, subject: "Flat viewing on Saturday", from: "lena@example.com", name: "Lena Brandt", thread: "thr_flat")
        let store = InMemoryMailStore(messages: [lena])
        let result = try await service(store).answer(
            AskMailboxQuestionInput(question: "Draft a reply saying Saturday works", scope: .activeConversation,
                                    activeConversationKey: MailThreading.conversationKey(for: lena)),
            actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        guard case .draft(let draft) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(draft.replyToMessageID, lena.id)
        XCTAssertEqual(draft.subject, "Re: Flat viewing on Saturday")
        XCTAssertEqual(draft.body, "Thanks, see you Saturday.")
        XCTAssertEqual(answer.text, "Here's a draft reply to **Lena Brandt**.")
    }

    func testDraftDoesNotDoubleReSubjectPrefix() async throws {
        let lena = msg("lena2", .personal, subject: "Re: Flat viewing on Saturday", from: "lena@example.com", name: "Lena Brandt", thread: "thr_flat2")
        let store = InMemoryMailStore(messages: [lena])
        let result = try await service(store).answer(
            AskMailboxQuestionInput(question: "Draft a reply saying Saturday works", scope: .activeConversation,
                                    activeConversationKey: MailThreading.conversationKey(for: lena)),
            actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        guard case .draft(let draft) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(draft.subject, "Re: Flat viewing on Saturday")
    }

    func testUpcomingBuildsCardsAndWaitingList() async throws {
        let flight = msg("flight", .travel, subject: "Your booking LX 318", from: "booking@swiss.com", name: "Swiss")
        let lena = msg("lena", .personal, subject: "Can you bring the form?", from: "lena@example.com", name: "Lena")
        var provider = ScriptedProvider()
        provider.cardJSON = #"{"relevant":true,"kind":"flight","title":"Swiss LX 318","hero":"ZRH → LHR","subtitle":"","fields":[],"startISO":"\#(iso(daysFromNow: 2))"}"#
        let result = try await service(InMemoryMailStore(messages: [flight, lena]), provider).answer(
            AskMailboxQuestionInput(question: "What do I need to deal with this week?"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertEqual(answer.blocks.map(\.id), ["card-flight", "waiting"])
        XCTAssertEqual(answer.citations.map(\.source.messageID), [flight.id])
        let badge = try XCTUnwrap({ if case .card(let card) = answer.blocks[0] { card.badge } else { nil } }())
        XCTAssertEqual(answer.text, "1 thing has a date coming up: **Swiss LX 318** (\(badge)) [1].")
    }

    func testUpcomingWithNoCardsAndOneWaitingMessageUsesSingularCopy() async throws {
        let lena = msg("lena", .personal, subject: "Can you bring the form?", from: "lena@example.com", name: "Lena")
        let result = try await service(InMemoryMailStore(messages: [lena])).answer(
            AskMailboxQuestionInput(question: "What do I need to deal with this week?"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertEqual(answer.blocks.map(\.id), ["waiting"])
        XCTAssertEqual(answer.text, "Nothing has a date coming up, but 1 message from people is still unread.")
    }

    func testUpcomingWithNoCardsAndSeveralWaitingMessagesUsesPluralCopy() async throws {
        let lena = msg("lena", .personal, subject: "Can you bring the form?", from: "lena@example.com", name: "Lena")
        let sam = msg("sam", .personal, subject: "Lunch tomorrow?", from: "sam@example.com", name: "Sam")
        let result = try await service(InMemoryMailStore(messages: [lena, sam])).answer(
            AskMailboxQuestionInput(question: "What do I need to deal with this week?"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertEqual(answer.blocks.map(\.id), ["waiting"])
        XCTAssertEqual(answer.text, "Nothing has a date coming up, but 2 messages from people are still unread.")
    }

    func testAnswerRetriesWithoutFilterWhenFilteredSearchFindsNothing() async throws {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let oldMessage = MessageSummary(
            id: MessageID("old"), threadID: nil, from: EmailAddress("lena@example.com"), fromDisplayName: "Lena",
            subject: "Flat viewing", preview: "Flat viewing", body: "Nothing happened yesterday about the flat viewing.",
            smartCategory: .personal, labels: [], isSeen: false, sentAt: startOfToday.addingTimeInterval(-2 * 86_400))
        var provider = ScriptedProvider()
        provider.text = "Lena confirmed the flat viewing [S1]."
        let store = InMemoryMailStore(messages: [oldMessage])
        let result = try await service(store, provider).answer(
            AskMailboxQuestionInput(question: "What happened today?"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertFalse(answer.insufficientEvidence)
        XCTAssertEqual(answer.citations.map(\.source.messageID), [oldMessage.id])
        XCTAssertTrue(answer.text.contains("Lena confirmed the flat viewing"))
    }

    func testDraftFallbackTextWhenNoTargetFound() async throws {
        let store = InMemoryMailStore(messages: [])
        let result = try await service(store).answer(
            AskMailboxQuestionInput(question: "Draft a reply saying thanks"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertTrue(answer.insufficientEvidence)
        XCTAssertTrue(answer.blocks.isEmpty)
        XCTAssertEqual(answer.text, "Open the email you want to reply to, then ask again.")
    }

    func testAccountScopingExcludesMessageOwnedByAnotherAccount() async throws {
        let mine = msg("mine", .notification, from: "noreply@github.com")
        let theirs = msg("theirs", .notification, from: "noreply@github.com")
        let store = InMemoryMailStore(
            messages: [mine, theirs],
            memberships: [
                MailboxMessageMembership(accountID: AccountID("acct-a"), mailboxPath: "INBOX", uidValidity: 1, uid: 1, messageID: mine.id),
                MailboxMessageMembership(accountID: AccountID("acct-b"), mailboxPath: "INBOX", uidValidity: 1, uid: 2, messageID: theirs.id)
            ]
        )
        let result = try await service(store).answer(
            AskMailboxQuestionInput(question: "Group my unread emails, I want to clean some of them",
                                    accountID: AccountID("acct-a")),
            actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertFalse(answer.referencedMessageIDs.contains(theirs.id))
        XCTAssertTrue(answer.referencedMessageIDs.contains(mine.id))
    }

    func testDropDatesOverrideFindsAnOlderMessageTheOriginalMissed() async throws {
        let old = MessageSummary(
            id: MessageID("old-lena"), threadID: nil, from: EmailAddress("lena@example.com"), fromDisplayName: "Lena",
            subject: "Deposit", preview: "Deposit", smartCategory: .personal, labels: [], isSeen: false,
            mailboxPath: "INBOX", isDeleted: false, sentAt: now.addingTimeInterval(-40 * 86_400))
        let store = InMemoryMailStore(messages: [old])
        let original = try await service(store).answer(
            AskMailboxQuestionInput(question: "unread from Lena today"), actor: PlainpostFixtures.guiUser)
        XCTAssertEqual(original.askMailAnswer?.insufficientEvidence, true)

        let widened = try await service(store).answer(
            AskMailboxQuestionInput(question: "unread from Lena today", filterOverride: .dropDates),
            actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(widened.askMailAnswer)
        XCTAssertFalse(answer.insufficientEvidence)
        XCTAssertTrue(answer.referencedMessageIDs.contains(old.id))
        XCTAssertFalse(answer.searched.map(\.label).contains("Today"))
    }

    func testSearchAllMailOverrideReturnsEvidenceWhenFiltersFoundNothing() async throws {
        let read = MessageSummary(
            id: MessageID("offsite"), threadID: nil, from: EmailAddress("tom@example.com"), fromDisplayName: "Tom",
            subject: "Offsite plan", preview: "Offsite plan",
            smartCategory: .personal, labels: [], isSeen: true,
            mailboxPath: "INBOX", isDeleted: false, body: "The offsite moves to Lucerne in November.",
            sentAt: now.addingTimeInterval(-60 * 86_400))
        var provider = ScriptedProvider()
        provider.text = "The offsite moves to Lucerne [S1]."
        let store = InMemoryMailStore(messages: [read])
        let question = "Unread about the offsite today"
        let original = try await service(store, provider).answer(
            AskMailboxQuestionInput(question: question), actor: PlainpostFixtures.guiUser)
        let originalAnswer = try XCTUnwrap(original.askMailAnswer)
        XCTAssertTrue(originalAnswer.insufficientEvidence)
        guard case .options(let options) = try XCTUnwrap(originalAnswer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(options.options.last?.filterOverride, .searchAllMail)

        let widened = try await service(store, provider).answer(
            AskMailboxQuestionInput(question: question, filterOverride: .searchAllMail),
            actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(widened.askMailAnswer)
        XCTAssertFalse(answer.insufficientEvidence)
        XCTAssertEqual(answer.citations.map(\.source.messageID), [read.id])
    }

    func testGroupedListTotalsCountEveryMatchBeyondTheRowCap() async throws {
        // The person's message is older than every automated one, so it falls outside the 1,000-row fetch.
        let lena = MessageSummary(id: MessageID("p"), threadID: nil, from: EmailAddress("lena@example.com"),
                                  fromDisplayName: "Lena", subject: "Hi", preview: "Hi", smartCategory: .personal,
                                  labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                                  sentAt: now.addingTimeInterval(-30 * 86_400))
        let messages = (0..<1_200).map { msg("n\($0)", .notification) } + [lena]
        let result = try await service(InMemoryMailStore(messages: messages)).answer(
            AskMailboxQuestionInput(question: "Group my unread emails"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        guard case .messages(let automated) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(automated.totalCount, 1_200)
        XCTAssertEqual(automated.sections[0].actionMessageIDs.count, AskMailLimits.actionIDsPerSection)
        XCTAssertEqual(answer.text, "**1200 of your 1201** unread messages look automated. I grouped them below. The **1 from people** are listed separately.")
        guard case .messages(let people) = answer.blocks[1] else { return XCTFail() }
        XCTAssertEqual(people.sections[0].rows.map(\.messageID), [lena.id])
    }

    private func dated(_ id: String, from: String, name: String, mailbox: String = "INBOX", thread: String,
                       hoursAgo: Double, subject: String = "Flat viewing") -> MessageSummary {
        MessageSummary(id: MessageID(id), threadID: ThreadID(thread), from: EmailAddress(from), fromDisplayName: name,
                       subject: subject, preview: subject, smartCategory: .personal, labels: [], isSeen: true,
                       mailboxPath: mailbox, isDeleted: false, sentAt: now.addingTimeInterval(-hoursAgo * 3_600))
    }

    func testDraftSkipsTheAccountsOwnSentReplyInTheConversation() async throws {
        let account = Account(id: AccountID("acct-me"), displayName: "Me", email: EmailAddress("me@example.com"),
                              imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let lena = dated("lena", from: "lena@example.com", name: "Lena Brandt", thread: "thr_flat", hoursAgo: 5)
        let mineInSent = dated("mine-sent", from: "me@example.com", name: "Me", mailbox: "Sent", thread: "thr_flat", hoursAgo: 2)
        let mineInInbox = dated("mine-inbox", from: "ME@example.com", name: "Me", thread: "thr_flat", hoursAgo: 1)
        let store = InMemoryMailStore(
            accounts: [account], messages: [lena, mineInSent, mineInInbox],
            memberships: [lena, mineInSent, mineInInbox].enumerated().map { offset, message in
                MailboxMessageMembership(accountID: account.id, mailboxPath: message.mailboxPath, uidValidity: 1,
                                         uid: offset + 1, messageID: message.id)
            })
        let result = try await service(store).answer(
            AskMailboxQuestionInput(question: "Draft a reply saying Saturday works", scope: .activeConversation,
                                    activeConversationKey: "thr_flat", accountID: account.id),
            actor: PlainpostFixtures.guiUser)
        guard case .draft(let draft) = try XCTUnwrap(result.askMailAnswer?.blocks.first) else { return XCTFail() }
        XCTAssertEqual(draft.replyToMessageID, lena.id)
        XCTAssertEqual(draft.recipientName, "Lena Brandt")
    }

    func testDraftPrefersANamedSenderOverTheOpenConversation() async throws {
        let lena = dated("lena", from: "lena@example.com", name: "Lena Brandt", thread: "thr_flat", hoursAgo: 1)
        let tomOld = dated("tom-old", from: "tom@example.com", name: "Tom Weber", thread: "thr_offsite", hoursAgo: 48,
                           subject: "Offsite")
        let tomNew = dated("tom-new", from: "tom@example.com", name: "Tom Weber", thread: "thr_offsite", hoursAgo: 3,
                           subject: "Offsite")
        let result = try await service(InMemoryMailStore(messages: [lena, tomOld, tomNew])).answer(
            AskMailboxQuestionInput(question: "Draft a reply to the email from Tom saying yes",
                                    activeConversationKey: "thr_flat"),
            actor: PlainpostFixtures.guiUser)
        guard case .draft(let draft) = try XCTUnwrap(result.askMailAnswer?.blocks.first) else { return XCTFail() }
        XCTAssertEqual(draft.replyToMessageID, tomNew.id)
    }

    func testDidIReplyQuestionIsNotDrafted() async throws {
        let tom = dated("tom", from: "tom@example.com", name: "Tom", thread: "thr_offsite", hoursAgo: 3, subject: "Offsite")
        let result = try await service(InMemoryMailStore(messages: [tom])).answer(
            AskMailboxQuestionInput(question: "Did I reply to Tom?"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertFalse(answer.blocks.contains { if case .draft = $0 { true } else { false } })
        XCTAssertNotEqual(answer.text, "Open the email you want to reply to, then ask again.")
    }

    private func iso(daysFromNow days: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(days * 86_400))
    }

    func testUpcomingDropsPastUndatedAndReceiptCards() async throws {
        let past = msg("past", .travel, subject: "Past trip", from: "a@swiss.com", name: "Swiss")
        let undated = msg("undated", .finance, subject: "Invoice", from: "b@bills.com", name: "Bills")
        let receipt = msg("receipt", .receipt, subject: "Receipt", from: "c@shop.com", name: "Shop")
        let future = msg("future", .invitation, subject: "Dinner", from: "d@example.com", name: "Dana")
        let provider = PerMessageCardProvider(cards: [
            "Past trip": #"{"relevant":true,"kind":"flight","title":"Old flight","hero":"ZRH → LHR","subtitle":"","fields":[],"startISO":"\#(iso(daysFromNow: -3))"}"#,
            "Invoice": #"{"relevant":true,"kind":"invoice","title":"Bills","hero":"CHF 10","subtitle":"","fields":[]}"#,
            "Receipt": #"{"relevant":true,"kind":"invoice","title":"Shop","hero":"CHF 5","subtitle":"","fields":[],"startISO":"\#(iso(daysFromNow: 1))"}"#,
            "Dinner": #"{"relevant":true,"kind":"event","title":"Dinner","hero":"Friday 19:00","subtitle":"","fields":[],"startISO":"\#(iso(daysFromNow: 3))"}"#,
        ])
        let store = InMemoryMailStore(messages: [past, undated, receipt, future])
        let result = try await AskMailAnswerService(provider: provider, store: store, now: { [now] in now }).answer(
            AskMailboxQuestionInput(question: "What do I need to deal with this week?"), actor: PlainpostFixtures.guiUser)
        let answer = try XCTUnwrap(result.askMailAnswer)
        XCTAssertEqual(answer.blocks.map(\.id), ["card-future"])
        XCTAssertTrue(answer.text.hasPrefix("1 thing has a date coming up: **Dinner**"), answer.text)
    }
}

/// Returns a canned card per message subject (found in the extraction prompt).
private struct PerMessageCardProvider: AIProvider {
    let id = "per-message"; let displayName = "Per message"; let chatModelID = "per-message-1"
    let capabilities = AICapabilities(supportsChat: true, supportsEmbeddings: false, supportsJSONMode: true,
                                      supportsStreaming: false, maxContextTokens: 4096, runsLocally: true)
    let cards: [String: String]
    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse { throw AIProviderError.unavailable }
    func generateStructured(_ request: AIStructuredGenerationRequest) async throws -> AIStructuredGenerationResponse {
        let json = cards.first { request.prompt.contains("Subject: \($0.key)") }?.value ?? #"{"relevant":false,"kind":"other","title":"","hero":"","subtitle":"","fields":[]}"#
        return AIStructuredGenerationResponse(json: Data(json.utf8), modelID: chatModelID, localOnly: true)
    }
    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse { throw AIProviderError.unavailable }
    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse { throw AIProviderError.unavailable }
    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse { throw AIProviderError.unavailable }
}
