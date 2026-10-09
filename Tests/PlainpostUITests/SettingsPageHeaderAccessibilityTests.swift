import XCTest
@testable import PlainpostUI
#if os(macOS)
import AppKit
import SwiftUI

/// The Mac settings page title sits in a grouped Form's first section; VoiceOver must still
/// announce it as the page heading, not as footer text.
@MainActor
final class SettingsPageHeaderAccessibilityTests: XCTestCase {
    func testMacSettingsPageTitleIsAnAccessibilityHeading() async throws {
        let host = AcceptanceHost(PrivacySettingsPage(), size: NSSize(width: 900, height: 700))
        defer { host.close() }
        let isHeading = await host.waitFor { elements in
            elements.contains { HostedAX.role($0) == "AXHeading" && HostedAX.texts($0).contains("Privacy") }
        }
        XCTAssertTrue(isHeading, host.axDump().joined(separator: "\n"))
    }
}
#endif
