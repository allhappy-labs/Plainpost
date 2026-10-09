import Foundation

public enum MailRetrievalScope: String, Codable, CaseIterable, Sendable {
    case allMail = "all_mail"
    case activeConversation = "active_conversation"
}

public struct MailKnowledgeQuery: Equatable, Sendable {
    public let text: String
    public let scope: MailRetrievalScope
    public let activeConversationKey: String?
    public let accountID: AccountID?
    public let filter: MailKnowledgeFilter
    public let limit: Int

    public init(
        text: String,
        scope: MailRetrievalScope = .allMail,
        activeConversationKey: String? = nil,
        accountID: AccountID? = nil,
        filter: MailKnowledgeFilter = .none,
        limit: Int = 24
    ) {
        self.text = text
        self.scope = scope
        self.activeConversationKey = activeConversationKey
        self.accountID = accountID
        self.filter = filter
        self.limit = limit
    }
}

public enum MailMailboxFilter: String, Codable, Sendable, CaseIterable {
    case any, inbox, sent, archive

    /// Matches the same mailbox classes `PlainpostRootView.openAskMailSource` uses.
    public func matches(_ mailboxPath: String) -> Bool {
        let path = mailboxPath.lowercased()
        switch self {
        case .any: return true
        case .inbox: return path == "inbox"
        case .sent: return path.contains("sent")
        case .archive: return path.contains("archive") || path.contains("all mail")
        }
    }

    /// Trash and junk folders; `.any` Ask Mail lists leave them out so bulk actions never touch them.
    public static let trashAndJunkPathFragments = ["trash", "deleted", "junk", "spam"]

    /// Trash as `TrashMailbox` recognizes it (special-use, Gmail's Bin,
    /// localized names), Junk by special-use, plus any path containing a trash
    /// or junk word. With the account's folder list, a marked `\Trash` settles
    /// Trash: an iCloud account's legacy "Trash" folder is then ordinary, as
    /// the folder list and Delete treat it.
    public static func isTrashOrJunk(
        _ mailboxPath: String, specialUse: String? = nil, accountMailboxes: [Mailbox] = []
    ) -> Bool {
        isTrashOrJunk(
            mailboxPath, specialUse: specialUse,
            accountHasMarkedTrash: accountMailboxes.contains {
                $0.specialUse?.caseInsensitiveCompare("\\Trash") == .orderedSame
            }
        )
    }

    /// The same rules for database predicates that already resolved the account's catalog.
    public static func isTrashOrJunk(
        _ mailboxPath: String, specialUse: String?, accountHasMarkedTrash: Bool
    ) -> Bool {
        if specialUse?.caseInsensitiveCompare("\\Trash") == .orderedSame
            || specialUse?.caseInsensitiveCompare("\\Junk") == .orderedSame
            || (!accountHasMarkedTrash && TrashMailbox.isTrash(path: mailboxPath, specialUse: specialUse)) {
            return true
        }
        let path = mailboxPath.lowercased()
        if ["junk", "spam"].contains(where: path.contains) { return true }
        return !accountHasMarkedTrash && ["trash", "deleted"].contains(where: path.contains)
    }
}

public struct MailKnowledgeFilter: Equatable, Codable, Sendable {
    public var unreadOnly: Bool
    public var mailbox: MailMailboxFilter
    public var senderContains: String?
    public var sentAfter: Date?
    public var sentBefore: Date?
    public var categories: [SmartCategory]

    public init(
        unreadOnly: Bool = false,
        mailbox: MailMailboxFilter = .any,
        senderContains: String? = nil,
        sentAfter: Date? = nil,
        sentBefore: Date? = nil,
        categories: [SmartCategory] = []
    ) {
        self.unreadOnly = unreadOnly
        self.mailbox = mailbox
        self.senderContains = senderContains
        self.sentAfter = sentAfter
        self.sentBefore = sentBefore
        self.categories = categories
    }

    public static let none = MailKnowledgeFilter()
    public var isEmpty: Bool { self == .none }

    public func matches(_ message: MessageSummary) -> Bool {
        if message.isDeleted { return false }
        if unreadOnly && message.isSeen { return false }
        if !mailbox.matches(message.mailboxPath) { return false }
        if let needle = senderContains?.lowercased(), !needle.isEmpty {
            let haystack = "\(message.fromDisplayName ?? "") \(message.from.rawValue)".lowercased()
            if !haystack.contains(needle) { return false }
        }
        if let sentAfter, (message.sentAt ?? .distantPast) < sentAfter { return false }
        if let sentBefore, (message.sentAt ?? .distantFuture) >= sentBefore { return false }
        if !categories.isEmpty && !categories.contains(message.smartCategory) { return false }
        return true
    }
}

public struct MailFilterResult: Equatable, Sendable {
    public let totalCount: Int
    public let messages: [MessageSummary]
    public init(totalCount: Int, messages: [MessageSummary]) {
        self.totalCount = totalCount
        self.messages = messages
    }
}

public struct RankedMailKnowledgeCandidate: Equatable, Sendable {
    public let message: MessageSummary
    public let snippet: String
    public let lexicalRank: Int
    public let lexicalScore: Double

    public init(message: MessageSummary, snippet: String, lexicalRank: Int, lexicalScore: Double) {
        self.message = message
        self.snippet = snippet
        self.lexicalRank = lexicalRank
        self.lexicalScore = lexicalScore
    }
}

public struct MailKnowledgeSource: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let messageID: MessageID
    public let conversationKey: String
    public let mailboxPath: String
    public let subject: String
    public let sender: String
    public let sentAt: Date?
    public let snippet: String

    public init(
        id: String,
        messageID: MessageID,
        conversationKey: String,
        mailboxPath: String,
        subject: String,
        sender: String,
        sentAt: Date?,
        snippet: String
    ) {
        self.id = id
        self.messageID = messageID
        self.conversationKey = conversationKey
        self.mailboxPath = mailboxPath
        self.subject = subject
        self.sender = sender
        self.sentAt = sentAt
        self.snippet = snippet
    }
}

public struct StoredMailEmbeddingChunk: Equatable, Sendable {
    public let messageID: MessageID
    public let providerID: String
    public let modelID: String
    public let contentFingerprint: String
    public let ordinal: Int
    public let text: String
    public let vector: [Double]
    public let updatedAt: Date

    public init(
        messageID: MessageID,
        providerID: String,
        modelID: String,
        contentFingerprint: String,
        ordinal: Int,
        text: String,
        vector: [Double],
        updatedAt: Date = Date()
    ) {
        self.messageID = messageID
        self.providerID = providerID
        self.modelID = modelID
        self.contentFingerprint = contentFingerprint
        self.ordinal = ordinal
        self.text = text
        self.vector = vector
        self.updatedAt = updatedAt
    }
}

public protocol MailKnowledgeRepository: MessageRepository {
    func rankedMailSearch(_ query: MailKnowledgeQuery) throws -> [RankedMailKnowledgeCandidate]
    func filteredMailMessages(
        _ filter: MailKnowledgeFilter, accountID: AccountID?, limit: Int
    ) throws -> MailFilterResult
    /// Every message matching `filter` (same predicate and ownership test as
    /// `filteredMailMessages`), counted per smart category without a row limit.
    func filteredMailCategoryCounts(_ filter: MailKnowledgeFilter, accountID: AccountID?) throws -> [SmartCategory: Int]
    func accountMessageIDs(accountID: AccountID) throws -> Set<MessageID>
    /// Undeleted messages whose `MailThreading.conversationKey` is `conversationKey`, limited to
    /// `accountID` when set (same ownership test as `filteredMailMessages`).
    func conversationMessages(conversationKey: String, accountID: AccountID?) throws -> [MessageSummary]
    func storedMailEmbeddingChunks(providerID: String, modelID: String) throws -> [StoredMailEmbeddingChunk]
    func replaceMailEmbeddingChunks(
        messageID: MessageID,
        providerID: String,
        modelID: String,
        contentFingerprint: String,
        chunks: [StoredMailEmbeddingChunk]
    ) throws
}

public extension MailKnowledgeRepository {
    func storedMailEmbeddingChunks(providerID: String, modelID: String) throws -> [StoredMailEmbeddingChunk] { [] }
    func replaceMailEmbeddingChunks(
        messageID: MessageID,
        providerID: String,
        modelID: String,
        contentFingerprint: String,
        chunks: [StoredMailEmbeddingChunk]
    ) throws {}
}
