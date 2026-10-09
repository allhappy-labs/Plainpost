import XCTest
#if os(macOS)
import AppKit
#endif
@testable import PlainpostUI

final class MailboxScrollRuntimeTests: XCTestCase {
#if os(macOS)
    @MainActor
    func testNativeScrollRestorationWaitsForTheMountedScrollView() {
        let runtime = MailboxNativeScrollViewRuntime()
        let scrollRuntime = MailboxScrollRuntime()
        let staleToken = scrollRuntime.installScrollContext(.smartInboxOverview)
        let mountedToken = scrollRuntime.installScrollContext(.smartInboxOverview)
        let scrollView = NSScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        let documentView = FlippedMailboxDocumentView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 3_000)
        )
        scrollView.documentView = documentView

        runtime.restore(to: 640, using: mountedToken)

        XCTAssertTrue(runtime.hasPendingRestoration)

        runtime.install(scrollView, using: staleToken)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)
        XCTAssertTrue(runtime.hasPendingRestoration)

        runtime.install(scrollView, using: mountedToken)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 640)
        XCTAssertFalse(runtime.hasPendingRestoration)
    }
#endif

    @MainActor
    func testContinuousOffsetUpdatesDoNotRequestPersistence() {
        let runtime = MailboxScrollRuntime()

        for offset in 0..<10_000 {
            runtime.updateContentOffset(Double(offset))
        }

        XCTAssertEqual(runtime.persistenceRequestCount, 0)
    }

    @MainActor
    func testSettledScrollCapturesStableAnchorAndOffset() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b", "message-c"])
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(7, for: "message-b")

        let capture = runtime.capture(
            reason: .scrollSettled,
            selectedMessageID: "b"
        )

        XCTAssertEqual(capture?.anchorID, "message-b")
        XCTAssertEqual(capture?.anchorViewportOffset, 7)
        XCTAssertEqual(capture?.contentOffsetY, 420)
        XCTAssertEqual(capture?.selectedMessageID, "b")
    }

    @MainActor
    func testNavigationBoundaryCapturesLastStableLocation() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b"])
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(7, for: "message-b")

        XCTAssertNotNil(runtime.capture(reason: .navigationBoundary))
    }

    @MainActor
    func testNavigationBoundaryEmitsAfterUnchangedSettledCapture() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b"])
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(7, for: "message-b")

        let settled = runtime.capture(reason: .scrollSettled)
        let boundary = runtime.capture(reason: .navigationBoundary)

        XCTAssertEqual(boundary, settled)
        XCTAssertEqual(runtime.persistenceRequestCount, 2)
    }

    @MainActor
    func testVisibilityChangesAloneDoNotRequestPersistence() {
        let runtime = MailboxScrollRuntime()

        XCTAssertTrue(runtime.updateVisibleIDs(["message-a", "message-b"]))

        XCTAssertEqual(runtime.persistenceRequestCount, 0)
        XCTAssertNil(runtime.capture(reason: .visibilityChanged))
    }

    @MainActor
    func testOnlyLeadingVisibleTargetBecomesActiveAnchor() {
        let runtime = MailboxScrollRuntime()

        XCTAssertTrue(runtime.updateVisibleIDs(["message-b", "message-c"]))
        runtime.updateAnchorViewportOffset(4, for: "message-c")
        runtime.updateAnchorViewportOffset(7, for: "message-b")

        XCTAssertEqual(runtime.topVisibleID, "message-b")
        XCTAssertEqual(runtime.anchorViewportOffset, 7)
    }

    @MainActor
    func testAnchorMeasurementForStaleIDIsIgnored() {
        let runtime = MailboxScrollRuntime()
        runtime.updateVisibleIDs(["message-b"])
        runtime.updateAnchorViewportOffset(7, for: "message-b")
        runtime.updateVisibleIDs(["message-c"])
        runtime.updateAnchorViewportOffset(13, for: "message-b")

        XCTAssertEqual(runtime.topVisibleID, "message-c")
        XCTAssertEqual(runtime.anchorViewportOffset, 0)
    }

    @MainActor
    func testCaptureRetainsOrderedMessageIDsAndSectionIdentities() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b"])

        let capture = runtime.capture(reason: .scrollSettled)

        XCTAssertEqual(runtime.orderedMessageIDs, ["a", "b", "c"])
        XCTAssertEqual(capture?.orderedItems, Self.items)
    }

    @MainActor
    func testOrderRefreshRemovingCurrentTopInvalidatesAnchorBeforeCapture() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b"])
        runtime.updateAnchorViewportOffset(7, for: "message-b")

        let refreshedItems = Self.items.filter { $0.id != "message-b" }
        runtime.updateOrderedItems(refreshedItems)
        let capture = runtime.capture(reason: .scrollSettled)

        XCTAssertNil(runtime.topVisibleID)
        XCTAssertEqual(runtime.anchorViewportOffset, 0)
        XCTAssertNil(capture?.anchorID)
        XCTAssertEqual(capture?.orderedItems, refreshedItems)
        XCTAssertEqual(runtime.orderedMessageIDs, ["a", "c"])
    }

    @MainActor
    func testAppendWhileActivelyScrollingPreservesLivePositionWithoutRestoration() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b", "message-c"])
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(7, for: "message-b")
        XCTAssertNotNil(runtime.capture(reason: .scrollSettled))

        runtime.updateVisibleIDs(["message-c"])
        runtime.updateContentOffset(680)
        let appendedItems = Self.items + [
            MailboxScrollItem(
                id: "message-d",
                sectionID: .smartInboxBundle(.people)
            )
        ]

        let plan = runtime.orderedItemsUpdatePlan(to: appendedItems)
        XCTAssertEqual(plan.update, .appendOnly)
        XCTAssertFalse(plan.capturesCurrentLocation)
        XCTAssertFalse(plan.requestsRestoration)

        runtime.updateOrderedItems(appendedItems)

        XCTAssertEqual(runtime.contentOffsetY, 680)
        XCTAssertEqual(runtime.topVisibleID, "message-c")
        XCTAssertEqual(runtime.persistenceRequestCount, 1)
    }

    @MainActor
    func testActiveScrollDisruptiveUpdateDefersRestorationUntilSettledMeasurement()
        throws
    {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        _ = runtime.updateVisibleIDs(
            ["message-b", "message-c"],
            using: contextToken
        )
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(-7, for: "message-b")
        XCTAssertNotNil(runtime.capture(reason: .scrollSettled))

        XCTAssertTrue(
            runtime.updateScrollActivity(.active, using: contextToken)
        )
        _ = runtime.updateVisibleIDs(
            ["message-c"],
            using: contextToken
        )
        runtime.updateContentOffset(680)
        let disruptiveItems = [
            MailboxScrollItem(
                id: "message-inserted",
                sectionID: .smartInboxToday
            )
        ] + Self.items

        let plan = runtime.orderedItemsUpdatePlan(to: disruptiveItems)
        XCTAssertEqual(plan.update, .disruptive)
        XCTAssertFalse(plan.capturesCurrentLocation)
        XCTAssertFalse(plan.requestsRestoration)

        XCTAssertNil(
            runtime.applyOrderedItemsUpdate(
                disruptiveItems,
                plan: plan,
                using: contextToken
            )
        )
        XCTAssertTrue(runtime.hasPendingSettledAnchorMeasurement)
        XCTAssertEqual(runtime.contentOffsetY, 680)
        XCTAssertEqual(runtime.topVisibleID, "message-c")
        XCTAssertEqual(runtime.persistenceRequestCount, 1)

        XCTAssertTrue(
            runtime.updateScrollActivity(.idle, using: contextToken)
        )
        let request = try XCTUnwrap(
            runtime.requestSettledAnchorMeasurement(
                using: contextToken
            )
        )
        XCTAssertEqual(request.anchorID, "message-c")
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                request,
                using: contextToken,
                anchorViewportOffset: -11
            )
        )
        XCTAssertFalse(runtime.hasPendingSettledAnchorMeasurement)
        let settled = runtime.capture(reason: .scrollSettled)

        XCTAssertEqual(settled?.anchorID, "message-c")
        XCTAssertEqual(settled?.anchorViewportOffset, -11)
        XCTAssertEqual(settled?.contentOffsetY, 680)
        XCTAssertEqual(settled?.orderedItems, disruptiveItems)
        XCTAssertEqual(runtime.persistenceRequestCount, 2)
    }

    @MainActor
    func testActiveScrollRemovalOfLiveAnchorDefersToNewSettledAnchor()
        throws
    {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        _ = runtime.updateVisibleIDs(
            ["message-b", "message-c"],
            using: contextToken
        )
        runtime.updateAnchorViewportOffset(-7, for: "message-b")

        XCTAssertTrue(
            runtime.updateScrollActivity(.active, using: contextToken)
        )
        _ = runtime.updateVisibleIDs(
            ["message-c"],
            using: contextToken
        )
        runtime.updateContentOffset(680)
        let removedAnchorItems = Self.items.filter {
            $0.id != "message-c"
        }

        let plan = runtime.orderedItemsUpdatePlan(
            to: removedAnchorItems
        )
        XCTAssertEqual(plan.update, .disruptive)
        XCTAssertFalse(plan.capturesCurrentLocation)
        XCTAssertFalse(plan.requestsRestoration)

        XCTAssertNil(
            runtime.applyOrderedItemsUpdate(
                removedAnchorItems,
                plan: plan,
                using: contextToken
            )
        )
        XCTAssertTrue(runtime.hasPendingSettledAnchorMeasurement)
        XCTAssertNil(runtime.topVisibleID)
        XCTAssertEqual(runtime.contentOffsetY, 680)
        XCTAssertEqual(runtime.persistenceRequestCount, 0)

        XCTAssertTrue(
            runtime.updateScrollActivity(.idle, using: contextToken)
        )
        XCTAssertNil(
            runtime.requestSettledAnchorMeasurement(
                using: contextToken
            )
        )
        let update = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: contextToken
            )
        )
        let request = try XCTUnwrap(update.measurementRequest)
        XCTAssertEqual(request.anchorID, "message-b")
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                request,
                using: contextToken,
                anchorViewportOffset: -5
            )
        )
        XCTAssertFalse(runtime.hasPendingSettledAnchorMeasurement)
        let settled = runtime.capture(reason: .scrollSettled)

        XCTAssertEqual(settled?.anchorID, "message-b")
        XCTAssertEqual(settled?.anchorViewportOffset, -5)
        XCTAssertEqual(settled?.contentOffsetY, 680)
        XCTAssertEqual(settled?.orderedItems, removedAnchorItems)
    }

    @MainActor
    func testSettledDisruptiveUpdateCapturesBeforeRequestingRestoration() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b", "message-c"])
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(-7, for: "message-b")

        let plan = runtime.orderedItemsUpdatePlan(
            to: Array(Self.items.dropFirst())
        )

        XCTAssertEqual(plan.update, .disruptive)
        XCTAssertTrue(plan.capturesCurrentLocation)
        XCTAssertTrue(plan.requestsRestoration)
    }

    @MainActor
    func testIdleUnmeasuredPrependSchedulesImmediatePostUpdateMeasurement()
        throws
    {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        _ = runtime.updateVisibleIDs(
            ["message-b", "message-c"],
            using: contextToken
        )
        runtime.updateAnchorViewportOffset(-7, for: "message-b")
        _ = runtime.updateVisibleIDs(
            ["message-c"],
            using: contextToken
        )
        let prependedItems = [
            MailboxScrollItem(
                id: "message-inserted",
                sectionID: .smartInboxToday
            )
        ] + Self.items

        let plan = runtime.orderedItemsUpdatePlan(to: prependedItems)
        XCTAssertEqual(plan.resolution, .deferUntilSettled)

        let request = try XCTUnwrap(
            runtime.applyOrderedItemsUpdate(
                prependedItems,
                plan: plan,
                using: contextToken
            )
        )

        XCTAssertEqual(request.anchorID, "message-c")
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                request,
                using: contextToken,
                anchorViewportOffset: -11
            )
        )
        XCTAssertFalse(runtime.hasPendingSettledAnchorMeasurement)
        XCTAssertEqual(runtime.persistenceRequestCount, 0)
    }

    @MainActor
    func testIdleUnmeasuredRemovalSchedulesMeasurementWhenNewAnchorArrives()
        throws
    {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        _ = runtime.updateVisibleIDs(
            ["message-b", "message-c"],
            using: contextToken
        )
        runtime.updateAnchorViewportOffset(-7, for: "message-b")
        _ = runtime.updateVisibleIDs(
            ["message-c"],
            using: contextToken
        )
        let removedAnchorItems = Self.items.filter {
            $0.id != "message-c"
        }

        let plan = runtime.orderedItemsUpdatePlan(to: removedAnchorItems)
        XCTAssertEqual(plan.resolution, .deferUntilSettled)
        XCTAssertNil(
            runtime.applyOrderedItemsUpdate(
                removedAnchorItems,
                plan: plan,
                using: contextToken
            )
        )
        XCTAssertNil(runtime.topVisibleID)

        let update = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: contextToken
            )
        )
        let request = try XCTUnwrap(update.measurementRequest)
        XCTAssertEqual(request.anchorID, "message-b")
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                request,
                using: contextToken,
                anchorViewportOffset: -5
            )
        )
        XCTAssertFalse(runtime.hasPendingSettledAnchorMeasurement)
        XCTAssertEqual(runtime.persistenceRequestCount, 0)
    }

    @MainActor
    func testSameIDStaleFrameCannotCompleteDisruptiveRearm() throws {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        let preUpdate = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: contextToken
            )
        )
        let preUpdateRequest = try XCTUnwrap(
            preUpdate.measurementRequest
        )
        let prependedItems = [
            MailboxScrollItem(
                id: "message-inserted",
                sectionID: .smartInboxToday
            )
        ] + Self.items
        let plan = runtime.orderedItemsUpdatePlan(to: prependedItems)

        let postUpdateRequest = try XCTUnwrap(
            runtime.applyOrderedItemsUpdate(
                prependedItems,
                plan: plan,
                using: contextToken
            )
        )

        XCTAssertEqual(preUpdateRequest.anchorID, "message-b")
        XCTAssertEqual(postUpdateRequest.anchorID, "message-b")
        XCTAssertNotEqual(preUpdateRequest.token, postUpdateRequest.token)

        let staleResult = captureSettledMailboxScrollLocation(
            runtime: runtime,
            request: preUpdateRequest,
            contextToken: contextToken,
            anchorViewportOffset: -29,
            selectedMessageID: "b"
        )
        guard case let .rejected(maybeReplacementRequest) = staleResult else {
            return XCTFail("Expected the pre-update request to be rejected")
        }
        let replacementRequest = try XCTUnwrap(maybeReplacementRequest)

        XCTAssertEqual(replacementRequest.anchorID, "message-b")
        XCTAssertEqual(replacementRequest, postUpdateRequest)
        XCTAssertEqual(runtime.anchorViewportOffset, 0)
        XCTAssertEqual(runtime.persistenceRequestCount, 0)

        let currentResult = captureSettledMailboxScrollLocation(
            runtime: runtime,
            request: replacementRequest,
            contextToken: contextToken,
            anchorViewportOffset: -7,
            selectedMessageID: "b"
        )
        guard case let .accepted(location) = currentResult else {
            return XCTFail("Expected the replacement request to be accepted")
        }

        XCTAssertEqual(location?.anchorID, "message-b")
        XCTAssertEqual(location?.anchorViewportOffset, -7)
        XCTAssertEqual(runtime.persistenceRequestCount, 1)
    }

    @MainActor
    func testCanceledContextRequestCannotCompleteSameIDInNewContext() throws {
        let originalContext = MailboxListContext.smartInboxOverview
        let replacementContext = MailboxListContext.mailbox(
            destination: .drafts,
            mode: .simpleList
        )
        let runtime = MailboxScrollRuntime()
        let originalContextToken = runtime.installScrollContext(
            originalContext
        )
        runtime.updateOrderedItems(Self.items)
        let originalUpdate = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: originalContextToken
            )
        )
        let originalRequest = try XCTUnwrap(
            originalUpdate.measurementRequest
        )

        let replacementContextToken = runtime.installScrollContext(
            replacementContext
        )
        let replacementUpdate = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: replacementContextToken
            )
        )
        let replacementRequest = try XCTUnwrap(
            replacementUpdate.measurementRequest
        )

        XCTAssertEqual(originalRequest.anchorID, replacementRequest.anchorID)
        XCTAssertNotEqual(originalRequest.token, replacementRequest.token)
        XCTAssertNotEqual(originalRequest.context, replacementRequest.context)

        let staleResult = captureSettledMailboxScrollLocation(
            runtime: runtime,
            request: originalRequest,
            contextToken: originalContextToken,
            anchorViewportOffset: -31,
            selectedMessageID: "b"
        )
        guard case let .rejected(maybeCurrentRequest) = staleResult else {
            return XCTFail("Expected the canceled context request to be rejected")
        }
        let currentRequest = try XCTUnwrap(maybeCurrentRequest)

        XCTAssertEqual(currentRequest.anchorID, "message-b")
        XCTAssertEqual(currentRequest.context, replacementContext)
        XCTAssertEqual(currentRequest, replacementRequest)
        XCTAssertEqual(runtime.measurementContext, replacementContext)
        XCTAssertEqual(runtime.anchorViewportOffset, 0)
        XCTAssertEqual(runtime.persistenceRequestCount, 0)
    }

    @MainActor
    func testOrdinaryIdleRequestRearmsFromAToBAndRejectsStaleA() throws {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        let updateA = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-a"],
                using: contextToken
            )
        )
        let requestA = try XCTUnwrap(updateA.measurementRequest)

        let updateB = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: contextToken
            )
        )
        let requestB = try XCTUnwrap(updateB.measurementRequest)

        XCTAssertEqual(requestA.anchorID, "message-a")
        XCTAssertEqual(requestB.anchorID, "message-b")
        XCTAssertNotEqual(requestA.token, requestB.token)

        let staleResult = captureSettledMailboxScrollLocation(
            runtime: runtime,
            request: requestA,
            contextToken: contextToken,
            anchorViewportOffset: -23,
            selectedMessageID: "b"
        )
        guard case let .rejected(maybeReplacementRequest) = staleResult else {
            return XCTFail("Expected stale A to be rejected")
        }
        let replacementRequest = try XCTUnwrap(maybeReplacementRequest)

        XCTAssertEqual(replacementRequest.anchorID, "message-b")
        XCTAssertEqual(replacementRequest, requestB)
        XCTAssertEqual(runtime.anchorViewportOffset, 0)
        XCTAssertEqual(runtime.persistenceRequestCount, 0)

        let currentResult = captureSettledMailboxScrollLocation(
            runtime: runtime,
            request: replacementRequest,
            contextToken: contextToken,
            anchorViewportOffset: -5,
            selectedMessageID: "b"
        )
        guard case let .accepted(location) = currentResult else {
            return XCTFail("Expected B to be captured")
        }

        XCTAssertEqual(location?.anchorID, "message-b")
        XCTAssertEqual(location?.anchorViewportOffset, -5)
        XCTAssertEqual(runtime.persistenceRequestCount, 1)
    }

    @MainActor
    func testAcceptedAToIdleTopBRequiresFreshMeasurement() throws {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        let updateA = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-a"],
                using: contextToken
            )
        )
        let requestA = try XCTUnwrap(updateA.measurementRequest)
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                requestA,
                using: contextToken,
                anchorViewportOffset: -3
            )
        )
        XCTAssertFalse(runtime.hasPendingSettledAnchorMeasurement)

        let updateB = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: contextToken
            )
        )
        let requestB = try XCTUnwrap(updateB.measurementRequest)

        XCTAssertEqual(requestB.anchorID, "message-b")
        XCTAssertNotEqual(requestB.token, requestA.token)
        XCTAssertTrue(runtime.hasPendingSettledAnchorMeasurement)
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                requestB,
                using: contextToken,
                anchorViewportOffset: -5
            )
        )
        XCTAssertEqual(runtime.anchorViewportOffset, -5)
        XCTAssertFalse(runtime.hasPendingSettledAnchorMeasurement)
    }

    @MainActor
    func testQueuedStaleGenerationsReuseAuthoritativeCurrentRequest() throws {
        let context = MailboxListContext.smartInboxOverview
        let runtime = MailboxScrollRuntime()
        let contextToken = runtime.installScrollContext(context)
        runtime.updateOrderedItems(Self.items)
        let oldestUpdate = try XCTUnwrap(
            runtime.updateVisibleIDs(
                ["message-b"],
                using: contextToken
            )
        )
        let oldestRequest = try XCTUnwrap(
            oldestUpdate.measurementRequest
        )
        let newerStaleRequest = try XCTUnwrap(
            runtime.requestSettledAnchorMeasurement(
                using: contextToken
            )
        )
        let currentRequest = try XCTUnwrap(
            runtime.requestSettledAnchorMeasurement(
                using: contextToken
            )
        )

        for staleRequest in [oldestRequest, newerStaleRequest] {
            let result = captureSettledMailboxScrollLocation(
                runtime: runtime,
                request: staleRequest,
                contextToken: contextToken,
                anchorViewportOffset: -27,
                selectedMessageID: "b"
            )
            guard case let .rejected(maybeReplacementRequest) = result else {
                return XCTFail("Expected queued stale request to be rejected")
            }
            XCTAssertEqual(maybeReplacementRequest, currentRequest)
            XCTAssertEqual(
                runtime.settledAnchorMeasurementRequest,
                currentRequest
            )
        }

        let accepted = captureSettledMailboxScrollLocation(
            runtime: runtime,
            request: currentRequest,
            contextToken: contextToken,
            anchorViewportOffset: -7,
            selectedMessageID: "b"
        )
        guard case let .accepted(location) = accepted else {
            return XCTFail("Expected authoritative request to remain valid")
        }
        XCTAssertEqual(location?.anchorViewportOffset, -7)
        XCTAssertEqual(runtime.persistenceRequestCount, 1)
    }

    @MainActor
    func testInstalledBRejectsStaleAVisibilityCallback() throws {
        let contextA = MailboxListContext.smartInboxOverview
        let contextB = MailboxListContext.mailbox(
            destination: .drafts,
            mode: .simpleList
        )
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        let tokenA = runtime.installScrollContext(contextA)
        _ = try XCTUnwrap(
            runtime.updateVisibleIDs(["message-a"], using: tokenA)
        )
        let tokenB = runtime.installScrollContext(contextB)
        let updateB = try XCTUnwrap(
            runtime.updateVisibleIDs(["message-b"], using: tokenB)
        )
        let requestB = try XCTUnwrap(updateB.measurementRequest)

        XCTAssertNil(
            runtime.updateVisibleIDs(["message-c"], using: tokenA)
        )

        XCTAssertEqual(runtime.measurementContext, contextB)
        XCTAssertEqual(runtime.topVisibleID, "message-b")
        XCTAssertEqual(runtime.scrollActivity, .idle)
        XCTAssertEqual(
            runtime.settledAnchorMeasurementRequest,
            requestB
        )
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                requestB,
                using: tokenB,
                anchorViewportOffset: -5
            )
        )
        XCTAssertEqual(
            runtime.capture(reason: .scrollSettled)?.anchorID,
            "message-b"
        )
    }

    @MainActor
    func testInstalledBRejectsStaleAActiveAndIdlePhaseCallbacks() throws {
        let contextA = MailboxListContext.smartInboxOverview
        let contextB = MailboxListContext.mailbox(
            destination: .drafts,
            mode: .simpleList
        )
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        let tokenA = runtime.installScrollContext(contextA)
        let tokenB = runtime.installScrollContext(contextB)
        let updateB = try XCTUnwrap(
            runtime.updateVisibleIDs(["message-b"], using: tokenB)
        )
        let requestB = try XCTUnwrap(updateB.measurementRequest)

        XCTAssertFalse(
            runtime.updateScrollActivity(.active, using: tokenA)
        )
        XCTAssertFalse(
            runtime.updateScrollActivity(.idle, using: tokenA)
        )

        XCTAssertEqual(runtime.measurementContext, contextB)
        XCTAssertEqual(runtime.topVisibleID, "message-b")
        XCTAssertEqual(runtime.scrollActivity, .idle)
        XCTAssertEqual(
            runtime.settledAnchorMeasurementRequest,
            requestB
        )
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                requestB,
                using: tokenB,
                anchorViewportOffset: -7
            )
        )
    }

    @MainActor
    func testInstallingBResetsActiveAToIdleWithoutBPhaseCallback() throws {
        let contextA = MailboxListContext.smartInboxOverview
        let contextB = MailboxListContext.mailbox(
            destination: .drafts,
            mode: .simpleList
        )
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        let tokenA = runtime.installScrollContext(contextA)
        XCTAssertTrue(
            runtime.updateScrollActivity(.active, using: tokenA)
        )
        XCTAssertEqual(runtime.scrollActivity, .active)

        let tokenB = runtime.installScrollContext(contextB)
        let updateB = try XCTUnwrap(
            runtime.updateVisibleIDs(["message-b"], using: tokenB)
        )
        let requestB = try XCTUnwrap(updateB.measurementRequest)

        XCTAssertEqual(runtime.measurementContext, contextB)
        XCTAssertEqual(runtime.topVisibleID, "message-b")
        XCTAssertEqual(runtime.scrollActivity, .idle)
        XCTAssertEqual(
            runtime.settledAnchorMeasurementRequest,
            requestB
        )
        XCTAssertTrue(
            runtime.acceptSettledAnchorMeasurement(
                requestB,
                using: tokenB,
                anchorViewportOffset: -9
            )
        )
        XCTAssertEqual(runtime.anchorViewportOffset, -9)
    }

    @MainActor
    func testRepeatedSettledCallbacksWithoutLocationChangeDoNotEmitDuplicates() {
        let runtime = MailboxScrollRuntime()
        runtime.updateOrderedItems(Self.items)
        runtime.updateVisibleIDs(["message-b"])
        runtime.updateContentOffset(420)
        runtime.updateAnchorViewportOffset(7, for: "message-b")

        XCTAssertNotNil(runtime.capture(reason: .scrollSettled))
        XCTAssertNil(runtime.capture(reason: .scrollSettled))
        XCTAssertEqual(runtime.persistenceRequestCount, 1)
    }

    @MainActor
    func testViewportCorrectionCannotApplyDuringContinuousGeometryAndIsConsumedAtIdle() {
        let scrollRuntime = MailboxScrollRuntime()
        let restorationRuntime = MailboxScrollRestorationRuntime()
        restorationRuntime.scheduleViewportOffsetAdjustment(-14)

        scrollRuntime.updateContentOffset(220)

        XCTAssertNil(
            restorationRuntime.correctionTargetY(
                currentContentOffsetY: scrollRuntime.contentOffsetY,
                boundary: .continuousGeometry
            )
        )
        XCTAssertTrue(restorationRuntime.hasPendingViewportOffsetAdjustment)
        XCTAssertEqual(
            restorationRuntime.correctionTargetY(
                currentContentOffsetY: scrollRuntime.contentOffsetY,
                boundary: .scrollSettled
            ),
            234
        )
        XCTAssertFalse(restorationRuntime.hasPendingViewportOffsetAdjustment)
        XCTAssertNil(
            restorationRuntime.correctionTargetY(
                currentContentOffsetY: scrollRuntime.contentOffsetY,
                boundary: .scrollSettled
            )
        )
    }

    @MainActor
    func testInitialRestorationWaitsForMatchingMountedSurfaceAndIsConsumedOnce() {
        let scrollRuntime = MailboxScrollRuntime()
        let staleToken = scrollRuntime.installScrollContext(.smartInboxOverview)
        let mountedToken = scrollRuntime.installScrollContext(.smartInboxOverview)
        let restorationRuntime = MailboxScrollRestorationRuntime()
        let input = MailboxScrollSurfaceRestorationInput(
            context: .smartInboxOverview,
            orderedItems: Self.items,
            orderedMessageIDs: ["a", "b", "c"]
        )

        restorationRuntime.deferInitialRestoration(
            input,
            until: mountedToken
        )
        let transientGeometry = MailboxScrollGeometrySnapshot(
            contentOffsetY: 0,
            contentHeight: 0,
            containerHeight: 0,
            topContentInset: 0
        )
        let mountedGeometry = MailboxScrollGeometrySnapshot(
            contentOffsetY: -52,
            contentHeight: 3_000,
            containerHeight: 800,
            topContentInset: 52
        )

        XCTAssertNil(
            restorationRuntime.consumeInitialRestoration(
                using: nil,
                geometry: mountedGeometry
            )
        )
        XCTAssertNil(
            restorationRuntime.consumeInitialRestoration(
                using: staleToken,
                geometry: mountedGeometry
            )
        )
        XCTAssertNil(
            restorationRuntime.consumeInitialRestoration(
                using: mountedToken,
                geometry: transientGeometry
            )
        )
        XCTAssertEqual(
            restorationRuntime.consumeInitialRestoration(
                using: mountedToken,
                geometry: mountedGeometry
            ),
            input
        )
        XCTAssertNil(
            restorationRuntime.consumeInitialRestoration(
                using: mountedToken,
                geometry: mountedGeometry
            )
        )
    }

    private static let items: [MailboxScrollItem] = [
        .init(id: "message-a", sectionID: .smartInboxToday),
        .init(id: "message-b", sectionID: .smartInboxHistorical(.yesterday)),
        .init(id: "message-c", sectionID: .smartInboxBundle(.people)),
        .init(id: "bundle-people", sectionID: .smartInboxToday),
    ]
}

#if os(macOS)
private final class FlippedMailboxDocumentView: NSView {
    override var isFlipped: Bool { true }
}
#endif
