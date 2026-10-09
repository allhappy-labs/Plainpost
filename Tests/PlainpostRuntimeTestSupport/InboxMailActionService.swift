import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostUI

/// A store-plus-IMAP inbox action handler for tests (moved from PlainpostUI:
/// production composes `IOSDirectInboxActionHandler` or the service adapter).
public protocol InboxMailActionStore: MessageRepository, MessageMetadataRepository {}

extension InMemoryMailStore: InboxMailActionStore {}
extension SQLiteMailStore: InboxMailActionStore {}

public final class InboxMailActionService<Store: InboxMailActionStore>: InboxMailActionHandling, @unchecked Sendable {
    private let store: Store
    private let imapClient: IMAPClientProtocol?
    private let actor: Actor
    private let archiveMailbox: String
    private let trashMailbox: String
    private let mailboxFlagScheduler: (any MailboxFlagScheduling)?

    public init(
        store: Store,
        imapClient: IMAPClientProtocol? = nil,
        actor: Actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser),
        archiveMailbox: String = "Archive",
        trashMailbox: String = "Trash",
        mailboxFlagScheduler: (any MailboxFlagScheduling)? = nil
    ) {
        self.store = store
        self.imapClient = imapClient
        self.actor = actor
        self.archiveMailbox = archiveMailbox
        self.trashMailbox = trashMailbox
        self.mailboxFlagScheduler = mailboxFlagScheduler
    }

    public func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        if let imapClient {
            let uid = try uid(for: messageID)
            switch action {
            case .markRead:
                try await imapClient.markRead(uid: uid)
            case .markUnread:
                try await imapClient.markUnread(uid: uid)
            case .archive:
                try await imapClient.archive(uid: uid, archiveMailbox: archiveMailbox)
            case .delete:
                // Delete moves to Trash; only an explicit permanent delete erases.
                _ = try await imapClient.move(uid: uid, to: trashMailbox)
            case .deletePermanently:
                // Erase only a message in Trash, like every other delete path.
                guard let message = store.messages.first(where: { $0.id == messageID }),
                      TrashMailbox.isTrashPath(message.mailboxPath)
                else { throw PlainpostError.validationFailed(TrashDelete.permanentOutsideTrashMessage) }
                try await imapClient.delete(uid: uid)
            case .flag, .unflag:
                try await imapClient.setFlags(uid: uid, add: action == .flag ? ["\\Flagged"] : [],
                                              remove: action == .flag ? [] : ["\\Flagged"], expectedModSequence: nil)
            case .move(let destination):
                _ = try await imapClient.move(uid: uid, to: destination)
            }
        }

        switch action {
        case .flag, .unflag:
            return InboxMailActionResult(messageID: messageID, action: action)
        case .move(let destination):
            let message = try store.moveMessage(messageID, toMailboxPath: destination, actor: actor)
            return InboxMailActionResult(messageID: message.id, action: action, mailboxPath: message.mailboxPath)
        case .markRead:
            let message = try store.markSeen(messageID, seen: true, actor: actor)
            try? await mailboxFlagScheduler?.signalWork()
            return InboxMailActionResult(messageID: message.id, action: action, seen: message.isSeen)
        case .markUnread:
            let message = try store.markSeen(messageID, seen: false, actor: actor)
            try? await mailboxFlagScheduler?.signalWork()
            return InboxMailActionResult(messageID: message.id, action: action, seen: message.isSeen)
        case .archive:
            let message = try store.moveMessage(messageID, toMailboxPath: archiveMailbox, actor: actor)
            return InboxMailActionResult(
                messageID: message.id,
                action: action,
                mailboxPath: message.mailboxPath,
                deleted: message.isDeleted
            )
        case .delete:
            let message = try store.moveMessage(messageID, toMailboxPath: trashMailbox, actor: actor)
            return InboxMailActionResult(
                messageID: message.id, action: action, mailboxPath: message.mailboxPath,
                deleted: message.isDeleted, deleteOutcome: .movedToTrash
            )
        case .deletePermanently:
            let message = try store.markDeleted(messageID, deleted: true, actor: actor)
            return InboxMailActionResult(
                messageID: message.id, action: action, deleted: message.isDeleted, deleteOutcome: .deletedPermanently
            )
        }
    }

    private func uid(for messageID: MessageID) throws -> Int {
        let mapping = Dictionary(
            uniqueKeysWithValues: store.messages
                .sorted { $0.id.rawValue < $1.id.rawValue }
                .enumerated()
                .compactMap { index, message -> (MessageID, Int)? in
                    let prefix = "msg_uid_"
                    if message.id.rawValue.hasPrefix(prefix),
                       let uid = Int(message.id.rawValue.dropFirst(prefix.count)) {
                        return (message.id, uid)
                    }
                    return (message.id, index + 1)
                }
        )
        guard let uid = mapping[messageID] else {
            throw PlainpostError.notFound("Message not found.")
        }
        return uid
    }
}
