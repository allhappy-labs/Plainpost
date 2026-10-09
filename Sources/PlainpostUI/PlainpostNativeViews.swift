import SwiftUI
import PlainpostCore
#if os(macOS)
import AppKit
#endif

public struct PlainpostSidebar: View {
    @Binding var selection: PlainpostDestination
    let viewModel: InboxViewModel
    let smartInboxActivity: SmartInboxActivityPresentation?
    let smartInboxActivityActionInFlight: Bool
    let smartInboxActivityActionMessage: String?
    let pauseSmartInbox: (String) -> Void
    let resumeSmartInbox: (String) -> Void
    /// The Calendar destination appears only for a Node whose calendar
    /// capability is enabled.
    var showsCalendar = false
    var smartInboxEnabled = true
    /// Each account's folders, listed after the shared sections when there is more than one
    /// account; choosing a folder shows only that account's mail there.
    var accountSections: [MailboxAccountSection] = []
    /// The account folder the mail list is narrowed to, if any.
    var selectedFolder: MailFolderRef?
    var openFolder: (MailFolderRef) -> Void = { _ in }

    private let favoriteDestinations: [PlainpostDestination] = [
        .smartInbox
    ]
    private let accountDestinations: [PlainpostDestination] = [
        .personal, .notifications, .newsletters
    ]
    private let libraryDestinations: [PlainpostDestination] = [
        .drafts, .sent, .archive, .trash, .labels
    ]
    private let agentDestinations: [PlainpostDestination] = [
        .approvalQueue, .aiIndexStatus
    ]

    public init(selection: Binding<PlainpostDestination>, viewModel: InboxViewModel) {
        self.init(
            selection: selection,
            viewModel: viewModel,
            smartInboxActivity: nil,
            smartInboxActivityActionInFlight: false,
            smartInboxActivityActionMessage: nil,
            pauseSmartInbox: { _ in },
            resumeSmartInbox: { _ in }
        )
    }

    @_spi(DesignPreview)
    public init(
        selection: Binding<PlainpostDestination>,
        viewModel: InboxViewModel,
        designSmartInboxActivity: SmartInboxActivityPresentation?
    ) {
        self.init(
            selection: selection,
            viewModel: viewModel,
            smartInboxActivity: designSmartInboxActivity,
            smartInboxActivityActionInFlight: false,
            smartInboxActivityActionMessage: nil,
            pauseSmartInbox: { _ in },
            resumeSmartInbox: { _ in }
        )
    }

    /// Design preview: the sidebar with each account's standard folders and the given unread
    /// counts (by account, then folder path).
    @_spi(DesignPreview)
    public init(
        selection: Binding<PlainpostDestination>,
        viewModel: InboxViewModel,
        designAccounts: [Account],
        designUnread: [AccountID: [String: Int]] = [:]
    ) {
        let mailboxes: [Mailbox] = designAccounts.flatMap { account -> [Mailbox] in
            [("INBOX", "\\Inbox"), ("Drafts", "\\Drafts"), ("Sent", "\\Sent"), ("Archive", "\\Archive"), ("Trash", "\\Trash")]
                .map { path, specialUse in
                    Mailbox(id: MailboxID("\(account.id.rawValue)-\(path)"), accountID: account.id,
                            name: path, path: path, specialUse: specialUse)
                }
        }
        self.init(
            selection: selection,
            viewModel: viewModel,
            smartInboxActivity: nil,
            smartInboxActivityActionInFlight: false,
            smartInboxActivityActionMessage: nil,
            pauseSmartInbox: { _ in },
            resumeSmartInbox: { _ in },
            accountSections: MailboxDirectoryModel.sections(
                accounts: designAccounts, mailboxes: mailboxes, unreadCounts: designUnread
            )
        )
    }

    init(
        selection: Binding<PlainpostDestination>,
        viewModel: InboxViewModel,
        smartInboxActivity: SmartInboxActivityPresentation?,
        smartInboxActivityActionInFlight: Bool,
        smartInboxActivityActionMessage: String?,
        pauseSmartInbox: @escaping (String) -> Void,
        resumeSmartInbox: @escaping (String) -> Void,
        showsCalendar: Bool = false,
        smartInboxEnabled: Bool = true,
        accountSections: [MailboxAccountSection] = [],
        selectedFolder: MailFolderRef? = nil,
        openFolder: @escaping (MailFolderRef) -> Void = { _ in }
    ) {
        self.accountSections = accountSections
        self.selectedFolder = selectedFolder
        self.openFolder = openFolder
        self.showsCalendar = showsCalendar
        self.smartInboxEnabled = smartInboxEnabled
        self._selection = selection
        self.viewModel = viewModel
        self.smartInboxActivity = smartInboxActivity
        self.smartInboxActivityActionInFlight = smartInboxActivityActionInFlight
        self.smartInboxActivityActionMessage = smartInboxActivityActionMessage
        self.pauseSmartInbox = pauseSmartInbox
        self.resumeSmartInbox = resumeSmartInbox
    }

    public var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<PlainpostSidebarItem?>(
                get: { PlainpostSidebarItem.current(destination: selection, folder: selectedFolder) },
                set: { item in
                    item?.apply(selectDestination: { selection = $0 }, openFolder: openFolder)
                }
            )) {
                Section("Favorites") {
                    if smartInboxEnabled {
                        ForEach(favoriteDestinations) { destination in
                            sidebarRow(destination)
                        }
                    }
                    sidebarRow(.allInboxes)
                    #if os(macOS)
                    if showsCalendar {
                        sidebarRow(.calendar)
                    }
                    #endif
                }

                Section("Smart Mailboxes") {
                    ForEach(accountDestinations) { destination in
                        sidebarRow(destination)
                    }
                }

                Section("Library") {
                    ForEach(libraryDestinations) { destination in
                        sidebarRow(destination)
                    }
                }

                Section("Agent") {
                    ForEach(agentDestinations) { destination in
                        sidebarRow(destination)
                    }
                }

                ForEach(Self.listedAccountSections(accountSections)) { section in
                    Section {
                        ForEach(section.folders) { folder in
                            folderRow(folder)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                            if let status = section.status.message {
                                Label(status, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("mailbox.sidebar.account-status.\(section.id.rawValue)")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mailbox.sidebar.account.\(section.id.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
#if os(macOS)
            // Keep the native sidebar material uniform beneath the titlebar.
            // macOS otherwise adds a top scroll-edge treatment to this List.
            .scrollEdgeEffectHidden(true, for: .top)
#endif

            if smartInboxEnabled, let smartInboxActivity {
                SmartInboxActivitySection(
                    presentation: smartInboxActivity,
                    isActionInFlight: smartInboxActivityActionInFlight,
                    actionMessage: smartInboxActivityActionMessage,
                    pause: pauseSmartInbox,
                    resume: resumeSmartInbox
                )
                Divider()
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mail stays on this device")
                        .font(.caption.weight(.medium))
                    Text(footerDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
#if os(macOS)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .labelStyle(.iconOnly)
                .mailGlassButtonStyle()
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
#endif
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
        .navigationTitle("Plainpost")
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 300)
    }

    @ViewBuilder
    private func sidebarRow(_ destination: PlainpostDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .symbolRenderingMode(.hierarchical)
            .badge(badge(for: destination) ?? 0)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mailbox.sidebar.\(destination.rawValue)")
            // List selection traits must be attached to the final row view.
            // Wrapping a tagged Label in a conditional badge branch causes
            // SwiftUI to lose the tag, leaving every sidebar row inert.
            .tag(PlainpostSidebarItem.destination(destination))
    }

    /// The account sections the sidebar lists: one per account, but none for a single account,
    /// whose mail All Inboxes already is.
    static func listedAccountSections(_ sections: [MailboxAccountSection]) -> [MailboxAccountSection] {
        sections.count > 1 ? sections : []
    }

    /// Under "Mail stays on this device": how many accounts, or the one account's address.
    private var footerDetail: String {
        if accountSections.count > 1 { return "\(accountSections.count) accounts" }
        return viewModel.accountIdentity?.email ?? "Private by default"
    }

    private func folderRow(_ folder: MailboxFolder) -> some View {
        let ref = MailFolderRef(accountID: folder.accountID, path: folder.path, name: folder.name, role: folder.role)
        return Label(folder.name, systemImage: MailboxFolder.systemImage(for: folder.role))
            .symbolRenderingMode(.hierarchical)
            .badge(folder.unread)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mailbox.sidebar.folder.\(folder.id)")
            // The tag stays the row's last modifier, as for the destination rows.
            .tag(PlainpostSidebarItem.folder(ref))
    }

    private func badge(for destination: PlainpostDestination) -> Int? {
        viewModel.sidebarItems.first { $0.title == destination.title }?.badge
    }

}

struct InboxPaginationFooterPresentation: Equatable {
    let isVisible: Bool
    let label: String

    static func make(
        hasMoreRows: Bool,
        isLoadingMore: Bool,
        isMailboxSyncDisabled: Bool = false
    ) -> Self {
        Self(isVisible: hasMoreRows && !isMailboxSyncDisabled, label: "Loading more messages")
    }
}

struct DisabledMailboxSyncPresentation: Equatable {
    let title: String
    let detail: String
    let actionTitle: String
    let isEnabling: Bool

    static func make(
        destination: PlainpostDestination,
        isDisabled: Bool,
        isEnabling: Bool
    ) -> Self? {
        guard isDisabled, destination == .sent || destination == .archive else {
            return nil
        }
        return Self(
            title: "\(destination.title) sync is turned off",
            detail: "Enable sync to download messages from \(destination.title).",
            actionTitle: "Enable \(destination.title) sync",
            isEnabling: isEnabling
        )
    }
}

enum MailboxSettledAnchorMeasurementCapture: Equatable {
    case accepted(MailboxScrollLocation?)
    case rejected(MailboxSettledAnchorMeasurementRequest?)
}

@MainActor
func captureSettledMailboxScrollLocation(
    runtime: MailboxScrollRuntime,
    request: MailboxSettledAnchorMeasurementRequest,
    contextToken: MailboxScrollContextToken,
    anchorViewportOffset: Double,
    selectedMessageID: String?
) -> MailboxSettledAnchorMeasurementCapture {
    guard runtime.acceptSettledAnchorMeasurement(
        request,
        using: contextToken,
        anchorViewportOffset: anchorViewportOffset
    ) else {
        return .rejected(
            runtime.authoritativeSettledAnchorMeasurementRequest()
        )
    }
    return .accepted(
        runtime.capture(
            reason: .scrollSettled,
            selectedMessageID: selectedMessageID
        )
    )
}

@MainActor
enum MailboxScrollCorrectionBoundary: Equatable {
    case continuousGeometry
    case scrollSettled
}

struct MailboxScrollSurfaceRestorationInput: Equatable {
    let context: MailboxListContext
    let orderedItems: [MailboxScrollItem]
    let orderedMessageIDs: [String]
}

struct MailboxScrollGeometrySnapshot: Equatable {
    let contentOffsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let topContentInset: CGFloat

    var isReadyForRestoration: Bool {
        contentHeight > 0 && containerHeight > 0
    }
}

#if os(macOS)
@MainActor
final class MailboxNativeScrollViewRuntime {
    private weak var scrollView: NSScrollView?
    private var installedToken: MailboxScrollContextToken?
    private var pendingRestoration: (
        token: MailboxScrollContextToken,
        contentOffsetY: CGFloat
    )?

    var hasPendingRestoration: Bool {
        pendingRestoration != nil
    }

    func install(
        _ scrollView: NSScrollView,
        using token: MailboxScrollContextToken
    ) {
        self.scrollView = scrollView
        installedToken = token
        applyPendingRestoration()
    }

    func restore(
        to contentOffsetY: CGFloat,
        using token: MailboxScrollContextToken
    ) {
        pendingRestoration = (token, max(0, contentOffsetY))
        applyPendingRestoration()
    }

    private func applyPendingRestoration() {
        guard let scrollView,
              let documentView = scrollView.documentView,
              let pendingRestoration,
              installedToken == pendingRestoration.token,
              scrollView.contentView.bounds.height > 0,
              documentView.bounds.height > 0
        else {
            return
        }
        let maximumY = max(
            0,
            documentView.bounds.height - scrollView.contentView.bounds.height
        )
        var origin = scrollView.contentView.bounds.origin
        origin.y = min(pendingRestoration.contentOffsetY, maximumY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.pendingRestoration = nil
    }
}

private struct MailboxNativeScrollViewReader: NSViewRepresentable {
    let install: @MainActor (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveScrollView(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveScrollView(from: nsView)
    }

    private func resolveScrollView(from view: NSView) {
        DispatchQueue.main.async {
            var ancestor: NSView? = view
            while let current = ancestor {
                if let scrollView = Self.descendantScrollView(in: current) {
                    install(scrollView)
                    return
                }
                ancestor = current.superview
            }
        }
    }

    private static func descendantScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = descendantScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}
#endif

@MainActor
final class MailboxScrollRestorationRuntime {
    private var pendingViewportOffsetAdjustment: Double?
    private var pendingInitialRestoration: (
        token: MailboxScrollContextToken,
        input: MailboxScrollSurfaceRestorationInput
    )?

    var hasPendingViewportOffsetAdjustment: Bool {
        pendingViewportOffsetAdjustment != nil
    }

    func scheduleViewportOffsetAdjustment(_ value: Double) {
        pendingViewportOffsetAdjustment = value
    }

    func clearViewportOffsetAdjustment() {
        pendingViewportOffsetAdjustment = nil
    }

    func deferInitialRestoration(
        _ input: MailboxScrollSurfaceRestorationInput,
        until token: MailboxScrollContextToken
    ) {
        pendingInitialRestoration = (token, input)
    }

    func consumeInitialRestoration(
        using token: MailboxScrollContextToken?,
        geometry: MailboxScrollGeometrySnapshot
    ) -> MailboxScrollSurfaceRestorationInput? {
        guard let token,
              let pendingInitialRestoration,
              pendingInitialRestoration.token == token,
              geometry.isReadyForRestoration
        else {
            return nil
        }
        self.pendingInitialRestoration = nil
        return pendingInitialRestoration.input
    }

    func correctionTargetY(
        currentContentOffsetY: Double,
        boundary: MailboxScrollCorrectionBoundary
    ) -> Double? {
        guard boundary == .scrollSettled,
              let adjustment = pendingViewportOffsetAdjustment
        else {
            return nil
        }
        pendingViewportOffsetAdjustment = nil
        return currentContentOffsetY - adjustment
    }
}

struct MailboxSettledAnchorFrame: Equatable {
    let request: MailboxSettledAnchorMeasurementRequest
    let frame: CGRect
}

struct SettledMailboxScrollAnchorMeasurement: ViewModifier {
    let id: String
    let request: MailboxSettledAnchorMeasurementRequest?
    let reportFrame: (
        MailboxSettledAnchorMeasurementRequest,
        CGRect
    ) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let request, id == request.anchorID {
            content
                .id(id)
                .onGeometryChange(
                    for: MailboxSettledAnchorFrame.self
                ) { geometry in
                    MailboxSettledAnchorFrame(
                        request: request,
                        frame: geometry.frame(
                            in: .named("plainpost-mailbox-list-viewport")
                        )
                    )
                } action: { measurement in
                    reportFrame(
                        measurement.request,
                        measurement.frame
                    )
                }
        } else {
            content.id(id)
        }
    }
}

#if os(iOS)
private struct MailboxListHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(MailDesign.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("mailbox.list.header")
    }
}
#endif

struct MailMessageListColumn: View {
    @State private var widthClass: MailboxListWidthClass = .wide
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var scrollRuntime: MailboxScrollRuntime
    @State private var restorationRuntime = MailboxScrollRestorationRuntime()
#if os(macOS)
    @State private var nativeScrollViewRuntime = MailboxNativeScrollViewRuntime()
#endif
    @State private var settledAnchorMeasurementRequest:
        MailboxSettledAnchorMeasurementRequest?
    @State private var scrollContextToken: MailboxScrollContextToken?
    @State private var trackedListContext: MailboxListContext?

    enum ContentPresentation: Equatable {
        case triage
        case unreadCards
        case flatList
    }

    let viewModel: InboxViewModel
    let destination: PlainpostDestination
    @Binding var selectedInboxMode: String
    let searchQuery: String
    @Binding var selectedMessageID: String?
    @ObservedObject var mailActions: InboxMailActionViewModel
    let labelActions: MessageLabelActions
    let quickActionFocus: MailboxRowQuickActionFocusCoordinator
    let openLabelCommandCenter: (MessageRowModel) -> Void
    let performMessageAction: (InboxMailAction, String) -> Void
    let isLoadingMore: Bool
    let loadMore: () -> Void
    let disabledMailboxSync: DisabledMailboxSyncPresentation?
    let enableMailboxSync: () -> Void
    let activeContext: MailboxListContext
    let activeSmartInboxBundle: SmartInboxDisplayBundle?
    let openMessage: (String, MailboxListContext) -> Void
    let openBundle: (SmartInboxDisplayBundle) -> Void
    let closeBundle: () -> Void
    let reportOrderedScrollItems: ([MailboxScrollItem]) -> Void
    let reportScrollLocation: (MailboxListContext, MailboxScrollLocation) -> Void
    let resolveRestoration: (
        MailboxListContext,
        [MailboxScrollItem],
        [String],
        Bool
    ) -> MailboxScrollRestoration?

    init(
        viewModel: InboxViewModel,
        destination: PlainpostDestination,
        selectedInboxMode: Binding<String>,
        searchQuery: String,
        selectedMessageID: Binding<String?>,
        mailActions: InboxMailActionViewModel,
        labelActions: MessageLabelActions = .preview(),
        quickActionFocus: MailboxRowQuickActionFocusCoordinator = .init(),
        openLabelCommandCenter: @escaping (MessageRowModel) -> Void = { _ in },
        performMessageAction: @escaping (InboxMailAction, String) -> Void,
        isLoadingMore: Bool,
        loadMore: @escaping () -> Void,
        disabledMailboxSync: DisabledMailboxSyncPresentation?,
        enableMailboxSync: @escaping () -> Void,
        activeContext: MailboxListContext = .smartInboxOverview,
        activeSmartInboxBundle: SmartInboxDisplayBundle? = nil,
        openMessage: @escaping (String, MailboxListContext) -> Void = { _, _ in },
        openBundle: @escaping (SmartInboxDisplayBundle) -> Void = { _ in },
        closeBundle: @escaping () -> Void = {},
        reportOrderedScrollItems: @escaping ([MailboxScrollItem]) -> Void = { _ in },
        reportScrollLocation: @escaping (
            MailboxListContext,
            MailboxScrollLocation
        ) -> Void = { _, _ in },
        resolveRestoration: @escaping (
            MailboxListContext,
            [MailboxScrollItem],
            [String],
            Bool
        ) -> MailboxScrollRestoration? = { _, _, _, _ in nil },
        scrollRuntime: MailboxScrollRuntime? = nil
    ) {
        self.viewModel = viewModel
        self.destination = destination
        self._selectedInboxMode = selectedInboxMode
        self.searchQuery = searchQuery
        self._selectedMessageID = selectedMessageID
        self.mailActions = mailActions
        self.labelActions = labelActions
        self.quickActionFocus = quickActionFocus
        self.openLabelCommandCenter = openLabelCommandCenter
        self.performMessageAction = performMessageAction
        self.isLoadingMore = isLoadingMore
        self.loadMore = loadMore
        self.disabledMailboxSync = disabledMailboxSync
        self.enableMailboxSync = enableMailboxSync
        self.activeContext = activeContext
        self.activeSmartInboxBundle = activeSmartInboxBundle
        self.openMessage = openMessage
        self.openBundle = openBundle
        self.closeBundle = closeBundle
        self.reportOrderedScrollItems = reportOrderedScrollItems
        self.reportScrollLocation = reportScrollLocation
        self.resolveRestoration = resolveRestoration
        self._scrollRuntime = State(
            initialValue: scrollRuntime ?? MailboxScrollRuntime()
        )
    }

    private var inboxMode: InboxDisplayMode {
        InboxDisplayMode(rawValue: selectedInboxMode) ?? .focusedList
    }

    private var rows: [MessageRowModel] {
        let availableRows = viewModel.rows(for: destination, matching: searchQuery)
        return inboxMode.visibleRows(from: availableRows, destination: destination)
    }

    var headerPresentation: MailboxHeaderPresentation {
        MailboxHeaderPresentation.make(
            title: destination.title,
            availableRows: viewModel.rows(
                for: destination,
                matching: searchQuery
            ),
            mode: inboxMode,
            destination: destination
        )
    }

    var contentPresentation: ContentPresentation {
        Self.presentation(
            destination: destination,
            mode: inboxMode,
            searchQuery: searchQuery
        )
    }

    var triagePaginationFooter: InboxPaginationFooterPresentation {
        InboxPaginationFooterPresentation.make(
            hasMoreRows: destination == .sent ? viewModel.hasMoreSentRows : viewModel.hasMoreRows,
            isLoadingMore: isLoadingMore,
            isMailboxSyncDisabled: disabledMailboxSync != nil
        )
    }

    static func presentation(
        destination: PlainpostDestination,
        mode: InboxDisplayMode,
        searchQuery: String
    ) -> ContentPresentation {
        guard destination.usesSmartGrouping else { return .flatList }
        if mode == .focusedList,
           searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .triage
        }
        return mode == .unreadCards ? .unreadCards : .flatList
    }

    static func rowActionSurface(
        for presentation: ContentPresentation
    ) -> MessageRowActionSurface {
        MailMessageListRow.actionSurface
    }

    var body: some View {
        VStack(spacing: 0) {
            if destination.showsThreadReader {
                #if os(iOS)
                MailboxListHeader(title: destination.title)
                #endif
                Group {
                    switch contentPresentation {
                    case .triage:
                        SmartInboxTriageView(
                            rows: viewModel.rows(for: .smartInbox),
                            contentRevision: viewModel.contentRevision,
                            selectedMessageID: $selectedMessageID,
                            widthClass: widthClass,
                            activeBundle: activeSmartInboxBundle,
                            mailActions: mailActions,
                            labelActions: labelActions,
                            quickActionFocus: quickActionFocus,
                            openLabelCommandCenter: openLabelCommandCenter,
                            performMessageAction: performMessageAction,
                            paginationPresentation: SmartInboxTriagePaginationPresentation(
                                footer: triagePaginationFooter
                            ),
                            loadMore: loadMore,
                            openBundle: { bundle in
                                persistScrollLocation(
                                    for: activeContext,
                                    reason: .navigationBoundary
                                )
                                openBundle(bundle)
                            },
                            closeBundle: {
                                persistScrollLocation(
                                    for: activeContext,
                                    reason: .navigationBoundary
                                )
                                closeBundle()
                            },
                            openMessage: { messageID, context in
                                selectedMessageID = messageID
                                persistScrollLocation(
                                    for: context,
                                    reason: .navigationBoundary
                                )
                                openMessage(messageID, context)
                            },
                            scrollPosition: $scrollPosition,
                            reportScrollGeometry: {
                                [callbackToken = scrollContextToken] geometry in
                                guard let callbackToken else { return }
                                handleScrollGeometry(
                                    geometry,
                                    using: callbackToken
                                )
                            },
                            reportVisibleIDs: {
                                [callbackToken = scrollContextToken] ids in
                                guard let callbackToken else { return }
                                handleVisibleIDs(
                                    ids,
                                    using: callbackToken
                                )
                            },
                            reportScrollPhase: {
                                [callbackToken = scrollContextToken] phase in
                                guard let callbackToken else { return }
                                handleScrollPhase(
                                    phase,
                                    using: callbackToken
                                )
                            },
                            settledAnchorMeasurementRequest:
                                settledAnchorMeasurementRequest,
                            reportSettledAnchorFrame: {
                                [callbackToken = scrollContextToken]
                                request,
                                frame in
                                guard let callbackToken else { return }
                                handleSettledAnchorFrame(
                                    request,
                                    frame,
                                    using: callbackToken
                                )
                            },
                            reportOrderedItems: handleOrderedItems
                        )
                        .id(scrollContextToken)
                        .background {
#if os(macOS)
                            if let scrollContextToken {
                                MailboxNativeScrollViewReader { scrollView in
                                    nativeScrollViewRuntime.install(
                                        scrollView,
                                        using: scrollContextToken
                                    )
                                }
                            }
#endif
                        }
                    case .unreadCards:
                        trackedScrollSurface(
                            List(selection: $selectedMessageID) {
                                ForEach(unreadCards) { card in
                                    Section {
                                        ForEach(card.messages) { row in
                                            nativeMessageRow(row)
                                        }
                                    } header: {
                                        Label(card.title, systemImage: card.systemImage)
                                    }
                                }
                                paginationFooter
                            }
                        )
                        .onAppear {
                            handleOrderedItems(
                                activeContext,
                                unreadCardScrollItems,
                                unreadCardRows.map(\.id)
                            )
                        }
                        .onChange(of: unreadCardRows.map(\.id)) { _, _ in
                            handleOrderedItems(
                                activeContext,
                                unreadCardScrollItems,
                                unreadCardRows.map(\.id)
                            )
                        }
                        .onChange(of: activeContext) { _, _ in
                            handleOrderedItems(
                                activeContext,
                                unreadCardScrollItems,
                                unreadCardRows.map(\.id)
                            )
                        }
                    case .flatList:
                        trackedScrollSurface(
                            List(selection: $selectedMessageID) {
                                #if os(iOS)
                                ForEach(rows) { row in
                                    nativeMessageRow(row)
                                }
                                #else
                                Section {
                                    ForEach(rows) { row in
                                        nativeMessageRow(row)
                                    }
                                } header: {
                                    Text(destination.title)
                                }
                                #endif
                                paginationFooter
                            }
                        )
                        .onAppear {
                            handleOrderedItems(
                                activeContext,
                                flatScrollItems,
                                rows.map(\.id)
                            )
                        }
                        .onChange(of: rows.map(\.id)) { _, _ in
                            handleOrderedItems(
                                activeContext,
                                flatScrollItems,
                                rows.map(\.id)
                            )
                        }
                        .onChange(of: activeContext) { _, _ in
                            handleOrderedItems(
                                activeContext,
                                flatScrollItems,
                                rows.map(\.id)
                            )
                        }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if let disabledMailboxSync {
                        ContentUnavailableView {
                            Label(disabledMailboxSync.title, systemImage: destination.systemImage)
                        } description: {
                            Text(disabledMailboxSync.detail)
                        } actions: {
                            Button(
                                disabledMailboxSync.isEnabling
                                    ? "Starting sync…"
                                    : disabledMailboxSync.actionTitle,
                                action: enableMailboxSync
                            )
                            .buttonStyle(.borderedProminent)
                            .disabled(disabledMailboxSync.isEnabling)
                        }
                        .mailboxEmptyStateFrame()
                    } else if rows.isEmpty && contentPresentation != .triage {
                        ContentUnavailableView(
                            searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "No messages"
                                : "No results",
                            systemImage: searchQuery.isEmpty ? "tray" : "magnifyingglass",
                            description: Text(
                                searchQuery.isEmpty
                                    ? "Messages appear here after your next inbox sync."
                                    : "Try another sender, subject, or phrase."
                            )
                        )
                        .mailboxEmptyStateFrame()
                    }
                }
                #if os(macOS)
                .scrollEdgeEffectStyle(.hard, for: .top)
                #endif
                #if os(macOS)
                .onMoveCommand(perform: moveKeyboardSelection)
                #endif
                .onKeyPress(.return) {
                    guard let selectedMessageID,
                          scrollRuntime.orderedMessageIDs.contains(selectedMessageID)
                    else {
                        return .ignored
                    }
                    persistScrollLocation(
                        for: activeContext,
                        reason: .navigationBoundary
                    )
                    openMessage(selectedMessageID, activeContext)
                    return .handled
                }
            } else {
                ContentUnavailableView {
                    Label(destination.utilityState.title, systemImage: destination.utilityState.symbol)
                } description: {
                    Text(destination.utilityState.detail)
                }
                .mailboxEmptyStateFrame()
            }
        }
        .mailboxCanvas()
        .onGeometryChange(for: MailboxListWidthClass.self) { geometry in
            MailboxListWidthClass.resolve(availableWidth: geometry.size.width)
        } action: { newClass in
            widthClass = newClass
        }
    }

    private var unreadCards: [SmartInboxCardModel] {
        SmartInboxCardModel.cards(from: rows).filter { !$0.messages.isEmpty }
    }

    private var unreadCardRows: [MessageRowModel] {
        unreadCards.flatMap(\.messages)
    }

    private var unreadCardScrollItems: [MailboxScrollItem] {
        MailboxScrollItemFactory.unreadCards(
            unreadCards.map {
                (sectionID: $0.id, messageIDs: $0.messages.map(\.id))
            }
        )
    }

    private var flatScrollItems: [MailboxScrollItem] {
        MailboxScrollItemFactory.flat(messageIDs: rows.map(\.id))
    }

    private func trackedScrollSurface<Content: View>(_ content: Content) -> some View {
        let callbackToken = scrollContextToken
        return content
            .scrollTargetLayout()
            .scrollPosition($scrollPosition)
            .coordinateSpace(.named("plainpost-mailbox-list-viewport"))
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: 0.01
            ) { visibleIDs in
                guard let callbackToken else { return }
                handleVisibleIDs(
                    visibleIDs,
                    using: callbackToken
                )
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
                guard let callbackToken else { return }
                handleScrollGeometry(
                    newGeometry,
                    using: callbackToken
                )
            }
            .onScrollPhaseChange { _, newPhase in
                guard let callbackToken else { return }
                handleScrollPhase(
                    newPhase,
                    using: callbackToken
                )
            }
            .id(callbackToken)
            .background {
#if os(macOS)
                if let callbackToken {
                    MailboxNativeScrollViewReader { scrollView in
                        nativeScrollViewRuntime.install(
                            scrollView,
                            using: callbackToken
                        )
                    }
                }
#endif
            }
            .mailboxListCanvas()
    }

    private func handleOrderedItems(
        _ context: MailboxListContext,
        _ orderedScrollItems: [MailboxScrollItem],
        _ orderedMessageIDs: [String]
    ) {
        let contextChanged = trackedListContext != context
        let installsNewSurface = contextChanged
            || scrollContextToken == nil
            || scrollRuntime.installedScrollContextToken
                != scrollContextToken
        let itemsUpdatePlan = scrollRuntime.orderedItemsUpdatePlan(
            to: orderedScrollItems
        )
        let isRefresh = !installsNewSurface
            && itemsUpdatePlan.requestsRestoration

        trackedListContext = context
        let contextToken: MailboxScrollContextToken
        if installsNewSurface {
            contextToken = scrollRuntime.installScrollContext(context)
            scrollContextToken = contextToken
            restorationRuntime.clearViewportOffsetAdjustment()
            settledAnchorMeasurementRequest = nil
        } else if itemsUpdatePlan.capturesCurrentLocation {
            contextToken = scrollContextToken!
            persistScrollLocation(
                for: context,
                reason: .navigationBoundary
            )
        } else {
            contextToken = scrollContextToken!
        }
        let deferredMeasurementRequest:
            MailboxSettledAnchorMeasurementRequest?
        if installsNewSurface {
            scrollRuntime.updateOrderedItems(orderedScrollItems)
            deferredMeasurementRequest = nil
        } else {
            deferredMeasurementRequest =
                scrollRuntime.applyOrderedItemsUpdate(
                    orderedScrollItems,
                    plan: itemsUpdatePlan,
                    using: contextToken
                )
        }
        reportOrderedScrollItems(orderedScrollItems)
        if let deferredMeasurementRequest {
            settledAnchorMeasurementRequest = deferredMeasurementRequest
        }

        if installsNewSurface {
            restorationRuntime.deferInitialRestoration(
                MailboxScrollSurfaceRestorationInput(
                    context: context,
                    orderedItems: orderedScrollItems,
                    orderedMessageIDs: orderedMessageIDs
                ),
                until: contextToken
            )
            return
        }
        guard itemsUpdatePlan.requestsRestoration else { return }
        guard let restoration = resolveRestoration(
            context,
            orderedScrollItems,
            orderedMessageIDs,
            isRefresh
        ) else {
            return
        }
        apply(restoration)
    }

    private func applyInitialRestorationIfReady(
        using contextToken: MailboxScrollContextToken?,
        geometry: MailboxScrollGeometrySnapshot
    ) -> Bool {
        guard let contextToken,
              let input = restorationRuntime.consumeInitialRestoration(
            using: contextToken,
            geometry: geometry
        ) else {
            return false
        }
        Task { @MainActor in
            await Task.yield()
            guard scrollContextToken == contextToken,
                  scrollRuntime.installedScrollContextToken == contextToken,
                  let restoration = resolveRestoration(
                    input.context,
                    input.orderedItems,
                    input.orderedMessageIDs,
                    false
                  )
            else {
                return
            }
            apply(restoration)
        }
        return true
    }

    private func apply(_ restoration: MailboxScrollRestoration) {
        switch restoration {
        case let .exact(contentOffsetY, selectedID):
            selectedMessageID = selectedID
            restorationRuntime.clearViewportOffsetAdjustment()
#if os(macOS)
            if let scrollContextToken {
                nativeScrollViewRuntime.restore(
                    to: CGFloat(contentOffsetY),
                    using: scrollContextToken
                )
            }
#else
            scrollPosition.scrollTo(y: CGFloat(contentOffsetY))
#endif
        case let .anchor(id, viewportOffset, selectedID):
            selectedMessageID = selectedID
            scrollPosition.scrollTo(id: id, anchor: .top)
            restorationRuntime.scheduleViewportOffsetAdjustment(
                viewportOffset
            )
        case let .top(selectedID):
            selectedMessageID = selectedID
            restorationRuntime.clearViewportOffsetAdjustment()
            scrollPosition.scrollTo(edge: .top)
        }
    }

    private func handleScrollGeometry(
        _ geometry: MailboxScrollGeometrySnapshot,
        using contextToken: MailboxScrollContextToken
    ) {
        if applyInitialRestorationIfReady(
            using: contextToken,
            geometry: geometry
        ) {
            return
        }
        _ = scrollRuntime.updateContentOffset(
            Double(geometry.contentOffsetY),
            using: contextToken
        )
    }

    private func handleVisibleIDs(
        _ ids: [String],
        using contextToken: MailboxScrollContextToken
    ) {
        guard let update = scrollRuntime.updateVisibleIDs(
            ids,
            using: contextToken
        ) else {
            return
        }
        guard update.topChanged,
              scrollRuntime.scrollActivity == .idle
        else {
            return
        }
        settledAnchorMeasurementRequest = update.measurementRequest
    }

    private func handleScrollPhase(
        _ phase: ScrollPhase,
        using contextToken: MailboxScrollContextToken
    ) {
        guard scrollRuntime.updateScrollActivity(
            phase == .idle ? .idle : .active,
            using: contextToken
        ) else {
            return
        }
        guard phase == .idle else {
            settledAnchorMeasurementRequest = nil
            return
        }
        if let correctionTargetY = restorationRuntime.correctionTargetY(
            currentContentOffsetY: scrollRuntime.contentOffsetY,
            boundary: .scrollSettled
        ) {
            scrollPosition.scrollTo(y: CGFloat(correctionTargetY))
        }
        settledAnchorMeasurementRequest =
            scrollRuntime.requestSettledAnchorMeasurement(
                using: contextToken
            )
    }

    private func handleSettledAnchorFrame(
        _ request: MailboxSettledAnchorMeasurementRequest,
        _ frame: CGRect,
        using contextToken: MailboxScrollContextToken
    ) {
        let result = captureSettledMailboxScrollLocation(
            runtime: scrollRuntime,
            request: request,
            contextToken: contextToken,
            anchorViewportOffset: Double(frame.minY),
            selectedMessageID: selectedMessageID
        )
        switch result {
        case let .accepted(location):
            settledAnchorMeasurementRequest = nil
            if let location {
                reportScrollLocation(activeContext, location)
            }
        case let .rejected(replacementRequest):
            settledAnchorMeasurementRequest = replacementRequest
        }
    }

    private func persistScrollLocation(
        for context: MailboxListContext,
        reason: MailboxScrollCaptureReason
    ) {
        guard let location = scrollRuntime.capture(
            reason: reason,
            selectedMessageID: selectedMessageID
        ) else {
            return
        }
        reportScrollLocation(context, location)
    }

    #if os(macOS)
    private func moveKeyboardSelection(_ direction: MoveCommandDirection) {
        let mapped: MailboxRowMoveDirection?
        switch direction {
        case .up:
            mapped = .up
        case .down:
            mapped = .down
        default:
            mapped = nil
        }
        guard let mapped else { return }
        selectedMessageID = MailboxRowKeyboardNavigation.nextID(
            current: selectedMessageID,
            direction: mapped,
            orderedIDs: scrollRuntime.orderedMessageIDs
        )
    }
    #endif

    private func nativeMessageRow(_ row: MessageRowModel) -> some View {
        let scrollID = MailboxScrollID.message(row.id)
        let callbackToken = scrollContextToken
        return MailMessageListRow(
            row: row,
            selected: row.id == selectedMessageID,
            widthClass: widthClass,
            mailActions: mailActions,
            labelActions: labelActions,
            quickActionFocus: quickActionFocus,
            openMessage: { messageID in
                selectedMessageID = messageID
                persistScrollLocation(
                    for: activeContext,
                    reason: .navigationBoundary
                )
                openMessage(messageID, activeContext)
            },
            openLabelCommandCenter: openLabelCommandCenter,
            performMessageAction: performMessageAction
        )
        .tag(row.id)
        .id(scrollID)
        .modifier(
            SettledMailboxScrollAnchorMeasurement(
                id: scrollID,
                request: settledAnchorMeasurementRequest,
                reportFrame: { request, frame in
                    guard let callbackToken else { return }
                    handleSettledAnchorFrame(
                        request,
                        frame,
                        using: callbackToken
                    )
                }
            )
        )
    }

    @ViewBuilder
    private var paginationFooter: some View {
        let footer = triagePaginationFooter
        if footer.isVisible {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(footer.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .onAppear(perform: loadMore)
        }
    }

}

enum MessageRowContextMenuAction: String, CaseIterable, Equatable, Identifiable, Sendable {
    case archive
    case readState
    case flag
    case move
    case labels
    case separator
    case delete

    var id: String { rawValue }
}

struct MessageRowActionSurface: Equatable, Sendable {
    let contextMenuActions: [MessageRowContextMenuAction]

    static let standard = MessageRowActionSurface(
        contextMenuActions: [.archive, .readState, .flag, .move, .labels, .separator, .delete]
    )
}

struct MessageRowPersistentAccessibilityPresentation: Equatable, Sendable {
    let label: String
    let value: String

    @MainActor
    static func resolve(
        row: MessageRowModel,
        senderIdentity: MailSenderIdentity,
        selected: Bool
    ) -> Self {
        Self(
            label: "\(senderIdentity.displayName), \(row.subject)",
            value: MessageListRow.accessibilityValue(for: row, selected: selected)
        )
    }
}

struct MailboxRowTrailingMetadataPresentation: Equatable, Sendable {
    let signals: SmartInboxSignalSet
    let isPinned: Bool
    var isFlagged = false
    let threadMessageCount: Int?
    let dateLabel: String
    let showsQuickActions: Bool
}

enum MailboxRowAccessibilityHierarchy: Equatable, Sendable {
    case containActionControls

    var childBehavior: AccessibilityChildBehavior {
        .contain
    }
}

enum MailboxRowControlPresentation: Equatable, Sendable {
    case siblingActivationAndQuickActions
    case siblingActivationReadStateAndQuickActions

    var supportsKeyboardActivation: Bool { true }
    var quickActionsAreKeyboardReachable: Bool { true }
    var preservesNativeContextMenu: Bool { true }
    var hasNestedButtons: Bool { false }
    var usesParentTapGesture: Bool { false }
    var accessibilityHint: String { "Open message" }
}

enum MailboxRowForegroundRole: Equatable, Sendable {
    case adaptivePrimary
    case adaptiveSecondary
    case accent
    case warning

    var color: Color {
        switch self {
        case .adaptivePrimary:
            MailDesign.primaryText
        case .adaptiveSecondary:
            MailDesign.secondaryText
        case .accent:
            Color.accentColor
        case .warning:
            Color.orange
        }
    }
}

struct MailboxRowForegroundPresentation: Equatable, Sendable {
    let primary: MailboxRowForegroundRole
    let secondary: MailboxRowForegroundRole
    let unread: MailboxRowForegroundRole
    let pinned: MailboxRowForegroundRole
    let preservesSemanticSignalColors: Bool

    private static let standard = Self(
        primary: .adaptivePrimary,
        secondary: .adaptiveSecondary,
        unread: .accent,
        pinned: .warning,
        preservesSemanticSignalColors: true
    )
    private static let softSelection = Self(
        primary: .adaptivePrimary,
        secondary: .adaptiveSecondary,
        unread: .accent,
        pinned: .warning,
        preservesSemanticSignalColors: true
    )

    static func resolve(selected: Bool) -> Self {
        selected ? softSelection : standard
    }
}

enum MailboxRowQuickAction: String, CaseIterable, Hashable, Identifiable, Sendable {
    case archive
    case labels
    case delete

    var id: String { rawValue }

    func accessibilityLabel(hasEffectiveLabels: Bool) -> String {
        switch self {
        case .archive:
            "Archive"
        case .labels:
            hasEffectiveLabels ? "Add or remove labels" : "Add a label"
        case .delete:
            "Delete"
        }
    }
}

enum MessageLabelMenuControl: Equatable, Identifiable, Sendable {
    case loading
    case retry
    case empty
    case item(MessageLabelMenuItem)

    var id: String {
        switch self {
        case .loading:
            "status-loading"
        case .retry:
            "action-retry"
        case .empty:
            "status-empty"
        case .item(let item):
            "label-\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .loading:
            "Loading labels…"
        case .retry:
            "Retry Loading Labels"
        case .empty:
            "No labels available"
        case .item(let item):
            item.title
        }
    }

    var systemImage: String? {
        switch self {
        case .retry:
            "arrow.clockwise"
        case .loading, .empty, .item:
            nil
        }
    }
}

extension EnvironmentValues {
    /// The folders a listed message can move to (its account's, minus the one shown).
    @Entry var mailMoveDestinations: @MainActor (String) -> [MailFolderRef] = { _ in [] }
}

struct MailMessageListRow: View {
    @Environment(\.mailAccessibilityPreviewOverrides) private var previewOverrides
    @Environment(\.mailMoveDestinations) private var moveDestinations
    let row: MessageRowModel
    let selected: Bool
    let widthClass: MailboxListWidthClass
    @ObservedObject var mailActions: InboxMailActionViewModel
    @ObservedObject var labelActions: MessageLabelActions
    @ObservedObject var quickActionFocus: MailboxRowQuickActionFocusCoordinator
    let openMessage: (String) -> Void
    let openLabelCommandCenter: (MessageRowModel) -> Void
    let performMessageAction: (InboxMailAction, String) -> Void
    private let senderIdentity: MailSenderIdentity
    let persistentAccessibilityPresentation: MessageRowPersistentAccessibilityPresentation
    @State private var isHovering = false
    @State private var hasQuickActionFocus = false

    static let actionSurface = MessageRowActionSurface.standard
    static let accessibilityHierarchy = MailboxRowAccessibilityHierarchy.containActionControls

    init(
        row: MessageRowModel,
        selected: Bool,
        widthClass: MailboxListWidthClass = .narrow,
        mailActions: InboxMailActionViewModel,
        labelActions: MessageLabelActions = .preview(),
        quickActionFocus: MailboxRowQuickActionFocusCoordinator = .init(),
        openMessage: @escaping (String) -> Void = { _ in },
        openLabelCommandCenter: @escaping (MessageRowModel) -> Void = { _ in },
        performMessageAction: @escaping (InboxMailAction, String) -> Void
    ) {
        self.row = row
        self.selected = selected
        self.widthClass = widthClass
        self.mailActions = mailActions
        self.labelActions = labelActions
        self.quickActionFocus = quickActionFocus
        self.openMessage = openMessage
        self.openLabelCommandCenter = openLabelCommandCenter
        self.performMessageAction = performMessageAction
        let senderIdentity = MailSenderIdentity(
            sender: row.sender,
            displayName: row.senderDisplayName
        )
        self.senderIdentity = senderIdentity
        self.persistentAccessibilityPresentation = .resolve(
            row: row,
            senderIdentity: senderIdentity,
            selected: selected
        )
    }

    var controlPresentation: MailboxRowControlPresentation {
        .siblingActivationReadStateAndQuickActions
    }

    var readStateTogglePresentation: MailboxReadStateTogglePresentation {
        .resolve(isUnread: row.isUnread)
    }

    var readStateToggleIsDisabled: Bool {
        mailActions.isPending(messageID: row.id)
    }

    private var forcesReadStateToggleHover: Bool {
        previewOverrides.hoveredReadStateMessageID == row.id
    }

    var metadataSignals: SmartInboxSignalSet {
        SmartInboxSignalSet(priority: row.smartPriority, requiresAction: row.requiresAction)
    }

    var labelMenuControls: [MessageLabelMenuControl] {
        switch labelActions.menuContent(for: row.id) {
        case .loading:
            [.loading]
        case .loadFailed:
            [.retry]
        case .empty:
            [.empty]
        case .items(let items):
            items.map(MessageLabelMenuControl.item)
        }
    }

    var trailingMetadataPresentation: MailboxRowTrailingMetadataPresentation {
        MailboxRowTrailingMetadataPresentation(
            signals: metadataSignals,
            isPinned: row.isPinned,
            isFlagged: row.isFlagged,
            threadMessageCount: row.threadMessageCount > 1 ? row.threadMessageCount : nil,
            dateLabel: row.dateLabel,
            showsQuickActions: showsQuickActions
        )
    }

    static func quickActionAccessibilityLabels(hasEffectiveLabels: Bool) -> [String] {
        MailboxRowQuickAction.allCases.map {
            $0.accessibilityLabel(hasEffectiveLabels: hasEffectiveLabels)
        }
    }

    private var metrics: MailboxListMetrics {
        MailboxListMetrics.resolve(widthClass)
    }

    private var foregroundPresentation: MailboxRowForegroundPresentation {
        MailboxRowForegroundPresentation.resolve(selected: selected)
    }

    private var showsQuickActions: Bool {
        Self.resolveShowsQuickActions(
            selected: selected,
            hovered: isRowHoveredForPresentation,
            hasQuickActionFocus: hasQuickActionFocus
        )
            || quickActionFocus.requestedLabelMessageID == row.id
    }

    private var isRowHoveredForPresentation: Bool {
        if let hoveredMailboxRowID = previewOverrides.hoveredMailboxRowID {
            return hoveredMailboxRowID == row.id
        }
        return isHovering
    }

    static func resolveShowsQuickActions(
        selected: Bool,
        hovered: Bool,
        hasQuickActionFocus: Bool
    ) -> Bool {
        selected || hovered || hasQuickActionFocus
    }

    var body: some View {
        HStack(spacing: MailboxListMetrics.quickActionSpacing) {
            ZStack(alignment: widthClass == .wide ? .leading : .topLeading) {
                Button(action: activate) {
                    rowContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(persistentAccessibilityPresentation.label)
                .accessibilityValue(persistentAccessibilityPresentation.value)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(Text(controlPresentation.accessibilityHint))

                MailboxReadStateToggle(
                    presentation: readStateTogglePresentation,
                    unreadColor: foregroundPresentation.unread.color,
                    isRowHovered: isRowHoveredForPresentation,
                    forceDirectHover: forcesReadStateToggleHover,
                    isDisabled: readStateToggleIsDisabled,
                    action: toggleReadState
                )
                .offset(
                    x: MailboxReadStateToggleLayout.horizontalOffset,
                    y: widthClass == .narrow
                        ? MailboxReadStateToggleLayout.narrowVerticalOffset
                        : 0
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingSlot
        }
        .padding(.horizontal, MailboxListMetrics.horizontalPadding)
        .background(
            selected ? MailDesign.selectionSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: MailDesign.Radius.control)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MailDesign.stroke.opacity(0.42))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(Self.actionSurface.contextMenuActions) { action in
                contextMenuControl(action)
            }
            .disabled(mailActions.isPending(messageID: row.id))
        }
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(
                row.isUnread ? "Mark as Read" : "Mark as Unread",
                systemImage: row.isUnread ? "envelope.open" : "envelope.badge"
            ) {
                perform(row.isUnread ? .markRead : .markUnread)
            }
            .tint(.blue)
            .disabled(mailActions.isPending(messageID: row.id))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                perform(.delete)
            }
            .disabled(mailActions.isPending(messageID: row.id))
        }
        #endif
        .accessibilityElement(children: Self.accessibilityHierarchy.childBehavior)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch widthClass {
        case .wide:
            HStack(spacing: MailboxListMetrics.contentSpacing) {
                unreadIndicatorPlaceholder
                MailSenderAvatar(identity: senderIdentity, size: metrics.avatarSize)
                Text(senderIdentity.displayName)
                .font(.system(size: 13, weight: row.isUnread ? .semibold : .medium))
                .foregroundStyle(foregroundPresentation.primary.color)
                .lineLimit(1)
                .frame(
                    minWidth: metrics.senderMinimumWidth,
                    idealWidth: metrics.senderColumnWidth,
                    maxWidth: metrics.senderColumnWidth,
                    alignment: .leading
                )
                .layoutPriority(MailboxRowLayoutPriority.sender)
                subjectAndPreview
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(MailboxRowLayoutPriority.subjectAndPreview)
            }
            .frame(height: metrics.fixedRowHeight)
        case .narrow:
            HStack(alignment: .top, spacing: MailboxListMetrics.contentSpacing) {
                unreadIndicatorPlaceholder
                    .padding(.top, 13)
                MailSenderAvatar(identity: senderIdentity, size: metrics.avatarSize)
                VStack(alignment: .leading, spacing: MailboxListMetrics.narrowLineSpacing) {
                    HStack(spacing: 8) {
                        Text(senderIdentity.displayName)
                            .font(narrowPrimaryFont)
                            .foregroundStyle(foregroundPresentation.primary.color)
                            .lineLimit(1)
                            .layoutPriority(1)
                        SmartInboxSignalIcons(
                            signals: trailingMetadataPresentation.signals,
                            selected: selected
                        )
                        Spacer(minLength: 6)
                    }
                    Text(row.subject)
                        .font(narrowPrimaryFont)
                        .foregroundStyle(foregroundPresentation.primary.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.preview)
                        .font(narrowSecondaryFont)
                        .foregroundStyle(foregroundPresentation.secondary.color)
                        .lineLimit(1)
                }
            }
            #if os(iOS)
            .frame(minHeight: metrics.fixedRowHeight)
            #else
            .frame(height: metrics.fixedRowHeight)
            #endif
        }
    }

    private var narrowPrimaryFont: Font {
        #if os(iOS)
        return .subheadline.weight(row.isUnread ? .semibold : .medium)
        #else
        return .system(size: 13, weight: row.isUnread ? .semibold : .medium)
        #endif
    }

    private var narrowSecondaryFont: Font {
        #if os(iOS)
        return .footnote
        #else
        return .system(size: 12)
        #endif
    }

    private var subjectAndPreview: some View {
        HStack(spacing: MailboxListMetrics.subjectPreviewSpacing) {
            Text(row.subject)
                .fontWeight(row.isUnread ? .semibold : .medium)
                .foregroundStyle(foregroundPresentation.primary.color)
                .lineLimit(1)
                .layoutPriority(1)
            Text(row.preview)
                .foregroundStyle(foregroundPresentation.secondary.color)
                .lineLimit(1)
        }
    }

    private var unreadIndicatorPlaceholder: some View {
        Color.clear
            .frame(
                width: MailboxListMetrics.unreadDotWidth,
                height: MailboxListMetrics.unreadDotWidth
            )
            .accessibilityHidden(true)
    }

    private func trailingMetadata(showsSignals: Bool) -> some View {
        let presentation = trailingMetadataPresentation
        return HStack(spacing: 8) {
            if showsSignals {
                SmartInboxSignalIcons(signals: presentation.signals, selected: selected)
            }
            if presentation.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(foregroundPresentation.pinned.color)
            }
            if presentation.isFlagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Flagged")
            }
            if let threadMessageCount = presentation.threadMessageCount {
                Text("\(threadMessageCount)")
            }
            Text(presentation.dateLabel)
                .frame(minWidth: 62, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(foregroundPresentation.secondary.color)
        .layoutPriority(MailboxRowLayoutPriority.trailingMetadata)
    }

    private var trailingSlot: some View {
        #if os(iOS)
        // Touch exposes row actions through the context menu. Keeping the
        // desktop hover capsule's width here truncates every iPhone subject.
        return VStack(alignment: .trailing, spacing: 2) {
            Text(trailingMetadataPresentation.dateLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if trailingMetadataPresentation.isPinned {
                    Image(systemName: "pin.fill")
                }
                if let count = trailingMetadataPresentation.threadMessageCount {
                    Text("\(count)")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(foregroundPresentation.secondary.color)
        .frame(width: 68, alignment: .trailing)
        #else
        let presentation = MailboxRowTrailingSlotPresentation.resolve(
            showsQuickActions: showsQuickActions
        )
        return Group {
            if presentation.content == .quickActions {
                MailboxRowQuickActionCapsule(
                    messageID: row.id,
                    hasEffectiveLabels: row.hasEffectiveLabels,
                    actionsDisabled: mailActions.isPending(messageID: row.id),
                    focusCoordinator: quickActionFocus,
                    archive: { perform(.archive) },
                    openLabels: openLabels,
                    delete: { perform(.delete) },
                    onFocusChange: { hasQuickActionFocus = $0 }
                )
                .transition(.opacity)
            } else {
                trailingMetadata(showsSignals: widthClass == .wide)
                    .transition(.opacity)
            }
        }
        .frame(
            width: presentation.reservedWidth,
            alignment: .trailing
        )
        .animation(.easeOut(duration: 0.12), value: showsQuickActions)
        .layoutPriority(MailboxRowLayoutPriority.trailingMetadata)
        #endif
    }

    @ViewBuilder
    private func contextMenuControl(_ action: MessageRowContextMenuAction) -> some View {
        switch action {
        case .archive:
            Button("Archive", systemImage: "archivebox") {
                perform(.archive)
            }
        case .readState:
            Button(
                row.isUnread ? "Mark as Read" : "Mark as Unread",
                systemImage: row.isUnread ? "envelope.open" : "envelope.badge"
            ) {
                perform(row.isUnread ? .markRead : .markUnread)
            }
        case .flag:
            Button(row.isFlagged ? "Unflag" : "Flag", systemImage: row.isFlagged ? "flag.slash" : "flag") {
                perform(row.isFlagged ? .unflag : .flag)
            }
        case .move:
            let folders = moveDestinations(row.id)
            Menu("Move to", systemImage: "folder") {
                ForEach(folders, id: \.path) { folder in
                    Button(folder.name, systemImage: MailboxFolder.systemImage(for: folder.role)) {
                        perform(.move(to: folder.path))
                    }
                }
            }
            .disabled(folders.isEmpty)
        case .labels:
            Menu("Labels", systemImage: "tag") {
                MessageLabelMenuContents(
                    messageID: row.id,
                    labelActions: labelActions
                )
            }
        case .separator:
            Divider()
        case .delete:
            Button("Delete", systemImage: "trash", role: .destructive) {
                perform(.delete)
            }
        }
    }

    @ViewBuilder
    private func labelMenuControl(_ control: MessageLabelMenuControl) -> some View {
        switch control {
        case .loading, .empty:
            Text(control.title)
        case .retry:
            Button(control.title, systemImage: control.systemImage ?? "arrow.clockwise") {
                Task {
                    await labelActions.retry(messageID: row.id)
                }
            }
        case .item(let item):
            labelButton(item)
        }
    }

    @ViewBuilder
    private func labelButton(_ item: MessageLabelMenuItem) -> some View {
        let button = Button {
            Task {
                await labelActions.setLabel(
                    item.id,
                    on: row.id,
                    selected: !item.hasUserOrSmartInboxOwnership
                )
            }
        } label: {
            Label(item.title, systemImage: item.isEffective ? "checkmark" : "tag")
        }
        if let help = item.ownershipHelp {
            button.help(help)
        } else {
            button
        }
    }

    func perform(_ action: InboxMailAction) {
        performMessageAction(action, row.id)
    }

    func toggleReadState() {
        perform(readStateTogglePresentation.action)
    }

    func activate() {
        openMessage(row.id)
    }

    func openLabels() {
        openLabelCommandCenter(row)
    }
}

/// Label data is deliberately loaded when its menu is presented, not while a
/// mailbox row is recycled during scrolling. This keeps label I/O and its
/// observable updates off the hot scroll path.
private struct MessageLabelMenuContents: View {
    let messageID: String
    @ObservedObject var labelActions: MessageLabelActions

    private var controls: [MessageLabelMenuControl] {
        switch labelActions.menuContent(for: messageID) {
        case .loading:
            [.loading]
        case .loadFailed:
            [.retry]
        case .empty:
            [.empty]
        case .items(let items):
            items.map(MessageLabelMenuControl.item)
        }
    }

    var body: some View {
        Group {
            ForEach(controls) { control in
                controlView(control)
            }
        }
        .task(id: MessageLabelRowRefreshKey(
            messageID: messageID,
            revision: labelActions.revision
        )) {
            await labelActions.runAppearanceTask(messageID: messageID)
        }
    }

    @ViewBuilder
    private func controlView(_ control: MessageLabelMenuControl) -> some View {
        switch control {
        case .loading, .empty:
            Text(control.title)
        case .retry:
            Button(control.title, systemImage: control.systemImage ?? "arrow.clockwise") {
                Task { await labelActions.retry(messageID: messageID) }
            }
        case .item(let item):
            labelButton(item)
        }
    }

    @ViewBuilder
    private func labelButton(_ item: MessageLabelMenuItem) -> some View {
        let button = Button {
            Task {
                await labelActions.setLabel(
                    item.id,
                    on: messageID,
                    selected: !item.hasUserOrSmartInboxOwnership
                )
            }
        } label: {
            Label(item.title, systemImage: item.isEffective ? "checkmark" : "tag")
        }
        if let help = item.ownershipHelp {
            button.help(help)
        } else {
            button
        }
    }
}

struct MessageLabelRowRefreshKey: Equatable, Hashable, Sendable {
    let messageID: String
    let revision: UInt64
}

struct ApprovalQueueListColumn: View {
    @ObservedObject var viewModel: ApprovalQueueViewModel
    @Binding var selectedFilter: ApprovalQueueFilter
    @Binding var selectedRequestID: String?

    private var items: [ApprovalQueueItemModel] {
        viewModel.items.filter { selectedFilter.matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(ApprovalQueueFilter.defaultFilters) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            List(items, selection: $selectedRequestID) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.subject)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer()
                        Text(item.status.capitalized)
                            .font(.caption)
                            .foregroundStyle(item.status.lowercased() == "failed" ? .red : .secondary)
                    }
                    Text(item.recipientSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.agentName)
                        if item.requiresAuthentication {
                            Label("Authentication", systemImage: "lock.shield")
                        }
                        if item.hasAttachments {
                            Image(systemName: "paperclip")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .tag(item.id)
            }
            .listStyle(.inset)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No requests",
                        systemImage: "checkmark.seal",
                        description: Text("Approval requests matching this filter appear here.")
                    )
                }
            }
        }
        .navigationTitle("Approvals")
        #if os(macOS)
        .navigationSubtitle("\(items.count) \(items.count == 1 ? "request" : "requests")")
        #endif
        .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 500)
        .task {
            try? await viewModel.refresh()
            resolveSelection()
        }
        .onChange(of: selectedFilter) { _, _ in
            resolveSelection()
        }
        .onChange(of: viewModel.items) { _, _ in
            resolveSelection()
        }
    }

    private func resolveSelection() {
        if !items.contains(where: { $0.id == selectedRequestID }) {
            selectedRequestID = items.first?.id
        }
    }
}

/// A Mac sidebar row: a destination, or one account's folder.
enum PlainpostSidebarItem: Hashable {
    case destination(PlainpostDestination)
    case folder(MailFolderRef)

    /// The row the sidebar shows as selected: an open folder, else the destination.
    static func current(destination: PlainpostDestination, folder: MailFolderRef?) -> PlainpostSidebarItem {
        folder.map(PlainpostSidebarItem.folder) ?? .destination(destination)
    }

    func apply(selectDestination: (PlainpostDestination) -> Void, openFolder: (MailFolderRef) -> Void) {
        switch self {
        case .destination(let destination): selectDestination(destination)
        case .folder(let folder): openFolder(folder)
        }
    }
}
