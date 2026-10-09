import Foundation
import PlainpostCore

/// Admission to a fresh provider checkpoint on an existing durable sync job.
/// This is not a request to finish or cancel that job's historical work.
public struct PlainpostForegroundInboxRefreshRequest: Equatable, Sendable {
    public let jobID: String
    public let accountID: AccountID
    public let sourceGeneration: Int64
    public let revision: Int64
    public let recentMessageLimit: Int
    public let createdJob: Bool

    public init(jobID: String, accountID: AccountID, sourceGeneration: Int64,
                revision: Int64, recentMessageLimit: Int, createdJob: Bool) {
        self.jobID = jobID
        self.accountID = accountID
        self.sourceGeneration = sourceGeneration
        self.revision = revision
        self.recentMessageLimit = recentMessageLimit
        self.createdJob = createdJob
    }
}

/// A durable proof of a post-admission INBOX search and committed finite window.
/// The publishing lease is provenance, not a requirement that history still run.
public struct PlainpostForegroundInboxRefreshReceipt: Codable, Equatable, Sendable {
    public let jobID: String
    public let accountID: AccountID
    public let sourceGeneration: Int64
    public let revision: Int64
    public let recentMessageLimit: Int
    public let mailboxPath: String
    public let uidValidity: Int
    public let leaseToken: String
    public let attempt: Int
    public let committedMessageCount: Int
    public let newlyDiscoveredMessageCount: Int

    public init(jobID: String, accountID: AccountID, sourceGeneration: Int64,
                revision: Int64, recentMessageLimit: Int, mailboxPath: String,
                uidValidity: Int, leaseToken: String, attempt: Int,
                committedMessageCount: Int, newlyDiscoveredMessageCount: Int) {
        self.jobID = jobID
        self.accountID = accountID
        self.sourceGeneration = sourceGeneration
        self.revision = revision
        self.recentMessageLimit = recentMessageLimit
        self.mailboxPath = mailboxPath
        self.uidValidity = uidValidity
        self.leaseToken = leaseToken
        self.attempt = attempt
        self.committedMessageCount = committedMessageCount
        self.newlyDiscoveredMessageCount = newlyDiscoveredMessageCount
    }
}
