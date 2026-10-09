import Foundation
import PlainpostCore
import PlainpostOperations

public struct AuditLogRowModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let actorID: String
    public let action: String
    public let targetSummary: String
    public let result: String

    public init(id: String, actorID: String, action: String, targetSummary: String, result: String) {
        self.id = id
        self.actorID = actorID
        self.action = action
        self.targetSummary = targetSummary
        self.result = result
    }
}

/// Writes an account-scoped plain-text copy of audit entries, for sharing where the raw
/// rotating log file cannot be (it holds every account on the device). The source `AuditEntry`
/// values carry no per-entry timestamp, so each line is `<action> · <result> · <target>`.
///
/// Writes only happen when the caller explicitly asks for an export (e.g. a tap on "Share
/// Audit Log"), never just because a page appeared, and each write first clears the
/// dedicated export folder so at most one exported file — and one account's audit data —
/// ever sits on disk at a time.
enum AuditLogExport {
    private static let directoryName = "PlainpostAuditExport"

    static func directory(in base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Removes any previously exported audit files. Safe to call when none exist.
    static func clear(_ directory: URL = Self.directory()) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func write(
        _ entries: [TimestampedAuditEntry],
        generatedAt: Date = Date(),
        to directory: URL = Self.directory()
    ) throws -> URL {
        clear(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = ["Plainpost audit log · exported \(generatedAt.formatted(date: .abbreviated, time: .shortened))"]
        let timestampFormatter = ISO8601DateFormatter()
        lines.append(contentsOf: entries.map { timestamped in
            let entry = timestamped.entry
            let time = timestamped.occurredAt.map(timestampFormatter.string(from:)) ?? "unknown time"
            return "\(time) · \(entry.action) · \(entry.result) · \(entry.targetType) \(entry.targetID)"
        })
        let url = directory.appendingPathComponent("Plainpost Audit Log \(UUID().uuidString.prefix(8)).txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
        return url
    }
}

public struct OperationActivityRowModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let state: PlainpostOperationState
    public let phase: String
    public let detail: String?
    public let providerID: String?
    public let modelID: String?
    public let accountEmail: String?
    public let resultDetail: String?
    public let isPartialFailure: Bool
    public let isSmartInboxOrganization: Bool
    public let current: Int
    public let total: Int?
    public let createdAt: Date
    public let updatedAt: Date
    public let attempt: Int
    public let maxAttempts: Int
    public let terminalOccurrenceAt: Date?

    public init(
        id: String,
        title: String,
        state: PlainpostOperationState,
        phase: String,
        detail: String?,
        providerID: String?,
        modelID: String?,
        accountEmail: String?,
        resultDetail: String?,
        isPartialFailure: Bool = false,
        isSmartInboxOrganization: Bool = false,
        current: Int,
        total: Int?,
        createdAt: Date,
        updatedAt: Date,
        attempt: Int = 0,
        maxAttempts: Int = 0,
        terminalOccurrenceAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.phase = phase
        self.detail = detail
        self.providerID = providerID
        self.modelID = modelID
        self.accountEmail = accountEmail
        self.resultDetail = resultDetail
        self.isPartialFailure = isPartialFailure
        self.isSmartInboxOrganization = isSmartInboxOrganization
        self.current = current
        self.total = total
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.terminalOccurrenceAt = terminalOccurrenceAt
    }

    public var isActive: Bool { state == .queued || state == .running || state == .paused }

    public var statusLabel: String {
        if isPartialFailure { return "Partial" }
        return state.rawValue.replacingOccurrences(of: "-", with: " ").capitalized
    }

    public var progressFraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(current) / Double(total)))
    }
}

public protocol AuditLogHandling: Sendable {
    func rows() throws -> [AuditLogRowModel]
}

public final class AuditLogService<Repository: AuditRepository & Sendable>: AuditLogHandling {
    private let repository: Repository
    private let displayLimit: Int
    private let selectedEntries: (@Sendable (Int) throws -> [AuditEntry])?

    public init(
        repository: Repository,
        displayLimit: Int = 200,
        selectedEntries: (@Sendable (Int) throws -> [AuditEntry])? = nil
    ) {
        self.repository = repository
        self.displayLimit = displayLimit
        self.selectedEntries = selectedEntries
    }

    public func rows() throws -> [AuditLogRowModel] {
        try (selectedEntries?(displayLimit) ?? repository.recentAuditEntries(limit: displayLimit))
            .map { entry in
                AuditLogRowModel(
                    id: entry.id,
                    actorID: entry.actorID,
                    action: entry.action,
                    targetSummary: "\(entry.targetType) \(entry.targetID)",
                    result: entry.result
                )
            }
    }

}

private struct OperationActivityLoadSnapshot: Sendable {
    let rows: [OperationActivityRowModel]
    let anchor: PlainpostDiagnosticsPageAnchor?
    let offset: Int
    let totalTerminalCount: Int
    let rangeLabel: String
}

public struct OperationDiagnosticsSource: Sendable {
    public let page: @Sendable (
        Date, PlainpostDiagnosticsPageAnchor?, Int, Int
    ) throws -> PlainpostDiagnosticsJobPage
    public let blockers: @Sendable () throws -> [PlainpostSyncBlocker]

    public init(
        page: @escaping @Sendable (
            Date, PlainpostDiagnosticsPageAnchor?, Int, Int
        ) throws -> PlainpostDiagnosticsJobPage,
        blockers: @escaping @Sendable () throws -> [PlainpostSyncBlocker]
    ) {
        self.page = page
        self.blockers = blockers
    }
}

@MainActor
public final class AuditLogViewModel: ObservableObject {
    public static let operationPageSize = 20
    @Published public private(set) var rows: [AuditLogRowModel]
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var operationRows: [OperationActivityRowModel]
    @Published public private(set) var operationPageOffset = 0
    @Published public private(set) var operationTotalCount = 0
    @Published public private(set) var operationRangeLabel = "0 of 0"
    @Published public private(set) var isLoadingOperations = false
    public let auditLogURL: URL?
    /// Writes the selected account's own audit entries to a plain-text file and returns its
    /// URL, for sharing on platforms (iOS) where `auditLogURL` stays nil because the on-device
    /// database and rotating log hold every account, not just the selected one. Nil wherever
    /// `auditLogURL` is also unavailable for another reason (no account selected, Node route).
    public let exportAuditLog: (() throws -> URL)?
    /// Share Audit Log is offered only where an export exists; the Node route has none.
    public var canShareAuditLog: Bool { exportAuditLog != nil }
    public let browserRegistrationStatus: BrowserNativeHostRegistrationStatus

    private let log: AuditLogHandling
    private let operationSource: OperationDiagnosticsSource?
    private let accountEmails: @Sendable () throws -> [AccountID: String]
    private var operationPageAnchor: PlainpostDiagnosticsPageAnchor?
    private var operationLoadGeneration = 0

    public init(
        log: AuditLogHandling,
        jobs: (any DurableJobRepository)? = nil,
        operationSource: OperationDiagnosticsSource? = nil,
        auditLogURL: URL? = nil,
        exportAuditLog: (() throws -> URL)? = nil,
        rows: [AuditLogRowModel] = [],
        operationRows: [OperationActivityRowModel] = [],
        browserRegistrationStatus: BrowserNativeHostRegistrationStatus = BrowserNativeHostRegistrationStatus(),
        accountEmails: @escaping @Sendable () throws -> [AccountID: String] = { [:] }
    ) {
        self.log = log
        self.exportAuditLog = exportAuditLog
        if let operationSource {
            self.operationSource = operationSource
        } else if let jobs {
            self.operationSource = OperationDiagnosticsSource(
                page: { now, anchor, offset, limit in
                    try jobs.diagnosticsJobPage(
                        now: now, anchor: anchor, offset: offset, limit: limit
                    )
                },
                blockers: { try jobs.smartInboxSyncBlockers() }
            )
        } else {
            self.operationSource = nil
        }
        self.auditLogURL = auditLogURL
        self.rows = rows
        self.operationRows = operationRows
        self.browserRegistrationStatus = browserRegistrationStatus
        self.accountEmails = accountEmails
    }

    public var browserRegistrationDiagnostic: BrowserNativeHostRegistrationDiagnostic {
        browserRegistrationStatus.diagnostic
    }

    public var canLoadNewerOperations: Bool { operationPageOffset > 0 }

    public var canLoadOlderOperations: Bool {
        operationPageOffset + operationRows.filter { !$0.isActive }.count < operationTotalCount
    }

    public func refresh() async throws {
        operationLoadGeneration += 1
        let requestGeneration = operationLoadGeneration
        let log = self.log
        let operationSource = self.operationSource
        let requestedAnchor = operationPageOffset == 0 ? nil : operationPageAnchor
        let requestedOffset = operationPageOffset
        let pageSize = Self.operationPageSize
        let accountEmails = self.accountEmails
        isLoadingOperations = operationSource != nil

        do {
            let loadedRows = try await Task.detached {
                try log.rows()
            }.value
            try Task.checkCancellation()
            guard requestGeneration == operationLoadGeneration else { return }

            let operationSnapshot: OperationActivityLoadSnapshot?
            if let operationSource {
                operationSnapshot = try await Self.loadOperationActivitySnapshot(
                    source: operationSource,
                    now: Date(),
                    anchor: requestedAnchor,
                    offset: requestedOffset,
                    pageSize: pageSize,
                    accountEmails: accountEmails
                )
                try Task.checkCancellation()
                guard requestGeneration == operationLoadGeneration else { return }
            } else {
                operationSnapshot = nil
            }

            rows = loadedRows
            if let operationSnapshot {
                apply(operationSnapshot)
            }
            statusMessage = loadedRows.isEmpty
                ? "No audit events"
                : "Showing latest \(loadedRows.count) audit events"
            isLoadingOperations = false
        } catch {
            if requestGeneration == operationLoadGeneration {
                isLoadingOperations = false
            }
            throw error
        }
    }

    public func refreshOperations(now: Date = Date()) async throws {
        try await loadOperations(
            now: now,
            offset: operationPageOffset,
            freshAnchor: operationPageOffset == 0
        )
    }

    public func refreshOperationsInBackground(now: Date = Date()) async throws {
        try await pollOperationsIfIdle(now: now)
    }

    public func pollOperationsIfIdle(now: Date = Date()) async throws {
        try Task.checkCancellation()
        guard !isLoadingOperations else { return }
        try await loadOperations(
            now: now,
            offset: operationPageOffset,
            freshAnchor: operationPageOffset == 0
        )
    }

    public func loadOlderOperations(now: Date = Date()) async throws {
        guard canLoadOlderOperations else { return }
        try await loadOperations(
            now: now,
            offset: operationPageOffset + Self.operationPageSize,
            freshAnchor: false
        )
    }

    public func loadNewerOperations(now: Date = Date()) async throws {
        guard canLoadNewerOperations else { return }
        try await loadOperations(
            now: now,
            offset: max(0, operationPageOffset - Self.operationPageSize),
            freshAnchor: false
        )
    }

    private func loadOperations(now: Date, offset: Int, freshAnchor: Bool) async throws {
        guard let operationSource else { return }
        operationLoadGeneration += 1
        let requestGeneration = operationLoadGeneration
        let requestedAnchor = freshAnchor ? nil : operationPageAnchor
        let pageSize = Self.operationPageSize
        let accountEmails = self.accountEmails
        isLoadingOperations = true

        do {
            let snapshot = try await Self.loadOperationActivitySnapshot(
                source: operationSource,
                now: now,
                anchor: requestedAnchor,
                offset: offset,
                pageSize: pageSize,
                accountEmails: accountEmails
            )
            try Task.checkCancellation()
            guard requestGeneration == operationLoadGeneration else { return }
            apply(snapshot)
            isLoadingOperations = false
        } catch {
            if requestGeneration == operationLoadGeneration {
                isLoadingOperations = false
            }
            throw error
        }
    }

    nonisolated private static func loadOperationActivitySnapshot(
        source: OperationDiagnosticsSource,
        now: Date,
        anchor: PlainpostDiagnosticsPageAnchor?,
        offset: Int,
        pageSize: Int,
        accountEmails: @escaping @Sendable () throws -> [AccountID: String]
    ) async throws -> OperationActivityLoadSnapshot {
        try await Task.detached {
            let page = try source.page(now, anchor, offset, pageSize)
            let blockers = try source.blockers()
            let emailByAccountID = try accountEmails()
            return makeOperationActivityLoadSnapshot(
                page: page,
                blockers: blockers,
                accountEmails: emailByAccountID
            )
        }.value
    }

    private func apply(_ snapshot: OperationActivityLoadSnapshot) {
        operationRows = snapshot.rows
        operationPageAnchor = snapshot.anchor
        operationPageOffset = snapshot.offset
        operationTotalCount = snapshot.totalTerminalCount
        operationRangeLabel = snapshot.rangeLabel
    }

    static func retainedJobs(_ jobs: [PlainpostDurableJob], now: Date) -> [PlainpostDurableJob] {
        jobs.filter { job in
            job.state == .queued || job.state == .running || job.state == .paused
                || job.updatedAt >= now.addingTimeInterval(-3_600)
        }
    }

    public static func preview() -> AuditLogViewModel {
        AuditLogViewModel(
            log: PreviewAuditLog(),
            rows: [
                AuditLogRowModel(
                    id: "aud_1",
                    actorID: "codex",
                    action: "draft.create",
                    targetSummary: "draft drf_preview",
                    result: "ok"
                )
            ],
            operationRows: [
                OperationActivityRowModel(
                    id: "job_preview",
                    title: "Organizing Smart Inbox",
                    state: .running,
                    phase: "Classifying",
                    detail: "Smart Inbox",
                    providerID: "foundation",
                    modelID: "apple-foundation-system",
                    accountEmail: nil,
                    resultDetail: nil,
                    current: 42,
                    total: 100,
                    createdAt: Date().addingTimeInterval(-18),
                    updatedAt: Date()
                )
            ]
        )
    }

    nonisolated private static func makeOperationActivityLoadSnapshot(
        page: PlainpostDiagnosticsJobPage,
        blockers: [PlainpostSyncBlocker],
        accountEmails: [AccountID: String]
    ) -> OperationActivityLoadSnapshot {
        OperationActivityLoadSnapshot(
            rows: (page.activeJobs + page.terminalJobs)
                .filter { $0.pauseReason != "smart-inbox-follow-up" }
                .map {
                    activityRow($0, accountEmails: accountEmails, blockers: blockers)
                },
            anchor: page.anchor,
            offset: page.offset,
            totalTerminalCount: page.totalTerminalCount,
            rangeLabel: operationRangeLabel(for: page)
        )
    }

    nonisolated private static func operationRangeLabel(
        for page: PlainpostDiagnosticsJobPage
    ) -> String {
        if page.totalTerminalCount == 0 {
            return "0 of 0"
        }
        if page.terminalJobs.isEmpty {
            return "\(min(page.offset, page.totalTerminalCount)) of \(page.totalTerminalCount)"
        }
        let upperBound = min(page.offset + page.terminalJobs.count, page.totalTerminalCount)
        let lowerBound = min(page.offset + 1, upperBound)
        return "\(lowerBound)–\(upperBound) of \(page.totalTerminalCount)"
    }

    nonisolated private static func activityRow(
        _ job: PlainpostDurableJob,
        accountEmails: [AccountID: String],
        blockers: [PlainpostSyncBlocker]
    ) -> OperationActivityRowModel {
        let aiInput = try? JSONDecoder().decode(
            PlainpostAIOperationInput.self,
            from: Data(job.payloadJSON.utf8)
        )
        let syncInput = try? JSONDecoder().decode(
            PlainpostInboxSyncInput.self,
            from: Data(job.payloadJSON.utf8)
        )
        return OperationActivityRowModel(
            id: job.id,
            title: title(for: job, aiInput: aiInput),
            state: job.state,
            phase: display(job.progress?.phase ?? job.state.rawValue),
            detail: job.progress?.label,
            providerID: aiInput?.providerID,
            modelID: aiInput?.diagnosticsModelID,
            accountEmail: syncInput.flatMap { accountEmails[$0.accountID] },
            resultDetail: resultDetail(for: job, aiInput: aiInput, blockers: blockers),
            isPartialFailure: job.state == .completed
                && job.errorCode == "SMART_INBOX_PARTIAL_FAILURE",
            isSmartInboxOrganization: job.kind == .aiOperation && aiInput?.operation == .recategorizeInbox,
            current: job.progress?.current ?? 0,
            total: job.progress?.total,
            createdAt: job.createdAt,
            updatedAt: job.updatedAt,
            attempt: job.attempt,
            maxAttempts: job.maxAttempts,
            terminalOccurrenceAt: job.state == .queued || job.state == .running || job.state == .paused
                ? nil
                : job.updatedAt
        )
    }

    nonisolated private static func resultDetail(
        for job: PlainpostDurableJob,
        aiInput: PlainpostAIOperationInput?,
        blockers: [PlainpostSyncBlocker]
    ) -> String? {
        switch job.state {
        case .queued:
            return safeErrorDetail(for: job) ?? "Waiting for the background worker"
        case .running:
            return nil
        case .paused:
            switch job.pauseReason {
            case "thread-summary": return "Paused for a thread summary"
            case "message-translation": return "Paused for message translation"
            case "thread-question": return "Paused for a thread question"
            case "ai-draft": return "Paused for an AI draft"
            case "draft-rewrite": return "Paused for an AI draft rewrite"
            case "mail-sync":
                return syncBlockerDetail(
                    prefix: "Waiting for mail sync",
                    blockers: blockers
                )
            case "mail-sync-failed":
                return syncBlockerDetail(
                    prefix: "Waiting for successful mail sync",
                    blockers: blockers
                )
            case "credentials-unavailable": return "Waiting for Mail Keychain"
            case "user-requested": return "Paused by you"
            case "low-power": return "Paused in Low Power Mode"
            case "smart-inbox-follow-up": return "Waiting for the paused Smart Inbox run"
            default: return "Paused for interactive AI work"
            }
        case .completed where job.errorCode == "SMART_INBOX_PARTIAL_FAILURE":
            return "Some messages could not be classified. Plainpost will try them again after the messages or AI setup change."
        case .completed:
            return nil
        case .failed, .deliveryUncertain:
            return safeErrorDetail(for: job) ?? "The operation did not complete"
        case .cancelled:
            return "Cancelled"
        }
    }

    nonisolated private static func syncBlockerDetail(
        prefix: String,
        blockers: [PlainpostSyncBlocker]
    ) -> String {
        if blockers.count == 1, let blocker = blockers.first {
            return "\(prefix) (\(blocker.accountEmail))"
        }
        if blockers.count > 1 {
            return "\(prefix) (\(blockers.count) accounts)"
        }
        return prefix
    }

    nonisolated private static func safeErrorDetail(for job: PlainpostDurableJob) -> String? {
        switch job.errorCode {
        case "DATABASE_BUSY":
            return "The local mail database is busy. Plainpost will retry automatically."
        case "IMAP_AUTHENTICATION_REJECTED":
            return "The mail server rejected the saved account credentials."
        case "IMAP_CONNECTION_LIMIT":
            return "The mail server has too many simultaneous connections. Plainpost will retry."
        case "IMAP_THROTTLED":
            return "The mail server temporarily limited synchronization. Plainpost will retry."
        case "IMAP_TLS_FAILED":
            return "Plainpost could not establish a trusted secure connection to the mail server."
        case "IMAP_NETWORK_UNAVAILABLE":
            return "The mail server did not respond in time. Plainpost will retry."
        case "IMAP_RESOURCE_LIMIT":
            return "The mail server response exceeded Plainpost's safety limit."
        case "IMAP_PROTOCOL_ERROR":
            return "The mail server returned an unsupported response."
        case "SMTP_UNAVAILABLE":
            return "The delivery operation failed. Review its status before retrying."
        case "DELIVERY_UNCERTAIN":
            return "SMTP delivery may have crossed the server acceptance boundary. Review before retrying."
        case "OPERATION_FAILED":
            return "The local operation failed and will be retried when safe."
        case .none:
            return nil
        default:
            return nil
        }
    }

    nonisolated private static func title(
        for job: PlainpostDurableJob,
        aiInput: PlainpostAIOperationInput?
    ) -> String {
        if let operation = aiInput?.operation {
            switch operation {
            case .summarizeThread: return "Summarizing thread"
            case .summarizeMessage: return "Summarizing message"
            case .translateMessage: return "Translating message"
            case .answerThreadQuestion: return "Answering thread question"
            case .answerMailboxQuestion: return "Answering mailbox question"
            case .draftReply: return "Drafting reply"
            case .rewriteDraft: return "Rewriting draft"
            case .classifyMessage: return "Classifying message"
            case .recategorizeInbox: return "Organizing Smart Inbox"
            case .rebuildIndex: return "Rebuilding semantic index"
            }
        }
        switch job.kind {
        case .inboxSync: return "Syncing inbox"
        case .historicalSync: return "Downloading mail history"
        case .approvedDelivery: return "Sending approved message"
        case .denySend: return "Updating approval"
        case .mailboxFlag: return "Updating message status"
        case .mailboxArchive: return "Archiving message"
        case .aiOperation: return "AI operation"
        case .searchRebuild: return "Rebuilding semantic index"
        }
    }

    nonisolated private static func display(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

private struct PreviewAuditLog: AuditLogHandling {
    func rows() throws -> [AuditLogRowModel] {
        [
            AuditLogRowModel(
                id: "aud_1",
                actorID: "codex",
                action: "draft.create",
                targetSummary: "draft drf_preview",
                result: "ok"
            )
        ]
    }
}
