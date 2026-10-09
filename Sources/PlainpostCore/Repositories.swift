import Foundation

public protocol AccountRepository {
    var accounts: [Account] { get }
}

public protocol MailboxRepository {
    var mailboxes: [Mailbox] { get }
}

public protocol MessageRepository {
    var messages: [MessageSummary] { get }
}

public protocol MailboxMembershipRepository {
    func membership(for messageID: MessageID) throws -> MailboxMessageMembership
}

public protocol ThreadRepository {
    var threads: [MailThread] { get }
}

public protocol DraftRepository {
    func createDraft(_ draft: Draft, actor: Actor) throws -> Draft
    func recordServerDraft(id: DraftID, uid: Int?, mailboxID: String, actor: Actor) throws -> Draft
}

public protocol SendRequestRepository {
    func requestSend(draftID: DraftID, actor: Actor, reason: String?) throws -> SendRequest
    func sendRequest(id: SendRequestID) throws -> SendRequest
    func cancelSendRequest(id: SendRequestID, actor: Actor) throws -> SendRequest
}

public protocol AuditRepository {
    var auditEntries: [AuditEntry] { get }
    func recentAuditEntries(limit: Int) throws -> [AuditEntry]
}

public extension AuditRepository {
    func recentAuditEntries(limit: Int) throws -> [AuditEntry] {
        Array(auditEntries.suffix(max(0, limit)).reversed())
    }
}

public protocol MessageMetadataRepository {
    func addLabel(_ label: String, to messageID: MessageID, actor: Actor) throws -> MessageSummary
    func removeLabel(_ label: String, from messageID: MessageID, actor: Actor) throws -> MessageSummary
    func recategorize(_ messageID: MessageID, as category: SmartCategory, actor: Actor) throws -> MessageSummary
    func recategorize(_ updates: [MessageCategoryUpdate], actor: Actor) throws
    func markSeen(_ messageID: MessageID, seen: Bool, actor: Actor) throws -> MessageSummary
    func moveMessage(_ messageID: MessageID, toMailboxPath mailboxPath: String, actor: Actor) throws -> MessageSummary
    func markDeleted(_ messageID: MessageID, deleted: Bool, actor: Actor) throws -> MessageSummary
}

public protocol MailRuleRepository: AnyObject, Sendable {
    func mailRules(effectiveFor accountID: AccountID?) throws -> [MailRule]
    func mailRule(id: String) throws -> MailRule?
    func saveMailRule(_ rule: MailRule) throws
    func setMailRuleEnabled(id: String, isEnabled: Bool) throws
    func deleteMailRule(id: String) throws
}

public protocol MailLabelDefinitionRepository: AnyObject, Sendable {
    func mailLabels(effectiveFor accountID: AccountID?) throws -> [MailLabelDefinition]
    func mailLabel(id: String) throws -> MailLabelDefinition?
    func saveMailLabel(_ label: MailLabelDefinition) throws
    func setMailLabelSmartInboxEnabled(id: String, isEnabled: Bool) throws
    func previewMailLabelReclassification(id: String) async throws -> MailLabelReclassificationPreview
    func previewMailLabelDeletion(id: String) throws -> MailLabelDeletionPreview
    func deleteMailLabel(id: String) throws
}

public protocol MessageLabelAssignmentRepository: AnyObject, Sendable {
    func labelAssignments(for messageID: MessageID) throws -> [MailLabelAssignment]
    func labelExclusions(for messageID: MessageID) throws -> [MailLabelExclusion]
    func addUserLabel(labelID: String, to messageID: MessageID, actor: Actor) throws
    func establishUserLabel(labelID: String, on messageID: MessageID, actor: Actor) throws
    func removeUserOrSmartInboxLabel(labelID: String, from messageID: MessageID, actor: Actor) throws
    func replaceRuleLabels(ruleID: String, labelIDs: [String], on messageID: MessageID, actor: Actor) throws
    func replaceSmartInboxLabels(labelIDs: [String], on messageID: MessageID, actor: Actor) throws
}

public protocol MessageLabelActionSnapshotRepository: AnyObject, Sendable {
    func messageLabelActionSnapshot(for messageID: MessageID) async throws -> MessageLabelActionSnapshot
}

public protocol SmartInboxLabelRepository: AnyObject, Sendable {
    func smartInboxClassificationInputs(scope: MailLabelScope?) throws -> [SmartInboxClassificationInput]
    func smartInboxLabelCatalogSnapshot() throws -> MailLabelCatalogSnapshot
    func previewMailLabelReclassification(id: String) async throws -> MailLabelReclassificationPreview
}

public struct MessageCategoryUpdate: Equatable, Sendable {
    public let messageID: MessageID
    public let category: SmartCategory

    public init(messageID: MessageID, category: SmartCategory) {
        self.messageID = messageID
        self.category = category
    }
}

public extension MessageMetadataRepository {
    func recategorize(_ updates: [MessageCategoryUpdate], actor: Actor) throws {
        for update in updates {
            _ = try recategorize(update.messageID, as: update.category, actor: actor)
        }
    }
}

public protocol ApprovalSendStore: AnyObject {
    func draft(id: DraftID) throws -> Draft
    func sendRequest(id: SendRequestID) throws -> SendRequest
    func claimSendRequestForDelivery(
        id: SendRequestID,
        currentDraftHash: String,
        actor: Actor
    ) throws -> SendRequest
    func updateSendRequest(
        id: SendRequestID,
        status: SendRequestStatus,
        approvedBy: String?,
        approvedDraftHash: String?
    ) throws -> SendRequest
}

public protocol SentMailRecordingStore: AnyObject {
    func recordSentMessage(draft: Draft, requestID: SendRequestID, actor: Actor) throws -> MessageSummary
    func recordDirectSentMessage(draft: Draft, actor: Actor) throws -> MessageSummary
}

public protocol SendWarningRecordingStore: AnyObject {
    func recordSendWarning(requestID: SendRequestID, action: String, actor: Actor)
}

public enum MailTranslationCacheSaveResult: Equatable, Sendable {
    case saved
    case sourceChanged
}

public protocol MailTranslationCacheRepository: AnyObject {
    func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) throws -> CachedMessageTranslation?
    func compareAndSaveCachedTranslation(
        _ translation: CachedMessageTranslation,
        expectedSourceFingerprint: String
    ) throws -> MailTranslationCacheSaveResult
    func compareAndSaveCachedTranslation(
        _ translation: CachedMessageTranslation,
        expectedSourceFingerprint: String,
        expectedDirectSourceGeneration: Int64
    ) throws -> MailTranslationCacheSaveResult
}

public extension MailTranslationCacheRepository {
    func compareAndSaveCachedTranslation(
        _ translation: CachedMessageTranslation,
        expectedSourceFingerprint _: String,
        expectedDirectSourceGeneration _: Int64
    ) throws -> MailTranslationCacheSaveResult {
        throw PlainpostError.permissionDenied("This store cannot fence an AI translation against a Direct source change.")
    }
}

public protocol LocalAIStore: AnyObject, AccountRepository, MailTranslationCacheRepository {
    var messages: [MessageSummary] { get }
    var threads: [MailThread] { get }
    func draft(id: DraftID) throws -> Draft
    func createDraft(_ draft: Draft, actor: Actor) throws -> Draft
    func createAIDraft(_ draft: Draft, actor: Actor, expectedDirectSourceGeneration: Int64) throws -> Draft
    func recordServerDraft(id: DraftID, uid: Int?, mailboxID: String, actor: Actor) throws -> Draft
}

public extension LocalAIStore {
    func createAIDraft(_ draft: Draft, actor: Actor, expectedDirectSourceGeneration _: Int64) throws -> Draft {
        throw PlainpostError.permissionDenied("This store cannot fence an AI draft against a Direct source change.")
    }
}

public struct DurableOperationArtifact: Equatable, Codable, Sendable {
    public let id: String
    public let kind: String
    public let recordID: String
    public let payloadJSON: String
    public let createdAt: Date

    public init(id: String, kind: String, recordID: String, payloadJSON: String, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.recordID = recordID
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

public protocol DurableOperationArtifactRepository: AnyObject {
    func saveDurableOperationArtifact(
        _ artifact: DurableOperationArtifact,
        forJobID jobID: String
    ) throws
    func durableOperationArtifact(id: String) throws -> DurableOperationArtifact
}
