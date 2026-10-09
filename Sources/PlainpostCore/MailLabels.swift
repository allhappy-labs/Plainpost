import Foundation

public enum MailLabelScope: Equatable, Codable, Sendable {
    case allAccounts
    case account(AccountID)

    public var accountID: AccountID? {
        if case .account(let accountID) = self { return accountID }
        return nil
    }

    public func includes(_ accountID: AccountID) -> Bool {
        switch self {
        case .allAccounts: true
        case .account(let scopedID): scopedID == accountID
        }
    }
}

public enum MailLabelValidationError: Error, Equatable, Sendable {
    case missingTitle
    case titleTooLong
    case descriptionTooLong
    case smartInboxDescriptionRequired
    case duplicateEffectiveTitle
    case effectiveSmartInboxLimitExceeded(scope: MailLabelScope)
    case immutableScope
    case unknownLabel
    case outOfScopeLabel
}

public struct MailLabelDefinition: Equatable, Codable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var description: String
    public var isSmartInboxEnabled: Bool
    public let scope: MailLabelScope
    public let createdAt: Date
    public var updatedAt: Date

    public var normalizedTitle: String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    public static func validated(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        description: String,
        isSmartInboxEnabled: Bool,
        scope: MailLabelScope,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws -> MailLabelDefinition {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MailLabelValidationError.missingTitle }
        guard title.count <= 64 else { throw MailLabelValidationError.titleTooLong }
        guard description.count <= 280 else { throw MailLabelValidationError.descriptionTooLong }
        guard !isSmartInboxEnabled || !description.isEmpty else {
            throw MailLabelValidationError.smartInboxDescriptionRequired
        }
        return .init(
            id: id, title: title, description: description,
            isSmartInboxEnabled: isSmartInboxEnabled, scope: scope,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    public init(
        id: String,
        title: String,
        description: String,
        isSmartInboxEnabled: Bool,
        scope: MailLabelScope,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.isSmartInboxEnabled = isSmartInboxEnabled
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MailLabelAssignmentSource: Equatable, Codable, Hashable, Sendable {
    case user
    case rule(ruleID: String)
    case smartInbox
}

public struct MailLabelAssignment: Equatable, Codable, Sendable {
    public let messageID: MessageID
    public let labelID: String
    public let source: MailLabelAssignmentSource
    public let createdAt: Date

    public init(messageID: MessageID, labelID: String, source: MailLabelAssignmentSource, createdAt: Date) {
        self.messageID = messageID
        self.labelID = labelID
        self.source = source
        self.createdAt = createdAt
    }
}

public struct MailLabelExclusion: Equatable, Codable, Sendable {
    public let messageID: MessageID
    public let labelID: String
    public let createdAt: Date

    public init(messageID: MessageID, labelID: String, createdAt: Date) {
        self.messageID = messageID
        self.labelID = labelID
        self.createdAt = createdAt
    }
}

public struct MessageLabelActionSnapshot: Equatable, Sendable {
    public let accountID: AccountID?
    public let labels: [MailLabelDefinition]
    public let assignments: [MailLabelAssignment]
    public let exclusions: [MailLabelExclusion]
    public let ruleNames: [String: String]

    public init(
        accountID: AccountID?,
        labels: [MailLabelDefinition],
        assignments: [MailLabelAssignment],
        exclusions: [MailLabelExclusion],
        ruleNames: [String: String]
    ) {
        self.accountID = accountID
        self.labels = labels
        self.assignments = assignments
        self.exclusions = exclusions
        self.ruleNames = ruleNames
    }
}

public struct SmartInboxLabelMatch: Equatable, Codable, Sendable {
    public let labelID: String
    public let confidence: Double

    public init(labelID: String, confidence: Double) {
        self.labelID = labelID
        self.confidence = confidence
    }
}

public struct SmartInboxClassificationInput: Equatable, Sendable {
    public let message: MailboxListMessage
    public let accountID: AccountID
    public let recipients: [EmailAddress]
    public let bodyExcerpt: String

    public init(
        message: MailboxListMessage,
        accountID: AccountID,
        recipients: [EmailAddress],
        bodyExcerpt: String
    ) {
        self.message = message
        self.accountID = accountID
        self.recipients = recipients
        self.bodyExcerpt = bodyExcerpt
    }
}

public struct MailLabelCatalogSnapshot: Equatable, Codable, Sendable {
    public let labels: [MailLabelDefinition]
    public let fingerprint: String
    public let createdAt: Date

    public init(labels: [MailLabelDefinition], fingerprint: String, createdAt: Date) {
        self.labels = labels
        self.fingerprint = fingerprint
        self.createdAt = createdAt
    }

    public func eligibleLabels(for accountID: AccountID) -> [MailLabelDefinition] {
        labels.filter { $0.isSmartInboxEnabled && !$0.description.isEmpty && $0.scope.includes(accountID) }
    }
}

public struct MailLabelDeletionPreview: Equatable, Sendable {
    public let labelID: String
    public let scope: MailLabelScope
    public let affectedMessageCount: Int
    public let affectedRuleCount: Int

    public init(labelID: String, scope: MailLabelScope, affectedMessageCount: Int, affectedRuleCount: Int) {
        self.labelID = labelID
        self.scope = scope
        self.affectedMessageCount = affectedMessageCount
        self.affectedRuleCount = affectedRuleCount
    }
}

public struct MailLabelReclassificationPreview: Equatable, Sendable {
    public let labelID: String
    public let scope: MailLabelScope
    public let affectedMessageCount: Int

    public init(labelID: String, scope: MailLabelScope, affectedMessageCount: Int) {
        self.labelID = labelID
        self.scope = scope
        self.affectedMessageCount = affectedMessageCount
    }
}
