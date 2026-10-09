import PlainpostCalendarPresentation
import Foundation
import PlainpostAccountRuntime
import PlainpostNodeTransport
import SwiftUI

/// Pure presentation for invitation cards; invitation text, links and
/// addresses are untrusted and rendered verbatim.
@MainActor enum ThreadInvitationPresentation {
    /// The resolved calendar event is authoritative; otherwise the invitation's
    /// own payload details are shown, so unseen invitations still render.
    static func title(_ card: ThreadInvitationCardModel) -> String {
        if let title = card.event?.title, !title.isEmpty { return title }
        return card.invitation.title.isEmpty ? "Calendar invitation" : card.invitation.title
    }

    static func location(_ card: ThreadInvitationCardModel) -> String {
        card.event?.location ?? card.invitation.location
    }

    static func timeLabel(_ card: ThreadInvitationCardModel, calendar: Calendar) -> String {
        if let event = card.event { return CalendarEventPopover.timeLabel(event: event, calendar: calendar) }
        if let start = card.invitation.start, let end = card.invitation.end {
            return CalendarEventPopover.timeLabel(start: start, end: end, calendar: calendar)
        }
        if let occurrence = occurrenceLabel(card.invitation.recurrenceID, calendar: calendar) { return "Occurrence · " + occurrence }
        return "Event time isn’t available for this invitation."
    }

    static func originalTimezone(_ card: ThreadInvitationCardModel, calendar: Calendar) -> String? {
        guard let start = card.event?.start ?? card.invitation.start, start.kind == .dateTime, !start.timezone.isEmpty,
              start.timezone != calendar.timeZone.identifier else { return nil }
        return "Original timezone: " + start.timezone
    }

    static func meetingLink(_ card: ThreadInvitationCardModel) -> URL? {
        card.invitation.meetingURL.flatMap { safeMeetingLink(in: $0) } ?? safeMeetingLink(in: location(card))
    }

    static func scope(_ card: ThreadInvitationCardModel) -> String? {
        if !card.invitation.recurrenceID.isEmpty { return "Applies to this occurrence only" }
        return card.event?.recurring == true ? "Applies to the entire series" : nil
    }

    static func status(_ card: ThreadInvitationCardModel) -> String? {
        if let receipt = card.receipt { return ThreadInvitationViewModel.statusText(receipt: receipt) }
        if card.isSubmitting { return "Sending response to your Sync Node…" }
        guard let response = card.event?.response else { return nil }
        switch response {
        case .accepted: return "Calendar shows Accepted"
        case .tentative: return "Calendar shows Maybe"
        case .declined: return "Calendar shows Declined"
        case .needsAction:
            if case .respond = card.availability { return "Awaiting your response" }
            return nil
        case .none: return nil
        }
    }

    /// The response currently reflected by the durable intent or calendar.
    static func selectedResponse(_ card: ThreadInvitationCardModel) -> NodeCalendarParticipation? {
        if let intent = card.intent, intent.receipt?.calendar != .failed { return intent.response }
        return card.event?.response
    }

    /// Only an ASCII https URL with a named host, no credentials and the
    /// default port is offered as a meeting link.
    static func safeMeetingLink(in text: String) -> URL? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>,;\"'()"))
        for token in text.components(separatedBy: separators) where token.lowercased().hasPrefix("https://") {
            guard token.utf8.count <= 2_048,
                  token.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
                  let components = URLComponents(string: token), components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(), host.contains("."), !host.hasSuffix("."),
                  host != "localhost", !host.hasSuffix(".local"),
                  host.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.").inverted) != nil,
                  components.user == nil, components.password == nil,
                  components.port == nil || components.port == 443,
                  let url = components.url else { continue }
            return url
        }
        return nil
    }

    private static func occurrenceLabel(_ recurrenceID: String, calendar: Calendar) -> String? {
        guard !recurrenceID.isEmpty,
              let date = CalendarWeekLayout.date(.init(kind: .dateTime, value: recurrenceID, timezone: ""), calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US"); formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, HH:mm z"
        return formatter.string(from: date)
    }
}

#if os(macOS)
/// Every invitation carried by one message, above that message's body.
struct ThreadInvitationCards: View {
    @ObservedObject var model: ThreadInvitationViewModel
    let messageID: String
    var showInCalendar: ((CalendarEventSelection) -> Void)?
    /// Set when returning from Calendar, to restore this message position.
    var scrollIntoView: (() -> Void)?

    var body: some View {
        let cards = model.cards(forMessageID: messageID)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cards) { card in
                    ThreadInvitationCard(
                        card: card,
                        reachability: model.reachabilityMessage,
                        respond: { response in Task { await model.respond(invitation: card.invitation, response: response) } },
                        showInCalendar: showInCalendar,
                        chooseDestination: { calendarID in model.selectDestination(invitationID: card.id, calendarID: calendarID) }
                    )
                }
            }
            .id(ThreadInvitationCards.scrollID(messageID: messageID))
            .onAppear { scrollIntoView?() }
        }
    }

    static func scrollID(messageID: String) -> String { "calendar-invitations-" + messageID }
}

/// Owns one account's thread invitation model for the reader it wraps.
struct ThreadInvitationHost<Content: View>: View {
    @StateObject private var model: ThreadInvitationViewModel
    let content: (ThreadInvitationViewModel) -> Content
    init(authority: PlainpostCalendarAuthority, appDataRoot: URL, @ViewBuilder content: @escaping (ThreadInvitationViewModel) -> Content) {
        _model = StateObject(wrappedValue: ThreadInvitationViewModel(
            service: authority,
            intents: CalendarResponseIntentStore.shared(cache: CalendarSnapshotCache(accountID: authority.accountID, appDataRoot: appDataRoot))))
        self.content = content
    }
    var body: some View { content(model) }
}

struct ThreadInvitationCard: View {
    let card: ThreadInvitationCardModel
    var reachability: String?
    var calendar: Calendar = .current
    let respond: (NodeCalendarParticipation) -> Void
    var showInCalendar: ((CalendarEventSelection) -> Void)?
    var chooseDestination: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(MailDesign.accentBlue).accessibilityHidden(true)
                Text(ThreadInvitationPresentation.title(card)).font(.headline).lineLimit(2)
            }
            Text(ThreadInvitationPresentation.timeLabel(card, calendar: calendar)).font(.callout)
            if let timezone = ThreadInvitationPresentation.originalTimezone(card, calendar: calendar) {
                Text(timezone).font(.caption).foregroundStyle(.secondary)
            }
            let location = ThreadInvitationPresentation.location(card)
            if !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse").font(.callout).textSelection(.enabled)
            }
            if let link = ThreadInvitationPresentation.meetingLink(card), let host = link.host {
                Link(destination: link) { Text(verbatim: "Join meeting (" + host + ")") }.font(.callout)
            }
            details
            if case let .explanation(text) = card.availability {
                Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = ThreadInvitationPresentation.status(card) {
                Text(status).font(.callout.weight(.medium))
                    .accessibilityLabel("Response status: " + status)
                    .accessibilityIdentifier("calendar.invitation.status")
            }
            if let message = card.message ?? reachability {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mailControlBackground(cornerRadius: MailDesign.Radius.control)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar invitation: " + ThreadInvitationPresentation.title(card))
        .accessibilityIdentifier("calendar.invitation." + card.id)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !card.invitation.organizer.isEmpty { LabeledContent("Organizer", value: card.invitation.organizer) }
            if !card.invitation.attendeeAddress.isEmpty { LabeledContent("Responding as", value: card.invitation.attendeeAddress) }
            let options = ThreadInvitationViewModel.destinationOptions(card)
            if options.count > 1, let chooseDestination, card.intent == nil {
                Picker("Saves to", selection: Binding(get: { card.selectedDestination ?? "" }, set: { chooseDestination($0) })) {
                    Text("Choose a calendar").tag("")
                    ForEach(options, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("calendar.invitation.destination")
            } else if let destination = ThreadInvitationViewModel.destination(card) {
                LabeledContent("Saves to", value: destination)
            }
            if let scope = ThreadInvitationPresentation.scope(card) { Text(scope).foregroundStyle(.secondary) }
        }
        .font(.caption)
    }

    @ViewBuilder private var actions: some View {
        let respondable = if case .respond = card.availability { true } else { false }
        HStack(spacing: 8) {
            if respondable {
                responseButton("Accept", .accepted, symbol: "checkmark")
                responseButton("Maybe", .tentative, symbol: "questionmark")
                responseButton("Decline", .declined, symbol: "xmark")
            }
            if let event = card.event, let showInCalendar {
                Button("Show in calendar", systemImage: "calendar") { showInCalendar(CalendarEventSelection(event: event)) }
                    .accessibilityIdentifier("calendar.invitation.show")
            }
        }
        .controlSize(.small)
    }

    private func responseButton(_ title: String, _ response: NodeCalendarParticipation, symbol: String) -> some View {
        let selected = ThreadInvitationPresentation.selectedResponse(card) == response
        return Button { respond(response) } label: {
            Label(title, systemImage: selected ? symbol + ".circle.fill" : symbol)
        }
        .buttonStyle(.bordered)
        .tint(selected ? MailDesign.accentBlue : nil)
        .disabled(!ThreadInvitationViewModel.canRespond(card, response: response))
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier("calendar.invitation.respond." + response.rawValue)
    }
}
#endif

#if DEBUG && os(macOS)
@_spi(DesignPreview)
public enum ThreadInvitationDesignPreview {
    /// Synthetic invitation cards rendered by the production card view.
    @MainActor public static func view(scenario: String) -> AnyView {
        let fixture = ThreadInvitationFixtureService(scenario: scenario)
        let intents = CalendarResponseIntentStore()
        if let receipt = fixture.receipt {
            intents["design-invite"] = .init(command: .init(operationID: receipt.operationID, connectionID: "design", generation: 1, eventID: "design-identity", invitationID: "design-invite", revision: "1", scope: .occurrence, response: .accepted), receipt: receipt)
        }
        let model = ThreadInvitationViewModel(service: fixture, intents: intents)
        return AnyView(
            ScrollView {
                ThreadInvitationCards(model: model, messageID: "design-message", showInCalendar: { _ in })
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MailDesign.workArea)
            .task { await model.prepare(messageIDs: ["design-message"]) }
        )
    }
}

private struct ThreadInvitationFixtureService: CalendarServing {
    let scenario: String
    var receipt: NodeCalendarReceipt? {
        switch scenario {
        case "pending": .init(operationID: "design-op", owner: .email, calendar: .confirmed, delivery: .pending, code: "", eventID: "design-identity", revision: "2")
        case "uncertain": .init(operationID: "design-op", owner: .email, calendar: .confirmed, delivery: .uncertain, code: "acceptance_unknown", eventID: "design-identity", revision: "2")
        default: nil
        }
    }
    func capabilities() async throws -> NodeCalendarCapabilities { .init(version: 1, providers: [.caldav], enabled: true) }
    func connections() async throws -> [NodeCalendarConnection] {
        [.init(id: "design", generation: 1, kind: .caldav, sendingMailbox: "design-mailbox", attendeeAddress: "me@example.test", delivery: .email, enabled: true, calendars: [.init(id: "work", name: "Work", color: "#557AC6", timezone: "Europe/Zurich", writable: true, scheduling: false)])]
    }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] {
        func invitation(_ id: String, event: String, state: NodeCalendarInvitationState = .actionable) -> NodeCalendarInvitation {
            .init(id: id, eventID: event.replacingOccurrences(of: "event", with: "identity"), messageID: "design-message", uid: event + "@example.test", organizer: "anna@example.test", attendeeAddress: "me@example.test", recurrenceID: "", method: "REQUEST", revision: "1", state: state, sequence: 0, stamp: "20260913T080000Z", calendarEventID: event)
        }
        switch scenario {
        case "superseded": return [invitation("design-invite", event: "design-event", state: .superseded)]
        case "multi": return [invitation("design-invite", event: "design-event"), invitation("design-invite-2", event: "design-event-2")]
        default: return [invitation("design-invite", event: "design-event")]
        }
    }
    func event(id: String) async throws -> NodeCalendarEvent {
        let second = id == "design-event-2"
        return .init(id: id, connectionID: "design", calendarID: "work", recurrenceID: "", organizer: "anna@example.test", revision: "1", sequence: 0, stamp: "", title: second ? "Quarterly planning" : "Design review", location: second ? "Studio 2" : "Room 4 · https://meet.example.com/design-review", notes: "", start: .init(kind: .dateTime, value: second ? "2026-09-18T14:00:00+02:00" : "2026-09-17T09:30:00+02:00", timezone: "Europe/Zurich"), end: .init(kind: .dateTime, value: second ? "2026-09-18T15:30:00+02:00" : "2026-09-17T10:30:00+02:00", timezone: "Europe/Zurich"), recurring: false, cancelled: false, attendeeAddress: "me@example.test", response: receipt == nil ? .needsAction : .accepted, canEditOccurrence: false, canEditSeries: false, canRespond: false, disabledReason: "", threadID: "design-thread", messageID: "design-message", providerLink: "")
    }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { receipt.map { [$0] } ?? [] }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot { throw NodeCalendarError.unsupported }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt { throw NodeCalendarError.unsupported }
}
#endif
