import XCTest
@testable import PlainpostCore
@testable import PlainpostUI

final class SmartInboxTriageModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_US") }
    private var now: Date { date(2026, 7, 22, 12) }

    func testOnlyTodayRowsFormBundlesAndHistoryStaysFlat() {
        let today = row("today", at: date(2026, 7, 22, 9), category: .newsletter)
        let yesterday = row("yesterday", at: date(2026, 7, 21, 9), category: .newsletter)

        let model = build([yesterday, today])

        XCTAssertEqual(model.todayBundles.map(\.id), [.newsletters])
        XCTAssertEqual(model.todayBundles.first?.rows.map(\.id), ["today"])
        XCTAssertEqual(model.historicalSections.map(\.id), [.yesterday])
        XCTAssertEqual(model.historicalSections.first?.rows.map(\.id), ["yesterday"])
    }

    func testPromotedRowsUsePriorityRankThenRecencyAndIdentifier() {
        let rows = [
            row("normal", at: date(2026, 7, 22, 11), category: .personal),
            row("high-z", at: date(2026, 7, 22, 10), category: .personal, priority: .high),
            row("high-a", at: date(2026, 7, 22, 10), category: .personal, priority: .high),
            row("action", at: date(2026, 7, 22, 8), category: .personal, requiresAction: true),
            row("high-action", at: date(2026, 7, 22, 7), category: .personal, priority: .high, requiresAction: true),
            row("pinned", at: date(2026, 7, 22, 6), category: .personal, isPinned: true)
        ]

        let model = build(rows)

        XCTAssertEqual(model.todayPromotedRows.map(\.id), ["pinned", "high-action", "action", "high-a", "high-z"])
        XCTAssertEqual(model.todayBundles.first?.rows.map(\.id), ["normal"])
    }

    func testBundleAggregatesEverySenderByNormalizedAddress() throws {
        let rows = [
            row("normal", sender: "reader@example.com", displayName: "Reader", at: date(2026, 7, 22, 8), category: .newsletter),
            row("high", sender: "Editor@Example.com", displayName: "Editor", at: date(2026, 7, 22, 10), category: .newsletter, priority: .high, isUnread: false),
            row("duplicate", sender: "editor@example.com", displayName: "Older Editor", at: date(2026, 7, 22, 9), category: .newsletter, requiresAction: true, isUnread: true),
            row("fallback", sender: "fallback@example.com", at: date(2026, 7, 22, 7), category: .newsletter),
            row("fourth", sender: "fourth@example.com", displayName: "Fourth", at: date(2026, 7, 22, 6), category: .newsletter)
        ]

        let bundle = try XCTUnwrap(build(rows).todayBundles.first)

        XCTAssertEqual(bundle.count, 5)
        XCTAssertEqual(bundle.senderSummaries.map(\.displayName), [
            "Editor", "Reader", "fallback@example.com", "Fourth"
        ])
        XCTAssertEqual(bundle.senderSummaries.map(\.messageCount), [2, 1, 1, 1])
        XCTAssertEqual(bundle.senderSummaries.first?.sender, "Editor@Example.com")
        XCTAssertTrue(bundle.senderSummaries.first?.hasUnread == true)
        XCTAssertTrue(bundle.hasUnread)
        XCTAssertEqual(bundle.rows.map(\.id), ["normal", "fallback", "fourth"])
    }

    func testBundleUnreadStateIsFalseWhenEveryMessageIsRead() throws {
        let read = MessageRowModel(
            id: "read",
            sender: "reader@example.com",
            subject: "Read",
            preview: "Already handled",
            category: .newsletter,
            categoryLabel: "Newsletter",
            isUnread: false,
            isPinned: false,
            dateLabel: "",
            sentAt: date(2026, 7, 22, 8),
            actions: []
        )

        XCTAssertFalse(try XCTUnwrap(build([read]).todayBundles.first).hasUnread)
    }

    func testBundleOrderIsStableAndMappingIsExhaustive() {
        let categories: [SmartCategory] = [
            .unknown, .invitationResponse, .newsletter, .security, .personal, .invitation
        ]
        let rows = categories.enumerated().map { index, category in
            row("\(index)", at: date(2026, 7, 22, 11 - index), category: category)
        }

        let model = build(rows)

        XCTAssertEqual(model.todayBundles.map(\.id), SmartInboxDisplayBundle.allCases)
        XCTAssertEqual(model.todayBundles.map(\.title), ["People", "Notifications", "Newsletters", "Invitations", "Invitation responses", "Updates"])
        XCTAssertFalse(model.todayBundles.contains { $0.systemImage.isEmpty })
    }

    func testDrillInContainsAllCategoryRowsUsingPromotionOrder() {
        let rows = [
            row("normal-new", at: date(2026, 7, 22, 11), category: .notification),
            row("high", at: date(2026, 7, 22, 10), category: .security, priority: .high),
            row("normal-old", at: date(2026, 7, 22, 9), category: .system),
            row("action", at: date(2026, 7, 22, 8), category: .notification, requiresAction: true),
            row("high-action", at: date(2026, 7, 22, 7), category: .notification, priority: .high, requiresAction: true),
            row("pinned", at: date(2026, 7, 22, 6), category: .notification, isPinned: true),
            row("yesterday", at: date(2026, 7, 21, 11), category: .notification)
        ]

        XCTAssertEqual(
            build(rows).drillInRows(for: .notifications).map(\.id),
            ["pinned", "high-action", "action", "high", "normal-new", "normal-old"]
        )
    }

    func testHistoricalSectionsAreChronologicalAndLocalized() {
        let rows = [
            row("yesterday-old", at: date(2026, 7, 21, 8), category: .personal),
            row("yesterday-new", at: date(2026, 7, 21, 10), category: .notification),
            row("this-week", at: date(2026, 7, 20, 10), category: .newsletter),
            row("last-week", at: date(2026, 7, 16, 10), category: .receipt),
            row("june", at: date(2026, 6, 20, 10), category: .personal),
            row("last-year", at: date(2025, 12, 20, 10), category: .personal)
        ]

        let sections = build(rows).historicalSections

        XCTAssertEqual(sections.map(\.id), [.yesterday, .thisWeek, .lastWeek, .month(year: 2026, month: 6), .month(year: 2025, month: 12)])
        XCTAssertEqual(sections.map(\.title), ["Yesterday", "This Week", "Last Week", "June", "December 2025"])
        XCTAssertEqual(sections[0].rows.map(\.id), ["yesterday-new", "yesterday-old"])
    }

    func testInjectedCalendarDefinesTodayInsteadOfElapsedHours() {
        let rowNearMidnight = row("near-midnight", at: date(2026, 7, 22, 0, 15), category: .newsletter)
        let almostTwentyFourHoursAgo = row("previous-day", at: date(2026, 7, 21, 12, 30), category: .newsletter)

        let model = build([almostTwentyFourHoursAgo, rowNearMidnight])

        XCTAssertEqual(model.todayBundles.first?.rows.map(\.id), ["near-midnight"])
        XCTAssertEqual(model.historicalSections.first?.rows.map(\.id), ["previous-day"])
    }

    func testInjectedNowDefinesYesterdayInsteadOfWallClockDate() {
        let injectedNow = date(2030, 4, 10, 12)
        let injectedYesterday = row("injected-yesterday", at: date(2030, 4, 9, 9), category: .personal)

        let model = SmartInboxTriageModel.build(
            rows: [injectedYesterday],
            now: injectedNow,
            calendar: calendar,
            locale: locale
        )

        XCTAssertEqual(model.historicalSections.map(\.id), [.yesterday])
    }

    func testOlderPinnedRowRemainsHistorical() {
        let pinned = row("old-pinned", at: date(2026, 7, 21, 10), category: .personal, isPinned: true)

        let model = build([pinned])

        XCTAssertTrue(model.todayPromotedRows.isEmpty)
        XCTAssertTrue(model.todayBundles.isEmpty)
        XCTAssertEqual(model.historicalSections.first?.rows.map(\.id), ["old-pinned"])
    }

    func testSnapshotCacheDoesNotRebuildForUnchangedMailboxRowsOnTheSameDay() {
        let rows = [
            row("today", at: date(2026, 7, 22, 10), category: .newsletter),
            row("yesterday", at: date(2026, 7, 21, 10), category: .personal)
        ]
        let cache = SmartInboxTriageModelSnapshotCache()

        let first = cache.model(
            rows: rows,
            contentRevision: 41,
            now: now,
            calendar: calendar,
            locale: locale
        )
        let second = cache.model(
            rows: rows,
            contentRevision: 41,
            now: date(2026, 7, 22, 17),
            calendar: calendar,
            locale: locale
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.buildCount, 1)
    }

    func testSnapshotCacheRebuildsWhenContentRevisionChanges() {
        let unread = row(
            "today",
            at: date(2026, 7, 22, 10),
            category: .personal,
            isUnread: true
        )
        let read = row(
            "today",
            at: date(2026, 7, 22, 10),
            category: .personal,
            isUnread: false
        )
        let cache = SmartInboxTriageModelSnapshotCache()

        _ = cache.model(
            rows: [unread],
            contentRevision: 41,
            now: now,
            calendar: calendar,
            locale: locale
        )
        let refreshed = cache.model(
            rows: [read],
            contentRevision: 42,
            now: now,
            calendar: calendar,
            locale: locale
        )

        XCTAssertEqual(refreshed.todayBundles.first?.rows.first?.isUnread, false)
        XCTAssertEqual(cache.buildCount, 2)
    }

    private func build(_ rows: [MessageRowModel]) -> SmartInboxTriageModel {
        SmartInboxTriageModel.build(rows: rows, now: now, calendar: calendar, locale: locale)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func row(
        _ id: String,
        sender: String = "sender@example.com",
        displayName: String? = nil,
        at sentAt: Date,
        category: SmartCategory,
        priority: SmartPriority = .normal,
        requiresAction: Bool = false,
        confidence: Double? = nil,
        isPinned: Bool = false,
        isUnread: Bool = true
    ) -> MessageRowModel {
        MessageRowModel(
            id: id,
            sender: sender,
            senderDisplayName: displayName,
            subject: id,
            preview: id,
            category: category,
            categoryLabel: category.rawValue,
            smartPriority: priority,
            requiresAction: requiresAction,
            smartConfidence: confidence,
            isUnread: isUnread,
            isPinned: isPinned,
            dateLabel: "",
            sentAt: sentAt,
            actions: []
        )
    }
}
