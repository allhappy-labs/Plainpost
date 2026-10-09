import PlainpostCore
import XCTest
@testable import PlainpostUI

final class MobileRowTextTests: XCTestCase {
    func testUsesTheDisplayName() {
        let text = MobileRowText(sender: "maria@x.example", senderDisplayName: "Maria Chen", subject: "Plan", preview: "Hi")
        XCTAssertEqual(text.sender, "Maria Chen")
        XCTAssertEqual(text.accessibilityLabel, "Maria Chen, Plan")
    }

    func testRawHeaderSenderShowsOnlyTheName() {
        let text = MobileRowText(sender: "Vercel <notifications@vercel.example>", senderDisplayName: nil, subject: "Deployment ready", preview: "")
        XCTAssertEqual(text.sender, "Vercel")
        XCTAssertFalse(text.accessibilityLabel.contains("<"))
    }

    /// A Direct IMAP message whose From header is a bare address ("From: alice@example.com")
    /// is stored with no display name. The row must name the sender the way the macOS/iPad row
    /// does ("Alice"), not show the raw address.
    func testDirectRowWithoutADisplayNameShowsTheSameNameAsTheSplitViewRow() {
        let row = MessageRowModel(message: MailboxListMessage(
            id: MessageID("msg_acc_reader_example_test_inbox_1_1"),
            threadID: nil,
            from: EmailAddress("alice@example.com"),
            fromDisplayName: nil,
            subject: "Availability",
            preview: "Can you meet next Tuesday?",
            smartCategory: .personal
        ))
        let text = MobileRowText(row: row)
        XCTAssertEqual(text.sender, "Alice")
        XCTAssertEqual(text.accessibilityLabel, "Alice, Availability")
    }

    func testSenderMatchesTheSplitViewRowForAddressOnlySenders() {
        for address in ["alice@example.com", "noreply@github.com", "jean-luc.picard@example.test"] {
            XCTAssertEqual(
                MobileRowText(sender: address, senderDisplayName: nil, subject: "s", preview: "").sender,
                MailSenderIdentity(sender: address, displayName: nil).displayName,
                address
            )
        }
    }

    func testBlankSubjectBecomesNoSubject() {
        XCTAssertEqual(MobileRowText(sender: "a@x", senderDisplayName: nil, subject: " \n ", preview: "").subject, "(No subject)")
    }

    func testPreviewParagraphsCollapseToOneSpace() {
        let text = MobileRowText(sender: "a@x", senderDisplayName: nil, subject: "s", preview: "Hello,\n\nThe engineer  will come")
        XCTAssertEqual(text.preview, "Hello, The engineer will come")
    }

    func testRecipientLineNamesTheFirstAndCountsTheRest() {
        XCTAssertEqual(MobileRowText.recipientLine(to: ["Reader <reader@example.test>", "b@x"], cc: ["c@x"]), "To: Reader & 2 more")
        XCTAssertEqual(MobileRowText.recipientLine(to: ["reader@example.test"], cc: []), "To: reader@example.test")
        XCTAssertNil(MobileRowText.recipientLine(to: [], cc: []))
    }
}
