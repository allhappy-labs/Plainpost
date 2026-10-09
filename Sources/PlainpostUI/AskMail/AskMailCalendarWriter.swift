import EventKit
import Foundation
import PlainpostCore

/// Errors surfaced when Ask Mail's "Add to Calendar" / "Remind me" actions cannot be completed.
public enum AskMailCalendarError: Error, Equatable {
    case accessDenied
    case noDefaultList
}

/// Writes calendar events and reminders on behalf of Ask Mail cards (flight, event, booking,
/// invoice). Ask Mail never reads existing calendar/reminder data — only write access is
/// requested.
public protocol AskMailCalendarWriting: Sendable {
    func addEvent(_ item: AskMailCalendarItem) async throws
    func addReminder(_ item: AskMailReminderItem) async throws
}

/// `EventKitAskMailCalendarWriter` backs `AskMailCalendarWriting` with `EventKit`. Access is
/// requested lazily, once per call, matching the "Add to Calendar" / "Remind me" action taps.
public final class EventKitAskMailCalendarWriter: AskMailCalendarWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var eventStore: EKEventStore?

    public init() {}

    /// Created on the first Add to Calendar / Remind me tap, not when Ask Mail loads.
    private var store: EKEventStore {
        lock.withLock {
            if let eventStore { return eventStore }
            let created = EKEventStore()
            eventStore = created
            return created
        }
    }

    var hasCreatedEventStore: Bool { lock.withLock { eventStore != nil } }

    public func addEvent(_ item: AskMailCalendarItem) async throws {
        guard try await store.requestWriteOnlyAccessToEvents() else { throw AskMailCalendarError.accessDenied }
        let event = Self.makeEvent(item, store: store)
        guard let calendar = store.defaultCalendarForNewEvents else { throw AskMailCalendarError.noDefaultList }
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
    }

    public func addReminder(_ item: AskMailReminderItem) async throws {
        guard try await store.requestFullAccessToReminders() else { throw AskMailCalendarError.accessDenied }
        let reminder = Self.makeReminder(item, store: store)
        guard let list = store.defaultCalendarForNewReminders() else { throw AskMailCalendarError.noDefaultList }
        reminder.calendar = list
        try store.save(reminder, commit: true)
    }

    /// Pure mapping from an Ask Mail calendar item to an `EKEvent`. An absent `end` defaults to
    /// one hour after `start`. Testable without triggering a permission prompt.
    static func makeEvent(_ item: AskMailCalendarItem, store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = item.title
        event.startDate = item.start
        event.endDate = item.end ?? item.start.addingTimeInterval(3_600)
        event.location = item.location
        event.notes = item.notes
        return event
    }

    /// Pure mapping from an Ask Mail reminder item to an `EKReminder`. Testable without
    /// triggering a permission prompt.
    static func makeReminder(_ item: AskMailReminderItem, store: EKEventStore) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = item.title
        reminder.notes = item.notes
        var components = Calendar.current.dateComponents(in: .current, from: item.due)
        // Set explicitly so `dueDateComponents.date` reliably round-trips to `item.due`.
        components.calendar = Calendar.current
        reminder.dueDateComponents = components
        return reminder
    }
}
