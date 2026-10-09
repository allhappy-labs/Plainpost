import Foundation
import Combine
import PlainpostCore
import PlainpostDB
import PlainpostOperations

/// One mail UI's controllers, view models and runtime hooks, wired to each other and
/// independent of any platform UI. `PlainpostRootView` and `MobileMailShell` each own one
/// for their runtime and apply `MailSessionLifecycle` with explicit presentation hooks.
/// Replacing an account runtime replaces its session; admitted durable actions must be
/// flushed by the host before replacement, independently of view-task cancellation.
///
/// The session wires its own objects together when it's built (search's after-open refresh,
/// the message actions' reprojection, compose's default thread source). A host connects
/// only what needs its own view state: `openComposerWindow` for a composer window,
/// `willShowAskMailMessage` for any view-only list scoping, `attachAskMailHost()` when
/// Ask Mail appears, and `attachConversationAskMailHost(beforeOpening:openCompose:)` when the
/// ✦ pane appears.
@MainActor
public final class MailSession: ObservableObject {
    private var smartInboxPolicySubscription: AnyCancellable?
    let mailbox: MailboxController
    let refreshBus: MailboxRefreshBus
    let actions: MessageActionController
    let compose: ComposeCoordinator
    let search: SearchController
    let activity: MailActivityCoordinator
    let inboxSnapshot: InboxViewModelSnapshotStore
    /// Each account's folders with unread counts. Loads when a host first refreshes it,
    /// then follows every snapshot refresh.
    let directory: MailboxDirectoryModel
    /// Contacts and recent correspondents for recipient fields. Loads only when a host's
    /// composer asks (see `RecipientSuggestionProvider`).
    let recipientSuggestions: RecipientSuggestionProvider

    let composer: ComposerViewModel
    let undoSend: UndoSendCoordinator
    let askMail: AskMailViewModel
    /// Ask Mail for the ✦ pane, scoped to the open conversation; separate from `askMail`.
    let conversationAskMail: AskMailViewModel
    let aiAssistant: ThreadAIAssistantViewModel
    let threadTranslation: ThreadTranslationViewModel
    /// The ✦ pane's model, shared by the iPhone sheet, the iPad popover and the Mac inspector.
    let conversationAI: ConversationAIPaneModel
    let aiProviderSettings: AIProviderSettingsViewModel
    let translationSettings: TranslationLanguageSettingsViewModel
    let accountSetup: AccountSetupViewModel
    let approvalQueue: ApprovalQueueViewModel
    let messageLabelActions: MessageLabelActions
    let mailRules: MailRulesViewModel
    let mailLabels: MailLabelsViewModel
    let maintenance: MailMaintenanceViewModel
    let smartInboxActivity: SmartInboxActivityCoordinator
    let nodeStatus: NodeMailModeStatusModel
    let attachmentState: PlainpostAttachmentState

    let mailSearch: MailSearchViewModel
    let searchIndexRebuild: MailSearchIndexRebuildController
    let inboxMailActions: InboxMailActionViewModel
    let auditLog: AuditLogViewModel
    let commandCenter: CommandCenterViewModel
    let commandSurfaces: MailboxCommandSurfaceLifecycle
    let storeChangeMonitor: MailStoreChangeMonitor
    let accountSessionModel: AccountSessionViewModel?
    let nodeSettings: SyncNodeSettingsViewModel?
    let composerActivity: PlainpostComposerActivity?

    let composerPresentationPolicy: ComposerPresentationPolicy
    let humanMessageOpenCoordinator: HumanMessageOpenCoordinator
    let openAttachment: (MailAttachment) async -> Void
    /// The image parts a message's HTML names by `cid:`.
    let loadInlineImages: @MainActor (String) -> [InlineImagePart]
    /// The account's saved composer drafts, how to reopen one, and how to delete one.
    let localDrafts: LocalDraftActions
    let invalidateInboxSnapshot: () -> Void
    let refreshMailSearchMailboxes: (Bool) async -> Void
    let runSmartInbox: (String, PlainpostSmartInboxRunMode, String?) async throws -> String
    let aiGenerationAvailable: () -> Bool
    /// False while the mailbox is read-only (offline lease, cached read-only runtime): Ask Mail
    /// then hides and refuses replies, drafts and mail actions.
    let allowsMailboxMutations: () -> Bool
    let configureAIAssistant: (ThreadAIAssistantViewModel, String) -> Void
    let configureAskMail: (AskMailViewModel, String) -> Void
    let configureThreadTranslation: (ThreadTranslationViewModel, String) -> Void
    let onAccountSetupConnected: (AccountID) -> Void
    let accountForMessage: (String) -> Account?
    /// Up to `limit` of one account folder's rows, newest first, for the iPhone folder list.
    /// Throws when the folder can't be read, so the list shows the failure rather than an
    /// empty folder.
    let loadFolderRows: (AccountID, String, Int) async throws -> [MessageRowModel]

    /// Opens a composer window for a `.window` answer. The macOS root connects `openWindow`;
    /// a host that only embeds the composer leaves it alone.
    var openComposerWindow: @MainActor (PlainpostComposerWindowRequest) -> Void = { _ in }
    /// Runs before Ask Mail shows a message in the mailbox, so a host can drop view-only list
    /// scoping (the macOS root clears its notification inbox scope).
    var willShowAskMailMessage: @MainActor () -> Void = {}

    private static let askMailReplyTargetUnavailable = "Couldn't open that message to reply."

    /// Builds the controllers in dependency order (bus, mailbox, actions, compose, search,
    /// activity) around the given view models, and wires them to each other.
    init(
        inbox: InboxViewModel,
        inboxProvider: ((String?) async -> InboxViewModel)?,
        loadMoreInboxProvider: ((String?) async -> InboxViewModel)?,
        threadProvider: ((String) async -> ThreadDetailModel?)? = nil,
        initialDestination: PlainpostDestination,
        initialInboxMode: String,
        initialSelectedMessageID: String?,
        initialNavigation: MailboxWorkspaceNavigationState,
        directory: MailboxDirectoryModel,
        recipientSuggestions: RecipientSuggestionProvider,
        accountSetup: AccountSetupViewModel,
        accountSessionModel: AccountSessionViewModel?,
        mailSearch: MailSearchViewModel,
        searchIndexRebuild: MailSearchIndexRebuildController,
        approvalQueue: ApprovalQueueViewModel,
        composer: ComposerViewModel,
        undoSend: UndoSendCoordinator,
        auditLog: AuditLogViewModel,
        commandCenter: CommandCenterViewModel,
        aiAssistant: ThreadAIAssistantViewModel,
        askMail: AskMailViewModel,
        conversationAskMail: AskMailViewModel,
        conversationActionDetector: any ConversationActionDetecting = NoConversationActionDetector(),
        aiProviderSettings: AIProviderSettingsViewModel,
        translationSettings: TranslationLanguageSettingsViewModel,
        threadTranslation: ThreadTranslationViewModel,
        inboxMailActions: InboxMailActionViewModel,
        nodeSettings: SyncNodeSettingsViewModel?,
        nodeStatus: NodeMailModeStatusModel,
        attachmentState: PlainpostAttachmentState,
        mailRules: MailRulesViewModel,
        mailLabels: MailLabelsViewModel,
        messageLabelActions: MessageLabelActions,
        smartInboxActivity: SmartInboxActivityCoordinator,
        maintenance: MailMaintenanceViewModel,
        composerActivity: PlainpostComposerActivity?,
        composerPresentationPolicy: ComposerPresentationPolicy,
        commitDelay: Duration,
        showsComposer: Bool,
        showsSearch: Bool,
        ownAddresses: @escaping @MainActor () -> Set<String>,
        loadForwardAttachments: @escaping (String) async -> (attachments: [DraftAttachment], unavailable: [String]),
        openMessage: @escaping (String) async throws -> Void,
        openAttachment: @escaping (MailAttachment) async -> Void,
        loadInlineImages: @escaping @MainActor (String) -> [InlineImagePart] = { _ in [] },
        localDrafts: LocalDraftActions = .none,
        invalidateInboxSnapshot: @escaping () -> Void,
        refreshMailSearchMailboxes: @escaping (Bool) async -> Void,
        runSmartInbox: @escaping (String, PlainpostSmartInboxRunMode, String?) async throws -> String,
        aiGenerationAvailable: @escaping () -> Bool,
        allowsMailboxMutations: @escaping () -> Bool,
        configureAIAssistant: @escaping (ThreadAIAssistantViewModel, String) -> Void,
        configureAskMail: @escaping (AskMailViewModel, String) -> Void,
        configureThreadTranslation: @escaping (ThreadTranslationViewModel, String) -> Void,
        onAccountSetupConnected: @escaping (AccountID) -> Void,
        accountForMessage: @escaping (String) -> Account?,
        loadFolderRows: @escaping (AccountID, String, Int) async throws -> [MessageRowModel]
    ) {
        messageLabelActions.transitionMailboxSurface(
            to: PlainpostRootView.messageLabelSurfaceDestination(for: initialDestination)
        )
        let refreshBus = MailboxRefreshBus()
        let mailbox = MailboxController(
            destination: initialDestination,
            mode: initialInboxMode,
            selectedMessageID: initialSelectedMessageID,
            navigation: initialNavigation
        )
        let actions = MessageActionController(
            mailbox: mailbox,
            refreshBus: refreshBus,
            commitDelay: commitDelay,
            performInMailbox: { [inboxMailActions] in await inboxMailActions.perform($0, messageID: $1, shownIn: $2) },
            reproject: {},
            reportFailure: { _ in }
        )
        let inboxSnapshot = InboxViewModelSnapshotStore(
            initialModel: inbox,
            provider: inboxProvider ?? { _ in inbox },
            loadMoreProvider: loadMoreInboxProvider,
            threadProvider: threadProvider,
            projector: { [overlayState = actions.overlayState] in
                OptimisticMailboxProjection.project(
                    $0,
                    overlays: overlayState.overlays,
                    projectionRevision: overlayState.revision
                )
            }
        )
        let compose = ComposeCoordinator(
            composer: composer,
            undoSend: undoSend,
            policy: composerPresentationPolicy,
            aiAssistant: aiAssistant,
            thread: { nil },
            ownAddresses: ownAddresses,
            loadForwardAttachments: loadForwardAttachments
        )
        compose.isPresented = showsComposer
        let search = SearchController(
            search: mailSearch,
            rebuild: searchIndexRebuild,
            mailbox: mailbox,
            accounts: { [accountSetup] in Self.mailSearchAccounts(accountSetup) },
            askMail: { _ in },
            canAskMail: { [aiProviderSettings] in aiProviderSettings.selectedRow?.isSelectable == true },
            afterOpen: { _ in }
        )
        search.isPresented = showsSearch
        let storeChangeMonitor = MailStoreChangeMonitor()
        let activity = MailActivityCoordinator(
            refreshBus: refreshBus,
            inboxSnapshot: inboxSnapshot,
            approvalQueue: approvalQueue,
            nodeStatus: nodeStatus,
            accountSetup: accountSetup,
            storeChanges: storeChangeMonitor,
            smartInbox: smartInboxActivity,
            maintenance: maintenance,
            selectedMessageID: { [mailbox] in mailbox.selectedMessageID },
            invalidateSnapshot: { invalidateInboxSnapshot() },
            refreshSearchMailboxes: { await refreshMailSearchMailboxes($0) },
            refreshSmartInbox: {},
            locale: .current
        )

        self.mailbox = mailbox
        self.refreshBus = refreshBus
        self.actions = actions
        self.compose = compose
        self.search = search
        self.activity = activity
        self.inboxSnapshot = inboxSnapshot
        self.directory = directory
        self.recipientSuggestions = recipientSuggestions
        self.composer = composer
        self.undoSend = undoSend
        self.askMail = askMail
        self.conversationAskMail = conversationAskMail
        self.aiAssistant = aiAssistant
        self.threadTranslation = threadTranslation
        self.conversationAI = ConversationAIPaneModel(
            assistant: aiAssistant, translation: threadTranslation,
            askMail: conversationAskMail, detector: conversationActionDetector
        )
        self.aiProviderSettings = aiProviderSettings
        self.translationSettings = translationSettings
        self.accountSetup = accountSetup
        self.approvalQueue = approvalQueue
        self.messageLabelActions = messageLabelActions
        self.mailRules = mailRules
        self.mailLabels = mailLabels
        self.maintenance = maintenance
        self.smartInboxActivity = smartInboxActivity
        self.nodeStatus = nodeStatus
        self.attachmentState = attachmentState
        self.mailSearch = mailSearch
        self.searchIndexRebuild = searchIndexRebuild
        self.inboxMailActions = inboxMailActions
        self.auditLog = auditLog
        self.commandCenter = commandCenter
        self.commandSurfaces = MailboxCommandSurfaceLifecycle(
            globalCommandCenter: commandCenter,
            labelCommandCenter: MessageLabelCommandCenterViewModel(),
            quickActionFocus: MailboxRowQuickActionFocusCoordinator()
        )
        self.storeChangeMonitor = storeChangeMonitor
        self.accountSessionModel = accountSessionModel
        self.nodeSettings = nodeSettings
        self.composerActivity = composerActivity
        self.composerPresentationPolicy = composerPresentationPolicy
        self.humanMessageOpenCoordinator = HumanMessageOpenCoordinator { messageID in
            try await openMessage(messageID.rawValue)
        }
        self.openAttachment = openAttachment
        self.loadInlineImages = loadInlineImages
        self.localDrafts = localDrafts
        self.invalidateInboxSnapshot = invalidateInboxSnapshot
        self.refreshMailSearchMailboxes = refreshMailSearchMailboxes
        self.runSmartInbox = runSmartInbox
        self.aiGenerationAvailable = aiGenerationAvailable
        self.allowsMailboxMutations = allowsMailboxMutations
        self.configureAIAssistant = configureAIAssistant
        self.configureAskMail = configureAskMail
        self.configureThreadTranslation = configureThreadTranslation
        self.onAccountSetupConnected = onAccountSetupConnected
        self.accountForMessage = accountForMessage
        self.loadFolderRows = loadFolderRows
        connectControllers()
        mailbox.applySmartInboxEnabled(aiProviderSettings.smartInboxEnabled)
        smartInboxPolicySubscription = aiProviderSettings.$smartInboxMode
            .map(\.isEnabled)
            .removeDuplicates()
            .sink { [weak mailbox, weak activity, weak commandCenter] enabled in
                mailbox?.applySmartInboxEnabled(enabled)
                activity?.smartInboxEnabled = enabled
                commandCenter?.smartInboxEnabled = enabled
            }
    }

    /// Wiring between the session's own objects. Everything is captured weakly, so none of
    /// these closures keeps the session alive.
    private func connectControllers() {
        actions.reproject = { [weak inboxSnapshot] in inboxSnapshot?.reproject() }
        activity.didRefreshSnapshot = { [weak directory] in await directory?.refreshIfLoaded() }
        activity.didInvalidateSnapshot = { [weak directory] in directory?.invalidate() }
        directory.didBecomeVisible = { [weak activity] in activity?.requestDirectoryRefresh() }
        // The unscoped thread the reader shows. The macOS root replaces this with one that
        // applies its notification inbox scope.
        compose.thread = { [weak inboxSnapshot, weak mailbox] in
            guard let inboxSnapshot, let mailbox else { return nil }
            return inboxSnapshot.model.thread(for: mailbox.selectedDestination)
        }
        // An opened search hit retires the command surfaces' mailbox source and refreshes the
        // inbox around it.
        search.afterOpen = { [weak self] messageID in
            guard let self else { return }
            commandSurfaces.invalidateMailboxSource()
            invalidateInboxSnapshot()
            Task { [inboxSnapshot] in
                await inboxSnapshot.refresh(selectedMessageID: messageID)
            }
        }
    }

    // MARK: - Mailbox

    /// False for a Sync Node runtime: the Node never erases, so a Trash folder
    /// offers no Delete Permanently there (the request would always be refused).
    var offersPermanentDelete = true

    /// Whether the message is flagged, as the store has it now.
    var isMessageFlagged: (String) -> Bool = { _ in false }

    /// Flag or Unflag, whichever the message's state calls for.
    func flagAction(forMessageID messageID: String) -> InboxMailAction {
        isMessageFlagged(messageID) ? .unflag : .flag
    }

    /// The folders a message can move to: its own account's, except `currentPath`.
    func moveDestinations(forMessageID messageID: String, excluding currentPath: String?) -> [MailFolderRef] {
        guard let accountID = accountForMessage(messageID)?.id,
              let section = directory.sections.first(where: { $0.id == accountID }) else { return [] }
        return section.folders
            .filter { $0.path.caseInsensitiveCompare(currentPath ?? "") != .orderedSame }
            .map { MailFolderRef(accountID: $0.accountID, path: $0.path, name: $0.name, role: $0.role) }
    }

    /// The device's accounts changed: a removed account's open draft and open conversation
    /// close, so nothing is shown or sent for an account that's gone.
    func accountsChanged() {
        compose.accountsChanged()
        let accounts = Set(accountSetup.accounts.map(\.id))
        if let selected = mailbox.selectedMessageID,
           let owner = accountForMessage(selected)?.id, !accounts.contains(owner) {
            mailbox.selectedMessageID = nil
        }
    }

    /// Archive or Delete for this message's account (Gmail archives).
    func removalAction(forMessageID messageID: String) -> InboxMailAction {
        MailRemovalPolicy.primaryAction(for: accountForMessage(messageID))
    }

    #if os(iOS)
    /// Retries a failed sync activity row shown by Mailboxes or the mailbox list: the host's
    /// own sync through `environment`, or this session's own sync otherwise.
    func retry(_ item: MailActivity, environment: MobileMailEnvironment) async {
        if item.id == MailActivity.hostSyncFailureID {
            await environment.retrySync()
        } else {
            await activity.retrySync()
        }
    }
    #endif

    /// The controller's open, after retiring the macOS command surfaces' mailbox source.
    func openMailboxMessage(
        _ messageID: String,
        destination: PlainpostDestination,
        from context: MailboxListContext,
        keepingFolder: Bool = false
    ) {
        commandSurfaces.invalidateMailboxSource()
        // Before the route changes, so a conversation shown moments ago is there on the
        // reader's first frame instead of its loading state.
        inboxSnapshot.showRecentThread(containing: messageID)
        mailbox.openMessage(messageID, destination: destination, from: context, keepingFolder: keepingFolder)
    }

    /// Reply or Forward from a list row: opens the message so its thread loads, then asks
    /// compose, unless the user opened something else meanwhile. Refuses while the mailbox
    /// is read-only, matching the conversation screen's Reply gate.
    func composeFromList(_ request: ComposeRequest, messageID: String, destination: PlainpostDestination) async {
        guard allowsMailboxMutations() else { return }
        // A list row: the open folder, if any, stays.
        openMailboxMessage(messageID, destination: destination, from: mailbox.currentListContext(), keepingFolder: true)
        await inboxSnapshot.refresh(selectedMessageID: messageID)
        guard mailbox.selectedMessageID == messageID else { return }
        _ = await compose.request(request)
    }

    /// Runs Smart Inbox, then advances the mailbox; the activity line is refreshed either way.
    func refreshSmartInbox(
        using providerID: String,
        mode: PlainpostSmartInboxRunMode,
        locale: Locale
    ) async {
        guard !Task.isCancelled, aiGenerationAvailable(), aiProviderSettings.smartInboxEnabled else { return }
        defer {
            if !Task.isCancelled { smartInboxActivity.refresh(locale: locale) }
        }
        do {
            _ = try await runSmartInbox(providerID, mode, nil)
            guard !Task.isCancelled else { return }
            refreshBus.bump()
        } catch {
            // The durable activity lookup is the only processing-status
            // surface. A persisted failure supplies its own safe copy.
        }
    }

    // MARK: - Compose

    /// Asks the compose coordinator for `request` and hands a window answer to `openComposerWindow`.
    private func presentCompose(_ request: ComposeRequest) {
        Task {
            await openCompose(request)
        }
    }

    /// `presentCompose` for callers already in a task, so nothing can change between their
    /// checks and the request.
    private func openCompose(_ request: ComposeRequest) async {
        if case let .window(windowRequest) = await compose.request(request) {
            openComposerWindow(windowRequest)
        }
    }

    // MARK: - Ask Mail

    /// Wires AskMailHostActions to mailbox, actions and compose. Call once when the Ask Mail view
    /// appears, and again when the account sources change.
    func attachAskMailHost() {
        askMail.setHost(askMailHostActions(for: askMail, beforeOpening: {}, hostCompose: nil))
    }

    /// The ✦ pane's Ask Mail, wired like `attachAskMailHost`. `beforeOpening` runs before it
    /// opens a message or a composer, so the host can close the sheet or popover the pane is in.
    /// `openCompose` is the pane's own compose path, the one Edit in Compose takes: a reply or
    /// draft to a message of the open conversation goes there instead, so Compose opens only
    /// once the pane has closed. Without it, Compose opens as it does for global Ask Mail.
    func attachConversationAskMailHost(
        beforeOpening: @escaping @MainActor () -> Void,
        openCompose: (@MainActor (ComposeRequest) -> Void)? = nil
    ) {
        conversationAskMail.setHost(askMailHostActions(
            for: conversationAskMail, beforeOpening: beforeOpening, hostCompose: openCompose
        ))
    }

    /// `viewModel`'s host: its reply and draft targets resolve against its own answers, and it
    /// reports the problems they hit.
    private func askMailHostActions(
        for viewModel: AskMailViewModel,
        beforeOpening: @escaping @MainActor () -> Void,
        hostCompose: (@MainActor (ComposeRequest) -> Void)?
    ) -> AskMailHostActions {
        AskMailHostActions(
            openMessage: { [weak self] in
                beforeOpening()
                self?.openAskMailSource($0)
            },
            reply: { [weak self, weak viewModel] messageID in
                guard let self, let viewModel else { return }
                replyToAskMailMessage(messageID, for: viewModel, beforeOpening: beforeOpening, hostCompose: hostCompose)
            },
            openDraft: { [weak self, weak viewModel] draft in
                guard let self, let viewModel else { return }
                openAskMailDraft(draft, for: viewModel, beforeOpening: beforeOpening, hostCompose: hostCompose)
            },
            mailAction: { [weak self] action, messageID in
                await self?.performAskMailAction(action, messageID: messageID) ?? false
            },
            allowsMutations: { [weak self] in self?.allowsMailboxMutations() ?? false },
            mailActionsSettled: { [weak self] in self?.actions.askMailActionsSettled() }
        )
    }

    func openAskMailSource(_ source: MailKnowledgeSource) {
        showAskMailMessage(source.messageID.rawValue, mailboxPath: source.mailboxPath)
        Task {
            await inboxSnapshot.refresh(selectedMessageID: source.messageID.rawValue)
        }
    }

    /// Opens the Ask Mail target in the mailbox it lives in (`viewModel`'s answer source for it,
    /// or the inbox), then waits for its thread to load. Returns the thread when the message is
    /// still the one selected, so a reply is never attached to a different message.
    private func openAskMailMessageForReply(
        _ messageID: MessageID,
        for viewModel: AskMailViewModel
    ) async -> ThreadDetailModel? {
        showAskMailTarget(messageID, for: viewModel)
        await inboxSnapshot.refresh(selectedMessageID: messageID.rawValue)
        guard mailbox.selectedMessageID == messageID.rawValue else { return nil }
        let thread = inboxSnapshot.model.thread(for: mailbox.selectedDestination)
        guard thread.messages.contains(where: { $0.id == messageID.rawValue }) else { return nil }
        return thread
    }

    private func replyToAskMailMessage(
        _ messageID: MessageID,
        for viewModel: AskMailViewModel,
        beforeOpening: @MainActor () -> Void,
        hostCompose: (@MainActor (ComposeRequest) -> Void)?
    ) {
        composeAskMailReply(
            .reply(messageID: messageID.rawValue),
            to: messageID,
            for: viewModel,
            beforeOpening: beforeOpening,
            hostCompose: hostCompose
        )
    }

    private func openAskMailDraft(
        _ draft: AskMailDraftBlock,
        for viewModel: AskMailViewModel,
        beforeOpening: @MainActor () -> Void,
        hostCompose: (@MainActor (ComposeRequest) -> Void)?
    ) {
        let request = ComposeRequest.aiDraftReply(
            messageID: draft.replyToMessageID.rawValue,
            bodyMarkdown: draft.body,
            recipient: draft.recipientAddress
        )
        composeAskMailReply(
            request,
            to: draft.replyToMessageID,
            for: viewModel,
            beforeOpening: beforeOpening,
            hostCompose: hostCompose
        )
    }

    /// Opens Compose for an Ask Mail reply or draft to `messageID`. A host compose path takes a
    /// message of the open conversation as it is. Otherwise the target opens in the mailbox
    /// first, and Compose follows once it has loaded, or at once in a runtime window. A target
    /// that can't be opened is reported in `viewModel`.
    private func composeAskMailReply(
        _ request: ComposeRequest,
        to messageID: MessageID,
        for viewModel: AskMailViewModel,
        beforeOpening: @MainActor () -> Void,
        hostCompose: (@MainActor (ComposeRequest) -> Void)?
    ) {
        guard allowsMailboxMutations() else { return }
        if let hostCompose, openConversationHolds(messageID) {
            hostCompose(request)
            return
        }
        beforeOpening()
        if composerPresentationPolicy == .runtimeWindow {
            showAskMailTarget(messageID, for: viewModel)
            presentCompose(request)
            Task { await inboxSnapshot.refresh(selectedMessageID: messageID.rawValue) }
            return
        }
        Task {
            guard await openAskMailMessageForReply(messageID, for: viewModel) != nil else {
                viewModel.reportHostProblem(Self.askMailReplyTargetUnavailable)
                return
            }
            await openCompose(request)
        }
    }

    /// The open conversation, the thread Compose replies in, holds `messageID`.
    private func openConversationHolds(_ messageID: MessageID) -> Bool {
        guard mailbox.selectedMessageID != nil, let thread = compose.thread() else { return false }
        return thread.messages.contains { $0.id == messageID.rawValue }
    }

    /// Ask Mail bulk actions: the mailbox action machinery, awaited for its real outcome.
    private func performAskMailAction(_ action: InboxMailAction, messageID: MessageID) async -> Bool {
        guard allowsMailboxMutations() else { return false }
        return await actions.performReturningOutcome(
            action,
            messageID: messageID.rawValue,
            origin: .askMailBatch
        )
    }

    /// Shows an Ask Mail target in the mailbox `viewModel`'s answer source names, or the inbox.
    private func showAskMailTarget(_ messageID: MessageID, for viewModel: AskMailViewModel) {
        showAskMailMessage(
            messageID.rawValue,
            mailboxPath: viewModel.source(for: messageID)?.mailboxPath ?? "INBOX"
        )
    }

    private func showAskMailMessage(_ messageID: String, mailboxPath: String) {
        willShowAskMailMessage()
        let destination: PlainpostDestination
        switch mailboxPath.lowercased() {
        case let path where path.contains("sent"):
            destination = .sent
        case let path where path.contains("archive") || path.contains("all mail"):
            destination = .archive
        default:
            destination = .allInboxes
        }
        let mode = mailbox.mailboxNavigation.rememberedMode(
            for: destination,
            fallback: InboxDisplayMode(rawValue: mailbox.selectedInboxMode) ?? .focusedList
        )
        openMailboxMessage(
            messageID,
            destination: destination,
            from: .mailbox(destination: destination, mode: mode)
        )
        invalidateInboxSnapshot()
    }

    static func mailSearchAccounts(_ accountSetup: AccountSetupViewModel) -> [MailSearchAccount] {
        accountSetup.accounts.map {
            MailSearchAccount(
                id: $0.id,
                displayName: $0.displayName.isEmpty ? $0.email.rawValue : $0.displayName,
                email: $0.email.rawValue
            )
        }
    }
}

extension MailSession {
    /// Builds a session from a runtime's (or a preview's) parts, resolving the same defaults
    /// and starting mailbox `PlainpostRootView(viewModel:…)` always has. Every default is a
    /// preview value.
    static func make(
        viewModel: InboxViewModel = .preview(),
        accountSetup: AccountSetupViewModel = .preview(),
        accountSessionModel: AccountSessionViewModel? = nil,
        mailSearch: MailSearchViewModel = .designTips(),
        approvalQueue: ApprovalQueueViewModel = .preview(),
        composer: ComposerViewModel = .preview(),
        undoSendCoordinator: UndoSendCoordinator? = nil,
        auditLog: AuditLogViewModel = .preview(),
        commandCenter: CommandCenterViewModel = .preview(),
        aiAssistant: ThreadAIAssistantViewModel = .preview(),
        askMail: AskMailViewModel = .preview(),
        conversationAskMail: AskMailViewModel = .preview(),
        conversationActionDetector: any ConversationActionDetecting = NoConversationActionDetector(),
        aiProviderSettings: AIProviderSettingsViewModel = .production(),
        translationSettings: TranslationLanguageSettingsViewModel? = nil,
        threadTranslation: ThreadTranslationViewModel? = nil,
        inboxMailActions: InboxMailActionViewModel = .preview(),
        nodeSettings: SyncNodeSettingsViewModel? = nil,
        nodeMailModeStatus: NodeMailModeStatusModel? = nil,
        attachmentState: PlainpostAttachmentState? = nil,
        mailRules: MailRulesViewModel = .preview(),
        mailLabels: MailLabelsViewModel = .preview(),
        messageLabelActions: MessageLabelActions = .preview(),
        openMessage: @escaping (String) async throws -> Void = { _ in },
        openAttachment: @escaping (MailAttachment) async -> Void = { _ in },
        loadForwardAttachments: @escaping (String) async -> (attachments: [DraftAttachment], unavailable: [String]) = { _ in ([], []) },
        loadInlineImages: @escaping @MainActor (String) -> [InlineImagePart] = { _ in [] },
        localDrafts: LocalDraftActions = .none,
        initialDestination: PlainpostDestination? = nil,
        initialInboxMode: String? = nil,
        initialSelectedMessageID: String? = nil,
        loadMailboxDirectory: @escaping () async -> [MailboxAccountSection] = { [] },
        contactDirectory: ContactDirectoryModel? = nil,
        loadCorrespondents: @escaping () async -> [Correspondent] = { [] },
        onAccountSetupConnected: @escaping (AccountID) -> Void = { _ in },
        showsSearch: Bool = false,
        showsComposer: Bool = false,
        composerPresentationPolicy: ComposerPresentationPolicy = .embedded,
        commitDelay: Duration = .zero,
        viewModelProvider: ((String?) async -> InboxViewModel)? = nil,
        loadMoreViewModelProvider: ((String?) async -> InboxViewModel)? = nil,
        threadProvider: ((String) async -> ThreadDetailModel?)? = nil,
        invalidateInboxSnapshot: @escaping () -> Void = {},
        configureAIAssistant: @escaping (ThreadAIAssistantViewModel, String) -> Void = { _, _ in },
        configureAskMail: @escaping (AskMailViewModel, String) -> Void = { _, _ in },
        configureThreadTranslation: @escaping (ThreadTranslationViewModel, String) -> Void = { _, _ in },
        searchIndexState: @escaping () async -> MailSearchIndexState = { .unavailable },
        rebuildSearchIndex: @escaping () async throws -> Void = {},
        allowsSearchIndexRebuild: Bool = true,
        refreshMailSearchMailboxes: @escaping (Bool) async -> Void = { _ in },
        refreshSmartInbox: @escaping (
            String,
            PlainpostSmartInboxRunMode,
            String?
        ) async throws -> String = { _, _, _ in "Up to date" },
        aiGenerationAvailable: (() -> Bool)? = nil,
        allowsMailboxMutations: @escaping () -> Bool = { true },
        // These five only build the preview/test maintenance model; a runtime passes its
        // own `maintenance:` (built by `makeMailMaintenanceViewModel`) and omits them.
        mailSyncCoordinator: MailSyncCoordinator = MailSyncCoordinator(),
        smartInboxActivityJob: @escaping () -> PlainpostDurableJob? = { nil },
        activeSmartInboxRerunJob: (() -> PlainpostDurableJob?)? = nil,
        pauseSmartInboxJob: @escaping (String) throws -> Void = { _ in },
        resumeSmartInboxJob: @escaping (String) async throws -> Void = { _ in },
        composerActivity: PlainpostComposerActivity? = nil,
        accountForMessage: @escaping (String) -> Account? = { _ in nil },
        loadFolderRows: @escaping (AccountID, String, Int) async throws -> [MessageRowModel] = { _, _, _ in [] },
        maintenance runtimeMaintenance: MailMaintenanceViewModel? = nil
    ) -> MailSession {
        let resolvedAIGenerationAvailability = aiGenerationAvailable
            ?? { PlainpostAIGenerationPolicy.current }
        let requestedInitialDestination = initialDestination
            ?? (viewModel.shouldPresentLegacyAccountSetup ? .settings : .smartInbox)
        let resolvedInitialDestination = requestedInitialDestination == .smartInbox && !aiProviderSettings.smartInboxEnabled
            ? .allInboxes : requestedInitialDestination
        let initialPresentation = PlainpostMailboxInitialPresentation.production(
            destination: resolvedInitialDestination,
            requestedMode: initialInboxMode,
            persistedMode: UserDefaults.standard.string(
                forKey: PlainpostMailboxInitialPresentation.persistedModeKey
            ),
            fallbackMode: PlainpostMailboxInitialPresentation.mode(
                for: viewModel.chrome.selectedModeID
            )
        )
        var initialNavigation = MailboxWorkspaceNavigationState(
            initialContext: initialPresentation.context
        )
        if let initialSelectedMessageID {
            initialNavigation.openReader(
                messageID: initialSelectedMessageID,
                from: initialPresentation.context
            )
        }
        // A runtime builds its maintenance model once, through
        // `PlainpostAppRuntime.makeMailMaintenanceViewModel`, so every Settings
        // surface follows the same Low Power gate. Previews build their own.
        let smartInboxActivity = runtimeMaintenance?.smartInboxActivity ?? SmartInboxActivityCoordinator(
            jobProvider: smartInboxActivityJob,
            pause: pauseSmartInboxJob,
            resume: resumeSmartInboxJob
        )
        let maintenance = runtimeMaintenance ?? MailMaintenanceViewModel(
            accountSetup: accountSetup,
            syncCoordinator: mailSyncCoordinator,
            smartInboxActivity: smartInboxActivity,
            activeRerunJob: activeSmartInboxRerunJob ?? {
                smartInboxActivity.isRerunActive
                    ? smartInboxActivity.job
                    : nil
            },
            selectedProviderID: { aiProviderSettings.selectedProviderID },
            aiGenerationAvailable: resolvedAIGenerationAvailability,
            smartInboxSettings: aiProviderSettings,
            rerun: refreshSmartInbox
        )
        let fallbackProviderIdentity = PlainpostRootView.translationProviderIdentity(
            providerID: aiProviderSettings.selectedProviderID
        )
        return MailSession(
            inbox: viewModel,
            inboxProvider: viewModelProvider,
            loadMoreInboxProvider: loadMoreViewModelProvider,
            threadProvider: threadProvider,
            initialDestination: resolvedInitialDestination,
            initialInboxMode: initialPresentation.mode.rawValue,
            initialSelectedMessageID: initialSelectedMessageID,
            initialNavigation: initialNavigation,
            directory: MailboxDirectoryModel(load: loadMailboxDirectory),
            recipientSuggestions: RecipientSuggestionProvider(
                contacts: contactDirectory ?? .unavailable(),
                correspondents: loadCorrespondents
            ),
            accountSetup: accountSetup,
            accountSessionModel: accountSessionModel,
            mailSearch: mailSearch,
            searchIndexRebuild: MailSearchIndexRebuildController(
                indexState: searchIndexState,
                rebuild: rebuildSearchIndex,
                allowsRebuild: allowsSearchIndexRebuild
            ),
            approvalQueue: approvalQueue,
            composer: composer,
            undoSend: undoSendCoordinator
                ?? UndoSendCoordinator(sender: UnconfiguredDirectComposerSender()),
            auditLog: auditLog,
            commandCenter: commandCenter,
            aiAssistant: aiAssistant,
            askMail: askMail,
            conversationAskMail: conversationAskMail,
            conversationActionDetector: conversationActionDetector,
            aiProviderSettings: aiProviderSettings,
            translationSettings: translationSettings
                ?? TranslationLanguageSettingsViewModel(
                    options: [
                        TranslationLanguageOption(
                            id: TranslationLanguageCatalog.defaultLanguageID,
                            localizedName: "English"
                        ),
                    ]
                ),
            threadTranslation: threadTranslation
                ?? ThreadTranslationViewModel(
                    handler: UnconfiguredThreadTranslationHandler(
                        providerID: fallbackProviderIdentity.providerID,
                        modelID: fallbackProviderIdentity.modelID
                    )
                ),
            inboxMailActions: inboxMailActions,
            nodeSettings: nodeSettings,
            nodeStatus: nodeMailModeStatus ?? NodeMailModeStatusModel.inactive(),
            attachmentState: attachmentState ?? PlainpostAttachmentState(accountID: nil),
            mailRules: mailRules,
            mailLabels: mailLabels,
            messageLabelActions: messageLabelActions,
            smartInboxActivity: smartInboxActivity,
            maintenance: maintenance,
            composerActivity: composerActivity,
            composerPresentationPolicy: composerPresentationPolicy,
            commitDelay: commitDelay,
            showsComposer: showsComposer,
            showsSearch: showsSearch,
            ownAddresses: { [accountSetup] in
                Set(accountSetup.accounts.map { $0.email.rawValue.lowercased() })
            },
            loadForwardAttachments: loadForwardAttachments,
            openMessage: openMessage,
            openAttachment: openAttachment,
            loadInlineImages: loadInlineImages,
            localDrafts: localDrafts,
            invalidateInboxSnapshot: invalidateInboxSnapshot,
            refreshMailSearchMailboxes: refreshMailSearchMailboxes,
            runSmartInbox: refreshSmartInbox,
            aiGenerationAvailable: resolvedAIGenerationAvailability,
            allowsMailboxMutations: allowsMailboxMutations,
            configureAIAssistant: configureAIAssistant,
            configureAskMail: configureAskMail,
            configureThreadTranslation: configureThreadTranslation,
            onAccountSetupConnected: onAccountSetupConnected,
            accountForMessage: accountForMessage,
            loadFolderRows: loadFolderRows
        )
    }

    /// A session of preview view models and no-op runtime hooks.
    static func preview() -> MailSession {
        make()
    }
}

/// An account's drafts saved in this app's composer, as the Drafts folder shows them.
struct LocalDraftActions {
    let load: @MainActor (AccountID) -> [Draft]
    let snapshot: @MainActor (Draft) -> ComposerRestoreSnapshot
    let discard: @MainActor (Draft) throws -> Void

    static let none = LocalDraftActions(
        load: { _ in [] },
        snapshot: { ComposerRestoreSnapshot(savedDraft: $0, sourceMessageID: nil) },
        discard: { _ in }
    )
}
