import XCTest
import LocalAuthentication
import Security
@testable import PlainpostSecrets

final class KeychainCredentialStoreTests: XCTestCase {
    func testCredentialAvailabilityClassifiesInteractionRequiredStatus() {
        XCTAssertEqual(
            KeychainCredentialAvailability(status: errSecInteractionNotAllowed),
            .interactionRequired
        )
    }

    func testInteractiveReadQueryUsesForegroundAuthenticationContext() {
        let context = LAContext()
        let query = KeychainCredentialStore.interactiveReadQuery(
            service: "PlainpostTests",
            account: "me@example.com",
            prompt: "Unlock Mail",
            context: context
        )

        XCTAssertTrue(query[kSecUseAuthenticationContext as String] as? LAContext === context)
        XCTAssertEqual(context.localizedReason, "Unlock Mail")
    }

    func testReadQueryDisablesAuthenticationInteraction() {
        let context = LAContext()
        let query = KeychainCredentialStore.readQuery(
            service: "PlainpostTests",
            account: "me@example.com",
            context: context
        )

        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUISkip as String
        )
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertTrue((query[kSecUseAuthenticationContext as String] as? LAContext) === context)
    }

    func testMetadataQueryRequestsAttributesWithoutSecretDataOrAuthenticationUI() {
        let query = KeychainCredentialStore.metadataQuery(
            service: "PlainpostTests",
            account: "me@example.com"
        )

        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUISkip as String
        )
    }

    func testReadTimeoutDoesNotWaitForBlockedKeychainOperation() {
        let startedAt = Date()

        XCTAssertThrowsError(
            try KeychainCredentialStore.awaitRead(timeout: 0.05) {
                Thread.sleep(forTimeInterval: 1)
                return "password"
            }
        ) { error in
            XCTAssertEqual(error as? KeychainCredentialError, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testInteractiveReadIsNotQueuedBehindATimedOutBackgroundRead() throws {
        let backgroundStarted = DispatchSemaphore(value: 0)
        let releaseBackground = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? KeychainCredentialStore.awaitRead(timeout: 0.01) {
                backgroundStarted.signal()
                releaseBackground.wait()
                return "background"
            }
        }
        XCTAssertEqual(backgroundStarted.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            releaseBackground.signal()
        }
        let startedAt = Date()

        let value = try KeychainCredentialStore.awaitInteractiveRead {
            "interactive"
        }

        XCTAssertEqual(value, "interactive")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.15)
    }

}
