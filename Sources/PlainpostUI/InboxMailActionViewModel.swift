import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer

public enum InboxMailAction: Hashable, Sendable {
    case markRead
    case markUnread
    case archive
    /// Moves the message to Trash. It never erases.
    case delete
    /// Erases a message in Trash. Only the "Delete Permanently" action, shown
    /// only in a recognized Trash folder, sends this.
    case deletePermanently
    case flag
    case unflag
    /// Moves the copy acted on to one of its account's folders, named by path.
    case move(to: String)

    public var statusMessage: String {
        switch self {
        case .markRead:
            "Marked read"
        case .markUnread:
            "Marked unread"
        case .archive:
            "Archived"
        case .delete:
            "Deleted"
        case .deletePermanently:
            "Deleted permanently"
        case .flag:
            "Flagged"
        case .unflag:
            "Unflagged"
        case .move:
            "Moved"
        }
    }

    /// Archive, a move and both deletes take the message out of the list it's in.
    public var removesMessage: Bool {
        switch self {
        case .archive, .delete, .deletePermanently, .move: true
        case .markRead, .markUnread, .flag, .unflag: false
        }
    }

    /// The flag state the action leaves, when it changes it.
    public var flaggedChange: Bool? {
        switch self {
        case .flag: true
        case .unflag: false
        default: nil
        }
    }
}

public struct InboxMailActionResult: Equatable, Sendable {
    public let messageID: MessageID
    public let action: InboxMailAction
    public let seen: Bool?
    public let mailboxPath: String?
    public let deleted: Bool
    /// For a delete on a Direct account: what it did.
    public let deleteOutcome: DeleteOutcome?
    /// For an archive on a Direct account: the copy was already in the Archive,
    /// so nothing was sent or changed.
    public let alreadyArchived: Bool

    public init(
        messageID: MessageID,
        action: InboxMailAction,
        seen: Bool? = nil,
        mailboxPath: String? = nil,
        deleted: Bool = false,
        deleteOutcome: DeleteOutcome? = nil,
        alreadyArchived: Bool = false
    ) {
        self.messageID = messageID
        self.action = action
        self.seen = seen
        self.mailboxPath = mailboxPath
        self.deleted = deleted
        self.deleteOutcome = deleteOutcome
        self.alreadyArchived = alreadyArchived
    }
}

public enum InboxMailActionOutcome: Equatable, Sendable {
    case succeeded(InboxMailActionResult)
    case failed(message: String)
}

public protocol InboxMailActionHandling: Sendable {
    func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult
    /// The same, naming the mailbox the user acted from, so an archive or
    /// delete touches that copy of the message and no other. Handlers that
    /// don't distinguish copies ignore it.
    func perform(_ action: InboxMailAction, messageID: MessageID, shownIn mailboxPath: String?) async throws
        -> InboxMailActionResult
}

public extension InboxMailActionHandling {
    func perform(_ action: InboxMailAction, messageID: MessageID, shownIn mailboxPath: String?) async throws
        -> InboxMailActionResult
    {
        try await perform(action, messageID: messageID)
    }
}

/// High-level inbox actions must be translated into a signed Node operation
/// before they can cross the Node mutation capability. Until that signer is
/// supplied by the account runtime, fail closed instead of routing a Node
/// account through the legacy IMAP/provider handler.
public struct NodeAuthorityInboxMailActionHandler: InboxMailActionHandling {
    static let noPermanentDeleteMessage = MailActionRefusal.noPermanentDeleteWithSyncNode.message
    private let mutations: (any MailMutationServing)?

    public init() { mutations = nil }

    public init(mutations: any MailMutationServing) {
        self.mutations = mutations
    }

    public func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        guard let mutations else {
            throw PlainpostError.validationFailed("Node mail mutations require an authenticated Node operation.")
        }
        let result: MailMutationResult
        switch action {
        case .markRead:
            result = try await mutations.perform(.setRead(messageIDs: [messageID], read: true))
        case .markUnread:
            result = try await mutations.perform(.setRead(messageIDs: [messageID], read: false))
        case .archive:
            result = try await mutations.perform(.archive(messageIDs: [messageID]))
        case .delete:
            // The Sync Node decides what a delete does; it moves to Trash and never erases.
            result = try await mutations.perform(.delete(messageIDs: [messageID]))
        case .deletePermanently:
            // As the Mac service does: the Sync Node offers no erase, so say so
            // rather than report "Deleted permanently" for a delete that isn't.
            throw PlainpostError.validationFailed(Self.noPermanentDeleteMessage)
        case .flag, .unflag:
            result = try await mutations.perform(.setFlagged(messageIDs: [messageID], flagged: action == .flag))
        case .move(let destination):
            result = try await mutations.perform(.move(messageIDs: [messageID], destinationMailboxPath: destination))
        }
        let movedTo: String? = if case let .move(destination) = action { destination } else { nil }
        return InboxMailActionResult(
            messageID: messageID,
            action: action,
            seen: action == .markRead ? true : action == .markUnread ? false : nil,
            mailboxPath: action == .archive ? "Archive" : movedTo,
            deleted: action == .delete || action == .deletePermanently || result.state == "deleted"
        )
    }
}

@MainActor
public final class InboxMailActionViewModel: ObservableObject {
    @Published public private(set) var pendingMessageIDs: Set<String> = []
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var lastResult: InboxMailActionResult?

    let handler: InboxMailActionHandling

    public init(handler: InboxMailActionHandling) {
        self.handler = handler
    }

    public func isPending(messageID: String) -> Bool {
        pendingMessageIDs.contains(messageID)
    }

    public func perform(
        _ action: InboxMailAction, messageID: String, shownIn mailboxPath: String? = nil
    ) async -> InboxMailActionOutcome {
        lastResult = nil
        statusMessage = nil
        pendingMessageIDs.insert(messageID)
        defer { pendingMessageIDs.remove(messageID) }
        do {
            let result = try await handler.perform(action, messageID: MessageID(messageID), shownIn: mailboxPath)
            lastResult = result
            // A Delete of a message already in Trash did nothing, and that is no
            // failure: the message is where a Delete puts it. Likewise an Archive of
            // a copy already in the Archive. The lists reload.
            statusMessage = result.deleteOutcome == .alreadyInTrash ? Self.alreadyInTrashMessage
                : result.alreadyArchived ? Self.alreadyArchivedMessage : action.statusMessage
            return .succeeded(result)
        } catch {
            let message = Self.message(for: error)
            statusMessage = message
            return .failed(message: message)
        }
    }

    static let alreadyInTrashMessage = "This message is already in Trash."
    static let alreadyArchivedMessage = "This message is already archived."

    private static func message(for error: Error) -> String {
        guard let mailError = error as? PlainpostError else {
            return "Mail action failed"
        }
        switch mailError {
        case .permissionDenied(let message), .validationFailed(let message), .notFound(let message):
            return message
        }
    }

    public static func preview() -> InboxMailActionViewModel {
        InboxMailActionViewModel(handler: PreviewInboxMailActionHandler())
    }
}

private struct PreviewInboxMailActionHandler: InboxMailActionHandling {
    func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        InboxMailActionResult(messageID: messageID, action: action)
    }
}
