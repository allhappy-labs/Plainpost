import XCTest
import PlainpostCore
@testable import PlainpostUI

final class MailRemovalPolicyTests: XCTestCase {
    private func account(_ email: String, imap: String = "imap.example.test", smtp: String = "smtp.example.test") -> Account {
        Account(id: AccountID(email), displayName: "", email: EmailAddress(email), imapHost: imap, smtpHost: smtp)
    }

    func testGmailServersArchive() {
        XCTAssertEqual(MailRemovalPolicy.primaryAction(for: account("me@company.example", imap: "imap.gmail.com", smtp: "smtp.gmail.com")), .archive)
    }

    func testGmailAddressesArchiveEvenThroughASyncNode() {
        XCTAssertEqual(MailRemovalPolicy.primaryAction(for: account("oleg.olhapi@gmail.com", imap: "", smtp: "")), .archive)
        XCTAssertEqual(MailRemovalPolicy.primaryAction(for: account("x@GoogleMail.com")), .archive)
    }

    func testEveryOtherAccountDeletes() {
        XCTAssertEqual(MailRemovalPolicy.primaryAction(for: account("me@icloud.com", imap: "imap.mail.me.com")), .delete)
        XCTAssertEqual(MailRemovalPolicy.primaryAction(for: nil), .delete)
    }

    func testSecondaryIsTheOtherOfTheTwo() {
        XCTAssertEqual(MailRemovalPolicy.secondaryAction(for: .archive), .delete)
        XCTAssertEqual(MailRemovalPolicy.secondaryAction(for: .delete), .archive)
        XCTAssertEqual(MailRemovalPolicy.title(for: .archive), "Archive")
        XCTAssertEqual(MailRemovalPolicy.systemImage(for: .delete), "trash")
    }
}
