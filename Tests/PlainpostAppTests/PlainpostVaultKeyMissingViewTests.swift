import AppKit
import SwiftUI
import XCTest
@testable import PlainpostApp

@MainActor
final class PlainpostVaultKeyMissingViewTests: XCTestCase {
    func testCopyExplainsTheLostKeyAndWhatStartingOverKeeps() {
        XCTAssertEqual(PlainpostVaultKeyMissingView.title, "Plainpost Vault Key is missing")
        XCTAssertEqual(PlainpostVaultKeyMissingView.startOverButtonTitle, "Start Over with Saved Sign-ins…")
        XCTAssertTrue(PlainpostVaultKeyMissingView.message.contains("new developer identity"))
        XCTAssertTrue(PlainpostVaultKeyMissingView.message.contains("saved sign-ins"))
        let confirmation = PlainpostVaultKeyMissingView.confirmationMessage
        XCTAssertTrue(confirmation.contains("mail on this Mac is kept"), confirmation)
        XCTAssertTrue(confirmation.contains("archived, not deleted"), confirmation)
        XCTAssertTrue(confirmation.contains("sign in to each mail account again in Settings"), confirmation)
        for copy in [PlainpostVaultKeyMissingView.message, confirmation] {
            for jargon in ["credential", "keychain", "ciphertext", "backup", "support"] {
                XCTAssertFalse(copy.localizedCaseInsensitiveContains(jargon), "\(jargon) in \(copy)")
            }
        }
    }

    func testRendersWithAndWithoutAFailedStartOver() {
        for error in [nil, "Plainpost couldn't finish starting over."] {
            let view = PlainpostVaultKeyMissingView(startOverError: error, startOver: {})
                .frame(width: 520, height: 320)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
            let renderer = ImageRenderer(content: view)
            XCTAssertNotNil(renderer.nsImage, "\(String(describing: error))")
        }
    }
}
