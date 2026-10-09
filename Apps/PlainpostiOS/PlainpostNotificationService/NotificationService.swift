import Foundation
import PlainpostAccountProtocol
import UserNotifications

/// The service extension is deliberately a local-only adapter. It does not
/// own an App Attest key, make network requests, or access mail storage.
final class NotificationService: UNNotificationServiceExtension {
    private var completionGate: NotificationCompletionGate<UNNotificationContent>?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let gate = NotificationCompletionGate<UNNotificationContent>(contentHandler)
        completionGate = gate
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            deliver(request.content)
            return
        }
        bestAttemptContent = content
        applyPresentation(to: content, userInfo: request.content.userInfo)
        deliver(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent { deliver(bestAttemptContent) }
    }

    private func deliver(_ content: UNNotificationContent) {
        let gate = completionGate
        completionGate = nil
        _ = gate?.finish(content)
    }

    private func applyPresentation(to content: UNMutableNotificationContent, userInfo: [AnyHashable: Any]) {
        guard let state = SharedNotificationState.load() else { return }
        do {
            let presentation = try NotificationServicePresentation.render(userInfo: userInfo, contexts: state.contexts)
            guard presentation != .fallback else {
                if let policy = state.policy(for: userInfo), NotificationServicePresentation.shouldSuppressFallback(policy: policy) {
                    suppressFallback(on: content)
                }
                return
            }
            if let title = presentation.title { content.title = title }
            if let subtitle = presentation.subtitle { content.subtitle = subtitle }
            content.body = presentation.body
            if let badge = presentation.badge { content.badge = badge }
            if let thread = presentation.threadIdentifier { content.threadIdentifier = thread }
            if let category = presentation.categoryIdentifier { content.categoryIdentifier = category }
            if let deepLink = presentation.deepLinkToken {
                var updated = content.userInfo
                updated["plainpost.deepLinkToken"] = deepLink
                content.userInfo = updated
            }
        } catch {
            // Invalid envelopes retain the producer's fixed generic alert.
            // Only an authenticated Off policy is allowed to blank it.
            if let policy = state.policy(for: userInfo), NotificationServicePresentation.shouldSuppressFallback(policy: policy) {
                suppressFallback(on: content)
            }
        }
    }

    private func suppressFallback(on content: UNMutableNotificationContent) {
        content.title = ""
        content.subtitle = ""
        content.body = ""
        content.badge = nil
        content.sound = nil
        content.threadIdentifier = ""
        content.categoryIdentifier = ""
        var userInfo = content.userInfo
        userInfo.removeValue(forKey: "plainpost.envelope")
        userInfo.removeValue(forKey: "plainpost.deepLinkToken")
        userInfo.removeValue(forKey: "envelope")
        content.userInfo = userInfo
    }
}

private struct SharedNotificationState {
    let contexts: [Data: NotificationServicePresentation.Context]

    static func load() -> SharedNotificationState? {
        let accessGroup = Bundle.main.object(forInfoDictionaryKey: "PLAINPOST_NOTIFICATION_KEYCHAIN_GROUP") as? String
        let store = NotificationSharedKeychainStore(accessGroup: accessGroup)
        guard let encoded = try? store.load(account: "mailboxContexts"),
              let records = try? JSONDecoder().decode([NotificationMailboxContextRecord].self, from: encoded),
              !records.isEmpty, records.count <= 64 else { return nil }
        let replay = NotificationReplayKeychainStore(store: store)
        var contexts: [Data: NotificationServicePresentation.Context] = [:]
        for record in records {
            guard contexts[record.logicalMailboxID] == nil,
                  let recipient = try? AccountDeviceID(record.recipientDeviceID),
                  let producer = try? AccountDeviceID(record.producerDeviceID),
                  let authority = try? RichNotificationEnvelope.Authority(
                      recipientDeviceID: recipient, producerDeviceID: producer,
                      producerSigningPublicKey: record.producerSigningPublicKey
                  ),
                  let context = try? NotificationServicePresentation.Context(
                      recipientAgreementPrivateKey: record.recipientAgreementPrivateKey,
                      authority: authority, trustEpoch: record.trustEpoch,
                      trustRevision: record.trustRevision, trustHead: record.trustHead,
                      policy: record.policy, replay: replay
                  ) else { return nil }
            contexts[record.logicalMailboxID] = context
        }
        return SharedNotificationState(contexts: contexts)
    }

    func policy(for userInfo: [AnyHashable: Any]) -> NotificationPreviewPolicy? {
        guard let encoded = userInfo["plainpost.envelope"] as? String
                ?? userInfo["envelope"] as? String,
              let wire = try? AccountWireCodec.decodeBase64URL(encoded, exactBytes: nil),
              let mailboxID = try? RichNotificationEnvelope.mailboxID(in: wire),
              let context = contexts[mailboxID] else { return nil }
        return context.policy
    }
}
