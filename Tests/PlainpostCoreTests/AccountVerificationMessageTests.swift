import Foundation
import XCTest
@testable import PlainpostCore

final class AccountVerificationMessageTests: XCTestCase {
    private let email = EmailAddress("me@example.com")
    private let identifier = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    func testRendersUniqueTaggedSelfAddressedMIME() {
        let message = AccountVerificationMessage(accountEmail: email, identifier: identifier)

        XCTAssertEqual(
            message.messageID,
            "<plainpost-account-verification-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@local.plainpost>"
        )
        XCTAssertTrue(message.smtpData.contains("From: <me@example.com>\r\n"))
        XCTAssertTrue(message.smtpData.contains("To: <me@example.com>\r\n"))
        XCTAssertTrue(message.smtpData.contains("Subject: Plainpost account verification\r\n"))
        XCTAssertTrue(message.smtpData.contains("Message-ID: \(message.messageID)\r\n"))
        XCTAssertTrue(message.smtpData.contains("X-Plainpost-Account-Verification: v1\r\n"))
        XCTAssertTrue(message.smtpData.hasSuffix("\r\n\r\nTesting local SMTP credentials."))
    }

    func testRecognizesOnlyCompleteSelfSentVerificationIdentity() {
        let message = AccountVerificationMessage(accountEmail: email, identifier: identifier)
        let header = message.smtpData.components(separatedBy: "\r\n\r\n")[0]

        XCTAssertTrue(message.matchesDeliveryHeader(header))
        XCTAssertTrue(AccountVerificationMessage.recognizes(
            header: header,
            body: AccountVerificationMessage.body,
            accountEmail: email
        ))
        XCTAssertFalse(AccountVerificationMessage.recognizes(
            header: header.replacingOccurrences(
                of: "X-Plainpost-Account-Verification: v1\r\n",
                with: ""
            ),
            body: AccountVerificationMessage.body,
            accountEmail: email
        ))
        XCTAssertFalse(AccountVerificationMessage.recognizes(
            header: header.replacingOccurrences(of: "From: <me@example.com>", with: "From: <other@example.com>"),
            body: AccountVerificationMessage.body,
            accountEmail: email
        ))
        XCTAssertFalse(AccountVerificationMessage.recognizes(
            header: header,
            body: "Different body",
            accountEmail: email
        ))
    }

    func testSameSubjectAndBodyWithoutPrivateMarkerRemainOrdinaryMail() {
        let header = """
        From: <me@example.com>\r
        To: <me@example.com>\r
        Subject: Plainpost account verification\r
        Message-ID: <ordinary@example.com>
        """

        XCTAssertFalse(AccountVerificationMessage.recognizes(
            header: header,
            body: AccountVerificationMessage.body,
            accountEmail: email
        ))
    }

    func testRejectsVerificationBodyWithLeadingOrTrailingWhitespace() {
        let message = AccountVerificationMessage(accountEmail: email, identifier: identifier)
        let header = message.smtpData.components(separatedBy: "\r\n\r\n")[0]

        XCTAssertFalse(AccountVerificationMessage.recognizes(
            header: header,
            body: " \n\(AccountVerificationMessage.body)",
            accountEmail: email
        ))
        XCTAssertFalse(AccountVerificationMessage.recognizes(
            header: header,
            body: "\(AccountVerificationMessage.body)\n ",
            accountEmail: email
        ))
    }
}
