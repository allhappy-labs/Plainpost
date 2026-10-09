import PlainpostCore
import SwiftUI

/// Message list block: sections of mail rows, optional selection + bulk bar, per-section receipts.
/// Selection lives in `AskMailListSelection`; commits and undo go through `AskMailActionCoordinator`.
struct AskMailMessageListBlockView: View {
    /// Turn-scoped block ID ("\(turn.id)/\(block.id)") used for coordinator keys.
    let blockID: String
    let block: AskMailMessageListBlock
    @ObservedObject var viewModel: AskMailViewModel
    @ObservedObject var actions: AskMailActionCoordinator

    @State private var selection: AskMailListSelection
    @State private var expanded: Set<String>
    @State private var showingAll: Set<String> = []

    init(blockID: String, block: AskMailMessageListBlock, viewModel: AskMailViewModel, actions: AskMailActionCoordinator) {
        self.blockID = blockID
        self.block = block
        self.viewModel = viewModel
        self.actions = actions
        _selection = State(initialValue: AskMailListSelection(block: block))
        #if os(iOS)
        _expanded = State(initialValue: [])
        #else
        _expanded = State(initialValue: Set(block.sections.prefix(1).map(\.id)))
        #endif
    }

    private var allowsMutations: Bool { viewModel.host.allowsMutations() }
    private var isSelectable: Bool { !block.bulkActions.isEmpty && allowsMutations }
    private var openSections: [AskMailMessageSection] { block.sections.filter { receipt(for: $0) == nil } }

    var body: some View {
        AskMailBlockContainer {
            AskMailBlockHeader(icon: block.icon, tint: block.tint, title: block.title, detail: "\(block.totalCount)")
            ForEach(block.sections) { section in
                Divider()
                if let receipt = receipt(for: section) {
                    doneLine(section: section, receipt: receipt)
                } else {
                    sectionView(section)
                }
            }
            if isSelectable, !openSections.isEmpty {
                Divider()
                bulkBar
            }
        }
    }

    private func receipt(for section: AskMailMessageSection) -> AskMailActionReceipt? {
        actions.receipts["\(blockID)/\(section.id)"]
    }

    // MARK: Section

    @ViewBuilder
    private func sectionView(_ section: AskMailMessageSection) -> some View {
        let isExpanded = block.sections.count == 1 || expanded.contains(section.id)
        sectionHeader(section, isExpanded: isExpanded)
        if isExpanded {
            let showAll = showingAll.contains(section.id)
            let visible = showAll ? section.rows : Array(section.rows.prefix(AskMailLimits.previewRowsPerSection))
            ForEach(visible) { row in
                rowView(row, in: section)
            }
            if !showAll, section.rows.count > visible.count {
                moreButton("Show all \(section.totalCount)") { showingAll.insert(section.id) }
            } else if section.totalCount > section.rows.count, let first = section.rows.first {
                moreButton("Open in mailbox to see all \(section.totalCount)") { viewModel.host.openMessage(first.source) }
            }
        }
    }

    private func sectionHeader(_ section: AskMailMessageSection, isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            if isSelectable {
                Button { selection.toggleSection(section.id) } label: {
                    AskMailCheckCircle(state: selection.sectionState(section.id))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(section.title)")
            }
            if block.sections.count > 1 {
                Button {
                    if expanded.contains(section.id) { expanded.remove(section.id) } else { expanded.insert(section.id) }
                } label: {
                    sectionTitle(section, isExpanded: isExpanded)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                // A lone section is always expanded, so its header is not a toggle.
                sectionTitle(section, isExpanded: true)
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func sectionTitle(_ section: AskMailMessageSection, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(section.tint.color).frame(width: 7, height: 7)
            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(MailDesign.primaryText)
            Text(countText(section)).font(.subheadline).monospacedDigit().foregroundStyle(MailDesign.tertiaryText)
            if block.sections.count > 1 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MailDesign.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            Spacer(minLength: 6)
            Text(section.summary)
                .font(.caption)
                .foregroundStyle(MailDesign.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
    }

    private func countText(_ section: AskMailMessageSection) -> String {
        guard isSelectable else { return "\(section.totalCount)" }
        let selected = selection.selectedCount(in: section.id)
        return selected == section.totalCount ? "\(section.totalCount)" : "\(selected) of \(section.totalCount)"
    }

    private func moreButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .padding(.leading, isSelectable ? 42 : 12)
            .padding(.top, 2)
            .padding(.bottom, 9)
    }

    // MARK: Rows

    private func rowView(_ row: AskMailMessageRow, in section: AskMailMessageSection) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                if isSelectable {
                    selection.toggleRow(row.messageID, in: section.id)
                } else {
                    viewModel.host.openMessage(row.source)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    if isSelectable {
                        AskMailCheckCircle(state: selection.isSelected(row.messageID) ? .all : .none)
                    } else {
                        MailSenderAvatar(sender: row.senderAddress, displayName: row.sender, size: 24)
                    }
                    rowText(row)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelectable && selection.isSelected(row.messageID) ? .isSelected : [])

            if block.rowAction == .reply, allowsMutations {
                Button("Reply") { viewModel.host.reply(row.messageID) }
                    .buttonStyle(AskMailSoftButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func rowText(_ row: AskMailMessageRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.sender)
                    .font(.subheadline.weight(row.isUnread ? .semibold : .regular))
                    .foregroundStyle(MailDesign.primaryText)
                    .lineLimit(1)
                if let tag = row.tag {
                    Text(tag).font(.caption2).foregroundStyle(MailDesign.secondaryText)
                }
                Spacer(minLength: 4)
                if let sentAt = row.sentAt {
                    Text(sentAt.askMailShortStamp).font(.caption).foregroundStyle(MailDesign.tertiaryText)
                }
            }
            Text(row.subject)
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Done line and bulk bar

    private func doneLine(section: AskMailMessageSection, receipt: AskMailActionReceipt) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(receipt.text).font(.subheadline).foregroundStyle(MailDesign.primaryText).lineLimit(2)
            Spacer(minLength: 4)
            if receipt.canUndo {
                Button("Undo") { actions.undo(blockID: blockID, sectionID: section.id) }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var bulkBar: some View {
        let selected = openSections.reduce(0) { $0 + selection.selectedCount(in: $1.id) }
        return HStack(spacing: 8) {
            Text(selected == 0 ? "Nothing selected" : "\(selected) selected")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(MailDesign.secondaryText)
            Spacer(minLength: 4)
            ForEach(block.bulkActions, id: \.self) { action in
                bulkButton(action)
            }
            .disabled(selected == 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func bulkButton(_ action: AskMailBulkAction) -> some View {
        let button = Button(Self.title(action)) { apply(action) }
        if action == .markRead {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func apply(_ action: AskMailBulkAction) {
        actions.apply(action, blockID: blockID, sections: openSections.map { section in
            (id: section.id, noun: section.title.lowercased(),
             messageIDs: selection.selectedMessageIDs(in: section.id), total: section.actionMessageIDs.count)
        })
    }

    private static func title(_ action: AskMailBulkAction) -> String {
        switch action {
        case .markRead: "Mark read"
        case .markUnread: "Mark unread"
        case .archive: "Archive"
        }
    }
}
