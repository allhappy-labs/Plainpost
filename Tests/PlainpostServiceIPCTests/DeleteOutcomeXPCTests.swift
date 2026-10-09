import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostSecrets
@testable import PlainpostServiceIPC
@testable import PlainpostServiceRuntime

/// Every delete outcome must succeed across the real XPC boundary: the
/// service listener's correlation check and the client's.
final class DeleteOutcomeXPCTests: XCTestCase {
    private func roundTrip(
        _ result: PlainpostMailActionSemanticResult, permanent: Bool = false
    ) async throws -> PlainpostForegroundOperationResult {
        try await roundTrip(permanent: permanent) { .delete(result) }
    }

    private func roundTrip(
        permanent: Bool = false,
        _ perform: @escaping @Sendable () throws -> PlainpostForegroundOperationResult
    ) async throws -> PlainpostForegroundOperationResult {
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: FixedVaultKeyProvider()),
            prepareForegroundUnlock: {}, beginVaultLockdown: {}, confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: coordinator,
            performForegroundOperation: { _ in try perform() }
        )
        let service = listener.exportedService(for: .cli)
        let unlockError: PlainpostXPCErrorDTO? = await withCheckedContinuation { continuation in
            service.unlock(reason: "Delete outcome test") { continuation.resume(returning: $0) }
        }
        XCTAssertNil(unlockError)
        let connection = ListenerConnection(service: service)
        let client = PlainpostServiceClient(connectionFactory: { connection }, capability: .cli)
        return try await client.perform(.delete(PlainpostMailActionPayload(messageID: "m1", permanent: permanent)))
    }

    func testMovedToTrashSucceedsOverXPC() async throws {
        let moved = PlainpostMailActionSemanticResult(
            messageID: "m1", mailboxPath: "Trash", isDeleted: false, deleteOutcome: .movedToTrash
        )
        guard case .delete(let value) = try await roundTrip(moved) else { return XCTFail("expected delete") }
        XCTAssertEqual(value, moved)
    }

    func testAlreadyInTrashSucceedsOverXPC() async throws {
        let already = PlainpostMailActionSemanticResult(
            messageID: "m1", mailboxPath: "Trash", isDeleted: false, deleteOutcome: .alreadyInTrash
        )
        guard case .delete(let value) = try await roundTrip(already) else { return XCTFail("expected delete") }
        XCTAssertEqual(value.deleteOutcome, .alreadyInTrash)
    }

    func testDeletedPermanentlySucceedsOverXPCOnlyWhenAskedFor() async throws {
        let erased = PlainpostMailActionSemanticResult(messageID: "m1", isDeleted: true, deleteOutcome: .deletedPermanently)
        guard case .delete(let value) = try await roundTrip(erased, permanent: true) else { return XCTFail("expected delete") }
        XCTAssertEqual(value.deleteOutcome, .deletedPermanently)

        do {
            _ = try await roundTrip(erased)
            XCTFail("an erase must never answer a plain delete")
        } catch {}
        let moved = PlainpostMailActionSemanticResult(
            messageID: "m1", mailboxPath: "Trash", isDeleted: false, deleteOutcome: .movedToTrash
        )
        do {
            _ = try await roundTrip(moved, permanent: true)
            XCTFail("a move must not answer Delete Permanently")
        } catch {}
    }

    func testARefusalKeepsItsReasonAcrossXPC() async throws {
        let cases: [(String, MailActionRefusal)] = [
            (TrashDelete.noTrashMessage, .noTrash),
            (TrashDelete.permanentOutsideTrashMessage, .permanentOutsideTrash),
            ("This message is no longer in [Gmail]/Sent Mail. Refresh, then try again.", .copyNotInMailbox),
            (MailActionRefusal.noPermanentDeleteWithSyncNode.message, .noPermanentDeleteWithSyncNode),
        ]
        for (message, refusal) in cases {
            do {
                _ = try await roundTrip { throw PlainpostError.validationFailed(message) }
                XCTFail("expected a refusal")
            } catch let error as PlainpostServiceClientError {
                XCTAssertEqual(error, .mailActionRefused(refusal))
            }
        }
        do {
            _ = try await roundTrip { throw PlainpostError.validationFailed("Something else.") }
            XCTFail("expected a failure")
        } catch let error as PlainpostServiceClientError {
            XCTAssertEqual(error, .operationFailed, "other failures stay generic")
        }
    }

    func testAnEraseThatLeavesAnotherCopySucceedsAndSaysTheMessageRemains() async throws {
        let partial = PlainpostMailActionSemanticResult(
            messageID: "m1", mailboxPath: "Sent", isDeleted: false, deleteOutcome: .deletedPermanently
        )
        guard case .delete(let value) = try await roundTrip(partial, permanent: true) else { return XCTFail("expected delete") }
        XCTAssertFalse(value.isDeleted)
        XCTAssertEqual(value.mailboxPath, "Sent")
    }

    func testANodeDeleteWithoutAnOutcomeStillSucceeds() async throws {
        let node = PlainpostMailActionSemanticResult(messageID: "m1", isDeleted: true, waitingForNode: true)
        guard case .delete = try await roundTrip(node) else { return XCTFail("expected delete") }
    }
}

private struct FixedVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { Data(repeating: 0x33, count: 32) }
    func countMatchingItems() async throws -> Int { 1 }
}

/// Hands the client the listener's exported service directly, in process.
private final class ListenerConnection: PlainpostServiceClientConnection, @unchecked Sendable {
    var interruptionHandler: (@Sendable () -> Void)?
    var invalidationHandler: (@Sendable () -> Void)?
    private let service: PlainpostServiceXPCProtocol

    init(service: PlainpostServiceXPCProtocol) { self.service = service }

    func activate() {}
    func invalidate() {}
    func remoteService(errorHandler: @escaping @Sendable (Error) -> Void) -> PlainpostServiceXPCProtocol? { service }
}
