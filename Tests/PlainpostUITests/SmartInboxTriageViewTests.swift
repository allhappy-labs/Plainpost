import SwiftUI
import XCTest
@testable import PlainpostCore
@testable import PlainpostUI
#if os(macOS)
import AppKit
#endif

final class SmartInboxTriageViewTests: XCTestCase {
    func testHighActionUsesTwoIconSignalsWithoutTextPills() {
        let signals = SmartInboxSignalSet(priority: .high, requiresAction: true)

        XCTAssertEqual(signals.items.map(\.accessibilityLabel), ["High priority", "Needs action"])
        XCTAssertTrue(signals.items.allSatisfy { $0.visibleText == nil })
        XCTAssertTrue(signals.items.allSatisfy { $0.pointSize == 11 })
        XCTAssertTrue(signals.items.allSatisfy { $0.verticalPadding == 0 })
    }

    #if os(macOS)
    func testHighActionSignalOrderUsesResolvableNativeSymbols() {
        let signals = SmartInboxSignalSet(priority: .high, requiresAction: true)

        XCTAssertEqual(
            signals.items.map(\.systemImage),
            ["exclamationmark.circle.fill", "arrowshape.turn.up.left.circle.fill"]
        )
        XCTAssertTrue(
            signals.items.allSatisfy {
                NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: nil) != nil
            }
        )
    }
    #endif

    func testNormalAndLowPriorityDoNotAddPrioritySignals() {
        XCTAssertTrue(SmartInboxSignalSet(priority: .normal, requiresAction: false).items.isEmpty)
        XCTAssertTrue(SmartInboxSignalSet(priority: .low, requiresAction: false).items.isEmpty)
        XCTAssertEqual(
            SmartInboxSignalSet(priority: .low, requiresAction: true).items.map(\.accessibilityLabel),
            ["Needs action"]
        )
    }

    @MainActor
    func testSmartRowRoutesActivationAndQuickActionsIndependently() {
        let rowModel = MessageRowModel(
            id: "newsletter-1",
            sender: "writer@example.com",
            subject: "Weekly update",
            preview: "News",
            category: .newsletter,
            categoryLabel: "Newsletter",
            isUnread: true,
            isPinned: false,
            dateLabel: "10:00",
            actions: []
        )
        var openedMessageIDs: [String] = []
        var openedLabelMessageID: String?
        var performedActions: [(InboxMailAction, String)] = []
        let row = SmartInboxTriageRow(
            row: rowModel,
            selectedMessageID: .constant(nil),
            mailActions: .preview(),
            performMessageAction: { performedActions.append(($0, $1)) },
            openLabelCommandCenter: { openedLabelMessageID = $0.id },
            openMessage: { openedMessageIDs.append($0) }
        )

        row.perform(.delete)

        XCTAssertTrue(openedMessageIDs.isEmpty)
        XCTAssertEqual(performedActions.map(\.0), [.delete])
        XCTAssertEqual(performedActions.map(\.1), ["newsletter-1"])

        row.openLabels()

        XCTAssertTrue(openedMessageIDs.isEmpty)
        XCTAssertEqual(openedLabelMessageID, "newsletter-1")
        XCTAssertEqual(performedActions.map(\.0), [.delete])

        row.select()

        XCTAssertEqual(openedMessageIDs, ["newsletter-1"])
        XCTAssertEqual(performedActions.map(\.0), [.delete])
        XCTAssertEqual(row.controlPresentation, .siblingActivationAndQuickActions)
        XCTAssertTrue(row.controlPresentation.supportsKeyboardActivation)
        XCTAssertTrue(row.controlPresentation.quickActionsAreKeyboardReachable)
        XCTAssertFalse(row.controlPresentation.hasNestedButtons)
        XCTAssertFalse(row.controlPresentation.usesParentTapGesture)
        XCTAssertTrue(row.controlPresentation.preservesNativeContextMenu)
        _ = row.body
    }

    func testPaginationAppearsOnlyAtTheEndOfTheOverview() {
        let presentation = SmartInboxTriagePaginationPresentation(
            footer: InboxPaginationFooterPresentation.make(
                hasMoreRows: true,
                isLoadingMore: false
            )
        )

        XCTAssertTrue(presentation.isVisible(activeBundle: nil))
        XCTAssertFalse(presentation.isVisible(activeBundle: .newsletters))
    }

    func testStableScrollIDsSeparateMessagesAndBundles() {
        XCTAssertEqual(MailboxScrollID.message("42"), "message-42")
        XCTAssertEqual(MailboxScrollID.bundle(.newsletters), "bundle-newsletters")
    }

    func testBundleBandMetricsKeepCompactRowAlignedWithConversationRows() {
        XCTAssertEqual(SmartInboxBundleMetrics.resolve(.wide).minimumHeight, 54)
        XCTAssertEqual(
            SmartInboxBundleMetrics.resolve(.wide).identityWidth,
            MailboxListMetrics.wide.contractedIdentityRegionWidth
        )
        XCTAssertEqual(SmartInboxBundleMetrics.resolve(.narrow).minimumHeight, 54)
        XCTAssertNil(SmartInboxBundleMetrics.resolve(.narrow).identityWidth)
    }

    func testCompactBundleKeepsStackedLayoutWithoutWideIdentityRegion() {
        let compactMetrics = SmartInboxBundleMetrics.resolve(.narrow)

        XCTAssertTrue(compactMetrics.usesStackedSummaryLayout)
        XCTAssertNil(compactMetrics.identityWidth)
    }

    func testSenderFlowUsesOneWidthDerivedWholePrefixWithoutAnArbitraryCap() {
        let summaries = (1...40).map { index in
            SmartInboxSenderSummary(
                id: "sender-\(index)",
                sender: "sender-\(index)@example.com",
                displayName: "Sender \(index)",
                messageCount: index,
                hasUnread: index.isMultiple(of: 2)
            )
        }
        let allSummariesWidth = SmartInboxSenderFlowMetrics.requiredWidth(
            summaryCount: summaries.count,
            includesOverflowIndicator: false
        )

        let allVisible = SmartInboxSenderFlowPresentation.make(
            summaries: summaries,
            availableWidth: allSummariesWidth
        )
        let constrained = SmartInboxSenderFlowPresentation.make(
            summaries: summaries,
            availableWidth: SmartInboxSenderFlowMetrics.requiredWidth(
                summaryCount: 2,
                includesOverflowIndicator: true
            )
        )

        XCTAssertEqual(allVisible.visibleSummaries.map(\.id), summaries.map(\.id))
        XCTAssertFalse(allVisible.showsOverflowIndicator)
        XCTAssertEqual(constrained.visibleSummaries.map(\.id), ["sender-1", "sender-2"])
        XCTAssertTrue(constrained.showsOverflowIndicator)
    }

    func testSenderFlowAccessibilityIncludesOnlyTheRenderedPrefix() {
        let summaries = (1...4).map { index in
            SmartInboxSenderSummary(
                id: "sender-\(index)",
                sender: "sender-\(index)@example.com",
                displayName: "Sender \(index)",
                messageCount: index,
                hasUnread: index == 1
            )
        }
        let presentation = SmartInboxSenderFlowPresentation.make(
            summaries: summaries,
            availableWidth: SmartInboxSenderFlowMetrics.requiredWidth(
                summaryCount: 2,
                includesOverflowIndicator: true
            )
        )

        XCTAssertEqual(
            presentation.accessibilityLabels,
            ["Sender 1, unread, 1 message", "Sender 2, 2 messages"]
        )
        XCTAssertFalse(
            presentation.accessibilityLabels.contains {
                $0.contains("Sender 3") || $0.contains("Sender 4")
            }
        )
    }

    func testBundleAccessibilityAnnouncesTitleCountAndUnreadStateOnce() {
        let bundle = SmartInboxTodayBundle(
            id: .notifications,
            title: "Notifications",
            systemImage: "bell.badge",
            count: 6,
            senderSummaries: [
                SmartInboxSenderSummary(
                    id: "github@example.com",
                    sender: "github@example.com",
                    displayName: "GitHub",
                    messageCount: 4,
                    hasUnread: true
                )
            ],
            hasUnread: true,
            rows: []
        )

        XCTAssertEqual(SmartInboxBundleAccessibility.label(for: bundle), "Notifications")
        XCTAssertEqual(
            SmartInboxBundleAccessibility.value(for: bundle),
            "Unread, 6 messages"
        )
        XCTAssertEqual(
            SmartInboxBundleAccessibility.value(for: bundle)
                .components(separatedBy: "6 messages")
                .count - 1,
            1
        )
    }

    @MainActor
    func testTriageViewForwardsExternallyOwnedBundleAndMessageRoutes() {
        var openedBundle: SmartInboxDisplayBundle?
        var didCloseBundle = false
        var openedMessage: (String, MailboxListContext)?
        let overview = SmartInboxTriageView(
            rows: [],
            selectedMessageID: .constant(nil),
            widthClass: .wide,
            activeBundle: nil,
            mailActions: .preview(),
            performMessageAction: { _, _ in },
            paginationPresentation: SmartInboxTriagePaginationPresentation(
                footer: InboxPaginationFooterPresentation.make(
                    hasMoreRows: false,
                    isLoadingMore: false
                )
            ),
            loadMore: {},
            openBundle: { openedBundle = $0 },
            closeBundle: { didCloseBundle = true },
            openMessage: { openedMessage = ($0, $1) }
        )

        overview.selectBundle(.newsletters)
        overview.dismissBundle()
        overview.selectMessage("overview-message")

        XCTAssertEqual(openedBundle, .newsletters)
        XCTAssertTrue(didCloseBundle)
        XCTAssertEqual(openedMessage?.0, "overview-message")
        XCTAssertEqual(openedMessage?.1, .smartInboxOverview)

        let drillIn = SmartInboxTriageView(
            rows: [],
            selectedMessageID: .constant(nil),
            widthClass: .narrow,
            activeBundle: .newsletters,
            mailActions: .preview(),
            performMessageAction: { _, _ in },
            paginationPresentation: SmartInboxTriagePaginationPresentation(
                footer: InboxPaginationFooterPresentation.make(
                    hasMoreRows: false,
                    isLoadingMore: false
                )
            ),
            loadMore: {},
            openBundle: { _ in },
            closeBundle: {},
            openMessage: { openedMessage = ($0, $1) }
        )

        drillIn.selectMessage("bundle-message")

        XCTAssertEqual(openedMessage?.0, "bundle-message")
        XCTAssertEqual(openedMessage?.1, .smartInboxBundle(.newsletters))
    }

    func testSignalLayoutReservesOneCompactSlotPerIcon() {
        XCTAssertEqual(SmartInboxSignalLayoutPresentation.spacing, 2)
        XCTAssertEqual(SmartInboxSignalLayoutPresentation.reservedWidth(itemCount: 1), 11)
        XCTAssertEqual(SmartInboxSignalLayoutPresentation.reservedWidth(itemCount: 2), 24)
    }
}
