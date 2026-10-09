import XCTest
import PlainpostNodeTransport
import PlainpostCalendarPresentation

final class CalendarWeekLayoutTests: XCTestCase {
    func testWeekUsesCalendarArithmeticAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Zurich"))
        calendar.firstWeekday = 2
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let interval = try XCTUnwrap(CalendarWeekLayout.interval(containing: date, calendar: calendar))
        XCTAssertEqual(interval.duration / 3600, 167)
        XCTAssertEqual(calendar.dateComponents([.day], from: interval.start, to: interval.end).day, 7)
    }
}


extension CalendarWeekLayoutTests {
    private var zurich: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> NodeCalendarEvent {
        NodeCalendarEvent(id: id, connectionID: "connection", calendarID: "work", recurrenceID: "", organizer: "", revision: "1", sequence: 0, stamp: "", title: id, location: "", notes: "", start: .init(kind: allDay ? .date : .dateTime, value: start, timezone: "Europe/Zurich"), end: .init(kind: allDay ? .date : .dateTime, value: end, timezone: "Europe/Zurich"), recurring: false, cancelled: false, attendeeAddress: "", response: .accepted, canEditOccurrence: false, canEditSeries: false, canRespond: false, disabledReason: "", threadID: "", messageID: "", providerLink: "")
    }
    private func placements(_ events: [NodeCalendarEvent], date: String = "2026-09-14T12:00:00+02:00") throws -> [CalendarEventPlacement] {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: date))
        return CalendarWeekLayout.placements(events: events, interval: try XCTUnwrap(CalendarWeekLayout.interval(containing: instant, calendar: zurich)), calendar: zurich)
    }
    func testAdjacentEventsReuseAColumn() throws {
        let result = try placements([event("a", "2026-09-14T09:00:00+02:00", "2026-09-14T10:00:00+02:00"), event("b", "2026-09-14T10:00:00+02:00", "2026-09-14T11:00:00+02:00")])
        XCTAssertEqual(result.map(\.columnIndex), [0, 0])
        XCTAssertEqual(result.map(\.columnCount), [1, 1])
    }
    func testThreeWayOverlapIsDeterministicAndUsesConnectedGroups() throws {
        let events = [event("c", "2026-09-14T09:30:00+02:00", "2026-09-14T11:00:00+02:00"), event("b", "2026-09-14T09:00:00+02:00", "2026-09-14T10:00:00+02:00"), event("a", "2026-09-14T09:00:00+02:00", "2026-09-14T10:00:00+02:00")]
        let result = try placements(events)
        XCTAssertEqual(result.map(\.eventID), ["a", "b", "c"])
        XCTAssertEqual(result.map(\.columnIndex), [0, 1, 2])
        XCTAssertEqual(result.map(\.columnCount), [3, 3, 3])
        XCTAssertEqual(result, try placements(events.reversed()))
    }
    func testAllDaySpanClipsToWeekAndExclusiveEnd() throws {
        let result = try placements([event("trip", "2026-09-13", "2026-09-17", allDay: true)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.dayIndex, 0)
        XCTAssertEqual(result.first?.allDaySpan, 3)
    }
    func testCrossMidnightKeepsOccurrenceID() throws {
        let result = try placements([event("late", "2026-09-14T23:30:00+02:00", "2026-09-15T01:00:00+02:00")])
        XCTAssertEqual(result.map(\.eventID), ["late", "late"])
        XCTAssertEqual(result.map(\.dayIndex), [0, 1])
        XCTAssertEqual(result.map(\.startMinute), [1410, 0])
        XCTAssertEqual(result.map(\.endMinute), [1440, 60])
    }
    func testZeroDurationHasDisplayMinimumWithoutMutatingEvent() throws {
        let original = event("point", "2026-09-14T09:00:00+02:00", "2026-09-14T09:00:00+02:00")
        let result = try placements([original])
        XCTAssertEqual(result.first?.startMinute, 540)
        XCTAssertEqual(result.first?.endMinute, 555)
        XCTAssertEqual(original.start, original.end)
    }
    func testFallBackOffsetsPreserveDistinctInstants() throws {
        let first = NodeCalendarTime(kind: .dateTime, value: "2026-10-25T02:30:00+02:00", timezone: "Europe/Zurich")
        let second = NodeCalendarTime(kind: .dateTime, value: "2026-10-25T02:30:00+01:00", timezone: "Europe/Zurich")
        XCTAssertEqual(try XCTUnwrap(CalendarWeekLayout.date(second, calendar: zurich)).timeIntervalSince(try XCTUnwrap(CalendarWeekLayout.date(first, calendar: zurich))), 3600)
        let result = try placements([event("first", first.value, "2026-10-25T02:45:00+02:00"), event("second", second.value, "2026-10-25T02:45:00+01:00")], date: "2026-10-25T12:00:00+01:00")
        XCTAssertEqual(result.count, 2)
        // Distinct instants at the same wall time must remain separately visible.
        XCTAssertEqual(result.map(\.columnCount), [2, 2])
    }
    func testLegacyWallTimeAndSparseWeek() throws {
        let result = try placements([event("legacy", "2026-09-16T09:15:00", "2026-09-16T10:00:00")])
        XCTAssertEqual(result.first?.dayIndex, 2)
        XCTAssertEqual(result.first?.startMinute, 555)
        XCTAssertEqual(try placements([]), [])
        XCTAssertEqual(try placements([event("outside", "2026-09-21T09:00:00Z", "2026-09-21T10:00:00Z")]), [])
    }
}
