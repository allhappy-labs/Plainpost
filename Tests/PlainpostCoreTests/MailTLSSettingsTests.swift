import Foundation
import XCTest
@testable import PlainpostCore

final class MailTLSSettingsTests: XCTestCase {
    func testSSLSettingsPinTLS12MinimumWithSystemTrust() {
        let settings = MailTLSSettings.sslSettings(
            host: "mail.example.com",
            certificateValidation: .systemTrust
        )

        XCTAssertEqual(settings[kCFStreamSSLLevel as String] as? String, MailTLSSettings.minimumTLSLevel)
        XCTAssertEqual(MailTLSSettings.minimumTLSLevel, "kCFStreamSocketSecurityLevelTLSv1_2")
        XCTAssertEqual(settings[kCFStreamSSLPeerName as String] as? String, "mail.example.com")
        XCTAssertNil(settings[kCFStreamSSLValidatesCertificateChain as String])
    }

    func testLocalCertificateOverrideStillPinsTLS12Minimum() {
        let settings = MailTLSSettings.sslSettings(
            host: "127.0.0.1",
            certificateValidation: .disabledForLocalTesting
        )

        XCTAssertEqual(settings[kCFStreamSSLLevel as String] as? String, MailTLSSettings.minimumTLSLevel)
        XCTAssertTrue(settings[kCFStreamSSLPeerName as String] is NSNull)
        XCTAssertEqual(settings[kCFStreamSSLValidatesCertificateChain as String] as? Bool, false)
    }
}
