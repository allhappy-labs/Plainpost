import EventKit
import XCTest
@testable import PlainpostCore
@testable import PlainpostUI

final class AskMailCalendarWriterTests: XCTestCase {
    func testEventMappingDefaultsToOneHour() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let event = EventKitAskMailCalendarWriter.makeEvent(
            AskMailCalendarItem(title: "LX 318", start: start, end: nil, location: "ZRH", notes: "Booking"),
            store: EKEventStore())
        XCTAssertEqual(event.title, "LX 318")
        XCTAssertEqual(event.startDate, start)
        XCTAssertEqual(event.endDate, start.addingTimeInterval(3_600))
        XCTAssertEqual(event.location, "ZRH")
        XCTAssertEqual(event.notes, "Booking")
    }

    func testReminderMappingSetsDueComponents() {
        let due = Date(timeIntervalSince1970: 1_790_000_000)
        let reminder = EventKitAskMailCalendarWriter.makeReminder(
            AskMailReminderItem(title: "Pay Marco", due: due, notes: nil), store: EKEventStore())
        XCTAssertEqual(reminder.title, "Pay Marco")
        XCTAssertEqual(reminder.dueDateComponents?.date, Calendar.current.dateComponents(in: .current, from: due).date)
    }

    func testEventStoreIsCreatedOnFirstUseNotAtInit() {
        let writer = EventKitAskMailCalendarWriter()
        XCTAssertFalse(writer.hasCreatedEventStore)
    }
}
