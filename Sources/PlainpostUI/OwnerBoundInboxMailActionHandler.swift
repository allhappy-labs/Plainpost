import PlainpostCore
import PlainpostDB

/// The device-wide runtime's action boundary: a message is acted on only through its own
/// account, and only while that account is still the source (Direct, or Sync Node) at the
/// generation the list showing it was read with. A Direct account's message goes to
/// `underlying`, a Sync Node account's to the device's Sync Node. It never falls through to
/// another account or source.
public struct OwnerBoundInboxMailActionHandler: InboxMailActionHandling {
    private let store: SQLiteMailStore
    private let readGeneration: @Sendable (MessageID, AccountID) -> Int64?
    private let underlying: any InboxMailActionHandling
    private let node: any InboxMailActionHandling

    init(
        store: SQLiteMailStore,
        readGeneration: @escaping @Sendable (MessageID, AccountID) -> Int64?,
        underlying: any InboxMailActionHandling,
        nodeMail: (any DeviceNodeMailBridging)? = nil
    ) {
        self.store = store
        self.readGeneration = readGeneration
        self.underlying = underlying
        node = DeviceNodeInboxMailActionHandler(bridge: nodeMail)
    }

    public func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        try await perform(action, messageID: messageID, shownIn: nil)
    }

    public func perform(
        _ action: InboxMailAction, messageID: MessageID, shownIn mailboxPath: String?
    ) async throws -> InboxMailActionResult {
        let owner = try store.membership(for: messageID).accountID
        // No list showed it, or its account wasn't Direct when one did: nothing to act against.
        guard let expected = readGeneration(messageID, owner) else {
            throw NodeMailModeStoreError.generationConflict
        }
        try DeviceMailScope.requireCurrentOwner(owner, expected: expected, in: store)
        if DeviceMailScope.isNodeOwner(owner, in: store) {
            return try await node.perform(action, messageID: messageID, shownIn: mailboxPath)
        }
        return try await underlying.perform(action, messageID: messageID, shownIn: mailboxPath)
    }
}

/// A Sync Node account's message actions on the device: each goes to the Node through the
/// device's journal. The Node offers no erase, so Delete Permanently is refused.
struct DeviceNodeInboxMailActionHandler: InboxMailActionHandling {
    static let unavailableMessage = "This account syncs through your Sync Node, which isn't connected on this device."
    let bridge: (any DeviceNodeMailBridging)?

    func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        let kind: MailIntentKind
        var folder: String?
        switch action {
        case .markRead: kind = .markRead
        case .markUnread: kind = .markUnread
        case .archive: kind = .archive
        case .delete: kind = .delete
        case .flag: kind = .flag
        case .unflag: kind = .unflag
        case .move(let destination):
            kind = .move
            folder = destination
        case .deletePermanently:
            throw PlainpostError.validationFailed(NodeAuthorityInboxMailActionHandler.noPermanentDeleteMessage)
        }
        guard let bridge else { throw PlainpostError.validationFailed(Self.unavailableMessage) }
        if case let .failed(message) = try await bridge.perform(kind, messageID: messageID, folder: folder) {
            throw PlainpostError.validationFailed(Self.outdatedNodeMessage(message, kind: kind))
        }
        return InboxMailActionResult(
            messageID: messageID, action: action,
            seen: action == .markRead ? true : action == .markUnread ? false : nil,
            mailboxPath: action == .archive ? "Archive" : folder,
            deleted: action == .delete
        )
    }

    /// An older Sync Node answers a flag or move it doesn't know as an invalid request; say
    /// what to do about it rather than the generic refusal.
    static func outdatedNodeMessage(_ message: String, kind: MailIntentKind) -> String {
        guard [.flag, .unflag, .move].contains(kind), message == MailIntentRouterRefusal.genericMessage else { return message }
        return kind == .move ? "Update your Sync Node to move messages." : "Update your Sync Node to flag messages."
    }
}
