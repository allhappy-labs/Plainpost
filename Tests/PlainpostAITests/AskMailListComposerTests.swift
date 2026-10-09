import XCTest
@testable import PlainpostAI
@testable import PlainpostCore

final class AskMailListComposerTests: XCTestCase {
    private func msg(_ id: String, _ category: SmartCategory, from: String = "noreply@github.com",
                     name: String? = "GitHub", mailbox: String = "INBOX") -> MessageSummary {
        MessageSummary(id: MessageID(id), threadID: nil, from: EmailAddress(from), fromDisplayName: name,
                       subject: "Subject \(id)", preview: "Preview \(id)", smartCategory: category,
                       labels: [], isSeen: false, mailboxPath: mailbox, isDeleted: false, sentAt: nil)
    }

    private let unreadPlan = AskMailQueryPlan(intent: .list, filter: MailKnowledgeFilter(unreadOnly: true, mailbox: .inbox),
                                              searchText: "", grouping: .category,
                                              searched: [.init(label: "Unread"), .init(label: "Inbox")])

    func testGroupsAutomatedByCategoryAndSeparatesPeople() throws {
        let messages = (0..<3).map { msg("n\($0)", .notification) }
            + (0..<2).map { msg("l\($0)", .newsletter, from: "news@figma.com", name: "Figma") }
            + [msg("p0", .personal, from: "lena@example.com", name: "Lena Brandt")]
        let answer = AskMailListComposer.answer(plan: unreadPlan, result: MailFilterResult(totalCount: 6, messages: messages))

        XCTAssertEqual(answer.text, "**5 of your 6** unread messages look automated. I grouped them below. The **1 from people** are listed separately.")
        XCTAssertEqual(answer.searched.map(\.label), ["Unread", "Inbox"])
        guard case .messages(let automated) = answer.blocks[0], case .messages(let people) = answer.blocks[1] else {
            return XCTFail("Expected two message blocks")
        }
        XCTAssertEqual(automated.title, "Automated")
        XCTAssertEqual(automated.sections.map(\.id), ["notification", "newsletter"])
        XCTAssertEqual(automated.sections.map(\.totalCount), [3, 2])
        XCTAssertEqual(automated.sections[0].summary, "GitHub")
        XCTAssertEqual(automated.bulkActions, [.markRead, .archive])
        XCTAssertNil(automated.rowAction)
        XCTAssertEqual(people.title, "From people")
        XCTAssertEqual(people.bulkActions, [])
        XCTAssertEqual(people.rowAction, .reply)
        XCTAssertEqual(people.sections.first?.rows.map(\.messageID), [MessageID("p0")])
    }

    func testLargeSectionsCapRowsAndActionIDs() throws {
        let messages = (0..<1_000).map { msg("n\($0)", .notification) } + [msg("p0", .personal, from: "lena@example.com", name: "Lena")]
        let answer = AskMailListComposer.answer(
            plan: unreadPlan, result: MailFilterResult(totalCount: 5_200, messages: messages),
            categoryCounts: [.notification: 4_000, .system: 1_000, .personal: 200])
        guard case .messages(let block) = answer.blocks[0], case .messages(let people) = answer.blocks[1] else {
            return XCTFail()
        }
        XCTAssertEqual(block.sections[0].rows.count, AskMailLimits.rowsPerSection)
        XCTAssertEqual(block.sections[0].actionMessageIDs.count, AskMailLimits.actionIDsPerSection)
        XCTAssertEqual(block.sections[0].totalCount, 5_000)
        XCTAssertEqual(block.totalCount, 5_000)
        XCTAssertEqual(people.sections[0].totalCount, 200)
        XCTAssertEqual(answer.text, "**5000 of your 5200** unread messages look automated. I grouped them below. The **200 from people** are listed separately.")
    }

    func testBulkActionsOnlyTargetInboxMessages() throws {
        func at(_ id: String, _ mailbox: String) -> MessageSummary { msg(id, .notification, mailbox: mailbox) }
        let anyPlan = AskMailQueryPlan(intent: .list, filter: MailKnowledgeFilter(categories: [.notification]),
                                       searchText: "", grouping: .none, searched: [.init(label: "Notifications")])
        let mixed = AskMailListComposer.answer(
            plan: anyPlan, result: MailFilterResult(totalCount: 3, messages: [at("in", "INBOX"), at("sent", "Sent"), at("arch", "Archive")]))
        guard case .messages(let block) = try XCTUnwrap(mixed.blocks.first) else { return XCTFail() }
        XCTAssertEqual(block.sections[0].totalCount, 3)
        XCTAssertEqual(block.sections[0].rows.count, 3)
        XCTAssertEqual(block.sections[0].actionMessageIDs, [MessageID("in")])
        XCTAssertEqual(block.bulkActions, [.archive])

        let outside = AskMailListComposer.answer(
            plan: anyPlan, result: MailFilterResult(totalCount: 2, messages: [at("sent", "Sent"), at("arch", "Archive")]))
        guard case .messages(let noInbox) = try XCTUnwrap(outside.blocks.first) else { return XCTFail() }
        XCTAssertEqual(noInbox.sections[0].actionMessageIDs, [])
        XCTAssertEqual(noInbox.bulkActions, [], "no bulk bar without an inbox message to act on")
    }

    func testNoMatchReturnsOptionsBlock() throws {
        var plan = unreadPlan
        plan.filter.sentAfter = Date(timeIntervalSince1970: 0)
        plan.intent = .answer
        plan.searchText = "offsite"
        let answer = AskMailListComposer.noMatch(plan: plan, question: "Unread about the offsite this week")
        XCTAssertTrue(answer.insufficientEvidence)
        XCTAssertEqual(answer.text, "I couldn't find any mail that matches.")
        guard case .options(let options) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(options.title, "Try instead")
        XCTAssertEqual(options.options.map { $0.label }, ["Search all dates", "Include read mail", "Search all mail for \u{201C}offsite\u{201D}"])
        XCTAssertEqual(options.options[1].question, "about the offsite this week")
        XCTAssertEqual(options.options.map(\.filterOverride), [.dropDates, .dropUnread, .searchAllMail])
        XCTAssertEqual(options.options[0].question, "Unread about the offsite this week")
    }

    func testSenderSummaryListsThreeNamesThenCount() {
        let names = ["GitHub", "Slack", "Linear", "Figma", "Stripe"]
        let messages = names.enumerated().map { msg("m\($0.offset)", .notification, from: "\($0.element)@x.com", name: $0.element) }
        let answer = AskMailListComposer.answer(plan: unreadPlan, result: MailFilterResult(totalCount: 5, messages: messages))
        guard case .messages(let block) = answer.blocks[0] else { return XCTFail() }
        XCTAssertEqual(block.sections[0].summary, "GitHub, Slack, Linear +2")
    }

    func testNoGroupingBuildsOneTitledSection() throws {
        var plan = AskMailQueryPlan(intent: .list, filter: MailKnowledgeFilter(unreadOnly: false, mailbox: .inbox),
                                    searchText: "", grouping: .none,
                                    searched: [.init(label: "Newsletters")])
        let messages = (0..<2).map { msg("l\($0)", .newsletter, from: "news@figma.com", name: "Figma") }
        let answer = AskMailListComposer.answer(plan: plan, result: MailFilterResult(totalCount: 2, messages: messages))
        guard case .messages(let block) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(block.title, "Newsletters")
        XCTAssertEqual(block.sections.count, 1)
        XCTAssertEqual(block.sections[0].id, "all")
        XCTAssertEqual(block.sections[0].title, "Newsletters")
        XCTAssertNil(block.rowAction)
        XCTAssertEqual(block.bulkActions, [.archive])
        XCTAssertEqual(answer.text, "Found **2** messages.")
    }

    func testNoMatchOffersAllDatesWhenOnlyEndDateIsSet() throws {
        var plan = unreadPlan
        plan.filter.sentBefore = Date(timeIntervalSince1970: 1000)
        let answer = AskMailListComposer.noMatch(plan: plan, question: "Old messages")
        guard case .options(let options) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(options.options.map { $0.label }, ["Search all dates", "Include read mail", "Search all mail for \u{201C}Old messages\u{201D}"])
    }

    func testIncludeReadMailRewriteCollapsesDoubleSpaces() throws {
        let answer = AskMailListComposer.noMatch(plan: unreadPlan, question: "Show my unread mail from this week")
        guard case .options(let options) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(options.options.first { $0.filterOverride == .dropUnread }?.question, "Show my mail from this week")
    }

    func testNoMatchWithoutFiltersOffersNoLoopingOptions() {
        let plan = AskMailQueryPlan(intent: .answer, filter: .none, searchText: "offsite", grouping: .none, searched: [])
        let answer = AskMailListComposer.noMatch(plan: plan, question: "offsite")
        XCTAssertTrue(answer.blocks.isEmpty)
        XCTAssertEqual(answer.text, "I couldn't find any mail that matches.")
    }
}
