import Foundation
import PlainpostCore

public enum PlainpostOperationKind: String, Codable, CaseIterable, Sendable {
    case inboxSync = "inbox-sync"
    case historicalSync = "historical-sync"
    case aiOperation = "ai-operation"
    case approvedDelivery = "approved-delivery"
    case denySend = "deny-send"
    case mailboxFlag = "mailbox-flag"
    case mailboxArchive = "mailbox-archive"
    case searchRebuild = "search-rebuild"
}

public enum PlainpostOperationState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
    case deliveryUncertain = "delivery-uncertain"
}

public struct PlainpostMailboxFlagInput: Equatable, Codable, Sendable {
    public let messageID: MessageID
    public let accountID: AccountID?
    public let mailboxPath: String?
    public let uidValidity: Int?
    public let uid: Int?
    public let desiredSeen: Bool
    public let expectedDirectSourceGeneration: Int64?

    public init(
        messageID: MessageID,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        desiredSeen: Bool,
        expectedDirectSourceGeneration: Int64? = nil
    ) {
        self.messageID = messageID
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.uidValidity = uidValidity
        self.uid = uid
        self.desiredSeen = desiredSeen
        self.expectedDirectSourceGeneration = expectedDirectSourceGeneration
    }

    public init(messageID: MessageID, desiredSeen: Bool) {
        self.messageID = messageID
        self.accountID = nil
        self.mailboxPath = nil
        self.uidValidity = nil
        self.uid = nil
        self.desiredSeen = desiredSeen
        self.expectedDirectSourceGeneration = nil
    }
}

public struct PlainpostMailboxArchiveInput: Equatable, Codable, Sendable {
    public let messageID: MessageID
    public let accountID: AccountID
    public let sourceMailboxPath: String
    public let destinationMailboxPath: String
    public let uidValidity: Int
    public let uid: Int
    public let expectedDirectSourceGeneration: Int64?

    public init(
        messageID: MessageID,
        accountID: AccountID,
        sourceMailboxPath: String,
        destinationMailboxPath: String,
        uidValidity: Int,
        uid: Int,
        expectedDirectSourceGeneration: Int64? = nil
    ) {
        self.messageID = messageID
        self.accountID = accountID
        self.sourceMailboxPath = sourceMailboxPath
        self.destinationMailboxPath = destinationMailboxPath
        self.uidValidity = uidValidity
        self.uid = uid
        self.expectedDirectSourceGeneration = expectedDirectSourceGeneration
    }
}

public struct MailRuleMessageActionRecord: Equatable, Sendable {
    public let messageID: MessageID
    public let action: MailRuleAction
    public let durableJobIDs: [String]

    public init(messageID: MessageID, action: MailRuleAction, durableJobIDs: [String]) {
        self.messageID = messageID
        self.action = action
        self.durableJobIDs = durableJobIDs
    }
}

public struct PlainpostOperationProgress: Equatable, Codable, Sendable {
    public let current: Int
    public let total: Int?
    public let phase: String
    public let label: String?

    public init(current: Int = 0, total: Int? = nil, phase: String, label: String? = nil) {
        self.current = current
        self.total = total
        self.phase = phase
        self.label = label
    }
}

public struct PlainpostDurableJob: Equatable, Codable, Sendable {
    public let id: String
    public let kind: PlainpostOperationKind
    public let payloadJSON: String
    public let state: PlainpostOperationState
    public let priority: Int
    public let availableAt: Date
    public let attempt: Int
    public let maxAttempts: Int
    public let leaseToken: String?
    public let leaseExpiresAt: Date?
    public let cancellationRequested: Bool
    public let pauseRequested: Bool
    public let idempotencyKey: String
    public let pauseReason: String?
    public let progress: PlainpostOperationProgress?
    public let resultArtifactID: String?
    public let errorCode: String?
    public let errorMessage: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        kind: PlainpostOperationKind,
        payloadJSON: String,
        state: PlainpostOperationState = .queued,
        priority: Int = 0,
        availableAt: Date = Date(),
        attempt: Int = 0,
        maxAttempts: Int = 5,
        leaseToken: String? = nil,
        leaseExpiresAt: Date? = nil,
        cancellationRequested: Bool = false,
        pauseRequested: Bool = false,
        idempotencyKey: String,
        pauseReason: String? = nil,
        progress: PlainpostOperationProgress? = nil,
        resultArtifactID: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.state = state
        self.priority = priority
        self.availableAt = availableAt
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
        self.cancellationRequested = cancellationRequested
        self.pauseRequested = pauseRequested
        self.idempotencyKey = idempotencyKey
        self.pauseReason = pauseReason
        self.progress = progress
        self.resultArtifactID = resultArtifactID
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case payloadJSON
        case state
        case priority
        case availableAt
        case attempt
        case maxAttempts
        case leaseToken
        case leaseExpiresAt
        case cancellationRequested
        case pauseRequested
        case idempotencyKey
        case pauseReason
        case progress
        case resultArtifactID
        case errorCode
        case errorMessage
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            kind: try values.decode(PlainpostOperationKind.self, forKey: .kind),
            payloadJSON: try values.decode(String.self, forKey: .payloadJSON),
            state: try values.decode(PlainpostOperationState.self, forKey: .state),
            priority: try values.decode(Int.self, forKey: .priority),
            availableAt: try values.decode(Date.self, forKey: .availableAt),
            attempt: try values.decode(Int.self, forKey: .attempt),
            maxAttempts: try values.decode(Int.self, forKey: .maxAttempts),
            leaseToken: try values.decodeIfPresent(String.self, forKey: .leaseToken),
            leaseExpiresAt: try values.decodeIfPresent(Date.self, forKey: .leaseExpiresAt),
            cancellationRequested: try values.decode(
                Bool.self,
                forKey: .cancellationRequested
            ),
            pauseRequested: try values.decodeIfPresent(
                Bool.self,
                forKey: .pauseRequested
            ) ?? false,
            idempotencyKey: try values.decode(String.self, forKey: .idempotencyKey),
            pauseReason: try values.decodeIfPresent(String.self, forKey: .pauseReason),
            progress: try values.decodeIfPresent(
                PlainpostOperationProgress.self,
                forKey: .progress
            ),
            resultArtifactID: try values.decodeIfPresent(
                String.self,
                forKey: .resultArtifactID
            ),
            errorCode: try values.decodeIfPresent(String.self, forKey: .errorCode),
            errorMessage: try values.decodeIfPresent(String.self, forKey: .errorMessage),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public struct PlainpostJobRequest: Equatable, Codable, Sendable {
    public let kind: PlainpostOperationKind
    public let payloadJSON: String
    public let priority: Int
    public let maxAttempts: Int
    public let idempotencyKey: String
    public let replaceTerminalDuplicate: Bool
    public let availableAt: Date?

    public init(
        kind: PlainpostOperationKind,
        payloadJSON: String,
        priority: Int = 0,
        maxAttempts: Int = 5,
        idempotencyKey: String,
        replaceTerminalDuplicate: Bool = false,
        availableAt: Date? = nil
    ) {
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.priority = priority
        self.maxAttempts = maxAttempts
        self.idempotencyKey = idempotencyKey
        self.replaceTerminalDuplicate = replaceTerminalDuplicate
        self.availableAt = availableAt
    }

    private enum CodingKeys: String, CodingKey {
        case kind, payloadJSON, priority, maxAttempts, idempotencyKey, replaceTerminalDuplicate, availableAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(PlainpostOperationKind.self, forKey: .kind)
        payloadJSON = try values.decode(String.self, forKey: .payloadJSON)
        priority = try values.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        maxAttempts = try values.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 5
        idempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
        replaceTerminalDuplicate = try values.decodeIfPresent(Bool.self, forKey: .replaceTerminalDuplicate) ?? false
        availableAt = try values.decodeIfPresent(Date.self, forKey: .availableAt)
    }
}

public struct PlainpostApprovedDeliveryAuthorization: Equatable, Sendable {
    public let request: SendRequest
    public let job: PlainpostDurableJob

    public init(request: SendRequest, job: PlainpostDurableJob) {
        self.request = request
        self.job = job
    }
}

public enum PlainpostSmartInboxReadiness: String, Codable, Equatable, Sendable {
    case ready
    case waitingForSync
    case waitingForSuccessfulSync
}

public struct PlainpostSyncBlocker: Equatable, Sendable {
    public let accountID: AccountID
    public let accountEmail: String
    public let state: PlainpostSmartInboxReadiness

    public init(
        accountID: AccountID,
        accountEmail: String,
        state: PlainpostSmartInboxReadiness
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.state = state
    }
}

public struct PlainpostDiagnosticsPageAnchor: Equatable, Sendable {
    public let updatedAt: Date
    public let id: String
    public let terminalCutoff: Date?
    public let maximumTerminalSequence: Int64?
    public let terminalJobIDs: Set<String>?

    public init(
        updatedAt: Date,
        id: String,
        terminalCutoff: Date? = nil,
        maximumTerminalSequence: Int64? = nil,
        terminalJobIDs: Set<String>? = nil
    ) {
        self.updatedAt = updatedAt
        self.id = id
        self.terminalCutoff = terminalCutoff
        self.maximumTerminalSequence = maximumTerminalSequence
        self.terminalJobIDs = terminalJobIDs
    }
}

public struct PlainpostDiagnosticsJobPage: Equatable, Sendable {
    public let activeJobs: [PlainpostDurableJob]
    public let terminalJobs: [PlainpostDurableJob]
    public let anchor: PlainpostDiagnosticsPageAnchor?
    public let totalTerminalCount: Int
    public let offset: Int
    public let limit: Int

    public init(
        activeJobs: [PlainpostDurableJob],
        terminalJobs: [PlainpostDurableJob],
        anchor: PlainpostDiagnosticsPageAnchor?,
        totalTerminalCount: Int,
        offset: Int,
        limit: Int
    ) {
        self.activeJobs = activeJobs
        self.terminalJobs = terminalJobs
        self.anchor = anchor
        self.totalTerminalCount = totalTerminalCount
        self.offset = offset
        self.limit = limit
    }
}

public protocol DurableJobRepository: AnyObject, Sendable {
    func enqueueJob(_ request: PlainpostJobRequest) throws -> PlainpostDurableJob
    func job(id: String) throws -> PlainpostDurableJob
    func job(idempotencyKey: String) throws -> PlainpostDurableJob?
    func jobs(limit: Int) throws -> [PlainpostDurableJob]
    func diagnosticsJobs(now: Date, recentTerminalLimit: Int) throws -> [PlainpostDurableJob]
    func diagnosticsJobPage(
        now: Date,
        anchor: PlainpostDiagnosticsPageAnchor?,
        offset: Int,
        limit: Int
    ) throws -> PlainpostDiagnosticsJobPage
    func smartInboxSyncBlockers() throws -> [PlainpostSyncBlocker]
    func claimNextJob(now: Date, leaseDuration: TimeInterval) throws -> PlainpostDurableJob?
    func nextPendingJob(
        higherPriorityThan priority: Int,
        now: Date,
        allowedKinds: Set<PlainpostOperationKind>?
    ) throws -> PlainpostDurableJob?
    func pauseJob(id: String, leaseToken: String, reason: String, progress: PlainpostOperationProgress) throws
    func requestJobPause(id: String) throws
    func acknowledgeJobPause(
        id: String,
        leaseToken: String,
        progress: PlainpostOperationProgress
    ) throws
    func resumeUserPausedJob(id: String, now: Date) throws
    func acknowledgeJobCancellation(id: String, leaseToken: String) throws
    func updateJobProgress(id: String, leaseToken: String, progress: PlainpostOperationProgress) throws
    func renewJobLease(id: String, leaseToken: String, now: Date, leaseDuration: TimeInterval) throws
    func inboxSyncReconciliationGeneration(id: String, leaseToken: String) throws -> Int
    func completeInboxSyncPass(
        id: String,
        leaseToken: String,
        observedReconciliationGeneration: Int,
        resultArtifactID: String?
    ) throws -> Bool
    func completeJob(id: String, leaseToken: String, resultArtifactID: String?) throws
    func failJob(id: String, leaseToken: String, code: String, message: String, retryAt: Date?) throws
    func markDeliveryUncertain(id: String, leaseToken: String, message: String) throws
    func requestJobCancellation(id: String) throws
    func pruneTerminalJobs(before: Date) throws
}

public enum DurableJobRepositoryPauseCapabilityError: Error, Equatable, Sendable {
    case unsupported
}

extension DurableJobRepositoryPauseCapabilityError: LocalizedError {
    public var errorDescription: String? {
        "This durable job repository does not support pausing and resuming jobs."
    }
}

public extension DurableJobRepository {
    func inboxSyncReconciliationGeneration(id: String, leaseToken: String) throws -> Int {
        0
    }

    func completeInboxSyncPass(
        id: String,
        leaseToken: String,
        observedReconciliationGeneration: Int,
        resultArtifactID: String?
    ) throws -> Bool {
        try completeJob(id: id, leaseToken: leaseToken, resultArtifactID: resultArtifactID)
        return false
    }

    func diagnosticsJobPage(
        now: Date,
        anchor: PlainpostDiagnosticsPageAnchor?,
        offset: Int,
        limit: Int
    ) throws -> PlainpostDiagnosticsJobPage {
        let normalizedOffset = max(0, offset)
        let normalizedLimit = max(0, limit)
        let diagnosticsNow = anchor?.terminalCutoff?.addingTimeInterval(3_600) ?? now
        let allJobs = try diagnosticsJobs(now: diagnosticsNow, recentTerminalLimit: .max)
        let terminalCutoff = anchor?.terminalCutoff ?? now.addingTimeInterval(-3_600)
        let activeJobs = allJobs
            .filter { $0.state == .queued || $0.state == .running || $0.state == .paused }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        let terminalJobs = allJobs
            .filter {
                $0.state != .queued && $0.state != .running && $0.state != .paused
                    && $0.updatedAt >= terminalCutoff
            }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        let resolvedAnchor = anchor ?? terminalJobs.first.map { newestJob in
            PlainpostDiagnosticsPageAnchor(
                updatedAt: newestJob.updatedAt,
                id: newestJob.id,
                terminalCutoff: terminalCutoff,
                terminalJobIDs: Set(terminalJobs.map(\.id))
            )
        }
        let anchoredTerminalJobs = terminalJobs.filter { job in
            guard let resolvedAnchor else { return false }
            if let terminalJobIDs = resolvedAnchor.terminalJobIDs {
                return terminalJobIDs.contains(job.id)
            }
            return (job.updatedAt, job.id) <= (resolvedAnchor.updatedAt, resolvedAnchor.id)
        }
        let effectiveOffset: Int
        if normalizedLimit == 0 || anchoredTerminalJobs.isEmpty {
            effectiveOffset = 0
        } else if normalizedOffset >= anchoredTerminalJobs.count {
            effectiveOffset = ((anchoredTerminalJobs.count - 1) / normalizedLimit) * normalizedLimit
        } else {
            effectiveOffset = normalizedOffset
        }
        let pageJobs = Array(
            anchoredTerminalJobs.dropFirst(effectiveOffset).prefix(normalizedLimit)
        )
        return PlainpostDiagnosticsJobPage(
            activeJobs: activeJobs,
            terminalJobs: pageJobs,
            anchor: resolvedAnchor,
            totalTerminalCount: anchoredTerminalJobs.count,
            offset: effectiveOffset,
            limit: normalizedLimit
        )
    }

    func smartInboxSyncBlockers() throws -> [PlainpostSyncBlocker] {
        []
    }

    func requestJobPause(id: String) throws {
        throw DurableJobRepositoryPauseCapabilityError.unsupported
    }

    func acknowledgeJobPause(
        id: String,
        leaseToken: String,
        progress: PlainpostOperationProgress
    ) throws {
        throw DurableJobRepositoryPauseCapabilityError.unsupported
    }

    func resumeUserPausedJob(id: String, now: Date) throws {
        throw DurableJobRepositoryPauseCapabilityError.unsupported
    }
}

public enum PlainpostInboxSyncTrigger: String, Codable, Sendable {
    case accountSetup
    case manual
    case schedule
    case realTimeSignal
}

public enum PlainpostSyncScope: String, Codable, Sendable {
    case recent
    case completeHistory
    case incremental
}

public struct PlainpostInboxSyncInput: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public let trigger: PlainpostInboxSyncTrigger
    public let scope: PlainpostSyncScope
    public let expectedDirectSourceGeneration: Int64?

    public init(
        accountID: AccountID, trigger: PlainpostInboxSyncTrigger,
        scope: PlainpostSyncScope = .recent,
        expectedDirectSourceGeneration: Int64? = nil
    ) {
        self.accountID = accountID
        self.trigger = trigger
        self.scope = scope
        self.expectedDirectSourceGeneration = expectedDirectSourceGeneration
    }

    public var schedulingPriority: Int {
        switch trigger {
        case .accountSetup, .manual:
            100
        case .realTimeSignal:
            50
        case .schedule:
            10
        }
    }
}

public struct PlainpostInboxSyncMailboxMetadata:
    Equatable, Codable, Sendable
{
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct PlainpostInboxSyncMessageMetadata:
    Equatable, Codable, Sendable
{
    public let messageID: MessageID
    public let subject: String
    public let preview: String
    public let path: String

    public init(
        messageID: MessageID,
        subject: String,
        preview: String,
        path: String
    ) {
        self.messageID = messageID
        self.subject = subject
        self.preview = preview
        self.path = path
    }
}

public struct PlainpostInboxSyncResult: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public let syncedMessageCount: Int
    public let newlyDiscoveredMessageCount: Int
    public let source: IMAPSyncSource
    public let newMessageIDs: [MessageID]
    public let suppressedNotificationMessageIDs: [MessageID]
    public let jobID: String
    public let mailboxes: [PlainpostInboxSyncMailboxMetadata]
    public let messages: [PlainpostInboxSyncMessageMetadata]

    public init(
        accountID: AccountID,
        syncedMessageCount: Int,
        newlyDiscoveredMessageCount: Int? = nil,
        source: IMAPSyncSource = .recentImport,
        newMessageIDs: [MessageID] = [],
        suppressedNotificationMessageIDs: [MessageID] = [],
        jobID: String,
        mailboxes: [PlainpostInboxSyncMailboxMetadata] = [],
        messages: [PlainpostInboxSyncMessageMetadata] = []
    ) {
        self.accountID = accountID
        self.syncedMessageCount = syncedMessageCount
        self.newlyDiscoveredMessageCount = newlyDiscoveredMessageCount ?? syncedMessageCount
        self.source = source
        self.newMessageIDs = newMessageIDs
        self.suppressedNotificationMessageIDs = suppressedNotificationMessageIDs
        self.jobID = jobID
        self.mailboxes = mailboxes
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, syncedMessageCount, newlyDiscoveredMessageCount, source
        case newMessageIDs, suppressedNotificationMessageIDs, jobID
        case mailboxes, messages
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(AccountID.self, forKey: .accountID)
        syncedMessageCount = try values.decode(Int.self, forKey: .syncedMessageCount)
        newlyDiscoveredMessageCount = try values.decodeIfPresent(Int.self, forKey: .newlyDiscoveredMessageCount)
            ?? syncedMessageCount
        source = try values.decodeIfPresent(IMAPSyncSource.self, forKey: .source) ?? .recentImport
        newMessageIDs = try values.decodeIfPresent([MessageID].self, forKey: .newMessageIDs) ?? []
        suppressedNotificationMessageIDs = try values.decodeIfPresent(
            [MessageID].self,
            forKey: .suppressedNotificationMessageIDs
        ) ?? []
        jobID = try values.decode(String.self, forKey: .jobID)
        mailboxes = try values.decodeIfPresent(
            [PlainpostInboxSyncMailboxMetadata].self,
            forKey: .mailboxes
        ) ?? []
        messages = try values.decodeIfPresent(
            [PlainpostInboxSyncMessageMetadata].self,
            forKey: .messages
        ) ?? []
    }
}

public enum PlainpostAIOperationKind: String, Codable, CaseIterable, Sendable {
    case summarizeThread
    case summarizeMessage
    case translateMessage
    case answerThreadQuestion
    case answerMailboxQuestion
    case draftReply
    case rewriteDraft
    case classifyMessage
    case recategorizeInbox
    case rebuildIndex
}

public enum PlainpostAIServiceClass: Int, Codable, CaseIterable, Sendable {
    case bulk = 10
    case direct = 80
    case interactive = 100

    public var priority: Int { rawValue }
}

public extension PlainpostAIOperationKind {
    var unambiguousConversationReferenceKind: PlainpostAIConversationReferenceKind? {
        switch self {
        case .summarizeThread, .answerThreadQuestion:
            return .thread
        case .summarizeMessage, .translateMessage, .classifyMessage:
            return .message
        case .draftReply, .answerMailboxQuestion, .rewriteDraft, .recategorizeInbox, .rebuildIndex:
            return nil
        }
    }

    var serviceClass: PlainpostAIServiceClass {
        switch self {
        case .summarizeThread, .summarizeMessage, .translateMessage, .answerThreadQuestion, .answerMailboxQuestion, .draftReply, .rewriteDraft:
            return .interactive
        case .classifyMessage:
            return .direct
        case .recategorizeInbox, .rebuildIndex:
            return .bulk
        }
    }

    var priority: Int { serviceClass.priority }

    var schedulerPauseReason: String {
        switch self {
        case .summarizeThread, .summarizeMessage:
            return "thread-summary"
        case .translateMessage:
            return "message-translation"
        case .answerThreadQuestion:
            return "thread-question"
        case .answerMailboxQuestion:
            return "mailbox-question"
        case .draftReply:
            return "ai-draft"
        case .rewriteDraft:
            return "draft-rewrite"
        case .classifyMessage:
            return "message-classification"
        case .recategorizeInbox, .rebuildIndex:
            return "interactive-ai"
        }
    }
}

public enum PlainpostSmartInboxRunMode: String, Codable, CaseIterable, Equatable, Sendable {
    case incremental
    case rerunAll
}

public enum PlainpostSmartInboxRunScope: Equatable, Codable, Sendable {
    case allAccounts
    case account(AccountID)

    public var identityValue: String {
        switch self {
        case .allAccounts:
            return "all-accounts"
        case .account(let accountID):
            return "account:\(accountID.rawValue)"
        }
    }
}

public struct PlainpostSmartInboxRunRequest: Equatable, Codable, Sendable {
    public let mode: PlainpostSmartInboxRunMode
    public let scope: PlainpostSmartInboxRunScope
    public let requestedLabelID: String?

    public init(
        mode: PlainpostSmartInboxRunMode,
        scope: PlainpostSmartInboxRunScope,
        requestedLabelID: String?
    ) {
        self.mode = mode
        self.scope = scope
        self.requestedLabelID = requestedLabelID
    }
}

public enum PlainpostSmartInboxWorkState: String, Codable, CaseIterable, Sendable {
    case pending
    case completed
    case failed
    case skipped
    case applied
}

public struct PlainpostSmartInboxWorkSeed: Equatable, Codable, Sendable {
    public let ordinal: Int
    public let messageID: String
    public let sourceFingerprint: String

    public init(ordinal: Int, messageID: String, sourceFingerprint: String) {
        self.ordinal = ordinal
        self.messageID = messageID
        self.sourceFingerprint = sourceFingerprint
    }
}

public struct PlainpostSmartInboxWorkItem: Equatable, Codable, Sendable {
    public let jobID: String
    public let ordinal: Int
    public let messageID: String
    public let sourceFingerprint: String
    public let state: PlainpostSmartInboxWorkState
    public let category: String?
    public let priority: String?
    public let requiresAction: Bool?
    public let confidence: Double?
    public let labelMatches: [SmartInboxLabelMatch]
    public let catalogFingerprint: String
    public let errorMessage: String?

    public init(
        jobID: String,
        ordinal: Int,
        messageID: String,
        sourceFingerprint: String,
        state: PlainpostSmartInboxWorkState,
        category: String? = nil,
        priority: String? = nil,
        requiresAction: Bool? = nil,
        confidence: Double? = nil,
        labelMatches: [SmartInboxLabelMatch] = [],
        catalogFingerprint: String = "",
        errorMessage: String? = nil
    ) {
        self.jobID = jobID
        self.ordinal = ordinal
        self.messageID = messageID
        self.sourceFingerprint = sourceFingerprint
        self.state = state
        self.category = category
        self.priority = priority
        self.requiresAction = requiresAction
        self.confidence = confidence
        self.labelMatches = labelMatches
        self.catalogFingerprint = catalogFingerprint
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case jobID, ordinal, messageID, sourceFingerprint, state, category, priority
        case requiresAction, confidence, labelMatches, catalogFingerprint, errorMessage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try values.decode(String.self, forKey: .jobID)
        ordinal = try values.decode(Int.self, forKey: .ordinal)
        messageID = try values.decode(String.self, forKey: .messageID)
        sourceFingerprint = try values.decode(String.self, forKey: .sourceFingerprint)
        state = try values.decode(PlainpostSmartInboxWorkState.self, forKey: .state)
        category = try values.decodeIfPresent(String.self, forKey: .category)
        priority = try values.decodeIfPresent(String.self, forKey: .priority)
        requiresAction = try values.decodeIfPresent(Bool.self, forKey: .requiresAction)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        labelMatches = try values.decodeIfPresent(
            [SmartInboxLabelMatch].self,
            forKey: .labelMatches
        ) ?? []
        catalogFingerprint = try values.decodeIfPresent(
            String.self,
            forKey: .catalogFingerprint
        ) ?? ""
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

public struct PlainpostSmartInboxWorkSummary: Equatable, Codable, Sendable {
    public let total: Int
    public let processed: Int
    public let categorized: Int
    public let unchanged: Int
    public let failed: Int

    public init(
        total: Int,
        processed: Int,
        categorized: Int,
        unchanged: Int = 0,
        failed: Int
    ) {
        self.total = total
        self.processed = processed
        self.categorized = categorized
        self.unchanged = unchanged
        self.failed = failed
    }

    private enum CodingKeys: String, CodingKey {
        case total, processed, categorized, unchanged, failed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        total = try values.decode(Int.self, forKey: .total)
        processed = try values.decode(Int.self, forKey: .processed)
        categorized = try values.decode(Int.self, forKey: .categorized)
        unchanged = try values.decodeIfPresent(Int.self, forKey: .unchanged) ?? 0
        failed = try values.decode(Int.self, forKey: .failed)
    }
}

public struct PlainpostAIConversationTurn: Equatable, Codable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public enum PlainpostAIConversationReferenceKind: String, Codable, CaseIterable, Sendable {
    case message
    case thread
}

public struct PlainpostAIConversationReference: Equatable, Codable, Sendable {
    public let recordID: String
    public let kind: PlainpostAIConversationReferenceKind

    public init(recordID: String, kind: PlainpostAIConversationReferenceKind) {
        self.recordID = recordID
        self.kind = kind
    }
}

public struct PlainpostAIOperationInput: Equatable, Codable, Sendable {
    public let operation: PlainpostAIOperationKind
    public let recordID: String
    public let conversationReferenceKind: PlainpostAIConversationReferenceKind?
    public let accountID: AccountID?
    public let expectedDirectSourceGeneration: Int64?
    public let providerID: String
    public let modelID: String?
    public let targetLanguageIdentifier: String?
    public let targetLanguageName: String?
    public let question: String?
    /// For `draftReply`: the reply's tone as a `PlainpostAI.DraftTone` raw value (`friendly`,
    /// `concise`, `formal` or `neutral`). Nil drafts in a neutral tone.
    public let draftTone: String?
    public let conversation: [PlainpostAIConversationTurn]
    public let retrievalScope: MailRetrievalScope?
    public let activeConversationKey: String?
    public let smartInboxRunRequest: PlainpostSmartInboxRunRequest
    public let smartInboxRequestID: String?
    public let smartInboxClassifierIdentity: SmartInboxClassifierIdentity?
    public let enqueueOnly: Bool
    /// Ask Mail "Try instead" option chosen for `answerMailboxQuestion`.
    public let askMailFilterOverride: AskMailFilterOverride?

    public init(
        operation: PlainpostAIOperationKind,
        recordID: String,
        conversationReferenceKind: PlainpostAIConversationReferenceKind? = nil,
        accountID: AccountID? = nil,
        expectedDirectSourceGeneration: Int64? = nil,
        providerID: String,
        modelID: String? = nil,
        targetLanguageIdentifier: String? = nil,
        targetLanguageName: String? = nil,
        question: String? = nil,
        draftTone: String? = nil,
        conversation: [PlainpostAIConversationTurn] = [],
        retrievalScope: MailRetrievalScope? = nil,
        activeConversationKey: String? = nil,
        smartInboxRunMode: PlainpostSmartInboxRunMode = .incremental,
        smartInboxRunRequest: PlainpostSmartInboxRunRequest? = nil,
        smartInboxRequestID: String? = nil,
        smartInboxClassifierIdentity: SmartInboxClassifierIdentity? = nil,
        enqueueOnly: Bool,
        askMailFilterOverride: AskMailFilterOverride? = nil
    ) {
        self.askMailFilterOverride = askMailFilterOverride
        self.operation = operation
        self.recordID = recordID
        self.conversationReferenceKind = conversationReferenceKind
            ?? operation.unambiguousConversationReferenceKind
        self.accountID = accountID
        self.expectedDirectSourceGeneration = expectedDirectSourceGeneration
        self.providerID = providerID
        self.modelID = modelID
        self.targetLanguageIdentifier = targetLanguageIdentifier
        self.targetLanguageName = targetLanguageName
        self.question = question
        self.draftTone = draftTone
        self.conversation = conversation
        self.retrievalScope = retrievalScope
        self.activeConversationKey = activeConversationKey
        self.smartInboxRunRequest = smartInboxRunRequest ?? PlainpostSmartInboxRunRequest(
            mode: smartInboxRunMode,
            scope: .allAccounts,
            requestedLabelID: nil
        )
        self.smartInboxRequestID = smartInboxRequestID
        self.smartInboxClassifierIdentity = smartInboxClassifierIdentity
        self.enqueueOnly = enqueueOnly
    }

    public init(
        operation: PlainpostAIOperationKind,
        recordID: String,
        conversationReferenceKind: PlainpostAIConversationReferenceKind? = nil,
        accountID: AccountID? = nil,
        expectedDirectSourceGeneration: Int64? = nil,
        providerID: String,
        modelID: String? = nil,
        targetLanguageIdentifier: String? = nil,
        targetLanguageName: String? = nil,
        question: String? = nil,
        draftTone: String? = nil,
        conversation: [PlainpostAIConversationTurn] = [],
        retrievalScope: MailRetrievalScope? = nil,
        activeConversationKey: String? = nil,
        smartInboxRunMode: PlainpostSmartInboxRunMode = .incremental,
        smartInboxRunRequest: PlainpostSmartInboxRunRequest? = nil,
        smartInboxRequestID: String? = nil,
        smartInboxClassifierIdentity: SmartInboxClassifierIdentity? = nil,
        askMailFilterOverride: AskMailFilterOverride? = nil
    ) {
        self.init(
            operation: operation,
            recordID: recordID,
            conversationReferenceKind: conversationReferenceKind,
            accountID: accountID,
            expectedDirectSourceGeneration: expectedDirectSourceGeneration,
            providerID: providerID,
            modelID: modelID,
            targetLanguageIdentifier: targetLanguageIdentifier,
            targetLanguageName: targetLanguageName,
            question: question,
            draftTone: draftTone,
            conversation: conversation,
            retrievalScope: retrievalScope,
            activeConversationKey: activeConversationKey,
            smartInboxRunMode: smartInboxRunMode,
            smartInboxRunRequest: smartInboxRunRequest,
            smartInboxRequestID: smartInboxRequestID,
            smartInboxClassifierIdentity: smartInboxClassifierIdentity,
            enqueueOnly: false,
            askMailFilterOverride: askMailFilterOverride
        )
    }

    private enum CodingKeys: String, CodingKey {
        case operation, recordID, conversationReferenceKind, accountID, expectedDirectSourceGeneration, providerID, modelID
        case targetLanguageIdentifier, targetLanguageName
        case question, draftTone, conversation, retrievalScope, activeConversationKey
        case smartInboxRunMode, smartInboxRunRequest, smartInboxRequestID, smartInboxClassifierIdentity, enqueueOnly
        case askMailFilterOverride
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        operation = try values.decode(PlainpostAIOperationKind.self, forKey: .operation)
        recordID = try values.decode(String.self, forKey: .recordID)
        conversationReferenceKind = try values.decodeIfPresent(
            PlainpostAIConversationReferenceKind.self,
            forKey: .conversationReferenceKind
        )
        accountID = try values.decodeIfPresent(AccountID.self, forKey: .accountID)
        expectedDirectSourceGeneration = try values.decodeIfPresent(Int64.self, forKey: .expectedDirectSourceGeneration)
        providerID = try values.decode(String.self, forKey: .providerID)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
        targetLanguageIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .targetLanguageIdentifier
        )
        targetLanguageName = try values.decodeIfPresent(String.self, forKey: .targetLanguageName)
        question = try values.decodeIfPresent(String.self, forKey: .question)
        draftTone = try values.decodeIfPresent(String.self, forKey: .draftTone)
        conversation = try values.decodeIfPresent([PlainpostAIConversationTurn].self, forKey: .conversation) ?? []
        retrievalScope = try values.decodeIfPresent(MailRetrievalScope.self, forKey: .retrievalScope)
        activeConversationKey = try values.decodeIfPresent(String.self, forKey: .activeConversationKey)
        let legacyMode = try values.decodeIfPresent(
            PlainpostSmartInboxRunMode.self,
            forKey: .smartInboxRunMode
        ) ?? .incremental
        smartInboxRunRequest = try values.decodeIfPresent(
            PlainpostSmartInboxRunRequest.self,
            forKey: .smartInboxRunRequest
        ) ?? PlainpostSmartInboxRunRequest(
            mode: legacyMode,
            scope: .allAccounts,
            requestedLabelID: nil
        )
        smartInboxRequestID = try values.decodeIfPresent(String.self, forKey: .smartInboxRequestID)
        smartInboxClassifierIdentity = try values.decodeIfPresent(
            SmartInboxClassifierIdentity.self,
            forKey: .smartInboxClassifierIdentity
        )
        enqueueOnly = try values.decodeIfPresent(Bool.self, forKey: .enqueueOnly) ?? false
        askMailFilterOverride = try? values.decodeIfPresent(AskMailFilterOverride.self, forKey: .askMailFilterOverride)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(operation, forKey: .operation)
        try values.encode(recordID, forKey: .recordID)
        try values.encodeIfPresent(conversationReferenceKind, forKey: .conversationReferenceKind)
        try values.encodeIfPresent(accountID, forKey: .accountID)
        try values.encodeIfPresent(expectedDirectSourceGeneration, forKey: .expectedDirectSourceGeneration)
        try values.encode(providerID, forKey: .providerID)
        try values.encodeIfPresent(modelID, forKey: .modelID)
        try values.encodeIfPresent(targetLanguageIdentifier, forKey: .targetLanguageIdentifier)
        try values.encodeIfPresent(targetLanguageName, forKey: .targetLanguageName)
        try values.encodeIfPresent(question, forKey: .question)
        try values.encodeIfPresent(draftTone, forKey: .draftTone)
        try values.encode(conversation, forKey: .conversation)
        try values.encodeIfPresent(retrievalScope, forKey: .retrievalScope)
        try values.encodeIfPresent(activeConversationKey, forKey: .activeConversationKey)
        try values.encode(smartInboxRunMode, forKey: .smartInboxRunMode)
        try values.encode(smartInboxRunRequest, forKey: .smartInboxRunRequest)
        try values.encodeIfPresent(smartInboxRequestID, forKey: .smartInboxRequestID)
        try values.encodeIfPresent(
            smartInboxClassifierIdentity,
            forKey: .smartInboxClassifierIdentity
        )
        try values.encode(enqueueOnly, forKey: .enqueueOnly)
        try values.encodeIfPresent(askMailFilterOverride, forKey: .askMailFilterOverride)
    }

    public var smartInboxRunMode: PlainpostSmartInboxRunMode {
        smartInboxRunRequest.mode
    }

    public var resolvedSmartInboxClassifierIdentity: SmartInboxClassifierIdentity {
        smartInboxClassifierIdentity ?? SmartInboxClassifierIdentity.resolve(
            providerID: providerID,
            modelID: modelID
        )
    }

    public func resolvingSmartInboxClassifierIdentity(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PlainpostAIOperationInput {
        let identity = smartInboxClassifierIdentity ?? SmartInboxClassifierIdentity.resolve(
            providerID: providerID,
            modelID: modelID,
            environment: environment
        )
        return PlainpostAIOperationInput(
            operation: operation,
            recordID: recordID,
            conversationReferenceKind: conversationReferenceKind,
            accountID: accountID,
            expectedDirectSourceGeneration: expectedDirectSourceGeneration,
            providerID: identity.providerID,
            modelID: identity.modelID,
            targetLanguageIdentifier: targetLanguageIdentifier,
            targetLanguageName: targetLanguageName,
            question: question,
            draftTone: draftTone,
            conversation: conversation,
            retrievalScope: retrievalScope,
            activeConversationKey: activeConversationKey,
            smartInboxRunRequest: smartInboxRunRequest,
            smartInboxRequestID: smartInboxRequestID,
            smartInboxClassifierIdentity: identity,
            enqueueOnly: enqueueOnly,
            askMailFilterOverride: askMailFilterOverride
        )
    }

    public var diagnosticsModelID: String {
        if let modelID, !modelID.isEmpty { return modelID }
        switch providerID {
        case "foundation": return "apple-foundation-system"
        case "ollama":
            if operation == .rebuildIndex { return "mxbai-embed-large" }
            return SmartInboxClassifierIdentity.resolve(
                providerID: providerID,
                modelID: modelID
            ).modelID
        case "deterministic": return operation == .rebuildIndex ? "deterministic-local-embedding" : "deterministic-local"
        default: return "Default model"
        }
    }
}

public struct PlainpostAIOperationResult: Equatable, Codable, Sendable {
    public let operation: PlainpostAIOperationKind
    public let recordID: String
    public let artifactID: String
    public let jobID: String

    public init(operation: PlainpostAIOperationKind, recordID: String, artifactID: String, jobID: String) {
        self.operation = operation
        self.recordID = recordID
        self.artifactID = artifactID
        self.jobID = jobID
    }
}

public struct PlainpostApprovalDecisionInput: Equatable, Codable, Sendable {
    public let requestID: SendRequestID
    public let actorID: String

    public init(requestID: SendRequestID, actorID: String) {
        self.requestID = requestID
        self.actorID = actorID
    }
}

public struct PlainpostSmartInboxFailureDiagnostic: Equatable, Codable, Sendable {
    public let code: String
    public let count: Int

    public init(code: String, count: Int) {
        self.code = code
        self.count = count
    }
}

public struct PlainpostLocalAIArtifactPayload: Equatable, Codable, Sendable {
    public let text: String?
    public let items: [String]
    public let modelID: String?
    public let localOnly: Bool
    public let resultRecordID: String?
    public let category: String?
    public let confidence: Double?
    public let indexedMessageCount: Int?
    public let categorizedMessageCount: Int?
    public let unchangedMessageCount: Int?
    public let failedMessageCount: Int?
    public let smartInboxFailureDiagnostics: [PlainpostSmartInboxFailureDiagnostic]?
    public let sources: [MailKnowledgeSource]
    public let insufficientEvidence: Bool?
    public let retrievalMode: String?
    public let translatedBodyKind: String?
    public let translatedBody: String?
    public let sourceFingerprint: String?
    public let askMailAnswer: AskMailAnswer?

    public init(
        text: String? = nil,
        items: [String] = [],
        modelID: String? = nil,
        localOnly: Bool = true,
        resultRecordID: String? = nil,
        category: String? = nil,
        confidence: Double? = nil,
        indexedMessageCount: Int? = nil,
        categorizedMessageCount: Int? = nil,
        unchangedMessageCount: Int? = nil,
        failedMessageCount: Int? = nil,
        smartInboxFailureDiagnostics: [PlainpostSmartInboxFailureDiagnostic]? = nil,
        sources: [MailKnowledgeSource] = [],
        insufficientEvidence: Bool? = nil,
        retrievalMode: String? = nil,
        translatedBodyKind: String? = nil,
        translatedBody: String? = nil,
        sourceFingerprint: String? = nil,
        askMailAnswer: AskMailAnswer? = nil
    ) {
        self.text = text
        self.items = items
        self.modelID = modelID
        self.localOnly = localOnly
        self.resultRecordID = resultRecordID
        self.category = category
        self.confidence = confidence
        self.indexedMessageCount = indexedMessageCount
        self.categorizedMessageCount = categorizedMessageCount
        self.unchangedMessageCount = unchangedMessageCount
        self.failedMessageCount = failedMessageCount
        self.smartInboxFailureDiagnostics = smartInboxFailureDiagnostics
        self.sources = sources
        self.insufficientEvidence = insufficientEvidence
        self.retrievalMode = retrievalMode
        self.translatedBodyKind = translatedBodyKind
        self.translatedBody = translatedBody
        self.sourceFingerprint = sourceFingerprint
        self.askMailAnswer = askMailAnswer
    }

    private enum CodingKeys: String, CodingKey {
        case text, items, modelID, localOnly, resultRecordID, category, confidence
        case indexedMessageCount, categorizedMessageCount, unchangedMessageCount, failedMessageCount
        case smartInboxFailureDiagnostics
        case sources, insufficientEvidence, retrievalMode
        case translatedBodyKind, translatedBody, sourceFingerprint
        case askMailAnswer
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        items = try values.decodeIfPresent([String].self, forKey: .items) ?? []
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
        localOnly = try values.decodeIfPresent(Bool.self, forKey: .localOnly) ?? true
        resultRecordID = try values.decodeIfPresent(String.self, forKey: .resultRecordID)
        category = try values.decodeIfPresent(String.self, forKey: .category)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        indexedMessageCount = try values.decodeIfPresent(Int.self, forKey: .indexedMessageCount)
        categorizedMessageCount = try values.decodeIfPresent(Int.self, forKey: .categorizedMessageCount)
        unchangedMessageCount = try values.decodeIfPresent(Int.self, forKey: .unchangedMessageCount) ?? 0
        failedMessageCount = try values.decodeIfPresent(Int.self, forKey: .failedMessageCount)
        smartInboxFailureDiagnostics = try values.decodeIfPresent(
            [PlainpostSmartInboxFailureDiagnostic].self,
            forKey: .smartInboxFailureDiagnostics
        )
        sources = try values.decodeIfPresent([MailKnowledgeSource].self, forKey: .sources) ?? []
        insufficientEvidence = try values.decodeIfPresent(Bool.self, forKey: .insufficientEvidence)
        retrievalMode = try values.decodeIfPresent(String.self, forKey: .retrievalMode)
        translatedBodyKind = try values.decodeIfPresent(String.self, forKey: .translatedBodyKind)
        translatedBody = try values.decodeIfPresent(String.self, forKey: .translatedBody)
        sourceFingerprint = try values.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        // A newer app may write block kinds this build can't read; keep the text and sources.
        askMailAnswer = try? values.decodeIfPresent(AskMailAnswer.self, forKey: .askMailAnswer)
    }
}

public protocol PlainpostOperationClientProtocol: Sendable {
    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult
    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult
    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws
    func approveSend(requestID: SendRequestID, approvedBy: String) async throws
    func denySend(requestID: SendRequestID, deniedBy: String) async throws
}

public extension PlainpostOperationClientProtocol {
    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        throw PlainpostError.validationFailed("Incremental Smart Inbox scheduling is unavailable.")
    }
}
