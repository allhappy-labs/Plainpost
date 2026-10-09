import XCTest
@testable import PlainpostBrowserIntegration

final class BrowserCallerValidatorTests: XCTestCase {
    func testCallerAllowsOnlyFixedChromeOrFirefoxIdentity() {
        XCTAssertTrue(BrowserCallerValidator.isAllowed(arguments: [
            "chrome-extension://fjhlbghobimgnakkhigjmjejahjackfo/",
        ]))
        XCTAssertTrue(BrowserCallerValidator.isAllowed(arguments: [
            "/manifest/path", "quick-mail@plainpost.olhapi.com",
        ]))
        XCTAssertFalse(BrowserCallerValidator.isAllowed(arguments: [
            "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/",
        ]))
    }

    func testCallerRejectsEmbeddedOrAdditionalIdentityArguments() {
        XCTAssertFalse(BrowserCallerValidator.isAllowed(arguments: [
            "prefix chrome-extension://fjhlbghobimgnakkhigjmjejahjackfo/ suffix",
        ]))
        XCTAssertFalse(BrowserCallerValidator.isAllowed(arguments: [
            "chrome-extension://fjhlbghobimgnakkhigjmjejahjackfo/", "unexpected",
        ]))
        XCTAssertFalse(BrowserCallerValidator.isAllowed(arguments: [
            "/manifest/path", "prefix-quick-mail@plainpost.olhapi.com",
        ]))
    }

    func testFirefoxCallerRequiresAnAbsoluteManifestPath() {
        XCTAssertFalse(BrowserCallerValidator.isAllowed(arguments: [
            "relative/manifest/path", "quick-mail@plainpost.olhapi.com",
        ]))
    }
}
