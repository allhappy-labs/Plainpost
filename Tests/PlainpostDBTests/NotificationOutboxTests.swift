import XCTest
import SQLite3
import PlainpostAccountProtocol
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNotificationRuntime

final class NotificationOutboxTests: XCTestCase {
    func testRevokedConfigurationSuppressesPublicationUntilNewerRestoration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-revoked-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-revoked-direct")
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let plainpost = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x33, count: 32))!
        let rich = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "rich_preview", policyVersion: 1, configRevision: 0,
            producerGeneration: 2, configVersion: "rich"
        )
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: rich), .applied)
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg-before-revoke"), threadID: nil,
                from: EmailAddress("sender@example.com"), subject: "Before revoke", preview: "Before revoke", body: "Before revoke",
                smartCategory: .personal
            ),
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)),
            notificationConfiguration: rich
        )
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'pending'", at: url), 1)
        XCTAssertEqual(try store.revokeNotificationProducerConfigurations(
            plainpostAccountID: plainpost, producerDeviceID: producer,
            retainedLogicalMailboxIDs: []
        ), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'cancelled' AND terminal_reason = 'producer-revoked'", at: url), 1)
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg-revoked-direct"), threadID: nil,
                from: EmailAddress("sender@example.com"), subject: "Revoked", preview: "Revoked", body: "Revoked",
                smartCategory: .personal
            ),
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 2,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)),
            notificationConfiguration: rich
        )
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'pending'", at: url), 0)
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX"))
    }

    func testProducerRevocationCancelsPendingClaimedAndFrozenPublicationsAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-revoke-states-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-revoke-states")
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let configuration = try authoritativeConfiguration(generation: 4, version: "revoke-states")
        try store.updateNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        for uid in 1...3 {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID("msg-revoke-state-\(uid)"), threadID: nil,
                               from: EmailAddress("sender@example.com"), subject: "State \(uid)", preview: "State \(uid)", body: "State \(uid)", smartCategory: .personal),
                metadata: metadata, accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: uid,
                notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)), notificationConfiguration: configuration
            )
        }
        let frozen = try XCTUnwrap(store.claimNotificationPublication(now: Date(), leaseToken: "frozen-lease", leaseDuration: 60))
        let recipient = NotificationRecipientSnapshot(
            recipientID: "ios", routingHandle: Data(repeating: 1, count: 32),
            agreementPublicKey: Data(repeating: 2, count: 65)
        )
        XCTAssertTrue(try store.freezeNotificationPublication(
            publicationID: frozen.publicationID, leaseToken: frozen.leaseToken,
            configVersion: frozen.configVersion, producerGeneration: frozen.producerGeneration,
            recipients: [recipient], envelopeBytes: [Data([3])]
        ))
        _ = try XCTUnwrap(store.claimNotificationPublication(now: Date(), leaseToken: "claimed-lease", leaseDuration: 60))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'pending'", at: url), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'claimed'", at: url), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'frozen'", at: url), 1)

        XCTAssertEqual(try store.revokeNotificationProducerConfigurations(
            plainpostAccountID: configuration.plainpostAccountID!, producerDeviceID: configuration.producerDeviceIDValue!, retainedLogicalMailboxIDs: []
        ), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'cancelled' AND terminal_reason = 'producer-revoked'", at: url), 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE lease_token IS NOT NULL OR lease_expires_at IS NOT NULL", at: url), 0)
    }

    func testPreV53MailboxRowsRemainEligibleAndNonRevokedAfterUpgrade() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-pre-v53-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc-pre-v53")
        let configuration = try authoritativeConfiguration(generation: 3, version: "pre-v53")
        do {
            let initial = try SQLiteMailStore(path: url.path)
            try initial.migrate()
            try initial.cacheAccounts([testAccount(id: accountID.rawValue)])
            try initial.updateNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        }
        // Model a real v52 file: preserve the row while removing only the v53
        // columns and migration marker before reopening through the migrator.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE local_notification_mailboxes DROP COLUMN notification_eligible", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE local_notification_mailboxes DROP COLUMN notification_revoked", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE local_notification_mailboxes DROP COLUMN producer_identity_digest", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE local_notification_mailboxes DROP COLUMN policy_override", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE local_notification_mailboxes DROP COLUMN direct_policy_scope_version", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM grdb_migrations WHERE identifier = 'v53-direct-notification-eligibility'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM grdb_migrations WHERE identifier = 'v54-direct-notification-assignment-identity'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM grdb_migrations WHERE identifier = 'v55-direct-notification-policy-scope'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM grdb_migrations WHERE identifier = 'v56-direct-notification-scope-coordinate'", nil, nil, nil), SQLITE_OK)
        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        XCTAssertEqual(try scalar("SELECT notification_eligible FROM local_notification_mailboxes WHERE account_id = 'acc-pre-v53'", at: url), 1)
        XCTAssertEqual(try scalar("SELECT notification_revoked FROM local_notification_mailboxes WHERE account_id = 'acc-pre-v53'", at: url), 0)
        XCTAssertNotNil(try reopened.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX"))
    }

    func testDirectPolicyScopeMigrationBackfillsLegacyRowsWithoutChangingConfigRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-direct-scope-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc-direct-scope-migration")
        let plainpost = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x39, count: 32))!
        let legacyRich = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "rich_preview", policyVersion: 7, configRevision: 10,
            producerGeneration: 4, configVersion: "legacy-rich"
        )
        do {
            let initial = try SQLiteMailStore(path: url.path)
            try initial.migrate()
            try initial.cacheAccounts([testAccount(id: accountID.rawValue)])
            try initial.updateNotificationProducerConfiguration(
                accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: legacyRich
            )
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE local_notification_mailboxes DROP COLUMN direct_policy_scope_version", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM grdb_migrations WHERE identifier = 'v56-direct-notification-scope-coordinate'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        XCTAssertEqual(try scalar("SELECT direct_policy_scope_version FROM local_notification_mailboxes WHERE account_id = 'acc-direct-scope-migration'", at: url), 0)
        let persisted = try XCTUnwrap(store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX"))
        XCTAssertEqual(persisted.configRevision, 10)
        XCTAssertEqual(persisted.directPolicyScopeVersion, 0)

        let off = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "off", policyVersion: 1, configRevision: 10,
            producerGeneration: 4, configVersion: "legacy-off", policyOverride: true,
            directPolicyScopeVersion: 1
        )
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(
            accountID: accountID, mailboxPath: "INBOX", configuration: off
        ), .applied)
        let offPersisted = try XCTUnwrap(store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX"))
        XCTAssertEqual(offPersisted.policyMode, "off")
        XCTAssertEqual(offPersisted.policyVersion, 1)
        XCTAssertEqual(offPersisted.configRevision, 10)
        XCTAssertEqual(offPersisted.directPolicyScopeVersion, 1)
    }

    func testEqualPolicyCoordinatesConflictEvenWhenAssignmentGenerationAdvances() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-equal-policy-conflict-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-equal-policy-conflict")
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let plainpost = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x3A, count: 32))!
        let off = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "off", policyVersion: 1, configRevision: 1,
            producerGeneration: 5, configVersion: "off", directPolicyScopeVersion: 1
        )
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: off), .applied)
        let newerRich = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "rich_preview", policyVersion: 1, configRevision: 1,
            producerGeneration: 6, configVersion: "rich", directPolicyScopeVersion: 1
        )
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: newerRich), .conflict)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX")?.policyMode, "off")
    }

    func testV55DirectScopeMigrationPreservesScopeAndNormalizesLegacyConfigRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-v55-scope-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc-v55-scope-migration")
        let plainpost = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x3D, count: 32))!
        let v55Off = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "off", policyVersion: 3, configRevision: 3,
            producerGeneration: 4, configVersion: "v55-off", producerIdentityDigest: "v55-identity",
            policyOverride: true
        )
        do {
            let initial = try SQLiteMailStore(path: url.path)
            try initial.migrate()
            try initial.cacheAccounts([testAccount(id: accountID.rawValue)])
            try initial.updateNotificationProducerConfiguration(
                accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: v55Off
            )
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "ALTER TABLE local_notification_mailboxes DROP COLUMN direct_policy_scope_version", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM grdb_migrations WHERE identifier = 'v56-direct-notification-scope-coordinate'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let migrated = try XCTUnwrap(store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX"))
        XCTAssertEqual(migrated.directPolicyScopeVersion, 3)
        XCTAssertEqual(migrated.configRevision, 0)
        XCTAssertEqual(migrated.policyMode, "off")

        let staleRich = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "rich_preview", policyVersion: 1, configRevision: 0,
            producerGeneration: 4, configVersion: "stale-rich", producerIdentityDigest: "v55-identity",
            policyOverride: true, directPolicyScopeVersion: 3
        )
        let staleResult = try store.reconcileNotificationProducerConfiguration(
            accountID: accountID, mailboxPath: "INBOX", configuration: staleRich
        )
        XCTAssertTrue(staleResult == .stale || staleResult == .conflict)
        let message = MessageSummary(
            id: MessageID("msg-v55-off"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "Must stay local",
            preview: "Must stay local", body: "Must stay local", smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)),
            notificationConfiguration: staleRich
        )
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'pending'", at: url), 0)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX")?.policyMode, "off")
    }

    func testOffDurableConfigurationSuppressesPublicationAndStaleCannotRestore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-off-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-off-direct")
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let plainpost = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x32, count: 32))!
        let rich = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "rich_preview", policyVersion: 1, configRevision: 0,
            producerGeneration: 4, configVersion: "rich", directPolicyScopeVersion: 0
        )
        let off = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "off", policyVersion: 1, configRevision: 1,
            producerGeneration: 5, configVersion: "off", directPolicyScopeVersion: 1
        )
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: rich), .applied)
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: off), .applied)
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: rich), .stale)
        let message = MessageSummary(
            id: MessageID("msg-off-direct"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "Must stay local", preview: "Must stay local", body: "Must stay local",
            smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)),
            notificationConfiguration: rich
        )
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications", at: url), 0)
        let persisted = try XCTUnwrap(store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX"))
        XCTAssertEqual(persisted.policyMode, "off")
        XCTAssertEqual(persisted.policyVersion, 1)
        XCTAssertEqual(persisted.configRevision, 1)
    }

    func testConcurrentDirectReconciliationRetainsHighestGenerationAndScope() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-concurrent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-concurrent-direct")
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x31, count: 32))!
        let plainpost = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let initial = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "rich_preview", policyVersion: 1, configRevision: 0,
            producerGeneration: 2, configVersion: "initial", directPolicyScopeVersion: 0
        )
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: initial), .applied)
        let newer = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "sender_subject", policyVersion: 1, configRevision: 1,
            producerGeneration: 4, configVersion: "newer", directPolicyScopeVersion: 1
        )
        let stale = NotificationProducerConfiguration(
            plainpostAccountID: plainpost, logicalMailboxID: logical, producerDeviceID: producer,
            policyMode: "rich_preview", policyVersion: 1, configRevision: 1,
            producerGeneration: 1, configVersion: "stale", directPolicyScopeVersion: 1
        )
        let results = ReconciliationResultCounter()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let result = try? store.reconcileNotificationProducerConfiguration(
                accountID: accountID, mailboxPath: "INBOX",
                configuration: index.isMultiple(of: 2) ? newer : stale
            )
            if let result { results.record(result) }
        }
        XCTAssertEqual(results.applied, 1)
        XCTAssertEqual(results.idempotent, 15)
        XCTAssertEqual(results.stale, 16)
        XCTAssertEqual(results.conflict, 0)
        let final = try XCTUnwrap(store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX"))
        XCTAssertEqual(final.producerGeneration, 4)
        XCTAssertEqual(final.configRevision, 1)
        XCTAssertEqual(final.policyMode, "sender_subject")
        XCTAssertEqual(final.policyVersion, 1)
    }

    func testDirectReconciliationUsesComponentwiseCoordinatesAndRequiresNewerProducerGeneration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-componentwise-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-componentwise-direct")
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let plainpost = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producerA = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let producerB = try AccountDeviceID("00000000-0000-4000-8000-000000000003")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x37, count: 32))!
        func configuration(_ producer: AccountDeviceID, generation: Int64, scope: Int64, policyVersion: Int64, mode: String = "rich_preview", version: String = "cfg") -> NotificationProducerConfiguration {
            NotificationProducerConfiguration(
                plainpostAccountID: plainpost, logicalMailboxID: logical,
                producerDeviceID: producer, policyMode: mode,
                policyVersion: policyVersion, configRevision: 10,
                producerGeneration: generation, configVersion: version,
                directPolicyScopeVersion: scope
            )
        }
        let initial = configuration(producerA, generation: 5, scope: 5, policyVersion: 5)
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", configuration: initial), .applied)

        // A coordinate that advances cannot compensate for another that rolls back.
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(
            accountID: accountID, mailboxPath: "INBOX",
            configuration: configuration(producerA, generation: 6, scope: 6, policyVersion: 4)
        ), .stale)
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(
            accountID: accountID, mailboxPath: "INBOX",
            configuration: configuration(producerA, generation: 6, scope: 4, policyVersion: 6)
        ), .stale)

        // Policy progress alone cannot rotate the producer identity.
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(
            accountID: accountID, mailboxPath: "INBOX",
            configuration: configuration(producerB, generation: 5, scope: 6, policyVersion: 6, version: "rotated")
        ), .conflict)
        XCTAssertEqual(try store.reconcileNotificationProducerConfiguration(
            accountID: accountID, mailboxPath: "INBOX",
            configuration: configuration(producerB, generation: 6, scope: 6, policyVersion: 6, version: "rotated")
        ), .applied)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX")?.producerDeviceIDValue, producerB)
    }

    func testIncomingCommitPublishesOnlyFreshIncrementalInboxMessageAndSuppressesDuplicate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([testAccount(id: "acc-notification")])
        let now = Date()
        let message = MessageSummary(
            id: MessageID("msg-notification"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "New", preview: "New", body: "New",
            smartCategory: .personal
        )
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        let disposition = IncomingNotificationDisposition.candidate(providerArrivalAt: now.addingTimeInterval(-30))
        let configuration = try authoritativeConfiguration(generation: 4, version: "config-a")
        try store.updateNotificationProducerConfiguration(accountID: AccountID("acc-notification"), mailboxPath: "INBOX", uidValidity: 8, configuration: configuration)
        _ = try store.commitIncomingMessage(
            message, metadata: metadata, accountID: AccountID("acc-notification"),
            mailboxPath: "INBOX", uidValidity: 8, uid: 11,
            notificationDisposition: disposition,
            notificationConfiguration: configuration
        )
        _ = try store.commitIncomingMessage(
            message, metadata: metadata, accountID: AccountID("acc-notification"),
            mailboxPath: "INBOX", uidValidity: 8, uid: 11,
            notificationDisposition: disposition,
            notificationConfiguration: configuration
        )
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications", at: url), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_watermarks", at: url), 1)
    }

    func testSyncCommitCannotOverwriteDurableProducerConfiguration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-authority")
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let selected = try authoritativeConfiguration(generation: 7, version: "selected")
        let unselected = try authoritativeConfiguration(generation: 99, version: "unselected")
        try store.updateNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: selected)
        let message = MessageSummary(id: MessageID("msg-authority"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "New", preview: "New", body: "New", smartCategory: .personal)
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        _ = try store.commitIncomingMessage(message, metadata: metadata, accountID: accountID,
            mailboxPath: "INBOX", uidValidity: 1, uid: 10,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)),
            notificationConfiguration: unselected)
        let claim = try XCTUnwrap(store.claimNotificationPublication(now: Date(), leaseToken: "authority", leaseDuration: 60))
        XCTAssertEqual(claim.configVersion, "selected")
        XCTAssertEqual(claim.producerGeneration, 7)
    }

    func testBaselineAndOldOrMissingArrivalEstablishSilence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([testAccount(id: "acc-baseline")])
        let message = MessageSummary(id: MessageID("msg-baseline"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "Old", preview: "Old", smartCategory: .personal)
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        for (uid, disposition) in [
            (1, IncomingNotificationDisposition.establishWatermark),
            (2, IncomingNotificationDisposition.candidate(providerArrivalAt: Date().addingTimeInterval(-16 * 60))),
            (3, IncomingNotificationDisposition.candidate(providerArrivalAt: nil))
        ] {
            _ = try store.commitIncomingMessage(message, metadata: metadata,
                accountID: AccountID("acc-baseline"), mailboxPath: "INBOX", uidValidity: 1, uid: uid,
                notificationDisposition: disposition)
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications", at: url), 0)
        XCTAssertEqual(try scalar("SELECT watermark_uid FROM local_notification_watermarks", at: url), 3)
    }

    func testExpiredPublicationCannotBeClaimedOrPrepared() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc-expired-publication")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let configuration = try authoritativeConfiguration(generation: 1, version: "cfg")
        try store.updateNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        _ = try store.commitIncomingMessage(
            MessageSummary(id: MessageID("msg-expired-publication"), threadID: nil, from: EmailAddress("sender@example.com"), subject: "New", preview: "New", body: "New", smartCategory: .personal),
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)), notificationConfiguration: configuration
        )
        XCTAssertNil(try store.claimNotificationPublication(now: Date().addingTimeInterval(901), leaseToken: "expired", leaseDuration: 60))
    }

    func testExpiredPublicationIsTerminalizedAndDoesNotScheduleWake() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc-expired-wake")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([testAccount(id: accountID.rawValue)])
        let configuration = try authoritativeConfiguration(generation: 1, version: "expired-wake")
        try store.updateNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        _ = try store.commitIncomingMessage(
            MessageSummary(id: MessageID("msg-expired-wake"), threadID: nil, from: EmailAddress("sender@example.com"), subject: "New", preview: "New", body: "New", smartCategory: .personal),
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)), notificationConfiguration: configuration
        )

        let now = Date().addingTimeInterval(901)
        XCTAssertNil(try store.nextWorkDate(now: now))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_publications WHERE state = 'cancelled' AND terminal_reason = 'expired'", at: url), 1)
    }

    func testFreezeUsesLeaseAndConfigGenerationCASAndDeliveryRetainsExactBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([testAccount(id: "acc-freeze")])
        let message = MessageSummary(id: MessageID("msg-freeze"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "New", preview: "New", smartCategory: .personal)
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        let configuration = try authoritativeConfiguration(generation: 9, version: "cfg")
        try store.updateNotificationProducerConfiguration(accountID: AccountID("acc-freeze"), mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        _ = try store.commitIncomingMessage(message, metadata: metadata, accountID: AccountID("acc-freeze"),
            mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)),
            notificationConfiguration: configuration)
        let claim = try XCTUnwrap(store.claimNotificationPublication(now: Date(), leaseToken: "lease-a", leaseDuration: 60))
        XCTAssertFalse(try store.freezeNotificationPublication(publicationID: claim.publicationID, leaseToken: "wrong",
            configVersion: "cfg", producerGeneration: 9,
            recipients: [NotificationRecipientSnapshot(recipientID: "ios", routingHandle: Data(repeating: 1, count: 32), agreementPublicKey: Data(repeating: 2, count: 65))],
            envelopeBytes: [Data([3, 4])]))
        XCTAssertTrue(try store.freezeNotificationPublication(publicationID: claim.publicationID, leaseToken: "lease-a",
            configVersion: "cfg", producerGeneration: 9,
            recipients: [NotificationRecipientSnapshot(recipientID: "ios", routingHandle: Data(repeating: 1, count: 32), agreementPublicKey: Data(repeating: 2, count: 65))],
            envelopeBytes: [Data([3, 4])]))
        XCTAssertTrue(try store.recordNotificationDeliveryOutcome(publicationID: claim.publicationID, leaseToken: "lease-a",
            recipientID: "ios", outcome: .accepted, nextAttemptAt: nil))
        XCTAssertEqual(try scalar("SELECT length(envelope_bytes) FROM local_notification_deliveries", at: url), 2)
    }

    func testRetryReopenReclaimsFrozenBytesWithoutRegeneratingRecipients() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc-reopen-retry")
        let configuration = try authoritativeConfiguration(generation: 9, version: "cfg")
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        let message = MessageSummary(id: MessageID("msg-reopen-retry"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "New", preview: "New", smartCategory: .personal)
        let retryAt = Date().addingTimeInterval(2)
        var store: SQLiteMailStore? = try SQLiteMailStore(path: url.path)
        try store?.migrate()
        try store?.cacheAccounts([testAccount(id: accountID.rawValue)])
        try store?.updateNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        _ = try store?.commitIncomingMessage(message, metadata: metadata, accountID: accountID,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)), notificationConfiguration: configuration)
        let firstClaim = try XCTUnwrap(store?.claimNotificationPublication(now: Date(), leaseToken: "lease-a", leaseDuration: 60))
        let recipient = NotificationRecipientSnapshot(recipientID: "ios", routingHandle: Data(repeating: 1, count: 32), agreementPublicKey: Data(repeating: 2, count: 65))
        XCTAssertTrue(try store?.freezeNotificationPublication(publicationID: firstClaim.publicationID, leaseToken: firstClaim.leaseToken,
            configVersion: configuration.configVersion, producerGeneration: configuration.producerGeneration,
            recipients: [recipient], envelopeBytes: [Data([0xA1, 0xB2])]) == true)
        XCTAssertTrue(try store?.recordNotificationDeliveryOutcome(publicationID: firstClaim.publicationID, leaseToken: firstClaim.leaseToken,
            recipientID: recipient.recipientID, outcome: .retryable, nextAttemptAt: retryAt) == true)
        store = nil

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        XCTAssertNil(try reopened.claimNotificationPublication(now: retryAt.addingTimeInterval(-0.5), leaseToken: "too-early", leaseDuration: 60))
        let resumed = try XCTUnwrap(reopened.claimNotificationPublication(now: retryAt.addingTimeInterval(0.5), leaseToken: "lease-b", leaseDuration: 60))
        XCTAssertTrue(resumed.resumesFrozenPublication)
        let deliveries = try reopened.claimDeliveries(publicationID: resumed.publicationID, leaseToken: resumed.leaseToken,
            limit: 16, now: retryAt.addingTimeInterval(0.5))
        XCTAssertEqual(deliveries.map(\.envelopeBytes), [Data([0xA1, 0xB2])])
        XCTAssertEqual(deliveries.map(\.recipientID), ["ios"])
    }

    func testRetryReopenDrainUsesPersistedBytesWithoutCallingProducer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc-reopen-drain")
        let configuration = try authoritativeConfiguration(generation: 9, version: "cfg")
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        var store: SQLiteMailStore? = try SQLiteMailStore(path: url.path)
        try store?.migrate()
        try store?.cacheAccounts([testAccount(id: accountID.rawValue)])
        try store?.updateNotificationProducerConfiguration(accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        _ = try store?.commitIncomingMessage(
            MessageSummary(id: MessageID("msg-reopen-drain"), threadID: nil, from: EmailAddress("sender@example.com"), subject: "New", preview: "New", smartCategory: .personal),
            metadata: metadata, accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)), notificationConfiguration: configuration
        )
        let claim = try XCTUnwrap(store?.claimNotificationPublication(now: Date(), leaseToken: "lease-a", leaseDuration: 60))
        let recipient = NotificationRecipientSnapshot(recipientID: "ios", routingHandle: Data(repeating: 1, count: 32), agreementPublicKey: Data(repeating: 2, count: 65))
        let frozenBytes = Data([0xA1, 0xB2])
        XCTAssertTrue(try store?.freezeNotificationPublication(publicationID: claim.publicationID, leaseToken: claim.leaseToken, configVersion: configuration.configVersion, producerGeneration: configuration.producerGeneration, recipients: [recipient], envelopeBytes: [frozenBytes]) == true)
        let retryAt = Date().addingTimeInterval(1)
        XCTAssertTrue(try store?.recordNotificationDeliveryOutcome(publicationID: claim.publicationID, leaseToken: claim.leaseToken, recipientID: recipient.recipientID, outcome: .retryable, nextAttemptAt: retryAt) == true)
        store = nil

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        let failingProducer = NotificationProducer(coordination: FailingNotificationCoordination(), verifier: FailingNotificationVerifier(), previewBuilder: FailingNotificationPreviewBuilder())
        let relay = RecordingNotificationRelay()
        let drain = NotificationDrain(store: reopened, producer: failingProducer, relay: relay, dateProvider: { retryAt.addingTimeInterval(1) })
        _ = try await drain.drain()
        let relayedBytes = await relay.bytes()
        XCTAssertEqual(relayedBytes, [frozenBytes])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM local_notification_deliveries WHERE outcome = 'accepted'", at: url), 1)
    }

    func testExpiredLeaseCannotRecordOutcomeAndSevenDayCleanupRemovesTerminalRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-notification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([testAccount(id: "acc-expired")])
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [])
        let configuration = try authoritativeConfiguration(generation: 2, version: "default")
        try store.updateNotificationProducerConfiguration(accountID: AccountID("acc-expired"), mailboxPath: "INBOX", uidValidity: 1, configuration: configuration)
        let message = MessageSummary(id: MessageID("msg-expired"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "New", preview: "New", smartCategory: .personal)
        _ = try store.commitIncomingMessage(message, metadata: metadata, accountID: AccountID("acc-expired"),
            mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationDisposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)), notificationConfiguration: configuration)
        let claim = try XCTUnwrap(store.claimNotificationPublication(now: Date(), leaseToken: "lease-expired", leaseDuration: -1))
        XCTAssertFalse(try store.freezeNotificationPublication(publicationID: claim.publicationID, leaseToken: claim.leaseToken,
            configVersion: claim.configVersion, producerGeneration: claim.producerGeneration,
            recipients: [NotificationRecipientSnapshot(recipientID: "ios", routingHandle: Data(repeating: 1, count: 32), agreementPublicKey: Data(repeating: 2, count: 65))],
            envelopeBytes: [Data([3])]))
        XCTAssertFalse(try store.recordNotificationDeliveryOutcome(publicationID: claim.publicationID, leaseToken: claim.leaseToken,
            recipientID: "ios", outcome: .accepted, nextAttemptAt: nil))
        XCTAssertEqual(try store.cleanupNotificationPublications(olderThan: Date().addingTimeInterval(1)), 0)
        let freshClaim = try XCTUnwrap(store.claimNotificationPublication(now: Date(), leaseToken: "lease-new", leaseDuration: 60))
        XCTAssertTrue(try store.cancelNotificationPublication(publicationID: freshClaim.publicationID, leaseToken: "lease-new",
            configVersion: freshClaim.configVersion, producerGeneration: freshClaim.producerGeneration))
        XCTAssertEqual(try store.cleanupNotificationPublications(olderThan: Date().addingTimeInterval(1)), 1)
    }

    private func scalar(_ sql: String, at url: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NSError(domain: "sqlite", code: 2) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "sqlite", code: 3) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func authoritativeConfiguration(generation: Int64, version: String) throws -> NotificationProducerConfiguration {
        NotificationProducerConfiguration(
            plainpostAccountID: try PlainpostAccountID("00000000-0000-4000-8000-000000000001"),
            logicalMailboxID: LogicalMailboxID(rawValue: Data(repeating: 3, count: 32))!,
            producerDeviceID: try AccountDeviceID("00000000-0000-4000-8000-000000000002"),
            policyVersion: 1, configRevision: 1, producerGeneration: generation, configVersion: version
        )
    }

    private func testAccount(id: String) -> Account {
        Account(
            id: AccountID(id), displayName: "Notification Test",
            email: EmailAddress("notification-\(id)@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
    }
}

private final class ReconciliationResultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SQLiteMailStore.NotificationProducerConfigurationReconciliationResult: Int] = [:]

    func record(_ value: SQLiteMailStore.NotificationProducerConfigurationReconciliationResult) {
        lock.lock()
        values[value, default: 0] += 1
        lock.unlock()
    }

    var applied: Int { count(.applied) }
    var idempotent: Int { count(.idempotent) }
    var stale: Int { count(.stale) }
    var conflict: Int { count(.conflict) }

    private func count(_ value: SQLiteMailStore.NotificationProducerConfigurationReconciliationResult) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[value, default: 0]
    }
}

private struct FailingNotificationCoordination: CoordinationClient {
    func recipientAssignment(for _: NotificationPublicationSource, claim _: NotificationPublicationClaim) async throws -> NotificationRecipientAssignment { XCTFail("producer must not be called on frozen retry"); throw NotificationRuntimeError.unavailable }
}

private struct FailingNotificationVerifier: RecipientAssignmentVerifying {
    func verify(assignment _: NotificationRecipientAssignment, source _: NotificationPublicationSource) throws { XCTFail("verifier must not be called on frozen retry") }
}

private struct FailingNotificationPreviewBuilder: NotificationPreviewBuilder {
    func envelope(for _: NotificationPublicationSource, claim _: NotificationPublicationClaim, recipient _: NotificationRecipientSnapshot) throws -> Data { XCTFail("preview must not be called on frozen retry"); throw NotificationRuntimeError.unavailable }
}

private actor RecordingNotificationRelay: RelayClient {
    private var values: [Data] = []
    func deliver(_ delivery: NotificationDeliveryClaim) async throws -> NotificationRelayResult { values.append(delivery.envelopeBytes); return NotificationRelayResult(outcome: .accepted) }
    func bytes() -> [Data] { values }
}
