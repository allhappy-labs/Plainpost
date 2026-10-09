import Combine
import AuthenticationServices
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport
import PlainpostNotificationRuntime
import PlainpostUI
import SwiftUI

enum MobileDirectSyncRetryPolicy {
    static let waitingDelay: Duration = .seconds(12)

    static func message(isPending: Bool, elapsed: Duration) -> String? {
        guard isPending, elapsed >= waitingDelay else { return nil }
        return "Mail sync is still in progress."
    }
}

private struct MobileHistoryProgress {
    let mailboxPath: String
    let downloaded: Int
    let estimatedTotal: Int?
}

struct MobileMailRootView: View {
    @StateObject private var model: MobileMailRuntimeModel
    @State private var authenticationSession: ASWebAuthenticationSession?
    // ASWebAuthenticationSession keeps its presentation provider weakly.
    // Retain this object for the entire authentication lifetime.
    @State private var authenticationPresentationContext: MobileAuthenticationPresentationContext?
    @State private var providerMessage: String?
    @State private var discoveredMailboxes: [SyncNodeProviderMailbox] = []
    @State private var selectedMailboxHandles: Set<String> = []
    @State private var assigningMailboxes = false
    @State private var assignedMailboxes: [SyncNodeProviderMailbox] = []
    @State private var policyCoordinator = NotificationPolicyPresentationCoordinator()
    @State private var mailboxPolicyMessage: String?
    @State private var connectedProviderIdentity: String?
    @State private var assignmentMessage: String?
    /// Shown once the mailbox-assignment sheet has gone, so an alert never
    /// races the sheet's dismissal.
    @State private var providerMessageAfterAssignment: String?
    @State private var pendingLocalAccountID: AccountID?
    @State private var routedLocalAccountID: AccountID?
    @State private var localMonitorTask: Task<Void, Never>?
    /// Starts and stops the device's Sync Node mail in order, so a quick background and return
    /// never leaves it stopped.
    @State private var nodeMailLifecycle: Task<Void, Never>?
    @State private var localSyncTask: Task<Void, Never>?
    @State private var localSyncRequestID: UUID?
    @State private var historySyncTask: Task<Void, Never>?
    @State private var localSyncStalledTask: Task<Void, Never>?
    @State private var localSyncFailure: String?
    @State private var localSyncNotice: String?
    @State private var localSyncing = false
    @State private var completeHistoryEnabled = false
    @State private var historyProgress: MobileHistoryProgress?
    @State private var historyDownloadStatus: String?
    @State private var historyRequestStartedAt: Date?
    /// The account whose complete history the user last asked for; its page shows progress.
    @State private var historyAccountID: AccountID?
    /// The account the current sync failure is about, named in the Activity row.
    @State private var localSyncFailureAccountID: AccountID?
    @State private var activeDirectRuntimeID: ObjectIdentifier?
    /// The runtime's accounts, read when the runtime or the account set changes: the host
    /// values derived from them are compared on every body pass, which must not open SQLite.
    @State private var runtimeAccounts: [Account] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileCompactKeyboardEditing) private var isCompactKeyboardEditing
    @StateObject private var mobileEnvironment = MobileMailEnvironment()
    /// Why the mail is read-only, or nil while it's writable.
    let readOnlyReason: MobileReadOnlyReason?
    var readOnly: Bool { readOnlyReason != nil }
    let accountModel: MobileAccountModel?
    let providerController: SyncNodeProviderController?
    let route: MobileMailRoute
    let onLocalAccountSetupConnected: (AccountID) -> Void
    let onLocalAccountSwitchBlockedChanged: (Bool) -> Void
    let contactDirectory: ContactDirectoryModel?
    /// Settings ▸ account page's "Use Sync Node for This Account", when the route offers it.
    let useSyncNodeForAccount: (@MainActor (AccountID) -> Void)?
    /// Settings ▸ Plainpost Account's Connect button, for local mail without a Plainpost account.
    let connectPlainpostAccount: (@MainActor () -> Void)?

    /// iPhone runs the native shell in every orientation; iPad keeps the split-view root.
    static func usesMobileShell(idiom: UIUserInterfaceIdiom) -> Bool { idiom == .phone }
    /// The Undo window for archive and delete on iPhone.
    static let mobileCommitDelay: Duration = .seconds(4)
    private var usesMobileShell: Bool { Self.usesMobileShell(idiom: UIDevice.current.userInterfaceIdiom) }

    init(
        readOnlyReason: MobileReadOnlyReason?,
        accountModel: MobileAccountModel? = nil,
        providerController: SyncNodeProviderController? = nil,
        route: MobileMailRoute = .localSetup,
        localLaunchModel: MobileLocalMailLaunchModel = MobileLocalMailLaunchModel(),
        contactDirectory: ContactDirectoryModel? = nil,
        useSyncNodeForAccount: (@MainActor (AccountID) -> Void)? = nil,
        connectPlainpostAccount: (@MainActor () -> Void)? = nil,
        onLocalAccountSetupConnected: @escaping (AccountID) -> Void = { _ in },
        onLocalAccountSwitchBlockedChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: MobileMailRuntimeModel(localLaunchModel: localLaunchModel))
        self.readOnlyReason = readOnlyReason
        self.accountModel = accountModel
        self.providerController = providerController
        self.route = route
        self.onLocalAccountSetupConnected = onLocalAccountSetupConnected
        self.onLocalAccountSwitchBlockedChanged = onLocalAccountSwitchBlockedChanged
        self.contactDirectory = contactDirectory
        self.useSyncNodeForAccount = useSyncNodeForAccount
        self.connectPlainpostAccount = connectPlainpostAccount
    }

    var body: some View {
        VStack(spacing: 0) {
            accountChrome
            if isDirectMailRoute, !readOnly, !usesMobileShell, let localSyncFailure {
                HStack {
                    Text(localSyncFailure)
                        .font(.footnote)
                    Spacer()
                    Button("Retry sync") { retryDirectMail() }
                        .accessibilityIdentifier("direct-mail.retry-sync")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if isDirectMailRoute, !readOnly, !completeHistoryEnabled, !usesMobileShell, let localSyncNotice {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(localSyncNotice).font(.footnote)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            mailContent
        }
        .alert("Google provider", isPresented: Binding(
            get: { providerMessage != nil },
            set: { if !$0 { providerMessage = nil } }
        )) {
            Button("OK", role: .cancel) { providerMessage = nil }
        } message: {
            Text(providerMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { accountModel.map { $0.notificationProducerSelectionState != .idle } ?? false },
            set: { if !$0 { accountModel?.dismissNotificationProducerSelection() } }
        )) {
            NotificationProducerSelectionView(
                state: accountModel?.notificationProducerSelectionState ?? .idle,
                targets: accountModel?.notificationProducerTargets ?? [],
                selectTarget: { target in
                    // The account whose "Use Mac" opened the picker, else a Sync Node account,
                    // else the first Direct account no Mac sends for yet.
                    guard let mailbox = accountModel?.pendingNotificationProducerMailboxID
                        ?? accountModel?.selectedMailAccountID?.rawValue
                        ?? accountModel?.firstDirectMailboxWithoutMac
                        ?? notificationPolicyRows.first?.id.rawValue else {
                        accountModel?.dismissNotificationProducerSelection()
                        return
                    }
                    accountModel?.beginNotificationProducerEnrollment(target: target, logicalMailboxID: mailbox)
                },
                configureAppleRequest: { accountModel?.configureNotificationProducerAppleRequest($0) },
                completeAppleAuthorization: { result, attemptID in accountModel?.completeNotificationProducerAppleAuthorization(result, attemptID: attemptID) },
                finish: { accountModel?.finishNotificationProducerEnrollment() },
                cancel: { accountModel?.dismissNotificationProducerSelection() }
            )
        }
        .task(id: preparationTaskIdentity) {
            await model.prepare(
                readOnly: readOnly,
                route: route,
                // There is no account switch: one runtime serves every account.
                isUserAccountSwitch: false,
                // And only while the Node still lists the held runtime's account.
                isAccountListed: { id in
                    guard let accountModel else { return true }
                    return accountModel.mailAccounts.contains { $0.logicalMailboxID == id }
                },
                // Right before the swap, after any wait on a send: an archive or delete started
                // while the switch waited commits with the runtime that shows it.
                beforeReplacing: { await mobileEnvironment.commitPendingActions() }
            )
            await loadAssignedMailboxes()
        }
        .onChange(of: model.runtimeGeneration) { _, _ in
            restartDirectMailLifecycle()
            // A switch replaces the runtime without changing the account count.
            refreshRuntimeAccounts()
            // Google mailboxes discovered for one runtime's provider are never
            // assigned through another's.
            discoveredMailboxes = []
            selectedMailboxHandles = []
        }
        .onReceive(MailStoreChangeSignal.mainThreadChanges) { scope in
            if scope == .accounts || scope == .all {
                Task { @MainActor in refreshRuntimeAccounts() }
            }
            guard scope == .operations else { return }
            Task { @MainActor in
                if let runtime = model.runtime, isDirectMailRoute {
                    refreshCompleteHistoryStatus(runtime)
                }
            }
        }
        .task { await runUITestNotificationTap() }
        .onChange(of: showsMailboxNotificationPolicy, initial: true) { _, shows in
            // The notification menu offers the per-mailbox sheet only when
            // there are rows to show.
            accountModel?.hasMailboxNotificationPolicyRows = shows
            if !shows { accountModel?.isMailboxNotificationPolicyPresented = false }
        }
        .onChange(of: Self.mobileSyncActionKey(route: route, readOnly: readOnly, scenePhase: scenePhase), initial: true) { _, _ in
            // The action captures this view's route, read-only state and scene phase, and the
            // view outlives changes to all three (local setup becomes Direct in place).
            configureMobileEnvironment()
        }
        .onChange(of: readOnlyReason, initial: true) { _, reason in
            mobileEnvironment.readOnlyReason = reason
        }
        .onChange(of: mobileBannerKey, initial: true) { _, key in
            mobileEnvironment.banner = key == Self.noMobileBannerKey ? nil : AnyView(mobileBannerContent)
        }
        .onChange(of: currentHostActivities, initial: true) { _, activities in
            // The shell lists these in Mailboxes' Activity section; a failure also heads the list.
            mobileEnvironment.hostActivities = activities
        }
        .onChange(of: accountCount, initial: true) { _, _ in
            mobileEnvironment.fromAddress = fromAddress
        }
        .onChange(of: model.hasUnsavedComposer, initial: true) { _, unsaved in
            // A notification tap waits for an unsaved composer.
            accountModel?.setMailComposerHasUnsavedChanges(unsaved)
            #if DEBUG
            // UI acceptance: a notification arrives the moment the draft has unsaved changes.
            if unsaved, ProcessInfo.processInfo.environment["PLAINPOST_UI_TEST_NOTIFICATION_TAP_WHILE_COMPOSING"] == "1" {
                accountModel?.handleNotificationTap(MobileNotificationOpenRequest(token: "ui-test", logicalMailboxID: nil))
            }
            #endif
            onLocalAccountSwitchBlockedChanged(MobileLocalAccountSwitchPolicy.isBlocked(
                hasUnsavedComposer: unsaved, isSendPending: model.isSendPending
            ))
            mobileEnvironment.fromAddress = fromAddress
            releaseCompletedLocalSetupIfSafe()
        }
        .onChange(of: model.isSendPending, initial: true) { _, pending in
            onLocalAccountSwitchBlockedChanged(MobileLocalAccountSwitchPolicy.isBlocked(
                hasUnsavedComposer: model.hasUnsavedComposer, isSendPending: pending
            ))
            mobileEnvironment.fromAddress = fromAddress
            releaseCompletedLocalSetupIfSafe()
        }
        .onDisappear {
            cancelDirectMailLifecycle()
            accountModel?.setMailComposerHasUnsavedChanges(false)
            accountModel?.hasMailboxNotificationPolicyRows = false
            accountModel?.isMailboxNotificationPolicyPresented = false
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { restartDirectMailLifecycle() }
            else { cancelDirectMailLifecycle() }
            // Accounts added, removed or reauthorized on the Mac appear when
            // the app returns to the foreground.
            guard phase == .active, let accountModel else { return }
            Task { @MainActor in await accountModel.refreshMailAccounts() }
        }
        .onChange(of: accountModel?.notificationProducerSelectionState) { _, state in
            guard state.map({ if case .selected = $0 { return true }; return false }) == true else { return }
            Task { @MainActor in await loadAssignedMailboxes() }
        }
        // The Plainpost Account binds its Sync Node account after the mail opens: its
        // notification rows load then.
        .onReceive(
            accountModel?.$selectedMailAccountID.dropFirst().removeDuplicates().eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { _ in
            Task { @MainActor in await loadAssignedMailboxes() }
        }
        .task {
            // A tap that launched the app was posted before this screen listened.
            guard let pending = MobileNotificationTaps.pending else { return }
            NotificationCenter.default.post(name: .plainpostOpenNotification, object: pending)
        }
        .onReceive(NotificationCenter.default.publisher(for: .plainpostOpenNotification)) { notification in
            guard let request = notification.object as? MobileNotificationOpenRequest else { return }
            MobileNotificationTaps.pending = nil
            Task { @MainActor in
                // The open rebuilds the mail root (`.id` below). An archive or delete still in
                // its Undo window commits first, or the new session shows its row again.
                await mobileEnvironment.commitPendingActions()
                // One runtime serves every account: the message opens in place, whichever
                // account it came to, with no switch.
                let openToken = model.beginNotificationOpen()
                for _ in 0..<40 where model.runtime == nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    await Task.yield()
                }
                guard let runtime = model.runtime else {
                    model.finishNotificationOpen(.allInboxes, token: openToken, resolvedBy: nil)
                    return
                }
                let destination = await runtime.resolveNotificationOpen(
                    request.token,
                    logicalMailboxHint: request.logicalMailboxID.map { AccountWireCodec.encodeBase64URL($0.rawValue) }
                )
                model.finishNotificationOpen(destination, token: openToken, resolvedBy: runtime)
                if destination == .messageUnavailable {
                    mobileEnvironment.notice = "This message is no longer on this iPhone."
                }
            }
        }
        .id(model.notificationOpen.map { String(describing: $0.destination) } ?? "plainpost-mail-root")
    }

    private var preparationTaskIdentity: String {
        Self.preparationTaskIdentity(route: route, readOnly: readOnly)
    }

    static func preparationTaskIdentity(route: MobileMailRoute, readOnly: Bool) -> String {
        switch route {
        case .localSetup: return "local-setup-\(readOnly)"
        case .allDirect: return "all-direct-\(readOnly)"
        case .node(let authority): return "node-\(ObjectIdentifier(authority as AnyObject))-\(readOnly)"
        case .nodeUnavailable(let id): return "node-unavailable-\(id.rawValue)-\(readOnly)"
        }
    }

    private var isDirectMailRoute: Bool {
        if case .allDirect = route { return true }
        return false
    }

    private var isLocalSetupRoute: Bool {
        if case .localSetup = route { return true }
        return false
    }

    private func refreshCompleteHistoryStatus(_ runtime: PlainpostAppRuntime) {
        guard let accountID = historyAccountID else {
            completeHistoryEnabled = false
            historyProgress = nil
            return
        }
        completeHistoryEnabled = (try? runtime.store.syncPreferences(accountID: accountID).downloadCompleteHistory) == true
        let latest = try? runtime.store.mailboxSyncStatuses(accountID: accountID)
            .filter { $0.phase.rawValue == "backfill" && !$0.complete }
            .max(by: { $0.updatedAt < $1.updatedAt })
        historyProgress = completeHistoryEnabled
            ? latest.map { MobileHistoryProgress(
                mailboxPath: $0.mailboxPath,
                downloaded: $0.downloaded,
                estimatedTotal: $0.estimatedTotal
            ) }
            : nil
        if historySyncTask != nil, let latest,
           let historyRequestStartedAt, latest.updatedAt >= historyRequestStartedAt,
           let historyProgress {
            historyDownloadStatus = DownloadProgressText.text(
                downloaded: historyProgress.downloaded,
                estimatedTotal: historyProgress.estimatedTotal
            )
        }
    }

    /// The device's Sync Node mail and its new-mail alerts run while the app is in the
    /// foreground; in the background, `MobileBackgroundMailRefresh` passes run on this runtime.
    private func setForegroundMailWork(running: Bool) {
        guard let runtime = model.runtime else { return }
        if running { MobileBackgroundMailRefresh.shared.activeRuntime = runtime }
        let previous = nodeMailLifecycle
        nodeMailLifecycle = Task { @MainActor in
            await previous?.value
            if running {
                await runtime.startDeviceNodeMail()
                await runtime.startNewMailAlerts()
            } else {
                await runtime.stopNewMailAlerts()
                await runtime.stopDeviceNodeMail()
            }
        }
    }

    private func cancelDirectMailLifecycle() {
        setForegroundMailWork(running: false)
        localMonitorTask?.cancel()
        localMonitorTask = nil
        localSyncTask?.cancel()
        localSyncTask = nil
        localSyncRequestID = nil
        historySyncTask?.cancel()
        historySyncTask = nil
        historyDownloadStatus = nil
        historyRequestStartedAt = nil
        localSyncStalledTask?.cancel()
        localSyncStalledTask = nil
        localSyncing = false
        localSyncNotice = nil
        historyProgress = nil
        activeDirectRuntimeID = nil
    }

    /// UI acceptance: a push tap for the Sync Node message named by
    /// `PLAINPOST_UI_TEST_NOTIFICATION_TAP_NODE_MESSAGE`, once the mirror has it ("missing"
    /// taps one this device never had, once the mail has opened).
    private func runUITestNotificationTap() async {
        #if DEBUG
        guard let nodeMessageID = ProcessInfo.processInfo.environment["PLAINPOST_UI_TEST_NOTIFICATION_TAP_NODE_MESSAGE"],
              !Self.uiTestNotificationTapped else { return }
        let token = NotificationOpaqueIdentities.messageToken(for: nodeMessageID)
        for _ in 0..<240 where !Task.isCancelled {
            if let runtime = model.runtime {
                let found = await runtime.resolveNotificationOpen(token)
                if nodeMessageID == "missing" { break }
                if case .message = found { break }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled, !Self.uiTestNotificationTapped else { return }
        Self.uiTestNotificationTapped = true
        let request = MobileNotificationOpenRequest(token: token, logicalMailboxID: nil)
        if let accountModel { accountModel.handleNotificationTap(request) }
        else { NotificationCenter.default.post(name: .plainpostOpenNotification, object: request) }
        #endif
    }

    #if DEBUG
    @MainActor private static var uiTestNotificationTapped = false

    /// The realistic UI fixture's account has no server; its mail is already in the store.
    private static var skipsDirectSync: Bool {
        ProcessInfo.processInfo.environment["PLAINPOST_REALISTIC_MAIL_UI_ACCEPTANCE"] != nil
    }
    #else
    private static let skipsDirectSync = false
    #endif

    private func restartDirectMailLifecycle() {
        guard !Self.skipsDirectSync, scenePhase == .active, isDirectMailRoute, !readOnly,
              let runtime = model.runtime else {
            cancelDirectMailLifecycle()
            return
        }
        if activeDirectRuntimeID == ObjectIdentifier(runtime),
           localSyncTask != nil || localMonitorTask != nil { return }
        cancelDirectMailLifecycle()
        activeDirectRuntimeID = ObjectIdentifier(runtime)
        // After a relaunch, pick up a history download that is still running.
        if historyAccountID == nil { historyAccountID = runtime.directAccountWithHistoryInProgress() }
        refreshCompleteHistoryStatus(runtime)
        setForegroundMailWork(running: true)
        // Read state queued while away goes out now, not after a long first sync.
        Task { await runtime.resumeQueuedMailboxWriteBack() }
        syncDirectMail()
        startDirectMonitor(runtime)
    }

    private func startDirectMonitor(_ runtime: PlainpostAppRuntime) {
        guard scenePhase == .active, model.runtime === runtime,
              localMonitorTask == nil else { return }
        // Each pass names a failing account, or clears the failure once every account synced;
        // the monitor keeps running through it.
        runtime.directSyncFailureHandler = { failure in
            guard model.runtime === runtime else { return }
            if let failure {
                localSyncFailureAccountID = failure.accountID
                localSyncFailure = "Mail sync failed. Check your connection and retry."
            } else if localSyncFailureAccountID != nil {
                localSyncFailureAccountID = nil
                localSyncFailure = nil
            }
        }
        localMonitorTask = Task {
            do {
                try await runtime.monitorMail()
            } catch {
                guard !Task.isCancelled, model.runtime === runtime else { return }
                localSyncFailureAccountID = (error as? DirectSyncFailure)?.accountID
                localSyncFailure = "Mail sync stopped. Check your connection and retry."
            }
            guard !Task.isCancelled, model.runtime === runtime else { return }
            localMonitorTask = nil
        }
    }

    private func syncDirectMail() {
        _ = beginDirectMailRefresh(replacingWaiter: false)
    }

    private func beginDirectMailRefresh(replacingWaiter: Bool) -> Task<Void, Never>? {
        guard !Self.skipsDirectSync, scenePhase == .active, isDirectMailRoute, !readOnly,
              let runtime = model.runtime else { return nil }
        if let localSyncTask, !replacingWaiter { return localSyncTask }
        // A pull is a genuine new provider-checkpoint request, even if startup
        // or another view waiter is still pending. Cancellation detaches only
        // that observer; the runtime retains the historical execution owner.
        localSyncTask?.cancel()
        let requestID = UUID()
        localSyncRequestID = requestID
        localSyncFailure = nil
        localSyncNotice = nil
        localSyncing = true
        refreshCompleteHistoryStatus(runtime)
        localSyncStalledTask?.cancel()
        localSyncStalledTask = Task {
            try? await Task.sleep(for: MobileDirectSyncRetryPolicy.waitingDelay)
            guard !Task.isCancelled, model.runtime === runtime,
                  localSyncRequestID == requestID else { return }
            localSyncNotice = MobileDirectSyncRetryPolicy.message(
                isPending: true, elapsed: MobileDirectSyncRetryPolicy.waitingDelay)
        }
        let task = Task {
            defer {
                if model.runtime === runtime, localSyncRequestID == requestID {
                    if Task.isCancelled { localSyncNotice = nil }
                    localSyncStalledTask?.cancel()
                    localSyncStalledTask = nil
                    localSyncing = false
                    localSyncTask = nil
                    localSyncRequestID = nil
                }
            }
            // Every Direct account syncs side by side; the first failing account (by id) is
            // the one the Activity row names.
            let results = await runtime.syncAllDirectMailNow()
            guard !Task.isCancelled, model.runtime === runtime,
                  localSyncRequestID == requestID else { return }
            localSyncNotice = nil
            let failure = results.sorted { $0.key.rawValue < $1.key.rawValue }.lazy
                .compactMap { accountID, result -> (AccountID, Error)? in
                    if case .failure(let error) = result { return (accountID, error) }
                    return nil
                }.first
            if let (accountID, error) = failure {
                localSyncFailureAccountID = accountID
                if let error = error as? PlainpostError,
                   case .validationFailed("Google sign-in isn't available in this build.") = error {
                    localSyncFailure = "Gmail cannot sync: Google sign-in is unavailable in this build."
                } else {
                    localSyncFailure = "Mail sync failed. Check your connection and retry."
                }
            } else {
                localSyncFailure = nil
                localSyncFailureAccountID = nil
            }
            // A failed periodic monitor has exited. Once the healthy accounts synced, monitoring
            // resumes for them (and retries the failing one on its schedule).
            if results.values.contains(where: { if case .success = $0 { true } else { false } }) {
                startDirectMonitor(runtime)
            }
        }
        localSyncTask = task
        return task
    }

    private func retryDirectMail() {
        // The operation client coalesces repeated Inbox sync requests for the
        // same account. Cancel this view's waiter, leaving the durable job
        // intact, then signal it again when connectivity may have returned.
        localSyncTask?.cancel()
        localSyncTask = nil
        localSyncStalledTask?.cancel()
        localSyncStalledTask = nil
        localSyncing = false
        localSyncNotice = nil
        syncDirectMail()
    }

    private func downloadCompleteHistory(_ accountID: AccountID) {
        if historySyncTask != nil {
            historyDownloadStatus = "History download is already running…"
            return
        }
        historyDownloadStatus = "Starting history download…"
        historyRequestStartedAt = Date()
        guard isDirectMailRoute, !readOnly,
              let runtime = model.runtime else {
            historyDownloadStatus = "History download is unavailable for this account."
            return
        }
        historyAccountID = accountID
        do {
            try runtime.enableCompleteHistory(for: accountID)
            refreshCompleteHistoryStatus(runtime)
            historyDownloadStatus = "Downloading"
            historySyncTask = Task {
                do {
                    try await runtime.syncDirectMailHistoryNow(for: accountID)
                    guard !Task.isCancelled, model.runtime === runtime else { return }
                    refreshCompleteHistoryStatus(runtime)
                    historyDownloadStatus = "Up to date"
                } catch {
                    guard !Task.isCancelled, model.runtime === runtime else { return }
                    historyDownloadStatus = "History download failed. Check your connection and retry."
                }
                historySyncTask = nil
            }
        } catch {
            localSyncFailure = "Complete mail history could not be started. Try again."
            historyDownloadStatus = localSyncFailure
        }
    }

    private func releaseCompletedLocalSetupIfSafe() {
        guard !model.isSendPending, !model.hasUnsavedComposer,
              let accountID = pendingLocalAccountID else { return }
        pendingLocalAccountID = nil
        routedLocalAccountID = accountID
        onLocalAccountSetupConnected(accountID)
    }

    /// A local account finished setup in `runtime`: hand it to the app once no composer or
    /// undoable send would be lost.
    private func localAccountSetupConnected(_ accountID: AccountID, runtime: PlainpostAppRuntime) {
        guard model.runtime === runtime else { return }
        guard pendingLocalAccountID != accountID, routedLocalAccountID != accountID else { return }
        pendingLocalAccountID = accountID
        releaseCompletedLocalSetupIfSafe()
    }

    /// The status lines the iPhone shell shows above its Mailboxes list.
    @ViewBuilder
    private var mobileBannerContent: some View {
        VStack(spacing: 0) {
            switchHoldReleasedAndDeferredNotification(paintsDeferredLine: false)
        }
        .background(.bar)
    }

    private var mobileBannerKey: String {
        Self.mobileBannerKey(
            switchHold: model.switchHold,
            hasReleasedFailedSend: model.releasedFailedSend != nil,
            hasDeferredNotificationOpen: accountModel?.hasDeferredNotificationOpen == true
        )
    }

    /// Changes whenever the banner's content would.
    static func mobileBannerKey(
        switchHold: MobileMailRuntimeSwitchHold?, hasReleasedFailedSend: Bool, hasDeferredNotificationOpen: Bool
    ) -> String {
        "\(String(describing: switchHold))|\(hasReleasedFailedSend)|\(hasDeferredNotificationOpen)"
    }

    /// The key while the banner has nothing to show, so the shell gets no banner at all.
    static let noMobileBannerKey = mobileBannerKey(
        switchHold: nil, hasReleasedFailedSend: false, hasDeferredNotificationOpen: false
    )

    /// The Direct sync's state as Activity rows for the iPhone shell.
    /// `notice` is the stalled-sync line ("Mail sync is still in progress."), shown under a
    /// running sync that isn't downloading history.
    static func hostActivities(
        accountTitle: String, isSyncing: Bool, failure: String?,
        historyMailbox: String?, downloaded: Int, total: Int?,
        notice: String? = nil
    ) -> [MobileHostActivity] {
        if let failure {
            return [MobileHostActivity(kind: .failed, accountTitle: accountTitle, detail: failure)]
        }
        guard isSyncing else { return [] }
        if let historyMailbox, let total, total > 0 {
            return [MobileHostActivity(
                kind: .syncing, accountTitle: accountTitle,
                detail: "\(historyMailbox) · \(downloaded) of \(total)",
                fraction: Double(downloaded) / Double(total)
            )]
        }
        return [MobileHostActivity(kind: .syncing, accountTitle: accountTitle, detail: notice)]
    }

    private var currentHostActivities: [MobileHostActivity] {
        let isSyncing = localSyncing || historySyncTask != nil
        guard usesMobileShell, isDirectMailRoute, !readOnly, isSyncing || localSyncFailure != nil else { return [] }
        // The failing account, else the one downloading its history, else mail in general.
        let accountID = localSyncFailure != nil ? localSyncFailureAccountID : historyAccountID
        let title = accountID.flatMap { id in runtimeAccounts.first { $0.id == id }?.email.rawValue } ?? "mail"
        return Self.hostActivities(
            accountTitle: title,
            isSyncing: isSyncing,
            failure: localSyncFailure,
            historyMailbox: historyProgress?.mailboxPath,
            downloaded: historyProgress?.downloaded ?? 0,
            total: historyProgress?.estimatedTotal,
            // The iPhone shell has no row for the old root's stalled-sync line; it goes here.
            notice: localSyncNotice
        )
    }

    /// Changes whenever the pull-to-refresh action's captured inputs do.
    static func mobileSyncActionKey(route: MobileMailRoute, readOnly: Bool, scenePhase: ScenePhase) -> String {
        "\(preparationTaskIdentity(route: route, readOnly: readOnly))|\(scenePhase)"
    }

    private func configureMobileEnvironment() {
        mobileEnvironment.syncAction = {
            guard isDirectMailRoute, !readOnly else { return }
            let refresh = beginDirectMailRefresh(replacingWaiter: true)
            await withTaskCancellationHandler {
                await refresh?.value
            } onCancel: {
                refresh?.cancel()
            }
        }
        // Retry restarts a sync still running, as the old root's Retry did: an offline sync
        // can wait far longer than the user will.
        mobileEnvironment.retryAction = {
            guard isDirectMailRoute, !readOnly else { return }
            retryDirectMail()
            await localSyncTask?.value
        }
    }

    /// How many accounts this runtime knows about, on either side (local or Sync Node).
    private var accountCount: Int {
        Self.accountCount(nodeAccounts: accountModel?.mailAccounts.count ?? 0, runtimeAccounts: runtimeAccounts.count)
    }

    static func accountCount(nodeAccounts: Int, runtimeAccounts: Int) -> Int {
        max(nodeAccounts, runtimeAccounts)
    }

    /// The selected account's address, shown read-only in Compose's From row when there's more
    /// than one account (F7: replaces a `Bool`, which named the wrong account).
    private var fromAddress: String? {
        fromAddress(accounts: runtimeAccounts)
    }

    private func fromAddress(accounts: [Account]) -> String? {
        guard let runtime = model.runtime else { return nil }
        return Self.fromAddress(
            accountCount: Self.accountCount(nodeAccounts: accountModel?.mailAccounts.count ?? 0, runtimeAccounts: accounts.count),
            selectedAccountID: runtime.configuration.selectedAccountID,
            accounts: accounts
        )
    }

    /// Re-reads the runtime's accounts: on a new runtime and on an account change, never in
    /// `body`.
    private func refreshRuntimeAccounts() {
        let accounts = model.runtime?.store.accounts ?? []
        runtimeAccounts = accounts
        mobileEnvironment.fromAddress = fromAddress(accounts: accounts)
    }

    static func fromAddress(accountCount: Int, selectedAccountID: AccountID?, accounts: [Account]) -> String? {
        guard accountCount > 1, let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }?.email.rawValue
    }

    private var mailContent: some View {
        Group {
            if let runtime = model.runtime, usesMobileShell {
                // iPhone: the native shell. A new runtime gets a new view identity, so the
                // previous account's session never survives under the new account.
                MobileMailRuntimeScoped(generation: model.runtimeGeneration) {
                    MobileMailShell(
                        session: runtime.makeMailSession(
                            composerPresentationPolicy: .embedded,
                            commitDelay: Self.mobileCommitDelay,
                            providerOnboarding: allowsGoogleProviderOnboarding ? { beginGoogleAuthorization() } : nil,
                            accountSessionModel: nil,
                            initialDestination: model.initialDestination,
                            initialSelectedMessageID: model.initialSelectedMessageID,
                            onAccountSetupConnected: { accountID in
                                localAccountSetupConnected(accountID, runtime: runtime)
                            },
                            contactDirectory: contactDirectory
                        ),
                        environment: mobileEnvironment
                    )
                    .environment(\.plainpostDownloadCompleteHistory, downloadCompleteHistory)
                    .environment(\.plainpostHistoryDownloadStatus, historyDownloadStatus)
                    .environment(\.plainpostHistoryDownloadAccountID, historyAccountID)
                    .plainpostSettingsHost(settingsHost)
                }
            } else if let runtime = model.runtime {
                // A new runtime gets a new view identity, so the previous
                // account's composer, inbox actions and settings never
                // survive under the new account.
                MobileMailRuntimeScoped(generation: model.runtimeGeneration) {
                    runtime.makeRootView(
                        composerPresentationPolicy: .embedded,
                        providerOnboarding: allowsGoogleProviderOnboarding ? { beginGoogleAuthorization() } : nil,
                        initialDestination: model.initialDestination,
                        initialSelectedMessageID: model.initialSelectedMessageID,
                        onAccountSetupConnected: { accountID in
                            localAccountSetupConnected(accountID, runtime: runtime)
                        }
                    )
                    .environment(\.plainpostDownloadCompleteHistory, downloadCompleteHistory)
                    .environment(\.plainpostHistoryDownloadStatus, historyDownloadStatus)
                    .environment(\.plainpostHistoryDownloadAccountID, historyAccountID)
                    .plainpostSettingsHost(settingsHost)
                }
            } else if let failure = model.failure {
                switch unavailableRecovery {
                case .accountAuthority(let offersSyncNodeSetup):
                    if let accountModel {
                        MobileAccountMailUnavailableView(account: accountModel, offersSyncNodeSetup: offersSyncNodeSetup)
                    }
                case .route:
                    ContentUnavailableView {
                        Label("Mail unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Retry") {
                            Task {
                                await model.prepare(
                                    readOnly: readOnly,
                                    route: route,
                                    isUserAccountSwitch: false,
                                    isAccountListed: { id in
                                        accountModel?.mailAccounts.contains { $0.logicalMailboxID == id } ?? true
                                    }
                                )
                            }
                        }
                        .accessibilityIdentifier("mail.retry-open")
                    }
                }
            } else {
                ProgressView("Opening mail…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Mailbox assignment and per-mailbox notification policy are sheets,
        // never panels over the mail: a panel covered the composer's Send bar
        // and the undo and failed-send snackbar.
        .sheet(isPresented: Binding(
            get: { !discoveredMailboxes.isEmpty },
            set: { presented in
                guard !presented, !assigningMailboxes else { return }
                discoveredMailboxes = []
                selectedMailboxHandles = []
            }
        ), onDismiss: {
            connectedProviderIdentity = nil
            assignmentMessage = nil
            if let message = providerMessageAfterAssignment {
                providerMessageAfterAssignment = nil
                providerMessage = message
            }
        }) {
            mailboxAssignmentSheet
        }
        .modifier(MailboxNotificationPolicySheetPresenter(
            accountModel: accountModel,
            isAvailable: showsMailboxNotificationPolicy
        ) {
            mailboxNotificationPolicySheet
        })
    }

    private var unavailableRecovery: MobileMailUnavailableRecovery {
        MobileMailUnavailableRecovery(
            route: route,
            isAccountMode: accountModel != nil,
            offersSyncNodeSetup: accountModel?.securityModel != nil
        )
    }

    /// The Settings pieces only this app can build: the Plainpost Account and Sync Node pages,
    /// the push-notification rows, the Node's mail accounts and the local-mail actions.
    private var settingsHost: PlainpostSettingsHost {
        var host = PlainpostSettingsHost()
        // Every account, Sync Node ones included, is the runtime's: Settings lists them from it.
        host.useSyncNodeForAccount = useSyncNodeForAccount
        host.connectPlainpostAccount = accountModel == nil ? connectPlainpostAccount : nil
        if let accountModel, let security = accountModel.securityModel {
            host.plainpostAccountPage = { AnyView(MobilePlainpostAccountPage(model: security)) }
            host.syncNodePage = { nodeSettings in
                AnyView(MobileSyncNodePage(account: accountModel, nodeSettings: nodeSettings))
            }
        }
        // Pushes come from a Sync Node or, for Direct accounts, a Mac with the same account.
        if let accountModel {
            host.pushNotificationRows = { AnyView(MobilePushNotificationRows(model: accountModel)) }
        }
        return host
    }

    private var showsMailboxNotificationPolicy: Bool {
        (!assignedMailboxes.isEmpty || !(accountModel?.directNotificationMailboxRows.isEmpty ?? true)) && accountModel != nil && !readOnly
    }

    /// The selected account's header and the deferred-switch status. It sits
    /// above the mail in layout and never covers the runtime's own bars.
    private var accountChrome: some View {
        VStack(spacing: 0) {
            if !usesMobileShell {
                // While typing on an iPhone in landscape the header steps aside
                // with the account bar, so the composer keeps its height.
                switchHoldReleasedAndDeferredNotification(paintsDeferredLine: true)
            }
        }
    }

    /// The deferred-switch status and the deferred-notification line, shared by the inline
    /// chrome (iPad and macOS) and the iPhone shell's banner. The banner paints one bar
    /// behind all its lines; a deferred line with its own bar inside the Compose sheet's
    /// inset is not hittable, so only the inline chrome paints the line itself.
    @ViewBuilder
    private func switchHoldReleasedAndDeferredNotification(paintsDeferredLine: Bool) -> some View {
        // Shown whenever a replacement waits, with or without the account header, so a held
        // failure can always be dismissed.
        if let hold = model.switchHold {
            MobileMailRuntimeSwitchHoldStatus(hold: hold, dismiss: { model.dismissFailedSend() })
        }
        // A failed send released by a replacement other than the user's switch lost its own
        // notice with its runtime.
        if let releasedFailedSend = model.releasedFailedSend {
            MobileMailReleasedFailedSendNotice(notice: releasedFailedSend, dismiss: { model.dismissReleasedFailedSendNotice() })
        }
        if accountModel?.hasDeferredNotificationOpen == true {
            Text("Save or close the draft to open the notification.")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(paintsDeferredLine ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
                .accessibilityIdentifier("mail-account.deferred-notification")
        }
    }

    private var allowsGoogleProviderOnboarding: Bool {
        accountModel?.allowsGoogleProviderOnboarding ?? true
    }

    @MainActor
    private func loadAssignedMailboxes() async {
        guard !readOnly, let accountModel else { return }
        assignedMailboxes = []
        mailboxPolicyMessage = nil
        if let runtime = model.runtime {
            await accountModel.setDirectMailAccounts(runtime.deviceDirectAccounts.map {
                (id: $0.id, email: $0.email.rawValue, imapHost: $0.imapHost)
            })
        }
        let assignments = await accountModel.refreshNotificationProducerAssignments()
        let syncMailboxIDs = Set(assignments.filter { $0.kind == .syncNode }.map(\.logicalMailboxID))
        if accountModel.notificationProducerAuthority == .syncNode || accountModel.notificationProducerAuthority == .mixed {
            // Sync Node rows are sourced only from the current provider
            // authority. If it is unavailable, keep the rows empty rather
            // than leaking stale Direct/provider state across a switch.
            if let catalogMailboxes = accountModel.selectedAccountNotificationPolicyMailboxes(syncNodeMailboxIDs: syncMailboxIDs) {
                // Policy rows follow the selected account from the
                // authenticated account catalog. /v1/status names only the
                // primary account, so it cannot serve other accounts.
                assignedMailboxes = catalogMailboxes
            } else if let providerController,
                      let status = try? await providerController.waitForTrustedProviderStatus(timeout: .seconds(5)) {
                assignedMailboxes = status.assignments.filter {
                    guard let mailbox = $0.logicalMailboxID else { return false }
                    return syncMailboxIDs.contains(mailbox.rawValue)
                }
            }
        }
        let providerMailboxes = assignedMailboxes.compactMap { mailbox in
            mailbox.logicalMailboxID.map { NotificationPolicyProviderMailbox(logicalMailboxID: $0, label: mailbox.displayName) }
        }
        do {
            _ = try await policyCoordinator.refresh(
                assignments: { assignments }, providerMailboxes: providerMailboxes,
                policyProvider: { mailbox in try await accountModel.notificationPolicyPresentation(for: mailbox) }
            )
        } catch is CancellationError {
            return
        } catch {
            // The coordinator has already published a bounded unavailable state.
        }
    }

    private var notificationPolicyRows: [NotificationPolicyMailboxPresentationRow] {
        policyCoordinator.current().rows
    }

    static func notificationPolicyRows(
        authority: NotificationProducerAuthority?,
        assignedMailboxes: [SyncNodeProviderMailbox],
        directMailboxes: [NotificationDirectMailboxRow]
    ) -> [NotificationMailboxPolicyRow] {
        switch authority {
        case .mac:
            return directMailboxes.map { NotificationMailboxPolicyRow(id: $0.logicalMailboxID, label: $0.label) }
        case .syncNode:
            return assignedMailboxes.compactMap { mailbox in
                mailbox.logicalMailboxID.map { NotificationMailboxPolicyRow(id: $0, label: mailbox.displayName) }
            }
        case .mixed:
            let direct = directMailboxes.map { NotificationMailboxPolicyRow(id: $0.logicalMailboxID, label: $0.label) }
            let provider = assignedMailboxes.compactMap { mailbox in
                mailbox.logicalMailboxID.map { NotificationMailboxPolicyRow(id: $0, label: mailbox.displayName) }
            }
            return direct + provider
        case nil:
            return []
        }
    }

    @MainActor
    private func beginGoogleAuthorization() {
        guard let providerController else {
            accountModel?.finishNotificationProducerEnrollment()
            return
        }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "PLAINPOST_GOOGLE_CLIENT_ID") as? String,
              !clientID.isEmpty,
              !clientID.hasPrefix("$("),
              let redirectURI = Bundle.main.object(forInfoDictionaryKey: "PLAINPOST_GOOGLE_REDIRECT_URI") as? String,
              !redirectURI.isEmpty,
              !redirectURI.hasPrefix("$(")
        else {
            providerMessage = "Google provider setup is unavailable in this build."
            accountModel?.finishNotificationProducerEnrollment()
            return
        }

        do {
            let request = try providerController.makeGoogleAuthorizationRequest(
                clientID: clientID,
                redirectURI: redirectURI
            )
            let presentation = MobileAuthenticationPresentationContext()
            authenticationPresentationContext = presentation
            authenticationSession = try providerController.makeGoogleAuthenticationSession(
                request: request,
                presentationContextProvider: presentation
            ) { callbackURL, error in
                Task { @MainActor in
                    authenticationSession = nil
                    authenticationPresentationContext = nil
                    guard let callbackURL else {
                        providerMessage = error?.localizedDescription ?? "Google authorization was cancelled."
                        accountModel?.finishNotificationProducerEnrollment()
                        return
                    }
                    do {
                        let result = try await providerController.completeGoogleAuthorization(callbackURL: callbackURL)
                        if result.discoveredMailboxes.isEmpty {
                            providerMessage = "Connected \(result.providerIdentity), but no selectable mailboxes were returned."
                        } else {
                            // The assignment sheet says who connected; an
                            // alert at the same time would block the sheet.
                            connectedProviderIdentity = result.providerIdentity
                            selectedMailboxHandles = Set(result.discoveredMailboxes.map(\.mailboxHandle))
                            discoveredMailboxes = result.discoveredMailboxes
                        }
                        accountModel?.finishNotificationProducerEnrollment()
                    } catch {
                        providerMessage = "Google authorization could not be completed."
                        accountModel?.finishNotificationProducerEnrollment()
                    }
                }
            }
            authenticationSession?.start()
        } catch {
            providerMessage = "Google authorization could not be started."
            accountModel?.finishNotificationProducerEnrollment()
        }
    }

    private var mailboxAssignmentSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(discoveredMailboxes, id: \.mailboxHandle) { mailbox in
                        Button {
                            if selectedMailboxHandles.contains(mailbox.mailboxHandle) {
                                selectedMailboxHandles.remove(mailbox.mailboxHandle)
                            } else {
                                selectedMailboxHandles.insert(mailbox.mailboxHandle)
                            }
                        } label: {
                            Label(mailbox.displayName, systemImage: selectedMailboxHandles.contains(mailbox.mailboxHandle) ? "checkmark.circle.fill" : "circle")
                        }
                        .disabled(assigningMailboxes)
                    }
                } header: {
                    if let connectedProviderIdentity {
                        Text("Connected \(connectedProviderIdentity)")
                    }
                } footer: {
                    if let assignmentMessage {
                        Text(assignmentMessage)
                    }
                }
            }
            .navigationTitle("Choose Google mailboxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        discoveredMailboxes = []
                        selectedMailboxHandles = []
                    }
                    .disabled(assigningMailboxes)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(assigningMailboxes ? "Assigning…" : "Assign") {
                        assignSelectedMailboxes()
                    }
                    .disabled(assigningMailboxes || selectedMailboxHandles.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(assigningMailboxes)
    }

    private var mailboxNotificationPolicySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Overrides apply only to the selected mailbox. Clear an override to inherit the account policy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(mailboxPolicySummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(notificationPolicyRows) { row in
                        HStack {
                            Text(row.label)
                            Spacer()
                            switch row.loadState {
                            case .loaded(let policy):
                                Picker("Notification detail", selection: Binding(
                                    get: { previewPolicy(for: policy) },
                                    set: { updateMailboxPolicy($0, mailbox: row.id) }
                                )) {
                                    Text("Full").tag(NotificationPreviewPolicy.rich)
                                    Text("Sender + subject").tag(NotificationPreviewPolicy.senderAndSubject)
                                    Text("Generic").tag(NotificationPreviewPolicy.generic)
                                    Text("Off").tag(NotificationPreviewPolicy.off)
                                }
                                .pickerStyle(.menu)
                                if policy.override {
                                    Button("Clear") { clearMailboxPolicy(row.id) }
                                        .buttonStyle(.bordered)
                                }
                            case .loading:
                                ProgressView().controlSize(.small)
                            case .error(let error):
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(error.message).font(.caption).foregroundStyle(.secondary)
                                    Button("Retry") { retryMailboxPolicy(row.id) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    if let mailboxPolicyMessage {
                        Text(mailboxPolicyMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A container, so each row keeps its own label and identifier.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notifications.mailbox-policy")
            }
            .navigationTitle("Notification policy by mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { accountModel?.isMailboxNotificationPolicyPresented = false }
                        .accessibilityIdentifier("notifications.mailbox-policy.done")
                }
            }
        }
    }

    private var mailboxPolicySummary: String {
        let overridden = notificationPolicyRows.reduce(into: 0) { count, row in
            if case .loaded(let policy) = row.loadState, policy.override {
                count += 1
            }
        }
        return "\(overridden) mailbox override\(overridden == 1 ? "" : "s") active"
    }

    private func previewPolicy(for policy: NotificationPolicyPresentationState) -> NotificationPreviewPolicy {
        switch policy.mode {
        case .richPreview: .rich
        case .senderSubject: .senderAndSubject
        case .generic: .generic
        case .off: .off
        }
    }

    @MainActor
    private func updateMailboxPolicy(_ policy: NotificationPreviewPolicy, mailbox: LogicalMailboxID) {
        guard let accountModel else { return }
        mailboxPolicyMessage = nil
        Task { @MainActor in
            do {
                try await accountModel.setNotificationPreviewPolicy(policy, for: mailbox)
                let state = try await accountModel.notificationPolicyPresentation(for: mailbox)
                policyCoordinator.setLoaded(mailbox, state: state)
            } catch is CancellationError {
                return
            } catch NotificationPolicyRemoteError.conflict {
                // A CAS conflict is never a successful local edit. Refresh
                // the authoritative mode's value before presenting retry UI.
                do {
                    let result = try await policyCoordinator.refreshAfterConflict(
                        mailbox,
                        policyProvider: { mailbox in try await accountModel.notificationPolicyPresentation(for: mailbox) }
                    )
                    mailboxPolicyMessage = result.message
                } catch is CancellationError {
                    return
                } catch {
                    policyCoordinator.setError(mailbox, error: .unavailable)
                    mailboxPolicyMessage = NotificationPolicyPresentationLoadError.unavailable.message
                }
            } catch {
                policyCoordinator.setError(mailbox, error: .unavailable)
                mailboxPolicyMessage = "Mailbox notification policy could not be updated."
            }
        }
    }

    @MainActor
    private func clearMailboxPolicy(_ mailbox: LogicalMailboxID) {
        guard let accountModel else { return }
        mailboxPolicyMessage = nil
        Task { @MainActor in
            do {
                try await accountModel.clearNotificationPreviewPolicy(for: mailbox)
                let state = try await accountModel.notificationPolicyPresentation(for: mailbox)
                policyCoordinator.setLoaded(mailbox, state: state)
            } catch is CancellationError {
                return
            } catch NotificationPolicyRemoteError.conflict {
                do {
                    let result = try await policyCoordinator.refreshAfterConflict(
                        mailbox,
                        policyProvider: { mailbox in try await accountModel.notificationPolicyPresentation(for: mailbox) }
                    )
                    mailboxPolicyMessage = result.message
                } catch is CancellationError {
                    return
                } catch {
                    policyCoordinator.setError(mailbox, error: .unavailable)
                    mailboxPolicyMessage = NotificationPolicyPresentationLoadError.unavailable.message
                }
            } catch {
                policyCoordinator.setError(mailbox, error: .unavailable)
                mailboxPolicyMessage = "Mailbox notification policy could not be cleared."
            }
        }
    }

    @MainActor
    private func retryMailboxPolicy(_ mailbox: LogicalMailboxID) {
        guard let accountModel else { return }
        Task { @MainActor in
            do {
                let result = try await policyCoordinator.retry(
                    mailbox,
                    policyProvider: { mailbox in try await accountModel.notificationPolicyPresentation(for: mailbox) }
                )
                mailboxPolicyMessage = result.message
            } catch is CancellationError {
                return
            } catch {
                policyCoordinator.setError(mailbox, error: .unavailable)
                mailboxPolicyMessage = NotificationPolicyPresentationLoadError.unavailable.message
            }
        }
    }

    @MainActor
    private func assignSelectedMailboxes() {
        guard let providerController, !selectedMailboxHandles.isEmpty else { return }
        let selections = selectedMailboxHandles.sorted().compactMap { handle in
            discoveredMailboxes.first(where: { $0.mailboxHandle == handle }).map {
                SyncNodeMailboxSelection(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID)
            }
        }
        guard selections.count == selectedMailboxHandles.count else {
            assignmentMessage = "The selected mailbox assignment was invalid."
            return
        }
        assigningMailboxes = true
        assignmentMessage = nil
        Task { @MainActor in
            defer { assigningMailboxes = false }
            do {
                _ = try await providerController.assignGoogleMailboxes(selections)
                providerMessageAfterAssignment = "Google mailboxes assigned."
                discoveredMailboxes.removeAll()
                selectedMailboxHandles.removeAll()
            } catch {
                // The sheet stays open so the selection can be retried.
                assignmentMessage = "Google mailbox assignment could not be completed."
            }
        }
    }
}

/// Presents the per-mailbox notification policy sheet when the account's
/// notification menu asks for it. The mail root holds the account model
/// without observing it, so this modifier observes the request.
private struct MailboxNotificationPolicySheetPresenter<SheetContent: View>: ViewModifier {
    let accountModel: MobileAccountModel?
    let isAvailable: Bool
    @ViewBuilder let sheet: () -> SheetContent

    func body(content: Content) -> some View {
        if let accountModel {
            content.modifier(ObservingPresenter(accountModel: accountModel, isAvailable: isAvailable, sheet: sheet))
        } else {
            content
        }
    }

    private struct ObservingPresenter: ViewModifier {
        @ObservedObject var accountModel: MobileAccountModel
        let isAvailable: Bool
        let sheet: () -> SheetContent

        func body(content: Content) -> some View {
            content.sheet(isPresented: Binding(
                get: { isAvailable && accountModel.isMailboxNotificationPolicyPresented },
                set: { if !$0 { accountModel.isMailboxNotificationPolicyPresented = false } }
            ), content: sheet)
        }
    }
}

struct NotificationMailboxPolicyRow: Identifiable {
    let id: LogicalMailboxID
    let label: String
}

private struct NotificationProducerSelectionView: View {
    let state: NotificationProducerSelectionState
    let targets: [NotificationProducerTarget]
    let selectTarget: (NotificationProducerTarget) -> Void
    let configureAppleRequest: (ASAuthorizationAppleIDRequest) -> UUID?
    let completeAppleAuthorization: (Result<ASAuthorization, Error>, UUID?) -> Void
    let finish: () -> Void
    let cancel: () -> Void
    @State private var appleAttemptID: UUID?

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .selecting:
                    Section("Trusted producers") {
                        ForEach(targets) { target in
                            Button { selectTarget(target) } label: {
                                Label(target.kind == .mac ? "Trusted Mac" : "Sync Node", systemImage: target.kind == .mac ? "desktopcomputer" : "server.rack")
                            }
                            .accessibilityIdentifier("notifications.select-producer.\(target.kind.rawValue)")
                        }
                    }
                case .authenticating(let authority):
                    Section {
                        SignInWithAppleButton(.continue) { request in
                            guard appleAttemptID == nil, let id = configureAppleRequest(request) else { return }
                            appleAttemptID = id
                        } onCompletion: { result in
                            let id = appleAttemptID
                            appleAttemptID = nil
                            completeAppleAuthorization(result, id)
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 50)
                    } header: {
                        Text("Confirm \(authority == .mac ? "Mac" : "Sync Node") selection")
                    } footer: {
                        Text("Apple confirmation is required before the producer assignment changes.")
                    }
                case .selected(let authority, let generation):
                    Section {
                        Label("Selected \(authority == .mac ? "Mac" : "Sync Node") (generation \(generation))", systemImage: "checkmark.shield.fill")
                        Button("Done", action: finish)
                    }
                case .conflict:
                    Section { Text("Another trusted device changed this producer assignment. Refresh and try again.") }
                case .unavailable:
                    Section { Text("Producer selection is unavailable until this account and trusted devices are online.") }
                case .idle:
                    EmptyView()
                }
            }
            .navigationTitle("Notification Producer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
            }
        }
    }
}

private final class MobileAuthenticationPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// What the "Mail unavailable" screen retries. In Plainpost-account mode a
/// missing Node authority is rebuilt by the account model; the new authority
/// then replaces the route. Local mode, and a runtime that failed to open,
/// re-run the route itself.
enum MobileMailUnavailableRecovery: Equatable {
    case route
    case accountAuthority(offersSyncNodeSetup: Bool)

    init(route: MobileMailRoute, isAccountMode: Bool, offersSyncNodeSetup: Bool) {
        guard isAccountMode, case .nodeUnavailable = route else {
            self = .route
            return
        }
        self = .accountAuthority(offersSyncNodeSetup: offersSyncNodeSetup)
    }
}

/// Account-mode mail with no Sync Node authority: says why when the enrollment
/// state can tell, opens Sync Node setup, and retries the account authority.
private struct MobileAccountMailUnavailableView: View {
    @ObservedObject var account: MobileAccountModel
    let offersSyncNodeSetup: Bool
    @State private var showsSyncNodeSetup = false
    @State private var isRetrying = false

    var body: some View {
        // The first authority attempt is still running: not yet a failure,
        // and nothing should load the enrollment state for it.
        if account.isPreparingMailAuthority {
            ProgressView("Opening mail…")
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Mail unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            if let enrollment = account.presentableSyncNodeEnrollmentModel {
                MobileAccountMailUnavailableMessage(account: account, enrollment: enrollment)
            } else {
                Text(account.mailUnavailability.message)
                    .accessibilityIdentifier("mail-unavailable.message")
            }
        } actions: {
            if offersSyncNodeSetup {
                Button("Set Up Sync Node") { showsSyncNodeSetup = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mail-unavailable.set-up-sync-node")
            }
            Button("Retry") { retry() }
                .disabled(isRetrying)
                .accessibilityIdentifier("mail.retry-open")
        }
        // Loads the enrollment state the message reads; a no-op once loaded.
        .task { account.prepareSyncNodeEnrollment() }
        .sheet(isPresented: $showsSyncNodeSetup, onDismiss: retry) {
            NavigationStack {
                MobileSyncNodePage(account: account, nodeSettings: nil)
                    .navigationTitle("Sync Node")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSyncNodeSetup = false }
                                .accessibilityIdentifier("mail-unavailable.sync-node.done")
                        }
                    }
            }
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task { @MainActor in
            await account.retryMailAuthority()
            isRetrying = false
        }
    }
}

/// Observes the enrollment so its connection changes refresh the message the
/// account model derives from it.
private struct MobileAccountMailUnavailableMessage: View {
    let account: MobileAccountModel
    @ObservedObject var enrollment: SyncNodeEnrollmentViewModel

    var body: some View {
        Text(account.mailUnavailability.message)
            .accessibilityIdentifier("mail-unavailable.message")
    }
}
