public enum SmartInboxBatchCategory: String, Equatable, Sendable {
    case personal
    case notification
    case newsletter
    case seen

    public init?(argument: String) {
        switch argument.replacingOccurrences(of: "-", with: "_").lowercased() {
        case "personal":
            self = .personal
        case "notification", "notifications":
            self = .notification
        case "newsletter", "newsletters":
            self = .newsletter
        case "seen":
            self = .seen
        default:
            return nil
        }
    }

    func matches(_ message: MessageSummary) -> Bool {
        switch self {
        case .personal:
            return message.smartCategory == .personal && !message.isSeen
        case .notification:
            return message.smartCategory == .notification && !message.isSeen
        case .newsletter:
            return message.smartCategory == .newsletter && !message.isSeen
        case .seen:
            return message.isSeen
        }
    }
}

public enum SmartInboxBatchAction: String, Equatable, Sendable {
    case archiveRead = "archive_read"

    public init?(argument: String) {
        switch argument.replacingOccurrences(of: "-", with: "_").lowercased() {
        case "archive_read":
            self = .archiveRead
        default:
            return nil
        }
    }
}

public struct SmartInboxBatchRequest: Equatable, Sendable {
    public let category: SmartInboxBatchCategory
    public let action: SmartInboxBatchAction
    public let messageUIDs: [MessageID: Int]
    public let archiveMailbox: String

    public init(
        category: SmartInboxBatchCategory,
        action: SmartInboxBatchAction,
        messageUIDs: [MessageID: Int] = [:],
        archiveMailbox: String = "Archive"
    ) {
        self.category = category
        self.action = action
        self.messageUIDs = messageUIDs
        self.archiveMailbox = archiveMailbox
    }
}

public struct SmartInboxBatchResult: Equatable, Sendable {
    public let category: SmartInboxBatchCategory
    public let action: SmartInboxBatchAction
    public let affectedMessageIDs: [MessageID]
    public let archiveMailbox: String

    public init(
        category: SmartInboxBatchCategory,
        action: SmartInboxBatchAction,
        affectedMessageIDs: [MessageID],
        archiveMailbox: String
    ) {
        self.category = category
        self.action = action
        self.affectedMessageIDs = affectedMessageIDs
        self.archiveMailbox = archiveMailbox
    }

    public var affectedCount: Int {
        affectedMessageIDs.count
    }
}

public final class SmartInboxBatchService<Store: MessageRepository & MessageMetadataRepository> {
    private let store: Store
    private let imapClient: IMAPClientProtocol?

    public init(store: Store, imapClient: IMAPClientProtocol? = nil) {
        self.store = store
        self.imapClient = imapClient
    }

    public func run(_ request: SmartInboxBatchRequest, actor: Actor) async throws -> SmartInboxBatchResult {
        guard actor.permissions.markSeen else {
            throw PlainpostError.permissionDenied("Actor is not allowed to change seen state.")
        }

        switch request.action {
        case .archiveRead:
            let matching = store.messages
                .filter { request.category.matches($0) }
                .sorted { $0.id.rawValue < $1.id.rawValue }

            // The account's own Archive (Gmail: All Mail); none refuses before any change.
            var archiveMailbox = request.archiveMailbox
            if let imapClient, matching.contains(where: { request.messageUIDs[$0.id] != nil }) {
                archiveMailbox = try await ArchiveMailbox.resolve(
                    requested: request.archiveMailbox, client: imapClient,
                    cachedMailboxes: (store as? MailboxRepository)?.mailboxes ?? []
                )
            }
            var affected: [MessageID] = []
            for message in matching {
                if let uid = request.messageUIDs[message.id], let imapClient {
                    _ = try await imapClient.move(uid: uid, to: archiveMailbox)
                }
                let updated = try store.markSeen(message.id, seen: true, actor: actor)
                affected.append(updated.id)
            }
            return SmartInboxBatchResult(
                category: request.category,
                action: request.action,
                affectedMessageIDs: affected,
                archiveMailbox: archiveMailbox
            )
        }
    }
}
