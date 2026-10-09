import XCTest
import PlainpostCore
@testable import PlainpostUI
#if os(macOS)
import AppKit
import SwiftUI

/// The Mac sidebar lists each account's folders after the shared sections, so one account's
/// mail is a click away; All Inboxes stays the combined view.
@MainActor
final class MacSidebarAccountSectionsTests: XCTestCase {
    private func account(_ id: String, _ name: String) -> Account {
        Account(id: AccountID(id), displayName: name, email: EmailAddress("\(id)@example.com"),
                imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    }

    private func sections(_ accounts: [Account]) -> [MailboxAccountSection] {
        MailboxDirectoryModel.sections(
            accounts: accounts,
            mailboxes: accounts.flatMap { account in
                [
                    Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                            name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
                    Mailbox(id: MailboxID("\(account.id.rawValue)-archive"), accountID: account.id,
                            name: "Archive", path: "Archive", specialUse: "\\Archive"),
                ]
            },
            unreadCounts: [:]
        )
    }

    private func host(_ sections: [MailboxAccountSection], openFolder: @escaping (MailFolderRef) -> Void = { _ in }) -> AcceptanceHost {
        AcceptanceHost(
            PlainpostSidebar(
                selection: .constant(.allInboxes),
                viewModel: .designPreview(),
                smartInboxActivity: nil,
                smartInboxActivityActionInFlight: false,
                smartInboxActivityActionMessage: nil,
                pauseSmartInbox: { _ in },
                resumeSmartInbox: { _ in },
                accountSections: sections,
                openFolder: openFolder
            ),
            size: NSSize(width: 280, height: 1100)
        )
    }

    // The headless host exposes no outline rows, so the rows the sidebar lists are checked
    // through the same helper the view builds them from.

    func testTwoAccountsShowASectionEachWithTheirFolders() {
        let listed = PlainpostSidebar.listedAccountSections(sections([account("home", "Home"), account("work", "Work")]))
        XCTAssertEqual(listed.map(\.id), [AccountID("home"), AccountID("work")])
        XCTAssertEqual(listed.map(\.title), ["Home", "Work"])
        XCTAssertEqual(listed.last?.folders.map(\.id), ["work|INBOX", "work|Archive"])
    }

    func testASectionCarriesItsAccountsStatus() {
        var listed = sections([account("home", "Home"), account("work", "Work")])
        listed[1].status = .syncNodeUnreachable
        XCTAssertEqual(PlainpostSidebar.listedAccountSections(listed).map(\.status), [.ok, .syncNodeUnreachable])
        XCTAssertEqual(AccountSyncStatus.syncNodeUnreachable.message, "Sync Node unreachable")
    }

    func testOneAccountShowsNoAccountSections() {
        XCTAssertTrue(PlainpostSidebar.listedAccountSections(sections([account("home", "Home")])).isEmpty)
    }

    func testFooterSaysMailStaysOnThisDeviceWithTheAccountCount() async throws {
        let host = host(sections([account("home", "Home"), account("work", "Work")]))
        defer { host.close() }
        let footer = await host.waitFor { elements in
            let texts = elements.flatMap(HostedAX.texts)
            return texts.contains("Mail stays on this device") && texts.contains("2 accounts")
        }
        XCTAssertTrue(footer, host.axDump().joined(separator: "\n"))
    }

    func testChoosingAFolderOpensIt() {
        var opened: [MailFolderRef] = []
        let folder = MailFolderRef(accountID: AccountID("work"), path: "INBOX", name: "Inbox", role: .inbox)
        var destination = PlainpostDestination.smartInbox
        PlainpostSidebarItem.folder(folder).apply(selectDestination: { destination = $0 }, openFolder: { opened.append($0) })
        XCTAssertEqual(opened, [folder])
        XCTAssertEqual(destination, .smartInbox)
        PlainpostSidebarItem.destination(.sent).apply(selectDestination: { destination = $0 }, openFolder: { opened.append($0) })
        XCTAssertEqual(destination, .sent)
        XCTAssertEqual(
            PlainpostSidebarItem.current(destination: .allInboxes, folder: folder), .folder(folder),
            "an open folder is the sidebar's selection"
        )
        XCTAssertEqual(PlainpostSidebarItem.current(destination: .sent, folder: nil), .destination(.sent))
    }
}
#endif
