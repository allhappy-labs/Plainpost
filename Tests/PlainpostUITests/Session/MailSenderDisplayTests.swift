import XCTest
@testable import PlainpostUI

final class MailSenderDisplayTests: XCTestCase {
    func testUsesDisplayNameWhenPresent() {
        XCTAssertEqual(MailSenderDisplay.name(displayName: "Maria Chen", address: "maria@x.example"), "Maria Chen")
    }

    func testParsesNameFromRawHeaderForm() {
        XCTAssertEqual(
            MailSenderDisplay.name(displayName: nil, address: "Vercel <notifications@vercel.com>"),
            "Vercel"
        )
        XCTAssertEqual(
            MailSenderDisplay.name(displayName: "  ", address: "\"Swiss Post\" <noreply@post.ch>"),
            "Swiss Post"
        )
    }

    func testFallsBackToBareAddress() {
        XCTAssertEqual(MailSenderDisplay.name(displayName: nil, address: "anon@example.test"), "anon@example.test")
    }

    func testNeverShowsTheAngleBracketForm() {
        let shown = MailSenderDisplay.name(displayName: "Vercel <notifications@vercel.com>", address: "notifications@vercel.com")
        XCTAssertEqual(shown, "Vercel")
    }

    func testAddressExtractsBracketedAddress() {
        XCTAssertEqual(MailSenderDisplay.address("Vercel <notifications@vercel.com>"), "notifications@vercel.com")
        XCTAssertEqual(MailSenderDisplay.address("plain@example.test"), "plain@example.test")
    }
}
