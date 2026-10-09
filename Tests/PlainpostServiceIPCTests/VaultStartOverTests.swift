import Foundation
import XCTest
@testable import PlainpostSecrets
@testable import PlainpostServiceIPC
@testable import PlainpostServiceRuntime

/// "Start Over with Saved Sign-ins": after the vault key is lost for good, the
/// app may archive the unreadable credentials and open a fresh vault.
final class VaultStartOverTests: XCTestCase {
    func testOnlyTheAppMayStartOver() {
        for capability in PlainpostClientCapability.allCases {
            XCTAssertEqual(
                PlainpostClientValidator.permits(.startOverAfterVaultKeyLoss, for: capability),
                capability == .app,
                "\(capability)"
            )
        }
    }

    func testStartOverArchivesThenRunsTheNormalUnlock() async throws {
        let provider = StartOverVaultKeyProvider(matchingItemCount: 0)
        let session = VaultSession(provider: provider)
        let events = StartOverEvents()
        let coordinator = makeCoordinator(session: session, events: events)

        try await coordinator.startOverAfterVaultKeyLoss(prompt: "Unlock Plainpost", capability: .app)

        let recorded = await events.events
        let state = await session.state
        let loads = await provider.interactiveLoads
        XCTAssertEqual(recorded, ["archive", "prepare", "recover", "reopen"])
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(loads, 1)
    }

    func testStartOverRefusesUnlessTheKeyIsMissing() async {
        for count in [1, 2] {
            let provider = StartOverVaultKeyProvider(matchingItemCount: count)
            let session = VaultSession(provider: provider)
            let events = StartOverEvents()
            let coordinator = makeCoordinator(session: session, events: events)

            do {
                try await coordinator.startOverAfterVaultKeyLoss(prompt: "Unlock Plainpost", capability: .app)
                XCTFail("Expected a refusal with \(count) key items")
            } catch {
                XCTAssertEqual(error as? PlainpostServiceClientError, .invalidRequest, "\(count)")
            }

            let recorded = await events.events
            let state = await session.state
            XCTAssertEqual(recorded, [], "\(count)")
            XCTAssertEqual(state, .locked, "\(count)")
        }
    }

    func testStartOverRefusesEveryClientButTheApp() async {
        for capability in PlainpostClientCapability.allCases where capability != .app {
            let provider = StartOverVaultKeyProvider(matchingItemCount: 0)
            let events = StartOverEvents()
            let coordinator = makeCoordinator(session: VaultSession(provider: provider), events: events)

            do {
                try await coordinator.startOverAfterVaultKeyLoss(prompt: "Unlock Plainpost", capability: capability)
                XCTFail("Expected \(capability) to be refused")
            } catch {
                XCTAssertEqual(error as? CredentialVaultError, .clientUnauthorized, "\(capability)")
            }

            let recorded = await events.events
            XCTAssertEqual(recorded, [], "\(capability)")
        }
    }

    func testFailedArchiveNeitherUnlocksNorBlocksALaterTransition() async throws {
        let provider = StartOverVaultKeyProvider(matchingItemCount: 0)
        let session = VaultSession(provider: provider)
        let events = StartOverEvents()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: { await events.record("prepare") },
            archiveCredentialsAfterKeyLoss: {
                await events.record("archive")
                throw StartOverTestError.archiveFailed
            },
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: { await events.record("reopen") }
        )

        do {
            try await coordinator.startOverAfterVaultKeyLoss(prompt: "Unlock Plainpost", capability: .app)
            XCTFail("Expected the archive failure")
        } catch {
            XCTAssertEqual(error as? StartOverTestError, .archiveFailed)
        }
        await coordinator.lock()

        let recorded = await events.events
        let state = await session.state
        XCTAssertEqual(recorded, ["archive"])
        XCTAssertEqual(state, .locked)
    }

    func testCoordinatorWithoutAnArchiveRefusesToStartOver() async {
        let provider = StartOverVaultKeyProvider(matchingItemCount: 0)
        let session = VaultSession(provider: provider)
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )

        do {
            try await coordinator.startOverAfterVaultKeyLoss(prompt: "Unlock Plainpost", capability: .app)
            XCTFail("Expected a refusal")
        } catch {}

        let state = await session.state
        XCTAssertEqual(state, .locked)
    }

    func testListenerRejectsNonAppCallersAndForwardsTheApp() async {
        for capability in PlainpostClientCapability.allCases where capability != .app {
            let events = StartOverEvents()
            let listener = PlainpostServiceListener(
                lifecycleCoordinator: makeCoordinator(
                    session: VaultSession(provider: StartOverVaultKeyProvider(matchingItemCount: 0)),
                    events: events
                )
            )
            let error = await startOver(listener.exportedService(for: capability))
            XCTAssertEqual(error?.code, .clientUnauthorized, "\(capability)")
            let recorded = await events.events
            XCTAssertEqual(recorded, [], "\(capability)")
        }

        let events = StartOverEvents()
        let session = VaultSession(provider: StartOverVaultKeyProvider(matchingItemCount: 0))
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: makeCoordinator(session: session, events: events)
        )
        let error = await startOver(listener.exportedService(for: .app))
        XCTAssertNil(error)
        let recorded = await events.events
        let state = await session.state
        XCTAssertEqual(recorded, ["archive", "prepare", "recover", "reopen"])
        XCTAssertEqual(state, .unlocked)
    }

    func testListenerReportsARefusalWhenTheKeyIsPresent() async {
        let events = StartOverEvents()
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: makeCoordinator(
                session: VaultSession(provider: StartOverVaultKeyProvider(matchingItemCount: 1)),
                events: events
            )
        )
        let error = await startOver(listener.exportedService(for: .app))
        XCTAssertEqual(error?.code, .invalidRequest)
        let recorded = await events.events
        XCTAssertEqual(recorded, [])
    }

    private func makeCoordinator(
        session: VaultSession,
        events: StartOverEvents
    ) -> PlainpostServiceLifecycleCoordinator {
        PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: { await events.record("prepare") },
            archiveCredentialsAfterKeyLoss: { await events.record("archive") },
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            recoverAfterUnlock: { await events.record("recover") },
            reopenRuntimeConstruction: { await events.record("reopen") }
        )
    }

    private func startOver(_ service: PlainpostServiceXPCProtocol) async -> PlainpostXPCErrorDTO? {
        await withCheckedContinuation { continuation in
            service.startOverAfterVaultKeyLoss(reason: "Unlock Plainpost") { continuation.resume(returning: $0) }
        }
    }
}

private enum StartOverTestError: Error, Equatable {
    case archiveFailed
}

private actor StartOverEvents {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor StartOverVaultKeyProvider: VaultKeyProvider {
    private let matchingItemCount: Int
    private(set) var interactiveLoads = 0

    init(matchingItemCount: Int) {
        self.matchingItemCount = matchingItemCount
    }

    func createIfMissing() {}

    func load(interactive: Bool, prompt: String?) -> Data? {
        if interactive { interactiveLoads += 1 }
        return Data(repeating: 0x64, count: 32)
    }

    func countMatchingItems() -> Int {
        matchingItemCount
    }
}
