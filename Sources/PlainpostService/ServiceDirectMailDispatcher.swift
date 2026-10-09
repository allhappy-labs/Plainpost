import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostNodeMailMode
import PlainpostSecrets
import PlainpostServiceIPC

/// The router's direct route: the service's existing provider paths
/// (immediate IMAP archive/delete, the durable flag job, the IMAP draft
/// append and `LocalDraftDeliveryService`, which owns the Sent copy).
/// Composition binds the operations after both exist.
final class ServiceDirectMailDispatcher: DirectMailDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private weak var operations: PlainpostServiceOperations?

    func bind(_ operations: PlainpostServiceOperations) {
        lock.withLock { self.operations = operations }
    }

    private func bound() throws -> PlainpostServiceOperations {
        guard let operations = lock.withLock({ self.operations }) else {
            // Nothing reached the provider: the intent waits, it never fails.
            throw DirectMailDispatchDeferral(reason: "The Plainpost service is not ready.")
        }
        return operations
    }

    /// The router's direct-dispatch gate: open only while the service
    /// runtime is (the vault is unlocked and no lockdown is running).
    func runtimeIsOpen() async -> Bool {
        guard let operations = lock.withLock({ self.operations }) else { return false }
        return await operations.runtimeIsOpen
    }

    func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws {
        try await bound().performDirectMailIntent(action, messageID: messageID, archiveMailbox: archiveMailbox)
    }

    func saveDraft(_ draft: Draft) async throws {
        try await bound().saveDraftDirectly(draft)
    }

    func send(_ draft: Draft, approvedContentHash: String) async throws {
        try await bound().sendDraftDirectly(draft, approvedContentHash: approvedContentHash)
    }

    static func deferral(for error: any Error) -> DirectMailDispatchDeferral? {
        DirectMailDispatchErrors.deferral(for: error)
    }

    static let networkMessage = DirectMailDispatchErrors.networkMessage

    static func refusal(for error: any Error) -> DirectMailDispatchRefusal? {
        DirectMailDispatchErrors.refusal(for: error)
    }
}
