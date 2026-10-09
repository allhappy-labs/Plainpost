#if os(iOS)
import PlainpostCore
import QuickLook
import SwiftUI

/// The iPhone mail UI: one navigation stack from Mailboxes down to a conversation, with
/// Compose as a sheet. It owns one `MailSession`, built when SwiftUI first installs it, and
/// reads the app's `MobileMailEnvironment`.
public struct MobileMailShell: View {
    @StateObject private var session: MailSession
    @StateObject private var mailbox: MailboxController
    @StateObject private var compose: ComposeCoordinator
    @StateObject private var accountSetup: AccountSetupViewModel
    @StateObject private var inboxSnapshot: InboxViewModelSnapshotStore
    @StateObject private var undoSend: UndoSendCoordinator
    @StateObject private var nodeStatus: NodeMailModeStatusModel
    @StateObject private var actions: MessageActionController
    @StateObject private var aiProviderSettings: AIProviderSettingsViewModel
    @StateObject private var folderRows = FolderRowsModel()
    @ObservedObject private var environment: MobileMailEnvironment
    @State private var navigator = MobileNavigator()
    @State private var failure: MobileMailFailure?
    @State private var attachmentArtifact: PlainpostAttachmentArtifact?
    @State private var isAskMailPresented = false
    @State private var askMailDetent: PresentationDetent = .large

    public init(session: @autoclosure @escaping () -> MailSession, environment: MobileMailEnvironment) {
        // Lazy, so the session is built when SwiftUI installs the first of these state
        // objects, and every other one shares it. A re-init evaluates none of them.
        lazy var s: MailSession = {
            let built = session()
            // An iPhone list shows no selection, so leaving a conversation or entering a
            // mailbox must not restore one (it would mark that message read unseen).
            built.mailbox.restoresListSelection = false
            return built
        }()
        _session = StateObject(wrappedValue: s)
        _mailbox = StateObject(wrappedValue: s.mailbox)
        _compose = StateObject(wrappedValue: s.compose)
        _accountSetup = StateObject(wrappedValue: s.accountSetup)
        _inboxSnapshot = StateObject(wrappedValue: s.inboxSnapshot)
        _undoSend = StateObject(wrappedValue: s.undoSend)
        _nodeStatus = StateObject(wrappedValue: s.nodeStatus)
        _actions = StateObject(wrappedValue: s.actions)
        _aiProviderSettings = StateObject(wrappedValue: s.aiProviderSettings)
        self.environment = environment
    }

    public var body: some View {
        Group {
            if showsAccountSetup {
                MobileAccountSetupScreen(session: session, environment: environment, accountSetup: accountSetup)
            } else {
                NavigationStack(path: pathBinding) {
                    MobileMailboxesScreen(
                        session: session,
                        environment: environment,
                        open: open,
                        compose: { request(.new) },
                        openSearch: openSearch,
                        askMail: openAskMail
                    )
                    .navigationDestination(for: MobileRoute.self) { destination(for: $0) }
                }
                .sheet(isPresented: $isAskMailPresented) {
                    AskMailInspectorWorkspace(
                        viewModel: session.askMail,
                        activeContext: nil,
                        close: { isAskMailPresented = false }
                    )
                    .presentationDetents([.medium, .large], selection: $askMailDetent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .onAppear(perform: session.attachAskMailHost)
                    .accessibilityIdentifier("ask-mail.sheet")
                    .sheet(isPresented: composeOverAskMail) { composeSheet }
                }
            }
        }
        .overlay(alignment: .bottom) { notices }
        .sheet(isPresented: composeOverMail) { composeSheet }
        .onChange(of: compose.isPresented) { _, presented in
            // People mailed since the last compose appear in suggestions.
            guard presented else { return }
            Task { await session.recipientSuggestions.refreshCorrespondents() }
        }
        .alert(failure?.title ?? "", isPresented: failureIsPresented, presenting: failure) { _ in
            Button("OK") { failure = nil }
        } message: { failure in
            Text(failure.message)
        }
        .quickLookPreview(attachmentURL)
        .modifier(MailSessionLifecycle(session: session, hooks: hooks))
        .onChange(of: aiProviderSettings.smartInboxEnabled, initial: true) { _, enabled in
            navigator.applySmartInboxEnabled(enabled)
        }
        .onChange(of: mailbox.mailboxNavigation.route) { _, _ in reconcile() }
        .onChange(of: environment.hostActivities, initial: true) { _, host in
            session.activity.hostActivities = host.map(MailActivity.init(host:))
        }
        .onChange(of: mailbox.selectedDestination) { _, _ in reconcile() }
        .onAppear {
            navigator.adoptLaunchDestination(mailbox.selectedDestination)
            reconcile()
            environment.commitPendingActions = { [weak actions = session.actions] in
                await actions?.commitPendingAndWait()
            }
            // A folder isn't the inbox projection: apply commits to its rows directly.
            actions.didCommit = { [weak folderRows] messageID, action in
                folderRows?.applyCommitted(messageID, action)
            }
            // A result shown from Ask Mail lowers the sheet so its conversation is visible.
            let detent = $askMailDetent
            session.willShowAskMailMessage = { detent.wrappedValue = .medium }
        }
    }

    private var showsAccountSetup: Bool { session.isAccountSetupPending }

    // MARK: Navigation

    private var pathBinding: Binding<[MobileRoute]> {
        Binding(
            get: { navigator.path },
            set: { newPath in
                let admitted = aiProviderSettings.smartInboxEnabled ? newPath : newPath.map {
                    $0 == .mailbox(.smartInbox) ? .mailbox(.allInboxes) : $0
                }
                apply(navigator.applySystemPath(admitted))
            }
        )
    }

    private func apply(_ effects: [MobileNavigationEffect]) {
        for effect in effects {
            switch effect {
            case .returnFromConversation: mailbox.returnToList()
            case .closeSearch: session.search.close()
            case .leaveMailbox: mailbox.resetFilters()
            case let .showMailbox(kind): mailbox.returnFromSearch(to: kind.destination)
            }
        }
    }

    private func reconcile() {
        navigator.reconcile(destination: mailbox.selectedDestination, route: mailbox.mailboxNavigation.route)
    }

    private func open(_ kind: MobileMailbox) {
        select(kind)
        navigator.openMailbox(kind)
    }

    /// Points the shared mailbox state at `kind`.
    private func select(_ kind: MobileMailbox) {
        mailbox.enterMailbox(kind.destination, unreadOnly: kind == .unread)
    }

    private func openMessage(_ messageID: String, in kind: MobileMailbox) {
        session.openMailboxMessage(messageID, destination: kind.destination, from: mailbox.currentListContext())
    }

    /// Search covers every account, or only the account whose folder it was started from.
    private func openSearch() {
        let folderAccount: AccountID? = if case let .mailbox(.folder(ref))? = navigator.path.first {
            ref.accountID
        } else { nil }
        session.search.present(query: nil, accountScope: folderAccount.map { [$0] } ?? [])
        navigator.openSearch()
    }

    private func openHit(_ hit: MailSearchHit) {
        session.search.open(session.mailSearch.messageToOpen(for: hit), closesSearch: false)
    }

    /// The mailbox row a conversation was opened from: its header shows while the body loads.
    private func listRow(for messageID: String) -> MessageRowModel? {
        guard case let .mailbox(kind)? = navigator.path.first else { return nil }
        let rows = if case .folder = kind { folderRows.rows } else { inboxSnapshot.model.rows(for: kind.destination) }
        return rows.first { $0.id == messageID }
    }

    /// The order of the list under the open conversation, for ⌃⌄.
    private func orderedMessageIDs() -> [String] {
        if navigator.path.contains(.search) {
            return session.mailSearch.rows.map { session.mailSearch.messageToOpen(for: $0).rawValue }
        }
        guard case let .mailbox(kind)? = navigator.path.first else { return [] }
        if case .folder = kind {
            return mailbox.visibleRows(folderRows.visible(hiding: actions.overlayState.overlays)).map(\.id)
        }
        return mailbox.visibleRows(inboxSnapshot.model.rows(for: kind.destination)).map(\.id)
    }

    /// The mailbox list a conversation sits on; none when it was opened from Search.
    private var mailboxUnderConversation: MobileMailbox? {
        guard !navigator.path.contains(.search), case let .mailbox(kind)? = navigator.path.first else { return nil }
        return kind
    }

    private func openAskMail() {
        askMailDetent = .large
        isAskMailPresented = true
    }

    private var composeOverMail: Binding<Bool> {
        Binding(get: { compose.isPresented && !isAskMailPresented }, set: { if !$0 { compose.isPresented = false } })
    }

    private var composeOverAskMail: Binding<Bool> {
        Binding(get: { compose.isPresented && isAskMailPresented }, set: { if !$0 { compose.isPresented = false } })
    }

    private var composeSheet: some View {
        MobileComposeSheet(
            composer: session.composer,
            suggestions: session.recipientSuggestions,
            fromAddress: environment.fromAddress,
            draftWithAI: { await compose.draftBodyWithAI() },
            // A read-only account can't send; the Compose buttons that open this are disabled too.
            readOnlyReason: session.allowsMailboxMutations() ? nil : environment.readOnlyReason.sendingLine,
            banner: environment.banner,
            close: { compose.isPresented = false }
        )
            .alert("This account was removed", isPresented: Binding(
                get: { compose.asksToDiscardRemovedAccountDraft },
                set: { if !$0 { compose.asksToDiscardRemovedAccountDraft = false } }
            )) {
                Button("Discard Draft", role: .destructive) { compose.discardRemovedAccountDraft() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("This draft can't be sent from an account that's no longer on this device.")
            }
    }

    @ViewBuilder
    private func destination(for route: MobileRoute) -> some View {
        switch route {
        case let .mailbox(kind):
            MobileMailboxListScreen(
                session: session,
                kind: kind,
                environment: environment,
                folderRows: folderRows,
                openMessage: { openMessage($0, in: kind) },
                openDraft: { request(.restore($0)) },
                compose: { request(.new) },
                openSearch: openSearch,
                askMail: openAskMail
            )
        case let .conversation(messageID):
            MobileConversationScreen(
                session: session,
                messageID: messageID,
                orderedMessageIDs: orderedMessageIDs,
                listRow: listRow(for: messageID),
                compose: request,
                openedFrom: mailboxUnderConversation,
                readOnlyReason: session.allowsMailboxMutations() ? nil : environment.readOnlyReason.sendingLine
            )
        case .search:
            MobileSearchScreen(session: session, openHit: openHit)
        case .approvals:
            MobileApprovalsScreen(approvalQueue: session.approvalQueue)
        case let .approval(requestID):
            MobileApprovalDetailScreen(approvalQueue: session.approvalQueue, requestID: requestID)
        case .settings:
            MobileSettingsListScreen(environment: environment, accountSetup: session.accountSetup)
        case let .settingsDestination(destination):
            MobileSettingsDestinationScreen(session: session, destination: destination)
        }
    }

    private func request(_ request: ComposeRequest) {
        Task { _ = await compose.request(request) }
    }

    // MARK: Session hooks, notices, failures

    private var hooks: MailSessionLifecycleHooks {
        let failure = $failure
        let attachmentArtifact = $attachmentArtifact
        return MailSessionLifecycleHooks(
            reportFailure: { failure.wrappedValue = .messageAction($0) },
            presentAskMail: { [askMail = $isAskMailPresented, detent = $askMailDetent] _ in
                detent.wrappedValue = .large
                askMail.wrappedValue = true
            },
            // The mobile shell has no selected approval row; the queue still refreshes.
            didRefreshApprovals: {},
            // No Smart Inbox run while first-run setup shows: there's no mail to triage yet.
            allowsSmartInboxRefreshOnAppear: { [weak session] in
                MailSession.allowsSmartInboxRefreshOnAppear(isAccountSetupPending: session?.isAccountSetupPending ?? true)
            },
            markReadFailed: { failure.wrappedValue = .markRead },
            attachmentEvent: { event in
                switch event.outcome {
                case let .saved(artifact): attachmentArtifact.wrappedValue = artifact
                case let .failed(message): failure.wrappedValue = .attachment(message)
                }
            }
        )
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if let pending = actions.pendingUndo {
                MobileUndoToast(title: pending.action == .archive ? "Archived" : "Deleted", undo: { actions.undo() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let state = undoSend.snackbarState {
                UndoSendSnackbar(
                    state: state,
                    undo: { request(.undoLatestSend) },
                    openDraft: { request(.restoreFailedSend) }
                )
            } else if let notice = nodeStatus.notice {
                NodeSendOutcomeNoticeView(notice: notice) { nodeStatus.dismissNotice() }
            }
            if let notice = environment.notice {
                MobileNoticeView(message: notice) { environment.notice = nil }
            }
        }
        .animation(.default, value: actions.pendingUndo)
        .padding(.horizontal, 16)
        .padding(.bottom, Self.noticeBottomInset)
    }

    /// Keeps the Undo toast and send notices above the bottom toolbar (Search, ✦, Compose).
    private static let noticeBottomInset: CGFloat = 64

    private var failureIsPresented: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private var attachmentURL: Binding<URL?> {
        Binding(
            get: { attachmentArtifact?.url },
            set: { url in
                guard url == nil else { return }
                session.attachmentState.clear()
                attachmentArtifact = nil
            }
        )
    }
}
extension MailActivity {
    init(host: MobileHostActivity) {
        switch host.kind {
        case .syncing:
            self = .hostSync(accountTitle: host.accountTitle, detail: host.detail, fraction: host.fraction)
        case .failed:
            self = .hostSyncFailure(accountTitle: host.accountTitle, message: host.detail ?? "Check your connection and retry.")
        }
    }
}

/// A passing line from the host, with Dismiss.
struct MobileNoticeView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mailbox.notice")
    }
}
#endif
