import Combine
import Foundation
import PlainpostAI
import PlainpostCore
import PlainpostOperations

public enum MailMaintenanceActionState: Equatable, Sendable {
    case idle
    case inProgress(message: String)
    case success(message: String)
    case failure(message: String)

    public var message: String {
        switch self {
        case .idle:
            return ""
        case .inProgress(let message),
             .success(let message),
             .failure(let message):
            return message
        }
    }

    var isInProgress: Bool {
        if case .inProgress = self {
            return true
        }
        return false
    }
}

@MainActor
enum MailMaintenanceSuccessPolicy {
    static func perform(
        advanceMailbox: () -> Void,
        refreshActivity: () -> Void
    ) {
        advanceMailbox()
        refreshActivity()
    }
}

/// The Troubleshooting "Last sync" time's locale-aware relative description. The time
/// itself comes from `SQLiteMailStore.lastSuccessfulMailboxSyncAt(accountID:)`.
enum MailLastSyncPolicy {
    static func description(of date: Date?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

@MainActor
public final class MailSyncCoordinator: ObservableObject {
    @Published public private(set) var state: MailMaintenanceActionState = .idle

    private var activeRequest: Task<Void, Never>?
    private var activeRequestID: UUID?

    public init() {}

    func run(
        operation: @escaping @MainActor () async -> MailMaintenanceActionState
    ) async {
        if let activeRequest {
            _ = await activeRequest.value
            return
        }

        state = .inProgress(message: "Syncing…")
        let requestID = UUID()
        activeRequestID = requestID
        let request = Task { @MainActor [weak self] in
            let result = await operation()
            guard let self, activeRequestID == requestID else { return }
            state = result
            activeRequest = nil
            activeRequestID = nil
        }
        activeRequest = request
        await request.value
    }
}

@MainActor
public final class MailMaintenanceViewModel: ObservableObject {
    @Published public private(set) var smartInboxEnabled = true
    private var smartInboxPolicyObservation: AnyCancellable?
    @Published public private(set) var rerunState: MailMaintenanceActionState = .idle
    @Published private(set) var successRevision: UInt64 = 0
    /// True while Low Power Mode is pausing Smart Inbox sorting on this device.
    @Published public private(set) var isSmartInboxPausedForLowPower: Bool
    private var lowPowerObservation: AnyCancellable?
    /// The selected account's last successful sync, refreshed on sync completion and
    /// with the activity poll while Troubleshooting is open.
    @Published public private(set) var lastSuccessfulSyncAt: Date?
    private let lastSuccessfulSync: () -> Date?

    let accountSetup: AccountSetupViewModel
    let syncCoordinator: MailSyncCoordinator
    let smartInboxActivity: SmartInboxActivityCoordinator
    let activeRerunJob: () -> PlainpostDurableJob?
    let selectedProviderID: () -> String
    let aiGenerationAvailable: () -> Bool
    let rerun: (String, PlainpostSmartInboxRunMode, String?) async throws -> String
    private let didCompleteSuccessfully: () async -> Void
    private var syncStateObservation: AnyCancellable?

    init(
        accountSetup: AccountSetupViewModel,
        syncCoordinator: MailSyncCoordinator = MailSyncCoordinator(),
        smartInboxActivity: SmartInboxActivityCoordinator,
        activeRerunJob: @escaping () -> PlainpostDurableJob?,
        selectedProviderID: @escaping () -> String,
        aiGenerationAvailable: @escaping () -> Bool = { true },
        smartInboxSettings: AIProviderSettingsViewModel? = nil,
        rerun: @escaping (String, PlainpostSmartInboxRunMode, String?) async throws -> String,
        didCompleteSuccessfully: @escaping () async -> Void = {},
        lowPowerModeActive: @escaping () -> Bool = { false },
        lowPowerModeChanges: AnyPublisher<Bool, Never>? = nil,
        lastSuccessfulSync: @escaping () -> Date? = { nil }
    ) {
        self.accountSetup = accountSetup
        self.syncCoordinator = syncCoordinator
        self.smartInboxActivity = smartInboxActivity
        self.activeRerunJob = activeRerunJob
        self.selectedProviderID = selectedProviderID
        self.aiGenerationAvailable = aiGenerationAvailable
        self.rerun = rerun
        self.didCompleteSuccessfully = didCompleteSuccessfully
        self.isSmartInboxPausedForLowPower = lowPowerModeActive()
        self.lastSuccessfulSync = lastSuccessfulSync
        self.lastSuccessfulSyncAt = lastSuccessfulSync()
        self.lowPowerObservation = lowPowerModeChanges?
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isSmartInboxPausedForLowPower = active
            }
        self.smartInboxPolicyObservation = smartInboxSettings?.$smartInboxMode
            .map(\.isEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.smartInboxEnabled = enabled
            }
        self.syncStateObservation = syncCoordinator.objectWillChange.sink {
            [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var syncState: MailMaintenanceActionState {
        syncCoordinator.state
    }

    public var syncButtonTitle: String {
        isSyncing ? "Syncing…" : "Sync now"
    }

    public var rerunButtonTitle: String {
        isRerunActive ? "Rerunning Smart Inbox…" : "Rerun Smart Inbox"
    }

    public var providerDisplayName: String {
        switch selectedProviderID() {
        case "foundation":
            return "Apple Foundation Models"
        case "ollama":
            return "Ollama Local"
        case OpenRouterConfiguration.providerID:
            return OpenRouterConfiguration.displayName
        default:
            return "selected model"
        }
    }

    public var isSyncing: Bool {
        syncState.isInProgress || accountSetup.isSyncing
    }

    public var isRerunActive: Bool {
        rerunState.isInProgress || activeRerunJob() != nil
    }

    public var canRerunSmartInbox: Bool {
        smartInboxEnabled && aiGenerationAvailable() && !isRerunActive && !isSmartInboxPausedForLowPower
    }

    public func refreshActivity() {
        smartInboxActivity.refresh()
        refreshLastSync()
    }

    public func refreshLastSync() {
        let latest = lastSuccessfulSync()
        if latest != lastSuccessfulSyncAt { lastSuccessfulSyncAt = latest }
    }

    /// The current Smart Inbox sort progress, when a job is actively reporting one.
    public var smartInboxProgress: (processed: Int, total: Int)? {
        guard let presentation = smartInboxActivity.presentation,
              let total = presentation.total else { return nil }
        return (presentation.processed, total)
    }

    public func syncNow() async {
        await syncCoordinator.run { [self] in
            guard accountSetup.account != nil else {
                return .failure(message: "Connect an account before syncing.")
            }

            await accountSetup.syncInbox()
            refreshLastSync()

            if accountSetup.lastSyncError == nil {
                smartInboxActivity.refresh()
                await didCompleteSuccessfully()
                successRevision &+= 1
                return .success(message: "Inbox sync finished.")
            }
            return .failure(
                message: "Inbox sync failed. Check your account settings and try again."
            )
        }
    }

    public func rerunSmartInbox() async {
        guard smartInboxEnabled, aiGenerationAvailable() else { return }
        refreshActivity()
        guard !isRerunActive else { return }

        rerunState = .inProgress(message: "Rerunning Smart Inbox…")
        do {
            _ = try await rerun(
                selectedProviderID(),
                .rerunAll,
                UUID().uuidString.lowercased()
            )
            rerunState = .success(message: "Smart Inbox rerun finished.")
            refreshActivity()
            await didCompleteSuccessfully()
            successRevision &+= 1
        } catch PlainpostSmartInboxMaintenanceError.rerunAlreadyActive {
            rerunState = .failure(message: "Smart Inbox rerun is already active.")
            refreshActivity()
        } catch {
            rerunState = .failure(message: "Smart Inbox rerun failed. Try again.")
            refreshActivity()
        }
    }

    public static func preview(
        accountSetup: AccountSetupViewModel = .connectedPreview()
    ) -> MailMaintenanceViewModel {
        MailMaintenanceViewModel(
            accountSetup: accountSetup,
            syncCoordinator: MailSyncCoordinator(),
            smartInboxActivity: SmartInboxActivityCoordinator(
                previewPresentation: nil
            ),
            activeRerunJob: { nil },
            selectedProviderID: { "foundation" },
            rerun: { _, _, _ in "Up to date" }
        )
    }
}
