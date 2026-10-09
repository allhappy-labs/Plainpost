import Foundation
import PlainpostCore
import PlainpostOperations

enum KeepOnDeviceOption: Hashable, CaseIterable, Identifiable {
    case last100, last250, last500, last1000, allMail
    var id: Self { self }

    var limit: Int? {
        switch self {
        case .last100: 100
        case .last250: 250
        case .last500: 500
        case .last1000: 1000
        case .allMail: nil
        }
    }

    var title: String {
        guard let limit else { return "All mail" }
        return "Last \(limit.formatted()) messages"
    }

    static func current(downloadCompleteHistory: Bool, recentMessageLimit: Int) -> KeepOnDeviceOption {
        if downloadCompleteHistory { return .allMail }
        let limited = allCases.filter { $0.limit != nil }
        // Ties round down, so 375 keeps the smaller download.
        return limited.min {
            abs($0.limit! - recentMessageLimit) < abs($1.limit! - recentMessageLimit)
        } ?? .last100
    }
}

enum MailboxDisplayName {
    static func name(for path: String) -> String {
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return "Inbox" }
        let last = path.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? path
        return last.caseInsensitiveCompare("INBOX") == .orderedSame ? "Inbox" : last
    }
}

/// Download progress copy; with no estimate yet (nil or 0) it is just "Downloading".
public enum DownloadProgressText {
    public static func text(downloaded: Int, estimatedTotal: Int?) -> String {
        guard let total = estimatedTotal, total > 0 else { return "Downloading" }
        return "Downloading \(downloaded.formatted()) of \(total.formatted())"
    }
}

enum MailboxSyncStatusText {
    static func text(_ status: MailboxSyncStatus) -> String? {
        if status.lastError != nil || status.phase == .failed { return "Couldn't sync this folder" }
        switch status.phase {
        case .discovery, .recentImport, .backfill:
            return DownloadProgressText.text(downloaded: status.downloaded, estimatedTotal: status.estimatedTotal)
        case .paused: return "Paused"
        case .incremental, .idle, .failed: return nil
        }
    }
}


/// The host's complete-history download acts on the runtime's selected account only, so the
/// account page uses it, and shows its progress, only when it is that account's page.
enum AccountHistoryDownloadScope {
    static func appliesToPage(pageAccountID: AccountID, hostAccountID: AccountID?) -> Bool {
        hostAccountID == pageAccountID
    }

    /// The account page's Status: a sync failure first, then the host's history progress for
    /// this account, then the account's own sync status.
    static func status(
        lastSyncError: String?,
        hostStatus: String?,
        pageAccountID: AccountID,
        hostAccountID: AccountID?,
        syncStatusMessage: String
    ) -> String {
        if let lastSyncError { return lastSyncError }
        if let hostStatus, appliesToPage(pageAccountID: pageAccountID, hostAccountID: hostAccountID) {
            return hostStatus
        }
        return syncStatusMessage
    }
}
