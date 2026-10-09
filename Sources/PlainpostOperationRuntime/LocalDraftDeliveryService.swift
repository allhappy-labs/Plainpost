import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

public struct LocalDraftDeliveryResult: Equatable, Sendable {
    public let messageID: String
    public let remoteSentCopyAppended: Bool
}

public final class LocalDraftDeliveryService: @unchecked Sendable {
    private let store: SQLiteMailStore
    private let credentialResolver: MailCredentialResolver
    private let smtpClientFactory: @Sendable (String, Int) -> SMTPClientProtocol

    public init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        credentialResolver: MailCredentialResolver? = nil,
        smtpClientFactory: @escaping @Sendable (String, Int) -> SMTPClientProtocol = MailTransportClientFactory.smtpClient
    ) {
        self.store = store
        self.credentialResolver = credentialResolver
            ?? .withoutGoogleOAuth(store: store, credentials: credentials)
        self.smtpClientFactory = smtpClientFactory
    }

    /// Shared account-owned send path used by the composers. Undo has
    /// already expired when the composer invokes this entry point.
    public func deliverDirect(draft: Draft, actor: Actor) async throws -> LocalDraftDeliveryResult {
        try await deliverDirect(draft: draft, actor: actor, allowImplicitDirectSource: false, allowNodeFallback: false)
    }

    private func deliverDirect(draft: Draft, actor: Actor, allowImplicitDirectSource: Bool, allowNodeFallback: Bool) async throws -> LocalDraftDeliveryResult {
        try rejectCompletedOrUncertainSend(draftID: draft.id, contentHash: draft.contentHash)
        let saved = try store.draft(id: draft.id)
        guard saved == draft, saved.createdBy == actor.id else {
            throw DirectSendIntentError.draftMismatch
        }
        let intent = try store.reserveDirectSend(
            draftID: draft.id, contentHash: draft.contentHash, accountID: draft.accountID,
            allowImplicitDirectSource: allowImplicitDirectSource, allowNodeFallback: allowNodeFallback
        )
        guard intent.state == .reserved else { throw DirectSendIntentError.alreadySubmitted(intent.state) }
        return try await deliver(
            draftID: draft.id, expectedHash: draft.contentHash, actor: actor,
            directIntent: intent, allowImplicitDirectSource: allowImplicitDirectSource,
            allowNodeFallback: allowNodeFallback
        )
    }

    public func deliver(draftID: DraftID, expectedHash: String, actor: Actor) async throws -> LocalDraftDeliveryResult {
        try await deliver(draftID: draftID, expectedHash: expectedHash, actor: actor, allowNodeFallback: false)
    }

    /// Only the service's journaled fallback route may send a Node-backed
    /// account directly. The source generation still fences mode changes.
    public func deliverRoutedFallback(draftID: DraftID, expectedHash: String, actor: Actor) async throws -> LocalDraftDeliveryResult {
        try await deliver(draftID: draftID, expectedHash: expectedHash, actor: actor, allowNodeFallback: true)
    }

    private func deliver(draftID: DraftID, expectedHash: String, actor: Actor, allowNodeFallback: Bool) async throws -> LocalDraftDeliveryResult {
        try rejectCompletedOrUncertainSend(draftID: draftID, contentHash: expectedHash)
        let draft = try store.draft(id: draftID)
        guard draft.contentHash == expectedHash else { throw DraftOptimisticUpdateError.conflict }
        return try await deliverDirect(draft: draft, actor: actor, allowImplicitDirectSource: true, allowNodeFallback: allowNodeFallback)
    }

    private func rejectCompletedOrUncertainSend(draftID: DraftID, contentHash: String) throws {
        if let intent = try store.directSendIntent(draftID: draftID, contentHash: contentHash),
           intent.state != .reserved {
            throw DirectSendIntentError.alreadySubmitted(intent.state)
        }
    }

    private func deliver(draftID: DraftID, expectedHash: String, actor: Actor, directIntent: DirectSendIntent, allowImplicitDirectSource: Bool, allowNodeFallback: Bool) async throws -> LocalDraftDeliveryResult {
        let draft = try store.draft(id: draftID)
        guard draft.contentHash == expectedHash else { throw DraftOptimisticUpdateError.conflict }
        guard draft.createdBy == actor.id else {
            throw PlainpostError.permissionDenied("This actor cannot deliver that draft.")
        }
        guard let account = store.accounts.first(where: { $0.id == draft.accountID })
            ?? store.accounts.first(where: { $0.email == draft.from }) else {
            throw PlainpostError.validationFailed("SMTP credentials are not available.")
        }
        guard account.id == draft.accountID else {
            throw DirectSendIntentError.draftMismatch
        }
        let smtpAuthentication: MailAuthentication
        do {
            smtpAuthentication = try await credentialResolver.smtpAuthentication(for: account)
        } catch MailCredentialError.unavailable {
            throw PlainpostError.validationFailed("SMTP credentials are not available.")
        }
        let rendered = try DraftRenderer().render(draft)
        let messageData = rendered.headers + "\r\n\r\n" + rendered.body
        try store.markDirectSendSubmitting(directIntent, allowImplicitDirectSource: allowImplicitDirectSource, allowNodeFallback: allowNodeFallback)
        // A refused OAuth token is refreshed and retried once, before `MAIL FROM`.
        do {
            try store.requireUnchangedDirectSendSource(directIntent, allowImplicitDirectSource: allowImplicitDirectSource, allowNodeFallback: allowNodeFallback)
            try await credentialResolver.tokenRefreshingSMTPClient(for: account) {
                self.smtpClientFactory(account.smtpHost, account.smtpPort)
            }.send(
                username: account.username, authentication: smtpAuthentication, from: draft.from,
                to: rendered.envelopeRecipients, data: messageData
            )
        } catch {
            if error is NodeMailModeStoreError || Self.provenBeforeData(error) {
                try store.releaseDirectSendAfterProvenPreSubmissionFailure(draftID: draft.id, contentHash: expectedHash)
            } else {
                try store.markDirectSendUncertain(draftID: draft.id, contentHash: expectedHash)
                throw DirectSendIntentError.alreadySubmitted(.uncertain)
            }
            throw error
        }
        let sentCopyManagedByServer = MailProviderProfile.gmail.storesSentMessagesAutomatically(for: account)
        var remoteSentCopyAppended = sentCopyManagedByServer
        if !sentCopyManagedByServer,
           let imapAuthentication = try? await credentialResolver.imapAuthentication(for: account) {
            do {
                let client = MailTransportClientFactory.imapClient(host: account.imapHost, port: account.imapPort)
                try await client.authenticate(username: account.username, authentication: imapAuthentication)
                _ = try await client.appendMessage(to: account.sentMailbox, flags: ["\\Seen"], data: messageData)
                remoteSentCopyAppended = true
                await client.disconnect()
            } catch { }
        }
        let message: MessageSummary
        do {
            message = try store.recordDirectSentMessage(draft: draft, actor: actor)
            do {
                try store.markDirectSendSent(directIntent, allowImplicitDirectSource: allowImplicitDirectSource, allowNodeFallback: allowNodeFallback)
            } catch NodeMailModeStoreError.generationConflict {
                try store.markDirectSendUncertain(draftID: draft.id, contentHash: expectedHash)
                throw DirectSendIntentError.alreadySubmitted(.uncertain)
            }
        } catch {
            if case DirectSendIntentError.alreadySubmitted(.uncertain) = error { throw error }
            try? store.markDirectSendUncertain(draftID: draft.id, contentHash: expectedHash)
            throw PostSMTPPersistenceError.localPersistenceFailed
        }
        return LocalDraftDeliveryResult(
            messageID: message.id.rawValue, remoteSentCopyAppended: remoteSentCopyAppended
        )
    }

    private static func provenBeforeData(_ error: Error) -> Bool {
        guard let smtp = error as? SMTPClientError else { return false }
        switch smtp {
        case .connectionFailed, .tlsFailed, .authenticationFailed,
             .smtpUTF8Unavailable, .recipientRejected,
             .refusedBeforeData, .unreachableBeforeData:
            return true
        case .resourceLimit, .deliveryUncertain, .unexpectedResponse:
            return false
        }
    }
}
