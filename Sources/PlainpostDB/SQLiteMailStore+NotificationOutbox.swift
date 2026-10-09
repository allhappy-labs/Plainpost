import CryptoKit
import Foundation
import GRDB
import PlainpostAccountProtocol
import PlainpostCore

extension SQLiteMailStore {
    public enum NotificationProducerConfigurationReconciliationResult: Sendable, Equatable {
        case applied
        case idempotent
        case stale
        case conflict
    }

    /// Reads the durable producer coordinate without manufacturing authority
    /// from a mailbox path. Malformed rows are treated as unconfigured so a
    /// service restart cannot publish using partially-corrupt state.
    public func notificationProducerConfiguration(
        accountID: AccountID,
        mailboxPath: String
    ) throws -> NotificationProducerConfiguration? {
        return try databasePool.read { database -> NotificationProducerConfiguration? in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT plainpost_account_id, logical_mailbox_id_bytes,
                           selected_producer_device_id, selected_producer_kind,
                           policy_mode, policy_version, config_revision,
                           direct_policy_scope_version,
                           config_version, producer_generation,
                           producer_identity_digest, policy_override,
                           notification_eligible, notification_revoked
                    FROM local_notification_mailboxes
                    WHERE account_id = ? AND mailbox_path = ?
                    """,
                arguments: [accountID.rawValue, mailboxPath]
            ) else { return nil }
            guard let plainpostAccountID = try? PlainpostAccountID(row["plainpost_account_id"]),
                  let logicalBytes = row["logical_mailbox_id_bytes"] as Data?,
                  let logicalMailboxID = LogicalMailboxID(rawValue: logicalBytes),
                  logicalBytes.contains(where: { $0 != 0 }),
                  let producerRaw = row["selected_producer_device_id"] as String?,
                  let producerDeviceID = try? AccountDeviceID(producerRaw),
                  (row["selected_producer_kind"] as String) == "mac",
                  let policyMode = row["policy_mode"] as String?,
                  let policyVersion = row["policy_version"] as Int64?,
                  let configRevision = row["config_revision"] as Int64?,
                  let directPolicyScopeVersion = row["direct_policy_scope_version"] as Int64?,
                  let configVersion = row["config_version"] as String?,
                  let producerGeneration = row["producer_generation"] as Int64?,
                  let eligible = row["notification_eligible"] as Int64?,
                  let revoked = row["notification_revoked"] as Int64?,
                  eligible == 1, revoked == 0,
                  policyVersion > 0, producerGeneration > 0 else { return nil }
            return NotificationProducerConfiguration(
                plainpostAccountID: plainpostAccountID,
                logicalMailboxID: logicalMailboxID,
                producerDeviceID: producerDeviceID,
                producerKind: "mac",
                policyMode: policyMode,
                policyVersion: policyVersion,
                configRevision: configRevision,
                producerGeneration: producerGeneration,
                configVersion: configVersion,
                producerIdentityDigest: row["producer_identity_digest"] as String?,
                policyOverride: (row["policy_override"] as Int64?).map { $0 != 0 },
                directPolicyScopeVersion: directPolicyScopeVersion
            )
        }
    }

    /// Reads a durable producer binding for reconciliation, including rows
    /// that are currently revoked. Runtime publication readers intentionally
    /// hide those rows; reconciliation must still be able to restore every
    /// provider-local account/path without guessing a new binding.
    public func notificationProducerConfigurationForReconciliation(
        accountID: AccountID,
        mailboxPath: String
    ) throws -> NotificationProducerConfiguration? {
        try databasePool.read { database -> NotificationProducerConfiguration? in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT plainpost_account_id, logical_mailbox_id_bytes,
                           selected_producer_device_id, selected_producer_kind,
                           policy_mode, policy_version, config_revision,
                           direct_policy_scope_version,
                           config_version, producer_generation, producer_identity_digest, policy_override
                    FROM local_notification_mailboxes
                    WHERE account_id = ? AND mailbox_path = ?
                    """,
                arguments: [accountID.rawValue, mailboxPath]
            ) else { return nil }
            guard let plainpostAccountID = try? PlainpostAccountID(row["plainpost_account_id"]),
                  let logicalBytes = row["logical_mailbox_id_bytes"] as Data?,
                  let logicalMailboxID = LogicalMailboxID(rawValue: logicalBytes),
                  logicalBytes.contains(where: { $0 != 0 }),
                  let producerRaw = row["selected_producer_device_id"] as String?,
                  let producerDeviceID = try? AccountDeviceID(producerRaw),
                  (row["selected_producer_kind"] as String) == "mac",
                  let policyMode = row["policy_mode"] as String?,
                  let policyVersion = row["policy_version"] as Int64?,
                  let configRevision = row["config_revision"] as Int64?,
                  let directPolicyScopeVersion = row["direct_policy_scope_version"] as Int64?,
                  let configVersion = row["config_version"] as String?,
                  let producerGeneration = row["producer_generation"] as Int64?,
                  policyVersion > 0, producerGeneration > 0 else { return nil }
            return NotificationProducerConfiguration(
                plainpostAccountID: plainpostAccountID,
                logicalMailboxID: logicalMailboxID,
                producerDeviceID: producerDeviceID,
                producerKind: "mac",
                policyMode: policyMode,
                policyVersion: policyVersion,
                configRevision: configRevision,
                producerGeneration: producerGeneration,
                configVersion: configVersion,
                producerIdentityDigest: row["producer_identity_digest"] as String?,
                policyOverride: (row["policy_override"] as Int64?).map { $0 != 0 },
                directPolicyScopeVersion: directPolicyScopeVersion
            )
        }
    }

    /// Counts unread, non-deleted messages in one account/mailbox scope for
    /// the PPN2 badge.  This stays in SQLite so the value cannot include a
    /// different account or a mailbox outside the publication's scope.
    public func unreadNotificationCount(accountID: AccountID, mailboxPath: String) throws -> Int {
        return try databasePool.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM mailbox_messages AS membership
                    JOIN messages AS message ON message.id = membership.message_id
                    WHERE membership.account_id = ?
                      AND membership.mailbox_path = ?
                      AND message.is_seen = 0
                      AND message.is_deleted = 0
                    """,
                arguments: [accountID.rawValue, mailboxPath]
            ) ?? 0
        }
    }

    /// Compares and updates one producer configuration while holding the
    /// SQLite writer transaction. Assignment generation and the Direct
    /// policy coordinate are both monotonic; a stale or conflicting attempt
    /// cannot overwrite a newer durable authority.
    public func reconcileNotificationProducerConfiguration(
        accountID: AccountID,
        mailboxPath: String,
        configuration: NotificationProducerConfiguration
    ) throws -> NotificationProducerConfigurationReconciliationResult {
        guard let plainpostAccountID = configuration.plainpostAccountID,
              let producerDeviceID = configuration.producerDeviceIDValue,
              configuration.logicalMailboxIDBytes.count == 32,
              configuration.logicalMailboxIDBytes.contains(where: { $0 != 0 }),
              configuration.producerKind == "mac",
              configuration.policyVersion > 0,
              configuration.configRevision >= 0,
              configuration.directPolicyScopeVersion >= 0,
              configuration.producerGeneration > 0,
              !configuration.policyMode.isEmpty,
              !configuration.configVersion.isEmpty else {
            throw PlainpostError.validationFailed("Notification producer configuration is not authoritative.")
        }

        return try databasePool.write { database in
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT plainpost_account_id, logical_mailbox_id_bytes,
                           selected_producer_device_id, selected_producer_kind,
                           policy_mode, policy_version, config_revision,
                           direct_policy_scope_version,
                           config_version, producer_generation, producer_identity_digest, policy_override
                           , notification_eligible, notification_revoked
                    FROM local_notification_mailboxes
                    WHERE account_id = ? AND mailbox_path = ?
                    """,
                arguments: [accountID.rawValue, mailboxPath]
            )

            if let row {
                let storedPlainpost = row["plainpost_account_id"] as String?
                let storedBytes = row["logical_mailbox_id_bytes"] as Data?
                let storedPolicyVersion = row["policy_version"] as Int64?
                let storedScopeVersion = row["direct_policy_scope_version"] as Int64?
                let storedGeneration = row["producer_generation"] as Int64?
                let storedProducerIdentity = row["producer_identity_digest"] as String?
                let hasZeroLogicalAuthority = storedBytes?.count == 32 &&
                    !(storedBytes?.contains(where: { $0 != 0 }) ?? true) &&
                    (storedPolicyVersion ?? 0) == 0 &&
                    (storedScopeVersion ?? 0) == 0 &&
                    (storedGeneration ?? 0) == 0
                let isUnconfigured = hasZeroLogicalAuthority
                if isUnconfigured {
                    try upsertConfigurationRow(
                        database: database, accountID: accountID, mailboxPath: mailboxPath,
                        configuration: configuration
                    )
                    return .applied
                }
                // A revoked row of this Plainpost account bound to another logical mailbox
                // (the matching key rotated, say) takes a newer authoritative binding: its monotonic coordinates belong
                // to the old mailbox, and its pending publications were cancelled with it.
                if (row["notification_revoked"] as Int64?) == 1,
                   storedPlainpost == plainpostAccountID.rawValue,
                   storedBytes != configuration.logicalMailboxIDBytes {
                    return try updateConfigurationRow(
                        database: database, accountID: accountID, mailboxPath: mailboxPath,
                        configuration: configuration
                    )
                }
                guard let storedPlainpost, !storedPlainpost.isEmpty else {
                    return .conflict
                }
                guard storedPlainpost == plainpostAccountID.rawValue,
                      let storedBytes,
                      storedBytes.count == 32,
                      storedBytes.contains(where: { $0 != 0 }),
                      storedBytes == configuration.logicalMailboxIDBytes,
                      (row["selected_producer_kind"] as String?) == configuration.producerKind,
                      let storedPolicyMode = row["policy_mode"] as String?,
                      let storedPolicyVersion = row["policy_version"] as Int64?,
               let storedScopeVersion = row["direct_policy_scope_version"] as Int64?,
               let storedConfigVersion = row["config_version"] as String?,
               let storedGeneration = row["producer_generation"] as Int64?,
               storedPolicyVersion > 0,
               storedScopeVersion >= 0,
               storedGeneration > 0 else {
                    return .conflict
                }
                let storedEligible = (row["notification_eligible"] as Int64?) ?? 1
                let storedRevoked = (row["notification_revoked"] as Int64?) ?? 0
                let sameProducer = (row["selected_producer_device_id"] as String?) == producerDeviceID.rawValue
                let sameAssignmentIdentity = storedProducerIdentity == configuration.producerIdentityDigest &&
                    storedProducerIdentity != nil && configuration.producerIdentityDigest != nil
                let generationHigher = configuration.producerGeneration > storedGeneration
                let scopeHigher = configuration.directPolicyScopeVersion > storedScopeVersion
                let policyHigher = configuration.policyVersion > storedPolicyVersion
                let allowsScopedPolicyReset = scopeHigher && configuration.policyOverride != nil
                let hasLowerCoordinate = configuration.producerGeneration < storedGeneration ||
                    configuration.directPolicyScopeVersion < storedScopeVersion ||
                    (configuration.policyVersion < storedPolicyVersion && !allowsScopedPolicyReset)
                guard !hasLowerCoordinate else { return .stale }

                let storedPolicyOverride = (row["policy_override"] as Int64?).map { $0 != 0 } ?? false
                let incomingPolicyOverride = configuration.policyOverride ?? false
                let policyValueChanged = configuration.policyMode != storedPolicyMode ||
                    incomingPolicyOverride != storedPolicyOverride
                if !scopeHigher && !policyHigher && policyValueChanged {
                    return .conflict
                }

                if !sameProducer {
                    // A producer identity change is authorized only by a
                    // strictly newer assignment generation. Policy progress
                    // alone must never replace the selected producer.
                    guard generationHigher else { return .conflict }
                    return try updateConfigurationRow(database: database, accountID: accountID, mailboxPath: mailboxPath, configuration: configuration)
                }

                // Trust/device identity is a separate monotonic component
                // from policy. A policy advance cannot rotate assignment
                // trust material at the same assignment generation.
                if !sameAssignmentIdentity,
                   storedProducerIdentity != nil,
                   configuration.producerIdentityDigest != nil {
                    guard generationHigher else { return .conflict }
                }

                if !generationHigher && !scopeHigher && !policyHigher {
                    guard configuration.policyMode == storedPolicyMode else { return .conflict }
                    guard configuration.configVersion == storedConfigVersion else { return .conflict }
                    return storedRevoked != 0 || storedEligible != 1 ? .stale : .idempotent
                }

                return try updateConfigurationRow(database: database, accountID: accountID, mailboxPath: mailboxPath, configuration: configuration)
            }

            try upsertConfigurationRow(
                database: database, accountID: accountID, mailboxPath: mailboxPath,
                configuration: configuration
            )
            return .applied
        }
    }

    private func updateConfigurationRow(
        database: Database,
        accountID: AccountID,
        mailboxPath: String,
        configuration: NotificationProducerConfiguration
    ) throws -> NotificationProducerConfigurationReconciliationResult {
        try database.execute(
            sql: """
                UPDATE local_notification_mailboxes SET
                    plainpost_account_id = ?, logical_mailbox_id = ?,
                    logical_mailbox_id_bytes = ?, selected_producer_device_id = ?,
                    selected_producer_kind = ?, policy_mode = ?, policy_version = ?,
                    config_revision = ?, direct_policy_scope_version = ?,
                    config_version = ?, producer_generation = ?,
                    producer_identity_digest = ?,
                    policy_override = ?,
                    notification_eligible = 1, notification_revoked = 0,
                    updated_at = ?
                WHERE account_id = ? AND mailbox_path = ?
                """,
            arguments: [configuration.plainpostAccountID?.rawValue,
                        configuration.logicalMailboxID, configuration.logicalMailboxIDBytes,
                        configuration.producerDeviceIDValue?.rawValue,
                        configuration.producerKind, configuration.policyMode,
                        configuration.policyVersion, configuration.configRevision,
                        configuration.directPolicyScopeVersion,
                        configuration.configVersion, configuration.producerGeneration,
                        configuration.producerIdentityDigest,
                        configuration.policyOverride.map { $0 ? 1 : 0 },
                        Date().timeIntervalSince1970, accountID.rawValue, mailboxPath]
        )
        return .applied
    }

    /// Revokes every previously configured Mac mailbox for the authenticated
    /// Plainpost account that is absent from the trustworthy assignment set.
    /// The durable identity and monotonic high-water remain for fail-closed
    /// restoration by a newer valid assignment/policy.
    @discardableResult
    public func revokeNotificationProducerConfigurations(
        plainpostAccountID: PlainpostAccountID,
        producerDeviceID: AccountDeviceID,
        retainedLogicalMailboxIDs: Set<LogicalMailboxID>
    ) throws -> Int {
        try databasePool.write { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT account_id, mailbox_path, logical_mailbox_id_bytes,
                           selected_producer_device_id
                    FROM local_notification_mailboxes
                    WHERE plainpost_account_id = ? AND selected_producer_kind = 'mac'
                    """,
                arguments: [plainpostAccountID.rawValue]
            )
            var revoked = 0
            for row in rows {
                let logicalBytes = row["logical_mailbox_id_bytes"] as Data?
                let selectedProducer = row["selected_producer_device_id"] as String?
                let logicalMailboxID = logicalBytes.flatMap(LogicalMailboxID.init(rawValue:))
                let retained = selectedProducer == producerDeviceID.rawValue &&
                    logicalMailboxID.map(retainedLogicalMailboxIDs.contains) == true
                guard !retained else {
                    continue
                }
                try database.execute(
                    sql: """
                        UPDATE local_notification_mailboxes
                        SET notification_eligible = 0, notification_revoked = 1,
                            updated_at = ?
                        WHERE account_id = ? AND mailbox_path = ?
                    """,
                    arguments: [Date().timeIntervalSince1970, row["account_id"], row["mailbox_path"]]
                )
                try database.execute(
                    sql: """
                        UPDATE local_notification_publications
                        SET state = 'cancelled', terminal_reason = 'producer-revoked',
                            lease_token = NULL, lease_expires_at = NULL,
                            updated_at = ?
                        WHERE account_id = ? AND mailbox_path = ?
                          AND state IN ('pending', 'claimed', 'frozen')
                        """,
                    arguments: [Date().timeIntervalSince1970, row["account_id"], row["mailbox_path"]]
                )
                revoked += 1
            }
            return revoked
        }
    }

    private func upsertConfigurationRow(
        database: Database,
        accountID: AccountID,
        mailboxPath: String,
        configuration: NotificationProducerConfiguration
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO local_notification_mailboxes (
                    account_id, plainpost_account_id, mailbox_path, logical_mailbox_id,
                    logical_mailbox_id_bytes, uid_validity, selected_producer_device_id,
                    selected_producer_kind, policy_mode, policy_version, config_revision,
                    direct_policy_scope_version,
                    config_version, producer_generation, notification_eligible,
                    notification_revoked, producer_identity_digest, policy_override, baseline_complete, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, 0, ?)
                ON CONFLICT(account_id, mailbox_path) DO UPDATE SET
                    plainpost_account_id = excluded.plainpost_account_id,
                    logical_mailbox_id = excluded.logical_mailbox_id,
                    logical_mailbox_id_bytes = excluded.logical_mailbox_id_bytes,
                    selected_producer_device_id = excluded.selected_producer_device_id,
                    selected_producer_kind = excluded.selected_producer_kind,
                    policy_mode = excluded.policy_mode,
                    policy_version = excluded.policy_version,
                    config_revision = excluded.config_revision,
                    direct_policy_scope_version = excluded.direct_policy_scope_version,
                    config_version = excluded.config_version,
                    producer_generation = excluded.producer_generation,
                    producer_identity_digest = excluded.producer_identity_digest,
                    policy_override = excluded.policy_override,
                    notification_eligible = 1,
                    notification_revoked = 0,
                    updated_at = excluded.updated_at
                """,
            arguments: [accountID.rawValue, configuration.plainpostAccountID?.rawValue,
                        mailboxPath, configuration.logicalMailboxID,
                        configuration.logicalMailboxIDBytes, 0,
                        configuration.producerDeviceIDValue?.rawValue,
                        configuration.producerKind, configuration.policyMode,
                        configuration.policyVersion, configuration.configRevision,
                        configuration.directPolicyScopeVersion,
                        configuration.configVersion, configuration.producerGeneration,
                        configuration.producerIdentityDigest,
                        configuration.policyOverride.map { $0 ? 1 : 0 }, Date().timeIntervalSince1970]
        )
    }

    /// Installs the selected producer/configuration authority. Sync commits
    /// never overwrite these fields; they only read this durable snapshot.
    public func updateNotificationProducerConfiguration(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        configuration: NotificationProducerConfiguration
    ) throws {
        guard let plainpostAccountID = configuration.plainpostAccountID,
              let producerDeviceID = configuration.producerDeviceIDValue,
              configuration.logicalMailboxIDBytes.count == 32,
              configuration.logicalMailboxIDBytes.contains(where: { $0 != 0 }),
              configuration.producerKind == "mac",
              configuration.producerGeneration > 0,
              configuration.policyVersion > 0 else {
            throw PlainpostError.validationFailed("Notification producer configuration is not authoritative.")
        }
        try databasePool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_notification_mailboxes (
                        account_id, plainpost_account_id, mailbox_path, logical_mailbox_id,
                        logical_mailbox_id_bytes, uid_validity, selected_producer_device_id,
                    selected_producer_kind, policy_mode, policy_version, config_revision,
                    direct_policy_scope_version,
                    config_version, producer_generation, notification_eligible,
                    notification_revoked, producer_identity_digest, policy_override, baseline_complete, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, 0, ?)
                    ON CONFLICT(account_id, mailbox_path) DO UPDATE SET
                        plainpost_account_id = excluded.plainpost_account_id,
                        logical_mailbox_id = excluded.logical_mailbox_id,
                        logical_mailbox_id_bytes = excluded.logical_mailbox_id_bytes,
                        selected_producer_device_id = excluded.selected_producer_device_id,
                        selected_producer_kind = excluded.selected_producer_kind,
                        policy_mode = excluded.policy_mode,
                        policy_version = excluded.policy_version,
                    config_revision = excluded.config_revision,
                    direct_policy_scope_version = excluded.direct_policy_scope_version,
                        config_version = excluded.config_version,
                        producer_generation = excluded.producer_generation,
                        producer_identity_digest = excluded.producer_identity_digest,
                        policy_override = excluded.policy_override,
                        notification_eligible = 1,
                        notification_revoked = 0,
                        updated_at = excluded.updated_at
                    """,
                arguments: [accountID.rawValue, plainpostAccountID.rawValue, mailboxPath,
                            configuration.logicalMailboxID, configuration.logicalMailboxIDBytes,
                            uidValidity, producerDeviceID.rawValue, configuration.producerKind,
                            configuration.policyMode, configuration.policyVersion,
                            configuration.configRevision, configuration.directPolicyScopeVersion,
                            configuration.configVersion,
                            configuration.producerGeneration, configuration.producerIdentityDigest,
                            configuration.policyOverride.map { $0 ? 1 : 0 }, Date().timeIntervalSince1970]
            )
        }
    }

    public func source(for publicationID: String) throws -> NotificationPublicationSource? {
        try databasePool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, account_id, plainpost_account_id, message_id, mailbox_path,
                           logical_mailbox_id, logical_mailbox_id_bytes, thread_id, uid_validity, uid, provider_arrival_at,
                           config_version, producer_generation
                    FROM local_notification_publications WHERE id = ?
                    """,
                arguments: [publicationID]
            ) else { return nil }
            return NotificationPublicationSource(
                publicationID: row["id"], accountID: AccountID(row["account_id"]),
                messageID: MessageID(row["message_id"]), mailboxPath: row["mailbox_path"],
                uidValidity: row["uid_validity"], uid: row["uid"],
                providerArrivalAt: (row["provider_arrival_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                plainpostAccountID: AccountID(row["plainpost_account_id"]),
                logicalMailboxID: row["logical_mailbox_id"],
                logicalMailboxIDBytes: row["logical_mailbox_id_bytes"],
                threadID: (row["thread_id"] as String?).map { ThreadID($0) },
                configVersion: row["config_version"],
                producerGeneration: row["producer_generation"]
            )
        }
    }

    public func claimDeliveries(
        publicationID: String,
        leaseToken: String,
        limit: Int,
        now: Date
    ) throws -> [NotificationDeliveryClaim] {
        try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT d.publication_id, d.recipient_id, d.routing_handle,
                           d.agreement_public_key, d.envelope_bytes, d.producer_device_id,
                           d.producer_generation, d.policy_version, d.replay_id,
                           d.collapse_digest, d.envelope_digest, d.lease_token,
                           d.lease_expires_at
                    FROM local_notification_deliveries d
                    WHERE publication_id = ? AND (outcome IS NULL OR outcome = 'retryable')
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                      AND EXISTS (
                          SELECT 1 FROM local_notification_publications
                          WHERE id = ? AND state IN ('claimed', 'frozen') AND lease_token = ? AND lease_expires_at > ?
                      )
                    ORDER BY recipient_id LIMIT ?
                    """,
                arguments: [publicationID, now.timeIntervalSince1970, publicationID, leaseToken, now.timeIntervalSince1970, max(0, limit)]
            ).map { row in
                NotificationDeliveryClaim(
                    publicationID: row["publication_id"], recipientID: row["recipient_id"],
                    routingHandle: row["routing_handle"], agreementPublicKey: row["agreement_public_key"],
                    envelopeBytes: row["envelope_bytes"], producerDeviceID: row["producer_device_id"],
                    producerGeneration: row["producer_generation"], policyVersion: row["policy_version"],
                    replayID: row["replay_id"], collapseDigest: row["collapse_digest"],
                    envelopeDigest: row["envelope_digest"], leaseToken: row["lease_token"],
                    leaseExpiresAt: (row["lease_expires_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    public func nextWorkDate(now: Date) throws -> Date? {
        // Expiry is a terminal local decision.  Marking rows here prevents an
        // expired publication from keeping the background wake scheduler
        // alive forever, while the claim query remains independently fenced.
        try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE local_notification_publications
                    SET state = 'cancelled', terminal_reason = 'expired',
                        lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                    WHERE expires_at <= ? AND state IN ('pending', 'claimed', 'frozen')
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]
            )
        }
        return try databasePool.read { database in
            let value: Double? = try Double.fetchOne(
                database,
                sql: """
                    SELECT MIN(CASE
                        WHEN state = 'pending' THEN COALESCE(
                            (SELECT MIN(next_attempt_at) FROM local_notification_deliveries d
                             WHERE d.publication_id = p.id AND d.outcome = 'retryable'), created_at)
                        WHEN state = 'claimed' THEN lease_expires_at
                        WHEN state = 'frozen' THEN COALESCE(
                            (SELECT MIN(next_attempt_at) FROM local_notification_deliveries d
                             WHERE d.publication_id = p.id AND d.outcome = 'retryable'),
                            lease_expires_at)
                        END)
                    FROM local_notification_publications p
                    WHERE state IN ('pending', 'claimed', 'frozen')
                    """
            )
            return value.map(Date.init(timeIntervalSince1970:))
        }
    }

    public func claimNotificationPublication(
        now: Date,
        leaseToken: String,
        leaseDuration: TimeInterval
    ) throws -> NotificationPublicationClaim? {
        do {
            return try databasePool.write { database in
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, account_id, message_id, logical_mailbox_id, logical_mailbox_id_bytes,
                               producer_device_id, producer_kind, policy_mode, policy_version,
                               config_revision, config_version, producer_generation, state
                        FROM local_notification_publications
                        WHERE expires_at > ? AND ((state = 'pending' AND (lease_expires_at IS NULL OR lease_expires_at <= ?)
                               AND NOT EXISTS (
                                   SELECT 1 FROM local_notification_deliveries d
                                   WHERE d.publication_id = local_notification_publications.id
                                     AND d.outcome = 'retryable'
                                     AND d.next_attempt_at IS NOT NULL AND d.next_attempt_at > ?
                               ))
                           OR (state IN ('claimed', 'frozen')
                               AND (lease_expires_at IS NULL OR lease_expires_at <= ?)
                               AND NOT EXISTS (
                                   SELECT 1 FROM local_notification_deliveries d
                                   WHERE d.publication_id = local_notification_publications.id
                                     AND d.outcome = 'retryable'
                                     AND d.next_attempt_at IS NOT NULL AND d.next_attempt_at > ?
                               )))
                        ORDER BY created_at, id LIMIT 1
                        """,
                    arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970]
                )
                guard let row else { return nil }
                try database.execute(
                    sql: """
                        UPDATE local_notification_publications
                        SET state = 'claimed', lease_token = ?, lease_expires_at = ?, updated_at = ?
                        WHERE id = ?
                          AND state IN ('pending', 'claimed', 'frozen')
                          AND (lease_expires_at IS NULL OR lease_expires_at <= ?)
                        """,
                    arguments: [leaseToken, now.addingTimeInterval(leaseDuration).timeIntervalSince1970,
                                now.timeIntervalSince1970, row["id"] as String,
                                now.timeIntervalSince1970]
                )
                guard database.changesCount > 0 else { return nil }
                return NotificationPublicationClaim(
                    publicationID: row["id"],
                    accountID: AccountID(row["account_id"]),
                    messageID: MessageID(row["message_id"]),
                    leaseToken: leaseToken,
                    configVersion: row["config_version"],
                    producerGeneration: row["producer_generation"]
                    , logicalMailboxID: row["logical_mailbox_id"],
                    producerDeviceID: row["producer_device_id"], producerKind: row["producer_kind"],
                    policyMode: row["policy_mode"], policyVersion: row["policy_version"],
                    configRevision: row["config_revision"],
                    logicalMailboxIDBytes: row["logical_mailbox_id_bytes"],
                    resumesFrozenPublication: (row["state"] as String? ?? "") == "frozen"
                )
            }
        } catch { throw error }
    }

    public func freezeNotificationPublication(
        publicationID: String,
        leaseToken: String,
        configVersion: String,
        producerGeneration: Int64,
        recipients: [NotificationRecipientSnapshot],
        envelopeBytes: [Data]
    ) throws -> Bool {
        guard recipients.count == envelopeBytes.count else {
            throw PlainpostError.validationFailed("Notification recipient and envelope counts differ.")
        }
        guard recipients.map(\.recipientID).count == Set(recipients.map(\.recipientID)).count else {
            throw PlainpostError.validationFailed("Notification recipients must be unique.")
        }
        guard recipients.allSatisfy({ $0.routingHandle.count == 32 && $0.agreementPublicKey.count == 65 }),
              envelopeBytes.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else {
            throw PlainpostError.validationFailed("Notification authority or envelope bytes are malformed.")
        }
        do {
            return try databasePool.write { database in
                let now = Date().timeIntervalSince1970
                try database.execute(
                    sql: """
                        UPDATE local_notification_publications
                        SET state = 'frozen', updated_at = ?
                        WHERE id = ? AND state = 'claimed' AND lease_token = ?
                          AND config_version = ? AND producer_generation = ? AND lease_expires_at > ?
                        """,
                    arguments: [now, publicationID, leaseToken, configVersion, producerGeneration, now]
                )
                guard database.changesCount > 0 else { return false }
                let publication = try Row.fetchOne(
                    database,
                    sql: "SELECT producer_device_id, producer_generation, policy_version, expires_at FROM local_notification_publications WHERE id = ?",
                    arguments: [publicationID]
                )
                let producerDeviceID: String? = publication?["producer_device_id"]
                let publicationGeneration: Int64 = publication?["producer_generation"] ?? producerGeneration
                let publicationPolicyVersion: Int64 = publication?["policy_version"] ?? 0
                let publicationExpiry: Double = publication?["expires_at"] ?? (now + 900)
                if recipients.isEmpty {
                    try database.execute(
                        sql: "UPDATE local_notification_publications SET state = 'completed', lease_token = NULL, lease_expires_at = NULL WHERE id = ?",
                        arguments: [publicationID]
                    )
                    return true
                }
                for (recipient, bytes) in zip(recipients, envelopeBytes) {
                    try database.execute(
                        sql: """
                            INSERT OR IGNORE INTO local_notification_deliveries (
                                publication_id, recipient_id, producer_device_id,
                                producer_generation, policy_version, replay_id, collapse_digest,
                                routing_handle, agreement_public_key, envelope_bytes, envelope_digest,
                                lease_token, lease_expires_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [publicationID, recipient.recipientID,
                                    recipient.producerDeviceID ?? producerDeviceID,
                                    recipient.producerGeneration ?? publicationGeneration,
                                    recipient.policyVersion ?? publicationPolicyVersion,
                                    recipient.replayID, recipient.collapseDigest,
                                    recipient.routingHandle, recipient.agreementPublicKey,
                                    bytes, Data(SHA256.hash(data: bytes)), leaseToken, publicationExpiry]
                    )
                }
                return true
            }
        } catch { throw error }
    }

    public func cancelNotificationPublication(
        publicationID: String,
        leaseToken: String,
        configVersion: String,
        producerGeneration: Int64
    ) throws -> Bool {
        do {
            return try databasePool.write { database in
                try database.execute(
                    sql: """
                        UPDATE local_notification_publications
                        SET state = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
                            updated_at = ?
                        WHERE id = ? AND state = 'claimed' AND lease_token = ?
                          AND config_version = ? AND producer_generation = ? AND lease_expires_at > ?
                        """,
                    arguments: [Date().timeIntervalSince1970, publicationID, leaseToken,
                                configVersion, producerGeneration, Date().timeIntervalSince1970]
                )
                return database.changesCount > 0
            }
        } catch { throw error }
    }

    public func recordNotificationDeliveryOutcome(
        publicationID: String,
        leaseToken: String,
        recipientID: String,
        outcome: NotificationDeliveryOutcome,
        nextAttemptAt: Date?
    ) throws -> Bool {
        do {
            return try databasePool.write { database in
                try database.execute(
                    sql: """
                        UPDATE local_notification_deliveries
                        SET outcome = ?, attempt_count = attempt_count + 1,
                            next_attempt_at = ?, completed_at = CASE
                                WHEN ? IN ('retryable') THEN NULL ELSE ? END,
                            lease_token = NULL, lease_expires_at = NULL
                        WHERE publication_id = ? AND recipient_id = ?
                          AND (outcome IS NULL OR outcome = 'retryable')
                          AND EXISTS (
                              SELECT 1 FROM local_notification_publications
                              WHERE id = ? AND state IN ('claimed', 'frozen') AND lease_token = ?
                                AND lease_expires_at > ?
                          )
                        """,
                    arguments: [outcome.rawValue, nextAttemptAt?.timeIntervalSince1970,
                                outcome.rawValue, Date().timeIntervalSince1970,
                                publicationID, recipientID, publicationID, leaseToken,
                                Date().timeIntervalSince1970]
                )
                guard database.changesCount > 0 else { return false }
                let hasRetry = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM local_notification_deliveries
                            WHERE publication_id = ? AND (outcome IS NULL OR outcome = 'retryable')
                        )
                        """,
                    arguments: [publicationID]
                ) ?? false
                if outcome == .retryable {
                    try database.execute(
                        sql: """
                            UPDATE local_notification_publications
                            SET state = 'frozen', lease_token = NULL, lease_expires_at = NULL,
                                updated_at = ?, last_error = CASE WHEN ? = 'retryable' THEN last_error ELSE ? END
                            WHERE id = ?
                            """,
                        arguments: [Date().timeIntervalSince1970, outcome.rawValue, outcome.rawValue, publicationID]
                    )
                } else if !hasRetry {
                    try database.execute(
                        sql: """
                            UPDATE local_notification_publications
                            SET state = 'completed', lease_token = NULL, lease_expires_at = NULL,
                                updated_at = ?, terminal_reason = ?
                            WHERE id = ?
                            """,
                        arguments: [Date().timeIntervalSince1970, outcome.rawValue, publicationID]
                    )
                }
                return true
            }
        } catch { throw error }
    }

    public func cleanupNotificationPublications(olderThan cutoff: Date) throws -> Int {
        do {
                return try databasePool.write { database in
                try database.execute(
                    sql: """
                        DELETE FROM local_notification_publications
                        WHERE created_at < ? AND state IN ('completed', 'cancelled')
                        """,
                    arguments: [cutoff.timeIntervalSince1970]
                )
                return database.changesCount
            }
        } catch { throw error }
    }

    public func cleanupNotificationPublications(now: Date = Date()) throws -> Int {
        try cleanupNotificationPublications(olderThan: now.addingTimeInterval(-7 * 24 * 60 * 60))
    }
}
