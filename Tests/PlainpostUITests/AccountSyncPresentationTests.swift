import XCTest
import PlainpostNodeTransport
@testable import PlainpostCore
@testable import PlainpostOperations
@testable import PlainpostUI

final class AccountSyncPresentationTests: XCTestCase {
    func testKeepOnDeviceMapsStoredValuesToTheNearestOption() {
        XCTAssertEqual(KeepOnDeviceOption.current(downloadCompleteHistory: true, recentMessageLimit: 100), .allMail)
        XCTAssertEqual(KeepOnDeviceOption.current(downloadCompleteHistory: false, recentMessageLimit: 25), .last100)
        XCTAssertEqual(KeepOnDeviceOption.current(downloadCompleteHistory: false, recentMessageLimit: 375), .last250)
        XCTAssertEqual(KeepOnDeviceOption.current(downloadCompleteHistory: false, recentMessageLimit: 376), .last500)
        XCTAssertEqual(KeepOnDeviceOption.current(downloadCompleteHistory: false, recentMessageLimit: 1000), .last1000)
        XCTAssertEqual(KeepOnDeviceOption.allCases.map(\.title),
                       ["Last 100 messages", "Last 250 messages", "Last 500 messages", "Last \(1000.formatted()) messages", "All mail"])
    }

    func testMailboxNamesAreFriendly() {
        XCTAssertEqual(MailboxDisplayName.name(for: "INBOX"), "Inbox")
        XCTAssertEqual(MailboxDisplayName.name(for: "[Gmail]/Sent Mail"), "Sent Mail")
        XCTAssertEqual(MailboxDisplayName.name(for: "INBOX.Receipts"), "Receipts")
        XCTAssertEqual(MailboxDisplayName.name(for: "Archive"), "Archive")
    }

    // With no estimate yet the download shows no "0 of 0" count.
    func testDownloadProgressWithoutAnEstimateSaysDownloading() {
        XCTAssertEqual(DownloadProgressText.text(downloaded: 0, estimatedTotal: 0), "Downloading")
        XCTAssertEqual(DownloadProgressText.text(downloaded: 0, estimatedTotal: nil), "Downloading")
        XCTAssertEqual(DownloadProgressText.text(downloaded: 12, estimatedTotal: 40), "Downloading \(12.formatted()) of \(40.formatted())")
    }

    // A folder sync that hasn't counted its messages yet shows no "0 of 0".
    func testAccountSyncProgressWithoutATotalSaysDownloading() {
        XCTAssertEqual(
            AccountSetupViewModel.syncProgressMessage(
                .syncingMailbox(path: "INBOX", phase: "recent-import", completed: 0, total: 0)
            ),
            "Downloading"
        )
        XCTAssertEqual(
            AccountSetupViewModel.syncProgressMessage(
                .syncingMailbox(path: "INBOX", phase: "recent-import", completed: 3, total: 40)
            ),
            "Downloading \(3.formatted()) of \(40.formatted()) messages"
        )
        XCTAssertEqual(AccountSetupViewModel.syncProgressMessage(.downloading(completed: 0, total: 0)), "No messages yet")
    }

    // The banner names the button it points at: Sign in again.
    @MainActor
    func testReauthorizationBannerAsksToSignInAgain() {
        for microsoft in [false, true] {
            let body = OAuthReauthorizationBanner.defaultMessage(microsoft: microsoft)
            XCTAssertTrue(body.hasSuffix("until you sign in again."), body)
            XCTAssertFalse(body.localizedCaseInsensitiveContains("reauthorize"), body)
        }
    }

    // A password account whose saved sign-in was set aside asks for its password again.
    @MainActor
    func testPasswordBannerAsksForThePasswordAgain() {
        let title = OAuthReauthorizationBanner.passwordTitle
        let body = OAuthReauthorizationBanner.passwordMessage
        XCTAssertEqual(title, "Enter your password again")
        XCTAssertTrue(body.hasSuffix("until you enter it again."), body)
        for jargon in ["reauthorize", "vault", "keychain", "credential"] {
            XCTAssertFalse(body.localizedCaseInsensitiveContains(jargon), body)
        }
    }

    func testFolderStatusIsPlainLanguage() {
        func status(_ phase: MailboxSyncPhase, _ downloaded: Int, _ total: Int?, error: String? = nil) -> MailboxSyncStatus {
            MailboxSyncStatus(accountID: AccountID("a"), mailboxPath: "INBOX", phase: phase, downloaded: downloaded,
                              estimatedTotal: total, complete: false, lastError: error, updatedAt: Date())
        }
        XCTAssertEqual(MailboxSyncStatusText.text(status(.backfill, 1200, 5000)), "Downloading \(1200.formatted()) of \(5000.formatted())")
        XCTAssertEqual(MailboxSyncStatusText.text(status(.recentImport, 3, nil)), "Downloading")
        XCTAssertEqual(MailboxSyncStatusText.text(status(.failed, 0, nil, error: "IMAP NO [ALERT] x")), "Couldn't sync this folder")
        XCTAssertNil(MailboxSyncStatusText.text(status(.idle, 10, 10)))
    }

    @MainActor
    func testAccountSyncStatusNeverNamesADeviceOrAPath() {
        let model = AccountSetupViewModel.connectedPreview()
        XCTAssertFalse(model.syncStatusMessage.contains("iPhone"))
        XCTAssertFalse(model.syncStatusMessage.contains("Mac"))
        XCTAssertFalse(model.syncStatusMessage.contains("INBOX"))
        XCTAssertEqual(model.syncStatusMessage, "Up to date")
    }

    func testNodeAccountStatusIsPlainLanguage() {
        XCTAssertEqual(NodeAccountSettingsPage.status(.ready), "Ready")
        XCTAssertEqual(NodeAccountSettingsPage.status(.degraded), "Sync delayed")
        XCTAssertEqual(NodeAccountSettingsPage.status(.authenticationRequired), "Needs attention")
    }

    func testHistoryDownloadAppliesOnlyToTheHostsSelectedAccount() {
        let page = AccountID("page")
        XCTAssertTrue(AccountHistoryDownloadScope.appliesToPage(pageAccountID: page, hostAccountID: page))
        XCTAssertFalse(AccountHistoryDownloadScope.appliesToPage(pageAccountID: page, hostAccountID: AccountID("other")))
        XCTAssertFalse(AccountHistoryDownloadScope.appliesToPage(pageAccountID: page, hostAccountID: nil))
    }

    func testStatusRanksFailureThenThisAccountsHostProgressThenSyncStatus() {
        let page = AccountID("page")
        func status(error: String? = nil, host: String? = "Downloading", hostAccount: AccountID?) -> String {
            AccountHistoryDownloadScope.status(
                lastSyncError: error, hostStatus: host, pageAccountID: page,
                hostAccountID: hostAccount, syncStatusMessage: "Up to date"
            )
        }
        XCTAssertEqual(status(error: "Couldn't connect", hostAccount: page), "Couldn't connect")
        XCTAssertEqual(status(hostAccount: page), "Downloading")
        XCTAssertEqual(status(hostAccount: AccountID("other")), "Up to date")
        XCTAssertEqual(status(host: nil, hostAccount: page), "Up to date")
    }
}
