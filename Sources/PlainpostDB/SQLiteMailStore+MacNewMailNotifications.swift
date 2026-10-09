import CryptoKit
import Foundation
import GRDB
import PlainpostCore

public enum MacNewMailEventState: String, Equatable, Sendable {
    case awaitingRules = "awaiting_rules"
    case ready
    case assigned
    case suppressed
    case expired
}

public struct MacNewMailEventRecord: Equatable, Sendable {
    public let id: String
    public let accountID: AccountID
    public let messageID: MessageID
    public let state: MacNewMailEventState
    public let providerArrivalAt: Date
    public let readyAt: Date?
    public let expiresAt: Date

    public init(
        id: String,
        accountID: AccountID,
        messageID: MessageID,
        state: MacNewMailEventState,
        providerArrivalAt: Date,
        readyAt: Date?,
        expiresAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.messageID = messageID
        self.state = state
        self.providerArrivalAt = providerArrivalAt
        self.readyAt = readyAt
        self.expiresAt = expiresAt
    }
}

public struct MacNewMailRuleWorkBatch: Equatable, Sendable {
    public let accountID: AccountID
    public let messageIDs: [MessageID]

    public init(accountID: AccountID, messageIDs: [MessageID]) {
        self.accountID = accountID
        self.messageIDs = messageIDs
    }
}

public enum MacNewMailDeliveryKind: String, Equatable, Sendable {
    case individual
    case summary
}

public enum MacNewMailDeliveryState: String, Equatable, Sendable {
    case ready
    case leased
    case submitting
    case submitted
    case retryWait = "retry_wait"
    case suppressed
    case expired
    case failed
}

public enum MacNewMailSuppressionReason: String, Equatable, Sendable {
    case notificationsDisabled = "notifications_disabled"
    case authorizationDenied = "authorization_denied"
    case authorizationNotDetermined = "authorization_not_determined"
    case authorizationUnavailable = "authorization_unavailable"
    case messageUnavailable = "message_unavailable"
    case messageSeen = "message_seen"
    case pushDelivered = "push_delivered"
    case accountUnavailable = "account_unavailable"
}

public enum MacNewMailSubmissionErrorCategory: String, Equatable, Sendable {
    case systemTemporarilyUnavailable = "system_temporarily_unavailable"
    case systemRejected = "system_rejected"
    case unknown
}

public struct MacNewMailDeliveryRecord: Equatable, Sendable {
    public let id: String
    public let accountID: AccountID
    public let kind: MacNewMailDeliveryKind
    public let state: MacNewMailDeliveryState
    public let eventCount: Int
    public let firstProviderArrivalAt: Date
    public let expiresAt: Date
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let messageIDs: [MessageID]
}

public struct MacNewMailDeliveryClaim: Equatable, Sendable {
    public let id: String
    public let accountID: AccountID
    public let kind: MacNewMailDeliveryKind
    public let eventCount: Int
    public let firstProviderArrivalAt: Date
    public let expiresAt: Date
    public let attemptCount: Int
    public let leaseToken: String
    public let messageIDs: [MessageID]

    public var contentSource: MacNewMailDeliveryContentSource {
        MacNewMailDeliveryContentSource(
            deliveryID: id,
            accountID: accountID,
            kind: kind,
            eventCount: eventCount,
            messageIDs: messageIDs
        )
    }
}

public struct MacNewMailDeliveryContentSource: Equatable, Sendable {
    public let deliveryID: String
    public let accountID: AccountID
    public let kind: MacNewMailDeliveryKind
    public let eventCount: Int
    public let messageIDs: [MessageID]
}

private final class NewMailNotificationWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 15 * 60

    var value: TimeInterval {
        get { lock.withLock { seconds } }
        set { lock.withLock { seconds = newValue } }
    }
}

private let newMailNotificationWindowStorage = NewMailNotificationWindow()

public extension SQLiteMailStore {
    /// How long after its provider arrival an Inbox message can still raise a new-mail
    /// notification, and how long that notification may wait to be delivered. The Mac's
    /// real-time monitor sees mail within seconds and keeps 15 minutes; the iPhone's
    /// background refresh can run hours apart, so it widens the window at launch.
    static var newMailNotificationWindow: TimeInterval {
        get { newMailNotificationWindowStorage.value }
        set { newMailNotificationWindowStorage.value = newValue }
    }

    func macNewMailEvents(accountID: AccountID) throws -> [MacNewMailEventRecord] {
        do {
            return try databasePool.read { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, account_id, message_id, state,
                               provider_arrival_at, ready_at, expires_at
                        FROM mac_new_mail_events
                        WHERE account_id = ?
                        ORDER BY provider_arrival_at, id
                        """,
                    arguments: [accountID.rawValue]
                )
                return try rows.map { row in
                    guard let state = MacNewMailEventState(rawValue: row["state"]) else {
                        throw PlainpostError.validationFailed(
                            "Local notification event has an invalid state."
                        )
                    }
                    let readyTimestamp: Double? = row["ready_at"]
                    return MacNewMailEventRecord(
                        id: row["id"],
                        accountID: AccountID(row["account_id"]),
                        messageID: MessageID(row["message_id"]),
                        state: state,
                        providerArrivalAt: Date(timeIntervalSince1970: row["provider_arrival_at"]),
                        readyAt: readyTimestamp.map(Date.init(timeIntervalSince1970:)),
                        expiresAt: Date(timeIntervalSince1970: row["expires_at"])
                    )
                }
            }
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw PlainpostError.validationFailed(
                "Local database operation failed: \(error.localizedDescription)"
            )
        }
    }

    func resolveMacNewMailEvents(
        accountID: AccountID,
        messageIDs: [MessageID],
        suppressedIDs: Set<MessageID>,
        now: Date
    ) throws {
        let orderedIDs = Array(Set(messageIDs)).sorted { $0.rawValue < $1.rawValue }
        guard !orderedIDs.isEmpty else { return }
        do {
            let changed = try databasePool.write { database in
                var changed = false
                let timestamp = now.timeIntervalSince1970
                for messageID in orderedIDs {
                    try database.execute(
                        sql: """
                            UPDATE mac_new_mail_events
                            SET state = 'expired', terminal_reason = 'provider_window_expired',
                                updated_at = ?
                            WHERE account_id = ? AND message_id = ?
                              AND state = 'awaiting_rules' AND expires_at <= ?
                            """,
                        arguments: [timestamp, accountID.rawValue, messageID.rawValue, timestamp]
                    )
                    changed = changed || database.changesCount > 0
                    let suppressed = suppressedIDs.contains(messageID)
                    try database.execute(
                        sql: """
                            UPDATE mac_new_mail_events
                            SET state = ?, ready_at = ?, terminal_reason = ?, updated_at = ?
                            WHERE account_id = ? AND message_id = ?
                              AND state = 'awaiting_rules' AND expires_at > ?
                            """,
                        arguments: [
                            suppressed ? "suppressed" : "ready",
                            suppressed ? nil : timestamp,
                            suppressed ? "rule_suppressed" : nil,
                            timestamp,
                            accountID.rawValue,
                            messageID.rawValue,
                            timestamp,
                        ]
                    )
                    changed = changed || database.changesCount > 0
                }
                return changed
            }
            if changed {
                MailStoreChangeSignal.post(scope: .operations)
            }
        } catch {
            throw databaseError(error)
        }
    }

    func failMacNewMailRuleEvaluation(
        accountID: AccountID,
        messageIDs: [MessageID],
        now: Date
    ) throws {
        let orderedIDs = Array(Set(messageIDs)).sorted { $0.rawValue < $1.rawValue }
        guard !orderedIDs.isEmpty else { return }
        do {
            let changed = try databasePool.write { database in
                var changed = false
                let timestamp = now.timeIntervalSince1970
                for messageID in orderedIDs {
                    try database.execute(
                        sql: """
                            UPDATE mac_new_mail_events
                            SET state = CASE WHEN expires_at <= ? THEN 'expired' ELSE 'suppressed' END,
                                terminal_reason = CASE WHEN expires_at <= ?
                                    THEN 'provider_window_expired' ELSE 'rule_evaluation_failed' END,
                                updated_at = ?
                            WHERE account_id = ? AND message_id = ?
                              AND state = 'awaiting_rules'
                            """,
                        arguments: [
                            timestamp, timestamp, timestamp,
                            accountID.rawValue, messageID.rawValue,
                        ]
                    )
                    changed = changed || database.changesCount > 0
                }
                return changed
            }
            if changed {
                MailStoreChangeSignal.post(scope: .operations)
            }
        } catch {
            throw databaseError(error)
        }
    }

    func awaitingMacNewMailEventMessageIDs(
        limit: Int,
        now: Date
    ) throws -> [MacNewMailRuleWorkBatch] {
        do {
            let result = try databasePool.write { database in
                let timestamp = now.timeIntervalSince1970
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_events
                        SET state = 'expired', terminal_reason = 'provider_window_expired',
                            updated_at = ?
                        WHERE state = 'awaiting_rules' AND expires_at <= ?
                        """,
                    arguments: [timestamp, timestamp]
                )
                let expiredAny = database.changesCount > 0
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT account_id, message_id
                        FROM mac_new_mail_events
                        WHERE state = 'awaiting_rules' AND expires_at > ?
                        ORDER BY provider_arrival_at, id
                        LIMIT ?
                        """,
                    arguments: [timestamp, max(1, min(limit, 500))]
                )
                var accountOrder: [AccountID] = []
                var IDsByAccount: [AccountID: [MessageID]] = [:]
                for row in rows {
                    let accountID = AccountID(row["account_id"])
                    if IDsByAccount[accountID] == nil {
                        accountOrder.append(accountID)
                    }
                    IDsByAccount[accountID, default: []].append(MessageID(row["message_id"]))
                }
                return (
                    accountOrder.map {
                        MacNewMailRuleWorkBatch(accountID: $0, messageIDs: IDsByAccount[$0] ?? [])
                    },
                    expiredAny
                )
            }
            if result.1 {
                MailStoreChangeSignal.post(scope: .operations)
            }
            return result.0
        } catch {
            throw databaseError(error)
        }
    }

    func nextMacNewMailDeliveryWakeDate(now: Date) throws -> Date? {
        do {
            return try databasePool.read { database in
                let timestamp: Double? = try Double.fetchOne(
                    database,
                    sql: """
                        SELECT MIN(wake_at)
                        FROM (
                            SELECT MIN(ready_at + 2) AS wake_at
                            FROM mac_new_mail_events
                            WHERE state = 'ready' AND expires_at > ?
                            UNION ALL
                            SELECT MIN(next_attempt_at) AS wake_at
                            FROM mac_new_mail_deliveries
                            WHERE state = 'retry_wait' AND expires_at > ?
                        )
                        """,
                    arguments: [
                        now.timeIntervalSince1970,
                        now.timeIntervalSince1970,
                    ]
                )
                return timestamp.map(Date.init(timeIntervalSince1970:))
            }
        } catch {
            throw databaseError(error)
        }
    }

    @discardableResult
    func formMacNewMailDeliveries(now: Date) throws -> Int {
        do {
            let formedCount = try databasePool.write { database in
                let timestamp = now.timeIntervalSince1970
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_events
                        SET state = 'expired', terminal_reason = 'provider_window_expired',
                            updated_at = ?
                        WHERE state = 'ready' AND expires_at <= ?
                        """,
                    arguments: [timestamp, timestamp]
                )
                let accountRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT account_id, MIN(ready_at) AS first_ready_at
                        FROM mac_new_mail_events
                        WHERE state = 'ready' AND expires_at > ?
                        GROUP BY account_id
                        HAVING first_ready_at + 2 <= ?
                        ORDER BY first_ready_at, account_id
                        """,
                    arguments: [timestamp, timestamp]
                )
                var formedCount = 0
                for accountRow in accountRows {
                    let accountID: String = accountRow["account_id"]
                    let firstReadyAt: Double = accountRow["first_ready_at"]
                    let cutoff = firstReadyAt + 2
                    let eventRows = try Row.fetchAll(
                        database,
                        sql: """
                            SELECT id, message_id, provider_arrival_at, expires_at
                            FROM mac_new_mail_events
                            WHERE account_id = ? AND state = 'ready'
                              AND ready_at <= ? AND expires_at > ?
                            ORDER BY provider_arrival_at, id
                            """,
                        arguments: [accountID, cutoff, timestamp]
                    )
                    guard !eventRows.isEmpty else { continue }
                    if eventRows.count <= 5 {
                        for eventRow in eventRows {
                            let eventID: String = eventRow["id"]
                            let deliveryID = "mac-mail-delivery-" + Self.macNotificationStableID(
                                "individual\u{1f}\(eventID)"
                            )
                            try database.execute(
                                sql: """
                                    INSERT OR IGNORE INTO mac_new_mail_deliveries (
                                        id, account_id, kind, state, event_count,
                                        first_provider_arrival_at, expires_at,
                                        created_at, updated_at
                                    ) VALUES (?, ?, 'individual', 'ready', 1, ?, ?, ?, ?)
                                    """,
                                arguments: [
                                    deliveryID, accountID,
                                    eventRow["provider_arrival_at"], eventRow["expires_at"],
                                    timestamp, timestamp,
                                ]
                            )
                            guard database.changesCount == 1 else { continue }
                            try database.execute(
                                sql: """
                                    UPDATE mac_new_mail_events
                                    SET state = 'assigned', delivery_id = ?, updated_at = ?
                                    WHERE id = ? AND state = 'ready'
                                    """,
                                arguments: [deliveryID, timestamp, eventID]
                            )
                            guard database.changesCount == 1 else {
                                throw PlainpostError.validationFailed(
                                    "A local notification event changed while forming its delivery."
                                )
                            }
                            formedCount += 1
                        }
                    } else {
                        let selectedRows = Array(eventRows.prefix(500))
                        let selectedEventIDs: [String] = selectedRows.map { $0["id"] }
                        let deliveryID = "mac-mail-delivery-" + Self.macNotificationStableID(
                            "summary\u{1f}\(accountID)\u{1f}\(selectedEventIDs.sorted().joined(separator: "\u{1f}"))"
                        )
                        let firstArrival: Double = selectedRows[0]["provider_arrival_at"]
                        let expiry = selectedRows.reduce(Double.greatestFiniteMagnitude) {
                            min($0, $1["expires_at"] as Double)
                        }
                        try database.execute(
                            sql: """
                                INSERT OR IGNORE INTO mac_new_mail_deliveries (
                                    id, account_id, kind, state, event_count,
                                    first_provider_arrival_at, expires_at,
                                    created_at, updated_at
                                ) VALUES (?, ?, 'summary', 'ready', ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                deliveryID, accountID, eventRows.count,
                                firstArrival, expiry, timestamp, timestamp,
                            ]
                        )
                        guard database.changesCount == 1 else { continue }
                        for eventID in selectedEventIDs {
                            try database.execute(
                                sql: """
                                    UPDATE mac_new_mail_events
                                    SET state = 'assigned', delivery_id = ?, updated_at = ?
                                    WHERE id = ? AND state = 'ready'
                                    """,
                                arguments: [deliveryID, timestamp, eventID]
                            )
                            guard database.changesCount == 1 else {
                                throw PlainpostError.validationFailed(
                                    "A local notification event changed while forming its summary."
                                )
                            }
                        }
                        if eventRows.count > selectedRows.count {
                            for row in eventRows.dropFirst(selectedRows.count) {
                                try database.execute(
                                    sql: """
                                        UPDATE mac_new_mail_events
                                        SET state = 'suppressed', terminal_reason = 'batch_overflow',
                                            updated_at = ?
                                        WHERE id = ? AND state = 'ready'
                                        """,
                                    arguments: [timestamp, row["id"] as String]
                                )
                            }
                        }
                        formedCount += 1
                    }
                }
                return formedCount
            }
            if formedCount > 0 {
                MailStoreChangeSignal.post(scope: .operations)
            }
            return formedCount
        } catch {
            throw databaseError(error)
        }
    }

    func macNewMailDeliveries(accountID: AccountID) throws -> [MacNewMailDeliveryRecord] {
        do {
            return try databasePool.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT * FROM mac_new_mail_deliveries
                        WHERE account_id = ?
                        ORDER BY created_at, id
                        """,
                    arguments: [accountID.rawValue]
                ).map { row in
                    try Self.macNotificationDeliveryRecord(row, database: database)
                }
            }
        } catch {
            throw databaseError(error)
        }
    }

    func claimMacNewMailDelivery(
        now: Date,
        leaseDuration: TimeInterval
    ) throws -> MacNewMailDeliveryClaim? {
        do {
            return try databasePool.write { database in
                let timestamp = now.timeIntervalSince1970
                guard let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT * FROM mac_new_mail_deliveries
                        WHERE expires_at > ?
                          AND (
                            state = 'ready'
                            OR (state = 'retry_wait' AND next_attempt_at <= ?)
                          )
                        ORDER BY created_at, id
                        LIMIT 1
                        """,
                    arguments: [timestamp, timestamp]
                ) else { return nil }
                let id: String = row["id"]
                let leaseToken = UUID().uuidString
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = 'leased', lease_token = ?, lease_expires_at = ?,
                            next_attempt_at = NULL, updated_at = ?
                        WHERE id = ? AND expires_at > ?
                          AND (
                            state = 'ready'
                            OR (state = 'retry_wait' AND next_attempt_at <= ?)
                          )
                        """,
                    arguments: [
                        leaseToken, timestamp + max(1, leaseDuration), timestamp,
                        id, timestamp, timestamp,
                    ]
                )
                guard database.changesCount == 1 else { return nil }
                guard let kind = MacNewMailDeliveryKind(rawValue: row["kind"]) else {
                    throw PlainpostError.validationFailed(
                        "A local notification delivery has an invalid kind."
                    )
                }
                return MacNewMailDeliveryClaim(
                    id: id,
                    accountID: AccountID(row["account_id"]),
                    kind: kind,
                    eventCount: row["event_count"],
                    firstProviderArrivalAt: Date(timeIntervalSince1970: row["first_provider_arrival_at"]),
                    expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
                    attemptCount: row["attempt_count"],
                    leaseToken: leaseToken,
                    messageIDs: try Self.macNotificationMessageIDs(
                        deliveryID: id,
                        database: database
                    )
                )
            }
        } catch {
            throw databaseError(error)
        }
    }

    func beginMacNewMailSubmission(
        id: String,
        leaseToken: String,
        now: Date
    ) throws -> Bool {
        do {
            let changed = try databasePool.write { database in
                let timestamp = now.timeIntervalSince1970
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = 'submitting', attempt_count = attempt_count + 1,
                            updated_at = ?
                        WHERE id = ? AND state = 'leased' AND lease_token = ?
                          AND lease_expires_at > ? AND expires_at > ?
                        """,
                    arguments: [timestamp, id, leaseToken, timestamp, timestamp]
                )
                return database.changesCount == 1
            }
            if changed { MailStoreChangeSignal.post(scope: .operations) }
            return changed
        } catch {
            throw databaseError(error)
        }
    }

    @discardableResult
    func suppressMacNewMailDelivery(
        id: String,
        leaseToken: String,
        reason: MacNewMailSuppressionReason,
        now: Date
    ) throws -> Bool {
        do {
            let changed = try databasePool.write { database in
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = 'suppressed', terminal_reason = ?,
                            lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                        WHERE id = ? AND state = 'leased' AND lease_token = ?
                        """,
                    arguments: [reason.rawValue, now.timeIntervalSince1970, id, leaseToken]
                )
                return database.changesCount == 1
            }
            if changed { MailStoreChangeSignal.post(scope: .operations) }
            return changed
        } catch {
            throw databaseError(error)
        }
    }

    @discardableResult
    func releaseMacNewMailDelivery(
        id: String,
        leaseToken: String,
        now: Date
    ) throws -> Bool {
        do {
            let changed = try databasePool.write { database in
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = CASE WHEN expires_at <= ? THEN 'expired' ELSE 'ready' END,
                            terminal_reason = CASE WHEN expires_at <= ?
                                THEN 'provider_window_expired' ELSE NULL END,
                            lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                        WHERE id = ? AND state = 'leased' AND lease_token = ?
                        """,
                    arguments: [
                        now.timeIntervalSince1970,
                        now.timeIntervalSince1970,
                        now.timeIntervalSince1970,
                        id,
                        leaseToken,
                    ]
                )
                return database.changesCount == 1
            }
            if changed { MailStoreChangeSignal.post(scope: .operations) }
            return changed
        } catch {
            throw databaseError(error)
        }
    }

    @discardableResult
    func completeMacNewMailSubmission(
        id: String,
        leaseToken: String,
        now: Date
    ) throws -> Bool {
        try transitionMacNewMailSubmission(
            id: id,
            leaseToken: leaseToken,
            state: .submitted,
            errorCategory: nil,
            retryAt: nil,
            now: now
        )
    }

    @discardableResult
    func failMacNewMailSubmission(
        id: String,
        leaseToken: String,
        errorCategory: MacNewMailSubmissionErrorCategory,
        retryAt: Date?,
        now: Date
    ) throws -> Bool {
        do {
            let timestamp = now.timeIntervalSince1970
            let changed = try databasePool.write { database in
                guard let expiry = try Double.fetchOne(
                    database,
                    sql: """
                        SELECT expires_at FROM mac_new_mail_deliveries
                        WHERE id = ? AND state = 'submitting' AND lease_token = ?
                        """,
                    arguments: [id, leaseToken]
                ) else { return false }
                let validRetryAt = retryAt?.timeIntervalSince1970
                let shouldRetry = validRetryAt.map { $0 > timestamp && $0 < expiry } == true
                let nextState = shouldRetry ? "retry_wait" : (timestamp >= expiry ? "expired" : "failed")
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = ?, next_attempt_at = ?, terminal_reason = ?,
                            last_error_category = ?, lease_token = NULL,
                            lease_expires_at = NULL, updated_at = ?
                        WHERE id = ? AND state = 'submitting' AND lease_token = ?
                        """,
                    arguments: [
                        nextState,
                        shouldRetry ? validRetryAt : nil,
                        shouldRetry ? nil : (nextState == "expired" ? "provider_window_expired" : "submission_failed"),
                        errorCategory.rawValue,
                        timestamp,
                        id,
                        leaseToken,
                    ]
                )
                return database.changesCount == 1
            }
            if changed { MailStoreChangeSignal.post(scope: .operations) }
            return changed
        } catch {
            throw databaseError(error)
        }
    }

    func recoverMacNewMailNotifications(now: Date) throws {
        do {
            let changed = try databasePool.write { database in
                let timestamp = now.timeIntervalSince1970
                var changed = false
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_events
                        SET state = 'expired', terminal_reason = 'provider_window_expired',
                            updated_at = ?
                        WHERE state IN ('awaiting_rules', 'ready') AND expires_at <= ?
                        """,
                    arguments: [timestamp, timestamp]
                )
                changed = changed || database.changesCount > 0
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = 'expired', terminal_reason = 'provider_window_expired',
                            lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                        WHERE state IN ('ready', 'leased', 'retry_wait') AND expires_at <= ?
                        """,
                    arguments: [timestamp, timestamp]
                )
                changed = changed || database.changesCount > 0
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = 'ready', lease_token = NULL, lease_expires_at = NULL,
                            updated_at = ?
                        WHERE state = 'leased' AND lease_expires_at <= ? AND expires_at > ?
                        """,
                    arguments: [timestamp, timestamp, timestamp]
                )
                changed = changed || database.changesCount > 0
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = 'failed', terminal_reason = 'submission_outcome_unknown',
                            last_error_category = 'submission_outcome_unknown',
                            lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                        WHERE state = 'submitting'
                        """,
                    arguments: [timestamp]
                )
                changed = changed || database.changesCount > 0
                return changed
            }
            if changed { MailStoreChangeSignal.post(scope: .operations) }
        } catch {
            throw databaseError(error)
        }
    }

    @discardableResult
    func cleanupMacNewMailNotifications(before cutoff: Date, limit: Int = 500) throws -> Int {
        do {
            let deleted = try databasePool.write { database in
                let boundedLimit = max(1, min(limit, 500))
                let timestamp = cutoff.timeIntervalSince1970
                var deleted = 0
                try database.execute(
                    sql: """
                        DELETE FROM mac_new_mail_events
                        WHERE id IN (
                            SELECT events.id
                            FROM mac_new_mail_events events
                            LEFT JOIN mac_new_mail_deliveries deliveries
                              ON deliveries.id = events.delivery_id
                            WHERE (
                                events.state IN ('suppressed', 'expired')
                                OR (
                                    events.state = 'assigned'
                                    AND deliveries.state IN ('submitted', 'suppressed', 'expired', 'failed')
                                )
                            )
                              AND COALESCE(deliveries.updated_at, events.updated_at) < ?
                            ORDER BY COALESCE(deliveries.updated_at, events.updated_at), events.id
                            LIMIT ?
                        )
                        """,
                    arguments: [timestamp, boundedLimit]
                )
                deleted += database.changesCount
                let remaining = max(0, boundedLimit - deleted)
                if remaining > 0 {
                    try database.execute(
                        sql: """
                            DELETE FROM mac_new_mail_deliveries
                            WHERE id IN (
                                SELECT deliveries.id
                                FROM mac_new_mail_deliveries deliveries
                                WHERE deliveries.state IN ('submitted', 'suppressed', 'expired', 'failed')
                                  AND deliveries.updated_at < ?
                                  AND NOT EXISTS (
                                    SELECT 1 FROM mac_new_mail_events events
                                    WHERE events.delivery_id = deliveries.id
                                  )
                                ORDER BY deliveries.updated_at, deliveries.id
                                LIMIT ?
                            )
                            """,
                        arguments: [timestamp, remaining]
                    )
                    deleted += database.changesCount
                }
                return deleted
            }
            return deleted
        } catch {
            throw databaseError(error)
        }
    }

    private func transitionMacNewMailSubmission(
        id: String,
        leaseToken: String,
        state: MacNewMailDeliveryState,
        errorCategory: String?,
        retryAt: Date?,
        now: Date
    ) throws -> Bool {
        do {
            let changed = try databasePool.write { database in
                try database.execute(
                    sql: """
                        UPDATE mac_new_mail_deliveries
                        SET state = ?, next_attempt_at = ?, terminal_reason = NULL,
                            last_error_category = ?, lease_token = NULL,
                            lease_expires_at = NULL, updated_at = ?
                        WHERE id = ? AND state = 'submitting' AND lease_token = ?
                        """,
                    arguments: [
                        state.rawValue,
                        retryAt?.timeIntervalSince1970,
                        errorCategory,
                        now.timeIntervalSince1970,
                        id,
                        leaseToken,
                    ]
                )
                return database.changesCount == 1
            }
            if changed { MailStoreChangeSignal.post(scope: .operations) }
            return changed
        } catch {
            throw databaseError(error)
        }
    }

    private static func macNotificationMessageIDs(
        deliveryID: String,
        database: Database
    ) throws -> [MessageID] {
        try String.fetchAll(
            database,
            sql: """
                SELECT message_id FROM mac_new_mail_events
                WHERE delivery_id = ? AND state = 'assigned'
                ORDER BY provider_arrival_at, id
                """,
            arguments: [deliveryID]
        ).map { MessageID($0) }
    }

    private static func macNotificationDeliveryRecord(
        _ row: Row,
        database: Database
    ) throws -> MacNewMailDeliveryRecord {
        guard let kind = MacNewMailDeliveryKind(rawValue: row["kind"]),
              let state = MacNewMailDeliveryState(rawValue: row["state"])
        else {
            throw PlainpostError.validationFailed(
                "A local notification delivery has an invalid state."
            )
        }
        let nextAttemptTimestamp: Double? = row["next_attempt_at"]
        let id: String = row["id"]
        return MacNewMailDeliveryRecord(
            id: id,
            accountID: AccountID(row["account_id"]),
            kind: kind,
            state: state,
            eventCount: row["event_count"],
            firstProviderArrivalAt: Date(timeIntervalSince1970: row["first_provider_arrival_at"]),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
            attemptCount: row["attempt_count"],
            nextAttemptAt: nextAttemptTimestamp.map(Date.init(timeIntervalSince1970:)),
            messageIDs: try macNotificationMessageIDs(deliveryID: id, database: database)
        )
    }

    private static func macNotificationStableID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
