import Foundation
import PlainpostAccountRuntime
import PlainpostNodeTransport

/// One user response intent. The frozen command keeps its operation ID until
/// the durable receipt is terminal; a changed response is a new intent.
struct CalendarResponseIntent: Codable, Equatable, Sendable {
    var command: NodeCalendarCommand
    var receipt: NodeCalendarReceipt?
    /// Last ledger write; orders eviction of settled history. Absent in older ledgers.
    var updatedAt: Date?
    var response: NodeCalendarParticipation { command.response ?? .none }
    /// Settled history that can never produce another external effect.
    var isEvictable: Bool {
        guard let receipt, ThreadInvitationViewModel.isTerminal(receipt) else { return false }
        return receipt.delivery != .uncertain && receipt.calendar != .uncertain
    }
    var isSuccessful: Bool {
        guard let receipt else { return false }
        return receipt.calendar == .confirmed && [.confirmed, .notNeeded].contains(receipt.delivery)
    }
}

/// Account-scoped intent ledger. In the app it is disk-backed next to the
/// calendar snapshot cache, so recreated views and relaunches re-read the same
/// durable operations instead of creating new ones.
@MainActor final class CalendarResponseIntentStore {
    private final class WeakStore { weak var value: CalendarResponseIntentStore? }
    private static var stores: [String: WeakStore] = [:]
    /// One live ledger per account cache: the thread card and the event
    /// popover share the same durable intents instead of overwriting each other.
    static func shared(cache: CalendarSnapshotCache) -> CalendarResponseIntentStore {
        let key = cache.directory.standardizedFileURL.path
        if let existing = stores[key]?.value { return existing }
        let store = CalendarResponseIntentStore(cache: cache)
        let box = WeakStore(); box.value = store
        stores = stores.filter { $0.value.value != nil }
        stores[key] = box
        return store
    }
    private var intents: [String: CalendarResponseIntent]
    private let cache: CalendarSnapshotCache?
    private let limit: Int
    private let clock: () -> Date
    init(cache: CalendarSnapshotCache? = nil, limit: Int = 512, clock: @escaping () -> Date = Date.init) {
        self.cache = cache; self.limit = limit; self.clock = clock
        intents = (try? cache?.loadResponseIntents()) ?? [:]
    }
    subscript(invitationID: String) -> CalendarResponseIntent? {
        get { intents[invitationID] }
        set {
            var value = newValue
            value?.updatedAt = clock()
            intents[invitationID] = value
            evict(keeping: invitationID)
            try? cache?.saveResponseIntents(intents)
        }
    }
    /// Only settled history is evicted, oldest successful entries first.
    /// Unresolved, uncertain or possibly admitted intents are never evicted,
    /// so the ledger may exceed its limit rather than re-enable a send.
    private func evict(keeping current: String) {
        guard intents.count > limit else { return }
        let candidates = intents.filter { $0.key != current && $0.value.isEvictable }
            .sorted { ($0.value.isSuccessful ? 0 : 1, $0.value.updatedAt ?? .distantPast) < ($1.value.isSuccessful ? 0 : 1, $1.value.updatedAt ?? .distantPast) }
        for (id, _) in candidates.prefix(intents.count - limit) { intents[id] = nil }
    }
}

/// Selection handed from a thread card to the week view: the opaque event,
/// its connection/calendar scope and the original occurrence identity.
public struct CalendarEventSelection: Equatable, Sendable {
    public let eventID: String
    public let connectionID: String
    public let calendarID: String
    public let recurrenceID: String
    public let start: NodeCalendarTime
    public init(event: NodeCalendarEvent) {
        eventID = event.id; connectionID = event.connectionID; calendarID = event.calendarID
        recurrenceID = event.recurrenceID; start = event.start
    }
    func matches(_ event: NodeCalendarEvent) -> Bool {
        event.id == eventID && event.connectionID == connectionID && event.calendarID == calendarID && event.recurrenceID == recurrenceID
    }
}

/// Where "Back to thread" returns after "Show in calendar".
struct ThreadCalendarReturn: Equatable {
    let selection: CalendarEventSelection
    let destination: PlainpostDestination
    let messageID: String
}

public enum ThreadInvitationAvailability: Equatable, Sendable {
    case respond(NodeCalendarConnection)
    case explanation(String)
}

public struct ThreadInvitationCardModel: Identifiable, Equatable, Sendable {
    public var id: String { invitation.id }
    public var invitation: NodeCalendarInvitation
    public var event: NodeCalendarEvent?
    public var availability: ThreadInvitationAvailability
    var intent: CalendarResponseIntent?
    public var isSubmitting = false
    public var message: String?
    /// The destination calendar chosen for a new attendee copy.
    public var selectedDestination: String?
    public var receipt: NodeCalendarReceipt? { intent?.receipt }
}

@MainActor
public final class ThreadInvitationViewModel: ObservableObject {
    @Published public private(set) var cards: [ThreadInvitationCardModel] = []
    @Published public private(set) var reachabilityMessage: String?
    private var connections: [NodeCalendarConnection] = []
    private let service: any CalendarServing
    private let intents: CalendarResponseIntentStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private var messageIDs: [String] = []
    /// Advances on every thread read; fences invitation reads and polling.
    private var generation: UInt64 = 0
    /// Advances only on stop (account switch or leaving); fences response results.
    private var lifetime: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    /// A Node without the calendar capability enabled shows no cards.
    private var calendarEnabled: Bool?

    public convenience init(service: any CalendarServing) {
        self.init(service: service, intents: CalendarResponseIntentStore())
    }
    init(service: any CalendarServing, intents: CalendarResponseIntentStore, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.service = service; self.intents = intents; self.sleep = sleep
    }

    public func cards(forMessageID messageID: String) -> [ThreadInvitationCardModel] {
        cards.filter { $0.invitation.messageID == messageID }
    }

    /// Reads invitations for a thread. The Node prepares old messages lazily;
    /// `pending_parse` placeholders are polled with bounded backoff.
    public func prepare(messageIDs requested: [String]) async {
        var seen: Set<String> = []
        let ids = requested.filter { !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") && seen.insert($0).inserted }
        let started = beginGeneration()
        if ids != messageIDs { cards = []; reachabilityMessage = nil }
        messageIDs = ids
        guard !ids.isEmpty else { return }
        if calendarEnabled != true {
            do {
                calendarEnabled = try await service.capabilities().enabled
            } catch let error as NodeCalendarError where error == .unsupported {
                calendarEnabled = false
            } catch {
                // An unreachable Node keeps the last known capability; reads report it.
            }
            guard generation == started else { return }
            if calendarEnabled == false { cards = []; return }
        }
        observeUpdates()
        await reload(generation: started)
        guard generation == started else { return }
        // Reopening re-reads the persisted durable status of every known intent.
        for card in cards where card.intent != nil {
            await refreshReceipt(invitationID: card.id)
            guard generation == started else { return }
        }
        schedulePolling()
    }

    public func respond(invitation: NodeCalendarInvitation, response: NodeCalendarParticipation) async {
        guard [.accepted, .tentative, .declined].contains(response),
              let card = cards.first(where: { $0.id == invitation.id }), card.invitation == invitation,
              Self.canRespond(card, response: response),
              case let .respond(connection) = card.availability else { return }
        let started = lifetime
        let intent: CalendarResponseIntent
        if let existing = card.intent, existing.receipt == nil, existing.response == response {
            // Admission was never confirmed: replay the same frozen operation.
            intent = existing
        } else {
            let scope: NodeCalendarScope = invitation.recurrenceID.isEmpty && card.event?.recurring == true ? .series : .occurrence
            // The destination is sent only when the user had to choose one.
            let target = Self.destinationOptions(card).count > 1 ? card.selectedDestination : nil
            intent = .init(command: .init(
                operationID: UUID().uuidString, connectionID: connection.id, generation: connection.generation,
                eventID: invitation.eventID, invitationID: invitation.id, revision: invitation.revision,
                scope: scope, response: response, targetCalendarID: target))
            // Persisted before dispatch so a crash or recreated view keeps this operation.
            intents[invitation.id] = intent
        }
        update(invitation.id) { $0.intent = intent; $0.isSubmitting = true; $0.message = nil }
        do {
            let receipt = try await service.submit(intent.command)
            guard lifetime == started else { return }
            // A repeated identical intent may be answered with its original receipt.
            guard receipt.operationID == intent.command.operationID || receipt.eventID == intent.command.eventID else { throw NodeCalendarError.invalidResponse }
            update(invitation.id) { $0.isSubmitting = false }
            apply(receipt, invitationID: invitation.id)
        } catch {
            guard lifetime == started, !(error is CancellationError) else { return }
            update(invitation.id) { $0.isSubmitting = false }
            await submissionFailed(error, intent: intent)
        }
        guard lifetime == started else { return }
        schedulePolling()
    }

    /// Chooses where a new attendee copy is saved; only an eligible writable
    /// calendar of the responding connection can be chosen.
    public func selectDestination(invitationID: String, calendarID: String) {
        guard let card = cards.first(where: { $0.id == invitationID }),
              Self.destinationOptions(card).contains(where: { $0.id == calendarID }) else { return }
        update(invitationID) { $0.selectedDestination = calendarID; $0.message = nil }
    }

    /// Account switch or leaving the thread: stale cards are cleared and late
    /// results discarded. Durable intents remain for the next reopen.
    public func stop() {
        generation &+= 1; lifetime &+= 1
        pollTask?.cancel(); pollTask = nil
        updatesTask?.cancel(); updatesTask = nil
        cards = []; messageIDs = []; reachabilityMessage = nil
    }

    // MARK: Presentation

    nonisolated public static func statusText(receipt: NodeCalendarReceipt) -> String {
        if receipt.calendar == .confirmed && receipt.delivery == .pending {
            return receipt.code == "remap_required"
                ? "Calendar saved; response waiting for a sending mailbox" : "Calendar saved; response pending"
        }
        if receipt.delivery == .uncertain {
            return "Response delivery is uncertain"
        }
        switch receipt.calendar {
        case .pending:
            return receipt.code == "remap_required"
                ? "Response waiting for a sending mailbox" : "Response pending; calendar not saved yet"
        case .inFlight: return "Saving response to calendar"
        case .uncertain:
            if receipt.code == "disconnected" {
                return receipt.delivery == .failed
                    ? "Response not sent; the calendar was disconnected"
                    : "Response not confirmed; the calendar was disconnected"
            }
            return receipt.code == "stale_generation"
                ? "Response not confirmed; the calendar connection changed while it was saving"
                : "Checking whether the calendar saved your response"
        case .failed:
            switch receipt.code {
            case "stale_generation": return "Response not saved; the calendar connection changed"
            case "disconnected": return "Response not saved; the calendar was disconnected"
            case "trust_changed": return "Response not saved; account access changed"
            case "conflict": return "Response not saved; the invitation or event changed"
            default: return "Response not saved to calendar"
            }
        case .confirmed, .notNeeded:
            switch receipt.delivery {
            case .inFlight: return "Calendar saved; sending response"
            case .failed:
                switch receipt.code {
                case "stale_revision": return "Calendar saved; response not sent because the event changed"
                case "disconnected": return "Calendar saved; response not sent because the calendar was disconnected"
                case "delivery_rejected": return "Calendar saved; the mail server rejected the response"
                default: return "Calendar saved; response not sent"
                }
            // Confirmed means SMTP or provider submission, never read or recipient delivery.
            case .confirmed: return "Response sent"
            case .notNeeded: return receipt.owner == .email ? "Calendar saved" : "Response sent"
            case .pending, .uncertain: return "Calendar saved; response pending"
            }
        }
    }

    /// Terminal receipts have no further automatic worker progress.
    nonisolated static func isTerminal(_ receipt: NodeCalendarReceipt) -> Bool {
        // Work settled by a reconnect or disconnect never progresses again.
        if receipt.code == "stale_generation" || receipt.code == "disconnected" { return true }
        switch receipt.calendar {
        case .failed: return true
        case .confirmed, .notNeeded: return [.confirmed, .notNeeded, .failed, .uncertain].contains(receipt.delivery)
        default: return false
        }
    }

    /// Placeholder revision while a calendar of the connection is still syncing.
    nonisolated static let indexPending = "calendar_index_pending"
    nonisolated static let indexPendingText = "Calendar is still syncing. Respond when it finishes."

    nonisolated static func canRespond(_ card: ThreadInvitationCardModel, response: NodeCalendarParticipation) -> Bool {
        guard case .respond = card.availability, !card.isSubmitting else { return false }
        guard let intent = card.intent else {
            return destinationOptions(card).count <= 1 || card.selectedDestination != nil
        }
        // Unconfirmed admission may only replay the same frozen response.
        guard let receipt = intent.receipt else { return intent.response == response }
        // Admitted/pending intents and uncertain delivery never offer another send.
        guard isTerminal(receipt), receipt.delivery != .uncertain else { return false }
        if receipt.calendar == .failed || receipt.delivery == .failed { return true }
        return response != intent.response
    }

    nonisolated static func availability(invitation: NodeCalendarInvitation, event: NodeCalendarEvent?, connections: [NodeCalendarConnection]) -> ThreadInvitationAvailability {
        let attendee = invitation.attendeeAddress
        switch invitation.state {
        case .superseded: return .explanation("The organizer sent a newer version of this invitation. Respond to the latest one.")
        case .cancelled: return .explanation("The organizer cancelled this event.")
        case .informational:
            switch invitation.revision {
            case "invalid_calendar": return .explanation("This calendar attachment couldn’t be read as a meeting invitation.")
            case "invitation_limit": return .explanation("This message has more calendar invitations than Plainpost can show. Respond from your calendar provider.")
            default: return .explanation("This calendar message is for information only. There’s nothing to respond to.")
            }
        case .unresolved:
            if invitation.revision == "pending_parse" { return .explanation("Checking this invitation…") }
            if invitation.revision == Self.indexPending { return .explanation(Self.indexPendingText) }
            if attendee.isEmpty {
                return .explanation("This invitation isn’t addressed to one of your verified addresses. It may have been forwarded, so Plainpost won’t respond for you.")
            }
            return .explanation("Plainpost couldn’t match this invitation to a single event. Respond from your calendar provider.")
        case .actionable:
            break
        }
        guard invitation.method.uppercased() == "REQUEST" else {
            return .explanation("Plainpost can’t respond to this kind of calendar message.")
        }
        if let event, event.cancelled { return .explanation("The organizer cancelled this event.") }
        if let event, !event.attendeeAddress.isEmpty, event.attendeeAddress.lowercased() != attendee.lowercased() {
            return .explanation("Your calendar lists a different attendee for this event, so Plainpost won’t respond as \(attendee).")
        }
        let matches = connections.filter { $0.enabled && $0.attendeeAddress.lowercased() == attendee.lowercased() && (event == nil || $0.id == event?.connectionID) }
        guard let connection = matches.first else {
            return .explanation("No connected calendar responds as \(attendee). Connect one in Calendar settings to respond.")
        }
        guard matches.count == 1 else {
            return .explanation("More than one calendar connection responds as \(attendee). Plainpost won’t guess which one to use.")
        }
        if let event {
            let collection = connection.calendars.first { $0.id == event.calendarID }
            if collection?.writable == false || connection.kind == .google && !event.canRespond {
                return .explanation(event.disabledReason.isEmpty ? "This calendar is read-only, so Plainpost can’t save a response." : event.disabledReason)
            }
        } else if connection.kind == .google {
            return .explanation("Google Calendar hasn’t made this invitation available yet. Check again later or respond in Google Calendar.")
        } else if !connection.calendars.isEmpty && !connection.calendars.contains(where: \.writable) {
            return .explanation("This calendar connection has no writable calendar, so Plainpost can’t save a response.")
        }
        return .respond(connection)
    }

    /// Calendars that could hold a new attendee copy for an invitation without a
    /// resolved event: the connection's writable basic CalDAV calendars.
    nonisolated static func destinationOptions(_ card: ThreadInvitationCardModel) -> [NodeCalendarCollection] {
        guard case let .respond(connection) = card.availability, card.event == nil, connection.kind == .caldav else { return [] }
        return connection.calendars.filter { $0.writable && !$0.scheduling }
    }

    /// Where the response will be saved, stated before submission. With several
    /// possible calendars nothing is claimed until the user chooses one.
    nonisolated static func destination(_ card: ThreadInvitationCardModel) -> String? {
        guard case let .respond(connection) = card.availability else { return nil }
        if let event = card.event {
            return connection.calendars.first { $0.id == event.calendarID }?.name ?? "Calendar for \(connection.attendeeAddress)"
        }
        let options = destinationOptions(card)
        if options.count > 1 {
            return options.first { $0.id == card.selectedDestination }?.name
        }
        if options.count == 1 { return options[0].name + " (or the existing event if it’s already in your calendar)" }
        return "The matching event in your calendar for \(connection.attendeeAddress)"
    }

    nonisolated static func unreachableMessage(_ error: Error) -> String {
        switch error as? NodeCalendarError {
        case .unauthorized: return "Calendar authorization expired. Reconnect in Calendar settings."
        case .unsupported: return "Calendar is unavailable. Update your Sync Node to respond to invitations."
        case .conflict: return "Calendar access changed. Showing the last known invitation status."
        default: return "Can’t reach your Sync Node. Showing the last known invitation status."
        }
    }

    // MARK: Loading

    private func reload(generation started: UInt64) async {
        let ids = messageIDs
        do {
            var invitations: [NodeCalendarInvitation] = []
            for start in stride(from: 0, to: ids.count, by: 200) {
                invitations += try await service.invitations(messageIDs: Array(ids[start..<min(ids.count, start + 200)]))
                guard generation == started else { return }
            }
            let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            var unique: Set<String> = []
            invitations = invitations.enumerated()
                .filter { order[$0.element.messageID] != nil && unique.insert($0.element.id).inserted }
                .sorted { (order[$0.element.messageID] ?? 0, $0.offset) < (order[$1.element.messageID] ?? 0, $1.offset) }
                .map(\.element)
            if invitations.contains(where: { $0.state == .actionable }) {
                connections = try await service.connections()
                guard generation == started else { return }
            }
            var next: [ThreadInvitationCardModel] = []
            for invitation in invitations {
                let previous = cards.first { $0.id == invitation.id }
                // Only the Node-resolved projected event is read; the invitation
                // identity is never a stored event ID.
                var event = previous?.event?.id == invitation.calendarEventID ? previous?.event : nil
                if let eventID = invitation.calendarEventID {
                    do { event = try await service.event(id: eventID) }
                    catch let error as NodeCalendarError where error == .unavailable || error == .deliveryUncertain {}
                    catch { event = nil }
                    guard generation == started else { return }
                }
                // A possibly admitted intent is kept even when the invitation
                // changed; reconciliation releases it only if the Node never saw it.
                let intent = intents[invitation.id]
                next.append(.init(
                    invitation: invitation, event: event,
                    availability: Self.availability(invitation: invitation, event: event, connections: connections),
                    intent: intent, isSubmitting: previous?.isSubmitting ?? false, message: previous?.message,
                    selectedDestination: previous?.selectedDestination))
            }
            cards = next
            reachabilityMessage = nil
        } catch {
            guard generation == started, !(error is CancellationError) else { return }
            // Offline keeps the last durable status already on screen.
            reachabilityMessage = Self.unreachableMessage(error)
        }
    }

    private func refreshReceipt(invitationID: String) async {
        // An in-flight submission owns its intent until the Node answers.
        guard let intent = intents[invitationID], cards.first(where: { $0.id == invitationID })?.isSubmitting != true else { return }
        let started = lifetime
        do {
            let receipts = try await service.receipts(operationIDs: [intent.command.operationID])
            guard lifetime == started else { return }
            // One requested operation: an alias answers with its original receipt.
            if let receipt = receipts.first { apply(receipt, invitationID: invitationID) }
        } catch {
            guard lifetime == started, !(error is CancellationError), intents[invitationID] == intent else { return }
            if (error as? NodeCalendarError) == .unknownOperation {
                guard intent.receipt == nil else { return }
                // Only the Node's explicit unknown-operation signal proves it was never admitted.
                intents[invitationID] = nil
                update(invitationID) { card in
                    card.intent = nil
                    if case .respond = card.availability, card.message == nil {
                        card.message = "Your Sync Node didn’t receive this response. Choose a response to send it."
                    }
                }
            } else {
                // 409s (authority, trust, mailbox mapping) and outages keep the intent.
                reachabilityMessage = Self.unreachableMessage(error)
            }
        }
    }

    /// No submit failure proves non-admission on its own (a 409, rejected
    /// authentication or an unreadable 2xx can follow durable admission), so the
    /// frozen intent is kept and reconciled through operations/read.
    private func submissionFailed(_ error: Error, intent: CalendarResponseIntent) async {
        let id = intent.command.invitationID
        switch error as? NodeCalendarError {
        case .unavailable:
            update(id) { $0.message = "Can’t reach your Sync Node. Your response isn’t confirmed; choose it again to resend the same response." }
        case .conflict:
            update(id) { $0.message = "Response not confirmed. The invitation, calendar connection, or sending mailbox may have changed. Checking…" }
            await reload(generation: beginGeneration())
        case .unauthorized:
            update(id) { $0.message = "Calendar authorization expired. Your response isn’t confirmed; reconnect in Calendar settings." }
        case .targetCalendarRequired:
            update(id) { $0.message = "Choose which calendar saves this response, then respond again." }
        case .calendarIndexPending:
            // The Node refused before admission: no operation exists to reconcile.
            if intents[id]?.command.operationID == intent.command.operationID { intents[id] = nil }
            update(id) { card in
                card.intent = nil
                card.message = Self.indexPendingText
            }
            await reload(generation: beginGeneration())
        default:
            update(id) { $0.message = "Plainpost couldn’t confirm that your Sync Node received this response. Checking again…" }
        }
    }

    private func apply(_ receipt: NodeCalendarReceipt, invitationID: String? = nil) {
        guard let index = cards.firstIndex(where: { card in invitationID.map { card.id == $0 } ?? (card.intent?.command.operationID == receipt.operationID) }),
              var intent = cards[index].intent, intent.receipt != receipt else { return }
        intent.receipt = receipt
        intents[cards[index].id] = intent
        cards[index].intent = intent
        cards[index].message = nil
    }

    private func beginGeneration() -> UInt64 {
        generation &+= 1
        pollTask?.cancel(); pollTask = nil
        return generation
    }

    private func update(_ invitationID: String, _ change: (inout ThreadInvitationCardModel) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == invitationID }) else { return }
        change(&cards[index])
    }

    // MARK: Shared refresh and polling

    private func observeUpdates() {
        guard updatesTask == nil else { return }
        let service = service, started = lifetime
        updatesTask = Task { [weak self] in
            let stream = await service.receiptUpdates()
            for await receipt in stream {
                guard let self, self.lifetime == started else { return }
                await self.receiptObserved(receipt)
            }
        }
    }

    private func receiptObserved(_ receipt: NodeCalendarReceipt) async {
        let started = lifetime
        apply(receipt)
        guard receipt.calendar == .confirmed,
              cards.contains(where: { $0.invitation.eventID == receipt.eventID || $0.event?.id == receipt.eventID || $0.intent?.command.operationID == receipt.operationID })
        else { return schedulePolling() }
        // A confirmed response (invitation identity) or calendar edit (stored
        // event) re-reads invitations, picking up a newly resolved event.
        await reload(generation: beginGeneration())
        guard lifetime == started else { return }
        schedulePolling()
    }

    private var needsPolling: Bool {
        cards.contains { card in
            if card.invitation.revision == "pending_parse" || card.invitation.revision == Self.indexPending { return true }
            guard let intent = card.intent, !card.isSubmitting else { return false }
            return intent.receipt.map { !Self.isTerminal($0) } ?? true
        }
    }

    /// Bounded exponential backoff while the thread is visible; cancelled by
    /// prepare and stop. Uncertain delivery is terminal and never resent.
    private func schedulePolling() {
        guard pollTask == nil, needsPolling else { return }
        let sleep = sleep, started = generation
        pollTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do { try await sleep(Self.backoff(attempt: attempt)) } catch { return }
                attempt += 1
                guard let self, self.generation == started, !Task.isCancelled else { return }
                await self.pollOnce(generation: started)
                guard self.generation == started else { return }
                if !self.needsPolling { self.pollTask = nil; return }
            }
        }
    }

    nonisolated static func backoff(attempt: Int) -> Duration { .seconds(min(30, 1 << min(attempt, 5))) }

    private func pollOnce(generation started: UInt64) async {
        if cards.contains(where: { $0.invitation.revision == "pending_parse" || $0.invitation.revision == Self.indexPending }) {
            await reload(generation: started)
            guard generation == started else { return }
        }
        for card in cards where !card.isSubmitting && card.intent.map({ $0.receipt.map { !Self.isTerminal($0) } ?? true }) == true {
            await refreshReceipt(invitationID: card.id)
            guard generation == started else { return }
        }
    }
}
