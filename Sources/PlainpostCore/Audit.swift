import Foundation

public struct AuditEntry: Equatable, Codable, Sendable {
    public let id: String
    public let actorID: String
    public let action: String
    public let targetType: String
    public let targetID: String
    public let result: String

    public init(id: String, actorID: String, action: String, targetType: String, targetID: String, result: String) {
        self.id = id
        self.actorID = actorID
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.result = result
    }
}

/// An audit entry with the time it occurred, for the account-scoped audit export.
/// `occurredAt` is nil only for legacy records written without a time.
public struct TimestampedAuditEntry: Equatable, Sendable {
    public let entry: AuditEntry
    public let occurredAt: Date?

    public init(entry: AuditEntry, occurredAt: Date?) {
        self.entry = entry
        self.occurredAt = occurredAt
    }
}
