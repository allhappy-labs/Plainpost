import PlainpostCalendarPresentation
import Foundation
import PlainpostAccountRuntime
import PlainpostNodeTransport
import SwiftUI

@MainActor public final class CalendarEventEditorViewModel: ObservableObject {
    @Published public var draft: NodeCalendarEdit
    @Published public private(set) var event: NodeCalendarEvent
    @Published public private(set) var latestEvent: NodeCalendarEvent?
    @Published public private(set) var conflict = false
    @Published public private(set) var saving = false
    @Published public private(set) var receipt: NodeCalendarReceipt?
    @Published public private(set) var isEditing = true
    @Published public var showDiscardConfirmation = false
    @Published public private(set) var errorMessage: String?
    private let service: any CalendarServing
    private var pendingCommand: NodeCalendarCommand?
    public init(event: NodeCalendarEvent, service: any CalendarServing) {
        self.event = event
        self.service = service
        draft = Self.edit(event)
    }
    public var dirty: Bool { draft != Self.edit(event) }
    public var readOnlyReason: String {
        if event.cancelled { return "Cancelled events cannot be edited." }
        if !event.canEditOccurrence && !event.canEditSeries {
            return event.disabledReason.isEmpty
                ? "Only the organizer or an authorized calendar owner can edit this event."
                : event.disabledReason
        }
        return ""
    }
    public var validationMessage: String? {
        // Unchanged provider times are kept as they are, including floating times
        // that carry no zone; changed times must name one.
        let timingUnchanged = draft.start == event.start && draft.end == event.end
        guard timingUnchanged || TimeZone(identifier: draft.start.timezone) != nil,
            timingUnchanged || TimeZone(identifier: draft.end.timezone) != nil
        else { return "Choose a valid timezone." }
        let calendar = Calendar(identifier: .gregorian)
        guard draft.start.kind == draft.end.kind,
            let start = CalendarWeekLayout.date(draft.start, calendar: calendar),
            let end = CalendarWeekLayout.date(draft.end, calendar: calendar), end > start
        else { return "End must be after start." }
        return nil
    }
    public var awaitingConfirmation: Bool { pendingCommand != nil }
    public func canSave(scope: NodeCalendarScope) -> Bool {
        guard isEditing, !saving, !conflict, dirty, !event.cancelled, validationMessage == nil
        else { return false }
        if scope == .series && event.recurring
            && (draft.start != event.start || draft.end != event.end)
        {
            return false
        }
        return scope == .occurrence ? event.canEditOccurrence : event.canEditSeries
    }
    public func save(scope: NodeCalendarScope) async {
        guard canSave(scope: scope) else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let connections = try await service.connections()
            try Task.checkCancellation()
            guard
                let connection = connections.first(where: {
                    $0.id == event.connectionID && $0.enabled
                })
            else { throw NodeCalendarError.unauthorized }
            if let pendingCommand, pendingCommand.generation != connection.generation {
                throw NodeCalendarError.conflict
            }
            if pendingCommand == nil {
                var edit = draft
                if draft.start == event.start && draft.end == event.end {
                    edit.start = .init(kind: .dateTime, value: "", timezone: "")
                    edit.end = edit.start
                }
                pendingCommand = .init(
                    operationID: UUID().uuidString, connectionID: event.connectionID,
                    generation: connection.generation, eventID: event.id, invitationID: "",
                    revision: event.revision, scope: scope, edit: edit)
            }
            guard let command = pendingCommand else { return }
            let result = try await service.submit(command)
            try Task.checkCancellation()
            guard result.operationID == command.operationID, result.eventID == event.id else {
                throw NodeCalendarError.invalidResponse
            }
            receipt = result
            if result.calendar == .confirmed {
                let updated = try await service.event(id: event.id)
                try Task.checkCancellation()
                guard updated.id == event.id, updated.connectionID == event.connectionID,
                    updated.revision != command.revision || result.revision == command.revision
                else {
                    throw NodeCalendarError.invalidResponse
                }
                event = updated
                pendingCommand = nil
                isEditing = false
            } else if result.calendar == .failed {
                throw NodeCalendarError.conflict
            } else {
                errorMessage =
                    "Save is awaiting provider confirmation. Check again to reconcile this same operation."
            }
        } catch {
            if (error as? NodeCalendarError) == .conflict {
                conflict = true
                pendingCommand = nil
                receipt = nil
                latestEvent = try? await service.event(id: event.id)
                errorMessage =
                    "This event changed. Review the latest event before reapplying your draft."
            } else if error is CancellationError {
                errorMessage =
                    "Save was interrupted. Your draft is preserved. Check again to confirm the same operation."
            } else {
                errorMessage = "The event could not be saved or confirmed. Your draft is preserved."
            }
        }
    }
    public func refreshConflict() async {
        guard conflict, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: event.start.timezone) ?? .current
            guard let date = CalendarWeekLayout.date(event.start, calendar: calendar),
                let interval = CalendarWeekLayout.interval(containing: date, calendar: calendar)
            else { throw NodeCalendarError.invalidResponse }
            let formatter = ISO8601DateFormatter()
            _ = try await service.window(
                .init(
                    window: .init(
                        start: formatter.string(from: interval.start),
                        end: formatter.string(from: interval.end),
                        timezone: calendar.timeZone.identifier), cursor: ""))
            latestEvent = try await service.event(id: event.id)
        } catch {
            errorMessage = "The latest event could not refresh. Your draft is preserved."
        }
    }
    public func reviewAndReapply() {
        guard !saving, conflict, let latestEvent, latestEvent.id == event.id,
            latestEvent.connectionID == event.connectionID
        else { return }
        event = latestEvent
        self.latestEvent = nil
        conflict = false
        pendingCommand = nil
        receipt = nil
        errorMessage = nil
    }
    public func cancel() {
        guard !saving else { return }
        if dirty || pendingCommand != nil {
            showDiscardConfirmation = true
        } else {
            isEditing = false
        }
    }
    public func discard() {
        guard !saving else { return }
        showDiscardConfirmation = false
        isEditing = false
    }
    private static func edit(_ e: NodeCalendarEvent) -> NodeCalendarEdit {
        .init(title: e.title, location: e.location, notes: e.notes, start: e.start, end: e.end)
    }
}
