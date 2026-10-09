import Foundation

public enum PlainpostWorkAreaKind: Equatable, Sendable {
    case mailbox
    case calendar
    case settings
    case approvalQueue
    case aiIndexStatus
}

public enum PlainpostDestination: String, CaseIterable, Identifiable, Sendable {
    #if os(macOS)
    case calendar
    #endif
    case smartInbox
    case allInboxes
    case personal
    case notifications
    case newsletters
    case drafts
    case sent
    case archive
    case trash
    case approvalQueue
    case labels
    case aiIndexStatus
    case settings

    public var id: String { rawValue }

    public static let mailboxDestinations: [PlainpostDestination] = [
        .smartInbox,
        .allInboxes,
        .drafts,
        .sent,
        .archive,
        .trash
    ]

    public static let utilityDestinations: [PlainpostDestination] = [
        .approvalQueue,
        .labels,
        .aiIndexStatus,
        .settings
    ]

    public static let iOSPrimaryDestinations = mailboxDestinations + utilityDestinations
    #if os(macOS)
    public static let primaryDestinations = mailboxDestinations + [.calendar] + utilityDestinations
    #else
    public static let primaryDestinations = iOSPrimaryDestinations
    #endif

    public var title: String {
        switch self {
        #if os(macOS)
        case .calendar: "Calendar"
        #endif
        case .smartInbox:
            "Smart Inbox"
        case .allInboxes:
            "All Inboxes"
        case .personal:
            "Personal"
        case .notifications:
            "Notifications"
        case .newsletters:
            "Newsletters"
        case .drafts:
            "Drafts"
        case .sent:
            "Sent"
        case .archive:
            "Archive"
        case .trash:
            "Trash"
        case .approvalQueue:
            "Agent approvals"
        case .labels:
            "Labels"
        case .aiIndexStatus:
            "AI Index Status"
        case .settings:
            "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        #if os(macOS)
        case .calendar: "calendar"
        #endif
        case .smartInbox:
            "tray.full"
        case .allInboxes:
            "mail.stack"
        case .personal:
            "person.2"
        case .notifications:
            "clock"
        case .newsletters:
            "newspaper"
        case .drafts:
            "folder"
        case .sent:
            "paperplane"
        case .archive:
            "archivebox"
        case .trash:
            "trash"
        case .approvalQueue:
            "shield"
        case .labels:
            "tag"
        case .aiIndexStatus:
            "chart.bar"
        case .settings:
            "gearshape"
        }
    }

    public var usesMailboxList: Bool {
        switch self {
        #if os(macOS)
        case .calendar: false
        #endif
        case .smartInbox, .allInboxes, .personal, .notifications, .newsletters, .drafts, .sent, .archive, .trash:
            true
        case .settings, .labels, .aiIndexStatus, .approvalQueue:
            false
        }
    }

    public var usesSmartGrouping: Bool {
        self == .smartInbox
    }

    public var showsThreadReader: Bool {
        switch self {
        #if os(macOS)
        case .calendar: false
        #endif
        case .smartInbox, .allInboxes, .personal, .notifications, .newsletters, .sent, .archive:
            true
        case .drafts, .trash, .labels:
            false
        case .approvalQueue, .aiIndexStatus, .settings:
            false
        }
    }

    public var syncMailboxPath: String? {
        switch self {
        case .sent:
            "Sent"
        case .archive:
            "Archive"
        default:
            nil
        }
    }

    public var workAreaKind: PlainpostWorkAreaKind {
        switch self {
        #if os(macOS)
        case .calendar: .calendar
        #endif
        case .settings, .labels:
            .settings
        case .approvalQueue:
            .approvalQueue
        case .aiIndexStatus:
            .aiIndexStatus
        default:
            .mailbox
        }
    }

    public var settingsSection: PlainpostSettingsSection? {
        switch self {
        case .labels:
            .rulesLabels
        default:
            nil
        }
    }
}

public enum PlainpostSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case accounts
    case smartInbox
    case rulesLabels
    case notifications
    case privacy
    case plainpostAccount
    case syncNode
    #if os(macOS)
    case calendars
    #endif
    case troubleshooting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accounts:
            "Add Account"
        case .smartInbox:
            "Smart Inbox & AI"
        case .rulesLabels:
            "Rules & Labels"
        case .notifications:
            "Notifications"
        case .privacy:
            "Privacy"
        case .plainpostAccount:
            "Plainpost Account"
        case .syncNode:
            "Sync Node"
        #if os(macOS)
        case .calendars:
            "Calendars"
        #endif
        case .troubleshooting:
            "Troubleshooting"
        }
    }

    public var systemImage: String {
        switch self {
        case .accounts:
            "plus.circle"
        case .smartInbox:
            "sparkles"
        case .rulesLabels:
            "line.3.horizontal.decrease.circle"
        case .notifications:
            "bell"
        case .privacy:
            "hand.raised"
        case .plainpostAccount:
            "person.badge.shield.checkmark"
        case .syncNode:
            "server.rack"
        #if os(macOS)
        case .calendars:
            "calendar"
        #endif
        case .troubleshooting:
            "wrench.and.screwdriver"
        }
    }
}

public enum PlainpostSettingsGroup: String, CaseIterable, Identifiable, Sendable {
    case accounts
    case mail
    case plainpost
    case troubleshooting

    public var id: String { rawValue }

    public var title: String? {
        switch self {
        case .accounts: "Accounts"
        case .mail: "Mail"
        case .plainpost: "Plainpost"
        case .troubleshooting: nil
        }
    }

    public var sections: [PlainpostSettingsSection] {
        switch self {
        case .accounts:
            []
        case .mail:
            [.smartInbox, .rulesLabels, .notifications, .privacy]
        case .plainpost:
            #if os(macOS)
            [.plainpostAccount, .syncNode, .calendars]
            #else
            [.plainpostAccount, .syncNode]
            #endif
        case .troubleshooting:
            [.troubleshooting]
        }
    }
}

public enum ApprovalQueueFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pending
    case highRisk
    case failed
    case sent
    case requiresAuth
    case attachments
    case externalRecipients

    public var id: String { rawValue }

    public static let defaultFilters: [ApprovalQueueFilter] = [
        .pending,
        .failed,
        .all
    ]

    public var title: String {
        switch self {
        case .all:
            "All activity"
        case .pending:
            "Pending"
        case .highRisk:
            "High risk"
        case .failed:
            "Failed"
        case .sent:
            "Sent"
        case .requiresAuth:
            "Requires auth"
        case .attachments:
            "Attachments"
        case .externalRecipients:
            "External recipients"
        }
    }

    public var systemImage: String {
        switch self {
        case .all:
            "tray.full"
        case .pending:
            "clock"
        case .highRisk:
            "exclamationmark.triangle"
        case .failed:
            "xmark.circle"
        case .sent:
            "checkmark.circle"
        case .requiresAuth:
            "lock"
        case .attachments:
            "paperclip"
        case .externalRecipients:
            "person.crop.circle.badge.exclamationmark"
        }
    }

    public func matches(_ item: ApprovalQueueItemModel) -> Bool {
        switch self {
        case .all:
            true
        case .pending:
            item.status.caseInsensitiveCompare("pending") == .orderedSame
        case .highRisk:
            item.requiresAuthentication || item.riskFlags.contains { flag in
                flag.localizedCaseInsensitiveContains("risk") || flag.localizedCaseInsensitiveContains("external")
            }
        case .failed:
            item.status.caseInsensitiveCompare("failed") == .orderedSame
        case .sent:
            item.status.caseInsensitiveCompare("sent") == .orderedSame
        case .requiresAuth:
            item.requiresAuthentication
        case .attachments:
            item.hasAttachments
        case .externalRecipients:
            item.riskFlags.contains { $0.localizedCaseInsensitiveContains("external") }
                || item.recipientSummary.split(separator: ",").count > 1
        }
    }
}
