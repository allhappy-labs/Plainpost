import PlainpostCalendarPresentation
import SwiftUI
import PlainpostAccountRuntime
import PlainpostNodeTransport

#if os(macOS)
struct CachedCalendarWorkspace: View {
    @StateObject private var model: CalendarWeekViewModel
    init(accountID: String, appDataRoot: URL) {
        _model = StateObject(wrappedValue: CalendarWeekViewModel(service: CachedCalendarService(), clock: Date.init, cache: CalendarSnapshotCache(accountID: accountID, appDataRoot: appDataRoot)))
    }
    var body: some View { CalendarWeekView(model: model, canConfigure: false) }
}

struct CalendarWorkspace: View {
    @StateObject private var model: CalendarWeekViewModel
    var openSettings: () -> Void
    var openThread: ((String, String) -> Void)?
    var selection: CalendarEventSelection?
    var backToThread: (() -> Void)?
    init(authority: PlainpostCalendarAuthority, appDataRoot: URL, openSettings: @escaping () -> Void, openThread: ((String, String) -> Void)? = nil, selection: CalendarEventSelection? = nil, backToThread: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: CalendarWeekViewModel(service: authority, clock: Date.init, cache: CalendarSnapshotCache(accountID: authority.accountID, appDataRoot: appDataRoot)))
        self.openSettings = openSettings; self.openThread = openThread; self.selection = selection; self.backToThread = backToThread
    }
    var body: some View { CalendarWeekView(model: model, openSettings: openSettings, openThread: openThread, selection: selection, backToThread: backToThread) }
}

/// Holds the hosting window weakly for key-window filtering.
final class CalendarHostWindow {
    weak var window: NSWindow?
}

/// Records the window that hosts the calendar week.
private struct CalendarHostWindowReader: NSViewRepresentable {
    let host: CalendarHostWindow
    func makeNSView(context: Context) -> NSView { Reader(host: host) }
    func updateNSView(_ nsView: NSView, context: Context) { host.window = nsView.window }
    final class Reader: NSView {
        let host: CalendarHostWindow
        init(host: CalendarHostWindow) { self.host = host; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); host.window = window }
    }
}

/// Observes the editor itself, so Cancel, Discard and Save close the sheet as
/// soon as editing ends rather than on the week view's next unrelated update.
private struct CalendarEditorSheet: View {
    @ObservedObject var editor: CalendarEventEditorViewModel
    let closed: () -> Void
    var body: some View {
        CalendarEventEditorView(model: editor)
            .onChange(of: editor.isEditing) { _, editing in if !editing { closed() } }
    }
}

struct CalendarWeekView: View {
    @ObservedObject var model: CalendarWeekViewModel
    var openSettings: () -> Void = {}
    var canConfigure = true
    var openThread: ((String, String) -> Void)?
    var selection: CalendarEventSelection?
    var backToThread: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedEvent: String?
    @State private var popoverAnchor: String?
    @State private var hostWindow = CalendarHostWindow()
    private let gutter: CGFloat = 58
    private var dayWidth: CGFloat { max(152, CGFloat(model.placements.map(\.columnCount).max() ?? 1) * 92) }
    private let hourHeight: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(12).background(MailDesign.background)
            Divider()
            status
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    let width = max(geometry.size.width, gutter + dayWidth * 7)
                    VStack(spacing: 0) {
                        dayHeaders(width: width)
                        allDayRow(width: width)
                        Divider()
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                timedGrid(width: width)
                            }.onAppear { proxy.scrollTo(8, anchor: .top) }
                        }
                    }.frame(width: width)
                }
            }
        }
        .background(MailDesign.workArea)
        .accessibilityIdentifier("calendar.week")
        .sheet(isPresented: Binding(get: { model.editor != nil }, set: { if !$0 { model.editor?.cancel() } })) {
            if let editor = model.editor {
                CalendarEditorSheet(editor: editor) { Task { await model.editorDidClose() } }
            }
        }
        .task { await model.start(selection: selection) }
        .onChange(of: model.selectedEventID) { _, id in
            // A programmatic selection opens the popover on the event's first day.
            guard let id, popoverAnchor?.hasPrefix(id + "-") != true,
                  let placement = model.placements.first(where: { $0.eventID == id }) else { return }
            popoverAnchor = id + "-" + String(placement.dayIndex)
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.load(refresh: true) } } }
        .onChange(of: model.timezoneID) { _, _ in Task { await model.load(refresh: true) } }
        .background(CalendarHostWindowReader(host: hostWindow))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard Self.refreshesOnKey(notification.object as AnyObject?, host: hostWindow.window) else { return }
            Task { await model.load(refresh: true) }
        }
        .focusSection()
    }
    /// Only the window hosting this calendar becoming key is a foregrounding
    /// refresh; other windows, panels and sheets are not.
    static func refreshesOnKey(_ window: AnyObject?, host: AnyObject?) -> Bool {
        guard let window, let host else { return false }
        return window === host
    }
    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let backToThread {
                    Button("Back to thread", systemImage: "chevron.left", action: backToThread).accessibilityIdentifier("calendar.backToThread")
                }
                Text("Calendar").font(.title3.weight(.semibold))
                Button("Today") { model.selectedDate = model.now; Task { await model.load(refresh: true) } }.accessibilityIdentifier("calendar.today")
                ControlGroup {
                    Button("Previous week", systemImage: "chevron.left") { Task { await model.moveWeek(by: -1) } }
                    Button("Next week", systemImage: "chevron.right") { Task { await model.moveWeek(by: 1) } }
                }.labelStyle(.iconOnly)
                DatePicker("Week", selection: Binding(get: { model.selectedDate }, set: { model.selectedDate = $0; Task { await model.load(refresh: true) } }), displayedComponents: .date).labelsHidden().frame(width: 116).accessibilityLabel("Choose calendar week")
                Picker("Timezone", selection: $model.timezoneID) { ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) } }.frame(width: 230)
                Menu {
                    ForEach(model.connections, id: \.id) { connection in
                        ForEach(connection.calendars, id: \.id) { collection in
                            Toggle(collection.name, isOn: Binding(get: { model.visibleCalendarIDs.contains(collection.id) }, set: { enabled in if enabled { model.visibleCalendarIDs.insert(collection.id) } else { model.visibleCalendarIDs.remove(collection.id) } }))
                        }
                    }
                    Divider()
                    Toggle("Show declined", isOn: $model.showDeclined)
                    if canConfigure { Button("Calendar settings", action: openSettings) }
                } label: { Label("Calendars", systemImage: "line.3.horizontal.decrease") }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load(refresh: true) } }.labelStyle(.iconOnly).help("Refresh calendar")
            }.controlSize(.regular)
        }.accessibilityElement(children: .contain).accessibilitySortPriority(100)
    }
    @ViewBuilder private var status: some View {
        if model.isLoading && model.snapshot == nil { ProgressView("Loading calendar…").padding(8) }
        if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1)) }
        if let age = model.cachedAgeLabel { Label(age, systemImage: "clock").font(.caption).padding(6) }
        ForEach(model.connectionErrors.keys.sorted(), id: \.self) { id in
            Label(id + ": " + CalendarWeekViewModel.connectionMessage(model.connectionErrors[id] ?? "unavailable"), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
        }
        if !model.isLoading && model.connections.isEmpty && model.errorMessage == nil {
            HStack { Text("Connect Google Calendar or CalDAV to see your week."); Button("Connect calendar", action: openSettings) }.font(.callout).padding(10)
        }
    }
    private func dayLabel(_ day: Date, format: String) -> String { let formatter = DateFormatter(); formatter.calendar = model.calendar; formatter.timeZone = model.calendar.timeZone; formatter.dateFormat = format; return formatter.string(from: day) }
    private func days() -> [Date] { guard let start = model.interval?.start else { return [] }; return (0..<7).compactMap { model.calendar.date(byAdding: .day, value: $0, to: start) } }
    private func dayHeaders(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(model.calendar.timeZone.abbreviation() ?? "Time").font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
            ForEach(days(), id: \.self) { day in
                VStack(spacing: 3) {
                    Text(dayLabel(day, format: "EEE")).font(.caption).textCase(.uppercase)
                    Text(dayLabel(day, format: "d")).font(.title2.weight(model.calendar.isDate(day, inSameDayAs: model.now) ? .bold : .regular))
                }.frame(width: (width - gutter) / 7, height: 64)
                .foregroundStyle(model.calendar.isDate(day, inSameDayAs: model.now) ? MailDesign.accentBlue : MailDesign.primaryText)
                .background(model.calendar.isDate(day, inSameDayAs: model.now) ? MailDesign.selectionSoft : Color.clear)
                .accessibilityLabel(dayLabel(day, format: "EEEE, MMMM d"))
            }
        }
    }
    private func allDayRow(width: CGFloat) -> some View {
        let placements = model.placements.filter { $0.allDaySpan > 0 }
        return HStack(alignment: .top, spacing: 0) {
            Text("All day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter, height: 30)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(placements.enumerated()), id: \.offset) { index, placement in
                    if let event = model.events.first(where: { $0.id == placement.eventID }) {
                        eventButton(event, placement: placement)
                            .frame(width: (width - gutter) / 7 * CGFloat(placement.allDaySpan) - 6, height: 25)
                            .offset(x: (width - gutter) / 7 * CGFloat(placement.dayIndex) + 3, y: CGFloat(index) * 28 + 3)
                    }
                }
            }.frame(height: max(32, CGFloat(placements.count) * 28 + 6))
        }
    }
    private func timedGrid(width: CGFloat) -> some View {
        let column = (width - gutter) / 7
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 0) {
                        Text(String(format: "%02d:00", hour)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: gutter, alignment: .center)
                        Rectangle().fill(MailDesign.stroke).frame(height: 0.5)
                    }.frame(height: hourHeight, alignment: .top).id(hour)
                }
            }
            ForEach(0..<8, id: \.self) { day in Rectangle().fill(MailDesign.stroke).frame(width: 0.5).offset(x: gutter + CGFloat(day) * column).accessibilityHidden(true) }
            ForEach(Array(model.placements.filter { $0.allDaySpan == 0 }.enumerated()), id: \.offset) { _, placement in
                if let event = model.events.first(where: { $0.id == placement.eventID }) {
                    eventButton(event, placement: placement)
                        .frame(width: column / CGFloat(placement.columnCount) - 5, height: max(15, placement.endMinute - placement.startMinute - 2))
                        .offset(x: gutter + CGFloat(placement.dayIndex) * column + CGFloat(placement.columnIndex) * column / CGFloat(placement.columnCount) + 3, y: placement.startMinute)
                }
            }
            TimelineView(.everyMinute) { _ in
                if let day = days().firstIndex(where: { model.calendar.isDate($0, inSameDayAs: model.now) }) {
                    HStack(spacing: 0) { Circle().frame(width: 6, height: 6); Rectangle().frame(height: 1) }
                        .foregroundStyle(.red).frame(width: column).offset(x: gutter + CGFloat(day) * column, y: CalendarWeekLayout.minute(model.now, calendar: model.calendar))
                        .accessibilityLabel("Current time")
                }
            }
        }.frame(width: width, height: hourHeight * 24)
    }
    private func eventButton(_ event: NodeCalendarEvent, placement: CalendarEventPlacement) -> some View {
        let collection = model.connections.flatMap(\.calendars).first { $0.id == event.calendarID }
        let name = collection?.name ?? "Calendar"
        let tint = Self.color(collection?.color)
        let anchorID = event.id + "-" + String(placement.dayIndex)
        return Button { popoverAnchor = anchorID; model.selectedEventID = event.id } label: {
            HStack(alignment: .top, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? "Untitled event" : event.title).font(.caption.weight(.semibold)).lineLimit(2)
                    if placement.allDaySpan == 0 && placement.endMinute - placement.startMinute >= 35 {
                        Text(name).font(.system(size: 10)).lineLimit(1)
                        if event.response == .needsAction || event.cancelled { Text(CalendarEventPopover.status(event)).font(.system(size: 10).weight(.medium)).lineLimit(1) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(4).background(tint.opacity(event.response == .needsAction ? 0.09 : 0.17), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: event.response == .needsAction ? [3, 2] : [])))
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focusedEvent == anchorID ? MailDesign.accentBlue : .clear, lineWidth: 2))
        .help(CalendarEventPopover.accessibilityLabel(event: event, calendarName: name, calendar: model.calendar))
        .focused($focusedEvent, equals: event.id + "-" + String(placement.dayIndex))
        .accessibilityIdentifier("calendar.event." + event.id + "." + String(placement.dayIndex))
        .accessibilityLabel(CalendarEventPopover.accessibilityLabel(event: event, calendarName: name, calendar: model.calendar))
        .accessibilitySortPriority(Double(90 - placement.dayIndex) - placement.startMinute / 1440)
        .popover(isPresented: Binding(get: { model.selectedEventID == event.id && popoverAnchor == anchorID }, set: { if !$0 { model.selectedEventID = nil } })) { CalendarEventPopover(event: event, calendarName: name, calendar: model.calendar, openThread: openThread, edit: { model.edit(event) }, backToThread: backToThread, responses: model.responses(for: event)) }
    }
    static func color(_ hex: String?) -> Color {
        guard let hex, hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return MailDesign.accentBlue }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
#endif
