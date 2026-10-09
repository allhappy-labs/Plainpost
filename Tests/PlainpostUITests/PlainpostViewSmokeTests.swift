import SwiftUI
import XCTest
import PlainpostAccounts
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostAI
import PlainpostCore
import PlainpostOperations
import PlainpostServiceIPC
@_spi(DesignPreview) @testable import PlainpostUI

#if os(macOS)
import AppKit
#endif

private struct EmptyDiagnosticsAuditLog: AuditLogHandling {
    func rows() throws -> [AuditLogRowModel] { [] }
}

@MainActor
final class PlainpostViewSmokeTests: XCTestCase {
#if os(macOS)
    func testHostedAccountChooserRetainsGmailCleanupRecoveryAccount() {
        let model = AccountSetupViewModel.gmailRecoveryPreview()
        let recoveredID = model.googleSetupRecoveryAccountID
        XCTAssertEqual(model.accounts.first?.id, recoveredID)
        XCTAssertEqual(model.accounts.first?.email.rawValue, "alex@gmail.com")
        XCTAssertNotNil(model.googleSetupRecoveryMessage)
        let hosted = hostRoot(
            AccountSetupWorkspace(viewModel: model),
            size: NSSize(width: 900, height: 700))
        XCTAssertNotNil(hosted.window.contentView)
    }

    private static var retainedHostedWindows: [NSWindow] = []
#endif

    func testMailboxCanvasModifiersConstruct() {
        evaluate(
            Color.clear
                .mailboxCanvas()
        )
        evaluate(
            List {
                Text("Message")
            }
            .mailboxListCanvas()
        )
    }

#if os(macOS)
    func testSidebarListDisablesItsTopScrollEdgeEffect() throws {
        let source = try plainpostNativeViewsSource()
        let listStart = try XCTUnwrap(
            source.range(of: "List(selection: Binding<PlainpostSidebarItem?>(")
        )
        let footerStart = try XCTUnwrap(
            source.range(
                of: "if smartInboxEnabled, let smartInboxActivity",
                range: listStart.upperBound..<source.endIndex
            )
        )
        let sidebarList = source[listStart.lowerBound..<footerStart.lowerBound]

        XCTAssertTrue(
            sidebarList.contains(".scrollEdgeEffectHidden(true, for: .top)"),
            "The sidebar List must suppress only its automatic top scroll-edge treatment."
        )
    }

    func testAccountRowsMarkAccountsThatNeedReauthorizationWhileAnotherPageIsOpen() throws {
        let ada = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"))
        let other = Account(
            id: AccountID("acc_other"), displayName: "Work", email: EmailAddress("work@example.com"),
            imapHost: "imap.example.com", imapPort: 993, smtpHost: "smtp.example.com", smtpPort: 587)
        let model = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            status: .connected(accountID: other.id.rawValue),
            lastConnectedEmail: other.email.rawValue,
            account: other,
            accounts: [ada, other],
            accountAuthenticationProvider: { id in
                id == ada.id
                    ? AccountAuthenticationSummary(method: .googleOAuth, state: .reauthorizationRequired)
                    : AccountAuthenticationSummary(method: .password, state: .ready)
            }
        )

        _ = hostRoot(AccountSettingsPage(accountID: other.id, viewModel: model), size: NSSize(width: 900, height: 700))
        let rows = SettingsAccountRow.rows(accountSetup: model, host: PlainpostSettingsHost())

        XCTAssertEqual(rows.map(\.title), ["ada@gmail.com", "work@example.com"])
        XCTAssertEqual(rows.map(\.needsAttention), [true, false])
        XCTAssertFalse(model.selectedAccountNeedsReauthorization, "the banner covers only the selected account")
    }

    func testTroubleshootingSyncSectionHasOnlyTheSyncButton() throws {
        // The Smart Inbox page (Task 8) now owns "Re-sort All Mail…"; Troubleshooting's
        // Sync section is just the manual sync action and its status.
        let source = try plainpostSettingsSource("Settings/TroubleshootingSettingsPage.swift")
        let groupStart = try XCTUnwrap(source.range(of: "Section(\"Sync\")"))
        let nextSection = try XCTUnwrap(
            source.range(of: "Section(\"Activity\")", range: groupStart.upperBound..<source.endIndex)
        )
        let syncSection = source[groupStart.lowerBound..<nextSection.lowerBound]

        XCTAssertTrue(syncSection.contains("diagnostics.sync-now"))
        XCTAssertFalse(syncSection.contains("diagnostics.rerun-smart-inbox"))
    }
#endif

#if os(macOS)
    func testMailboxToolbarListReaderListReaderTransitionKeepsBothActionGroupsLive() throws {
        let viewModel = InboxViewModel.designPreview()
        let root = PlainpostRootView(
            viewModel: viewModel,
            aiAssistant: .designPreview(),
            initialInboxMode: .simpleList,
            designNow: Date(timeIntervalSince1970: 1)
        )
        let hosted = hostRoot(
            root,
            size: NSSize(width: 1_600, height: 640)
        )
        let targetRow = try XCTUnwrap(viewModel.rows(for: .smartInbox).first)
        let targetRowLabel = MessageListRow.accessibilityLabel(for: targetRow)
        let toolbar = try XCTUnwrap(hosted.window.toolbar)

        try openMessageRow(named: targetRowLabel, in: hosted)
        assertReaderToolbarActionGroups(in: hosted, toolbar: toolbar)

        try returnToMailboxList(in: hosted, toolbar: toolbar)
        try openMessageRow(named: targetRowLabel, in: hosted)
        assertReaderToolbarActionGroups(in: hosted, toolbar: toolbar)
    }

    func testMailboxReaderToolbarUsesNativeTrailingActionItemOrder() throws {
        let root = PlainpostRootView(
            viewModel: .designPreview(),
            aiAssistant: .designPreview(),
            initialSelectedMessageID: "jessica-intro",
            designNow: Date(timeIntervalSince1970: 1)
        )
        let hosted = hostRoot(
            root,
            size: NSSize(width: 1_600, height: 640)
        )
        let toolbar = try XCTUnwrap(hosted.window.toolbar)
        let flexibleSpacerIndex = try XCTUnwrap(
            toolbar.items.lastIndex {
                $0.itemIdentifier == .flexibleSpace
            }
        )
        let toolbarView = try XCTUnwrap(nativeToolbarView(in: hosted.window))
        let trailingActionItems = toolbarActionItems(
            after: flexibleSpacerIndex,
            in: toolbar
        )
        XCTAssertEqual(
            trailingActionItems.count,
            2,
            "Reader state must contain only contextual and global action items after the flexible spacer."
        )
        let trailingActionFrames = Array(
            toolbarPlatterFrames(in: toolbarView)
                .suffix(trailingActionItems.count)
        )
        guard trailingActionFrames.count == 2 else {
            XCTFail("Expected two rendered trailing action groups.")
            return
        }

        XCTAssertLessThan(
            flexibleSpacerIndex,
            toolbar.items.count - 1,
            "A flexible spacer must keep both reader action groups trailing."
        )
        XCTAssertGreaterThan(
            trailingActionFrames[0].midX,
            toolbarView.bounds.midX,
            "The contextual action group must render in the window's trailing half."
        )
        XCTAssertGreaterThan(
            trailingActionFrames[1].minX,
            trailingActionFrames[0].maxX,
            "The global action group must follow the contextual action group."
        )
    }

    func testMailboxListToolbarKeepsGlobalActionsAtNativeTrailingEdge() throws {
        let root = PlainpostRootView(
            viewModel: .designPreview(),
            aiAssistant: .designPreview(),
            designNow: Date(timeIntervalSince1970: 1)
        )
        let hosted = hostRoot(
            root,
            size: NSSize(width: 1_600, height: 640)
        )
        let toolbar = try XCTUnwrap(hosted.window.toolbar)
        let flexibleSpacerIndex = try XCTUnwrap(
            toolbar.items.lastIndex {
                $0.itemIdentifier == .flexibleSpace
            }
        )
        let toolbarView = try XCTUnwrap(nativeToolbarView(in: hosted.window))
        let globalActionFrame = try XCTUnwrap(toolbarPlatterFrames(in: toolbarView).last)

        XCTAssertLessThan(flexibleSpacerIndex, toolbar.items.count - 1)
        XCTAssertGreaterThan(globalActionFrame.midX, toolbarView.bounds.midX)
    }

    func testThreadReaderWorkspaceFillsWideNavigationSplitViewDetailColumn() {
        let viewModel = InboxViewModel.designPreview()
        let windowSize = NSSize(width: 1_800, height: 900)
        let navigationSplitViewFrames = splitViewFrames(
            for: NavigationSplitView {
                Color.clear
                    .frame(minWidth: 190)
            } detail: {
                ThreadReaderWorkspace(
                    thread: viewModel.selectedThread,
                    openComposer: {},
                    selectedMessageID: viewModel.selectedThread.messages.first?.id,
                    mailActions: .preview()
                )
            }
            .navigationSplitViewStyle(.balanced),
            size: windowSize
        )

        XCTAssertGreaterThan(
            navigationSplitViewFrames
                .filter { $0.height >= windowSize.height }
                .map(\.width)
                .max() ?? 0,
            1_500,
            "ThreadReaderWorkspace must not cap the navigation detail column"
        )
    }

    func testThreadReaderWorkspaceWideCardsExpandPastObsolete980PointInnerCap() throws {
        let viewModel = InboxViewModel.designPreview()
        let hosted = hostFixedWidth(
            ThreadReaderWorkspace(
                thread: viewModel.selectedThread,
                openComposer: {},
                selectedMessageID: viewModel.selectedThread.messages.first?.id,
                mailActions: .preview()
            ),
            width: 1_800
        )

        let messagePanel = try XCTUnwrap(
            readerPanel(id: "reader-message-panel", in: hosted),
            "Missing the stable message panel layout probe."
        )
        let messagePanelWidth = hosted.hostingView.convert(
            messagePanel.bounds,
            from: messagePanel
        ).width

        XCTAssertGreaterThan(
            messagePanelWidth,
            1_700,
            "The message card must use the wide reader canvas; restoring the obsolete readerContentMaximumWidth cap must fail this test."
        )
    }

    func testThreadReaderWorkspaceAndTranslationPillEvaluate() {
        let viewModel = InboxViewModel.designPreview()
        evaluate(
            ThreadReaderWorkspace(
                thread: viewModel.selectedThread,
                openComposer: {},
                selectedMessageID: viewModel.selectedThread.messages.first?.id
            )
        )
        evaluate(ConversationTranslationPill(sourceLanguageName: nil, progressText: "1 of 3", showOriginal: {}))
    }
#endif

    func testConversationExpansionPolicyExpandsEveryMessageWhenThreadOpens() {
        XCTAssertTrue(
            ConversationExpansionPolicy.startsExpanded(
                isSelected: true,
                isOnlyMessage: false
            )
        )
        XCTAssertTrue(
            ConversationExpansionPolicy.startsExpanded(
                isSelected: false,
                isOnlyMessage: false
            )
        )
        XCTAssertTrue(
            ConversationExpansionPolicy.startsExpanded(
                isSelected: false,
                isOnlyMessage: true
            )
        )
    }

    func testSmartInboxActivitySectionConstructsDeterminateAndIndeterminateStates() throws {
        let running = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: rerunJob(
                    state: .running,
                    progress: PlainpostOperationProgress(
                        current: 20,
                        total: 100,
                        phase: "classifying"
                    )
                )
            )
        )
        let preparing = try XCTUnwrap(
            SmartInboxActivityPresentation(job: rerunJob(state: .queued))
        )

        evaluate(
            SmartInboxActivitySection(
                presentation: running,
                isActionInFlight: false,
                actionMessage: nil,
                pause: { _ in },
                resume: { _ in }
            )
        )
        evaluate(
            SmartInboxActivitySection(
                presentation: preparing,
                isActionInFlight: false,
                actionMessage: nil,
                pause: { _ in },
                resume: { _ in }
            )
        )
    }

    func testDesignPreviewRootUsesExplicitSmartInboxActivityPresentation() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: rerunJob(
                    state: .running,
                    progress: PlainpostOperationProgress(
                        current: 2_340,
                        total: 9_256,
                        phase: "classifying",
                        label: "Smart Inbox"
                    )
                ),
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let root = PlainpostRootView(
            viewModel: .designPreview(),
            aiAssistant: .designPreview(),
            initialSmartInboxBundle: nil,
            designNow: Date(timeIntervalSince1970: 1_753_178_400),
            smartInboxActivityPresentation: presentation
        )

        XCTAssertEqual(root.smartInboxActivityCoordinator.presentation, presentation)
        evaluate(root)
        evaluate(
            PlainpostSidebar(
                selection: .constant(.smartInbox),
                viewModel: .designPreview(),
                designSmartInboxActivity: presentation
            )
        )
    }

    func testSmartInboxClassificationResultPresentsUpdatedUnchangedAndFailedSeparately() {
        XCTAssertEqual(
            SmartInboxClassificationResultPresentation.status(
                providerDisplayName: "Local Model",
                updated: 2,
                unchanged: 3,
                failed: 4
            ),
            "Categorized with Local Model: 2 updated, 3 unchanged, 4 failed."
        )
        XCTAssertEqual(
            SmartInboxClassificationResultPresentation.status(
                providerDisplayName: "Local Model",
                updated: 0,
                unchanged: 5,
                failed: 0
            ),
            "Categorized with Local Model: 0 updated, 5 unchanged, 0 failed."
        )
        XCTAssertEqual(
            SmartInboxClassificationResultPresentation.status(
                providerDisplayName: "Local Model",
                updated: 0,
                unchanged: 0,
                failed: 0
            ),
            "Up to date"
        )
    }

    func testInboxPaginationFooterShowsOnlyWhileMoreRowsExist() {
        XCTAssertTrue(
            InboxPaginationFooterPresentation.make(
                hasMoreRows: true,
                isLoadingMore: false
            ).isVisible
        )
        XCTAssertFalse(
            InboxPaginationFooterPresentation.make(
                hasMoreRows: false,
                isLoadingMore: false
            ).isVisible
        )
        XCTAssertEqual(
            InboxPaginationFooterPresentation.make(
                hasMoreRows: true,
                isLoadingMore: true
            ).label,
            "Loading more messages"
        )
    }

    func testDisabledMailboxPresentationNamesFolderAndEnableAction() {
        let presentation = DisabledMailboxSyncPresentation.make(
            destination: .sent,
            isDisabled: true,
            isEnabling: false
        )

        XCTAssertEqual(presentation?.title, "Sent sync is turned off")
        XCTAssertEqual(presentation?.detail, "Enable sync to download messages from Sent.")
        XCTAssertEqual(presentation?.actionTitle, "Enable Sent sync")
        XCTAssertNil(
            DisabledMailboxSyncPresentation.make(
                destination: .sent,
                isDisabled: false,
                isEnabling: false
            )
        )
        XCTAssertNil(
            DisabledMailboxSyncPresentation.make(
                destination: .archive,
                isDisabled: false,
                isEnabling: false
            )
        )
    }

    func testDisabledMailboxSuppressesPaginationAndMapsSyncPath() {
        XCTAssertFalse(
            InboxPaginationFooterPresentation.make(
                hasMoreRows: true,
                isLoadingMore: false,
                isMailboxSyncDisabled: true
            ).isVisible
        )
        XCTAssertEqual(PlainpostDestination.sent.syncMailboxPath, "Sent")
        XCTAssertEqual(PlainpostDestination.archive.syncMailboxPath, "Archive")
        XCTAssertNil(PlainpostDestination.smartInbox.syncMailboxPath)
    }

    private func rerunJob(
        state: PlainpostOperationState,
        progress: PlainpostOperationProgress? = nil
    ) -> PlainpostDurableJob {
        PlainpostDurableJob(
            id: "job_rerun_\(state.rawValue)",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: state,
            idempotencyKey: "rerun-\(state.rawValue)",
            progress: progress
        )
    }

    func testMailSearchAccessibilityLabelsInterpolatePresentedValues() {
        let account = MailSearchAccount(
            id: AccountID("account_work"),
            displayName: "Work",
            email: "me@work.example"
        )

        XCTAssertEqual(
            MailSearchPresentation.accountAccessibilityLabel(account),
            "Search Work, me@work.example"
        )
        XCTAssertEqual(
            MailSearchPresentation.tipAccessibilityLabel(MailSearchTip.reference[0]),
            "Insert from:alice"
        )
    }

    func testMailSearchResultAccountsUseConfiguredDisplayNameWithRawIDFallback() {
        let workID = AccountID("account_work")
        let unknownID = AccountID("account_unknown")
        let names = [workID: "Work"]

        XCTAssertEqual(
            MailSearchPresentation.resultAccountDisplayName(workID, accountDisplayNames: names),
            "Work"
        )
        XCTAssertEqual(
            MailSearchPresentation.resultAccountAccessibilityLabel(
                workID,
                accountDisplayNames: names
            ),
            "account Work"
        )
        XCTAssertEqual(
            MailSearchPresentation.resultAccountDisplayName(
                unknownID,
                accountDisplayNames: names
            ),
            unknownID.rawValue
        )
    }

    func testMailSearchTipsPartitionIntoContiguousBalancedColumns() {
        let insertions = MailSearchTip.reference.map(\.insertion)
        let wide = MailSearchPresentation.tipColumns(MailSearchTip.reference, count: 4)
        let compact = MailSearchPresentation.tipColumns(MailSearchTip.reference, count: 2)

        XCTAssertEqual(wide.map(\.count), [5, 4, 4, 4])
        XCTAssertEqual(compact.map(\.count), [9, 8])
        XCTAssertEqual(wide.flatMap { $0 }.map(\.insertion), insertions)
        XCTAssertEqual(compact.flatMap { $0 }.map(\.insertion), insertions)
    }

    func testMailSearchInsertionAddsSpacingAfterEmojiAndComposedUnicode() {
        let emoji = "😀"
        let emojiResult = MailSearchTextInsertion.apply(
            "from: alex",
            to: emoji,
            selectedRange: NSRange(location: emoji.utf16.count, length: 0)
        )
        XCTAssertEqual(emojiResult.text, "😀 from: alex ")
        XCTAssertEqual(emojiResult.selectedRange.location, emojiResult.text.utf16.count)

        let composed = "e\u{301}"
        let composedResult = MailSearchTextInsertion.apply(
            "from: alex",
            to: composed,
            selectedRange: NSRange(location: composed.utf16.count, length: 0)
        )
        XCTAssertEqual(composedResult.text, "e\u{301} from: alex ")
        XCTAssertEqual(composedResult.selectedRange.location, composedResult.text.utf16.count)
    }

    func testMailSearchInsertionHandlesStartAndEndPositions() {
        let atStart = MailSearchTextInsertion.apply(
            "from: alex",
            to: "hello",
            selectedRange: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(atStart.text, "from: alex hello")
        XCTAssertEqual(atStart.selectedRange, NSRange(location: 11, length: 0))

        let atEnd = MailSearchTextInsertion.apply(
            "from: alex",
            to: "hello",
            selectedRange: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(atEnd.text, "hello from: alex ")
        XCTAssertEqual(atEnd.selectedRange.location, atEnd.text.utf16.count)
    }

    func testMailSearchInsertionReplacesTheSelectedRange() {
        let result = MailSearchTextInsertion.apply(
            "from: alex",
            to: "hello world",
            selectedRange: NSRange(location: 6, length: 5)
        )

        XCTAssertEqual(result.text, "hello from: alex ")
        XCTAssertEqual(result.selectedRange.location, result.text.utf16.count)
        XCTAssertEqual(result.selectedRange.length, 0)
    }

    func testMailSearchSuggestionReplacementUsesValidatedUTF16SourceRange() {
        let source = "😀 from:al project"
        let replacement = MailSearchTextRange(
            location: ("😀 from:" as NSString).length,
            length: ("al" as NSString).length
        )

        let result = MailSearchTextInsertion.apply(
            "alex@example.com",
            to: source,
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: replacement
        )

        XCTAssertEqual(result.text, "😀 from:alex@example.com project")
        XCTAssertEqual(
            result.selectedRange,
            NSRange(location: ("😀 from:alex@example.com " as NSString).length, length: 0)
        )
    }

    func testMailSearchSuggestionApplicationPreservesQuotedAndGroupedDelimiters() throws {
        let cases: [(query: String, selected: String, insertion: String, expected: String)] = [
            (
                query: #"from:"al" project"#,
                selected: "al",
                insertion: "alice@example.com",
                expected: #"from:"alice@example.com" project"#
            ),
            (
                query: "from:(alice OR bo)",
                selected: "bo",
                insertion: "bob@example.com",
                expected: "from:(alice OR bob@example.com)"
            ),
        ]

        for value in cases {
            let selectedRange = (value.query as NSString).range(of: value.selected)
            let context = try XCTUnwrap(
                MailSearchQueryParser.suggestionContext(
                    in: value.query,
                    selection: .init(
                        location: selectedRange.location + selectedRange.length,
                        length: 0
                    )
                ),
                value.query
            )
            let result = MailSearchTextInsertion.apply(
                value.insertion,
                to: value.query,
                selectedRange: NSRange(location: 0, length: 0),
                replacementRange: context.replacementRange
            )

            XCTAssertEqual(result.text, value.expected, value.query)
            XCTAssertEqual(
                result.selectedRange,
                NSRange(
                    location: context.replacementRange.location + value.insertion.utf16.count,
                    length: 0
                ),
                value.query
            )
        }
    }

    func testMailSearchTokenRemovalCollapsesAdjacentWhitespace() {
        let result = MailSearchTextInsertion.apply(
            "",
            to: "project from:alex next",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: .init(location: 8, length: 9)
        )

        XCTAssertEqual(result.text, "project next")
        XCTAssertEqual(result.selectedRange, NSRange(location: 8, length: 0))
    }

    func testMailSearchTokenRemovalNormalizesAllOuterSeparatorsOnly() {
        let cases: [(String, String, String)] = [
            ("   from:alex   project", "from:alex", "project"),
            ("project   from:alex   ", "from:alex", "project"),
            ("project   from:alex \t  next", "from:alex", "project next"),
            (#"subject:"Quarterly  Review"   from:alex"#, "from:alex", #"subject:"Quarterly  Review""#),
        ]

        for (source, token, expected) in cases {
            let tokenRange = (source as NSString).range(of: token)
            let result = MailSearchTextInsertion.apply(
                "",
                to: source,
                selectedRange: NSRange(location: 0, length: 0),
                replacementRange: .init(location: tokenRange.location, length: tokenRange.length)
            )

            XCTAssertEqual(result.text, expected, source)
        }
    }

    func testMailSearchScopeAccessibilityIncludesConfiguredAccountAndMailboxNames() {
        let account = MailSearchAccount(
            id: AccountID("work"),
            displayName: "Work",
            email: "me@work.example"
        )
        let mailbox = MailSearchMailbox(
            id: MailboxID("projects"),
            accountID: account.id,
            displayName: "Project Archive"
        )

        XCTAssertEqual(
            MailSearchPresentation.scopeAccessibilityValue(
                .init(accountIDs: [account.id], mailboxIDs: [mailbox.id]),
                accounts: [account],
                mailboxes: [mailbox]
            ),
            "Accounts Work; mailboxes Work — Project Archive"
        )
        XCTAssertEqual(
            MailSearchPresentation.scopeAccessibilityValue(
                .init(mailboxIDs: [mailbox.id]),
                accounts: [account],
                mailboxes: [mailbox]
            ),
            "Mailboxes Work — Project Archive"
        )
        XCTAssertEqual(
            MailSearchPresentation.scopeAccessibilityValue(
                .init(),
                accounts: [account],
                mailboxes: [mailbox]
            ),
            "All accounts and mailboxes"
        )
        XCTAssertEqual(
            MailSearchPresentation.mailboxAccessibilityLabel(
                mailbox,
                accounts: [account]
            ),
            "Search mailbox Project Archive, Work account"
        )
    }

    func testMailSearchEffectiveScopeHidesAccountOnlyWhenExactlyOneAccountIsProven() {
        let work = AccountID("work")
        let personal = AccountID("personal")
        let workInbox = MailSearchMailbox(
            id: MailboxID("work-inbox"),
            accountID: work,
            displayName: "Inbox"
        )
        let workArchive = MailSearchMailbox(
            id: MailboxID("work-archive"),
            accountID: work,
            displayName: "Archive"
        )
        let personalInbox = MailSearchMailbox(
            id: MailboxID("personal-inbox"),
            accountID: personal,
            displayName: "Inbox"
        )
        let mailboxes = [workInbox, workArchive, personalInbox]
        let cases: [(String, MailSearchSelectionScope, Bool)] = [
            ("all accounts", .init(), false),
            ("one account", .init(accountIDs: [work]), true),
            ("multiple accounts", .init(accountIDs: [work, personal]), false),
            ("one mailbox", .init(mailboxIDs: [workInbox.id]), true),
            ("same-account mailboxes", .init(mailboxIDs: [workInbox.id, workArchive.id]), true),
            ("cross-account mailboxes", .init(mailboxIDs: [workInbox.id, personalInbox.id]), false),
            ("mixed same account", .init(accountIDs: [work], mailboxIDs: [workInbox.id]), true),
            ("mixed cross account", .init(accountIDs: [work], mailboxIDs: [personalInbox.id]), false),
            ("unknown mailbox owner", .init(mailboxIDs: [MailboxID("missing")]), false),
        ]

        for (name, scope, expected) in cases {
            XCTAssertEqual(
                MailSearchEffectiveScope.isExactlyOneAccount(scope, mailboxes: mailboxes),
                expected,
                name
            )
        }
    }

    func testMailSearchDuplicateMailboxNamesAreQualifiedAcrossAccounts() {
        let work = MailSearchAccount(
            id: AccountID("work"),
            displayName: "Work",
            email: "me@work.example"
        )
        let personal = MailSearchAccount(
            id: AccountID("personal"),
            displayName: "Personal",
            email: "me@personal.example"
        )
        let workInbox = MailSearchMailbox(
            id: MailboxID("work-inbox"),
            accountID: work.id,
            displayName: "Inbox"
        )
        let personalInbox = MailSearchMailbox(
            id: MailboxID("personal-inbox"),
            accountID: personal.id,
            displayName: "Inbox"
        )
        let accounts = [work, personal]
        let mailboxes = [workInbox, personalInbox]

        XCTAssertEqual(
            MailSearchPresentation.mailboxDisplayLabel(workInbox, accounts: accounts),
            "Work — Inbox"
        )
        XCTAssertEqual(
            MailSearchPresentation.mailboxDisplayLabel(personalInbox, accounts: accounts),
            "Personal — Inbox"
        )
        XCTAssertEqual(
            MailSearchPresentation.scopeAccessibilityValue(
                .init(mailboxIDs: [workInbox.id, personalInbox.id]),
                accounts: accounts,
                mailboxes: mailboxes
            ),
            "Mailboxes Personal — Inbox, Work — Inbox"
        )
        XCTAssertEqual(
            MailSearchPresentation.scopeAccessibilityValue(
                .init(accountIDs: [work.id], mailboxIDs: [personalInbox.id]),
                accounts: accounts,
                mailboxes: mailboxes
            ),
            "Accounts Work; mailboxes Personal — Inbox"
        )
    }

    func testMailSearchScopeSelectionSelectsAndDeselectsMultipleMailboxes() {
        let inbox = MailboxID("inbox")
        let archive = MailboxID("archive")
        var scope = MailSearchSelectionScope()

        scope = MailSearchScopeSelection.togglingMailbox(inbox, in: scope)
        scope = MailSearchScopeSelection.togglingMailbox(archive, in: scope)
        XCTAssertEqual(scope.mailboxIDs, [archive, inbox])
        XCTAssertFalse(MailSearchScopeSelection.isAll(scope))

        scope = MailSearchScopeSelection.togglingMailbox(inbox, in: scope)
        XCTAssertEqual(scope.mailboxIDs, [archive])
    }

    func testMailSearchScopeSelectionPreservesMixedAccountAndMailboxSelections() {
        let account = AccountID("work")
        let mailbox = MailboxID("projects")
        var scope = MailSearchSelectionScope(mailboxIDs: [mailbox])

        scope = MailSearchScopeSelection.togglingAccount(account, in: scope)
        XCTAssertEqual(scope.accountIDs, [account])
        XCTAssertEqual(scope.mailboxIDs, [mailbox])

        scope = MailSearchScopeSelection.togglingAccount(account, in: scope)
        XCTAssertTrue(scope.accountIDs.isEmpty)
        XCTAssertEqual(scope.mailboxIDs, [mailbox])
        XCTAssertFalse(MailSearchScopeSelection.isAll(scope))
    }

    func testMailSearchScopeSelectionAllResetClearsAccountsAndMailboxes() {
        let scope = MailSearchSelectionScope(
            accountIDs: [AccountID("work")],
            mailboxIDs: [MailboxID("projects")]
        )

        let reset = MailSearchScopeSelection.reset(scope)

        XCTAssertTrue(reset.accountIDs.isEmpty)
        XCTAssertTrue(reset.mailboxIDs.isEmpty)
        XCTAssertTrue(MailSearchScopeSelection.isAll(reset))
    }

    func testMailSearchPresentationSplitsValidatedUTF16HighlightsIntoPlainRuns() throws {
        let text = "👩‍💻 <script>alert(1)</script> Project"
        let projectRange = (text as NSString).range(of: "Project")
        let snippet = try MailSearchSnippet(
            text: text,
            highlights: [.init(location: projectRange.location, length: projectRange.length)]
        )

        XCTAssertEqual(MailSearchPresentation.highlightedRuns(for: snippet), [
            MailSearchTextRun(text: "👩‍💻 <script>alert(1)</script> ", isHighlighted: false),
            MailSearchTextRun(text: "Project", isHighlighted: true),
        ])
    }

    func testConversationAccessibilitySummaryIncludesEveryVisibleRowField() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let latestActivity = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024,
            month: 7,
            day: 3
        )))
        let hit = MailSearchHit.conversation(.init(
            stableID: "thread:fixture",
            threadID: ThreadID("fixture"),
            accountID: AccountID("account"),
            bestMatchingMessageID: MessageID("best"),
            subject: "Project",
            participants: ["Alex", "Max"],
            latestActivity: latestActivity,
            snippet: try MailSearchSnippet(text: "Project timeline is attached.", highlights: []),
            matchingMessageCount: 2,
            totalMessageCount: 3,
            unreadMessageCount: 1,
            hasAttachments: true,
            hasDocuments: false
        ))

        let accessibility = MailSearchPresentation.resultAccessibility(
            for: hit,
            showsAccount: true,
            accountDisplayNames: [AccountID("account"): "Personal"],
            mailboxDisplayNames: [:],
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(accessibility.label, "Project")
        XCTAssertEqual(
            accessibility.value,
            "Alex and Max, latest activity Jul 3, 2024, 2 matching messages, 3 total messages, 1 unread, has attachments, account Personal, snippet Project timeline is attached."
        )
    }

    func testMessageAccessibilitySummaryIncludesEveryVisibleRowField() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let sentAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024,
            month: 7,
            day: 3
        )))
        let hit = MailSearchHit.message(.init(
            stableID: "message:fixture",
            messageID: MessageID("fixture"),
            threadID: ThreadID("thread"),
            accountID: AccountID("account"),
            sender: EmailAddress("alex@example.com"),
            senderDisplayName: "Alex",
            recipients: [EmailAddress("max@example.com"), EmailAddress("me@example.com")],
            subject: "Project",
            sentAt: sentAt,
            snippet: try MailSearchSnippet(text: "Project timeline is attached.", highlights: []),
            isUnread: true,
            isFlagged: true,
            isDelegated: false,
            mailboxIDs: [MailboxID("inbox"), MailboxID("projects")],
            hasAttachments: true,
            hasDocuments: true
        ))

        let accessibility = MailSearchPresentation.resultAccessibility(
            for: hit,
            showsAccount: true,
            accountDisplayNames: [AccountID("account"): "Personal"],
            mailboxDisplayNames: [
                MailboxID("inbox"): "Inbox",
                MailboxID("projects"): "Project Archive",
            ],
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(accessibility.label, "Project")
        XCTAssertEqual(
            accessibility.value,
            "Alex, to max@example.com and me@example.com, sent Jul 3, 2024, mailboxes Inbox and Project Archive, unread, flagged, has attachments, has documents, account Personal, snippet Project timeline is attached."
        )
    }

    func testMailSearchSuggestionSectionsUseCanonicalCategoryOrder() {
        let item = MailSearchSuggestionItem(
            id: "fixture",
            title: "Fixture",
            detail: "Fixture",
            insertion: "fixture",
            replacementRange: nil
        )
        let unordered = [
            MailSearchSuggestionSection(kind: .filters, items: [item]),
            MailSearchSuggestionSection(kind: .recent, items: [item]),
            MailSearchSuggestionSection(kind: .fields, items: [item]),
            MailSearchSuggestionSection(kind: .people, items: [item]),
        ]

        XCTAssertEqual(
            MailSearchPresentation.orderedSuggestionSections(unordered).map(\.kind),
            [.recent, .people, .fields, .filters]
        )
    }

    func testReturnAppliesOnlyAnExplicitlySelectedSearchSuggestion() {
        let contact = MailSearchSuggestionItem(
            id: "contact", title: "Post CH Ltd", detail: "notifications@post.ch",
            insertion: "participants:notifications@post.ch", replacementRange: nil
        )
        let sections = [MailSearchSuggestionSection(kind: .people, items: [contact])]

        XCTAssertNil(MailSearchPresentation.suggestionForReturn(
            sections: sections, selectedID: nil, isVisible: true
        ))
        XCTAssertEqual(MailSearchPresentation.suggestionForReturn(
            sections: sections, selectedID: "contact", isVisible: true
        ), contact)
        XCTAssertNil(MailSearchPresentation.suggestionForReturn(
            sections: sections, selectedID: "contact", isVisible: false
        ))

        let hit = MailSearchViewModel.designResults().rows.first
        XCTAssertEqual(MailSearchPresentation.actionForReturn(
            sections: sections, selectedID: nil, isVisible: true,
            hit: hit, origin: .queryField
        ), .submitSearch)
        XCTAssertEqual(MailSearchPresentation.actionForReturn(
            sections: sections, selectedID: "contact", isVisible: true,
            hit: hit, origin: .queryField
        ), .applySuggestion(contact))
    }

    func testMailSearchEditableFilterTokensPreserveCanonicalSourceRanges() {
        let query = "😀 from:\"Alex Rivera\" is:unread project"

        XCTAssertEqual(MailSearchPresentation.editableTokens(in: query), [
            MailSearchEditableToken(
                text: "from:\"Alex Rivera\"",
                sourceRange: .init(location: 3, length: 18)
            ),
            MailSearchEditableToken(
                text: "is:unread",
                sourceRange: .init(location: 22, length: 9)
            ),
        ])
    }

    func testMailSearchEditableFilterTokensIncludeCompleteGroupedFieldExpression() {
        let query = "from:(alice OR bob) has:attachment"

        XCTAssertEqual(MailSearchPresentation.editableTokens(in: query), [
            MailSearchEditableToken(
                text: "from:(alice OR bob)",
                sourceRange: .init(location: 0, length: 19)
            ),
            MailSearchEditableToken(
                text: "has:attachment",
                sourceRange: .init(location: 20, length: 14)
            ),
        ])
    }

    func testMailSearchAskMailAndRetainedLoadingPlacementIsStateSpecific() {
        XCTAssertTrue(MailSearchPresentation.showsAskMail(in: .initial))
        XCTAssertTrue(MailSearchPresentation.showsAskMail(in: .empty))
        XCTAssertFalse(MailSearchPresentation.showsAskMail(in: .suggesting))
        XCTAssertFalse(MailSearchPresentation.showsAskMail(in: .results(hasMore: false)))
        XCTAssertFalse(MailSearchPresentation.showsAskMail(in: .searching(retainingResults: true)))

        XCTAssertTrue(
            MailSearchPresentation.showsRetainedLoading(
                in: .searching(retainingResults: true)
            )
        )
        XCTAssertFalse(
            MailSearchPresentation.showsRetainedLoading(
                in: .searching(retainingResults: false)
            )
        )
    }

    func testMailSearchExamplesComeFromCanonicalFieldRegistry() {
        XCTAssertEqual(
            MailSearchPresentation.examples.map(\.insertion),
            MailSearchFieldRegistry.all.compactMap { $0.examples.first }
        )
    }

    func testMailSearchSuggestionNavigatorWrapsArrowAndTabMovement() {
        let ids = ["recent", "person", "field"]

        XCTAssertEqual(MailSearchSuggestionNavigator.move(from: nil, command: .down, ids: ids), "recent")
        XCTAssertEqual(MailSearchSuggestionNavigator.move(from: "field", command: .cycleForward, ids: ids), "recent")
        XCTAssertEqual(MailSearchSuggestionNavigator.move(from: nil, command: .up, ids: ids), "field")
        XCTAssertEqual(MailSearchSuggestionNavigator.move(from: "recent", command: .cycleBackward, ids: ids), "field")
    }

    #if os(macOS)
    func testMailSearchTextFieldReportsComposedUTF16SelectionChanges() {
        let query = "😀 from:e\u{301}"
        var reported: MailSearchTextRange?
        let textField = MailSearchTextField(
            text: .constant(query),
            focusGeneration: 0,
            insertionRequest: nil,
            onSubmit: {},
            onSelectionChange: { reported = $0 }
        )
        let coordinator = textField.makeCoordinator()
        let decomposedRange = (query as NSString).range(of: "e\u{301}")

        coordinator.reportSelection(
            NSRange(location: decomposedRange.location + 1, length: 0),
            in: query
        )

        XCTAssertEqual(
            reported,
            .init(location: decomposedRange.location, length: decomposedRange.length)
        )
    }

    func testMailSearchTextFieldCoordinatorRoutesSuggestionKeyboardCommandsWithoutMutatingText() {
        var query = "project"
        var commands: [MailSearchKeyboardCommand] = []
        var submitCount = 0
        let textField = MailSearchTextField(
            text: Binding(get: { query }, set: { query = $0 }),
            focusGeneration: 0,
            insertionRequest: nil,
            onSubmit: { submitCount += 1 },
            onCommand: {
                commands.append($0)
                return true
            }
        )
        let coordinator = textField.makeCoordinator()
        let editor = NSTextView()
        editor.string = query

        XCTAssertTrue(
            coordinator.control(
                NSTextField(),
                textView: editor,
                doCommandBy: #selector(NSResponder.moveDown(_:))
            )
        )
        XCTAssertTrue(
            coordinator.control(
                NSTextField(),
                textView: editor,
                doCommandBy: #selector(NSResponder.moveUp(_:))
            )
        )
        XCTAssertTrue(
            coordinator.control(
                NSTextField(),
                textView: editor,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )
        )
        XCTAssertTrue(
            coordinator.control(
                NSTextField(),
                textView: editor,
                doCommandBy: #selector(NSResponder.insertBacktab(_:))
            )
        )
        XCTAssertTrue(
            coordinator.control(
                NSTextField(),
                textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            )
        )
        coordinator.submit()

        XCTAssertEqual(commands, [.down, .up, .cycleForward, .cycleBackward, .dismiss])
        XCTAssertEqual(query, "project")
        XCTAssertEqual(editor.string, "project")
        XCTAssertEqual(submitCount, 1)

        coordinator.parent = MailSearchTextField(
            text: Binding(get: { query }, set: { query = $0 }),
            focusGeneration: 0,
            insertionRequest: nil,
            onSubmit: {},
            onCommand: { _ in false }
        )
        XCTAssertFalse(
            coordinator.control(
                NSTextField(),
                textView: editor,
                doCommandBy: #selector(NSResponder.moveDown(_:))
            )
        )
    }
    #endif

    func testMailSearchResultCountReportsOnlyLoadedRows() {
        XCTAssertEqual(
            MailSearchResultCountPresentation.loaded(100),
            MailSearchResultCountPresentation(
                label: "100 loaded results",
                showsLoadingFooter: false
            )
        )
    }

    func testMailSearchTipsMatchSupportedReferenceOperators() {
        XCTAssertEqual(
            MailSearchTip.reference.map(\.insertion),
            MailSearchFieldRegistry.all.compactMap { $0.examples.first }
        )
    }

    func testMailSearchReferenceDateTipParsesAcrossProductionLocales() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 19)
        )!
        let expectedDate = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 2)
        )!
        let referenceTip = try XCTUnwrap(
            MailSearchTip.reference.first { $0.insertion == "after:2026-07-01" }
        )

        let expression = try MailSearchQueryParser(calendar: calendar).parse(
            referenceTip.insertion,
            now: now
        ).expression

        XCTAssertEqual(expression, .date(.init(lowerBound: expectedDate, upperBound: nil)))
    }

    @MainActor
    func testMailSearchWorkspaceConstructsAllStates() {
        XCTAssertEqual(MailSearchViewModel.designPreviews.map(\.state), [
            .initial,
            .suggesting,
            .results(hasMore: false),
            .results(hasMore: false),
            .searching(retainingResults: true),
            .empty,
            .invalid("Check the search query and try again."),
            .rebuilding,
            .unavailable,
        ])
        for preview in MailSearchViewModel.designPreviews {
            evaluate(MailSearchWorkspace(
                viewModel: preview,
                close: {},
                openResult: { _ in },
                askMail: {},
                rebuildIndex: {}
            ))
        }
    }

    func testSenderIdentityUsesLocalBrandingAndStableFallback() {
        let homegate = MailSenderIdentity(sender: "noreply@notifications.homegate.ch")
        XCTAssertEqual(homegate.displayName, "Homegate")
        XCTAssertEqual(homegate.brand, .homegate)
        XCTAssertEqual(homegate.brand.symbol, "house.fill")

        let first = MailSenderIdentity(sender: "updates@unknown-service.example")
        let second = MailSenderIdentity(sender: "updates@unknown-service.example")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.displayName, "Updates")
        XCTAssertGreaterThanOrEqual(first.paletteIndex, 0)
    }

    func testSenderIdentityPrefersPersistedDisplayName() {
        let identity = MailSenderIdentity(sender: "noreply@notifications.homegate.ch", displayName: "Homegate Notifications")

        XCTAssertEqual(identity.displayName, "Homegate Notifications")
    }

    func testRootViewHasBodyForSetupAndEveryVisibleDestination() {
        let destinations = PlainpostDestination.mailboxDestinations + PlainpostDestination.utilityDestinations

        evaluate(
            PlainpostRootView(
                viewModel: inbox(requiresAccountSetup: true),
                accountSetup: accountSetup(status: .idle),
                initialDestination: .settings,
                initialSettingsSection: .accounts
            )
        )

        for destination in destinations {
            evaluate(
                PlainpostRootView(
                    viewModel: inbox(requiresAccountSetup: false),
                    accountSetup: accountSetup(status: .connected(accountID: "acc_preview")),
                    approvalQueue: .preview(),
                    composer: .preview(),
                    auditLog: .preview(),
                    commandCenter: .preview(),
                    aiAssistant: .preview(),
                    aiProviderSettings: .preview(),
                    inboxMailActions: .preview(),
                    initialDestination: destination,
                    initialInboxMode: destination == .smartInbox ? InboxDisplayMode.focusedList.rawValue : InboxDisplayMode.simpleList.rawValue
                )
            )
        }

        XCTAssertEqual(destinations.count, 10)
    }

    func testMessageToolbarSelectionRequiresOpenMessageInCurrentMailbox() throws {
        let viewModel = InboxViewModel.designPreview()
        let openMessageID = try XCTUnwrap(viewModel.rows(for: .smartInbox).first?.id)

        XCTAssertNil(
            PlainpostRootView.actionableMessageID(
                in: viewModel,
                selectedDestination: .smartInbox,
                selectedMessageID: nil
            )
        )
        XCTAssertEqual(
            PlainpostRootView.actionableMessageID(
                in: viewModel,
                selectedDestination: .smartInbox,
                selectedMessageID: openMessageID
            ),
            openMessageID
        )
        XCTAssertNil(
            PlainpostRootView.actionableMessageID(
                in: viewModel,
                selectedDestination: .smartInbox,
                selectedMessageID: "missing-message"
            )
        )
        XCTAssertNil(
            PlainpostRootView.actionableMessageID(
                in: viewModel,
                selectedDestination: .approvalQueue,
                selectedMessageID: openMessageID
            )
        )
    }

    func testRootViewConstructsDedicatedMailSearchWorkspace() {
        evaluate(
            PlainpostRootView(
                viewModel: inbox(requiresAccountSetup: false),
                accountSetup: accountSetup(status: .connected(accountID: "acc_preview")),
                mailSearch: .designTips(),
                showsSearch: true
            )
        )
    }

#if os(macOS)
    func testAccountSetupRootKeepsSplitViewWithinWindowHeight() {
        let windowSize = NSSize(width: 1_440, height: 900)
        let rootView = PlainpostRootView(
            viewModel: inbox(requiresAccountSetup: true),
            accountSetup: accountSetup(status: .idle),
            initialDestination: .settings,
            initialSettingsSection: .accounts
        )
        let rootSplitFrames = splitViewFrames(for: rootView, size: windowSize)

        XCTAssertFalse(rootSplitFrames.isEmpty)
        guard let outerHeight = rootSplitFrames.first?.height else { return }
        XCTAssertTrue(
            rootSplitFrames.dropFirst().allSatisfy { $0.height <= outerHeight + 1 },
            "Navigation split view escaped its outer container: \(rootSplitFrames)"
        )
    }

    func testHostedRootKeepsActivityPersistentAcrossSmartInboxAndSettings() throws {
        let job = rerunJob(
            state: .running,
            progress: PlainpostOperationProgress(
                current: 123_456,
                total: 777_777,
                phase: "classifying",
                label: "Smart Inbox"
            )
        )
        for destination in [PlainpostDestination.smartInbox, .settings] {
            let hosted = hostRoot(
                PlainpostRootView(
                    viewModel: inbox(requiresAccountSetup: false),
                    accountSetup: accountSetup(status: .connected(accountID: "acc_preview")),
                    initialDestination: destination,
                    smartInboxActivityJob: { job }
                )
            )

            _ = try XCTUnwrap(
                descendants(of: hosted.sidebarView)
                    .compactMap { $0 as? NSProgressIndicator }
                    .first,
                "Missing Activity progress in shipped root for \(destination)"
            )
            let control = try XCTUnwrap(
                descendants(of: hosted.sidebarView).first {
                    $0.accessibilityIdentifier() == "smart-inbox-activity-control"
                },
                "Missing Activity control in shipped root for \(destination)"
            )
            XCTAssertEqual(control.accessibilityIdentifier(), "smart-inbox-activity-control")
        }
    }

    func testHostedSidebarKeepsBothCountsAndControlInsideMinimumWidth() throws {
        let job = rerunJob(
            state: .running,
            progress: PlainpostOperationProgress(
                current: 123_456,
                total: 777_777,
                phase: "classifying",
                label: "Smart Inbox"
            )
        )
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let compactDetail = try XCTUnwrap(presentation.compactDetail)
        let hosted = hostFixedWidth(
            PlainpostSidebar(
                selection: .constant(.smartInbox),
                viewModel: inbox(requiresAccountSetup: false),
                smartInboxActivity: presentation,
                smartInboxActivityActionInFlight: false,
                smartInboxActivityActionMessage: nil,
                pauseSmartInbox: { _ in },
                resumeSmartInbox: { _ in }
            ),
            width: 190
        )
        _ = try XCTUnwrap(
            descendants(of: hosted.hostingView)
                .compactMap { $0 as? NSProgressIndicator }
                .first
        )
        XCTAssertEqual(hosted.containerView.bounds.width, 190, accuracy: 0.01)
        XCTAssertEqual(hosted.hostingView.bounds.width, 190, accuracy: 0.01)

        let control = try XCTUnwrap(
            descendants(of: hosted.hostingView).first {
                $0.accessibilityIdentifier() == "smart-inbox-activity-control"
            }
        )
        let controlFrameInSidebar = hosted.hostingView.convert(control.bounds, from: control)
        let compactDetailSlotWidth: CGFloat = 190 - (14 * 2) - 22 - 10 - 10 - 28
        let compactWidthAtMinimumScale = (compactDetail as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        ).width * SmartInboxActivitySection.detailMinimumScaleFactor
        XCTAssertGreaterThanOrEqual(controlFrameInSidebar.minX, 190 - 14 - 28)
        XCTAssertLessThanOrEqual(controlFrameInSidebar.maxX, 190 - 14 + 1)
        XCTAssertEqual(compactDetailSlotWidth, 92)
        XCTAssertEqual(SmartInboxActivitySection.detailMinimumScaleFactor, 0.84)
        XCTAssertLessThanOrEqual(compactWidthAtMinimumScale, compactDetailSlotWidth)
        XCTAssertTrue(compactDetail.contains("123,456"))
        XCTAssertTrue(compactDetail.contains("777,777"))
    }

    func testHostedRootRemovesActivitySectionWhenIdle() {
        let hosted = hostRoot(
            PlainpostRootView(
                viewModel: inbox(requiresAccountSetup: false),
                accountSetup: accountSetup(status: .connected(accountID: "acc_preview")),
                initialDestination: .settings,
                smartInboxActivityJob: { nil }
            )
        )
        XCTAssertTrue(
            descendants(of: hosted.sidebarView)
                .compactMap { $0 as? NSProgressIndicator }
                .isEmpty
        )
    }
#endif

    @MainActor
    func testInboxSnapshotRefreshesProviderOnlyWhenExplicitlyRequested() async {
        var providerCallCount = 0
        let initialModel = inbox(requiresAccountSetup: false)
        let snapshot = InboxViewModelSnapshotStore(
            initialModel: initialModel,
            provider: { _ in
                providerCallCount += 1
                return self.inbox(requiresAccountSetup: false)
            }
        )

        XCTAssertEqual(snapshot.model.classicRows, initialModel.classicRows)
        XCTAssertEqual(providerCallCount, 0)

        await snapshot.refresh(selectedMessageID: "msg_alice")

        XCTAssertEqual(providerCallCount, 1)
    }

    @MainActor
    func testInboxSnapshotRefreshKeepsThePendingDeleteOverlay() async {
        let overlay = OptimisticMailboxOverlay(rowID: "msg_1", action: .delete)
        let snapshot = InboxViewModelSnapshotStore(
            initialModel: inbox(rows: [unreadRow(id: "msg_1")]),
            provider: { _ in self.inbox(rows: [self.unreadRow(id: "msg_1")]) },
            projector: { OptimisticMailboxProjection.project($0, overlays: ["msg_1": overlay]) }
        )

        await snapshot.refresh(selectedMessageID: "msg_1")

        XCTAssertTrue(snapshot.model.classicRows.isEmpty)
    }

    @MainActor
    func testMailboxReadFailureKeepsCachedRowsUntilExplicitRetrySucceeds() async {
        let cached = inbox(rows: [unreadRow(id: "cached")])
        var fails = true
        let snapshot = InboxViewModelSnapshotStore(
            initialModel: cached,
            provider: { _ in
                fails
                    ? InboxViewModel.loading(requiresAccountSetup: false)
                        .withMailboxLoadFailure("Mail could not be loaded. Retry.")
                    : cached
            }
        )

        await snapshot.refresh(selectedMessageID: "cached")
        XCTAssertEqual(snapshot.model.classicRows.map(\.id), ["cached"])
        XCTAssertEqual(snapshot.model.mailboxLoadFailure, "Mail could not be loaded. Retry.")

        fails = false
        await snapshot.refresh(selectedMessageID: "cached")
        XCTAssertEqual(snapshot.model.classicRows.map(\.id), ["cached"])
        XCTAssertNil(snapshot.model.mailboxLoadFailure)
    }

    func testSentSyncControlsUseSelectedAccountMailboxPath() {
        let account = Account(
            id: AccountID("custom-sent"),
            displayName: "Work",
            email: EmailAddress("work@example.com"),
            sentMailbox: "Sent Items",
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )

        XCTAssertEqual(PlainpostRootView.mailboxSyncPath(for: .sent, account: account), "Sent Items")
        XCTAssertEqual(PlainpostRootView.mailboxSyncPath(for: .archive, account: account), "Archive")
    }

    @MainActor
    func testMailboxFailureDoesNotShowPreviousMessageUnderNewSelection() async {
        let base = inbox(rows: [unreadRow(id: "message-a"), unreadRow(id: "message-b")])
        let cached = InboxViewModel(
            chrome: base.chrome,
            sidebarItems: base.sidebarItems,
            smartCards: base.smartCards,
            classicRows: base.classicRows,
            selectedThread: ThreadDetailModel(
                subject: "Message A", participants: [], summaryStatus: "Not summarized",
                actionItems: [], availableActions: ["Reply"],
                messages: [ThreadMessageModel(
                    id: "message-a", sender: "alice@example.com", body: .plainText("A body")
                )]
            ),
            aiIndexStatus: base.aiIndexStatus
        )
        let snapshot = InboxViewModelSnapshotStore(
            initialModel: cached,
            provider: { _ in
                InboxViewModel.loading(requiresAccountSetup: false)
                    .withMailboxLoadFailure("Mail could not be loaded. Retry.")
            }
        )

        await snapshot.refresh(selectedMessageID: "message-a")
        XCTAssertEqual(snapshot.model.selectedThread.messages.map(\.id), ["message-a"])

        await snapshot.refresh(selectedMessageID: "message-b")

        XCTAssertEqual(snapshot.model.classicRows.map(\.id), ["message-a", "message-b"])
        XCTAssertTrue(snapshot.model.selectedThread.messages.isEmpty)
        XCTAssertEqual(snapshot.model.mailboxLoadFailure, "Mail could not be loaded. Retry.")
    }

    @MainActor
    func testDeleteHidesTheRowAndDismissesSelectionBeforeTheHandlerCompletes() async {
        let handler = ControlledInboxMailActionHandler()
        let presentation = MailboxActionPresentationHarness(
            model: inbox(rows: [unreadRow(id: "msg_1")]),
            handler: handler,
            selectedMessageID: "msg_1"
        )

        presentation.perform(.delete, messageID: "msg_1")
        await handler.waitUntilStarted()

        XCTAssertTrue(presentation.snapshot.model.classicRows.isEmpty)
        XCTAssertNil(presentation.selectedMessageID)

        await handler.succeed(.init(messageID: .init("msg_1"), action: .delete, deleted: true))
    }

    @MainActor
    func testInboxSnapshotLoadsOnePageForRepeatedAutomaticFooterAppearances() async {
        let initial = inbox(requiresAccountSetup: false, hasMoreRows: true)
        let loaded = inbox(requiresAccountSetup: false, hasMoreRows: false, mailboxRevision: 1)
        let provider = SuspendedInboxLoadMoreProvider(model: loaded)
        let snapshot = InboxViewModelSnapshotStore(
            initialModel: initial,
            provider: { _ in initial },
            loadMoreProvider: { _ in await provider.load() }
        )

        let first = Task { await snapshot.loadMore(selectedMessageID: nil) }
        await provider.waitForRequestCount(1)
        await snapshot.loadMore(selectedMessageID: nil)

        XCTAssertTrue(snapshot.isLoadingMore)
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 1)
        await provider.resume()
        _ = await first.result

        XCTAssertFalse(snapshot.isLoadingMore)
        XCTAssertEqual(snapshot.model.mailboxRevision, 1)
        XCTAssertFalse(snapshot.model.hasMoreRows)
    }

    @MainActor
    func testSentSnapshotCanLoadMoreWhenInboxHasNoMoreRows() async {
        let shell = inbox(requiresAccountSetup: false)
        let initial = InboxViewModel(
            chrome: shell.chrome, sidebarItems: shell.sidebarItems,
            smartCards: shell.smartCards, classicRows: shell.classicRows,
            sentRows: [unreadRow(id: "sent-one")], selectedThread: shell.selectedThread,
            aiIndexStatus: shell.aiIndexStatus, hasMoreRows: false, hasMoreSentRows: true
        )
        let provider = SuspendedInboxLoadMoreProvider(model: initial)
        let snapshot = InboxViewModelSnapshotStore(
            initialModel: initial, provider: { _ in initial },
            loadMoreProvider: { _ in await provider.load() }
        )

        let request = Task {
            await snapshot.loadMore(selectedMessageID: nil, destination: .sent)
        }
        await provider.waitForRequestCount(1)
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 1)
        await provider.resume()
        _ = await request.result
    }

    @MainActor
    func testInboxSnapshotDiscardsAnOlderRefreshThatFinishesLast() async {
        let initialModel = inbox(requiresAccountSetup: false)
        let snapshot = InboxViewModelSnapshotStore(
            initialModel: initialModel,
            provider: { selectedMessageID in
                if selectedMessageID == "slow" {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                return InboxViewModel(
                    chrome: initialModel.chrome,
                    sidebarItems: initialModel.sidebarItems,
                    smartCards: initialModel.smartCards,
                    classicRows: initialModel.classicRows,
                    selectedThread: ThreadDetailModel(
                        subject: selectedMessageID ?? "none",
                        participants: [],
                        summaryStatus: "Not summarized",
                        actionItems: [],
                        availableActions: []
                    ),
                    aiIndexStatus: initialModel.aiIndexStatus
                )
            }
        )

        let slowRefresh = Task { await snapshot.refresh(selectedMessageID: "slow") }
        await Task.yield()
        await snapshot.refresh(selectedMessageID: "fast")
        await slowRefresh.value

        XCTAssertEqual(snapshot.model.selectedThread.subject, "fast")
    }

    func testEmailBodyRenderCacheReusesRenderedHTMLUntilTheMessageChanges() {
        var renderCount = 0
        let cache = EmailBodyRenderCache { input in
            renderCount += 1
            return EmailBodyRenderer.render(input)
        }
        let first = EmailBodyInput.html("<p>Hello</p>")

        _ = cache.renderedBody(messageID: "msg_1", input: first)
        _ = cache.renderedBody(messageID: "msg_1", input: first)
        XCTAssertEqual(renderCount, 1)

        _ = cache.renderedBody(messageID: "msg_1", input: .html("<p>Updated</p>"))
        XCTAssertEqual(renderCount, 2)

        cache.retain(messageIDs: [])
        _ = cache.renderedBody(messageID: "msg_1", input: first)
        XCTAssertEqual(renderCount, 3)
    }

    func testDeferredEmailBodyRenderStoreCachesPreparedHTML() async {
        let store = DeferredEmailBodyRenderStore(capacity: 2)
        let input = EmailBodyInput.html("<p>Hello</p><img src=\"https://example.com/a.jpg\">")

        let first = await store.render(messageID: "msg_1", input: input)
        let second = await store.render(messageID: "msg_1", input: input)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.blockedRemoteImageURLs, ["https://example.com/a.jpg"])
    }

    func testAIProviderSettingsPresentsSearchableTranslationLanguagePicker() {
        let translationSettings = TranslationLanguageSettingsViewModel(
            options: [
                .init(id: "de", localizedName: "German"),
                .init(id: "en", localizedName: "English"),
            ]
        )
        var isLanguagePickerPresented = true

        evaluate(
            SmartInboxSettingsPage(
                settings: .preview(),
                translation: translationSettings,
                maintenance: .preview()
            )
        )
        translationSettings.query = "German"
        evaluate(
            TranslationLanguagePickerPopover(
                viewModel: translationSettings,
                isPresented: Binding(
                    get: { isLanguagePickerPresented },
                    set: { isLanguagePickerPresented = $0 }
                )
            )
        )

        XCTAssertEqual(translationSettings.filteredOptions.map(\.id), ["de"])
        XCTAssertEqual(translationSettings.selectedOption.localizedName, "English")
    }

    func testTranslatedMessagePresentationReplacesOnlyBodyAndKeepsOriginalRemoteImagePolicy() {
        let message = ThreadMessageModel(
            id: "message-translation",
            sender: "sender@example.com",
            senderDisplayName: "Sender",
            dateLabel: "Today",
            body: .html("<p>Original</p><img src=\"https://example.com/original.png\">")
        )
        let translated = RenderedEmailBody(
            kind: .plainText,
            safeText: "Translated body",
            safeHTML: nil,
            blockedRemoteImageURLs: ["https://tracker.example/translated.png"]
        )

        let displayed = ThreadMessageBlock.bodyOnlyReplacement(
            for: message,
            displayedBody: translated
        )

        XCTAssertEqual(displayed.kind, .plainText)
        XCTAssertEqual(displayed.safeText, "Translated body")
        XCTAssertEqual(displayed.blockedRemoteImageURLs, message.blockedRemoteImageURLs)
        XCTAssertEqual(message.senderDisplayName, "Sender")
        XCTAssertEqual(message.dateLabel, "Today")
    }

    func testSettingsWorkspaceHasBodyForEverySectionAndAccountState() {
        XCTAssertEqual(SystemSettingsSidebarLabel.titleLeadingPadding, 4)

        for section in PlainpostSettingsSection.allCases {
            let selectedSection = section
            var selection: PlainpostSettingsDestination? = .section(section)
            let accountSetup = accountSetup(status: .connected(accountID: "acc_preview"))
            let maintenance = MailMaintenanceViewModel.preview(accountSetup: accountSetup)
            evaluate(SystemSettingsSidebarLabel(section: section, isSelected: section == selectedSection))
            evaluate(
                SystemSettingsHero(
                    title: section.title,
                    detail: "",
                    systemImage: section.systemImage,
                    tint: section.settingsTint
                )
            )
            let settings = SettingsWorkspace(
                selection: Binding(get: { selection }, set: { selection = $0 }),
                accountSetup: accountSetup,
                aiProviderSettings: .preview(),
                aiIndexStatus: inbox().aiIndexStatus,
                auditLog: .preview(),
                mailRules: .preview(),
                mailLabels: .preview(),
                maintenance: maintenance
            )
            XCTAssertTrue(settings.maintenance === maintenance)
            evaluate(settings)
        }

        evaluate(AddAccountSettingsPage(accountSetup: accountSetup(status: .idle), selection: nil))
        evaluate(AccountSettingsPage(accountID: AccountID("preview"), viewModel: .connectedPreview()))
        evaluate(AccountFoldersPage(viewModel: .connectedPreview()))
        evaluate(AccountServerSettingsPage(viewModel: .connectedPreview()))
        let providerSettings = AIProviderSettingsViewModel.preview()
        evaluate(
            SmartInboxSettingsPage(
                settings: providerSettings,
                translation: TranslationLanguageSettingsViewModel(
                    options: [TranslationLanguageOption(id: "en", localizedName: "English")]
                ),
                maintenance: .preview()
            )
        )
        evaluate(SystemSettingsHero(title: "Notifications", detail: "Choose which Plainpost events can interrupt you.", systemImage: "bell", tint: .red))
        evaluate(SystemSettingsSidebarLabel(section: .notifications, isSelected: true))
        evaluate(SystemSettingsSidebarLabel(section: .accounts, isSelected: false))
        evaluate(SystemSettingsGroup("Preview") {
            SystemSettingsValueRow(title: "Status", systemImage: "checkmark.circle", tint: .green, value: "Ready")
        })
        evaluate(SystemSettingsInsetSeparator())
        #if os(macOS)
        // macOS adds only the Calendars section ahead of the eight shared sections.
        XCTAssertEqual(PlainpostSettingsSection.allCases.count, 9)
        XCTAssertEqual(PlainpostSettingsSection.syncNode.title, "Sync Node")
        XCTAssertEqual(PlainpostSettingsSection.syncNode.systemImage, "server.rack")
        XCTAssertEqual(
            PlainpostSettingsSection.allCases.map(\.rawValue),
            ["accounts", "smartInbox", "rulesLabels", "notifications", "privacy", "plainpostAccount", "syncNode", "calendars", "troubleshooting"]
        )
        #else
        XCTAssertEqual(PlainpostSettingsSection.allCases.count, 8)
        XCTAssertEqual(
            PlainpostSettingsSection.allCases.map(\.rawValue),
            ["accounts", "smartInbox", "rulesLabels", "notifications", "privacy", "plainpostAccount", "syncNode", "troubleshooting"]
        )
        #endif
    }

    func testSecurityPrivacySettingsConstructsLoadedEmptyLoadingAndFailedStates() {
        evaluate(makePlainpostAccountPage(loadState: .loaded))
        evaluate(makePlainpostAccountPage(loadState: .loading))
        evaluate(
            makePlainpostAccountPage(
                loadState: .failed(message: "Account security couldn’t be loaded.")
            )
        )
        evaluate(PlainpostAccountSettingsPage(accountSessionModel: nil))
    }

    func testAccountSecurityDesignPreviewConstructsEachLoadState() {
        evaluate(AccountSecuritySettingsPanel.designPreview(loadState: .loaded))
        evaluate(AccountSecuritySettingsPanel.designPreview(loadState: .loading))
        evaluate(
            AccountSecuritySettingsPanel.designPreview(
                loadState: .failed(message: "Account security couldn’t be loaded.")
            )
        )
        evaluate(AccountSecuritySettingsDesignPreview(loadState: .loaded))
    }

    func testSyncNodeServerEditorEditsOnlyTheAddress() {
        let hosted = hostRoot(
            SyncNodeServerEditor(
                currentOrigin: "https://sync.example.test:18443",
                save: { _ in .invalidAddress },
                importProfile: { _ in false }
            )
        )
        let textFields = descendants(of: hosted.hostingView).compactMap { $0 as? NSTextField }

        XCTAssertTrue(
            textFields.contains {
                $0.isEditable && $0.stringValue == "https://sync.example.test:18443"
            },
            "The server editor must expose an editable Sync Node address."
        )
        XCTAssertFalse(
            textFields.contains { $0.stringValue.contains("fingerprint") || $0.stringValue.contains("protected identity") },
            "The fingerprint lives behind Verify Fingerprint, not in the address editor."
        )
    }

    func testSecurityPrivacySettingsWorkspaceAcceptsAccountSecurityCapability() {
        var selection: PlainpostSettingsDestination? = .section(.plainpostAccount)
        let session = AccountSessionViewModel(prepareSession: { _ in .active })
        let accountSetup = accountSetup(status: .connected(accountID: "acc_preview"))

        evaluate(
            SettingsWorkspace(
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                ),
                accountSetup: accountSetup,
                accountSessionModel: session,
                aiProviderSettings: .preview(),
                aiIndexStatus: inbox().aiIndexStatus,
                auditLog: .preview(),
                mailRules: .preview(),
                mailLabels: .preview(),
                maintenance: .preview(accountSetup: accountSetup)
            )
        )
    }

    func testActiveAccountRootDoesNotRenderFloatingAccountSecurityShortcut() {
        let model = AccountSessionViewModel.debugAuthorized()
        let root = AccountSessionRootView(model: model) { _, _ in Text("Inbox") }
        let hosted = hostRoot(root)

        XCTAssertNil(
            descendants(of: hosted.hostingView).first {
                $0.accessibilityLabel() == "Account Security"
                    || ($0 as? NSButton)?.title == "Account Security"
            }
        )
    }

    func testRecoveryAccountRootKeepsRecoveryAndServerActionsSeparatedAtCompactSize() async throws {
        let model = AccountSessionViewModel(
            prepareSession: { _ in .expired },
            securityFactory: { _ in
                AccountSecurityViewModel(
                    controllerFactory: {
                        throw AccountRuntimeError.untrustedResponse
                    },
                    stateChanged: {}
                )
            }
        )
        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where model.presentation != .recoveryRequired {
            await Task.yield()
        }

        let root = AccountSessionRootView(
            model: model,
            changeServer: {}
        ) { _, _ in Text("Inbox") }
        XCTAssertEqual(model.presentation, .recoveryRequired)
        XCTAssertTrue(
            AccountSessionRootView<Text>.showsRecoveryAction(
                presentation: model.presentation,
                hasSecurityModel: model.securityModel != nil
            )
        )
        let hosted = hostRoot(
            root,
            size: NSSize(width: 694, height: 562)
        )
        let actionViews = descendants(of: hosted.hostingView).filter {
            let typeName = String(describing: type(of: $0))
            return typeName == "KeyViewProxy" || typeName == "SwiftUIAppKitButton"
        }
        XCTAssertEqual(
            actionViews.count,
            2,
            "The compact root must render exactly the primary recovery control and Change Server link."
        )
        let actionFrames = actionViews
            .map { $0.convert($0.bounds, to: hosted.hostingView) }
            .sorted { $0.minY < $1.minY }
        guard actionFrames.count == 2 else { return }
        XCTAssertFalse(
            actionFrames[0].intersects(actionFrames[1]),
            "Recovery and Change Server actions must not overlap at the reported 694 by 562 window size."
        )
        for frame in actionFrames {
            XCTAssertTrue(
                hosted.hostingView.bounds.contains(frame),
                "Both actions must remain fully inside the compact recovery root."
            )
        }
        if let securityModel = model.securityModel {
            evaluate(AccountRecoveryView(model: securityModel))
        } else {
            XCTFail("Recovery requires the configured security capability.")
        }
    }

    func testRecoveryActionsRenderTogether() {
        let actions = AccountRecoveryActions(recover: {}, changeServer: {})
        let labels = reflectedViewNodes(in: actions.body).compactMap { node -> String? in
            guard let button = node.value as? Button<Text>,
                  let label = Mirror(reflecting: button).children
                    .first(where: { $0.label == "label" })?.value
            else { return nil }
            return reflectedStrings(in: label).first
        }

        XCTAssertTrue(labels.contains("Recover Plainpost Account"))
        XCTAssertTrue(labels.contains("Change Server"))
        evaluate(actions)
    }

    func testRecoverySheetImmediatelyOffersAppleConfirmation() {
        let model = AccountSecurityViewModel(
            controllerFactory: {
                throw AccountRuntimeError.untrustedResponse
            },
            stateChanged: {}
        )
        let hosted = hostRoot(
            AccountRecoveryView(model: model),
            size: NSSize(width: 620, height: 420)
        )
        let controls = descendants(of: hosted.hostingView)

        XCTAssertFalse(
            controls.contains {
                ($0 as? NSButton)?.title == "Recover Plainpost Account"
            },
            "Opening recovery must not require a second recovery-button click."
        )
        XCTAssertTrue(
            controls.contains {
                $0.accessibilityLabel()?.localizedCaseInsensitiveContains("Apple") == true
            },
            "The recovery sheet must immediately expose Apple confirmation."
        )
    }

    func testRecoverySheetFitsItsContentWithoutFixedBottomGap() {
        let model = AccountSecurityViewModel(
            controllerFactory: {
                throw AccountRuntimeError.untrustedResponse
            },
            stateChanged: {}
        )
        let hostingView = NSHostingView(
            rootView: AnyView(AccountRecoverySheet(model: model))
        )

        XCTAssertLessThan(hostingView.fittingSize.height, 320)
    }

    func testRecoverySheetDismissesAfterSuccessfulRecovery() async throws {
        let model = AccountSecurityViewModel(
            loadSnapshot: { .init(devices: [], events: []) },
            performAction: { action, _, _ in
                XCTAssertEqual(action, .recoverAccount)
                return nil
            },
            saveLabel: { _, _ in },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA5, count: 32) }
        )
        let hosted = hostRoot(RecoverySheetDismissalHarness(model: model))
        let didPresent = await eventuallyRecoverySheet { hosted.window.attachedSheet != nil }
        XCTAssertTrue(didPresent)

        let request = try model.begin(.recoverAccount)
        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)

        let didComplete = await eventuallyRecoverySheet { model.recoveryDidComplete }
        XCTAssertTrue(didComplete)
        let didDismiss = await eventuallyRecoverySheet { hosted.window.attachedSheet == nil }
        XCTAssertTrue(
            didDismiss,
            "A fully completed recovery must dismiss its modal sheet."
        )
    }

    func testCredentialReplacementRendersProviderPasswordControlsAndDisabledState() throws {
        let gmail = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        let custom = Account(
            id: AccountID("acc_custom"),
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let viewModel = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            account: gmail,
            accounts: [gmail, custom]
        )
        let panel = CredentialReplacementSection(viewModel: viewModel)
        var structure = try credentialReplacementStructure(in: panel)
        XCTAssertEqual(
            structure.fields,
            [
                CredentialFieldStructure(
                    label: "Google App Password",
                    prompt: "Google App Password",
                    accessibilityLabel: "Google App Password",
                    identifier: "credential-replacement-incoming"
                ),
            ],
            "Gmail asks for its one App Password once"
        )
        XCTAssertNil(structure.help, "The password sheet carries no Keychain or App Password help line")
        XCTAssertEqual(
            structure.update,
            CredentialUpdateStructure(
                title: "Update Password",
                identifier: "credential-replacement-update",
                isDisabled: true
            )
        )

        viewModel.imapPassword = "abcd efgh ijkl mno"
        structure = try credentialReplacementStructure(in: panel)
        XCTAssertTrue(structure.update.isDisabled)

        viewModel.imapPassword = "abcd efgh ijkl mnop"
        structure = try credentialReplacementStructure(in: panel)
        XCTAssertFalse(structure.update.isDisabled)
        viewModel.imapPassword = ""

        viewModel.selectAccount(id: custom.id)
        structure = try credentialReplacementStructure(in: panel)
        XCTAssertEqual(
            structure.fields,
            [
                CredentialFieldStructure(
                    label: "IMAP password",
                    prompt: "New IMAP password",
                    accessibilityLabel: "IMAP password",
                    identifier: "credential-replacement-incoming"
                ),
                CredentialFieldStructure(
                    label: "SMTP password",
                    prompt: "New SMTP password",
                    accessibilityLabel: "SMTP password",
                    identifier: "credential-replacement-outgoing"
                ),
            ]
        )
        XCTAssertNil(structure.help)
        XCTAssertTrue(structure.update.isDisabled)

        viewModel.imapPassword = "incoming secret"
        structure = try credentialReplacementStructure(in: panel)
        XCTAssertTrue(structure.update.isDisabled)

        viewModel.smtpPassword = "outgoing secret"
        structure = try credentialReplacementStructure(in: panel)
        XCTAssertFalse(structure.update.isDisabled)

        viewModel.selectAccount(id: gmail.id)
        structure = try credentialReplacementStructure(in: panel)
        XCTAssertEqual(structure.fields.map(\.prompt), ["Google App Password"])
    }

    func testCredentialReplacementAsksICloudForItsAppPasswordOnce() throws {
        let icloud = Account(
            id: AccountID("acc_icloud"),
            displayName: "iCloud",
            email: EmailAddress("me@icloud.com"),
            imapHost: "imap.mail.me.com",
            smtpHost: "smtp.mail.me.com"
        )
        let viewModel = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            account: icloud,
            accounts: [icloud]
        )
        XCTAssertTrue(viewModel.isSelectedAccountICloud)
        let panel = CredentialReplacementSection(viewModel: viewModel)
        var structure = try credentialReplacementStructure(in: panel)
        XCTAssertEqual(
            structure.fields,
            [
                CredentialFieldStructure(
                    label: "App-specific password",
                    prompt: "App-specific password",
                    accessibilityLabel: "App-specific password",
                    identifier: "credential-replacement-incoming"
                ),
            ]
        )
        XCTAssertEqual(structure.update.title, "Update Password")
        XCTAssertTrue(structure.update.isDisabled)

        viewModel.imapPassword = "abcd-efgh-ijkl-mnop"
        structure = try credentialReplacementStructure(in: panel)
        XCTAssertFalse(structure.update.isDisabled)
    }

    func testOAuthSignInRowNamesTheProviderAndOffersSignInAgain() {
        let ada = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"))
        let viewModel = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            account: ada,
            accounts: [ada],
            accountAuthenticationProvider: { _ in
                AccountAuthenticationSummary(method: .googleOAuth, state: .ready)
            }
        )
        XCTAssertTrue(viewModel.isSelectedAccountGoogleOAuth)

        let strings = reflectedViewNodes(in: CredentialReplacementSection(viewModel: viewModel).body)
            .flatMap { reflectedStrings(in: $0.value) }

        XCTAssertTrue(strings.contains("Sign-in"))
        XCTAssertTrue(strings.contains("Google account"))
        XCTAssertTrue(strings.contains("Sign in again"))
        XCTAssertFalse(strings.contains("Credentials"))
        XCTAssertFalse(strings.contains(viewModel.credentialReplacementHelp))
    }

    private func makePlainpostAccountPage(
        loadState: AccountSecurityViewModel.LoadState
    ) -> PlainpostAccountSettingsPage {
        let model = AccountSecurityViewModel(
            loadSnapshot: { .init(devices: [], events: []) },
            performAction: { _, _, _ in nil },
            saveLabel: { _, _ in },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA5, count: 32) },
            initialLoadState: loadState
        )
        let session = AccountSessionViewModel(prepareSession: { _ in .active }, securityFactory: { _ in model })
        return PlainpostAccountSettingsPage(accountSessionModel: session)
    }

    func testAccountDeletionConfirmationUsesExactLocalOnlyCopy() {
        XCTAssertEqual(
            AccountDeletionConfirmation.message(email: "me@example.com"),
            "This permanently removes me@example.com, its credentials, cached mail, attachments, drafts, queued work, and account rules from Plainpost. Mail on your provider is not deleted."
        )
    }

    func testAccountDeletionDangerSectionRendersAccessibleDestructiveControlAndSafeNotice()
        async throws
    {
        let deleted = smokeDeletionAccount(id: "acc_deleted", email: "deleted@example.com")
        let remaining = smokeDeletionAccount(id: "acc_remaining", email: "remaining@example.com")
        let accounts = SmokeAccountList([remaining])
        let viewModel = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            account: deleted,
            accounts: [deleted, remaining],
            accountsProvider: accounts.load,
            accountDeleter: { _ in
                throw PlainpostServiceClientError.accountDeletionCleanupPending
            }
        )
        await viewModel.deleteSelectedAccount()
        var requestedConfirmation = false
        let section = AccountDeletionDangerSection(
            viewModel: viewModel,
            requestConfirmation: { requestedConfirmation = true }
        )

        let structure = try accountDeletionDangerStructure(in: section)

        XCTAssertEqual(structure.open.title, "Remove Account…")
        XCTAssertEqual(structure.open.identifier, "account-deletion-open-confirmation")
        XCTAssertFalse(structure.open.isDisabled)
        XCTAssertTrue(structure.open.isDestructive)
        XCTAssertEqual(
            structure.notice,
            AccessibleTextStructure(
                text: "Account deleted from Plainpost. Local audit cleanup will finish automatically.",
                accessibilityLabel: "Account deleted from Plainpost. Local audit cleanup will finish automatically.",
                identifier: "account-deletion-status"
            )
        )
        section.requestConfirmation()
        XCTAssertTrue(requestedConfirmation)

        let failedViewModel = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            account: deleted,
            accounts: [deleted],
            accountDeleter: { _ in
                throw NSError(domain: "credential-token-leak", code: 17)
            }
        )
        await failedViewModel.deleteSelectedAccount()
        let failedStructure = try accountDeletionDangerStructure(
            in: AccountDeletionDangerSection(viewModel: failedViewModel, requestConfirmation: {})
        )
        XCTAssertEqual(
            failedStructure.notice,
            AccessibleTextStructure(
                text: "Account could not be deleted from Plainpost.",
                accessibilityLabel: "Account could not be deleted from Plainpost.",
                identifier: "account-deletion-status"
            )
        )
    }

    func testAccountDeletionConfirmationActionsWireDeleteAndDisableAllDestructiveEntryPoints()
        async throws
    {
        let account = smokeDeletionAccount(id: "acc_delete", email: "delete@example.com")
        let deletion = SuspendedSettingsAccountDeleter()
        let viewModel = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            account: account,
            accounts: [account],
            accountDeleter: deletion.delete
        )
        let actions = AccountDeletionConfirmationActions(viewModel: viewModel)
        let initial = try accountDeletionConfirmationStructure(in: actions)

        XCTAssertEqual(initial.cancel.title, "Cancel")
        XCTAssertEqual(initial.cancel.identifier, "account-deletion-cancel")
        XCTAssertEqual(initial.cancel.accessibilityLabel, "Cancel account deletion")
        XCTAssertEqual(initial.confirm.title, "Delete from Plainpost")
        XCTAssertEqual(initial.confirm.identifier, "account-deletion-confirm")
        XCTAssertEqual(initial.confirm.accessibilityLabel, "Delete delete@example.com from Plainpost")
        XCTAssertFalse(initial.confirm.isDisabled)
        XCTAssertTrue(initial.confirm.isDestructive)

        actions.deleteAccount()
        await deletion.waitUntilStarted()
        let requestCount = await deletion.requestCount
        XCTAssertEqual(requestCount, 1)

        let executingActions = try accountDeletionConfirmationStructure(
            in: AccountDeletionConfirmationActions(viewModel: viewModel)
        )
        let executingDanger = try accountDeletionDangerStructure(
            in: AccountDeletionDangerSection(viewModel: viewModel, requestConfirmation: {})
        )
        XCTAssertTrue(executingActions.confirm.isDisabled)
        XCTAssertTrue(executingDanger.open.isDisabled)

        await deletion.succeed()
        for _ in 0..<200 where viewModel.isDeletingAccount {
            await Task.yield()
        }
        XCTAssertFalse(viewModel.isDeletingAccount)
    }

    func testAccountDeletionCleanupPendingNoticeSurvivesLastAccountTransition() async throws {
        let account = smokeDeletionAccount(id: "acc_last", email: "last@example.com")
        let viewModel = AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            account: account,
            accounts: [account],
            accountsProvider: SmokeAccountList([]).load,
            accountDeleter: { _ in
                throw PlainpostServiceClientError.accountDeletionCleanupPending
            }
        )

        await viewModel.deleteSelectedAccount()
        XCTAssertFalse(viewModel.hasConnectedAccount)

        let statusNotice = try XCTUnwrap(
            firstReflectedValue(
                of: AccountDeletionStatusNotice.self,
                in: AddAccountSettingsPage(accountSetup: viewModel, selection: nil).body
            )
        )
        let notice = reflectedViewNodes(in: statusNotice.body)
            .compactMap { accessibleTextStructure(in: $0.value) }
            .first { $0.identifier == "account-deletion-status" }
        XCTAssertEqual(
            notice,
            AccessibleTextStructure(
                text: "Account deleted from Plainpost. Local audit cleanup will finish automatically.",
                accessibilityLabel: "Account deleted from Plainpost. Local audit cleanup will finish automatically.",
                identifier: "account-deletion-status"
            )
        )
    }

#if os(macOS)
    func testEmptyLabelsListContentHonorsSharedListPaneWidth() throws {
        let availableWidth: CGFloat = 240 - (16 * 2)
        let renderer = ImageRenderer(content: MailLabelEmptyListContent())
        renderer.proposedSize = ProposedViewSize(
            width: nil,
            height: 320
        )
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.cgImage)

        XCTAssertLessThanOrEqual(CGFloat(image.width), availableWidth)
    }
#endif

    func testMailRulesSettingsMetadata() {
        XCTAssertEqual(PlainpostSettingsSection.rulesLabels.title, "Rules & Labels")
        XCTAssertEqual(
            PlainpostSettingsSection.rulesLabels.systemImage,
            "line.3.horizontal.decrease.circle"
        )
        evaluate(MailRulesSettingsPanel(viewModel: .preview()))
    }

    func testRulesAndLabelsShareOnePage() {
        XCTAssertEqual(RulesLabelsTab.allCases.map(\.rawValue), ["Rules", "Labels"])
        evaluate(RulesLabelsSettingsPage(rules: .preview(), labels: .preview()))
    }

    func testAccountSetupWorkspaceRendersProviderChooserAndBothProviderForms() {
        evaluate(AccountSetupWorkspace(viewModel: AccountSetupViewModel(setup: SmokeAccountSetupService())))
        evaluate(AccountSetupWorkspace(viewModel: .gmailEmptyPreview()))
        evaluate(AccountSetupWorkspace(viewModel: .gmailPartialPasswordPreview()))
        evaluate(AccountSetupWorkspace(viewModel: .gmailFailurePreview()))
        evaluate(AccountSetupWorkspace(viewModel: .gmailConnectingPreview()))
        evaluate(
            AccountSetupWorkspace(
                viewModel: AccountSetupViewModel(
                    setup: SmokeAccountSetupService(),
                    selectedProvider: .gmail,
                    displayName: "Personal",
                    email: "me@gmail.com",
                    gmailAppPassword: "abcdefghijklmnop"
                )
            )
        )
        evaluate(
            AccountSetupWorkspace(
                viewModel: AccountSetupViewModel(
                    setup: SmokeAccountSetupService(),
                    selectedProvider: .other,
                    displayName: "Personal",
                    email: "me@example.com",
                    imapHost: "imap.example.com",
                    smtpHost: "smtp.example.com",
                    username: "me@example.com"
                )
            )
        )
    }

#if os(iOS)
    func testIOSGmailSetupHasOneSignInActionAndNoManualIdentityFields() {
        let workspace = AccountSetupWorkspace(viewModel: .gmailEmptyPreview())
        let nodes = reflectedViewNodes(in: workspace.body)
        let strings = nodes.flatMap { reflectedStrings(in: $0.value) }
        let identifiers = nodes.compactMap { accessibilityMetadata(in: $0.value)?.identifier }

        XCTAssertTrue(strings.contains("Connect Gmail"))
        XCTAssertTrue(strings.contains("Sign in with Google"))
        XCTAssertFalse(strings.contains("Your name"))
        XCTAssertFalse(strings.contains("Google account"))
        XCTAssertTrue(identifiers.contains("gmail-sign-in-with-google"))
        XCTAssertFalse(nodes.contains { $0.typeName.contains("TextField") })
        evaluate(workspace)
    }

    func testIOSSettingsAccountAndSecurityRowsHaveCompactWidthFallbacks() throws {
        let device = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            platform: .ios,
            isCurrentDevice: true
        )
        let security = AccountSecuritySettingsPanel.designPreview(
            loadState: .loaded,
            devices: [device]
        )
        let securityNodes = reflectedViewNodes(in: security.body)
        XCTAssertTrue(
            securityNodes.contains { $0.typeName.contains("ViewThatFits") },
            "Security rows need a stacked accessory layout when horizontal space is tight."
        )
        evaluate(security)
    }
#endif

    func testAccountSetupLayoutUsesCompactReadablePanelMetrics() {
        let layout = AccountSetupLayoutMetrics.standard

        XCTAssertEqual(layout.contentMaxWidth, 760)
        XCTAssertEqual(layout.contentLeadingInset, 50)
        XCTAssertEqual(layout.panelSpacing, 14)
        XCTAssertEqual(layout.panelPadding, 16)
        XCTAssertEqual(layout.rowVerticalPadding, 8)
        XCTAssertEqual(layout.fieldLabelWidth, 128)
        XCTAssertEqual(layout.contentTopPadding, 10)
        XCTAssertEqual(layout.contentBottomPadding, 28)
        XCTAssertEqual(layout.headerHorizontalInset, 28)
        XCTAssertEqual(layout.headerTopPadding, 26)
        XCTAssertEqual(layout.headerBottomPadding, 0)
        XCTAssertEqual(layout.headerTextLayoutPriority, 1)
        XCTAssertEqual(layout.headerTitleLineLimit, 1)

        evaluate(
            AccountSetupPanel("Preview", footer: "Stored securely.", layout: layout) {
                LabeledContent("Account", value: "me@example.com")
            }
        )
    }

    func testOtherAccountSetupPreviewSelectsManualProviderAndRenders() {
        let viewModel = AccountSetupViewModel.otherPreview()

        XCTAssertEqual(viewModel.selectedProvider, .other)
        XCTAssertEqual(viewModel.email, "me@example.com")
        XCTAssertEqual(viewModel.imapHost, "imap.example.com")
        XCTAssertEqual(viewModel.smtpHost, "smtp.example.com")
        evaluate(AccountSetupWorkspace(viewModel: viewModel))
    }

    func testInboxViewsHaveBodyForFocusedUnreadAndSimpleStates() {
        let viewModel = inbox()
        let mailActions = InboxMailActionViewModel.preview()
        let destination = PlainpostDestination.smartInbox
        let smartMode = InboxDisplayMode.focusedList.rawValue
        let unreadMode = InboxDisplayMode.unreadCards.rawValue
        let classicMode = InboxDisplayMode.simpleList.rawValue
        let searchQuery = ""

        XCTAssertEqual(
            MailboxColumn.inboxDestinations,
            [.smartInbox, .allInboxes, .personal, .notifications, .newsletters]
        )
        XCTAssertNil(AppRail.approvalBadge(for: .approvalQueue, pendingApprovalCount: 0))
        XCTAssertEqual(AppRail.approvalBadge(for: .approvalQueue, pendingApprovalCount: 2), 2)
        XCTAssertNil(AppRail.approvalBadge(for: .smartInbox, pendingApprovalCount: 2))
        for destination in PlainpostDestination.allCases {
            XCTAssertEqual(
                AppRail.composeIsAvailable(isAccountSetupRequired: false, destination: destination),
                destination.workAreaKind == .mailbox
            )
            XCTAssertFalse(AppRail.composeIsAvailable(isAccountSetupRequired: true, destination: destination))
        }

        evaluate(
            AppRail(
                selectedDestination: .constant(destination),
                openCommandCenter: {},
                openComposer: {},
                canCompose: true
            )
        )
        evaluate(
            AppRail(
                selectedDestination: .constant(destination),
                openCommandCenter: {},
                openComposer: {},
                canCompose: false
            )
        )
        evaluate(
            MailboxColumn(
                viewModel: viewModel,
                selectedDestination: .constant(destination),
                selectedInboxMode: .constant(smartMode),
                searchQuery: .constant(searchQuery),
                selectedMessageID: .constant(viewModel.classicRows.first?.id),
                mailActions: mailActions
            )
        )
        evaluate(
            MailboxColumn(
                viewModel: viewModel,
                selectedDestination: .constant(destination),
                selectedInboxMode: .constant(unreadMode),
                searchQuery: .constant(searchQuery),
                selectedMessageID: .constant(viewModel.classicRows.first?.id),
                mailActions: mailActions
            )
        )
        evaluate(
            MailboxColumn(
                viewModel: viewModel,
                selectedDestination: .constant(destination),
                selectedInboxMode: .constant(classicMode),
                searchQuery: .constant(searchQuery),
                selectedMessageID: .constant(viewModel.classicRows.first?.id),
                mailActions: mailActions
            )
        )
        evaluate(
            MailboxColumn(
                viewModel: viewModel,
                selectedDestination: .constant(destination),
                selectedInboxMode: .constant(classicMode),
                searchQuery: .constant("availability"),
                selectedMessageID: .constant(viewModel.classicRows.first?.id),
                mailActions: mailActions
            )
        )
        for destination in [PlainpostDestination.allInboxes, .personal, .notifications, .newsletters] {
            evaluate(
                MailboxColumn(
                    viewModel: InboxViewModel.designPreview(),
                    selectedDestination: .constant(destination),
                    selectedInboxMode: .constant(classicMode),
                    searchQuery: .constant(searchQuery),
                    selectedMessageID: .constant(InboxViewModel.designPreview().classicRows.first?.id),
                    mailActions: mailActions
                )
            )
        }
        evaluate(
            DenseMailboxList(
                title: "All Inboxes",
                rows: viewModel.classicRows,
                selectMessage: { _ in }
            )
        )

        for card in viewModel.smartCards {
            evaluate(
                SmartInboxSection(
                    card: card,
                    selectedMessageID: viewModel.classicRows.first?.id,
                    selectMessage: { _ in },
                    mailActions: mailActions
                )
            )
        }
        for row in viewModel.classicRows {
            evaluate(
                MessageListRow(
                    row: row,
                    selected: row == viewModel.classicRows.first,
                    onSelect: {},
                    mailActions: mailActions
                )
            )
        }

        let readerActions = InboxMailActionViewModel.preview()
        evaluate(
            ThreadReaderWorkspace(
                thread: viewModel.selectedThread,
                openComposer: {},
                selectedMessageID: viewModel.selectedThread.messages.first?.id,
                mailActions: readerActions,
                dismissReader: {},
                performMessageAction: { _, _ in }
            )
        )
        evaluate(
            ThreadReaderWorkspace(
                thread: ThreadDetailModel(
                    subject: "Empty",
                    participants: [],
                    summaryStatus: "Not summarized",
                    actionItems: [],
                    availableActions: []
                ),
                openComposer: {}
            )
        )
        evaluate(
            ReaderToolbar(
                isUnread: true,
                isWorking: false,
                dismissReader: {},
                performMessageAction: { _ in }
            )
        )
        evaluate(ToolbarIcon("archivebox", "Archive", selected: true))
        for destination in [PlainpostDestination.drafts, .sent, .archive, .trash, .labels] {
            evaluate(MailboxUtilityList(destination: destination))
            evaluate(MailboxDestinationWorkspace(destination: destination, openComposer: {}))
            evaluate(MailboxWorkspaceHeader(destination: destination))
            evaluate(
                MailboxUtilityStateView(
                    state: destination.utilityState,
                    tint: destination.overviewTint,
                    openComposer: {}
                )
            )
        }
        if let message = viewModel.selectedThread.messages.first {
            evaluate(ThreadMessageBlock(message: message))
            evaluate(
                ConversationMessageDisclosure(
                    message: message,
                    isSelected: true,
                    isOnlyMessage: false,
                    allowsRemoteContent: false,
                    allowsReply: true,
                    openComposer: {}
                )
            )
        }
        evaluate(RemoteImagesBanner(blockedCount: 4, imagesLoaded: false))
        evaluate(RemoteImagesBanner(blockedCount: 4, imagesLoaded: true))
        evaluate(RemoteImagesBanner(blockedCount: 4, isDismissed: true))

        XCTAssertFalse(viewModel.classicRows.isEmpty)
    }

    func testSmartInboxChoosesTriageOnlyForAnEmptyFocusedSearch() {
        XCTAssertEqual(
            MailboxColumn.smartInboxPresentation(mode: .focusedList, searchQuery: ""),
            .triage
        )
        XCTAssertEqual(
            MailboxColumn.smartInboxPresentation(mode: .focusedList, searchQuery: "  availability "),
            .flatList
        )
        XCTAssertEqual(
            MailboxColumn.smartInboxPresentation(mode: .unreadCards, searchQuery: ""),
            .unreadCards
        )
        XCTAssertEqual(
            MailboxColumn.smartInboxPresentation(mode: .simpleList, searchQuery: ""),
            .flatList
        )
    }

    func testNativeMailboxColumnUsesTriageOnlyForEmptyFocusedSmartInbox() {
        XCTAssertEqual(
            nativeMessageListColumn(mode: .focusedList, searchQuery: "").contentPresentation,
            .triage
        )
        XCTAssertEqual(
            nativeMessageListColumn(mode: .focusedList, searchQuery: "project").contentPresentation,
            .flatList
        )
        XCTAssertEqual(
            nativeMessageListColumn(mode: .unreadCards, searchQuery: "").contentPresentation,
            .unreadCards
        )
        XCTAssertEqual(
            nativeMessageListColumn(mode: .simpleList, searchQuery: "").contentPresentation,
            .flatList
        )
    }

    func testNativeTriagePaginationUsesSharedFooterSemantics() {
        let available = nativeMessageListColumn(
            mode: .focusedList,
            searchQuery: "",
            hasMoreRows: true,
            isLoadingMore: false
        )
        let exhausted = nativeMessageListColumn(
            mode: .focusedList,
            searchQuery: "",
            hasMoreRows: false,
            isLoadingMore: false
        )
        let disabled = nativeMessageListColumn(
            mode: .focusedList,
            searchQuery: "",
            hasMoreRows: true,
            isLoadingMore: false,
            disabledMailboxSync: DisabledMailboxSyncPresentation(
                title: "Disabled",
                detail: "Disabled",
                actionTitle: "Enable",
                isEnabling: false
            )
        )

        XCTAssertTrue(available.triagePaginationFooter.isVisible)
        XCTAssertEqual(available.triagePaginationFooter.label, "Loading more messages")
        XCTAssertFalse(exhausted.triagePaginationFooter.isVisible)
        XCTAssertFalse(disabled.triagePaginationFooter.isVisible)
    }

    func testResponsiveSmartInboxBandsRenderAtBothWidthClasses() {
        for (widthClass, activeBundle) in [
            (MailboxListWidthClass.wide, Optional<SmartInboxDisplayBundle>.none),
            (.narrow, .some(.newsletters))
        ] {
            evaluate(
                SmartInboxTriageView(
                    rows: inbox().rows(for: .smartInbox),
                    selectedMessageID: .constant(nil),
                    widthClass: widthClass,
                    activeBundle: activeBundle,
                    mailActions: .preview(),
                    performMessageAction: { _, _ in },
                    paginationPresentation: SmartInboxTriagePaginationPresentation(
                        footer: InboxPaginationFooterPresentation.make(
                            hasMoreRows: true,
                            isLoadingMore: false
                        )
                    ),
                    loadMore: {},
                    openBundle: { _ in },
                    closeBundle: {},
                    openMessage: { _, _ in }
                )
            )
        }
    }

    func testNativeMailboxListSurfacesConstructAcrossContextsAndWidths() {
        for widthClass in [MailboxListWidthClass.wide, .narrow] {
            for activeBundle in [
                Optional<SmartInboxDisplayBundle>.none,
                .some(.newsletters),
            ] {
                evaluate(
                    SmartInboxTriageView(
                        rows: inbox().rows(for: .smartInbox),
                        selectedMessageID: .constant(nil),
                        widthClass: widthClass,
                        activeBundle: activeBundle,
                        mailActions: .preview(),
                        performMessageAction: { _, _ in },
                        paginationPresentation: SmartInboxTriagePaginationPresentation(
                            footer: InboxPaginationFooterPresentation.make(
                                hasMoreRows: true,
                                isLoadingMore: false
                            )
                        ),
                        loadMore: {},
                        openBundle: { _ in },
                        closeBundle: {},
                        openMessage: { _, _ in }
                    )
                )
            }
        }

        for mode in [
            InboxDisplayMode.focusedList,
            .simpleList,
            .unreadCards,
        ] {
            evaluate(nativeMessageListColumn(mode: mode, searchQuery: ""))
        }
    }

    func testShippedRootAndNativeMailboxColumnConstructTheFocusedTriagePath() {
        let viewModel = inbox(requiresAccountSetup: false)
        let root = PlainpostRootView(
            viewModel: viewModel,
            accountSetup: accountSetup(status: .connected(accountID: "acc_preview")),
            inboxMailActions: .preview(),
            initialDestination: .smartInbox,
            initialInboxMode: InboxDisplayMode.focusedList.rawValue
        )
        let column = nativeMessageListColumn(mode: .focusedList, searchQuery: "")

        evaluate(root)
        evaluate(column)
        XCTAssertEqual(column.contentPresentation, .triage)
    }

    func testUtilityMailboxStatesDoNotPretendToHaveLiveData() {
        let destinations: [PlainpostDestination] = [.drafts, .sent, .archive, .trash, .labels]

        for destination in destinations {
            let state = destination.utilityState
            XCTAssertFalse(state.title.localizedCaseInsensitiveContains("preview"))
            XCTAssertFalse(state.detail.localizedCaseInsensitiveContains("sync"))
            XCTAssertFalse(state.detail.localizedCaseInsensitiveContains("available after"))
        }

        XCTAssertEqual(PlainpostDestination.drafts.utilityState.actionTitle, "New Draft")
        for destination in destinations where destination != .drafts {
            XCTAssertNil(destination.utilityState.actionTitle)
        }
    }

    func testApprovalDetailContentWidthRemainsReadableAndResponsive() {
        XCTAssertEqual(ApprovalDetailLayout.contentWidth(availableWidth: 1_700), 960)
        XCTAssertEqual(ApprovalDetailLayout.contentWidth(availableWidth: 700), 644)
        XCTAssertEqual(ApprovalDetailLayout.contentWidth(availableWidth: 40), 0)
    }

    func testComposerOnlyRevealsOptionalRecipientFieldsWhenTheyContainRecipients() {
        XCTAssertFalse(ComposerAddressFields.shouldRevealRecipientField(""))
        XCTAssertFalse(ComposerAddressFields.shouldRevealRecipientField("  \n"))
        XCTAssertTrue(ComposerAddressFields.shouldRevealRecipientField("max@example.com"))
    }

    func testMessageListRowAccessibilityDescribesUnreadAndSelectedState() throws {
        let row = try XCTUnwrap(InboxViewModel.designPreview().classicRows.first)

        XCTAssertEqual(
            MessageListRow.accessibilityLabel(for: row),
            "\(MailSenderIdentity(sender: row.sender, displayName: row.senderDisplayName).displayName), \(row.subject)"
        )

        let selectedValue = MessageListRow.accessibilityValue(for: row, selected: true)
        XCTAssertTrue(selectedValue.contains(row.isUnread ? "Unread" : "Read"))
        XCTAssertTrue(selectedValue.contains("Selected"))
        XCTAssertTrue(selectedValue.contains(row.categoryLabel))
        XCTAssertTrue(selectedValue.contains(row.dateLabel))
        XCTAssertTrue(selectedValue.contains(row.preview))

        let unselectedValue = MessageListRow.accessibilityValue(for: row, selected: false)
        XCTAssertFalse(unselectedValue.contains("Selected"))
    }

    func testApprovalViewsHaveBodyForEveryFilterAndRequestState() {
        let viewModel = ApprovalQueueViewModel.preview()
        let items = viewModel.items

        for filter in ApprovalQueueFilter.defaultFilters {
            evaluate(ApprovalQueueWorkspace(viewModel: viewModel, selectedFilter: .constant(filter)))
            evaluate(ApprovalFilterColumn(selectedFilter: .constant(filter), items: items))
        }

        let selectedRequestID: String? = items.first?.id
        evaluate(
            ApprovalRequestList(
                items: [],
                selectedRequestID: .constant(selectedRequestID),
                isWorking: false,
                statusMessage: nil
            )
        )
        evaluate(
            ApprovalRequestList(
                items: items,
                selectedRequestID: .constant(selectedRequestID),
                isWorking: true,
                statusMessage: nil
            )
        )
        evaluate(
            ApprovalRequestList(
                items: items,
                selectedRequestID: .constant(selectedRequestID),
                isWorking: false,
                statusMessage: "Failed to refresh"
            )
        )

        for item in items {
            evaluate(ApprovalRequestRow(item: item, selected: item.id == selectedRequestID, action: {}))
            evaluate(ApprovalDetailPane(item: item, viewModel: viewModel))
            evaluate(ApprovalReviewBar(item: item))
        }
        evaluate(
            ApprovalRequestRow(
                item: ApprovalQueueItemModel(
                    id: "failed",
                    agentName: "Agent",
                    subject: "Failed send",
                    recipientSummary: "external@example.com",
                    riskFlags: ["External recipients"],
                    hasAttachments: false,
                    status: "failed"
                ),
                selected: false,
                action: {}
            )
        )
        evaluate(ApprovalDetailPane(item: nil, viewModel: viewModel))
        evaluate(DetailLine("Label", "Value"))
        evaluate(AttachmentRow(name: "Report.pdf", detail: "10 KB"))
        evaluate(AttachmentRow(name: "Data.xlsx", detail: "12 KB"))
        evaluate(TimelineLine("Today", "Created"))

        XCTAssertEqual(ApprovalQueueFilter.defaultFilters, [.pending, .failed, .all])
    }

    func testComposerAndSharedPanelsHaveBodyForPrimaryStates() {
        let composer = ComposerViewModel.preview()
        let auditLog = AuditLogViewModel.preview()
        let commandCenter = CommandCenterViewModel.preview()

        evaluate(ComposerWindow(viewModel: composer, close: {}))
        evaluate(ComposerHeader(mode: .reply(recipient: "alex@example.com", subject: "Quarterly planning"), close: {}))
        evaluate(
            ComposerAddressFields(
                to: .constant("alex@example.com"),
                cc: .constant(""),
                bcc: .constant(""),
                subject: .constant("Re: Quarterly planning")
            )
        )
        evaluate(ComposerFieldLabel("Subject"))
        evaluate(ComposerBodyEditor(bodyMarkdown: .constant(""), placeholder: "Write your message..."))
        evaluate(ComposerCommandBar(viewModel: composer))
        evaluate(CommandCenterPanel(viewModel: commandCenter))
        evaluate(CommandCenterHeader(commandCount: commandCenter.commands.count))
        evaluate(CommandCenterSearchField(query: .constant("draft"), resultCount: 2))
        evaluate(CommandCenterCategoryHeader(category: .navigation, count: 4))
        evaluate(CommandCenterRow(command: CommandCenterViewModel.defaultCommands[0], highlighted: true, action: {}))
        evaluate(CommandCenterKeycap("Return", highlighted: true))
        evaluate(CommandCenterFooter())
        commandCenter.query = "no matching command"
        evaluate(CommandCenterPanel(viewModel: commandCenter))
        evaluate(PrivacySettingsPage())
        evaluate(NotificationsSettingsPage())
        evaluate(AIIndexStatusWorkspace(status: inbox().aiIndexStatus))
        evaluate(SettingsToggleRow(title: "New messages", detail: "Show an alert for newly delivered mail.", symbol: "envelope.badge", isOn: .constant(true)))
        evaluate(DisabledSettingsToggleRowSmokeView())
        evaluate(SystemSettingsValueRow(title: "Passwords", systemImage: "key.fill", tint: .orange, value: "macOS Keychain"))
        evaluate(SystemSettingsValueRow(title: "AI index", systemImage: "sparkles", tint: MailDesign.accentTeal, value: "Local"))
        evaluate(SettingsRowIcon(symbol: "bell", tint: MailDesign.accentBlue))
        evaluate(
            TroubleshootingSettingsPage(
                auditLog: auditLog,
                maintenance: .preview(),
                accountSetup: .preview(),
                searchIndexRebuild: MailSearchIndexRebuildController()
            )
        )
        evaluate(TroubleshootingRecentEventsPage(auditLog: auditLog))
        evaluate(EmptyState(title: "No messages", detail: "Messages will appear here."))
        evaluate(WorkflowStateBanner(title: "Connected", detail: "Account ready", symbol: "checkmark.circle", tint: .green))
        evaluate(MailAvatar(text: "Me", category: .personal, size: 36))
        evaluate(MailField("Field", text: .constant("value"), width: 120))
        evaluate(MailDivider())

        XCTAssertTrue(composer.canSaveDraft)
    }

    func testSettingsPanelsConstruct() throws {
        let pagedDiagnostics = AuditLogViewModel(
            log: EmptyDiagnosticsAuditLog(),
            operationRows: [
                OperationActivityRowModel(
                    id: "job_completed_preview",
                    title: "Classified Smart Inbox",
                    state: .completed,
                    phase: "Completed",
                    detail: "Smart Inbox",
                    providerID: "foundation",
                    modelID: "apple-foundation-system",
                    accountEmail: "preview@example.com",
                    resultDetail: nil,
                    current: 1,
                    total: 1,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 2),
                    attempt: 1,
                    maxAttempts: 3,
                    terminalOccurrenceAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )
        evaluate(
            TroubleshootingSettingsPage(
                auditLog: pagedDiagnostics,
                maintenance: .preview(),
                accountSetup: .preview(),
                searchIndexRebuild: MailSearchIndexRebuildController()
            )
        )

        let source = try plainpostSettingsSource("Settings/TroubleshootingSettingsPage.swift")
        XCTAssertTrue(source.contains("DiagnosticsRecentEventsScroll"))
        XCTAssertTrue(source.contains("DiagnosticsEventsNewer"))
        XCTAssertTrue(source.contains("DiagnosticsEventsOlder"))
    }

    func testLabelCommandCenterPanelConstructsForEmptyAndPopulatedStates() async throws {
        let emptyModel = MessageLabelCommandCenterViewModel()
        emptyModel.open(
            context: .init(
                messageID: "empty",
                sender: "Sender",
                subject: "No labels yet"
            )
        )
        evaluate(
            MessageLabelCommandCenterPanel(
                viewModel: emptyModel,
                labelActions: .preview(),
                reduceMotion: false
            )
        )

        let populatedActions = MessageLabelActions(
            loadItems: { _ in
                [
                    MessageLabelMenuItem(
                        label: try .validated(
                            id: "news",
                            title: "Newsletters",
                            description: "",
                            isSmartInboxEnabled: false,
                            scope: .allAccounts
                        ),
                        sources: [.user],
                        isExcluded: false,
                        ruleNames: [:]
                    ),
                ]
            },
            mutate: { _, _, _ in }
        )
        _ = activateLabelActions(populatedActions, messageID: "populated")
        await populatedActions.refresh(messageID: "populated")
        let populatedModel = MessageLabelCommandCenterViewModel()
        populatedModel.open(
            context: .init(
                messageID: "populated",
                sender: "Platformatic",
                subject: "A labelled message"
            )
        )
        evaluate(
            MessageLabelCommandCenterPanel(
                viewModel: populatedModel,
                labelActions: populatedActions,
                reduceMotion: true
            )
        )
    }

    func testUndoSendAndToolbarStatusViewsHaveBodiesForAllStates() {
        let snapshot = ComposerRestoreSnapshot.preview()

        evaluate(ComposerToolbarStatusCapsule(isWorking: true, message: "Saving draft"))
        evaluate(ComposerToolbarStatusCapsule(isWorking: false, message: "Sent"))
        evaluate(
            UndoSendSnackbar(
                state: .pending(snapshot: snapshot, deadline: .now.addingTimeInterval(10)),
                undo: {}
            )
        )
        let sendingSnackbar = UndoSendSnackbar(state: .sending, undo: {})
        XCTAssertNil(sendingSnackbar.actionTitle)
        evaluate(sendingSnackbar)
        evaluate(UndoSendSnackbar(state: .failed(snapshot: snapshot), undo: {}))
        evaluate(UndoSendSnackbar(state: .sent, undo: {}))
    }

    func testUndoSendSnackbarOnlyOffersUndoBeforeItsDeadline() {
        let snapshot = ComposerRestoreSnapshot.preview()
        let deadline = Date(timeIntervalSinceReferenceDate: 1_000)

        let activeSnackbar = UndoSendSnackbar(
            state: .pending(snapshot: snapshot, deadline: .distantFuture),
            undo: {}
        )
        let expiredSnackbar = UndoSendSnackbar(
            state: .pending(snapshot: snapshot, deadline: .distantPast),
            undo: {}
        )

        XCTAssertEqual(activeSnackbar.actionTitle, "Undo")
        XCTAssertNil(expiredSnackbar.actionTitle)

        let beforeDeadline = UndoSendPendingPresentation(
            deadline: deadline,
            date: deadline.addingTimeInterval(-0.1)
        )
        let atDeadline = UndoSendPendingPresentation(deadline: deadline, date: deadline)

        XCTAssertEqual(beforeDeadline.message, "Sending in 1s")
        XCTAssertEqual(beforeDeadline.actionTitle, "Undo")
        XCTAssertEqual(atDeadline.message, "Sending…")
        XCTAssertNil(atDeadline.actionTitle)
    }

    func testUndoSendSnackbarTimelineStartsTenSecondsBeforeDeadline() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            UndoSendSnackbar.timelineStart(deadline: deadline),
            deadline.addingTimeInterval(-10)
        )
    }

    private func evaluate<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
        _ = view.body
        XCTAssertTrue(true, file: file, line: line)
    }

    private func activateLabelActions(
        _ actions: MessageLabelActions,
        messageID: String
    ) -> MessageLabelAppearanceToken {
        actions.transitionMailboxSurface(to: "smartInbox")
        guard let appearance = actions.beginAppearance(messageID: messageID) else {
            preconditionFailure("Expected an active label surface.")
        }
        return appearance
    }

    private struct ReflectedViewNode {
        let typeName: String
        let value: Any
    }

    private struct CredentialFieldStructure: Equatable {
        let label: String
        let prompt: String
        let accessibilityLabel: String
        let identifier: String
    }

    private struct AccessibleTextStructure: Equatable {
        let text: String
        let accessibilityLabel: String
        let identifier: String
    }

    private struct CredentialUpdateStructure: Equatable {
        let title: String
        let identifier: String
        let isDisabled: Bool
    }

    private struct CredentialReplacementStructure {
        let fields: [CredentialFieldStructure]
        let help: AccessibleTextStructure?
        let update: CredentialUpdateStructure
    }

    private struct AccountDeletionButtonStructure {
        let title: String
        let accessibilityLabel: String
        let identifier: String
        let isDisabled: Bool
        let isDestructive: Bool
    }

    private struct AccountDeletionDangerStructure {
        let notice: AccessibleTextStructure?
        let open: AccountDeletionButtonStructure
    }

    private struct AccountDeletionConfirmationStructure {
        let cancel: AccountDeletionButtonStructure
        let confirm: AccountDeletionButtonStructure
    }

    private struct AccessibilityMetadata {
        let label: String?
        let identifier: String?
    }

    private func credentialReplacementStructure(
        in section: CredentialReplacementSection
    ) throws -> CredentialReplacementStructure {
        let nodes = reflectedViewNodes(in: section.body)
        let fields = nodes.compactMap { credentialFieldStructure(in: $0.value) }
        let help = nodes.compactMap { accessibleTextStructure(in: $0.value) }
            .first { $0.identifier == "credential-replacement-help" }
        let update = try XCTUnwrap(
            nodes.compactMap { credentialUpdateStructure(in: $0.value) }.first
        )
        return CredentialReplacementStructure(fields: fields, help: help, update: update)
    }

    private func accountDeletionDangerStructure(
        in section: AccountDeletionDangerSection
    ) throws -> AccountDeletionDangerStructure {
        let nodes = reflectedViewNodes(in: section.body)
        let buttons = nodes.compactMap { accountDeletionButtonStructure(in: $0.value) }
        let open = try XCTUnwrap(
            buttons.first { $0.identifier == "account-deletion-open-confirmation" }
        )
        let notice = firstReflectedValue(of: AccountDeletionStatusNotice.self, in: section.body)
            .map { reflectedViewNodes(in: $0.body) }?
            .compactMap { accessibleTextStructure(in: $0.value) }
            .first { $0.identifier == "account-deletion-status" }
        return AccountDeletionDangerStructure(
            notice: notice,
            open: open
        )
    }

    private func accountDeletionConfirmationStructure(
        in actions: AccountDeletionConfirmationActions
    ) throws -> AccountDeletionConfirmationStructure {
        let buttons = reflectedViewNodes(in: actions.body)
            .compactMap { accountDeletionButtonStructure(in: $0.value) }
        return AccountDeletionConfirmationStructure(
            cancel: try XCTUnwrap(
                buttons.first { $0.identifier == "account-deletion-cancel" }
            ),
            confirm: try XCTUnwrap(
                buttons.first { $0.identifier == "account-deletion-confirm" }
            )
        )
    }

    private func accountDeletionButtonStructure(
        in value: Any
    ) -> AccountDeletionButtonStructure? {
        guard
            let button = firstReflectedValue(of: Button<Text>.self, in: value),
            let titleValue = Mirror(reflecting: button).children
                .first(where: { $0.label == "label" })?.value,
            let title = reflectedStrings(in: titleValue).first,
            let accessibility = accessibilityMetadata(in: value),
            let identifier = accessibility.identifier
        else { return nil }
        // A button without its own accessibility label is read by its title.
        let accessibilityLabel = accessibility.label ?? title
        let roleDescription = Mirror(reflecting: button).children
            .first(where: { $0.label == "role" })
            .map { String(reflecting: $0.value) } ?? ""
        return AccountDeletionButtonStructure(
            title: title,
            accessibilityLabel: accessibilityLabel,
            identifier: identifier,
            isDisabled: standardDisabledValue(in: value) ?? false,
            isDestructive: roleDescription.localizedCaseInsensitiveContains("destructive")
        )
    }

    private func credentialFieldStructure(in value: Any) -> CredentialFieldStructure? {
        let mirror = Mirror(reflecting: value)
        guard
            let label = mirror.children.first(where: { $0.label == "label" })?.value as? Text,
            let content = mirror.children.first(where: { $0.label == "content" })?.value,
            let field = firstReflectedValue(of: SecureField<Text>.self, in: content),
            allReflectedValues(of: SecureField<Text>.self, in: content).count == 1,
            let labelText = reflectedStrings(in: label).first,
            let promptValue = Mirror(reflecting: field).children.first(where: { $0.label == "label" })?.value,
            let prompt = reflectedStrings(in: promptValue).first,
            let accessibility = accessibilityMetadata(in: content),
            let accessibilityLabel = accessibility.label,
            let identifier = accessibility.identifier
        else { return nil }
        return CredentialFieldStructure(
            label: labelText,
            prompt: prompt,
            accessibilityLabel: accessibilityLabel,
            identifier: identifier
        )
    }

    private func accessibleTextStructure(in value: Any) -> AccessibleTextStructure? {
        let mirror = Mirror(reflecting: value)
        guard
            let text = mirror.children.first(where: { $0.label == "content" })?.value as? Text,
            let modifier = mirror.children.first(where: { $0.label == "modifier" })?.value,
            String(reflecting: type(of: modifier)) == "SwiftUI.AccessibilityAttachmentModifier",
            let displayedText = reflectedStrings(in: text).first,
            let accessibility = accessibilityMetadata(in: modifier),
            let accessibilityLabel = accessibilityTextLabel(in: text) ?? accessibility.label,
            let identifier = accessibility.identifier
        else { return nil }
        return AccessibleTextStructure(
            text: displayedText,
            accessibilityLabel: accessibilityLabel,
            identifier: identifier
        )
    }

    private func accessibilityTextLabel(in text: Text) -> String? {
        guard let attributes = reflectedViewNodes(in: text).first(where: {
            $0.typeName == "SwiftUI.AccessibilityTextAttributes"
        })?.value else { return nil }
        return Mirror(reflecting: attributes).children
            .first(where: { $0.label == "label" })
            .flatMap { reflectedStrings(in: $0.value).first }
    }

    private func credentialUpdateStructure(in value: Any) -> CredentialUpdateStructure? {
        let mirror = Mirror(reflecting: value)
        guard
            let content = mirror.children.first(where: { $0.label == "content" })?.value,
            let modifier = mirror.children.first(where: { $0.label == "modifier" })?.value,
            String(reflecting: type(of: modifier)) == "SwiftUI.AccessibilityAttachmentModifier",
            let button = firstReflectedValue(of: Button<Text>.self, in: content),
            let titleValue = Mirror(reflecting: button).children.first(where: { $0.label == "label" })?.value,
            let title = reflectedStrings(in: titleValue).first,
            let accessibility = accessibilityMetadata(in: modifier),
            let identifier = accessibility.identifier,
            let disabled = standardDisabledValue(in: content)
        else { return nil }
        return CredentialUpdateStructure(title: title, identifier: identifier, isDisabled: disabled)
    }

    private func accessibilityMetadata(in value: Any) -> AccessibilityMetadata? {
        let propertyValues = reflectedViewNodes(in: value)
            .filter { $0.typeName == "SwiftUI.AccessibilityProperties" }
            .map(\.value)
        guard !propertyValues.isEmpty else { return nil }
        let propertyChildren = propertyValues.map { Mirror(reflecting: $0).children }
        return AccessibilityMetadata(
            label: propertyChildren.lazy.compactMap { children in
                children.first(where: { $0.label == "label" })
                    .flatMap { self.reflectedStrings(in: $0.value).first }
            }.first,
            identifier: propertyChildren.lazy.compactMap { children in
                children.first(where: { $0.label == "identifier" })
                    .flatMap { self.reflectedStrings(in: $0.value).first }
            }.first
        )
    }

    private func standardDisabledValue(in value: Any) -> Bool? {
        guard let modifier = reflectedViewNodes(in: value).first(where: {
            $0.typeName == "SwiftUI._EnvironmentKeyTransformModifier<Swift.Bool>"
        })?.value else { return nil }
        guard let transform = Mirror(reflecting: modifier).children
            .first(where: { $0.label == "transform" })?.value as? (inout Bool) -> Void
        else { return nil }
        var isEnabled = true
        transform(&isEnabled)
        return !isEnabled
    }

    private func firstReflectedValue<T>(of targetType: T.Type, in value: Any, depth: Int = 0) -> T? {
        if let typed = value as? T {
            return typed
        }
        guard depth < 24, !String(reflecting: type(of: value)).contains("AccountSetupViewModel") else {
            return nil
        }
        for child in Mirror(reflecting: value).children {
            if let typed = firstReflectedValue(of: targetType, in: child.value, depth: depth + 1) {
                return typed
            }
        }
        return nil
    }

    private func allReflectedValues<T>(of targetType: T.Type, in value: Any, depth: Int = 0) -> [T] {
        let current = (value as? T).map { [$0] } ?? []
        guard depth < 24, !String(reflecting: type(of: value)).contains("AccountSetupViewModel") else {
            return current
        }
        return current + Mirror(reflecting: value).children.flatMap {
            allReflectedValues(of: targetType, in: $0.value, depth: depth + 1)
        }
    }

    private func reflectedStrings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        if let string = value as? String {
            return [string]
        }
        return Mirror(reflecting: value).children.flatMap {
            reflectedStrings(in: $0.value, depth: depth + 1)
        }
    }

    private func reflectedViewNodes(in value: Any, depth: Int = 0) -> [ReflectedViewNode] {
        let typeName = String(reflecting: type(of: value))
        let current = ReflectedViewNode(typeName: typeName, value: value)
        guard depth < 24, !typeName.contains("AccountSetupViewModel") else {
            return [current]
        }
        return [current] + Mirror(reflecting: value).children.flatMap {
            reflectedViewNodes(in: $0.value, depth: depth + 1)
        }
    }

#if os(macOS)
    private struct HostedRoot {
        let sidebarView: NSView
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>
    }

    private struct HostedView {
        let containerView: NSView
        let hostingView: NSHostingView<AnyView>
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func readerPanel(id: String, in hosted: HostedView) -> NSView? {
        descendants(of: hosted.hostingView).first {
            $0.identifier?.rawValue == id
        }
    }

    private func nativeToolbarView(in window: NSWindow) -> NSView? {
        window.accessibilityChildren()?
            .compactMap { $0 as? NSView }
            .first {
                String(describing: type(of: $0)).contains("NSToolbarView")
            }
    }

    private func toolbarPlatterFrames(in toolbarView: NSView) -> [NSRect] {
        toolbarPlatters(in: toolbarView)
            .map { $0.convert($0.bounds, to: toolbarView) }
    }

    private func toolbarPlatters(in toolbarView: NSView) -> [NSView] {
        descendants(of: toolbarView)
            .filter {
                String(describing: type(of: $0)).contains("NSToolbarPlatterView")
            }
            .sorted(by: { $0.frame.minX < $1.frame.minX })
    }

    private func hostRoot<V: View>(
        _ view: V,
        size: NSSize = NSSize(width: 900, height: 640)
    ) -> HostedRoot {
        let hostingView = NSHostingView(
            rootView: AnyView(view.frame(width: size.width, height: size.height))
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hostingView
        window.orderFront(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        Self.retainedHostedWindows.append(window)

        let sidebarView = descendants(of: hostingView).first {
            String(describing: type(of: $0)).contains("SidebarStyleContext")
        } ?? NSView()

        return HostedRoot(
            sidebarView: sidebarView,
            window: window,
            hostingView: hostingView
        )
    }

    private func hostFixedWidth<V: View>(_ view: V, width: CGFloat) -> HostedView {
        let size = NSSize(width: width, height: 640)
        let hostingView = NSHostingView(
            rootView: AnyView(view.frame(width: size.width, height: size.height))
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let containerView = NSView(frame: NSRect(origin: .zero, size: size))
        containerView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentMinSize = size
        window.contentMaxSize = size
        window.contentView = containerView
        window.setContentSize(size)
        window.orderFront(nil)
        window.layoutIfNeeded()
        containerView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        Self.retainedHostedWindows.append(window)
        return HostedView(
            containerView: containerView,
            hostingView: hostingView
        )
    }

    private func plainpostNativeViewsSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/PlainpostUI/PlainpostNativeViews.swift"),
            encoding: .utf8
        )
    }

    private func plainpostSharedViewsSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/PlainpostUI/PlainpostSharedViews.swift"),
            encoding: .utf8
        )
    }

    private func plainpostSettingsSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/PlainpostUI")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func openMessageRow(named label: String, in hosted: HostedRoot) throws {
        let messageRows = descendants(of: hosted.hostingView)
            .filter { String(describing: type(of: $0)).contains("ListTableRowView") }
        let messageRow = try XCTUnwrap(
            messageRows.first { row in
                let frame = hosted.hostingView.convert(row.bounds, from: row)
                return frame.minX > 200 && frame.width > 400 && frame.height > 20
            },
            "Expected a native message-list row for \(label)."
        )
        hosted.window.makeKeyAndOrderFront(nil)
        sendNativeClick(to: messageRow, in: hosted.window)
        drainNativeLayout(for: hosted)
    }

    private func returnToMailboxList(
        in hosted: HostedRoot,
        toolbar: NSToolbar
    ) throws {
        let backItem = try XCTUnwrap(
            toolbar.items.first { $0.label == "Back" },
            "Expected the reader toolbar Back item."
        )
        XCTAssertEqual(backItem.label, "Back")
        sendNativeKey(
            "[",
            modifiers: .command,
            keyCode: 33,
            to: hosted.window
        )
        drainNativeLayout(for: hosted)
    }

    private func assertReaderToolbarActionGroups(
        in hosted: HostedRoot,
        toolbar: NSToolbar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toolbarView = nativeToolbarView(in: hosted.window)
        XCTAssertNotNil(toolbarView, file: file, line: line)
        guard let toolbarView else { return }
        let flexibleSpacerIndex = toolbar.items.lastIndex {
            $0.itemIdentifier == .flexibleSpace
        }
        let trailingActionItems = flexibleSpacerIndex.map {
            toolbarActionItems(after: $0, in: toolbar)
        } ?? []
        let trailingActionFrames = Array(
            toolbarPlatterFrames(in: toolbarView)
                .suffix(trailingActionItems.count)
        )

        XCTAssertFalse(
            toolbar.items.contains {
                [
                    "mailbox.message-actions",
                    "mailbox.global-actions",
                ].contains($0.itemIdentifier.rawValue)
            },
            "Dynamic reader actions must not opt into NSToolbar customization.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            trailingActionItems.count,
            2,
            "Reader state must contain only contextual and global action items after the flexible spacer.",
            file: file,
            line: line
        )
        XCTAssertEqual(trailingActionFrames.count, 2, file: file, line: line)
        guard trailingActionFrames.count == 2 else { return }
        XCTAssertNotNil(flexibleSpacerIndex, file: file, line: line)
    }

    private func toolbarActionItems(
        after flexibleSpacerIndex: Int,
        in toolbar: NSToolbar
    ) -> [NSToolbarItem] {
        toolbar.items
            .dropFirst(flexibleSpacerIndex + 1)
            .filter {
                $0.itemIdentifier != .space
                    && $0.itemIdentifier != .flexibleSpace
            }
    }

    private func drainNativeLayout(for hosted: HostedRoot) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosted.window.layoutIfNeeded()
        hosted.hostingView.layoutSubtreeIfNeeded()
    }

    private func sendNativeClick(to view: NSView, in window: NSWindow) {
        let pointInWindow = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func sendNativeKey(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        to window: NSWindow
    ) {
        let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
        let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func splitViewFrames<V: View>(for view: V, size: NSSize) -> [NSRect] {
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        return descendants(of: hostingView).compactMap { ($0 as? NSSplitView)?.frame }
    }

#endif

    private func inbox(
        requiresAccountSetup: Bool = false,
        hasMoreRows: Bool = false,
        mailboxRevision: UInt64 = 0
    ) -> InboxViewModel {
        let preview = InboxViewModel.designPreview()
        return InboxViewModel(
            chrome: preview.chrome,
            sidebarItems: preview.sidebarItems,
            smartCards: preview.smartCards,
            classicRows: preview.classicRows,
            selectedThread: preview.selectedThread,
            aiIndexStatus: preview.aiIndexStatus,
            requiresAccountSetup: requiresAccountSetup,
            hasMoreRows: hasMoreRows,
            mailboxRevision: mailboxRevision
        )
    }

    private func inbox(rows: [MessageRowModel]) -> InboxViewModel {
        let base = InboxViewModel.loading(requiresAccountSetup: false)
        return InboxViewModel(
            chrome: base.chrome,
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: SidebarUnreadCounts(rows: rows),
                pendingApprovalCount: 0
            ),
            smartCards: SmartInboxCardModel.cards(from: rows),
            classicRows: rows,
            selectedThread: base.selectedThread,
            aiIndexStatus: base.aiIndexStatus
        )
    }

    func testNativeMessageRowForwardsItsContextActionToTheProvidedSharedHandler() {
        var received: (InboxMailAction, String)?
        let row = MailMessageListRow(
            row: unreadRow(id: "msg_1"),
            selected: false,
            mailActions: .preview(),
            performMessageAction: { action, id in received = (action, id) }
        )

        row.perform(.archive)

        XCTAssertEqual(received?.0, .archive)
        XCTAssertEqual(received?.1, "msg_1")
    }

    func testNativeRowAccessibilityPresentationUsesThePrecomputedSenderIdentity() {
        let row = unreadRow(id: "msg_accessibility")
        let senderIdentity = MailSenderIdentity(
            sender: row.sender,
            displayName: row.senderDisplayName
        )

        let presentation = MessageRowPersistentAccessibilityPresentation.resolve(
            row: row,
            senderIdentity: senderIdentity,
            selected: false
        )

        XCTAssertEqual(
            presentation.label,
            "\(senderIdentity.displayName), \(row.subject)"
        )
        XCTAssertEqual(
            presentation.value,
            MessageListRow.accessibilityValue(for: row, selected: false)
        )
    }

    func testOrdinaryRowRoutesActivationAndQuickActionsIndependently() {
        var openedMessageIDs: [String] = []
        var openedLabelMessageIDs: [String] = []
        var performedActions: [(InboxMailAction, String)] = []
        let row = MailMessageListRow(
            row: unreadRow(id: "msg_routing"),
            selected: true,
            widthClass: .wide,
            mailActions: .preview(),
            openMessage: { openedMessageIDs.append($0) },
            openLabelCommandCenter: { openedLabelMessageIDs.append($0.id) },
            performMessageAction: { performedActions.append(($0, $1)) }
        )

        row.perform(.archive)

        XCTAssertTrue(openedMessageIDs.isEmpty)
        XCTAssertEqual(performedActions.map(\.0), [.archive])
        XCTAssertEqual(performedActions.map(\.1), ["msg_routing"])

        row.openLabels()

        XCTAssertTrue(openedMessageIDs.isEmpty)
        XCTAssertEqual(openedLabelMessageIDs, ["msg_routing"])
        XCTAssertEqual(performedActions.map(\.0), [.archive])

        row.activate()

        XCTAssertEqual(openedMessageIDs, ["msg_routing"])
        XCTAssertEqual(performedActions.map(\.0), [.archive])
        XCTAssertEqual(
            row.controlPresentation,
            .siblingActivationReadStateAndQuickActions
        )
        XCTAssertFalse(row.controlPresentation.hasNestedButtons)
        XCTAssertFalse(row.controlPresentation.usesParentTapGesture)
        XCTAssertTrue(row.controlPresentation.supportsKeyboardActivation)
        XCTAssertTrue(row.controlPresentation.quickActionsAreKeyboardReachable)
    }

    func testUnreadToggleRoutesReadStateWithoutOpeningTheMessage() {
        var openedMessageIDs: [String] = []
        var performedActions: [(InboxMailAction, String)] = []
        let row = MailMessageListRow(
            row: unreadRow(id: "msg_toggle"),
            selected: false,
            widthClass: .wide,
            mailActions: .preview(),
            openMessage: { openedMessageIDs.append($0) },
            performMessageAction: { performedActions.append(($0, $1)) }
        )

        row.toggleReadState()

        XCTAssertTrue(openedMessageIDs.isEmpty)
        XCTAssertEqual(performedActions.map(\.0), [.markRead])
        XCTAssertEqual(performedActions.map(\.1), ["msg_toggle"])

        row.activate()

        XCTAssertEqual(openedMessageIDs, ["msg_toggle"])
        XCTAssertEqual(performedActions.map(\.0), [.markRead])
        XCTAssertEqual(
            row.controlPresentation,
            .siblingActivationReadStateAndQuickActions
        )
        XCTAssertFalse(row.controlPresentation.hasNestedButtons)
    }

    @MainActor
    func testUnreadToggleIsDisabledWhileTheMessageActionIsPending() async {
        let handler = ControlledInboxMailActionHandler()
        let actions = InboxMailActionViewModel(handler: handler)
        let actionTask = Task {
            await actions.perform(.markRead, messageID: "msg_pending_toggle")
        }
        await handler.waitUntilStarted()

        let row = MailMessageListRow(
            row: unreadRow(id: "msg_pending_toggle"),
            selected: false,
            mailActions: actions,
            performMessageAction: { _, _ in }
        )

        XCTAssertTrue(row.readStateToggleIsDisabled)

        await handler.succeed(
            .init(
                messageID: .init("msg_pending_toggle"),
                action: .markRead,
                seen: true
            )
        )
        _ = await actionTask.value

        XCTAssertFalse(row.readStateToggleIsDisabled)
    }

    func testLedgerMessageRowsRenderAtBothWidthClasses() {
        let model = unreadRow(id: "msg_ledger")
        for widthClass in [MailboxListWidthClass.wide, .narrow] {
            let row = MailMessageListRow(
                row: model,
                selected: widthClass == .wide,
                widthClass: widthClass,
                mailActions: .preview(),
                performMessageAction: { _, _ in }
            )
            evaluate(row)
            XCTAssertEqual(row.metadataSignals.items, [])
        }
    }

    func testSelectedLedgerRowsReplaceMetadataInsideAStableTrailingSlot() {
        let model = MessageRowModel(
            id: "msg_metadata",
            sender: "sender@example.com",
            subject: "Keep every trailing item",
            preview: "Actions must not replace metadata",
            category: .personal,
            categoryLabel: "Personal",
            smartPriority: .high,
            requiresAction: true,
            isUnread: true,
            isPinned: true,
            dateLabel: "10:45",
            actions: MessageRowActionModel.defaultActions(isUnread: true),
            threadMessageCount: 3
        )

        for widthClass in [MailboxListWidthClass.wide, .narrow] {
            let row = MailMessageListRow(
                row: model,
                selected: true,
                widthClass: widthClass,
                mailActions: .preview(),
                performMessageAction: { _, _ in }
            )

            XCTAssertTrue(row.trailingMetadataPresentation.showsQuickActions)
            XCTAssertEqual(
                row.trailingMetadataPresentation.signals.items.map(\.accessibilityLabel),
                ["High priority", "Needs action"]
            )
            XCTAssertTrue(row.trailingMetadataPresentation.isPinned)
            XCTAssertEqual(row.trailingMetadataPresentation.threadMessageCount, 3)
            XCTAssertEqual(row.trailingMetadataPresentation.dateLabel, "10:45")
            evaluate(row)
        }

        XCTAssertEqual(
            MailMessageListRow.quickActionAccessibilityLabels(hasEffectiveLabels: false),
            ["Archive", "Add a label", "Delete"]
        )
        XCTAssertEqual(
            MailMessageListRow.quickActionAccessibilityLabels(hasEffectiveLabels: true),
            ["Archive", "Add or remove labels", "Delete"]
        )
        XCTAssertTrue(
            MailMessageListRow.resolveShowsQuickActions(
                selected: false,
                hovered: false,
                hasQuickActionFocus: true
            )
        )
        XCTAssertEqual(MailboxRowQuickActionCapsule.labelSystemImage, "tag")
        XCTAssertEqual(
            MailMessageListRow.accessibilityHierarchy,
            .containActionControls
        )
    }

    @MainActor
    func testLedgerRowBuildsQuickActionControlsOnlyWhenActive() {
        let inactiveRow = MailMessageListRow(
            row: unreadRow(id: "msg_inactive_actions"),
            selected: false,
            widthClass: .wide,
            mailActions: .preview(),
            performMessageAction: { _, _ in }
        )
        let activeRow = MailMessageListRow(
            row: unreadRow(id: "msg_active_actions"),
            selected: true,
            widthClass: .wide,
            mailActions: .preview(),
            performMessageAction: { _, _ in }
        )
        let quickActionType = String(
            reflecting: MailboxRowQuickActionCapsule.self
        )
        let inactiveTypes = reflectedViewNodes(in: inactiveRow.body)
            .map(\.typeName)
        let activeTypes = reflectedViewNodes(in: activeRow.body).map(\.typeName)

        XCTAssertFalse(
            inactiveTypes.contains(quickActionType),
            "An inactive row must not construct its hidden quick-action controls."
        )
        XCTAssertTrue(
            activeTypes.contains(quickActionType),
            "An active row must construct its quick-action controls."
        )
    }

    @MainActor
    func testRequestedLabelFocusBuildsActionsAndConsumesTheRequest() {
        let focus = MailboxRowQuickActionFocusCoordinator()
        focus.requestLabelFocus(for: "msg_restore_label_focus")
        let row = MailMessageListRow(
            row: unreadRow(id: "msg_restore_label_focus"),
            selected: false,
            widthClass: .wide,
            mailActions: .preview(),
            quickActionFocus: focus,
            performMessageAction: { _, _ in }
        )

        let hosted = hostFixedWidth(row, width: 1_000)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosted.hostingView.layoutSubtreeIfNeeded()
        XCTAssertNil(focus.requestedLabelMessageID)
    }

    func testSelectedSoftLedgerRowsKeepAdaptiveAndSemanticForegroundRoles() {
        let presentation = MailboxRowForegroundPresentation.resolve(
            selected: true
        )

        XCTAssertEqual(presentation.primary, .adaptivePrimary)
        XCTAssertEqual(presentation.secondary, .adaptiveSecondary)
        XCTAssertEqual(presentation.unread, .accent)
        XCTAssertEqual(presentation.pinned, .warning)
        XCTAssertTrue(presentation.preservesSemanticSignalColors)
    }

    func testNativeMessageRowExposesTheSameVisibleSignalsAsItsAccessibilityValue() {
        let row = MessageRowModel(
            id: "msg_priority",
            sender: "sender@example.com",
            subject: "Review today",
            preview: "Please respond",
            category: .personal,
            categoryLabel: "Personal",
            smartPriority: .high,
            requiresAction: true,
            isUnread: true,
            isPinned: false,
            dateLabel: "10:00",
            actions: []
        )
        let nativeRow = MailMessageListRow(
            row: row,
            selected: false,
            mailActions: .preview(),
            performMessageAction: { _, _ in }
        )

        XCTAssertEqual(
            nativeRow.metadataSignals.items.map(\.accessibilityLabel),
            ["High priority", "Needs action"]
        )
        XCTAssertTrue(MessageListRow.accessibilityValue(for: row, selected: false).contains("High priority"))
        XCTAssertTrue(MessageListRow.accessibilityValue(for: row, selected: false).contains("Needs action"))
    }

    private func nativeMessageListColumn(
        mode: InboxDisplayMode,
        searchQuery: String,
        hasMoreRows: Bool = false,
        isLoadingMore: Bool = false,
        disabledMailboxSync: DisabledMailboxSyncPresentation? = nil
    ) -> MailMessageListColumn {
        MailMessageListColumn(
            viewModel: inbox(requiresAccountSetup: false, hasMoreRows: hasMoreRows),
            destination: .smartInbox,
            selectedInboxMode: .constant(mode.rawValue),
            searchQuery: searchQuery,
            selectedMessageID: .constant(nil),
            mailActions: .preview(),
            performMessageAction: { _, _ in },
            isLoadingMore: isLoadingMore,
            loadMore: {},
            disabledMailboxSync: disabledMailboxSync,
            enableMailboxSync: {}
        )
    }

    func testNativeMessageListExposesToolbarHeaderPresentation() {
        let column = nativeMessageListColumn(
            mode: .focusedList,
            searchQuery: ""
        )

        XCTAssertEqual(column.headerPresentation.title, "Smart Inbox")
        XCTAssertTrue(
            column.headerPresentation.conversationCountLabel
                .hasSuffix(" conversations")
        )
    }

    func testCompactMailboxToolbarPiecesConstructIndependently() {
        let presentation = MailboxHeaderPresentation(
            title: "Smart Inbox",
            conversationCountLabel: "480 conversations"
        )

        evaluate(MailboxHeaderIdentity(presentation: presentation))
        evaluate(
            MailboxHeaderModePicker(
                selectedInboxMode: .constant(
                    InboxDisplayMode.focusedList.rawValue
                )
            )
        )
        evaluate(
            MailboxGlobalActionGroup(
                controlSize: .small,
                compose: {},
                toggleAskMail: {},
                openCommandCenter: {}
            )
        )
    }

    private func unreadRow(id: String) -> MessageRowModel {
        MessageRowModel(
            id: id,
            sender: "sender@example.com",
            subject: id,
            preview: id,
            category: .personal,
            categoryLabel: "Personal",
            isUnread: true,
            isPinned: false,
            dateLabel: "",
            actions: MessageRowActionModel.defaultActions(isUnread: true)
        )
    }

    private func accountSetup(status: AccountSetupStatus) -> AccountSetupViewModel {
        AccountSetupViewModel(
            setup: SmokeAccountSetupService(),
            displayName: "Personal",
            email: "me@example.com",
            imapHost: "imap.example.com",
            imapPort: "993",
            smtpHost: "smtp.example.com",
            smtpPort: "587",
            username: "me@example.com",
            status: status,
            lastConnectedEmail: status == .connected(accountID: "acc_preview") ? "me@example.com" : nil,
            account: status == .connected(accountID: "acc_preview")
                ? Account(
                    id: AccountID("acc_preview"),
                    displayName: "Personal",
                    email: EmailAddress("me@example.com"),
                    imapHost: "imap.example.com",
                    imapPort: 993,
                    smtpHost: "smtp.example.com",
                    smtpPort: 587
                )
                : nil
        )
    }
}

@MainActor
private final class MailboxActionPresentationHarness {
    let actions: InboxMailActionViewModel
    let mutations = OptimisticMutationCoordinator<String>()
    let snapshot: InboxViewModelSnapshotStore
    private let overlayState: MailboxOverlayState
    private(set) var selectedMessageID: String?

    init(model: InboxViewModel, handler: InboxMailActionHandling, selectedMessageID: String?) {
        let overlayState = MailboxOverlayState()
        self.actions = InboxMailActionViewModel(handler: handler)
        self.overlayState = overlayState
        self.snapshot = InboxViewModelSnapshotStore(
            initialModel: model,
            provider: { _ in model },
            projector: { OptimisticMailboxProjection.project($0, overlays: overlayState.overlays) }
        )
        self.selectedMessageID = selectedMessageID
    }

    func perform(_ action: InboxMailAction, messageID: String) {
        let token = mutations.begin(for: messageID)
        let priorSelection = selectedMessageID
        overlayState.overlays[messageID] = .init(rowID: messageID, action: action)
        if action == .archive || action == .delete {
            selectedMessageID = nil
        }
        snapshot.reproject()

        Task {
            switch await actions.perform(action, messageID: messageID) {
            case .succeeded:
                guard mutations.resolve(token, as: .committed) == .committed else { return }
                overlayState.overlays[messageID] = nil
            case .failed:
                guard mutations.resolve(token, as: .rolledBack) == .rolledBack else { return }
                overlayState.overlays[messageID] = nil
                if selectedMessageID == nil {
                    selectedMessageID = priorSelection
                }
                snapshot.reproject()
            }
        }
    }
}

private final class MailboxOverlayState {
    var overlays: [String: OptimisticMailboxOverlay] = [:]
}

private actor ControlledInboxMailActionHandler: InboxMailActionHandling {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<InboxMailActionResult, Error>?
    private var hasStarted = false

    func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { resultContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeed(_ result: InboxMailActionResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

private actor SuspendedInboxLoadMoreProvider {
    let model: InboxViewModel
    private(set) var requestCount = 0
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resultContinuation: CheckedContinuation<InboxViewModel, Never>?

    init(model: InboxViewModel) {
        self.model = model
    }

    func load() async -> InboxViewModel {
        requestCount += 1
        resumeRequestWaiters()
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requestCount < expected else { return }
        await withCheckedContinuation { requestWaiters.append((expected, $0)) }
    }

    func resume() {
        resultContinuation?.resume(returning: model)
        resultContinuation = nil
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requestCount >= $0.0 }
        requestWaiters.removeAll { requestCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private struct DisabledSettingsToggleRowSmokeView: View {
    var body: some View {
        SettingsToggleRow(
            title: "Preview",
            detail: "Requires new-message alerts.",
            symbol: "text.bubble",
            isOn: .constant(false)
        )
        .disabled(true)
    }
}

private struct RecoverySheetDismissalHarness: View {
    @ObservedObject var model: AccountSecurityViewModel
    @State private var showsRecovery = true

    var body: some View {
        Text("Recovery required")
            .sheet(isPresented: $showsRecovery) {
                AccountRecoverySheet(model: model)
            }
    }
}

@MainActor
private func eventuallyRecoverySheet(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        await Task.yield()
    }
    return false
}

private func smokeDeletionAccount(id: String, email: String) -> Account {
    Account(
        id: AccountID(id),
        displayName: id,
        email: EmailAddress(email),
        username: email,
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )
}

private final class SmokeAccountList: @unchecked Sendable {
    private let lock = NSLock()
    private let accounts: [Account]

    init(_ accounts: [Account]) {
        self.accounts = accounts
    }

    func load() -> [Account] {
        lock.withLock { accounts }
    }
}

private actor SuspendedSettingsAccountDeleter {
    private(set) var requestCount = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func delete(_ accountID: AccountID) async {
        _ = accountID
        requestCount += 1
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeed() {
        completion?.resume()
        completion = nil
    }
}

private struct SmokeAccountSetupService: AccountSetupHandling {
    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        AccountSetupResult(
            account: Account(
                id: AccountID("acc_preview"),
                displayName: request.displayName,
                email: request.email,
                imapHost: request.imapHost,
                imapPort: request.imapPort,
                smtpHost: request.smtpHost,
                smtpPort: request.smtpPort
            ),
            imapVerified: true,
            smtpVerified: true
        )
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        IMAPSyncResult(syncedMessageCount: 0)
    }
}
