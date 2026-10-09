import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

final class MicrosoftAccessTokenProviderTests: XCTestCase {
    func testMicrosoftVaultKeyIsSeparateFromGoogle() {
        let id = AccountID("acc_ada_example_com")
        XCTAssertEqual(MailCredentialKeys.microsoftRefreshToken(id).rawValue,
                       "account:acc_ada_example_com:microsoft-refresh-token")
        XCTAssertNotEqual(MailCredentialKeys.microsoftRefreshToken(id), MailCredentialKeys.googleRefreshToken(id))
    }
}
