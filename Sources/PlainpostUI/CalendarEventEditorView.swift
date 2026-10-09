import PlainpostCalendarPresentation
import PlainpostNodeTransport
import SwiftUI

struct CalendarEventEditorView: View {
    @ObservedObject var model: CalendarEventEditorViewModel
    @State private var scope: NodeCalendarScope = .occurrence
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit event").font(.title2.weight(.semibold))
            if !model.readOnlyReason.isEmpty {
                Text(model.readOnlyReason).foregroundStyle(.secondary)
            }
            Form {
                TextField("Title", text: $model.draft.title)
                TextField("Location", text: $model.draft.location)
                TextField("Notes", text: $model.draft.notes, axis: .vertical).lineLimit(3...5)
                Toggle(
                    "All day",
                    isOn: Binding(get: { model.draft.start.kind == .date }, set: { setAllDay($0) })
                )
                DatePicker(
                    "Start", selection: dateBinding(start: true),
                    displayedComponents: model.draft.start.kind == .date
                        ? [.date] : [.date, .hourAndMinute])
                DatePicker(
                    model.draft.start.kind == .date ? "End (exclusive)" : "End",
                    selection: dateBinding(start: false),
                    displayedComponents: model.draft.start.kind == .date
                        ? [.date] : [.date, .hourAndMinute])
                Picker(
                    "Timezone",
                    selection: Binding(
                        get: { model.draft.start.timezone }, set: { setTimezone($0) })
                ) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) {
                        Text($0.replacingOccurrences(of: "_", with: " ")).tag($0)
                    }
                }
            }
            .disabled(model.saving || model.awaitingConfirmation || !model.readOnlyReason.isEmpty)
            if model.event.recurring {
                Picker("Apply changes to", selection: $scope) {
                    Text("This occurrence").tag(NodeCalendarScope.occurrence).disabled(
                        !model.event.canEditOccurrence)
                    Text("Entire series").tag(NodeCalendarScope.series).disabled(
                        !model.event.canEditSeries || timingChanged)
                }.pickerStyle(.segmented).disabled(model.saving || model.awaitingConfirmation)
                if timingChanged {
                    Text(
                        "Series time changes are unavailable because existing exceptions must be preserved."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !model.event.canEditOccurrence {
                    Text(model.event.disabledReason).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let validation = model.validationMessage {
                Text(validation).font(.callout).foregroundStyle(.secondary)
            }
            if model.conflict {
                Button("Refresh latest event") { Task { await model.refreshConflict() } }.disabled(
                    model.saving)
            }
            if let message = model.errorMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            if model.conflict, let latest = model.latestEvent {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Latest event").font(.headline)
                    Text(latest.title)
                    Text(CalendarEventPopover.timeLabel(event: latest, calendar: displayCalendar))
                        .font(
                            .caption)
                    if !latest.location.isEmpty { Text(latest.location).font(.caption) }
                    if !latest.notes.isEmpty { Text(latest.notes).font(.caption).lineLimit(4) }
                    Button("Review and reapply my draft") { model.reviewAndReapply() }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(
                    model.saving)
                Spacer()
                if model.saving { ProgressView().controlSize(.small) }
                Button(model.awaitingConfirmation ? "Check save" : "Save") {
                    Task { await model.save(scope: scope) }
                }
                .keyboardShortcut(.defaultAction).disabled(!model.canSave(scope: scope))
            }
        }.padding(24).frame(width: 520).background(MailDesign.workArea)
            .environment(\.timeZone, displayCalendar.timeZone)
            .interactiveDismissDisabled(true)
            .confirmationDialog(
                "Discard your unsaved draft?", isPresented: $model.showDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard draft", role: .destructive) { model.discard() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(
                    model.awaitingConfirmation
                        ? "A submitted save may still complete. Discarding this draft does not undo it."
                        : "Your changes will be lost.")
            }
            .onAppear {
                if !model.event.canEditOccurrence && model.event.canEditSeries { scope = .series }
            }
    }
    private var timingChanged: Bool {
        model.draft.start != model.event.start || model.draft.end != model.event.end
    }
    private var displayCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: model.draft.start.timezone) ?? .current
        return c
    }
    private func dateBinding(start: Bool) -> Binding<Date> {
        Binding(
            get: {
                CalendarWeekLayout.date(
                    start ? model.draft.start : model.draft.end, calendar: displayCalendar)
                    ?? Date()
            },
            set: { date in
                let value = wire(date, kind: model.draft.start.kind)
                if start { model.draft.start = value } else { model.draft.end = value }
            })
    }
    private func wire(_ date: Date, kind: NodeCalendarTimeKind) -> NodeCalendarTime {
        let f = DateFormatter()
        f.calendar = displayCalendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = displayCalendar.timeZone
        f.dateFormat = kind == .date ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ssXXX"
        return .init(
            kind: kind, value: f.string(from: date), timezone: displayCalendar.timeZone.identifier)
    }
    private func setAllDay(_ enabled: Bool) {
        let start = dateBinding(start: true).wrappedValue
        var end = dateBinding(start: false).wrappedValue
        let kind: NodeCalendarTimeKind = enabled ? .date : .dateTime
        if enabled && displayCalendar.isDate(start, inSameDayAs: end) {
            end = displayCalendar.date(byAdding: .day, value: 1, to: start) ?? end
        }
        model.draft.start = wire(start, kind: kind)
        model.draft.end = wire(end, kind: kind)
    }
    private func setTimezone(_ zone: String) {
        let start = dateBinding(start: true).wrappedValue
        let end = dateBinding(start: false).wrappedValue
        model.draft.start.timezone = zone
        model.draft.end.timezone = zone
        if model.draft.start.kind == .dateTime {
            model.draft.start = wire(start, kind: .dateTime)
            model.draft.end = wire(end, kind: .dateTime)
        }
    }
}
