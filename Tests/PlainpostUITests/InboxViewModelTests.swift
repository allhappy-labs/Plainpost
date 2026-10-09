import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI

final class InboxViewModelTests: XCTestCase {
    func testSyncNodeSourceNeverProjectsLegacyAccountSetupEvenWithEmptyLocalProjection() {
        let viewModel = InboxViewModel.loading(
            requiresAccountSetup: true,
            setupSource: .syncNode
        )

        XCTAssertTrue(viewModel.requiresAccountSetup)
        XCTAssertFalse(viewModel.shouldPresentLegacyAccountSetup)
        XCTAssertEqual(viewModel.setupSource, .syncNode)
        XCTAssertEqual(viewModel.setupState, .requiresAccount(source: .syncNode))
    }

    func testInboxDisplayModesExposeBundlesUnreadAndAllMail() {
        let unreadNewsletter = displayModeRow(id: "unread-newsletter", category: .newsletter, isUnread: true)
        let pinnedRead = displayModeRow(id: "pinned", category: .notification, isUnread: false, isPinned: true)
        let focusedRead = displayModeRow(id: "focused-read", category: .personal, isUnread: false)
        let rows = [unreadNewsletter, pinnedRead, focusedRead]

        XCTAssertEqual(
            InboxDisplayMode.focusedList.visibleRows(from: rows).map(\.id),
            ["unread-newsletter", "pinned", "focused-read"]
        )
        XCTAssertEqual(InboxDisplayMode.unreadCards.visibleRows(from: rows).map(\.id), ["unread-newsletter"])
        XCTAssertEqual(
            InboxDisplayMode.simpleList.visibleRows(from: rows).map(\.id),
            ["unread-newsletter", "pinned", "focused-read"]
        )
        XCTAssertEqual(
            InboxDisplayMode.focusedList.visibleRows(from: rows, destination: .notifications).map(\.id),
            ["unread-newsletter", "pinned", "focused-read"]
        )
        XCTAssertTrue(InboxDisplayMode.focusedList.usesSmartSections)
        XCTAssertTrue(InboxDisplayMode.unreadCards.usesSmartSections)
        XCTAssertFalse(InboxDisplayMode.simpleList.usesSmartSections)
    }

    func testTimestampFormatterUsesActualDateOrAnHonestFallback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 12))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 10, minute: 24))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 10, minute: 24))!

        XCTAssertTrue(MailTimestampFormatter.inboxLabel(for: today, now: now, calendar: calendar, locale: locale).contains(":"))
        XCTAssertTrue(MailTimestampFormatter.readerLabel(for: today, now: now, calendar: calendar, locale: locale).hasPrefix("Today at "))
        XCTAssertEqual(MailTimestampFormatter.inboxLabel(for: yesterday, now: now, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertTrue(MailTimestampFormatter.readerLabel(for: yesterday, now: now, calendar: calendar, locale: locale).hasPrefix("Yesterday at "))
        XCTAssertEqual(MailTimestampFormatter.inboxLabel(for: nil, now: now, calendar: calendar, locale: locale), "")
        XCTAssertEqual(MailTimestampFormatter.readerLabel(for: nil, now: now, calendar: calendar, locale: locale), "")
    }

    private func displayModeRow(
        id: String,
        category: SmartCategory,
        isUnread: Bool,
        isPinned: Bool = false
    ) -> MessageRowModel {
        MessageRowModel(
            id: id,
            sender: "sender@example.com",
            subject: id,
            preview: id,
            category: category,
            categoryLabel: category.rawValue.capitalized,
            isUnread: isUnread,
            isPinned: isPinned,
            dateLabel: "",
            actions: []
        )
    }

    func testSidebarIncludesCoreDestinationsAndBadges() {
        let viewModel = InboxViewModel.preview()

        XCTAssertEqual(
            viewModel.sidebarItems.map(\.title),
            [
                "Smart Inbox",
                "All Inboxes",
                "Personal",
                "Notifications",
                "Newsletters",
                "Drafts",
                "Sent",
                "Archive",
                "Trash",
                "Agent approvals",
                "Labels",
                "AI Index Status",
                "Settings"
            ]
        )
        XCTAssertEqual(viewModel.sidebarItems.first(where: { $0.title == "Smart Inbox" })?.badge, 1)
        XCTAssertEqual(viewModel.sidebarItems.first(where: { $0.title == "Agent approvals" })?.badge, 1)
    }

    func testSidebarUnreadBadgesUseDestinationSpecificMessageCounts() {
        let messages = [
            MessageSummary(
                id: MessageID("personal_unread"),
                threadID: nil,
                from: EmailAddress("person@example.com"),
                subject: "Personal",
                preview: "Unread",
                smartCategory: .personal,
                isSeen: false
            ),
            MessageSummary(
                id: MessageID("notification_unread"),
                threadID: nil,
                from: EmailAddress("alerts@example.com"),
                subject: "Notification",
                preview: "Unread",
                smartCategory: .notification,
                isSeen: false
            ),
            MessageSummary(
                id: MessageID("newsletter_read"),
                threadID: nil,
                from: EmailAddress("news@example.com"),
                subject: "Newsletter",
                preview: "Read",
                smartCategory: .newsletter,
                isSeen: true
            )
        ]
        let items = SidebarItemModel.defaultItems(
            unreadCounts: SidebarUnreadCounts(messages: messages),
            pendingApprovalCount: 0
        )

        XCTAssertEqual(items.first(where: { $0.title == "Smart Inbox" })?.badge, 2)
        XCTAssertEqual(items.first(where: { $0.title == "All Inboxes" })?.badge, 2)
        XCTAssertEqual(items.first(where: { $0.title == "Personal" })?.badge, 1)
        XCTAssertEqual(items.first(where: { $0.title == "Notifications" })?.badge, 1)
        XCTAssertEqual(items.first(where: { $0.title == "Newsletters" })?.badge, 0)
    }

    func testSmartInboxGroupsFixtureMailIntoCards() {
        let viewModel = InboxViewModel.preview()

        XCTAssertEqual(viewModel.smartCards.map(\.title), ["People", "Notifications", "Newsletters", "Invitations", "Invitation responses", "Updates", "Pinned"])
        XCTAssertEqual(viewModel.smartCards.first?.messages.map(\.subject), ["Availability"])
        XCTAssertEqual(viewModel.smartCards.first?.quickActionTitle, "Archive read")
        XCTAssertEqual(viewModel.smartCards.first?.systemImage, "person.crop.circle")
        XCTAssertEqual(viewModel.smartCards.first?.quickActionSystemImage, "archivebox")
        XCTAssertEqual(viewModel.smartCards.first?.summary, "Conversations and messages from people.")
    }

    func testInboxChromeExposesSparkLikeMacToolbarState() {
        let viewModel = InboxViewModel.preview()

        XCTAssertEqual(viewModel.chrome.title, "Plainpost")
        XCTAssertEqual(viewModel.chrome.subtitle, "Unified local inbox")
        XCTAssertEqual(viewModel.chrome.searchPrompt, "Search mail, people, labels, or commands")
        XCTAssertEqual(viewModel.chrome.modes.map(\.title), ["Smart Bundles", "Unread Cards", "Simple List"])
        XCTAssertEqual(viewModel.chrome.selectedModeID, InboxDisplayMode.focusedList.rawValue)
        XCTAssertEqual(
            viewModel.chrome.toolbarActions.map(\.id),
            ["sync", "compose", "approvals", "command_center"]
        )
        XCTAssertEqual(
            viewModel.chrome.toolbarActions.map(\.systemImage),
            ["arrow.triangle.2.circlepath", "square.and.pencil", "checkmark.seal", "command"]
        )
    }

    func testSmartInboxSeparatesPinnedMessages() {
        let pinned = MessageSummary(
            id: MessageID("msg_pinned_1"),
            threadID: nil,
            from: EmailAddress("founder@example.com"),
            subject: "Board packet",
            preview: "Please keep this handy.",
            smartCategory: .personal,
            labels: ["Pinned"]
        )
        let store = InMemoryMailStore(messages: [pinned])

        let viewModel = InboxViewModel.preview(store: store, pendingApprovalCount: 0)

        XCTAssertEqual(viewModel.smartCards.first(where: { $0.title == "People" })?.messages.map(\.subject), [])
        XCTAssertEqual(viewModel.smartCards.first(where: { $0.title == "Pinned" })?.messages.map(\.subject), ["Board packet"])
        XCTAssertEqual(viewModel.classicRows.first?.isPinned, true)
    }

    func testClassicRowExposesScanFields() {
        let viewModel = InboxViewModel.preview()

        XCTAssertEqual(viewModel.classicRows.count, 1)
        XCTAssertEqual(viewModel.classicRows[0].sender, "alice@example.com")
        XCTAssertEqual(viewModel.classicRows[0].subject, "Availability")
        XCTAssertEqual(viewModel.classicRows[0].preview, "Can you meet next Tuesday?")
        XCTAssertEqual(viewModel.classicRows[0].categoryLabel, "Personal")
        XCTAssertTrue(viewModel.classicRows[0].isUnread)
        XCTAssertFalse(viewModel.classicRows[0].isPinned)
        XCTAssertEqual(viewModel.classicRows[0].smartPriority, .normal)
        XCTAssertFalse(viewModel.classicRows[0].requiresAction)
        XCTAssertNil(viewModel.classicRows[0].smartConfidence)
    }

    func testMessageRowsExposeEffectiveLabelPresenceFromBothProjectionTypes() {
        let summary = MessageSummary(
            id: MessageID("summary"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Summary",
            preview: "Preview",
            smartCategory: .personal,
            labels: ["Newsletters"]
        )
        let labelledListMessage = MailboxListMessage(
            id: MessageID("labelled"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Labelled",
            preview: "Preview",
            smartCategory: .personal,
            labels: ["Receipts"]
        )
        let unlabelledListMessage = MailboxListMessage(
            id: MessageID("unlabelled"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Unlabelled",
            preview: "Preview",
            smartCategory: .personal,
            labels: []
        )

        XCTAssertTrue(MessageRowModel(message: summary).hasEffectiveLabels)
        XCTAssertTrue(MessageRowModel(message: labelledListMessage).hasEffectiveLabels)
        XCTAssertFalse(MessageRowModel(message: unlabelledListMessage).hasEffectiveLabels)
    }

    func testThreadedProjectionUsesNewestTriageMetadataAndAggregatesUnreadAndPinned() {
        let threadID = ThreadID("thread")
        let older = MailboxListMessage(
            id: MessageID("older"),
            threadID: threadID,
            from: EmailAddress("older@example.com"),
            subject: "Older",
            preview: "Older",
            smartCategory: .personal,
            smartPriority: .normal,
            smartRequiresAction: false,
            smartConfidence: 0.99,
            labels: ["Pinned"],
            isSeen: false,
            sentAt: Date(timeIntervalSince1970: 1)
        )
        let newest = MailboxListMessage(
            id: MessageID("newest"),
            threadID: threadID,
            from: EmailAddress("newest@example.com"),
            subject: "Newest",
            preview: "Newest",
            smartCategory: .invitation,
            smartPriority: .high,
            smartRequiresAction: true,
            smartConfidence: 0.31,
            labels: [],
            isSeen: true,
            sentAt: Date(timeIntervalSince1970: 2)
        )

        let row = MessageRowModel.threadedRows(from: [older, newest]).first

        XCTAssertEqual(row?.id, "newest")
        XCTAssertEqual(row?.category, .invitation)
        XCTAssertEqual(row?.smartPriority, .high)
        XCTAssertEqual(row?.requiresAction, true)
        XCTAssertEqual(row?.smartConfidence, 0.31)
        XCTAssertEqual(row?.isUnread, true)
        XCTAssertEqual(row?.isPinned, true)
    }

    func testAlternativeCardsIncludeInvitationCategoriesAndKeepCategoryFirstBehavior() {
        let rows = [
            displayModeRow(id: "response", category: .invitationResponse, isUnread: true),
            displayModeRow(id: "invitation", category: .invitation, isUnread: true),
            displayModeRow(id: "newsletter", category: .newsletter, isUnread: false)
        ]

        let cards = SmartInboxCardModel.cards(from: rows, includeRead: false)

        XCTAssertEqual(cards.first(where: { $0.title == "Invitations" })?.messages.map(\.id), ["invitation"])
        XCTAssertEqual(cards.first(where: { $0.title == "Invitation responses" })?.messages.map(\.id), ["response"])
        XCTAssertEqual(InboxDisplayMode.simpleList.visibleRows(from: rows).map(\.id), rows.map(\.id))
    }

    func testDestinationRowsFilterClassicMailboxTabs() {
        let viewModel = InboxViewModel.designPreview()

        XCTAssertEqual(viewModel.rows(for: .allInboxes).count, 12)
        XCTAssertEqual(
            viewModel.rows(for: .personal).map(\.subject),
            ["Intro Emily <> Max", "Q3 planning kickoff", "Coffee next week?", "Project update & next steps"]
        )
        XCTAssertEqual(
            viewModel.rows(for: .notifications).map(\.subject),
            ["Pull request #482 opened", "Issue MA-128 moved to In Review", "Slack digest: 5 new highlights"]
        )
        XCTAssertEqual(
            viewModel.rows(for: .newsletters).map(\.subject),
            ["Big Tech's infrastructure moment", "The psychology of good product decisions"]
        )
        XCTAssertEqual(viewModel.rows(for: .sent), [])
        XCTAssertEqual(viewModel.rows(for: .labels), [])
    }

    func testSentDestinationUsesItsOwnRowsWithoutAddingThemToInbox() {
        let preview = InboxViewModel.designPreview()
        let sent = MessageRowModel(
            id: "sent-one", sender: "me@example.com", subject: "Accepted send",
            preview: "Delivered body", category: .personal, categoryLabel: "Personal",
            isUnread: false, isPinned: false, dateLabel: "Today", actions: []
        )
        let viewModel = InboxViewModel(
            chrome: preview.chrome, sidebarItems: preview.sidebarItems,
            smartCards: preview.smartCards, classicRows: preview.classicRows,
            sentRows: [sent], selectedThread: preview.selectedThread,
            aiIndexStatus: preview.aiIndexStatus
        )

        XCTAssertEqual(viewModel.rows(for: .sent).map(\.id), ["sent-one"])
        XCTAssertFalse(viewModel.rows(for: .allInboxes).contains { $0.id == "sent-one" })
    }

    func testDebugScrollProfileUsesAStableFourHundredAndEightyRowMailbox() {
        let viewModel = InboxViewModel.debugScrollProfilePreview()

        XCTAssertEqual(viewModel.classicRows.count, 480)
        XCTAssertEqual(Set(viewModel.classicRows.map(\.id)).count, 480)
        XCTAssertEqual(viewModel.totalRowCount, 480)
        XCTAssertEqual(viewModel.classicRows.first?.sender, "Jessica Sun")
    }

    func testDestinationThreadMatchesFilteredMailboxTab() {
        let viewModel = InboxViewModel.designPreview()

        let notificationsThread = viewModel.thread(for: .notifications)
        XCTAssertEqual(notificationsThread.subject, "Pull request #482 opened")
        XCTAssertEqual(notificationsThread.categoryLabel, "Notifications")
        XCTAssertEqual(notificationsThread.participants, ["GitHub"])
        XCTAssertEqual(notificationsThread.messages.first?.safeBodyText, "harper/ux polish · 2 commits")

        let newslettersThread = viewModel.thread(for: .newsletters)
        XCTAssertEqual(newslettersThread.subject, "Big Tech's infrastructure moment")
        XCTAssertEqual(newslettersThread.categoryLabel, "Newsletters")
        XCTAssertEqual(newslettersThread.participants, ["Stratechery by Ben Thompson"])

        XCTAssertEqual(viewModel.thread(for: .personal).subject, viewModel.selectedThread.subject)
    }

    func testThreadDetailExposesSummaryAndActions() {
        let viewModel = InboxViewModel.preview()

        XCTAssertEqual(viewModel.selectedThread.subject, "Availability")
        XCTAssertEqual(viewModel.selectedThread.participants, ["alice@example.com", "me@example.com"])
        XCTAssertEqual(viewModel.selectedThread.summaryStatus, "Not summarized")
        XCTAssertEqual(viewModel.selectedThread.availableActions, ["Reply", "Reply all", "Forward", "Archive", "Delete"])
    }

    func testLocalSearchMatchesSenderSubjectAndPreviewAcrossInboxViews() {
        let viewModel = InboxViewModel.designPreview()

        let results = viewModel.rows(for: .allInboxes, matching: "GITHUB")
        XCTAssertEqual(results.map(\.id), ["github-pr"])

        let cards = viewModel.smartCards(matching: "github")
        XCTAssertEqual(cards.map(\.title), ["Notifications"])
        XCTAssertEqual(cards.first?.messages.map(\.id), ["github-pr"])

        XCTAssertEqual(viewModel.rows(for: .allInboxes, matching: "   ").count, viewModel.classicRows.count)
        XCTAssertTrue(viewModel.rows(for: .allInboxes, matching: "not-present").isEmpty)
    }

    func testThreadDetailExposesSanitizedMessagesAndBlockedRemoteImages() {
        let message = ThreadMessageModel(
            id: "msg_html_1",
            sender: "alice@example.com",
            body: .html(#"<p>Hello <strong>Alice</strong></p><script>alert(1)</script><img src="https://tracker.example/pixel.png">"#)
        )
        let thread = ThreadDetailModel(
            subject: "HTML Update",
            participants: ["alice@example.com"],
            summaryStatus: "Not summarized",
            actionItems: [],
            availableActions: ["Reply"],
            messages: [message]
        )

        XCTAssertEqual(thread.messages[0].safeBodyText, "Hello Alice")
        XCTAssertEqual(thread.messages[0].blockedRemoteImageCount, 1)
        XCTAssertEqual(thread.messages[0].blockedRemoteImageStatus, "1 remote image blocked")
        XCTAssertTrue(thread.messages[0].safeHTML?.contains("<strong>Alice</strong>") == true)
        XCTAssertTrue(thread.messages[0].safeHTML?.contains("tracker.example/pixel.png") == true)
        XCTAssertFalse(thread.messages[0].safeHTML?.contains("<script") == true)
        XCTAssertFalse(thread.messages[0].safeBodyText.contains("script"))
        XCTAssertFalse(thread.messages[0].safeBodyText.contains("tracker.example"))
    }

    /// The Mac mail list narrowed to one account folder lists exactly that folder's rows, in
    /// the combined view's shell.
    func testNarrowedToFolderRowsListsOnlyThem() {
        let combined = InboxViewModel.designPreview()
        let folderRows = Array(combined.classicRows.suffix(2))
        let narrowed = combined.narrowed(toFolderRows: folderRows, hasMore: true)
        XCTAssertEqual(narrowed.rows(for: .allInboxes).map(\.id), folderRows.map(\.id))
        XCTAssertEqual(narrowed.totalRowCount, folderRows.count)
        XCTAssertTrue(narrowed.hasMoreRows)
        XCTAssertEqual(narrowed.sidebarItems, combined.sidebarItems)
        XCTAssertNotEqual(
            narrowed.contentRevision,
            combined.narrowed(toFolderRows: Array(folderRows.prefix(1)), hasMore: false).contentRevision,
            "different folder rows are a different list"
        )
    }
}
