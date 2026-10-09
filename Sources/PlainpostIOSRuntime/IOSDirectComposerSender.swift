import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime
import PlainpostSecrets
import PlainpostUI

public struct IOSDirectComposerSender: DirectComposerSending {
    private let deliveryService: LocalDraftDeliveryService

    public init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        credentialResolver: MailCredentialResolver? = nil,
        smtpClientFactory: @escaping @Sendable (String, Int) -> SMTPClientProtocol = MailTransportClientFactory.smtpClient
    ) {
        deliveryService = LocalDraftDeliveryService(
            store: store, credentials: credentials, credentialResolver: credentialResolver,
            smtpClientFactory: smtpClientFactory
        )
    }

    public func send(draft: Draft) async throws -> DirectComposerSendResult {
        let result = try await deliveryService.deliverDirect(
            draft: draft,
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        )
        return DirectComposerSendResult(
            messageID: result.messageID, remoteSentCopyAppended: result.remoteSentCopyAppended
        )
    }
}
