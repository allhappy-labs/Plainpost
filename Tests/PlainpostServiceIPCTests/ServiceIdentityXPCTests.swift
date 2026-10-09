import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostSecrets
@testable import PlainpostServiceIPC
@testable import PlainpostServiceRuntime

final class ServiceIdentityXPCTests: XCTestCase {
    func testOnlyTheAppMayReadTheServiceIdentity() {
        for capability in PlainpostClientCapability.allCases {
            XCTAssertEqual(PlainpostClientValidator.permits(.serviceIdentity, for: capability), capability == .app, "\(capability)")
        }
    }

    func testInterfaceAdmitsStringRepliesForBothFields() {
        let interface = PlainpostServiceXPCInterface.make()
        for index in 0...1 {
            let classes = interface.classes(for: #selector(PlainpostServiceXPCProtocol.serviceIdentity(reply:)), argumentIndex: index, ofReply: true)
            XCTAssertTrue(classes.contains { ($0 as? AnyClass) == NSString.self }, "argument \(index)")
        }
    }

    func testListenerRejectsNonAppCallersAndAnswersTheApp() async {
        let listener = PlainpostServiceListener(lifecycleCoordinator: makeCoordinator())
        for capability in PlainpostClientCapability.allCases where capability != .app {
            let answer = await identity(listener.exportedService(for: capability))
            XCTAssertNil(answer.path)
            XCTAssertNil(answer.stamp)
            XCTAssertEqual(answer.error?.code, .clientUnauthorized)
        }
        // The test runner is not a bundled service: no identity, no error.
        let answer = await identity(listener.exportedService(for: .app))
        XCTAssertNil(answer.error)
        XCTAssertEqual(answer.path, PlainpostServiceBuildIdentity.of(bundleURL: Bundle.main.bundleURL)?.bundlePath)
    }

    private func makeCoordinator() -> PlainpostServiceLifecycleCoordinator {
        PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: IdentityLockedVaultKeyProvider()),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
    }

    private func identity(_ service: PlainpostServiceXPCProtocol) async -> (path: String?, stamp: String?, error: PlainpostXPCErrorDTO?) {
        await withCheckedContinuation { continuation in
            service.serviceIdentity { continuation.resume(returning: ($0, $1, $2)) }
        }
    }
}

private struct IdentityLockedVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { nil }
    func countMatchingItems() async throws -> Int { 1 }
}
