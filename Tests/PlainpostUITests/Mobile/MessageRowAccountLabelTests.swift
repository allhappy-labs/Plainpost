import PlainpostCore
@testable import PlainpostUI
import XCTest

final class MessageRowAccountLabelTests: XCTestCase {
    private func account(_ id: String, _ email: String) -> Account {
        Account(id: AccountID(id), displayName: id, email: EmailAddress(email),
                imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    }

    func testNoLabelWithOneAccount() {
        XCTAssertNil(MessageRowAccountLabel.label(for: AccountID("a"), accounts: [account("a", "me@example.test")]))
    }

    func testTheAddressLocalPartWithSeveralAccounts() {
        let accounts = [account("a", "me@example.test"), account("b", "work@company.test")]
        XCTAssertEqual(MessageRowAccountLabel.label(for: AccountID("b"), accounts: accounts), "work")
    }

    func testTheFullAddressWhenLocalPartsCollide() {
        let accounts = [account("a", "me@example.test"), account("b", "me@company.test")]
        XCTAssertEqual(MessageRowAccountLabel.label(for: AccountID("b"), accounts: accounts), "me@company.test")
    }

    func testNoLabelForAnUnknownOrMissingAccount() {
        let accounts = [account("a", "me@example.test"), account("b", "work@company.test")]
        XCTAssertNil(MessageRowAccountLabel.label(for: nil, accounts: accounts))
        XCTAssertNil(MessageRowAccountLabel.label(for: AccountID("gone"), accounts: accounts))
    }
}
