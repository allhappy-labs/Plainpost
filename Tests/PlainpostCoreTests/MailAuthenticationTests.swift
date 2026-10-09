import XCTest
@testable import PlainpostCore

final class MailAuthenticationTests: XCTestCase {
    func testXOAUTH2InitialResponseMatchesGoogleFormatAndRedacts() throws {
        let encoded = try XOAUTH2.initialClientResponse(username: "ada@example.test", accessToken: "ya29.token")
        XCTAssertEqual(Data(base64Encoded: encoded), Data("user=ada@example.test\u{01}auth=Bearer ya29.token\u{01}\u{01}".utf8))
        XCTAssertThrowsError(try XOAUTH2.initialClientResponse(username: "a\u{01}b", accessToken: "t"))
        XCTAssertThrowsError(try XOAUTH2.initialClientResponse(username: "a", accessToken: "t\r\n"))
        XCTAssertFalse(String(describing: MailAuthentication.xoauth2(accessToken: "ya29.token")).contains("ya29"))
    }

    func testXOAUTH2RejectsEmptyAndControlCharacterCredentials() {
        for (username, token) in [("", "t"), ("a", ""), ("a\0b", "t"), ("a", "t\u{01}"), ("a b\n", "t"), ("a", "t\0")] {
            XCTAssertThrowsError(try XOAUTH2.initialClientResponse(username: username, accessToken: token)) {
                XCTAssertEqual($0 as? MailAuthenticationError, .invalidCredentialCharacters)
            }
        }
    }

    func testEveryDescriptionRedactsSecrets() {
        let values: [MailAuthentication] = [.password("hunter2-secret"), .xoauth2(accessToken: "ya29.secret")]
        for value in values {
            for rendered in [String(describing: value), String(reflecting: value), "\(value)", value.debugDescription] {
                XCTAssertFalse(rendered.contains("secret"), rendered)
            }
        }
        XCTAssertEqual(String(describing: MailAuthentication.password("x")), "MailAuthentication.password(<redacted>)")
        XCTAssertEqual(String(describing: MailAuthentication.xoauth2(accessToken: "x")), "MailAuthentication.xoauth2(<redacted>)")
    }

    func testProtocolDefaultsUsePasswordPathAndRefuseXOAUTH2() async throws {
        let imap = PasswordOnlyIMAPDouble()
        try await imap.authenticate(username: "ada", authentication: .password("pw"))
        XCTAssertEqual(imap.logins, ["ada"])
        do {
            try await imap.authenticate(username: "ada", authentication: .xoauth2(accessToken: "t"))
            XCTFail("default IMAP client accepted XOAUTH2")
        } catch MailAuthenticationError.mechanismUnavailable {}

        let smtp = PasswordOnlySMTPDouble()
        try await smtp.send(username: "ada", authentication: .password("pw"), from: EmailAddress("ada@example.test"),
                            to: [EmailAddress("b@example.test")], data: "x")
        XCTAssertEqual(smtp.sends, ["ada"])
        do {
            try await smtp.send(username: "ada", authentication: .xoauth2(accessToken: "t"), from: EmailAddress("ada@example.test"),
                                to: [EmailAddress("b@example.test")], data: "x")
            XCTFail("default SMTP client accepted XOAUTH2")
        } catch MailAuthenticationError.mechanismUnavailable {}
        XCTAssertEqual(smtp.sends, ["ada"])
    }
}

private final class PasswordOnlyIMAPDouble: IMAPClientProtocol, @unchecked Sendable {
    var logins: [String] = []
    func login(username: String, password: String) async throws { logins.append(username) }
    func listMailboxes() async throws -> [Mailbox] { [] }
    func selectMailbox(_ path: String) async throws -> String { "" }
    func allMessageUIDs() async throws -> [Int] { [] }
    func fetchHeader(uid: Int) async throws -> String { "" }
    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

private final class PasswordOnlySMTPDouble: SMTPClientProtocol, @unchecked Sendable {
    var sends: [String] = []
    func send(username: String, password: String, from: EmailAddress, to recipients: [EmailAddress], data: String) async throws {
        sends.append(username)
    }
}
