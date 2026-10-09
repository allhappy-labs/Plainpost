import Foundation

/// What a Delete did. Erasing needs an explicit request (`permanent`); a plain
/// Delete only ever moves a message to Trash, or leaves one already there alone.
public enum DeleteOutcome: String, Codable, Equatable, Sendable {
    case movedToTrash = "moved_to_trash"
    case alreadyInTrash = "already_in_trash"
    case deletedPermanently = "deleted_permanently"

    /// What to tell the user or an agent.
    public var summary: String {
        switch self {
        case .movedToTrash: "Moved to Trash."
        case .alreadyInTrash: "Already in Trash. Nothing was changed."
        case .deletedPermanently: "Deleted permanently."
        }
    }
}

/// A refusal of an archive or delete that stays nameable across XPC (as an
/// `operationFailed` detail), so the Mac app, CLI and MCP can say why.
public enum MailActionRefusal: Int, Sendable, CaseIterable {
    case noTrash = 1
    case permanentOutsideTrash = 2
    case copyNotInMailbox = 3
    case noPermanentDeleteWithSyncNode = 4
    case noSourceMailboxWithSyncNode = 5

    public var message: String {
        switch self {
        case .noTrash: TrashDelete.noTrashMessage
        case .permanentOutsideTrash: TrashDelete.permanentOutsideTrashMessage
        case .copyNotInMailbox: "This message is no longer in that mailbox. Refresh, then try again."
        case .noPermanentDeleteWithSyncNode: "Delete Permanently isn't available while the Sync Node handles this account."
        case .noSourceMailboxWithSyncNode:
            "A source mailbox can't be chosen while the Sync Node handles this account. Leave it out; the Sync Node picks the copy."
        }
    }

    /// The refusal a service-side validation message stands for, if any.
    public init?(message: String) {
        if message.hasPrefix("This message is no longer in ") {
            self = .copyNotInMailbox
            return
        }
        guard let match = Self.allCases.first(where: { $0.message == message }) else { return nil }
        self = match
    }
}

/// Delete's provider step, shared by every direct path (the device and Mac
/// runtime, and the Mac's fallback for a Node-backed account):
/// - plain Delete outside Trash: move to the account's Trash;
/// - plain Delete in Trash: nothing (already in Trash);
/// - permanent Delete in Trash: erase that one UID;
/// - permanent Delete outside Trash, or no Trash at all: refuse before any change.
public enum TrashDelete {
    public static let noTrashMessage = "This account has no Trash mailbox, so the message wasn't deleted."
    public static let permanentOutsideTrashMessage = "Only a message in Trash can be deleted permanently."

    /// The provider-side result of a Delete.
    public enum Step: Equatable, Sendable {
        case moved(IMAPMoveResult)
        case alreadyInTrash
        case erased

        public var outcome: DeleteOutcome {
            switch self {
            case .moved: .movedToTrash
            case .alreadyInTrash: .alreadyInTrash
            case .erased: .deletedPermanently
            }
        }
    }

    /// Whether `mailboxPath` is Trash by the account's cached folder list
    /// (its special-use) or by the shared Trash rules.
    public static func isInTrash(_ mailboxPath: String, cachedMailboxes: [Mailbox]) -> Bool {
        let specialUse = cachedMailboxes.first { $0.path == mailboxPath }?.specialUse
        return TrashMailbox.isTrash(path: mailboxPath, specialUse: specialUse, accountMailboxes: cachedMailboxes)
            || TrashMailbox.path(in: cachedMailboxes) == mailboxPath
    }

    /// Answers without the server when the cached folder list already settles
    /// it: a plain Delete of a message in Trash does nothing. Nil means the
    /// server step is needed.
    public static func precheck(sourceMailbox: String, cachedMailboxes: [Mailbox], permanent: Bool) -> Step? {
        !permanent && isInTrash(sourceMailbox, cachedMailboxes: cachedMailboxes) ? .alreadyInTrash : nil
    }

    /// What a Delete will do on the server.
    public enum Plan: Equatable, Sendable {
        case move(to: String)
        case alreadyInTrash
        case erase
    }

    /// Decides the step for a message in `sourceMailbox`. Trash comes from the
    /// cached folder list, else from the server's LIST. Throws, before any
    /// change, when there is no Trash or a permanent Delete is outside Trash.
    public static func plan(
        client: IMAPClientProtocol,
        sourceMailbox: String,
        cachedMailboxes: [Mailbox],
        permanent: Bool
    ) async throws -> Plan {
        var mailboxes = cachedMailboxes
        var trash = TrashMailbox.path(in: mailboxes)
        if trash == nil {
            // The cached list may predate the Trash folder.
            mailboxes = try await client.listMailboxes()
            trash = TrashMailbox.path(in: mailboxes)
        }
        let inTrash = sourceMailbox == trash || isInTrash(sourceMailbox, cachedMailboxes: mailboxes)
        if permanent {
            guard inTrash else { throw PlainpostError.validationFailed(permanentOutsideTrashMessage) }
            return .erase
        }
        if inTrash { return .alreadyInTrash }
        guard let trash else { throw PlainpostError.validationFailed(noTrashMessage) }
        return .move(to: trash)
    }

    /// Carries out `plan` on `client`, which has the message's mailbox selected.
    public static func execute(_ plan: Plan, client: IMAPClientProtocol, uid: Int) async throws -> Step {
        switch plan {
        case .move(let trash): return .moved(try await client.move(uid: uid, to: trash))
        case .alreadyInTrash: return .alreadyInTrash
        case .erase:
            try await client.delete(uid: uid)
            return .erased
        }
    }
}
