import AppKit
import QuartzCore
import SwiftUI
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostOperations
@_spi(DesignPreview) import PlainpostUI

enum MailboxToolbarFixtureScenario: CaseIterable {
    case focusedList
    case board
    case splitBoard

    static let all = allCases

    var selectedInboxMode: InboxDisplayMode {
        switch self {
        case .focusedList:
            .focusedList
        case .board:
            .simpleList
        case .splitBoard:
            .unreadCards
        }
    }

    func renderWidth(for configurationSize: CGSize) -> CGFloat {
        configurationSize.width
    }
}

@main
@MainActor
struct PlainpostDesignSnapshot {
    static let mailboxToolbarFixtureFrameAlignment: Alignment = .leading

    private struct SnapshotConfiguration {
        let name: String
        let size: CGSize
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let reduceTransparency: Bool
        let reduceMotion: Bool

        init(
            _ name: String,
            size: CGSize,
            colorScheme: ColorScheme,
            contrast: ColorSchemeContrast = .standard,
            reduceTransparency: Bool = false,
            reduceMotion: Bool = false
        ) {
            self.name = name
            self.size = size
            self.colorScheme = colorScheme
            self.contrast = contrast
            self.reduceTransparency = reduceTransparency
            self.reduceMotion = reduceMotion
        }
    }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)

        let outputDirectory = outputDirectoryURL()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fixedSmartInboxNow = ISO8601DateFormatter().date(
            from: "2026-07-22T10:00:00Z"
        )!

        // Sync Node and Node-account scenarios (90-9b) need real `await`s
        // (Task-driven state) to settle, so they are built up front rather
        // than inside a scenario closure, which this renderer calls
        // synchronously.
        let syncNodeNotConnectedSession = try await syncNodeSessionNotConnected()
        let syncNodeReadyToConnectSession = try await syncNodeSessionReadyToConnect()
        let syncNodeConnectedSession = try await syncNodeSessionEnrolled(presentation: .connected)
        let syncNodeConnectionFailedSession = try await syncNodeSessionEnrolled(presentation: .connectionFailed)
        let syncNodeOutdatedProfileSession = try await syncNodeSessionOutdatedProfile()
        let syncNodeGenericFailureSession = try await syncNodeSessionGenericFailure()
        let syncNodeCommitUncertainModel = try await SyncNodeDesignFixture().commitUncertainModel()
        let syncNodeCommitUncertainSession = try await syncNodeSessionFromModel(syncNodeCommitUncertainModel)
        let syncNodeConnectedStatus = try syncNodeStatusViewModel()
        let syncNodeUnreachableSession = try await syncNodeSessionEnrolled(presentation: .connected)
        let syncNodeUnreachableStatus = try syncNodeStatusViewModel(reachability: "unreachable")
        let syncNodeReplaceableSession = try await syncNodeSessionEnrolled(presentation: .connected, withReplaceableProfile: true)
        let syncNodeMatchingConfirmationModel = try await SyncNodeDesignFixture().matchingStringConfirmationModel()
        let syncNodeMatchingConfirmationSession = try await syncNodeSessionFromModel(syncNodeMatchingConfirmationModel)
        let syncNodeActivationUncertainModel = try await SyncNodeDesignFixture().activationUncertainModel()
        let syncNodeActivationUncertainSession = try await syncNodeSessionFromModel(syncNodeActivationUncertainModel)

        // Calendar design previews are compiled only in debug builds.
        #if DEBUG
        let calendarSnapshots: [(String, () -> AnyView)] = [
            ("calendar-normal", { CalendarDesignPreview.view(scenario: "normal") }),
            ("calendar-overlap", { CalendarDesignPreview.view(scenario: "overlap") }),
            ("calendar-all-day", { CalendarDesignPreview.view(scenario: "all-day") }),
            ("calendar-all-day-details", { CalendarDesignPreview.allDayDetailsView() }),
            ("calendar-reconnect", { CalendarDesignPreview.reconnectView() }),
            ("calendar-narrow", { CalendarDesignPreview.view(scenario: "normal") }),
            ("calendar-invitation-actionable", { ThreadInvitationDesignPreview.view(scenario: "actionable") }),
            ("calendar-invitation-pending", { ThreadInvitationDesignPreview.view(scenario: "pending") }),
            ("calendar-invitation-uncertain", { ThreadInvitationDesignPreview.view(scenario: "uncertain") }),
            ("calendar-invitation-superseded", { ThreadInvitationDesignPreview.view(scenario: "superseded") }),
            ("calendar-invitation-multi", { ThreadInvitationDesignPreview.view(scenario: "multi") }),
        ]
        #else
        let calendarSnapshots: [(String, () -> AnyView)] = []
        #endif

        let snapshots: [(String, () -> AnyView)] = calendarSnapshots + [
            (
                "01-smart-inbox",
                {
                    mailboxSnapshot(
                        fixedSmartInboxNow: fixedSmartInboxNow,
                        initialSelectedMessageID: nil,
                        initialSmartInboxBundle: nil
                    )
                }
            ),
            (
                "01b-smart-inbox-newsletters",
                {
                    mailboxSnapshot(
                        fixedSmartInboxNow: fixedSmartInboxNow,
                        initialSelectedMessageID: nil,
                        initialSmartInboxBundle: .newsletters
                    )
                }
            ),
            (
                "01c-smart-inbox-reader",
                {
                    mailboxSnapshot(
                        fixedSmartInboxNow: fixedSmartInboxNow,
                        initialSelectedMessageID: "jessica-intro",
                        initialSmartInboxBundle: nil
                    )
                }
            ),
            (
                "01d-smart-inbox-selected",
                {
                    mailboxSnapshot(
                        fixedSmartInboxNow: fixedSmartInboxNow,
                        initialSelectedMessageID: nil,
                        initialListSelectedMessageID: "jessica-intro",
                        initialSmartInboxBundle: nil
                    )
                }
            ),
            (
                "01c-smart-inbox-activity-running",
                {
                    smartInboxActivityPreview(
                        id: "snapshot-smart-inbox-running",
                        state: .running,
                        processed: 2_340,
                        total: 9_256,
                        designNow: fixedSmartInboxNow
                    )
                }
            ),
            (
                "01d-smart-inbox-activity-pausing",
                {
                    smartInboxActivityPreview(
                        id: "snapshot-smart-inbox-pausing",
                        state: .running,
                        processed: 2_340,
                        total: 9_256,
                        pauseRequested: true,
                        designNow: fixedSmartInboxNow
                    )
                }
            ),
            (
                "01e-smart-inbox-activity-paused",
                {
                    smartInboxActivityPreview(
                        id: "snapshot-smart-inbox-paused",
                        state: .paused,
                        processed: 2_340,
                        total: 9_256,
                        pauseReason: "user-requested",
                        designNow: fixedSmartInboxNow
                    )
                }
            ),
            (
                "01f-smart-inbox-activity-large-counts",
                {
                    smartInboxActivityPreview(
                        id: "snapshot-smart-inbox-large-counts",
                        state: .running,
                        processed: 123_456,
                        total: 777_777,
                        designNow: fixedSmartInboxNow
                    )
                }
            ),
            (
                "02-settings-smart-inbox",
                { settingsPreview(destination: .section(.smartInbox)) }
            ),
            (
                "03-approval-queue",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .approvalQueue)) }
            ),
            (
                "04-compose-window",
                { AnyView(ComposerWindow(viewModel: .preview(), close: {}, showsEmbeddedChrome: false)) }
            ),
            (
                "05-command-center",
                { AnyView(commandCenterPreview()) }
            ),
            (
                "06-account-setup",
                { AnyView(AccountSetupWorkspace(viewModel: .preview())) }
            ),
            (
                "06b-gmail-sign-in",
                { AnyView(AccountSetupWorkspace(viewModel: .gmailPreview())) }
            ),
            (
                "06c-gmail-account-empty",
                { AnyView(AccountSetupWorkspace(viewModel: .gmailEmptyPreview())) }
            ),
            (
                "06d-gmail-identity-mismatch",
                { AnyView(AccountSetupWorkspace(viewModel: .gmailFailurePreview())) }
            ),
            (
                "06e-gmail-verifying",
                { AnyView(AccountSetupWorkspace(viewModel: .gmailConnectingPreview())) }
            ),
            (
                "06f-gmail-waiting-for-browser",
                { AnyView(AccountSetupWorkspace(viewModel: .gmailWaitingForBrowserPreview())) }
            ),
            (
                "06h-gmail-sign-in-unavailable",
                { AnyView(AccountSetupWorkspace(viewModel: .gmailUnavailablePreview())) }
            ),
            (
                "06g-other-account-setup",
                { AnyView(AccountSetupWorkspace(viewModel: .otherPreview())) }
            ),
            (
                "07-connected-account",
                { settingsPreview(destination: .account(AccountID("acc_preview")), connected: true) }
            ),
            (
                "07b-gmail-reauthorize",
                { settingsPreview(destination: nil, accountSetup: .gmailReauthorizationPreview()) }
            ),
            (
                "08-drafts",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .drafts, initialInboxMode: "Classic")) }
            ),
            (
                "09-rules-labels",
                { settingsPreview(destination: .section(.rulesLabels)) }
            ),
            (
                "09a-labels-account",
                { settingsPreview(destination: .section(.rulesLabels), labelsState: .accountScope) }
            ),
            (
                "09aa-labels-empty-add",
                { settingsPreview(destination: .section(.rulesLabels), labelsState: .emptyAdd) }
            ),
            (
                "09b-labels-empty",
                { settingsPreview(destination: .section(.rulesLabels), labelsState: .empty) }
            ),
            (
                "09c-labels-delete-confirmation",
                { labelConfirmationPreview(state: .deleteConfirmation) }
            ),
            (
                "09d-mail-rules-shared-shell",
                { settingsPreview(destination: .section(.rulesLabels)) }
            ),
            (
                "09e-labels-reclassify-confirmation",
                { labelConfirmationPreview(state: .reclassifyConfirmation) }
            ),
            (
                "09f-labels-description-validation",
                { settingsPreview(destination: .section(.rulesLabels), labelsState: .descriptionValidation) }
            ),
            (
                "09g-labels-progress",
                { settingsPreview(destination: .section(.rulesLabels), labelsState: .progress) }
            ),
            (
                "09h-labels-disable-confirmation",
                { labelConfirmationPreview(state: .disableConfirmation) }
            ),
            (
                "09i-message-labels-submenu",
                {
                    AnyView(
                        ZStack {
                            Color(nsColor: .windowBackgroundColor)
                            MessageLabelsSubmenuDesignPreview()
                                .fixedSize()
                        }
                    )
                }
            ),
            (
                "10-plainpost-account",
                { settingsPreview(destination: .section(.plainpostAccount)) }
            ),
            (
                "10-security-privacy",
                { securityPrivacyPreview(loadState: .loaded, populated: true) }
            ),
            (
                "10b-security-privacy-empty",
                { securityPrivacyPreview(loadState: .loaded) }
            ),
            (
                "10c-security-privacy-loading",
                { securityPrivacyPreview(loadState: .loading) }
            ),
            (
                "10d-security-privacy-failed",
                {
                    securityPrivacyPreview(
                        loadState: .failed(
                            message: "Account security couldn’t be loaded."
                        )
                    )
                }
            ),
            (
                "11-notifications",
                { settingsPreview(destination: .section(.notifications)) }
            ),
            (
                "13-troubleshooting",
                { settingsPreview(destination: .section(.troubleshooting)) }
            ),
            (
                "14-all-inboxes",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .allInboxes, initialInboxMode: "Classic")) }
            ),
            (
                "15-personal",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .personal, initialInboxMode: "Classic")) }
            ),
            (
                "16-notifications-mailbox",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .notifications, initialInboxMode: "Classic")) }
            ),
            (
                "17-newsletters",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .newsletters, initialInboxMode: "Classic")) }
            ),
            (
                "18-sent",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .sent, initialInboxMode: "Classic")) }
            ),
            (
                "19-archive",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .archive, initialInboxMode: "Classic")) }
            ),
            (
                "20-trash",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .trash, initialInboxMode: "Classic")) }
            ),
            (
                "21-ai-index-status",
                { AnyView(PlainpostRootView(viewModel: .designPreview(), initialDestination: .aiIndexStatus)) }
            ),
            (
                "22-empty-reader",
                { AnyView(PlainpostRootView(viewModel: emptyReaderPreview(), initialDestination: .personal, initialInboxMode: "Classic")) }
            ),
            (
                "23-ask-mail-inspector",
                {
                    AnyView(
                        HStack(spacing: 0) {
                            Color(nsColor: .windowBackgroundColor)
                            AskMailInspectorWorkspace(
                                viewModel: .designPreview(),
                                activeContext: AskMailActiveContext(
                                    conversationKey: "thr_intro",
                                    subject: "Introduction: Max and Emily",
                                    messageIDs: [MessageID("jessica-intro")]
                                ),
                                close: {}
                            )
                            .frame(width: 360)
                            .background(.regularMaterial)
                        }
                    )
                }
            ),
            ("23b-ask-mail-upcoming", { askMailInspectorFixture(.designPreview(turns: [AskMailSnapshotFixtures.upcoming])) }),
            ("23c-ask-mail-quote-draft", { askMailInspectorFixture(.designPreview(turns: AskMailSnapshotFixtures.quoteDraft)) }),
            ("23d-ask-mail-empty", { askMailInspectorFixture(.designPreview(turns: [], starters: AskMailSnapshotFixtures.starters)) }),
            ("23e-ask-mail-no-match", { askMailInspectorFixture(.designPreview(turns: [AskMailSnapshotFixtures.noMatch])) }),
            (
                "23f-ask-mail-working",
                { askMailInspectorFixture(.designPreview(turns: [], pendingQuestion: "What do I need to deal with this week?")) }
            ),
            (
                "31-ask-mail-root-open",
                {
                    let askMail = AskMailViewModel.designPreview()
                    return AnyView(
                        HStack(spacing: 0) {
                            ZStack(alignment: .leading) {
                                PlainpostRootView(
                                    viewModel: .designPreview(),
                                    aiAssistant: .designPreview(),
                                    askMail: askMail,
                                    initialSelectedMessageID: "jessica-intro",
                                    showsAIInspector: false
                                )

                                // NavigationSplitView's sidebar column is blank in the
                                // headless NSHostingView renderer, so draw the production
                                // sidebar over its reserved 190-point region for this fixture.
                                PlainpostSidebar(
                                    selection: .constant(.smartInbox),
                                    viewModel: .designPreview()
                                )
                                .frame(width: 190)
                                .frame(maxHeight: .infinity)
                                .background(.regularMaterial)
                            }
                            .overlay(alignment: .topTrailing) {
                                // NSHostingView also omits SwiftUI's window toolbar. Keep this
                                // visible fixture-local strip aligned with the reader title area.
                                headlessMailboxToolbarFixture(
                                    selectedInboxMode: .focusedList,
                                    showsBack: false,
                                    showsMessageActions: true
                                )
                                    .padding(.top, 8)
                                    .padding(.trailing, 10)
                            }
                            .frame(width: 912)

                            AskMailInspectorWorkspace(
                                viewModel: askMail,
                                activeContext: AskMailActiveContext(
                                    conversationKey: "thr_intro",
                                    subject: "Introduction: Max and Emily",
                                    messageIDs: [MessageID("jessica-intro")]
                                ),
                                close: {}
                            )
                            .frame(width: 360)
                            .background(.regularMaterial)
                        }
                        .frame(width: 1_272)
                    )
                }
            ),
            (
                "25-account-sidebar-two-accounts",
                {
                    let home = Account(
                        id: AccountID("design-home"), displayName: "Personal",
                        email: EmailAddress("me@example.com"),
                        imapHost: "imap.example.com", smtpHost: "smtp.example.com"
                    )
                    let work = Account(
                        id: AccountID("design-work"), displayName: "Work",
                        email: EmailAddress("me@work.example"),
                        imapHost: "imap.work.example", smtpHost: "smtp.work.example"
                    )
                    return AnyView(
                        HStack(spacing: 0) {
                            PlainpostSidebar(
                                selection: .constant(.allInboxes),
                                viewModel: .designPreview(),
                                designAccounts: [home, work],
                                designUnread: [home.id: ["INBOX": 12], work.id: ["INBOX": 3, "Archive": 1]]
                            )
                            .frame(width: 320)
                            .background(.regularMaterial)

                            Color(nsColor: .windowBackgroundColor)
                        }
                    )
                }
            ),
            (
                "24-account-sidebar",
                {
                    AnyView(
                        HStack(spacing: 0) {
                            PlainpostSidebar(
                                selection: .constant(.allInboxes),
                                viewModel: .designPreview()
                            )
                            .frame(width: 320)
                            .background(.regularMaterial)

                            Color(nsColor: .windowBackgroundColor)
                        }
                    )
                }
            ),
            (
                "25-thread-conversation",
                {
                    AnyView(
                        PlainpostRootView(
                            viewModel: conversationPreview(),
                            aiAssistant: .designPreview(),
                            initialSelectedMessageID: "conversation-reply"
                        )
                    )
                }
            ),
            (
                "26-compose-expanded-recipients",
                { AnyView(expandedRecipientsComposerPreview()) }
            ),
            (
                "27-search-initial",
                { AnyView(MailSearchWorkspace(viewModel: .designTips(), close: {}, openResult: { _ in }, askMail: {}, forceSearchFocusAppearance: true)) }
            ),
            (
                "28-search-suggestions",
                { AnyView(MailSearchWorkspace(viewModel: .designSuggestions(), close: {}, openResult: { _ in }, askMail: {}, forceSearchFocusAppearance: true)) }
            ),
            (
                "29-search-conversation-results",
                { AnyView(MailSearchWorkspace(viewModel: .designResults(), close: {}, openResult: { _ in }, forceSearchFocusAppearance: true)) }
            ),
            (
                "30-search-message-results",
                { AnyView(MailSearchWorkspace(viewModel: .designMessageResults(), close: {}, openResult: { _ in }, forceSearchFocusAppearance: true)) }
            ),
            (
                "31-search-retained-loading",
                { AnyView(MailSearchWorkspace(viewModel: .designRetainedLoading(), close: {}, openResult: { _ in }, forceSearchFocusAppearance: true)) }
            ),
            (
                "32-search-empty",
                { AnyView(MailSearchWorkspace(viewModel: .designEmpty(), close: {}, openResult: { _ in }, askMail: {}, forceSearchFocusAppearance: true)) }
            ),
            (
                "33-search-invalid",
                { AnyView(MailSearchWorkspace(viewModel: .designInvalid(), close: {}, openResult: { _ in }, forceSearchFocusAppearance: true)) }
            ),
            (
                "34-search-rebuilding",
                { AnyView(MailSearchWorkspace(viewModel: .designRebuilding(), close: {}, openResult: { _ in }, rebuildIndex: {}, forceSearchFocusAppearance: true)) }
            ),
            (
                "35-search-unavailable",
                { AnyView(MailSearchWorkspace(viewModel: .designUnavailable(), close: {}, openResult: { _ in }, rebuildIndex: {}, forceSearchFocusAppearance: true)) }
            ),
            (
                "32-undo-send-pending",
                {
                    let snapshot = ComposerRestoreSnapshot.preview()
                    let coordinator = UndoSendCoordinator.preview(
                        state: .pending(snapshot: snapshot, deadline: .now.addingTimeInterval(10))
                    )
                    return AnyView(
                        PlainpostRootView(
                            viewModel: .designPreview(),
                            undoSendCoordinator: coordinator
                        )
                    )
                }
            ),
            // Sync Node and Node-backed mail account snapshots. Render just
            // this set with `PLAINPOST_SNAPSHOT_ONLY=9`.
            (
                "90-sync-node-not-connected",
                { syncNodeSettingsPreview(session: syncNodeNotConnectedSession) }
            ),
            (
                "91-sync-node-ready-to-connect",
                { syncNodeSettingsPreview(session: syncNodeReadyToConnectSession) }
            ),
            (
                "92-sync-node-connected",
                { syncNodeSettingsPreview(session: syncNodeConnectedSession, nodeSettings: syncNodeConnectedStatus) }
            ),
            (
                "93-sync-node-connection-failed",
                { syncNodeSettingsPreview(session: syncNodeConnectionFailedSession) }
            ),
            (
                "94-sync-node-outdated-server-setup",
                { syncNodeSettingsPreview(session: syncNodeOutdatedProfileSession) }
            ),
            (
                "95-sync-node-generic-failure",
                { syncNodeSettingsPreview(session: syncNodeGenericFailureSession) }
            ),
            (
                "96-sync-node-commit-uncertain",
                { syncNodeSettingsPreview(session: syncNodeCommitUncertainSession) }
            ),
            (
                "97-node-account-ready",
                { nodeAccountPreview(state: .ready) }
            ),
            (
                "97b-node-account-needs-attention",
                { nodeAccountPreview(state: .authenticationRequired) }
            ),
            (
                "98-sync-node-connected-unreachable",
                { syncNodeSettingsPreview(session: syncNodeUnreachableSession, nodeSettings: syncNodeUnreachableStatus) }
            ),
            (
                "99-sync-node-connected-replaceable",
                { syncNodeSettingsPreview(session: syncNodeReplaceableSession, nodeSettings: syncNodeConnectedStatus) }
            ),
            (
                "9a-sync-node-matching-confirmation",
                { syncNodeSettingsPreview(session: syncNodeMatchingConfirmationSession) }
            ),
            (
                "9b-sync-node-activation-uncertain",
                { syncNodeSettingsPreview(session: syncNodeActivationUncertainSession) }
            )
        ]

        let standardSize = CGSize(width: 1180, height: 720)
        let toolbarSnapshots: [(String, MailboxToolbarFixtureScenario, Bool, Bool)] = [
            ("01g-mailbox-toolbar-list", .focusedList, false, false),
            ("01h-mailbox-toolbar-reader", .focusedList, true, true),
            ("01i-mailbox-toolbar-list-board", .board, false, false),
            ("01j-mailbox-toolbar-reader-split-board", .splitBoard, true, true),
        ]
        let configurations: [SnapshotConfiguration] = [
            SnapshotConfiguration(
                "mailbox-ledger",
                size: CGSize(width: 1_440, height: 1_024),
                colorScheme: .dark
            ),
            SnapshotConfiguration("dark-large", size: CGSize(width: 1600, height: 1000), colorScheme: .dark),
            SnapshotConfiguration("light-large", size: CGSize(width: 1600, height: 1000), colorScheme: .light),
            SnapshotConfiguration("dark-standard", size: standardSize, colorScheme: .dark),
            SnapshotConfiguration("light-standard", size: standardSize, colorScheme: .light),
            SnapshotConfiguration(
                "ask-mail-recovery",
                size: CGSize(width: 1_272, height: 768),
                colorScheme: .dark
            ),
            SnapshotConfiguration("dark-compact", size: CGSize(width: 900, height: 640), colorScheme: .dark),
            SnapshotConfiguration("light-compact", size: CGSize(width: 900, height: 640), colorScheme: .light),
            SnapshotConfiguration("dark-increased-contrast", size: standardSize, colorScheme: .dark, contrast: .increased),
            SnapshotConfiguration("light-increased-contrast", size: standardSize, colorScheme: .light, contrast: .increased),
            SnapshotConfiguration("dark-reduced-transparency", size: standardSize, colorScheme: .dark, reduceTransparency: true, reduceMotion: true),
            SnapshotConfiguration("light-reduced-transparency", size: standardSize, colorScheme: .light, reduceTransparency: true, reduceMotion: true)
        ]

        let requestedSnapshotNames = requestedValues(for: "PLAINPOST_SNAPSHOT_NAMES")
        let requestedConfigurationNames = requestedValues(for: "PLAINPOST_SNAPSHOT_CONFIGURATIONS")
        // A prefix filter, so e.g. `PLAINPOST_SNAPSHOT_ONLY=9` renders just
        // the Sync Node / Node-account scenario set without listing each
        // name individually.
        let requestedPrefix = ProcessInfo.processInfo.environment["PLAINPOST_SNAPSHOT_ONLY"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        func matchesRequest(_ name: String) -> Bool {
            (requestedSnapshotNames.isEmpty || requestedSnapshotNames.contains(name))
                && (requestedPrefix.map { name.hasPrefix($0) } ?? true)
        }
        let selectedSnapshots = snapshots.filter { matchesRequest($0.0) }
        let selectedToolbarSnapshots = toolbarSnapshots.filter { matchesRequest($0.0) }
        let selectedConfigurations = requestedConfigurationNames.isEmpty
            ? configurations
            : configurations.filter { requestedConfigurationNames.contains($0.name) }

        for configuration in selectedConfigurations {
            let configurationDirectory = outputDirectory.appendingPathComponent(configuration.name, isDirectory: true)
            try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
            for (name, makeView) in selectedSnapshots {
                let destination = configurationDirectory.appendingPathComponent("\(name).png")
                try render(
                    view: makeView(),
                    size: configuration.size,
                    colorScheme: configuration.colorScheme,
                    contrast: configuration.contrast,
                    reduceTransparency: configuration.reduceTransparency,
                    reduceMotion: configuration.reduceMotion,
                    to: destination
                )
                print(destination.path)
            }
            for (name, scenario, showsBack, showsMessageActions) in selectedToolbarSnapshots {
                let destination = configurationDirectory.appendingPathComponent("\(name).png")
                try render(
                    view: AnyView(
                        headlessMailboxToolbarFixture(
                            selectedInboxMode: scenario.selectedInboxMode,
                            showsBack: showsBack,
                            showsMessageActions: showsMessageActions,
                            width: scenario.renderWidth(for: configuration.size)
                        )
                    ),
                    size: configuration.size,
                    colorScheme: configuration.colorScheme,
                    contrast: configuration.contrast,
                    reduceTransparency: configuration.reduceTransparency,
                    reduceMotion: configuration.reduceMotion,
                    to: destination
                )
                print(destination.path)
            }
        }
    }

    /// An Ask Mail inspector at the mockup's Mac inspector width beside a blank mailbox column.
    private static func askMailInspectorFixture(_ viewModel: AskMailViewModel) -> AnyView {
        AnyView(
            HStack(spacing: 0) {
                Color(nsColor: .windowBackgroundColor)
                AskMailInspectorWorkspace(viewModel: viewModel, close: {})
                    .frame(width: 384)
                    .background(.regularMaterial)
            }
        )
    }

    private static func outputDirectoryURL() -> URL {
        if let argument = CommandLine.arguments.dropFirst().first {
            return URL(fileURLWithPath: argument, isDirectory: true)
        }
        return URL(fileURLWithPath: "output/design-verification", isDirectory: true)
    }

    private static func mailboxSnapshot(
        fixedSmartInboxNow: Date,
        initialSelectedMessageID: String?,
        initialListSelectedMessageID: String? = nil,
        initialSmartInboxBundle: SmartInboxDisplayBundle?
    ) -> AnyView {
        AnyView(
            PlainpostRootView(
                viewModel: .designPreview(),
                aiAssistant: .designPreview(),
                initialSelectedMessageID: initialSelectedMessageID,
                initialListSelectedMessageID: initialListSelectedMessageID,
                initialInboxMode: .focusedList,
                initialSmartInboxBundle: initialSmartInboxBundle,
                designNow: fixedSmartInboxNow
            )
        )
    }

    private static func headlessMailboxToolbarFixture(
        selectedInboxMode: InboxDisplayMode,
        showsBack: Bool,
        showsMessageActions: Bool,
        width: CGFloat = 900
    ) -> some View {
        HStack(spacing: 16) {
            if showsBack {
                Button("Back", systemImage: "chevron.left", action: {})
                    .labelStyle(.iconOnly)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Smart Inbox")
                    .font(.headline)
                Text("480 conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Picker(
                "Inbox view",
                selection: .constant(selectedInboxMode.rawValue)
            ) {
                ForEach(
                    InboxDisplayMode.segmentedDisplayOrder,
                    id: \.rawValue
                ) { mode in
                    Label(
                        mode.segmentedTitle,
                        systemImage: mode.segmentedSystemImage
                    )
                    .labelStyle(.iconOnly)
                    .tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .controlSize(.regular)

            if showsMessageActions {
                ControlGroup {
                    Button(
                        "Reply",
                        systemImage: "arrowshape.turn.up.left",
                        action: {}
                    )
                    Button("Archive", systemImage: "archivebox", action: {})
                    Button(
                        "Mark as Read",
                        systemImage: "envelope.open",
                        action: {}
                    )
                    Button("Delete", systemImage: "trash", action: {})
                }
                .labelStyle(.iconOnly)
                .controlSize(.regular)
                .fixedSize()
            }

            ControlGroup {
                Button(
                    "Compose",
                    systemImage: "square.and.pencil",
                    action: {}
                )
                Button("Ask Mail", systemImage: "sparkles", action: {})
                Button("Command Center", systemImage: "command", action: {})
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
            .fixedSize()

            // The packaged NavigationSplitView owns the only sidebar toggle.
            // A headless HStack must not draw an app-owned substitute.
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: width, alignment: Self.mailboxToolbarFixtureFrameAlignment)
        .background(.bar)
    }

    private static func requestedValues(for environmentKey: String) -> Set<String> {
        Set(
            ProcessInfo.processInfo.environment[environmentKey, default: ""]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func smartInboxActivityPreview(
        id: String,
        state: PlainpostOperationState,
        processed: Int,
        total: Int,
        pauseRequested: Bool = false,
        pauseReason: String? = nil,
        designNow: Date
    ) -> AnyView {
        let job = PlainpostDurableJob(
            id: id,
            kind: .aiOperation,
            payloadJSON: "{}",
            state: state,
            pauseRequested: pauseRequested,
            idempotencyKey: id,
            pauseReason: pauseReason,
            progress: PlainpostOperationProgress(
                current: processed,
                total: total,
                phase: "classifying",
                label: "Smart Inbox"
            ),
            createdAt: designNow,
            updatedAt: designNow
        )
        let presentation = SmartInboxActivityPresentation(
            designPreviewJob: job,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let preview = InboxViewModel.designPreview()
        return AnyView(
            ZStack(alignment: .leading) {
                PlainpostRootView(
                    viewModel: preview,
                    aiAssistant: .designPreview(),
                    initialSelectedMessageID: "jessica-intro",
                    initialSmartInboxBundle: nil,
                    designNow: designNow,
                    smartInboxActivityPresentation: presentation
                )

                // NavigationSplitView does not materialize its sidebar in the
                // headless renderer. Overlay the production sidebar so these
                // fixtures exercise the shipped Activity hierarchy.
                PlainpostSidebar(
                    selection: .constant(.smartInbox),
                    viewModel: preview,
                    designSmartInboxActivity: presentation
                )
                .frame(width: 190)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
            }
        )
    }

    private static func smartInboxIdlePreview(designNow: Date) -> AnyView {
        let preview = InboxViewModel.designPreview()
        return AnyView(
            ZStack(alignment: .leading) {
                PlainpostRootView(
                    viewModel: preview,
                    aiAssistant: .designPreview(),
                    initialSelectedMessageID: "jessica-intro",
                    initialSmartInboxBundle: nil,
                    designNow: designNow
                )

                PlainpostSidebar(
                    selection: .constant(.smartInbox),
                    viewModel: preview,
                    designSmartInboxActivity: nil
                )
                .frame(width: 190)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
            }
        )
    }

    private static func setupRequiredInboxPreview() -> InboxViewModel {
        let preview = InboxViewModel.designPreview()
        return InboxViewModel(
            chrome: preview.chrome,
            sidebarItems: preview.sidebarItems,
            smartCards: preview.smartCards,
            classicRows: preview.classicRows,
            selectedThread: preview.selectedThread,
            aiIndexStatus: preview.aiIndexStatus,
            requiresAccountSetup: true
        )
    }

    private static func emptyReaderPreview() -> InboxViewModel {
        let preview = InboxViewModel.designPreview()
        return InboxViewModel(
            chrome: preview.chrome,
            sidebarItems: preview.sidebarItems,
            smartCards: preview.smartCards,
            classicRows: preview.classicRows,
            selectedThread: ThreadDetailModel(
                subject: "No Thread",
                participants: [],
                summaryStatus: "Not summarized",
                actionItems: [],
                availableActions: [],
                messages: []
            ),
            aiIndexStatus: preview.aiIndexStatus,
            requiresAccountSetup: false
        )
    }

    private static func conversationPreview() -> InboxViewModel {
        let preview = InboxViewModel.designPreview()
        let originalMessage = preview.selectedThread.messages.first
            ?? ThreadMessageModel(
                id: "conversation-original",
                sender: "jessica@example.com",
                senderDisplayName: "Jessica Sun",
                dateLabel: "Yesterday, 4:18 PM",
                body: .plainText("Hi Emily,\n\nI'd like to introduce you to Max Harper. I think the two of you should connect.")
            )
        let reply = ThreadMessageModel(
            id: "conversation-reply",
            sender: "max@example.com",
            senderDisplayName: "Max Harper",
            dateLabel: "Today, 9:12 AM",
            body: .plainText("Thanks for the introduction, Jessica.\n\nEmily, great to meet you. I'd be happy to find time for a short conversation next week.\n\nBest,\nMax")
        )

        return InboxViewModel(
            chrome: preview.chrome,
            sidebarItems: preview.sidebarItems,
            smartCards: preview.smartCards,
            classicRows: preview.classicRows,
            selectedThread: ThreadDetailModel(
                subject: "Intro Emily <> Max",
                participants: ["jessica@example.com", "max@example.com", "me@example.com"],
                summaryStatus: "Not summarized",
                actionItems: [],
                availableActions: ["Reply", "Archive", "Delete"],
                messages: [originalMessage, reply],
                categoryLabel: "Personal"
            ),
            aiIndexStatus: preview.aiIndexStatus,
            requiresAccountSetup: false,
            accountIdentity: preview.accountIdentity
        )
    }

    private static func expandedRecipientsComposerPreview() -> ComposerWindow {
        let composer = ComposerViewModel.preview()
        composer.cc = "max@bb8.finance"
        composer.bcc = "archive@example.com"
        return ComposerWindow(
            viewModel: composer,
            close: {},
            showsEmbeddedChrome: false
        )
    }

    private static func commandCenterPreview() -> PlainpostRootView {
        let commandCenter = CommandCenterViewModel.preview()
        commandCenter.open()
        return PlainpostRootView(viewModel: .designPreview(), commandCenter: commandCenter)
    }

    /// The Settings window opened at `destination`; nil lets Settings pick its default page
    /// (the first account).
    private static func settingsPreview(
        destination: PlainpostSettingsDestination?,
        connected: Bool = false,
        labelsState: MailLabelsDesignPreviewState = .standard,
        accountSetup overrideAccountSetup: AccountSetupViewModel? = nil
    ) -> AnyView {
        let accountSetup = overrideAccountSetup ?? (connected
            ? AccountSetupViewModel.connectedPreview()
            : AccountSetupViewModel.preview())
        return AnyView(
            SettingsWorkspace(
                selection: .constant(destination),
                accountSetup: accountSetup,
                aiProviderSettings: .preview(),
                aiIndexStatus: InboxViewModel.designPreview().aiIndexStatus,
                auditLog: .preview(),
                mailRules: .preview(),
                mailLabels: .preview(state: labelsState),
                maintenance: .preview(accountSetup: accountSetup)
            )
            .mailContactDirectory(ContactDirectoryModel.designPreview())
        )
    }

    private static func securityPrivacyPreview(
        loadState: AccountSecurityViewModel.LoadState,
        populated: Bool = false
    ) -> AnyView {
        let devices: [AccountLifecycleDeviceSummary]
        let events: [AccountSecurityEventV1]

        if populated {
            devices = [
                AccountLifecycleDeviceSummary(
                    id: try! AccountDeviceID(
                        "11111111-2222-4333-8444-555555555555"
                    ),
                    platform: .macos,
                    isCurrentDevice: true,
                    localLabel: "Office Mac",
                    status: "active",
                    lastSecurityEventAt: "2026-09-07T14:20:00Z"
                ),
                AccountLifecycleDeviceSummary(
                    id: try! AccountDeviceID(
                        "66666666-7777-4888-8999-aaaaaaaaaaaa"
                    ),
                    platform: .ios,
                    isCurrentDevice: false,
                    localLabel: "Personal iPhone",
                    status: "active",
                    lastSecurityEventAt: "2026-09-06T18:45:00Z"
                ),
            ]
            events = [
                try! AccountSecurityEventV1(
                    handle: Data(repeating: 0x11, count: 32),
                    category: .deviceAdded,
                    actorHandle: Data(repeating: 0x21, count: 32),
                    targetHandle: Data(repeating: 0x31, count: 32),
                    platform: .ios,
                    status: "active",
                    occurredAt: "2026-09-06T18:45:00Z"
                ),
                try! AccountSecurityEventV1(
                    handle: Data(repeating: 0x12, count: 32),
                    category: .deviceSuspended,
                    actorHandle: Data(repeating: 0x22, count: 32),
                    targetHandle: Data(repeating: 0x32, count: 32),
                    platform: .macos,
                    status: "suspended",
                    occurredAt: "2026-09-02T08:10:00Z"
                ),
            ]
        } else {
            devices = []
            events = []
        }

        return AnyView(
            AccountSecuritySettingsDesignPreview(
                loadState: loadState,
                devices: devices,
                events: events
            )
        )
    }

    private static func labelConfirmationPreview(
        state: MailLabelsDesignPreviewState
    ) -> AnyView {
        AnyView(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                MailLabelConfirmationDesignPreview(
                    viewModel: .preview(state: state)
                )
                .fixedSize()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        )
    }

    private static func render(
        view: AnyView,
        size: CGSize,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast,
        reduceTransparency: Bool,
        reduceMotion: Bool,
        to destination: URL
    ) throws {
        let rootView = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
            .mailAccessibilityPreview(
                increasedContrast: contrast == .increased,
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion,
                hoveredMailboxRowID: "stratechery",
                hoveredReadStateMessageID: "stratechery"
            )
            .environment(\.controlActiveState, .active)

        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = .zero
        window.contentMinSize = .zero
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.title = "Plainpost"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        let appearanceName: NSAppearance.Name
        switch (colorScheme, contrast) {
        case (.dark, .increased):
            appearanceName = .accessibilityHighContrastDarkAqua
        case (.light, .increased):
            appearanceName = .accessibilityHighContrastAqua
        case (.dark, _):
            appearanceName = .darkAqua
        default:
            appearanceName = .aqua
        }
        window.appearance = NSAppearance(named: appearanceName)
        window.backgroundColor = colorScheme == .dark ? .windowBackgroundColor : .windowBackgroundColor
        window.contentViewController = hostingController
        window.setContentSize(size)
        let topLeft = NSPoint(
            x: 20,
            y: (NSScreen.main?.frame.maxY ?? 1_200) - 20
        )
        window.setFrameTopLeftPoint(topLeft)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let renderDeadline = Date().addingTimeInterval(0.20)
        while Date() < renderDeadline {
            RunLoop.current.run(until: min(renderDeadline, Date().addingTimeInterval(0.01)))
        }
        window.layoutIfNeeded()
        hostingController.view.layoutSubtreeIfNeeded()
        hostingController.view.displayIfNeeded()
        CATransaction.flush()

        // SwiftUI installs its toolbar after the window is ordered. Reassert
        // the requested content size once that production chrome exists so
        // AppKit's titlebar fitting cannot drift between sequential captures.
        window.setContentSize(size)
        window.setFrameTopLeftPoint(topLeft)
        window.layoutIfNeeded()
        hostingController.view.layoutSubtreeIfNeeded()
        let stabilizationDeadline = Date().addingTimeInterval(2.50)
        while Date() < stabilizationDeadline {
            RunLoop.current.run(
                until: min(
                    stabilizationDeadline,
                    Date().addingTimeInterval(0.01)
                )
            )
        }
        CATransaction.flush()

        // Opt-in (`PLAINPOST_SNAPSHOT_CACHE_DISPLAY=1`) skips the screen-capture
        // attempt outright; by default nothing changes here for anyone with
        // Screen Recording access, since `captureWindow` succeeds and this
        // fallback is never reached.
        let forcesCacheDisplay = ProcessInfo.processInfo.environment["PLAINPOST_SNAPSHOT_CACHE_DISPLAY"] == "1"
        do {
            guard !forcesCacheDisplay else { throw SnapshotError.couldNotCaptureWindow }
            try captureWindow(window, to: destination)
        } catch SnapshotError.couldNotCaptureWindow {
            // Automatic fallback whenever window capture fails (for example,
            // Screen Recording isn't granted): render the hosted view's own
            // AppKit content offscreen instead of the compositor's window
            // image. This never fires when `captureWindow` succeeds.
            guard let bitmap = hostingController.view.bitmapImageRepForCachingDisplay(in: hostingController.view.bounds) else {
                throw SnapshotError.couldNotCaptureWindow
            }
            hostingController.view.cacheDisplay(in: hostingController.view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.couldNotCaptureWindow }
            try png.write(to: destination)
            let reason = forcesCacheDisplay ? "PLAINPOST_SNAPSHOT_CACHE_DISPLAY=1" : "screen capture unavailable"
            print("AppKit content capture (\(reason)): " + destination.path)
        }
    }

    /// The single canonical window capture subprocess.
    private static func captureWindow(_ window: NSWindow, to destination: URL) throws {
        let capture = Process()
        capture.executableURL = .init(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = [
            "-x",
            "-o",
            "-l\(window.windowNumber)",
            destination.path,
        ]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw SnapshotError.couldNotCaptureWindow
        }
    }
}

enum SnapshotError: Error {
    case couldNotCaptureWindow
}

/// Fixed Ask Mail answers mirroring `docs/design/ask-mail-mockups/a-result-blocks.html`.
@MainActor
enum AskMailSnapshotFixtures {
    static let now = Date()

    static func source(_ id: String, sender: String, subject: String, daysAgo: Double, snippet: String) -> MailKnowledgeSource {
        MailKnowledgeSource(
            id: id, messageID: MessageID(id), conversationKey: "thr_\(id)", mailboxPath: "INBOX",
            subject: subject, sender: sender, sentAt: now.addingTimeInterval(-daysAgo * 86_400), snippet: snippet
        )
    }

    static func row(_ source: MailKnowledgeSource, address: String) -> AskMailMessageRow {
        AskMailMessageRow(
            messageID: source.messageID, conversationKey: source.conversationKey, mailboxPath: source.mailboxPath,
            sender: source.sender, senderAddress: address, subject: source.subject, snippet: source.snippet,
            sentAt: source.sentAt, isUnread: true, tag: nil
        )
    }

    static let invoice = source("marco-invoice", sender: "Marco Rossi", subject: "Invoice for September", daysAgo: 2,
                                snippet: "Hi Oleh, attached is the invoice for the September sprint.")
    static let flight = source("swiss-booking", sender: "Swiss International Air Lines", subject: "Your booking LX 318 is confirmed",
                               daysAgo: 1, snippet: "Zurich → London Heathrow · Thu 2 Oct · 07:40")
    static let viewing = source("lena-viewing", sender: "Lena Brandt", subject: "Re: Flat viewing on Saturday", daysAgo: 0,
                                snippet: "Works for me — can you bring the signed form?")
    static let anna = source("anna-q4", sender: "Anna Keller", subject: "Q4 plan: can you review by Friday?", daysAgo: 1,
                             snippet: "Could you look at the Q4 plan before Friday?")
    static let deposit1 = source("lena-deposit-1", sender: "Lena Brandt", subject: "Flat deposit", daysAgo: 16,
                                 snippet: "The landlord asks for a deposit of two months' rent.")
    static let deposit2 = source("lena-deposit-2", sender: "Lena Brandt", subject: "Re: Flat deposit", daysAgo: 9,
                                 snippet: "Good news: they're fine with SwissCaution instead of cash.")

    static let upcoming = AskMailTurn(
        question: "What do I need to deal with this week?",
        answer: AskMailAnswer(
            text: "Three things have a date this week: **Marco's invoice** is due Friday [1], you **fly to London** on Thursday [2], and the **flat viewing** with Lena is on Saturday [3].",
            citations: [
                AskMailCitation(number: 1, source: invoice),
                AskMailCitation(number: 2, source: flight),
                AskMailCitation(number: 3, source: viewing)
            ],
            blocks: [
                .card(AskMailCardBlock(
                    id: "card-invoice", kind: .invoice, title: "Marco Rossi", badge: "Due Fri", hero: "CHF 2,400.00",
                    subtitle: "September sprint · due Friday 3 October",
                    fields: [
                        AskMailCardField(label: "Invoice", value: "2026-09-14"),
                        AskMailCardField(label: "Account", value: "CH93 … 4410"),
                        AskMailCardField(label: "Terms", value: "14 days")
                    ],
                    source: invoice, calendarItem: nil,
                    reminderItem: AskMailReminderItem(title: "Pay Marco's invoice", due: now.addingTimeInterval(3 * 86_400), notes: nil)
                )),
                .card(AskMailCardBlock(
                    id: "card-flight", kind: .flight, title: "Swiss LX 318", badge: "Thu", hero: "ZRH → LHR",
                    subtitle: "Thursday 2 October · 07:40 – 08:25",
                    fields: [
                        AskMailCardField(label: "Booking", value: "KX7P2Q"),
                        AskMailCardField(label: "Seat", value: "14A"),
                        AskMailCardField(label: "Bag", value: "1 × 23 kg")
                    ],
                    source: flight,
                    calendarItem: AskMailCalendarItem(title: "LX 318 ZRH → LHR", start: now.addingTimeInterval(2 * 86_400),
                                                      end: nil, location: "Zurich Airport", notes: nil),
                    reminderItem: AskMailReminderItem(title: "Check in for LX 318", due: now.addingTimeInterval(86_400), notes: nil)
                )),
                .messages(AskMailMessageListBlock(
                    id: "waiting", title: "Waiting on you", icon: .person, tint: .orange,
                    sections: [AskMailMessageSection(
                        id: "waiting", title: "Questions for you", tint: .orange, totalCount: 2, summary: "Lena, Anna",
                        rows: [row(viewing, address: "lena@brandt.example"), row(anna, address: "anna@keller.example")],
                        actionMessageIDs: [viewing.messageID, anna.messageID]
                    )],
                    bulkActions: [], rowAction: .reply
                ))
            ],
            searched: [AskMailSearchToken(label: "Next 7 days"), AskMailSearchToken(label: "Inbox")]
        )
    )

    static let quoteDraft: [AskMailTurn] = [
        AskMailTurn(
            question: "What did we agree about the flat deposit?",
            answer: AskMailAnswer(
                text: "The deposit is **two months' rent, CHF 4,800**, due by 15 October [1]. Lena later confirmed the landlord accepts a **SwissCaution guarantee** instead of cash [2].",
                citations: [AskMailCitation(number: 1, source: deposit1), AskMailCitation(number: 2, source: deposit2)],
                blocks: [.quotes(AskMailQuoteBlock(id: "quotes", quotes: [
                    AskMailQuote(
                        number: 1, source: deposit1,
                        excerpt: "The landlord asks for a deposit of two months' rent (CHF 4,800) paid into a blocked account by 15 October, before the keys are handed over.",
                        highlight: "a deposit of two months' rent (CHF 4,800) paid into a blocked account by 15 October"
                    ),
                    AskMailQuote(
                        number: 2, source: deposit2,
                        excerpt: "Good news: they're fine with SwissCaution instead of cash, just send me the certificate once you have it.",
                        highlight: "they're fine with SwissCaution instead of cash"
                    )
                ]))]
            )
        ),
        AskMailTurn(
            question: "Draft a reply saying I'll go with SwissCaution",
            answer: AskMailAnswer(
                text: "Here's a reply to Lena [1].\n\nEdit it, then open it in Compose to send.",
                citations: [AskMailCitation(number: 1, source: deposit2)],
                blocks: [.draft(AskMailDraftBlock(
                    id: "draft", replyToMessageID: deposit2.messageID, recipientName: "Lena Brandt",
                    recipientAddress: "lena@brandt.example", subject: "Re: Flat deposit",
                    body: "Hi Lena,\n\nThanks for checking with the landlord. I'll go with the SwissCaution guarantee and send you the certificate this week.\n\nBest,\nOleh"
                ))]
            )
        )
    ]

    static let noMatch = AskMailTurn(
        question: "What did Tom say about the offsite?",
        answer: AskMailAnswer(
            text: "I couldn't find any mail from Tom that mentions an offsite.",
            blocks: [.options(AskMailOptionsBlock(id: "widen", title: "Try instead", options: [
                AskMailOption(label: "Search all time", detail: "+3 years", question: "What did Tom say about the offsite? (any date)"),
                AskMailOption(label: "Include \u{201C}retreat\u{201D} and \u{201C}team trip\u{201D}", detail: "4 matches",
                              question: "What did Tom say about the offsite, retreat or team trip?"),
                AskMailOption(label: "A different Tom", detail: "Tom Weber", question: "What did Tom Weber say about the offsite?")
            ]))],
            searched: [
                AskMailSearchToken(label: "From Tom Hughes"),
                AskMailSearchToken(label: "\u{201C}offsite\u{201D}"),
                AskMailSearchToken(label: "Last 12 months")
            ],
            insufficientEvidence: true
        )
    )

    static let starters = [
        AskMailStarter(id: "due", count: "3", title: "Things due this week", detail: "An invoice, a flight and a flat viewing",
                       question: "What do I need to deal with this week?"),
        AskMailStarter(id: "unread", count: "52", title: "Unread messages", detail: "46 look automated",
                       question: "Clean up my unread mail"),
        AskMailStarter(id: "questions", count: "2", title: "Questions for you", detail: "From Lena and Anna",
                       question: "Who is waiting on a reply from me?")
    ]
}
