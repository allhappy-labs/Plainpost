import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Troubleshooting settings page: manual sync, current and recent activity (no raw
/// IDs, provider/model internals, or attempt counters), the search index rebuild, and the
/// local audit log. Replaces the old Diagnostics and Local Storage panels.
struct TroubleshootingSettingsPage: View {
    @ObservedObject var auditLog: AuditLogViewModel
    @ObservedObject var maintenance: MailMaintenanceViewModel
    @ObservedObject var accountSetup: AccountSetupViewModel
    @ObservedObject var searchIndexRebuild: MailSearchIndexRebuildController
    @ObservedObject private var smartInboxActivity: SmartInboxActivityCoordinator
    @ObservedObject private var browserRegistrationStatus: BrowserNativeHostRegistrationStatus
    #if os(iOS)
    @State private var exportedAuditLogURL: URL?
    @State private var isPresentingShareSheet = false
    @State private var exportErrorMessage: String?
    #endif

    init(
        auditLog: AuditLogViewModel,
        maintenance: MailMaintenanceViewModel,
        accountSetup: AccountSetupViewModel,
        searchIndexRebuild: MailSearchIndexRebuildController
    ) {
        self.auditLog = auditLog
        self.maintenance = maintenance
        self.accountSetup = accountSetup
        self.searchIndexRebuild = searchIndexRebuild
        self._smartInboxActivity = ObservedObject(wrappedValue: maintenance.smartInboxActivity)
        self._browserRegistrationStatus = ObservedObject(wrappedValue: auditLog.browserRegistrationStatus)
    }

    private var syncStatusIsFailure: Bool {
        if case .failure = maintenance.syncState { return true }
        return false
    }

    private var activeOperations: [OperationActivityRowModel] {
        Self.reconciledActiveOperations(
            auditLog.operationRows,
            smartInboxActivity: smartInboxActivity.presentation,
            smartInboxEnabled: maintenance.smartInboxEnabled
        )
    }

    /// Overlays the sidebar's live Smart Inbox progress onto the matching diagnostics row,
    /// and presents the Smart Inbox job as paused (with an explanatory detail) while Smart
    /// Inbox is turned off. Moved from the old `DiagnosticsPanel` unchanged.
    static func reconciledActiveOperations(
        _ rows: [OperationActivityRowModel],
        smartInboxActivity: SmartInboxActivityPresentation?,
        smartInboxEnabled: Bool = true
    ) -> [OperationActivityRowModel] {
        rows.filter(\.isActive).map { row in
            let disabled = !smartInboxEnabled && row.isSmartInboxOrganization
            guard let smartInboxActivity, row.id == smartInboxActivity.id else {
                return row.replacingActivityPresentation(
                    current: row.current, total: row.total, smartInboxDisabled: disabled
                )
            }
            return row.replacingActivityPresentation(
                current: smartInboxActivity.processed,
                total: smartInboxActivity.total,
                smartInboxDisabled: disabled
            )
        }
    }

    var body: some View {
        SettingsPage(.troubleshooting) {
            Section("Sync") {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent(
                        "Last sync",
                        value: MailLastSyncPolicy.description(
                            of: maintenance.lastSuccessfulSyncAt, now: context.date
                        )
                    )
                    .accessibilityIdentifier("troubleshooting.last-sync")
                }
                Button(maintenance.syncButtonTitle) { Task { await maintenance.syncNow() } }
                    .disabled(maintenance.isSyncing)
                    .accessibilityIdentifier("diagnostics.sync-now")
                if !maintenance.syncState.message.isEmpty {
                    HStack(spacing: 6) {
                        if maintenance.syncState.isInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Text(maintenance.syncState.message)
                            .font(.caption)
                            .foregroundStyle(syncStatusIsFailure ? Color.orange : Color.secondary)
                    }
                }
            }
            Section("Activity") {
                let active = activeOperations
                if active.isEmpty {
                    LabeledContent("Now", value: "Nothing running")
                } else {
                    ForEach(active) { OperationActivityRow(operation: $0) }
                }
                if auditLog.operationTotalCount > 0 {
                    NavigationLink("Recent Events") {
                        TroubleshootingRecentEventsPage(auditLog: auditLog)
                    }
                }
            }
            SearchIndexDiagnosticsPanel(controller: searchIndexRebuild)
            #if os(macOS)
            Section("Logs") {
                if let url = auditLog.auditLogURL {
                    Button("Open Audit Log") { NSWorkspace.shared.open(url) }
                }
                Button("Show Data Folder in Finder") {
                    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Plainpost", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            #else
            if auditLog.canShareAuditLog {
                Section("Logs") {
                    Button("Share Audit Log") { shareAuditLog() }
                    if let exportErrorMessage {
                        Text(exportErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            #endif
            #if os(macOS)
            let browser = auditLog.browserRegistrationDiagnostic
            if browser.needsAttention {
                Section("Browser Extension") {
                    Text(browser.detail)
                }
            }
            #endif
        }
        .task {
            while !Task.isCancelled {
                maintenance.refreshActivity()
                try? await auditLog.pollOperationsIfIdle()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        #if os(iOS)
        .onDisappear { AuditLogExport.clear() }
        .sheet(isPresented: $isPresentingShareSheet) {
            if let exportedAuditLogURL {
                ActivityShareSheet(activityItems: [exportedAuditLogURL])
            }
        }
        #endif
    }

    #if os(iOS)
    /// Generates the account-scoped export only now, on the explicit tap — never just
    /// because this page appeared — so at most one export ever sits on disk.
    private func shareAuditLog() {
        guard let exportAuditLog = auditLog.exportAuditLog else { return }
        do {
            exportedAuditLogURL = try exportAuditLog()
            exportErrorMessage = nil
            isPresentingShareSheet = true
        } catch {
            exportedAuditLogURL = nil
            exportErrorMessage = "Couldn't prepare the audit log."
        }
    }
    #endif
}

#if os(iOS)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

struct TroubleshootingRecentEventsPage: View {
    @ObservedObject var auditLog: AuditLogViewModel

    private var recentOperations: [OperationActivityRowModel] {
        auditLog.operationRows.filter { !$0.isActive }
    }

    var body: some View {
        List {
            ForEach(recentOperations) { OperationActivityRow(operation: $0) }
            HStack {
                Button("Newer") { Task { try? await auditLog.loadNewerOperations() } }
                    .disabled(auditLog.isLoadingOperations || !auditLog.canLoadNewerOperations)
                    .accessibilityIdentifier("DiagnosticsEventsNewer")
                Spacer()
                if auditLog.isLoadingOperations {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("DiagnosticsEventsLoading")
                } else {
                    Text(auditLog.operationRangeLabel).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Older") { Task { try? await auditLog.loadOlderOperations() } }
                    .disabled(auditLog.isLoadingOperations || !auditLog.canLoadOlderOperations)
                    .accessibilityIdentifier("DiagnosticsEventsOlder")
            }
        }
        .accessibilityIdentifier("DiagnosticsRecentEventsScroll")
        .navigationTitle("Recent Events")
        .task {
            while !Task.isCancelled {
                try? await auditLog.pollOperationsIfIdle()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private extension OperationActivityRowModel {
    func replacingActivityPresentation(
        current: Int, total: Int?, smartInboxDisabled: Bool
    ) -> OperationActivityRowModel {
        OperationActivityRowModel(
            id: id,
            title: title,
            state: smartInboxDisabled ? .paused : state,
            phase: smartInboxDisabled ? "Paused" : phase,
            detail: detail,
            providerID: providerID,
            modelID: modelID,
            accountEmail: accountEmail,
            resultDetail: smartInboxDisabled
                ? "Smart Inbox is disabled. Turn it on to resume organizing."
                : resultDetail,
            isPartialFailure: isPartialFailure,
            isSmartInboxOrganization: isSmartInboxOrganization,
            current: current,
            total: total,
            createdAt: createdAt,
            updatedAt: updatedAt,
            attempt: attempt,
            maxAttempts: maxAttempts,
            terminalOccurrenceAt: terminalOccurrenceAt
        )
    }
}
