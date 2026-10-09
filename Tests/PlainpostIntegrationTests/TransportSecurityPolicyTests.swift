import XCTest
@testable import PlainpostCore

final class TransportSecurityPolicyTests: XCTestCase {
    func testProviderAuthCannotDowngradeOutsideLoopbackFixture() {
        XCTAssertThrowsError(try MailTransportSecurityPolicy.validateCleartextHarnessHost("imap.example.invalid"))
        XCTAssertNoThrow(try MailTransportSecurityPolicy.validateCleartextHarnessHost("127.0.0.1"))
    }
}
