import Foundation

public enum MailSearchMode: String, Codable, CaseIterable, Sendable {
    case conversations
    case messages
}

public enum MailSearchScopeContract {
    public static let maximumAccountCount = 64
    public static let maximumMailboxCount = 256
    public static let maximumIdentifierUTF8Length = 256

    public static func validate(_ scope: MailSearchSelectionScope) throws {
        guard scope.accountIDs.count <= maximumAccountCount else {
            throw MailSearchError.requestTooLarge(maximum: maximumAccountCount)
        }
        guard scope.mailboxIDs.count <= maximumMailboxCount else {
            throw MailSearchError.requestTooLarge(maximum: maximumMailboxCount)
        }
        guard scope.accountIDs.allSatisfy({ isValidIdentifier($0.rawValue) }),
              scope.mailboxIDs.allSatisfy({ isValidIdentifier($0.rawValue) }) else {
            throw MailSearchError.requestTooLarge(maximum: maximumIdentifierUTF8Length)
        }
    }

    public static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= maximumIdentifierUTF8Length else {
            return false
        }
        return !value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
        }
    }
}

public struct MailSearchSelectionScope: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case accountIDs
        case mailboxIDs
    }

    public var accountIDs: [AccountID]
    public var mailboxIDs: [MailboxID]

    public init(accountIDs: [AccountID] = [], mailboxIDs: [MailboxID] = []) {
        self.accountIDs = Array(Set(accountIDs)).sorted { $0.rawValue < $1.rawValue }
        self.mailboxIDs = Array(Set(mailboxIDs)).sorted { $0.rawValue < $1.rawValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accountIDs: try container.decode([AccountID].self, forKey: .accountIDs),
            mailboxIDs: try container.decode([MailboxID].self, forKey: .mailboxIDs)
        )
    }
}

public struct MailSearchCursor: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum MailSearchStableIdentity {
    public static let threadPrefix = "thread|"
    public static let messagePrefix = "message|"

    public static func thread(accountID: AccountID, threadID: ThreadID) -> String {
        threadPrefix + hex(accountID.rawValue) + "|" + hex(threadID.rawValue)
    }

    public static func message(accountID: AccountID, messageID: MessageID) -> String {
        messagePrefix + hex(accountID.rawValue) + "|" + hex(messageID.rawValue)
    }

    public static func isMessageBackedConversation(
        stableID: String,
        threadID: ThreadID,
        accountID: AccountID,
        bestMatchingMessageID: MessageID
    ) -> Bool {
        let identity = message(accountID: accountID, messageID: bestMatchingMessageID)
        return stableID == identity && isMessageBackedThreadIdentity(
            threadID.rawValue,
            accountID: accountID,
            messageID: bestMatchingMessageID
        )
    }

    public static func isMessageBackedThreadIdentity(
        _ threadID: String,
        accountID: AccountID,
        messageID: MessageID
    ) -> Bool {
        threadID == message(accountID: accountID, messageID: messageID)
    }

    private static func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02X", $0) }.joined()
    }
}

public enum MailSearchTextField: String, Codable, Sendable {
    case from
    case to
    case cc
    case bcc
    case participants
    case subject
    case filename
    case mailbox
}

public enum MailSearchContentFilter: String, Codable, Sendable {
    case attachment
    case document
}

public enum MailSearchStateFilter: String, Codable, Sendable {
    case unread
    case read
    case flagged
    case delegated
}

public enum MailSearchLocationFilter: String, Codable, Sendable {
    case inbox
    case sent
    case trash
}

public struct MailSearchDateInterval: Codable, Equatable, Sendable {
    public let lowerBound: Date?
    public let upperBound: Date?

    public init(lowerBound: Date?, upperBound: Date?) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public indirect enum MailSearchQueryExpression: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case prefix
        case field
        case expression
        case interval
        case expressions
    }

    private enum ExpressionType: String, Codable {
        case matchAll
        case term
        case phrase
        case field
        case content
        case state
        case location
        case date
        case all
        case any
        case not
    }

    case matchAll
    case term(String, prefix: Bool)
    case phrase(String)
    case field(MailSearchTextField, MailSearchQueryExpression)
    case content(MailSearchContentFilter)
    case state(MailSearchStateFilter)
    case location(MailSearchLocationFilter)
    case date(MailSearchDateInterval)
    case all([MailSearchQueryExpression])
    case any([MailSearchQueryExpression])
    case not(MailSearchQueryExpression)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ExpressionType.self, forKey: .type) {
        case .matchAll:
            self = .matchAll
        case .term:
            self = .term(
                try container.decode(String.self, forKey: .value),
                prefix: try container.decode(Bool.self, forKey: .prefix)
            )
        case .phrase:
            self = .phrase(try container.decode(String.self, forKey: .value))
        case .field:
            self = .field(
                try container.decode(MailSearchTextField.self, forKey: .field),
                try container.decode(MailSearchQueryExpression.self, forKey: .expression)
            )
        case .content:
            self = .content(
                try container.decode(MailSearchContentFilter.self, forKey: .value)
            )
        case .state:
            self = .state(
                try container.decode(MailSearchStateFilter.self, forKey: .value)
            )
        case .location:
            self = .location(
                try container.decode(MailSearchLocationFilter.self, forKey: .value)
            )
        case .date:
            self = .date(
                try container.decode(MailSearchDateInterval.self, forKey: .interval)
            )
        case .all:
            self = .all(
                try container.decode([MailSearchQueryExpression].self, forKey: .expressions)
            )
        case .any:
            self = .any(
                try container.decode([MailSearchQueryExpression].self, forKey: .expressions)
            )
        case .not:
            self = .not(
                try container.decode(MailSearchQueryExpression.self, forKey: .expression)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .matchAll:
            try container.encode(ExpressionType.matchAll, forKey: .type)
        case .term(let value, let prefix):
            try container.encode(ExpressionType.term, forKey: .type)
            try container.encode(value, forKey: .value)
            try container.encode(prefix, forKey: .prefix)
        case .phrase(let value):
            try container.encode(ExpressionType.phrase, forKey: .type)
            try container.encode(value, forKey: .value)
        case .field(let field, let expression):
            try container.encode(ExpressionType.field, forKey: .type)
            try container.encode(field, forKey: .field)
            try container.encode(expression, forKey: .expression)
        case .content(let value):
            try container.encode(ExpressionType.content, forKey: .type)
            try container.encode(value, forKey: .value)
        case .state(let value):
            try container.encode(ExpressionType.state, forKey: .type)
            try container.encode(value, forKey: .value)
        case .location(let value):
            try container.encode(ExpressionType.location, forKey: .type)
            try container.encode(value, forKey: .value)
        case .date(let interval):
            try container.encode(ExpressionType.date, forKey: .type)
            try container.encode(interval, forKey: .interval)
        case .all(let expressions):
            try container.encode(ExpressionType.all, forKey: .type)
            try container.encode(expressions, forKey: .expressions)
        case .any(let expressions):
            try container.encode(ExpressionType.any, forKey: .type)
            try container.encode(expressions, forKey: .expressions)
        case .not(let expression):
            try container.encode(ExpressionType.not, forKey: .type)
            try container.encode(expression, forKey: .expression)
        }
    }
}

public extension MailSearchQueryExpression {
    func normalized() -> MailSearchQueryExpression {
        switch self {
        case .matchAll:
            return self
        case .field(let field, let expression):
            return .field(field, expression.normalized())
        case .all(let expressions):
            let values = expressions.flatMap { expression -> [MailSearchQueryExpression] in
                let normalized = expression.normalized()
                if case .all(let nested) = normalized { return nested }
                return [normalized]
            }
            return values.count == 1 ? values[0] : .all(values)
        case .any(let expressions):
            let values = expressions.flatMap { expression -> [MailSearchQueryExpression] in
                let normalized = expression.normalized()
                if case .any(let nested) = normalized { return nested }
                return [normalized]
            }
            return values.count == 1 ? values[0] : .any(values)
        case .not(let expression):
            return .not(expression.normalized())
        case .term, .phrase, .content, .state, .location, .date:
            return self
        }
    }

    var canonicalDescription: String {
        renderedCanonicalDescription(parentPrecedence: 0)
    }

    private var canonicalPrecedence: Int {
        switch self {
        case .any: 1
        case .all: 2
        case .not: 3
        default: 4
        }
    }

    private func renderedCanonicalDescription(parentPrecedence: Int) -> String {
        let rendered: String
        switch self {
        case .matchAll:
            rendered = "*"
        case .term(let value, _):
            rendered = value
        case .phrase(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            rendered = "\"\(escaped)\""
        case .field(let field, let expression):
            let value = expression.renderedCanonicalDescription(parentPrecedence: 0)
            switch expression {
            case .all, .any, .not:
                rendered = "\(field.rawValue):(\(value))"
            default:
                rendered = "\(field.rawValue):\(value)"
            }
        case .content(let filter):
            rendered = "has:\(filter.rawValue)"
        case .state(let filter):
            rendered = "is:\(filter.rawValue)"
        case .location(let filter):
            rendered = "in:\(filter.rawValue)"
        case .date(let interval):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let lower = interval.lowerBound.map(formatter.string(from:)) ?? "*"
            let upper = interval.upperBound.map(formatter.string(from:)) ?? "*"
            rendered = "date:[\(lower)..\(upper))"
        case .all(let expressions):
            rendered = expressions.map {
                $0.renderedCanonicalDescription(parentPrecedence: canonicalPrecedence)
            }.joined(separator: " AND ")
        case .any(let expressions):
            rendered = expressions.map {
                $0.renderedCanonicalDescription(parentPrecedence: canonicalPrecedence)
            }.joined(separator: " OR ")
        case .not(let expression):
            rendered = "NOT \(expression.renderedCanonicalDescription(parentPrecedence: canonicalPrecedence))"
        }

        if canonicalPrecedence < parentPrecedence {
            return "(\(rendered))"
        }
        return rendered
    }
}

public struct MailSearchParsedQuery: Codable, Equatable, Sendable {
    public let expression: MailSearchQueryExpression
    public let tokens: [MailSearchPresentationToken]
    public let canonicalQuery: String

    public init(
        expression: MailSearchQueryExpression,
        tokens: [MailSearchPresentationToken],
        canonicalQuery: String
    ) {
        self.expression = expression
        self.tokens = tokens
        self.canonicalQuery = canonicalQuery
    }
}

public struct MailSearchRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case query
        case scope
        case mode
        case limit
        case cursor
    }

    public static let defaultLimit = 50
    public static let maximumLimit = 100

    public let query: String
    public let scope: MailSearchSelectionScope
    public let mode: MailSearchMode
    public let limit: Int
    public let cursor: MailSearchCursor?

    public init(
        query: String,
        scope: MailSearchSelectionScope = .init(),
        mode: MailSearchMode = .conversations,
        limit: Int = defaultLimit,
        cursor: MailSearchCursor? = nil
    ) {
        self.query = query
        self.scope = scope
        self.mode = mode
        self.limit = min(Self.maximumLimit, max(1, limit))
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            query: try container.decode(String.self, forKey: .query),
            scope: try container.decode(MailSearchSelectionScope.self, forKey: .scope),
            mode: try container.decode(MailSearchMode.self, forKey: .mode),
            limit: try container.decode(Int.self, forKey: .limit),
            cursor: try container.decodeIfPresent(MailSearchCursor.self, forKey: .cursor)
        )
    }

    public func validate() throws {
        try MailSearchScopeContract.validate(scope)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !scope.accountIDs.isEmpty
                || !scope.mailboxIDs.isEmpty else {
            throw MailSearchError.invalidQuery(
                reason: "Query is empty unless an account or mailbox scope is selected.",
                range: nil
            )
        }
    }
}

public struct MailSearchTextRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum MailSearchPresentationTokenKind: String, Codable, Sendable {
    case text
    case phrase
    case filter
    case boolean
    case grouping
}

public struct MailSearchPresentationToken: Codable, Equatable, Sendable {
    public let kind: MailSearchPresentationTokenKind
    public let text: String
    public let sourceRange: MailSearchTextRange

    public init(
        kind: MailSearchPresentationTokenKind,
        text: String,
        sourceRange: MailSearchTextRange
    ) {
        self.kind = kind
        self.text = text
        self.sourceRange = sourceRange
    }
}

public enum MailSearchModelError: Error, Equatable, Sendable {
    case invalidHighlightRange
}

public struct MailSearchSnippet: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case text
        case highlights
    }

    public let text: String
    public let highlights: [MailSearchTextRange]

    public init(text: String, highlights: [MailSearchTextRange]) throws {
        let string = text as NSString
        var previousEnd = 0

        for highlight in highlights {
            let location = highlight.location
            let length = highlight.length
            guard location >= 0,
                  length > 0,
                  location <= string.length,
                  length <= string.length - location,
                  location >= previousEnd
            else {
                throw MailSearchModelError.invalidHighlightRange
            }

            let range = NSRange(location: location, length: length)
            guard string.rangeOfComposedCharacterSequences(for: range) == range else {
                throw MailSearchModelError.invalidHighlightRange
            }
            previousEnd = location + length
        }

        self.text = text
        self.highlights = highlights
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: container.decode(String.self, forKey: .text),
            highlights: container.decode([MailSearchTextRange].self, forKey: .highlights)
        )
    }
}

public struct MailConversationSearchHit: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case stableID
        case threadID
        case accountID
        case bestMatchingMessageID
        case subject
        case participants
        case latestActivity
        case snippet
        case matchingMessageCount
        case totalMessageCount
        case unreadMessageCount
        case hasAttachments
        case hasDocuments
        case bestMatchSender
        case bestMatchSenderDisplayName
    }

    public let stableID: String
    public let threadID: ThreadID
    public let accountID: AccountID
    public let bestMatchingMessageID: MessageID
    public let subject: String
    public let participants: [String]
    public let latestActivity: Date?
    public let snippet: MailSearchSnippet
    public let matchingMessageCount: Int
    public let totalMessageCount: Int
    public let unreadMessageCount: Int
    public let hasAttachments: Bool
    public let hasDocuments: Bool
    /// Who sent the best-matching message, so a row can name its sender. `participants` is
    /// sorted and mixes in recipients. Nil from sources that predate these fields.
    public let bestMatchSender: EmailAddress?
    public let bestMatchSenderDisplayName: String?

    public init(
        stableID: String,
        threadID: ThreadID,
        accountID: AccountID,
        bestMatchingMessageID: MessageID,
        subject: String,
        participants: [String],
        latestActivity: Date?,
        snippet: MailSearchSnippet,
        matchingMessageCount: Int,
        totalMessageCount: Int,
        unreadMessageCount: Int,
        hasAttachments: Bool,
        hasDocuments: Bool,
        bestMatchSender: EmailAddress? = nil,
        bestMatchSenderDisplayName: String? = nil
    ) {
        self.stableID = stableID
        self.threadID = threadID
        self.accountID = accountID
        self.bestMatchingMessageID = bestMatchingMessageID
        self.subject = subject
        self.participants = participants
        self.latestActivity = latestActivity
        self.snippet = snippet
        self.matchingMessageCount = matchingMessageCount
        self.totalMessageCount = totalMessageCount
        self.unreadMessageCount = unreadMessageCount
        self.hasAttachments = hasAttachments
        self.hasDocuments = hasDocuments
        self.bestMatchSender = bestMatchSender
        self.bestMatchSenderDisplayName = bestMatchSenderDisplayName
    }
}

public struct MailMessageSearchHit: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case stableID
        case messageID
        case threadID
        case accountID
        case sender
        case senderDisplayName
        case recipients
        case subject
        case sentAt
        case snippet
        case isUnread
        case isFlagged
        case isDelegated
        case mailboxIDs
        case hasAttachments
        case hasDocuments
    }

    public let stableID: String
    public let messageID: MessageID
    public let threadID: ThreadID
    public let accountID: AccountID
    public let sender: EmailAddress
    public let senderDisplayName: String?
    public let recipients: [EmailAddress]
    public let subject: String
    public let sentAt: Date?
    public let snippet: MailSearchSnippet
    public let isUnread: Bool
    public let isFlagged: Bool
    public let isDelegated: Bool
    public let mailboxIDs: [MailboxID]
    public let hasAttachments: Bool
    public let hasDocuments: Bool

    public init(
        stableID: String,
        messageID: MessageID,
        threadID: ThreadID,
        accountID: AccountID,
        sender: EmailAddress,
        senderDisplayName: String?,
        recipients: [EmailAddress],
        subject: String,
        sentAt: Date?,
        snippet: MailSearchSnippet,
        isUnread: Bool,
        isFlagged: Bool,
        isDelegated: Bool,
        mailboxIDs: [MailboxID],
        hasAttachments: Bool,
        hasDocuments: Bool
    ) {
        self.stableID = stableID
        self.messageID = messageID
        self.threadID = threadID
        self.accountID = accountID
        self.sender = sender
        self.senderDisplayName = senderDisplayName
        self.recipients = recipients
        self.subject = subject
        self.sentAt = sentAt
        self.snippet = snippet
        self.isUnread = isUnread
        self.isFlagged = isFlagged
        self.isDelegated = isDelegated
        self.mailboxIDs = mailboxIDs
        self.hasAttachments = hasAttachments
        self.hasDocuments = hasDocuments
    }
}

public enum MailSearchHit: Codable, Equatable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum HitType: String, Codable {
        case conversation
        case message
    }

    case conversation(MailConversationSearchHit)
    case message(MailMessageSearchHit)

    public var id: String {
        switch self {
        case .conversation(let hit):
            hit.stableID
        case .message(let hit):
            hit.stableID
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(HitType.self, forKey: .type) {
        case .conversation:
            self = .conversation(
                try container.decode(MailConversationSearchHit.self, forKey: .value)
            )
        case .message:
            self = .message(
                try container.decode(MailMessageSearchHit.self, forKey: .value)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conversation(let hit):
            try container.encode(HitType.conversation, forKey: .type)
            try container.encode(hit, forKey: .value)
        case .message(let hit):
            try container.encode(HitType.message, forKey: .type)
            try container.encode(hit, forKey: .value)
        }
    }
}

public struct MailSearchResponse: Codable, Equatable, Sendable {
    public let parsedQuery: MailSearchParsedQuery
    public let mode: MailSearchMode
    public let scope: MailSearchSelectionScope
    public let hits: [MailSearchHit]
    public let nextCursor: MailSearchCursor?
    public let indexRevision: String

    public init(
        parsedQuery: MailSearchParsedQuery,
        mode: MailSearchMode,
        scope: MailSearchSelectionScope,
        hits: [MailSearchHit],
        nextCursor: MailSearchCursor?,
        indexRevision: String
    ) {
        self.parsedQuery = parsedQuery
        self.mode = mode
        self.scope = scope
        self.hits = hits
        self.nextCursor = nextCursor
        self.indexRevision = indexRevision
    }
}

public enum MailSearchSuggestionKind: String, Codable, Sendable {
    case recent
    case people
    case fields
    case filters
}

public struct MailSearchSuggestionItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let insertion: String
    public let replacementRange: MailSearchTextRange?

    public init(
        id: String,
        title: String,
        detail: String,
        insertion: String,
        replacementRange: MailSearchTextRange?
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.insertion = insertion
        self.replacementRange = replacementRange
    }
}

public struct MailSearchSuggestionSection: Codable, Equatable, Sendable {
    public let kind: MailSearchSuggestionKind
    public let items: [MailSearchSuggestionItem]

    public init(kind: MailSearchSuggestionKind, items: [MailSearchSuggestionItem]) {
        self.kind = kind
        self.items = items
    }
}

public struct MailSearchSuggestionRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case query
        case scope
        case recentQueries
        case activeRange
    }

    public let query: String
    public let scope: MailSearchSelectionScope
    public let recentQueries: [String]
    public let activeRange: MailSearchTextRange?

    public init(
        query: String,
        scope: MailSearchSelectionScope = .init(),
        recentQueries: [String],
        activeRange: MailSearchTextRange? = nil
    ) {
        self.query = query
        self.scope = scope
        var normalizedQueries: [String] = []
        for rawQuery in recentQueries {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty,
                  !normalizedQueries.contains(where: {
                      $0.caseInsensitiveCompare(query) == .orderedSame
                  })
            else {
                continue
            }
            normalizedQueries.append(query)
            if normalizedQueries.count == 10 {
                break
            }
        }
        self.recentQueries = normalizedQueries
        self.activeRange = Self.normalizedActiveRange(activeRange, in: query)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            query: try container.decode(String.self, forKey: .query),
            scope: try container.decode(MailSearchSelectionScope.self, forKey: .scope),
            recentQueries: try container.decode([String].self, forKey: .recentQueries),
            activeRange: try container.decodeIfPresent(MailSearchTextRange.self, forKey: .activeRange)
        )
    }

    private static func normalizedActiveRange(
        _ activeRange: MailSearchTextRange?,
        in query: String
    ) -> MailSearchTextRange? {
        guard let activeRange else { return nil }
        let source = query as NSString
        guard activeRange.location >= 0,
              activeRange.length >= 0,
              activeRange.location <= source.length,
              activeRange.length <= source.length - activeRange.location else {
            return nil
        }
        let requested = NSRange(location: activeRange.location, length: activeRange.length)
        let composed = source.rangeOfComposedCharacterSequences(for: requested)
        return .init(location: composed.location, length: composed.length)
    }
}

public enum MailSearchIndexState: String, Codable, Equatable, Sendable {
    case ready
    case preparing
    case rebuilding
    case unavailable
}

public enum MailSearchError: Error, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case code
        case reason
        case range
        case name
        case field
        case value
        case maximum
    }

    private enum WireCode: String, Codable {
        case invalidQuery = "INVALID_QUERY"
        case unsupportedField = "UNSUPPORTED_FIELD"
        case unsupportedValue = "UNSUPPORTED_VALUE"
        case requestTooLarge = "REQUEST_TOO_LARGE"
        case invalidCursor = "INVALID_CURSOR"
        case staleCursor = "STALE_CURSOR"
        case rebuilding = "SEARCH_REBUILDING"
        case unavailable = "SEARCH_UNAVAILABLE"
        case cancelled = "CANCELLED"
    }

    case invalidQuery(reason: String, range: MailSearchTextRange?)
    case unsupportedField(name: String, range: MailSearchTextRange)
    case unsupportedValue(field: String, range: MailSearchTextRange)
    case requestTooLarge(maximum: Int)
    case invalidCursor
    case staleCursor
    case rebuilding
    case unavailable
    case cancelled

    public var code: String {
        wireCode.rawValue
    }

    private var wireCode: WireCode {
        switch self {
        case .invalidQuery:
            .invalidQuery
        case .unsupportedField:
            .unsupportedField
        case .unsupportedValue:
            .unsupportedValue
        case .requestTooLarge:
            .requestTooLarge
        case .invalidCursor:
            .invalidCursor
        case .staleCursor:
            .staleCursor
        case .rebuilding:
            .rebuilding
        case .unavailable:
            .unavailable
        case .cancelled:
            .cancelled
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireCode.self, forKey: .code) {
        case .invalidQuery:
            self = .invalidQuery(
                reason: try container.decode(String.self, forKey: .reason),
                range: try container.decodeIfPresent(MailSearchTextRange.self, forKey: .range)
            )
        case .unsupportedField:
            self = .unsupportedField(
                name: try container.decode(String.self, forKey: .name),
                range: try container.decode(MailSearchTextRange.self, forKey: .range)
            )
        case .unsupportedValue:
            guard !container.contains(.value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Rejected search values are not part of the canonical error shape."
                )
            }
            self = .unsupportedValue(
                field: try container.decode(String.self, forKey: .field),
                range: try container.decode(MailSearchTextRange.self, forKey: .range)
            )
        case .requestTooLarge:
            self = .requestTooLarge(
                maximum: try container.decode(Int.self, forKey: .maximum)
            )
        case .invalidCursor:
            self = .invalidCursor
        case .staleCursor:
            self = .staleCursor
        case .rebuilding:
            self = .rebuilding
        case .unavailable:
            self = .unavailable
        case .cancelled:
            self = .cancelled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireCode, forKey: .code)
        switch self {
        case .invalidQuery(let reason, let range):
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(range, forKey: .range)
        case .unsupportedField(let name, let range):
            try container.encode(name, forKey: .name)
            try container.encode(range, forKey: .range)
        case .unsupportedValue(let field, let range):
            try container.encode(field, forKey: .field)
            try container.encode(range, forKey: .range)
        case .requestTooLarge(let maximum):
            try container.encode(maximum, forKey: .maximum)
        case .invalidCursor, .staleCursor, .rebuilding, .unavailable, .cancelled:
            break
        }
    }
}

public enum MailSearchJSON {
    private static let fractionalSecondsDateFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSince1970
            let milliseconds = (seconds * 1_000).rounded()
            guard seconds.isFinite, milliseconds.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Expected a finite supported timestamp."
                    )
                )
            }
            // Normalize to rounded millisecond precision, then shift by half
            // a millisecond because ISO8601FormatStyle truncates. A decoded
            // value therefore formats to the identical canonical bytes.
            let normalized = Date(timeIntervalSince1970: milliseconds / 1_000)
                .addingTimeInterval(0.000_5)
            var container = encoder.singleValueContainer()
            try container.encode(normalized.formatted(fractionalSecondsDateFormat))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            do {
                return try fractionalSecondsDateFormat.parse(value)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp with fractional seconds."
                )
            }
        }
        return decoder
    }
}
