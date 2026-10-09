import Foundation
import PlainpostAccountRuntime
import PlainpostCore
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import PlainpostDB

public struct ApprovalQueueAttachmentModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int

    public init(id: String, filename: String, mimeType: String, byteCount: Int) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

public struct ApprovalQueueReviewDetails: Equatable, Sendable {
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let bodyPlain: String
    public let attachments: [ApprovalQueueAttachmentModel]
    public let requestReason: String?
    public let riskScore: Int

    public init(
        from: String,
        to: [String],
        cc: [String],
        bcc: [String],
        bodyPlain: String,
        attachments: [ApprovalQueueAttachmentModel],
        requestReason: String?,
        riskScore: Int
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.bodyPlain = bodyPlain
        self.attachments = attachments
        self.requestReason = requestReason
        self.riskScore = riskScore
    }
}

public struct ApprovalQueueItemModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let agentName: String
    public let subject: String
    public let recipientSummary: String
    public let riskFlags: [String]
    public let hasAttachments: Bool
    public let requiresAuthentication: Bool
    public let status: String
    public let reviewDetails: ApprovalQueueReviewDetails?

    public init(
        id: String,
        agentName: String,
        subject: String,
        recipientSummary: String,
        riskFlags: [String],
        hasAttachments: Bool,
        requiresAuthentication: Bool = false,
        status: String,
        reviewDetails: ApprovalQueueReviewDetails? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.subject = subject
        self.recipientSummary = recipientSummary
        self.riskFlags = riskFlags
        self.hasAttachments = hasAttachments
        self.requiresAuthentication = requiresAuthentication
        self.status = status
        self.reviewDetails = reviewDetails
    }
}

public protocol ApprovalQueueHandling: Sendable {
    func items() throws -> [ApprovalQueueItemModel]
    func approve(requestID: String, username: String, password: String) async throws
    func deny(requestID: String, reason: String?) async throws
}

public final class ApprovalQueueService<Store: ApprovalQueueReadableStore>: ApprovalQueueHandling, @unchecked Sendable {
    public static var authenticationRiskScoreThreshold: Int { 45 }

    private let store: Store
    private let smtpService: ApprovalSMTPService<Store>
    private let guiUser: Actor
    private let authenticator: LocalApprovalAuthenticating

    public init(
        store: Store,
        smtpClient: SMTPClientProtocol,
        authenticator: LocalApprovalAuthenticating = LocalApprovalAuthenticatorFactory.defaultAuthenticator(),
        guiUser: Actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
    ) {
        self.store = store
        self.smtpService = ApprovalSMTPService(store: store, smtpClient: smtpClient)
        self.authenticator = authenticator
        self.guiUser = guiUser
    }

    public func items() throws -> [ApprovalQueueItemModel] {
        try store.approvalQueueRequests.map { request in
            let draft = try store.draft(id: request.draftID)
            return ApprovalQueueItemModel(
                id: request.id.rawValue,
                agentName: request.requestedBy,
                subject: draft.subject,
                recipientSummary: (draft.to + draft.cc + draft.bcc).map(\.rawValue).joined(separator: ", "),
                riskFlags: request.riskFlags.map(\.rawValue),
                hasAttachments: !draft.attachments.isEmpty,
                requiresAuthentication: Self.requiresAuthentication(for: request),
                status: request.status.rawValue,
                reviewDetails: ApprovalQueueReviewDetails(
                    from: draft.from.rawValue,
                    to: draft.to.map(\.rawValue),
                    cc: draft.cc.map(\.rawValue),
                    bcc: draft.bcc.map(\.rawValue),
                    bodyPlain: draft.bodyPlain,
                    attachments: draft.attachments.map {
                        ApprovalQueueAttachmentModel(
                            id: $0.id,
                            filename: $0.filename,
                            mimeType: $0.mimeType,
                            byteCount: $0.data.count
                        )
                    },
                    requestReason: request.reason,
                    riskScore: request.riskScore
                )
            )
        }
    }

    public func approve(requestID: String, username: String, password: String) async throws {
        let request = try store.sendRequest(id: SendRequestID(requestID))
        if Self.requiresAuthentication(for: request) {
            let draft = try store.draft(id: request.draftID)
            try await authenticator.authenticate(
                reason: "Authenticate to approve high-risk send \"\(draft.subject)\"."
            )
        }
        try await smtpService.approveAndSend(
            requestID: SendRequestID(requestID),
            actor: guiUser,
            configuration: SMTPDeliveryConfiguration(username: username, password: password)
        )
    }

    public func deny(requestID: String, reason: String?) async throws {
        try smtpService.deny(requestID: SendRequestID(requestID), actor: guiUser, reason: reason)
    }

    private static func requiresAuthentication(for request: SendRequest) -> Bool {
        request.riskScore >= authenticationRiskScoreThreshold
    }
}

public protocol ApprovalQueueReadableStore: ApprovalSendStore, DraftRepository {
    var approvalQueueRequests: [SendRequest] { get }
}

extension InMemoryMailStore: ApprovalQueueReadableStore {}
extension SQLiteMailStore: ApprovalQueueReadableStore {}

@MainActor
public final class ApprovalQueueViewModel: ObservableObject {
    @Published public private(set) var items: [ApprovalQueueItemModel]
    @Published public private(set) var isWorking: Bool
    /// Why the last refresh failed, until one succeeds. Unlike `statusMessage`, an approval's
    /// outcome never replaces it, so a list can keep showing that it's stale.
    @Published public private(set) var refreshFailure: String?
    @Published public private(set) var statusMessage: String? {
        didSet {
            announceStatusMessage()
        }
    }

    private let queue: ApprovalQueueHandling

    public init(queue: ApprovalQueueHandling, items: [ApprovalQueueItemModel] = []) {
        self.queue = queue
        self.items = items
        self.isWorking = false
    }

    private func announceStatusMessage() {
        guard let statusMessage, !statusMessage.isEmpty else {
            return
        }
#if os(macOS)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: statusMessage,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
#elseif canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: statusMessage)
#endif
    }

    public var pendingItemCount: Int {
        items.filter { $0.status.caseInsensitiveCompare("pending") == .orderedSame }.count
    }

    public func refresh() async throws {
        try Task.checkCancellation()
        isWorking = true
        defer { isWorking = false }
        do {
            let refreshed = try queue.items()
            // A synchronous store read may finish after its caller was cancelled.
            try Task.checkCancellation()
            items = refreshed
            refreshFailure = nil
        } catch {
            if !Task.isCancelled {
                statusMessage = "Unable to refresh approval queue."
                refreshFailure = "Unable to refresh approval queue."
            }
            throw error
        }
    }

    public func approve(requestID: String, username: String, password: String) async throws {
        guard !isWorking else {
            statusMessage = "Approval already in progress."
            throw PlainpostError.validationFailed("Approval already in progress.")
        }
        isWorking = true
        defer { isWorking = false }
        statusMessage = requiresAuthentication(requestID: requestID)
            ? "Waiting for local authentication..."
            : "Approving send request..."
        do {
            let subject = try subject(for: requestID)
            try await queue.approve(requestID: requestID, username: username, password: password)
            recordCompletedAction(requestID: requestID, status: "sent")
            refreshAfterCompletedAction()
            statusMessage = "Sent \(subject)"
        } catch {
            refreshAfterCompletedAction()
            let possiblySent = items.first(where: { $0.id == requestID })?.status == ApprovalStatusPresentation.deliveryUncertain
            statusMessage = possiblySent || SMTPDeliveryAmbiguity.isAmbiguous(error)
                ? Self.possiblySentMessage
                : Self.failureMessage(for: .approve, error: error)
            throw error
        }
    }

    /// Never "try again": asking to send it again would be refused.
    static let possiblySentMessage = "This message may have been sent. Check Sent before sending it again."

    func approveUsingConfiguredCredentials(requestID: String) async throws {
        try await approve(requestID: requestID, username: "", password: "")
    }

    public func deny(requestID: String, reason: String?) async throws {
        isWorking = true
        defer { isWorking = false }
        statusMessage = "Denying send request..."
        do {
            let subject = try subject(for: requestID)
            try await queue.deny(requestID: requestID, reason: reason)
            recordCompletedAction(requestID: requestID, status: "denied")
            refreshAfterCompletedAction()
            statusMessage = "Denied \(subject)"
        } catch {
            statusMessage = Self.failureMessage(for: .deny, error: error)
            throw error
        }
    }

    private func subject(for requestID: String) throws -> String {
        if let item = items.first(where: { $0.id == requestID }) {
            return item.subject
        }
        let loadedItems = try queue.items()
        items = loadedItems
        return loadedItems.first(where: { $0.id == requestID })?.subject ?? requestID
    }

    private func requiresAuthentication(requestID: String) -> Bool {
        items.first(where: { $0.id == requestID })?.requiresAuthentication ?? false
    }

    private func recordCompletedAction(requestID: String, status: String) {
        items = items.map { item in
            guard item.id == requestID else { return item }
            return ApprovalQueueItemModel(
                id: item.id,
                agentName: item.agentName,
                subject: item.subject,
                recipientSummary: item.recipientSummary,
                riskFlags: item.riskFlags,
                hasAttachments: item.hasAttachments,
                requiresAuthentication: item.requiresAuthentication,
                status: status,
                reviewDetails: item.reviewDetails
            )
        }
    }

    private func refreshAfterCompletedAction() {
        // The action has already committed in the operation worker. A transient
        // projection read must not turn that success into a false failure or
        // leave the completed request visible in the Pending filter.
        if let refreshedItems = try? queue.items() {
            items = refreshedItems
        }
    }

    private enum ApprovalAction {
        case approve
        case deny
    }

    private static func failureMessage(for action: ApprovalAction, error: Error) -> String {
        if let authenticationError = error as? LocalApprovalAuthenticationError {
            switch authenticationError {
            case .denied:
                return "Approval cancelled. Local authentication was not completed."
            case .unavailable:
                return "Approval failed. Local authentication is unavailable."
            }
        }
        if let mailError = error as? PlainpostError {
            let detail: String
            switch mailError {
            case .permissionDenied(let message), .validationFailed(let message), .notFound(let message):
                detail = message
            }
            return "\(action == .approve ? "Approval" : "Denial") failed. \(detail)"
        }
        return "\(action == .approve ? "Approval" : "Denial") failed. Try again."
    }

    public static func preview() -> ApprovalQueueViewModel {
        ApprovalQueueViewModel(
            queue: PreviewApprovalQueue(),
            items: PreviewApprovalQueue.previewItems
        )
    }
}

private struct PreviewApprovalQueue: ApprovalQueueHandling {
    static let previewItems = [
        ApprovalQueueItemModel(
            id: "APR-2025-0514-1024",
            agentName: "Jessica Sun",
            subject: "Intro to Strategic Finance partnership",
            recipientSummary: "Emily Jones, Max Harper +2",
            riskFlags: ["External recipients", "Contains financial terms", "Introduces new partnership"],
            hasAttachments: true,
            requiresAuthentication: true,
            status: "pending",
            reviewDetails: ApprovalQueueReviewDetails(
                from: "jessica@bbb.vc",
                to: ["emily@aaa.capital", "max@bb8.finance"],
                cc: [],
                bcc: [],
                bodyPlain: """
                Hi Emily,

                I'd like to introduce you to Max Harper. Max is the founder and CEO of BB8, an AI-native financial planning platform for founders and finance teams.

                Max, Emily leads Strategic Finance at AAA Capital. I would love to see if there is a fit for a short introduction this week.

                Best,
                Jessica
                """,
                attachments: [
                    ApprovalQueueAttachmentModel(id: "att-overview", filename: "Strategic Finance Overview.pdf", mimeType: "application/pdf", byteCount: 1_258_291),
                    ApprovalQueueAttachmentModel(id: "att-terms", filename: "Term Sheet (draft).xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", byteCount: 319_488)
                ],
                requestReason: "Intro email and context for a potential strategic finance partnership.",
                riskScore: 78
            )
        ),
        ApprovalQueueItemModel(
            id: "APR-2025-0514-0958",
            agentName: "John Smith",
            subject: "Q2 Board Update",
            recipientSummary: "board@aaa.capital",
            riskFlags: ["External recipients"],
            hasAttachments: true,
            status: "pending"
        ),
        ApprovalQueueItemModel(
            id: "APR-2025-0514-0941",
            agentName: "Diana Jones",
            subject: "Re: Vendor contract review",
            recipientSummary: "legal@acmelegal.com",
            riskFlags: ["External recipients"],
            hasAttachments: false,
            status: "pending"
        ),
        ApprovalQueueItemModel(
            id: "APR-2025-0513-1700",
            agentName: "Linear",
            subject: "Customer data export",
            recipientSummary: "exports@datahub.io",
            riskFlags: ["High risk data export", "External recipients"],
            hasAttachments: false,
            requiresAuthentication: true,
            status: "failed"
        ),
        ApprovalQueueItemModel(
            id: "APR-2025-0513-1540",
            agentName: "Jessica Sun",
            subject: "Marketing plan alignment",
            recipientSummary: "team@bbbventures.com",
            riskFlags: [],
            hasAttachments: true,
            status: "sent"
        ),
        ApprovalQueueItemModel(
            id: "APR-2025-0513-1204",
            agentName: "Lenny's Newsletter",
            subject: "Investment memo - April",
            recipientSummary: "investors@acmefund.com",
            riskFlags: ["External recipients", "Financial terms"],
            hasAttachments: true,
            requiresAuthentication: true,
            status: "pending"
        )
    ]

    func items() throws -> [ApprovalQueueItemModel] {
        Self.previewItems
    }

    func approve(requestID: String, username: String, password: String) async throws {}

    func deny(requestID: String, reason: String?) async throws {}
}
