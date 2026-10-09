import SwiftUI
import PlainpostAI
import PlainpostCore

#if os(macOS)
import AppKit
#endif

struct PlainpostNowProviderKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> Date = { Date() }
}

struct PlainpostInitialSmartInboxBundleKey: EnvironmentKey {
    static let defaultValue: SmartInboxDisplayBundle? = nil
}

extension EnvironmentValues {
    var plainpostNow: @Sendable () -> Date {
        get { self[PlainpostNowProviderKey.self] }
        set { self[PlainpostNowProviderKey.self] = newValue }
    }

    var plainpostInitialSmartInboxBundle: SmartInboxDisplayBundle? {
        get { self[PlainpostInitialSmartInboxBundleKey.self] }
        set { self[PlainpostInitialSmartInboxBundleKey.self] = newValue }
    }
}

struct AppRail: View {
    @Binding var selectedDestination: PlainpostDestination
    let pendingApprovalCount: Int
    let openCommandCenter: () -> Void
    let openComposer: () -> Void
    let canCompose: Bool

    init(
        selectedDestination: Binding<PlainpostDestination>,
        pendingApprovalCount: Int = 0,
        openCommandCenter: @escaping () -> Void,
        openComposer: @escaping () -> Void = {},
        canCompose: Bool = true
    ) {
        self._selectedDestination = selectedDestination
        self.pendingApprovalCount = pendingApprovalCount
        self.openCommandCenter = openCommandCenter
        self.openComposer = openComposer
        self.canCompose = canCompose
    }

    static func approvalBadge(
        for destination: PlainpostDestination,
        pendingApprovalCount: Int
    ) -> Int? {
        destination == .approvalQueue && pendingApprovalCount > 0 ? pendingApprovalCount : nil
    }

    static func composeIsAvailable(
        isAccountSetupRequired: Bool,
        destination: PlainpostDestination
    ) -> Bool {
        !isAccountSetupRequired && destination.workAreaKind == .mailbox
    }

    var body: some View {
        VStack(spacing: canCompose ? 10 : 12) {
            Spacer().frame(height: canCompose ? 30 : 42)

            if canCompose {
                Button(action: openComposer) {
                    Image(systemName: "pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(MailDesign.accentBlue, in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.control).stroke(Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .help("Compose")
                .accessibilityLabel(Text("Compose"))
            }

            ForEach(PlainpostDestination.mailboxDestinations) { destination in
                railButton(destination)
            }

            Spacer()

            Button {
                openCommandCenter()
            } label: {
                Image(systemName: "command")
            }
            .railIcon(selected: false, badge: nil, help: "Command Center")

            ForEach(PlainpostDestination.utilityDestinations) { destination in
                railButton(destination)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 68)
        .background(.ultraThinMaterial)
        .background(MailDesign.rail.opacity(0.82))
    }

    private func railButton(_ destination: PlainpostDestination) -> some View {
        Button {
            selectedDestination = destination
        } label: {
            Image(systemName: destination.systemImage)
        }
        .railIcon(
            selected: selectedDestination == destination,
            badge: Self.approvalBadge(for: destination, pendingApprovalCount: pendingApprovalCount),
            help: destination.title
        )
    }
}

struct MailboxColumn: View {
    static let inboxDestinations: [PlainpostDestination] = [
        .smartInbox,
        .allInboxes,
        .personal,
        .notifications,
        .newsletters
    ]

    let viewModel: InboxViewModel
    @Binding var selectedDestination: PlainpostDestination
    @Binding var selectedInboxMode: String
    @Binding var searchQuery: String
    @Binding var selectedMessageID: String?
    @ObservedObject var mailActions: InboxMailActionViewModel
    @FocusState private var isSearchFocused: Bool
    @State private var activeSmartInboxBundle: SmartInboxDisplayBundle?

    init(
        viewModel: InboxViewModel,
        selectedDestination: Binding<PlainpostDestination>,
        selectedInboxMode: Binding<String>,
        searchQuery: Binding<String>,
        selectedMessageID: Binding<String?>,
        mailActions: InboxMailActionViewModel
    ) {
        self.viewModel = viewModel
        self._selectedDestination = selectedDestination
        self._selectedInboxMode = selectedInboxMode
        self._searchQuery = searchQuery
        self._selectedMessageID = selectedMessageID
        self.mailActions = mailActions
    }

    private var inboxDisplayMode: InboxDisplayMode {
        InboxDisplayMode(rawValue: selectedInboxMode) ?? .focusedList
    }

    static func smartInboxPresentation(
        mode: InboxDisplayMode,
        searchQuery: String
    ) -> MailMessageListColumn.ContentPresentation {
        MailMessageListColumn.presentation(
            destination: .smartInbox,
            mode: mode,
            searchQuery: searchQuery
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(MailDesign.tertiaryText)
                    TextField("Search mail (⌘F)", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            isSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MailDesign.tertiaryText)
                        .frame(width: 24, height: 24)
                        .help("Clear search")
                        .accessibilityLabel(Text("Clear search"))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .mailControlBackground()

                HStack {
                    Menu {
                        ForEach(Self.inboxDestinations) { destination in
                            Button {
                                selectInboxDestination(destination)
                            } label: {
                                Label(
                                    destination.title,
                                    systemImage: destination == selectedDestination ? "checkmark" : destination.systemImage
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedDestination.title)
                                .font(.system(size: 17, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(MailDesign.primaryText)
                    .help("Choose mailbox")
                    .accessibilityLabel(Text("Choose mailbox"))

                    Spacer()

                    Menu {
                        ForEach(InboxDisplayMode.allCases, id: \.rawValue) { mode in
                            Button {
                                selectedInboxMode = mode.rawValue
                            } label: {
                                Label(mode.title, systemImage: mode == inboxDisplayMode ? "checkmark" : "rectangle.3.group")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(inboxDisplayMode.title)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MailDesign.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(MailDesign.control, in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Choose inbox view")
                    .accessibilityLabel(Text("Choose inbox view"))
                }

            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            mailboxContent
        }
        .frame(width: 352)
        .background(.thinMaterial)
        .background(MailDesign.column.opacity(0.86))
        .onReceive(NotificationCenter.default.publisher(for: .plainpostAppCommand)) { notification in
            if notification.plainpostAppCommand == .focusSearch {
                isSearchFocused = true
            }
        }
    }

    @ViewBuilder
    private var mailboxContent: some View {
        if selectedDestination.usesSmartGrouping {
            smartInboxContent
        } else {
            flatMailboxContent
        }
    }

    @ViewBuilder
    private var smartInboxContent: some View {
        let allRows = viewModel.rows(for: .smartInbox, matching: searchQuery)
        let rows = inboxDisplayMode.visibleRows(from: allRows, destination: .smartInbox)

        switch Self.smartInboxPresentation(mode: inboxDisplayMode, searchQuery: searchQuery) {
        case .triage:
            SmartInboxTriageView(
                rows: viewModel.rows(for: .smartInbox),
                contentRevision: viewModel.contentRevision,
                selectedMessageID: $selectedMessageID,
                widthClass: .narrow,
                activeBundle: activeSmartInboxBundle,
                mailActions: mailActions,
                performMessageAction: { action, messageID in
                    Task {
                        _ = await mailActions.perform(action, messageID: messageID)
                    }
                },
                paginationPresentation: SmartInboxTriagePaginationPresentation(
                    footer: InboxPaginationFooterPresentation.make(
                        hasMoreRows: viewModel.hasMoreRows,
                        isLoadingMore: false
                    )
                ),
                loadMore: {},
                openBundle: { activeSmartInboxBundle = $0 },
                closeBundle: { activeSmartInboxBundle = nil },
                openMessage: { messageID, _ in
                    selectedMessageID = messageID
                }
            )
        case .unreadCards:
            let cards = SmartInboxCardModel.cards(
                from: rows,
                includeRead: false
            ).filter { !$0.messages.isEmpty }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if cards.isEmpty {
                        EmptyState(
                            title: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Smart Inbox is empty"
                                : "No matching messages",
                            detail: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Messages appear here after local AI classification."
                                : "Try a sender, subject, or phrase from the message preview."
                        )
                        .frame(minHeight: 280)
                    } else {
                        ForEach(cards) { card in
                            SmartInboxSection(
                                card: card,
                                selectedMessageID: selectedMessageID,
                                selectMessage: { selectedMessageID = $0 },
                                mailActions: mailActions
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 24)
            }
        case .flatList:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MailSectionHeader(
                        title: inboxDisplayMode == .simpleList ? "ALL MAIL" : "FOCUSED",
                        count: rows.count
                    )
                    ForEach(rows) { row in
                        MessageListRow(
                            row: row,
                            selected: row.id == selectedMessageID,
                            onSelect: { selectedMessageID = row.id },
                            mailActions: mailActions
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 24)
            }
        }
    }

    private var flatMailboxContent: some View {
        let rows = selectedDestination.showsThreadReader
            ? viewModel.rows(for: selectedDestination, matching: searchQuery)
            : []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                MailSectionHeader(title: selectedDestination.title.uppercased(), count: rows.count)
                if !selectedDestination.showsThreadReader {
                    MailboxUtilityList(destination: selectedDestination)
                } else if rows.isEmpty {
                    EmptyState(
                        title: "No messages",
                        detail: "\(selectedDestination.title) messages will appear here after sync."
                    )
                    .frame(minHeight: 280)
                } else {
                    ForEach(rows) { row in
                        MessageListRow(
                            row: row,
                            selected: row.id == selectedMessageID,
                            onSelect: { selectedMessageID = row.id },
                            mailActions: mailActions
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 24)
        }
    }

    private func selectInboxDestination(_ destination: PlainpostDestination) {
        selectedDestination = destination
        selectedMessageID = nil
        if destination != .smartInbox {
            selectedInboxMode = InboxDisplayMode.simpleList.rawValue
        }
    }
}

struct DenseMailboxList: View {
    let title: String
    let rows: [MessageRowModel]
    let selectMessage: (String) -> Void

    private var sections: [(title: String, rows: [MessageRowModel])] {
        let calendar = Calendar.current
        let now = Date()
        let today = rows.filter { $0.sentAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        let yesterday = rows.filter { row in
            guard let date = row.sentAt,
                  let previousDay = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            return calendar.isDate(date, inSameDayAs: previousDay)
        }
        let earlier = rows.filter { row in
            !today.contains(where: { $0.id == row.id }) && !yesterday.contains(where: { $0.id == row.id })
        }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)].filter { !$0.rows.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Text("\(rows.count) conversations")
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }
            .padding(.horizontal, 28)
            .frame(height: 62)
            .overlay(alignment: .bottom) { Rectangle().fill(MailDesign.stroke).frame(height: 1) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.rows) { row in
                                DenseMessageRow(row: row, select: { selectMessage(row.id) })
                            }
                        } header: {
                            Text(section.title)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(MailDesign.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 14)
                                .background(MailDesign.workArea)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailDesign.workArea)
    }
}

/// Marks a message whose change waits for the Sync Node to confirm it
/// (an `admitted` or `uncertain` intent).
struct WaitingForSyncNodeBadge: View {
    static let title = "Waiting for Sync Node"
    static let accessibilityText = "Waiting for Sync Node to confirm this change"
    let selected: Bool

    var body: some View {
        Label(Self.title, systemImage: "clock.arrow.circlepath")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(selected ? Color.white.opacity(0.85) : MailDesign.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((selected ? Color.white : MailDesign.secondaryText).opacity(0.12), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.accessibilityText))
    }
}

private struct DenseMessageRow: View {
    let row: MessageRowModel
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Circle()
                    .fill(row.isUnread ? MailDesign.unread : Color.clear)
                    .frame(width: 8, height: 8)

                MailSenderAvatar(sender: row.sender, displayName: row.senderDisplayName, size: 32)

                Text(MailSenderIdentity(sender: row.sender, displayName: row.senderDisplayName).displayName)
                    .font(.system(size: 15, weight: row.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(width: 220, alignment: .leading)

                Text(row.subject)
                    .font(.system(size: 15, weight: row.isUnread ? .medium : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 430, alignment: .leading)

                Text(row.preview)
                    .font(.system(size: 15))
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if row.threadMessageCount > 1 {
                    Text("\(row.threadMessageCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(MailDesign.accentBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(MailDesign.accentBlue.opacity(0.12), in: Capsule())
                }

                if row.isWaitingForNode {
                    WaitingForSyncNodeBadge(selected: false)
                }

                Text(row.dateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MailDesign.secondaryText)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 28)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(MailDesign.primaryText)
        .overlay(alignment: .bottom) { Rectangle().fill(MailDesign.stroke.opacity(0.42)).frame(height: 1) }
        .accessibilityLabel("\(MailSenderIdentity(sender: row.sender, displayName: row.senderDisplayName).displayName), \(row.subject)")
        .accessibilityValue(row.isWaitingForNode ? WaitingForSyncNodeBadge.accessibilityText : "")
    }
}

struct MailboxUtilityList: View {
    let destination: PlainpostDestination

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: destination.utilityState.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(destination.overviewTint)
                .frame(width: 30, height: 30)
                .background(destination.overviewTint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(destination.overviewTint.opacity(0.22)))

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MailDesign.primaryText)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(MailDesign.panel.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MailDesign.stroke))
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(destination.title))
        .accessibilityValue(Text(caption))
    }

    /// Drafts lists the saved drafts beside this card, so it never claims there are none.
    private var caption: String {
        destination == .drafts ? "Drafts saved in Plainpost" : destination.utilityState.title
    }
}

struct MailboxDestinationWorkspace: View {
    let destination: PlainpostDestination
    let openComposer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(destination.utilityState.title, systemImage: destination.utilityState.symbol)
        } description: {
            Text(destination.utilityState.detail)
        } actions: {
            if let actionTitle = destination.utilityState.actionTitle {
                Button(actionTitle, systemImage: "square.and.pencil", action: openComposer)
                    .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle(destination.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MailDesign.background)
    }
}

struct MailboxWorkspaceHeader: View {
    let destination: PlainpostDestination

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: destination.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(destination.overviewTint)
                .frame(width: 42, height: 42)
                .background(destination.overviewTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(destination.overviewTint.opacity(0.24)))

            VStack(alignment: .leading, spacing: 6) {
                Text(destination.title)
                    .font(.system(size: 25, weight: .semibold))
                Text(destination.utilityState.summary)
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

struct MailboxUtilityStateView: View {
    let state: MailboxUtilityState
    let tint: Color
    let openComposer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: state.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))

            Text(state.title)
                .font(.title3.weight(.semibold))

            Text(state.detail)
                .font(.callout)
                .foregroundStyle(MailDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle = state.actionTitle {
                Button {
                    openComposer()
                } label: {
                    Label(actionTitle, systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(MailDesign.primaryText)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .mailControlBackground()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .mailPanel(cornerRadius: 16)
    }
}

struct MailboxUtilityState: Equatable {
    let summary: String
    let title: String
    let detail: String
    let symbol: String
    let actionTitle: String?
}

extension PlainpostDestination {
    var utilityState: MailboxUtilityState {
        switch self {
        case .drafts:
            MailboxUtilityState(
                summary: "Create and review a message before sending it from this device.",
                title: "No drafts yet",
                detail: "Start a local draft when you are ready, then send it directly from the composer.",
                symbol: "doc.text",
                actionTitle: "New Draft"
            )
        case .sent:
            MailboxUtilityState(
                summary: "Review sent-message history.",
                title: "No sent messages to show",
                detail: "No sent-message data is available in this view.",
                symbol: "paperplane",
                actionTitle: nil
            )
        case .archive:
            MailboxUtilityState(
                summary: "Review conversations removed from active inboxes.",
                title: "No archived messages to show",
                detail: "No archived-message data is available in this view.",
                symbol: "archivebox",
                actionTitle: nil
            )
        case .trash:
            MailboxUtilityState(
                summary: "Review messages marked for deletion.",
                title: "No deleted messages to show",
                detail: "No deleted-message data is available in this view.",
                symbol: "trash",
                actionTitle: nil
            )
        case .labels:
            MailboxUtilityState(
                summary: "Organize conversations with labels.",
                title: "No labels to show",
                detail: "No label data is available in this view.",
                symbol: "tag",
                actionTitle: nil
            )
        default:
            MailboxUtilityState(
                summary: "Review mailbox contents.",
                title: "Nothing to show",
                detail: "No mailbox data is available in this view.",
                symbol: systemImage,
                actionTitle: nil
            )
        }
    }

    var overviewTint: Color {
        switch self {
        case .trash:
            Color(hex: 0xFF6B6B)
        case .sent:
            MailDesign.accentTeal
        case .archive:
            Color(hex: 0xB197FC)
        case .labels:
            Color(hex: 0xFFD166)
        default:
            MailDesign.accentBlue
        }
    }
}

struct SmartInboxSection: View {
    let card: SmartInboxCardModel
    let selectedMessageID: String?
    let selectMessage: (String) -> Void
    @ObservedObject var mailActions: InboxMailActionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MailSectionHeader(title: card.title.uppercased(), count: card.messages.count)

            if card.messages.isEmpty {
                Text("No messages")
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            } else {
                ForEach(card.messages) { row in
                    MessageListRow(
                        row: row,
                        selected: row.id == selectedMessageID,
                        onSelect: { selectMessage(row.id) },
                        mailActions: mailActions
                    )
                }
            }
        }
        .padding(.bottom, 8)
    }
}

struct MailSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MailDesign.secondaryText)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

struct MessageListRow: View {
    let row: MessageRowModel
    let selected: Bool
    let onSelect: () -> Void
    @ObservedObject var mailActions: InboxMailActionViewModel

    static func accessibilityLabel(for row: MessageRowModel) -> String {
        "\(MailSenderIdentity(sender: row.sender, displayName: row.senderDisplayName).displayName), \(row.subject)"
    }

    static func accessibilityValue(for row: MessageRowModel, selected: Bool) -> String {
        let signalLabels = SmartInboxSignalSet(
            priority: row.smartPriority,
            requiresAction: row.requiresAction
        ).items.map(\.accessibilityLabel)
        return [
            row.isUnread ? "Unread" : "Read",
            row.isWaitingForNode ? WaitingForSyncNodeBadge.accessibilityText : nil,
            selected ? "Selected" : nil,
            row.categoryLabel,
            row.dateLabel,
            row.preview,
            signalLabels.isEmpty ? nil : signalLabels.joined(separator: ", ")
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(row.isUnread ? MailDesign.unread : Color.clear)
                    .frame(width: 7, height: 7)
                    // Center the unread indicator on the 34pt sender avatar,
                    // rather than offsetting it relative to the whole row.
                    .padding(.top, 13.5)

                MailSenderAvatar(sender: row.sender, displayName: row.senderDisplayName, size: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(MailSenderIdentity(sender: row.sender, displayName: row.senderDisplayName).displayName)
                            .font(.system(size: 13, weight: row.isUnread ? .semibold : .medium))
                            .lineLimit(1)
                        if row.threadMessageCount > 1 {
                            Text("\(row.threadMessageCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(selected ? Color.white : MailDesign.accentBlue)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background((selected ? Color.white : MailDesign.accentBlue).opacity(selected ? 0.16 : 0.12), in: Capsule())
                        }
                        Spacer()
                        SmartInboxSignalIcons(
                            signals: SmartInboxSignalSet(
                                priority: row.smartPriority,
                                requiresAction: row.requiresAction
                            ),
                            selected: selected
                        )
                        Text(row.dateLabel)
                            .font(.caption)
                            .foregroundStyle(selected ? .white.opacity(0.72) : MailDesign.secondaryText)
                        if row.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                        }
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .opacity(row.actions.isEmpty ? 0 : 0.8)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: row.category.rowSymbol)
                            .font(.caption2)
                        Text(row.subject)
                            .font(.system(size: 13, weight: row.isUnread ? .semibold : .medium))
                            .lineLimit(1)
                        if row.isWaitingForNode {
                            Spacer(minLength: 4)
                            WaitingForSyncNodeBadge(selected: selected)
                        }
                    }

                    Text(row.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? .white.opacity(0.72) : MailDesign.secondaryText)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Color.white : MailDesign.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(selected ? MailDesign.selectionSoft : Color.clear, in: RoundedRectangle(cornerRadius: MailDesign.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.row).stroke(selected ? MailDesign.strokeStrong : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: MailDesign.Radius.row))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityLabel(for: row)))
        .accessibilityValue(Text(Self.accessibilityValue(for: row, selected: selected)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ThreadTranslationPreparationID: Equatable, Hashable, Sendable {
    let orderedMessageIDs: [String]
    let orderedSourceFingerprints: [String]
    let targetLanguageID: String
    let providerID: String
    let modelID: String
}

struct UnconfiguredThreadTranslationHandler: ThreadTranslationHandling {
    let providerID: String
    let modelID: String

    init(providerID: String = "disabled", modelID: String = "disabled") {
        self.providerID = providerID
        self.modelID = modelID
    }

    func cachedTranslation(
        messageID _: MessageID,
        targetLanguageID _: String
    ) throws -> MessageTranslationResult? {
        nil
    }

    func translate(
        messageID _: MessageID,
        targetLanguageID _: String,
        targetLanguageName _: String
    ) async throws -> MessageTranslationResult {
        throw PlainpostError.notFound("Translation is unavailable.")
    }
}

struct ThreadReaderWorkspace: View {
    let thread: ThreadDetailModel
    @ObservedObject var translation: ThreadTranslationViewModel
    let translationLanguage: TranslationLanguageOption
    let translationProviderID: String
    let translationModelID: String
    let openComposer: () -> Void
    let openAttachment: (MailAttachment) async -> Void
    let selectedMessageID: String?
    @ObservedObject var mailActions: InboxMailActionViewModel
    let dismissReader: () -> Void
    let performMessageAction: (InboxMailAction, String) -> Void
    let invitations: ThreadInvitationViewModel?
    let showInCalendar: ((CalendarEventSelection, String) -> Void)?
    let invitationScrollMessageID: String?
    @AppStorage(PlainpostPrivacyPreference.blockRemoteImagesKey)
    private var blockRemoteImages = true
    @State private var allowsRemoteContent = false
    @State private var isRemoteContentBannerDismissed = false
    /// The language of the original bodies, for the translation pill.
    @State private var translationSourceLanguageName: String?

    init(
        thread: ThreadDetailModel,
        translation: ThreadTranslationViewModel? = nil,
        translationLanguage: TranslationLanguageOption = TranslationLanguageOption(
            id: TranslationLanguageCatalog.defaultLanguageID,
            localizedName: "English"
        ),
        translationProviderID: String = "disabled",
        translationModelID: String = "disabled",
        openComposer: @escaping () -> Void,
        openAttachment: @escaping (MailAttachment) async -> Void = { _ in },
        selectedMessageID: String? = nil,
        mailActions: InboxMailActionViewModel = .preview(),
        dismissReader: @escaping () -> Void = {},
        performMessageAction: @escaping (InboxMailAction, String) -> Void = { _, _ in },
        invitations: ThreadInvitationViewModel? = nil,
        showInCalendar: ((CalendarEventSelection, String) -> Void)? = nil,
        invitationScrollMessageID: String? = nil
    ) {
        self.thread = thread
        self.translation = translation
            ?? ThreadTranslationViewModel(
                handler: UnconfiguredThreadTranslationHandler()
            )
        self.translationLanguage = translationLanguage
        self.translationProviderID = translationProviderID
        self.translationModelID = translationModelID
        self.openComposer = openComposer
        self.openAttachment = openAttachment
        self.selectedMessageID = selectedMessageID
        self.mailActions = mailActions
        self.dismissReader = dismissReader
        self.performMessageAction = performMessageAction
        self.invitations = invitations
        self.showInCalendar = showInCalendar
        self.invitationScrollMessageID = invitationScrollMessageID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if thread.messages.isEmpty {
                            EmptyState(
                                title: "No conversation selected",
                                detail: "Choose a message from the inbox to read the thread and use AI assistance."
                            )
                            .frame(minHeight: 420)
                        } else {
                            subjectHeader

                            if let code = thread.verificationCode {
                                VerificationCodeBanner(code: code)
                                    .id(code)
                            }

                            if blockRemoteImages && blockedRemoteImageCount > 0 {
                                RemoteImagesBanner(
                                    blockedCount: blockedRemoteImageCount,
                                    imagesLoaded: allowsRemoteContent,
                                    isDismissed: isRemoteContentBannerDismissed,
                                    showImages: { allowsRemoteContent = true },
                                    dismiss: { isRemoteContentBannerDismissed = true }
                                )
                            }

                            if translation.isTranslating || translation.displayMode == .translated {
                                ConversationTranslationPill(
                                    sourceLanguageName: translationSourceLanguageName,
                                    progressText: translation.progressText,
                                    showOriginal: { translation.showOriginal() }
                                )
                            }

                            // A reader slot is stable across message selections, so
                            // SwiftUI updates the existing WKWebView instead of
                            // destroying it and cold-starting a new WebKit reader.
                            ForEach(Array(thread.messages.enumerated()), id: \.offset) { _, message in
                                ConversationMessageDisclosure(
                                    message: message,
                                    displayedBody: translation.displayedBody(for: message),
                                    isSelected: message.id == selectedMessageID,
                                    isOnlyMessage: thread.messages.count == 1,
                                    allowsRemoteContent: allowsRemoteContent || !blockRemoteImages,
                                    allowsReply: message.id == selectedMessageID && allowsReply,
                                    openComposer: openComposer,
                                    openAttachment: openAttachment,
                                    invitationCards: invitationCards(for: message, scrollProxy: scrollProxy)
                                )
                            }

                            if allowsReply && showsAutomatedReplyAdvisory {
                                AutomatedReplyAdvisory()
                            } else if !allowsReply {
                                ReplyUnavailableNotice()
                            }
                        }
                    }
                    .padding(.horizontal, readerHorizontalPadding)
                    #if os(iOS)
                    .padding(.top, 12)
                    #else
                    .padding(.top, 20)
                    #endif
                    .padding(.bottom, 120)
                    .frame(
                        maxWidth: MailboxCanvasLayout.readerContentMaximumWidth,
                        alignment: .leading
                    )
                }
                #if os(iOS)
                .safeAreaPadding(.top, 12)
                #endif
            }
        }
        .mailboxReaderCanvas()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(MailDesign.workArea, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #else
        .navigationTitle(thread.messages.isEmpty ? "No Selection" : thread.subject)
        #endif
        // The summary is prepared by the ✦ pane (`PlainpostRootView` points it at the selection),
        // never here: a second preparer would drop a draft the pane must write again.
        .task(id: translationPreparationID) {
            await translation.prepare(
                messages: thread.messages,
                configuration: translationConfiguration
            )
        }
        .task(id: thread.messages.map(\.translationSourceFingerprint)) {
            translationSourceLanguageName = ConversationLanguage.dominantLanguageName(
                of: thread.messages.map(\.safeBodyText)
            )
        }
        .onChange(of: thread.messages.first?.id) {
            allowsRemoteContent = false
            isRemoteContentBannerDismissed = false
        }
        .task(id: thread.messages.map(\.id)) {
            await invitations?.prepare(messageIDs: thread.messages.map(\.id))
        }
        .onDisappear { invitations?.stop() }
    }

    /// Calendar invitation cards for one message; the original message body,
    /// MIME and attachments render unchanged below them.
    private func invitationCards(for message: ThreadMessageModel, scrollProxy: ScrollViewProxy) -> AnyView? {
        #if os(macOS)
        guard let invitations else { return nil }
        let messageID = message.id
        return AnyView(ThreadInvitationCards(
            model: invitations,
            messageID: messageID,
            showInCalendar: showInCalendar.map { show in { show($0, messageID) } },
            scrollIntoView: invitationScrollMessageID == messageID
                ? { scrollProxy.scrollTo(ThreadInvitationCards.scrollID(messageID: messageID), anchor: .top) } : nil
        ))
        #else
        return nil
        #endif
    }

    private var blockedRemoteImageCount: Int {
        thread.messages.reduce(0) { $0 + $1.blockedRemoteImageCount }
    }

    private var readerHorizontalPadding: CGFloat {
        #if os(iOS)
        16
        #else
        28
        #endif
    }

    private var translationConfiguration: ThreadTranslationConfiguration {
        ThreadTranslationConfiguration(
            targetLanguageID: translationLanguage.id,
            targetLanguageName: translationLanguage.localizedName
        )
    }

    private var translationPreparationID: ThreadTranslationPreparationID {
        ThreadTranslationPreparationID(
            orderedMessageIDs: thread.messages.map(\.id),
            orderedSourceFingerprints: thread.messages.map(\.translationSourceFingerprint),
            targetLanguageID: translationLanguage.id,
            providerID: translationProviderID,
            modelID: translationModelID
        )
    }

    private var subjectHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                subjectTitle
                categoryBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                subjectTitle
                categoryBadge
            }
        }
    }

    private var subjectTitle: some View {
        Text(thread.subject)
            .font(.title2.weight(.semibold))
            .foregroundStyle(MailDesign.primaryText)
            .lineLimit(2)
            .accessibilityIdentifier("mailbox.reader.subject")
    }

    private var categoryBadge: some View {
        MailCategoryBadge(label: thread.categoryLabel)
    }

    private var allowsReply: Bool {
        sourceVerifiedReplyRecipient != nil
    }

    private var sourceVerifiedReplyRecipient: String? {
        SourceVerifiedReplyTarget.recipient(
            selectedMessageID: selectedMessageID,
            thread: thread
        )
    }

    private var showsAutomatedReplyAdvisory: Bool {
        SourceVerifiedReplyTarget.isLikelyAutomated(
            selectedMessageID: selectedMessageID,
            thread: thread
        )
    }

    private func performSelectedMessageAction(_ action: InboxMailAction) {
        guard let selectedMessageID else {
            return
        }
        performMessageAction(action, selectedMessageID)
    }
}

enum SourceVerifiedReplyTarget {
    static func recipient(for message: ThreadMessageModel) -> String? {
        let replyTo = message.replyTo.map(sanitizedAddress)
        let sender = sanitizedAddress(message.sender)
        return ReplyAddressPolicy.recipient(
            replyTo: replyTo.map { EmailAddress($0) },
            from: EmailAddress(sender)
        )?.rawValue
    }

    static func recipient(selectedMessageID: String?, thread: ThreadDetailModel) -> String? {
        guard thread.categoryLabel != PlainpostDestination.notifications.title,
              let selectedMessageID,
              let message = thread.messages.first(where: { $0.id == selectedMessageID })
        else {
            return nil
        }
        return recipient(for: message)
    }

    static func isLikelyAutomated(selectedMessageID: String?, thread: ThreadDetailModel) -> Bool {
        guard let recipient = recipient(selectedMessageID: selectedMessageID, thread: thread) else {
            return false
        }
        return ReplyAddressPolicy.isLikelyAutomated(EmailAddress(recipient))
    }

    private static func sanitizedAddress(_ address: String) -> String {
        address
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ReaderToolbar: View {
    let isUnread: Bool
    let isWorking: Bool
    let dismissReader: () -> Void
    let performMessageAction: (InboxMailAction) -> Void

    init(
        isUnread: Bool = false,
        isWorking: Bool = false,
        dismissReader: @escaping () -> Void = {},
        performMessageAction: @escaping (InboxMailAction) -> Void = { _ in }
    ) {
        self.isUnread = isUnread
        self.isWorking = isWorking
        self.dismissReader = dismissReader
        self.performMessageAction = performMessageAction
    }

    var body: some View {
        HStack(spacing: 18) {
            ToolbarIcon("chevron.left", "Back", selected: true, action: dismissReader)
            ToolbarIcon("archivebox", "Archive") { performMessageAction(.archive) }
            ToolbarIcon("trash", "Delete") { performMessageAction(.delete) }
            MailDivider().frame(height: 28)
            ToolbarIcon(isUnread ? "envelope.open" : "envelope.badge", isUnread ? "Mark read" : "Mark unread") {
                performMessageAction(isUnread ? .markRead : .markUnread)
            }
            Spacer()
        }
        .disabled(isWorking)
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
        .background(MailDesign.workArea.opacity(0.64))
        .overlay(alignment: .bottom) { Rectangle().fill(MailDesign.stroke).frame(height: 1) }
    }
}

struct ToolbarIcon: View {
    let symbol: String
    let help: String
    let selected: Bool
    let action: () -> Void

    init(_ symbol: String, _ help: String, selected: Bool = false, action: @escaping () -> Void = {}) {
        self.symbol = symbol
        self.help = help
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .foregroundStyle(MailDesign.secondaryText)
        .frame(width: 30, height: 30)
        .mailGlassButtonStyle()
        .tint(selected ? MailDesign.accentBlue : nil)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

enum ConversationExpansionPolicy {
    static func startsExpanded(isSelected _: Bool, isOnlyMessage _: Bool) -> Bool {
        true
    }
}

struct ConversationMessageDisclosure: View {
    let message: ThreadMessageModel
    let displayedBody: RenderedEmailBody
    let isSelected: Bool
    let isOnlyMessage: Bool
    let allowsRemoteContent: Bool
    let allowsReply: Bool
    let openComposer: () -> Void
    let openAttachment: (MailAttachment) async -> Void
    let invitationCards: AnyView?
    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.mailAccessibilityPreviewOverrides) private var previewOverrides

    private var reduceMotion: Bool {
        previewOverrides.reduceMotion ?? systemReduceMotion
    }

    init(
        message: ThreadMessageModel,
        displayedBody: RenderedEmailBody? = nil,
        isSelected: Bool,
        isOnlyMessage: Bool,
        allowsRemoteContent: Bool,
        allowsReply: Bool,
        openComposer: @escaping () -> Void,
        openAttachment: @escaping (MailAttachment) async -> Void = { _ in },
        invitationCards: AnyView? = nil
    ) {
        self.message = message
        self.displayedBody = displayedBody ?? message.renderedBodySnapshot
        self.invitationCards = invitationCards
        self.isSelected = isSelected
        self.isOnlyMessage = isOnlyMessage
        self.allowsRemoteContent = allowsRemoteContent
        self.allowsReply = allowsReply
        self.openComposer = openComposer
        self.openAttachment = openAttachment
        self._isExpanded = State(
            initialValue: ConversationExpansionPolicy.startsExpanded(
                isSelected: isSelected,
                isOnlyMessage: isOnlyMessage
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        MailSenderAvatar(
                            sender: message.sender,
                            displayName: message.senderDisplayName,
                            size: 34
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(MailSenderIdentity(
                                sender: message.sender,
                                displayName: message.senderDisplayName
                            ).displayName)
                            .font(.headline)
                            .lineLimit(1)

                            Text(message.sender)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(minWidth: 0, alignment: .leading)
                        .layoutPriority(1)

                        Spacer(minLength: 8)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                if !message.dateLabel.isEmpty {
                                    Text(message.dateLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                disclosureChevron
                            }
                            .fixedSize(horizontal: true, vertical: false)

                            disclosureChevron
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Message from \(MailSenderIdentity(sender: message.sender, displayName: message.senderDisplayName).displayName)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Collapse message" : "Expand message")

                if allowsReply {
                    ToolbarIcon("arrowshape.turn.up.left", "Reply", action: openComposer)
                }
            }

            if isExpanded {
                Divider()
                    .padding(.vertical, 12)

                if let invitationCards {
                    invitationCards.padding(.bottom, 12)
                }

                ThreadMessageBlock(
                    message: message,
                    displayedBody: displayedBody,
                    allowsRemoteContent: allowsRemoteContent,
                    openAttachment: openAttachment
                )
                .transition(.opacity)
            }
        }
        .padding(14)
        .mailPanel(cornerRadius: 14)
        .readerPanelLayoutProbe("reader-message-panel")
        .onChange(of: isSelected) { _, selected in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                isExpanded = ConversationExpansionPolicy.startsExpanded(
                    isSelected: selected,
                    isOnlyMessage: isOnlyMessage
                )
            }
        }
        .onChange(of: message.id) {
            isExpanded = ConversationExpansionPolicy.startsExpanded(
                isSelected: isSelected,
                isOnlyMessage: isOnlyMessage
            )
        }
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
}

struct RemoteImagesBanner: View {
    let blockedCount: Int
    let imagesLoaded: Bool
    let isDismissed: Bool
    let showImages: () -> Void
    let dismiss: () -> Void

    init(
        blockedCount: Int = 1,
        imagesLoaded: Bool = false,
        isDismissed: Bool = false,
        showImages: @escaping () -> Void = {},
        dismiss: @escaping () -> Void = {}
    ) {
        self.blockedCount = blockedCount
        self.imagesLoaded = imagesLoaded
        self.isDismissed = isDismissed
        self.showImages = showImages
        self.dismiss = dismiss
    }

    var body: some View {
        Group {
            if isDismissed {
                Color.clear
                    .accessibilityHidden(true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: imagesLoaded ? "checkmark.circle.fill" : "photo")
                            .foregroundStyle(imagesLoaded ? MailDesign.accentTeal : MailDesign.secondaryText)
                        Text(statusText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        #if os(macOS)
                        if !imagesLoaded {
                            Button("Show images", action: showImages)
                                .buttonStyle(.bordered)
                                .font(.caption.weight(.semibold))
                                .controlSize(.small)
                                .accessibilityHint("Loads remote images for this message.")
                            Button(action: dismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(MailDesign.secondaryText)
                            .frame(width: 26, height: 26)
                            .help("Dismiss remote image warning")
                            .accessibilityLabel("Dismiss remote image warning")
                        }
                        #else
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MailDesign.secondaryText)
                        .frame(width: 26, height: 26)
                        .help("Dismiss remote image warning")
                        .accessibilityLabel("Dismiss remote image warning")
                        #endif
                    }
                    #if os(iOS)
                    if !imagesLoaded {
                        Button("Show images", action: showImages)
                            .buttonStyle(.bordered)
                            .accessibilityHint("Loads remote images for this message.")
                            .padding(.leading, 26)
                    }
                    #endif
                }
                .font(.callout)
                .foregroundStyle(MailDesign.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .mailControlBackground(cornerRadius: MailDesign.Radius.control)
            }
        }
        .frame(minHeight: 44)
    }

    private var statusText: String {
        if imagesLoaded {
            return blockedCount == 1 ? "Remote image loaded." : "\(blockedCount) remote images loaded."
        }
        return blockedCount == 1
            ? "1 remote image blocked to protect your privacy."
            : "\(blockedCount) remote images blocked to protect your privacy."
    }
}

private struct InlineImageTaskID: Equatable {
    let messageID: String
    let html: String
}

/// Reads the image parts a message's HTML names by `cid:`.
struct InlineImagePartsLoader {
    let load: @MainActor (String) -> [InlineImagePart]
}

private struct InlineImagePartsKey: EnvironmentKey {
    static let defaultValue = InlineImagePartsLoader { _ in [] }
}

extension EnvironmentValues {
    var inlineImageParts: InlineImagePartsLoader {
        get { self[InlineImagePartsKey.self] }
        set { self[InlineImagePartsKey.self] = newValue }
    }
}

struct ThreadMessageBlock: View {
    let message: ThreadMessageModel
    let displayedBody: RenderedEmailBody
    let allowsRemoteContent: Bool
    let openAttachment: (MailAttachment) async -> Void
    /// The plain-text body's font. The iPhone conversation passes a text style so the body
    /// follows Dynamic Type; everywhere else keeps the fixed 15 pt.
    let plainTextFont: Font
    @State private var htmlContentHeight: CGFloat = 180
    @State private var deferredRenderedBody: RenderedEmailBody?
    /// The HTML with its `cid:` images swapped for the message's own parts.
    @State private var inlineResolved: (source: String, html: String)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.inlineImageParts) private var inlineImageParts

    init(
        message: ThreadMessageModel,
        displayedBody: RenderedEmailBody? = nil,
        allowsRemoteContent: Bool = false,
        openAttachment: @escaping (MailAttachment) async -> Void = { _ in },
        plainTextFont: Font = .system(size: 15)
    ) {
        self.message = message
        self.displayedBody = displayedBody ?? message.renderedBodySnapshot
        self.allowsRemoteContent = allowsRemoteContent
        self.openAttachment = openAttachment
        self.plainTextFont = plainTextFont
        // A message rendered before shows its HTML, at its last height, on the first frame.
        _deferredRenderedBody = State(initialValue: Self.cachedRenderedBody(for: message))
        _htmlContentHeight = State(initialValue: HTMLMessageHeightCache.height(for: message.id) ?? 180)
    }

    private static func cachedRenderedBody(for message: ThreadMessageModel) -> RenderedEmailBody? {
        message.deferredBody.flatMap {
            DeferredEmailBodyRenderStore.shared.cachedBody(messageID: message.id, input: $0)
        }
    }

    @ViewBuilder
    var body: some View {
        Group {
            if resolvedDisplayedBody.kind == .html,
               let html = resolvedDisplayedBody.safeHTML {
                HTMLMessageView(
                    html: inlineResolved?.source == html ? inlineResolved?.html ?? html : html,
                    allowsRemoteContent: allowsRemoteContent,
                    contentHeight: $htmlContentHeight
                )
                .task(id: InlineImageTaskID(messageID: message.id, html: html)) {
                    guard InlineImageResolver.references(in: html) else { return }
                    let parts = inlineImageParts.load(message.id)
                    guard !parts.isEmpty else { return }
                    let resolved = await Task.detached(priority: .userInitiated) {
                        InlineImageResolver.resolve(html: html, parts: parts)
                    }.value
                    guard !Task.isCancelled, resolved != html else { return }
                    inlineResolved = (html, resolved)
                }
                .frame(maxWidth: .infinity)
                .frame(height: htmlContentHeight)
                .background(MailDesign.workArea)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(MailDesign.strokeStrong))
                .onChange(of: message.id) {
                    htmlContentHeight = HTMLMessageHeightCache.height(for: message.id) ?? 180
                }
                .onChange(of: htmlContentHeight) { _, height in
                    HTMLMessageHeightCache.record(height, for: message.id)
                }
            } else {
                Text(resolvedDisplayedBody.safeText)
                    .font(plainTextFont)
                    .lineSpacing(6)
                    .foregroundStyle(MailDesign.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Attachments").font(.headline)
                    ForEach(message.attachments, id: \.id) { attachment in
                        Button {
                            Task { await openAttachment(attachment) }
                        } label: {
                            Label(attachment.filename, systemImage: "paperclip")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Open attachment \(attachment.filename)")
                    }
                }
            }
        }
        .task(id: message.id) {
            guard let deferredBody = message.deferredBody else {
                deferredRenderedBody = nil
                return
            }
            if let cached = Self.cachedRenderedBody(for: message) {
                deferredRenderedBody = cached
                return
            }
            deferredRenderedBody = nil
            let renderedBody = await DeferredEmailBodyRenderStore.shared.render(
                messageID: message.id,
                input: deferredBody
            )
            guard !Task.isCancelled else {
                return
            }
            deferredRenderedBody = renderedBody
        }
    }

    private var resolvedDisplayedBody: RenderedEmailBody {
        let candidate = displayedBody == message.renderedBodySnapshot
            ? deferredRenderedBody ?? displayedBody
            : displayedBody
        return Self.bodyOnlyReplacement(
            for: message,
            displayedBody: candidate
        )
    }

    static func bodyOnlyReplacement(
        for message: ThreadMessageModel,
        displayedBody: RenderedEmailBody
    ) -> RenderedEmailBody {
        RenderedEmailBody(
            kind: displayedBody.kind,
            safeText: displayedBody.safeText,
            safeHTML: displayedBody.safeHTML,
            blockedRemoteImageURLs: message.blockedRemoteImageURLs
        )
    }
}

enum AISummaryMarkdown {
    static func attributedString(from source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }
}

private extension View {
    @ViewBuilder
    func readerPanelLayoutProbe(_ identifier: String) -> some View {
#if DEBUG && os(macOS)
        background(ReaderPanelLayoutProbe(identifier: identifier))
#else
        self
#endif
    }
}

#if DEBUG && os(macOS)
private struct ReaderPanelLayoutProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> NSView {
        let view = ReaderPanelLayoutProbeView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityIdentifier(identifier)
    }
}

private final class ReaderPanelLayoutProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
#endif

struct AutomatedReplyAdvisory: View {
    var body: some View {
        Label(
            "This automated sender may not monitor replies.",
            systemImage: "bell.badge"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(MailDesign.secondaryText)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .mailPanel(cornerRadius: 12)
        .accessibilityLabel(Text("This automated sender may not monitor replies."))
    }
}

struct ReplyUnavailableNotice: View {
    var body: some View {
        Label(
            "Reply is unavailable because this message has no usable reply address.",
            systemImage: "bell.badge"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(MailDesign.secondaryText)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .mailPanel(cornerRadius: 12)
        .accessibilityLabel(Text("Reply is unavailable because this message has no usable reply address."))
    }
}
