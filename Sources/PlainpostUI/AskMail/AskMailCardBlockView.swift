import PlainpostCore
import SwiftUI

/// One thing pulled from an email (flight, invoice, event…): hero value, fields, actions, source.
struct AskMailCardBlockView: View {
    let turnID: String
    let card: AskMailCardBlock
    @ObservedObject var viewModel: AskMailViewModel
    @State private var isWorking = false

    var body: some View {
        AskMailBlockContainer {
            AskMailBlockHeader(icon: card.kind.icon, tint: card.kind.tint, title: card.kind.label,
                               detail: card.title, badge: card.badge)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.hero)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(MailDesign.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(MailDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if !card.fields.isEmpty {
                Divider()
                fieldsGrid
            }
            if card.calendarItem != nil || card.reminderItem != nil {
                Divider()
                actionsRow
            }
            Divider()
            sourceLine
        }
    }

    private var status: (event: AskMailCalendarStatus?, reminder: AskMailCalendarStatus?) {
        viewModel.calendarStatus(turnID: turnID, cardID: card.id)
    }

    private var fieldsGrid: some View {
        let rows = stride(from: 0, to: card.fields.count, by: 3).map { Array(card.fields[$0..<min($0 + 3, card.fields.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index].indices, id: \.self) { column in
                        let field = rows[index][column]
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.label).font(.caption).foregroundStyle(MailDesign.tertiaryText).lineLimit(1)
                            Text(field.value)
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(MailDesign.primaryText)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Each action keeps its own state: a finished one becomes a checkmark label while the other
    /// stays tappable; failures show their copy under the buttons.
    private var actionsRow: some View {
        let status = self.status
        let failures = [status.event, status.reminder].compactMap { outcome -> String? in
            if case .failed(let message) = outcome { return message }
            return nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if card.calendarItem != nil {
                    if status.event == .eventAdded {
                        doneLabel("Added to Calendar")
                    } else {
                        Button("Add to Calendar") { run { await viewModel.addToCalendar(card, turnID: turnID) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if card.reminderItem != nil {
                    if status.reminder == .reminderAdded {
                        doneLabel("Reminder added")
                    } else {
                        let button = Button("Remind me") { run { await viewModel.addReminder(card, turnID: turnID) } }
                        if card.calendarItem == nil {
                            button.buttonStyle(.borderedProminent)
                        } else {
                            button.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .controlSize(.small)
            .disabled(isWorking)
            ForEach(failures.indices, id: \.self) { index in
                Text(failures[index]).font(.caption).foregroundStyle(MailDesign.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func doneLabel(_ title: String) -> some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(MailDesign.primaryText)
            .symbolRenderingMode(.multicolor)
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        isWorking = true
        Task {
            await operation()
            isWorking = false
        }
    }

    private var sourceLine: some View {
        HStack(spacing: 6) {
            MailSenderAvatar(sender: card.source.sender, displayName: card.source.sender, size: 18)
            HStack(spacing: 0) {
                Text(card.source.sender).fontWeight(.medium).foregroundStyle(MailDesign.primaryText).layoutPriority(1)
                Text(sourceDetail).foregroundStyle(MailDesign.secondaryText)
            }
            .font(.caption)
            .lineLimit(1)
            Spacer(minLength: 4)
            Button("Open") { viewModel.host.openMessage(card.source) }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Open \(card.source.subject)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sourceDetail: String {
        var parts = [card.source.subject]
        if let sentAt = card.source.sentAt { parts.append(sentAt.askMailShortStamp) }
        return " · " + parts.joined(separator: " · ")
    }
}
