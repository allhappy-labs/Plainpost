import XCTest
@testable import PlainpostUI

final class MailboxListLayoutTests: XCTestCase {
    func testWidthClassChangesAtExactlyNineHundredPoints() {
        XCTAssertEqual(MailboxListWidthClass.resolve(availableWidth: 899), .narrow)
        XCTAssertEqual(MailboxListWidthClass.resolve(availableWidth: 900), .wide)
    }

    func testApprovedLedgerMetricsAreStable() {
        XCTAssertEqual(MailboxListMetrics.wide.rowMinimumHeight, 50)
        XCTAssertEqual(MailboxListMetrics.wide.senderColumnWidth, 220)
        XCTAssertEqual(MailboxListMetrics.wide.senderMinimumWidth, 140)
        XCTAssertEqual(MailboxListMetrics.wide.avatarSize, 30)
        XCTAssertEqual(MailboxListMetrics.narrow.rowMinimumHeight, 66)
        XCTAssertNil(MailboxListMetrics.narrow.senderColumnWidth)
        XCTAssertNil(MailboxListMetrics.narrow.senderMinimumWidth)
        XCTAssertEqual(MailboxListMetrics.narrow.avatarSize, 34)
        XCTAssertEqual(MailboxListMetrics.horizontalPadding, 12)
        XCTAssertEqual(MailboxListMetrics.contentSpacing, 10)
        XCTAssertEqual(MailboxListMetrics.narrowLineSpacing, 4)
        XCTAssertEqual(MailboxListMetrics.subjectPreviewSpacing, 6)
        XCTAssertEqual(MailboxListMetrics.quickActionSpacing, 4)
    }

    func testLedgerRowsUseFixedApprovedHeightsForNativeListSizing() {
        XCTAssertEqual(MailboxListMetrics.wide.fixedRowHeight, 50)
        XCTAssertEqual(MailboxListMetrics.narrow.fixedRowHeight, 66)
    }

    func testTrailingSlotKeepsTheSameReservedWidthForMetadataAndQuickActions() {
        let metadata = MailboxRowTrailingSlotPresentation.resolve(showsQuickActions: false)
        let quickActions = MailboxRowTrailingSlotPresentation.resolve(showsQuickActions: true)

        XCTAssertEqual(metadata.reservedWidth, quickActions.reservedWidth)
        XCTAssertEqual(metadata.reservedWidth, MailboxListMetrics.trailingActionSlotWidth)
        XCTAssertEqual(metadata.content, .metadata)
        XCTAssertEqual(quickActions.content, .quickActions)
    }

    func testWideSenderKeepsReferenceAlignmentButContractsBeforeSubjectPreview() {
        XCTAssertLessThan(
            MailboxRowLayoutPriority.sender,
            MailboxRowLayoutPriority.subjectAndPreview
        )
        XCTAssertLessThan(
            MailboxRowLayoutPriority.subjectAndPreview,
            MailboxRowLayoutPriority.trailingMetadata
        )
    }

    func testWideSmartInboxSummaryMatchesContractedMessageSubjectOrigin() {
        XCTAssertEqual(
            MailboxListMetrics.wide.contractedContentColumnOrigin,
            SmartInboxBundleMetrics.wide.summaryColumnOrigin
        )
        XCTAssertEqual(MailboxListMetrics.wide.contractedContentColumnOrigin, 205)
        XCTAssertEqual(MailboxListMetrics.wide.contentColumnOrigin, 285)
    }

    func testInboxModeControlsUseExpectedOrderAndAccessibleIconMetadata() {
        XCTAssertEqual(
            InboxDisplayMode.segmentedDisplayOrder,
            [.focusedList, .simpleList, .unreadCards]
        )
        XCTAssertEqual(InboxDisplayMode.focusedList.segmentedTitle, "Focused")
        XCTAssertEqual(InboxDisplayMode.simpleList.segmentedTitle, "Simple")
        XCTAssertEqual(InboxDisplayMode.unreadCards.segmentedTitle, "Unread")
        XCTAssertEqual(InboxDisplayMode.focusedList.segmentedSystemImage, "rectangle.3.group")
        XCTAssertEqual(InboxDisplayMode.simpleList.segmentedSystemImage, "list.bullet")
        XCTAssertEqual(InboxDisplayMode.unreadCards.segmentedSystemImage, "envelope.badge")
        XCTAssertEqual(InboxDisplayMode.focusedList.segmentedAccessibilityLabel, "Focused")
    }

    private func headerRow(id: String, isUnread: Bool) -> MessageRowModel {
        MessageRowModel(
            id: id,
            sender: "sender@example.com",
            subject: id,
            preview: id,
            category: .personal,
            categoryLabel: "Personal",
            isUnread: isUnread,
            isPinned: false,
            dateLabel: "",
            actions: MessageRowActionModel.defaultActions(isUnread: isUnread)
        )
    }

    func testMailboxHeaderPresentationUsesModeFilteredConversationCount() {
        let rows = [
            headerRow(id: "read", isUnread: false),
            headerRow(id: "unread", isUnread: true),
        ]

        XCTAssertEqual(
            MailboxHeaderPresentation.make(
                title: "Smart Inbox",
                availableRows: rows,
                mode: .focusedList,
                destination: .smartInbox
            ),
            MailboxHeaderPresentation(
                title: "Smart Inbox",
                conversationCountLabel: "2 conversations"
            )
        )
        XCTAssertEqual(
            MailboxHeaderPresentation.make(
                title: "Smart Inbox",
                availableRows: rows,
                mode: .unreadCards,
                destination: .smartInbox
            ).conversationCountLabel,
            "1 conversation"
        )
    }

    func testKeyboardSelectionMovesWithoutWrapping() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(
            MailboxRowKeyboardNavigation.nextID(
                current: "b",
                direction: .down,
                orderedIDs: ids
            ),
            "c"
        )
        XCTAssertEqual(
            MailboxRowKeyboardNavigation.nextID(
                current: "a",
                direction: .up,
                orderedIDs: ids
            ),
            "a"
        )
        XCTAssertEqual(
            MailboxRowKeyboardNavigation.nextID(
                current: nil,
                direction: .down,
                orderedIDs: ids
            ),
            "a"
        )
    }

    func testScrollItemsCaptureOrdinaryAndUnreadCardSections() {
        XCTAssertEqual(
            MailboxScrollItemFactory.flat(messageIDs: ["a", "b"]),
            [
                .init(id: "message-a", sectionID: .mailbox),
                .init(id: "message-b", sectionID: .mailbox),
            ]
        )
        XCTAssertEqual(
            MailboxScrollItemFactory.unreadCards([
                (sectionID: "People", messageIDs: ["a", "b"]),
                (sectionID: "Newsletters", messageIDs: ["c"]),
            ]),
            [
                .init(id: "message-a", sectionID: .unreadCard("People")),
                .init(id: "message-b", sectionID: .unreadCard("People")),
                .init(id: "message-c", sectionID: .unreadCard("Newsletters")),
            ]
        )
    }

    func testScrollItemsCaptureSmartOverviewAndBundleSections() {
        XCTAssertEqual(
            MailboxScrollItemFactory.smartInboxOverview(
                promotedMessageIDs: ["promoted"],
                bundleIDs: [.people, .newsletters],
                historicalSections: [
                    (id: .yesterday, messageIDs: ["yesterday"]),
                    (id: .thisWeek, messageIDs: ["week-a", "week-b"]),
                ]
            ),
            [
                .init(id: "message-promoted", sectionID: .smartInboxToday),
                .init(id: "bundle-people", sectionID: .smartInboxToday),
                .init(id: "bundle-newsletters", sectionID: .smartInboxToday),
                .init(
                    id: "message-yesterday",
                    sectionID: .smartInboxHistorical(.yesterday)
                ),
                .init(
                    id: "message-week-a",
                    sectionID: .smartInboxHistorical(.thisWeek)
                ),
                .init(
                    id: "message-week-b",
                    sectionID: .smartInboxHistorical(.thisWeek)
                ),
            ]
        )
        XCTAssertEqual(
            MailboxScrollItemFactory.smartInboxBundle(
                .newsletters,
                messageIDs: ["a", "b"]
            ),
            [
                .init(
                    id: "message-a",
                    sectionID: .smartInboxBundle(.newsletters)
                ),
                .init(
                    id: "message-b",
                    sectionID: .smartInboxBundle(.newsletters)
                ),
            ]
        )
    }
}
