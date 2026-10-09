import Foundation
import PlainpostCore

public enum MailboxSyncMode: String, Codable, CaseIterable, Sendable {
    case off
    case recent
    case complete
}

public struct MailSyncPreferences: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public var downloadCompleteHistory: Bool
    public var recentMessageLimit: Int
    public var realTimeMonitoringEnabled: Bool

    public init(
        accountID: AccountID,
        downloadCompleteHistory: Bool = false,
        recentMessageLimit: Int = 100,
        realTimeMonitoringEnabled: Bool = true
    ) {
        self.accountID = accountID
        self.downloadCompleteHistory = downloadCompleteHistory
        self.recentMessageLimit = max(1, min(recentMessageLimit, 10_000))
        self.realTimeMonitoringEnabled = realTimeMonitoringEnabled
    }
}

public struct MailboxSyncPreference: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public let mailboxPath: String
    public var mode: MailboxSyncMode

    public init(accountID: AccountID, mailboxPath: String, mode: MailboxSyncMode) {
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.mode = mode
    }
}

public enum MailboxSyncSelection {
    public static func effectiveModes(
        availableMailboxPaths: [String],
        preferences: [MailboxSyncPreference]
    ) -> [String: MailboxSyncMode] {
        effectiveModes(
            availableMailboxPaths: availableMailboxPaths,
            defaultModesByKey: [normalizedKey(for: "INBOX"): .recent],
            preferences: preferences
        )
    }

    public static func effectiveModes(
        availableMailboxes: [Mailbox],
        preferences: [MailboxSyncPreference]
    ) -> [String: MailboxSyncMode] {
        var defaultModesByKey: [String: MailboxSyncMode] = [:]
        for mailbox in availableMailboxes {
            switch mailbox.specialUse?.lowercased() {
            case "\\inbox", "\\sent", "\\archive", "\\drafts":
                defaultModesByKey[normalizedKey(for: mailbox.path)] = .recent
            default:
                break
            }
        }
        return effectiveModes(
            availableMailboxPaths: availableMailboxes.map(\.path),
            defaultModesByKey: defaultModesByKey,
            preferences: preferences
        )
    }

    private static func effectiveModes(
        availableMailboxPaths: [String],
        defaultModesByKey: [String: MailboxSyncMode],
        preferences: [MailboxSyncPreference]
    ) -> [String: MailboxSyncMode] {
        var canonicalPathsByKey: [String: String] = [:]
        for path in availableMailboxPaths + preferences.map(\.mailboxPath) {
            let key = normalizedKey(for: path)
            if canonicalPathsByKey[key] == nil {
                canonicalPathsByKey[key] = path
            }
        }
        let inboxKey = normalizedKey(for: "INBOX")
        if canonicalPathsByKey[inboxKey] == nil {
            canonicalPathsByKey[inboxKey] = "INBOX"
        }

        var explicitModesByKey: [String: MailboxSyncMode] = [:]
        for preference in preferences {
            explicitModesByKey[normalizedKey(for: preference.mailboxPath)] = preference.mode
        }

        return Dictionary(uniqueKeysWithValues: canonicalPathsByKey.map { key, path in
            let defaultMode = defaultModesByKey[key] ?? (key == inboxKey ? .recent : .off)
            return (path, explicitModesByKey[key] ?? defaultMode)
        })
    }

    public static func selectedMailboxPaths(
        availableMailboxPaths: [String],
        preferences: [MailboxSyncPreference]
    ) -> [String] {
        effectiveModes(
            availableMailboxPaths: availableMailboxPaths,
            preferences: preferences
        )
        .filter { $0.value != .off }
        .map(\.key)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func selectedMailboxPaths(
        availableMailboxes: [Mailbox],
        preferences: [MailboxSyncPreference]
    ) -> [String] {
        effectiveModes(
            availableMailboxes: availableMailboxes,
            preferences: preferences
        )
        .filter { $0.value != .off }
        .map(\.key)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func normalizedKey(for path: String) -> String {
        path.caseInsensitiveCompare("INBOX") == .orderedSame ? "\u{0}inbox" : "\u{1}\(path)"
    }
}

public enum MailboxSyncPhase: String, Codable, Sendable {
    case discovery
    case recentImport = "recent-import"
    case backfill
    case incremental
    case idle
    case paused
    case failed
}

public struct MailboxSyncStatus: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public let mailboxPath: String
    public let phase: MailboxSyncPhase
    public let downloaded: Int
    public let estimatedTotal: Int?
    public let complete: Bool
    public let lastError: String?
    public let updatedAt: Date

    public init(
        accountID: AccountID,
        mailboxPath: String,
        phase: MailboxSyncPhase,
        downloaded: Int,
        estimatedTotal: Int?,
        complete: Bool,
        lastError: String?,
        updatedAt: Date
    ) {
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.phase = phase
        self.downloaded = downloaded
        self.estimatedTotal = estimatedTotal
        self.complete = complete
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public protocol MailSyncPreferenceRepository: AnyObject, Sendable {
    func syncPreferences(accountID: AccountID) throws -> MailSyncPreferences
    func saveSyncPreferences(_ preferences: MailSyncPreferences) throws
    func mailboxSyncPreferences(accountID: AccountID) throws -> [MailboxSyncPreference]
    func saveMailboxSyncPreference(_ preference: MailboxSyncPreference) throws
    func mailboxSyncStatuses(accountID: AccountID) throws -> [MailboxSyncStatus]
}
