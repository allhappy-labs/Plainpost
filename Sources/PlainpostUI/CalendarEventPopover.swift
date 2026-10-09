import PlainpostCalendarPresentation
import SwiftUI
import PlainpostNodeTransport

struct CalendarEventPopover: View {
    let event: NodeCalendarEvent
    let calendarName: String
    let calendar: Calendar
    var openThread: ((String, String) -> Void)?
    var edit: (() -> Void)?
    var backToThread: (() -> Void)?
    /// Linked invitation responses, driven through the thread invitation model.
    var responses: ThreadInvitationViewModel?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(event.title.isEmpty ? "Untitled event" : event.title).font(.title3.weight(.semibold))
            Label(calendarName, systemImage: "calendar")
            Text(Self.timeLabel(event: event, calendar: calendar)).font(.callout)
            if event.start.kind == .dateTime && !event.start.timezone.isEmpty && event.start.timezone != calendar.timeZone.identifier { Text("Original timezone: " + event.start.timezone).font(.caption).foregroundStyle(.secondary) }
            Label(Self.status(event), systemImage: event.cancelled ? "xmark.circle" : "person.crop.circle.badge.checkmark")
            if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").textSelection(.enabled) }
            if !event.organizer.isEmpty { LabeledContent("Organizer", value: event.organizer) }
            if !event.attendeeAddress.isEmpty { LabeledContent("Attendee", value: event.attendeeAddress) }
            if event.recurring { Label("Recurring event", systemImage: "repeat") }
            if !event.notes.isEmpty { ScrollView { Text(event.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
            if !event.disabledReason.isEmpty { Text(event.disabledReason).font(.caption).foregroundStyle(.secondary) }
            if !event.threadID.isEmpty, let openThread { Button("Show related email", systemImage: "envelope") { openThread(event.threadID, event.messageID) } }
            if !event.cancelled, event.canEditOccurrence || event.canEditSeries, let edit { Button("Edit event", systemImage: "pencil", action: edit) }
            if let url = URL(string: event.providerLink), url.scheme == "https" { Link("Open in calendar provider", destination: url) }
            if let backToThread { Button("Back to thread", systemImage: "arrow.uturn.backward", action: backToThread) }
            #if os(macOS)
            if let responses { CalendarEventResponses(model: responses, event: event) }
            #endif
        }
        .padding(20).frame(width: 340, alignment: .leading)
        .foregroundStyle(MailDesign.primaryText)
        .accessibilityElement(children: .contain)
    }
    static func status(_ event: NodeCalendarEvent) -> String {
        if event.cancelled { return "Cancelled" }
        switch event.response { case .needsAction: return "Needs response"; case .accepted: return "Accepted"; case .tentative: return "Maybe"; case .declined: return "Declined"; case .none: return "No response status" }
    }
    static func timeLabel(event: NodeCalendarEvent, calendar: Calendar) -> String {
        timeLabel(start: event.start, end: event.end, calendar: calendar)
    }
    static func timeLabel(start startTime: NodeCalendarTime, end endTime: NodeCalendarTime, calendar: Calendar) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.timeZone = calendar.timeZone
        formatter.dateFormat = startTime.kind == .date ? "EEEE, MMMM d" : "EEEE, MMMM d, HH:mm z"
        let start = CalendarWeekLayout.date(startTime, calendar: calendar).map(formatter.string) ?? startTime.value
        let end = CalendarWeekLayout.date(endTime, calendar: calendar).map(formatter.string) ?? endTime.value
        return startTime.kind == .date ? "All day · " + start + " – " + end + " (exclusive end)" : start + " – " + end
    }
    static func accessibilityLabel(event: NodeCalendarEvent, calendarName: String, calendar: Calendar) -> String {
        [event.title, calendarName, timeLabel(event: event, calendar: calendar), status(event)].joined(separator: ", ")
    }
}

#if os(macOS)
/// Accept, Maybe and Decline for an attendee event with a linked invitation.
/// Availability, destination and durable status come from the invitation card.
struct CalendarEventResponses: View {
    @ObservedObject var model: ThreadInvitationViewModel
    let event: NodeCalendarEvent
    var body: some View {
        let card = CalendarWeekViewModel.responseCard(for: event, in: model)
        VStack(alignment: .leading, spacing: 6) {
            if let card {
                if let status = ThreadInvitationPresentation.status(card) {
                    Text(status).font(.callout.weight(.medium)).accessibilityLabel("Response status: " + status)
                }
                if case .respond = card.availability {
                    HStack(spacing: 8) {
                        response("Accept", .accepted, card: card)
                        response("Maybe", .tentative, card: card)
                        response("Decline", .declined, card: card)
                    }.controlSize(.small)
                } else if case let .explanation(text) = card.availability {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
                if let message = card.message ?? model.reachabilityMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: event.messageID) { await model.prepare(messageIDs: [event.messageID]) }
        .accessibilityIdentifier("calendar.popover.responses")
    }
    private func response(_ title: String, _ value: NodeCalendarParticipation, card: ThreadInvitationCardModel) -> some View {
        Button(title) { Task { await model.respond(invitation: card.invitation, response: value) } }
            .buttonStyle(.bordered)
            .disabled(!ThreadInvitationViewModel.canRespond(card, response: value))
            .accessibilityValue(ThreadInvitationPresentation.selectedResponse(card) == value ? "Selected" : "")
            .accessibilityIdentifier("calendar.popover.respond." + value.rawValue)
    }
}
#endif
