import XCTest
@testable import PlainpostAI
@testable import PlainpostCore

final class AskMailQueryInterpreterTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        c.firstWeekday = 2
        return c
    }()
    // Thursday 1 October 2026, 10:00 Zurich
    private let now = ISO8601DateFormatter().date(from: "2026-10-01T08:00:00Z")!

    private func plan(_ q: String) -> AskMailQueryPlan {
        AskMailQueryInterpreter.plan(question: q, now: now, calendar: calendar)
    }

    func testGroupUnreadIsAListOfUnreadInboxGroupedByCategory() {
        let p = plan("Group my unread emails, I want to clean some of them")
        XCTAssertEqual(p.intent, .list)
        XCTAssertTrue(p.filter.unreadOnly)
        XCTAssertEqual(p.filter.mailbox, .inbox)
        XCTAssertEqual(p.grouping, .category)
        XCTAssertEqual(p.searchText, "")
        XCTAssertEqual(p.searched.map(\.label), ["Unread", "Inbox"])
    }

    func testThisWeekDeadlinesAreUpcomingWithDateWindow() {
        let p = plan("What do I need to deal with this week?")
        XCTAssertEqual(p.intent, .upcoming)
        XCTAssertEqual(p.filter.sentAfter, calendar.date(byAdding: .day, value: -21, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(p.searched.map(\.label), ["This week"])
    }

    func testFromSenderAndCategoryWords() {
        let p = plan("Show newsletters from Figma")
        XCTAssertEqual(p.intent, .list)
        XCTAssertEqual(p.filter.senderContains, "figma")
        XCTAssertEqual(p.filter.categories, [.newsletter])
        XCTAssertEqual(p.searched.map(\.label), ["Newsletters", "From figma"])
    }

    func testQuestionAboutContentIsAnAnswerWithSearchText() {
        let p = plan("What did we agree about the flat deposit?")
        XCTAssertEqual(p.intent, .answer)
        XCTAssertEqual(p.searchText, "What did we agree about the flat deposit?")
        XCTAssertTrue(p.filter.isEmpty)
    }

    func testDraftIntent() {
        XCTAssertEqual(plan("Draft a reply saying I'll go with SwissCaution").intent, .draft)
        XCTAssertEqual(plan("Reply to Lena that Saturday works").intent, .draft)
    }

    func testYesterdayAndLastNDays() {
        let y = plan("unread from yesterday")
        XCTAssertEqual(y.filter.sentAfter, calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(y.filter.sentBefore, calendar.startOfDay(for: now))
        let n = plan("receipts from the last 10 days")
        XCTAssertEqual(n.filter.sentAfter, calendar.date(byAdding: .day, value: -10, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(n.filter.categories, [.receipt])
    }

    func testNonEnglishFallsBackToAnswer() {
        let p = plan("Was hat Lena über die Kaution gesagt?")
        XCTAssertEqual(p.intent, .answer)
        XCTAssertTrue(p.filter.isEmpty)
    }

    func testUnreadFromSenderThisWeekIsAFilteredListNotUpcoming() {
        let p = plan("unread from Tom this week")
        XCTAssertEqual(p.intent, .list)
        XCTAssertTrue(p.filter.unreadOnly)
        XCTAssertEqual(p.filter.senderContains, "tom")
        XCTAssertEqual(p.filter.sentAfter, calendar.dateInterval(of: .weekOfYear, for: now)?.start)
        XCTAssertEqual(p.searched.map(\.label), ["Unread", "Inbox", "From tom", "This week"])
    }

    func testShowUnreadFromThisWeekIsAListWithWeekFilter() {
        let p = plan("Show my unread mail from this week")
        XCTAssertEqual(p.intent, .list)
        XCTAssertTrue(p.filter.unreadOnly)
        XCTAssertNil(p.filter.senderContains)
        XCTAssertEqual(p.filter.sentAfter, calendar.dateInterval(of: .weekOfYear, for: now)?.start)
    }

    func testDidIReplyIsNotADraft() {
        XCTAssertNotEqual(plan("Did I reply to Tom?").intent, .draft)
        XCTAssertNotEqual(plan("Have I replied to Lena yet? Did I reply to her?").intent, .draft)
        XCTAssertNotEqual(plan("Was there a reply to the invoice?").intent, .draft)
        XCTAssertEqual(plan("Please reply to Tom that Friday works").intent, .draft)
    }
}
