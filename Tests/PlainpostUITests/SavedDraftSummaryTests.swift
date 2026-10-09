import XCTest
import PlainpostCore
@testable import PlainpostUI

final class SavedDraftSummaryTests: XCTestCase {
    private func draft(to: [String], subject: String, body: String) -> Draft {
        Draft(
            id: DraftID("drf_summary"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: to.map { EmailAddress($0) }, cc: [], bcc: [],
            subject: subject,
            bodyPlain: body,
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: nil
        )
    }

    func testPreviewIsTheFirstAuthoredLineNeverAQuote() {
        let summary = SavedDraftSummary(draft(
            to: ["jeremy@example.com"],
            subject: "  Re: Kundenrückfrage ",
            body: "\n> quoted first\n\nHello. Thanks for the help.\nSecond line"
        ))
        XCTAssertEqual(summary.recipients, "jeremy@example.com")
        XCTAssertEqual(summary.subject, "Re: Kundenrückfrage")
        XCTAssertEqual(summary.preview, "Hello. Thanks for the help.")
    }

    func testEmptyDraftNamesWhatIsMissing() {
        let summary = SavedDraftSummary(draft(to: [], subject: " ", body: ""))
        XCTAssertEqual(summary.recipients, "No Recipients")
        XCTAssertEqual(summary.subject, "No Subject")
        XCTAssertEqual(summary.preview, "")
    }
}
