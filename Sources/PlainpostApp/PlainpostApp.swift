import SwiftUI
import PlainpostCore
import PlainpostAccountRuntime
#if DEBUG
@_spi(DesignPreview) import PlainpostUI
#else
import PlainpostUI
#endif
import AppKit
import Combine
import Network
import ServiceManagement
@preconcurrency import UserNotifications

#if DEBUG
@MainActor
enum PlainpostDebugMailboxUIAcceptance {
    static let environmentKey = "PLAINPOST_MAILBOX_UI_ACCEPTANCE"
    static let initialInboxMode = InboxDisplayMode.focusedList
    static let initialSmartInboxBundle: SmartInboxDisplayBundle? = nil
    static let composerPresentationPolicy = ComposerPresentationPolicy.snapshotWindow

    enum Error: Swift.Error, Equatable {
        case invalidValue
        case conflictsWithSyncAcceptance
    }

    static func resolve(
        environment: [String: String],
        syncAcceptanceConfigured: Bool = false
    ) throws -> Bool {
        guard let value = environment[environmentKey] else {
            return false
        }
        guard value == "1" else {
            throw Error.invalidValue
        }
        guard !syncAcceptanceConfigured else {
            throw Error.conflictsWithSyncAcceptance
        }
        return true
    }
}

@MainActor
enum PlainpostDebugMailboxScrollProfile {
    static let environmentKey = "PLAINPOST_MAILBOX_SCROLL_PROFILE"

    static func resolve(environment: [String: String]) throws -> Bool {
        guard let rawValue = environment[environmentKey] else { return false }
        guard rawValue == "1" else {
            throw PlainpostDebugMailboxUIAcceptance.Error.invalidValue
        }
        return true
    }
}

@MainActor
enum PlainpostDebugWindowlessAcceptance {
    static func shouldConfigure(environment: [String: String]) -> Bool {
        environment["PLAINPOST_ACCEPTANCE_MODE"] != "smart-inbox"
    }

    static func perform(
        closeUserFacingWindows: () -> Void,
        userFacingWindowCount: () -> Int,
        setAccessoryPolicy: () -> Void,
        writeStatus: () throws -> Void
    ) async throws {
        closeUserFacingWindows()
        setAccessoryPolicy()
        for _ in 0..<100 {
            if userFacingWindowCount() == 0 {
                try writeStatus()
                return
            }
            closeUserFacingWindows()
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }
}

@MainActor
struct PlainpostApplicationPresentationDependencies {
    let contactDirectory: ContactDirectoryModel
    let siteIconDirectory: SiteIconDirectoryModel

    static func debugAcceptance(
        rootURL: URL,
        makeSystemContacts: () -> ContactDirectoryModel = { .system() },
        makeSystemSiteIcons: () -> SiteIconDirectoryModel = { .system() }
    ) throws -> Self {
        // The factories are intentionally accepted for an observable contract:
        // a fully resolved acceptance configuration must never call them.
        _ = makeSystemContacts
        _ = makeSystemSiteIcons
        return Self(
            contactDirectory: .designPreview(),
            siteIconDirectory: try .debugAcceptance(rootURL: rootURL)
        )
    }
}
#endif
@MainActor
final class PlainpostApplicationPresenceController {
    private let currentActivationPolicy: () -> NSApplication.ActivationPolicy
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let hasUserFacingWindow: () -> Bool
    private let activateAfterPresentation: () -> Void

    init(
        currentActivationPolicy: @escaping () -> NSApplication.ActivationPolicy = {
            NSApp.activationPolicy()
        },
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = {
            NSApp.setActivationPolicy($0)
        },
        hasUserFacingWindow: @escaping () -> Bool = {
            PlainpostApplicationPresence.hasUserFacingWindow(in: NSApp.windows)
        },
        activateAfterPresentation: @escaping () -> Void = {
            DispatchQueue.main.async {
                NSApp.activate()
            }
        }
    ) {
        self.currentActivationPolicy = currentActivationPolicy
        self.setActivationPolicy = setActivationPolicy
        self.hasUserFacingWindow = hasUserFacingWindow
        self.activateAfterPresentation = activateAfterPresentation
    }

    func prepareForWindowPresentation() {
        setActivationPolicyIfNeeded(.regular)
    }

    func activatePresentedWindow() {
        activateAfterPresentation()
    }

    func presentWindow(_ action: () -> Void) {
        prepareForWindowPresentation()
        action()
        activatePresentedWindow()
    }

    func reconcileActivationPolicy() {
        setActivationPolicyIfNeeded(hasUserFacingWindow() ? .regular : .accessory)
    }

    /// Menu bar only: no Dock icon and no window.
    func enterBackground() {
        setActivationPolicyIfNeeded(.accessory)
    }

    var hasPresentedWindow: Bool {
        hasUserFacingWindow()
    }

    private func setActivationPolicyIfNeeded(_ policy: NSApplication.ActivationPolicy) {
        guard currentActivationPolicy() != policy else {
            return
        }
        setActivationPolicy(policy)
    }
}

@MainActor
final class PlainpostApplicationDelegate: NSObject, NSApplicationDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
{
    private let presenceController: PlainpostApplicationPresenceController
    private let installNotificationDelegate: (any UNUserNotificationCenterDelegate) -> Void
    /// Set by the bundled login item: start hidden, with no window.
    let isLoginLaunch: Bool
    private let openMailboxOverride: (() -> Void)?
    private let initialWindowCheckDelay: TimeInterval
    private var attentionObserver: NSObjectProtocol?
    private var attentionContexts: [UUID: PlainpostNotificationAttentionContext] = [:]
    private var notificationOpenHandler: ((String) -> Void)?
    private var pendingNotificationOpenTokens: [String] = []

    override init() {
        presenceController = PlainpostApplicationPresenceController()
        installNotificationDelegate = { delegate in
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            UNUserNotificationCenter.current().delegate = delegate
        }
        isLoginLaunch = PlainpostLoginLaunch.isLoginLaunch(arguments: CommandLine.arguments)
        openMailboxOverride = nil
        initialWindowCheckDelay = 0.25
        super.init()
    }

    init(
        presenceController: PlainpostApplicationPresenceController,
        launchArguments: [String] = CommandLine.arguments,
        openMailbox: (() -> Void)? = nil,
        initialWindowCheckDelay: TimeInterval = 0.25,
        installNotificationDelegate: @escaping (
            any UNUserNotificationCenterDelegate
        ) -> Void = { _ in }
    ) {
        self.presenceController = presenceController
        self.installNotificationDelegate = installNotificationDelegate
        isLoginLaunch = PlainpostLoginLaunch.isLoginLaunch(arguments: launchArguments)
        openMailboxOverride = openMailbox
        self.initialWindowCheckDelay = initialWindowCheckDelay
        super.init()
    }

    /// A login launch suppresses the mailbox scene SwiftUI would otherwise
    /// present at launch.
    static func presentsMailboxAtLaunch(arguments: [String]) -> Bool {
        !PlainpostLoginLaunch.isLoginLaunch(arguments: arguments)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // As early as possible, so a login launch never shows a Dock icon.
        if isLoginLaunch {
            presenceController.enterBackground()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installNotificationDelegate(self)
        attentionObserver = NotificationCenter.default.addObserver(
            forName: .plainpostNotificationAttentionUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let update = notification.object as? PlainpostNotificationAttentionUpdate else {
                return
            }
            Task { @MainActor in self?.apply(update) }
        }
        if isLoginLaunch {
            // Menu bar only. The account session, runtime and notification
            // delivery start without a window; reopening from the Dock,
            // Finder or the menu bar presents the mailbox.
            presenceController.enterBackground()
        } else {
            prepareForWindowPresentation()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        guard !isLoginLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + initialWindowCheckDelay) {
            guard !self.presenceController.hasPresentedWindow else {
                return
            }

            // Early SwiftPM bundles wrote an AppKit restoration record without
            // a restoration class. If that migration record suppresses the
            // default scene, invoke SwiftUI's own mailbox command so the system
            // still creates and owns the window, toolbar, and scene lifecycle.
            self.openMailbox()
        }
    }

    private func openMailbox() {
        if let openMailboxOverride {
            openMailboxOverride()
        } else {
            openMailboxUsingApplicationCommand()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        prepareForWindowPresentation()
        if let window = sender.windows.first(where: PlainpostApplicationPresence.isUserFacingWindow) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        // Returning true lets SwiftUI reopen its default mailbox scene when no
        // content window exists. Sending the mailbox command here as well would
        // race that system path and create two windows.
        activateAfterWindowPresentation()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let attentionObserver {
            NotificationCenter.default.removeObserver(attentionObserver)
            self.attentionObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    func setNotificationOpenHandler(_ handler: @escaping (String) -> Void) {
        notificationOpenHandler = handler
        let queued = pendingNotificationOpenTokens
        pendingNotificationOpenTokens.removeAll(keepingCapacity: false)
        queued.forEach(handler)
    }

    func handleNotificationOpenToken(_ token: String) {
        guard !token.isEmpty, token.utf8.count <= 256,
              !token.contains(where: { $0 == "\0" || $0.isNewline }) else {
            return
        }
        if let notificationOpenHandler {
            notificationOpenHandler(token)
        } else {
            pendingNotificationOpenTokens.append(token)
        }
        prepareForWindowPresentation()
        openMailboxUsingApplicationCommand()
        activateAfterWindowPresentation()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        let token = notification.request.content.userInfo["plainpost.openToken"] as? String
        let policy = PlainpostNotificationPresentationPolicy.resolve(
            isApplicationActive: NSApp.isActive,
            openToken: token,
            contexts: Array(attentionContexts.values),
            playsSound: notification.request.content.sound != nil
        )
        var options: UNNotificationPresentationOptions = []
        if policy.showsBanner { options.insert(.banner) }
        if policy.addsToList { options.insert(.list) }
        if policy.playsSound { options.insert(.sound) }
        completionHandler(options)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let token = response.notification.request.content.userInfo[
            "plainpost.openToken"
        ] as? String {
            handleNotificationOpenToken(token)
        }
        completionHandler()
    }

    private func apply(_ update: PlainpostNotificationAttentionUpdate) {
        switch update {
        case .set(let sourceID, let context):
            attentionContexts[sourceID] = context
        case .remove(let sourceID):
            attentionContexts[sourceID] = nil
        }
    }

    func prepareForWindowPresentation() {
        presenceController.prepareForWindowPresentation()
    }

    func activateAfterWindowPresentation() {
        presenceController.activatePresentedWindow()
    }

    func presentWindow(_ action: () -> Void) {
        presenceController.presentWindow(action)
    }

    private func openMailboxUsingApplicationCommand() {
        guard let item = Self.menuItem(titled: "Open Mailbox Window", in: NSApp.mainMenu),
              let action = item.action else {
            return
        }
        presentWindow {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.reconcileActivationPolicy()
        }
    }

    @objc
    private func windowDidBecomeMain(_ notification: Notification) {
        prepareForWindowPresentation()
    }

    private func reconcileActivationPolicy() {
        presenceController.reconcileActivationPolicy()
    }

    private static func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else {
            return nil
        }
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let match = menuItem(titled: title, in: item.submenu) {
                return match
            }
        }
        return nil
    }
}

/// Runs before any model exists. The login item's own launch leaves an
/// already-running Plainpost alone (registering the item starts one extra
/// copy), and removes a login item the user turned off.
@MainActor
enum PlainpostLoginLaunchStartup {
    /// Held for the life of the process.
    private static var instanceLock: PlainpostInstanceLock?

    static func resolve(arguments: [String] = CommandLine.arguments) {
        let isLoginLaunch = PlainpostLoginLaunch.isLoginLaunch(arguments: arguments)
        defer { holdInstanceLock(isLoginLaunch: isLoginLaunch) }
        guard isLoginLaunch else { return }
        let decision = PlainpostLoginLaunch.startupDecision(
            arguments: arguments,
            otherInstanceRunning: anotherInstanceIsRunning(),
            openAtLogin: PlainpostLoginLaunch.openAtLogin(in: .standard)
        )
        switch decision {
        case .run:
            return
        case .yield:
            exit(0)
        case .retire:
            // This process is the job's own; unregistering ends it.
            try? SMAppService.agent(plistName: PlainpostLoginLaunch.plistName).unregister()
            exit(0)
        }
    }

    /// A second hidden login launch that raced past the running-instance
    /// check exits here, so two hidden copies never both run a runtime.
    /// (Each new-mail event is also leased in SQLite, so two processes
    /// could not post the same notification twice.) A manual launch keeps
    /// running without the lock.
    private static func holdInstanceLock(isLoginLaunch: Bool) {
        let url = PlainpostAppRuntimeConfiguration.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("app-instance.lock")
        instanceLock = PlainpostInstanceLock.acquire(at: url)
        if instanceLock == nil, isLoginLaunch {
            exit(0)
        }
    }

    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != current && !$0.isTerminated }
    }
}

enum PlainpostWindowToolbarConfiguration {
    static let mailboxShowsTitle = false
    static let composeShowsTitle = true
    static let settingsShowsTitle = true
}

@main
struct PlainpostApplication: App {
    @NSApplicationDelegateAdaptor(PlainpostApplicationDelegate.self) private var appDelegate
    @AppStorage("Plainpost.smartInbox.enabled") private var smartInboxEnabled = true
    @StateObject private var applicationModel: PlainpostApplicationModel
    @StateObject private var accountLaunchModel: PlainpostAccountLaunchModel
    @StateObject private var centralServerSetupModel: CentralServerSetupViewModel
    @StateObject private var contactDirectory: ContactDirectoryModel
    @StateObject private var siteIconDirectory: SiteIconDirectoryModel
    /// Owns the runtime while no window is open; nil in UI acceptance.
    private let runtimeLifetime: PlainpostRuntimeLifetime?
    private let loginItemModel: PlainpostLoginItemModel?
    private let sessionRecovery: PlainpostSessionRecoveryTriggers?
    private static let presentsMailboxAtLaunch =
        PlainpostApplicationDelegate.presentsMailboxAtLaunch(arguments: CommandLine.arguments)
#if DEBUG
    private let mailboxUIAcceptanceEnabled: Bool
    private let mailboxScrollProfileEnabled: Bool
#endif

    init() {
        PlainpostLoginLaunchStartup.resolve()
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let mailboxUIAcceptance: Bool
        do {
            mailboxUIAcceptance = try PlainpostDebugMailboxUIAcceptance.resolve(
                environment: environment,
                syncAcceptanceConfigured: false
            )
        } catch {
            preconditionFailure("Invalid Plainpost Debug mailbox UI acceptance configuration")
        }
        let mailboxScrollProfile: Bool
        do {
            mailboxScrollProfile = try PlainpostDebugMailboxScrollProfile.resolve(
                environment: environment
            )
        } catch {
            preconditionFailure("Invalid Plainpost Debug mailbox scroll profile configuration")
        }
        mailboxUIAcceptanceEnabled = mailboxUIAcceptance || mailboxScrollProfile
        mailboxScrollProfileEnabled = mailboxScrollProfile
        if mailboxUIAcceptanceEnabled {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Plainpost-MailboxUIAcceptance-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            do {
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: rootURL.path
                )
                let presentationDependencies =
                    try PlainpostApplicationPresentationDependencies.debugAcceptance(
                        rootURL: rootURL
                    )
                _applicationModel = StateObject(
                    wrappedValue: .debugMailboxUIAcceptance()
                )
                let secrets = InMemoryAccountSecretStore()
                let configuration = try CentralServerConfiguration(originText: "https://plainpost-api.olhapi.com")
                let configurationStore = KeychainCentralServerConfigurationStore(secretStore: secrets)
                _ = try configurationStore.installSelectionIfAbsent(configuration.canonicalSelectionRecord)
                let credentials = AccountCredentialStore(secretStore: secrets, service: "debug.mailbox.acceptance")
                let launchModel = PlainpostAccountLaunchModel(
                    resolver: CentralServerConfigurationResolver(store: configurationStore),
                    store: configurationStore,
                    credentials: credentials,
                    bundledDocument: nil,
                    makeAccountModel: { _ in .debugAuthorized() }
                )
                _accountLaunchModel = StateObject(wrappedValue: launchModel)
                _centralServerSetupModel = StateObject(wrappedValue: CentralServerSetupViewModel { [weak launchModel] origin in
                    await launchModel?.save(originText: origin)
                    return launchModel?.selectedServer.map(CentralServerResolution.configured) ?? .setupRequired
                })
                _contactDirectory = StateObject(
                    wrappedValue: presentationDependencies.contactDirectory
                )
                _siteIconDirectory = StateObject(
                    wrappedValue: presentationDependencies.siteIconDirectory
                )
                runtimeLifetime = nil
                loginItemModel = nil
                sessionRecovery = nil
            } catch {
                preconditionFailure("Invalid Plainpost Debug mailbox UI acceptance storage")
            }
        } else {
            let applicationModel = PlainpostApplicationModel(startsImmediately: false)
            _applicationModel = StateObject(wrappedValue: applicationModel)
            let credentials = AccountCredentialStore(accessGroup: PlainpostAccountSharedKeychain.accessGroup)
            let nodeSessionClient = applicationModel.nodeSessionClient
            let configurationStore = KeychainCentralServerConfigurationStore(
                accessGroup: PlainpostAccountSharedKeychain.accessGroup
            )
            let launchModel = PlainpostAccountLaunchModel(
                resolver: CentralServerConfigurationResolver(store: configurationStore),
                store: configurationStore,
                credentials: credentials,
                makeAccountModel: { server in
                    try AccountSessionViewModel.production(
                        server: server,
                        credentials: credentials,
                        nodeSessionClient: nodeSessionClient,
                        purgeManagedData: { _ in try await applicationModel.purgePlainpostManagedData() }
                    )
                }
            )
            _accountLaunchModel = StateObject(wrappedValue: launchModel)
            _centralServerSetupModel = StateObject(wrappedValue: CentralServerSetupViewModel { [weak launchModel] origin in
                await launchModel?.save(originText: origin)
                if let server = launchModel?.selectedServer { return .configured(server) }
                if let repair = launchModel?.repair { return .repairRequired(repair) }
                return .setupRequired
            })
            _contactDirectory = StateObject(wrappedValue: .system())
            _siteIconDirectory = StateObject(wrappedValue: .system())
            let background = Self.startBackgroundLifetime(
                applicationModel: applicationModel,
                launchModel: launchModel
            )
            runtimeLifetime = background.lifetime
            loginItemModel = background.loginItem
            sessionRecovery = background.recovery
        }
#else
        let applicationModel = PlainpostApplicationModel(startsImmediately: false)
        _applicationModel = StateObject(wrappedValue: applicationModel)
        let credentials = AccountCredentialStore(accessGroup: PlainpostAccountSharedKeychain.accessGroup)
        let nodeSessionClient = applicationModel.nodeSessionClient
        let configurationStore = KeychainCentralServerConfigurationStore(
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )
        let launchModel = PlainpostAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: configurationStore),
            store: configurationStore,
            credentials: credentials,
            makeAccountModel: { server in
                try AccountSessionViewModel.production(
                    server: server,
                    credentials: credentials,
                    nodeSessionClient: nodeSessionClient,
                    purgeManagedData: { _ in try await applicationModel.purgePlainpostManagedData() }
                )
            }
        )
        _accountLaunchModel = StateObject(wrappedValue: launchModel)
        _centralServerSetupModel = StateObject(wrappedValue: CentralServerSetupViewModel { [weak launchModel] origin in
            await launchModel?.save(originText: origin)
            if let server = launchModel?.selectedServer { return .configured(server) }
            if let repair = launchModel?.repair { return .repairRequired(repair) }
            return .setupRequired
        })
        _contactDirectory = StateObject(wrappedValue: .system())
        _siteIconDirectory = StateObject(wrappedValue: .system())
        let background = Self.startBackgroundLifetime(
            applicationModel: applicationModel,
            launchModel: launchModel
        )
        runtimeLifetime = background.lifetime
        loginItemModel = background.loginItem
        sessionRecovery = background.recovery
#endif
    }

    /// The runtime follows the account session rather than the mailbox
    /// window, so closing the last window keeps notifications flowing and a
    /// hidden login launch starts them with no window at all.
    private static func startBackgroundLifetime(
        applicationModel: PlainpostApplicationModel,
        launchModel: PlainpostAccountLaunchModel
    ) -> (
        lifetime: PlainpostRuntimeLifetime,
        loginItem: PlainpostLoginItemModel,
        recovery: PlainpostSessionRecoveryTriggers
    ) {
        let isLoginLaunch = PlainpostLoginLaunch.isLoginLaunch(arguments: CommandLine.arguments)
        let lifetime = PlainpostRuntimeLifetime(applicationModel: applicationModel)
        lifetime.observe(
            launchModel.$accountModel
                .map { model -> AnyPublisher<AccountSessionViewModel.Presentation?, Never> in
                    guard let model else { return Just(nil).eraseToAnyPublisher() }
                    return model.$presentation.map(Optional.some).eraseToAnyPublisher()
                }
                .switchToLatest()
                .eraseToAnyPublisher()
        )
        if isLoginLaunch {
            // No window will prepare the session.
            launchModel.accountModel?.prepare()
        }
        let loginItem = PlainpostLoginItemModel.production(isLoginLaunch: isLoginLaunch)
        Task { @MainActor in await loginItem.reconcile() }
        // Every launch: after a manual launch's window closes, a failed
        // background refresh must recover without a window too.
        let recovery = PlainpostSessionRecoveryTriggers(launchModel: launchModel)
        return (lifetime, loginItem, recovery)
    }

    var body: some Scene {
        WindowGroup("Plainpost", id: "main") {
            Group {
#if DEBUG
            if mailboxUIAcceptanceEnabled {
                PlainpostDebugMailboxUIAcceptanceRoot(
                    scrollProfile: mailboxScrollProfileEnabled
                )
                    .mailContactDirectory(contactDirectory)
                    .mailSiteIconDirectory(siteIconDirectory)
                    .task { await contactDirectory.prepare() }
            } else {
                accountLaunchContent
            }
#else
            accountLaunchContent
#endif
            }
            .onOpenURL { url in
                accountLaunchModel.accountModel?.importSyncNodeBootstrapProfile(from: url)
            }
            .onAppear {
                appDelegate.setNotificationOpenHandler { token in
                    applicationModel.requestNotificationOpen(token: token)
                }
            }
            // The first message opened shouldn't wait for WebKit to start.
            .task { HTMLMessageWebViewPool.prewarm() }
        }
        .defaultSize(width: 1440, height: 900)
        .defaultLaunchBehavior(Self.presentsMailboxAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified(showsTitle: PlainpostWindowToolbarConfiguration.mailboxShowsTitle))
        .commands {
            if let accountSessionModel = accountLaunchModel.accountModel {
                PlainpostWindowCommands(
                    applicationDelegate: appDelegate,
                    accountSessionModel: accountSessionModel
                )
            }

            CommandGroup(replacing: .newItem) {
                Button("New Message", systemImage: "square.and.pencil") {
                    PlainpostAppCommand.compose.post()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(accountLaunchModel.accountModel?.presentation.allowsMailboxMutations != true)
            }

            CommandMenu("Navigate") {
                if smartInboxEnabled {
                    Button("Smart Inbox", systemImage: "tray.full") {
                        PlainpostAppCommand.smartInbox.post()
                    }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(accountLaunchModel.accountModel?.presentation.allowsMailbox != true)
                }

                Button("Agent Approvals", systemImage: "checkmark.shield") {
                    PlainpostAppCommand.approvalQueue.post()
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(accountLaunchModel.accountModel?.presentation.allowsMailboxMutations != true)

            }

            CommandGroup(after: .textEditing) {
                Button("Search Mail", systemImage: "magnifyingglass") {
                    PlainpostAppCommand.focusSearch.post()
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(accountLaunchModel.accountModel?.presentation.allowsMailbox != true)

                Button("Command Center", systemImage: "command") {
                    PlainpostAppCommand.commandCenter.post()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(accountLaunchModel.accountModel?.presentation.allowsMailboxMutations != true)
            }
        }

        WindowGroup("Compose", for: PlainpostComposerWindowRequest.self) { request in
            Group {
#if DEBUG
                if mailboxUIAcceptanceEnabled {
                    PlainpostDebugComposerSceneContent(
                        request: request.wrappedValue ?? .newMessage
                    )
                } else if accountLaunchModel.accountModel?.presentation.allowsMailboxMutations == true {
                    PlainpostComposerSceneRoot(
                        request: request.wrappedValue ?? .newMessage,
                        applicationModel: applicationModel
                    )
                } else {
                    AccountSceneUnavailableView(message: "An active account session is required to compose mail.")
                }
#else
                if accountLaunchModel.accountModel?.presentation.allowsMailboxMutations == true {
                    PlainpostComposerSceneRoot(
                        request: request.wrappedValue ?? .newMessage,
                        applicationModel: applicationModel
                    )
                } else {
                    AccountSceneUnavailableView(message: "An active account session is required to compose mail.")
                }
#endif
            }
            .mailContactDirectory(contactDirectory)
            .mailSiteIconDirectory(siteIconDirectory)
        }
        .defaultSize(width: 760, height: 680)
        .windowToolbarStyle(.unified(showsTitle: PlainpostWindowToolbarConfiguration.composeShowsTitle))

        Settings {
            Group {
                if let accountSessionModel = accountLaunchModel.accountModel,
                   accountSessionModel.presentation.allowsMailboxMutations {
                    PlainpostSettingsSceneRoot(
                        applicationModel: applicationModel,
                        accountSessionModel: accountSessionModel
                    )
                        .task { await contactDirectory.prepare() }
                } else {
                    VStack(spacing: 20) {
                        AccountSceneUnavailableView(message: "An active account session is required to change settings.")
                        // Offline, the mailbox is read-only but Plainpost
                        // still runs in the background, so opening at login
                        // stays adjustable.
                        if accountLaunchModel.accountModel?.presentation.allowsMailbox == true,
                           let loginItemModel {
                            PlainpostLoginItemSettingsGroup(model: loginItemModel)
                                .frame(maxWidth: 560)
                                .padding(.horizontal, 28)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            .mailContactDirectory(contactDirectory)
            .mailSiteIconDirectory(siteIconDirectory)
            .environment(\.plainpostLoginItemModel, loginItemModel)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified(showsTitle: PlainpostWindowToolbarConfiguration.settingsShowsTitle))

        MenuBarExtra {
            if let accountSessionModel = accountLaunchModel.accountModel {
                PlainpostMenuBarMenu(
                    applicationDelegate: appDelegate,
                    accountSessionModel: accountSessionModel,
                    applicationModel: applicationModel,
                    loginItemModel: loginItemModel
                )
            } else {
                Text("Open Plainpost to configure Central")
            }
        } label: {
            Image(nsImage: PlainpostMenuBarMarkImage.template)
                .accessibilityLabel("Plainpost")
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var accountLaunchContent: some View {
        if accountLaunchModel.isChangingServer {
            ProgressView("Changing Server…")
        } else if let accountSessionModel = accountLaunchModel.accountModel {
            AccountSessionRootView(
                model: accountSessionModel,
                changeServer: accountLaunchModel.canChangeServer ? {
                    Task { await accountLaunchModel.changeServer() }
                } : nil
            ) { readOnly, _ in
                PlainpostRuntimeRootView(
                    applicationModel: applicationModel,
                    accountSessionModel: accountSessionModel,
                    readOnly: readOnly
                )
            }
            .mailContactDirectory(contactDirectory)
            .mailSiteIconDirectory(siteIconDirectory)
            .task { accountSessionModel.prepare() }
            .task(id: accountSessionModel.presentation.allowsMailbox) {
                guard accountSessionModel.presentation.allowsMailbox else { return }
                await contactDirectory.prepare()
            }
        } else {
            CentralServerSetupView(
                model: centralServerSetupModel,
                repair: accountLaunchModel.repair,
                cancel: accountLaunchModel.canCancelServerChange ? { accountLaunchModel.cancelChangeServer() } : nil
            )
        }
    }
}

#if DEBUG
@MainActor
private struct PlainpostDebugMailboxUIAcceptanceRoot: View {
    private static let designNow = ISO8601DateFormatter().date(
        from: "2026-07-22T10:00:00Z"
    )!

    let scrollProfile: Bool

    var body: some View {
        PlainpostRootView(
            viewModel: scrollProfile ? .debugScrollProfilePreview() : .designPreview(),
            aiAssistant: .designPreview(),
            initialInboxMode: PlainpostDebugMailboxUIAcceptance.initialInboxMode,
            initialSmartInboxBundle:
                PlainpostDebugMailboxUIAcceptance.initialSmartInboxBundle,
            composerPresentationPolicy:
                PlainpostDebugMailboxUIAcceptance.composerPresentationPolicy,
            designNow: Self.designNow
        )
    }
}
#endif

private struct PlainpostWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let applicationDelegate: PlainpostApplicationDelegate
    @ObservedObject var accountSessionModel: AccountSessionViewModel

    var body: some Commands {
        CommandMenu("Mailbox") {
            Button("Open Mailbox Window", systemImage: "macwindow") {
                applicationDelegate.presentWindow {
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!accountSessionModel.presentation.allowsMailbox)
        }
    }
}

private struct PlainpostMenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let applicationDelegate: PlainpostApplicationDelegate
    @ObservedObject var accountSessionModel: AccountSessionViewModel
    @ObservedObject var applicationModel: PlainpostApplicationModel
    let loginItemModel: PlainpostLoginItemModel?

    private var status: PlainpostMenuBarStatus {
        PlainpostMenuBarStatus(
            vaultState: applicationModel.vaultLaunchState,
            presentation: accountSessionModel.presentation,
            transientFailure: accountSessionModel.transientFailure,
            ownership: applicationModel.serviceOwnership,
            lockError: applicationModel.lockVaultError
        )
    }

    var body: some View {
        let status = status
        ForEach(status.messages, id: \.self) { message in
            Text(message)
        }
        if status.offersUnlock {
            Button("Unlock Plainpost…", systemImage: "lock.open") {
                applicationModel.unlockVault()
            }
        }
        if !status.messages.isEmpty || status.offersUnlock {
            Divider()
        }

        Button("Open Plainpost", systemImage: "macwindow") {
            applicationDelegate.presentWindow {
                openWindow(id: "main")
            }
        }

        Button("New Message", systemImage: "square.and.pencil") {
            applicationDelegate.presentWindow {
                openWindow(value: PlainpostComposerWindowRequest.newMessage)
            }
        }
        .disabled(!accountSessionModel.presentation.allowsMailboxMutations)

        Button("Settings…", systemImage: "gearshape") {
            applicationDelegate.presentWindow {
                openSettings()
            }
        }
        .disabled(!accountSessionModel.presentation.allowsMailbox)

        if let loginItemModel {
            PlainpostMenuBarLoginItemToggle(model: loginItemModel)
        }

        Divider()

        // Vault ruling: the vault stays unlocked for the whole login
        // session; this explicit item (like sign-out, session end or the
        // service terminating) is what locks it.
        if status.offersLock {
            Button("Lock Vault", systemImage: "lock") {
                Task { await applicationModel.lockVault() }
            }
        }

        Button("Quit Plainpost", systemImage: "power") {
            NSApp.terminate(nil)
        }
    }
}

private struct PlainpostMenuBarLoginItemToggle: View {
    @ObservedObject var model: PlainpostLoginItemModel

    var body: some View {
        if model.presentation.isToggleEnabled {
            Toggle("Open Plainpost at Login", isOn: Binding(
                get: { model.isEnabled },
                set: { enabled in Task { await model.setEnabled(enabled) } }
            ))
        }
    }
}

/// Feeds the session recovery monitor its system triggers. Created for
/// every launch: the monitor itself only retries while no window is open.
@MainActor
final class PlainpostSessionRecoveryTriggers {
    let monitor: PlainpostSessionRecoveryMonitor
    private let pathMonitor = NWPathMonitor()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(launchModel: PlainpostAccountLaunchModel) {
        monitor = PlainpostSessionRecoveryMonitor(
            accountModels: launchModel.$accountModel.eraseToAnyPublisher(),
            isHidden: { !PlainpostApplicationPresence.hasOnScreenWindow(in: NSApp.windows) }
        )
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.monitor.networkPathChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: .main)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"))
    }

    isolated deinit {
        pathMonitor.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.conditionsMayHaveChanged() }
        }
        observers.append((center, token))
    }
}

@MainActor
private struct PlainpostComposerSceneRoot: View {
    let request: PlainpostComposerWindowRequest
    @ObservedObject var applicationModel: PlainpostApplicationModel

    @ViewBuilder
    var body: some View {
        if let runtime = applicationModel.runtime {
            PlainpostComposerSceneContent(runtime: runtime, request: request)
        } else {
            SceneRuntimeErrorView(message: applicationModel.runtimeError ?? "The composer is unavailable.")
        }
    }
}

@MainActor
private struct PlainpostComposerSceneContent: View {
    @StateObject private var composer: ComposerViewModel
    @State private var hasRequestedForwardAttachments = false
    private let runtime: PlainpostAppRuntime
    /// The files a forward still has to attach. The scene can't await in `init`, so the
    /// forward's body is prepared there, marked as loading (which holds Send), and its
    /// files are added on appear.
    private let pendingForwardAttachments: [MailAttachment]

    init(runtime: PlainpostAppRuntime, request: PlainpostComposerWindowRequest) {
        self.runtime = runtime
        let sourceMessageID: String? = switch request {
        case .newMessage: nil
        case .reply(let sourceMessageID): sourceMessageID
        case .replyAll(let sourceMessageID): sourceMessageID
        case .forward(let sourceMessageID): sourceMessageID
        case .aiReply(let sourceMessageID, _, _): sourceMessageID
        case .restore: nil
        }
        let composer = runtime.makeComposerViewModel(sourceMessageID: sourceMessageID)
        var pendingForwardAttachments: [MailAttachment] = []
        switch request {
        case .newMessage:
            composer.prepareNewMessage()
        case .reply(let sourceMessageID):
            if let context = runtime.makeComposerReplyContext(sourceMessageID: sourceMessageID) {
                composer.prepareReply(context: context)
            } else {
                composer.prepareNewMessage()
            }
        case .replyAll(let sourceMessageID):
            if let context = runtime.makeComposerReplyAllContext(sourceMessageID: sourceMessageID) {
                composer.prepareReplyAll(context: context)
            } else {
                composer.prepareNewMessage()
            }
        case .forward(let sourceMessageID):
            if let context = runtime.makeComposerForwardContext(sourceMessageID: sourceMessageID) {
                composer.prepareForward(context: context, attachments: [], unavailable: [])
                pendingForwardAttachments = runtime.forwardAttachmentSources(for: sourceMessageID)
                composer.beginAttachingForwardedFiles(count: pendingForwardAttachments.count)
            } else {
                composer.prepareNewMessage()
            }
        case .aiReply(let sourceMessageID, let bodyMarkdown, let recipient):
            if let context = runtime.makeComposerReplyContext(sourceMessageID: sourceMessageID, recipient: recipient) {
                composer.prepareAIDraftReply(context: context, bodyMarkdown: bodyMarkdown)
            } else {
                composer.prepareNewMessage()
                composer.bodyMarkdown = bodyMarkdown
            }
        case .restore(let snapshot):
            composer.restore(from: snapshot)
        }
        self.pendingForwardAttachments = pendingForwardAttachments
        _composer = StateObject(wrappedValue: composer)
    }

    var body: some View {
        PlainpostComposerSceneView(composer: composer)
            .task { await attachForwardedFiles() }
    }

    /// Loads a forward's original files once and hands them to the composer, which keeps
    /// any edits made meanwhile and releases Send.
    private func attachForwardedFiles() async {
        guard !pendingForwardAttachments.isEmpty, !hasRequestedForwardAttachments else { return }
        hasRequestedForwardAttachments = true
        let files = await runtime.forwardAttachments(from: pendingForwardAttachments)
        guard !Task.isCancelled else { return }
        composer.attachForwardedFiles(files.attachments, unavailable: files.unavailable)
    }
}

#if DEBUG
@MainActor
private struct PlainpostDebugComposerSceneContent: View {
    @StateObject private var composer: ComposerViewModel

    init(request: PlainpostComposerWindowRequest) {
        let composer = ComposerViewModel.preview()
        switch request {
        case .restore(let snapshot):
            composer.restore(from: snapshot)
        case .newMessage:
            composer.prepareNewMessage()
        case .reply, .replyAll, .forward:
            composer.prepareNewMessage()
        case .aiReply(_, let bodyMarkdown, let recipient):
            composer.prepareNewMessage()
            composer.to = recipient
            composer.bodyMarkdown = bodyMarkdown
        }
        _composer = StateObject(wrappedValue: composer)
    }

    var body: some View {
        PlainpostComposerSceneView(composer: composer)
    }
}
#endif

@MainActor
private struct PlainpostComposerSceneView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var composer: ComposerViewModel

    var body: some View {
        ComposerWindow(
            viewModel: composer,
            close: { dismissWindow() },
            showsEmbeddedChrome: false,
            showsCommandBar: false
        )
        .frame(minWidth: 620, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ComposerToolbarStatusCapsule(
                    isWorking: composer.isWorking,
                    message: composer.displayStatusMessage,
                    tint: .secondary
                )
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save Draft", systemImage: "doc.badge.plus") {
                    Task { try? await composer.saveDraft() }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .help("Save Draft (⌘S)")
                .disabled(!composer.canSaveDraft)

                Button {
                    Task {
                        if (try? await composer.send()) == true {
                            dismissWindow()
                        }
                    }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Send (⇧⌘D)")
                .disabled(!composer.canSend)
            }
        }
    }
}

@MainActor
private struct PlainpostSettingsSceneRoot: View {
    @ObservedObject var applicationModel: PlainpostApplicationModel
    @ObservedObject var accountSessionModel: AccountSessionViewModel

    @ViewBuilder
    var body: some View {
        if let runtime = applicationModel.runtime {
            PlainpostSettingsSceneContent(
                runtime: runtime,
                accountSessionModel: accountSessionModel
            )
        } else {
            SceneRuntimeErrorView(message: applicationModel.runtimeError ?? "Settings are unavailable.")
        }
    }
}

@MainActor
private struct PlainpostSettingsSceneContent: View {
    @State private var selection: PlainpostSettingsDestination?
    @StateObject private var accountSetup: AccountSetupViewModel
    @StateObject private var aiProviderSettings: AIProviderSettingsViewModel
    @StateObject private var translationSettings: TranslationLanguageSettingsViewModel
    @StateObject private var auditLog: AuditLogViewModel
    @StateObject private var maintenance: MailMaintenanceViewModel
    @StateObject private var mailRules: MailRulesViewModel
    @StateObject private var mailLabels: MailLabelsViewModel
    @StateObject private var notificationPermission = NotificationPermissionModel()
    @ObservedObject private var accountSessionModel: AccountSessionViewModel
    private let nodeSettings: SyncNodeSettingsViewModel?
    private let aiIndexStatus: AIIndexStatusModel
    private let searchIndexState: () async -> MailSearchIndexState
    private let rebuildSearchIndex: () async throws -> Void
    private let settingsHost: PlainpostSettingsHost

    init(
        runtime: PlainpostAppRuntime,
        accountSessionModel: AccountSessionViewModel
    ) {
        let accountSetup = runtime.makeAccountSetupViewModel()
        let aiProviderSettings = runtime.makeAIProviderSettingsViewModel()
        let translationSettings = runtime.translationState.languageSettings
        _accountSetup = StateObject(wrappedValue: accountSetup)
        _aiProviderSettings = StateObject(wrappedValue: aiProviderSettings)
        _translationSettings = StateObject(wrappedValue: translationSettings)
        _auditLog = StateObject(wrappedValue: runtime.makeAuditLogViewModel())
        _maintenance = StateObject(
            wrappedValue: runtime.makeMailMaintenanceViewModel(
                accountSetup: accountSetup,
                aiProviderSettings: aiProviderSettings
            )
        )
        _mailRules = StateObject(wrappedValue: runtime.makeMailRulesViewModel())
        _mailLabels = StateObject(wrappedValue: runtime.makeMailLabelsViewModel())
        self.accountSessionModel = accountSessionModel
        nodeSettings = runtime.makeNodeSettingsViewModel()
        aiIndexStatus = runtime.makeAIIndexStatusModel()
        searchIndexState = { [service = runtime.mailSearchService] in
            await service.indexState()
        }
        rebuildSearchIndex = { [service = runtime.mailSearchService] in
            try await service.rebuildIndex()
        }
        var host = PlainpostSettingsHost()
        host.nodeMailAccounts = runtime.settingsNodeMailAccounts
        settingsHost = host
    }

    var body: some View {
        SettingsWorkspace(
            selection: $selection,
            accountSetup: accountSetup,
            accountSessionModel: accountSessionModel,
            nodeSettings: nodeSettings,
            aiProviderSettings: aiProviderSettings,
            translationSettings: translationSettings,
            aiIndexStatus: aiIndexStatus,
            auditLog: auditLog,
            mailRules: mailRules,
            mailLabels: mailLabels,
            maintenance: maintenance,
            searchIndexState: searchIndexState,
            rebuildSearchIndex: rebuildSearchIndex
        )
        .frame(minWidth: 820, minHeight: 560)
        .background(SettingsWindowChrome(title: windowTitle))
        .notificationPermission(notificationPermission)
        .environment(\.plainpostCalendarAuthority, accountSessionModel.calendarAuthority)
        .plainpostSettingsHost(settingsHost)
    }

    private var windowTitle: String {
        selection?.title(accountSetup: accountSetup, nodeAccounts: settingsHost.nodeMailAccounts) ?? "Settings"
    }
}

private struct SettingsWindowChrome: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> SettingsWindowChromeView {
        SettingsWindowChromeView(title: title)
    }

    func updateNSView(_ view: SettingsWindowChromeView, context: Context) {
        view.title = title
        view.applyWindowChrome()
    }
}

private final class SettingsWindowChromeView: NSView {
    var title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.applyWindowChrome()
        }
    }

    override func layout() {
        super.layout()
        applyWindowChrome()
    }

    func applyWindowChrome() {
        guard let window else { return }
        window.title = title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false

        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = buttonTypes.compactMap(window.standardWindowButton)
        guard let container = buttons.first?.superview else { return }

        let leftInset: CGFloat = 18
        let spacing: CGFloat = 7
        for (index, button) in buttons.enumerated() {
            let x = leftInset + CGFloat(index) * (button.frame.width + spacing)
            let y = max(2, container.bounds.height - button.frame.height - 10)
            button.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

private struct SceneRuntimeErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "Plainpost is unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .frame(minWidth: 420, minHeight: 260)
    }
}

private struct AccountSceneUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "Plainpost is locked",
            systemImage: "lock.fill",
            description: Text(message)
        )
        .frame(minWidth: 420, minHeight: 260)
    }
}

@MainActor
private struct PlainpostRuntimeRootView: View {
    @ObservedObject var applicationModel: PlainpostApplicationModel
    @ObservedObject var accountSessionModel: AccountSessionViewModel
    let readOnly: Bool
    @Environment(\.openSettings) private var openSettings

    /// The Settings pieces the main window needs: the Node's mail accounts. Mac reads
    /// the Plainpost Account and Sync Node pages from `accountSessionModel` directly, so
    /// unlike iOS this host carries no page builders.
    static func settingsHost(for runtime: PlainpostAppRuntime) -> PlainpostSettingsHost {
        var host = PlainpostSettingsHost()
        host.nodeMailAccounts = runtime.settingsNodeMailAccounts
        return host
    }

    var body: some View {
        Group {
            switch applicationModel.vaultLaunchState {
        case .checking:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Opening Plainpost…").font(.headline)
                Text("Checking your Plainpost vault").font(.callout).foregroundStyle(.secondary)
            }.frame(minWidth: 520, minHeight: 320)
        case .locked: MailKeychainUnlockView(unlock: applicationModel.unlockVault)
        case .keyMissing:
            PlainpostVaultKeyMissingView(
                startOverError: applicationModel.vaultStartOverError,
                startOver: applicationModel.startOverWithSavedSignIns
            )
        case .keyAmbiguous:
            PlainpostVaultIssueView(
                title: "Multiple Plainpost Vault Keys were found",
                message:
                    "Plainpost did not choose or change a key. Contact support to identify the correct Plainpost Vault Key before continuing."
            )
        case .ciphertextInvalid:
            PlainpostVaultIssueView(
                title: "Encrypted credential data is invalid",
                message:
                    "Plainpost could not safely read the encrypted credential data, so it was preserved unchanged. Contact support before making any credential changes."
            )
        case .unsupportedVersion(let version):
            PlainpostVaultIssueView(
                title: "This vault version is not supported",
                message:
                    "The encrypted credentials use vault version \(version). Update Plainpost or contact support; the existing data was preserved unchanged."
            )
        case .authorizationFailed:
            PlainpostVaultIssueView(
                title: "Vault authorization failed",
                message:
                    "Plainpost could not authorize access. Check your Mac authentication settings, then try again.",
                buttonTitle: "Try Again", action: applicationModel.retry)
        case .serviceUnavailable:
            PlainpostVaultIssueView(
                title: "Plainpost Service is unavailable",
                message:
                    "Plainpost could not reach its signed local service. Make sure Plainpost is installed correctly, then try again.",
                buttonTitle: "Try Again", action: applicationModel.retry)
            case .ready: readyContent
            }
        }
        // After starting over, each account must sign in again: Settings
        // marks them and offers the sign-in.
        .onChange(of: applicationModel.startedOverWithSavedSignIns) { _, startedOver in
            if startedOver { openSettings() }
        }
        // PlainpostRuntimeLifetime starts and stops the runtime from the
        // account session; closing this window leaves it running.
    }

    @ViewBuilder
    private var readyContent: some View {
        if let runtime = applicationModel.runtime {
            if readOnly {
                PlainpostCachedMailboxRoot(calendarAccountID: accountSessionModel.calendarCacheAccountID, runtime: runtime)
            } else {
                runtime.makeRootView(
                    accountSessionModel: accountSessionModel,
                    notificationOpenRequest: applicationModel.notificationOpenRequest,
                    notificationOpenHandled: applicationModel.consumeNotificationOpenRequest
                )
                .plainpostSettingsHost(Self.settingsHost(for: runtime))
            }
        } else if let runtimeError = applicationModel.runtimeError {
            VStack(alignment: .leading, spacing: 14) {
                Label("Plainpost could not start", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(runtimeError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: applicationModel.retry)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .frame(width: 520, alignment: .leading)
            .frame(minWidth: 520, minHeight: 240, alignment: .center)
            .accessibilityElement(children: .contain)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Opening Plainpost…")
                    .font(.headline)
                Text("Preparing your local mailbox")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 520, minHeight: 320)
        }
    }
}

/// Offline leases expose only immutable cached message navigation. Keeping
/// this root separate prevents the full mailbox root from constructing
/// settings, approvals, compose, AI, search, or mutation models.
@MainActor
private struct PlainpostCachedMailboxRoot: View {
    let calendarAccountID: String?
    @State private var showsCalendar = false
    let runtime: PlainpostAppRuntime
    @State private var selection: String?

    private var model: InboxViewModel {
        runtime.makeInboxViewModel(selectedMessageID: selection)
    }

    var body: some View {
        NavigationSplitView {
            List(model.classicRows, selection: $selection) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.senderDisplayName ?? row.sender).font(.headline)
                    Text(row.subject).font(.subheadline)
                    Text(row.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(row.id)
            }
            .navigationTitle("Cached Mail")
        } detail: {
            if selection == nil {
                ContentUnavailableView("Select a cached message", systemImage: "envelope.open")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.selectedThread.subject).font(.title2.bold())
                        ForEach(model.selectedThread.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.senderDisplayName ?? message.sender).font(.headline)
                                Text(message.safeBodyText).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
            }
        }
        .toolbar {
            if calendarAccountID != nil { Button("Cached Calendar", systemImage: "calendar") { showsCalendar = true } }
        }
        .sheet(isPresented: $showsCalendar) {
            if let calendarAccountID {
                VStack(spacing: 0) {
                    HStack { Text("Cached Calendar").font(.headline); Spacer(); Button("Done") { showsCalendar = false } }.padding()
                    runtime.makeCachedCalendarView(accountID: calendarAccountID)
                }.frame(minWidth: 900, minHeight: 640)
            }
        }
    }
}

private struct MailKeychainUnlockView: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
            Text("Unlock Mail")
                .font(.title2.weight(.semibold))
            Text("Plainpost needs access to the mail credentials stored in your Mac Keychain. Unlock them to open your mailbox and resume mail work.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            Button("Unlock Plainpost Credentials", systemImage: "key.fill", action: unlock)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The vault key is gone. After Plainpost is reinstalled under a new developer
/// identity the old key can never be read again, so this screen offers to
/// start over: the old encrypted sign-ins are archived, mail is kept, and each
/// account signs in again.
struct PlainpostVaultKeyMissingView: View {
    static let title = "Plainpost Vault Key is missing"
    static let message =
        "Plainpost can't open the key that protects your saved sign-ins. This happens when Plainpost is reinstalled under a new developer identity, and the old key can't be brought back. Your mail on this Mac is safe."
    static let startOverButtonTitle = "Start Over with Saved Sign-ins…"
    static let confirmationTitle = "Start over with saved sign-ins?"
    static let confirmationButtonTitle = "Start Over"
    static let confirmationMessage =
        "Your mail on this Mac is kept. Your old encrypted sign-ins are archived, not deleted. Afterward, you'll sign in to each mail account again in Settings."

    let startOverError: String?
    let startOver: () -> Void
    @State private var confirmsStartOver = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.slash")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(Self.title)
                .font(.title3.weight(.semibold))
            Text(Self.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(Self.startOverButtonTitle) { confirmsStartOver = true }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("vault-start-over")
            if let startOverError {
                Label(startOverError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .confirmationDialog(Self.confirmationTitle, isPresented: $confirmsStartOver) {
            Button(Self.confirmationButtonTitle, action: startOver)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.confirmationMessage)
        }
    }
}

private struct PlainpostVaultIssueView: View {
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.slash")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action).keyboardShortcut(.defaultAction)
            }
        }.frame(minWidth: 520, minHeight: 320)
    }
}
