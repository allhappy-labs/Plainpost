import AppKit
import SwiftUI
import XCTest
import PlainpostAI
import PlainpostCore
import PlainpostOperations
@_spi(DesignPreview) @testable import PlainpostUI

@MainActor
final class PlainpostRootViewTests: XCTestCase {
    func testSettingsWorkspaceRequiresRealRulesAndLabels() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/PlainpostUITests/PlainpostRootViewTests.swift",
            with: "Sources/PlainpostUI/PlainpostSettingsViews.swift"))
        XCTAssertFalse(source.contains("mailRules: MailRulesViewModel = .preview()"))
        XCTAssertFalse(source.contains("mailLabels: MailLabelsViewModel = .preview()"))
        let app = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/PlainpostUITests/PlainpostRootViewTests.swift",
            with: "Sources/PlainpostApp/PlainpostApp.swift"))
        XCTAssertTrue(app.contains(".notificationPermission("))
    }

    func testAskMailBatchArchiveKeepsUnrelatedSelection() {
        XCTAssertFalse(MessageActionController.archiveClearsSelection(
            origin: .askMailBatch, selectedMessageID: "open", mutatedMessageID: "other"))
        XCTAssertFalse(MessageActionController.archiveClearsSelection(
            origin: .askMailBatch, selectedMessageID: nil, mutatedMessageID: "other"))
        XCTAssertTrue(MessageActionController.archiveClearsSelection(
            origin: .askMailBatch, selectedMessageID: "open", mutatedMessageID: "open"))
        XCTAssertTrue(MessageActionController.archiveClearsSelection(
            origin: .mailbox, selectedMessageID: "open", mutatedMessageID: "other"))
    }

    func testSecurityPrivacySettingsReceivesAccountSession() throws {
        let session = AccountSessionViewModel(prepareSession: { _ in .active })
        let root = PlainpostRootView(
            viewModel: .designPreview(),
            accountSessionModel: session,
            initialDestination: .settings,
            initialSettingsSection: .plainpostAccount
        )

        let mailSession = try XCTUnwrap(
            Mirror(reflecting: root).children.first {
                $0.label == "_session"
            }?.value as? StateObject<MailSession>
        ).wrappedValue
        let stored = try XCTUnwrap(mailSession.accountSessionModel)
        XCTAssertTrue(stored === session)
    }

    func testSettingsWindowLanguageChangeImmediatelyResetsExistingReaderTranslation() async {
        let languageSettings = TranslationLanguageSettingsViewModel(
            options: [
                .init(id: "de", localizedName: "German"),
                .init(id: "en", localizedName: "English"),
            ]
        )
        let message = ThreadMessageModel(
            id: "shared-settings-translation",
            sender: "sender@example.com",
            body: .plainText("Original")
        )
        let translation = ThreadTranslationViewModel(
            handler: RootTranslationHandler(
                providerID: "foundation",
                modelID: "apple-foundation-system",
                cachedBodies: [message.id: "Translated"]
            )
        )
        let applicationState = PlainpostAppTranslationState(
            languageSettings: languageSettings
        )
        await translation.prepare(
            messages: [message],
            configuration: ThreadTranslationConfiguration(
                targetLanguageID: "en",
                targetLanguageName: "English"
            )
        )
        XCTAssertEqual(translation.actionTitle, "Show Translation")

        let root = PlainpostRootView(
            translationSettings: applicationState.languageSettings,
            threadTranslation: translation
        )
        let readerTranslationIdentity = ObjectIdentifier(translation)
        let hostingView = NSHostingView(
            rootView: AnyView(root.frame(width: 900, height: 640))
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        hostingView.layoutSubtreeIfNeeded()

        applicationState.languageSettings.selectLanguage("de")
        for _ in 0..<20 where translation.actionTitle != "Translate" {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(applicationState.languageSettings.selectedLanguageID, "de")
        XCTAssertEqual(translation.actionTitle, "Translate")
        XCTAssertEqual(
            ObjectIdentifier(translation),
            readerTranslationIdentity
        )
    }

    func testProviderAndLanguageChangesKeepTranslationConfigurationScoped() async {
        let message = ThreadMessageModel(
            id: "root-translation",
            sender: "sender@example.com",
            body: .plainText("Original")
        )
        let configuration = ThreadTranslationConfiguration(
            targetLanguageID: "de",
            targetLanguageName: "German"
        )
        let cachedHandler = RootTranslationHandler(
            providerID: "foundation",
            modelID: "apple-foundation-system",
            cachedBodies: [message.id: "Übersetzt"]
        )
        let replacementHandler = RootTranslationHandler(
            providerID: "ollama",
            modelID: "ollama:qwen3:8b"
        )
        let translation = ThreadTranslationViewModel(handler: cachedHandler)
        await translation.prepare(messages: [message], configuration: configuration)
        XCTAssertEqual(translation.actionTitle, "Show Translation")

        var assistantProviders: [String] = []
        var askMailProviders: [String] = []
        var translationProviders: [String] = []
        PlainpostRootView.applyAIProviderChange(
            providerID: "ollama",
            aiAssistant: .preview(),
            askMail: .preview(),
            threadTranslation: translation,
            configureAIAssistant: { _, providerID in
                assistantProviders.append(providerID)
            },
            configureAskMail: { _, providerID in
                askMailProviders.append(providerID)
            },
            configureThreadTranslation: { viewModel, providerID in
                translationProviders.append(providerID)
                viewModel.configure(handler: replacementHandler)
            }
        )

        XCTAssertEqual(assistantProviders, ["ollama"])
        XCTAssertEqual(askMailProviders, ["ollama"])
        XCTAssertEqual(translationProviders, ["ollama"])
        XCTAssertEqual(translation.actionTitle, "Translate")

        translation.configure(handler: cachedHandler)
        await translation.prepare(messages: [message], configuration: configuration)
        XCTAssertEqual(translation.actionTitle, "Show Translation")
        PlainpostRootView.applyTranslationLanguageChange(
            threadTranslation: translation
        )

        XCTAssertEqual(translation.actionTitle, "Translate")
        XCTAssertEqual(assistantProviders, ["ollama"])
        XCTAssertEqual(askMailProviders, ["ollama"])
        XCTAssertEqual(translationProviders, ["ollama"])
    }

    func testTranslationPreparationIdentityIncludesMessageOrderLanguageProviderAndModel() {
        let base = ThreadTranslationPreparationID(
            orderedMessageIDs: ["first", "second"],
            orderedSourceFingerprints: ["source-first", "source-second"],
            targetLanguageID: "de",
            providerID: "foundation",
            modelID: "apple-foundation-system"
        )

        XCTAssertNotEqual(
            base,
            ThreadTranslationPreparationID(
                orderedMessageIDs: ["second", "first"],
                orderedSourceFingerprints: ["source-second", "source-first"],
                targetLanguageID: "de",
                providerID: "foundation",
                modelID: "apple-foundation-system"
            )
        )
        XCTAssertNotEqual(
            base,
            ThreadTranslationPreparationID(
                orderedMessageIDs: ["first", "second"],
                orderedSourceFingerprints: ["source-first", "source-second"],
                targetLanguageID: "fr",
                providerID: "foundation",
                modelID: "apple-foundation-system"
            )
        )
        XCTAssertNotEqual(
            base,
            ThreadTranslationPreparationID(
                orderedMessageIDs: ["first", "second"],
                orderedSourceFingerprints: ["source-first", "source-second"],
                targetLanguageID: "de",
                providerID: "ollama",
                modelID: "ollama:qwen3:8b"
            )
        )
        XCTAssertNotEqual(
            base,
            ThreadTranslationPreparationID(
                orderedMessageIDs: ["first", "second"],
                orderedSourceFingerprints: ["source-first", "source-second-refreshed"],
                targetLanguageID: "de",
                providerID: "foundation",
                modelID: "apple-foundation-system"
            )
        )
    }

    @MainActor
    func testScopedLabelCenterOwnsTheModalAndRestoresSourceFocusOnClose() {
        let global = CommandCenterViewModel.preview()
        let labels = MessageLabelCommandCenterViewModel()
        let focus = MailboxRowQuickActionFocusCoordinator()
        let lifecycle = MailboxCommandSurfaceLifecycle(
            globalCommandCenter: global,
            labelCommandCenter: labels,
            quickActionFocus: focus
        )
        global.open()

        lifecycle.openLabels(
            for: MessageRowModel(
                id: "m1",
                sender: "sender@example.com",
                subject: "Subject",
                preview: "Preview",
                category: .personal,
                categoryLabel: "Personal",
                isUnread: true,
                isPinned: false,
                dateLabel: "10:00",
                actions: []
            )
        )

        XCTAssertTrue(labels.isPresented)
        XCTAssertFalse(global.isPresented)

        lifecycle.closeLabels(restoringFocus: true)

        XCTAssertFalse(labels.isPresented)
        XCTAssertEqual(focus.requestedLabelMessageID, "m1")
    }

    @MainActor
    func testGlobalCenterAndMailboxInvalidationDismissScopedLabelsWithoutStaleFocus() {
        let global = CommandCenterViewModel.preview()
        let labels = MessageLabelCommandCenterViewModel()
        let focus = MailboxRowQuickActionFocusCoordinator()
        let lifecycle = MailboxCommandSurfaceLifecycle(
            globalCommandCenter: global,
            labelCommandCenter: labels,
            quickActionFocus: focus
        )
        let row = MessageRowModel(
            id: "m1",
            sender: "sender@example.com",
            subject: "Subject",
            preview: "Preview",
            category: .personal,
            categoryLabel: "Personal",
            isUnread: true,
            isPinned: false,
            dateLabel: "10:00",
            actions: []
        )

        lifecycle.openLabels(for: row)
        lifecycle.openGlobalCommandCenter()

        XCTAssertFalse(labels.isPresented)
        XCTAssertTrue(global.isPresented)
        XCTAssertNil(focus.requestedLabelMessageID)

        global.close()
        lifecycle.openLabels(for: row)
        lifecycle.invalidateMailboxSource(
            availableMessageIDs: ["another-message"]
        )

        XCTAssertFalse(labels.isPresented)
        XCTAssertNil(focus.requestedLabelMessageID)
    }

    func testScopedCommandCenterTransitionHonorsReducedMotion() {
        XCTAssertEqual(
            MailboxCommandSurfaceTransition.resolve(reduceMotion: true),
            .opacityOnly
        )
        XCTAssertEqual(
            MailboxCommandSurfaceTransition.resolve(reduceMotion: false),
            .scaleAndOpacity
        )
    }

    func testDesignPreviewForcesFocusedModeAndHonorsTypedBundleRoute() throws {
        let defaults = UserDefaults.standard
        let key = PlainpostMailboxInitialPresentation.persistedModeKey
        let priorValue = defaults.object(forKey: key)
        defer {
            if let priorValue {
                defaults.set(priorValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        for persistedMode in [
            InboxDisplayMode.simpleList,
            .unreadCards,
        ] {
            defaults.set(
                persistedMode.rawValue,
                forKey: key
            )
            let presentation = PlainpostMailboxInitialPresentation.designPreview(
                mode: .focusedList,
                smartInboxBundle: .newsletters
            )

            XCTAssertEqual(presentation.mode, .focusedList)
            XCTAssertEqual(
                presentation.context,
                .smartInboxBundle(.newsletters)
            )
            let root = PlainpostRootView(
                viewModel: .designPreview(),
                aiAssistant: .designPreview(),
                initialInboxMode: .focusedList,
                initialSmartInboxBundle: .newsletters,
                designNow: Date(timeIntervalSince1970: 1)
            )
            XCTAssertEqual(
                try selectedInboxMode(in: root),
                .focusedList
            )
            XCTAssertEqual(
                try mailboxNavigation(in: root).route,
                .list(.smartInboxBundle(.newsletters))
            )
        }
    }

    func testProductionPresentationStillUsesPersistedInboxMode() throws {
        let defaults = UserDefaults.standard
        let key = PlainpostMailboxInitialPresentation.persistedModeKey
        let priorValue = defaults.object(forKey: key)
        defer {
            if let priorValue {
                defaults.set(priorValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        for persistedMode in [
            InboxDisplayMode.simpleList,
            .unreadCards,
        ] {
            defaults.set(
                persistedMode.rawValue,
                forKey: key
            )
            let presentation = PlainpostMailboxInitialPresentation.production(
                destination: .smartInbox,
                requestedMode: nil,
                persistedMode: defaults.string(forKey: key),
                fallbackMode: .focusedList
            )
            let root = PlainpostRootView(viewModel: .designPreview())

            XCTAssertEqual(presentation.mode, persistedMode)
            XCTAssertEqual(
                presentation.context,
                .mailbox(destination: .smartInbox, mode: persistedMode)
            )
            XCTAssertEqual(try selectedInboxMode(in: root), persistedMode)
            XCTAssertEqual(
                try mailboxNavigation(in: root).route,
                .list(.mailbox(destination: .smartInbox, mode: persistedMode))
            )
        }
    }

    func testDesignPreviewCanSelectARealListRowWithoutOpeningTheReader() {
        let listSelection = PlainpostDesignPreviewMailboxSelection.resolve(
            initialReaderMessageID: nil,
            initialListSelectedMessageID: "jessica-intro"
        )
        let readerSelection = PlainpostDesignPreviewMailboxSelection.resolve(
            initialReaderMessageID: "reader-message",
            initialListSelectedMessageID: "list-message"
        )

        XCTAssertEqual(listSelection.selectedMessageID, "jessica-intro")
        XCTAssertNil(listSelection.readerMessageID)
        XCTAssertEqual(readerSelection.selectedMessageID, "reader-message")
        XCTAssertEqual(readerSelection.readerMessageID, "reader-message")
    }

    func testDesignPreviewCanTargetOneMailboxRowForDeterministicHover() {
        XCTAssertNil(
            MailAccessibilityPreviewOverrides().hoveredMailboxRowID
        )
        XCTAssertNil(
            MailAccessibilityPreviewOverrides().hoveredReadStateMessageID
        )
        XCTAssertEqual(
            MailAccessibilityPreviewOverrides(
                hoveredMailboxRowID: "message-hovered",
                hoveredReadStateMessageID: "read-state-hovered"
            ).hoveredMailboxRowID,
            "message-hovered"
        )
        XCTAssertEqual(
            MailAccessibilityPreviewOverrides(
                hoveredReadStateMessageID: "read-state-hovered"
            ).hoveredReadStateMessageID,
            "read-state-hovered"
        )
    }

    func testMailMessageListRowConsumesTargetedPreviewHoverOverride() throws {
        let row = MessageRowModel(
            id: "message-hovered",
            sender: "sender@example.com",
            subject: "Keep the preview visible",
            preview: "Quick actions belong only to this row.",
            category: .personal,
            categoryLabel: "Personal",
            isUnread: true,
            isPinned: false,
            dateLabel: "10:24",
            actions: MessageRowActionModel.defaultActions(isUnread: true)
        )

        func renderedRow(hoveredMailboxRowID: String?) throws -> Data {
            let renderer = ImageRenderer(
                content: MailMessageListRow(
                    row: row,
                    selected: false,
                    widthClass: .wide,
                    mailActions: .preview(),
                    performMessageAction: { _, _ in }
                )
                .mailAccessibilityPreview(
                    hoveredMailboxRowID: hoveredMailboxRowID
                )
                .frame(width: 1_000, height: 52)
            )
            renderer.proposedSize = ProposedViewSize(width: 1_000, height: 52)
            return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        }

        let targeted = try renderedRow(hoveredMailboxRowID: row.id)
        let untargeted = try renderedRow(hoveredMailboxRowID: "another-message")

        XCTAssertNotEqual(
            targeted,
            untargeted,
            "The actual row must consume the environment override and render quick actions only for its ID."
        )
    }

    func testMailMessageListRowConsumesTargetedReadStateHoverOverride() throws {
        let row = MessageRowModel(
            id: "read-state-hovered",
            sender: "sender@example.com",
            subject: "Preview the read-state action",
            preview: "The unread dot should become an eye.",
            category: .personal,
            categoryLabel: "Personal",
            isUnread: true,
            isPinned: false,
            dateLabel: "10:25",
            actions: MessageRowActionModel.defaultActions(isUnread: true)
        )

        func renderedRow(hoveredReadStateMessageID: String?) throws -> Data {
            let renderer = ImageRenderer(
                content: MailMessageListRow(
                    row: row,
                    selected: false,
                    widthClass: .wide,
                    mailActions: .preview(),
                    performMessageAction: { _, _ in }
                )
                .mailAccessibilityPreview(
                    hoveredReadStateMessageID: hoveredReadStateMessageID
                )
                .frame(width: 1_000, height: 52)
            )
            renderer.proposedSize = ProposedViewSize(width: 1_000, height: 52)
            return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        }

        let targeted = try renderedRow(hoveredReadStateMessageID: row.id)
        let untargeted = try renderedRow(
            hoveredReadStateMessageID: "another-message"
        )

        XCTAssertNotEqual(
            targeted,
            untargeted,
            "Only the targeted read-state control should render its direct-hover eye preview."
        )
    }

    func testUnavailableAIGenerationSkipsAutomaticSmartInboxRefresh() {
        XCTAssertFalse(
            PlainpostAIGenerationPolicy.isAvailable(
                isIOS: true, foundationAvailability: .requiresNewerOS
            )
        )
        XCTAssertTrue(
            PlainpostAIGenerationPolicy.isAvailable(
                isIOS: true, foundationAvailability: .available
            )
        )
        XCTAssertTrue(
            PlainpostAIGenerationPolicy.isAvailable(
                isIOS: false, foundationAvailability: .requiresNewerOS
            )
        )
        XCTAssertFalse(
            PlainpostRootView.shouldRefreshSmartInboxAfterAccountConnection(
                isRerunActive: false,
                aiGenerationAvailable: false
            )
        )
        XCTAssertTrue(
            PlainpostRootView.shouldRefreshSmartInboxAfterAccountConnection(
                isRerunActive: false,
                aiGenerationAvailable: true
            )
        )
    }

    func testMailboxUsesTwoColumnsWhileUtilitiesKeepThree() {
        XCTAssertEqual(
            PlainpostRootWorkspacePresentation.resolve(for: .mailbox),
            .sidebarAndWorkspace
        )
        XCTAssertEqual(
            PlainpostRootWorkspacePresentation.resolve(for: .settings),
            .sidebarContentAndDetail
        )
        XCTAssertEqual(
            PlainpostRootWorkspacePresentation.resolve(for: .approvalQueue),
            .sidebarContentAndDetail
        )
    }

    func testLateFailureDoesNotRestorePriorReaderAfterInterveningNavigation() {
        let optimistic = MailboxNavigationIntent(
            destination: .smartInbox,
            mode: .focusedList,
            route: .list(.smartInboxOverview),
            selectedMessageID: nil,
            revision: 12
        )
        let transition = MailboxOptimisticNavigationTransition(
            optimisticIntent: optimistic
        )
        let openedAnotherMessage = MailboxNavigationIntent(
            destination: .allInboxes,
            mode: .simpleList,
            route: .reader(
                messageID: "message-2",
                returnContext: .mailbox(
                    destination: .allInboxes,
                    mode: .simpleList
                )
            ),
            selectedMessageID: "message-2",
            revision: 13
        )
        let returnedToSameAppearance = MailboxNavigationIntent(
            destination: optimistic.destination,
            mode: optimistic.mode,
            route: optimistic.route,
            selectedMessageID: optimistic.selectedMessageID,
            revision: 14
        )

        XCTAssertFalse(
            transition.shouldRestoreNavigation(currentIntent: openedAnotherMessage)
        )
        XCTAssertFalse(
            transition.shouldRestoreNavigation(currentIntent: returnedToSameAppearance)
        )
    }

    func testUnchangedOptimisticNavigationAllowsFailureRecovery() {
        let optimistic = MailboxNavigationIntent(
            destination: .smartInbox,
            mode: .focusedList,
            route: .list(.smartInboxOverview),
            selectedMessageID: nil,
            revision: 12
        )
        let transition = MailboxOptimisticNavigationTransition(
            optimisticIntent: optimistic
        )

        XCTAssertTrue(
            transition.shouldRestoreNavigation(currentIntent: optimistic)
        )
    }

    func testActivityCoordinatorKeepsIdleQuietAndRefreshesRunningWork() throws {
        var durableJob: PlainpostDurableJob?
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { durableJob },
            pause: { _ in },
            resume: { _ in }
        )

        XCTAssertNil(coordinator.presentation)
        XCTAssertNil(coordinator.actionMessage)

        durableJob = activityJob(state: .running)
        coordinator.refresh(locale: Locale(identifier: "en_US"))

        XCTAssertEqual(coordinator.presentation?.id, "activity-running")
        XCTAssertEqual(coordinator.presentation?.title, "Organizing Smart Inbox")
        XCTAssertEqual(coordinator.presentation?.detail, "2,340 processed · 6,916 left")
    }

    func testCompletedActivityDisappearsWithoutSuccessChatter() {
        var durableJob: PlainpostDurableJob? = activityJob(state: .running)
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { durableJob },
            pause: { _ in },
            resume: { _ in }
        )
        XCTAssertNotNil(coordinator.presentation)

        durableJob = activityJob(state: .completed)
        coordinator.refresh(locale: Locale(identifier: "en_US"))

        XCTAssertNil(coordinator.presentation)
        XCTAssertNil(coordinator.actionMessage)
    }

    func testRerunGateDoesNotSuppressAutomaticRefreshForIncrementalActivity() {
        var durableJob = activityJob(state: .running, runMode: .incremental)
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { durableJob },
            pause: { _ in },
            resume: { _ in }
        )

        XCTAssertFalse(coordinator.isRerunActive)

        durableJob = activityJob(state: .paused, runMode: .rerunAll)
        coordinator.refresh()

        XCTAssertTrue(coordinator.isRerunActive)
    }

    func testSidebarKeepsActivityIndependentOfSelectedDestination() throws {
        let runningJob = activityJob(state: .running)
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(job: runningJob, locale: Locale(identifier: "en_US"))
        )

        for destination in [PlainpostDestination.smartInbox, .settings] {
            let root = PlainpostRootView(
                viewModel: .designPreview(),
                initialDestination: destination,
                smartInboxActivityJob: { runningJob }
            )
            let sidebar = PlainpostSidebar(
                selection: .constant(destination),
                viewModel: .designPreview(),
                smartInboxActivity: root.smartInboxActivityCoordinator.presentation,
                smartInboxActivityActionInFlight: false,
                smartInboxActivityActionMessage: nil,
                pauseSmartInbox: { _ in },
                resumeSmartInbox: { _ in }
            )
            XCTAssertEqual(sidebar.smartInboxActivity?.id, presentation.id)
            XCTAssertEqual(sidebar.smartInboxActivity?.title, presentation.title)
            XCTAssertEqual(sidebar.smartInboxActivity?.processed, presentation.processed)
            XCTAssertEqual(sidebar.smartInboxActivity?.remaining, presentation.remaining)
        }
    }

    func testActivitySectionRoutesPauseAndResumeByPresentationJobID() throws {
        var received: [(String, String)] = []
        let running = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: activityJob(state: .running),
                locale: Locale(identifier: "en_US")
            )
        )
        let paused = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: activityJob(state: .paused, pauseReason: "user-requested"),
                locale: Locale(identifier: "en_US")
            )
        )

        SmartInboxActivitySection(
            presentation: running,
            isActionInFlight: false,
            actionMessage: nil,
            pause: { received.append(("pause", $0)) },
            resume: { received.append(("resume", $0)) }
        ).performControl()
        SmartInboxActivitySection(
            presentation: paused,
            isActionInFlight: false,
            actionMessage: nil,
            pause: { received.append(("pause", $0)) },
            resume: { received.append(("resume", $0)) }
        ).performControl()

        XCTAssertEqual(received.map(\.0), ["pause", "resume"])
        XCTAssertEqual(received.map(\.1), [running.id, paused.id])
    }

    func testActivitySectionSuppressesRepeatedControlWhileActionIsInFlight() throws {
        var actionCount = 0
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: activityJob(state: .running),
                locale: Locale(identifier: "en_US")
            )
        )
        let section = SmartInboxActivitySection(
            presentation: presentation,
            isActionInFlight: true,
            actionMessage: nil,
            pause: { _ in actionCount += 1 },
            resume: { _ in actionCount += 1 }
        )

        section.performControl()

        XCTAssertTrue(section.isControlDisabled)
        XCTAssertEqual(actionCount, 0)
    }

    func testActivitySectionAccessibilityIncludesDisplayedActionFailure() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: activityJob(state: .running),
                locale: Locale(identifier: "en_US")
            )
        )
        let section = SmartInboxActivitySection(
            presentation: presentation,
            isActionInFlight: false,
            actionMessage: "Couldn't pause—try again.",
            pause: { _ in },
            resume: { _ in }
        )
        XCTAssertEqual(
            section.descriptiveAccessibilityLabel,
            "\(presentation.accessibilityLabel), Couldn't pause—try again."
        )
    }

    func testPauseFailureRetainsRunningPresentationAndShowsRetryCopy() {
        let running = activityJob(state: .running)
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { running },
            pause: { _ in throw ActivityTestError.writeFailed },
            resume: { _ in }
        )

        coordinator.pause(running.id, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(coordinator.presentation?.title, "Organizing Smart Inbox")
        XCTAssertEqual(coordinator.actionMessage, "Couldn't pause—try again.")
        XCTAssertFalse(coordinator.isActionInFlight)
    }

    func testResumeFailureRetainsPausedPresentationAndShowsRetryCopy() async {
        let paused = activityJob(state: .paused, pauseReason: "user-requested")
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { paused },
            pause: { _ in },
            resume: { _ in throw ActivityTestError.writeFailed }
        )

        await coordinator.resume(paused.id, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(coordinator.presentation?.title, "Smart Inbox paused")
        XCTAssertEqual(coordinator.actionMessage, "Couldn't resume—try again.")
        XCTAssertFalse(coordinator.isActionInFlight)
    }

    func testResumeDuringLowPowerModeSaysSoInsteadOfFailing() async {
        let paused = activityJob(state: .paused, pauseReason: "user-requested")
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { paused },
            pause: { _ in },
            resume: { _ in throw SmartInboxPowerGateError.lowPowerMode }
        )

        await coordinator.resume(paused.id, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(coordinator.actionMessage, "Paused in Low Power Mode")
    }

    func testCommittedResumeSignalFailureRefreshesQueuedState() async {
        var durableJob = activityJob(state: .paused, pauseReason: "user-requested")
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { durableJob },
            pause: { _ in },
            resume: { _ in
                durableJob = self.activityJob(state: .queued)
                throw SmartInboxActivityActionError(didCommitResume: true)
            }
        )

        await coordinator.resume(durableJob.id, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(coordinator.presentation?.title, "Waiting to organize")
        XCTAssertNotEqual(coordinator.presentation?.title, "Smart Inbox paused")
        XCTAssertEqual(coordinator.actionMessage, "Waiting to resume")
        XCTAssertFalse(coordinator.isActionInFlight)
    }

    func testEveryListPresentationUsesTheActualContextMenuActionOrder() {
        for presentation in [
            MailMessageListColumn.ContentPresentation.flatList,
            .unreadCards,
            .triage,
        ] {
            XCTAssertEqual(
                MailMessageListColumn.rowActionSurface(for: presentation).contextMenuActions,
                [.archive, .readState, .flag, .move, .labels, .separator, .delete],
                "\(presentation)"
            )
        }
    }

    func testActualNativeRowPersistentAccessibilityUsesOnlyMessageModelFields() {
        let row = MessageRowModel(
            id: "m1",
            sender: "sender@example.com",
            subject: "Trip details",
            preview: "Your itinerary",
            category: .personal,
            categoryLabel: "Personal",
            isUnread: true,
            isPinned: false,
            dateLabel: "10:00",
            actions: []
        )
        let nativeRow = MailMessageListRow(
            row: row,
            selected: false,
            mailActions: .preview(),
            labelActions: .preview(),
            performMessageAction: { _, _ in }
        )
        let presentation = nativeRow.persistentAccessibilityPresentation
        let actualModelFields = Set(
            Mirror(reflecting: nativeRow.row).children.compactMap(\.label)
        )

        XCTAssertEqual(
            presentation.label,
            "\(MailSenderIdentity(sender: row.sender, displayName: row.senderDisplayName).displayName), Trip details"
        )
        XCTAssertTrue(presentation.value.contains("Your itinerary"))
        XCTAssertFalse(presentation.label.contains("Travel"))
        XCTAssertFalse(presentation.value.contains("Travel"))
        XCTAssertFalse(actualModelFields.contains("labels"))
        XCTAssertFalse(actualModelFields.contains("mailLabels"))
    }

    private func selectedInboxMode(
        in root: PlainpostRootView
    ) throws -> InboxDisplayMode {
        try XCTUnwrap(InboxDisplayMode(rawValue: mailbox(in: root).selectedInboxMode))
    }

    private func mailboxNavigation(
        in root: PlainpostRootView
    ) throws -> MailboxWorkspaceNavigationState {
        try mailbox(in: root).mailboxNavigation
    }

    private func mailbox(
        in root: PlainpostRootView
    ) throws -> MailboxController {
        let state = try XCTUnwrap(
            Mirror(reflecting: root).children.first {
                $0.label == "_mailbox"
            }?.value as? StateObject<MailboxController>
        )
        return state.wrappedValue
    }

    func testLabelsDestinationRoutesDirectlyToLabelsSettings() {
        XCTAssertEqual(PlainpostDestination.labels.workAreaKind, .settings)
        XCTAssertEqual(PlainpostDestination.labels.settingsSection, .rulesLabels)
        XCTAssertFalse(PlainpostDestination.labels.usesMailboxList)
        XCTAssertFalse(PlainpostDestination.labels.showsThreadReader)
    }

    func testLabelActionSurfaceSessionTracksMailboxDestinationOnly() {
        XCTAssertEqual(
            PlainpostRootView.messageLabelSurfaceDestination(for: .smartInbox),
            PlainpostDestination.smartInbox.rawValue
        )
        XCTAssertEqual(
            PlainpostRootView.messageLabelSurfaceDestination(for: .sent),
            PlainpostDestination.sent.rawValue
        )
        XCTAssertNil(PlainpostRootView.messageLabelSurfaceDestination(for: .settings))
        XCTAssertNil(PlainpostRootView.messageLabelSurfaceDestination(for: .labels))
    }

    func testExistingDestinationBehaviorRemainsUnchanged() {
        XCTAssertEqual(PlainpostDestination.smartInbox.workAreaKind, .mailbox)
        XCTAssertEqual(PlainpostDestination.settings.workAreaKind, .settings)
        XCTAssertNil(PlainpostDestination.smartInbox.settingsSection)
        XCTAssertNil(PlainpostDestination.settings.settingsSection)
    }

    func testSelectingLabelsUtilityTransitionsRootIntoLabelsSettings() {
        let transition = PlainpostRootDestinationTransition.resolve(
            selectedDestination: .labels,
            currentSettingsSection: .accounts,
            isAccountSetupRequired: false
        )

        XCTAssertEqual(transition.destination, .labels)
        XCTAssertEqual(transition.workAreaKind, .settings)
        XCTAssertEqual(transition.settingsSection, .rulesLabels)
        XCTAssertTrue(transition.dismissesSearch)
    }

    func testDeterministicLabelManagerPreviewCoversAccountAndEmptyStates() async {
        let accountModel = MailLabelsViewModel.preview(state: .accountScope)
        await accountModel.load()
        XCTAssertEqual(accountModel.selection, .account(AccountID("a")))
        XCTAssertTrue(accountModel.labels.contains { $0.scope == .allAccounts })
        XCTAssertTrue(accountModel.labels.contains {
            $0.scope == .account(AccountID("a"))
        })

        let emptyModel = MailLabelsViewModel.preview(state: .empty)
        await emptyModel.load()
        XCTAssertTrue(emptyModel.labels.isEmpty)
        XCTAssertNil(emptyModel.selectedLabelID)
        XCTAssertNil(emptyModel.draft)
    }

    func testDeterministicMessageLabelsSubmenuPreviewCoversEveryOwnershipState() {
        let items = MessageLabelsSubmenuDesignPreview.items

        XCTAssertEqual(items.map(\.title), [
            "Added manually",
            "Added by rule",
            "Added by Smart Inbox",
            "Combined ownership",
            "Excluded from Smart Inbox",
        ])
        XCTAssertEqual(items[0].sources, [.user])
        XCTAssertEqual(items[1].sources, [.rule(ruleID: "travel-rule")])
        XCTAssertEqual(items[2].sources, [.smartInbox])
        XCTAssertEqual(
            items[3].sources,
            [.user, .rule(ruleID: "travel-rule"), .smartInbox]
        )
        XCTAssertTrue(items[4].sources.isEmpty)
        XCTAssertTrue(items[4].isExcluded)
    }

    private func activityJob(
        state: PlainpostOperationState,
        pauseReason: String? = nil,
        runMode: PlainpostSmartInboxRunMode = .incremental
    ) -> PlainpostDurableJob {
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "smart-inbox",
            providerID: "foundation",
            smartInboxRunMode: runMode
        )
        let payloadJSON = String(
            decoding: try! JSONEncoder().encode(input),
            as: UTF8.self
        )
        return PlainpostDurableJob(
            id: "activity-\(state.rawValue)",
            kind: .aiOperation,
            payloadJSON: payloadJSON,
            state: state,
            idempotencyKey: "activity-\(state.rawValue)",
            pauseReason: pauseReason,
            progress: PlainpostOperationProgress(
                current: 2_340,
                total: 9_256,
                phase: state.rawValue,
                label: "Smart Inbox"
            )
        )
    }

    /// An open account folder is that account's inbox for notifications only when it is the
    /// Inbox; any other folder hides no inbox's mail.
    func testAnOpenFolderOnlyCoversItsOwnInboxForNotifications() {
        let all: Set<String> = ["home-token", "work-token"]
        let token: (String) -> String = { "\($0)-token" }
        let list = MailboxWorkspaceRoute.list(.mailbox(destination: .allInboxes, mode: .focusedList))
        XCTAssertEqual(PlainpostRootView.visibleAccountInboxTokens(
            destination: .allInboxes, route: list, scopeAccountID: nil, folder: nil,
            allTokens: all, token: token), all)
        XCTAssertEqual(PlainpostRootView.visibleAccountInboxTokens(
            destination: .allInboxes, route: list, scopeAccountID: nil,
            folder: MailFolderRef(accountID: AccountID("work"), path: "INBOX", name: "Inbox", role: .inbox),
            allTokens: all, token: token), ["work-token"])
        XCTAssertEqual(PlainpostRootView.visibleAccountInboxTokens(
            destination: .allInboxes, route: list, scopeAccountID: nil,
            folder: MailFolderRef(accountID: AccountID("work"), path: "Sent", name: "Sent", role: .sent),
            allTokens: all, token: token), [])
    }
}

private enum ActivityTestError: Error {
    case writeFailed
}

private final class RootTranslationHandler: ThreadTranslationHandling, @unchecked Sendable {
    let providerID: String
    let modelID: String
    private let cachedBodies: [String: String]

    init(
        providerID: String,
        modelID: String,
        cachedBodies: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.cachedBodies = cachedBodies
    }

    func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) throws -> MessageTranslationResult? {
        guard let body = cachedBodies[messageID.rawValue] else { return nil }
        return result(
            messageID: messageID,
            targetLanguageID: targetLanguageID,
            body: body
        )
    }

    func translate(
        messageID: MessageID,
        targetLanguageID: String,
        targetLanguageName _: String
    ) async throws -> MessageTranslationResult {
        result(
            messageID: messageID,
            targetLanguageID: targetLanguageID,
            body: cachedBodies[messageID.rawValue] ?? "Translated"
        )
    }

    private func result(
        messageID: MessageID,
        targetLanguageID: String,
        body: String
    ) -> MessageTranslationResult {
        MessageTranslationResult(
            messageID: messageID,
            renderedBody: RenderedEmailBody(
                kind: .plainText,
                safeText: body,
                safeHTML: nil,
                blockedRemoteImageURLs: []
            ),
            sourceFingerprint: MailTranslationFingerprint.source(
                messageID: messageID,
                body: .plainText("Original")
            ),
            providerID: providerID,
            modelID: modelID,
            targetLanguageID: targetLanguageID,
            wasCached: true
        )
    }

}
