import XCTest
@testable import PlainpostUI
@testable import PlainpostDB
import PlainpostRuntimeTestSupport

final class PlainpostDesignModelTests: XCTestCase {
    func testSettingsGroupsListSectionsInDisplayOrder() {
        XCTAssertEqual(PlainpostSettingsGroup.allCases.map(\.title), ["Accounts", "Mail", "Plainpost", nil])
        XCTAssertEqual(PlainpostSettingsGroup.mail.sections, [.smartInbox, .rulesLabels, .notifications, .privacy])
        #if os(macOS)
        XCTAssertEqual(PlainpostSettingsGroup.plainpost.sections, [.plainpostAccount, .syncNode, .calendars])
        #else
        XCTAssertEqual(PlainpostSettingsGroup.plainpost.sections, [.plainpostAccount, .syncNode])
        #endif
        XCTAssertEqual(PlainpostSettingsGroup.troubleshooting.sections, [.troubleshooting])
    }

    func testSettingsSectionTitlesAndSymbols() {
        XCTAssertEqual(PlainpostSettingsSection.smartInbox.title, "Smart Inbox & AI")
        XCTAssertEqual(PlainpostSettingsSection.rulesLabels.title, "Rules & Labels")
        XCTAssertEqual(PlainpostSettingsSection.plainpostAccount.systemImage, "person.badge.shield.checkmark")
        XCTAssertEqual(PlainpostSettingsSection.troubleshooting.systemImage, "wrench.and.screwdriver")
        XCTAssertEqual(PlainpostSettingsSection.accounts.title, "Add Account")
    }

    private func runtimeConfiguration(
        databaseURL: URL,
        keychainService: String
    ) -> PlainpostAppRuntimeConfiguration {
        RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: databaseURL,
            keychainService: keychainService
        ).configuration
    }

    func testInspectorStateDoesNotExpandMailboxRootMinimumWidth() {
        XCTAssertEqual(PlainpostRootView.minimumWindowWidth(showsAIInspector: false), 900)
        XCTAssertEqual(PlainpostRootView.minimumWindowWidth(showsAIInspector: true), 900)
    }

    /// The iOS keyboard and landscape fixes size these per platform. The Mac
    /// window and its floating composer keep their sizes.
    func testMacMailboxRootAndComposerKeepTheirWindowSizes() {
        XCTAssertEqual(PlainpostRootView.mailboxRootMinimumHeight, 640)
        XCTAssertEqual(PlainpostRootView.composerBottomPadding, 96)
        XCTAssertEqual(ComposerBodyEditor.minimumEditorHeight, 260)
    }

    @MainActor
    func testAskMailInspectorKeepsMailboxToolbarAvailable() {
        XCTAssertTrue(PlainpostRootView.showsMailboxToolbar(showsAIInspector: false))
        XCTAssertTrue(PlainpostRootView.showsMailboxToolbar(showsAIInspector: true))
    }

    @MainActor
    func testMailboxToolbarKeepsContextualAndGlobalActionsSeparate() {
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarMessageActionIdentifiers,
            ["reply", "reply_all", "forward", "archive", "read_state", "delete"]
        )
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarGlobalActionIdentifiers,
            ["compose", "ask_mail", "command_center"]
        )
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarGroupedItemIdentifiers(
                hasActionableMessage: true
            ),
            [
                ["reply", "reply_all", "forward", "archive", "read_state", "delete"],
                ["compose", "ask_mail", "command_center"],
            ]
        )
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarGroupedItemIdentifiers(
                hasActionableMessage: false
            ),
            [
                ["compose", "ask_mail", "command_center"],
            ]
        )
    }

    @MainActor
    func testMailboxToolbarPlacesActionGroupsAtTheNativeTrailingEdge() {
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarActionPlacement,
            .automatic
        )
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarTrailingItemIdentifiers(
                hasActionableMessage: true
            ),
            [
                "reply",
                "reply_all",
                "forward",
                "archive",
                "read_state",
                "delete",
                "compose",
                "ask_mail",
                "command_center",
            ]
        )
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarTrailingItemIdentifiers(
                hasActionableMessage: false
            ),
            ["compose", "ask_mail", "command_center"]
        )
    }

    @MainActor
    func testMailboxToolbarLeadsWithIdentityThenLayoutModes() {
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarLeadingItemIdentifiers,
            ["mailbox_identity", "inbox_layout"]
        )
    }

    @MainActor
    func testMailboxToolbarUsesCompactNativeChromePolicy() {
        XCTAssertEqual(
            PlainpostRootView.mailboxToolbarIdentitySharedBackgroundVisibility,
            .hidden
        )
        XCTAssertEqual(PlainpostRootView.mailboxToolbarControlSize, .regular)
    }

    @MainActor
    func testMailboxToolbarUsesNativeFixedGapOnlyBetweenTrailingActionGroups() {
        let listPlan = PlainpostRootView.mailboxToolbarSpacingPlan(
            isReader: false,
            hasActionableMessage: false,
            hasMailboxCluster: true
        )
        XCTAssertEqual(
            listPlan.identifiers,
            ["identity_to_layout", "leading_to_actions"]
        )
        let readerPlan = PlainpostRootView.mailboxToolbarSpacingPlan(
            isReader: true,
            hasActionableMessage: true,
            hasMailboxCluster: true
        )
        XCTAssertEqual(
            readerPlan.identifiers,
            [
                "back_to_identity",
                "identity_to_layout",
                "leading_to_actions",
                "message_actions_to_global",
            ]
        )
    }

    @MainActor
    func testMailboxToolbarDoesNotAddListSpacerWithoutMailboxCluster() {
        let plan = PlainpostRootView.mailboxToolbarSpacingPlan(
            isReader: false,
            hasActionableMessage: false,
            hasMailboxCluster: false
        )

        XCTAssertEqual(plan.identifiers, [])
    }

    @MainActor
    func testMailboxRootFillsTheOfferedWindowArea() {
        XCTAssertTrue(PlainpostRootView.mailboxRootMaximumWidth.isInfinite)
        XCTAssertTrue(PlainpostRootView.mailboxRootMaximumHeight.isInfinite)
    }

    func testAskMailEmptyStateUsesFixedTopInset() {
        XCTAssertEqual(AskMailEmptyStateLayout.introductionTopPadding, 24)
    }

    func testVisibleDestinationsKeepModelCategoriesInsideSmartInbox() {
        XCTAssertEqual(
            PlainpostDestination.mailboxDestinations.map(\.title),
            [
                "Smart Inbox",
                "All Inboxes",
                "Drafts",
                "Sent",
                "Archive",
                "Trash"
            ]
        )
        XCTAssertEqual(
            PlainpostDestination.utilityDestinations.map(\.title),
            [
                "Agent approvals",
                "Labels",
                "AI Index Status",
                "Settings"
            ]
        )
    }

    func testDestinationColumnBehaviorMatchesReferenceModes() {
        XCTAssertTrue(PlainpostDestination.smartInbox.usesMailboxList)
        XCTAssertFalse(PlainpostDestination.settings.usesMailboxList)
        XCTAssertFalse(PlainpostDestination.aiIndexStatus.usesMailboxList)
        XCTAssertFalse(PlainpostDestination.approvalQueue.usesMailboxList)
        XCTAssertEqual(PlainpostDestination.approvalQueue.workAreaKind, .approvalQueue)
        XCTAssertEqual(PlainpostDestination.settings.workAreaKind, .settings)
        XCTAssertTrue(PlainpostDestination.smartInbox.usesSmartGrouping)
        XCTAssertFalse(PlainpostDestination.drafts.usesSmartGrouping)
        XCTAssertTrue(PlainpostDestination.personal.showsThreadReader)
        XCTAssertFalse(PlainpostDestination.drafts.showsThreadReader)
        XCTAssertTrue(PlainpostDestination.sent.showsThreadReader)
        XCTAssertFalse(PlainpostDestination.labels.showsThreadReader)
    }

    func testApprovalQueueFiltersCoverPRDReviewStates() {
        XCTAssertEqual(
            ApprovalQueueFilter.defaultFilters.map(\.title),
            [
                "Pending",
                "Failed",
                "All activity"
            ]
        )
    }

    func testApprovalQueueFiltersMatchRequestMetadata() {
        let highRisk = ApprovalQueueItemModel(
            id: "high-risk",
            agentName: "Agent",
            subject: "Intro",
            recipientSummary: "person@example.com, external@example.com",
            riskFlags: ["External recipients"],
            hasAttachments: true,
            requiresAuthentication: true,
            status: "pending"
        )
        let sent = ApprovalQueueItemModel(
            id: "sent",
            agentName: "Agent",
            subject: "Done",
            recipientSummary: "team@example.com",
            riskFlags: [],
            hasAttachments: false,
            status: "sent"
        )

        XCTAssertTrue(ApprovalQueueFilter.all.matches(highRisk))
        XCTAssertTrue(ApprovalQueueFilter.pending.matches(highRisk))
        XCTAssertTrue(ApprovalQueueFilter.highRisk.matches(highRisk))
        XCTAssertTrue(ApprovalQueueFilter.requiresAuth.matches(highRisk))
        XCTAssertTrue(ApprovalQueueFilter.attachments.matches(highRisk))
        XCTAssertTrue(ApprovalQueueFilter.externalRecipients.matches(highRisk))
        XCTAssertFalse(ApprovalQueueFilter.failed.matches(highRisk))

        XCTAssertTrue(ApprovalQueueFilter.sent.matches(sent))
        XCTAssertFalse(ApprovalQueueFilter.pending.matches(sent))
        XCTAssertFalse(ApprovalQueueFilter.highRisk.matches(sent))
    }

    func testAIProviderRowsCanRepresentDisabledRemoteProviders() {
        let row = AIProviderSettingsRowModel(
            id: "openai",
            title: "OpenAI",
            statusLabel: "Disabled (MVP)",
            localityLabel: "Cloud",
            modelSummary: "Chat: gpt-4o-mini · Embeddings: text-embedding-3-small",
            detail: "Remote · Disabled",
            systemImage: "cloud",
            isSelected: false
        )

        XCTAssertEqual(row.id, "openai")
        XCTAssertEqual(row.statusLabel, "Disabled (MVP)")
        XCTAssertEqual(row.localityLabel, "Cloud")
        XCTAssertFalse(row.isSelected)
    }

    @MainActor
    func testRuntimeInboxModelFlagsFirstRunWhenNoAccountsExist() throws {
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("plainpost-design-\(UUID().uuidString).sqlite"),
                keychainService: "PlainpostDesignModelTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )

        XCTAssertTrue(runtime.makeInboxViewModel().requiresAccountSetup)
    }

    func testPreviewInboxDoesNotRequireAccountSetup() {
        XCTAssertFalse(InboxViewModel.preview().requiresAccountSetup)
    }

    func testDesignPreviewProvidesReferenceDensity() {
        let viewModel = InboxViewModel.designPreview()

        XCTAssertGreaterThanOrEqual(viewModel.classicRows.count, 8)
        XCTAssertEqual(viewModel.smartCards.first?.title, "People")
        XCTAssertEqual(viewModel.smartCards.first?.messages.first?.subject, "Intro Emily <> Max")
        XCTAssertEqual(viewModel.selectedThread.subject, "Intro Emily <> Max")
        XCTAssertFalse(viewModel.selectedThread.messages.isEmpty)
        XCTAssertEqual(viewModel.aiIndexStatus.title, "AI index ready")
    }

    func testDesignPreviewCoversDeterministicSmartInboxDailyTriage() throws {
        let viewModel = InboxViewModel.designPreview()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Zurich"))
        let locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-22T10:00:00Z")
        )
        let model = SmartInboxTriageModel.build(
            rows: viewModel.classicRows,
            now: now,
            calendar: calendar,
            locale: locale
        )

        XCTAssertTrue(model.todayPromotedRows.contains { $0.smartPriority == .high && $0.requiresAction })
        XCTAssertTrue(model.todayPromotedRows.contains { $0.smartPriority == .normal && $0.requiresAction })
        XCTAssertTrue(model.todayPromotedRows.contains { $0.smartPriority == .high && !$0.requiresAction })

        let bundleIDs = Set(model.todayBundles.map(\.id))
        XCTAssertGreaterThanOrEqual(bundleIDs.count, 4)
        XCTAssertTrue(bundleIDs.contains(.invitations))
        XCTAssertTrue(bundleIDs.contains(.invitationResponses))

        XCTAssertEqual(
            model.historicalSections.prefix(4).map(\.id),
            [.yesterday, .thisWeek, .lastWeek, .month(year: 2026, month: 6)]
        )

        let lowConfidenceHighPriority = try XCTUnwrap(
            viewModel.classicRows.first { $0.smartPriority == .high && ($0.smartConfidence ?? 1) < 0.5 }
        )
        XCTAssertEqual(lowConfidenceHighPriority.category, .newsletter)
        XCTAssertTrue(model.drillInRows(for: .newsletters).contains { $0.id == lowConfidenceHighPriority.id })

        let triageStorageLabels = viewModel.classicRows.flatMap { row in
            Mirror(reflecting: row).children.compactMap(\.label)
        }
        XCTAssertFalse(triageStorageLabels.contains("reason"))
        XCTAssertFalse(triageStorageLabels.contains("summary"))
    }

    @MainActor
    func testDesignPreviewCalendarIgnoresAlternateHostTimeZone() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-22T10:00:00Z")
        )
        var alternateHostCalendar = Calendar(identifier: .gregorian)
        alternateHostCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let alternateHostLocale = Locale(identifier: "de_DE")

        XCTAssertEqual(
            PlainpostRootView.smartInboxCalendar(designNow: nil, current: alternateHostCalendar),
            alternateHostCalendar
        )
        XCTAssertEqual(
            PlainpostRootView.smartInboxLocale(designNow: nil, current: alternateHostLocale),
            alternateHostLocale
        )

        let calendar = PlainpostRootView.smartInboxCalendar(
            designNow: now,
            current: alternateHostCalendar
        )
        let locale = PlainpostRootView.smartInboxLocale(
            designNow: now,
            current: alternateHostLocale
        )
        let model = SmartInboxTriageModel.build(
            rows: InboxViewModel.designPreview().classicRows,
            now: now,
            calendar: calendar,
            locale: locale
        )

        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone.identifier, "Europe/Zurich")
        XCTAssertEqual(locale.identifier, "en_US_POSIX")
        XCTAssertTrue(model.todayBundles.contains { $0.id == .invitationResponses })
        XCTAssertTrue(model.drillInRows(for: .invitationResponses).contains { $0.id == "calendar-response" })
    }
}
