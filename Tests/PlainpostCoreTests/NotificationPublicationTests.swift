import XCTest
@testable import PlainpostCore

final class NotificationPublicationTests: XCTestCase {
    func testIncomingDispositionIsSilentForBaselineAndOnlyCandidateForIncrementalInbox() {
        XCTAssertEqual(
            IncomingNotificationDisposition.forSync(
                mailboxPath: "INBOX", source: .recentImport,
                generation: .initialBaseline, providerArrivalAt: Date()
            ),
            .establishWatermark
        )
        XCTAssertEqual(
            IncomingNotificationDisposition.forSync(
                mailboxPath: "INBOX", source: .historicalBackfill,
                generation: .unchanged, providerArrivalAt: Date()
            ),
            .establishWatermark
        )
        XCTAssertEqual(
            IncomingNotificationDisposition.forSync(
                mailboxPath: "INBOX", source: .incremental,
                generation: .unchanged, providerArrivalAt: Date(timeIntervalSince1970: 1)
            ),
            .candidate(providerArrivalAt: Date(timeIntervalSince1970: 1))
        )
        XCTAssertEqual(
            IncomingNotificationDisposition.forSync(
                mailboxPath: "Archive", source: .incremental,
                generation: .unchanged, providerArrivalAt: Date()
            ),
            .ineligible
        )
    }

    func testMissingProviderArrivalFailsClosed() {
        XCTAssertEqual(
            IncomingNotificationDisposition.forSync(
                mailboxPath: "INBOX", source: .incremental,
                generation: .unchanged, providerArrivalAt: nil
            ),
            .candidate(providerArrivalAt: nil)
        )
        XCTAssertFalse(IncomingNotificationDisposition.candidate(providerArrivalAt: nil).isEligible)
    }

    func testInternalDateParserAcceptsIMAPInternaldate() {
        let date = IMAPInternalDateParser.date(from: "* 1 FETCH (INTERNALDATE \"01-Sep-2026 11:22:33 +0000\")")
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = 11
        components.minute = 22
        components.second = 33
        XCTAssertEqual(date, components.date)
    }
}
