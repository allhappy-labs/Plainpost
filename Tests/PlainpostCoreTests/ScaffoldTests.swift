import XCTest
@testable import PlainpostCore

final class ScaffoldTests: XCTestCase {
    func testCoreModuleExposesVersion() {
        XCTAssertEqual(PlainpostVersion.current.name, "Plainpost")
    }

    func testAccountDecodesLegacyPayloadWithoutUsername() throws {
        let data = Data(
            """
            {
              "id": "acc_me_example_com",
              "displayName": "Personal",
              "email": "me@example.com",
              "imapHost": "imap.example.com",
              "imapPort": 993,
              "smtpHost": "smtp.example.com",
              "smtpPort": 587
            }
            """.utf8
        )

        let account = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(account.id, AccountID("acc_me_example_com"))
        XCTAssertEqual(account.email, EmailAddress("me@example.com"))
        XCTAssertEqual(account.username, "me@example.com")
    }

    func testAccountDecodesLegacyPayloadWithoutSentMailbox() throws {
        let data = Data(
            """
            {
              "id": "acc_me_example_com",
              "displayName": "Personal",
              "email": "me@example.com",
              "username": "login-id",
              "imapHost": "imap.example.com",
              "imapPort": 993,
              "smtpHost": "smtp.example.com",
              "smtpPort": 587
            }
            """.utf8
        )

        let account = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(account.sentMailbox, "Sent")
    }

}
