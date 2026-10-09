import Foundation
import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
import PlainpostNodeTransport
@testable import PlainpostUI

final class SettingsRootListTests: XCTestCase {
    func testDirectAccountRowsNameTheProviderAndFlagReauthorization() {
        let gmail = Account(id: AccountID("a1"), displayName: "Ada", email: EmailAddress("ada@gmail.com"),
                            username: "ada@gmail.com", sentMailbox: "Sent",
                            imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 587)
        let other = Account(id: AccountID("a2"), displayName: "Work", email: EmailAddress("me@work.test"),
                            username: "me", sentMailbox: "Sent",
                            imapHost: "mail.work.test", imapPort: 993, smtpHost: "mail.work.test", smtpPort: 587)
        let rows = SettingsAccountRow.rows(
            directAccounts: [gmail, other],
            needsReauthorization: { $0 == AccountID("a1") },
            authenticationMethod: { $0 == AccountID("a1") ? .googleOAuth : .password },
            nodeAccounts: []
        )
        XCTAssertEqual(rows.map(\.title), ["ada@gmail.com", "me@work.test"])
        XCTAssertEqual(rows.map(\.subtitle), ["Gmail", "IMAP"])
        XCTAssertEqual(rows.map(\.needsAttention), [true, false])
        XCTAssertEqual(rows.first?.destination, .account(AccountID("a1")))
        XCTAssertEqual(rows.map(\.accessibilityIdentifier), ["settings.account.a1", "settings.account.a2"])
    }

    func testNodeAccountsReplaceDirectRowsAndShowTheirState() {
        let node = NodeMailAccount.fixture(providerIdentity: "grace@example.test", state: .authenticationRequired)
        let direct = Account(id: AccountID("a1"), displayName: "Ada", email: EmailAddress("ada@gmail.com"),
                             imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com")
        let rows = SettingsAccountRow.rows(directAccounts: [direct], needsReauthorization: { _ in false },
                                           authenticationMethod: { _ in nil }, nodeAccounts: [node])
        XCTAssertEqual(rows.map(\.title), ["grace@example.test"])
        XCTAssertEqual(rows.map(\.subtitle), ["Via Sync Node"])
        XCTAssertEqual(rows.map(\.needsAttention), [true])
        XCTAssertEqual(rows.first?.destination, .nodeAccount(node.logicalMailboxID))
        XCTAssertEqual(rows.first?.accessibilityIdentifier, "settings.node-account.grace@example.test")
    }

    func testProviderNamesCoverMicrosoftAndICloud() {
        let outlook = Account(id: AccountID("m"), displayName: "M", email: EmailAddress("m@outlook.com"),
                              imapHost: "outlook.office365.com", smtpHost: "smtp.office365.com")
        let custom = Account(id: AccountID("c"), displayName: "C", email: EmailAddress("c@corp.test"),
                             imapHost: "imap.corp.test", smtpHost: "smtp.corp.test")
        let icloud = Account(id: AccountID("i"), displayName: "I", email: EmailAddress("i@icloud.com"),
                             imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com")
        XCTAssertEqual(SettingsAccountRow.providerName(outlook, method: .password), "Microsoft")
        XCTAssertEqual(SettingsAccountRow.providerName(custom, method: .microsoftOAuth), "Microsoft")
        XCTAssertEqual(SettingsAccountRow.providerName(icloud, method: .password), "iCloud")
    }

    // MARK: Selection reconciliation

    private func directRows(_ ids: [String]) -> [SettingsAccountRow] {
        SettingsAccountRow.rows(
            directAccounts: ids.map {
                Account(id: AccountID($0), displayName: $0, email: EmailAddress("\($0)@example.test"),
                        imapHost: "imap.example.test", smtpHost: "smtp.example.test")
            },
            needsReauthorization: { _ in false },
            authenticationMethod: { _ in .password },
            nodeAccounts: []
        )
    }

    func testReconciliationReplacesARemovedAccountWithTheFirstRemainingOne() {
        XCTAssertEqual(
            SettingsAccountRow.reconciledDestination(current: .account(AccountID("gone")), rows: directRows(["a1", "a2"])),
            .account(AccountID("a1"))
        )
        XCTAssertEqual(
            SettingsAccountRow.reconciledDestination(current: .account(AccountID("gone")), rows: []),
            .section(.accounts)
        )
        let node = NodeMailAccount.fixture(providerIdentity: "grace@example.test")
        XCTAssertEqual(
            SettingsAccountRow.reconciledDestination(current: .nodeAccount(node.logicalMailboxID), rows: directRows(["a1"])),
            .account(AccountID("a1"))
        )
    }

    func testReconciliationFillsAnEmptySelection() {
        XCTAssertEqual(SettingsAccountRow.reconciledDestination(current: nil, rows: directRows(["a1"])), .account(AccountID("a1")))
        XCTAssertEqual(SettingsAccountRow.reconciledDestination(current: nil, rows: []), .section(.accounts))
    }

    func testReconciliationKeepsAStillListedAccountAndAnySection() {
        let rows = directRows(["a1", "a2"])
        XCTAssertEqual(SettingsAccountRow.reconciledDestination(current: .account(AccountID("a2")), rows: rows), .account(AccountID("a2")))
        XCTAssertEqual(SettingsAccountRow.reconciledDestination(current: .section(.privacy), rows: []), .section(.privacy))
        XCTAssertEqual(SettingsAccountRow.reconciledDestination(current: .section(.accounts), rows: rows), .section(.accounts))
    }

    func testReconciliationPromotesADefaultAddAccountOnlyWhenAsked() {
        let rows = directRows(["a1"])
        XCTAssertEqual(
            SettingsAccountRow.reconciledDestination(current: .section(.accounts), rows: rows, promotingAddAccount: true),
            .account(AccountID("a1"))
        )
        XCTAssertEqual(
            SettingsAccountRow.reconciledDestination(current: .section(.accounts), rows: [], promotingAddAccount: true),
            .section(.accounts)
        )
        XCTAssertEqual(
            SettingsAccountRow.reconciledDestination(current: .section(.privacy), rows: rows, promotingAddAccount: true),
            .section(.privacy)
        )
    }

    // MARK: Navigation style

    /// Only the iPhone stack (which registers a `MobileRoute` destination) may push. The Mac
    /// sidebar and the iPad split column have no `MobileRoute` handler, so pushed rows there
    /// would be dead; they must drive the selection binding.
    func testOnlyTheIPhoneListPushesRoutesEveryOtherRootListDrivesSelection() throws {
        let selectionCallers = [
            "Sources/PlainpostUI/PlainpostRootView.swift",
            "Sources/PlainpostUI/PlainpostSettingsViews.swift",
            "Sources/PlainpostUI/AccountSecuritySettingsView.swift",
        ]
        for path in selectionCallers {
            let source = try Self.source(path)
            let lists = source.components(separatedBy: "SettingsRootList(").count - 1
            XCTAssertGreaterThan(lists, 0, path)
            XCTAssertEqual(source.components(separatedBy: "navigation: .selection").count - 1, lists, path)
            XCTAssertFalse(source.contains("navigation: .push"), path)
        }
        let mobile = try Self.source("Sources/PlainpostUI/Mobile/MobileSettingsScreens.swift")
        XCTAssertTrue(mobile.contains("navigation: .push"))
        XCTAssertFalse(mobile.contains("navigation: .selection"))
        let rootList = try Self.source("Sources/PlainpostUI/Settings/SettingsRootList.swift")
        XCTAssertFalse(rootList.contains("#if os(macOS)"), "Row navigation must follow `navigation`, not the platform.")
        XCTAssertEqual(rootList.components(separatedBy: "NavigationLink(value: MobileRoute").count - 1, 1, "Only the .push branch pushes a route.")
    }

    #if os(macOS)
    /// Every sidebar row, not only the account rows, must move the selection when clicked.
    @MainActor
    func testClickingAnyMacSidebarRowSelectsItsPage() throws {
        let rows = directRows(["a", "b"])
        let host = SelectionHost(rows: rows)
        let hostingView = NSHostingView(rootView: host.view.frame(width: 260, height: 900))
        hostingView.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        Self.retainedWindows.append(window)

        let table = try XCTUnwrap(Self.descendants(of: hostingView).compactMap { $0 as? NSTableView }.first)
        let expected: [PlainpostSettingsDestination] = rows.map(\.destination) + [.section(.accounts)]
            + PlainpostSettingsGroup.allCases.flatMap { $0.sections.map { .section($0) } }
        var clicked: [PlainpostSettingsDestination] = []
        for row in 0..<table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let selection = host.selection { clicked.append(selection) }
            host.selection = nil
        }
        XCTAssertGreaterThan(table.numberOfRows, expected.count)
        XCTAssertEqual(clicked, expected)
    }

    @MainActor private static var retainedWindows: [NSWindow] = []

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
    #endif

    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private extension NodeMailAccount {
    static func fixture(
        providerIdentity: String,
        state: NodeSyncMailAccountState = .ready
    ) -> NodeMailAccount {
        NodeMailAccount(
            logicalMailboxID: LogicalMailboxID(rawValue: Data(repeating: 0x41, count: 32))!,
            providerIdentity: providerIdentity,
            providerKind: "gmail",
            isPrimary: true,
            state: state,
            mailboxes: []
        )
    }
}

#if os(macOS)
/// Holds the sidebar's selection outside SwiftUI so a test can read what a click chose.
@MainActor
private final class SelectionHost {
    var selection: PlainpostSettingsDestination?
    let rows: [SettingsAccountRow]

    init(rows: [SettingsAccountRow]) { self.rows = rows }

    var view: some View {
        SettingsRootList(
            selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
            accountRows: rows,
            navigation: .selection
        )
    }
}
#endif
