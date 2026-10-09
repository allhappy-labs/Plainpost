import XCTest
@testable import PlainpostCore

final class MailActionServerRefusalTests: XCTestCase {
    func testServerRefusalBecomesAReadableReasonWithoutTheTaggedLine() {
        let refusal = IMAPClientError.protocolError("A0007 NO [TRYCREATE] Mailbox doesn't exist: Archive (Failure)")
        let mapped = MailActionServerRefusal.error(for: refusal, action: .archive)
        guard case .validationFailed(let text)? = mapped else { return XCTFail("expected validationFailed, got \(String(describing: mapped))") }
        XCTAssertEqual(text, "The mail server refused to archive this message: Mailbox doesn't exist: Archive (Failure).")
        XCTAssertFalse(text.contains("A0007"))
        XCTAssertFalse(text.contains("TRYCREATE"))

        let delete = MailActionServerRefusal.error(for: IMAPClientError.protocolError("A0009 NO UID 7 is locked"), action: .delete)
        XCTAssertEqual(delete, .validationFailed("The mail server refused to delete this message."),
                       "a reason naming a UID is left out")
        XCTAssertEqual(
            MailActionServerRefusal.error(for: IMAPClientError.protocolError("A0010 BAD"), action: .archive),
            .validationFailed("The mail server refused to archive this message.")
        )
        XCTAssertEqual(
            MailActionServerRefusal.error(for: IMAPClientError.protocolError("UID MOVE and UID EXPUNGE are unavailable."), action: .archive),
            .validationFailed("The mail server can't move messages, so this message wasn't archived.")
        )
        XCTAssertEqual(
            MailActionServerRefusal.error(for: IMAPClientError.protocolError("Mailbox names cannot contain control characters."), action: .delete),
            .validationFailed("Plainpost couldn't delete this message on the mail server."),
            "a client-side error is not worded as the server's refusal"
        )
        XCTAssertNil(MailActionServerRefusal.error(for: IMAPClientError.timedOut, action: .archive), "only a refusal is mapped")
    }
}
