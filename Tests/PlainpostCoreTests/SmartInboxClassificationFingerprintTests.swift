import XCTest
import Testing
@testable import PlainpostCore

final class SmartInboxClassificationFingerprintTests: XCTestCase {
    func testBodyFreeFingerprintMatchesCompleteMessageFingerprint() {
        let complete = MessageSummary(
            id: MessageID("msg_1"),
            threadID: ThreadID("thread_1"),
            from: EmailAddress("sender@example.com"),
            subject: "Subject",
            preview: "Preview",
            body: String(repeating: "large-body", count: 10_000),
            smartCategory: .personal
        )
        let lightweight = MailboxListMessage(
            id: complete.id,
            threadID: complete.threadID,
            from: complete.from,
            subject: complete.subject,
            preview: complete.preview,
            smartCategory: complete.smartCategory
        )

        XCTAssertEqual(
            SmartInboxClassificationFingerprint.message(lightweight),
            SmartInboxClassificationFingerprint.message(complete)
        )
        XCTAssertEqual(
            SmartInboxClassificationFingerprint.workSet(messages: [lightweight], discriminator: "incremental"),
            SmartInboxClassificationFingerprint.workSet(messages: [complete], discriminator: "incremental")
        )
    }
}

@Test func fingerprintIncludesDisplayNameAndClassifierIdentity() {
    let base = mailboxFixture(id: "m-1", fromDisplayName: "Ada")
    let renamed = mailboxFixture(id: "m-1", fromDisplayName: "Ada Lovelace")

    #expect(
        SmartInboxClassificationFingerprint.message(base, classifierDiscriminator: "p:model:v1")
        != SmartInboxClassificationFingerprint.message(renamed, classifierDiscriminator: "p:model:v1")
    )
    #expect(
        SmartInboxClassificationFingerprint.message(base, classifierDiscriminator: "p:model:v1")
        != SmartInboxClassificationFingerprint.message(base, classifierDiscriminator: "p:model:v2")
    )
}

@Test func fingerprintCanonicalizesBodyFreeClassificationInputs() {
    let complete = MessageSummary(
        id: MessageID(" m-1 "),
        threadID: nil,
        from: EmailAddress("SENDER@EXAMPLE.COM"),
        fromDisplayName: " Ada\u{00A0}Lovelace ",
        subject: " Subject\tline ",
        preview: " Preview\ntext ",
        body: "Unhashed body",
        smartCategory: .unknown
    )
    let lightweight = MailboxListMessage(
        id: MessageID("m-1"),
        threadID: nil,
        from: EmailAddress("sender@example.com"),
        fromDisplayName: "Ada Lovelace",
        subject: "Subject line",
        preview: "Preview text",
        smartCategory: .unknown
    )

    #expect(
        SmartInboxClassificationFingerprint.message(complete, classifierDiscriminator: " model\u{2003}v1 ")
        == SmartInboxClassificationFingerprint.message(lightweight, classifierDiscriminator: "model v1")
    )
}
