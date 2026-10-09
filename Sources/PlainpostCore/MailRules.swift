import Foundation

public enum MailRuleScope: Equatable, Codable, Sendable {
    case allAccounts
    case account(AccountID)

    public func includes(_ accountID: AccountID) -> Bool {
        switch self {
        case .allAccounts:
            true
        case .account(let scopedID):
            scopedID == accountID
        }
    }
}

public enum MailRuleConditionField: String, Codable, CaseIterable, Sendable {
    case from
    case recipients
    case subject
}

public enum MailRuleConditionOperator: String, Codable, CaseIterable, Sendable {
    case emailIs
    case domainIs
    case contains
}

public struct MailRuleCondition: Equatable, Codable, Identifiable, Sendable {
    public let id: String
    public let field: MailRuleConditionField
    public let `operator`: MailRuleConditionOperator
    public let value: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        field: MailRuleConditionField,
        operator: MailRuleConditionOperator,
        value: String
    ) {
        self.id = id
        self.field = field
        self.operator = `operator`
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MailRuleAction: String, Codable, CaseIterable, Hashable, Sendable {
    case skipInbox
    case markAsRead
    case suppressNotification
}

public enum MailRuleValidationError: Error, Equatable, Sendable {
    case missingName
    case missingConditions
    case emptyConditionValue
    case invalidConditionOperator
    case missingActions
}

public struct MailRuleActionCounts: Equatable, Sendable {
    public let archiveCount: Int
    public let markReadCount: Int

    public init(archiveCount: Int = 0, markReadCount: Int = 0) {
        self.archiveCount = archiveCount
        self.markReadCount = markReadCount
    }
}

public struct MailRuleExistingMatch: Equatable, Identifiable, Sendable {
    public var id: String { messageID.rawValue }
    public let messageID: MessageID
    public let accountID: AccountID
    public let subject: String
    public let sender: EmailAddress
    public let actions: Set<MailRuleAction>
    public let labelIDs: [String]

    public init(
        messageID: MessageID,
        accountID: AccountID,
        subject: String,
        sender: EmailAddress,
        actions: Set<MailRuleAction>,
        labelIDs: [String] = []
    ) {
        self.messageID = messageID
        self.accountID = accountID
        self.subject = subject
        self.sender = sender
        self.actions = actions
        self.labelIDs = Array(Set(labelIDs)).sorted()
    }
}

public struct MailRuleExistingPreview: Equatable, Sendable {
    public let ruleID: String
    public let matches: [MailRuleExistingMatch]
    public let countsByAccount: [AccountID: MailRuleActionCounts]

    public init(
        ruleID: String,
        matches: [MailRuleExistingMatch],
        countsByAccount: [AccountID: MailRuleActionCounts]
    ) {
        self.ruleID = ruleID
        self.matches = matches
        self.countsByAccount = countsByAccount
    }

    public var archiveCount: Int {
        matches.filter { $0.actions.contains(.skipInbox) }.count
    }

    public var markReadCount: Int {
        matches.filter { $0.actions.contains(.markAsRead) }.count
    }
}

public struct MailRuleRun: Equatable, Identifiable, Sendable {
    public let id: String
    public let ruleID: String
    public let messageIDs: [MessageID]
    public let totalItemCount: Int
    public let enqueuedItemCount: Int
    public let completedItemCount: Int
    public let failedItemCount: Int

    public init(
        id: String,
        ruleID: String,
        messageIDs: [MessageID],
        totalItemCount: Int,
        enqueuedItemCount: Int,
        completedItemCount: Int,
        failedItemCount: Int
    ) {
        self.id = id
        self.ruleID = ruleID
        self.messageIDs = messageIDs
        self.totalItemCount = totalItemCount
        self.enqueuedItemCount = enqueuedItemCount
        self.completedItemCount = completedItemCount
        self.failedItemCount = failedItemCount
    }
}

public struct MailRuleCandidateMessage: Equatable, Sendable {
    public let message: MessageSummary
    public let accountID: AccountID

    public init(message: MessageSummary, accountID: AccountID) {
        self.message = message
        self.accountID = accountID
    }
}

public struct MailRule: Equatable, Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var isEnabled: Bool
    public var scope: MailRuleScope
    public var conditions: [MailRuleCondition]
    public var actions: Set<MailRuleAction>
    public var labelIDs: [String]
    public let createdAt: Date
    public var updatedAt: Date

    public static func validated(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        isEnabled: Bool = true,
        scope: MailRuleScope,
        conditions: [MailRuleCondition],
        actions: Set<MailRuleAction>,
        labelIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws -> MailRule {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MailRuleValidationError.missingName
        }
        guard !conditions.isEmpty else {
            throw MailRuleValidationError.missingConditions
        }
        guard conditions.allSatisfy({ !$0.value.isEmpty }) else {
            throw MailRuleValidationError.emptyConditionValue
        }
        guard conditions.allSatisfy(Self.hasValidOperator) else {
            throw MailRuleValidationError.invalidConditionOperator
        }
        guard !actions.isEmpty || !labelIDs.isEmpty || !isEnabled else {
            throw MailRuleValidationError.missingActions
        }
        return MailRule(
            id: id,
            name: trimmedName,
            isEnabled: isEnabled,
            scope: scope,
            conditions: conditions.map(Self.normalized),
            actions: actions,
            labelIDs: Array(Set(labelIDs)).sorted(),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func hasValidOperator(_ condition: MailRuleCondition) -> Bool {
        switch (condition.field, condition.operator) {
        case (.from, .emailIs), (.from, .domainIs),
             (.recipients, .emailIs), (.recipients, .domainIs),
             (.subject, .contains):
            true
        default:
            false
        }
    }

    private static func normalized(_ condition: MailRuleCondition) -> MailRuleCondition {
        let value: String
        switch condition.operator {
        case .emailIs:
            value = condition.value.lowercased()
        case .domainIs:
            let lowercased = condition.value.lowercased()
            value = lowercased.hasPrefix("@") ? String(lowercased.dropFirst()) : lowercased
        case .contains:
            value = condition.value
        }
        return MailRuleCondition(
            id: condition.id,
            field: condition.field,
            operator: condition.operator,
            value: value
        )
    }
}

public enum MailRuleEvaluator {
    public static func matches(
        message: MessageSummary,
        accountID: AccountID,
        rule: MailRule
    ) -> Bool {
        rule.isEnabled
            && rule.scope.includes(accountID)
            && rule.conditions.allSatisfy { matches($0, message: message) }
    }

    public static func actions(
        for message: MessageSummary,
        accountID: AccountID,
        rules: [MailRule]
    ) -> Set<MailRuleAction> {
        rules.reduce(into: Set<MailRuleAction>()) { result, rule in
            guard matches(message: message, accountID: accountID, rule: rule) else {
                return
            }
            result.formUnion(rule.actions)
        }
    }

    private static func matches(_ condition: MailRuleCondition, message: MessageSummary) -> Bool {
        switch condition.field {
        case .from:
            matches(condition, address: message.from)
        case .recipients:
            (message.to + message.cc).contains { matches(condition, address: $0) }
        case .subject:
            condition.operator == .contains
                && message.subject.localizedCaseInsensitiveContains(condition.value)
        }
    }

    private static func matches(_ condition: MailRuleCondition, address: EmailAddress) -> Bool {
        let candidate = address.rawValue.lowercased()
        switch condition.operator {
        case .emailIs:
            return candidate == condition.value
        case .domainIs:
            guard let domain = domain(in: candidate) else { return false }
            return domain == condition.value || domain.hasSuffix("." + condition.value)
        case .contains:
            return false
        }
    }

    private static func domain(in address: String) -> String? {
        guard let separator = address.lastIndex(of: "@") else { return nil }
        let value = address[address.index(after: separator)...]
        return value.isEmpty ? nil : String(value)
    }
}
