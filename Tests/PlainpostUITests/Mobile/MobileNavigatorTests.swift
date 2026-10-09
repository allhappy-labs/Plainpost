import XCTest
import PlainpostCore
@testable import PlainpostUI

final class MobileNavigatorTests: XCTestCase {
    private let smartInboxReader = MailboxWorkspaceRoute.reader(messageID: "m1", returnContext: .smartInboxOverview)
    private let allInboxesContext = MailboxListContext.mailbox(destination: .allInboxes, mode: .focusedList)

    func testDisabledSmartInboxRetiresReaderAndSettingsBreadcrumbsAndStaysOffUntilExplicitOpen() {
        var navigator = MobileNavigator(path: [.mailbox(.smartInbox), .conversation(messageID: "m1"), .settings])
        navigator.applySmartInboxEnabled(false)
        XCTAssertEqual(navigator.path, [.mailbox(.allInboxes)])
        navigator.applySmartInboxEnabled(true)
        XCTAssertEqual(navigator.path, [.mailbox(.allInboxes)])
        navigator.openMailbox(.smartInbox)
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox)])
    }

    func testLaunchPathIsSmartInboxAboveMailboxes() {
        XCTAssertEqual(MobileNavigator().path, [.mailbox(.smartInbox)])
    }

    func testConversationPathUnwindsOneLevelPerBack() {
        var navigator = MobileNavigator()
        navigator.reconcile(destination: .smartInbox, route: smartInboxReader)
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox), .conversation(messageID: "m1")])

        XCTAssertEqual(navigator.applySystemPath([.mailbox(.smartInbox)]), [.returnFromConversation])
        navigator.reconcile(destination: .smartInbox, route: .list(.smartInboxOverview))
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox)], "one Back leaves the mailbox on screen")

        XCTAssertEqual(navigator.applySystemPath([]), [.leaveMailbox])
        XCTAssertEqual(navigator.path, [])
    }

    func testSearchResultReturnsToSearchThenToTheMailbox() {
        var navigator = MobileNavigator()
        navigator.openSearch()
        // Opening a hit moves the shared state to All Inboxes.
        navigator.reconcile(destination: .allInboxes, route: .reader(messageID: "m2", returnContext: allInboxesContext))
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox), .search, .conversation(messageID: "m2")])

        XCTAssertEqual(navigator.applySystemPath([.mailbox(.smartInbox), .search]), [.returnFromConversation])
        navigator.reconcile(destination: .allInboxes, route: .list(allInboxesContext))
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox), .search], "results stay on screen")

        XCTAssertEqual(
            navigator.applySystemPath([.mailbox(.smartInbox)]),
            [.closeSearch, .showMailbox(.smartInbox)]
        )
    }

    func testUnchangedSystemPathProducesNoEffects() {
        var navigator = MobileNavigator(path: [.mailbox(.smartInbox), .conversation(messageID: "m1")])
        XCTAssertEqual(navigator.applySystemPath(navigator.path), [])
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox), .conversation(messageID: "m1")])
    }

    func testPopToRootReportsEveryLevel() {
        var navigator = MobileNavigator()
        navigator.openSearch()
        navigator.reconcile(destination: .allInboxes, route: .reader(messageID: "m2", returnContext: allInboxesContext))
        XCTAssertEqual(navigator.applySystemPath([]), [.returnFromConversation, .closeSearch, .leaveMailbox])
    }

    func testExternalOpenFromRootBuildsMailboxAndConversation() {
        var navigator = MobileNavigator(path: [])
        navigator.reconcile(destination: .allInboxes, route: .reader(messageID: "n1", returnContext: allInboxesContext))
        XCTAssertEqual(navigator.path, [.mailbox(.allInboxes), .conversation(messageID: "n1")])

        var fromApprovals = MobileNavigator(path: [])
        fromApprovals.openApprovals()
        fromApprovals.reconcile(destination: .allInboxes, route: .reader(messageID: "n1", returnContext: allInboxesContext))
        XCTAssertEqual(fromApprovals.path, [.mailbox(.allInboxes), .conversation(messageID: "n1")])
    }

    func testListRouteOnTheRootOrAUtilityChangesNothing() {
        var root = MobileNavigator(path: [])
        root.reconcile(destination: .smartInbox, route: .list(.smartInboxOverview))
        XCTAssertEqual(root.path, [], "popping to Mailboxes is never undone by a refresh")

        var settings = MobileNavigator(path: [.settings, .settingsDestination(.section(.smartInbox))])
        settings.reconcile(destination: .smartInbox, route: .list(.smartInboxOverview))
        XCTAssertEqual(settings.path, [.settings, .settingsDestination(.section(.smartInbox))])
    }

    func testReconcileIgnoresNonMailboxDestinations() {
        var navigator = MobileNavigator()
        navigator.reconcile(destination: .settings, route: smartInboxReader)
        navigator.reconcile(destination: .approvalQueue, route: smartInboxReader)
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox)])
    }

    func testAdjacentOpenReplacesTheConversation() {
        var navigator = MobileNavigator(path: [.mailbox(.smartInbox), .conversation(messageID: "m1")])
        navigator.reconcile(destination: .smartInbox, route: .reader(messageID: "m2", returnContext: .smartInboxOverview))
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox), .conversation(messageID: "m2")])
    }

    func testFolderMailboxKeepsItsLevelWhenAConversationOpens() {
        let sent = MailFolderRef(accountID: AccountID("a"), path: "Sent", name: "Sent")
        var navigator = MobileNavigator(path: [])
        navigator.openMailbox(.folder(sent))
        navigator.reconcile(destination: .allInboxes, route: .reader(messageID: "s1", returnContext: allInboxesContext))
        XCTAssertEqual(navigator.path, [.mailbox(.folder(sent)), .conversation(messageID: "s1")])
    }

    func testUtilitiesStackAndPopWithoutEffects() {
        var navigator = MobileNavigator(path: [])
        navigator.openApproval(requestID: "r1")
        XCTAssertEqual(navigator.path, [.approvals, .approval(requestID: "r1")])
        XCTAssertEqual(navigator.applySystemPath([.approvals]), [])
        XCTAssertEqual(navigator.applySystemPath([]), [])
    }

    func testSettingsAlwaysOpensOnItsList() {
        var navigator = MobileNavigator(path: [])
        navigator.openSettings()
        _ = navigator.applySystemPath([.settings, .settingsDestination(.section(.smartInbox))])
        navigator.openSettings()
        XCTAssertEqual(navigator.path, [.settings])
    }

    func testResetToLaunchStartsAtSmartInbox() {
        var navigator = MobileNavigator(path: [.settings, .settingsDestination(.section(.rulesLabels))])
        navigator.resetToLaunch()
        XCTAssertEqual(navigator.path, MobileNavigator.launchPath)
    }

    func testMailboxTitlesAndDestinations() {
        XCTAssertEqual(MobileMailbox.unread.title, "Unread")
        XCTAssertEqual(MobileMailbox.unread.destination, .allInboxes)
        XCTAssertEqual(MobileMailbox.smartInbox.destination, .smartInbox)
        XCTAssertEqual(MobileMailbox.forDestination(.sent), .allInboxes)
        XCTAssertEqual(MobileMailbox.folder(MailFolderRef(accountID: AccountID("a"), path: "[Gmail]/Sent Mail", name: "Sent Mail")).title, "Sent Mail")
    }

    func testSubtitleNamesTheAccountAndUnreadCount() {
        XCTAssertEqual(MobileMailbox.subtitle(accountTitles: ["reader@example.test"], unread: 3), "reader@example.test · 3 unread")
        XCTAssertEqual(MobileMailbox.subtitle(accountTitles: ["a@x", "b@y"], unread: 0), "All accounts")
        XCTAssertEqual(MobileMailbox.subtitle(accountTitles: [], unread: 1), "All accounts · 1 unread")
    }

    func testEmptyStateNamesWhatTheFolderHolds() {
        func folder(_ name: String, _ role: MailboxFolder.Role) -> MobileMailbox {
            .folder(MailFolderRef(accountID: AccountID("a"), path: name, name: name, role: role))
        }
        func empty(_ mailbox: MobileMailbox, unreadOnly: Bool = false, category: String? = nil) -> [String] {
            let state = mailbox.emptyState(unreadOnly: unreadOnly, categoryTitle: category)
            return [state.title, state.detail]
        }
        XCTAssertEqual(empty(.allInboxes), ["No Mail", "New messages appear here."])
        XCTAssertEqual(empty(.unread), ["No Unread Mail", "You're all caught up."])
        XCTAssertEqual(empty(.smartInbox, category: "Updates"), ["Nothing in Updates", "New messages appear here."])
        XCTAssertEqual(empty(.smartInbox, unreadOnly: true, category: "Updates"), ["Nothing in Updates", "You're all caught up."])
        XCTAssertEqual(empty(folder("Drafts", .drafts)), ["No Drafts", "Drafts you save appear here."])
        XCTAssertEqual(empty(folder("Sent", .sent)), ["No Sent Mail", "Messages you send appear here."])
        XCTAssertEqual(empty(folder("Archive", .archive)), ["No Archived Mail", "Messages you archive appear here."])
        XCTAssertEqual(empty(folder("Spam", .junk)), ["No Junk Mail", "Messages in Spam appear here."])
        XCTAssertEqual(empty(folder("Trash", .trash)), ["Trash Is Empty", "Messages in Trash appear here."])
        XCTAssertEqual(empty(folder("Receipts", .other)), ["No Mail", "Messages in Receipts appear here."])
        XCTAssertEqual(empty(folder("Sent", .sent), unreadOnly: true), ["No Unread Mail", "You're all caught up."])
    }

    func testDeleteInsideTrashIsTheExplicitDeletePermanently() {
        let trash = MobileMailbox.folder(MailFolderRef(accountID: AccountID("a"), path: "Trash", name: "Trash", role: .trash))
        let sent = MobileMailbox.folder(MailFolderRef(accountID: AccountID("a"), path: "Sent", name: "Sent", role: .sent))
        // Only a recognized Trash folder turns Delete into the permanent action, with its title.
        XCTAssertEqual(trash.removalActions(primary: .delete), [.deletePermanently, .archive])
        XCTAssertEqual(trash.removalActions(primary: .archive), [.archive, .deletePermanently])
        XCTAssertEqual(trash.removalTitle(for: .deletePermanently), "Delete Permanently")
        XCTAssertEqual(trash.removalTitle(for: .archive), "Archive")
        XCTAssertEqual(sent.removalActions(primary: .delete), [.delete, .archive])
        // A Sync Node runtime never erases: its Trash offers no Delete at all, not one that always fails.
        XCTAssertEqual(trash.removalActions(primary: .delete, offersPermanentDelete: false), [.archive])
        XCTAssertEqual(trash.removalActions(primary: .archive, offersPermanentDelete: false), [.archive])
        XCTAssertEqual(sent.removalActions(primary: .delete, offersPermanentDelete: false), [.delete, .archive])
        XCTAssertEqual(sent.removalTitle(for: .delete), "Delete")
        XCTAssertEqual(MobileMailbox.allInboxes.removalTitle(for: .delete), "Delete")
        XCTAssertEqual(MobileMailbox.smartInbox.removalTitle(for: .archive), "Archive")
    }

    func testAConversationOpenedFromOutsideItsListDoesNotActInThatList() {
        let trash = MobileMailbox.folder(MailFolderRef(accountID: AccountID("a"), path: "Trash", name: "Trash", role: .trash))
        // Ask Mail opens an Archive message while Smart Inbox is underneath.
        XCTAssertNil(MobileMailbox.actionList(under: .smartInbox, messageID: "archived", listMessageIDs: ["m1", "m2"]))
        // A notification opens an Inbox message over a Trash list: no Delete Permanently for it.
        XCTAssertNil(MobileMailbox.actionList(under: trash, messageID: "inbox-1", listMessageIDs: ["t1"]))
        XCTAssertEqual(MobileMailbox.actionList(under: trash, messageID: "t1", listMessageIDs: ["t1"]), trash)
        XCTAssertEqual(MobileMailbox.actionList(under: .smartInbox, messageID: "m1", listMessageIDs: ["m1"]), .smartInbox)
        XCTAssertNil(MobileMailbox.actionList(under: nil, messageID: "m1", listMessageIDs: ["m1"]), "Search has no list")
    }

    func testActionsActOnTheShownMailboxCopy() {
        let sent = MobileMailbox.folder(MailFolderRef(accountID: AccountID("a"), path: "[Gmail]/Sent Mail", name: "Sent Mail", role: .sent))
        XCTAssertEqual(sent.shownMailboxPath, "[Gmail]/Sent Mail")
        XCTAssertEqual(MobileMailbox.allInboxes.shownMailboxPath, "INBOX")
        XCTAssertEqual(MobileMailbox.smartInbox.shownMailboxPath, "INBOX")
        XCTAssertEqual(MobileMailbox.unread.shownMailboxPath, "INBOX")
    }

    func testArchiveIsNotOfferedInsideAnArchiveFolder() {
        let archive = MobileMailbox.folder(MailFolderRef(accountID: AccountID("a"), path: "Archive", name: "Archive", role: .archive))
        let trash = MobileMailbox.folder(MailFolderRef(accountID: AccountID("a"), path: "Trash", name: "Trash", role: .trash))
        XCTAssertEqual(archive.removalActions(primary: .archive), [.delete], "Gmail's primary Archive becomes Delete")
        XCTAssertEqual(archive.removalActions(primary: .delete), [.delete], "the secondary Archive is dropped")
        XCTAssertEqual(trash.removalActions(primary: .delete), [.deletePermanently, .archive])
        XCTAssertEqual(MobileMailbox.allInboxes.removalActions(primary: .archive), [.archive, .delete])
        XCTAssertEqual(MobileMailbox.smartInbox.removalActions(primary: .delete), [.delete, .archive])
    }

    func testNotificationLaunchOpensTheConversationAboveItsMailbox() {
        var navigator = MobileNavigator()
        navigator.adoptLaunchDestination(.smartInbox)
        navigator.reconcile(destination: .smartInbox, route: .reader(messageID: "n1", returnContext: .smartInboxOverview))
        XCTAssertEqual(navigator.path, [.mailbox(.smartInbox), .conversation(messageID: "n1")])
    }

    func testAccountInboxNotificationLaunchesInAllInboxes() {
        var navigator = MobileNavigator()
        navigator.adoptLaunchDestination(.allInboxes)
        XCTAssertEqual(navigator.path, [.mailbox(.allInboxes)])
        navigator.adoptLaunchDestination(.smartInbox)
        XCTAssertEqual(navigator.path, [.mailbox(.allInboxes)], "only the untouched launch path follows")
    }
}
