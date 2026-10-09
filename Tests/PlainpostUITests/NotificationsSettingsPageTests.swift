import XCTest
@testable import PlainpostUI

final class NotificationsSettingsPageTests: XCTestCase {
    func testCompletedSyncAlertsAreNeverEnabled() {
        UserDefaults.standard.set(true, forKey: "Plainpost.notifications.syncCompleted")
        defer { UserDefaults.standard.removeObject(forKey: "Plainpost.notifications.syncCompleted") }
        XCTAssertFalse(PlainpostNotificationPreference.isEnabled(categoryIdentifier: "sync_completed"))
        XCTAssertTrue(PlainpostNotificationPreference.isEnabled(categoryIdentifier: "sync_failed"))
    }

    func testPageRendersWithoutCaptions() throws {
        _ = NotificationsSettingsPage().body
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/PlainpostUITests/NotificationsSettingsPageTests.swift",
            with: "Sources/PlainpostUI/Settings/NotificationsSettingsPage.swift"))
        for banned in ["Completed mail syncs", "Initial account imports", "remain visible in approvals"] {
            XCTAssertFalse(source.contains(banned), banned)
        }
    }
}
