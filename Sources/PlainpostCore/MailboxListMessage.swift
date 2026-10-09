import Foundation

/// Body-free metadata used to build mailbox and conversation lists.
public struct MailboxListMessage: Equatable, Sendable, Identifiable {
    public let id: MessageID
    public let threadID: ThreadID?
    public let from: EmailAddress
    public let fromDisplayName: String?
    public let subject: String
    public let preview: String
    public let smartCategory: SmartCategory
    public let smartPriority: SmartPriority
    public let smartRequiresAction: Bool
    public let smartConfidence: Double?
    public let labels: [String]
    public let isSeen: Bool
    /// Some copy of the message carries \\Flagged.
    public let isFlagged: Bool
    public let mailboxPath: String
    public let isDeleted: Bool
    public let sentAt: Date?
    /// The account whose mailbox holds the message, when the query knows it.
    public let accountID: AccountID?

    public init(
        id: MessageID,
        threadID: ThreadID?,
        from: EmailAddress,
        fromDisplayName: String? = nil,
        subject: String,
        preview: String,
        smartCategory: SmartCategory,
        smartPriority: SmartPriority = .normal,
        smartRequiresAction: Bool = false,
        smartConfidence: Double? = nil,
        labels: [String] = [],
        isSeen: Bool = false,
        mailboxPath: String = "INBOX",
        isDeleted: Bool = false,
        sentAt: Date? = nil,
        accountID: AccountID? = nil,
        isFlagged: Bool = false
    ) {
        self.isFlagged = isFlagged
        self.id = id
        self.threadID = threadID
        self.from = from
        self.fromDisplayName = fromDisplayName
        self.subject = subject
        self.preview = preview
        self.smartCategory = smartCategory
        self.smartPriority = smartPriority
        self.smartRequiresAction = smartRequiresAction
        self.smartConfidence = smartConfidence
        self.labels = labels
        self.isSeen = isSeen
        self.mailboxPath = mailboxPath
        self.isDeleted = isDeleted
        self.sentAt = sentAt
        self.accountID = accountID
    }
}

/// Exact unread conversation totals for a mailbox, computed without loading message bodies.
public struct MailboxUnreadConversationCounts: Equatable, Sendable {
    public let total: Int
    public let personal: Int
    public let notifications: Int
    public let newsletters: Int

    public init(
        total: Int,
        personal: Int,
        notifications: Int,
        newsletters: Int
    ) {
        self.total = total
        self.personal = personal
        self.notifications = notifications
        self.newsletters = newsletters
    }
}
