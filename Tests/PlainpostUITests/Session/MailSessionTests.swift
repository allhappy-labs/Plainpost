import AppKit
import SwiftUI
import XCTest
import PlainpostCore
import PlainpostDB
@testable import PlainpostUI

@MainActor
final class MailSessionTests: XCTestCase {
    func testPreviewSessionWiresControllersToOneMailbox() {
        let session = MailSession.preview()
        XCTAssertTrue(session.actions.mailboxForTesting === session.mailbox)
        XCTAssertTrue(session.search.mailboxForTesting === session.mailbox)
    }

    func testAskMailOpenSourceOpensTheMessage() {
        let session = MailSession.preview()
        session.openAskMailSource(.preview(messageID: "m7", mailboxPath: "INBOX"))
        XCTAssertEqual(session.mailbox.selectedMessageID, "m7")
    }

    func testAskMailOpenSourceShowsTheSourceMailboxAfterTheHostHook() {
        let session = MailSession.preview()
        var destinationWhenHookRan: PlainpostDestination?
        session.willShowAskMailMessage = { destinationWhenHookRan = session.mailbox.selectedDestination }

        session.openAskMailSource(.preview(messageID: "m8", mailboxPath: "[Gmail]/Sent Mail"))

        XCTAssertNotNil(destinationWhenHookRan)
        XCTAssertNotEqual(destinationWhenHookRan, .sent)
        XCTAssertEqual(session.mailbox.selectedDestination, .sent)
        XCTAssertEqual(session.mailbox.selectedMessageID, "m8")
    }

    func testAskMailReplyInRuntimeWindowHandsTheWindowToTheHost() async {
        let session = MailSession.make(composerPresentationPolicy: .runtimeWindow)
        let opened = expectation(description: "composer window")
        var requests: [PlainpostComposerWindowRequest] = []
        session.openComposerWindow = {
            requests.append($0)
            opened.fulfill()
        }
        session.attachAskMailHost()

        session.askMail.host.reply(MessageID("m9"))

        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(requests, [.reply(sourceMessageID: "m9")])
        XCTAssertEqual(session.mailbox.selectedMessageID, "m9")
        XCTAssertFalse(session.compose.isPresented)
    }

    func testAskMailHostRefusesMutationsWhileTheMailboxIsReadOnly() async {
        let session = MailSession.make(
            composerPresentationPolicy: .runtimeWindow,
            allowsMailboxMutations: { false }
        )
        var windowOpened = false
        session.openComposerWindow = { _ in windowOpened = true }
        session.attachAskMailHost()

        XCTAssertFalse(session.askMail.host.allowsMutations())
        let performed = await session.askMail.host.mailAction(.archive, MessageID("m1"))
        session.askMail.host.reply(MessageID("m1"))
        await Task.yield()

        XCTAssertFalse(performed)
        XCTAssertFalse(windowOpened)
        XCTAssertNil(session.mailbox.selectedMessageID)
    }

    func testSearchHitRefreshesTheInboxWithoutAViewConnectingIt() {
        var invalidations = 0
        let session = MailSession.make(invalidateInboxSnapshot: { invalidations += 1 })

        session.search.open(MessageID("m3"), closesSearch: true)

        XCTAssertEqual(session.mailbox.selectedMessageID, "m3")
        XCTAssertEqual(invalidations, 1)
    }

    func testRootBuildsItsSessionOnceWhenInstalledAndNeverOnReinit() {
        var builds = 0
        func countedSession() -> MailSession {
            builds += 1
            return MailSession.preview()
        }
        func makeRoot() -> PlainpostRootView {
            PlainpostRootView(session: countedSession())
        }

        _ = makeRoot()
        _ = makeRoot()
        XCTAssertEqual(builds, 0)

        let hostingView = NSHostingView(rootView: AnyView(makeRoot().frame(width: 900, height: 640)))
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(builds, 1)

        hostingView.rootView = AnyView(makeRoot().frame(width: 900, height: 640))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(builds, 1)
    }

    func testSnapshotRefreshesKeepTheDirectoryCurrentOnceAHostLoadsIt() async {
        var loads = 0
        let session = MailSession.make(loadMailboxDirectory: {
            loads += 1
            return [MailboxAccountSection(id: AccountID("a"), title: "A", folders: [])]
        })

        await session.activity.didRefreshSnapshot()
        XCTAssertEqual(loads, 0, "no host has shown the directory")

        await session.directory.refresh()
        session.directory.setVisible(true)
        await session.activity.didRefreshSnapshot()
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(session.directory.sections.map(\.id), [AccountID("a")])
    }

    func testSnapshotReportsItsFirstFinishedRefresh() async {
        let store = InboxViewModelSnapshotStore(initialModel: .preview(), provider: { _ in .preview() })
        XCTAssertFalse(store.hasRefreshed, "a new list shows placeholders, not 'No Mail'")
        await store.refresh(selectedMessageID: nil)
        XCTAssertTrue(store.hasRefreshed)
    }

    func testSnapshotCountsOnlyTheRefreshesThatLand() async {
        var pending: [CheckedContinuation<Void, Never>] = []
        let store = InboxViewModelSnapshotStore(initialModel: .preview(), provider: { _ in
            await withCheckedContinuation { pending.append($0) }
            return .preview()
        })
        XCTAssertEqual(store.completedRefreshes, 0)

        let older = Task { await store.refresh(selectedMessageID: nil) }
        while pending.count < 1 { await Task.yield() }
        let newer = Task { await store.refresh(selectedMessageID: nil) }
        while pending.count < 2 { await Task.yield() }
        XCTAssertEqual(store.completedRefreshes, 0, "nothing has landed while the provider runs")

        pending[1].resume()
        await newer.value
        XCTAssertEqual(store.completedRefreshes, 1)
        pending[0].resume()
        await older.value
        XCTAssertEqual(store.completedRefreshes, 1, "a superseded refresh never lands")
    }

    func testPreviewSessionDirectoryIsEmpty() async {
        let session = MailSession.preview()
        await session.directory.refresh()
        XCTAssertEqual(session.directory.sections, [])
    }

    func testRecipientSuggestionsLoadCorrespondentsOnlyWhenAsked() async {
        var loads = 0
        let session = MailSession.make(loadCorrespondents: {
            loads += 1
            return [Correspondent(address: "ivy@example.com", displayName: "Ivy", lastSeen: nil)]
        })

        await session.activity.didRefreshSnapshot()
        XCTAssertEqual(loads, 0, "snapshot refreshes never load correspondents")

        await session.recipientSuggestions.refreshCorrespondents()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(session.recipientSuggestions.suggestions(matching: "iv", excluding: []).map(\.address), ["ivy@example.com"])
    }

    func testPreviewSessionSuggestsNoOneAndNeverAsksForContacts() async {
        let session = MailSession.preview()
        await session.recipientSuggestions.prepareContactsIfNeeded()
        XCTAssertEqual(session.recipientSuggestions.contacts.snapshot.authorization, .unavailable)
        XCTAssertEqual(session.recipientSuggestions.correspondents, [])
    }

    func testComposeReadsTheSelectedThreadWithoutAViewConnectingIt() {
        let session = MailSession.make(viewModel: .designPreview())
        let expected = session.inboxSnapshot.model.thread(for: session.mailbox.selectedDestination)

        XCTAssertEqual(session.compose.thread()?.subject, expected.subject)
    }

    func testComposeFromListOpensTheMessageThenAsksCompose() async throws {
        let session = MailSession.make(viewModel: .designPreview())
        let messageID = try XCTUnwrap(session.inboxSnapshot.model.selectedThread.messages.last?.id)

        await session.composeFromList(.forward(messageID: messageID), messageID: messageID, destination: .allInboxes)

        XCTAssertEqual(session.mailbox.selectedMessageID, messageID)
        XCTAssertTrue(session.compose.isPresented)
    }

    func testComposeFromListRefusesWhileTheMailboxIsReadOnly() async throws {
        let session = MailSession.make(viewModel: .designPreview(), allowsMailboxMutations: { false })
        let messageID = try XCTUnwrap(session.inboxSnapshot.model.selectedThread.messages.last?.id)

        await session.composeFromList(.forward(messageID: messageID), messageID: messageID, destination: .allInboxes)

        XCTAssertNil(session.mailbox.selectedMessageID)
        XCTAssertFalse(session.compose.isPresented)
    }

    func testRemovalActionFollowsTheMessagesAccount() {
        let gmail = Account(id: AccountID("g"), displayName: "", email: EmailAddress("me@gmail.com"),
                            imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com")
        let session = MailSession.make(accountForMessage: { $0 == "g1" ? gmail : nil })
        XCTAssertEqual(session.removalAction(forMessageID: "g1"), .archive)
        XCTAssertEqual(session.removalAction(forMessageID: "other"), .delete)
    }

    func testVisibleDirectoryBeforeAttachLoadsOnceAndJoinsDetach() async {
        let gate = MailRefreshTestBarrier()
        let approvals = MailRefreshTestCounter()
        let session = MailSession.make(loadMailboxDirectory: {
            await gate.wait()
            return []
        })
        session.directory.setVisible(true)
        XCTAssertEqual(gate.arrived.count, 0, "visibility only marks dirty until attach owns it")
        session.activity.didRefreshApprovals = { approvals.record() }
        var returned = false
        let attached = Task { await session.activity.attach(); returned = true }
        await gate.arrived.wait(for: 1)
        await approvals.wait(for: 1)
        XCTAssertEqual(gate.arrived.count, 1)
        attached.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        XCTAssertFalse(returned)
        gate.release()
        await attached.value
        XCTAssertEqual(gate.arrived.count, 1)
    }

    func testHideShowDuringOwnedDirectoryReadCoalescesAndFencesOldResult() async {
        let gate = MailRefreshTestBarrier()
        let approvals = MailRefreshTestCounter()
        let fresh = MailRefreshTestCounter()
        var loads = 0
        let session = MailSession.make(loadMailboxDirectory: {
            loads += 1
            let load = loads
            if load == 1 { await gate.wait() }
            return [MailboxAccountSection(id: AccountID("a"), title: "load-\(load)", folders: [])]
        })
        session.activity.didRefreshApprovals = { approvals.record() }
        let subscription = session.directory.$sections.sink {
            if $0.first?.title == "load-2" { fresh.record() }
        }
        let attached = Task { await session.activity.attach() }
        await approvals.wait(for: 1)
        session.directory.setVisible(true)
        await gate.arrived.wait(for: 1)
        session.directory.setVisible(false)
        session.directory.setVisible(true)
        XCTAssertEqual(loads, 1, "showing again merges one pending refresh")
        gate.release()
        await fresh.wait(for: 1)
        attached.cancel()
        await attached.value
        subscription.cancel()
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(session.directory.sections.first?.title, "load-2")
    }

    func testVisibleDirectoryLoadsWhileTheBootstrapSmartInboxRunIsStillWorking() async {
        // The iPhone Mailboxes screen appeared during a long Smart Inbox run (the realistic UI
        // fixture's) and listed no folders: its load waited behind the whole bootstrap.
        let smartInbox = MailRefreshTestBarrier()
        let loaded = MailRefreshTestCounter()
        let session = MailSession.make(
            loadMailboxDirectory: { [MailboxAccountSection(id: AccountID("a"), title: "folders", folders: [])] },
            refreshSmartInbox: { _, _, _ in
                await smartInbox.wait()
                return "Done"
            }, aiGenerationAvailable: { true }, smartInboxActivityJob: { nil }
        )
        session.connectLifecycle(MailSessionLifecycleHooks(reportFailure: { _ in }, presentAskMail: { _ in },
                                          didRefreshApprovals: {}, allowsSmartInboxRefreshOnAppear: { true },
                                          markReadFailed: {}, attachmentEvent: { _ in }),
                                 locale: .current)
        let subscription = session.directory.$sections.sink { if $0.first?.title == "folders" { loaded.record() } }
        let attached = Task { await session.activity.attach() }
        await smartInbox.arrived.wait(for: 1)

        session.directory.setVisible(true)
        await loaded.wait(for: 1)

        XCTAssertEqual(smartInbox.departed.count, 0, "the folders loaded while Smart Inbox was still running")
        XCTAssertEqual(session.directory.sections.first?.title, "folders")
        smartInbox.release()
        attached.cancel()
        await attached.value
        subscription.cancel()
    }

    func testAMailboxReadFencedByAMailChangeIsRetriedWhileTheBootstrapSmartInboxRunIsStillWorking() async {
        // After the Mac woke, a fresh session's first mailbox read was discarded by a sync
        // import, and its retry waited behind the whole Smart Inbox run: the list said
        // "No messages" while the folder counts were already shown.
        let smartInbox = MailRefreshTestBarrier()
        let firstRead = MailRefreshTestBarrier()
        let loaded = MailRefreshTestCounter()
        var reads = 0
        let session = MailSession.make(
            viewModel: .loading(requiresAccountSetup: false),
            viewModelProvider: { _ in
                reads += 1
                if reads == 1 { await firstRead.wait() }
                return .preview()
            },
            refreshSmartInbox: { _, _, _ in
                await smartInbox.wait()
                return "Done"
            }, aiGenerationAvailable: { true }, smartInboxActivityJob: { nil }
        )
        session.connectLifecycle(MailSessionLifecycleHooks(reportFailure: { _ in }, presentAskMail: { _ in },
                                          didRefreshApprovals: {}, allowsSmartInboxRefreshOnAppear: { true },
                                          markReadFailed: {}, attachmentEvent: { _ in }),
                                 locale: .current)
        let subscription = session.inboxSnapshot.$model.sink { if !$0.classicRows.isEmpty { loaded.record() } }
        let attached = Task { await session.activity.attach() }
        await firstRead.arrived.wait(for: 1)
        session.refreshBus.bump()
        firstRead.release()
        await loaded.wait(for: 1)

        XCTAssertEqual(smartInbox.departed.count, 0, "the mailbox loaded while Smart Inbox was still running")
        XCTAssertFalse(session.inboxSnapshot.model.classicRows.isEmpty)
        smartInbox.release()
        attached.cancel()
        await attached.value
        subscription.cancel()
    }

    func testAFolderLoadFencedByAMailChangeIsRetriedWhileTheBootstrapSmartInboxRunIsStillWorking() async {
        // Re-review N1: a sync import bumps the refresh bus while the first folder load is in
        // flight; the fenced load must be redone at once, not after the Smart Inbox run.
        let smartInbox = MailRefreshTestBarrier()
        let firstLoad = MailRefreshTestBarrier()
        let loaded = MailRefreshTestCounter()
        var loads = 0
        let session = MailSession.make(
            loadMailboxDirectory: {
                loads += 1
                if loads == 1 { await firstLoad.wait() }
                return [MailboxAccountSection(id: AccountID("a"), title: "folders", folders: [])]
            },
            refreshSmartInbox: { _, _, _ in
                await smartInbox.wait()
                return "Done"
            }, aiGenerationAvailable: { true }, smartInboxActivityJob: { nil }
        )
        session.connectLifecycle(MailSessionLifecycleHooks(reportFailure: { _ in }, presentAskMail: { _ in },
                                          didRefreshApprovals: {}, allowsSmartInboxRefreshOnAppear: { true },
                                          markReadFailed: {}, attachmentEvent: { _ in }),
                                 locale: .current)
        let subscription = session.directory.$sections.sink { if $0.first?.title == "folders" { loaded.record() } }
        let attached = Task { await session.activity.attach() }
        await smartInbox.arrived.wait(for: 1)

        session.directory.setVisible(true)
        await firstLoad.arrived.wait(for: 1)
        session.refreshBus.bump()
        firstLoad.release()
        await loaded.wait(for: 1)

        XCTAssertEqual(smartInbox.departed.count, 0, "the folders loaded while Smart Inbox was still running")
        XCTAssertEqual(session.directory.sections.first?.title, "folders")
        smartInbox.release()
        attached.cancel()
        await attached.value
        subscription.cancel()
    }

    func testOperationChangesRefreshActivityWhileTheBootstrapSmartInboxRunIsStillWorking() async {
        // The iPhone Mailboxes Activity section stayed empty during a long Smart Inbox run:
        // its progress reads waited behind the run on the attachment's one worker.
        let smartInbox = MailRefreshTestBarrier()
        let activityReads = MailRefreshTestCounter()
        let session = MailSession.make(
            refreshSmartInbox: { _, _, _ in
                await smartInbox.wait()
                return "Done"
            }, aiGenerationAvailable: { true }, smartInboxActivityJob: {
                activityReads.record()
                return nil
            }
        )
        session.connectLifecycle(MailSessionLifecycleHooks(reportFailure: { _ in }, presentAskMail: { _ in },
                                          didRefreshApprovals: {}, allowsSmartInboxRefreshOnAppear: { true },
                                          markReadFailed: {}, attachmentEvent: { _ in }),
                                 locale: .current)
        let attached = Task { await session.activity.attach() }
        await smartInbox.arrived.wait(for: 1)
        let readsBefore = activityReads.count

        // In-process only: never broadcast to the machine from a test.
        NotificationCenter.default.post(
            name: MailStoreChangeSignal.notificationName, object: nil,
            userInfo: [MailStoreChangeSignal.scopeUserInfoKey: MailStoreChangeScope.operations.rawValue]
        )
        await activityReads.wait(for: readsBefore + 1)

        XCTAssertEqual(smartInbox.departed.count, 0, "activity refreshed while Smart Inbox was still running")
        smartInbox.release()
        attached.cancel()
        await attached.value
    }

    func testDetachJoinsSmartInboxWithoutPublishingLateActivityOrRevision() async {
        let gate = MailRefreshTestBarrier()
        var activityReads = 0
        var durableCompletions = 0
        let session = MailSession.make(refreshSmartInbox: { _, _, _ in
            await gate.wait()
            durableCompletions += 1
            return "Done"
        }, aiGenerationAvailable: { true }, smartInboxActivityJob: {
            activityReads += 1
            return nil
        })
        session.connectLifecycle(MailSessionLifecycleHooks(reportFailure: { _ in }, presentAskMail: { _ in },
                                          didRefreshApprovals: {}, allowsSmartInboxRefreshOnAppear: { true },
                                          markReadFailed: {}, attachmentEvent: { _ in }),
                                 locale: .current)
        let attached = Task { await session.activity.attach() }
        await gate.arrived.wait(for: 1)
        let revision = session.refreshBus.revision
        let reads = activityReads
        attached.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        gate.release()
        await attached.value
        XCTAssertEqual(session.refreshBus.revision, revision)
        XCTAssertEqual(activityReads, reads)
        XCTAssertEqual(durableCompletions, 1, "the admitted operation still completes")

        let revisions = MailRefreshTestCounter()
        let subscription = session.refreshBus.$revision.dropFirst().sink { _ in revisions.record() }
        let reattached = Task { await session.activity.attach() }
        await revisions.wait(for: 1)
        reattached.cancel()
        await reattached.value
        subscription.cancel()
        XCTAssertEqual(durableCompletions, 2)
        XCTAssertEqual(session.refreshBus.revision, revision + 1, "a fresh attachment remains usable")
    }

    func testSessionIsReleasedAfterAttachCancellationJoinsRefresh() async {
        weak var weakSession: MailSession?
        weak var weakSnapshot: InboxViewModelSnapshotStore?
        weak var weakActivity: MailActivityCoordinator?
        let gate = MailRefreshTestBarrier()
        do {
            let session = MailSession.make(viewModelProvider: { _ in
                await gate.wait()
                return .preview()
            })
            weakSession = session
            weakSnapshot = session.inboxSnapshot
            weakActivity = session.activity
            let attached = Task { await session.activity.attach() }
            await gate.arrived.wait(for: 1)
            attached.cancel()
            await fulfillment(of: [gate.cancelled], timeout: 5)
            gate.release()
            await attached.value
        }
        XCTAssertNil(weakSession)
        XCTAssertNil(weakSnapshot)
        XCTAssertNil(weakActivity)
    }

    func testSessionIsReleasedOnceItsPendingGraceActionCommits() async {
        weak var weakSession: MailSession?
        weak var weakActions: MessageActionController?
        do {
            let session = MailSession.make(commitDelay: .seconds(600))
            weakSession = session
            weakActions = session.actions
            session.attachAskMailHost()
            session.connectLifecycle(
                MailSessionLifecycleHooks(reportFailure: { _ in }, presentAskMail: { _ in },
                                          didRefreshApprovals: {}, allowsSmartInboxRefreshOnAppear: { true },
                                          markReadFailed: {}, attachmentEvent: { _ in }),
                locale: .current
            )
            session.actions.perform(.archive, messageID: "m1")
            await session.actions.commitPendingAndWait()
        }
        XCTAssertNil(weakSession, "a MailSession must not outlive its owner")
        XCTAssertNil(weakActions)
    }
}

private extension MailKnowledgeSource {
    static func preview(messageID: String, mailboxPath: String) -> MailKnowledgeSource {
        MailKnowledgeSource(
            id: "source-\(messageID)",
            messageID: MessageID(messageID),
            conversationKey: "conversation-\(messageID)",
            mailboxPath: mailboxPath,
            subject: "Subject",
            sender: "sender@example.com",
            sentAt: nil,
            snippet: "Snippet"
        )
    }
}
