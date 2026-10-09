import XCTest
@testable import PlainpostCore

final class TransportSecurityPolicyTests: XCTestCase {
    func testCleartextTransportAllowsLoopbackHarnessHosts() throws {
        XCTAssertNoThrow(try MailTransportSecurityPolicy.validateCleartextHarnessHost("127.0.0.1"))
        XCTAssertNoThrow(try MailTransportSecurityPolicy.validateCleartextHarnessHost("localhost"))
        XCTAssertNoThrow(try MailTransportSecurityPolicy.validateCleartextHarnessHost("::1"))
    }

    func testCleartextTransportRejectsRemoteHosts() {
        XCTAssertThrowsError(try MailTransportSecurityPolicy.validateCleartextHarnessHost("imap.example.com")) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Cleartext mail transport is only allowed for loopback test harnesses.")
            )
        }
    }

    func testPlaintextSMTPClientRejectsRemoteHostsBeforeConnecting() async {
        let client = PlaintextSMTPClient(host: "smtp.example.com", port: 587)

        do {
            try await client.send(
                username: "me@example.com",
                password: "secret",
                from: EmailAddress("me@example.com"),
                to: [EmailAddress("alice@example.com")],
                data: "Subject: Blocked\r\n\r\nBody"
            )
            XCTFail("Expected remote cleartext SMTP to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Cleartext mail transport is only allowed for loopback test harnesses.")
            )
        }
    }

    func testPlaintextIMAPClientRejectsRemoteHostsBeforeConnecting() async {
        let client = PlaintextIMAPClient(host: "imap.example.com", port: 143)

        do {
            try await client.login(username: "me@example.com", password: "secret")
            XCTFail("Expected remote cleartext IMAP to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Cleartext mail transport is only allowed for loopback test harnesses.")
            )
        }
    }

    func testSMTPFactoryUsesSecureClientsForRemoteSubmissionPortsAndPlaintextOnlyForLoopbackHarnesses() {
        XCTAssertTrue(MailTransportClientFactory.smtpClient(host: "smtp.example.com", port: 465) is SecureSMTPClient)
        XCTAssertTrue(MailTransportClientFactory.smtpClient(host: "smtp.example.com", port: 587) is StartTLSSMTPClient)
        XCTAssertTrue(MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: 2525) is PlaintextSMTPClient)
    }

    func testIMAPFactoryUsesSecureClientForRemoteImplicitTLSPortAndPlaintextOnlyForLoopbackHarnesses() {
        XCTAssertTrue(MailTransportClientFactory.imapClient(host: "imap.example.com", port: 993) is SecureIMAPClient)
        XCTAssertTrue(MailTransportClientFactory.imapClient(host: "imap.example.com", port: 143) is StartTLSIMAPClient)
        XCTAssertTrue(MailTransportClientFactory.imapClient(host: "127.0.0.1", port: 1143) is PlaintextIMAPClient)
    }
}
