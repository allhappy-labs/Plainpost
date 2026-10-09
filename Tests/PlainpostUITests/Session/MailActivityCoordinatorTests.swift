import XCTest
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostServiceIPC
@testable import PlainpostUI

extension SmartInboxActivityPresentation {
    static func preview(title: String, processed: Int, total: Int?, remaining: Int?) -> SmartInboxActivityPresentation {
        SmartInboxActivityPresentation(
            id: "smart-inbox-preview",
            title: title,
            detail: nil,
            compactDetail: total.map { "\(processed)/\($0)" },
            errorDetail: nil,
            processed: processed,
            total: total,
            remaining: remaining,
            fraction: total.flatMap { $0 > 0 ? Double(processed) / Double($0) : nil },
            control: nil,
            accessibilityLabel: title
        )
    }
}

@MainActor
final class MailActivityCoordinatorTests: XCTestCase {
    func testNoWorkMeansNoActivities() {
        XCTAssertEqual(MailActivityCoordinator.activities(smartInbox: nil, syncState: .idle, isSyncing: false), [])
    }

    func testSyncingShowsOneSyncActivity() {
        let result = MailActivityCoordinator.activities(smartInbox: nil, syncState: .inProgress(message: "Syncing mail"), isSyncing: true)
        XCTAssertEqual(result.map(\.kind), [.sync])
        XCTAssertEqual(result.first?.title, "Syncing mail")
    }

    func testSyncFailureOffersRetry() {
        let result = MailActivityCoordinator.activities(smartInbox: nil, syncState: .failure(message: "IMAP login failed"), isSyncing: false)
        XCTAssertEqual(result.first?.kind, .syncFailure)
        XCTAssertEqual(result.first?.title, "Couldn't sync")
        XCTAssertEqual(result.first?.detail, "IMAP login failed")
        XCTAssertTrue(result.first?.retry == true)
    }

    func testSmartInboxProgressShowsRemaining() {
        let presentation = SmartInboxActivityPresentation.preview(title: "Sorting Smart Inbox", processed: 5, total: 2000, remaining: 1995)
        let result = MailActivityCoordinator.activities(
            smartInbox: presentation, syncState: .idle, isSyncing: false, locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(result.first?.kind, .smartInbox)
        XCTAssertEqual(result.first?.detail, "1,995 left")
    }

    func testSmartInboxWithoutRemainingUsesCompactDetailAndPassesFraction() {
        let presentation = SmartInboxActivityPresentation.preview(title: "Preparing Smart Inbox...", processed: 3, total: nil, remaining: nil)
        let result = MailActivityCoordinator.activities(smartInbox: presentation, syncState: .idle, isSyncing: false)
        XCTAssertEqual(result, [MailActivity(
            id: "smart-inbox-preview", kind: .smartInbox, title: "Preparing Smart Inbox...",
            detail: nil, fraction: nil, retry: false
        )])
        let counted = SmartInboxActivityPresentation.preview(title: "Sorting", processed: 1, total: 4, remaining: 3)
        XCTAssertEqual(
            MailActivityCoordinator.activities(smartInbox: counted, syncState: .idle, isSyncing: false).first?.fraction,
            0.25
        )
    }

    func testFailureComesBeforeSyncBeforeSmartInbox() {
        let presentation = SmartInboxActivityPresentation.preview(title: "Sorting Smart Inbox", processed: 5, total: 10, remaining: 5)
        let result = MailActivityCoordinator.activities(
            smartInbox: presentation, syncState: .failure(message: "Offline"), isSyncing: true
        )
        XCTAssertEqual(result.map(\.kind), [.syncFailure, .sync, .smartInbox])
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
        XCTAssertEqual(result.map(\.retry), [true, false, false])
    }

    func testSuccessAndIdleShowNothing() {
        XCTAssertEqual(MailActivityCoordinator.activities(smartInbox: nil, syncState: .success(message: "Done"), isSyncing: false), [])
    }

    func testMaintenanceSuccessAdvancesRevisionAndRefreshesActivityExactlyOnce() {
        var mailboxRevision = 7
        var activityRefreshCount = 0

        MailActivityCoordinator.applyMailMaintenanceSuccess(
            advanceMailbox: { mailboxRevision &+= 1 },
            refreshActivity: { activityRefreshCount += 1 }
        )

        XCTAssertEqual(mailboxRevision, 8)
        XCTAssertEqual(activityRefreshCount, 1)
    }

    // MARK: - attach()

    func testBootstrapRunsActivitySnapshotApprovalsThenSmartInboxInOrder() async {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }

        await waitUntil { harness.log.entries.contains("smart-inbox") }
        XCTAssertEqual(
            harness.log.entries,
            ["activity", "snapshot:m1", "approvals", "approvals-loaded", "smart-inbox"]
        )
    }

    func testRevisionBumpRefreshesOnceWithTheCurrentSelection() async {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        harness.log.entries.removeAll()

        harness.refreshBus.bump()
        harness.selectedMessageID = "m2"
        await waitUntil { harness.log.entries.contains { $0.hasPrefix("snapshot") } }
        await settle()

        XCTAssertEqual(harness.log.entries, ["invalidate", "search:true", "snapshot:m2"])
    }

    func testPendingApprovalChangeRefreshesTheSnapshotWithoutSearch() async throws {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        harness.log.entries.removeAll()

        harness.queue.pending = [Self.approval(id: "a1", status: "pending")]
        try await harness.approvalQueue.refresh()
        await waitUntil { harness.log.entries.contains { $0.hasPrefix("snapshot") } }
        await settle()
        XCTAssertEqual(harness.log.entries, ["approvals", "invalidate", "snapshot:m1"])

        harness.log.entries.removeAll()
        try await harness.approvalQueue.refresh()
        await settle()
        XCTAssertEqual(harness.log.entries, ["approvals"], "an unchanged pending count refreshes nothing")
    }

    func testEverySnapshotRefreshRunsTheSnapshotHookAfterIt() async throws {
        let harness = Harness()
        harness.coordinator.didRefreshSnapshot = { [log = harness.log] in log.entries.append("snapshot-hook") }
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        XCTAssertEqual(Array(harness.log.entries.prefix(2)), ["activity", "snapshot:m1"])
        XCTAssertTrue(harness.log.entries.contains("snapshot-hook"))
        let approvalsLoadedIndex = harness.log.entries.firstIndex(of: "approvals-loaded")
        let smartInboxIndex = harness.log.entries.firstIndex(of: "smart-inbox")
        XCTAssertNotNil(approvalsLoadedIndex)
        XCTAssertNotNil(smartInboxIndex)
        if let approvalsLoadedIndex, let smartInboxIndex {
            XCTAssertLessThan(approvalsLoadedIndex, smartInboxIndex, "approvals load before Smart Inbox, even while the directory may still be loading concurrently")
        }

        harness.log.entries.removeAll()
        harness.refreshBus.bump()
        await waitUntil { harness.log.entries.contains("snapshot-hook") }
        await settle()
        XCTAssertEqual(harness.log.entries, ["invalidate", "search:true", "snapshot:m1", "snapshot-hook"])

        harness.log.entries.removeAll()
        harness.queue.pending = [Self.approval(id: "a1", status: "pending")]
        try await harness.approvalQueue.refresh()
        await waitUntil { harness.log.entries.contains("snapshot-hook") }
        await settle()
        XCTAssertEqual(harness.log.entries, ["approvals", "invalidate", "snapshot:m1", "snapshot-hook"])
    }

    func testMailboxStoreChangeBumpsTheRefreshBusOnce() async {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        let revision = harness.refreshBus.revision

        harness.post(.mailbox)
        await waitUntil { harness.refreshBus.revision != revision }
        await settle()
        XCTAssertEqual(harness.refreshBus.revision, revision + 1)
    }

    func testContinuousMailboxHintsPublishDuringImportAndRetainFinalSnapshot() async {
        var contentRevision = 0
        let sentSix = MailRefreshTestCounter()
        let harness = Harness(provider: { _ in
            InboxViewModel.preview().withMailboxLoadFailure("revision-\(contentRevision)")
        })
        let attached = harness.attach()
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        let initialRefreshes = harness.snapshot.completedRefreshes
        var producing = true
        let producer = Task { @MainActor in
            // The real 200-ms monitor sees no quiet interval during this
            // finite 2-second stream. These waits model commit cadence, not
            // a negative sleep used to guess whether a callback ran.
            for revision in 1...40 {
                guard !Task.isCancelled else { break }
                contentRevision = revision
                harness.post(.mailbox)
                if revision == 6 { sentSix.record() }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
            }
            producing = false
        }
        await sentSix.wait(for: 1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while producing, harness.snapshot.completedRefreshes == initialRefreshes,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let publishedDuringStream = producing && harness.snapshot.completedRefreshes > initialRefreshes
        print("MAILBOX_STREAM_DIAGNOSTIC sent=\(contentRevision) producer_active=\(producing) published_during_stream=\(publishedDuringStream)")
        XCTAssertGreaterThanOrEqual(contentRevision, 6)
        XCTAssertTrue(publishedDuringStream, "Continuous committed-mail hints must publish before the producer stops")
        await producer.value
        await waitUntil { harness.snapshot.model.mailboxLoadFailure == "revision-40" }
        XCTAssertEqual(harness.snapshot.model.mailboxLoadFailure, "revision-40", "The last committed content must not be lost by coalescing")
        producer.cancel()
        attached.cancel()
        await attached.value
    }

    func testAccountStoreChangeBumpsTheRefreshBusOnce() async {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        let revision = harness.refreshBus.revision

        harness.post(.accounts)
        await waitUntil { harness.refreshBus.revision != revision }
        await settle()
        XCTAssertEqual(harness.refreshBus.revision, revision + 1)
    }

    func testOperationStoreChangeRefreshesActivityAndApprovals() async {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        harness.log.entries.removeAll()

        harness.post(.operations)
        await waitUntil { harness.log.entries.contains("approvals") }
        await settle()
        XCTAssertEqual(harness.log.entries, ["activity", "approvals"])
    }

    func testMaintenanceSuccessBumpsTheRefreshBusOnceAndRefreshesActivity() async {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        let revision = harness.refreshBus.revision
        harness.log.entries.removeAll()

        await harness.maintenance.rerunSmartInbox()
        await waitUntil { harness.refreshBus.revision != revision }
        await settle()

        XCTAssertEqual(harness.refreshBus.revision, revision + 1)
        // The rerun refreshes the activity before and after it runs; the success adds one more.
        XCTAssertEqual(harness.log.entries.filter { $0 == "activity" }.count, 3)
    }

    func testActivitiesFollowTheSmartInboxPresentation() async {
        let harness = Harness()
        let attached = harness.attach()
        defer { attached.cancel() }
        await waitUntil { harness.log.entries.contains("smart-inbox") }
        XCTAssertEqual(harness.coordinator.activities, [])

        harness.job = PlainpostDurableJob(
            id: "job-1",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .running,
            idempotencyKey: "job-1",
            progress: .init(current: 5, total: 2000, phase: "classifying", label: "Smart Inbox")
        )
        harness.smartInbox.refresh(locale: Locale(identifier: "en_US"))
        await waitUntil { !harness.coordinator.activities.isEmpty }

        XCTAssertEqual(harness.coordinator.activities.map(\.kind), [.smartInbox])
        XCTAssertEqual(harness.coordinator.activities.first?.id, "job-1")
    }

    func testDeliveredActivityChangeDoesNotPublishAfterAttachCancellation() async {
        let harness = Harness()
        let observed = MailRefreshTestCounter()
        var publications: [[MailActivity]] = []
        let subscription = harness.coordinator.$activities.dropFirst().sink { activities in
            publications.append(activities)
            observed.record()
        }
        harness.job = PlainpostDurableJob(
            id: "activity-before-cancel", kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .running, idempotencyKey: "activity-before-cancel",
            progress: .init(current: 1, total: 10, phase: "classifying", label: "Smart Inbox")
        )
        harness.smartInbox.refresh(locale: Locale(identifier: "en_US"))
        let attached = harness.attach()
        // Only the real activity observation child publishes this initial presentation.
        // Its synchronous sink completes before that child waits for its next value.
        await observed.wait(for: 1)
        let beforeCancellation = harness.coordinator.activities
        XCTAssertEqual(beforeCancellation.first?.id, "activity-before-cancel")

        harness.job = PlainpostDurableJob(
            id: "activity-after-cancel", kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .running, idempotencyKey: "activity-after-cancel",
            progress: .init(current: 2, total: 10, phase: "classifying", label: "Smart Inbox")
        )
        // Delivery and cancellation happen in one actor turn: the already-resumed
        // observation continuation runs only after this task yields at the join.
        harness.smartInbox.refresh(locale: Locale(identifier: "en_US"))
        attached.cancel()
        await attached.value
        subscription.cancel()

        XCTAssertEqual(harness.coordinator.activities, beforeCancellation)
        XCTAssertEqual(publications, [beforeCancellation], "no late activity publication after cancellation")
    }

    func testAttachEndsWhenCancelled() async {
        let harness = Harness()
        let ended = expectation(description: "attach returned")
        let attached = Task { @MainActor in
            await harness.coordinator.attach()
            ended.fulfill()
        }
        await waitUntil { harness.log.entries.contains("smart-inbox") }

        attached.cancel()
        await fulfillment(of: [ended], timeout: 5)
    }

    func testBurstCoalescesIntoOneFollowup() async {
        let gate = MailRefreshTestBarrier()
        let invalidations = MailRefreshTestCounter()
        let completions = MailRefreshTestCounter()
        var selections: [String?] = []
        let harness = Harness(provider: { selected in
            selections.append(selected)
            await gate.wait()
            return InboxViewModel.preview().withMailboxLoadFailure(selected ?? "nil")
        }, invalidated: { invalidations.record() })
        harness.coordinator.didRefreshSnapshot = { completions.record() }
        let attached = harness.attach()
        await gate.arrived.wait(for: 1)

        for revision in 1...20 {
            harness.selectedMessageID = "m\(revision)"
            harness.refreshBus.bump()
            await invalidations.wait(for: revision)
        }
        XCTAssertEqual(selections.count, 1, "20 dirty revisions must not admit concurrent provider calls")
        gate.release()
        await completions.wait(for: 2)
        attached.cancel()
        await attached.value

        XCTAssertEqual(selections, ["m1", "m20"], "one merged follow-up reads the final selection")
        XCTAssertEqual(harness.snapshot.model.mailboxLoadFailure, "m20", "the final revision must publish")
    }

    func testDetachJoinsAdmittedRefreshAndPreventsPublication() async {
        let gate = MailRefreshTestBarrier()
        let bootstrapped = MailRefreshTestCounter()
        var reads = 0
        let harness = Harness(provider: { _ in
            reads += 1
            if reads > 1 { await gate.wait() }
            return InboxViewModel.preview().withMailboxLoadFailure("read-\(reads)")
        })
        harness.coordinator.didRefreshApprovals = { bootstrapped.record() }
        var returned = false
        let attached = Task {
            await harness.coordinator.attach()
            returned = true
        }
        await bootstrapped.wait(for: 1)
        harness.refreshBus.bump()
        await gate.arrived.wait(for: 1)
        attached.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        XCTAssertFalse(returned, "detach joins the admitted non-cancellable provider")
        harness.refreshBus.bump()
        gate.release()
        await attached.value
        await gate.departed.wait(for: 1)

        XCTAssertTrue(returned)
        XCTAssertEqual(reads, 2, "no pending read is admitted after cancellation")
        XCTAssertEqual(harness.snapshot.completedRefreshes, 1)
        XCTAssertEqual(harness.snapshot.model.mailboxLoadFailure, "read-1", "cached result survives detach")
    }

    func testSelectionChangesDuringReadOnlyPublishTheLatestSelection() async {
        let gate = MailRefreshTestBarrier()
        let completions = MailRefreshTestCounter()
        var selections: [String?] = []
        let harness = Harness(provider: { selected in
            selections.append(selected)
            await gate.wait()
            return InboxViewModel.preview().withMailboxLoadFailure(selected ?? "nil")
        })
        var published: [String] = []
        let subscription = harness.snapshot.$model.sink {
            if let failure = $0.mailboxLoadFailure { published.append(failure) }
        }
        harness.coordinator.didRefreshSnapshot = { completions.record() }
        let attached = harness.attach()
        await gate.arrived.wait(for: 1)
        harness.selectedMessageID = "m2"
        gate.release()
        await completions.wait(for: 2)
        attached.cancel()
        await attached.value
        subscription.cancel()
        XCTAssertEqual(selections, ["m1", "m2"])
        XCTAssertEqual(published, ["m2"], "a read for the old selection never lands")
    }

    func testAccountChangeDuringNodeReadOnlyPublishesCurrentGeneration() async {
        let gate = MailRefreshTestBarrier()
        let invalidations = MailRefreshTestCounter()
        let publications = MailRefreshTestCounter()
        var reads = 0
        let status = NodeMailModeStatusModel(fetchStatus: {
            await MainActor.run { reads += 1 }
            let read = await MainActor.run { reads }
            if read == 1 { await gate.wait() }
            return PlainpostNodeMailModeStatus(state: read == 1 ? .reconnectRequired : .updateRequired,
                                              nodeBackedAccountCount: 1, waitingIntentCount: 0)
        }, store: nil)
        let harness = Harness(invalidated: { invalidations.record() }, nodeStatus: status)
        var lines: [String] = []
        let subscription = status.$statusLine.sink {
            if let line = $0 { lines.append(line); publications.record() }
        }
        let attached = harness.attach()
        await gate.arrived.wait(for: 1)
        harness.post(.accounts)
        await invalidations.wait(for: 1)
        gate.release()
        await publications.wait(for: 1)
        attached.cancel()
        await attached.value
        subscription.cancel()
        XCTAssertEqual(lines, ["Update your Sync Node"])
    }

    func testReattachWaitsForCancelledOwnerAndWaitingAttachCanCancel() async {
        let gate = MailRefreshTestBarrier()
        let admissions = MailRefreshTestCounter()
        let bootstraps = MailRefreshTestCounter()
        let nextStarted = MailRefreshTestCounter()
        let waiterStarted = MailRefreshTestCounter()
        let harness = Harness(provider: { _ in
            admissions.record()
            if admissions.count == 1 { await gate.wait() }
            return .preview()
        })
        harness.coordinator.didRefreshApprovals = { bootstraps.record() }
        let old = harness.attach()
        await gate.arrived.wait(for: 1)
        old.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        let next = Task {
            nextStarted.record()
            await harness.coordinator.attach()
        }
        await nextStarted.wait(for: 1)
        XCTAssertEqual(admissions.count, 1, "the old owner must join before a new read is admitted")
        let cancelledWaiter = Task {
            waiterStarted.record()
            await harness.coordinator.attach()
        }
        await waiterStarted.wait(for: 1)
        cancelledWaiter.cancel()
        await cancelledWaiter.value
        XCTAssertEqual(admissions.count, 1, "a cancelled waiting attachment never starts work")
        gate.release()
        await old.value
        await bootstraps.wait(for: 1)
        harness.refreshBus.bump()
        await admissions.wait(for: 3)
        next.cancel()
        await next.value
        XCTAssertEqual(admissions.count, 3, "old teardown must not cancel the new subscriptions")
    }

    func testSlowDirectoryDoesNotDelayApprovalRefresh() async {
        let gate = MailRefreshTestBarrier()
        let approvals = MailRefreshTestCounter()
        let harness = Harness()
        harness.coordinator.didRefreshSnapshot = { await gate.wait() }
        harness.coordinator.didRefreshApprovals = { approvals.record() }
        let attached = harness.attach()
        await gate.arrived.wait(for: 1)
        await approvals.wait(for: 1)
        XCTAssertTrue(harness.log.entries.contains("approvals"))
        gate.release()
        attached.cancel()
        await attached.value
    }

    func testDetachJoinsNodeStatusAndPreventsPublication() async {
        let gate = MailRefreshTestBarrier()
        let status = NodeMailModeStatusModel(fetchStatus: {
            await gate.wait()
            return PlainpostNodeMailModeStatus(state: .reconnectRequired, nodeBackedAccountCount: 1, waitingIntentCount: 0)
        }, store: nil)
        let harness = Harness(nodeStatus: status)
        var returned = false
        let attached = Task {
            await harness.coordinator.attach()
            returned = true
        }
        await gate.arrived.wait(for: 1)
        attached.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        XCTAssertFalse(returned)
        gate.release()
        await attached.value
        XCTAssertNil(status.statusLine, "a late service result must not publish after detach")
    }

    // MARK: - Helpers

    private static func approval(id: String, status: String) -> ApprovalQueueItemModel {
        ApprovalQueueItemModel(
            id: id, agentName: "Agent", subject: "Subject", recipientSummary: "Someone",
            riskFlags: [], hasAttachments: false, status: status
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the condition", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets any follow-up work a change could start run to completion.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func testBootstrapLoadsApprovalsWithoutWaitingForTheDirectory() async {
        let session = MailSession.make()
        let gate = Gate()
        var approvalsLoaded = false
        session.activity.didRefreshSnapshot = { await gate.wait() }
        session.activity.didRefreshApprovals = { approvalsLoaded = true }
        let attach = Task { await session.activity.attach() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !approvalsLoaded, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(approvalsLoaded, "approvals load while the directory still refreshes")
        gate.open()
        attach.cancel()
        await attach.value
    }

    func testHostActivitiesLeadWithFailuresThenSyncs() {
        let list = MailActivityCoordinator.activities(
            smartInbox: nil, syncState: .idle, isSyncing: false,
            host: [
                .hostSync(accountTitle: "a@x.example", detail: nil, fraction: nil),
                .hostSyncFailure(accountTitle: "b@y.example", message: "Check your connection and retry."),
            ]
        )
        XCTAssertEqual(list.map(\.id), ["host-sync-failure", "host-sync"])
        XCTAssertEqual(list.first?.title, "Couldn't sync b@y.example")
        XCTAssertEqual(list.last?.title, "Syncing a@x.example")
        XCTAssertEqual(list.first?.retry, true)
    }

    @MainActor
    func testSettingHostActivitiesUpdatesTheList() {
        let session = MailSession.make()
        session.activity.hostActivities = [.hostSync(accountTitle: "a@x.example", detail: "INBOX · 10 of 40", fraction: 0.25)]
        XCTAssertEqual(session.activity.activities.map(\.id), ["host-sync"])
        session.activity.hostActivities = []
        XCTAssertTrue(session.activity.activities.isEmpty)
    }

    func testEachActivityReadsAsOneLine() {
        XCTAssertEqual(MailActivity.hostSync(accountTitle: "a@x.example", detail: "INBOX · 10 of 40", fraction: 0.25).line,
                       "Syncing a@x.example · INBOX · 10 of 40")
        XCTAssertEqual(MailActivity.hostSync(accountTitle: "a@x.example", detail: nil, fraction: nil).line,
                       "Syncing a@x.example")
        XCTAssertEqual(MailActivity.hostSyncFailure(accountTitle: "b@y.example", message: "Mail sync failed.").line,
                       "Couldn't sync b@y.example · Mail sync failed.")
        let list = MailActivityCoordinator.activities(
            smartInbox: nil, syncState: .idle, isSyncing: true, host: []
        )
        XCTAssertEqual(list.map(\.line), ["Syncing mail"])
    }

    func testAListsFailureLineSaysWhatFailed() {
        XCTAssertEqual(MailActivity.hostSyncFailure(accountTitle: "b@y.example", message: "Mail sync failed. Check your connection and retry.").failureMessage,
                       "Mail sync failed. Check your connection and retry.")
        let own = MailActivityCoordinator.activities(
            smartInbox: nil, syncState: .failure(message: "Inbox sync failed."), isSyncing: false
        )
        XCTAssertEqual(own.first?.failureMessage, "Inbox sync failed.")
        let untold = MailActivity(id: "x", kind: .syncFailure, title: "Couldn't sync", detail: nil, fraction: nil, retry: true)
        XCTAssertEqual(untold.failureMessage, "Couldn't sync")
    }

    /// Two failures at once: the first Retry keeps the plain id, the other is told apart.
    func testRetryIdentifiersAreUniqueWhenTwoFailuresShow() {
        let list = MailActivityCoordinator.activities(
            smartInbox: nil, syncState: .failure(message: "Offline"), isSyncing: false,
            host: [.hostSyncFailure(accountTitle: "b@y.example", message: "Check your connection and retry.")]
        )
        let ids = list.filter(\.retry).map { $0.retryAccessibilityIdentifier(in: list) }
        XCTAssertEqual(ids, ["mailboxes.activity.retry", "mailboxes.activity.retry.sync-failure"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

private final class EventLog: @unchecked Sendable {
    var entries: [String] = []
}

private final class RecordingApprovalQueue: ApprovalQueueHandling, @unchecked Sendable {
    let log: EventLog
    var pending: [ApprovalQueueItemModel] = []

    init(log: EventLog) { self.log = log }

    func items() throws -> [ApprovalQueueItemModel] {
        log.entries.append("approvals")
        return pending
    }

    func approve(requestID: String, username: String, password: String) async throws {}
    func deny(requestID: String, reason: String?) async throws {}
}

@MainActor
private final class Harness {
    let log: EventLog
    let center = NotificationCenter()
    let refreshBus = MailboxRefreshBus()
    let queue: RecordingApprovalQueue
    let approvalQueue: ApprovalQueueViewModel
    let smartInbox: SmartInboxActivityCoordinator
    let maintenance: MailMaintenanceViewModel
    let coordinator: MailActivityCoordinator
    let snapshot: InboxViewModelSnapshotStore
    var selectedMessageID: String? = "m1"
    var job: PlainpostDurableJob?

    init(
        provider: (@MainActor (String?) async -> InboxViewModel)? = nil,
        invalidated: @escaping @MainActor () -> Void = {},
        nodeStatus: NodeMailModeStatusModel = .inactive()
    ) {
        let log = EventLog()
        self.log = log
        queue = RecordingApprovalQueue(log: log)
        approvalQueue = ApprovalQueueViewModel(queue: queue)
        weak var harness: Harness?
        smartInbox = SmartInboxActivityCoordinator(
            jobProvider: {
                log.entries.append("activity")
                return MainActor.assumeIsolated { harness?.job }
            },
            pause: { _ in },
            resume: { _ in }
        )
        log.entries.removeAll()
        let accountSetup = AccountSetupViewModel.preview()
        maintenance = MailMaintenanceViewModel(
            accountSetup: accountSetup,
            smartInboxActivity: smartInbox,
            activeRerunJob: { nil },
            selectedProviderID: { "foundation" },
            rerun: { _, _, _ in "Up to date" }
        )
        snapshot = InboxViewModelSnapshotStore(
            initialModel: .preview(),
            provider: { @MainActor selected in
                log.entries.append("snapshot:\(selected ?? "nil")")
                return await provider?(selected) ?? .preview()
            }
        )
        coordinator = MailActivityCoordinator(
            refreshBus: refreshBus,
            inboxSnapshot: snapshot,
            approvalQueue: approvalQueue,
            nodeStatus: nodeStatus,
            accountSetup: accountSetup,
            storeChanges: MailStoreChangeMonitor(
                notificationCenter: center,
                observeDistributedNotifications: false
            ),
            smartInbox: smartInbox,
            maintenance: maintenance,
            selectedMessageID: { harness?.selectedMessageID },
            invalidateSnapshot: { log.entries.append("invalidate"); invalidated() },
            refreshSearchMailboxes: { log.entries.append("search:\($0)") },
            refreshSmartInbox: { log.entries.append("smart-inbox") },
            locale: Locale(identifier: "en_US")
        )
        coordinator.didRefreshApprovals = { log.entries.append("approvals-loaded") }
        harness = self
    }

    func attach() -> Task<Void, Never> {
        Task { @MainActor [coordinator] in await coordinator.attach() }
    }

    func post(_ scope: MailStoreChangeScope) {
        center.post(
            name: MailStoreChangeSignal.notificationName,
            object: nil,
            userInfo: [MailStoreChangeSignal.scopeUserInfoKey: scope.rawValue]
        )
    }
}
