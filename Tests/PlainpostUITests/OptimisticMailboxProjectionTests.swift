import XCTest
@testable import PlainpostUI

final class OptimisticMailboxProjectionTests: XCTestCase {
    func testProjectionPreservesAggregateUnreadCountsForAPartialPage() {
        let visibleRows = [unreadRow(id: "visible")]
        let aggregateRows = (0..<290).map { unreadRow(id: "aggregate_\($0)") }
        let base = inbox(rows: visibleRows, sidebarRows: aggregateRows)

        let projected = OptimisticMailboxProjection.project(base, overlays: [:])

        XCTAssertEqual(projected.sidebarItems.first { $0.title == "Smart Inbox" }?.badge, 290)
    }

    func testReadOverlayAdjustsAggregateUnreadCountsWithoutCollapsingToVisiblePage() {
        let visibleRows = [unreadRow(id: "visible")]
        let aggregateRows = (0..<290).map { unreadRow(id: "aggregate_\($0)") }
        let base = inbox(rows: visibleRows, sidebarRows: aggregateRows)

        let projected = OptimisticMailboxProjection.project(
            base,
            overlays: ["visible": .init(rowID: "visible", action: .markRead)]
        )

        XCTAssertEqual(projected.sidebarItems.first { $0.title == "Smart Inbox" }?.badge, 289)
        XCTAssertEqual(projected.sidebarItems.first { $0.title == "Personal" }?.badge, 289)
    }

    func testRemovalOverlayHidesOnlyThePendingConversationAndRebuildsDerivedLists() {
        let base = inbox(rows: [unreadRow(id: "msg_1"), readRow(id: "msg_2")])
        let overlay = OptimisticMailboxOverlay(
            rowID: "msg_1",
            action: .delete
        )

        let projected = OptimisticMailboxProjection.project(base, overlays: ["msg_1": overlay])

        XCTAssertEqual(projected.classicRows.map(\.id), ["msg_2"])
        XCTAssertEqual(projected.sidebarItems.first { $0.title == "Smart Inbox" }?.badge, 0)
        XCTAssertFalse(projected.smartCards.flatMap(\.messages).contains { $0.id == "msg_1" })
    }

    func testReadOverlayUpdatesRowActionsAndUnreadBadgesWithoutRemovingTheRow() {
        let base = inbox(rows: [unreadRow(id: "msg_1")])
        let projected = OptimisticMailboxProjection.project(
            base,
            overlays: ["msg_1": .init(rowID: "msg_1", action: .markRead)]
        )

        XCTAssertFalse(projected.classicRows[0].isUnread)
        XCTAssertEqual(projected.classicRows[0].actions.first?.id, "mark_unread")
        XCTAssertEqual(projected.sidebarItems.first { $0.title == "Smart Inbox" }?.badge, 0)
    }

    func testRefreshWithTheOldRowRetainsPendingRemovalOverlay() {
        let refreshed = inbox(rows: [unreadRow(id: "msg_1")])
        let projected = OptimisticMailboxProjection.project(
            refreshed,
            overlays: ["msg_1": .init(rowID: "msg_1", action: .archive)]
        )

        XCTAssertTrue(projected.classicRows.isEmpty)
    }

    func testSuccessMayShowAReplacementRowForAnotherMessageInTheThread() {
        let reconciled = inbox(rows: [readRow(id: "msg_older_thread_message")])
        let projected = OptimisticMailboxProjection.project(reconciled, overlays: [:])

        XCTAssertEqual(projected.classicRows.map(\.id), ["msg_older_thread_message"])
    }

    func testInboxOverlayKeepsConfirmedSentRowsAndTheirPagination() {
        let empty = inbox(rows: [])
        let base = InboxViewModel(
            chrome: empty.chrome, sidebarItems: empty.sidebarItems,
            smartCards: [], classicRows: [], sentRows: [readRow(id: "sent-one")],
            selectedThread: empty.selectedThread, aiIndexStatus: empty.aiIndexStatus,
            hasMoreSentRows: true
        )

        let projected = OptimisticMailboxProjection.project(base, overlays: [:])

        XCTAssertEqual(projected.rows(for: .sent).map(\.id), ["sent-one"])
        XCTAssertTrue(projected.hasMoreSentRows)
    }

    private func inbox(
        rows: [MessageRowModel],
        sidebarRows: [MessageRowModel]? = nil
    ) -> InboxViewModel {
        let base = InboxViewModel.loading(requiresAccountSetup: false)
        return InboxViewModel(
            chrome: base.chrome,
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: SidebarUnreadCounts(rows: sidebarRows ?? rows),
                pendingApprovalCount: 0
            ),
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: base.selectedThread,
            aiIndexStatus: base.aiIndexStatus
        )
    }

    private func unreadRow(id: String) -> MessageRowModel {
        row(id: id, isUnread: true)
    }

    private func readRow(id: String) -> MessageRowModel {
        row(id: id, isUnread: false)
    }

    private func row(id: String, isUnread: Bool) -> MessageRowModel {
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
}
