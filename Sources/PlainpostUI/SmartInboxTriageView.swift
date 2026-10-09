import SwiftUI
import PlainpostCore

struct SmartInboxSignal: Equatable, Sendable {
    let systemImage: String
    let accessibilityLabel: String
    let visibleText: String? = nil
    let pointSize: CGFloat = 11
    let verticalPadding: CGFloat = 0
}

struct SmartInboxSignalSet: Equatable, Sendable {
    let items: [SmartInboxSignal]

    init(priority: SmartPriority, requiresAction: Bool) {
        var items: [SmartInboxSignal] = []
        if priority == .high {
            items.append(
                SmartInboxSignal(
                    systemImage: "exclamationmark.circle.fill",
                    accessibilityLabel: "High priority"
                )
            )
        }
        if requiresAction {
            items.append(
                SmartInboxSignal(
                    systemImage: "arrowshape.turn.up.left.circle.fill",
                    accessibilityLabel: "Needs action"
                )
            )
        }
        self.items = items
    }
}

struct SmartInboxBundleMetrics: Equatable {
    let minimumHeight: CGFloat
    let identityWidth: CGFloat?
    let usesStackedSummaryLayout: Bool

    static let wide = Self(
        minimumHeight: 54,
        identityWidth: MailboxListMetrics.wide.contractedIdentityRegionWidth,
        usesStackedSummaryLayout: false
    )
    static let narrow = Self(
        minimumHeight: 54,
        identityWidth: nil,
        usesStackedSummaryLayout: true
    )

    static func resolve(_ widthClass: MailboxListWidthClass) -> Self {
        widthClass == .wide ? .wide : .narrow
    }

    var summaryColumnOrigin: CGFloat {
        guard let identityWidth else { return 0 }
        return identityWidth + MailboxListMetrics.contentSpacing
    }
}

enum SmartInboxBundleAccessibility {
    static func label(for bundle: SmartInboxTodayBundle) -> String {
        bundle.title
    }

    static func value(for bundle: SmartInboxTodayBundle) -> String {
        return [
            bundle.hasUnread ? "Unread" : nil,
            "\(bundle.count) messages"
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

enum SmartInboxSenderFlowMetrics {
    static let summaryWidth: CGFloat = 132
    static let spacing: CGFloat = 14
    static let overflowIndicatorWidth: CGFloat = 12

    static func requiredWidth(
        summaryCount: Int,
        includesOverflowIndicator: Bool
    ) -> CGFloat {
        let normalizedCount = max(0, summaryCount)
        var width: CGFloat = normalizedCount == 0
            ? 0
            : CGFloat(normalizedCount) * summaryWidth
                + CGFloat(normalizedCount - 1) * spacing

        if includesOverflowIndicator {
            if normalizedCount > 0 {
                width += spacing
            }
            width += overflowIndicatorWidth
        }
        return width
    }
}

struct SmartInboxSenderFlowPresentation: Equatable {
    let visibleSummaries: [SmartInboxSenderSummary]
    let showsOverflowIndicator: Bool

    var accessibilityLabels: [String] {
        visibleSummaries.map { summary in
            [
                summary.displayName,
                summary.hasUnread ? "unread" : nil,
                "\(summary.messageCount) \(summary.messageCount == 1 ? "message" : "messages")"
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        }
    }

    static func make(
        summaries: [SmartInboxSenderSummary],
        availableWidth: CGFloat
    ) -> Self {
        guard !summaries.isEmpty else {
            return Self(visibleSummaries: [], showsOverflowIndicator: false)
        }

        if SmartInboxSenderFlowMetrics.requiredWidth(
            summaryCount: summaries.count,
            includesOverflowIndicator: false
        ) <= availableWidth {
            return Self(
                visibleSummaries: summaries,
                showsOverflowIndicator: false
            )
        }

        let widthForSummaries = max(
            0,
            availableWidth
                - SmartInboxSenderFlowMetrics.overflowIndicatorWidth
                - SmartInboxSenderFlowMetrics.spacing
        )
        let visibleCount: Int
        if widthForSummaries < SmartInboxSenderFlowMetrics.summaryWidth {
            visibleCount = 0
        } else {
            visibleCount = min(
                summaries.count - 1,
                Int(
                    (widthForSummaries + SmartInboxSenderFlowMetrics.spacing)
                        / (
                            SmartInboxSenderFlowMetrics.summaryWidth
                                + SmartInboxSenderFlowMetrics.spacing
                        )
                )
            )
        }

        return Self(
            visibleSummaries: Array(summaries.prefix(visibleCount)),
            showsOverflowIndicator: true
        )
    }
}

struct SmartInboxTriagePaginationPresentation: Equatable {
    let footer: InboxPaginationFooterPresentation

    func isVisible(activeBundle: SmartInboxDisplayBundle?) -> Bool {
        activeBundle == nil && footer.isVisible
    }
}

enum SmartInboxSignalLayoutPresentation {
    static let spacing: CGFloat = 2

    static func reservedWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount * 11) + CGFloat(itemCount - 1) * spacing
    }
}

struct SmartInboxTriageView: View {
    let rows: [MessageRowModel]
    let contentRevision: UInt64
    @Binding var selectedMessageID: String?
    let widthClass: MailboxListWidthClass
    let activeBundle: SmartInboxDisplayBundle?
    @ObservedObject var mailActions: InboxMailActionViewModel
    @ObservedObject var labelActions: MessageLabelActions
    let quickActionFocus: MailboxRowQuickActionFocusCoordinator
    let openLabelCommandCenter: (MessageRowModel) -> Void
    let performMessageAction: (InboxMailAction, String) -> Void
    let paginationPresentation: SmartInboxTriagePaginationPresentation
    let loadMore: () -> Void
    let openBundle: (SmartInboxDisplayBundle) -> Void
    let closeBundle: () -> Void
    let openMessage: (String, MailboxListContext) -> Void
    @Binding private var scrollPosition: ScrollPosition
    let reportScrollGeometry: (MailboxScrollGeometrySnapshot) -> Void
    let reportVisibleIDs: ([String]) -> Void
    let reportScrollPhase: (ScrollPhase) -> Void
    let settledAnchorMeasurementRequest:
        MailboxSettledAnchorMeasurementRequest?
    let reportSettledAnchorFrame: (
        MailboxSettledAnchorMeasurementRequest,
        CGRect
    ) -> Void
    let reportOrderedItems: (
        MailboxListContext,
        [MailboxScrollItem],
        [String]
    ) -> Void

    @Environment(\.plainpostNow) private var now
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @State private var modelCache = SmartInboxTriageModelSnapshotCache()

    init(
        rows: [MessageRowModel],
        contentRevision: UInt64 = 0,
        selectedMessageID: Binding<String?>,
        widthClass: MailboxListWidthClass,
        activeBundle: SmartInboxDisplayBundle?,
        mailActions: InboxMailActionViewModel,
        labelActions: MessageLabelActions = .preview(),
        quickActionFocus: MailboxRowQuickActionFocusCoordinator = .init(),
        openLabelCommandCenter: @escaping (MessageRowModel) -> Void = { _ in },
        performMessageAction: @escaping (InboxMailAction, String) -> Void,
        paginationPresentation: SmartInboxTriagePaginationPresentation,
        loadMore: @escaping () -> Void,
        openBundle: @escaping (SmartInboxDisplayBundle) -> Void,
        closeBundle: @escaping () -> Void,
        openMessage: @escaping (String, MailboxListContext) -> Void,
        scrollPosition: Binding<ScrollPosition> = .constant(
            ScrollPosition(idType: String.self)
        ),
        reportScrollGeometry: @escaping (MailboxScrollGeometrySnapshot) -> Void = { _ in },
        reportVisibleIDs: @escaping ([String]) -> Void = { _ in },
        reportScrollPhase: @escaping (ScrollPhase) -> Void = { _ in },
        settledAnchorMeasurementRequest:
            MailboxSettledAnchorMeasurementRequest? = nil,
        reportSettledAnchorFrame: @escaping (
            MailboxSettledAnchorMeasurementRequest,
            CGRect
        ) -> Void = { _, _ in },
        reportOrderedItems: @escaping (
            MailboxListContext,
            [MailboxScrollItem],
            [String]
        ) -> Void = { _, _, _ in }
    ) {
        self.rows = rows
        self.contentRevision = contentRevision
        self._selectedMessageID = selectedMessageID
        self.widthClass = widthClass
        self.activeBundle = activeBundle
        self.mailActions = mailActions
        self.labelActions = labelActions
        self.quickActionFocus = quickActionFocus
        self.openLabelCommandCenter = openLabelCommandCenter
        self.performMessageAction = performMessageAction
        self.paginationPresentation = paginationPresentation
        self.loadMore = loadMore
        self.openBundle = openBundle
        self.closeBundle = closeBundle
        self.openMessage = openMessage
        self._scrollPosition = scrollPosition
        self.reportScrollGeometry = reportScrollGeometry
        self.reportVisibleIDs = reportVisibleIDs
        self.reportScrollPhase = reportScrollPhase
        self.settledAnchorMeasurementRequest =
            settledAnchorMeasurementRequest
        self.reportSettledAnchorFrame = reportSettledAnchorFrame
        self.reportOrderedItems = reportOrderedItems
    }

    private var model: SmartInboxTriageModel {
        modelCache.model(
            rows: rows,
            contentRevision: contentRevision,
            now: now(),
            calendar: calendar,
            locale: locale
        )
    }

    var body: some View {
        Group {
            if let activeBundle {
                drillInView(activeBundle)
            } else {
                rootView
            }
        }
        .mailboxCanvas()
        .onAppear(perform: publishOrderedIDs)
        .onChange(of: orderedScrollItems) { _, _ in
            publishOrderedIDs()
        }
    }

    private var rootView: some View {
        trackedList(
            List(selection: $selectedMessageID) {
                if hasTodayRows {
                    Section {
                        ForEach(model.todayPromotedRows) { row in
                            messageRow(row)
                        }

                        ForEach(model.todayBundles) { bundle in
                            SmartInboxBundleRow(
                                bundle: bundle,
                                widthClass: widthClass
                            ) {
                                selectBundle(bundle.id)
                            }
                            .id(MailboxScrollID.bundle(bundle.id))
                            .modifier(
                                SettledMailboxScrollAnchorMeasurement(
                                    id: MailboxScrollID.bundle(bundle.id),
                                    request:
                                        settledAnchorMeasurementRequest,
                                    reportFrame: reportSettledAnchorFrame
                                )
                            )
                            .listRowInsets(mailboxListRowInsets)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        SmartInboxDateHeader(title: "Today")
                    }
                }

                ForEach(model.historicalSections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            messageRow(row)
                        }
                    } header: {
                        SmartInboxDateHeader(title: section.title)
                    }
                }

                if !hasTodayRows && model.historicalSections.isEmpty {
                    EmptyState(
                        title: "Smart Inbox is empty",
                        detail: "Messages appear here after local AI classification."
                    )
                    .frame(minHeight: 280)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                if paginationPresentation.isVisible(activeBundle: activeBundle) {
                    SmartInboxTriagePaginationFooter(
                        presentation: paginationPresentation.footer,
                        loadMore: loadMore
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .modifier(SmartInboxListSectionSpacing())
            .scrollContentBackground(.hidden)
        )
    }

    private func drillInView(_ bundle: SmartInboxDisplayBundle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    dismissBundle()
                } label: {
                    Label("Today", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MailDesign.accentBlue)
                .help("Back to Today")
                .accessibilityLabel(Text("Back to Today"))

                Divider()
                    .frame(height: 16)

                Image(systemName: bundle.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MailDesign.secondaryText)

                Text(bundle.title)
                    .font(.system(size: 13, weight: .semibold))

                Text("\(model.drillInRows(for: bundle).count)")
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)

                Spacer(minLength: 0)
            }
            .foregroundStyle(MailDesign.primaryText)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MailDesign.stroke.opacity(0.55)).frame(height: 1)
            }

            trackedList(
                List(selection: $selectedMessageID) {
                    Section {
                        ForEach(model.drillInRows(for: bundle)) { row in
                            messageRow(row)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            )
        }
    }

    private var hasTodayRows: Bool {
        !model.todayPromotedRows.isEmpty || !model.todayBundles.isEmpty
    }

    private func messageRow(_ row: MessageRowModel) -> some View {
        let scrollID = MailboxScrollID.message(row.id)
        return SmartInboxTriageRow(
            row: row,
            selectedMessageID: $selectedMessageID,
            widthClass: widthClass,
            mailActions: mailActions,
            labelActions: labelActions,
            quickActionFocus: quickActionFocus,
            performMessageAction: performMessageAction,
            openLabelCommandCenter: openLabelCommandCenter,
            openMessage: selectMessage
        )
        .tag(row.id)
        .id(scrollID)
        .modifier(
            SettledMailboxScrollAnchorMeasurement(
                id: scrollID,
                request: settledAnchorMeasurementRequest,
                reportFrame: reportSettledAnchorFrame
            )
        )
        .listRowInsets(mailboxListRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    func selectBundle(_ bundle: SmartInboxDisplayBundle) {
        openBundle(bundle)
    }

    func dismissBundle() {
        closeBundle()
    }

    func selectMessage(_ messageID: String) {
        selectedMessageID = messageID
        let context = activeBundle.map {
            MailboxListContext.smartInboxBundle($0)
        } ?? .smartInboxOverview
        openMessage(messageID, context)
    }

    private var activeContext: MailboxListContext {
        activeBundle.map(MailboxListContext.smartInboxBundle)
            ?? .smartInboxOverview
    }

    private var orderedMessageIDs: [String] {
        if let activeBundle {
            return model.drillInRows(for: activeBundle).map(\.id)
        }
        return model.todayPromotedRows.map(\.id)
            + model.historicalSections.flatMap { $0.rows.map(\.id) }
    }

    private var orderedScrollItems: [MailboxScrollItem] {
        if let activeBundle {
            return MailboxScrollItemFactory.smartInboxBundle(
                activeBundle,
                messageIDs: model.drillInRows(for: activeBundle).map(\.id)
            )
        }
        return MailboxScrollItemFactory.smartInboxOverview(
            promotedMessageIDs: model.todayPromotedRows.map(\.id),
            bundleIDs: model.todayBundles.map(\.id),
            historicalSections: model.historicalSections.map {
                (id: $0.id, messageIDs: $0.rows.map(\.id))
            }
        )
    }

    private func publishOrderedIDs() {
        reportOrderedItems(activeContext, orderedScrollItems, orderedMessageIDs)
    }

    private var mailboxListRowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
    }

    private func trackedList<Content: View>(
        _ content: Content
    ) -> some View {
        content
            .scrollTargetLayout()
            .scrollPosition($scrollPosition)
            .coordinateSpace(.named("plainpost-mailbox-list-viewport"))
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: 0.01
            ) { visibleIDs in
                reportVisibleIDs(visibleIDs)
            }
            .onScrollGeometryChange(
                for: MailboxScrollGeometrySnapshot.self
            ) { geometry in
                MailboxScrollGeometrySnapshot(
                    contentOffsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    topContentInset: geometry.contentInsets.top
                )
            } action: { _, newGeometry in
                reportScrollGeometry(newGeometry)
            }
            .onScrollPhaseChange { _, newPhase in
                reportScrollPhase(newPhase)
            }
    }
}

private struct SmartInboxListSectionSpacing: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listSectionSpacing(0)
            .contentMargins(.top, 0, for: .scrollContent)
        #else
        content
        #endif
    }
}

struct SmartInboxTriageRow: View {
    let row: MessageRowModel
    @Binding var selectedMessageID: String?
    let widthClass: MailboxListWidthClass
    @ObservedObject var mailActions: InboxMailActionViewModel
    @ObservedObject var labelActions: MessageLabelActions
    @ObservedObject var quickActionFocus: MailboxRowQuickActionFocusCoordinator
    let performMessageAction: (InboxMailAction, String) -> Void
    let openLabelCommandCenter: (MessageRowModel) -> Void
    let openMessage: ((String) -> Void)?

    init(
        row: MessageRowModel,
        selectedMessageID: Binding<String?>,
        widthClass: MailboxListWidthClass = .narrow,
        mailActions: InboxMailActionViewModel,
        labelActions: MessageLabelActions = .preview(),
        quickActionFocus: MailboxRowQuickActionFocusCoordinator = .init(),
        performMessageAction: @escaping (InboxMailAction, String) -> Void,
        openLabelCommandCenter: @escaping (MessageRowModel) -> Void = { _ in },
        openMessage: ((String) -> Void)? = nil
    ) {
        self.row = row
        self._selectedMessageID = selectedMessageID
        self.widthClass = widthClass
        self.mailActions = mailActions
        self.labelActions = labelActions
        self.quickActionFocus = quickActionFocus
        self.performMessageAction = performMessageAction
        self.openLabelCommandCenter = openLabelCommandCenter
        self.openMessage = openMessage
    }

    var controlPresentation: MailboxRowControlPresentation {
        .siblingActivationAndQuickActions
    }

    var body: some View {
        MailMessageListRow(
            row: row,
            selected: row.id == selectedMessageID,
            widthClass: widthClass,
            mailActions: mailActions,
            labelActions: labelActions,
            quickActionFocus: quickActionFocus,
            openMessage: { _ in select() },
            openLabelCommandCenter: openLabelCommandCenter,
            performMessageAction: { action, _ in perform(action) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func select() {
        selectedMessageID = row.id
        openMessage?(row.id)
    }

    func perform(_ action: InboxMailAction) {
        performMessageAction(action, row.id)
    }

    func openLabels() {
        openLabelCommandCenter(row)
    }
}

private struct SmartInboxTriagePaginationFooter: View {
    let presentation: InboxPaginationFooterPresentation
    let loadMore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(presentation.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear(perform: loadMore)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(presentation.label))
    }
}

private struct SmartInboxDateHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MailDesign.secondaryText)
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }
}

private struct SmartInboxSenderFlow: View {
    let summaries: [SmartInboxSenderSummary]

    var body: some View {
        GeometryReader { geometry in
            let presentation = SmartInboxSenderFlowPresentation.make(
                summaries: summaries,
                availableWidth: geometry.size.width
            )

            HStack(spacing: SmartInboxSenderFlowMetrics.spacing) {
                ForEach(
                    Array(presentation.visibleSummaries.enumerated()),
                    id: \.element.id
                ) { index, summary in
                    senderSummary(
                        summary,
                        accessibilityLabel: presentation.accessibilityLabels[index]
                    )
                }
                if presentation.showsOverflowIndicator {
                    Text("…")
                        .foregroundStyle(.tertiary)
                        .frame(
                            width: SmartInboxSenderFlowMetrics.overflowIndicatorWidth,
                            alignment: .leading
                        )
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 22)
        .font(.system(size: 12))
    }

    private func senderSummary(
        _ summary: SmartInboxSenderSummary,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: 5) {
            if summary.hasUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
            MailSenderAvatar(
                sender: summary.sender,
                displayName: summary.displayName,
                size: 22
            )
            .accessibilityHidden(true)
            Text(summary.displayName)
                .lineLimit(1)
            Text("\(summary.messageCount)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(
            width: SmartInboxSenderFlowMetrics.summaryWidth,
            alignment: .leading
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

private struct SmartInboxBundleRow: View {
    let bundle: SmartInboxTodayBundle
    let widthClass: MailboxListWidthClass
    let onSelect: () -> Void

    private var metrics: SmartInboxBundleMetrics {
        SmartInboxBundleMetrics.resolve(widthClass)
    }

    var body: some View {
        Button(action: onSelect) {
            Group {
                if metrics.usesStackedSummaryLayout {
                    narrowContent
                } else {
                    wideContent
                }
            }
            .foregroundStyle(MailDesign.primaryText)
            .padding(.horizontal, MailboxListMetrics.horizontalPadding)
            .contentShape(RoundedRectangle(cornerRadius: MailDesign.Radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(SmartInboxBundleAccessibility.label(for: bundle)))
        .accessibilityValue(Text(SmartInboxBundleAccessibility.value(for: bundle)))
    }

    private var wideContent: some View {
        HStack(spacing: MailboxListMetrics.contentSpacing) {
            HStack(spacing: MailboxListMetrics.contentSpacing) {
                unreadDot
                bundleIcon
                bundleTitleAndCount
                Spacer(minLength: 0)
            }
            .frame(width: metrics.identityWidth, alignment: .leading)

            SmartInboxSenderFlow(summaries: bundle.senderSummaries)
                .frame(maxWidth: .infinity, alignment: .leading)

            disclosureIndicator
        }
        .frame(minHeight: metrics.minimumHeight)
    }

    private var narrowContent: some View {
        HStack(spacing: MailboxListMetrics.contentSpacing) {
            unreadDot
            bundleIcon

            VStack(alignment: .leading, spacing: 5) {
                bundleTitleAndCount
                SmartInboxSenderFlow(summaries: bundle.senderSummaries)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            disclosureIndicator
        }
        .frame(minHeight: metrics.minimumHeight)
    }

    private var unreadDot: some View {
        Circle()
            .fill(bundle.hasUnread ? Color.accentColor : .clear)
            .frame(
                width: MailboxListMetrics.unreadDotWidth,
                height: MailboxListMetrics.unreadDotWidth
            )
            .accessibilityHidden(true)
    }

    private var bundleIcon: some View {
        Image(systemName: bundle.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(bundleTint, in: Circle())
            .accessibilityHidden(true)
    }

    private var bundleTitleAndCount: some View {
        HStack(spacing: 6) {
            Text(bundle.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(bundle.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private var disclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private var bundleTint: Color {
        switch bundle.id {
        case .people:
            .blue
        case .notifications:
            .purple
        case .newsletters:
            .teal
        case .invitations:
            .orange
        case .invitationResponses:
            .green
        case .updates:
            .indigo
        }
    }
}

struct SmartInboxSignalIcons: View {
    let signals: SmartInboxSignalSet
    let selected: Bool

    var body: some View {
        HStack(spacing: SmartInboxSignalLayoutPresentation.spacing) {
            ForEach(Array(signals.items.enumerated()), id: \.offset) { _, signal in
                Image(systemName: signal.systemImage)
                    .font(.system(size: signal.pointSize, weight: .semibold))
                    .foregroundStyle(signalColor(signal))
                    .frame(width: signal.pointSize, height: signal.pointSize)
                    .padding(.vertical, signal.verticalPadding)
                    .help(signal.accessibilityLabel)
                    .accessibilityLabel(Text(signal.accessibilityLabel))
            }
        }
        .frame(
            width: SmartInboxSignalLayoutPresentation.reservedWidth(itemCount: signals.items.count),
            height: 11
        )
        .fixedSize()
    }

    private func signalColor(_ signal: SmartInboxSignal) -> Color {
        let foreground = MailboxRowForegroundPresentation.resolve(
            selected: selected
        )
        guard foreground.preservesSemanticSignalColors else {
            return .white.opacity(0.78)
        }
        return signal.accessibilityLabel == "High priority"
            ? Color.orange.opacity(0.82)
            : MailDesign.accentTeal.opacity(0.88)
    }
}
