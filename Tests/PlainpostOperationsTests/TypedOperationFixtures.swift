import PlainpostCore
import PlainpostDB
import PlainpostTestSupport

let plainpostTestAIOperationPayloadJSON = #"{"operation":"recategorizeInbox","recordID":"","providerID":"deterministic","conversation":[],"smartInboxRunRequest":{"mode":"incremental","scope":{"allAccounts":{}}},"smartInboxClassifierIdentity":{"providerID":"deterministic","modelID":"deterministic-local","promptVersion":"2026-07-23","schemaVersion":"smart-inbox-triage-labels-v2"},"enqueueOnly":false}"#
let plainpostTestInboxSyncPayloadJSON = #"{"accountID":"acc_personal","trigger":"manual","scope":"incremental"}"#

extension SQLiteMailStore {
    func cacheOwnedTestMessage(
        _ message: MessageSummary,
        account: Account = PlainpostFixtures.personalAccount
    ) throws {
        try cacheAccounts([account])
        let uid = message.id.rawValue.utf8.reduce(1) { partial, byte in
            ((partial * 31) + Int(byte)) % 2_000_000_000
        }
        _ = try commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: uid,
            notificationEligible: false
        )
    }
}
