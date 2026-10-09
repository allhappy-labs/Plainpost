import Foundation
import SwiftUI

/// Readable Sync Node status from the snapshot strings the runtime publishes
/// (`PlainpostAppRuntime.makeNodeSettingsViewModel`): reachability is "reachable" from a
/// status response or "Unavailable" when it fails; the lag is "<seconds>s" or "unknown";
/// storage is "<used>/<limit> bytes"; backup is "verified", "uncertain" or "unknown".
enum SyncNodeStatusText {
    static let delayedAfter: TimeInterval = 15 * 60

    /// Fails closed: only a status that says "reachable" counts as connected.
    static func connection(reachability: String, syncLag: String) -> String {
        guard isReachable(reachability) else { return "Needs attention" }
        if isDelayed(syncLag) { return "Sync delayed" }
        return "Connected"
    }

    static func isReachable(_ reachability: String) -> Bool {
        reachability.lowercased() == "reachable"
    }

    static func isDelayed(_ syncLag: String) -> Bool {
        guard let lag = lagSeconds(syncLag) else { return false }
        return lag >= delayedAfter
    }

    static func storage(_ value: String) -> String {
        let parts = value.replacingOccurrences(of: " bytes", with: "").split(separator: "/")
        guard parts.count == 2, let used = Int64(parts[0]), let limit = Int64(parts[1]), limit > 0 else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: used)) of \(formatter.string(fromByteCount: limit))"
    }

    static func backup(_ value: String) -> String {
        switch value.lowercased() {
        case "verified": "Verified"
        case "uncertain": "Not verified"
        default: "Unknown"
        }
    }

    /// Names the operation that didn't finish. An erase may have gone part way, so it asks
    /// for a look at the Sync Node before another try.
    static func operationProblem(_ operation: SyncNodeOperationKind?) -> String {
        switch operation {
        case .backup: "Backup didn’t finish. Try again."
        case .erase: "Erase didn’t finish. Check the Sync Node before trying again."
        case nil: "The last Sync Node action didn’t finish. Try again."
        }
    }

    private static func lagSeconds(_ lag: String) -> TimeInterval? {
        guard let unit = lag.last, let amount = Double(lag.dropLast()) else { return nil }
        switch unit {
        case "s": return amount
        case "m": return amount * 60
        case "h": return amount * 3600
        default: return nil
        }
    }
}

/// The enrolled Sync Node's details: storage, the last backup with Back Up Now, an update
/// that is ready to install, and an operation that didn't finish. Connection status is the
/// page overview's alone.
public struct SyncNodeStatusSection: View {
    @ObservedObject private var model: SyncNodeSettingsViewModel

    public init(model: SyncNodeSettingsViewModel) { self.model = model }

    public var body: some View {
        Section("Sync Node") {
            LabeledContent("Storage", value: SyncNodeStatusText.storage(model.snapshot.storage))
            if model.canOperate {
                LabeledContent("Last backup") {
                    HStack {
                        Text(AccountSecurityPresentation.relative(model.lastVerifiedBackupAt) ?? SyncNodeStatusText.backup(model.snapshot.backup))
                        Button("Back Up Now") { Task { await model.runBackup() } }
                            .disabled(model.operationPhase == .inFlight || Self.isKnownUnreachable(model))
                            .accessibilityIdentifier("sync-node.settings.backup")
                    }
                }
            }
            if model.upgradeReady {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Update available")
                    Text("Install it from your Sync Node’s server.")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sync-node.settings.upgrade-ready")
            }
            if model.operationPhase == .failed || model.operationPhase == .uncertain || model.operatorActionRequired {
                Label(SyncNodeStatusText.operationProblem(model.lastOperation), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("sync-node.settings.operation-problem")
            }
        }
        .task { await model.refresh() }
    }

    /// A Node whose status was read and isn't reachable can't back up either. Before the
    /// first status read the button stays available.
    @MainActor
    static func isKnownUnreachable(_ model: SyncNodeSettingsViewModel) -> Bool {
        model.hasStatus && !SyncNodeStatusText.isReachable(model.snapshot.reachability)
    }
}

/// The page's last section: Erase Sync Node, behind a typed confirmation.
public struct SyncNodeEraseSection: View {
    @ObservedObject private var model: SyncNodeSettingsViewModel
    @State private var confirmsErase = false
    @State private var eraseText = ""

    public init(model: SyncNodeSettingsViewModel) { self.model = model }

    public var body: some View {
        if model.canOperate {
            Section {
                Button("Erase Sync Node…", role: .destructive) { confirmsErase = true }
                    #if os(macOS)
                    // A Mac form button ignores the destructive role's colour.
                    .foregroundStyle(.red)
                    #endif
                    .disabled(model.operationPhase == .inFlight)
                    .accessibilityIdentifier("sync-node.settings.erase")
            } footer: {
                Text("Erases all mail and settings stored on the Sync Node. Your mail provider accounts aren’t affected.")
            }
            .sheet(isPresented: $confirmsErase, onDismiss: { eraseText = "" }) {
                eraseSheet
            }
        }
    }

    private var eraseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Type \(model.eraseConfirmation)", text: $eraseText)
                        .accessibilityIdentifier("sync-node.settings.erase-confirmation")
                } footer: {
                    Text("This erases all mail and settings stored on the Sync Node.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Erase Sync Node")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmsErase = false } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Erase", role: .destructive) {
                        let confirmation = eraseText
                        confirmsErase = false
                        Task { await model.runErase(confirmation: confirmation) }
                    }
                    .disabled(eraseText != model.eraseConfirmation)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 220)
        #endif
    }
}
