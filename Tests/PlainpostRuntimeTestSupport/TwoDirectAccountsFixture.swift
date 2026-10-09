import Foundation
import XCTest
import PlainpostCore
import PlainpostDB
import PlainpostSecrets
import PlainpostUI

/// Two Direct accounts (and optionally a node-backed third) in one store, as the
/// device-wide iOS runtime sees them.
///
/// INBOX mail, every message unread: `first` has "msg_first_1" (sentAt 1) and
/// "msg_first_2" (sentAt 3); `second` has "msg_second_1" (sentAt 2); `node` has
/// "msg_node_1" (sentAt 4), a row left from before it moved to Sync Node. Subjects are
/// "Hello <account id>". Each Direct account also has an "Archive" mailbox.
public struct TwoDirectAccountsFixture: Sendable {
    public let databaseURL: URL
    public let first: Account
    public let second: Account
    public let node: Account?

    public init(testCase: XCTestCase, withNodeAccount: Bool = false) throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-direct-\(UUID().uuidString).sqlite")
        let url = databaseURL
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        first = Self.account("acc_two_first", "first")
        second = Self.account("acc_two_second", "second")
        node = withNodeAccount ? Self.account("acc_two_node", "node") : nil

        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        for account in [first, second] + (node.map { [$0] } ?? []) {
            try store.cacheAccountSetup(
                account: account,
                inbox: Mailbox(
                    id: MailboxID("mb_\(account.id.rawValue)_inbox"), accountID: account.id,
                    name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
                ),
                source: try AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                    logicalMailboxID: nil, providerIdentity: nil, generation: 1
                )
            )
        }
        try store.cacheMailboxes([first, second].map {
            Mailbox(id: MailboxID("mb_\($0.id.rawValue)_archive"), accountID: $0.id,
                    name: "Archive", path: "Archive", specialUse: "\\Archive")
        })
        var seeds: [(Account, String, Double)] = [
            (first, "msg_first_1", 1), (second, "msg_second_1", 2), (first, "msg_first_2", 3),
        ]
        if let node { seeds.append((node, "msg_node_1", 4)) }
        for (uid, seed) in seeds.enumerated() {
            let (account, id, sentAt) = seed
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID(id), threadID: ThreadID("thr_\(id)"),
                    from: EmailAddress("sender@example.com"), subject: "Hello \(account.id.rawValue)",
                    preview: "Preview \(id)", smartCategory: .personal,
                    sentAt: Date(timeIntervalSince1970: sentAt)
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [account.email], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: uid + 1,
                notificationEligible: false
            )
        }
        if let node { try Self.makeNodeBacked(node, in: store) }
    }

    public func store() throws -> SQLiteMailStore {
        try SQLiteMailStore(path: databaseURL.path)
    }

    /// Moves `account` to Sync Node, as a Direct → Sync Node attach does: generation + 1.
    public func switchToNode(_ account: Account) throws {
        try Self.makeNodeBacked(account, in: store())
    }

    /// Moves `account` back to Direct, as leaving a Sync Node does: generation + 1.
    public func switchToDirect(_ account: Account) throws {
        let store = try store()
        let source = try store.mailSource(accountID: account.id)
        _ = try store.replaceMailSource(source.revertedToDirect(), expectedGeneration: source.generation)
    }

    /// An iOS-style runtime: Direct runtime dependencies and no selected account.
    @MainActor
    public func deviceWideRuntime(
        credentials: InMemoryCredentialVault = InMemoryCredentialVault(),
        nodeMail: (any DeviceNodeMailBridging)? = nil
    ) throws -> PlainpostAppRuntime {
        try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                runtimeDependencies: InMemoryAppRuntimeDependencies(credentials: credentials, deviceNodeMail: nodeMail)
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
    }

    private static func account(_ id: String, _ local: String) -> Account {
        Account(
            id: AccountID(id), displayName: local.capitalized, email: EmailAddress("\(local)@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
    }

    private static func makeNodeBacked(_ account: Account, in store: SQLiteMailStore) throws {
        let source = try store.mailSource(accountID: account.id)
        _ = try store.replaceMailSource(source.nodeBacked(
            nodeID: "00112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: account.email.rawValue
        ), expectedGeneration: source.generation)
    }
}
