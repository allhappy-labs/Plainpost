import XCTest
@testable import PlainpostUI

final class PrivacySettingsPageTests: XCTestCase {
    func testContactsOffersOneActionPerState() {
        XCTAssertEqual(ContactsAccessAction.action(for: .notDetermined), .allow)
        XCTAssertEqual(ContactsAccessAction.action(for: .authorized), .refresh)
        XCTAssertEqual(ContactsAccessAction.action(for: .limited), .refresh)
        XCTAssertEqual(ContactsAccessAction.action(for: .denied), .openSettings)
        XCTAssertEqual(ContactsAccessAction.action(for: .restricted), .openSettings)
        XCTAssertNil(ContactsAccessAction.action(for: .unavailable))
    }

    func testPrivacyHasNoStaticProtectionsOrMacCopyOnIOS() throws {
        _ = PrivacySettingsPage().body
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/PlainpostUITests/PrivacySettingsPageTests.swift",
            with: "Sources/PlainpostUI/Settings/PrivacySettingsPage.swift"))
        XCTAssertFalse(source.contains("Enforced protections"))
        XCTAssertFalse(source.contains("macOS will ask"))
    }
}
