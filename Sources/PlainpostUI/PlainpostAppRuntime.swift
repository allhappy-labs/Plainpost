import os
import Combine
import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostAI
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostOperations

/// A notification tap is resolved only against locally authenticated mail.
/// Unknown opaque tokens deliberately land on All Inboxes rather than
/// exposing or guessing a message identifier.
public enum PlainpostNotificationOpenDestination: Equatable, Sendable {
    case message(String)
    case accountInbox(String)
    case allInboxes
    /// The tap named a message this device no longer has (its account was removed, or the
    /// message is gone): All Inboxes, saying so.
    case messageUnavailable

    /// Resolves through an app-owned mapping persisted when the authenticated
    /// Node projection is materialized.  The notification token is an opaque
    /// digest and must never be compared directly with a message identifier.
    public static func resolve(token: String, deepLinkMapping: [String: String]) -> Self {
        resolve(
            token: token,
            messageMapping: deepLinkMapping,
            accountInboxMapping: [:]
        )
    }

    public static func resolve(
        token: String,
        messageMapping: [String: String],
        accountInboxMapping: [String: String]
    ) -> Self {
        guard !token.isEmpty, token.utf8.count <= 256,
              !token.contains(where: { $0 == "\0" || $0.isNewline }) else {
            return .allInboxes
        }
        if let messageID = messageMapping[token], Self.isSafeIdentifier(messageID) {
            return .message(messageID)
        }
        if let accountID = accountInboxMapping[token], Self.isSafeIdentifier(accountID) {
            return .accountInbox(accountID)
        }
        return .allInboxes
    }

    @available(*, deprecated, message: "Use resolve(token:deepLinkMapping:) with the persisted opaque-token mapping.")
    public static func resolve(token: String, locallyAvailableIDs: Set<String>) -> Self {
        resolve(token: token, deepLinkMapping: Dictionary(uniqueKeysWithValues: locallyAvailableIDs.map { ($0, $0) }))
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.contains(where: { $0 == "\0" || $0.isNewline })
    }
}

public struct PlainpostNotificationAttentionContext: Equatable, Sendable {
    public let visibleMessageToken: String?
    public let visibleAccountInboxTokens: Set<String>

    public init(
        visibleMessageToken: String?,
        visibleAccountInboxTokens: Set<String>
    ) {
        self.visibleMessageToken = visibleMessageToken
        self.visibleAccountInboxTokens = visibleAccountInboxTokens
    }
}

public struct PlainpostNotificationInboxScope: Equatable, Sendable {
    public let accountID: String
    public let messageIDs: Set<String>
    public let accountIdentity: MailboxAccountIdentity

    public init(
        accountID: String,
        messageIDs: Set<String>,
        accountIdentity: MailboxAccountIdentity
    ) {
        self.accountID = accountID
        self.messageIDs = messageIDs
        self.accountIdentity = accountIdentity
    }

    public func apply(to viewModel: InboxViewModel) -> InboxViewModel {
        let rows = viewModel.classicRows.filter { messageIDs.contains($0.id) }
        return InboxViewModel(
            chrome: viewModel.chrome,
            sidebarItems: viewModel.sidebarItems,
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: viewModel.selectedThread,
            aiIndexStatus: viewModel.aiIndexStatus,
            requiresAccountSetup: viewModel.requiresAccountSetup,
            setupSource: viewModel.setupSource,
            accountIdentity: accountIdentity,
            totalRowCount: messageIDs.count,
            hasMoreRows: rows.count < messageIDs.count,
            mailboxLoadFailure: viewModel.mailboxLoadFailure,
            mailboxRevision: viewModel.mailboxRevision,
            contentRevision: viewModel.contentRevision
        )
    }
}

public enum PlainpostNotificationAttentionUpdate: Sendable {
    case set(sourceID: UUID, context: PlainpostNotificationAttentionContext)
    case remove(sourceID: UUID)

    public func post(center: NotificationCenter = .default) {
        center.post(name: .plainpostNotificationAttentionUpdate, object: self)
    }
}

public extension Notification.Name {
    static let plainpostNotificationAttentionUpdate = Notification.Name(
        "PlainpostNotificationAttentionUpdate"
    )
}

public struct PlainpostNotificationPresentationPolicy: Equatable, Sendable {
    public let showsBanner: Bool
    public let addsToList: Bool
    public let playsSound: Bool
    public let updatesBadge: Bool

    public init(
        showsBanner: Bool,
        addsToList: Bool,
        playsSound: Bool,
        updatesBadge: Bool
    ) {
        self.showsBanner = showsBanner
        self.addsToList = addsToList
        self.playsSound = playsSound
        self.updatesBadge = updatesBadge
    }

    public static func resolve(
        isApplicationActive: Bool,
        openToken: String?,
        contexts: [PlainpostNotificationAttentionContext],
        playsSound: Bool
    ) -> Self {
        let isRelevant = isApplicationActive && openToken.map { token in
            contexts.contains {
                $0.visibleMessageToken == token
                    || $0.visibleAccountInboxTokens.contains(token)
            }
        } == true
        return Self(
            showsBanner: !isRelevant,
            addsToList: true,
            playsSound: !isRelevant && playsSound,
            updatesBadge: false
        )
    }
}

/// The app/runtime seam for the server-derived opaque notification identity.
/// Implementations must only return a locally authenticated message ID.
public protocol PlainpostNotificationDeepLinkResolving: Sendable {
    func messageID(forOpaqueToken token: String) async -> String?
}

public protocol PlainpostNotificationDeepLinkRefreshing: Sendable {
    func refreshForNotification() async
}

import PlainpostOperationRuntime
import PlainpostServiceIPC
import OSLog
import SwiftUI

public struct PlainpostAttachmentArtifact: Equatable, Sendable {
    public let url: URL
    public let filename: String
    public let isShareable: Bool

    public init(url: URL, filename: String, isShareable: Bool = true) {
        self.url = url
        self.filename = filename
        self.isShareable = isShareable
    }

    public func cleanup() throws {
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

struct MailSearchMaintenanceCoordinator: Sendable {
    private let service: any MailSearchService
    private let reportFailure: @Sendable () throws -> Void
    private let logger = Logger(
        subsystem: "com.marynavdovenko.Plainpost",
        category: "MailSearchMaintenance"
    )

    init(
        service: any MailSearchService,
        reportFailure: @escaping @Sendable () throws -> Void
    ) {
        self.service = service
        self.reportFailure = reportFailure
    }

    func perform(now: Date) async {
        do {
            try await service.performMaintenanceIfDue(now: now)
        } catch is CancellationError {
            return
        } catch let error as MailSearchError where error == .cancelled {
            return
        } catch {
            do {
                try reportFailure()
            } catch {
                logger.error("Mail search maintenance failed and its diagnostic could not be persisted.")
            }
        }
    }
}

struct SmartInboxClassificationResultPresentation {
    static func status(
        providerDisplayName: String,
        updated: Int,
        unchanged: Int,
        failed: Int
    ) -> String {
        guard updated + unchanged + failed > 0 else {
            return "Up to date"
        }
        return "Categorized with \(providerDisplayName): \(updated) updated, "
            + "\(unchanged) unchanged, \(failed) failed."
    }
}

public enum PlainpostSmartInboxMaintenanceError: Error, Equatable, Sendable {
    case rerunAlreadyActive
}

public enum PlainpostRuntimeAccountAccess: Equatable, Sendable {
    case readWrite
    case cachedReadOnly
}

public struct PlainpostAppRuntimeConfiguration: Sendable, Equatable {
    public let databaseURL: URL
    public let selectedAccountID: AccountID?
    public let selectedNodeSource: AccountMailSource?
    let serviceClient: any PlainpostServiceClientProtocol
    var runtimeDependencies:
        (any PlainpostAppRuntimeDependencyProviding)?
    public let mailAuthority: (any PlainpostMailAuthority)?
    private let serviceClientIdentity: UUID?
    private var runtimeDependenciesIdentity: UUID?
    private let mailAuthorityIdentity: UUID?
    #if DEBUG
    public let keychainService: String
#endif

    public var localAPISocketURL: URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent("LocalAPI-v1.sock")
    }

    public init(
        databaseURL: URL = Self.defaultDatabaseURL(),
        serviceClient: (any PlainpostServiceClientProtocol)? = nil,
        selectedAccountID: AccountID? = nil,
        mailAuthority: (any PlainpostMailAuthority)? = nil,
        selectedNodeSource: AccountMailSource? = nil
    ) {
        let resolvedServiceClient = serviceClient ?? PlainpostServiceClient()
        self.databaseURL = databaseURL
        self.selectedAccountID = selectedAccountID
        self.selectedNodeSource = selectedNodeSource
        self.serviceClient = resolvedServiceClient
        self.runtimeDependencies = nil
        self.mailAuthority = mailAuthority
        self.serviceClientIdentity = serviceClient == nil ? nil : UUID()
        self.runtimeDependenciesIdentity = nil
        self.mailAuthorityIdentity = mailAuthority == nil ? nil : UUID()
        #if DEBUG
        self.keychainService = "Plainpost"
        #endif
    }

    public init(
        databaseURL: URL,
        serviceClient: (any PlainpostServiceClientProtocol)? = nil,
        mailAuthority: (any PlainpostMailAuthority)? = nil,
        selectedAccountID: AccountID? = nil,
        runtimeDependencies: any PlainpostAppRuntimeDependencyProviding
    ) {
        self.databaseURL = databaseURL
        self.selectedAccountID = selectedAccountID
        self.selectedNodeSource = nil
        self.serviceClient = serviceClient ?? PlainpostServiceClient()
        self.runtimeDependencies = runtimeDependencies
        self.mailAuthority = mailAuthority
        self.serviceClientIdentity = serviceClient == nil ? nil : UUID()
        self.runtimeDependenciesIdentity = UUID()
        self.mailAuthorityIdentity = mailAuthority == nil ? nil : UUID()
        #if DEBUG
        self.keychainService = "Plainpost"
        #endif
    }

    #if DEBUG
    public init(
        databaseURL: URL = Self.defaultDatabaseURL(), keychainService: String,
        serviceClient: (any PlainpostServiceClientProtocol)? = nil,
        runtimeDependencies:
            (any PlainpostAppRuntimeDependencyProviding)? = nil,
        mailAuthority: (any PlainpostMailAuthority)? = nil
    ) {
        let resolvedServiceClient = serviceClient ?? PlainpostServiceClient()
        self.databaseURL = databaseURL
        self.selectedAccountID = nil
        self.selectedNodeSource = nil
        self.serviceClient = resolvedServiceClient
        self.runtimeDependencies = runtimeDependencies
        self.mailAuthority = mailAuthority
        self.serviceClientIdentity = serviceClient == nil ? nil : UUID()
        self.runtimeDependenciesIdentity = runtimeDependencies == nil ? nil : UUID()
        self.mailAuthorityIdentity = mailAuthority == nil ? nil : UUID()
        self.keychainService = keychainService
    }
#endif

    public static func == (lhs: Self, rhs: Self) -> Bool {
        let commonFieldsMatch =
            lhs.databaseURL == rhs.databaseURL
            && lhs.selectedAccountID == rhs.selectedAccountID
            && lhs.selectedNodeSource == rhs.selectedNodeSource
            && lhs.serviceClientIdentity == rhs.serviceClientIdentity
            && lhs.runtimeDependenciesIdentity == rhs.runtimeDependenciesIdentity
            && lhs.mailAuthorityIdentity == rhs.mailAuthorityIdentity
        #if DEBUG
        return commonFieldsMatch && lhs.keychainService == rhs.keychainService
        #else
        return commonFieldsMatch
        #endif
    }

    #if DEBUG
    public func withRuntimeDependencies(
        _ runtimeDependencies:
            any PlainpostAppRuntimeDependencyProviding
    ) -> Self {
        var configuration = self
        configuration.runtimeDependencies = runtimeDependencies
        configuration.runtimeDependenciesIdentity = UUID()
        return configuration
    }
    #endif

    public static func defaultDatabaseURL(
        fileManager: FileManager = .default
    ) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("Plainpost", isDirectory: true)
            .appendingPathComponent("Plainpost.sqlite")
    }
}

@MainActor
public final class PlainpostAppTranslationState {
    public let languageSettings: TranslationLanguageSettingsViewModel

    public init(languageSettings: TranslationLanguageSettingsViewModel) {
        self.languageSettings = languageSettings
    }
}

@MainActor
public final class PlainpostAppRuntime {
    static let guiMailOperationJobKinds: Set<PlainpostOperationKind> = [
        .inboxSync, .historicalSync, .approvedDelivery, .denySend,
    ]

    public let configuration: PlainpostAppRuntimeConfiguration
    public let store: SQLiteMailStore
    public let mailSearchService: any MailSearchService
    /// The authority is resolved once when the runtime is assembled. Every
    /// native mail capability exposed by this runtime comes from this same
    /// instance; local fixtures may intentionally leave it nil.
    public let mailAuthority: (any PlainpostMailAuthority)?
    /// Capability handles are retained from the same authority instance. They
    /// make it impossible for a product surface to silently select a second
    /// local/provider data path once Node mail is configured.
    public let mailSnapshotService: (any MailSnapshotServing)?
    public let mailMessageService: (any MailMessageServing)?
    public let mailMutationService: (any MailMutationServing)?
    public let mailAttachmentService: (any MailAttachmentServing)?
    public let attachmentState: PlainpostAttachmentState
    public let browserRegistrationStatus: BrowserNativeHostRegistrationStatus
    public let translationState: PlainpostAppTranslationState
    private let undoSendCoordinator: UndoSendCoordinator
    /// Whether this runtime's embedded composer is open with unsaved changes.
    public let composerActivity = PlainpostComposerActivity()
    /// The scoped account `account(forMessageID:)` answers with.
    private let scopedAccountCache = ScopedAccountCache()
    private let notificationScheduler: any LocalNotificationScheduling
    let macNewMailDelivery: (any MacNewMailDelivering)?
    private let mailOperationClient: any PlainpostOperationClientProtocol
    private let aiOperationClient: any PlainpostOperationClientProtocol
    private let smartInboxPowerGate: SmartInboxPowerGate
    private var smartInboxLowPowerRerunPolicy: SmartInboxLowPowerRerunPolicy?
    private let inboxSyncer: LocalOperationAccountInboxSyncer
    private let foregroundInboxRefresh: DirectMailForegroundRefreshCoordinator?
    private let syncCompletionHandler: @Sendable () async -> Void
    private let requestSmartInboxOrganization: @Sendable () async -> Void
    let backgroundWork: RuntimeBackgroundWork
    private let mailSearchMaintenance: MailSearchMaintenanceCoordinator
    private let localAPIOwnership: LocalAPIServerOwnershipCoordinator?
    private let localAPIOwnershipMaintenance: Task<Void, Never>?
    private let messageOpening: MessageOpeningService<SQLiteMailStore>
    private let mailboxFlagScheduler: DurableMailboxFlagScheduler
    private let inboxProjectionRepository: InboxProjectionRepository
    private let operationWorkerSignal: (any OperationWorkerSignaling)?
    private let aiProviderPreferences: UserDefaultsAIProviderPreferenceStore
    private var aiProviderSettingsModel: AIProviderSettingsViewModel?
    /// The Sync Node Settings model, shared across every caller of `makeNodeSettingsViewModel`
    /// (the main window's session and the ⌘, window). `PlainpostNodeMailAuthority.onStatusRefresh`
    /// is a single-slot callback, so a second model built on a second call would silently steal
    /// live status pushes from whichever model was built first; sharing one instance keeps both
    /// windows observing the same status.
    private var nodeSettingsModel: SyncNodeSettingsViewModel?
    private let runtimeDependencies: (any PlainpostAppRuntimeDependencyProviding)?
    private let accountAccess: PlainpostRuntimeAccountAccess
    private let selectedDirectSourceGeneration: Int64?
    private let serviceClient: any PlainpostServiceClientProtocol
    /// The mailbox header's Sync Node status model (see `makeNodeMailModeStatusModel`).
    private var nodeMailModeStatusModel: NodeMailModeStatusModel?
    private let serviceFailureMonitor: PlainpostRuntimeServiceFailureMonitor?
    var hasServiceFailureMonitor: Bool { serviceFailureMonitor != nil }
    private let notificationDeepLinkResolver: (any PlainpostNotificationDeepLinkResolving)?
    private let smartInboxResumeSignalRetryDelay: @Sendable () async -> Void
    private let mailSyncCoordinator = MailSyncCoordinator()
    private var inboxMailboxSnapshot: InboxMailboxSnapshot?
    /// Full Node messages are retained only as the current UI projection's
    /// source context. They are never replaced with the local SQLite store.
    private var nodeMessagesByID: [String: MessageSummary] = [:]
    /// The latest Node snapshot page, the messages the Node inbox shows. The mailbox
    /// directory counts a Node account's unread mail from it.
    private var nodeSnapshotMessages: [MessageSummary] = []
    private var inboxProjectionNeedsReload = true
    private var metadataReadGeneration: UInt64 = 0
    private var inboxRequestGeneration: UInt64 = 0
    private var inboxPageLimit = InboxProjectionRepository.pageSize
    private var isSmartInboxMaintenanceRerunInFlight = false

    var notificationScope: RuntimeNotificationScope {
        RuntimeNotificationScope(
            store: store,
            selectedAccountID: configuration.selectedAccountID,
            selectedDirectGeneration: selectedDirectSourceGeneration,
            scopesLocalNotifications: runtimeDependencies != nil || configuration.selectedAccountID != nil,
            hasNodeAuthority: mailAuthority != nil,
            isDeviceWideDirect: isDeviceWideDirect
        )
    }

    /// The accounts whose inbox notifications this runtime resolves.
    func notificationAccountIDs() -> [AccountID] {
        if isDeviceWideDirect {
            let direct = DeviceMailScope.current(in: store).accountIDs
            return store.accounts.map(\.id).filter(direct.contains)
        }
        return store.accounts.map(\.id).filter {
            configuration.selectedAccountID == nil || $0 == configuration.selectedAccountID
        }
    }

    func notificationMessageToken(for messageID: String) -> String? {
        notificationScope.messageToken(for: messageID)
    }

    func notificationInboxScope(for rawAccountID: String) -> PlainpostNotificationInboxScope? {
        notificationScope.inboxScope(for: rawAccountID)
    }

    /// The iPhone runtime: Direct dependencies, no selected account and no Node authority.
    /// It serves every Direct account on the device, and every action checks the message's
    /// own account instead of a selection.
    var isDeviceWideDirect: Bool {
        runtimeDependencies != nil && configuration.selectedAccountID == nil && configuration.mailAuthority == nil
    }

    /// The device-wide runtime's Direct accounts and generations as of its latest inbox read:
    /// an action on a listed row is accepted only while its account is still at the generation
    /// the row was read with.
    var latestDeviceMailSources: DeviceMailSources? { deviceDirectReadState.value }

    /// The source generation `messageID` was listed at, under `owner`.
    nonisolated func deviceDirectReadGeneration(for messageID: MessageID, owner: AccountID) -> Int64? {
        deviceDirectReadState.generation(for: messageID, owner: owner)
    }

    /// The account a listed message belongs to, as its list read it.
    nonisolated func deviceDirectReadOwner(of messageID: MessageID) -> AccountID? {
        deviceDirectReadState.owner(of: messageID)
    }

    /// When mail last synced without error: the selected account's, every account's on the
    /// Mac, or the newest of the device-wide runtime's Direct accounts.
    func lastSuccessfulDirectSync() -> Date? {
        guard isDeviceWideDirect else {
            return (try? store.lastSuccessfulMailboxSyncAt(accountID: configuration.selectedAccountID)) ?? nil
        }
        return DeviceMailScope.current(in: store).directSyncAccountIDs.compactMap {
            (try? store.lastSuccessfulMailboxSyncAt(accountID: $0)) ?? nil
        }.max()
    }

    /// The Direct account whose complete history is still downloading, so a relaunched app
    /// shows its progress again; the first by id when there are several.
    public func directAccountWithHistoryInProgress() -> AccountID? {
        guard isDeviceWideDirect else { return nil }
        return DeviceMailScope.current(in: store).directAccountIDs.sorted { $0.rawValue < $1.rawValue }.first { id in
            (try? store.syncPreferences(accountID: id).downloadCompleteHistory) == true
                && ((try? store.mailboxSyncStatuses(accountID: id)) ?? []).contains {
                    $0.phase.rawValue == "backfill" && !$0.complete
                }
        }
    }

    /// Accounts whose last Direct sync failed, until one succeeds.
    private var directSyncFailures: Set<AccountID> = []

    /// The device-wide monitor's report after each pass: the first failing account's failure,
    /// or nil when every account synced. The monitor keeps running either way.
    public var directSyncFailureHandler: (@MainActor (DirectSyncFailure?) -> Void)?
    nonisolated private let deviceDirectReadState = DeviceDirectReadState()

    private var isSelectedDirectSourceCurrent: Bool {
        guard runtimeDependencies != nil else { return true }
        // The device-wide runtime's projection source fences each read itself.
        if isDeviceWideDirect { return true }
        if configuration.selectedAccountID == nil { return store.accounts.isEmpty }
        guard let accountID = configuration.selectedAccountID,
              let generation = selectedDirectSourceGeneration,
              (try? store.requireDirectMailSource(accountID: accountID)) != nil,
              (try? store.mailSource(accountID: accountID).generation) == generation else {
            return false
        }
        return true
    }

    private func staleDirectInboxViewModel() -> InboxViewModel {
        InboxViewModel.loading(requiresAccountSetup: false, setupSource: .localAccount)
            .withMailboxLoadFailure("Mail source changed. Reopen this account.")
    }

    public convenience init(
        configuration: PlainpostAppRuntimeConfiguration = PlainpostAppRuntimeConfiguration(),
        notificationScheduler: (any LocalNotificationScheduling)? = nil,
        accountAccess: PlainpostRuntimeAccountAccess = .readWrite,
        notificationDeepLinkResolver: (any PlainpostNotificationDeepLinkResolving)? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            notificationScheduler: notificationScheduler,
            aiOperationClientFactory: nil,
            operationWorkerSignal: nil,
            undoSendSleep: { try await Task.sleep(for: $0) },
            accountAccess: accountAccess,
            notificationDeepLinkResolver: notificationDeepLinkResolver
        )
    }

    convenience init(
        configuration: PlainpostAppRuntimeConfiguration,
        notificationScheduler: (any LocalNotificationScheduling)? = nil,
        undoSendSleep: @escaping @Sendable (Duration) async throws -> Void
    ) throws {
        try self.init(
            configuration: configuration,
            notificationScheduler: notificationScheduler,
            aiOperationClientFactory: nil,
            operationWorkerSignal: nil,
            undoSendSleep: undoSendSleep
        )
    }

    convenience init(
        configuration: PlainpostAppRuntimeConfiguration,
        notificationScheduler: (any LocalNotificationScheduling)? = nil,
        accountAccess: PlainpostRuntimeAccountAccess = .readWrite,
        macNewMailDeliveryFactory: @escaping (SQLiteMailStore) -> any MacNewMailDelivering
    ) throws {
        try self.init(
            configuration: configuration,
            notificationScheduler: notificationScheduler,
            aiOperationClientFactory: nil,
            operationWorkerSignal: nil,
            undoSendSleep: { try await Task.sleep(for: $0) },
            accountAccess: accountAccess,
            macNewMailDeliveryFactory: macNewMailDeliveryFactory
        )
    }

    convenience init(
        configuration: PlainpostAppRuntimeConfiguration,
        notificationScheduler: (any LocalNotificationScheduling)? = nil,
        packagedOperationWorkerSignalFactory: @escaping () -> (any OperationWorkerSignaling)?,
        browserNativeHostStartup: @escaping @MainActor (BrowserNativeHostRegistrationStatus) -> Void,
        accountAccess: PlainpostRuntimeAccountAccess = .readWrite,
        aiProviderPreferences: UserDefaultsAIProviderPreferenceStore = UserDefaultsAIProviderPreferenceStore()
    ) throws {
        try self.init(
            configuration: configuration,
            notificationScheduler: notificationScheduler,
            aiOperationClientFactory: nil,
            operationWorkerSignal: nil,
            undoSendSleep: { try await Task.sleep(for: $0) },
            aiProviderPreferences: aiProviderPreferences,
            packagedOperationWorkerSignalFactory: packagedOperationWorkerSignalFactory,
            browserNativeHostStartup: browserNativeHostStartup,
            accountAccess: accountAccess
        )
    }

    convenience init(
        configuration: PlainpostAppRuntimeConfiguration,
        notificationScheduler: (any LocalNotificationScheduling)? = nil,
        aiOperationClientFactory: @escaping (SQLiteMailStore) -> any PlainpostOperationClientProtocol,
        aiProviderPreferences: UserDefaultsAIProviderPreferenceStore = UserDefaultsAIProviderPreferenceStore(),
        smartInboxPowerGate: SmartInboxPowerGate? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            notificationScheduler: notificationScheduler,
            aiOperationClientFactory: Optional(aiOperationClientFactory),
            operationWorkerSignal: nil,
            undoSendSleep: { try await Task.sleep(for: $0) },
            aiProviderPreferences: aiProviderPreferences,
            smartInboxPowerGate: smartInboxPowerGate
        )
    }

    convenience init(
        configuration: PlainpostAppRuntimeConfiguration,
        notificationScheduler: (any LocalNotificationScheduling)? = nil,
        operationWorkerSignal: any OperationWorkerSignaling,
        smartInboxResumeSignalRetryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(500))
        },
        mailSearchMaintenanceService: (any MailSearchService)? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            notificationScheduler: notificationScheduler,
            aiOperationClientFactory: nil,
            operationWorkerSignal: operationWorkerSignal,
            undoSendSleep: { try await Task.sleep(for: $0) },
            smartInboxResumeSignalRetryDelay: smartInboxResumeSignalRetryDelay,
            mailSearchMaintenanceService: mailSearchMaintenanceService
        )
    }

    private init(
        configuration: PlainpostAppRuntimeConfiguration,
        notificationScheduler: (any LocalNotificationScheduling)?,
        aiOperationClientFactory: ((SQLiteMailStore) -> any PlainpostOperationClientProtocol)?,
        operationWorkerSignal: (any OperationWorkerSignaling)?,
        undoSendSleep: @escaping @Sendable (Duration) async throws -> Void,
        smartInboxResumeSignalRetryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(500))
        },
        aiProviderPreferences: UserDefaultsAIProviderPreferenceStore = UserDefaultsAIProviderPreferenceStore(),
        packagedOperationWorkerSignalFactory: () -> (any OperationWorkerSignaling)? = {
            PackagedOperationWorkerSignal()
        },
        browserNativeHostStartup: @escaping @MainActor (BrowserNativeHostRegistrationStatus) -> Void = {
            PlainpostBrowserNativeHostStartup.startIfPackaged(status: $0)
        },
        accountAccess: PlainpostRuntimeAccountAccess = .readWrite,
        notificationDeepLinkResolver: (any PlainpostNotificationDeepLinkResolving)? = nil,
        mailSearchMaintenanceService: (any MailSearchService)? = nil,
        macNewMailDeliveryFactory: ((SQLiteMailStore) -> any MacNewMailDelivering)? = nil,
        smartInboxPowerGate injectedSmartInboxPowerGate: SmartInboxPowerGate? = nil
    ) throws {
        self.configuration = configuration
        self.accountAccess = accountAccess
        let backgroundWork = RuntimeBackgroundWork()
        self.backgroundWork = backgroundWork
        let runtimeDependencies = configuration.runtimeDependencies
        self.runtimeDependencies = runtimeDependencies
        let serviceFailureMonitor =
            runtimeDependencies == nil ? PlainpostRuntimeServiceFailureMonitor() : nil
        let resolvedServiceClient: any PlainpostServiceClientProtocol
        if let serviceFailureMonitor {
            resolvedServiceClient = PlainpostRuntimeServiceClient(
                base: configuration.serviceClient,
                failureMonitor: serviceFailureMonitor
            )
        } else {
            resolvedServiceClient = configuration.serviceClient
        }
        self.serviceClient = resolvedServiceClient
        self.serviceFailureMonitor = serviceFailureMonitor
        self.translationState = PlainpostAppTranslationState(
            languageSettings: TranslationLanguageSettingsViewModel(
                options: TranslationLanguageCatalog.options(),
                preferenceStore:
                    UserDefaultsTranslationLanguagePreferenceStore()
            )
        )
        if accountAccess == .readWrite {
            try FileManager.default.createDirectory(
                at: configuration.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else if !FileManager.default.fileExists(atPath: configuration.databaseURL.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        let store = try SQLiteMailStore(
            path: configuration.databaseURL.path,
            readOnly: accountAccess == .cachedReadOnly
        )
        self.aiProviderPreferences = aiProviderPreferences
        if accountAccess == .readWrite {
            try store.migrate()
            // Mirror this installation's choice before any worker/client/organizer is constructed.
            try store.setSmartInboxMode(aiProviderPreferences.smartInboxMode())
        }
        if let expectedNodeSource = configuration.selectedNodeSource,
           (configuration.selectedAccountID != expectedNodeSource.accountID
                || configuration.mailAuthority == nil) {
            throw PlainpostError.permissionDenied("Selected Sync Node source has no matching authority.")
        }
        if let selectedAccountID = configuration.selectedAccountID,
           let mailAuthority = configuration.mailAuthority {
            guard mailAuthority.accountID == selectedAccountID,
                  store.accounts.contains(where: { $0.id == selectedAccountID }) else {
                throw PlainpostError.permissionDenied("Selected Sync Node account does not match its authority.")
            }
            let source = try store.mailSource(accountID: selectedAccountID)
            guard source.kind == .nodeBacked, source.mode == .node else {
                throw PlainpostError.permissionDenied("Selected Sync Node source is unavailable.")
            }
            if let expectedNodeSource = configuration.selectedNodeSource,
               source != expectedNodeSource {
                throw PlainpostError.permissionDenied("Selected Sync Node source changed during runtime construction.")
            }
        }
        if runtimeDependencies != nil {
            let accounts = store.accounts
            if let selectedAccountID = configuration.selectedAccountID {
                guard accounts.contains(where: { $0.id == selectedAccountID }) else {
                    throw PlainpostError.permissionDenied("Selected mail account is unavailable.")
                }
                try store.requireDirectMailSource(accountID: selectedAccountID)
            }
        }
        if runtimeDependencies != nil, let selectedAccountID = configuration.selectedAccountID {
            self.selectedDirectSourceGeneration = try store.mailSource(
                accountID: selectedAccountID
            ).generation
        } else {
            self.selectedDirectSourceGeneration = nil
        }
        self.store = store
        // The Mac delivers new-mail alerts, and so does the iPhone's device-wide Direct
        // runtime (its own Direct sync and background refresh). A selected-account or
        // read-only runtime never does.
        let deliversNewMailAlerts = runtimeDependencies == nil
            || (configuration.selectedAccountID == nil && configuration.mailAuthority == nil)
        if accountAccess == .readWrite, deliversNewMailAlerts {
            self.macNewMailDelivery = macNewMailDeliveryFactory?(store)
                ?? MacNewMailDelivery(
                    store: store,
                    center: SystemUserNotificationCenterAdapter()
                )
        } else {
            self.macNewMailDelivery = nil
        }
        let localMailSearchService = configuration.selectedAccountID.map {
            SQLiteMailSearchService(store: store, selectedAccountID: $0)
        } ?? SQLiteMailSearchService(store: store)
        let resolvedMailAuthority: (any PlainpostMailAuthority)?
        if let mailAuthority = configuration.mailAuthority {
            resolvedMailAuthority = mailAuthority
        } else if let runtimeDependencies, let accountID = configuration.selectedAccountID {
            resolvedMailAuthority = try runtimeDependencies.makeMailAuthority(
                accountID: accountID, access: accountAccess
            )
        } else {
            resolvedMailAuthority = nil
        }
        self.mailAuthority = resolvedMailAuthority
        self.notificationDeepLinkResolver = notificationDeepLinkResolver
            ?? resolvedMailAuthority.map(AuthorityNotificationDeepLinkResolver.init)
        self.mailSnapshotService = resolvedMailAuthority?.snapshots
        self.mailMessageService = resolvedMailAuthority?.messages
        self.mailMutationService = resolvedMailAuthority?.mutations
        self.mailAttachmentService = resolvedMailAuthority?.attachments
        self.attachmentState = PlainpostAttachmentState(
            accountID: resolvedMailAuthority?.accountID?.rawValue
                ?? (runtimeDependencies == nil ? nil : configuration.selectedAccountID?.rawValue)
        )
        let baseMailSearchService: any MailSearchService =
            mailSearchMaintenanceService ?? resolvedMailAuthority?.search ?? localMailSearchService
        let mailSearchService: any MailSearchService
        if runtimeDependencies != nil {
            mailSearchService = DirectSourceBoundMailSearchService(
                base: localMailSearchService, store: store,
                accountID: configuration.selectedAccountID,
                sourceGeneration: selectedDirectSourceGeneration,
                isDeviceWide: configuration.selectedAccountID == nil && configuration.mailAuthority == nil,
                readState: deviceDirectReadState
            )
        } else {
            mailSearchService = baseMailSearchService
        }
        self.mailSearchService = mailSearchService
        let mailSearchMaintenance = MailSearchMaintenanceCoordinator(
            service: mailSearchService,
            reportFailure: store.recordSearchMaintenanceFailure
        )
        self.mailSearchMaintenance = mailSearchMaintenance
        let deviceWideDirect = runtimeDependencies != nil && configuration.selectedAccountID == nil
            && configuration.mailAuthority == nil
        self.inboxProjectionRepository = InboxProjectionRepository(
            source: deviceWideDirect
                ? SQLiteInboxProjectionSource(store: store, scope: .deviceDirect)
                : SQLiteInboxProjectionSource(
                    store: store,
                    accountID: configuration.selectedAccountID,
                    requiresDirectSource: runtimeDependencies != nil,
                    expectedDirectGeneration: selectedDirectSourceGeneration
                )
        )
        let browserRegistrationStatus =
            BrowserNativeHostRegistrationStatus()
        self.browserRegistrationStatus = browserRegistrationStatus
        let directComposerSender: any DirectComposerSending
        if let authority = resolvedMailAuthority {
            directComposerSender = NodeAuthorityDirectComposerSender(mutations: authority.mutations)
        } else if accountAccess == .cachedReadOnly {
            directComposerSender = UnconfiguredDirectComposerSender()
        } else {
            directComposerSender = try runtimeDependencies?.makeDirectComposerSender(store: store)
                ?? PlainpostServiceDirectComposerSender(serviceClient: resolvedServiceClient)
        }
        // The device-wide runtime sends a Sync Node account's draft through the device's Node.
        let composerSender: any DirectComposerSending = deviceWideDirect
            ? DeviceMailComposerSender(store: store, direct: directComposerSender, nodeMail: runtimeDependencies?.deviceNodeMail)
            : directComposerSender
        // The Mac sends from any account, so it surfaces any account's uncertain send.
        let uncertainAccountIDs: [AccountID] = configuration.selectedAccountID.map { [$0] }
            ?? (runtimeDependencies == nil
                ? store.accounts.map(\.id)
                : DeviceMailScope.current(in: store).accountIDs.sorted { $0.rawValue < $1.rawValue })
        let uncertainIntents = try uncertainAccountIDs.flatMap { try store.uncertainDirectSendIntents(accountID: $0) }
        // The device-wide runtime re-checks a send's From account when Undo ends, and
        // remembers it as the default for the next new message.
        let sourceAtSchedule: @MainActor (Draft) -> Int64?
        let validateBeforeSend: @Sendable (Draft, Int64?) throws -> Void
        let didSend: @MainActor (Draft) -> Void
        if deviceWideDirect {
            sourceAtSchedule = { [store] draft in
                try? DeviceMailScope.requireCurrentOwner(draft.accountID, expected: nil, in: store)
            }
            validateBeforeSend = { [store] draft, scheduled in
                // No source at Send means the account already wasn't Direct: refuse.
                guard let scheduled else { throw NodeMailModeStoreError.generationConflict }
                try DeviceMailScope.requireCurrentOwner(draft.accountID, expected: scheduled, in: store)
            }
            didSend = { draft in ComposerFromAccountPreference().recordSent(from: draft.accountID) }
        } else {
            sourceAtSchedule = { _ in nil }
            validateBeforeSend = { _, _ in }
            // The Mac remembers the last account sent from too; a selected-account runtime has
            // only one to choose.
            if runtimeDependencies == nil, configuration.selectedAccountID == nil, configuration.mailAuthority == nil {
                didSend = { draft in ComposerFromAccountPreference().recordSent(from: draft.accountID) }
            } else {
                didSend = { _ in }
            }
        }
        self.undoSendCoordinator = UndoSendCoordinator(
            sender: composerSender, uncertainIntents: uncertainIntents,
            sleep: undoSendSleep, sourceAtSchedule: sourceAtSchedule,
            validateBeforeSend: validateBeforeSend, didSend: didSend)
        let resolvedNotificationScheduler: any LocalNotificationScheduling = accountAccess == .cachedReadOnly
            ? NoopLocalNotificationScheduler()
            : (notificationScheduler ?? makeNotificationScheduler())
        self.notificationScheduler = resolvedNotificationScheduler
        let packagedWorkerSignal: (any OperationWorkerSignaling)?
        if accountAccess == .cachedReadOnly {
            packagedWorkerSignal = nil
        } else if let operationWorkerSignal {
            packagedWorkerSignal = operationWorkerSignal
        } else {
#if DEBUG
            packagedWorkerSignal = packagedOperationWorkerSignalFactory()
#else
            packagedWorkerSignal = packagedOperationWorkerSignalFactory()
#endif
        }
        self.operationWorkerSignal = packagedWorkerSignal
        self.smartInboxResumeSignalRetryDelay =
            smartInboxResumeSignalRetryDelay
        let selectedAIProviderID: @Sendable () -> String = {
            AIProviderSelection.resolvedProviderID(
                from: aiProviderPreferences
            )
        }
        let mailRuntime = accountAccess == .cachedReadOnly ? nil : runtimeDependencies?.makeOperationRuntime(
            store: store, allowedJobKinds: Self.guiMailOperationJobKinds,
            selectedDirectAccountID: configuration.selectedAccountID,
            expectedDirectSourceGeneration: selectedDirectSourceGeneration)
        let mailOperationClient: any PlainpostOperationClientProtocol
        if accountAccess == .cachedReadOnly {
            mailOperationClient = AccountReadOnlyOperationClient()
        } else if runtimeDependencies == nil {
            mailOperationClient = PlainpostServiceOperationAdapter(
                serviceClient: resolvedServiceClient)
        } else if let workerSignal = packagedWorkerSignal {
            mailOperationClient = QueuedOperationClient(store: store, workerSignal: workerSignal)
        } else {
            mailOperationClient = LocalOperationClient(runtime: mailRuntime!)
        }
        self.mailOperationClient = mailOperationClient
        let aiOperationClient:
            any PlainpostOperationClientProtocol
        if accountAccess == .cachedReadOnly {
            aiOperationClient = AccountReadOnlyOperationClient()
        } else if let aiOperationClientFactory {
            aiOperationClient = aiOperationClientFactory(store)
        } else if runtimeDependencies == nil {
            aiOperationClient = PlainpostServiceOperationAdapter(
                serviceClient: resolvedServiceClient)
        } else if let workerSignal = packagedWorkerSignal {
            aiOperationClient = QueuedOperationClient(
                store: store,
                workerSignal: workerSignal
            )
        } else {
            aiOperationClient = LocalOperationClient(
                runtime: runtimeDependencies!.makeOperationRuntime(
                    store: store, allowedJobKinds: [.aiOperation, .searchRebuild],
                    selectedDirectAccountID: configuration.selectedAccountID,
                    expectedDirectSourceGeneration: selectedDirectSourceGeneration))
        }
        self.aiOperationClient = aiOperationClient
        let smartInboxPowerGate = injectedSmartInboxPowerGate ?? SmartInboxPowerGate()
        self.smartInboxPowerGate = smartInboxPowerGate
        // The device-wide runtime organizes every account's inbox, unscoped, as on the Mac.
        let requiresDirectSmartInboxScope = runtimeDependencies != nil && !deviceWideDirect
        let selectedSmartInboxAccountID = configuration.selectedAccountID
        let selectedSmartInboxGeneration = try selectedSmartInboxAccountID.map {
            try store.mailSource(accountID: $0).generation
        }
        let smartInboxSyncCompletionOrganizer = SmartInboxSyncCompletionOrganizer(
            client: aiOperationClient,
            selectedAIProviderID: selectedAIProviderID,
            aiGenerationAvailable: { PlainpostAIGenerationPolicy.current },
            smartInboxEnabled: { aiProviderPreferences.smartInboxEnabled() && smartInboxPowerGate.allowsWork },
            scopeProvider: {
                guard requiresDirectSmartInboxScope else { return .allAccounts }
                guard let selectedSmartInboxAccountID else {
                    throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
                }
                try store.requireDirectMailSource(accountID: selectedSmartInboxAccountID)
                return .account(selectedSmartInboxAccountID)
            },
            directSourceProvider: {
                guard requiresDirectSmartInboxScope else { return nil }
                guard let selectedSmartInboxAccountID, let selectedSmartInboxGeneration else {
                    throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
                }
                try store.requireDirectMailSource(accountID: selectedSmartInboxAccountID)
                return (selectedSmartInboxAccountID, selectedSmartInboxGeneration)
            }
        )
        // With no helper to launch (iOS), read-state and archive write-back runs here.
        let mailboxWriteBackWorker: InProcessOperationWorkerSignal?
        if packagedWorkerSignal == nil, accountAccess != .cachedReadOnly, let runtimeDependencies {
            mailboxWriteBackWorker = InProcessOperationWorkerSignal(runtime: runtimeDependencies.makeOperationRuntime(
                store: store, allowedJobKinds: [.mailboxFlag, .mailboxArchive],
                selectedDirectAccountID: configuration.selectedAccountID,
                expectedDirectSourceGeneration: selectedDirectSourceGeneration))
            // Only the screen that asked runs a question or translation here; one left by an
            // earlier launch has no one waiting and would stay queued.
            try? LocalOperationRuntime.cancelAbandonedInteractiveAIJobs(in: store)
        } else {
            mailboxWriteBackWorker = nil
        }
        let syncCompletionHandler: @Sendable () async -> Void = {
            await backgroundWork.start {
                await mailSearchMaintenance.perform(now: Date())
            }
            // Retries write-back that failed offline, and anything queued without a signal.
            try? await mailboxWriteBackWorker?.signalWork()
            await smartInboxSyncCompletionOrganizer.requestIncrementalOrganization()
        }
        self.syncCompletionHandler = syncCompletionHandler
        self.requestSmartInboxOrganization = {
            await smartInboxSyncCompletionOrganizer.requestIncrementalOrganization()
        }
        smartInboxPowerGate.observe { allowsWork in
            Task { @MainActor in
                backgroundWork.start {
                    if allowsWork {
                        await smartInboxSyncCompletionOrganizer.requestIncrementalOrganization()
                    } else if let client = aiOperationClient as? LocalOperationClient {
                        _ = await client.cancelAndWaitForIncrementalSmartInbox()
                    }
                }
            }
        }
        let accountGenerationProvider: (@Sendable (Account) throws -> Int64?)?
        if deviceWideDirect {
            accountGenerationProvider = { [store] account in
                try DeviceMailScope.requireCurrentDirectOwner(account.id, expected: nil, in: store)
            }
        } else {
            accountGenerationProvider = nil
        }
        let inboxSyncer = LocalOperationAccountInboxSyncer(
            client: mailOperationClient,
            notificationScheduler: resolvedNotificationScheduler,
            didCompleteSync: syncCompletionHandler,
            directSourceProvider: {
                guard requiresDirectSmartInboxScope else { return nil }
                guard let selectedSmartInboxAccountID, let selectedSmartInboxGeneration else {
                    throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
                }
                return (selectedSmartInboxAccountID, selectedSmartInboxGeneration)
            },
            accountGenerationProvider: accountGenerationProvider
        )
        self.inboxSyncer = inboxSyncer
        self.foregroundInboxRefresh = (mailOperationClient as? LocalOperationClient).map { client in
            DirectMailForegroundRefreshCoordinator(client: client) { account, result in
                await inboxSyncer.didFinishForegroundOwnedSync(account: account, result: result)
            }
        }
        let mailboxFlagScheduler = DurableMailboxFlagScheduler(
            store: store,
            workerSignal:
                packagedWorkerSignal
                    ?? mailboxWriteBackWorker
                    ?? NoopOperationWorkerSignal()
        )
        self.mailboxFlagScheduler = mailboxFlagScheduler
        let messageOpening = MessageOpeningService(
            store: store,
            scheduler: mailboxFlagScheduler
        )
        self.messageOpening = messageOpening
        #if os(macOS)
        if accountAccess == .readWrite,
           !(runtimeDependencies != nil && configuration.selectedAccountID != nil) {
            let localAPIServer = try PlainpostLocalServerFactory.make(
                socketURL: configuration.localAPISocketURL, store: store,
                lastSync: Self.localAPILastSync(store: store), messageOpening: messageOpening,
                inboxSyncer: mailOperationClient, aiClient: aiOperationClient,
                selectedProviderID: selectedAIProviderID,
                deliveryService: Self.localAPIDeliveryService(
                    store: store, runtime: mailRuntime, serviceClient: resolvedServiceClient))
            let localAPIOwnership = LocalAPIServerOwnershipCoordinator(
                server: localAPIServer
            )
            try localAPIOwnership.activate()
            self.localAPIOwnership = localAPIOwnership
            self.localAPIOwnershipMaintenance = Task {
                await localAPIOwnership.maintainOwnership()
            }
        } else {
            self.localAPIOwnership = nil
            self.localAPIOwnershipMaintenance = nil
        }
        #else
        self.localAPIOwnership = nil
        self.localAPIOwnershipMaintenance = nil
        #endif
        if let packagedWorkerSignal {
            backgroundWork.start {
                try? await packagedWorkerSignal.signalWork()
            }
        }
        if accountAccess == .readWrite, let runtimeDependencies {
            backgroundWork.start { [store] in
                try? await runtimeDependencies.recoverPendingLocalAccountDeletions(store: store)
            }
        }
        #if os(macOS)
        if accountAccess == .readWrite {
            browserNativeHostStartup(browserRegistrationStatus)
        }
        #endif
        let rerunPolicy = SmartInboxLowPowerRerunPolicy(
            activeRerunJob: { [weak self] in try? self?.activeSmartInboxRerunJob() },
            pause: { [weak self] jobID in try self?.pauseSmartInboxJob(id: jobID, reason: .lowPower) },
            liftLowPowerPauses: { [weak self] in try await self?.liftLowPowerSmartInboxPauses() }
        )
        smartInboxLowPowerRerunPolicy = rerunPolicy
        smartInboxPowerGate.observe { allowsWork in
            Task { @MainActor in rerunPolicy.schedule(allowsWork: allowsWork) }
        }
        // At launch: pause in Low Power Mode, or lift a pause an earlier run left.
        rerunPolicy.schedule(allowsWork: smartInboxPowerGate.allowsWork)
    }

    deinit {
        localAPIOwnershipMaintenance?.cancel()
        localAPIOwnership?.stop()
        Task {
        }
    }

    /// True while an undoable send waits out its undo window or is being
    /// delivered. Releasing the runtime in that window cancels the delivery.
    public var isSendPending: Bool {
        undoSendCoordinator.isSendPending
    }

    /// Publishes `isSendPending` changes, starting with the current value.
    public var sendPendingPublisher: AnyPublisher<Bool, Never> {
        undoSendCoordinator.sendPendingPublisher
    }

    /// True while a failed send's notice, and its draft restore, is showing.
    public var hasFailedSend: Bool {
        undoSendCoordinator.hasFailedSend
    }

    public var hasUncertainSend: Bool {
        undoSendCoordinator.hasUncertainSend
    }

    /// Acknowledges a failed send without reopening its draft.
    public func dismissFailedSend() {
        undoSendCoordinator.dismissFailedSend()
    }

    /// True while this runtime's embedded composer is open with unsaved changes.
    public var hasUnsavedOpenComposer: Bool {
        composerActivity.hasUnsavedOpenComposer
    }

    /// Publishes `hasUnsavedOpenComposer` changes, starting with the current value.
    public var unsavedOpenComposerPublisher: AnyPublisher<Bool, Never> {
        composerActivity.unsavedOpenComposerPublisher
    }

    public func shutdown() async {
        metadataReadGeneration &+= 1
        inboxRequestGeneration &+= 1
        await foregroundInboxRefresh?.shutdown()
        await macNewMailDelivery?.stop()
        localAPIOwnershipMaintenance?.cancel()
        await localAPIOwnershipMaintenance?.value
        localAPIOwnership?.stop()
        let drain = backgroundWork.beginShutdown()
        await drain.value
        attachmentState.clear()
    }

    /// The mailbox header's Sync Node status line and send notices. The
    /// status comes from the service over XPC; the app holds no Node session
    /// for mail. Send outcomes are read from the shared store's journal.
    /// Created once per runtime: every `makeRootView` (a parent re-render)
    /// shares it, so its status line and notice survive and only one model
    /// polls.
    func makeNodeMailModeStatusModel() -> NodeMailModeStatusModel {
        if let nodeMailModeStatusModel { return nodeMailModeStatusModel }
        let serviceClient = self.serviceClient
        let model = NodeMailModeStatusModel(
            fetchStatus: { try await serviceClient.nodeMailModeStatus() },
            store: store
        )
        nodeMailModeStatusModel = model
        return model
    }

    var localAPIOwnershipState:
        LocalAPIServerOwnershipCoordinator.State?
    {
        localAPIOwnership?.state
    }

    func didCompleteSync() async {
        await syncCompletionHandler()
    }

    public func makeAIProviderSettingsViewModel() -> AIProviderSettingsViewModel {
        if let aiProviderSettingsModel { return aiProviderSettingsModel }
        let model = AIProviderSettingsViewModel.production(
            preferenceStore: aiProviderPreferences,
            persistSmartInboxPolicy: { [weak self] mode in
                guard let self else { throw SmartInboxPolicyError.disabled }
                guard self.accountAccess == .readWrite else { return }
                try self.store.setSmartInboxMode(mode)
                self.aiProviderPreferences.saveSmartInboxMode(mode)
                guard mode.isEnabled else { return }
                self.backgroundWork.start { [weak self, signal = self.operationWorkerSignal] in
                    try? await signal?.signalWork()
                    await self?.requestSmartInboxOrganization()
                }
            }
        )
        aiProviderSettingsModel = model
        return model
    }

    public func makeMailMaintenanceViewModel(
        accountSetup: AccountSetupViewModel,
        aiProviderSettings: AIProviderSettingsViewModel
    ) -> MailMaintenanceViewModel {
        let activity = SmartInboxActivityCoordinator(
            jobProvider: { [weak self] in
                guard let self else { return nil }
                return try? self.smartInboxActivityJob()
            },
            pause: { [weak self] jobID in
                guard let self else { return }
                try self.pauseSmartInboxJob(id: jobID)
            },
            resume: { [weak self] jobID in
                guard let self else { return }
                try await self.resumeSmartInboxJob(id: jobID)
            },
            lowPowerAllowsWork: { [smartInboxPowerGate] in smartInboxPowerGate.allowsWork }
        )
        return MailMaintenanceViewModel(
            accountSetup: accountSetup,
            syncCoordinator: mailSyncCoordinator,
            smartInboxActivity: activity,
            activeRerunJob: { [weak self] in
                guard let self else { return nil }
                return try? self.activeSmartInboxRerunJob()
            },
            selectedProviderID: { aiProviderSettings.selectedProviderID },
            aiGenerationAvailable: { PlainpostAIGenerationPolicy.current },
            smartInboxSettings: aiProviderSettings,
            rerun: { [weak self] providerID, mode, requestID in
                guard let self else { return "Up to date" }
                return try await self.runSmartInboxMaintenance(
                    providerID: providerID,
                    mode: mode,
                    requestID: requestID
                )
            },
            didCompleteSuccessfully: { [weak self] in
                guard let self else { return }
                MailMaintenanceSuccessPolicy.perform(
                    advanceMailbox: self.invalidateInboxSnapshot,
                    refreshActivity: {}
                )
            },
            lowPowerModeActive: { [smartInboxPowerGate] in !smartInboxPowerGate.allowsWork },
            lowPowerModeChanges: smartInboxPowerGate.allowsWorkChanges.map { !$0 }.eraseToAnyPublisher(),
            // The selected account's newest error-free mailbox sync, or every cached
            // account's when the runtime has no selected account. One query per poll.
            lastSuccessfulSync: { [weak self] in self?.lastSuccessfulDirectSync() }
        )
    }

    #if os(macOS)
    public func makeCachedCalendarView(accountID: String) -> AnyView {
        AnyView(CachedCalendarWorkspace(accountID: accountID, appDataRoot: configuration.databaseURL.deletingLastPathComponent()))
    }
    #endif

    public func makeRootView(
        composerPresentationPolicy: ComposerPresentationPolicy = .runtimeWindow,
        providerOnboarding: (() -> Void)? = nil,
        accountSessionModel: AccountSessionViewModel? = nil,
        initialDestination: PlainpostDestination? = nil,
        initialSelectedMessageID: String? = nil,
        notificationOpenRequest: PlainpostNotificationOpenRequest? = nil,
        notificationOpenHandled: @escaping (UUID) -> Void = { _ in },
        onAccountSetupConnected: @escaping @MainActor @Sendable (AccountID) -> Void = { _ in }
    ) -> PlainpostRootView {
        let requiresLegacyAccountSetup = initialInboxViewModel().shouldPresentLegacyAccountSetup
        return PlainpostRootView(
            // Evaluated once, when SwiftUI first installs the root: a parent re-render that
            // calls this again builds no second session. Until then the root's value holds this
            // runtime, which is also what the root shows.
            session: self.makeMailSession(
                composerPresentationPolicy: composerPresentationPolicy,
                commitDelay: .zero,
                providerOnboarding: providerOnboarding,
                accountSessionModel: accountSessionModel,
                initialDestination: initialDestination,
                initialSelectedMessageID: initialSelectedMessageID,
                onAccountSetupConnected: onAccountSetupConnected,
                // The root's composer reads Contacts from the environment and never asks
                // this session for recipient suggestions.
                contactDirectory: nil
            ),
            notificationOpenRequest: notificationOpenRequest,
            notificationOpenHandled: notificationOpenHandled,
            inputs: PlainpostRootView.Inputs(
                settingsSection: PlainpostRootView.Inputs.settingsSection(
                    initial: nil,
                    destination: initialDestination,
                    requiresLegacyAccountSetup: requiresLegacyAccountSetup
                ),
                isAccountSetupRequired: requiresLegacyAccountSetup,
                calendarAuthority: accountSessionModel?.calendarAuthority,
                calendarAppDataRoot: configuration.databaseURL.deletingLastPathComponent(),
                notificationAccountInboxTokens: Set(notificationAccountIDs().map {
                    NotificationOpaqueIdentities.accountInboxToken(for: $0.rawValue)
                }),
                notificationMessageToken: { [scope = notificationScope] messageID in
                    scope.messageToken(for: messageID)
                },
                notificationInboxScope: { [scope = notificationScope] rawAccountID in
                    scope.inboxScope(for: rawAccountID)
                }
            )
        )
    }

    /// The mail UI's session: every controller and view model a mail screen needs, wired to this
    /// runtime. `makeRootView` hosts one in the macOS root; an iPhone UI can host one directly.
    /// `contactDirectory` is the app's Contacts directory, which recipient suggestions list
    /// first; without one they come from recent correspondents only.
    public func makeMailSession(
        composerPresentationPolicy: ComposerPresentationPolicy,
        commitDelay: Duration,
        providerOnboarding: (() -> Void)?,
        accountSessionModel: AccountSessionViewModel?,
        initialDestination: PlainpostDestination?,
        initialSelectedMessageID: String?,
        onAccountSetupConnected: @escaping @MainActor @Sendable (AccountID) -> Void,
        contactDirectory: ContactDirectoryModel?
    ) -> MailSession {
        let mailSearch = makeMailSearchViewModel()
        let accountSetup = makeAccountSetupViewModel(onCompletedAdd: onAccountSetupConnected)
        let aiProviderSettings = makeAIProviderSettingsViewModel()
        let session = MailSession.make(
            viewModel: initialInboxViewModel(),
            accountSetup: accountSetup,
            accountSessionModel: accountSessionModel,
            mailSearch: mailSearch,
            approvalQueue: makeApprovalQueueViewModel(),
            composer: makeComposerViewModel(),
            undoSendCoordinator: undoSendCoordinator,
            auditLog: makeAuditLogViewModel(),
            commandCenter: .preview(),
            aiAssistant: makeThreadAIAssistantViewModel(),
            askMail: makeAskMailViewModel(),
            conversationAskMail: makeAskMailViewModel(),
            conversationActionDetector: makeConversationActionDetector(),
            aiProviderSettings: aiProviderSettings,
            translationSettings: translationState.languageSettings,
            threadTranslation: makeThreadTranslationViewModel(),
            inboxMailActions: makeInboxMailActionViewModel(),
            nodeSettings: makeNodeSettingsViewModel(onConnectProvider: providerOnboarding),
            nodeMailModeStatus: makeNodeMailModeStatusModel(),
            attachmentState: attachmentState,
            mailRules: makeMailRulesViewModel(),
            mailLabels: makeMailLabelsViewModel(),
            messageLabelActions: makeMessageLabelActions(),
            openMessage: { [weak self] messageID in
                guard let self else { return }
                guard self.accountAccess == .readWrite else { return }
                let changed: Bool
                if let authority = self.mailAuthority {
                    _ = try await authority.mutations.perform(
                        .setRead(messageIDs: [MessageID(messageID)], read: true)
                    )
                    changed = true
                } else if self.isDeviceWideDirect {
                    changed = try await self.openConversation(MessageID(messageID), opening: self.openOwnedDirectMessage)
                } else if self.runtimeDependencies != nil {
                    changed = try await self.openConversation(MessageID(messageID), opening: self.openSelectedMessage)
                } else {
                    _ = try await self.messageOpening.open(MessageID(messageID))
                    changed = true
                }
                // Opening an already-read message changes nothing the list shows. Keeping
                // the projection makes the refresh after it a cached read, not a rebuild.
                if changed { self.invalidateInboxSnapshot() }
            },
            openAttachment: { [weak self] attachment in
                guard let self else { return }
                let operationToken = self.attachmentState.begin(attachmentID: attachment.id)
                let eventAccountID = self.attachmentState.accountID
                do {
                    let artifact: PlainpostAttachmentArtifact
                    if self.mailAuthority == nil {
                        artifact = try self.saveDirectAttachmentArtifact(attachment)
                    } else {
                        artifact = try await self.saveNodeAttachmentArtifact(attachment)
                    }
                    self.attachmentState.publish(PlainpostAttachmentEvent(accountID: eventAccountID, attachmentID: attachment.id, operationToken: operationToken, outcome: .saved(artifact)))
                } catch {
                    self.attachmentState.publish(PlainpostAttachmentEvent(accountID: eventAccountID, attachmentID: attachment.id, operationToken: operationToken, outcome: .failed(error.localizedDescription)))
                }
            },
            loadForwardAttachments: { [weak self] messageID in
                await self?.forwardAttachments(for: messageID) ?? ([], [])
            },
            loadInlineImages: { [weak self] messageID in
                self?.inlineImageParts(for: messageID) ?? []
            },
            localDrafts: LocalDraftActions(
                load: { [weak self] accountID in self?.localDrafts(accountID: accountID) ?? [] },
                snapshot: { [weak self] draft in
                    self?.restoreSnapshot(forLocalDraft: draft)
                        ?? ComposerRestoreSnapshot(savedDraft: draft, sourceMessageID: nil)
                },
                discard: { [weak self] draft in try self?.discardLocalDraft(draft) }
            ),
            initialDestination: initialDestination,
            initialSelectedMessageID: initialSelectedMessageID,
            loadMailboxDirectory: { [weak self] in
                await self?.mailboxDirectorySections() ?? []
            },
            contactDirectory: contactDirectory,
            loadCorrespondents: { [weak self] in
                await self?.recentCorrespondents() ?? []
            },
            onAccountSetupConnected: onAccountSetupConnected,
            composerPresentationPolicy: composerPresentationPolicy,
            commitDelay: commitDelay,
            viewModelProvider: { [weak self] messageID in
                guard let self else {
                    return InboxViewModel.preview()
                }
                return await self.makeInboxSelectionViewModelAsync(selectedMessageID: messageID)
            },
            loadMoreViewModelProvider: { [weak self] messageID in
                guard let self else { return InboxViewModel.preview() }
                return await self.loadMoreInboxSelectionViewModelAsync(selectedMessageID: messageID)
            },
            threadProvider: { [weak self] messageID in
                await self?.selectedThreadDetailAsync(messageID: messageID)
            },
            invalidateInboxSnapshot: { [weak self] in
                self?.invalidateInboxSnapshot()
            },
            configureAIAssistant: { [weak self] viewModel, providerID in
                self?.configureThreadAIAssistant(viewModel, providerID: providerID)
            },
            configureAskMail: { [weak self] viewModel, providerID in
                self?.configureAskMail(viewModel, providerID: providerID)
            },
            configureThreadTranslation: { [weak self] viewModel, providerID in
                self?.configureThreadTranslation(viewModel, providerID: providerID)
            },
            searchIndexState: { [mailSearchService] in
                await mailSearchService.indexState()
            },
            rebuildSearchIndex: { [weak self, mailSearchService] in
                guard self?.accountAccess == .readWrite else {
                    throw PlainpostError.validationFailed(
                        "This cached mailbox is read-only while the account is offline."
                    )
                }
                try await mailSearchService.rebuildIndex()
            },
            allowsSearchIndexRebuild: runtimeDependencies == nil,
            refreshMailSearchMailboxes: { [weak self, weak mailSearch] forceReload in
                guard let self, let mailSearch else { return }
                guard self.accountAccess == .readWrite else { return }
                await self.refreshMailSearchMailboxes(
                    in: mailSearch,
                    forceReload: forceReload
                )
            },
            refreshSmartInbox: { [weak self] providerID, mode, requestID in
                guard let self else {
                    return "Up to date"
                }
                return try await self.runSmartInboxMaintenance(
                    providerID: providerID,
                    mode: mode,
                    requestID: requestID
                )
            },
            allowsMailboxMutations: { [weak self, weak accountSessionModel] in
                // Cached read-only runtimes and non-active sessions (offline lease) never mutate.
                guard self?.accountAccess == .readWrite else { return false }
                return accountSessionModel?.presentation.allowsMailboxMutations ?? true
            },
            composerActivity: composerActivity,
            accountForMessage: { [weak self] in self?.account(forMessageID: $0) },
            loadFolderRows: { [weak self] in try await self?.folderRows(accountID: $0, path: $1, limit: $2) ?? [] },
            maintenance: makeMailMaintenanceViewModel(
                accountSetup: accountSetup,
                aiProviderSettings: aiProviderSettings
            )
        )
        // A Sync Node runtime never erases, so its Trash offers no Delete Permanently.
        session.offersPermanentDelete = mailAuthority == nil
        session.isMessageFlagged = { [store] id in (try? store.messageSummary(id: MessageID(id)))??.isFlagged == true }
        return session
    }

    /// The mailbox a new root shows until its first snapshot loads.
    private func initialInboxViewModel() -> InboxViewModel {
        .loading(
            requiresAccountSetup: mailAuthority == nil && store.accounts.isEmpty,
            setupSource: mailAuthority == nil ? .localAccount : .syncNode
        )
    }

    /// Resolves an opaque notification token without logging or returning any
    /// identifier that the local mail authority cannot prove exists.
    /// - Parameter logicalMailboxHint: a push envelope's logical mailbox (base64url), an
    ///   unauthenticated hint naming which Sync Node account to look in first.
    public func resolveNotificationOpen(
        _ token: String, logicalMailboxHint: String? = nil
    ) async -> PlainpostNotificationOpenDestination {
        let signposter = OSSignposter(subsystem: "com.plainpost.performance", category: "runtime")
        let interval = signposter.beginInterval("NotificationOpen", id: signposter.makeSignpostID())
        defer { signposter.endInterval("NotificationOpen", interval) }
        guard !token.isEmpty, token.utf8.count <= 256,
              !token.contains(where: { $0 == "\0" || $0.isNewline }) else { return .allInboxes }
        guard !Task.isCancelled else { return .allInboxes }
        let generation = metadataReadGeneration
        guard let read = try? await inboxProjectionRepository.notificationIdentity(token),
              (try? await inboxProjectionRepository.verifyAuthority(read.authority)) != nil,
              generation == metadataReadGeneration, !Task.isCancelled,
              acceptsReadAuthority(read.authority) else { return .allInboxes }
        if let destination = read.destination { return destination }
        if isDeviceWideDirect {
            return await resolveMirroredNotificationOpen(token, logicalMailboxHint: logicalMailboxHint)
        }
        let selectedAccountID = configuration.selectedAccountID
        let selectedSource = read.authority.source
        if runtimeDependencies != nil { return .allInboxes }
        if let selectedAccountID {
            guard let nodeAuthority = mailAuthority as? PlainpostNodeMailAuthority,
                  nodeAuthority.accountID == selectedAccountID,
                  let nodeAccount = nodeAuthority.mailAccount,
                  selectedSource?.kind == .nodeBacked,
                  selectedSource?.mode == .node,
                  selectedSource?.providerIdentity == nodeAccount.providerIdentity else {
                return .allInboxes
            }
        }
        if let resolver = notificationDeepLinkResolver {
            if let messageID = await resolver.messageID(forOpaqueToken: token) {
                if (try? await inboxProjectionRepository.notificationMappingIsCurrent(
                    messageID: messageID, authority: read.authority
                )) == true, generation == metadataReadGeneration, !Task.isCancelled,
                   acceptsReadAuthority(read.authority) {
                    return .resolve(token: token, deepLinkMapping: [token: messageID])
                }
            }
            if let refresher = resolver as? any PlainpostNotificationDeepLinkRefreshing {
                guard generation == metadataReadGeneration, !Task.isCancelled else { return .allInboxes }
                await refresher.refreshForNotification()
                if let messageID = await resolver.messageID(forOpaqueToken: token) {
                    if (try? await inboxProjectionRepository.notificationMappingIsCurrent(
                        messageID: messageID, authority: read.authority
                    )) == true, generation == metadataReadGeneration, !Task.isCancelled,
                       acceptsReadAuthority(read.authority) {
                        return .resolve(token: token, deepLinkMapping: [token: messageID])
                    }
                }
            }
        }
        return .allInboxes
    }

    /// A Sync Node's push names the Node's own message ID: the device-wide runtime finds the
    /// message it mirrored from it, in place, with no account switch. A served account's
    /// message opens; anything else (its account removed, the message gone) is unavailable.
    /// The mirror writes while this waits, so the result is checked against the owner's
    /// current source rather than one read generation.
    private func resolveMirroredNotificationOpen(
        _ token: String, logicalMailboxHint: String?
    ) async -> PlainpostNotificationOpenDestination {
        let store = store
        let lookup = {
            await Task.detached(priority: .userInitiated) {
                DeviceMailScope.mirroredMessage(notificationToken: token, logicalMailboxHint: logicalMailboxHint, in: store)
            }.value
        }
        var found = await lookup()
        // A push can arrive (or launch the app) before the mirror has its message: mirror
        // now and look again for a moment before saying it's gone.
        if found == nil, let nodeMail = runtimeDependencies?.deviceNodeMail {
            await nodeMail.wake()
            for _ in 0..<Self.notificationMirrorRetries where found == nil && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                found = await lookup()
            }
        }
        guard !Task.isCancelled else { return .allInboxes }
        guard let found,
              let generationNow = try? DeviceMailScope.requireCurrentOwner(found.owner, expected: nil, in: store),
              store.accountID(forMessageID: found.messageID) == found.owner,
              (try? store.messageSummary(id: found.messageID))??.isDeleted == false else {
            return .messageUnavailable
        }
        let sources = DeviceMailScope.current(in: store)
        guard sources.generations[found.owner] == generationNow else { return .messageUnavailable }
        deviceDirectReadState.record([(found.messageID, found.owner)], sources: sources)
        return .message(found.messageID.rawValue)
    }

    /// How many times (a quarter second apart) a Sync Node push's message is looked for
    /// again after waking the mirror.
    static let notificationMirrorRetries = 12

    /// The actor re-reads database authority; this final synchronous check fences
    /// the selected runtime identity without waiting for SQLite on MainActor.
    private func acceptsReadAuthority(_ authority: InboxReadAuthority) -> Bool {
        if isDeviceWideDirect {
            guard authority.accountID == nil, let sources = authority.deviceDirect else { return false }
            deviceDirectReadState.value = sources
            return true
        }
        guard authority.accountID == configuration.selectedAccountID else { return false }
        if runtimeDependencies != nil, configuration.selectedAccountID != nil {
            guard authority.source?.kind == .direct,
                  authority.source?.generation == selectedDirectSourceGeneration else { return false }
        }
        if let expected = configuration.selectedNodeSource, authority.source != expected { return false }
        return true
    }

    /// Consumes the authority-owned one-shot attachment stream. The reader
    /// never reaches into a provider or local mailbox implementation.
    public func readNodeAttachment(_ attachment: MailAttachment) async throws -> Data {
        guard let mailAttachmentService else {
            throw PlainpostError.notFound("Attachment service is unavailable.")
        }
        return try await mailAttachmentService.attachment(id: attachment.id).readAll()
    }

    /// Saves one verified Node attachment as an observable local artifact.
    /// MailAttachmentStream.readAll validates declared size and SHA-256 before
    /// any bytes are written, and consuming the stream closes its producer.
    public func saveNodeAttachment(_ attachment: MailAttachment) async throws -> URL {
        let artifact = try await saveNodeAttachmentArtifact(attachment)
        return artifact.url
    }

    /// Writes a verified attachment into a unique mode-0700 temporary
    /// directory. The typed artifact owns cleanup and can be handed to a
    /// share/open surface without exposing a provider or mutable string event.
    public func saveNodeAttachmentArtifact(_ attachment: MailAttachment) async throws -> PlainpostAttachmentArtifact {
        let bytes = try await readNodeAttachment(attachment)
        let safeName = attachment.filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let filename = safeName.isEmpty ? attachment.id : safeName
        return try writeNodeAttachmentArtifact(
            bytes: bytes,
            filename: filename,
            temporaryRoot: FileManager.default.temporaryDirectory,
            write: { bytes, url in try bytes.write(to: url, options: .atomic) },
            setFilePermissions: { url in
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        )
    }

    /// The image parts a shown message's HTML names by `cid:`, read from this
    /// device's store. A message outside the runtime's account gets none.
    public func inlineImageParts(for messageID: String) -> [InlineImagePart] {
        let id = MessageID(messageID)
        guard let accountID = store.accountID(forMessageID: id),
              configuration.selectedAccountID == nil || configuration.selectedAccountID == accountID
        else { return [] }
        return (try? store.inlineImageParts(messageID: id)) ?? []
    }

    /// The drafts the person saved in this app's composer for an account, which
    /// the account's Drafts folder lists above the server's own drafts.
    public func localDrafts(accountID: AccountID) -> [Draft] {
        guard configuration.selectedAccountID == nil || configuration.selectedAccountID == accountID else { return [] }
        return (try? store.drafts(
            requiredIDPrefix: Self.localDraftIDPrefix, requiredCreatorID: Self.localDraftActor.id,
            accountID: accountID, limit: 200
        )) ?? []
    }

    /// Deletes a draft the person saved in this app's composer.
    public func discardLocalDraft(_ draft: Draft) throws {
        guard configuration.selectedAccountID == nil || configuration.selectedAccountID == draft.accountID else {
            throw PlainpostError.permissionDenied("This draft belongs to another account.")
        }
        try store.deleteDraft(
            id: draft.id, expectedHash: draft.contentHash, actor: Self.localDraftActor,
            requiredIDPrefix: Self.localDraftIDPrefix, requiredCreatorID: Self.localDraftActor.id
        )
    }

    /// What the composer needs to reopen a saved draft: the saved body already
    /// holds any quote, and a reply keeps its threading headers.
    public func restoreSnapshot(forLocalDraft draft: Draft) -> ComposerRestoreSnapshot {
        let source = draft.inReplyTo.flatMap { try? store.messageID(accountID: draft.accountID, rfcMessageID: $0) }
        return ComposerRestoreSnapshot(savedDraft: draft, sourceMessageID: source)
    }

    private static let localDraftIDPrefix = "drf_"
    private static let localDraftActor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

    /// Resolves only a currently selected Direct account's persisted incoming
    /// attachment. The source generation in the row identity fences old reader
    /// buttons after a Direct/Node transition, including a later return to Direct.
    func saveDirectAttachmentArtifact(_ attachment: MailAttachment) throws -> PlainpostAttachmentArtifact {
        guard mailAuthority == nil,
              let identity = DirectIncomingAttachmentID.decode(attachment.id),
              runtimeDependencies == nil || configuration.selectedAccountID == identity.accountID
                // The device-wide runtime opens the attachment of any account it syncs itself.
                || isDeviceWideDirect && DeviceMailScope.current(in: store).directSyncAccountIDs.contains(identity.accountID),
              store.accountID(forMessageID: identity.messageID) == identity.accountID else {
            throw PlainpostError.permissionDenied("Attachment is unavailable for this account.")
        }
        func requireCurrentSource() throws {
            let source = try store.mailSource(accountID: identity.accountID)
            guard source.runsDirectSync,
                  source.generation == identity.sourceGeneration else {
                throw PlainpostError.permissionDenied("Attachment source has changed.")
            }
            if runtimeDependencies != nil {
                try store.requireDirectSyncSource(accountID: identity.accountID)
            }
        }
        try requireCurrentSource()
        guard let metadata = try store.incomingMessageAttachmentMetadata(messageID: identity.messageID)
            .first(where: { $0.partPath == identity.partPath }),
              identity.attachment(for: metadata) == attachment else {
            throw PlainpostError.validationFailed("Attachment metadata has changed.")
        }
        var bytes = Data()
        bytes.reserveCapacity(metadata.byteCount)
        while bytes.count < metadata.byteCount {
            try requireCurrentSource()
            guard let chunk = try store.incomingMessageAttachmentChunk(
                messageID: identity.messageID, partPath: identity.partPath,
                offset: bytes.count, length: min(512 * 1_024, metadata.byteCount - bytes.count)
            ), chunk.metadata == metadata, !chunk.data.isEmpty else {
                throw PlainpostError.validationFailed("Attachment payload has changed.")
            }
            bytes.append(chunk.data)
        }
        guard bytes.count == metadata.byteCount,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
            throw PlainpostError.validationFailed("Attachment payload did not match its digest.")
        }
        try requireCurrentSource()
        let artifact = try writeNodeAttachmentArtifact(
            bytes: bytes, filename: metadata.filename,
            temporaryRoot: FileManager.default.temporaryDirectory,
            write: { bytes, url in try bytes.write(to: url, options: .atomic) },
            setFilePermissions: { url in
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        )
        do {
            try requireCurrentSource()
            return artifact
        } catch {
            try? artifact.cleanup()
            throw error
        }
    }

    func smartInboxActivityJob() throws -> PlainpostDurableJob? {
        if let (accountID, generation) = try selectedSmartInboxSource() {
            return try store.smartInboxActivityJob(
                accountID: accountID, sourceGeneration: generation
            )
        }
        return try store.smartInboxActivityJob()
    }

    func activeSmartInboxRerunJob() throws -> PlainpostDurableJob? {
        if let (accountID, generation) = try selectedSmartInboxSource() {
            return try store.activeSmartInboxRerunJob(
                accountID: accountID, sourceGeneration: generation
            )
        }
        return try store.activeSmartInboxRerunJob()
    }

    private func selectedSmartInboxSource() throws -> (AccountID, Int64)? {
        guard runtimeDependencies != nil, !isDeviceWideDirect else { return nil }
        // The local setup runtime has no selected provider account yet. It
        // cannot expose another account's jobs while its store is empty.
        if configuration.selectedAccountID == nil, store.accounts.isEmpty {
            return nil
        }
        guard let accountID = configuration.selectedAccountID,
              let generation = selectedDirectSourceGeneration else {
            throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
        }
        return (accountID, generation)
    }

    func pauseSmartInboxJob(id: String, reason: PlainpostJobPauseRequestReason = .userRequested) throws {
        guard accountAccess == .readWrite else {
            throw PlainpostError.validationFailed(
                "This cached mailbox is read-only while the account is offline."
            )
        }
        if let (accountID, generation) = try selectedSmartInboxSource() {
            try store.requestJobPause(
                id: id, accountID: accountID, sourceGeneration: generation, reason: reason
            )
        } else {
            try store.requestJobPause(id: id, reason: reason)
        }
    }

    /// Lifts every Low Power pause once Low Power Mode is off, then wakes the worker.
    func liftLowPowerSmartInboxPauses() async throws {
        guard accountAccess == .readWrite, smartInboxPowerGate.allowsWork else { return }
        guard try store.resumeLowPowerPausedJobs(now: Date()) > 0 else { return }
        try? await (operationWorkerSignal ?? NoopOperationWorkerSignal()).signalWork()
    }

    /// Waits for the Low Power policy to apply every power change seen so far.
    func settleSmartInboxLowPowerPolicy() async {
        await smartInboxLowPowerRerunPolicy?.settle()
    }

    func resumeSmartInboxJob(id: String) async throws {
        guard accountAccess == .readWrite else {
            throw PlainpostError.validationFailed(
                "This cached mailbox is read-only while the account is offline."
            )
        }
        guard smartInboxPowerGate.allowsWork else { throw SmartInboxPowerGateError.lowPowerMode }
        if let (accountID, generation) = try selectedSmartInboxSource() {
            try store.resumeUserPausedJob(
                id: id, accountID: accountID, sourceGeneration: generation, now: Date()
            )
        } else {
            try store.resumeUserPausedJob(id: id, now: Date())
        }
        let signal = operationWorkerSignal ?? NoopOperationWorkerSignal()
        do {
            try await signal.signalWork()
        } catch {
            let retryDelay = smartInboxResumeSignalRetryDelay
            Task {
                await retryDelay()
                try? await signal.signalWork()
            }
            throw SmartInboxActivityActionError(didCommitResume: true)
        }
    }

    public func makeMailRulesViewModel() -> MailRulesViewModel {
        MailRulesViewModel(
            store: store,
            processor: MailRuleProcessor(
                store: store,
                workerSignal: operationWorkerSignal ?? NoopOperationWorkerSignal(),
                expectedDirectSourceGeneration: runtimeDependencies == nil
                    ? nil : selectedDirectSourceGeneration,
                requireDirectSourceGeneration: runtimeDependencies != nil,
                perAccountDirectSource: isDeviceWideDirect
            ),
            accounts: ruleAccounts,
            selectedDirectAccountID: configuration.selectedAccountID
        )
    }

    /// The accounts Rules & Labels offer: every account, or only the device-wide runtime's
    /// Direct accounts (rules act on the provider through Direct sync).
    private var ruleAccounts: [Account] {
        guard isDeviceWideDirect else { return store.accounts }
        let direct = DeviceMailScope.current(in: store).directAccountIDs
        return store.accounts.filter { direct.contains($0.id) }
    }

    public func makeMailLabelsViewModel() -> MailLabelsViewModel {
        MailLabelsViewModel(
            definitions: store,
            accounts: ruleAccounts,
            selectedDirectAccountID: configuration.selectedAccountID,
            runReclassification: { [weak self] request in
                guard let self else {
                    throw PlainpostError.notFound("Plainpost runtime")
                }
                return try await self.reclassifyMailLabel(request)
            }
        )
    }

    /// The Node mail accounts Settings lists, resolved from the active Sync Node authority.
    /// There is never more than one, because a runtime has at most one mail authority.
    public var settingsNodeMailAccounts: [NodeMailAccount] {
        guard let authority = mailAuthority as? PlainpostNodeMailAuthority else { return [] }
        return [authority.mailAccount].compactMap { $0 }
    }

    public func makeInboxViewModel() -> InboxViewModel {
        let selectedMessageID: String?
        if let accountID = configuration.selectedAccountID {
            selectedMessageID = try? store.mailboxListMessages(
                inMailboxPath: "INBOX", accountID: accountID, limit: 1, query: ""
            ).first?.id.rawValue
        } else {
            selectedMessageID = store.messages.first?.id.rawValue
        }
        return makeInboxViewModel(selectedMessageID: selectedMessageID)
    }

    public func makeAIIndexStatusModel() -> AIIndexStatusModel {
        let indexedMessageCount: Int
        if runtimeDependencies != nil, !isSelectedDirectSourceCurrent {
            indexedMessageCount = 0
        } else if isDeviceWideDirect {
            indexedMessageCount = DeviceMailScope.current(in: store).accountIDs.reduce(0) {
                $0 + ((try? store.activeMessageCount(accountID: $1)) ?? 0)
            }
        } else if runtimeDependencies != nil, let accountID = configuration.selectedAccountID {
            indexedMessageCount = (try? store.activeMessageCount(accountID: accountID)) ?? 0
        } else {
            #if os(iOS)
            indexedMessageCount = configuration.selectedAccountID.flatMap {
                try? store.activeMessageCount(accountID: $0)
            } ?? 0
            #else
            indexedMessageCount = (try? store.activeMessageCount()) ?? 0
            #endif
        }
        return AIIndexStatusModel(
            snapshot: AIIndexStatusSnapshot(
                state: .ready,
                indexedMessageCount: indexedMessageCount,
                providerID: "local-search",
                modelID: "built-in-local-embeddings",
                isStale: false,
                localOnly: true
            )
        )
    }

    public func makeMailSearchViewModel() -> MailSearchViewModel {
        let deviceDirectAccounts = isDeviceWideDirect ? DeviceMailScope.current(in: store).accountIDs : nil
        return MailSearchViewModel(
            accounts: store.accounts.filter {
                if let deviceDirectAccounts { return deviceDirectAccounts.contains($0.id) }
                return configuration.selectedAccountID == nil || $0.id == configuration.selectedAccountID
            }.map {
                MailSearchAccount(
                    id: $0.id,
                    displayName: $0.displayName.isEmpty ? $0.email.rawValue : $0.displayName,
                    email: $0.email.rawValue
                )
            },
            service: mailSearchService
        )
    }

    func refreshMailSearchMailboxes(
        in viewModel: MailSearchViewModel,
        forceReload: Bool
    ) async {
        await refreshMailSearchMailboxes(in: viewModel, forceReload: forceReload) { forceReload in
            try await self.inboxProjectionRepository.mailSearchMailboxes(forceReload: forceReload)
        }
    }

    /// Shares admission and publication checks around the asynchronous metadata read.
    func refreshMailSearchMailboxes(
        in viewModel: MailSearchViewModel,
        forceReload: Bool,
        load: @MainActor (Bool) async throws -> [MailSearchMailbox]
    ) async {
        guard !Task.isCancelled else { return }
        guard isSelectedDirectSourceCurrent else {
            viewModel.updateMailboxes([])
            return
        }
        guard let mailboxes = try? await load(forceReload), !Task.isCancelled else { return }
        guard isSelectedDirectSourceCurrent else {
            viewModel.updateMailboxes([])
            return
        }
        let deviceDirectAccounts = isDeviceWideDirect ? DeviceMailScope.current(in: store).accountIDs : nil
        // A search scoped to some accounts offers only their mailboxes.
        let scopedAccounts = Set(viewModel.scope.accountIDs)
        viewModel.updateMailboxes(mailboxes.filter {
            if !scopedAccounts.isEmpty, !scopedAccounts.contains($0.accountID) { return false }
            if let deviceDirectAccounts { return deviceDirectAccounts.contains($0.accountID) }
            return configuration.selectedAccountID == nil || $0.accountID == configuration.selectedAccountID
        })
    }

    /// Each account's folders with unread counts, for the mailbox directory. The local store
    /// answers for Direct and mirrored accounts. A Sync Node authority's mail isn't in the
    /// store, and the Node serves no folder list or counts, so its account lists its stored
    /// mailboxes plus the paths in the latest snapshot page, counted from that page (the
    /// same messages its inbox and sidebar count).
    func mailboxDirectorySections() async -> [MailboxAccountSection] {
        guard isSelectedDirectSourceCurrent else { return [] }
        if let mailAuthority {
            guard let accountID = mailAuthority.accountID,
                  configuration.selectedAccountID == nil || configuration.selectedAccountID == accountID,
                  let account = store.accounts.first(where: { $0.id == accountID }) else { return [] }
            // Counts come from the newest snapshot page (up to 200 messages), so a large Node mailbox undercounts.
            return MailboxDirectoryModel.sections(
                accounts: [account],
                mailboxes: (try? store.mailboxes(
                    limit: MailboxDirectoryModel.mailboxLimit,
                    accountID: accountID
                )) ?? [],
                unreadCounts: [accountID: MailboxDirectoryModel.unreadCounts(messages: nodeSnapshotMessages)]
            )
        }
        guard let sections = try? await inboxProjectionRepository.mailboxDirectory(),
              isSelectedDirectSourceCurrent else { return [] }
        let statuses = await accountSyncStatuses()
        return sections.map { section in
            var section = section
            section.status = statuses[section.id] ?? .ok
            return section
        }
    }

    /// Each account that isn't syncing, and why: a sign-in to renew, an unreachable Sync
    /// Node, or a failed last sync. One account's problem never marks another.
    func accountSyncStatuses() async -> [AccountID: AccountSyncStatus] {
        var statuses: [AccountID: AccountSyncStatus] = [:]
        for accountID in directSyncFailures { statuses[accountID] = .failed }
        if let nodeMail = runtimeDependencies?.deviceNodeMail, isDeviceWideDirect {
            for (accountID, state) in await nodeMail.accountStates() {
                switch state {
                case .ready: break
                case .unreachable: statuses[accountID] = .syncNodeUnreachable
                case .noLongerOnSyncNode: statuses[accountID] = .noLongerOnSyncNode
                }
            }
        }
        for accountID in (try? store.reauthorizationRequiredAccountIDs()) ?? [] {
            statuses[accountID] = .needsSignIn
        }
        return statuses
    }

    /// Records which accounts' last sync failed; a section's status line follows.
    private func recordDirectSync(failed: Set<AccountID>, synced: Set<AccountID>) {
        let updated = directSyncFailures.subtracting(synced).union(failed)
        guard updated != directSyncFailures else { return }
        directSyncFailures = updated
        // The directory reloads on the change, so the section's status line follows.
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    /// Up to `limit` of one account folder's rows for the iPhone folder list. A Sync Node
    /// account's come from the latest snapshot page, the only Node mail held locally, so a Node
    /// folder never shows more than that page holds (a known limit: the Node has no folder
    /// query yet).
    func folderRows(accountID: AccountID, path: String, limit: Int) async throws -> [MessageRowModel] {
        guard isSelectedDirectSourceCurrent else { return [] }
        if mailAuthority != nil {
            return nodeSnapshotMessages
                .filter { !$0.isDeleted && $0.mailboxPath.caseInsensitiveCompare(path) == .orderedSame }
                .sorted { ($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast) }
                .prefix(limit)
                .map(MessageRowModel.init(message:))
        }
        guard isDeviceWideDirect else {
            return try await inboxProjectionRepository.folderRows(accountID: accountID, path: path, limit: limit)
        }
        // A folder list is its own read: its rows are acted on against the sources it was read at.
        let sources = DeviceMailScope.current(in: store)
        let rows = try await inboxProjectionRepository.folderRows(accountID: accountID, path: path, limit: limit)
        guard DeviceMailScope.current(in: store) == sources else { return [] }
        deviceDirectReadState.record(rows.map { (MessageID($0.id), $0.accountID ?? accountID) }, sources: sources)
        return rows
    }

    /// The people this session's accounts have mailed with, newest first, for recipient
    /// suggestions; no address the user sends from appears. The local store answers for
    /// Direct and mirrored accounts, across every account the session shows (one when an
    /// account is selected). A Sync Node authority's mail isn't in the store, so its account's
    /// come from the latest snapshot page, which carries senders, To and Cc.
    func recentCorrespondents() async -> [Correspondent] {
        guard isSelectedDirectSourceCurrent else { return [] }
        let ownAddresses = Set(store.accounts.map { $0.email.rawValue })
        if let mailAuthority {
            guard let accountID = mailAuthority.accountID,
                  configuration.selectedAccountID == nil || configuration.selectedAccountID == accountID else {
                return []
            }
            return Correspondent.recent(in: nodeSnapshotMessages, ownAddresses: ownAddresses)
        }
        guard let correspondents = try? await inboxProjectionRepository.recentCorrespondents(
            ownAddresses: ownAddresses
        ), isSelectedDirectSourceCurrent else { return [] }
        return correspondents
    }

    /// The account a message belongs to, for per-account choices such as Archive vs Delete.
    /// Lists ask per row, so this avoids the store: a runtime scoped to one account answers
    /// from a cache read once per account change, and the device-wide iPhone runtime from what
    /// its lists recorded when they read the row.
    func account(forMessageID messageID: String) -> Account? {
        if let scopedAccountID = mailAuthority?.accountID ?? configuration.selectedAccountID {
            return scopedAccountCache.account(scopedAccountID) { [store] in
                store.accounts.first { $0.id == scopedAccountID }
            }
        }
        if isDeviceWideDirect, let owner = deviceDirectReadState.owner(of: MessageID(messageID)),
           let account = deviceDirectReadState.account(owner) {
            return account
        }
        guard let accountID = store.accountID(forMessageID: MessageID(messageID)) else { return nil }
        return store.accounts.first { $0.id == accountID }
    }

    public func makeInboxViewModel(selectedMessageID: String?) -> InboxViewModel {
        // Public callers use this as a fresh database projection. The app's
        // selection path below is intentionally narrower and reuses the shell.
        invalidateInboxSnapshot()
        return makeInboxSelectionViewModel(selectedMessageID: selectedMessageID)
    }

    func makeInboxSelectionViewModel(selectedMessageID: String?) -> InboxViewModel {
        guard isSelectedDirectSourceCurrent else { return staleDirectInboxViewModel() }
        // Selection changes are much more frequent than mailbox mutations. Keep
        // the database-backed shell stable while the user moves between rows so
        // a click only resolves the selected conversation instead of querying,
        // grouping, and classifying the complete mailbox again on the main actor.
        let snapshot = currentInboxMailboxSnapshot()
        return Self.makeInboxSelectionViewModel(
            snapshot: snapshot,
            selectedMessageID: selectedMessageID,
            selectedAccountID: configuration.selectedAccountID
        )
    }

    /// `messageID`'s conversation alone, read without rebuilding the mailbox projection, so
    /// an opened message shows before the list refresh. Nil for a Sync Node runtime, whose
    /// thread arrives with its snapshot, and for a read the source changed under.
    func selectedThreadDetailAsync(messageID: String) async -> ThreadDetailModel? {
        guard mailAuthority == nil, !Task.isCancelled else { return nil }
        let signposter = OSSignposter(subsystem: "com.plainpost.performance", category: "runtime")
        let interval = signposter.beginInterval("SelectedThread", id: signposter.makeSignpostID())
        defer { signposter.endInterval("SelectedThread", interval) }
        let generation = metadataReadGeneration
        do {
            let authority = try await inboxProjectionRepository.readAuthority()
            guard acceptsReadAuthority(authority) else { return nil }
            let detail = try await inboxProjectionRepository.threadDetail(messageID: messageID)
            try await inboxProjectionRepository.verifyAuthority(authority)
            guard generation == metadataReadGeneration, !Task.isCancelled,
                  acceptsReadAuthority(authority) else { return nil }
            return detail
        } catch {
            return nil
        }
    }

    func makeInboxSelectionViewModelAsync(selectedMessageID: String?) async -> InboxViewModel {
        await makeInboxSelectionViewModelAsync(
            selectedMessageID: selectedMessageID,
            limit: inboxPageLimit
        )
    }

    func loadMoreInboxSelectionViewModelAsync(selectedMessageID: String?) async -> InboxViewModel {
        inboxPageLimit += InboxProjectionRepository.pageSize
        return await makeInboxSelectionViewModelAsync(
            selectedMessageID: selectedMessageID,
            limit: inboxPageLimit
        )
    }

    private func makeInboxSelectionViewModelAsync(
        selectedMessageID: String?,
        limit: Int
    ) async -> InboxViewModel {
        let signposter = OSSignposter(subsystem: "com.plainpost.performance", category: "runtime")
        let interval = signposter.beginInterval("InboxSelection", id: signposter.makeSignpostID())
        defer { signposter.endInterval("InboxSelection", interval) }
        guard !Task.isCancelled else { return staleDirectInboxViewModel() }
        inboxRequestGeneration &+= 1
        let requestGeneration = inboxRequestGeneration
        let generation = metadataReadGeneration
        if let mailAuthority {
            do {
                let authority = try await inboxProjectionRepository.readAuthority()
                guard acceptsReadAuthority(authority) else { return staleDirectInboxViewModel() }
                let page = try await mailAuthority.snapshots.snapshot(after: nil, limit: min(limit, 200))
                let selectedMessages: [MessageSummary]
                if let selectedMessageID {
                    selectedMessages = [try await mailAuthority.messages.message(id: MessageID(selectedMessageID))]
                } else {
                    selectedMessages = []
                }
                let account = try await inboxProjectionRepository.account(id: mailAuthority.accountID)
                try await inboxProjectionRepository.verifyAuthority(authority)
                guard generation == metadataReadGeneration, requestGeneration == inboxRequestGeneration,
                      !Task.isCancelled, acceptsReadAuthority(authority) else { return staleDirectInboxViewModel() }
                nodeMessagesByID = Dictionary(
                    (page.messages + selectedMessages).map { ($0.id.rawValue, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                nodeSnapshotMessages = page.messages
                signposter.emitEvent("InboxProjectionReady", "rows=\(page.messages.count, privacy: .public)")
                return Self.makeNodeInboxViewModel(
                    messages: page.messages,
                    selectedMessages: selectedMessages,
                    revision: page.revision,
                    account: account,
                    hasAuthorityIdentity: mailAuthority.accountID != nil
                )
            } catch {
                return InboxViewModel.loading(requiresAccountSetup: false, setupSource: .syncNode)
                    .withMailboxLoadFailure("Mail could not be loaded from the Sync Node. Retry.")
            }
        }
        do {
            let forceReload = inboxProjectionNeedsReload
            inboxProjectionNeedsReload = false
            let page = try await inboxProjectionRepository.mailboxPage(
                limit: limit,
                query: "",
                forceReload: forceReload
            )
            let detail: ThreadDetailModel
            if let selectedMessageID {
                detail = try await inboxProjectionRepository.threadDetail(messageID: selectedMessageID)
            } else {
                detail = Self.emptyInboxThread
            }
            try await inboxProjectionRepository.verifyAuthority(page.authority)
            guard generation == metadataReadGeneration, requestGeneration == inboxRequestGeneration,
                  !Task.isCancelled, acceptsReadAuthority(page.authority) else { return staleDirectInboxViewModel() }
            if isDeviceWideDirect, let sources = page.authority.deviceDirect {
                deviceDirectReadState.record(
                    (page.rows + page.sentRows).map { (MessageID($0.id), $0.accountID) },
                    sources: sources, accounts: page.accounts
                )
            }
            signposter.emitEvent("InboxProjectionReady", "rows=\(page.rows.count, privacy: .public)")
            return Self.makeInboxViewModel(
                page: page, selectedThread: detail,
                selectedAccountID: configuration.selectedAccountID,
                waiting: page.waitingMessageIDs
            )
        } catch {
            inboxProjectionNeedsReload = true
            return InboxViewModel.loading(requiresAccountSetup: false, setupSource: .localAccount)
                .withMailboxLoadFailure("Mail could not be loaded from this device. Retry.")
        }
    }

    /// The "Waiting for Sync Node" projection: row message IDs with an
    /// `admitted` or `uncertain` Node intent in the shared store. The app
    /// only reads the service's journal; it never routes a change. A read
    /// error shows no badge (the next store signal retries).
    nonisolated static func waitingForNode(rows: [MessageRowModel], store: SQLiteMailStore) -> Set<String> {
        guard !rows.isEmpty,
              let waiting = try? store.mailIntentsWaitingForNode(messageIDs: rows.map { MessageID($0.id) })
        else { return [] }
        return Set(waiting.map(\.rawValue))
    }

    /// Folds the waiting set into the content revision, so a journal move
    /// that changes no message still refreshes the list.
    nonisolated static func waitingRevision(_ waiting: Set<String>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in waiting.sorted().joined(separator: "\u{0}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return waiting.isEmpty ? 0 : hash
    }

    nonisolated private static func makeInboxViewModel(
        page: InboxMailboxPage,
        selectedThread: ThreadDetailModel,
        selectedAccountID: AccountID?,
        waiting: Set<String> = []
    ) -> InboxViewModel {
        let account = projectedAccount(in: page.accounts, selectedAccountID: selectedAccountID)
        return InboxViewModel(
            chrome: .default,
            sidebarItems: page.sidebarItems,
            smartCards: page.smartCards,
            classicRows: waiting.isEmpty ? page.rows : page.rows.map { $0.withWaitingForNode(waiting.contains($0.id)) },
            sentRows: page.sentRows,
            selectedThread: selectedThread,
            aiIndexStatus: page.aiIndexStatus,
            requiresAccountSetup: page.accounts.isEmpty,
            accountIdentity: account.map {
                MailboxAccountIdentity(
                    displayName: $0.displayName.isEmpty ? $0.email.rawValue : $0.displayName,
                    email: $0.email.rawValue
                )
            },
            totalRowCount: page.totalRowCount,
            hasMoreRows: page.hasMoreRows,
            hasMoreSentRows: page.hasMoreSentRows,
            mailboxRevision: page.revision,
            contentRevision: page.revision &+ waitingRevision(waiting)
        )
    }

    nonisolated static func projectedAccount(
        in accounts: [Account], selectedAccountID: AccountID?
    ) -> Account? {
        guard let selectedAccountID else { return accounts.first }
        return accounts.first { $0.id == selectedAccountID }
    }

    private static func makeNodeInboxViewModel(
        messages: [MessageSummary],
        selectedMessages: [MessageSummary],
        revision: String,
        account: Account?,
        hasAuthorityIdentity: Bool
    ) -> InboxViewModel {
        let rows = MessageRowModel.threadedRows(from: messages)
        let indexStatus = AIIndexStatusModel(
            snapshot: AIIndexStatusSnapshot(
                state: .ready,
                indexedMessageCount: messages.count,
                providerID: "sync-node",
                modelID: "node-search",
                isStale: false,
                localOnly: false
            )
        )
        let threadMessages = selectedMessages.sorted {
            let lhs = $0.sentAt ?? .distantPast
            let rhs = $1.sentAt ?? .distantPast
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
        }
        let participants = Array(Set(
            threadMessages.flatMap { [$0.from.rawValue] + $0.to.map(\.rawValue) }
        )).sorted()
        let detail = ThreadDetailModel(
            subject: threadMessages.first?.subject ?? "No conversation selected",
            participants: participants,
            summaryStatus: "Not summarized",
            actionItems: [],
            availableActions: threadMessages.isEmpty ? [] : ["Reply", "Reply all", "Forward", "Archive", "Delete"],
            messages: threadMessages.map { message in
                ThreadMessageModel(
                    id: message.id.rawValue,
                    sender: message.from.rawValue,
                    senderDisplayName: message.fromDisplayName,
                    replyTo: message.replyTo?.rawValue,
                    dateLabel: MailTimestampFormatter.readerLabel(for: message.sentAt),
                    deferredBody: message.bodyHTML.map(EmailBodyInput.html) ?? .plainText(message.body),
                    fallbackText: message.body,
                    blockedRemoteImageURLs: message.bodyHTML.map(EmailBodyRenderer.remoteImageURLs(inHTML:)) ?? [],
                    translationSourceFingerprint: MailTranslationFingerprint.message(message),
                    sourceThreadID: message.threadID,
                    rfcMessageID: message.rfcMessageID,
                    inReplyTo: message.inReplyTo,
                    references: message.references,
                    attachments: message.attachments,
                    to: message.to.map(\.rawValue),
                    cc: message.cc.map(\.rawValue)
                )
            }
        )
        let sidebar = SidebarItemModel.defaultItems(
            unreadCounts: SidebarUnreadCounts(messages: messages),
            pendingApprovalCount: 0,
            aiIndexWarningCount: nil
        )
        return InboxViewModel(
            chrome: .default,
            sidebarItems: sidebar,
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: detail,
            aiIndexStatus: indexStatus,
            requiresAccountSetup: false,
            setupSource: .syncNode,
            accountIdentity: account.map {
                MailboxAccountIdentity(
                    displayName: $0.displayName.isEmpty ? $0.email.rawValue : $0.displayName,
                    email: $0.email.rawValue
                )
            },
            totalRowCount: rows.count,
            hasMoreRows: false,
            mailboxRevision: UInt64(revision) ?? 0
        )
    }

    nonisolated private static let emptyInboxThread = ThreadDetailModel(
        subject: "No conversation selected",
        participants: [],
        summaryStatus: "Not summarized",
        actionItems: [],
        availableActions: []
    )

    nonisolated private static func makeInboxSelectionViewModel(
        snapshot: InboxMailboxSnapshot,
        selectedMessageID: String?,
        selectedAccountID: AccountID?
    ) -> InboxViewModel {
        let account = projectedAccount(in: snapshot.accounts, selectedAccountID: selectedAccountID)
        let messages = snapshot.messages
        let selectedMessage = selectedMessageID.flatMap { selectedID in
            messages.first { $0.id.rawValue == selectedID }
        }
        let selectedThreadID = selectedMessage?.threadID
        let selectedThread = snapshot.threads.first { $0.id == selectedThreadID }
        let selectedThreadKey = selectedMessage.map { MessageRowModel.threadGroupingKey(for: $0) }
        let selectedThreadMessages = selectedThreadKey.flatMap {
            snapshot.messagesByThreadKey[$0]
        } ?? []
        let threadParticipants = selectedThread?.participantEmails.map(\.rawValue) ?? []
        let senderParticipants = selectedThreadMessages.map(\.from.rawValue)
        let accountParticipants = [account?.email.rawValue].compactMap { $0 }
        let selectedParticipants = Array(
            Set(threadParticipants + senderParticipants + accountParticipants)
        ).sorted()
        return InboxViewModel(
            chrome: .default,
            sidebarItems: snapshot.sidebarItems,
            smartCards: snapshot.smartCards,
            classicRows: snapshot.rows,
            sentRows: snapshot.sentRows,
            selectedThread: ThreadDetailModel(
                subject: selectedThreadMessages.first?.subject ?? selectedMessage?.subject ?? "No Thread",
                participants: selectedParticipants,
                summaryStatus: "Not summarized",
                actionItems: [],
                availableActions: selectedMessage == nil
                    ? []
                    : ["Reply", "Reply all", "Forward", "Archive", "Delete"],
                messages: selectedThreadMessages.map { message in
                    let bodyInput = message.bodyHTML.map(EmailBodyInput.html) ?? .plainText(message.body)
                    return ThreadMessageModel(
                        id: message.id.rawValue,
                        sender: message.from.rawValue,
                        senderDisplayName: message.fromDisplayName,
                        replyTo: message.replyTo?.rawValue,
                        dateLabel: MailTimestampFormatter.readerLabel(for: message.sentAt),
                        deferredBody: bodyInput,
                        fallbackText: message.body,
                        blockedRemoteImageURLs: message.bodyHTML.map(EmailBodyRenderer.remoteImageURLs(inHTML:)) ?? [],
                        translationSourceFingerprint: MailTranslationFingerprint.message(message),
                        sourceThreadID: message.threadID,
                        rfcMessageID: message.rfcMessageID,
                        inReplyTo: message.inReplyTo,
                        references: message.references,
                        attachments: message.attachments,
                        to: message.to.map(\.rawValue),
                        cc: message.cc.map(\.rawValue)
                    )
                }
            ),
            aiIndexStatus: snapshot.aiIndexStatus,
            requiresAccountSetup: snapshot.accounts.isEmpty,
            accountIdentity: account.map {
                MailboxAccountIdentity(
                    displayName: $0.displayName.isEmpty ? $0.email.rawValue : $0.displayName,
                    email: $0.email.rawValue
                )
            }
        )
    }

    func invalidateInboxSnapshot() {
        metadataReadGeneration &+= 1
        inboxRequestGeneration &+= 1
        inboxMailboxSnapshot = nil
        inboxProjectionNeedsReload = true
    }

    private func currentInboxMailboxSnapshot() -> InboxMailboxSnapshot {
        if let inboxMailboxSnapshot {
            return inboxMailboxSnapshot
        }

        let selectedAccountID = configuration.selectedAccountID
        // The device-wide runtime reads every Direct account, never a Sync Node one's rows.
        let deviceDirect = isDeviceWideDirect && !store.accounts.isEmpty
            ? DeviceMailScope.current(in: store).accountIDs : nil
        let covers: (AccountID?) -> Bool = { owner in
            guard let deviceDirect else { return selectedAccountID == nil || owner == selectedAccountID }
            return owner.map(deviceDirect.contains) ?? false
        }
        var inboxMessages = store.messages(inMailboxPath: "INBOX", accountID: selectedAccountID)
        var conversationMessages = store.messages(accountID: selectedAccountID).filter { !$0.isDeleted }
        if deviceDirect != nil {
            inboxMessages = inboxMessages.filter { covers(store.accountID(forMessageID: $0.id)) }
            conversationMessages = conversationMessages.filter { covers(store.accountID(forMessageID: $0.id)) }
        }
        let threads = store.threads.filter { covers($0.accountID) }
        let accounts = store.accounts.filter { covers($0.id) }
        let threadedRows = MessageRowModel.threadedRows(from: inboxMessages)
        let waiting = Self.waitingForNode(rows: threadedRows, store: store)
        let rows = waiting.isEmpty ? threadedRows : threadedRows.map { $0.withWaitingForNode(waiting.contains($0.id)) }
        let sentMessages = (try? store.sentMailboxListMessages(
            accountID: selectedAccountID,
            limit: inboxPageLimit,
            query: ""
        )) ?? []
        let aiIndexStatus = AIIndexStatusModel(
            snapshot: AIIndexStatusSnapshot(
                state: .ready,
                indexedMessageCount: conversationMessages.count,
                providerID: "local-search",
                modelID: "built-in-local-embeddings",
                isStale: false,
                localOnly: true
            )
        )
        let snapshot = InboxMailboxSnapshot(
            messages: conversationMessages,
            messagesByThreadKey: Dictionary(grouping: conversationMessages) {
                MessageRowModel.threadGroupingKey(for: $0)
            }.mapValues { messages in
                messages.sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
            },
            threads: threads,
            accounts: accounts,
            rows: rows,
            sentRows: sentMessages.map(MessageRowModel.init(message:)),
            smartCards: SmartInboxCardModel.cards(from: rows),
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: SidebarUnreadCounts(messages: inboxMessages),
                pendingApprovalCount: runtimeDependencies != nil && selectedAccountID == nil && deviceDirect == nil ? 0 :
                    ((try? store.approvalQueueRequests.filter { request in
                        guard request.status == .pending else { return false }
                        let draft = try store.draft(id: request.draftID)
                        return covers(draft.accountID)
                    }.count) ?? 0),
                aiIndexWarningCount: aiIndexStatus.needsAttention ? 1 : nil
            ),
            aiIndexStatus: aiIndexStatus
        )
        inboxMailboxSnapshot = snapshot
        return snapshot
    }

    public func makeAccountSetupViewModel(
        onCompletedAdd: @escaping @MainActor @Sendable (AccountID) -> Void = { _ in }
    ) -> AccountSetupViewModel {
        let scopesDirectSettings = runtimeDependencies != nil || configuration.selectedAccountID != nil
        let selectedSettingsAccountID = configuration.selectedAccountID
        // The device-wide runtime's settings cover every Direct account on the device.
        let deviceWide = isDeviceWideDirect
        let requireSettingsAccount: @Sendable (AccountID) throws -> Void = { [store] accountID in
            guard scopesDirectSettings else { return }
            guard deviceWide || accountID == selectedSettingsAccountID else {
                throw PlainpostError.permissionDenied("The account does not match the selected Direct account.")
            }
            if deviceWide {
                try DeviceMailScope.requireCurrentOwner(accountID, expected: nil, in: store)
            } else {
                try store.requireDirectMailSource(accountID: accountID)
            }
        }
        let scopedAccounts: @Sendable () -> [Account] = { [store] in
            if deviceWide {
                let direct = DeviceMailScope.current(in: store).accountIDs
                return store.accounts.filter { direct.contains($0.id) }
            }
            return store.accounts.filter { !scopesDirectSettings || $0.id == selectedSettingsAccountID }
        }
        let accounts = scopedAccounts()
        let existingAccount = configuration.selectedAccountID.flatMap { selected in
            accounts.first { $0.id == selected }
        } ?? (runtimeDependencies == nil ? accounts.first : nil)
        let syncPreferences = existingAccount.flatMap {
            try? store.syncPreferences(accountID: $0.id)
        }
        let mailboxPreferences =
            existingAccount.flatMap { try? store.mailboxSyncPreferences(accountID: $0.id) } ?? []
        let mailboxStatuses =
            existingAccount.flatMap { try? store.mailboxSyncStatuses(accountID: $0.id) } ?? []
        let mailboxPaths =
            existingAccount.map { account in (try? store.mailboxPaths(accountID: account.id)) ?? []
            } ?? ["INBOX"]
        let setup: any AccountSetupHandling
        let credentialSaver: @Sendable (AccountID, String, String) async throws -> Void
        var googleSignIn: PlainpostGoogleSignIn?
        if mailAuthority != nil {
            // A Node-backed runtime is already account/session-authorized.
            // Do not construct the legacy IMAP/SMTP setup adapter or expose a
            // credential-saving path merely because its SQLite projection is
            // empty. Provider onboarding belongs to Node settings.
            setup = NodeAccountSetupUnavailable()
            credentialSaver = { _, _, _ in
                throw PlainpostError.permissionDenied("Node-backed mail does not accept local provider credentials.")
            }
        } else if let runtimeDependencies {
            let setupSyncer = IOSAccountSetupInboxSyncer(
                store: store,
                runtimeDependencies: runtimeDependencies,
                selectedSyncer: inboxSyncer
            )
            let directSetup = runtimeDependencies.makeAccountSetupHandler(
                store: store, inboxSyncOrchestrator: setupSyncer)
            setup = scopesDirectSettings
                ? SelectedDirectAccountSetupHandler(
                    base: directSetup, store: store, requireSelectedAccount: requireSettingsAccount
                )
                : directSetup
            credentialSaver = { accountID, imapPassword, smtpPassword in
                try requireSettingsAccount(accountID)
                try await runtimeDependencies.saveAccountCredentials(
                    accountID: accountID, imapPassword: imapPassword, smtpPassword: smtpPassword)
            }
        } else {
            googleSignIn = PlainpostGoogleSignIn.production()
            setup = PlainpostServiceAccountSetupAdapter(
                serviceClient: serviceClient, googleOAuthTokens: googleSignIn?.tokens)
            credentialSaver = plainpostServiceAccountCredentialSaver(
                serviceClient: serviceClient)
        }
        let accountDeleter: @Sendable (AccountID) async throws -> Void
        if let runtimeDependencies {
            accountDeleter = { [store] accountID in
                try requireSettingsAccount(accountID)
                try await runtimeDependencies.deleteLocalAccount(accountID: accountID, store: store)
            }
        } else {
            accountDeleter = plainpostServiceAccountDeleter(serviceClient: serviceClient)
        }
        // The device-wide runtime's Sync Node accounts: whether the phone can keep each one
        // syncing while its Node is away.
        var syncNodeSignInProvider: (@Sendable (AccountID) async -> SyncNodeSignIn?)?
        if deviceWide, let runtimeDependencies {
            syncNodeSignInProvider = { [store] accountID in
                guard (try? requireSettingsAccount(accountID)) != nil,
                      let source = try? store.mailSource(accountID: accountID), source.kind == .nodeBacked,
                      let account = store.accounts.first(where: { $0.id == accountID }) else { return nil }
                if await runtimeDependencies.hasProviderSignIn(accountID: accountID, store: store) {
                    return SyncNodeSignIn.signedIn
                }
                return MailProviderProfile.gmail.matches(account) ? SyncNodeSignIn.googleAvailable : SyncNodeSignIn.unavailable
            }
        }
        return AccountSetupViewModel(
            setup: setup, displayName: existingAccount?.displayName ?? "",
            email: existingAccount?.email.rawValue ?? "", imapHost: existingAccount?.imapHost ?? "",
            imapPort: existingAccount.map { "\($0.imapPort)" } ?? "993",
            smtpHost: existingAccount?.smtpHost ?? "",
            smtpPort: existingAccount.map { "\($0.smtpPort)" } ?? "587",
            username: existingAccount?.username ?? existingAccount?.email.rawValue ?? "",
            status: existingAccount.map { .connected(accountID: $0.id.rawValue) } ?? .idle,
            lastConnectedEmail: existingAccount?.email.rawValue, account: existingAccount,
            accounts: accounts, accountsProvider: scopedAccounts,
            accountSaver: { [store] account in
                try requireSettingsAccount(account.id)
                try store.cacheAccounts([account])
            },
            accountCredentialSaver: credentialSaver,
            accountDeleter: accountDeleter,
            syncPreferences: syncPreferences,
            syncPreferencesProvider: { [store] accountID in
                try requireSettingsAccount(accountID)
                return try store.syncPreferences(accountID: accountID)
            },
            syncPreferencesSaver: { [store] preferences in
                try requireSettingsAccount(preferences.accountID)
                try store.saveSyncPreferences(preferences)
            },
            mailboxPreferences: mailboxPreferences,
            availableMailboxPaths: mailboxPaths,
            mailboxPreferencesProvider: { [store] accountID in
                try requireSettingsAccount(accountID)
                return try store.mailboxSyncPreferences(accountID: accountID)
            },
            mailboxPathsProvider: { [store] accountID in
                try requireSettingsAccount(accountID)
                return try store.mailboxPaths(accountID: accountID)
            },
            mailboxPreferenceSaver: { [store] preference in
                try requireSettingsAccount(preference.accountID)
                try store.saveMailboxSyncPreference(preference)
            },
            mailboxSyncStatuses: mailboxStatuses,
            mailboxStatusProvider: { [store, existingAccount] in
                guard let account = existingAccount else { return [] }
                return try store.mailboxSyncStatuses(accountID: account.id)
            },
            accountMailboxStatusProvider: { [store] accountID in
                try requireSettingsAccount(accountID)
                return try store.mailboxSyncStatuses(accountID: accountID)
            },
            googleAuthorization: googleSignIn?.authorize ?? runtimeDependencies?.makeGoogleAuthorization(),
            microsoftAuthorization: runtimeDependencies?.makeMicrosoftAuthorization(),
            accountAuthenticationProvider: { [store] accountID in
                try requireSettingsAccount(accountID)
                let authentication = try store.accountAuthentication(accountID: accountID)
                return AccountAuthenticationSummary(method: authentication.method, state: authentication.state)
            },
            syncNodeSignInProvider: syncNodeSignInProvider,
            onCompletedAdd: onCompletedAdd
        )
    }

    public func makeApprovalQueueViewModel() -> ApprovalQueueViewModel {
        ApprovalQueueViewModel(
            queue: RuntimeApprovalQueueService(
                store: store,
                operationClient: mailOperationClient,
                selectedAccountID: configuration.selectedAccountID,
                requiresAccountScope: runtimeDependencies != nil || configuration.selectedAccountID != nil,
                isDeviceWideDirect: isDeviceWideDirect
            )
        )
    }

    public static let mailMonitorFallbackInterval: Duration = .seconds(5 * 60)

    /// The reader can retain a message identifier across account and source
    /// changes. Check ownership at the action boundary before flagging mail.
    /// Opens a message in the device-wide runtime: marks it read through its own account,
    /// while that account is still Direct at the generation the list was read with.
    /// Starts sending queued read-state and archive changes now, rather than after the
    /// next sync or message open. iOS calls it whenever the app becomes active.
    public func resumeQueuedMailboxWriteBack() async {
        guard accountAccess == .readWrite else { return }
        try? await mailboxFlagScheduler.signalWork()
    }

    /// Marks the opened message read, then the rest of its conversation: its list row stays
    /// unread while any message in it is. True when that changed any read state. Only the
    /// opened message's refusal fails the open.
    func openConversation(
        _ messageID: MessageID,
        opening open: (MessageID) async throws -> Bool
    ) async throws -> Bool {
        var changed = try await open(messageID)
        let unread = (try? await inboxProjectionRepository.unreadConversationMessageIDs(containing: messageID)) ?? []
        for id in unread where id != messageID {
            if (try? await open(id)) == true { changed = true }
        }
        return changed
    }

    /// Marks the opened message read; true when that changed its read state.
    @discardableResult
    func openOwnedDirectMessage(_ messageID: MessageID) async throws -> Bool {
        guard accountAccess == .readWrite, isDeviceWideDirect,
              let owner = store.accountID(forMessageID: messageID),
              let expected = deviceDirectReadState.generation(for: messageID, owner: owner) else {
            throw PlainpostError.permissionDenied("The message's account is not a Direct account on this device.")
        }
        let generation = try DeviceMailScope.requireCurrentOwner(owner, expected: expected, in: store)
        if DeviceMailScope.isNodeOwner(owner, in: store) {
            // Already read, as the mirror last saw it: nothing to send.
            guard try store.messageSummary(id: messageID)?.isSeen != true else { return false }
            _ = try await DeviceNodeInboxMailActionHandler(bridge: runtimeDependencies?.deviceNodeMail)
                .perform(.markRead, messageID: messageID)
            return true
        }
        let actor = Actor(
            id: "local-user", kind: .user, displayName: "Local User",
            permissions: .guiUser
        )
        let result = try store.openSelectedDirectMessageForHumanResult(
            messageID, actor: actor, accountID: owner,
            expectedSourceGeneration: generation
        )
        if result.scheduledRemoteFlag {
            try? await mailboxFlagScheduler.signalWork()
        }
        return result.scheduledRemoteFlag
    }

    /// Marks the opened message read; true when that changed its read state.
    @discardableResult
    func openSelectedMessage(_ messageID: MessageID) async throws -> Bool {
        guard accountAccess == .readWrite,
              runtimeDependencies != nil,
              let accountID = configuration.selectedAccountID,
              let generation = selectedDirectSourceGeneration,
              store.accountID(forMessageID: messageID) == accountID else {
            throw PlainpostError.permissionDenied("The message does not belong to the selected Direct account.")
        }
        try store.requireDirectMailSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
        let actor = Actor(
            id: "local-user", kind: .user, displayName: "Local User",
            permissions: .guiUser
        )
        let result = try store.openSelectedDirectMessageForHumanResult(
            messageID, actor: actor, accountID: accountID,
            expectedSourceGeneration: generation
        )
        if result.scheduledRemoteFlag {
            try? await mailboxFlagScheduler.signalWork()
        }
        return result.scheduledRemoteFlag
    }

    /// One bounded foreground pass for the selected device-local account.
    /// The operation runtime rechecks the persisted Direct generation after
    /// credential resolution and before provider I/O.
    public func syncDirectMailNow() async throws -> IMAPSyncResult {
        guard runtimeDependencies != nil, mailAuthority == nil,
              let accountID = configuration.selectedAccountID,
              let generation = selectedDirectSourceGeneration,
              let account = store.accounts.first(where: { $0.id == accountID }) else {
            throw PlainpostError.permissionDenied("A Direct mail account must be selected.")
        }
        return try await syncDirectMail(account: account, generation: generation)
    }

    /// Starts the device's Sync Node mail (mirror and pending changes) while the app is in
    /// the foreground. Without a Sync Node it does nothing.
    public func startDeviceNodeMail() async {
        guard isDeviceWideDirect, accountAccess == .readWrite else { return }
        await runtimeDependencies?.deviceNodeMail?.start()
    }

    /// Stops the device's Sync Node mail when the app leaves the foreground.
    public func stopDeviceNodeMail() async {
        await runtimeDependencies?.deviceNodeMail?.stop()
    }

    /// One foreground pass for every Direct account on the device, side by side: one
    /// account's failure, or its retries, never holds up the others.
    public func syncAllDirectMailNow() async -> [AccountID: Result<IMAPSyncResult, Error>] {
        guard isDeviceWideDirect else { return [:] }
        // Sync Node accounts catch up through the Node, alongside.
        let nodeMail = runtimeDependencies?.deviceNodeMail
        let nodeWake = Task { await nodeMail?.wake() }
        let scope = DeviceMailScope.current(in: store)
        let targets = scope.generations.filter { scope.directSyncAccountIDs.contains($0.key) }.compactMap { accountID, generation in
            store.accounts.first(where: { $0.id == accountID }).map { ($0, generation) }
        }
        let passes = targets.map { account, generation in
            (account.id, Task { @MainActor () -> Result<IMAPSyncResult, Error> in
                do { return .success(try await self.syncDirectMail(account: account, generation: generation)) }
                catch { return .failure(error) }
            })
        }
        let results = await withTaskCancellationHandler {
            var results: [AccountID: Result<IMAPSyncResult, Error>] = [:]
            for (accountID, pass) in passes { results[accountID] = await pass.value }
            return results
        } onCancel: {
            for (_, pass) in passes { pass.cancel() }
            nodeWake.cancel()
        }
        await nodeWake.value
        var failed: Set<AccountID> = []
        var synced: Set<AccountID> = []
        for (accountID, result) in results {
            switch result {
            case .success: synced.insert(accountID)
            case let .failure(error) where !(error is CancellationError): failed.insert(accountID)
            case .failure: break
            }
        }
        recordDirectSync(failed: failed, synced: synced)
        return results
    }

    private func syncDirectMail(account: Account, generation: Int64) async throws -> IMAPSyncResult {
        let accountID = account.id
        try store.requireDirectSyncSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
        guard let foregroundInboxRefresh else {
            throw PlainpostError.validationFailed("Foreground inbox refresh is unavailable in this runtime.")
        }
        let result = try await foregroundInboxRefresh.refresh(account: account, sourceGeneration: generation)
        try store.requireDirectSyncSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
        return result
    }

    /// Enables a persistent backfill for the selected device-local account.
    /// Its next manual sync includes every UID in each enabled mailbox; later
    /// foreground syncs resume any unfinished import from the local cache.
    public func enableCompleteHistoryForSelectedDirectAccount() throws {
        guard runtimeDependencies != nil, mailAuthority == nil,
              let accountID = configuration.selectedAccountID,
              let generation = selectedDirectSourceGeneration else {
            throw PlainpostError.permissionDenied("A Direct mail account must be selected.")
        }
        try enableCompleteHistory(for: accountID, generation: generation)
    }

    /// Enables a persistent backfill for one of the device-wide runtime's accounts. A Sync
    /// Node account's mirror then keeps its whole history too.
    public func enableCompleteHistory(for accountID: AccountID) throws {
        guard isDeviceWideDirect else {
            throw PlainpostError.permissionDenied("A Direct mail account must be selected.")
        }
        if DeviceMailScope.isNodeOwner(accountID, in: store) {
            // The mirror, and a fallback's own sync, both follow the preference.
            var preferences = try store.syncPreferences(accountID: accountID)
            preferences.downloadCompleteHistory = true
            try store.saveSyncPreferences(preferences)
            return
        }
        try enableCompleteHistory(
            for: accountID, generation: DeviceMailScope.requireCurrentOwner(accountID, expected: nil, in: store)
        )
    }

    private func enableCompleteHistory(for accountID: AccountID, generation: Int64) throws {
        try store.requireDirectMailSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
        var preferences = try store.syncPreferences(accountID: accountID)
        preferences.downloadCompleteHistory = true
        try store.saveSyncPreferences(preferences)
    }

    /// Starts a distinct durable historical pass, so a running recent-mail
    /// sync cannot swallow the user's request or delay its enqueueing.
    public func syncSelectedDirectMailHistoryNow() async throws {
        guard runtimeDependencies != nil, mailAuthority == nil,
              let accountID = configuration.selectedAccountID,
              let generation = selectedDirectSourceGeneration else {
            throw PlainpostError.permissionDenied("A Direct mail account must be selected.")
        }
        try await syncDirectMailHistory(accountID: accountID, generation: generation)
    }

    /// A durable historical pass for one of the device-wide runtime's Direct accounts.
    public func syncDirectMailHistoryNow(for accountID: AccountID) async throws {
        guard isDeviceWideDirect else {
            throw PlainpostError.permissionDenied("A Direct mail account must be selected.")
        }
        let scope = DeviceMailScope.current(in: store)
        if scope.nodeAccountIDs.subtracting(scope.fallbackAccountIDs).contains(accountID) {
            guard let nodeMail = runtimeDependencies?.deviceNodeMail else {
                throw PlainpostError.validationFailed(DeviceNodeInboxMailActionHandler.unavailableMessage)
            }
            try await nodeMail.downloadCompleteHistory(for: accountID)
            return
        }
        try await syncDirectMailHistory(
            accountID: accountID,
            generation: DeviceMailScope.requireCurrentOwner(accountID, expected: nil, in: store)
        )
    }

    private func syncDirectMailHistory(accountID: AccountID, generation: Int64) async throws {
        try store.requireDirectSyncSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
        let input = PlainpostInboxSyncInput(
            accountID: accountID, trigger: .manual, scope: .completeHistory,
            expectedDirectSourceGeneration: generation
        )
        if let local = mailOperationClient as? LocalOperationClient {
            let outcome = await local.executeInboxSyncWithTerminalOwnership(input)
            _ = try outcome.result.get()
            if outcome.ownsTerminalEffects { await syncCompletionHandler() }
        } else {
            _ = try await mailOperationClient.executeInboxSync(input)
            await syncCompletionHandler()
        }
    }

    public func monitorMail(
        interval: Duration = PlainpostAppRuntime.mailMonitorFallbackInterval
    ) async throws {
        guard let serviceFailureMonitor else {
            try await runMailMonitor(interval: interval)
            return
        }
        if let error = await serviceFailureMonitor.nextFailure() {
            throw error
        }
    }

    /// The iPhone's background refresh: one incremental Inbox pass for every Direct account,
    /// then the new-mail alerts it found. True when every account synced. Cancelling it
    /// (the system's expiration) stops both; a pass already queued resumes next time.
    public func refreshDirectMailInBackground(
        alertWait: Duration = .seconds(5)
    ) async -> Bool {
        guard isDeviceWideDirect, accountAccess == .readWrite else { return false }
        guard let failures = await runDeviceWideDirectBackgroundPass() else { return false }
        await macNewMailDelivery?.deliverPending(maxWait: alertWait)
        return failures.isEmpty && !Task.isCancelled
    }

    /// The Direct accounts this device syncs with their providers itself.
    public var deviceDirectAccounts: [Account] {
        guard isDeviceWideDirect else { return [] }
        let scope = DeviceMailScope.current(in: store)
        return store.accounts.filter { scope.directSyncAccountIDs.contains($0.id) }
    }

    /// Starts new-mail alerts while the app is in the foreground; the iPhone stops them
    /// when it leaves.
    public func startNewMailAlerts() async {
        await macNewMailDelivery?.start()
    }

    public func stopNewMailAlerts() async {
        await macNewMailDelivery?.stop()
    }

    /// Every Direct account side by side, as a real-time pass: one account's failure or
    /// retries never hold up the others; the pass reports it by account and goes on.
    /// Nil when cancelled.
    private func runDeviceWideDirectBackgroundPass() async -> [DirectSyncFailure]? {
        let accounts = DeviceMailScope.current(in: store).directSyncAccountIDs.compactMap { accountID in
            store.accounts.first(where: { $0.id == accountID })
        }
        let passes = accounts.map { account in
            Task { @MainActor () -> DirectSyncFailure? in
                do {
                    try self.store.requireDirectSyncSource(accountID: account.id)
                    _ = try await self.inboxSyncer.syncInbox(for: account, reason: .background)
                    return nil
                } catch {
                    return error is CancellationError
                        ? nil : DirectSyncFailure(accountID: account.id, underlying: error)
                }
            }
        }
        let failures = await withTaskCancellationHandler {
            var failures: [DirectSyncFailure] = []
            for pass in passes { if let failure = await pass.value { failures.append(failure) } }
            return failures
        } onCancel: {
            for pass in passes { pass.cancel() }
        }
        guard !Task.isCancelled else { return nil }
        let failed = Set(failures.map(\.accountID))
        recordDirectSync(failed: failed, synced: Set(accounts.map(\.id)).subtracting(failed))
        return failures
    }

    private func runMailMonitor(interval: Duration) async throws {
        if runtimeDependencies != nil {
            // Foreground entry requests one explicit pass. The periodic
            // monitor begins after that pass so it does not duplicate it.
            do { try await Task.sleep(for: interval) } catch { return }
        }
        while !Task.isCancelled {
            if isDeviceWideDirect {
                // This periodic pass is each Direct account's fallback sync, Instant
                // updates on or off.
                guard let failures = await runDeviceWideDirectBackgroundPass() else { return }
                directSyncFailureHandler?(failures.min(by: { $0.accountID.rawValue < $1.accountID.rawValue }))
                do { try await Task.sleep(for: interval) } catch { return }
                continue
            }
            if runtimeDependencies != nil {
                guard mailAuthority == nil,
                      let accountID = configuration.selectedAccountID,
                      let account = store.accounts.first(where: { $0.id == accountID }) else {
                    throw PlainpostError.permissionDenied(
                        "A Direct mail account must be selected for background sync."
                    )
                }
                try store.requireDirectMailSource(accountID: accountID)
                _ = try await inboxSyncer.syncInbox(for: account, reason: .background)
                do { try await Task.sleep(for: interval) } catch { return }
                continue
            }
            for account in store.directSyncAccounts {
                guard !Task.isCancelled else { return }
                let preferences = try? store.syncPreferences(accountID: account.id)
                guard preferences?.realTimeMonitoringEnabled == true else { continue }
                _ = try? await inboxSyncer.syncInbox(for: account, reason: .background)
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    public func makeComposerViewModel(sourceMessageID: String? = nil) -> ComposerViewModel {
        if isDeviceWideDirect { return makeDeviceWideComposerViewModel(sourceMessageID: sourceMessageID) }
        if runtimeDependencies == nil, mailAuthority == nil, configuration.selectedAccountID == nil {
            return makeMacComposerViewModel(sourceMessageID: sourceMessageID)
        }
        let sourceAccountID = sourceMessageID.flatMap { store.accountID(forMessageID: MessageID($0)) }
        let account: Account?
        if runtimeDependencies != nil {
            account = configuration.selectedAccountID.flatMap { selected in
                store.accounts.first { $0.id == selected }
            }
        } else {
            account = sourceAccountID.flatMap { accountID in
                store.accounts.first { $0.id == accountID }
            } ?? store.accounts.first
        }
        let authorityAccount = mailAuthority?.accountID.flatMap { accountID in
            store.accounts.first { $0.id == accountID }
        }
        let composerAccount = authorityAccount ?? account
        let authoritySender = mailAuthority?.senderAddress
        let localComposer: any ComposerHandling
        if mailAuthority != nil {
            // Node accounts never fall back to the local/provider composer.
            // The Node handler below resolves the current sender at submit
            // time, after a retained authority may have refreshed its status.
            localComposer = UnavailableComposerDraftHandler()
        } else if let from = composerAccount?.email ?? authoritySender {
            let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
            if runtimeDependencies != nil,
               let accountID = configuration.selectedAccountID,
               let generation = selectedDirectSourceGeneration {
                localComposer = SelectedDirectComposerDraftHandler(
                    store: store, accountID: accountID, generation: generation,
                    from: from, actor: actor
                )
            } else {
                localComposer = ComposerDraftService(
                    store: store,
                    accountID: composerAccount?.id ?? AccountID("acc_local"),
                    from: from, actor: actor
                )
            }
        } else {
            localComposer = UnavailableComposerDraftHandler()
        }
        let nodeComposer = mailAuthority.map { authority in
            NodeAuthorityComposerDraftHandler(
                accountID: composerAccount?.id ?? authority.accountID ?? AccountID("acc_local"),
                actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser),
                mutations: authority.mutations,
                senderProvider: { authority.senderAddress }
            )
        }
        return ComposerViewModel(
            composer: localComposer,
            asyncComposer: nodeComposer,
            sendScheduler: undoSendCoordinator
        )
    }

    /// The device-wide runtime's composer: it sends through one Direct account at a time,
    /// chosen per draft. A new message defaults to the last account sent from; a reply or
    /// forward to the account its original was sent to.
    private func makeDeviceWideComposerViewModel(sourceMessageID: String?) -> ComposerViewModel {
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        let accounts: () -> [Account] = { [store] in
            let direct = DeviceMailScope.current(in: store).accountIDs
            return store.accounts.filter { direct.contains($0.id) }
        }
        let fromAccounts = ComposerFromAccounts(
            accounts: accounts,
            defaultAccountID: { ComposerFromAccountPreference().defaultAccount(among: accounts())?.id },
            owner: { [store] in store.accountID(forMessageID: $0) },
            makeComposer: { [store] account -> any ComposerDraftSessionHandling in
                // Each save checks the account's current source; one that's gone or has moved
                // between Direct and Sync Node refuses the save instead of misfiling it.
                if DeviceMailScope.isNodeOwner(account.id, in: store) {
                    // A Sync Node account's draft stays on the device until it is sent; the
                    // send carries it to the Node.
                    return AccountComposerDraftHandler(
                        store: store, accountID: account.id, from: account.email, actor: actor,
                        requireCurrentSource: {
                            guard DeviceMailScope.isNodeOwner(account.id, in: store) else {
                                throw NodeMailModeStoreError.generationConflict
                            }
                        }
                    )
                }
                return SelectedDirectComposerDraftHandler(
                    store: store, accountID: account.id,
                    currentGeneration: { try DeviceMailScope.requireCurrentDirectOwner(account.id, expected: nil, in: store) },
                    from: account.email, actor: actor
                )
            }
        )
        let composer = ComposerViewModel(
            composer: UnavailableComposerDraftHandler(),
            sendScheduler: undoSendCoordinator,
            fromAccounts: fromAccounts
        )
        if let sourceMessageID, let context = makeComposerReplyContext(sourceMessageID: sourceMessageID) {
            composer.prepareReply(context: context)
        }
        return composer
    }

    /// The Mac composer: every account can send (the service delivers each draft through its
    /// own account, Direct or Sync Node). A new message defaults to the last account sent from;
    /// a reply or forward to the account its original was sent to.
    private func makeMacComposerViewModel(sourceMessageID: String?) -> ComposerViewModel {
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        let accounts: () -> [Account] = { [store] in store.accounts }
        let composer = ComposerViewModel(
            composer: UnavailableComposerDraftHandler(),
            sendScheduler: undoSendCoordinator,
            fromAccounts: ComposerFromAccounts(
                accounts: accounts,
                defaultAccountID: { ComposerFromAccountPreference().defaultAccount(among: accounts())?.id },
                owner: { [store] in store.accountID(forMessageID: $0) },
                makeComposer: { [store] account in
                    AccountComposerDraftHandler(store: store, accountID: account.id, from: account.email, actor: actor)
                }
            )
        )
        if let sourceMessageID, let context = makeComposerReplyContext(sourceMessageID: sourceMessageID) {
            composer.prepareReply(context: context)
        }
        return composer
    }

    /// The message a reply/reply-all window request answers, subject to the same
    /// Node-authority and stale-generation guards as every other selected-message read.
    private func resolveReplySourceMessage(sourceMessageID: String) -> MessageSummary? {
        if mailAuthority != nil {
            return nodeMessagesByID[sourceMessageID]
        }
        if isDeviceWideDirect {
            guard let owner = store.accountID(forMessageID: MessageID(sourceMessageID)),
                  (try? DeviceMailScope.requireCurrentOwner(owner, expected: nil, in: store)) != nil
            else { return nil }
        } else if runtimeDependencies != nil {
            guard let selectedAccountID = configuration.selectedAccountID,
                  let generation = selectedDirectSourceGeneration,
                  store.accountID(forMessageID: MessageID(sourceMessageID)) == selectedAccountID,
                  (try? store.requireDirectMailSource(accountID: selectedAccountID)) != nil,
                  (try? store.mailSource(accountID: selectedAccountID).generation) == generation
            else { return nil }
        }
        return try? store.messageSummary(id: MessageID(sourceMessageID))
    }

    public func makeComposerReplyContext(sourceMessageID: String, recipient: String? = nil) -> ComposerReplyContext? {
        guard let message = resolveReplySourceMessage(sourceMessageID: sourceMessageID) else { return nil }
        let resolvedRecipient = recipient ?? ReplyAddressPolicy.recipient(
            replyTo: message.replyTo,
            from: message.from
        )?.rawValue
        guard let resolvedRecipient else { return nil }
        return ComposerReplyContext(
            sourceThreadID: message.threadID,
            sourceMessageID: message.id,
            rfcMessageID: message.rfcMessageID,
            sourceInReplyTo: message.inReplyTo,
            references: message.references,
            recipient: resolvedRecipient,
            subject: message.subject,
            senderName: message.fromDisplayName ?? message.from.rawValue,
            dateLabel: MailTimestampFormatter.readerLabel(for: message.sentAt),
            quotedBody: message.body
        )
    }

    /// Reply-all's composer context for the macOS runtime window path: the same fields as
    /// `makeComposerReplyContext`, but with `to`/`cc` (minus the sender, the primary recipient,
    /// and every configured account's address) reduced through `ComposeCoordinator`'s shared
    /// reply-all address algorithm so the two presentation paths never disagree on Cc.
    public func makeComposerReplyAllContext(sourceMessageID: String) -> ComposerReplyContext? {
        guard let message = resolveReplySourceMessage(sourceMessageID: sourceMessageID) else { return nil }
        let ownAddresses = Set(store.accounts.map { $0.email.rawValue.lowercased() })
        let recipients = ComposeCoordinator.replyAllRecipients(
            sender: message.from.rawValue,
            replyTo: message.replyTo?.rawValue,
            to: message.to.map(\.rawValue),
            cc: message.cc.map(\.rawValue),
            ownAddresses: ownAddresses
        )
        return ComposerReplyContext(
            sourceThreadID: message.threadID,
            sourceMessageID: message.id,
            rfcMessageID: message.rfcMessageID,
            sourceInReplyTo: message.inReplyTo,
            references: message.references,
            recipient: recipients.to,
            subject: message.subject,
            senderName: message.fromDisplayName ?? message.from.rawValue,
            dateLabel: MailTimestampFormatter.readerLabel(for: message.sentAt),
            quotedBody: message.body,
            cc: recipients.cc
        )
    }

    /// Forward's composer context for the macOS runtime window path, built through
    /// `ComposeCoordinator`'s shared forward context so both presentation paths quote alike.
    public func makeComposerForwardContext(sourceMessageID: String) -> ComposerForwardContext? {
        guard let message = resolveReplySourceMessage(sourceMessageID: sourceMessageID) else { return nil }
        return ComposeCoordinator.forwardContext(
            sourceMessageID: message.id.rawValue,
            subject: message.subject,
            senderDisplayName: message.fromDisplayName,
            sender: message.from.rawValue,
            dateLabel: MailTimestampFormatter.readerLabel(for: message.sentAt),
            quotedBody: message.body
        )
    }

    /// The source message's files, from the Sync Node or from the selected Direct account's
    /// stored copy, subject to the same guards as every other selected-message read.
    public func forwardAttachmentSources(for messageID: String) -> [MailAttachment] {
        guard let message = resolveReplySourceMessage(sourceMessageID: messageID) else { return [] }
        if mailAuthority != nil {
            return message.attachments
        }
        let source = SQLiteInboxProjectionSource(store: store, accountID: configuration.selectedAccountID)
        return (try? source.attachments(for: message)) ?? []
    }

    /// The source message's files as draft attachments. Files that can't be read, or that a
    /// draft can't carry, are named in `unavailable`.
    public func forwardAttachments(for messageID: String) async -> (attachments: [DraftAttachment], unavailable: [String]) {
        await forwardAttachments(from: forwardAttachmentSources(for: messageID))
    }

    /// Reads `sources` (from `forwardAttachmentSources`) into draft attachments. Every source
    /// ends up in exactly one of `attachments` or `unavailable`.
    public func forwardAttachments(from sources: [MailAttachment]) async -> (attachments: [DraftAttachment], unavailable: [String]) {
        if mailAuthority != nil {
            return await Self.forwardDraftAttachments(from: sources) { [weak self] attachment in
                guard let self else { throw PlainpostError.notFound("Attachment service is unavailable.") }
                return try await self.readNodeAttachment(attachment)
            }
        }
        return await Self.forwardDraftAttachments(from: sources) { [weak self] attachment in
            guard let self else { throw PlainpostError.notFound("Attachment is unavailable.") }
            let artifact = try self.saveDirectAttachmentArtifact(attachment)
            defer { try? artifact.cleanup() }
            return try Data(contentsOf: artifact.url)
        }
    }

    /// Reads `sources` into draft attachments that together satisfy `DraftAttachmentContract`.
    /// A file that is too large, one past the count or size limit, or one whose read throws
    /// is named in `unavailable`; oversized files are never read.
    static func forwardDraftAttachments(
        from sources: [MailAttachment],
        read: (MailAttachment) async throws -> Data
    ) async -> (attachments: [DraftAttachment], unavailable: [String]) {
        var attachments: [DraftAttachment] = []
        var unavailable: [String] = []
        var aggregateBytes = 0
        for source in sources {
            guard attachments.count < DraftAttachmentContract.maximumCount,
                  source.byteCount <= DraftAttachmentContract.maximumBytesPerAttachment,
                  aggregateBytes + source.byteCount <= DraftAttachmentContract.maximumAggregateBytes,
                  let data = try? await read(source)
            else {
                unavailable.append(source.filename)
                continue
            }
            let candidate = DraftAttachment(
                id: "fwd_\(UUID().uuidString.lowercased())",
                filename: source.filename,
                mimeType: source.mimeType,
                data: data
            )
            guard (try? DraftAttachmentContract.validate(attachments + [candidate])) != nil else {
                unavailable.append(source.filename)
                continue
            }
            attachments.append(candidate)
            aggregateBytes += data.count
        }
        return (attachments, unavailable)
    }

    public func makeAuditLogViewModel() -> AuditLogViewModel {
        let selectedAccountID = runtimeDependencies == nil ? nil : configuration.selectedAccountID
        let selectedGeneration = runtimeDependencies == nil ? nil : selectedDirectSourceGeneration
        let selectedNodeAccountID = runtimeDependencies == nil && mailAuthority != nil
            ? configuration.selectedAccountID : nil
        let selectedEntries: (@Sendable (Int) throws -> [AuditEntry])?
        let selectedOperations: OperationDiagnosticsSource?
        let exportAuditLog: (() throws -> URL)?
        if isDeviceWideDirect {
            // Every Direct account's own entries, merged newest first. A Sync Node account's
            // history is the Node's, so the raw combined file stays hidden here too.
            let entries: @Sendable (Int) throws -> [TimestampedAuditEntry] = { [store] limit in
                let sources = DeviceMailScope.current(in: store)
                return try sources.generations.filter { sources.directAccountIDs.contains($0.key) }.flatMap { accountID, generation in
                    try store.recentTimestampedAuditEntries(
                        limit: limit, accountID: accountID, sourceGeneration: generation
                    )
                }
                .sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
                .prefix(limit).map { $0 }
            }
            selectedEntries = { limit in try entries(limit).map(\.entry) }
            exportAuditLog = { try AuditLogExport.write(entries(1_000)) }
            selectedOperations = nil
        } else if selectedNodeAccountID != nil {
            // Node-owned audit and diagnostics need a Node source-aware DB
            // query before this combined local log can safely be displayed.
            selectedEntries = { _ in [] }
            selectedOperations = nil
            exportAuditLog = nil
        } else if runtimeDependencies == nil {
            selectedEntries = nil
            selectedOperations = nil
            exportAuditLog = nil
        } else {
            selectedEntries = { [store] limit in
                guard let selectedAccountID, let selectedGeneration else {
                    throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
                }
                return try store.recentAuditEntries(
                    limit: limit, accountID: selectedAccountID,
                    sourceGeneration: selectedGeneration
                )
            }
            // The on-device database and rotating audit log hold every Direct and Sync
            // Node account on this device, so the raw file (`auditLogURL`, below) stays
            // hidden here. This exports only the selected account's own entries, so iOS
            // can still let the user share something.
            exportAuditLog = { [store] in
                guard let selectedAccountID, let selectedGeneration else {
                    throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
                }
                let entries = try store.recentTimestampedAuditEntries(
                    limit: 1_000, accountID: selectedAccountID,
                    sourceGeneration: selectedGeneration
                )
                return try AuditLogExport.write(entries)
            }
            selectedOperations = OperationDiagnosticsSource(
                page: { [store] now, anchor, offset, limit in
                    guard let selectedAccountID, let selectedGeneration else {
                        throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
                    }
                    return try store.diagnosticsJobPage(
                        now: now, anchor: anchor, offset: offset, limit: limit,
                        accountID: selectedAccountID, sourceGeneration: selectedGeneration
                    )
                },
                blockers: { [store] in
                    guard let selectedAccountID, let selectedGeneration else {
                        throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
                    }
                    return try store.smartInboxSyncBlockers(
                        accountID: selectedAccountID, sourceGeneration: selectedGeneration
                    )
                }
            )
        }
        return AuditLogViewModel(
            log: AuditLogService(repository: store, selectedEntries: selectedEntries),
            jobs: selectedNodeAccountID == nil ? store : nil,
            operationSource: selectedOperations,
            auditLogURL: runtimeDependencies == nil && selectedNodeAccountID == nil
                ? store.auditLogURL : nil,
            exportAuditLog: exportAuditLog,
            browserRegistrationStatus: browserRegistrationStatus,
            accountEmails: { [store, deviceWide = isDeviceWideDirect] in
                let deviceDirect = deviceWide ? DeviceMailScope.current(in: store).directAccountIDs : nil
                return Dictionary(
                    uniqueKeysWithValues: store.accounts.filter { account in
                        if let deviceDirect { return deviceDirect.contains(account.id) }
                        return (selectedAccountID ?? selectedNodeAccountID) == nil
                            || account.id == (selectedAccountID ?? selectedNodeAccountID)
                    }.map { account in
                        (account.id, account.email.rawValue)
                    }
                )
            }
        )
    }

    /// The AI provider every AI action uses for `providerID`. DEBUG builds launched by UI tests
    /// with `PLAINPOST_UI_TEST_AI_PROVIDER=deterministic` use the deterministic local provider
    /// instead, since simulators have no on-device model.
    nonisolated static func uiTestAIProviderID(
        _ providerID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        #if DEBUG
        if environment["PLAINPOST_UI_TEST_AI_PROVIDER"] == "deterministic" {
            return "deterministic"
        }
        #endif
        return providerID
    }

    public func makeThreadAIAssistantViewModel() -> ThreadAIAssistantViewModel {
        let preferenceStore = UserDefaultsAIProviderPreferenceStore()
        let providerID = AIProviderSelection.resolvedProviderID(preferenceStore.selectedProviderID())
        if preferenceStore.selectedProviderID() != providerID {
            preferenceStore.saveSelectedProviderID(providerID)
        }
        return makeThreadAIAssistantViewModel(providerID: Self.uiTestAIProviderID(providerID))
    }

    public func makeAskMailViewModel() -> AskMailViewModel {
        let preferenceStore = UserDefaultsAIProviderPreferenceStore()
        var providerID = AIProviderSelection.resolvedProviderID(preferenceStore.selectedProviderID())
        #if DEBUG && os(iOS)
        // The Ask Mail UI acceptance fixture answers with the deterministic
        // local provider, since simulators have no on-device model. Only Ask
        // Mail uses it; Smart Inbox would reclassify the seeded categories.
        if ProcessInfo.processInfo.environment["PLAINPOST_ASK_MAIL_UI_ACCEPTANCE"] != nil {
            providerID = "deterministic"
        }
        #endif
        providerID = Self.uiTestAIProviderID(providerID)
        let provider = (try? LocalAIProviderResolver.resolve(LocalAIProviderSelection(providerID: providerID)))
            ?? DisabledAIProvider()
        let viewModel = AskMailViewModel(
            handler: makeAskMailHandler(providerID: providerID, provider: provider),
            providerName: provider.displayName,
            availability: {
                Self.aiActionAvailability(provider: provider, requestedProviderID: providerID, operation: .askMail)
            }
        )
        let requiresAccountScope = runtimeDependencies != nil || configuration.selectedAccountID != nil
        viewModel.setStarterSource { [store, selectedAccountID = configuration.selectedAccountID] in
            AskMailStarterBuilder.starters(
                requiresAccountScope: requiresAccountScope,
                accountID: selectedAccountID
            ) { filter, accountID in
                (try? store.filteredMailMessages(filter, accountID: accountID, limit: 0).totalCount) ?? 0
            }
        }
        return viewModel
    }

    /// The ✦ pane's detected actions: Ask Mail's card extractor on the newest message, with the
    /// AI provider resolved per call (as the operation runtime does), so Settings changes apply.
    func makeConversationActionDetector() -> any ConversationActionDetecting {
        LocalConversationActionDetector(
            store: store,
            selectedAccountID: configuration.selectedAccountID,
            provider: {
                let environment = ProcessInfo.processInfo.environment
                let providerID = Self.uiTestAIProviderID(AIProviderSelection.resolvedProviderID(
                    UserDefaultsAIProviderPreferenceStore().selectedProviderID()
                ))
                return try? LocalAIProviderResolver.resolve(LocalAIProviderSelection(
                    providerID: providerID,
                    ollamaBaseURL: environment["PLAINPOST_OLLAMA_URL"].flatMap(URL.init(string:)),
                    ollamaChatModelID: environment["PLAINPOST_OLLAMA_CHAT_MODEL"] ?? "qwen3:8b"
                ))
            }
        )
    }

    public func makeThreadTranslationViewModel() -> ThreadTranslationViewModel {
        let preferenceStore = UserDefaultsAIProviderPreferenceStore()
        let providerID = AIProviderSelection.resolvedProviderID(
            preferenceStore.selectedProviderID()
        )
        if preferenceStore.selectedProviderID() != providerID {
            preferenceStore.saveSelectedProviderID(providerID)
        }
        return Self.makeThreadTranslationViewModel(
            aiOperationClient: aiOperationClient,
            store: store,
            providerID: providerID,
            selectedAccountID: configuration.selectedAccountID,
            requiresAccountScope: runtimeDependencies != nil || configuration.selectedAccountID != nil,
            isDeviceWide: isDeviceWideDirect
        )
    }

    public func configureThreadTranslation(
        _ viewModel: ThreadTranslationViewModel,
        providerID: String
    ) {
        Self.configureThreadTranslation(
            viewModel,
            aiOperationClient: aiOperationClient,
            store: store,
            providerID: providerID,
            selectedAccountID: configuration.selectedAccountID,
            requiresAccountScope: runtimeDependencies != nil || configuration.selectedAccountID != nil,
            isDeviceWide: isDeviceWideDirect
        )
    }

    static func makeThreadTranslationViewModel(
        aiOperationClient: any PlainpostOperationClientProtocol,
        store: SQLiteMailStore,
        providerID: String,
        selectedAccountID: AccountID? = nil,
        requiresAccountScope: Bool = false,
        isDeviceWide: Bool = false
    ) -> ThreadTranslationViewModel {
        let handler = makeThreadTranslationHandler(
            aiOperationClient: aiOperationClient,
            store: store,
            providerID: providerID,
            selectedAccountID: selectedAccountID,
            requiresAccountScope: requiresAccountScope,
            isDeviceWide: isDeviceWide
        )
        #if os(iOS)
        return ThreadTranslationViewModel(
            handler: handler,
            availability: translationAvailability(providerID: providerID)
        )
        #else
        return ThreadTranslationViewModel(handler: handler)
        #endif
    }

    static func configureThreadTranslation(
        _ viewModel: ThreadTranslationViewModel,
        aiOperationClient: any PlainpostOperationClientProtocol,
        store: SQLiteMailStore,
        providerID: String,
        selectedAccountID: AccountID? = nil,
        requiresAccountScope: Bool = false,
        isDeviceWide: Bool = false
    ) {
        let handler = makeThreadTranslationHandler(
            aiOperationClient: aiOperationClient,
            store: store,
            providerID: providerID,
            selectedAccountID: selectedAccountID,
            requiresAccountScope: requiresAccountScope,
            isDeviceWide: isDeviceWide
        )
        #if os(iOS)
        viewModel.configure(
            handler: handler,
            availability: translationAvailability(providerID: providerID)
        )
        #else
        viewModel.configure(handler: handler)
        #endif
    }

    nonisolated private static func translationAvailability(
        providerID: String
    ) -> () -> AIActionAvailability {
        let resolvedProviderID = uiTestAIProviderID(AIProviderSelection.resolvedProviderID(providerID))
        let provider = (
            try? LocalAIProviderResolver.resolve(
                LocalAIProviderSelection(providerID: resolvedProviderID)
            )
        ) ?? DisabledAIProvider()
        return {
            aiActionAvailability(
                provider: provider,
                requestedProviderID: resolvedProviderID,
                operation: .translation
            )
        }
    }

    private static func makeThreadTranslationHandler(
        aiOperationClient: any PlainpostOperationClientProtocol,
        store: SQLiteMailStore,
        providerID: String,
        selectedAccountID: AccountID?,
        requiresAccountScope: Bool,
        isDeviceWide: Bool
    ) -> any ThreadTranslationHandling {
        let resolvedProviderID = uiTestAIProviderID(AIProviderSelection.resolvedProviderID(providerID))
        let provider = (
            try? LocalAIProviderResolver.resolve(
                LocalAIProviderSelection(providerID: resolvedProviderID)
            )
        ) ?? DisabledAIProvider()
        return LocalOperationThreadTranslationService(
            client: aiOperationClient,
            store: store,
            provider: provider,
            selectedAccountID: selectedAccountID,
            requiresAccountScope: requiresAccountScope,
            isDeviceWide: isDeviceWide
        )
    }

    public func configureAskMail(_ viewModel: AskMailViewModel, providerID: String) {
        let resolvedProviderID = Self.uiTestAIProviderID(AIProviderSelection.resolvedProviderID(providerID))
        let provider = (try? LocalAIProviderResolver.resolve(LocalAIProviderSelection(providerID: resolvedProviderID)))
            ?? DisabledAIProvider()
        viewModel.configure(
            handler: makeAskMailHandler(providerID: resolvedProviderID, provider: provider),
            providerName: provider.displayName,
            localOnly: provider.capabilities.runsLocally,
            availability: {
                Self.aiActionAvailability(provider: provider, requestedProviderID: resolvedProviderID, operation: .askMail)
            }
        )
    }

    func makeAskMailHandler(
        providerID: String,
        provider: any AIProvider
    ) -> any AskMailHandling {
        if accountAccess == .cachedReadOnly {
            return CachedMailAskMailService(
                provider: provider,
                store: store,
                selectedAccountID: configuration.selectedAccountID,
                requiresAccountScope: runtimeDependencies != nil || configuration.selectedAccountID != nil,
                isDeviceWide: isDeviceWideDirect
            )
        }
        return LocalOperationAskMailService(
            client: aiOperationClient,
            store: store,
            providerID: providerID,
            providerName: provider.displayName,
            selectedAccountID: configuration.selectedAccountID,
            requiresAccountScope: runtimeDependencies != nil || configuration.selectedAccountID != nil,
            isDeviceWide: isDeviceWideDirect
        )
    }

    public func configureThreadAIAssistant(
        _ viewModel: ThreadAIAssistantViewModel,
        providerID: String
    ) {
        let providerID = Self.uiTestAIProviderID(providerID)
        let provider = (try? LocalAIProviderResolver.resolve(LocalAIProviderSelection(providerID: providerID)))
            ?? DisabledAIProvider()
        viewModel.configure(
            assistant: makeThreadAIAssistant(providerID: providerID, provider: provider),
            providerID: providerID,
            availability: { operation in
                Self.aiActionAvailability(provider: provider, requestedProviderID: providerID, operation: operation)
            }
        )
    }

    private func makeThreadAIAssistantViewModel(providerID: String) -> ThreadAIAssistantViewModel {
        let provider = (try? LocalAIProviderResolver.resolve(LocalAIProviderSelection(providerID: providerID)))
            ?? DisabledAIProvider()
        return ThreadAIAssistantViewModel(
            assistant: makeThreadAIAssistant(providerID: providerID, provider: provider),
            providerID: providerID,
            availability: { operation in
                Self.aiActionAvailability(provider: provider, requestedProviderID: providerID, operation: operation)
            }
        )
    }

    nonisolated private static func aiActionAvailability(
        provider: any AIProvider,
        requestedProviderID: String,
        operation: AIActionOperation
    ) -> AIActionAvailability {
        #if os(iOS)
        let platformAvailability: FoundationModelsAvailability? =
            FoundationModelsAvailability.current()
        #else
        let platformAvailability: FoundationModelsAvailability? = nil
        #endif
        let status: AIProviderStatusSnapshot
        switch provider.id {
        case "foundation":
            status = AIProviderStatusService.foundation()
        case "disabled":
            if requestedProviderID == "ollama",
               platformAvailability != .requiresNewerOS {
                return AIActionAvailability(
                    isAvailable: false,
                    reason: "Ollama is not configured. Choose an available provider in AI Providers."
                )
            }
            if requestedProviderID == OpenRouterConfiguration.providerID {
                return AIActionAvailability(
                    isAvailable: false,
                    reason: "OpenRouter isn’t set up. Add an API key and model in Settings › Smart Inbox & AI."
                )
            }
            status = AIProviderStatusService.disabled()
        default:
            // Configured local providers may fail at request time. Their
            // capability flag is authoritative for which actions to show.
            status = AIProviderStatusSnapshot(
                providerID: provider.id, displayName: provider.displayName, state: .ready,
                chatModelID: provider.chatModelID, embeddingModelID: nil,
                localOnly: provider.capabilities.runsLocally, detail: "Provider is configured."
            )
        }
        return AIActionAvailability.resolve(
            provider: provider, status: status, operation: operation,
            platformAvailability: platformAvailability
        )
    }

    private static func requireAIGenerationPlatform() throws {
        #if os(iOS)
        guard FoundationModelsAvailability.current() != .requiresNewerOS else {
            throw PlainpostError.validationFailed("AI actions require iOS 26 or later on this device.")
        }
        #endif
    }

    private func makeThreadAIAssistant(
        providerID: String,
        provider: any AIProvider
    ) -> any ThreadAIAssistantHandling {
        return LocalOperationThreadAIAssistantService(
            client: aiOperationClient,
            store: store,
            providerID: providerID,
            providerName: provider.displayName,
            selectedAccountID: configuration.selectedAccountID,
            requiresAccountScope: runtimeDependencies != nil || configuration.selectedAccountID != nil,
            isDeviceWide: isDeviceWideDirect
        )
    }

    public func makeInboxMailActionViewModel() -> InboxMailActionViewModel {
        let handler: any InboxMailActionHandling
        if let mailAuthority {
            handler = NodeAuthorityInboxMailActionHandler(mutations: mailAuthority.mutations)
        } else if accountAccess == .cachedReadOnly {
            handler = AccountReadOnlyInboxMailActionHandler()
        } else if let runtimeDependencies, isDeviceWideDirect {
            handler = OwnerBoundInboxMailActionHandler(
                store: store,
                readGeneration: { [deviceDirectReadState] in deviceDirectReadState.generation(for: $0, owner: $1) },
                underlying: runtimeDependencies.makeInboxMailActionHandler(
                    store: store, mailboxFlagScheduler: mailboxFlagScheduler
                ),
                nodeMail: runtimeDependencies.deviceNodeMail
            )
        } else if let runtimeDependencies, let selectedAccountID = configuration.selectedAccountID {
            handler = runtimeDependencies.makeInboxMailActionHandler(
                store: store, mailboxFlagScheduler: mailboxFlagScheduler,
                selectedAccountID: selectedAccountID)
        } else if runtimeDependencies != nil {
            handler = AccountReadOnlyInboxMailActionHandler()
        } else {
            handler = PlainpostServiceInboxMailActionAdapter(
                serviceClient: serviceClient)
        }
        return InboxMailActionViewModel(handler: handler)
    }

    @MainActor
    public func makeNodeSettingsViewModel(onConnectProvider: (() -> Void)? = nil) -> SyncNodeSettingsViewModel? {
        if let nodeSettingsModel { return nodeSettingsModel }
        guard let authority = mailAuthority as? any SyncNodeStatusProviding else { return nil }
        // Cached authorities retain diagnostics only. Provider onboarding is
        // an active-session capability and must not reappear through the
        // read-only wrapper.
        let connectProvider = accountAccess == .readWrite
            && mailAuthority is SyncNodeStatusProviding
            ? onConnectProvider
            : nil
        let model = SyncNodeSettingsViewModel(refresh: {
            do {
                let current = try await authority.status()
                return Self.nodeSettingsSnapshot(from: current)
            } catch {
                return SyncNodeSettingsSnapshot(
                    version: "Unavailable", reachability: "Unavailable", syncLag: "Unavailable",
                    storage: "Unavailable", provider: "Unavailable", mailboxAssignments: [],
                    backup: "Unavailable", endpoint: "Unavailable", updateStatus: "Unavailable"
                )
            }
        }, connectProvider: connectProvider,
        operationsController: accountAccess == .readWrite
            ? (mailAuthority as? PlainpostNodeMailAuthority)?.operationsController
            : nil)
        if let liveAuthority = mailAuthority as? PlainpostNodeMailAuthority {
            liveAuthority.onStatusRefresh = { [weak model] current in
                Task { @MainActor in
                    model?.update(Self.nodeSettingsSnapshot(from: current))
                }
            }
        }
        nodeSettingsModel = model
        return model
    }

    nonisolated private static func nodeSettingsSnapshot(from status: SyncNodeStatus) -> SyncNodeSettingsSnapshot {
        SyncNodeSettingsSnapshot(
            version: status.version,
            reachability: status.reachability,
            syncLag: status.syncLag,
            storage: status.storage,
            provider: status.providerIdentity ?? "Not configured",
            mailboxAssignments: status.assignments.map(\.displayName),
            backup: status.backup,
            endpoint: status.endpoint,
            updateStatus: status.updateStatus
        )
    }

    @MainActor
    func makeMessageLabelActions() -> MessageLabelActions {
        if accountAccess == .cachedReadOnly { return .preview() }
        if let authority = mailAuthority {
            return MessageLabelActions(
                loadItems: { _ in [] },
                mutate: { labelID, messageID, selected in
                    _ = try await authority.mutations.perform(
                        .setLabels(
                            messageIDs: [messageID],
                            addLabelIDs: selected ? [labelID] : [],
                            removeLabelIDs: selected ? [] : [labelID]
                        )
                    )
                }
            )
        }
        if isDeviceWideDirect {
            return OwnerBoundMessageLabelActionsFactory.make(
                store: store,
                readGeneration: { [deviceDirectReadState] in deviceDirectReadState.generation(for: $0, owner: $1) }
            )
        }
        if runtimeDependencies != nil {
            guard let selectedAccountID = configuration.selectedAccountID,
                  let sourceGeneration = selectedDirectSourceGeneration else { return .preview() }
            return AccountBoundMessageLabelActionsFactory.make(
                store: store, selectedAccountID: selectedAccountID,
                sourceGeneration: sourceGeneration
            )
        }
        return ProductionMessageLabelActionsFactory.make(
            store: store,
            serviceClient: serviceClient
        )
    }

    public func runSmartInboxMaintenance(
        providerID: String,
        mode: PlainpostSmartInboxRunMode,
        requestID: String?
    ) async throws -> String {
        guard aiProviderPreferences.smartInboxEnabled() else { throw SmartInboxPolicyError.disabled }
        guard try store.smartInboxEnabled() else { throw SmartInboxPolicyError.disabled }
        try Self.requireAIGenerationPlatform()
        guard accountAccess == .readWrite else {
            throw PlainpostError.validationFailed(
                "This cached mailbox is read-only while the account is offline."
            )
        }
        guard mode == .rerunAll else {
            return try await organizeSmartInbox(
                using: providerID,
                mode: mode,
                requestID: requestID
            )
        }
        guard smartInboxPowerGate.allowsWork else { throw SmartInboxPowerGateError.lowPowerMode }
        guard !isSmartInboxMaintenanceRerunInFlight else {
            throw PlainpostSmartInboxMaintenanceError.rerunAlreadyActive
        }
        guard try activeSmartInboxRerunJob() == nil else {
            throw PlainpostSmartInboxMaintenanceError.rerunAlreadyActive
        }

        isSmartInboxMaintenanceRerunInFlight = true
        defer { isSmartInboxMaintenanceRerunInFlight = false }
        return try await organizeSmartInbox(
            using: providerID,
            mode: mode,
            requestID: requestID
        )
    }

    func organizeSmartInbox(
        using providerID: String,
        mode: PlainpostSmartInboxRunMode,
        requestID: String? = nil
    ) async throws -> String {
        guard aiProviderPreferences.smartInboxEnabled() else { throw SmartInboxPolicyError.disabled }
        guard try store.smartInboxEnabled() else { throw SmartInboxPolicyError.disabled }
        try Self.requireAIGenerationPlatform()
        let scope: PlainpostSmartInboxRunScope
        let scopedAccountID: AccountID?
        let expectedDirectSourceGeneration: Int64?
        if runtimeDependencies != nil, !isDeviceWideDirect {
            guard let selectedAccountID = configuration.selectedAccountID,
                  let selectedDirectSourceGeneration else {
                throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
            }
            try store.requireDirectMailSource(accountID: selectedAccountID)
            scope = .account(selectedAccountID)
            scopedAccountID = selectedAccountID
            expectedDirectSourceGeneration = selectedDirectSourceGeneration
        } else {
            scope = .allAccounts
            scopedAccountID = nil
            expectedDirectSourceGeneration = nil
        }
        let resolvedProviderID = AIProviderSelection.resolvedProviderID(providerID)
        let classifierIdentity = SmartInboxClassifierIdentity.resolve(
            providerID: resolvedProviderID,
            modelID: AIProviderSelection.classifierModelID(providerID: resolvedProviderID)
        )

        let operation = try await aiOperationClient.executeAI(
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                accountID: scopedAccountID,
                expectedDirectSourceGeneration: expectedDirectSourceGeneration,
                providerID: resolvedProviderID,
                modelID: classifierIdentity.modelID,
                smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                    mode: mode, scope: scope, requestedLabelID: nil
                ),
                smartInboxRequestID: requestID,
                smartInboxClassifierIdentity: classifierIdentity
            )
        )
        if mode == .incremental {
            return "Up to date"
        }
        let artifact = try store.durableOperationArtifact(id: operation.artifactID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        let categorized = payload.categorizedMessageCount ?? 0
        let unchanged = payload.unchangedMessageCount ?? 0
        let failed = payload.failedMessageCount ?? 0
        guard categorized + unchanged + failed > 0 else {
            return "Up to date"
        }
        let provider = try LocalAIProviderResolver.resolve(
            LocalAIProviderSelection(providerID: resolvedProviderID)
        )
        return SmartInboxClassificationResultPresentation.status(
            providerDisplayName: provider.displayName,
            updated: categorized,
            unchanged: unchanged,
            failed: failed
        )
    }

    private func reclassifyMailLabel(
        _ request: PlainpostSmartInboxRunRequest
    ) async throws -> MailLabelRunProgress {
        guard aiProviderPreferences.smartInboxEnabled() else { throw SmartInboxPolicyError.disabled }
        guard try store.smartInboxEnabled() else { throw SmartInboxPolicyError.disabled }
        try Self.requireAIGenerationPlatform()
        let scopedAccountID: AccountID?
        let expectedDirectSourceGeneration: Int64?
        if runtimeDependencies != nil, !isDeviceWideDirect {
            guard let selectedAccountID = configuration.selectedAccountID,
                  let selectedDirectSourceGeneration,
                  request.scope == .account(selectedAccountID) else {
                throw PlainpostError.permissionDenied("This label run requires the selected local mail account.")
            }
            try store.requireDirectMailSource(accountID: selectedAccountID)
            scopedAccountID = selectedAccountID
            expectedDirectSourceGeneration = selectedDirectSourceGeneration
        } else {
            scopedAccountID = nil
            expectedDirectSourceGeneration = nil
        }
        let preferenceStore = UserDefaultsAIProviderPreferenceStore()
        let providerID = AIProviderSelection.resolvedProviderID(
            preferenceStore.selectedProviderID()
        )
        let classifierIdentity = SmartInboxClassifierIdentity.resolve(
            providerID: providerID,
            modelID: AIProviderSelection.classifierModelID(providerID: providerID)
        )
        let operation = try await aiOperationClient.executeAI(
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                accountID: scopedAccountID,
                expectedDirectSourceGeneration: expectedDirectSourceGeneration,
                providerID: providerID,
                modelID: classifierIdentity.modelID,
                smartInboxRunRequest: request,
                smartInboxRequestID: "label-reclassify-\(UUID().uuidString.lowercased())",
                smartInboxClassifierIdentity: classifierIdentity
            )
        )
        let artifact = try store.durableOperationArtifact(id: operation.artifactID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        return MailLabelRunProgress(
            updated: payload.categorizedMessageCount ?? 0,
            unchanged: payload.unchangedMessageCount ?? 0,
            failed: payload.failedMessageCount ?? 0
        )
    }
}

/// Resolves notification identities only through the currently authenticated
/// Node projection. Refreshing the snapshot is the app-level sync request;
/// no provider identifiers or notification payload fields are consulted.
private struct AuthorityNotificationDeepLinkResolver: PlainpostNotificationDeepLinkResolving, PlainpostNotificationDeepLinkRefreshing {
    let authority: any PlainpostMailAuthority

    func messageID(forOpaqueToken token: String) async -> String? {
        var cursor: MailSearchCursor?
        for _ in 0..<32 {
            guard let page = try? await authority.snapshots.snapshot(after: cursor, limit: 200) else { return nil }
            if let match = page.messages.first(where: {
                NotificationOpaqueIdentities.messageToken(for: $0.id.rawValue) == token
            }) {
                return match.id.rawValue
            }
            guard let next = page.nextCursor else { return nil }
            cursor = next
        }
        return nil
    }

    func refreshForNotification() async {
        if let syncer = authority as? any PlainpostNotificationProviderSynchronizing {
            do {
                try await syncer.requestProviderSyncForNotification()
            } catch {
                // A provider-sync request is a completion fence, not a
                // best-effort hint. Never resolve a tap against a stale
                // snapshot when the authenticated fence timed out.
                return
            }
        }
        _ = try? await authority.snapshots.snapshot(after: nil, limit: 200)
    }
}

/// The first inbox pass is part of account admission. It runs after the new
/// Direct source is published but before the root can select that account, so
/// it needs a temporary worker scoped to that new source.
private struct IOSAccountSetupInboxSyncer: AccountInboxSyncOrchestrating {
    let store: SQLiteMailStore
    let runtimeDependencies: any PlainpostAppRuntimeDependencyProviding
    let selectedSyncer: any AccountInboxSyncOrchestrating

    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        guard reason == .accountSetup else {
            return try await selectedSyncer.syncInbox(for: account, reason: reason)
        }
        guard let source = try store.explicitMailSource(accountID: account.id),
              source.kind == .direct else {
            throw PlainpostError.permissionDenied("Account setup requires a published Direct mail source.")
        }
        let accountID = account.id
        let generation = source.generation
        let runtime = runtimeDependencies.makeOperationRuntime(
            store: store,
            allowedJobKinds: [.inboxSync],
            selectedDirectAccountID: accountID,
            expectedDirectSourceGeneration: generation
        )
        let syncer = LocalOperationAccountInboxSyncer(
            client: LocalOperationClient(runtime: runtime),
            notificationScheduler: NoopLocalNotificationScheduler(),
            directSourceProvider: { (accountID, generation) }
        )
        return try await syncer.syncInbox(for: account, reason: reason)
    }
}

/// Keeps existing-account setup operations on the selected Direct account.
/// Adding a new account remains available and publishes its own Direct source
/// before the iOS root switches to a new runtime for that account.
private struct SelectedDirectAccountSetupHandler: AccountSetupHandling {
    let base: any AccountSetupHandling
    let store: SQLiteMailStore
    let requireSelectedAccount: @Sendable (AccountID) throws -> Void
    private let addedAccounts = AddedDirectAccountCleanupScope()

    private func requireNewAccount(email: EmailAddress) throws -> AccountID {
        let accountID = AccountID.stableAccountID(email: email)
        let normalizedEmail = email.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !store.accounts.contains(where: {
            $0.id == accountID
                || $0.email.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedEmail
        }) else {
            throw PlainpostError.permissionDenied("This mail account is already connected.")
        }
        return accountID
    }

    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        let expectedID = try requireNewAccount(email: request.email)
        let result = try await base.addAccount(request, progress: progress)
        guard result.account.id == expectedID else {
            throw PlainpostError.permissionDenied("The added account identity changed.")
        }
        try store.requireDirectMailSource(accountID: expectedID)
        return result
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        try requireSelectedAccount(account.id)
        return try await base.syncInbox(for: account, progress: progress)
    }

    func addGoogleAccount(
        displayName: String, email: EmailAddress, authorization: GmailAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        let expectedID = try requireNewAccount(email: email)
        let result = try await base.addGoogleAccount(
            displayName: displayName, email: email, authorization: authorization, progress: progress
        )
        guard result.account.id == expectedID else {
            throw PlainpostError.permissionDenied("The added account identity changed.")
        }
        try store.requireDirectMailSource(accountID: expectedID)
        await addedAccounts.record(expectedID)
        return result
    }

    func reauthorizeGoogleAccount(
        accountID: AccountID, email: EmailAddress, authorization: GmailAuthorizationCode
    ) async throws {
        try requireSelectedAccount(accountID)
        try await base.reauthorizeGoogleAccount(accountID: accountID, email: email, authorization: authorization)
    }

    func discardAddedGoogleAccount(accountID: AccountID) async throws {
        try store.requireDirectMailSource(accountID: accountID)
        guard await addedAccounts.claim(accountID) else {
            throw PlainpostError.permissionDenied("This account was not added by the current setup attempt.")
        }
        do {
            try await base.discardAddedGoogleAccount(accountID: accountID)
        } catch {
            await addedAccounts.record(accountID)
            throw error
        }
    }

    func addMicrosoftAccount(
        displayName: String, email: EmailAddress, authorization: MicrosoftAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        let expectedID = try requireNewAccount(email: email)
        let result = try await base.addMicrosoftAccount(
            displayName: displayName, email: email, authorization: authorization, progress: progress
        )
        guard result.account.id == expectedID else {
            throw PlainpostError.permissionDenied("The added account identity changed.")
        }
        try store.requireDirectMailSource(accountID: expectedID)
        await addedAccounts.record(expectedID)
        return result
    }

    func discardAddedMicrosoftAccount(accountID: AccountID) async throws {
        try store.requireDirectMailSource(accountID: accountID)
        guard await addedAccounts.claim(accountID) else {
            throw PlainpostError.permissionDenied("This account was not added by the current setup attempt.")
        }
        do {
            try await base.discardAddedMicrosoftAccount(accountID: accountID)
        } catch {
            await addedAccounts.record(accountID)
            throw error
        }
    }

    func reauthorizeMicrosoftAccount(
        accountID: AccountID, email: EmailAddress, authorization: MicrosoftAuthorizationCode
    ) async throws {
        try requireSelectedAccount(accountID)
        try await base.reauthorizeMicrosoftAccount(accountID: accountID, email: email, authorization: authorization)
    }
}

private actor AddedDirectAccountCleanupScope {
    private var accountIDs: Set<AccountID> = []

    func record(_ accountID: AccountID) { accountIDs.insert(accountID) }
    func claim(_ accountID: AccountID) -> Bool { accountIDs.remove(accountID) != nil }
}

private struct NodeAccountSetupUnavailable: AccountSetupHandling {
    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        _ = request
        _ = progress
        throw PlainpostError.permissionDenied("Node-backed mail is configured through Node settings.")
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        _ = account
        _ = progress
        throw PlainpostError.permissionDenied("Node-backed mail does not use local IMAP credentials.")
    }
}

private struct AccountReadOnlyInboxMailActionHandler: InboxMailActionHandling {
    func perform(
        _ action: InboxMailAction,
        messageID: MessageID
    ) async throws -> InboxMailActionResult {
        throw PlainpostError.validationFailed(
            "This cached mailbox is read-only while the account is offline."
        )
    }
}

private struct InboxMailboxSnapshot: Sendable {
    let messages: [MessageSummary]
    let messagesByThreadKey: [String: [MessageSummary]]
    let threads: [MailThread]
    let accounts: [Account]
    let rows: [MessageRowModel]
    let sentRows: [MessageRowModel]
    let smartCards: [SmartInboxCardModel]
    let sidebarItems: [SidebarItemModel]
    let aiIndexStatus: AIIndexStatusModel
}

private final class RuntimeApprovalQueueService: ApprovalQueueHandling, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let guiUser: Actor
    private let authenticator: LocalApprovalAuthenticating
    private let operationClient: any PlainpostOperationClientProtocol
    private let selectedAccountID: AccountID?
    private let requiresAccountScope: Bool
    /// Every Direct account's approvals, each reviewed through its own account.
    private let isDeviceWideDirect: Bool

    init(
        store: SQLiteMailStore,
        operationClient: any PlainpostOperationClientProtocol,
        selectedAccountID: AccountID?,
        requiresAccountScope: Bool,
        isDeviceWideDirect: Bool = false,
        authenticator: LocalApprovalAuthenticating = LocalApprovalAuthenticatorFactory.defaultAuthenticator(),
        guiUser: Actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
    ) {
        self.store = store
        self.operationClient = operationClient
        self.selectedAccountID = selectedAccountID
        self.requiresAccountScope = requiresAccountScope
        self.isDeviceWideDirect = isDeviceWideDirect
        self.authenticator = authenticator
        self.guiUser = guiUser
    }

    func items() throws -> [ApprovalQueueItemModel] {
        let deviceDirect = isDeviceWideDirect ? DeviceMailScope.current(in: store).accountIDs : nil
        guard !requiresAccountScope || selectedAccountID != nil || deviceDirect != nil else { return [] }
        return try store.approvalQueueRequests.compactMap { request in
            let draft = try store.draft(id: request.draftID)
            if let deviceDirect {
                guard deviceDirect.contains(draft.accountID) else { return nil }
            } else {
                guard !requiresAccountScope || draft.accountID == selectedAccountID else { return nil }
            }
            return ApprovalQueueItemModel(
                id: request.id.rawValue,
                agentName: request.requestedBy,
                subject: draft.subject,
                recipientSummary: (draft.to + draft.cc + draft.bcc).map(\.rawValue).joined(separator: ", "),
                riskFlags: request.riskFlags.map(\.rawValue),
                hasAttachments: !draft.attachments.isEmpty,
                requiresAuthentication: requiresAuthentication(for: request),
                status: request.status.rawValue,
                reviewDetails: ApprovalQueueReviewDetails(
                    from: draft.from.rawValue,
                    to: draft.to.map(\.rawValue),
                    cc: draft.cc.map(\.rawValue),
                    bcc: draft.bcc.map(\.rawValue),
                    bodyPlain: draft.bodyPlain,
                    attachments: draft.attachments.map {
                        ApprovalQueueAttachmentModel(
                            id: $0.id,
                            filename: $0.filename,
                            mimeType: $0.mimeType,
                            byteCount: $0.data.count
                        )
                    },
                    requestReason: request.reason,
                    riskScore: request.riskScore
                )
            )
        }
    }

    func approve(requestID: String, username: String, password: String) async throws {
        let request = try store.sendRequest(id: SendRequestID(requestID))
        let draft = try store.draft(id: request.draftID)
        try requireSelectedAccount(for: draft)
        if requiresAuthentication(for: request) {
            try await authenticator.authenticate(
                reason: "Authenticate to approve high-risk send \"\(draft.subject)\"."
            )
        }

        try await operationClient.approveSend(requestID: request.id, approvedBy: guiUser.id)
    }

    func deny(requestID: String, reason: String?) async throws {
        let request = try store.sendRequest(id: SendRequestID(requestID))
        let draft = try store.draft(id: request.draftID)
        try requireSelectedAccount(for: draft)
        try await operationClient.denySend(requestID: request.id, deniedBy: guiUser.id)
    }

    private func requireSelectedAccount(for draft: Draft) throws {
        if isDeviceWideDirect {
            try DeviceMailScope.requireCurrentOwner(draft.accountID, expected: nil, in: store)
            return
        }
        guard requiresAccountScope else { return }
        guard let selectedAccountID, draft.accountID == selectedAccountID else {
            throw PlainpostError.permissionDenied("This approval belongs to another mail account.")
        }
        try store.requireDirectMailSource(accountID: selectedAccountID)
    }

    private func account(for draft: Draft) throws -> Account {
        if let account = store.accounts.first(where: { $0.id == draft.accountID }) {
            return account
        }
        if let account = store.accounts.first(where: { $0.email == draft.from }) {
            return account
        }
        throw PlainpostError.validationFailed("No configured account matches this draft.")
    }

    private func requiresAuthentication(for request: SendRequest) -> Bool {
        request.riskScore >= ApprovalQueueService<SQLiteMailStore>.authenticationRiskScoreThreshold
    }
}

enum DefaultNotificationSchedulerSelection: Equatable {
    case userNotifications
    case noop
}

func defaultNotificationSchedulerSelection(bundleURL: URL = Bundle.main.bundleURL) -> DefaultNotificationSchedulerSelection {
    bundleURL.pathExtension.lowercased() == "app" ? .userNotifications : .noop
}

private func makeNotificationScheduler() -> any LocalNotificationScheduling {
    guard defaultNotificationSchedulerSelection() == .userNotifications else {
        return NoopLocalNotificationScheduler()
    }

    #if canImport(UserNotifications)
    return UserNotificationsLocalScheduler()
    #else
    return NoopLocalNotificationScheduler()
    #endif
}

private struct UnconfiguredRuntimeSMTPClient: SMTPClientProtocol {
    func send(
        username: String,
        password: String,
        from: EmailAddress,
        to: [EmailAddress],
        data: String
    ) async throws {
        throw PlainpostError.validationFailed("SMTP delivery is not configured for this approval session.")
    }
}

private final class SelectedDirectComposerDraftHandler: ComposerDraftSessionHandling, @unchecked Sendable {
    let store: SQLiteMailStore
    let accountID: AccountID
    /// The Direct generation a save is checked against: fixed for a selected account's
    /// runtime, or (device-wide) the account's own current one, read at each save.
    private let generation: () throws -> Int64
    let from: EmailAddress
    let actor: Actor
    private let draftIdentity = ComposerDraftIdentity()

    convenience init(store: SQLiteMailStore, accountID: AccountID, generation: Int64, from: EmailAddress, actor: Actor) {
        self.init(store: store, accountID: accountID, currentGeneration: { generation }, from: from, actor: actor)
    }

    init(
        store: SQLiteMailStore, accountID: AccountID, currentGeneration: @escaping () throws -> Int64,
        from: EmailAddress, actor: Actor
    ) {
        self.store = store
        self.accountID = accountID
        self.generation = currentGeneration
        self.from = from
        self.actor = actor
    }

    func saveDraft(input: ComposerDraftInput) throws -> Draft {
        let draft = try ComposerDraftBuilder.makeDraft(
            input: input,
            id: draftIdentity.current(orCreate: { DraftID("drf_\(UUID().uuidString.lowercased())") }),
            accountID: accountID, from: from, actor: actor
        )
        _ = try draft.validated()
        return try store.createDirectDraft(
            draft, actor: actor, expectedDirectSourceGeneration: try generation()
        )
    }

    func beginNewDraftSession() {
        draftIdentity.reset()
    }

    func restoreDraftSession(draftID: String) {
        draftIdentity.restore(DraftID(draftID))
    }

    func discardDraft(draftID: String) throws {
        try store.requireDirectMailSource(accountID: accountID)
        let draft = try store.draft(id: DraftID(draftID))
        guard draft.accountID == accountID else {
            throw PlainpostError.permissionDenied("This draft belongs to another account.")
        }
        try store.deleteDraft(
            id: draft.id,
            expectedHash: draft.contentHash,
            actor: actor,
            requiredIDPrefix: "drf_",
            requiredCreatorID: actor.id
        )
        draftIdentity.reset()
    }
}

private struct AccountReadOnlyOperationClient: PlainpostOperationClientProtocol {
    private func rejected() -> PlainpostError {
        .validationFailed("This cached mailbox is read-only while the account is offline.")
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        throw rejected()
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        throw rejected()
    }

    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        throw rejected()
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw rejected()
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw rejected()
    }
}

#if os(macOS)
extension PlainpostAppRuntime {
    // Separate typed helpers keep the local API server construction cheap to
    // type-check under Swift 6.4.
    fileprivate static func localAPILastSync(store: SQLiteMailStore) -> @Sendable () -> Date? {
        { [store] in (try? store.lastSuccessfulMailboxSyncAt()) ?? nil }
    }

    fileprivate static func localAPIDeliveryService(
        store: SQLiteMailStore, runtime: LocalOperationRuntime?,
        serviceClient: any PlainpostServiceClientProtocol
    ) -> any BrowserReplyDelivering {
        guard let runtime else {
            return PlainpostServiceBrowserReplyDeliveryAdapter(serviceClient: serviceClient)
        }
        return BrowserReplyDeliveryService(store: store, runtime: runtime)
    }
}
#endif

/// Keeps a selected device-local search session within the Direct source
/// generation that created it. A store-wide index rebuild is deliberately
/// unavailable from one selected account's runtime.
private struct DirectSourceBoundMailSearchService: MailSearchService {
    let base: any MailSearchService
    let store: SQLiteMailStore
    let accountID: AccountID?
    let sourceGeneration: Int64?
    /// Searches every Direct account, never a Sync Node one, instead of one selected account.
    var isDeviceWide = false
    /// Where a device-wide search records its hits as read, so actions on them are checked
    /// against the generation the search read.
    var readState: DeviceDirectReadState?

    private func requireCurrentSource() throws {
        if isDeviceWide { return }
        guard let accountID, let sourceGeneration else {
            throw PlainpostError.permissionDenied("A local mail account must be selected explicitly.")
        }
        try store.requireDirectMailSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation == sourceGeneration else {
            throw NodeMailModeStoreError.generationConflict
        }
    }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        try requireCurrentSource()
        let sources = isDeviceWide ? DeviceMailScope.current(in: store) : nil
        let result = try await base.search(try deviceWideRequest(request))
        if let sources, let readState, DeviceMailScope.current(in: store) == sources {
            readState.record(result.hits.map { hit in
                switch hit {
                case .conversation(let hit): (hit.bestMatchingMessageID, hit.accountID)
                case .message(let hit): (hit.messageID, hit.accountID)
                }
            }, sources: sources)
        }
        try requireCurrentSource()
        return result
    }

    func suggestions(_ request: MailSearchSuggestionRequest) async throws -> [MailSearchSuggestionSection] {
        try requireCurrentSource()
        let result = try await base.suggestions(try deviceWideRequest(request))
        try requireCurrentSource()
        return result
    }

    /// A device-wide search covers the accounts it asks for, or all of them.
    private func deviceWideRequest(_ request: MailSearchRequest) throws -> MailSearchRequest {
        guard isDeviceWide else { return request }
        let accounts = try directAccounts(asked: request.scope.accountIDs)
        return MailSearchRequest(
            query: request.query,
            scope: MailSearchSelectionScope(accountIDs: Array(accounts), mailboxIDs: request.scope.mailboxIDs),
            mode: request.mode, limit: request.limit, cursor: request.cursor
        )
    }

    /// Suggestions draw on the same accounts as results.
    private func deviceWideRequest(_ request: MailSearchSuggestionRequest) throws -> MailSearchSuggestionRequest {
        guard isDeviceWide else { return request }
        let accounts = try directAccounts(asked: request.scope.accountIDs)
        return MailSearchSuggestionRequest(
            query: request.query,
            scope: MailSearchSelectionScope(accountIDs: Array(accounts), mailboxIDs: request.scope.mailboxIDs),
            recentQueries: request.recentQueries,
            activeRange: request.activeRange
        )
    }

    /// The accounts a device-wide request covers: those it asks for, or all of them. An
    /// empty scope means every account, so no account means no request.
    private func directAccounts(asked: [AccountID]) throws -> Set<AccountID> {
        let direct = DeviceMailScope.current(in: store).accountIDs
        let accounts = asked.isEmpty ? direct : Set(asked).intersection(direct)
        guard !accounts.isEmpty else {
            throw PlainpostError.permissionDenied("There is no mail account to search.")
        }
        return accounts
    }

    func indexState() async -> MailSearchIndexState {
        guard (try? requireCurrentSource()) != nil else { return .unavailable }
        let result = await base.indexState()
        return (try? requireCurrentSource()) != nil ? result : .unavailable
    }

    func rebuildIndex() async throws {
        try requireCurrentSource()
        throw PlainpostError.permissionDenied("Search index rebuild requires a store-wide authority.")
    }

    func performMaintenanceIfDue(now: Date) async throws {
        try requireCurrentSource()
        // The underlying maintenance updates global search state. A selected
        // Direct runtime only needs account-scoped search reads.
    }
}

@MainActor enum ProductionMessageLabelActionsFactory {
    static func make(
        store: SQLiteMailStore, serviceClient: (any PlainpostServiceClientProtocol)? = nil
    ) -> MessageLabelActions {
        guard let serviceClient else {
            return MessageLabelActions(snapshots: store, assignments: store)
        }
        let mutations = PlainpostServiceMessageLabelMutationAdapter(serviceClient: serviceClient)
        return MessageLabelActions(
            snapshots: store,
            mutate: { labelID, messageID, selected in
                try await mutations.command(
                    labelID: labelID, messageID: messageID, selected: selected)
            })
    }
}

/// What the device-wide runtime has listed: the latest inbox read's sources, and for each
/// message a list showed (inbox, folder or search), the account and source generation it was
/// read under. Shared with action handlers that run off the main actor.
final class DeviceDirectReadState: @unchecked Sendable {
    /// Lists record their rows as they read; past this many, older reads are dropped.
    static let messageLimit = 5_000
    private let lock = NSLock()
    private var sources: DeviceMailSources?
    private var reads: [MessageID: (owner: AccountID, generation: Int64)] = [:]
    private var accounts: [AccountID: Account] = [:]

    var value: DeviceMailSources? {
        get { lock.withLock { sources } }
        set { lock.withLock { sources = newValue } }
    }

    /// Records `rows` (message and its account) as read at `sources`, and the accounts a
    /// later per-row lookup names.
    func record(_ rows: [(MessageID, AccountID?)], sources: DeviceMailSources, accounts: [Account]? = nil) {
        lock.withLock {
            if reads.count + rows.count > Self.messageLimit { reads.removeAll(keepingCapacity: true) }
            for (messageID, owner) in rows {
                guard let owner, let generation = sources.generations[owner] else { continue }
                reads[messageID] = (owner, generation)
            }
            if let accounts {
                self.accounts = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
    }

    /// The generation `messageID` was listed at under `owner`; for a message no list showed,
    /// the latest inbox read's.
    func generation(for messageID: MessageID, owner: AccountID) -> Int64? {
        lock.withLock {
            if let read = reads[messageID], read.owner == owner { return read.generation }
            return sources?.generations[owner]
        }
    }

    func owner(of messageID: MessageID) -> AccountID? {
        lock.withLock { reads[messageID]?.owner }
    }

    func account(_ id: AccountID) -> Account? {
        lock.withLock { accounts[id] }
    }
}

/// A device-wide background sync pass in which one account failed; the other accounts
/// still synced.
public struct DirectSyncFailure: Error {
    public let accountID: AccountID
    public let underlying: Error
}

/// Which accounts' notifications a runtime resolves, and the opaque tokens and inbox scopes
/// it hands the notification layer: every account on the Mac, one selected account (Node or
/// Direct), or every Direct account on the device-wide iPhone runtime.
struct RuntimeNotificationScope: Sendable {
    let store: SQLiteMailStore
    let selectedAccountID: AccountID?
    let selectedDirectGeneration: Int64?
    let scopesLocalNotifications: Bool
    let hasNodeAuthority: Bool
    let isDeviceWideDirect: Bool

    func messageToken(for messageID: String) -> String? {
        guard scopesLocalNotifications else {
            return NotificationOpaqueIdentities.messageToken(for: messageID)
        }
        if isDeviceWideDirect {
            let sources = DeviceMailScope.current(in: store)
            guard let owner = store.accountID(forMessageID: MessageID(messageID)),
                  let generation = sources.generations[owner] else { return nil }
            let kind: AccountMailSourceKind = sources.nodeAccountIDs.contains(owner) ? .nodeBacked : .direct
            return NotificationOpaqueIdentities.messageToken(
                for: messageID, accountID: owner.rawValue,
                sourceKind: kind.rawValue, sourceGeneration: generation
            )
        }
        guard let selectedAccountID,
              store.accountID(forMessageID: MessageID(messageID)) == selectedAccountID,
              let source = try? store.mailSource(accountID: selectedAccountID) else { return nil }
        if let selectedDirectGeneration {
            guard source.kind == .direct,
                  source.generation == selectedDirectGeneration else { return nil }
        }
        return NotificationOpaqueIdentities.messageToken(
            for: messageID,
            accountID: selectedAccountID.rawValue,
            sourceKind: source.kind.rawValue,
            sourceGeneration: source.generation
        )
    }

    func inboxScope(for rawAccountID: String) -> PlainpostNotificationInboxScope? {
        let accountID = AccountID(rawAccountID)
        if isDeviceWideDirect {
            guard DeviceMailScope.current(in: store).accountIDs.contains(accountID) else { return nil }
        } else if scopesLocalNotifications {
            guard accountID == selectedAccountID else {
                return nil
            }
            if hasNodeAuthority {
                guard let source = try? store.mailSource(accountID: accountID),
                      source.kind == .nodeBacked, source.mode == .node else { return nil }
            } else {
                guard (try? store.requireDirectMailSource(accountID: accountID)) != nil,
                      selectedDirectGeneration == nil
                        || (try? store.mailSource(accountID: accountID).generation) == selectedDirectGeneration else {
                    return nil
                }
            }
        }
        guard let account = store.accounts.first(where: { $0.id == accountID }),
              let messageIDs = try? store.mailboxListMessageIDs(
                  accountID: accountID,
                  inMailboxPath: "INBOX"
              ) else { return nil }
        return PlainpostNotificationInboxScope(
            accountID: rawAccountID,
            messageIDs: Set(messageIDs.map(\.rawValue)),
            accountIdentity: MailboxAccountIdentity(
                displayName: account.displayName.isEmpty
                    ? account.email.rawValue
                    : account.displayName,
                email: account.email.rawValue
            )
        )
    }
}

/// One account's drafts on the Mac: one draft id per message, saved through the store, and
/// deleted when From moves the message to another account.
private final class AccountComposerDraftHandler: ComposerDraftSessionHandling, @unchecked Sendable {
    let store: SQLiteMailStore
    let accountID: AccountID
    let from: EmailAddress
    let actor: Actor
    /// Throws when the account's source is no longer the one this composer saves for.
    private let requireCurrentSource: () throws -> Void
    private let draftIdentity = ComposerDraftIdentity()

    init(
        store: SQLiteMailStore, accountID: AccountID, from: EmailAddress, actor: Actor,
        requireCurrentSource: @escaping () throws -> Void = {}
    ) {
        self.store = store
        self.accountID = accountID
        self.from = from
        self.actor = actor
        self.requireCurrentSource = requireCurrentSource
    }

    func saveDraft(input: ComposerDraftInput) throws -> Draft {
        try requireCurrentSource()
        let draft = try ComposerDraftBuilder.makeDraft(
            input: input,
            id: draftIdentity.current(orCreate: { DraftID("drf_\(UUID().uuidString.lowercased())") }),
            accountID: accountID, from: from, actor: actor
        )
        _ = try draft.validated()
        // Saving again under a draft's id never moves it to another account.
        if let existing = try? store.draft(id: draft.id), existing.accountID != accountID {
            throw PlainpostError.permissionDenied("This draft belongs to another account.")
        }
        return try store.createDraft(draft, actor: actor)
    }

    func beginNewDraftSession() {
        draftIdentity.reset()
    }

    func restoreDraftSession(draftID: String) {
        draftIdentity.restore(DraftID(draftID))
    }

    func discardDraft(draftID: String) throws {
        try requireCurrentSource()
        let draft = try store.draft(id: DraftID(draftID))
        guard draft.accountID == accountID else {
            throw PlainpostError.permissionDenied("This draft belongs to another account.")
        }
        try store.deleteDraft(
            id: draft.id,
            expectedHash: draft.contentHash,
            actor: actor,
            requiredIDPrefix: "drf_",
            requiredCreatorID: actor.id
        )
        draftIdentity.reset()
    }
}

/// The device-wide runtime's sender: a Sync Node account's draft goes to the device's Node
/// (which saves it there and sends it), every other draft to the Direct sender.
private struct DeviceMailComposerSender: DirectComposerSending {
    let store: SQLiteMailStore
    let direct: any DirectComposerSending
    let nodeMail: (any DeviceNodeMailBridging)?

    func send(draft: Draft) async throws -> DirectComposerSendResult {
        guard DeviceMailScope.isNodeOwner(draft.accountID, in: store) else {
            return try await direct.send(draft: draft)
        }
        guard let nodeMail else {
            throw PlainpostError.validationFailed(DeviceNodeInboxMailActionHandler.unavailableMessage)
        }
        switch try await nodeMail.send(draft) {
        case let .failed(message):
            throw PlainpostError.validationFailed(message)
        case .confirmed:
            return DirectComposerSendResult(messageID: draft.id.rawValue, remoteSentCopyAppended: true)
        case .waitingForNode, .uncertain:
            return DirectComposerSendResult(messageID: draft.id.rawValue, remoteSentCopyAppended: false, isQueuedForSyncNode: true)
        }
    }
}
