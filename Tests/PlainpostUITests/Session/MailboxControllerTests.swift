import Combine
import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class MailboxControllerTests: XCTestCase {
    private func makeController() -> MailboxController {
        MailboxController(
            destination: .smartInbox,
            mode: InboxDisplayMode.focusedList.rawValue,
            selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .smartInboxOverview)
        )
    }

    func testCurrentAllInboxesMessageOpenNormalizesRetainedSmartContextsWhileDisabled() {
        let controller = makeController()
        controller.applySmartInboxEnabled(false)
        for context: MailboxListContext in [.smartInboxOverview, .smartInboxBundle(.newsletters), .mailbox(destination: .smartInbox, mode: .simpleList)] {
            controller.openMessage("m1", from: context)
            let mode: InboxDisplayMode
            if case let .mailbox(_, contextMode) = context { mode = contextMode }
            else { mode = .focusedList }
            XCTAssertEqual(controller.selectedDestination, .allInboxes)
            XCTAssertEqual(controller.mailboxNavigation.route,
                .reader(messageID: "m1", returnContext: .mailbox(destination: .allInboxes, mode: mode)))
            controller.returnToList()
            XCTAssertEqual(controller.mailboxNavigation.route,
                .list(.mailbox(destination: .allInboxes, mode: mode)))
        }
        controller.openMessage("m2", destination: .drafts,
            from: .mailbox(destination: .drafts, mode: .simpleList))
        XCTAssertEqual(controller.selectedDestination, .drafts)
        XCTAssertEqual(controller.mailboxNavigation.route,
            .reader(messageID: "m2", returnContext: .mailbox(destination: .drafts, mode: .simpleList)))
    }

    func testOpenAndReturnWalkTheRoute() {
        let controller = makeController()
        var routes: [MailboxWorkspaceRoute] = []
        controller.onRouteChange = { routes.append($0) }
        controller.openMessage("m1", from: .smartInboxOverview)
        XCTAssertEqual(controller.selectedMessageID, "m1")
        XCTAssertEqual(controller.mailboxNavigation.route, .reader(messageID: "m1", returnContext: .smartInboxOverview))
        controller.returnToList()
        XCTAssertEqual(controller.mailboxNavigation.route, .list(.smartInboxOverview))
        XCTAssertEqual(routes.count, 2)
    }

    func testOpenMessageBumpsNavigationRevision() {
        let controller = makeController()
        let before = controller.navigationRevision
        controller.openMessage("m1", from: .smartInboxOverview)
        XCTAssertGreaterThan(controller.navigationRevision, before)
    }

    func testSetDestinationChangesDestinationAndMode() {
        let controller = makeController()
        controller.setDestination(.drafts, displayMode: InboxDisplayMode.simpleList.rawValue)
        XCTAssertEqual(controller.selectedDestination, .drafts)
        XCTAssertEqual(controller.selectedInboxMode, InboxDisplayMode.simpleList.rawValue)
    }

    func testAdjacentMessageFollowsListOrder() {
        let controller = makeController()
        controller.openMessage("b", from: .smartInboxOverview)
        XCTAssertEqual(controller.adjacentMessageID(.next, in: ["a", "b", "c"]), "c")
        XCTAssertEqual(controller.adjacentMessageID(.previous, in: ["a", "b", "c"]), "a")
        XCTAssertNil(controller.adjacentMessageID(.next, in: ["a", "b"]))
        XCTAssertNil(controller.adjacentMessageID(.next, in: ["x"]), "selection not in list")
    }

    func testRefreshBusCountsBumps() {
        let bus = MailboxRefreshBus()
        bus.bump(); bus.bump()
        XCTAssertEqual(bus.revision, 2)
    }

    private func row(_ id: String, unread: Bool = true, category: SmartCategory = .personal) -> MessageRowModel {
        MessageRowModel(
            id: id, sender: "\(id)@example.test", subject: id, preview: "",
            category: category, categoryLabel: category.displayName,
            isUnread: unread, isPinned: false, dateLabel: "", actions: []
        )
    }

    func testUnreadFilterKeepsAMessageOpenedWhileFiltering() {
        let controller = makeController()
        controller.setUnreadOnly(true)
        XCTAssertEqual(controller.visibleRows([row("a"), row("b", unread: false)]).map(\.id), ["a"])

        controller.openMessage("a", from: .smartInboxOverview)
        let afterOpen = [row("a", unread: false), row("b", unread: false)]
        XCTAssertEqual(controller.visibleRows(afterOpen).map(\.id), ["a"], "the opened row stays until you leave")

        controller.setUnreadOnly(false)
        controller.setUnreadOnly(true)
        XCTAssertEqual(controller.visibleRows(afterOpen).map(\.id), [])
    }

    func testCategoryChipFiltersByDisplayBundle() {
        let controller = makeController()
        let rows = [row("r", category: .receipt), row("p"), row("f", category: .finance),
                    row("i", category: .invitation), row("ir", category: .invitationResponse)]
        controller.selectedCategory = .updates
        XCTAssertEqual(controller.visibleRows(rows).map(\.id), ["r", "f"])
        controller.selectedCategory = .invitations
        XCTAssertEqual(controller.visibleRows(rows).map(\.id), ["i", "ir"], "responses sit with invitations")
    }

    func testResetFiltersClearsChipUnreadAndKeptRows() {
        let controller = makeController()
        controller.selectedCategory = .people
        controller.setUnreadOnly(true)
        controller.openMessage("a", from: .smartInboxOverview)
        XCTAssertEqual(controller.keptUnreadIDs, ["a"], "opening it while Unread Only is on keeps it listed")
        controller.resetFilters()
        XCTAssertNil(controller.selectedCategory)
        XCTAssertFalse(controller.unreadOnly)
        XCTAssertTrue(controller.keptUnreadIDs.isEmpty)
    }

    func testReturningFromSearchWithoutAHitKeepsTheListAndItsFilters() {
        let controller = makeController()
        controller.selectedCategory = .updates
        controller.setUnreadOnly(true)
        // A display mode that differs from the one `returnFromSearch` would force (focusedList)
        // if it ran, so a guard that stopped guarding would show up as a changed mode, not just
        // as a same-destination no-op that happens to look identical either way.
        controller.setDisplayMode(InboxDisplayMode.simpleList.rawValue)
        let route = controller.mailboxNavigation.route
        let revision = controller.navigationRevision

        controller.returnFromSearch(to: .smartInbox)

        XCTAssertEqual(controller.selectedDestination, .smartInbox)
        XCTAssertEqual(controller.selectedInboxMode, InboxDisplayMode.simpleList.rawValue,
                       "a destination that never moved keeps its own display mode, not the one a hit would force")
        XCTAssertEqual(controller.selectedCategory, .updates)
        XCTAssertTrue(controller.unreadOnly)
        XCTAssertEqual(controller.mailboxNavigation.route, route)
        XCTAssertEqual(controller.navigationRevision, revision)
    }

    func testReturningFromSearchAfterAHitRepointsTheListAndKeepsItsFilters() {
        let controller = makeController()
        controller.selectedCategory = .people
        controller.setUnreadOnly(true)
        // Opening a search hit moves the shared destination to All Inboxes.
        controller.setDestination(.allInboxes, displayMode: InboxDisplayMode.focusedList.rawValue)
        controller.openMessage("hit", destination: .allInboxes, from: controller.currentListContext())
        controller.returnToList()

        controller.returnFromSearch(to: .smartInbox)

        XCTAssertEqual(controller.selectedDestination, .smartInbox)
        XCTAssertEqual(controller.selectedInboxMode, InboxDisplayMode.focusedList.rawValue)
        XCTAssertEqual(controller.mailboxNavigation.route, .list(controller.currentListContext()))
        XCTAssertEqual(controller.selectedCategory, .people, "Search must not clear the chip")
        XCTAssertTrue(controller.unreadOnly, "Search must not clear Unread Only")
    }

    /// Smart Inbox → open m1 → Back → All Inboxes → Smart Inbox, as the iPhone shell drives it.
    private func detourAfterOpeningM1(_ controller: MailboxController) {
        controller.enterMailbox(.smartInbox, unreadOnly: false)
        controller.openMessage("m1", destination: .smartInbox, from: controller.currentListContext())
        controller.returnToList()
        controller.enterMailbox(.allInboxes, unreadOnly: false)
        controller.enterMailbox(.smartInbox, unreadOnly: false)
    }

    func testIPhoneListDoesNotRestoreALeftConversationsSelection() {
        let controller = makeController()
        controller.restoresListSelection = false
        controller.enterMailbox(.smartInbox, unreadOnly: false)
        controller.openMessage("m1", destination: .smartInbox, from: controller.currentListContext())

        controller.returnToList()
        XCTAssertNil(controller.selectedMessageID, "Back from a conversation leaves no hidden selection")

        controller.openMessage("m1", destination: .smartInbox, from: controller.currentListContext())
        controller.returnToList()
        controller.enterMailbox(.allInboxes, unreadOnly: false)
        controller.enterMailbox(.smartInbox, unreadOnly: false)
        XCTAssertNil(controller.selectedMessageID, "re-entering the mailbox must not restore m1")
        XCTAssertEqual(controller.mailboxNavigation.route, .list(.smartInboxOverview))
    }

    func testIPhoneReturnFromSearchDoesNotRestoreASelection() {
        let controller = makeController()
        controller.restoresListSelection = false
        controller.enterMailbox(.smartInbox, unreadOnly: false)
        controller.openMessage("m1", destination: .smartInbox, from: controller.currentListContext())
        controller.returnToList()
        // A search hit moves the shared destination and opens its message.
        controller.setDestination(.allInboxes, displayMode: InboxDisplayMode.focusedList.rawValue)
        controller.openMessage("hit", destination: .allInboxes, from: controller.currentListContext())
        controller.returnToList()

        controller.returnFromSearch(to: .smartInbox)

        XCTAssertEqual(controller.selectedDestination, .smartInbox)
        XCTAssertNil(controller.selectedMessageID)
    }

    func testSplitViewStillRestoresTheListSelection() {
        // macOS and iPad show the restored selection in their reader, so it stays.
        let controller = makeController()
        detourAfterOpeningM1(controller)
        XCTAssertEqual(controller.selectedMessageID, "m1")
    }

    func testIPhoneDetourSendsNoHumanOpenForTheLeftMessage() async throws {
        let controller = makeController()
        controller.restoresListSelection = false
        var opened: [String] = []
        let opener = HumanMessageOpenCoordinator { opened.append($0.rawValue) }
        var selections: [String?] = []
        let watch = controller.$selectedMessageID.dropFirst().sink { selections.append($0) }
        defer { watch.cancel() }

        detourAfterOpeningM1(controller)

        XCTAssertNil(controller.selectedMessageID)
        // `MailSessionLifecycle` runs one human open (setRead on a Node) per selection change.
        for selection in selections { try await opener.openIfPresent(selection) }
        XCTAssertEqual(opened, ["m1"], "only the explicit open marks read; the detour sends no setRead")
    }

    func testChipsListInvitationsOnlyWhenPresent() {
        XCTAssertEqual(SmartInboxDisplayBundle.chips(for: [row("p")]), [.people, .notifications, .updates, .newsletters])
        XCTAssertEqual(SmartInboxDisplayBundle.chips(for: [row("i", category: .invitationResponse)]).last, .invitations)
    }

    // MARK: - Account folders

    private let work = MailFolderRef(accountID: AccountID("work"), path: "INBOX", name: "Inbox", role: .inbox)
    private let workArchive = MailFolderRef(accountID: AccountID("work"), path: "Archive", name: "Archive", role: .archive)

    func testOpeningAFolderShowsAllInboxesNarrowedToIt() {
        let controller = makeController()
        controller.openFolder(work)
        XCTAssertEqual(controller.selectedFolder, work)
        XCTAssertEqual(controller.selectedDestination, .allInboxes)
    }

    func testChoosingADestinationClearsTheFolder() {
        let controller = makeController()
        controller.openFolder(work)
        controller.setDestination(.sent)
        XCTAssertNil(controller.selectedFolder)
        XCTAssertEqual(controller.selectedDestination, .sent)
        controller.openFolder(work)
        controller.setDestination(.allInboxes)
        XCTAssertNil(controller.selectedFolder, "All Inboxes returns to the combined view")
    }

    func testChoosingAnotherFolderReplacesIt() {
        let controller = makeController()
        controller.openFolder(work)
        controller.openFolder(workArchive)
        XCTAssertEqual(controller.selectedFolder, workArchive)
    }

    func testAFolderWhoseAccountLeavesReturnsToAllInboxes() {
        let controller = makeController()
        controller.openFolder(work)
        controller.reconcileFolder(withAccounts: [AccountID("home")])
        XCTAssertNil(controller.selectedFolder)
        XCTAssertEqual(controller.selectedDestination, .allInboxes)
        controller.openFolder(work)
        controller.reconcileFolder(withAccounts: [AccountID("work")])
        XCTAssertEqual(controller.selectedFolder, work, "a present account keeps its folder")
    }

    func testAnyOtherDestinationClearsTheFolderEvenWhenSetDirectly() {
        let controller = makeController()
        controller.openFolder(work)
        controller.selectedDestination = .calendar
        XCTAssertNil(controller.selectedFolder)
    }

    /// A message opened from search, a notification or Ask Mail isn't from the folder list:
    /// the folder closes so the list and reader agree. A row opened in the folder keeps it.
    func testOpeningAMessageFromElsewhereLeavesTheFolder() {
        let controller = makeController()
        controller.openFolder(work)
        controller.openMessage("m1", destination: .allInboxes, from: .mailbox(destination: .allInboxes, mode: .focusedList))
        XCTAssertNil(controller.selectedFolder)
        controller.openFolder(work)
        controller.openMessage(
            "m2", destination: .allInboxes, from: .mailbox(destination: .allInboxes, mode: .focusedList),
            keepingFolder: true
        )
        XCTAssertEqual(controller.selectedFolder, work)
    }

    /// Down to one account the sidebar lists no account folders, so none stays open.
    func testOneListedAccountLeavesTheFolder() {
        let controller = makeController()
        controller.openFolder(work)
        let work = Account(id: AccountID("work"), displayName: "Work", email: EmailAddress("work@example.com"),
                           imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        controller.reconcileFolder(withDirectory: MailboxDirectoryModel.sections(accounts: [work], mailboxes: [], unreadCounts: [:]))
        XCTAssertNil(controller.selectedFolder)
        controller.openFolder(self.work)
        controller.reconcileFolder(withDirectory: [])
        XCTAssertEqual(controller.selectedFolder, self.work, "an unloaded directory says nothing")
    }
}
