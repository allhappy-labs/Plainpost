import Foundation

public struct OptimisticMailboxOverlay: Equatable, Sendable {
    public let rowID: String
    public let action: InboxMailAction

    public init(rowID: String, action: InboxMailAction) {
        self.rowID = rowID
        self.action = action
    }

    public var hidesRow: Bool {
        action.removesMessage
    }

    public var unreadOverride: Bool? {
        switch action {
        case .markRead:
            false
        case .markUnread:
            true
        case .archive, .delete, .deletePermanently, .flag, .unflag, .move:
            nil
        }
    }
}

public enum OptimisticMailboxProjection {
    public static func project(
        _ base: InboxViewModel,
        overlays: [String: OptimisticMailboxOverlay],
        projectionRevision: UInt64 = 0
    ) -> InboxViewModel {
        let rows = base.classicRows.compactMap { row -> MessageRowModel? in
            guard let overlay = overlays[row.id] else { return row }
            guard !overlay.hidesRow else { return nil }
            return row.replacing(isUnread: overlay.unreadOverride ?? row.isUnread)
                .replacing(isFlagged: overlay.action.flaggedChange ?? row.isFlagged)
        }
        var unreadCounts: SidebarUnreadCounts
        if let total = base.sidebarItems.first(where: { $0.title == "Smart Inbox" })?.badge,
           let personal = base.sidebarItems.first(where: { $0.title == "Personal" })?.badge,
           let notifications = base.sidebarItems.first(where: { $0.title == "Notifications" })?.badge,
           let newsletters = base.sidebarItems.first(where: { $0.title == "Newsletters" })?.badge {
            unreadCounts = SidebarUnreadCounts(
                total: total,
                personal: personal,
                notifications: notifications,
                newsletters: newsletters
            )
        } else {
            unreadCounts = SidebarUnreadCounts(rows: base.classicRows)
        }
        for overlay in overlays.values {
            guard let baseRow = base.classicRows.first(where: { $0.id == overlay.rowID }) else {
                continue
            }
            let unreadDelta: Int
            switch overlay.action {
            case .archive, .delete, .deletePermanently, .markRead, .move:
                unreadDelta = baseRow.isUnread ? -1 : 0
            case .markUnread:
                unreadDelta = baseRow.isUnread ? 0 : 1
            case .flag, .unflag:
                unreadDelta = 0
            }
            unreadCounts = unreadCounts.adjustingUnread(
                by: unreadDelta,
                category: baseRow.category
            )
        }
        return InboxViewModel(
            chrome: base.chrome,
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: unreadCounts,
                pendingApprovalCount: base.sidebarItems.first { $0.title == "Agent approvals" }?.badge ?? 0,
                aiIndexWarningCount: base.sidebarItems.first { $0.title == "AI Index Status" }?.badge
            ),
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            sentRows: base.sentRows,
            selectedThread: base.selectedThread,
            aiIndexStatus: base.aiIndexStatus,
            requiresAccountSetup: base.requiresAccountSetup,
            accountIdentity: base.accountIdentity,
            totalRowCount: base.totalRowCount,
            hasMoreRows: base.hasMoreRows,
            hasMoreSentRows: base.hasMoreSentRows,
            mailboxLoadFailure: base.mailboxLoadFailure,
            mailboxRevision: base.mailboxRevision,
            contentRevision: base.contentRevision &+ projectionRevision
        )
    }
}
