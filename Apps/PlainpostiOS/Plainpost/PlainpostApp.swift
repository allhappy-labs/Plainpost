@preconcurrency import BackgroundTasks
import SwiftUI
import UIKit
import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostNodeMailMode
import PlainpostUI
import UserNotifications

extension Notification.Name {
    static let plainpostAPNsToken = Notification.Name("PlainpostAPNsToken")
    static let plainpostAPNsRegistrationFailed = Notification.Name("PlainpostAPNsRegistrationFailed")
    static let plainpostNotificationTapped = Notification.Name("PlainpostNotificationTapped")
    static let plainpostOpenNotification = Notification.Name("PlainpostOpenNotification")
}

private extension Result where Success == MobileMailRoute {
    var selectedLocalAccountID: AccountID? {
        guard case .success(let route) = self else { return nil }
        switch route {
        case .localSetup: return nil
        case .nodeUnavailable(let accountID): return accountID
        case .allDirect: return nil
        case .node(let authority): return authority.accountID
        }
    }
}

@MainActor
final class PlainpostAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // The handler must be registered before launch finishes.
        MobileBackgroundMailRefresh.shared.register()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .plainpostAPNsToken, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .plainpostAPNsRegistrationFailed, object: error)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let request = MobileNotificationOpenRequest(userInfo: response.notification.request.content.userInfo) {
            // A tap that launched the app can arrive before the mail screen listens.
            MobileNotificationTaps.pending = request
            NotificationCenter.default.post(name: .plainpostNotificationTapped, object: request)
        }
        completionHandler()
    }

    /// While Plainpost is open, an alert still shows as a banner (the mail may be for another
    /// screen than the one in view), quietly.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// The tap that launched the app, until the mail screen opens it.
@MainActor
enum MobileNotificationTaps {
    static var pending: MobileNotificationOpenRequest?
}

/// Keeps Direct mail, and its new-mail alerts, current while Plainpost is in the background.
/// iOS decides when the refresh runs (usually no more than a few times an hour, less for an
/// app that is rarely opened), so an alert can follow its message by a while.
@MainActor
final class MobileBackgroundMailRefresh {
    static let shared = MobileBackgroundMailRefresh()
    /// How long after its arrival a message found by a refresh still alerts.
    static let alertWindow: TimeInterval = 24 * 60 * 60
    private static let earliestInterval: TimeInterval = 15 * 60

    /// Builds a device-wide runtime when the app was launched just for the refresh.
    var makeRuntime: (() throws -> PlainpostAppRuntime)?
    /// The mail screen's runtime, while the app still holds one.
    weak var activeRuntime: PlainpostAppRuntime?

    private var identifier: String {
        (Bundle.main.bundleIdentifier ?? "com.marynavdovenko.Plainpost.iOS") + ".mail-refresh"
    }

    func register() {
        SQLiteMailStore.newMailNotificationWindow = Self.alertWindow
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                MobileBackgroundMailRefresh.shared.run(refresh)
            }
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.earliestInterval)
        // Fails only where background refresh is unavailable (Simulator, or turned off).
        try? BGTaskScheduler.shared.submit(request)
    }

    private func run(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in await refresh() }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            task.setTaskCompleted(success: await work.value)
        }
    }

    private func refresh() async -> Bool {
        if let activeRuntime { return await activeRuntime.refreshDirectMailInBackground() }
        guard let runtime = try? makeRuntime?() else { return false }
        let synced = await runtime.refreshDirectMailInBackground()
        await runtime.shutdown()
        return synced
    }
}

@main
struct PlainpostApp: App {
    @UIApplicationDelegateAdaptor(PlainpostAppDelegate.self) private var appDelegate
    @StateObject private var siteIconDirectory = SiteIconDirectoryModel.system()
    @StateObject private var accountLaunchModel: MobileAccountLaunchModel
    @StateObject private var centralServerSetupModel: CentralServerSetupViewModel
    @StateObject private var contactDirectory: ContactDirectoryModel
    @State private var showsPlainpostAccount = false
    @State private var localSelectedAccountID: AccountID?
    @State private var localTransitionError: String?
    @State private var localRouteAttempt = 0
    @State private var localNodePreparationAttempt = 0
    /// Bumped to add the Sync Node's accounts to the device's catalog again.
    @State private var localNodeAccountsAttempt = 0
    @State private var localAccountSwitchBlocked = false
    @State private var localNodeAttachInProgress = false
    @StateObject private var notificationPermission = NotificationPermissionModel()
    @Environment(\.scenePhase) private var scenePhase
    private let localLaunchModel: MobileLocalMailLaunchModel
    private let localNodeBroker: NodeSessionBroker?
    private let accountCredentials: AccountCredentialStore
    private let usesDebugAccountFlow: Bool

    init() {
        #if DEBUG
        // Before this launch seeds its own UI-acceptance fixture, clear out any left by a
        // previous one: each seeds a fresh UUID-named directory and never removes it. Ledger
        // Task 8.
        DebugUIAcceptanceFixtures.removeStale()
        let debugAccountFlow = ProcessInfo.processInfo.environment.keys.contains {
            ["PLAINPOST_SIGNED_OUT_UI_ACCEPTANCE", "PLAINPOST_MAILBOX_UI_ACCEPTANCE", "PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"].contains($0)
        }
        #else
        let debugAccountFlow = false
        #endif
        usesDebugAccountFlow = debugAccountFlow
        let credentials = AccountCredentialStore()
        accountCredentials = credentials
        let configurationStore = KeychainCentralServerConfigurationStore()
        let broker = try? NodeSessionBroker.production(
            credentials: credentials,
            endpointStore: MobileAccountModel.makeSyncNodeEndpointStore(),
            discoveryRemote: {
                guard case .configured(let server) = CentralServerConfigurationResolver(
                    store: configurationStore
                ).resolve(credentials: credentials) else {
                    throw AccountRuntimeError.untrustedResponse
                }
                #if targetEnvironment(simulator)
                let manifest = try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore())
                #else
                let manifest = try BootstrapKeyManifestStore()
                #endif
                return try AccountAPIClient(
                    credentialStore: credentials, manifestStore: manifest, baseURL: server.origin
                )
            }
        )
        localNodeBroker = broker
        let launchModel: MobileAccountLaunchModel
        #if DEBUG
        if ProcessInfo.processInfo.environment["PLAINPOST_SIGNED_OUT_UI_ACCEPTANCE"] == "1" {
            launchModel = Self.debugLaunchModel(factory: { .debugSignedOut() })
        } else if ProcessInfo.processInfo.environment["PLAINPOST_MAILBOX_UI_ACCEPTANCE"] == "1" {
            launchModel = Self.debugLaunchModel(factory: { .debugAuthorized() })
        } else if ProcessInfo.processInfo.environment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] == "1" {
            launchModel = Self.debugLaunchModel(factory: { .debugTwoAccountNode() })
        } else {
            launchModel = Self.productionLaunchModel(credentials: credentials, nodeBroker: broker)
        }
        #else
        launchModel = Self.productionLaunchModel(credentials: credentials, nodeBroker: broker)
        #endif
        #if DEBUG
        if let rawID = ProcessInfo.processInfo.environment["PLAINPOST_APPROVAL_QUEUE_UI_ACCEPTANCE"],
           let acceptanceID = UUID(uuidString: rawID) {
            let directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Plainpost-approval-acceptance-\(acceptanceID.uuidString)", isDirectory: true)
            let databaseURL = IOSLocalDatabaseProtection.databaseURL(in: directory)
            do {
                try DebugApprovalQueueFixture.seed(databaseURL: databaseURL)
            } catch {
                fatalError("Approval Queue UI fixture could not be seeded: \(error)")
            }
            localLaunchModel = MobileLocalMailLaunchModel(
                databaseURL: databaseURL,
                nodeAuthority: { [weak launchModel] _ in launchModel?.accountModel?.mailAuthority }
            )
        } else if let rawID = ProcessInfo.processInfo.environment["PLAINPOST_LOCAL_SEARCH_UI_ACCEPTANCE"],
                  let acceptanceID = UUID(uuidString: rawID) {
            let directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Plainpost-search-acceptance-\(acceptanceID.uuidString)", isDirectory: true)
            let databaseURL = IOSLocalDatabaseProtection.databaseURL(in: directory)
            do {
                try DebugLocalSearchFixture.seed(databaseURL: databaseURL)
            } catch {
                fatalError("Local search UI fixture could not be seeded: \(error)")
            }
            localLaunchModel = MobileLocalMailLaunchModel(databaseURL: databaseURL)
        } else if let rawID = ProcessInfo.processInfo.environment["PLAINPOST_REALISTIC_MAIL_UI_ACCEPTANCE"],
                  let acceptanceID = UUID(uuidString: rawID) {
            let directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Plainpost-realistic-acceptance-\(acceptanceID.uuidString)", isDirectory: true)
            let databaseURL = IOSLocalDatabaseProtection.databaseURL(in: directory)
            do {
                // Two local accounts, starting on the first: a previous run's switch is forgotten.
                let secondAccount = ProcessInfo.processInfo.environment["PLAINPOST_UI_TEST_SECOND_LOCAL_ACCOUNT"] == "1"
                if secondAccount {
                    UserDefaults.standard.removeObject(forKey: "plainpost.ios.selected-provider-account")
                }
                try DebugRealisticMailFixture.seed(
                    databaseURL: databaseURL,
                    secondAccount: secondAccount,
                    verificationCodeMail: ProcessInfo.processInfo.environment["PLAINPOST_UI_TEST_VERIFICATION_CODE_MAIL"] == "1"
                )
            } catch {
                fatalError("Realistic mail UI fixture could not be seeded: \(error)")
            }
            localLaunchModel = MobileLocalMailLaunchModel(databaseURL: databaseURL)
        } else if let rawID = ProcessInfo.processInfo.environment["PLAINPOST_ASK_MAIL_UI_ACCEPTANCE"],
                  let acceptanceID = UUID(uuidString: rawID) {
            let directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Plainpost-ask-mail-acceptance-\(acceptanceID.uuidString)", isDirectory: true)
            let databaseURL = IOSLocalDatabaseProtection.databaseURL(in: directory)
            do {
                try DebugAskMailFixture.seed(databaseURL: databaseURL)
            } catch {
                fatalError("Ask Mail UI fixture could not be seeded: \(error)")
            }
            localLaunchModel = MobileLocalMailLaunchModel(databaseURL: databaseURL)
        } else if let acceptanceID = ProcessInfo.processInfo.environment["PLAINPOST_LOCAL_MAIL_UI_ACCEPTANCE"] {
            let directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Plainpost-local-acceptance-\(acceptanceID)", isDirectory: true)
            localLaunchModel = MobileLocalMailLaunchModel(
                databaseURL: IOSLocalDatabaseProtection.databaseURL(in: directory),
                nodeAuthority: { [weak launchModel] _ in launchModel?.accountModel?.mailAuthority }
            )
        } else if ProcessInfo.processInfo.environment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] == "1" {
            // The fixture Sync Node's accounts, mirrored into a fresh database like a phone's.
            let directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Plainpost-node-acceptance-\(UUID().uuidString)", isDirectory: true)
            localLaunchModel = MobileLocalMailLaunchModel(databaseURL: IOSLocalDatabaseProtection.databaseURL(in: directory))
        } else {
            localLaunchModel = Self.productionLocalLaunchModel(nodeBroker: broker)
        }
        // Every fixture launched with the fixture Sync Node (the approval fixture too) mirrors it.
        if ProcessInfo.processInfo.environment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] == "1" {
            let sender = DebugTwoAccountNodeSender.fromEnvironment()
            localLaunchModel.nodeBroker = NodeSessionBroker(resolveSender: {
                (DebugTwoAccountNodeSender.nodeID, sender)
            })
        }
        #else
        localLaunchModel = Self.productionLocalLaunchModel(nodeBroker: broker)
        #endif
        MobileBackgroundMailRefresh.shared.makeRuntime = { [localLaunchModel] in
            try localLaunchModel.makeLocalRuntime()
        }
        _accountLaunchModel = StateObject(wrappedValue: launchModel)
        _centralServerSetupModel = StateObject(wrappedValue: CentralServerSetupViewModel { [weak launchModel] origin in
            await launchModel?.save(originText: origin)
            if let server = launchModel?.selectedServer { return .configured(server) }
            if let repair = launchModel?.repair { return .repairRequired(repair) }
            return .setupRequired
        })
        #if DEBUG
        if ProcessInfo.processInfo.environment["PLAINPOST_CONTACT_AUTOCOMPLETE_UI_ACCEPTANCE"] == "1" {
            _contactDirectory = StateObject(wrappedValue: .contactAutocompleteAcceptancePreview())
        } else {
            let usesUIFixtureContacts = debugAccountFlow
                || ProcessInfo.processInfo.environment["PLAINPOST_LOCAL_MAIL_UI_ACCEPTANCE"] != nil
                || ProcessInfo.processInfo.environment["PLAINPOST_APPROVAL_QUEUE_UI_ACCEPTANCE"] != nil
                || ProcessInfo.processInfo.environment["PLAINPOST_REALISTIC_MAIL_UI_ACCEPTANCE"] != nil
            _contactDirectory = StateObject(wrappedValue: usesUIFixtureContacts ? .designPreview() : .system())
        }
        #else
        _contactDirectory = StateObject(wrappedValue: .system())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !usesDebugAccountFlow && !showsPlainpostAccount {
                    localMailRoot
                } else if accountLaunchModel.isChangingServer {
                    ProgressView("Changing Server…")
                } else if let accountModel = accountLaunchModel.accountModel {
                    // The Plainpost Account's sign-in, approval and prompts. Once the account is
                    // active, its Sync Node accounts are in the one mail root with every other
                    // account; its root mirrors them when it appears.
                    MobileAccountRootView(
                        model: accountModel,
                        changeServer: accountLaunchModel.canChangeServer && accountModel.presentation == .signInRequired ? {
                            Task { await accountLaunchModel.changeServer() }
                        } : nil
                    ) { _, _ in
                        localMailRoot
                    }
                    .task { accountModel.prepare() }
                    #if DEBUG
                    .modifier(DebugNodeMutationLog(isEnabled: ProcessInfo.processInfo.environment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] == "1"))
                    #endif
                } else {
                    CentralServerSetupView(
                        model: centralServerSetupModel,
                        repair: accountLaunchModel.repair,
                        cancel: accountLaunchModel.canCancelServerChange ? { accountLaunchModel.cancelChangeServer() } : nil
                    )
                }
            }
            // The first message opened shouldn't wait for WebKit to start.
            .task { HTMLMessageWebViewPool.prewarm() }
            .safeAreaInset(edge: .top) {
                if !usesDebugAccountFlow && showsPlainpostAccount {
                    HStack {
                        Button("Back to mail") { showsPlainpostAccount = false }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .mailSiteIconDirectory(siteIconDirectory)
            .onReceive(NotificationCenter.default.publisher(for: .plainpostAPNsToken)) { notification in
                guard let token = notification.object as? Data else { return }
                accountLaunchModel.accountModel?.didRegisterForRemoteNotifications(deviceToken: token)
            }
            .onReceive(NotificationCenter.default.publisher(for: .plainpostAPNsRegistrationFailed)) { notification in
                guard let error = notification.object as? Error else { return }
                accountLaunchModel.accountModel?.didFailToRegisterForRemoteNotifications(error: error)
            }
            .onReceive(NotificationCenter.default.publisher(for: .plainpostNotificationTapped)) { notification in
                guard let request = notification.object as? MobileNotificationOpenRequest else { return }
                if let accountModel = accountLaunchModel.accountModel {
                    accountModel.handleNotificationTap(request)
                } else {
                    NotificationCenter.default.post(name: .plainpostOpenNotification, object: request)
                }
            }
            .notificationPermission(notificationPermission)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { MobileBackgroundMailRefresh.shared.schedule() }
            }
            .mailContactDirectory(contactDirectory)
        }
    }

    @ViewBuilder
    private var localMailRoot: some View {
        let routeResult = localRouteResult
        VStack(spacing: 0) {
            switch routeResult {
            case .success(let route):
                if let localTransitionError {
                    Text(localTransitionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if localNodeAttachInProgress {
                    ProgressView("Checking Sync Node…")
                }
                if case .nodeUnavailable = route {
                    Button("Retry Sync Node") { localNodePreparationAttempt += 1 }
                        .accessibilityIdentifier("local-mail.retry-node")
                }
                MobileMailRootView(
                    readOnlyReason: localNodeReadOnlyReason(route),
                    // The Plainpost Account, once connected, for its Settings pages, push rows and
                    // notification features. Its Sync Node accounts' mail is in this runtime.
                    accountModel: connectedAccountModel,
                    providerController: connectedAccountModel?.syncNodeProviderController,
                    route: route,
                    localLaunchModel: localLaunchModel,
                    contactDirectory: contactDirectory,
                    // Not offered while a switch is blocked or an attach is already running.
                    // Attaches the account page's account: selecting it keeps the device-wide
                    // route (a Direct selection opens every Direct account) and names the
                    // account the attach flow moves.
                    useSyncNodeForAccount: localOffersSyncNode(route) && !localAccountSwitchBlocked && !localNodeAttachInProgress
                        ? { accountID in if selectLocalAccount(accountID) { attachSelectedDirectAccount() } } : nil,
                    connectPlainpostAccount: {
                        accountLaunchModel.start()
                        showsPlainpostAccount = true
                    },
                    onLocalAccountSetupConnected: { accountID in
                        selectLocalAccount(accountID)
                    },
                    onLocalAccountSwitchBlockedChanged: { blocked in
                        localAccountSwitchBlocked = blocked
                    }
                )
            case .failure(let error):
                ContentUnavailableView {
                    Label("Mail unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try again") {
                        localRouteAttempt += 1
                        localNodePreparationAttempt += 1
                    }
                        .accessibilityIdentifier("local-mail.retry-route")
                }
            }
        }
        .onReceive(MailStoreChangeSignal.mainThreadChanges) { scope in
            guard scope == .accounts || scope == .all else { return }
            Task { @MainActor in
                // The first accounts, added from the Sync Node, open the mail.
                if case .success(.localSetup) = localRouteResult { localRouteAttempt += 1 }
            }
        }
        .task(id: localNodeAccountsAttempt) {
            // A device whose accounts are all on its Sync Node has nothing else to open.
            if await localLaunchModel.addSyncNodeAccounts() { localRouteAttempt += 1 }
        }
        .task(id: "\(localSelectedAccountID?.rawValue ?? ""):\(localNodePreparationAttempt)") {
            guard let localNodeBroker,
                  case .success(.nodeUnavailable) = routeResult else { return }
            do {
                try await localLaunchModel.prepareSelectedNodeAuthority(
                    broker: localNodeBroker, credentials: accountCredentials
                )
            } catch {
                // The selected Node route stays unavailable until a later retry.
            }
            localRouteAttempt += 1
        }
    }

    private func localOffersSyncNode(_ route: MobileMailRoute) -> Bool {
        if case .allDirect = route, localNodeBroker != nil { return true }
        return false
    }

    /// Names the account the attach flow moves, or the account just set up.
    @discardableResult
    private func selectLocalAccount(_ accountID: AccountID) -> Bool {
        do {
            try localLaunchModel.selectAccountID(accountID)
            localTransitionError = nil
            localSelectedAccountID = accountID
            return true
        } catch {
            localTransitionError = error.localizedDescription
            return false
        }
    }

    /// The Plainpost Account once it is connected and active. Inside the account root the
    /// mail shows only while the account is active, so it is passed as soon as it exists.
    private var connectedAccountModel: MobileAccountModel? {
        guard let model = accountLaunchModel.accountModel else { return nil }
        if usesDebugAccountFlow || showsPlainpostAccount { return model }
        switch model.presentation {
        case .active, .offlineLease: return model
        default: return nil
        }
    }

    private var localRouteResult: Result<MobileMailRoute, Error> {
        Result {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PLAINPOST_LOCAL_ROUTE_FAIL_ONCE"] == "1",
               localRouteAttempt == 0 {
                throw PlainpostError.permissionDenied("Temporary local mail error.")
            }
            #endif
            _ = localRouteAttempt
            let accountID = try localSelectedAccountID ?? localLaunchModel.selectedAccountID()
            return try localLaunchModel.route(for: accountID)
        }
    }

    private func localNodeReadOnlyReason(_ route: MobileMailRoute) -> MobileReadOnlyReason? {
        #if DEBUG
        // Opens the Direct accounts' cached mail read-only, as an offline lease
        // does, for read-only UI acceptance.
        if ProcessInfo.processInfo.environment["PLAINPOST_UI_TEST_READ_ONLY_MAIL"] == "1",
           case .allDirect = route {
            return .offlineLease(expiresAt: nil)
        }
        #endif
        // The broker admits a Node session read-only only by its offline lease.
        if case .node = route, localLaunchModel.selectedNodeIsReadOnly {
            return .offlineLease(expiresAt: localLaunchModel.selectedNodeLeaseExpiry)
        }
        return nil
    }


    private func attachSelectedDirectAccount() {
        guard let broker = localNodeBroker,
              !localAccountSwitchBlocked, !localNodeAttachInProgress else { return }
        localNodeAttachInProgress = true
        localTransitionError = nil
        Task { @MainActor in
            do {
                #if targetEnvironment(simulator)
                let manifestSecrets: any AccountSecretStoring = InMemoryAccountSecretStore()
                #else
                let manifestSecrets: any AccountSecretStoring = KeychainAccountSecretStore()
                #endif
                let manifest = try SessionKeyManifestStore(
                    bundledDocument: SessionKeyManifestStore.bundledManifest,
                    offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
                    offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
                    secretStore: manifestSecrets
                ).verifier()
                let endpointStore = try MobileAccountModel.makeSyncNodeEndpointStore()
                let runtime = try await localLaunchModel.attachSelectedDirectAccount(
                    broker: broker, accountCredentials: accountCredentials,
                    endpointStore: endpointStore, manifest: manifest
                )
                await runtime?.shutdown()
                localRouteAttempt += 1
                localNodePreparationAttempt += 1
            } catch {
                localTransitionError = "Sync Node could not be verified for this mail account. \(error.localizedDescription)"
            }
            localNodeAttachInProgress = false
        }
    }


    /// The device's mail: every Direct account, and every Sync Node account mirrored through
    /// the device's Node session.
    private static func productionLocalLaunchModel(nodeBroker: NodeSessionBroker?) -> MobileLocalMailLaunchModel {
        let model = MobileLocalMailLaunchModel()
        model.nodeBroker = nodeBroker
        return model
    }

    private static func productionLaunchModel(
        credentials: AccountCredentialStore,
        nodeBroker: NodeSessionBroker?
    ) -> MobileAccountLaunchModel {
        let configurationStore = KeychainCentralServerConfigurationStore()
        return MobileAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: configurationStore),
            store: configurationStore,
            credentials: credentials,
            resolveOnInit: false,
            makeAccountModel: { server in
                return try MobileAccountModel.production(
                    server: server, credentials: credentials, nodeBroker: nodeBroker
                )
            }
        )
    }

    #if DEBUG
    private static func debugLaunchModel(
        factory: @escaping @MainActor () -> MobileAccountModel
    ) -> MobileAccountLaunchModel {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "debug.mobile.acceptance")
        let configurationStore = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let configuration = try! CentralServerConfiguration(originText: "https://plainpost-api.olhapi.com")
        _ = try! configurationStore.installSelectionIfAbsent(configuration.canonicalSelectionRecord)
        return MobileAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: configurationStore),
            store: configurationStore,
            credentials: credentials,
            bundledDocument: nil,
            makeAccountModel: { _ in factory() }
        )
    }
    #endif
}

