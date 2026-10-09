import Foundation
import PlainpostAI
import PlainpostCore
import PlainpostDB

public enum MailTimestampFormatter {
    public static func inboxLabel(
        for date: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let date else {
            return ""
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return formattedTime(date, calendar: calendar, locale: locale)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return formattedDate(date, includingYear: !calendar.isDate(date, equalTo: now, toGranularity: .year), calendar: calendar, locale: locale)
    }

    public static func readerLabel(
        for date: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let date else {
            return ""
        }
        let time = formattedTime(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today at \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday at \(time)"
        }
        return "\(formattedDate(date, includingYear: !calendar.isDate(date, equalTo: now, toGranularity: .year), calendar: calendar, locale: locale)) at \(time)"
    }

    private static func formattedTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private static func formattedDate(
        _ date: Date,
        includingYear: Bool,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(includingYear ? "dMMMy" : "dMMM")
        return formatter.string(from: date)
    }
}

public struct InboxViewModel: Equatable, Sendable {
    public enum SetupSource: Equatable, Sendable {
        case localAccount
        case syncNode
    }

    /// The mailbox setup state includes both the owning source and whether
    /// that source still needs setup. Keeping those facts together prevents
    /// an impossible bool/source combination from driving the UI.
    public enum SetupState: Equatable, Sendable {
        case ready(source: SetupSource)
        case requiresAccount(source: SetupSource)

        public var source: SetupSource {
            switch self {
            case let .ready(source), let .requiresAccount(source): return source
            }
        }

        public var requiresAccountSetup: Bool {
            if case .requiresAccount = self { return true }
            return false
        }
    }

    public let chrome: InboxChromeModel
    public let sidebarItems: [SidebarItemModel]
    public let smartCards: [SmartInboxCardModel]
    public let classicRows: [MessageRowModel]
    public let sentRows: [MessageRowModel]
    public let selectedThread: ThreadDetailModel
    public let aiIndexStatus: AIIndexStatusModel
    public let setupState: SetupState
    /// Compatibility projections for callers that only need one facet of the
    /// source-aware setup state.
    public var requiresAccountSetup: Bool { setupState.requiresAccountSetup }
    /// Identifies which setup flow owns the mailbox. A Node-backed mailbox is
    /// already account/session-authorized even when the local SQLite account
    /// projection is empty; it must never open the legacy credential form.
    public var setupSource: SetupSource { setupState.source }
    public var shouldPresentLegacyAccountSetup: Bool {
        setupSource == .localAccount && requiresAccountSetup
    }
    public let accountIdentity: MailboxAccountIdentity?
    public let totalRowCount: Int
    public let hasMoreRows: Bool
    public let hasMoreSentRows: Bool
    public let mailboxLoadFailure: String?
    public let mailboxRevision: UInt64
    /// Advances whenever the row content presented by the mailbox changes.
    /// It includes optimistic projections that do not yet have a persisted
    /// mailbox revision.
    public let contentRevision: UInt64

    public init(
        chrome: InboxChromeModel,
        sidebarItems: [SidebarItemModel],
        smartCards: [SmartInboxCardModel],
        classicRows: [MessageRowModel],
        sentRows: [MessageRowModel] = [],
        selectedThread: ThreadDetailModel,
        aiIndexStatus: AIIndexStatusModel,
        requiresAccountSetup: Bool = false,
        setupSource: SetupSource = .localAccount,
        accountIdentity: MailboxAccountIdentity? = nil,
        totalRowCount: Int? = nil,
        hasMoreRows: Bool = false,
        hasMoreSentRows: Bool = false,
        mailboxLoadFailure: String? = nil,
        mailboxRevision: UInt64 = 0,
        contentRevision: UInt64? = nil
    ) {
        self.chrome = chrome
        self.sidebarItems = sidebarItems
        self.smartCards = smartCards
        self.classicRows = classicRows
        self.sentRows = sentRows
        self.selectedThread = selectedThread
        self.aiIndexStatus = aiIndexStatus
        self.setupState = requiresAccountSetup
            ? .requiresAccount(source: setupSource)
            : .ready(source: setupSource)
        self.accountIdentity = accountIdentity
        self.totalRowCount = totalRowCount ?? classicRows.count
        self.hasMoreRows = hasMoreRows
        self.hasMoreSentRows = hasMoreSentRows
        self.mailboxLoadFailure = mailboxLoadFailure
        self.mailboxRevision = mailboxRevision
        self.contentRevision = contentRevision ?? mailboxRevision
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contentRevision == rhs.contentRevision
            && lhs.selectedThread == rhs.selectedThread
            && lhs.mailboxLoadFailure == rhs.mailboxLoadFailure
    }

    public func withMailboxLoadFailure(
        _ message: String?, selectedThread: ThreadDetailModel? = nil
    ) -> InboxViewModel {
        InboxViewModel(
            chrome: chrome,
            sidebarItems: sidebarItems,
            smartCards: smartCards,
            classicRows: classicRows,
            sentRows: sentRows,
            selectedThread: selectedThread ?? self.selectedThread,
            aiIndexStatus: aiIndexStatus,
            requiresAccountSetup: requiresAccountSetup,
            setupSource: setupSource,
            accountIdentity: accountIdentity,
            totalRowCount: totalRowCount,
            hasMoreRows: hasMoreRows,
            hasMoreSentRows: hasMoreSentRows,
            mailboxLoadFailure: message,
            mailboxRevision: mailboxRevision,
            contentRevision: contentRevision
        )
    }

    public static func loading(requiresAccountSetup: Bool, setupSource: SetupSource = .localAccount) -> InboxViewModel {
        let aiIndex = AIIndexStatusModel(
            snapshot: AIIndexStatusSnapshot(
                state: .notBuilt,
                indexedMessageCount: 0,
                providerID: "local-search",
                modelID: "built-in-local-embeddings",
                isStale: true,
                localOnly: true
            )
        )
        return InboxViewModel(
            chrome: .default,
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: SidebarUnreadCounts(rows: []),
                pendingApprovalCount: 0,
                aiIndexWarningCount: nil
            ),
            smartCards: [],
            classicRows: [],
            selectedThread: ThreadDetailModel(
                subject: "No conversation selected",
                participants: [],
                summaryStatus: "Not summarized",
                actionItems: [],
                availableActions: []
            ),
            aiIndexStatus: aiIndex,
            requiresAccountSetup: requiresAccountSetup,
            setupSource: setupSource
        )
    }

    public static func preview(
        store: InMemoryMailStore = .seededForStage0(),
        pendingApprovalCount: Int = 1,
        aiIndexStatus: AIIndexStatusSnapshot = AIIndexStatusSnapshot(
            state: .ready,
            indexedMessageCount: 1,
            providerID: "local-search",
            modelID: "built-in-local-embeddings",
            isStale: false,
            localOnly: true
        )
    ) -> InboxViewModel {
        let messages = store.messages
        let rows = MessageRowModel.threadedRows(from: messages)
        let unreadCounts = SidebarUnreadCounts(messages: messages)
        let aiIndex = AIIndexStatusModel(snapshot: aiIndexStatus)

        return InboxViewModel(
            chrome: .default,
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: unreadCounts,
                pendingApprovalCount: pendingApprovalCount,
                aiIndexWarningCount: aiIndex.needsAttention ? 1 : nil
            ),
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: ThreadDetailModel(
                subject: store.threads.first?.subjectNormalized.capitalized ?? messages.first?.subject ?? "No Thread",
                participants: (store.threads.first?.participantEmails ?? []).map(\.rawValue),
                summaryStatus: "Not summarized",
                actionItems: [],
                availableActions: ["Reply", "Reply all", "Forward", "Archive", "Delete"],
                messages: messages.map { message in
                    ThreadMessageModel(
                        id: message.id.rawValue,
                        sender: message.from.rawValue,
                        senderDisplayName: message.fromDisplayName,
                        replyTo: message.replyTo?.rawValue,
                        body: message.bodyHTML.map(EmailBodyInput.html) ?? .plainText(message.body)
                    )
                }
            ),
            aiIndexStatus: aiIndex,
            requiresAccountSetup: false,
            accountIdentity: MailboxAccountIdentity(displayName: "Personal", email: "me@example.com")
        )
    }

    public static func designPreview() -> InboxViewModel {
        let fixtureDate: (String) -> Date = { value in
            ISO8601DateFormatter().date(from: value)!
        }
        let rows = [
            designRow(
                id: "jessica-intro",
                sender: "Jessica Sun",
                subject: "Intro Emily <> Max",
                preview: "Hi Emily, I'd like to introduce you to Max...",
                category: .personal,
                isUnread: true,
                isPinned: false,
                dateLabel: "10:24 AM",
                smartPriority: .high,
                requiresAction: true,
                smartConfidence: 0.96,
                sentAt: fixtureDate("2026-07-22T08:24:00Z")
            ),
            designRow(
                id: "diana-kickoff",
                sender: "Diana Jones",
                subject: "Q3 planning kickoff",
                preview: "Please confirm whether you can join tomorrow...",
                category: .personal,
                isUnread: true,
                isPinned: false,
                dateLabel: "10:02 AM",
                requiresAction: true,
                smartConfidence: 0.91,
                sentAt: fixtureDate("2026-07-22T08:02:00Z")
            ),
            designRow(
                id: "stratechery",
                sender: "Stratechery by Ben Thompson",
                subject: "Big Tech's infrastructure moment",
                preview: "A deep dive into compute, power, and...",
                category: .newsletter,
                isUnread: true,
                isPinned: false,
                dateLabel: "9:48 AM",
                smartPriority: .high,
                smartConfidence: 0.21,
                sentAt: fixtureDate("2026-07-22T07:48:00Z")
            ),
            designRow(
                id: "maria-checkin",
                sender: "Maria Chen",
                subject: "Coffee next week?",
                preview: "Would Tuesday morning work for you?",
                category: .personal,
                isUnread: true,
                isPinned: false,
                dateLabel: "9:31 AM",
                smartConfidence: 0.88,
                sentAt: fixtureDate("2026-07-22T07:31:00Z")
            ),
            designRow(
                id: "github-pr",
                sender: "GitHub",
                subject: "Pull request #482 opened",
                preview: "harper/ux polish · 2 commits",
                category: .notification,
                isUnread: true,
                isPinned: false,
                dateLabel: "9:15 AM",
                smartConfidence: 0.98,
                sentAt: fixtureDate("2026-07-22T07:15:00Z"),
                threadMessageCount: 3
            ),
            designRow(
                id: "lenny-newsletter",
                sender: "Lenny's Newsletter",
                subject: "The psychology of good product decisions",
                preview: "In this week's edition, Lenny explores...",
                category: .newsletter,
                isUnread: true,
                isPinned: false,
                dateLabel: "8:46 AM",
                smartConfidence: 0.94,
                sentAt: fixtureDate("2026-07-22T06:46:00Z")
            ),
            designRow(
                id: "calendar-invitation",
                sender: "Nadia Rieben",
                subject: "Invitation: Product review",
                preview: "Thursday, 23 July · 14:00–14:45",
                category: .invitation,
                isUnread: true,
                isPinned: false,
                dateLabel: "8:20 AM",
                smartConfidence: 0.97,
                sentAt: fixtureDate("2026-07-22T06:20:00Z")
            ),
            designRow(
                id: "calendar-response",
                sender: "Alexander Denchev",
                subject: "Accepted: Product review",
                preview: "Alexander Denchev accepted this invitation.",
                category: .invitationResponse,
                isUnread: true,
                isPinned: false,
                dateLabel: "8:05 AM",
                smartConfidence: 0.99,
                sentAt: fixtureDate("2026-07-22T06:05:00Z")
            ),
            designRow(
                id: "john-update",
                sender: "John Smith",
                subject: "Project update & next steps",
                preview: "Thanks for the great sync yesterday. Here...",
                category: .personal,
                isUnread: true,
                isPinned: false,
                dateLabel: "Yesterday",
                sentAt: fixtureDate("2026-07-21T14:20:00Z")
            ),
            designRow(
                id: "linear-issue",
                sender: "Linear",
                subject: "Issue MA-128 moved to In Review",
                preview: "Design system tokens",
                category: .notification,
                isUnread: true,
                isPinned: false,
                dateLabel: "Jul 20",
                sentAt: fixtureDate("2026-07-20T12:10:00Z")
            ),
            designRow(
                id: "slack-digest",
                sender: "no-reply@slack.com",
                subject: "Slack digest: 5 new highlights",
                preview: "You have a new mention and 4 updates.",
                category: .notification,
                isUnread: false,
                isPinned: false,
                dateLabel: "Jul 16",
                sentAt: fixtureDate("2026-07-16T09:30:00Z")
            ),
            designRow(
                id: "june-receipt",
                sender: "SBB CFF FFS",
                subject: "Your ticket receipt",
                preview: "Thank you for travelling with SBB.",
                category: .receipt,
                isUnread: false,
                isPinned: false,
                dateLabel: "Jun 28",
                sentAt: fixtureDate("2026-06-28T08:00:00Z")
            )
        ]
        let aiIndex = AIIndexStatusModel(
            snapshot: AIIndexStatusSnapshot(
                state: .ready,
                indexedMessageCount: 152_834,
                providerID: "local-search",
                modelID: "built-in-local-embeddings",
                isStale: false,
                localOnly: true
            )
        )

        return InboxViewModel(
            chrome: .default,
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: SidebarUnreadCounts(rows: rows),
                pendingApprovalCount: 12,
                aiIndexWarningCount: nil
            ),
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: ThreadDetailModel(
                subject: "Intro Emily <> Max",
                participants: ["Jessica Sun", "Emily Jones", "Max Harper"],
                summaryStatus: "Ready",
                actionItems: [
                    "Emily: Reply if you're open to a short intro this week.",
                    "Max: Prepare a brief overview of BB8 for the intro.",
                    "Jessica: Follow up if no response by end of week."
                ],
                availableActions: ["Reply", "Reply all", "Forward", "Archive", "Delete"],
                messages: [
                    ThreadMessageModel(
                        id: "jessica-intro",
                        sender: "jessica@example.com",
                        senderDisplayName: "Jessica Sun",
                        dateLabel: "10:24 AM",
                        body: .plainText("""
                        Hi Emily,

                        I'd like to introduce you to Max Harper. Max is the founder and CEO of BB8, an AI-native financial planning platform for founders and finance teams.

                        Max, Emily is Head of Strategic Finance at AAA Capital. Her team helps portfolio companies model, plan, and grow with confidence.

                        Would love to see if there's a fit for a quick intro this week.

                        Best,
                        Jessica
                        """)
                    )
                ]
            ),
            aiIndexStatus: aiIndex,
            requiresAccountSetup: false,
            accountIdentity: MailboxAccountIdentity(displayName: "Personal", email: "me@example.com")
        )
    }

#if DEBUG
    /// A deterministic, credential-free mailbox large enough to exercise native
    /// list recycling and fast scrolling in the packaged debug app.
    public static func debugScrollProfilePreview() -> InboxViewModel {
        let preview = designPreview()
        let rows = (0..<40).flatMap { page in
            preview.classicRows.map { row in
                MessageRowModel(
                    id: "scroll-profile-\(page)-\(row.id)",
                    sender: row.sender,
                    senderDisplayName: row.senderDisplayName,
                    subject: row.subject,
                    preview: row.preview,
                    category: row.category,
                    categoryLabel: row.categoryLabel,
                    smartPriority: row.smartPriority,
                    requiresAction: row.requiresAction,
                    smartConfidence: row.smartConfidence,
                    isUnread: row.isUnread,
                    isPinned: row.isPinned,
                    dateLabel: row.dateLabel,
                    sentAt: row.sentAt,
                    actions: row.actions,
                    threadMessageCount: row.threadMessageCount
                )
            }
        }

        return InboxViewModel(
            chrome: preview.chrome,
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: SidebarUnreadCounts(rows: rows),
                pendingApprovalCount: 12,
                aiIndexWarningCount: nil
            ),
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: preview.selectedThread,
            aiIndexStatus: preview.aiIndexStatus,
            requiresAccountSetup: false,
            accountIdentity: preview.accountIdentity,
            totalRowCount: rows.count
        )
    }
#endif

    public func rows(for destination: PlainpostDestination) -> [MessageRowModel] {
        switch destination {
        #if os(macOS)
        case .calendar: []
        #endif
        case .smartInbox, .allInboxes:
            classicRows
        case .personal:
            classicRows.filter { $0.category == .personal }
        case .notifications:
            classicRows.filter { $0.category == .notification }
        case .newsletters:
            classicRows.filter { $0.category == .newsletter }
        case .sent:
            sentRows
        case .drafts, .archive, .trash, .approvalQueue, .labels, .aiIndexStatus, .settings:
            []
        }
    }

    public func rows(for destination: PlainpostDestination, matching query: String) -> [MessageRowModel] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return rows(for: destination)
        }

        return rows(for: destination).filter { row in
            [row.sender, row.subject, row.preview, row.body].contains { value in
                value.range(
                    of: normalizedQuery,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
    }

    public func smartCards(matching query: String) -> [SmartInboxCardModel] {
        let rows = rows(for: .smartInbox, matching: query)
        return SmartInboxCardModel.cards(from: rows).filter { !$0.messages.isEmpty }
    }

    public func thread(for destination: PlainpostDestination) -> ThreadDetailModel {
        if destination == .smartInbox || destination == .allInboxes || destination == .personal
            || destination == .sent || destination == .archive {
            return selectedThread
        }

        guard let row = rows(for: destination).first else {
            return ThreadDetailModel(
                subject: "No conversation selected",
                participants: [],
                summaryStatus: "Not summarized",
                actionItems: [],
                availableActions: [],
                categoryLabel: destination.title
            )
        }

        return ThreadDetailModel(
            subject: row.subject,
            participants: [row.sender],
            summaryStatus: "Not summarized",
            actionItems: [],
            availableActions: ["Archive", "Delete", row.isUnread ? "Mark read" : "Mark unread"],
            messages: [
                ThreadMessageModel(
                    id: "thread_\(row.id)",
                    sender: row.sender,
                    senderDisplayName: row.senderDisplayName,
                    dateLabel: row.readerDateLabel,
                    body: row.bodyHTML.map(EmailBodyInput.html) ?? .plainText(row.body)
                )
            ],
            categoryLabel: row.categoryLabel
        )
    }

    private static func designRow(
        id: String,
        sender: String,
        subject: String,
        preview: String,
        category: SmartCategory,
        isUnread: Bool,
        isPinned: Bool,
        dateLabel: String,
        smartPriority: SmartPriority = .normal,
        requiresAction: Bool = false,
        smartConfidence: Double? = nil,
        sentAt: Date? = nil,
        threadMessageCount: Int = 1
    ) -> MessageRowModel {
        MessageRowModel(
            id: id,
            sender: sender,
            subject: subject,
            preview: preview,
            category: category,
            categoryLabel: category.displayName,
            smartPriority: smartPriority,
            requiresAction: requiresAction,
            smartConfidence: smartConfidence,
            isUnread: isUnread,
            isPinned: isPinned,
            dateLabel: dateLabel,
            sentAt: sentAt,
            actions: MessageRowActionModel.defaultActions(isUnread: isUnread),
            threadMessageCount: threadMessageCount
        )
    }
}

public struct MailboxAccountIdentity: Equatable, Sendable {
    public let displayName: String
    public let email: String

    public init(displayName: String, email: String) {
        self.displayName = displayName
        self.email = email
    }
}

public struct InboxChromeModel: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let searchPrompt: String
    public let modes: [InboxModeModel]
    public let selectedModeID: String
    public let toolbarActions: [InboxToolbarActionModel]

    public init(
        title: String,
        subtitle: String,
        searchPrompt: String,
        modes: [InboxModeModel],
        selectedModeID: String,
        toolbarActions: [InboxToolbarActionModel]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.searchPrompt = searchPrompt
        self.modes = modes
        self.selectedModeID = selectedModeID
        self.toolbarActions = toolbarActions
    }

    public static let `default` = InboxChromeModel(
        title: "Plainpost",
        subtitle: "Unified local inbox",
        searchPrompt: "Search mail, people, labels, or commands",
        modes: [
            InboxModeModel(id: InboxDisplayMode.focusedList.rawValue, title: InboxDisplayMode.focusedList.title),
            InboxModeModel(id: InboxDisplayMode.unreadCards.rawValue, title: InboxDisplayMode.unreadCards.title),
            InboxModeModel(id: InboxDisplayMode.simpleList.rawValue, title: InboxDisplayMode.simpleList.title)
        ],
        selectedModeID: InboxDisplayMode.focusedList.rawValue,
        toolbarActions: [
            InboxToolbarActionModel(id: "sync", title: "Sync", systemImage: "arrow.triangle.2.circlepath"),
            InboxToolbarActionModel(id: "compose", title: "Compose", systemImage: "square.and.pencil"),
            InboxToolbarActionModel(id: "approvals", title: "Approvals", systemImage: "checkmark.seal"),
            InboxToolbarActionModel(id: "command_center", title: "Command Center", systemImage: "command")
        ]
    )
}

public enum InboxDisplayMode: String, CaseIterable, Sendable {
    case focusedList = "focused_list"
    case unreadCards = "unread_cards"
    case simpleList = "simple_list"

    public static let segmentedDisplayOrder: [Self] = [
        .focusedList,
        .simpleList,
        .unreadCards,
    ]

    public var title: String {
        switch self {
        case .focusedList:
            "Smart Bundles"
        case .unreadCards:
            "Unread Cards"
        case .simpleList:
            "Simple List"
        }
    }

    public var segmentedTitle: String {
        switch self {
        case .focusedList:
            "Focused"
        case .unreadCards:
            "Unread"
        case .simpleList:
            "Simple"
        }
    }

    public var segmentedSystemImage: String {
        switch self {
        case .focusedList:
            "rectangle.3.group"
        case .unreadCards:
            "envelope.badge"
        case .simpleList:
            "list.bullet"
        }
    }

    public var segmentedAccessibilityLabel: String {
        segmentedTitle
    }

    public var systemImage: String {
        segmentedSystemImage
    }

    public func visibleRows(
        from rows: [MessageRowModel],
        destination: PlainpostDestination = .smartInbox
    ) -> [MessageRowModel] {
        switch self {
        case .focusedList:
            return rows
        case .unreadCards:
            return rows.filter(\.isUnread)
        case .simpleList:
            return rows
        }
    }

    public var usesSmartSections: Bool {
        self == .focusedList || self == .unreadCards
    }
}

public struct InboxModeModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct InboxToolbarActionModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

public struct SidebarItemModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let badge: Int?

    public init(title: String, badge: Int? = nil) {
        self.id = title
        self.title = title
        self.badge = badge
    }

    public static func defaultItems(
        unreadCounts: SidebarUnreadCounts,
        pendingApprovalCount: Int,
        aiIndexWarningCount: Int? = nil
    ) -> [SidebarItemModel] {
        [
            SidebarItemModel(title: "Smart Inbox", badge: unreadCounts.total),
            SidebarItemModel(title: "All Inboxes", badge: unreadCounts.total),
            SidebarItemModel(title: "Personal", badge: unreadCounts.personal),
            SidebarItemModel(title: "Notifications", badge: unreadCounts.notifications),
            SidebarItemModel(title: "Newsletters", badge: unreadCounts.newsletters),
            SidebarItemModel(title: "Drafts"),
            SidebarItemModel(title: "Sent"),
            SidebarItemModel(title: "Archive"),
            SidebarItemModel(title: "Trash"),
            SidebarItemModel(title: "Agent approvals", badge: pendingApprovalCount),
            SidebarItemModel(title: "Labels"),
            SidebarItemModel(title: "AI Index Status", badge: aiIndexWarningCount),
            SidebarItemModel(title: "Settings")
        ]
    }
}

public struct SidebarUnreadCounts: Equatable, Sendable {
    public let total: Int
    public let personal: Int
    public let notifications: Int
    public let newsletters: Int

    public init(messages: [MessageSummary]) {
        self.init(unreadCategories: messages.lazy.filter { !$0.isSeen }.map(\.smartCategory))
    }

    public init(rows: [MessageRowModel]) {
        self.init(unreadCategories: rows.lazy.filter(\.isUnread).map(\.category))
    }

    init(mailboxCounts: MailboxUnreadConversationCounts) {
        total = mailboxCounts.total
        personal = mailboxCounts.personal
        notifications = mailboxCounts.notifications
        newsletters = mailboxCounts.newsletters
    }

    init(total: Int, personal: Int, notifications: Int, newsletters: Int) {
        self.total = total
        self.personal = personal
        self.notifications = notifications
        self.newsletters = newsletters
    }

    func adjustingUnread(by delta: Int, category: SmartCategory) -> Self {
        Self(
            total: max(0, total + delta),
            personal: max(0, personal + (category == .personal ? delta : 0)),
            notifications: max(0, notifications + (category == .notification ? delta : 0)),
            newsletters: max(0, newsletters + (category == .newsletter ? delta : 0))
        )
    }

    private init<S: Sequence>(unreadCategories: S) where S.Element == SmartCategory {
        let categories = Array(unreadCategories)
        total = categories.count
        personal = categories.count(where: { $0 == .personal })
        notifications = categories.count(where: { $0 == .notification })
        newsletters = categories.count(where: { $0 == .newsletter })
    }
}

public struct AIIndexStatusModel: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let needsAttention: Bool

    public init(snapshot: AIIndexStatusSnapshot) {
        self.needsAttention = snapshot.isStale || snapshot.state != .ready
        self.detail = "\(snapshot.indexedMessageCount) \(snapshot.indexedMessageCount == 1 ? "message" : "messages") indexed"
        switch snapshot.state {
        case .notBuilt:
            self.title = "AI index not built"
        case .paused:
            self.title = "AI index paused"
        case .rebuilding:
            self.title = "AI index rebuilding"
        case .ready:
            self.title = "AI index ready"
        case .failed:
            self.title = "AI index failed"
        }
    }
}

public struct SmartInboxCardModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let summary: String
    public let messages: [MessageRowModel]
    public let quickActionTitle: String
    public let quickActionSystemImage: String
    public let isCollapsedByDefault: Bool

    public init(
        title: String,
        systemImage: String,
        summary: String,
        messages: [MessageRowModel],
        quickActionTitle: String,
        quickActionSystemImage: String,
        isCollapsedByDefault: Bool = false
    ) {
        self.id = title
        self.title = title
        self.systemImage = systemImage
        self.summary = summary
        self.messages = messages
        self.quickActionTitle = quickActionTitle
        self.quickActionSystemImage = quickActionSystemImage
        self.isCollapsedByDefault = isCollapsedByDefault
    }

    public static func cards(from rows: [MessageRowModel], includeRead: Bool = true) -> [SmartInboxCardModel] {
        let activeRows = includeRead ? rows : rows.filter(\.isUnread)
        return [
            SmartInboxCardModel(
                title: "People",
                systemImage: "person.crop.circle",
                summary: "Conversations and messages from people.",
                messages: activeRows.filter { $0.category == .personal && !$0.isPinned },
                quickActionTitle: "Archive read",
                quickActionSystemImage: "archivebox"
            ),
            SmartInboxCardModel(
                title: "Notifications",
                systemImage: "bell.badge",
                summary: "Alerts, security messages, and service notifications.",
                messages: activeRows.filter { [.notification, .system, .security].contains($0.category) && !$0.isPinned },
                quickActionTitle: "Mark read",
                quickActionSystemImage: "checkmark.circle"
            ),
            SmartInboxCardModel(
                title: "Newsletters",
                systemImage: "newspaper",
                summary: "Subscriptions, publications, and recurring reading.",
                messages: activeRows.filter { $0.category == .newsletter && !$0.isPinned },
                quickActionTitle: "Archive",
                quickActionSystemImage: "archivebox"
            ),
            SmartInboxCardModel(
                title: "Invitations",
                systemImage: "calendar.badge.plus",
                summary: "Invitations that may need a response.",
                messages: activeRows.filter { $0.category == .invitation && !$0.isPinned },
                quickActionTitle: "Mark read",
                quickActionSystemImage: "checkmark.circle"
            ),
            SmartInboxCardModel(
                title: "Invitation responses",
                systemImage: "calendar.badge.checkmark",
                summary: "Accepted, declined, and tentative responses.",
                messages: activeRows.filter { $0.category == .invitationResponse && !$0.isPinned },
                quickActionTitle: "Archive",
                quickActionSystemImage: "archivebox"
            ),
            SmartInboxCardModel(
                title: "Updates",
                systemImage: "rectangle.3.group",
                summary: "Receipts, finance, travel, support, and other updates.",
                messages: activeRows.filter { [.receipt, .finance, .travel, .support, .social, .unknown].contains($0.category) && !$0.isPinned },
                quickActionTitle: "Mark read",
                quickActionSystemImage: "checkmark.circle"
            ),
            SmartInboxCardModel(
                title: "Pinned",
                systemImage: "pin",
                summary: "Messages you pinned for quick access.",
                messages: activeRows.filter(\.isPinned),
                quickActionTitle: "Unpin",
                quickActionSystemImage: "pin.slash"
            )
        ]
    }
}

public struct MessageRowModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let sender: String
    public let senderDisplayName: String?
    public let subject: String
    public let preview: String
    public let category: SmartCategory
    public let categoryLabel: String
    public let smartPriority: SmartPriority
    public let requiresAction: Bool
    public let smartConfidence: Double?
    public let isUnread: Bool
    public let isPinned: Bool
    public let hasEffectiveLabels: Bool
    public let dateLabel: String
    public let sentAt: Date?
    public let actions: [MessageRowActionModel]
    public let threadMessageCount: Int
    /// A Node-backed account's change to this message was admitted by the
    /// Sync Node, or may have reached it, and is not confirmed yet. Projected
    /// from the shared store's mail-intent journal; never set for Direct mail
    /// or for a change still waiting to be sent.
    public private(set) var isWaitingForNode = false
    /// Some copy of the message carries \\Flagged.
    public private(set) var isFlagged = false
    /// The account whose mailbox holds the message, when the list knows it.
    public let accountID: AccountID?

    public init(
        id: String,
        sender: String,
        senderDisplayName: String? = nil,
        subject: String,
        preview: String,
        body: String? = nil,
        bodyHTML: String? = nil,
        category: SmartCategory,
        categoryLabel: String,
        smartPriority: SmartPriority = .normal,
        requiresAction: Bool = false,
        smartConfidence: Double? = nil,
        isUnread: Bool,
        isPinned: Bool,
        hasEffectiveLabels: Bool = false,
        dateLabel: String,
        sentAt: Date? = nil,
        actions: [MessageRowActionModel],
        threadMessageCount: Int = 1,
        accountID: AccountID? = nil
    ) {
        self.id = id
        self.sender = sender
        self.senderDisplayName = senderDisplayName
        self.subject = subject
        self.preview = preview
        self.category = category
        self.categoryLabel = categoryLabel
        self.smartPriority = smartPriority
        self.requiresAction = requiresAction
        self.smartConfidence = smartConfidence
        self.isUnread = isUnread
        self.isPinned = isPinned
        self.hasEffectiveLabels = hasEffectiveLabels
        self.dateLabel = dateLabel
        self.sentAt = sentAt
        self.actions = actions
        self.threadMessageCount = threadMessageCount
        self.accountID = accountID
    }

    public func withWaitingForNode(_ waiting: Bool) -> MessageRowModel {
        var copy = self
        copy.isWaitingForNode = waiting
        return copy
    }

    public func replacing(isFlagged: Bool) -> MessageRowModel {
        var copy = self
        copy.isFlagged = isFlagged
        return copy
    }

    /// Compatibility accessors for previews and older callers. List state never
    /// retains complete body data; reader content is fetched by conversation ID.
    public var body: String { preview }
    public var bodyHTML: String? { nil }

    public init(message: MailboxListMessage) {
        let isUnread = !message.isSeen
        self.init(
            id: message.id.rawValue,
            sender: message.from.rawValue,
            senderDisplayName: message.fromDisplayName,
            subject: message.subject,
            preview: message.preview,
            category: message.smartCategory,
            categoryLabel: message.smartCategory.displayName,
            smartPriority: message.smartPriority,
            requiresAction: message.smartRequiresAction,
            smartConfidence: message.smartConfidence,
            isUnread: isUnread,
            isPinned: message.labels.contains { $0.caseInsensitiveCompare("Pinned") == .orderedSame },
            hasEffectiveLabels: !message.labels.isEmpty,
            dateLabel: MailTimestampFormatter.inboxLabel(for: message.sentAt),
            sentAt: message.sentAt,
            actions: MessageRowActionModel.defaultActions(isUnread: isUnread),
            accountID: message.accountID
        )
        isFlagged = message.isFlagged
    }

    public init(message: MessageSummary) {
        let isUnread = !message.isSeen
        self.init(
            id: message.id.rawValue,
            sender: message.from.rawValue,
            senderDisplayName: message.fromDisplayName,
            subject: message.subject,
            preview: message.preview,
            body: message.body,
            bodyHTML: message.bodyHTML,
            category: message.smartCategory,
            categoryLabel: message.smartCategory.displayName,
            smartPriority: .normal,
            requiresAction: false,
            smartConfidence: nil,
            isUnread: isUnread,
            isPinned: message.labels.contains { $0.caseInsensitiveCompare("Pinned") == .orderedSame },
            hasEffectiveLabels: !message.labels.isEmpty,
            dateLabel: MailTimestampFormatter.inboxLabel(for: message.sentAt),
            sentAt: message.sentAt,
            actions: MessageRowActionModel.defaultActions(isUnread: isUnread)
        )
        isFlagged = message.isFlagged
    }

    public static func threadedRows(from messages: [MessageSummary]) -> [MessageRowModel] {
        let groups = Dictionary(grouping: messages) { threadGroupingKey(for: $0) }
        return groups.values.compactMap { group in
            guard let newest = group.max(by: { lhs, rhs in
                let lhsDate = lhs.sentAt ?? .distantPast
                let rhsDate = rhs.sentAt ?? .distantPast
                return lhsDate == rhsDate ? lhs.id.rawValue < rhs.id.rawValue : lhsDate < rhsDate
            }) else { return nil }
            let newestRow = MessageRowModel(message: newest)
            return MessageRowModel(
                id: newestRow.id,
                sender: newestRow.sender,
                senderDisplayName: newestRow.senderDisplayName,
                subject: newestRow.subject,
                preview: newestRow.preview,
                body: newestRow.body,
                bodyHTML: newestRow.bodyHTML,
                category: newestRow.category,
                categoryLabel: newestRow.categoryLabel,
                smartPriority: newestRow.smartPriority,
                requiresAction: newestRow.requiresAction,
                smartConfidence: newestRow.smartConfidence,
                isUnread: group.contains { !$0.isSeen },
                isPinned: group.contains { $0.labels.contains { $0.caseInsensitiveCompare("Pinned") == .orderedSame } },
                hasEffectiveLabels: group.contains { !$0.labels.isEmpty },
                dateLabel: newestRow.dateLabel,
                sentAt: newestRow.sentAt,
                actions: MessageRowActionModel.defaultActions(isUnread: group.contains { !$0.isSeen }),
                threadMessageCount: group.count
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.sentAt ?? .distantPast
            let rhsDate = rhs.sentAt ?? .distantPast
            return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
        }
    }

    public static func threadedRows(from messages: [MailboxListMessage]) -> [MessageRowModel] {
        let groups = Dictionary(grouping: messages) { message -> String in
            guard let threadID = message.threadID?.rawValue else {
                return "message_\(message.id.rawValue)"
            }
            return threadID.hasPrefix("thr_uid_")
                ? "legacy_subject_\(MailThreading.normalizedSubject(message.subject))"
                : threadID
        }
        return groups.values.compactMap { group in
            guard let newest = group.max(by: { lhs, rhs in
                let lhsDate = lhs.sentAt ?? .distantPast
                let rhsDate = rhs.sentAt ?? .distantPast
                return lhsDate == rhsDate ? lhs.id.rawValue < rhs.id.rawValue : lhsDate < rhsDate
            }) else { return nil }
            let row = MessageRowModel(message: newest)
            let isUnread = group.contains { !$0.isSeen }
            return MessageRowModel(
                id: row.id,
                sender: row.sender,
                senderDisplayName: row.senderDisplayName,
                subject: row.subject,
                preview: row.preview,
                category: row.category,
                categoryLabel: row.categoryLabel,
                smartPriority: row.smartPriority,
                requiresAction: row.requiresAction,
                smartConfidence: row.smartConfidence,
                isUnread: isUnread,
                isPinned: group.contains { message in
                    message.labels.contains { $0.caseInsensitiveCompare("Pinned") == .orderedSame }
                },
                hasEffectiveLabels: group.contains { !$0.labels.isEmpty },
                dateLabel: row.dateLabel,
                sentAt: row.sentAt,
                actions: MessageRowActionModel.defaultActions(isUnread: isUnread),
                threadMessageCount: group.count,
                accountID: row.accountID
            )
        }.sorted { lhs, rhs in
            let lhsDate = lhs.sentAt ?? .distantPast
            let rhsDate = rhs.sentAt ?? .distantPast
            return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
        }
    }

    public static func threadGroupingKey(for message: MessageSummary) -> String {
        MailThreading.conversationKey(for: message)
    }

    public func replacing(isUnread: Bool) -> MessageRowModel {
        var copy = MessageRowModel(
            id: id,
            sender: sender,
            senderDisplayName: senderDisplayName,
            subject: subject,
            preview: preview,
            category: category,
            categoryLabel: categoryLabel,
            smartPriority: smartPriority,
            requiresAction: requiresAction,
            smartConfidence: smartConfidence,
            isUnread: isUnread,
            isPinned: isPinned,
            hasEffectiveLabels: hasEffectiveLabels,
            dateLabel: dateLabel,
            sentAt: sentAt,
            actions: MessageRowActionModel.defaultActions(isUnread: isUnread),
            threadMessageCount: threadMessageCount,
            accountID: accountID
        )
        copy.isFlagged = isFlagged
        copy.isWaitingForNode = isWaitingForNode
        return copy
    }

    public var readerDateLabel: String {
        sentAt.map { MailTimestampFormatter.readerLabel(for: $0) } ?? dateLabel
    }
}

public struct MessageRowActionModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let action: InboxMailAction

    public init(id: String, title: String, systemImage: String, action: InboxMailAction) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public static func defaultActions(isUnread: Bool) -> [MessageRowActionModel] {
        [
            isUnread
                ? MessageRowActionModel(id: "mark_read", title: "Mark read", systemImage: "envelope.open", action: .markRead)
                : MessageRowActionModel(id: "mark_unread", title: "Mark unread", systemImage: "envelope.badge", action: .markUnread),
            MessageRowActionModel(id: "archive", title: "Archive", systemImage: "archivebox", action: .archive),
            MessageRowActionModel(id: "delete", title: "Delete", systemImage: "trash", action: .delete)
        ]
    }
}

public struct ThreadDetailModel: Equatable, Sendable {
    public let subject: String
    public let participants: [String]
    public let summaryStatus: String
    public let actionItems: [String]
    public let availableActions: [String]
    public let messages: [ThreadMessageModel]
    public let categoryLabel: String

    public init(
        subject: String,
        participants: [String],
        summaryStatus: String,
        actionItems: [String],
        availableActions: [String],
        messages: [ThreadMessageModel] = [],
        categoryLabel: String = "Personal"
    ) {
        self.subject = subject
        self.participants = participants
        self.summaryStatus = summaryStatus
        self.actionItems = actionItems
        self.availableActions = availableActions
        self.messages = messages
        self.categoryLabel = categoryLabel
    }
}

public struct ThreadMessageModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let sender: String
    public let senderDisplayName: String?
    public let replyTo: String?
    public let dateLabel: String
    public let bodyKind: EmailBodyKind
    public let safeBodyText: String
    public let safeHTML: String?
    public let blockedRemoteImageURLs: [String]
    public let translationSourceFingerprint: String
    public let sourceThreadID: ThreadID?
    public let rfcMessageID: String?
    public let inReplyTo: String?
    public let references: [String]
    public let attachments: [MailAttachment]
    public let to: [String]
    public let cc: [String]
    let deferredBody: EmailBodyInput?

    public init(
        id: String,
        sender: String,
        senderDisplayName: String? = nil,
        replyTo: String? = nil,
        dateLabel: String = "",
        body: EmailBodyInput,
        sourceThreadID: ThreadID? = nil,
        rfcMessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [MailAttachment] = [],
        to: [String] = [],
        cc: [String] = []
    ) {
        let rendered = EmailBodyRenderer.render(body)
        self.init(
            id: id,
            sender: sender,
            senderDisplayName: senderDisplayName,
            replyTo: replyTo,
            dateLabel: dateLabel,
            renderedBody: rendered,
            translationSourceFingerprint: MailTranslationFingerprint.source(
                messageID: MessageID(id),
                body: body
            ),
            sourceThreadID: sourceThreadID,
            rfcMessageID: rfcMessageID,
            inReplyTo: inReplyTo,
            references: references,
            attachments: attachments,
            to: to,
            cc: cc
        )
    }

    init(
        id: String,
        sender: String,
        senderDisplayName: String? = nil,
        replyTo: String? = nil,
        dateLabel: String = "",
        renderedBody: RenderedEmailBody,
        translationSourceFingerprint: String? = nil,
        sourceThreadID: ThreadID? = nil,
        rfcMessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [MailAttachment] = [],
        to: [String] = [],
        cc: [String] = []
    ) {
        self.id = id
        self.sender = sender
        self.senderDisplayName = senderDisplayName
        self.replyTo = replyTo
        self.dateLabel = dateLabel
        self.bodyKind = renderedBody.kind
        self.safeBodyText = renderedBody.safeText
        self.safeHTML = renderedBody.safeHTML
        self.blockedRemoteImageURLs = renderedBody.blockedRemoteImageURLs
        self.translationSourceFingerprint = translationSourceFingerprint
            ?? MailTranslationFingerprint.source(
                messageID: MessageID(id),
                renderedBody: renderedBody
            )
        self.sourceThreadID = sourceThreadID
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.to = to
        self.cc = cc
        self.deferredBody = nil
    }

    init(
        id: String,
        sender: String,
        senderDisplayName: String? = nil,
        replyTo: String? = nil,
        dateLabel: String = "",
        deferredBody: EmailBodyInput,
        fallbackText: String,
        blockedRemoteImageURLs: [String],
        translationSourceFingerprint: String? = nil,
        sourceThreadID: ThreadID? = nil,
        rfcMessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [MailAttachment] = [],
        to: [String] = [],
        cc: [String] = []
    ) {
        self.id = id
        self.sender = sender
        self.senderDisplayName = senderDisplayName
        self.replyTo = replyTo
        self.dateLabel = dateLabel
        self.bodyKind = switch deferredBody {
        case .html: .html
        case .plainText: .plainText
        }
        self.safeBodyText = fallbackText
        self.safeHTML = nil
        self.blockedRemoteImageURLs = blockedRemoteImageURLs
        self.translationSourceFingerprint = translationSourceFingerprint
            ?? MailTranslationFingerprint.source(
                messageID: MessageID(id),
                body: deferredBody
            )
        self.sourceThreadID = sourceThreadID
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.to = to
        self.cc = cc
        self.deferredBody = deferredBody
    }

    var renderedBodySnapshot: RenderedEmailBody {
        RenderedEmailBody(
            kind: bodyKind,
            safeText: safeBodyText,
            safeHTML: safeHTML,
            blockedRemoteImageURLs: blockedRemoteImageURLs
        )
    }

    public var blockedRemoteImageCount: Int {
        blockedRemoteImageURLs.count
    }

    public var blockedRemoteImageStatus: String? {
        switch blockedRemoteImageCount {
        case 0:
            return nil
        case 1:
            return "1 remote image blocked"
        default:
            return "\(blockedRemoteImageCount) remote images blocked"
        }
    }
}

extension SmartCategory {
    var displayName: String {
        switch self {
        case .personal:
            "Personal"
        case .notification:
            "Notifications"
        case .newsletter:
            "Newsletters"
        case .receipt:
            "Receipts"
        case .security:
            "Security"
        case .finance:
            "Finance"
        case .travel:
            "Travel"
        case .support:
            "Support"
        case .social:
            "Social"
        case .system:
            "System"
        case .invitation:
            "Invitation"
        case .invitationResponse:
            "Invitation response"
        case .unknown:
            "Unknown"
        }
    }
}

extension InboxViewModel {
    /// The combined view's shell listing one account folder's rows instead: the Mac mail list
    /// with a sidebar folder open. Its content revision follows the rows, so the list redraws
    /// when the folder's rows change.
    func narrowed(toFolderRows rows: [MessageRowModel], hasMore: Bool) -> InboxViewModel {
        var revision: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in rows {
            for byte in "\(row.id)\u{0}\(row.isUnread)\u{0}".utf8 {
                revision = (revision ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        return InboxViewModel(
            chrome: chrome,
            sidebarItems: sidebarItems,
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: selectedThread,
            aiIndexStatus: aiIndexStatus,
            requiresAccountSetup: requiresAccountSetup,
            setupSource: setupSource,
            accountIdentity: accountIdentity,
            totalRowCount: rows.count,
            hasMoreRows: hasMore,
            mailboxLoadFailure: mailboxLoadFailure,
            mailboxRevision: mailboxRevision,
            contentRevision: revision
        )
    }
}
