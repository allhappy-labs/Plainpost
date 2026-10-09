import Foundation

public enum SendRequestStatus: String, Codable, Sendable {
    case pending
    case approved
    case sending
    case sent
    case deliveryUncertain = "delivery_uncertain"
    case denied
    case failed
    case cancelled
    case expired
}

public enum RiskFlag: String, Codable, Hashable, Sendable {
    case externalRecipient = "external_recipient"
    case newRecipient = "new_recipient"
    case manyRecipients = "many_recipients"
    case attachmentPresent = "attachment_present"
    case emptySubject = "empty_subject"
    case suspiciousLink = "suspicious_link"
    case replyToMismatch = "reply_to_mismatch"
    case aiGeneratedBody = "ai_generated_body"
    case agentRequestedSend = "agent_requested_send"
    case bccPresent = "bcc_present"
    case draftChangedAfterRequest = "draft_changed_after_request"
}

public struct SendRequest: Equatable, Codable, Sendable {
    public let id: SendRequestID
    public let draftID: DraftID
    public let requestedBy: String
    public let status: SendRequestStatus
    public let requestedDraftHash: String
    public let riskScore: Int
    public let riskFlags: [RiskFlag]
    public let reason: String?
    public let approvedBy: String?
    public let approvedDraftHash: String?
    /// Optional for compatibility with persisted requests created before
    /// approval expiry existed. New policy requests always set it.
    public let expiresAt: Date?
    /// The mail-intent operation ID this approval was claimed for when the
    /// send is routed through the journal (a Node-backed account). Set only
    /// together with the `sending` claim, so a re-approval (a new request
    /// payload) never reuses an earlier approval's intent.
    public let deliveryOperationID: String?

    public init(
        id: SendRequestID,
        draftID: DraftID,
        requestedBy: String,
        status: SendRequestStatus,
        requestedDraftHash: String,
        riskScore: Int,
        riskFlags: [RiskFlag],
        reason: String?,
        approvedBy: String?,
        approvedDraftHash: String?,
        expiresAt: Date? = nil,
        deliveryOperationID: String? = nil
    ) {
        self.deliveryOperationID = deliveryOperationID
        self.id = id
        self.draftID = draftID
        self.requestedBy = requestedBy
        self.status = status
        self.requestedDraftHash = requestedDraftHash
        self.riskScore = riskScore
        self.riskFlags = riskFlags
        self.reason = reason
        self.approvedBy = approvedBy
        self.approvedDraftHash = approvedDraftHash
        self.expiresAt = expiresAt
    }

    public func updating(status: SendRequestStatus, approvedBy: String? = nil, approvedDraftHash: String? = nil) -> SendRequest {
        SendRequest(
            id: id,
            draftID: draftID,
            requestedBy: requestedBy,
            status: status,
            requestedDraftHash: requestedDraftHash,
            riskScore: riskScore,
            riskFlags: riskFlags,
            reason: reason,
            approvedBy: approvedBy ?? self.approvedBy,
            approvedDraftHash: approvedDraftHash ?? self.approvedDraftHash,
            expiresAt: expiresAt,
            deliveryOperationID: deliveryOperationID
        )
    }

    public func claimedForRoutedDelivery(operationID: String) -> SendRequest {
        SendRequest(
            id: id, draftID: draftID, requestedBy: requestedBy, status: status,
            requestedDraftHash: requestedDraftHash, riskScore: riskScore, riskFlags: riskFlags, reason: reason,
            approvedBy: approvedBy, approvedDraftHash: approvedDraftHash, expiresAt: expiresAt,
            deliveryOperationID: operationID
        )
    }
}

public struct SendRequestPolicy: Sendable {
    public init() {}

    public func requestSend(draft: Draft, actor: Actor, reason: String?) throws -> SendRequest {
        guard actor.permissions.requestSend else {
            throw PlainpostError.permissionDenied("Actor is not allowed to request sends.")
        }

        var flags: [RiskFlag] = []
        if actor.kind != .user {
            flags.append(.agentRequestedSend)
        }
        if draft.aiGenerated {
            flags.append(.aiGeneratedBody)
        }
        if !draft.bcc.isEmpty {
            flags.append(.bccPresent)
        }
        if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flags.append(.emptySubject)
        }
        let recipientCount = draft.to.count + draft.cc.count + draft.bcc.count
        if recipientCount > 5 {
            flags.append(.manyRecipients)
        }
        if !draft.attachments.isEmpty {
            flags.append(.attachmentPresent)
        }
        if Self.containsSuspiciousLink(draft.bodyPlain) {
            flags.append(.suspiciousLink)
        }

        return SendRequest(
            id: SendRequestID("srq_\(draft.id.rawValue)"),
            draftID: draft.id,
            requestedBy: actor.id,
            status: .pending,
            requestedDraftHash: draft.contentHash,
            riskScore: min(flags.count * 15, 100),
            riskFlags: flags,
            reason: reason,
            approvedBy: nil,
            approvedDraftHash: nil,
            expiresAt: Date().addingTimeInterval(24 * 60 * 60)
        )
    }

    private static func containsSuspiciousLink(_ body: String) -> Bool {
        let lowercased = body.lowercased()
        return lowercased.contains("http://")
            || lowercased.contains("https://")
            || lowercased.contains("xn--")
            || lowercased.contains("@http")
    }
}

public enum ApprovalPolicy {
    public static func ensureCanApprove(actor: Actor) throws {
        guard actor.kind == .user, actor.permissions.approveSend else {
            throw PlainpostError.permissionDenied("Only the local GUI user can approve sends.")
        }
    }

    public static func validateApprovedDraftHash(request: SendRequest, currentDraftHash: String) throws {
        guard request.requestedDraftHash == currentDraftHash else {
            throw PlainpostError.validationFailed("Draft changed after send request was created.")
        }
    }

    public static func validateApproval(request: SendRequest, currentDraftHash: String, actor: Actor) throws {
        try ensureCanApprove(actor: actor)
        try validateApprovedDraftHash(request: request, currentDraftHash: currentDraftHash)
    }
}
