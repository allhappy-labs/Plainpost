import Foundation

/// An Ask Mail answer: short text with numbered citations plus typed blocks the app renders.
/// Built by app code from real rows; the model only contributes text, quotes and card fields.
public struct AskMailAnswer: Equatable, Codable, Sendable {
    public var text: String
    public var citations: [AskMailCitation]
    public var blocks: [AskMailBlock]
    public var searched: [AskMailSearchToken]
    public var suggestions: [String]
    public var insufficientEvidence: Bool

    public init(text: String, citations: [AskMailCitation] = [], blocks: [AskMailBlock] = [],
                searched: [AskMailSearchToken] = [], suggestions: [String] = [],
                insufficientEvidence: Bool = false) {
        self.text = text
        self.citations = citations
        self.blocks = blocks
        self.searched = searched
        self.suggestions = suggestions
        self.insufficientEvidence = insufficientEvidence
    }

    /// Every message the answer points at; each must pass the account ownership check.
    public var referencedMessageIDs: Set<MessageID> {
        var ids = Set(citations.map(\.source.messageID))
        for block in blocks {
            switch block {
            case .messages(let list):
                for section in list.sections {
                    ids.formUnion(section.rows.map(\.messageID))
                    ids.formUnion(section.actionMessageIDs)
                }
            case .card(let card): ids.insert(card.source.messageID)
            case .quotes(let quotes): ids.formUnion(quotes.quotes.map(\.source.messageID))
            case .draft(let draft): ids.insert(draft.replyToMessageID)
            case .options: break
            }
        }
        return ids
    }
}

public struct AskMailCitation: Equatable, Codable, Sendable {
    public var number: Int
    public var source: MailKnowledgeSource
    public init(number: Int, source: MailKnowledgeSource) { self.number = number; self.source = source }
}

public struct AskMailSearchToken: Equatable, Codable, Sendable, Hashable {
    public var label: String
    public init(label: String) { self.label = label }
}

public enum AskMailBlock: Equatable, Codable, Sendable {
    case messages(AskMailMessageListBlock)
    case card(AskMailCardBlock)
    case quotes(AskMailQuoteBlock)
    case draft(AskMailDraftBlock)
    case options(AskMailOptionsBlock)

    public var id: String {
        switch self {
        case .messages(let b): b.id
        case .card(let b): b.id
        case .quotes(let b): b.id
        case .draft(let b): b.id
        case .options(let b): b.id
        }
    }
}

public enum AskMailTint: String, Codable, Sendable, CaseIterable {
    case blue, teal, purple, green, orange, pink, gray
}

public enum AskMailIcon: String, Codable, Sendable, CaseIterable {
    case tray, person, bell, newspaper, receipt, airplane, calendar, creditCard, shippingBox,
         quote, draft, magnifier, shield, sparkles
}

public struct AskMailMessageRow: Equatable, Codable, Sendable, Identifiable {
    public var id: MessageID { messageID }
    public var messageID: MessageID
    public var conversationKey: String
    public var mailboxPath: String
    public var sender: String
    public var senderAddress: String
    public var subject: String
    public var snippet: String
    public var sentAt: Date?
    public var isUnread: Bool
    public var tag: String?

    public init(messageID: MessageID, conversationKey: String, mailboxPath: String, sender: String,
                senderAddress: String, subject: String, snippet: String, sentAt: Date?,
                isUnread: Bool, tag: String?) {
        self.messageID = messageID
        self.conversationKey = conversationKey
        self.mailboxPath = mailboxPath
        self.sender = sender
        self.senderAddress = senderAddress
        self.subject = subject
        self.snippet = snippet
        self.sentAt = sentAt
        self.isUnread = isUnread
        self.tag = tag
    }

    public var source: MailKnowledgeSource {
        MailKnowledgeSource(id: messageID.rawValue, messageID: messageID, conversationKey: conversationKey,
                            mailboxPath: mailboxPath, subject: subject, sender: sender, sentAt: sentAt,
                            snippet: snippet)
    }
}

public struct AskMailMessageSection: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var tint: AskMailTint
    /// Real number of matching messages, even when rows/actionMessageIDs are capped.
    public var totalCount: Int
    public var summary: String
    /// Rows shown in the UI (capped at `AskMailLimits.rowsPerSection`).
    public var rows: [AskMailMessageRow]
    /// Messages a bulk action applies to (capped at `AskMailLimits.actionIDsPerSection`).
    public var actionMessageIDs: [MessageID]

    public init(id: String, title: String, tint: AskMailTint, totalCount: Int, summary: String,
                rows: [AskMailMessageRow], actionMessageIDs: [MessageID]) {
        self.id = id
        self.title = title
        self.tint = tint
        self.totalCount = totalCount
        self.summary = summary
        self.rows = rows
        self.actionMessageIDs = actionMessageIDs
    }
}

public enum AskMailBulkAction: String, Codable, Sendable, CaseIterable {
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case archive
}

public enum AskMailRowAction: String, Codable, Sendable {
    case reply
}

public struct AskMailMessageListBlock: Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var icon: AskMailIcon
    public var tint: AskMailTint
    public var sections: [AskMailMessageSection]
    /// Empty means rows are not selectable.
    public var bulkActions: [AskMailBulkAction]
    public var rowAction: AskMailRowAction?

    public init(id: String, title: String, icon: AskMailIcon, tint: AskMailTint,
                sections: [AskMailMessageSection], bulkActions: [AskMailBulkAction],
                rowAction: AskMailRowAction?) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tint = tint
        self.sections = sections
        self.bulkActions = bulkActions
        self.rowAction = rowAction
    }

    public var totalCount: Int { sections.reduce(0) { $0 + $1.totalCount } }
}

public enum AskMailCardKind: String, Codable, Sendable, CaseIterable {
    case flight, invoice, event, delivery, booking, other
}

public struct AskMailCardField: Equatable, Codable, Sendable {
    public var label: String
    public var value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

public struct AskMailCalendarItem: Equatable, Codable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var location: String?
    public var notes: String?
    public init(title: String, start: Date, end: Date?, location: String?, notes: String?) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
    }
}

public struct AskMailReminderItem: Equatable, Codable, Sendable {
    public var title: String
    public var due: Date
    public var notes: String?
    public init(title: String, due: Date, notes: String?) { self.title = title; self.due = due; self.notes = notes }
}

public struct AskMailCardBlock: Equatable, Codable, Sendable {
    public var id: String
    public var kind: AskMailCardKind
    public var title: String
    public var badge: String?
    public var hero: String
    public var subtitle: String
    public var fields: [AskMailCardField]
    public var source: MailKnowledgeSource
    public var calendarItem: AskMailCalendarItem?
    public var reminderItem: AskMailReminderItem?

    public init(id: String, kind: AskMailCardKind, title: String, badge: String?, hero: String,
                subtitle: String, fields: [AskMailCardField], source: MailKnowledgeSource,
                calendarItem: AskMailCalendarItem?, reminderItem: AskMailReminderItem?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.badge = badge
        self.hero = hero
        self.subtitle = subtitle
        self.fields = fields
        self.source = source
        self.calendarItem = calendarItem
        self.reminderItem = reminderItem
    }
}

public struct AskMailQuote: Equatable, Codable, Sendable {
    public var number: Int
    public var source: MailKnowledgeSource
    public var excerpt: String
    /// A substring of `excerpt` to highlight; empty when nothing matched.
    public var highlight: String
    public init(number: Int, source: MailKnowledgeSource, excerpt: String, highlight: String) {
        self.number = number
        self.source = source
        self.excerpt = excerpt
        self.highlight = highlight
    }
}

public struct AskMailQuoteBlock: Equatable, Codable, Sendable {
    public var id: String
    public var quotes: [AskMailQuote]
    public init(id: String, quotes: [AskMailQuote]) { self.id = id; self.quotes = quotes }
}

public struct AskMailDraftBlock: Equatable, Codable, Sendable {
    public var id: String
    public var replyToMessageID: MessageID
    public var recipientName: String
    public var recipientAddress: String
    public var subject: String
    public var body: String
    public init(id: String, replyToMessageID: MessageID, recipientName: String, recipientAddress: String,
                subject: String, body: String) {
        self.id = id
        self.replyToMessageID = replyToMessageID
        self.recipientName = recipientName
        self.recipientAddress = recipientAddress
        self.subject = subject
        self.body = body
    }
}

/// How a "Try instead" option widens the original question's filters. Applied by the answer
/// service after interpreting the question, so it never depends on rephrasing the question.
public enum AskMailFilterOverride: String, Codable, Sendable, CaseIterable {
    /// Clear the date window.
    case dropDates = "drop_dates"
    /// Include read mail.
    case dropUnread = "drop_unread"
    /// Clear every filter and run a full-text search for the question.
    case searchAllMail = "search_all_mail"
}

public struct AskMailOption: Equatable, Codable, Sendable {
    public var label: String
    public var detail: String?
    /// Asked as a new question when the option is chosen.
    public var question: String
    /// Sent with `question`; `nil` in payloads written before overrides existed.
    public var filterOverride: AskMailFilterOverride?
    public init(label: String, detail: String?, question: String, filterOverride: AskMailFilterOverride? = nil) {
        self.label = label
        self.detail = detail
        self.question = question
        self.filterOverride = filterOverride
    }
}

public struct AskMailOptionsBlock: Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var options: [AskMailOption]
    public init(id: String, title: String, options: [AskMailOption]) {
        self.id = id
        self.title = title
        self.options = options
    }
}

public enum AskMailLimits {
    public static let rowsPerSection = 50
    public static let previewRowsPerSection = 3
    public static let actionIDsPerSection = 500
    public static let maxCards = 3
}
