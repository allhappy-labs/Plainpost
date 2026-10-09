import PlainpostCalendarPresentation
import Foundation
import SwiftUI
import PlainpostAccountRuntime
import PlainpostNodeTransport

/// The Node answered the capability probe without calendar assembled.
struct CalendarNodeDisabled: Error {}

@MainActor
public final class CalendarWeekViewModel: ObservableObject {
    @Published public var selectedDate: Date
    @Published public var timezoneID: String { didSet { persistSettings() } }
    @Published public var visibleCalendarIDs: Set<String> = [] { didSet { persistSettings() } }
    @Published public var showDeclined = false { didSet { persistSettings() } }
    @Published public private(set) var snapshot: NodeCalendarWindowSnapshot?
    @Published public var selectedEventID: String?
    @Published var editor: CalendarEventEditorViewModel?
    @Published public private(set) var connectionErrors: [String: String] = [:]
    @Published public private(set) var connections: [NodeCalendarConnection] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isCached = false
    private let service: any CalendarServing
    private let clock: () -> Date
    private let cache: CalendarSnapshotCache?
    private var hasSavedFilters = false
    private var knownCalendarIDs: Set<String> = []
    private var generation: UInt64 = 0
    private var visibilityGeneration: UInt64 = 0
    public private(set) var isVisible = false
    public var isRefreshingPeriodically: Bool { timerTask != nil }
    private var requestTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    /// A thread card's exact occurrence, applied once its week has loaded.
    private var pendingSelection: CalendarEventSelection?

    /// The event popover's invitation responses share the thread card's model
    /// type and durable intent ledger.
    private let intents: CalendarResponseIntentStore
    private var responseModel: ThreadInvitationViewModel?
    public convenience init(service: any CalendarServing, clock: @escaping () -> Date = Date.init) {
        self.init(service: service, clock: clock, cache: nil)
    }
    init(service: any CalendarServing, clock: @escaping () -> Date, cache: CalendarSnapshotCache?, intents: CalendarResponseIntentStore? = nil) {
        self.service = service; self.clock = clock; self.cache = cache
        self.intents = intents ?? cache.map { CalendarResponseIntentStore.shared(cache: $0) } ?? CalendarResponseIntentStore()
        selectedDate = clock(); timezoneID = TimeZone.current.identifier
        connections = (try? cache?.loadConnections()) ?? []
        if let settings = try? cache?.loadSettings() {
            timezoneID = TimeZone(identifier: settings.timezoneID)?.identifier ?? TimeZone.current.identifier
            visibleCalendarIDs = settings.visibleCalendarIDs; showDeclined = settings.showDeclined; hasSavedFilters = true
            knownCalendarIDs = settings.knownCalendarIDs ?? Set(connections.flatMap(\.calendars).map(\.id)).union(settings.visibleCalendarIDs)
        }
    }
    public var calendar: Calendar { var result = Calendar.current; result.timeZone = TimeZone(identifier: timezoneID) ?? .current; return result }
    public var interval: DateInterval? { CalendarWeekLayout.interval(containing: selectedDate, calendar: calendar) }
    public var now: Date { clock() }
    public var events: [NodeCalendarEvent] { snapshot?.events.filter { visibleCalendarIDs.contains($0.calendarID) && (showDeclined || $0.response != .declined) } ?? [] }
    var placements: [CalendarEventPlacement] { interval.map { CalendarWeekLayout.placements(events: events, interval: $0, calendar: calendar) } ?? [] }
    public var selectedEvent: NodeCalendarEvent? { events.first { $0.id == selectedEventID } }
    public var cachedAgeLabel: String? {
        guard isCached, let value = snapshot?.refreshedAt else { return nil }
        let date = ISO8601DateFormatter().date(from: value)
        return date.map { "Cached · " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: clock()) } ?? "Cached calendar"
    }

    public func load(refresh: Bool) async {
        guard let interval else { return }
        generation &+= 1; let current = generation
        requestTask?.cancel(); prefetchTask?.cancel()
        let request = Self.request(interval, timezoneID: timezoneID, refresh: refresh)
        if snapshot?.window != request.window {
            snapshot = try? cache?.load(request.window)
            selectedEventID = nil
            isCached = snapshot != nil
            applyPendingSelection()
        } else if !refresh { isCached = snapshot != nil }
        if let snapshot { connectionErrors = snapshot.failures }
        isLoading = true; errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let capabilities = try await service.capabilities()
                guard capabilities.enabled else { throw CalendarNodeDisabled() }
                let connections = try await service.connections()
                let result = try await service.window(request)
                guard generation == current, !Task.isCancelled else { return }
                self.connections = connections
                try? cache?.saveConnections(connections)
                let discovered = Set(connections.flatMap(\.calendars).map(\.id))
                let newlyDiscovered = discovered.subtracting(knownCalendarIDs)
                knownCalendarIDs.formUnion(discovered)
                hasSavedFilters = true
                visibleCalendarIDs.formUnion(newlyDiscovered)
                persistSettings()
                let projection = Self.preservingIncompleteCoverage(result, previous: snapshot)
                snapshot = projection; connectionErrors = result.failures; isCached = result.coverage != "complete"; isLoading = false
                try? cache?.save(projection)
                applyPendingSelection()
                prefetch(interval: interval, generation: current)
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                isLoading = false; isCached = snapshot != nil
                errorMessage = Self.message(error)
            }
        }
        requestTask = task
        await task.value
    }
    public func moveWeek(by offset: Int) async {
        guard let moved = calendar.date(byAdding: .weekOfYear, value: offset, to: selectedDate) else { return }
        selectedDate = moved; await load(refresh: true)
    }
    public func start(selection: CalendarEventSelection? = nil) async {
        isVisible = true; visibilityGeneration &+= 1; let visibleGeneration = visibilityGeneration
        if let selection { focus(selection) }
        observeReceipts(visibleGeneration)
        await load(refresh: true)
        guard isVisible, visibilityGeneration == visibleGeneration, !Task.isCancelled, timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.load(refresh: true)
            }
        }
    }
    /// Targets the week, calendar and original occurrence of a selection.
    func focus(_ selection: CalendarEventSelection) {
        pendingSelection = selection
        if let date = CalendarWeekLayout.date(selection.start, calendar: calendar) { selectedDate = date }
        if !visibleCalendarIDs.contains(selection.calendarID) { visibleCalendarIDs.insert(selection.calendarID) }
        applyPendingSelection()
    }
    private func applyPendingSelection() {
        guard let selection = pendingSelection, let event = snapshot?.events.first(where: selection.matches) else { return }
        pendingSelection = nil
        selectedEventID = event.id
    }
    /// Receipts admitted or read through the shared authority (thread cards,
    /// editor saves) refresh this week once the calendar write is confirmed.
    private func observeReceipts(_ visibleGeneration: UInt64) {
        updatesTask?.cancel()
        let service = service
        updatesTask = Task { [weak self] in
            for await receipt in await service.receiptUpdates() where receipt.calendar == .confirmed {
                guard let self, self.isVisible, self.visibilityGeneration == visibleGeneration else { return }
                await self.load(refresh: true)
            }
        }
    }
    func edit(_ event: NodeCalendarEvent) {
        guard editor == nil else {return}
        selectedEventID=nil
        editor=CalendarEventEditorViewModel(event:event,service:service)
    }
    func editorDidClose() async {
        let saved=editor?.receipt?.calendar == .confirmed
        editor=nil
        if saved {await mutationDidSucceed()}
    }
    public func mutationDidSucceed() async { await load(refresh: true) }
    /// The invitation response model for an attendee event linked to an
    /// invitation message, or nil when the event offers no response.
    func responses(for event: NodeCalendarEvent) -> ThreadInvitationViewModel? {
        guard !event.messageID.isEmpty, !event.attendeeAddress.isEmpty, !event.cancelled,
              event.organizer.lowercased() != event.attendeeAddress.lowercased() else { return nil }
        if let responseModel { return responseModel }
        let model = ThreadInvitationViewModel(service: service, intents: intents)
        responseModel = model
        return model
    }
    /// The linked invitation card that answers this exact event.
    static func responseCard(for event: NodeCalendarEvent, in model: ThreadInvitationViewModel) -> ThreadInvitationCardModel? {
        model.cards(forMessageID: event.messageID).first { $0.invitation.calendarEventID == event.id || $0.event?.id == event.id }
    }
    /// Bounded, provider-free per-connection refresh codes in plain language.
    nonisolated static func connectionMessage(_ code: String) -> String {
        switch code {
        case "events_skipped": "Some events couldn’t be shown"
        case "unavailable": "Refresh failed"
        default: code
        }
    }
    public func stop() {
        isVisible = false; visibilityGeneration &+= 1
        generation &+= 1; requestTask?.cancel(); requestTask = nil; prefetchTask?.cancel(); prefetchTask = nil
        timerTask?.cancel(); timerTask = nil; updatesTask?.cancel(); updatesTask = nil; isLoading = false
        responseModel?.stop()
    }
    func waitForPrefetch() async { await prefetchTask?.value }
    private func prefetch(interval: DateInterval, generation current: UInt64) {
        let calendar = calendar, timezone = timezoneID
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for offset in [-1, 1] {
                guard !Task.isCancelled, generation == current,
                      let date = calendar.date(byAdding: .weekOfYear, value: offset, to: interval.start),
                      let adjacent = CalendarWeekLayout.interval(containing: date, calendar: calendar) else { return }
                do {
                    // Prefetches read the stored projection; they never fetch providers.
                    let result = try await service.window(Self.request(adjacent, timezoneID: timezone, refresh: false))
                    guard generation == current, !Task.isCancelled else { return }
                    let previous = try? cache?.load(result.window)
                    try? cache?.save(Self.preservingIncompleteCoverage(result, previous: previous))
                } catch { return }
            }
        }
    }
    private static func preservingIncompleteCoverage(_ incoming: NodeCalendarWindowSnapshot, previous: NodeCalendarWindowSnapshot?) -> NodeCalendarWindowSnapshot {
        guard incoming.coverage != "complete", let previous, previous.window == incoming.window else { return incoming }
        var result = incoming
        var events = Dictionary(previous.events.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for event in incoming.events { events[event.id] = event }
        result.events = events.values.sorted { $0.id < $1.id }
        result.refreshedAt = previous.refreshedAt
        return result
    }
    private func persistSettings() {
        guard hasSavedFilters else { return }
        try? cache?.saveSettings(.init(timezoneID: timezoneID, visibleCalendarIDs: visibleCalendarIDs, showDeclined: showDeclined, knownCalendarIDs: knownCalendarIDs))
    }
    private static func request(_ interval: DateInterval, timezoneID: String, refresh: Bool) -> NodeCalendarWindowRequest {
        let formatter = ISO8601DateFormatter()
        return .init(window: .init(start: formatter.string(from: interval.start), end: formatter.string(from: interval.end), timezone: timezoneID), cursor: "", refresh: refresh)
    }
    static func message(_ error: Error) -> String {
        if error is CalendarNodeDisabled { return CalendarAvailability.disabled.settingsMessage ?? "" }
        return switch error as? NodeCalendarError {
        case .unsupported: "Calendar unavailable. Update your Sync Node to use Calendar."
        case .unauthorized: "Calendar authorization expired. Reconnect in Settings."
        case .deliveryUncertain: "Finishing setup… Refresh to check."
        case .conflict: "Calendar changed. Refresh and try again."
        default: "Calendar could not refresh. Cached events remain available."
        }
    }
}


#if DEBUG
@_spi(DesignPreview)
public enum CalendarDesignPreview {
    @MainActor public static func model(scenario: String) -> CalendarWeekViewModel {
        let now = ISO8601DateFormatter().date(from: "2026-09-16T10:00:00Z")!
        let model = CalendarWeekViewModel(service: CalendarFixtureService(scenario: scenario), clock: { now })
        model.timezoneID = "Europe/Zurich"
        return model
    }
    #if os(macOS)
    @MainActor public static func view(scenario: String) -> AnyView { AnyView(CalendarWeekView(model: model(scenario: scenario))) }
    @MainActor public static func allDayDetailsView() -> AnyView {
        var event = CalendarFixtureService(scenario: "all-day").event("offsite", "Team offsite", "2026-09-16", "2026-09-17", allDay: true)
        event.start.timezone = "Pacific/Auckland"; event.end.timezone = "Pacific/Auckland"
        var display = Calendar(identifier: .gregorian)
        display.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return AnyView(CalendarEventPopover(event: event, calendarName: "Work", calendar: display).frame(maxWidth: .infinity, maxHeight: .infinity).background(MailDesign.workArea))
    }
    @MainActor public static func reconnectView() -> AnyView {
        let model = CalendarSettingsModel(service: CalendarFixtureService(scenario: "normal"))
        model.beginReconnect(.init(id: "design", generation: 1, kind: .google, sendingMailbox: "", attendeeAddress: "me@example.test", delivery: .google, enabled: true))
        return AnyView(CalendarSettingsView(model: model).frame(width: 760).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(MailDesign.workArea))
    }

    #endif
}
private struct CalendarFixtureService: CalendarServing {
    let scenario: String
    func capabilities() async throws -> NodeCalendarCapabilities { .init(version: 1, providers: [.google, .caldav], enabled: true, google: .init(clientID: "calendar-client.example.apps.googleusercontent.com")) }
    func connections() async throws -> [NodeCalendarConnection] { [.init(id: "design", generation: 1, kind: .google, sendingMailbox: "", attendeeAddress: "me@example.test", delivery: .google, enabled: true, calendars: [.init(id: "work", name: "Work", color: "#557AC6", timezone: "Europe/Zurich", writable: true, scheduling: true), .init(id: "personal", name: "Personal", color: "#488A78", timezone: "Europe/Zurich", writable: false, scheduling: false)])] }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot {
        var events: [NodeCalendarEvent] = []
        if scenario == "overlap" {
            events = [event("review", "Product review", "2026-09-16T09:00:00+02:00", "2026-09-16T11:30:00+02:00"), event("planning", "Weekly planning", "2026-09-16T09:30:00+02:00", "2026-09-16T11:00:00+02:00"), event("design", "Design discussion", "2026-09-16T10:00:00+02:00", "2026-09-16T12:00:00+02:00", needsAction: true)]
        } else if scenario == "all-day" {
            events = [event("trip", "Team offsite · Zürich", "2026-09-14", "2026-09-17", allDay: true), event("leave", "Annual leave", "2026-09-17", "2026-09-21", allDay: true, personal: true), event("deadline", "Planning deadline", "2026-09-16", "2026-09-17", allDay: true)]
        } else {
            events = [event("standup", "Team check-in", "2026-09-14T09:00:00+02:00", "2026-09-14T09:45:00+02:00"), event("focus", "Product direction", "2026-09-15T10:00:00+02:00", "2026-09-15T11:30:00+02:00"), event("lunch", "Lunch with Anna", "2026-09-16T12:00:00+02:00", "2026-09-16T13:00:00+02:00", personal: true), event("review", "Design review", "2026-09-17T09:30:00+02:00", "2026-09-17T11:00:00+02:00", needsAction: true), event("walk", "Afternoon walk", "2026-09-18T14:00:00+02:00", "2026-09-18T15:00:00+02:00", personal: true), event("birthday", "Anna’s birthday", "2026-09-19", "2026-09-20", allDay: true, personal: true)]
        }
        return .init(events: events, window: request.window, coverage: "complete", refreshedAt: "2026-09-16T10:00:00Z", failures: [:], nextCursor: "")
    }
    fileprivate func event(_ id: String, _ title: String, _ start: String, _ end: String, allDay: Bool = false, personal: Bool = false, needsAction: Bool = false) -> NodeCalendarEvent {
        .init(id: id, connectionID: "design", calendarID: personal ? "personal" : "work", recurrenceID: "", organizer: "anna@example.test", revision: "1", sequence: 0, stamp: "", title: title, location: "Zürich", notes: "Discuss this week’s plans and next steps.", start: .init(kind: allDay ? .date : .dateTime, value: start, timezone: "Europe/Zurich"), end: .init(kind: allDay ? .date : .dateTime, value: end, timezone: "Europe/Zurich"), recurring: false, cancelled: false, attendeeAddress: "me@example.test", response: needsAction ? .needsAction : .accepted, canEditOccurrence: false, canEditSeries: false, canRespond: false, disabledReason: "Read-only calendar overview", threadID: "", messageID: "", providerLink: "")
    }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func event(id: String) async throws -> NodeCalendarEvent { throw NodeCalendarError.unsupported }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] { [] }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt { throw NodeCalendarError.unsupported }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { [] }
}
#endif


/// An admitted offline lease can browse disk projections without creating a transport.
struct CachedCalendarService: CalendarServing {
    func capabilities() async throws -> NodeCalendarCapabilities { throw NodeCalendarError.unavailable }
    func connections() async throws -> [NodeCalendarConnection] { throw NodeCalendarError.unavailable }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot { throw NodeCalendarError.unavailable }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unavailable }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unavailable }
    func event(id: String) async throws -> NodeCalendarEvent { throw NodeCalendarError.unavailable }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] { throw NodeCalendarError.unavailable }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt { throw NodeCalendarError.unavailable }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { throw NodeCalendarError.unavailable }
}
