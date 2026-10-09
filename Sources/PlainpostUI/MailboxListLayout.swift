import SwiftUI

enum MailboxListWidthClass: Equatable, Sendable {
    case wide
    case narrow

    static let boundary: CGFloat = 900

    static func resolve(availableWidth: CGFloat) -> Self {
        availableWidth >= boundary ? .wide : .narrow
    }
}

struct MailboxListMetrics: Equatable, Sendable {
    let rowMinimumHeight: CGFloat
    let senderColumnWidth: CGFloat?
    let senderMinimumWidth: CGFloat?
    let avatarSize: CGFloat

    static let horizontalPadding: CGFloat = 12
    static let unreadDotWidth: CGFloat = 5
    static let contentSpacing: CGFloat = 10
    static let narrowLineSpacing: CGFloat = 4
    static let subjectPreviewSpacing: CGFloat = 6
    static let quickActionSpacing: CGFloat = 4
    static let quickActionButtonSize: CGFloat = 28
    static let quickActionCount = 3
    static let quickActionSeparatorWidth: CGFloat = 1
    static let quickActionCapsuleInset: CGFloat = 2
    static let trailingActionSlotWidth: CGFloat =
        CGFloat(quickActionCount) * quickActionButtonSize
        + CGFloat(quickActionCount - 1) * quickActionSeparatorWidth
        + quickActionCapsuleInset * 2

    static let wide = Self(
        rowMinimumHeight: 50,
        senderColumnWidth: 220,
        senderMinimumWidth: 140,
        avatarSize: 30
    )
    static let narrow = Self(
        rowMinimumHeight: 66,
        senderColumnWidth: nil,
        senderMinimumWidth: nil,
        avatarSize: 34
    )

    static func resolve(_ widthClass: MailboxListWidthClass) -> Self {
        widthClass == .wide ? .wide : .narrow
    }

    /// Native `List` rows use a fixed height so AppKit does not need to
    /// repeatedly ask every recycled row for its intrinsic size while scrolling.
    var fixedRowHeight: CGFloat {
        rowMinimumHeight
    }

    var avatarDiameter: CGFloat {
        avatarSize
    }

    var contentColumnOrigin: CGFloat {
        contentColumnOrigin(senderWidth: senderColumnWidth ?? 0)
    }

    var contractedContentColumnOrigin: CGFloat {
        contentColumnOrigin(senderWidth: senderMinimumWidth ?? 0)
    }

    private func contentColumnOrigin(senderWidth: CGFloat) -> CGFloat {
        Self.unreadDotWidth
            + Self.contentSpacing
            + avatarDiameter
            + Self.contentSpacing
            + senderWidth
            + Self.contentSpacing
    }

    var identityRegionWidth: CGFloat? {
        guard senderColumnWidth != nil else { return nil }
        return contentColumnOrigin - Self.contentSpacing
    }

    var contractedIdentityRegionWidth: CGFloat? {
        guard senderMinimumWidth != nil else { return nil }
        return contractedContentColumnOrigin - Self.contentSpacing
    }
}

struct MailboxRowTrailingSlotPresentation: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case metadata
        case quickActions
    }

    let content: Content
    let reservedWidth: CGFloat

    static func resolve(showsQuickActions: Bool) -> Self {
        Self(
            content: showsQuickActions ? .quickActions : .metadata,
            reservedWidth: MailboxListMetrics.trailingActionSlotWidth
        )
    }
}

enum MailboxRowLayoutPriority {
    static let sender = 0.0
    static let subjectAndPreview = 1.0
    static let trailingMetadata = 2.0
}

enum MailboxRowMoveDirection: Sendable {
    case up
    case down
}

enum MailboxRowKeyboardNavigation {
    static func nextID(
        current: String?,
        direction: MailboxRowMoveDirection,
        orderedIDs: [String]
    ) -> String? {
        guard !orderedIDs.isEmpty else { return nil }
        guard let current, let index = orderedIDs.firstIndex(of: current) else {
            return orderedIDs.first
        }
        switch direction {
        case .up:
            return orderedIDs[max(orderedIDs.startIndex, index - 1)]
        case .down:
            return orderedIDs[min(orderedIDs.index(before: orderedIDs.endIndex), index + 1)]
        }
    }
}

enum MailboxScrollID {
    static func message(_ id: String) -> String {
        "message-\(id)"
    }

    static func bundle(_ bundle: SmartInboxDisplayBundle) -> String {
        "bundle-\(bundle.rawValue)"
    }
}

enum MailboxScrollItemFactory {
    static func flat(messageIDs: [String]) -> [MailboxScrollItem] {
        messageIDs.map {
            MailboxScrollItem(
                id: MailboxScrollID.message($0),
                sectionID: .mailbox
            )
        }
    }

    static func unreadCards(
        _ sections: [(sectionID: String, messageIDs: [String])]
    ) -> [MailboxScrollItem] {
        sections.flatMap { section in
            section.messageIDs.map {
                MailboxScrollItem(
                    id: MailboxScrollID.message($0),
                    sectionID: .unreadCard(section.sectionID)
                )
            }
        }
    }

    static func smartInboxOverview(
        promotedMessageIDs: [String],
        bundleIDs: [SmartInboxDisplayBundle],
        historicalSections: [
            (id: SmartInboxHistoricalSectionID, messageIDs: [String])
        ]
    ) -> [MailboxScrollItem] {
        promotedMessageIDs.map {
            MailboxScrollItem(
                id: MailboxScrollID.message($0),
                sectionID: .smartInboxToday
            )
        } + bundleIDs.map {
            MailboxScrollItem(
                id: MailboxScrollID.bundle($0),
                sectionID: .smartInboxToday
            )
        } + historicalSections.flatMap { section in
            section.messageIDs.map {
                MailboxScrollItem(
                    id: MailboxScrollID.message($0),
                    sectionID: .smartInboxHistorical(section.id)
                )
            }
        }
    }

    static func smartInboxBundle(
        _ bundle: SmartInboxDisplayBundle,
        messageIDs: [String]
    ) -> [MailboxScrollItem] {
        messageIDs.map {
            MailboxScrollItem(
                id: MailboxScrollID.message($0),
                sectionID: .smartInboxBundle(bundle)
            )
        }
    }
}
