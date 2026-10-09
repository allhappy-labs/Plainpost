import Foundation
import PlainpostCore

public enum SmartInboxDisplayBundle: String, CaseIterable, Identifiable, Sendable {
    case people
    case notifications
    case newsletters
    case invitations
    case invitationResponses
    case updates

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .people: "People"
        case .notifications: "Notifications"
        case .newsletters: "Newsletters"
        case .invitations: "Invitations"
        case .invitationResponses: "Invitation responses"
        case .updates: "Updates"
        }
    }

    public var systemImage: String {
        switch self {
        case .people: "person.crop.circle"
        case .notifications: "bell.badge"
        case .newsletters: "newspaper"
        case .invitations: "calendar.badge.plus"
        case .invitationResponses: "calendar.badge.checkmark"
        case .updates: "rectangle.3.group"
        }
    }

    static func bundle(for category: SmartCategory) -> Self {
        switch category {
        case .personal:
            .people
        case .notification, .security, .system:
            .notifications
        case .newsletter:
            .newsletters
        case .invitation:
            .invitations
        case .invitationResponse:
            .invitationResponses
        case .receipt, .finance, .travel, .support, .social, .unknown:
            .updates
        }
    }
}

extension SmartInboxDisplayBundle {
    /// The iPhone category chips, in order. "All" is not a bundle; it is `nil`.
    static let chipOrder: [SmartInboxDisplayBundle] = [.people, .notifications, .updates, .newsletters, .invitations]

    /// The chip a category's messages appear under. Invitation responses sit with invitations.
    static func chip(for category: SmartCategory) -> SmartInboxDisplayBundle {
        let bundle = Self.bundle(for: category)
        return bundle == .invitationResponses ? .invitations : bundle
    }

    /// The chips to show for `rows`: every chip except Invitations, which appears only when
    /// an invitation or a response is listed.
    static func chips(for rows: [MessageRowModel]) -> [SmartInboxDisplayBundle] {
        let hasInvitations = rows.contains { chip(for: $0.category) == .invitations }
        return chipOrder.filter { $0 != .invitations || hasInvitations }
    }
}

public enum SmartInboxHistoricalSectionID: Hashable, Sendable {
    case yesterday
    case thisWeek
    case lastWeek
    case month(year: Int, month: Int)
    case undated
}

public struct SmartInboxSenderSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String
    public let displayName: String
    public let messageCount: Int
    public let hasUnread: Bool
}

public struct SmartInboxTodayBundle: Identifiable, Equatable, Sendable {
    public let id: SmartInboxDisplayBundle
    public let title: String
    public let systemImage: String
    public let count: Int
    public let senderSummaries: [SmartInboxSenderSummary]
    public let hasUnread: Bool
    public let rows: [MessageRowModel]

    public init(
        id: SmartInboxDisplayBundle,
        title: String,
        systemImage: String,
        count: Int,
        senderSummaries: [SmartInboxSenderSummary],
        hasUnread: Bool,
        rows: [MessageRowModel]
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.senderSummaries = senderSummaries
        self.hasUnread = hasUnread
        self.rows = rows
    }
}

public struct SmartInboxHistoricalSection: Identifiable, Equatable, Sendable {
    public let id: SmartInboxHistoricalSectionID
    public let title: String
    public let rows: [MessageRowModel]

    public init(id: SmartInboxHistoricalSectionID, title: String, rows: [MessageRowModel]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

public struct SmartInboxTriageModel: Equatable, Sendable {
    public let todayPromotedRows: [MessageRowModel]
    public let todayBundles: [SmartInboxTodayBundle]
    public let historicalSections: [SmartInboxHistoricalSection]

    private let todayRows: [MessageRowModel]

    private init(
        todayPromotedRows: [MessageRowModel],
        todayBundles: [SmartInboxTodayBundle],
        historicalSections: [SmartInboxHistoricalSection],
        todayRows: [MessageRowModel]
    ) {
        self.todayPromotedRows = todayPromotedRows
        self.todayBundles = todayBundles
        self.historicalSections = historicalSections
        self.todayRows = todayRows
    }

    public static func build(
        rows: [MessageRowModel],
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> SmartInboxTriageModel {
        let todayRows = rows.filter { row in
            row.sentAt.map { calendar.isDate($0, inSameDayAs: now) } == true
        }
        let historicalRows = rows.filter { row in
            row.sentAt.map { !calendar.isDate($0, inSameDayAs: now) } ?? true
        }
        let promoted = todayRows.filter(isPromoted).sorted(by: orderedBefore)

        let bundles = SmartInboxDisplayBundle.allCases.compactMap { bundle -> SmartInboxTodayBundle? in
            let allRows = todayRows
                .filter { SmartInboxDisplayBundle.bundle(for: $0.category) == bundle }
                .sorted(by: newestBefore)
            let ordinaryRows = allRows.filter { !isPromoted($0) }
            guard !ordinaryRows.isEmpty else { return nil }
            return SmartInboxTodayBundle(
                id: bundle,
                title: bundle.title,
                systemImage: bundle.systemImage,
                count: allRows.count,
                senderSummaries: senderSummaries(from: allRows),
                hasUnread: allRows.contains(where: \.isUnread),
                rows: ordinaryRows
            )
        }

        return SmartInboxTriageModel(
            todayPromotedRows: promoted,
            todayBundles: bundles,
            historicalSections: historicalSections(
                from: historicalRows,
                now: now,
                calendar: calendar,
                locale: locale
            ),
            todayRows: todayRows
        )
    }

    public func drillInRows(for bundle: SmartInboxDisplayBundle) -> [MessageRowModel] {
        todayRows
            .filter { SmartInboxDisplayBundle.bundle(for: $0.category) == bundle }
            .sorted(by: Self.orderedBefore)
    }

    private static func isPromoted(_ row: MessageRowModel) -> Bool {
        row.isPinned || row.smartPriority == .high || row.requiresAction
    }

    private static func rank(_ row: MessageRowModel) -> Int {
        if row.isPinned { return 0 }
        if row.smartPriority == .high && row.requiresAction { return 1 }
        if row.requiresAction { return 2 }
        if row.smartPriority == .high { return 3 }
        return 4
    }

    private static func orderedBefore(_ lhs: MessageRowModel, _ rhs: MessageRowModel) -> Bool {
        let lhsRank = rank(lhs)
        let rhsRank = rank(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return newestBefore(lhs, rhs)
    }

    private static func newestBefore(_ lhs: MessageRowModel, _ rhs: MessageRowModel) -> Bool {
        let lhsDate = lhs.sentAt ?? .distantPast
        let rhsDate = rhs.sentAt ?? .distantPast
        return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
    }

    private static func senderSummaries(
        from rows: [MessageRowModel]
    ) -> [SmartInboxSenderSummary] {
        struct Accumulator {
            let sender: String
            let displayName: String
            var messageCount: Int
            var hasUnread: Bool
        }

        var order: [String] = []
        var values: [String: Accumulator] = [:]
        for row in rows.sorted(by: newestBefore) {
            let key = row.sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if var existing = values[key] {
                existing.messageCount += 1
                existing.hasUnread = existing.hasUnread || row.isUnread
                values[key] = existing
                continue
            }
            let name = row.senderDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            order.append(key)
            values[key] = Accumulator(
                sender: row.sender,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? row.sender,
                messageCount: 1,
                hasUnread: row.isUnread
            )
        }

        return order.compactMap { key in
            values[key].map {
                SmartInboxSenderSummary(
                    id: key,
                    sender: $0.sender,
                    displayName: $0.displayName,
                    messageCount: $0.messageCount,
                    hasUnread: $0.hasUnread
                )
            }
        }
    }

    private static func historicalSections(
        from rows: [MessageRowModel],
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [SmartInboxHistoricalSection] {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)
        let previousWeek = currentWeek.flatMap { interval in
            calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start)
        }.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)

        let grouped = Dictionary(grouping: rows) { row -> SmartInboxHistoricalSectionID in
            guard let date = row.sentAt else { return .undated }
            if yesterday.map({ calendar.isDate(date, inSameDayAs: $0) }) == true { return .yesterday }
            if currentWeek?.contains(date) == true { return .thisWeek }
            if previousWeek?.contains(date) == true { return .lastWeek }
            let components = calendar.dateComponents([.year, .month], from: date)
            return .month(year: components.year ?? 1, month: components.month ?? 1)
        }

        return grouped.map { id, sectionRows in
            SmartInboxHistoricalSection(
                id: id,
                title: historicalTitle(for: id, now: now, calendar: calendar, locale: locale),
                rows: sectionRows.sorted(by: newestBefore)
            )
        }.sorted { historicalOrder($0.id, $1.id) }
    }

    private static func historicalOrder(
        _ lhs: SmartInboxHistoricalSectionID,
        _ rhs: SmartInboxHistoricalSectionID
    ) -> Bool {
        func fixedRank(_ id: SmartInboxHistoricalSectionID) -> Int {
            switch id {
            case .yesterday: 0
            case .thisWeek: 1
            case .lastWeek: 2
            case .month: 3
            case .undated: 4
            }
        }
        let lhsRank = fixedRank(lhs)
        let rhsRank = fixedRank(rhs)
        guard lhsRank == rhsRank else { return lhsRank < rhsRank }
        switch (lhs, rhs) {
        case let (.month(lhsYear, lhsMonth), .month(rhsYear, rhsMonth)):
            return lhsYear == rhsYear ? lhsMonth > rhsMonth : lhsYear > rhsYear
        default:
            return false
        }
    }

    private static func historicalTitle(
        for id: SmartInboxHistoricalSectionID,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        switch id {
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case let .month(year, month):
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
                return "Earlier"
            }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            let currentYear = calendar.component(.year, from: now)
            formatter.setLocalizedDateFormatFromTemplate(year == currentYear ? "MMMM" : "MMMMy")
            return formatter.string(from: date)
        case .undated:
            return "Earlier"
        }
    }
}

/// Keeps the expensive date grouping stable while SwiftUI reevaluates a
/// scrolling Smart Inbox. `contentRevision` changes for both persisted and
/// optimistic row updates, so the cache can avoid comparing every row during
/// scrolling while still rebuilding immediately when mailbox content changes.
final class SmartInboxTriageModelSnapshotCache {
    private var cachedContentRevision: UInt64?
    private var cachedDay: Date?
    private var cachedCalendar: Calendar?
    private var cachedLocaleIdentifier: String?
    private var cachedModel: SmartInboxTriageModel?

    private(set) var buildCount = 0

    func model(
        rows: [MessageRowModel],
        contentRevision: UInt64,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> SmartInboxTriageModel {
        let day = calendar.startOfDay(for: now)
        if cachedContentRevision == contentRevision,
           cachedDay == day,
           cachedCalendar == calendar,
           cachedLocaleIdentifier == locale.identifier,
           let cachedModel {
            return cachedModel
        }

        let model = SmartInboxTriageModel.build(
            rows: rows,
            now: now,
            calendar: calendar,
            locale: locale
        )
        cachedContentRevision = contentRevision
        cachedDay = day
        cachedCalendar = calendar
        cachedLocaleIdentifier = locale.identifier
        cachedModel = model
        buildCount += 1
        return model
    }
}
