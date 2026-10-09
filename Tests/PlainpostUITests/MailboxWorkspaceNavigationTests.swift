import XCTest
@testable import PlainpostUI

final class MailboxWorkspaceNavigationTests: XCTestCase {
    private let overview = MailboxListContext.smartInboxOverview

    @MainActor
    func testNativeSettledVisibilityOrderRestoresLeadingTargetAfterReaderBack() throws {
        let section = MailboxScrollSectionID.smartInboxToday
        let items = [
            MailboxScrollItem(id: "message-a", sectionID: section),
            MailboxScrollItem(id: "message-b", sectionID: section),
            MailboxScrollItem(id: "message-c", sectionID: section),
        ]
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(overview)
        runtime.updateOrderedItems(items)
        runtime.updateContentOffset(240)
        _ = runtime.updateVisibleIDs(
            ["message-b", "message-c"],
            using: contextToken
        )
        let request = try XCTUnwrap(
            runtime.requestSettledAnchorMeasurement(
                using: contextToken
            )
        )
        let capture = captureSettledMailboxScrollLocation(
            runtime: runtime,
            request: request,
            contextToken: contextToken,
            anchorViewportOffset: -14,
            selectedMessageID: "b"
        )
        guard case let .accepted(capturedLocation) = capture else {
            return XCTFail("Expected the current request to be accepted")
        }
        let location = try XCTUnwrap(capturedLocation)
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(location, for: overview)

        state.openReader(messageID: "b", from: overview)
        state.returnFromReader()
        state.prepareListRestoration(
            for: overview,
            availableItems: [
                .init(id: "message-inserted", sectionID: section),
                .init(id: "message-a", sectionID: section),
                .init(id: "message-b", sectionID: section),
                .init(id: "message-c", sectionID: section),
            ],
            availableMessageIDs: ["inserted", "a", "b", "c"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .anchor(
                id: "message-b",
                viewportOffset: -14,
                selectedMessageID: "b"
            )
        )
    }

    func testReaderBackRestoresExactOffsetWhenRowsAreUnchanged() {
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-b",
                anchorViewportOffset: -14,
                contentOffsetY: 240,
                orderedIDs: ["message-a", "message-b", "message-c"],
                selectedMessageID: "b"
            ),
            for: overview
        )

        state.openReader(messageID: "b", from: overview)
        state.returnFromReader()
        state.prepareListRestoration(
            for: overview,
            availableScrollIDs: ["message-a", "message-b", "message-c"],
            availableMessageIDs: ["a", "b", "c"]
        )

        XCTAssertEqual(state.route, .list(overview))
        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .exact(contentOffsetY: 240, selectedMessageID: "b")
        )
    }

    func testReaderBackReturnsToTheBundleThatOpenedTheConversation() {
        let bundle = MailboxListContext.smartInboxBundle(.newsletters)
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.showList(bundle)
        state.openReader(messageID: "newsletter-message", from: bundle)

        state.returnFromReader()

        XCTAssertEqual(state.route, .list(bundle))
    }

    func testReaderBackUsesNearestSurvivingNeighborWhenAnchorDisappears() {
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-b",
                anchorViewportOffset: -12,
                contentOffsetY: 220,
                orderedIDs: ["message-a", "message-b", "message-c"],
                selectedMessageID: "b"
            ),
            for: overview
        )

        state.openReader(messageID: "b", from: overview)
        state.returnFromReader()
        state.prepareListRestoration(
            for: overview,
            availableScrollIDs: ["message-a", "message-c"],
            availableMessageIDs: ["a", "c"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .anchor(id: "message-c", viewportOffset: -12, selectedMessageID: nil)
        )
    }

    func testReaderBackUsesMountedUnreadListAfterSelectedRowStopsMatchingFilter() {
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-b",
                anchorViewportOffset: -11,
                contentOffsetY: 210,
                orderedIDs: ["message-a", "message-b", "message-c"],
                selectedMessageID: "b"
            ),
            for: overview
        )

        state.openReader(messageID: "b", from: overview)
        state.returnFromReader()
        state.prepareListRestoration(
            for: overview,
            availableScrollIDs: ["message-a", "message-c"],
            availableMessageIDs: ["a", "c"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .anchor(id: "message-c", viewportOffset: -11, selectedMessageID: nil)
        )
    }

    func testReaderBackUsesMountedOrderAfterRowInsertionAndRetainsSelection() {
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-b",
                anchorViewportOffset: -8,
                contentOffsetY: 190,
                orderedIDs: ["message-a", "message-b", "message-c"],
                selectedMessageID: "b"
            ),
            for: overview
        )

        state.openReader(messageID: "b", from: overview)
        state.returnFromReader()
        state.prepareListRestoration(
            for: overview,
            availableScrollIDs: [
                "message-new",
                "message-a",
                "message-b",
                "message-c",
            ],
            availableMessageIDs: ["new", "a", "b", "c"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .anchor(id: "message-b", viewportOffset: -8, selectedMessageID: "b")
        )
    }

    func testRemovedLastHistoricalRowPrefersPredecessorFromSameSection() {
        let yesterday = MailboxScrollSectionID.smartInboxHistorical(.yesterday)
        let thisWeek = MailboxScrollSectionID.smartInboxHistorical(.thisWeek)
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-yesterday-last",
                anchorViewportOffset: -7,
                contentOffsetY: 320,
                orderedItems: [
                    .init(id: "message-yesterday-first", sectionID: yesterday),
                    .init(id: "message-yesterday-last", sectionID: yesterday),
                    .init(id: "message-this-week-first", sectionID: thisWeek),
                    .init(id: "message-this-week-selected", sectionID: thisWeek),
                ],
                selectedMessageID: "this-week-selected"
            ),
            for: overview
        )

        state.prepareRefreshRestoration(
            for: overview,
            availableItems: [
                .init(id: "message-yesterday-first", sectionID: yesterday),
                .init(id: "message-this-week-first", sectionID: thisWeek),
                .init(id: "message-this-week-selected", sectionID: thisWeek),
            ],
            availableMessageIDs: [
                "yesterday-first",
                "this-week-first",
                "this-week-selected",
            ]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .anchor(
                id: "message-yesterday-first",
                viewportOffset: -7,
                selectedMessageID: "this-week-selected"
            )
        )
    }

    func testSmartBundleRestorationSurvivesInsertedAndRemovedRows() {
        let context = MailboxListContext.smartInboxBundle(.newsletters)
        let section = MailboxScrollSectionID.smartInboxBundle(.newsletters)
        var state = MailboxWorkspaceNavigationState(initialContext: context)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-middle",
                anchorViewportOffset: -5,
                contentOffsetY: 180,
                orderedItems: [
                    .init(id: "message-first", sectionID: section),
                    .init(id: "message-middle", sectionID: section),
                    .init(id: "message-selected", sectionID: section),
                ],
                selectedMessageID: "selected"
            ),
            for: context
        )

        state.prepareRefreshRestoration(
            for: context,
            availableItems: [
                .init(id: "message-inserted", sectionID: section),
                .init(id: "message-first", sectionID: section),
                .init(id: "message-selected", sectionID: section),
            ],
            availableMessageIDs: ["inserted", "first", "selected"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: context),
            .anchor(
                id: "message-selected",
                viewportOffset: -5,
                selectedMessageID: "selected"
            )
        )
    }

    func testSameSectionRestorationRejectsNeighborThatMovedSections() {
        let yesterday = MailboxScrollSectionID.smartInboxHistorical(.yesterday)
        let thisWeek = MailboxScrollSectionID.smartInboxHistorical(.thisWeek)
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-anchor",
                anchorViewportOffset: -6,
                contentOffsetY: 240,
                orderedItems: [
                    .init(id: "message-anchor", sectionID: yesterday),
                    .init(id: "message-moved", sectionID: yesterday),
                    .init(id: "message-current-neighbor", sectionID: yesterday),
                ],
                selectedMessageID: nil
            ),
            for: overview
        )

        state.prepareRefreshRestoration(
            for: overview,
            availableItems: [
                .init(id: "message-moved", sectionID: thisWeek),
                .init(id: "message-current-neighbor", sectionID: yesterday),
            ],
            availableMessageIDs: ["moved", "current-neighbor"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .anchor(
                id: "message-current-neighbor",
                viewportOffset: -6,
                selectedMessageID: nil
            )
        )
    }

    func testLocationsRemainIndependentAcrossMailboxAndBundleContexts() {
        let simple = MailboxListContext.mailbox(
            destination: .allInboxes,
            mode: .simpleList
        )
        let newsletters = MailboxListContext.smartInboxBundle(.newsletters)
        var state = MailboxWorkspaceNavigationState(initialContext: simple)

        state.save(.fixture(anchorID: "all-1", y: 100), for: simple)
        state.save(.fixture(anchorID: "news-1", y: 400), for: newsletters)

        XCTAssertEqual(state.location(for: simple).contentOffsetY, 100)
        XCTAssertEqual(state.location(for: newsletters).contentOffsetY, 400)
    }

    func testSmartInboxOverviewAndBundleMaintainIndependentLocations() {
        let newsletters = MailboxListContext.smartInboxBundle(.newsletters)
        var state = MailboxWorkspaceNavigationState(initialContext: overview)

        state.save(
            .fixture(anchorID: "message-overview", y: 120),
            for: overview
        )
        state.showList(newsletters)
        state.save(
            .fixture(anchorID: "message-newsletter", y: 460),
            for: newsletters
        )
        state.showList(overview)
        state.prepareListRestoration(
            for: overview,
            availableScrollIDs: ["message-overview"],
            availableMessageIDs: ["overview"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .exact(contentOffsetY: 120, selectedMessageID: nil)
        )
        XCTAssertEqual(
            state.location(for: newsletters).contentOffsetY,
            460
        )
    }

    func testDisplayModesRemainIndependentByMailboxDestination() {
        var state = MailboxWorkspaceNavigationState(
            initialContext: .smartInboxOverview
        )

        state.remember(.simpleList, for: .allInboxes)
        state.remember(.unreadCards, for: .newsletters)

        XCTAssertEqual(
            state.rememberedMode(for: .allInboxes, fallback: .focusedList),
            .simpleList
        )
        XCTAssertEqual(
            state.rememberedMode(for: .newsletters, fallback: .focusedList),
            .unreadCards
        )
        XCTAssertEqual(
            state.rememberedMode(for: .archive, fallback: .focusedList),
            .focusedList
        )
    }

    func testReturningToPriorMailboxQueuesItsSavedLocation() {
        let all = MailboxListContext.mailbox(
            destination: .allInboxes,
            mode: .simpleList
        )
        var state = MailboxWorkspaceNavigationState(initialContext: all)
        state.save(.fixture(anchorID: "message-a", y: 180), for: all)

        state.showList(.smartInboxOverview)
        state.showList(all)
        state.prepareListRestoration(
            for: all,
            availableScrollIDs: ["message-a"],
            availableMessageIDs: ["a"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: all),
            .exact(contentOffsetY: 180, selectedMessageID: nil)
        )
    }

    func testVisibleListRefreshUsesNearestSurvivingAnchor() {
        var state = MailboxWorkspaceNavigationState(initialContext: overview)
        state.save(
            MailboxScrollLocation(
                anchorID: "message-b",
                anchorViewportOffset: -9,
                contentOffsetY: 160,
                orderedIDs: ["message-a", "message-b", "message-c"],
                selectedMessageID: "b"
            ),
            for: overview
        )

        state.prepareRefreshRestoration(
            for: overview,
            availableScrollIDs: ["message-a", "message-c"],
            availableMessageIDs: ["a", "c"]
        )

        XCTAssertEqual(
            state.consumeRestoration(for: overview),
            .anchor(id: "message-c", viewportOffset: -9, selectedMessageID: nil)
        )
    }

    @MainActor
    func testDisplayModeSetterCapturesActiveScrollBeforeMutation() throws {
        let runtime = activeScrollRuntime()
        var mode = InboxDisplayMode.focusedList.rawValue
        var events: [String] = []
        var capturedLocation: MailboxScrollLocation?

        MailboxNavigationBoundarySetter.setDisplayMode(
            from: mode,
            to: InboxDisplayMode.simpleList.rawValue,
            runtime: runtime,
            selectedMessageID: "c",
            capture: { location in
                events.append("capture-\(mode)")
                capturedLocation = location
            },
            assign: { newMode in
                events.append("assign-\(newMode)")
                mode = newMode
            }
        )

        XCTAssertEqual(
            events,
            ["capture-focused_list", "assign-simple_list"]
        )
        XCTAssertEqual(mode, InboxDisplayMode.simpleList.rawValue)
        let location = try XCTUnwrap(capturedLocation)
        XCTAssertEqual(location.anchorID, "message-c")
        XCTAssertEqual(location.contentOffsetY, 612)
        XCTAssertEqual(location.selectedMessageID, "c")
    }

    @MainActor
    func testSidebarDestinationSetterCapturesActiveScrollBeforeMutation() throws {
        let runtime = activeScrollRuntime()
        var destination = PlainpostDestination.smartInbox
        var events: [String] = []
        var capturedLocation: MailboxScrollLocation?

        MailboxNavigationBoundarySetter.setDestination(
            from: destination,
            to: .archive,
            runtime: runtime,
            selectedMessageID: "c",
            capture: { location in
                events.append("capture-\(destination.rawValue)")
                capturedLocation = location
            },
            assign: { newDestination in
                events.append("assign-\(newDestination.rawValue)")
                destination = newDestination
            }
        )

        XCTAssertEqual(
            events,
            ["capture-smartInbox", "assign-archive"]
        )
        XCTAssertEqual(destination, .archive)
        let location = try XCTUnwrap(capturedLocation)
        XCTAssertEqual(location.anchorID, "message-c")
        XCTAssertEqual(location.contentOffsetY, 612)
        XCTAssertEqual(location.selectedMessageID, "c")
    }

    @MainActor
    func testProgrammaticDestinationAndModeSetterCapturesBeforeEitherMutation() throws {
        let runtime = activeScrollRuntime()
        var destination = PlainpostDestination.smartInbox
        var mode = InboxDisplayMode.focusedList.rawValue
        var events: [String] = []
        var capturedLocation: MailboxScrollLocation?

        MailboxNavigationBoundarySetter.setDestinationAndDisplayMode(
            from: destination,
            currentDisplayMode: mode,
            to: .drafts,
            displayMode: InboxDisplayMode.simpleList.rawValue,
            runtime: runtime,
            selectedMessageID: "c",
            capture: { location in
                events.append(
                    "capture-\(destination.rawValue)-\(mode)"
                )
                capturedLocation = location
            },
            assign: { newDestination, newMode in
                events.append(
                    "assign-\(newDestination.rawValue)-\(newMode)"
                )
                destination = newDestination
                mode = newMode
            }
        )

        XCTAssertEqual(
            events,
            [
                "capture-smartInbox-focused_list",
                "assign-drafts-simple_list",
            ]
        )
        XCTAssertEqual(destination, .drafts)
        XCTAssertEqual(mode, InboxDisplayMode.simpleList.rawValue)
        let location = try XCTUnwrap(capturedLocation)
        XCTAssertEqual(location.anchorID, "message-c")
        XCTAssertEqual(location.contentOffsetY, 612)
        XCTAssertEqual(location.selectedMessageID, "c")
    }

    @MainActor
    private func activeScrollRuntime() -> MailboxScrollRuntime {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems([
            .init(id: "message-a", sectionID: .smartInboxToday),
            .init(id: "message-b", sectionID: .smartInboxToday),
            .init(id: "message-c", sectionID: .smartInboxToday),
        ])
        runtime.updateVisibleIDs(["message-b", "message-c"])
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(-7, for: "message-b")
        _ = runtime.capture(reason: .scrollSettled)

        runtime.updateVisibleIDs(["message-c"])
        runtime.updateContentOffset(612)
        return runtime
    }
}

private extension MailboxScrollLocation {
    static func fixture(anchorID: String, y: Double) -> Self {
        Self(
            anchorID: anchorID,
            anchorViewportOffset: 0,
            contentOffsetY: y,
            orderedIDs: [anchorID],
            selectedMessageID: nil
        )
    }
}
