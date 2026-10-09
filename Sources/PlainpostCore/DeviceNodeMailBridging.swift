import Foundation

/// What the user learns about one change sent through a Sync Node.
public enum DeviceNodeMailOutcome: Equatable, Sendable {
    /// The Node applied it.
    case confirmed
    /// It is journaled and goes to the Node once the Node answers.
    case waitingForNode
    /// It may have taken effect; never resent automatically.
    case uncertain
    /// Refused before any provider effect.
    case failed(String)
}

/// How a Sync Node account is syncing on this device.
public enum DeviceNodeAccountState: Equatable, Sendable {
    case ready
    /// The Node did not answer the last mirror pass; mirrored mail stays readable.
    case unreachable
    /// The Node no longer lists the account: its mail on this device stays until the user
    /// removes the account here.
    case noLongerOnSyncNode
}

/// Sync Node mail on a device that runs its own mail runtime (the iPhone): a
/// mirror keeps every Node account's recent mail in the local database, and
/// each change to a Node account's message, draft or send goes to the Node
/// through a journal, so nothing is lost while the Node is away.
public protocol DeviceNodeMailBridging: Sendable {
    func start() async
    func stop() async
    /// Mirrors now, and sends the changes waiting for the Node.
    func wake() async
    /// `folder` names a move's destination (its path); no other kind takes one.
    func perform(_ kind: MailIntentKind, messageID: MessageID, folder: String?) async throws -> DeviceNodeMailOutcome
    func saveDraft(_ draft: Draft) async throws -> DeviceNodeMailOutcome
    func send(_ draft: Draft) async throws -> DeviceNodeMailOutcome
    /// Mirrors the account's whole history from now on, not only its recent window.
    func downloadCompleteHistory(for accountID: AccountID) async throws
    /// Every account in Node mode, keyed by account, and every Node account the Node no
    /// longer lists.
    func accountStates() async -> [AccountID: DeviceNodeAccountState]
}
