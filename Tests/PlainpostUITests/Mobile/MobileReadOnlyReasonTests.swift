import XCTest
@testable import PlainpostUI

/// Final-review Minor 7: the read-only line names the actual reason.
final class MobileReadOnlyReasonTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_790_000_000)

    func testEachReasonHasItsOwnLine() {
        let reasons: [MobileReadOnlyReason] = [.offlineLease(expiresAt: expiry), .offlineLease(expiresAt: nil), .reauthorization]
        XCTAssertEqual(Set(reasons.map(\.changesLine)).count, reasons.count)
        XCTAssertNotEqual(MobileReadOnlyReason.offlineLease(expiresAt: nil).sendingLine, MobileReadOnlyReason.reauthorization.sendingLine)
    }

    func testTheOfflineLeaseNamesWhenCachedMailStopsBeingReadable() {
        let line = MobileReadOnlyReason.offlineLease(expiresAt: expiry).changesLine
        XCTAssertTrue(line.contains(expiry.formatted(date: .abbreviated, time: .shortened)), line)
        XCTAssertTrue(line.hasPrefix("Offline"), line)
    }

    func testReauthorizationPointsToTheMac() {
        XCTAssertEqual(MobileReadOnlyReason.reauthorization.changesLine, "Sign in to this account again on your Mac to make changes.")
        XCTAssertEqual(MobileReadOnlyReason.reauthorization.sendingLine, "Sign in to this account again on your Mac to send.")
    }

    func testNoReasonFallsBackToAGenericLine() {
        let none: MobileReadOnlyReason? = nil
        XCTAssertEqual(none.changesLine, "Changes are paused while this account is read-only.")
        XCTAssertEqual(none.sendingLine, "Sending is paused while this account is read-only.")
        let lease: MobileReadOnlyReason? = .offlineLease(expiresAt: nil)
        XCTAssertEqual(lease.changesLine, "Offline: cached mail is read-only until Plainpost reconnects.")
        XCTAssertEqual(lease.sendingLine, "Sending is paused while you're offline.")
    }
}
