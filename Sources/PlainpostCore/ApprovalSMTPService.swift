import Foundation

public struct SMTPDeliveryConfiguration: Equatable, Sendable {
    public let username: String
    public let authentication: MailAuthentication

    public init(username: String, authentication: MailAuthentication) {
        self.username = username
        self.authentication = authentication
    }

    public init(username: String, password: String) {
        self.init(username: username, authentication: .password(password))
    }
}

public struct RemoteSentAppendConfiguration: Equatable, Sendable {
    public let username: String
    public let authentication: MailAuthentication
    public let mailbox: String

    public init(username: String, authentication: MailAuthentication, mailbox: String = "Sent") {
        self.username = username
        self.authentication = authentication
        self.mailbox = mailbox
    }

    public init(username: String, password: String, mailbox: String = "Sent") {
        self.init(username: username, authentication: .password(password), mailbox: mailbox)
    }
}

public enum PostSMTPPersistenceError: Error, Equatable, LocalizedError, Sendable {
    case localPersistenceFailed

    public var errorDescription: String? {
        "SMTP accepted the message, but its local Sent copy could not be persisted. Review delivery before retrying."
    }
}

/// The one rule for whether a failed delivery may already have reached the
/// provider. Ambiguous (the send is `deliveryUncertain`, never `failed`, so
/// it is never asked for and sent again):
/// - `.deliveryUncertain`: the content was sent and the final reply was lost;
/// - `.unexpectedResponse`: an unexpected final reply after the content;
/// - `.connectionFailed`: the SMTP clients never report it before the
///   content (that is `.unreachableBeforeData`), so a caller that does is
///   treated conservatively;
/// - `PostSMTPPersistenceError`: SMTP accepted, a local write failed.
/// Everything before the content is on the wire (`.refusedBeforeData`,
/// `.unreachableBeforeData`, TLS, authentication, SMTPUTF8, a rejected
/// recipient) and every non-SMTP error, OAuth included, is definite.
public enum SMTPDeliveryAmbiguity {
    public static func isAmbiguous(_ error: Error) -> Bool {
        if error is PostSMTPPersistenceError {
            return true
        }
        guard let smtpError = error as? SMTPClientError else { return false }
        switch smtpError {
        case .connectionFailed, .deliveryUncertain, .unexpectedResponse:
            return true
        case .tlsFailed, .authenticationFailed, .resourceLimit, .smtpUTF8Unavailable, .recipientRejected, .refusedBeforeData,
             .unreachableBeforeData:
            return false
        }
    }
}

public final class ApprovalSMTPService<Store: ApprovalSendStore> {
    private let store: Store
    private let smtpClient: SMTPClientProtocol
    private let sentAppendClient: IMAPClientProtocol?
    private let renderer: DraftRenderer

    public init(
        store: Store,
        smtpClient: SMTPClientProtocol,
        sentAppendClient: IMAPClientProtocol? = nil,
        renderer: DraftRenderer = DraftRenderer()
    ) {
        self.store = store
        self.smtpClient = smtpClient
        self.sentAppendClient = sentAppendClient
        self.renderer = renderer
    }

    public func approveAndSend(
        requestID: SendRequestID,
        actor: Actor,
        configuration: SMTPDeliveryConfiguration,
        sentAppend: RemoteSentAppendConfiguration? = nil
    ) async throws {
        let request = try store.sendRequest(id: requestID)
        let draft = try store.draft(id: request.draftID)
        _ = try store.claimSendRequestForDelivery(
            id: requestID,
            currentDraftHash: draft.contentHash,
            actor: actor
        )

        let rendered = try renderer.render(draft)
        let messageData = rendered.headers + "\r\n\r\n" + rendered.body

        do {
            try await smtpClient.send(
                username: configuration.username,
                authentication: configuration.authentication,
                from: draft.from,
                to: rendered.envelopeRecipients,
                data: messageData
            )
        } catch {
            // An ambiguous failure may have delivered the message: it is
            // possibly sent, never failed (which would allow a resend).
            _ = try? store.updateSendRequest(
                id: requestID,
                status: SMTPDeliveryAmbiguity.isAmbiguous(error) ? .deliveryUncertain : .failed,
                approvedBy: actor.id,
                approvedDraftHash: draft.contentHash
            )
            throw error
        }

        if let sentAppendClient, let sentAppend {
            do {
                try await sentAppendClient.authenticate(username: sentAppend.username, authentication: sentAppend.authentication)
                _ = try await sentAppendClient.appendMessage(to: sentAppend.mailbox, flags: ["\\Seen"], data: messageData)
            } catch {
                (store as? SendWarningRecordingStore)?.recordSendWarning(
                    requestID: requestID,
                    action: "send.remote_sent_append_failed",
                    actor: actor
                )
            }
        }

        do {
            if let sentStore = store as? SentMailRecordingStore {
                _ = try sentStore.recordSentMessage(
                    draft: draft,
                    requestID: requestID,
                    actor: actor
                )
            }
            _ = try store.updateSendRequest(
                id: requestID,
                status: .sent,
                approvedBy: actor.id,
                approvedDraftHash: draft.contentHash
            )
        } catch {
            _ = try? store.updateSendRequest(
                id: requestID,
                status: .deliveryUncertain,
                approvedBy: actor.id,
                approvedDraftHash: draft.contentHash
            )
            throw PostSMTPPersistenceError.localPersistenceFailed
        }
    }

    public func deny(requestID: SendRequestID, actor: Actor, reason: String?) throws {
        try ApprovalPolicy.ensureCanApprove(actor: actor)
        _ = try store.updateSendRequest(
            id: requestID,
            status: .denied,
            approvedBy: actor.id,
            approvedDraftHash: nil
        )
    }
}
