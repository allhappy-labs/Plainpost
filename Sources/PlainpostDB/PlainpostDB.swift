import Foundation
import PlainpostCore

public final class InMemoryMailStore: AccountRepository, MailboxRepository, MessageRepository, MailboxMembershipRepository, ThreadRepository, DraftRepository, SendRequestRepository, AuditRepository, MessageMetadataRepository {
    public private(set) var accounts: [Account]
    public private(set) var mailboxes: [Mailbox]
    public private(set) var messages: [MessageSummary]
    public private(set) var memberships: [MailboxMessageMembership]
    public private(set) var threads: [MailThread]
    private var drafts: [DraftID: Draft]
    private var sendRequests: [SendRequestID: SendRequest]
    private var mailEmbeddingChunks: [StoredMailEmbeddingChunk] = []
    private var messageTranslations: [String: CachedMessageTranslation] = [:]
    private let approvalClaimLock = NSLock()
    private let messageTranslationLock = NSLock()
    private let onTranslationCompareAndSaveBeforeLock: (@Sendable () -> Void)?
    private let onTranslationSaveAfterActiveCheck: (@Sendable () -> Void)?
    private let onMessageDeleteBeforeTranslationCacheMutation: (@Sendable () -> Void)?
    public private(set) var auditEntries: [AuditEntry]

    public init(
        accounts: [Account] = [],
        mailboxes: [Mailbox] = [],
        messages: [MessageSummary] = [],
        memberships: [MailboxMessageMembership] = [],
        threads: [MailThread] = [],
        drafts: [Draft] = [],
        sendRequests: [SendRequest] = [],
        auditEntries: [AuditEntry] = []
    ) {
        self.accounts = accounts
        self.mailboxes = mailboxes
        self.messages = messages
        self.memberships = memberships
        self.threads = threads
        self.drafts = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        self.sendRequests = Dictionary(uniqueKeysWithValues: sendRequests.map { ($0.id, $0) })
        self.auditEntries = auditEntries
        onTranslationCompareAndSaveBeforeLock = nil
        onTranslationSaveAfterActiveCheck = nil
        onMessageDeleteBeforeTranslationCacheMutation = nil
    }

    init(
        messages: [MessageSummary],
        onTranslationCompareAndSaveBeforeLock: @escaping @Sendable () -> Void = {},
        onTranslationSaveAfterActiveCheck: @escaping @Sendable () -> Void,
        onMessageDeleteBeforeTranslationCacheMutation: @escaping @Sendable () -> Void
    ) {
        accounts = []
        mailboxes = []
        self.messages = messages
        memberships = []
        threads = []
        drafts = [:]
        sendRequests = [:]
        auditEntries = []
        self.onTranslationCompareAndSaveBeforeLock = onTranslationCompareAndSaveBeforeLock
        self.onTranslationSaveAfterActiveCheck = onTranslationSaveAfterActiveCheck
        self.onMessageDeleteBeforeTranslationCacheMutation = onMessageDeleteBeforeTranslationCacheMutation
    }

    public func membership(for messageID: MessageID) throws -> MailboxMessageMembership {
        let matches = memberships.filter { $0.messageID == messageID }
        guard matches.count == 1, let membership = matches.first else {
            throw PlainpostError.validationFailed(
                "An exact mailbox membership is required for the message."
            )
        }
        return membership
    }

    public static func seededForStage0() -> InMemoryMailStore {
        InMemoryMailStore(
            accounts: [Stage0Seed.account],
            mailboxes: [Stage0Seed.mailbox],
            messages: [Stage0Seed.message],
            threads: [Stage0Seed.thread]
        )
    }

    public func createDraft(_ draft: Draft, actor: Actor) throws -> Draft {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to create drafts.")
        }

        drafts[draft.id] = draft
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: "draft.create",
                targetType: "draft",
                targetID: draft.id.rawValue,
                result: "ok"
            )
        )
        return draft
    }

    public func draft(id: DraftID) throws -> Draft {
        guard let draft = drafts[id] else {
            throw PlainpostError.notFound("Draft not found.")
        }
        return draft
    }

    public func recordServerDraft(id: DraftID, uid: Int?, mailboxID: String, actor: Actor) throws -> Draft {
        guard let existing = drafts[id] else {
            throw PlainpostError.notFound("Draft not found.")
        }
        let updated = existing.recordingServerDraft(uid: uid, mailboxID: mailboxID)
        drafts[id] = updated
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: "draft.server_sync",
                targetType: "draft",
                targetID: id.rawValue,
                result: "ok"
            )
        )
        return updated
    }

    public func updateDraft(id: DraftID, patch: DraftPatch, actor: Actor) throws -> Draft {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to update drafts.")
        }
        guard let existing = drafts[id] else {
            throw PlainpostError.notFound("Draft not found.")
        }

        let updated = existing.applying(patch)
        drafts[id] = updated
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: "draft.update",
                targetType: "draft",
                targetID: id.rawValue,
                result: "ok"
            )
        )
        return updated
    }

    public func deleteDraft(id: DraftID, actor: Actor) throws {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to delete drafts.")
        }
        guard drafts.removeValue(forKey: id) != nil else {
            throw PlainpostError.notFound("Draft not found.")
        }
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: "draft.delete",
                targetType: "draft",
                targetID: id.rawValue,
                result: "ok"
            )
        )
    }

    public func requestSend(draftID: DraftID, actor: Actor, reason: String?) throws -> SendRequest {
        guard let draft = drafts[draftID] else {
            throw PlainpostError.notFound("Draft not found.")
        }

        let request = try SendRequestPolicy().requestSend(draft: draft, actor: actor, reason: reason)
        sendRequests[request.id] = request
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: "send.request",
                targetType: "send_request",
                targetID: request.id.rawValue,
                result: "ok"
            )
        )
        return request
    }

    public func sendRequest(id: SendRequestID) throws -> SendRequest {
        guard let request = sendRequests[id] else {
            throw PlainpostError.notFound("Send request not found.")
        }
        return request
    }

    public func cancelSendRequest(id: SendRequestID, actor: Actor) throws -> SendRequest {
        try approvalClaimLock.withLock {
            let request = try sendRequest(id: id)
            guard Self.isCanonicalSendTransition(from: request.status, to: .cancelled) else {
                throw PlainpostError.validationFailed("The send request is no longer eligible for this transition.")
            }
            let updated = request.updating(status: .cancelled)
            sendRequests[id] = updated
            auditEntries.append(
                AuditEntry(
                    id: "aud_\(auditEntries.count + 1)",
                    actorID: actor.id,
                    action: "send.cancel",
                    targetType: "send_request",
                    targetID: id.rawValue,
                    result: "ok"
                )
            )
            return updated
        }
    }

    public func validateAppApproval(requestID: SendRequestID, currentDraftHash: String, actor: Actor) throws {
        guard let request = sendRequests[requestID] else {
            throw PlainpostError.notFound("Send request not found.")
        }

        try ApprovalPolicy.validateApproval(request: request, currentDraftHash: currentDraftHash, actor: actor)
    }

    public var approvalQueueRequests: [SendRequest] {
        sendRequests.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func addLabel(_ label: String, to messageID: MessageID, actor: Actor) throws -> MessageSummary {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        return try updateMessage(messageID, actor: actor, action: "label.add") { message in
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw PlainpostError.validationFailed("Label cannot be empty.")
            }
            let labels = (message.labels + [normalized]).reduce(into: [String]()) { result, label in
                if !result.contains(label) {
                    result.append(label)
                }
            }
            return message.withLabels(labels)
        }
    }

    public func removeLabel(_ label: String, from messageID: MessageID, actor: Actor) throws -> MessageSummary {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        return try updateMessage(messageID, actor: actor, action: "label.remove") { message in
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.withLabels(message.labels.filter { $0 != normalized })
        }
    }

    public func recategorize(_ messageID: MessageID, as category: SmartCategory, actor: Actor) throws -> MessageSummary {
        guard actor.permissions.recategorize else {
            throw PlainpostError.permissionDenied("Actor is not allowed to recategorize messages.")
        }
        return try updateMessage(messageID, actor: actor, action: "category.change") { message in
            message.withSmartCategory(category)
        }
    }

    public func markSeen(_ messageID: MessageID, seen: Bool, actor: Actor) throws -> MessageSummary {
        guard actor.permissions.markSeen else {
            throw PlainpostError.permissionDenied("Actor is not allowed to change seen state.")
        }
        return try updateMessage(messageID, actor: actor, action: seen ? "message.mark_seen" : "message.mark_unseen") { message in
            message.withSeen(seen)
        }
    }

    public func moveMessage(_ messageID: MessageID, toMailboxPath mailboxPath: String, actor: Actor) throws -> MessageSummary {
        try updateMessage(messageID, actor: actor, action: "message.move") { message in
            message.withMailboxPath(mailboxPath)
        }
    }

    public func markDeleted(_ messageID: MessageID, deleted: Bool, actor: Actor) throws -> MessageSummary {
        if deleted {
            onMessageDeleteBeforeTranslationCacheMutation?()
        }
        return try updateMessage(messageID, actor: actor, action: "message.delete") { message in
            message.withDeleted(deleted)
        }
    }

    private func updateMessage(
        _ messageID: MessageID,
        actor: Actor,
        action: String,
        transform: (MessageSummary) throws -> MessageSummary
    ) throws -> MessageSummary {
        let updated = try messageTranslationLock.withLock {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
                throw PlainpostError.notFound("Message not found.")
            }
            let updated = try transform(messages[index])
            messages[index] = updated
            if updated.isDeleted {
                messageTranslations = messageTranslations.filter { $0.value.messageID != messageID }
            }
            return updated
        }
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: action,
                targetType: "message",
                targetID: messageID.rawValue,
                result: "ok"
            )
        )
        return updated
    }
}

extension InMemoryMailStore: ApprovalSendStore {
    public func claimSendRequestForDelivery(
        id: SendRequestID,
        currentDraftHash: String,
        actor: Actor
    ) throws -> SendRequest {
        try approvalClaimLock.withLock {
            guard let request = sendRequests[id] else {
                throw PlainpostError.notFound("Send request not found.")
            }
            try ApprovalPolicy.validateApproval(request: request, currentDraftHash: currentDraftHash, actor: actor)
            guard request.status == .pending || request.status == .approved else {
                throw PlainpostError.validationFailed("Send request is already being processed or is no longer pending.")
            }

            let approved: SendRequest
            if request.status == .pending {
                approved = request.updating(
                    status: .approved,
                    approvedBy: actor.id,
                    approvedDraftHash: currentDraftHash
                )
                sendRequests[id] = approved
                auditEntries.append(
                    AuditEntry(
                        id: "aud_\(auditEntries.count + 1)",
                        actorID: actor.id,
                        action: "send.approved",
                        targetType: "send_request",
                        targetID: id.rawValue,
                        result: "ok"
                    )
                )
            } else {
                guard request.approvedDraftHash == currentDraftHash else {
                    throw PlainpostError.validationFailed("Approved draft hash does not match the current draft.")
                }
                approved = request
            }

            let sending = approved.updating(status: .sending)
            sendRequests[id] = sending
            auditEntries.append(
                AuditEntry(
                    id: "aud_\(auditEntries.count + 1)",
                    actorID: actor.id,
                    action: "send.sending",
                    targetType: "send_request",
                    targetID: id.rawValue,
                    result: "ok"
                )
            )
            return sending
        }
    }

    public func updateSendRequest(
        id: SendRequestID,
        status: SendRequestStatus,
        approvedBy: String?,
        approvedDraftHash: String?
    ) throws -> SendRequest {
        try approvalClaimLock.withLock {
            guard let request = sendRequests[id] else {
                throw PlainpostError.notFound("Send request not found.")
            }
            guard Self.isCanonicalSendTransition(from: request.status, to: status) else {
                throw PlainpostError.validationFailed("The send request is no longer eligible for this transition.")
            }
            let updated = request.updating(status: status, approvedBy: approvedBy, approvedDraftHash: approvedDraftHash)
            sendRequests[id] = updated
            auditEntries.append(
                AuditEntry(
                    id: "aud_\(auditEntries.count + 1)",
                    actorID: approvedBy ?? request.requestedBy,
                    action: "send.\(status.rawValue)",
                    targetType: "send_request",
                    targetID: id.rawValue,
                    result: "ok"
                )
            )
            return updated
        }
    }

    private static func isCanonicalSendTransition(
        from current: SendRequestStatus,
        to next: SendRequestStatus
    ) -> Bool {
        switch (current, next) {
        case (.pending, .approved), (.pending, .denied), (.pending, .cancelled), (.pending, .expired),
             (.approved, .sending), (.approved, .failed), (.approved, .deliveryUncertain),
             (.sending, .sent), (.sending, .failed), (.sending, .deliveryUncertain):
            true
        default:
            false
        }
    }
}

extension InMemoryMailStore: SentMailRecordingStore {
    public func recordSentMessage(draft: Draft, requestID: SendRequestID, actor: Actor) -> MessageSummary {
        recordSentMessage(
            draft: draft,
            messageID: MessageID("msg_sent_\(requestID.rawValue)"),
            actor: actor,
            auditAction: "message.sent_copy"
        )
    }

    public func recordDirectSentMessage(draft: Draft, actor: Actor) -> MessageSummary {
        recordSentMessage(
            draft: draft,
            messageID: MessageID("msg_sent_direct_\(draft.id.rawValue)"),
            actor: actor,
            auditAction: "message.direct_send"
        )
    }

    private func recordSentMessage(
        draft: Draft,
        messageID: MessageID,
        actor: Actor,
        auditAction: String
    ) -> MessageSummary {
        let sentMailbox = accounts.first(where: { $0.id == draft.accountID })?.sentMailbox ?? "Sent"
        let mailbox = Mailbox(
            id: MailboxID("mbx_\(draft.accountID.rawValue)_sent"),
            accountID: draft.accountID,
            name: sentMailbox,
            path: sentMailbox,
            specialUse: "\\Sent"
        )
        if let existingIndex = mailboxes.firstIndex(where: { $0.id == mailbox.id }) {
            mailboxes[existingIndex] = mailbox
        } else {
            mailboxes.append(mailbox)
        }

        let message = MessageSummary(
            id: messageID,
            threadID: draft.sourceThreadID,
            from: draft.from,
            subject: draft.subject,
            preview: draft.bodyPlain,
            smartCategory: .personal,
            labels: ["Sent"],
            isSeen: true,
            mailboxPath: sentMailbox,
            isDeleted: false,
            sentAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        messages.removeAll { $0.id == message.id }
        messages.append(message)
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: auditAction,
                targetType: "message",
                targetID: message.id.rawValue,
                result: "ok"
            )
        )
        return message
    }
}

extension InMemoryMailStore: SendWarningRecordingStore {
    public func recordSendWarning(requestID: SendRequestID, action: String, actor: Actor) {
        auditEntries.append(
            AuditEntry(
                id: "aud_\(auditEntries.count + 1)",
                actorID: actor.id,
                action: action,
                targetType: "send_request",
                targetID: requestID.rawValue,
                result: "ok"
            )
        )
    }
}

extension InMemoryMailStore: MailCache {
    public func cacheMailboxes(_ mailboxes: [Mailbox]) {
        self.mailboxes = mailboxes
    }

    public func cacheMessage(_ message: MessageSummary) {
        messageTranslationLock.withLock {
            messages.removeAll { $0.id == message.id }
            messages.append(message)
            if message.isDeleted {
                messageTranslations = messageTranslations.filter { $0.value.messageID != message.id }
            }
        }
    }
}

extension InMemoryMailStore: LocalAIStore {}

extension InMemoryMailStore: MailTranslationCacheRepository {
    public func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) throws -> CachedMessageTranslation? {
        messageTranslationLock.withLock {
            messageTranslations[translationCacheKey(messageID: messageID, targetLanguageID: targetLanguageID)]
        }
    }

    public func compareAndSaveCachedTranslation(
        _ translation: CachedMessageTranslation,
        expectedSourceFingerprint: String
    ) throws -> MailTranslationCacheSaveResult {
        onTranslationCompareAndSaveBeforeLock?()
        return messageTranslationLock.withLock {
            guard translation.sourceFingerprint == expectedSourceFingerprint,
                  let activeMessage = messages.first(where: {
                      $0.id == translation.messageID && !$0.isDeleted
                  }),
                  MailTranslationFingerprint.message(activeMessage) == expectedSourceFingerprint
            else {
                return .sourceChanged
            }
            onTranslationSaveAfterActiveCheck?()
            let key = translationCacheKey(
                messageID: translation.messageID,
                targetLanguageID: translation.targetLanguageID
            )
            let createdAt = messageTranslations[key]?.createdAt ?? translation.createdAt
            messageTranslations[key] = CachedMessageTranslation(
                messageID: translation.messageID,
                targetLanguageID: translation.targetLanguageID,
                sourceFingerprint: translation.sourceFingerprint,
                providerID: translation.providerID,
                modelID: translation.modelID,
                contractVersion: translation.contractVersion,
                bodyKind: translation.bodyKind,
                translatedBody: translation.translatedBody,
                createdAt: createdAt,
                updatedAt: translation.updatedAt
            )
            return .saved
        }
    }

    private func translationCacheKey(messageID: MessageID, targetLanguageID: String) -> String {
        "\(messageID.rawValue)\u{1f}\(targetLanguageID)"
    }
}

extension InMemoryMailStore: MailKnowledgeRepository {
    public func accountMessageIDs(accountID: AccountID) throws -> Set<MessageID> {
        Set(messages.compactMap { message in
            let membershipOwners = Set(memberships.filter { $0.messageID == message.id }.map(\.accountID))
            let threadOwners: Set<AccountID> = message.threadID.map { threadID in
                Set(threads.filter { $0.id == threadID }.map(\.accountID))
            } ?? []
            if !threadOwners.isEmpty && threadOwners != Set([accountID]) { return nil }
            if !membershipOwners.isEmpty {
                return membershipOwners == Set([accountID]) ? message.id : nil
            }
            return threadOwners == Set([accountID]) ? message.id : nil
        })
    }

    public func rankedMailSearch(_ query: MailKnowledgeQuery) throws -> [RankedMailKnowledgeCandidate] {
        let tokens = query.text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return [] }
        let allowed = try query.accountID.map { try accountMessageIDs(accountID: $0) }
        let matching = messages.compactMap { message -> (MessageSummary, Int)? in
            guard !message.isDeleted else { return nil }
            guard query.filter.matches(message) else { return nil }
            if let allowed, !allowed.contains(message.id) { return nil }
            if query.scope == .activeConversation,
               MailThreading.conversationKey(for: message) != query.activeConversationKey {
                return nil
            }
            let text = "\(message.from.rawValue) \(message.subject) \(message.body)".lowercased()
            let count = tokens.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            return count > 0 ? (message, count) : nil
        }.sorted {
            if $0.1 == $1.1 { return $0.0.id.rawValue < $1.0.id.rawValue }
            return $0.1 > $1.1
        }
        return matching.prefix(max(1, query.limit)).enumerated().map { offset, value in
            RankedMailKnowledgeCandidate(
                message: value.0,
                snippet: value.0.preview,
                lexicalRank: offset + 1,
                lexicalScore: Double(value.1) / Double(tokens.count)
            )
        }
    }

    public func filteredMailMessages(
        _ filter: MailKnowledgeFilter, accountID: AccountID?, limit: Int
    ) throws -> MailFilterResult {
        let matching = try filteredMailMatches(filter, accountID: accountID)
            .sorted { ($0.sentAt ?? .distantPast, $0.id.rawValue) > ($1.sentAt ?? .distantPast, $1.id.rawValue) }
        return MailFilterResult(totalCount: matching.count, messages: Array(matching.prefix(max(0, limit))))
    }

    public func filteredMailCategoryCounts(
        _ filter: MailKnowledgeFilter, accountID: AccountID?
    ) throws -> [SmartCategory: Int] {
        try filteredMailMatches(filter, accountID: accountID)
            .reduce(into: [:]) { counts, message in counts[message.smartCategory, default: 0] += 1 }
    }

    public func conversationMessages(conversationKey: String, accountID: AccountID?) throws -> [MessageSummary] {
        let allowed = try accountID.map { try accountMessageIDs(accountID: $0) }
        return messages.filter { message in
            !message.isDeleted && MailThreading.conversationKey(for: message) == conversationKey
                && (allowed?.contains(message.id) ?? true)
        }
    }

    private func filteredMailMatches(_ filter: MailKnowledgeFilter, accountID: AccountID?) throws -> [MessageSummary] {
        let allowed = try accountID.map { try accountMessageIDs(accountID: $0) }
        return messages.filter { message in
            if let allowed, !allowed.contains(message.id) { return false }
            if filter.mailbox == .any,
               MailMailboxFilter.isTrashOrJunk(
                   message.mailboxPath,
                   specialUse: mailboxes.first { $0.path == message.mailboxPath }?.specialUse
               ) { return false }
            return filter.matches(message)
        }
    }

    public func storedMailEmbeddingChunks(
        providerID: String,
        modelID: String
    ) throws -> [StoredMailEmbeddingChunk] {
        mailEmbeddingChunks.filter { $0.providerID == providerID && $0.modelID == modelID }
    }

    public func replaceMailEmbeddingChunks(
        messageID: MessageID,
        providerID: String,
        modelID: String,
        contentFingerprint: String,
        chunks: [StoredMailEmbeddingChunk]
    ) throws {
        mailEmbeddingChunks.removeAll {
            $0.messageID == messageID && $0.providerID == providerID && $0.modelID == modelID
        }
        mailEmbeddingChunks.append(contentsOf: chunks)
    }
}

private enum Stage0Seed {
    static let account = Account(
        id: AccountID("acc_personal"),
        displayName: "Personal",
        email: EmailAddress("me@example.com"),
        imapHost: "127.0.0.1",
        smtpHost: "127.0.0.1"
    )

    static let mailbox = Mailbox(
        id: MailboxID("mbx_inbox"),
        accountID: account.id,
        name: "INBOX",
        path: "INBOX",
        specialUse: "\\Inbox"
    )

    static let thread = MailThread(
        id: ThreadID("thr_alice_1"),
        accountID: account.id,
        subjectNormalized: "availability",
        participantEmails: [EmailAddress("alice@example.com"), account.email]
    )

    static let message = MessageSummary(
        id: MessageID("msg_alice_1"),
        threadID: thread.id,
        from: EmailAddress("alice@example.com"),
        subject: "Availability",
        preview: "Can you meet next Tuesday?",
        smartCategory: .personal
    )
}
