import Foundation
import XCTest
import PlainpostCore
import PlainpostDB
@testable import PlainpostUI
import PlainpostRuntimeTestSupport

@MainActor
final class MessageLabelActionsTests: XCTestCase {
    func testSelectedDirectAccountLabelActionsRejectForeignMessageID() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-label-actions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        for id in ["a", "b"] {
            let accountID = AccountID(id)
            try store.cacheAccountSetup(
                account: Account(id: accountID, displayName: id,
                                 email: EmailAddress("\(id)@example.com"),
                                 imapHost: "imap.example.com", smtpHost: "smtp.example.com"),
                inbox: Mailbox(id: MailboxID("\(id)-inbox"), accountID: accountID,
                               name: "Inbox", path: "INBOX", specialUse: nil),
                source: try AccountMailSource(
                    accountID: accountID, kind: .direct, mode: nil, nodeID: nil,
                    logicalMailboxID: nil, providerIdentity: nil, generation: 1
                )
            )
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID("\(id)-message"), threadID: nil,
                               from: EmailAddress("sender@example.com"),
                               subject: "Subject", preview: "Preview", smartCategory: .personal),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ), accountID: accountID, mailboxPath: "INBOX",
                uidValidity: 1, uid: 1, notificationEligible: false
            )
        }
        try store.saveMailLabel(try .validated(
            id: "travel", title: "Travel", description: "",
            isSmartInboxEnabled: false, scope: .allAccounts
        ))
        let actions = AccountBoundMessageLabelActionsFactory.make(
            store: store, selectedAccountID: AccountID("b"), sourceGeneration: 1
        )
        _ = activate(actions, messageID: "a-message")

        await actions.refresh(messageID: "a-message")
        await actions.setLabel("travel", on: "a-message", selected: true)

        XCTAssertTrue(actions.menuItems(for: "a-message").isEmpty)
        XCTAssertTrue(try store.labelAssignments(for: MessageID("a-message")).isEmpty)
        _ = activate(actions, messageID: "b-message")
        await actions.refresh(messageID: "b-message")
        await actions.setLabel("travel", on: "b-message", selected: true)
        XCTAssertEqual(try store.labelAssignments(for: MessageID("b-message")).map(\.labelID), ["travel"])
    }

    func testOwnerBoundLabelActionsLabelEachAccountsMessageAndRefuseAMovedAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let store = try fixture.store()
        try store.saveMailLabel(try .validated(
            id: "travel", title: "Travel", description: "",
            isSmartInboxEnabled: false, scope: .allAccounts
        ))
        let read: [AccountID: Int64] = [fixture.first.id: 1, fixture.second.id: 1]
        let actions = OwnerBoundMessageLabelActionsFactory.make(store: store, readGeneration: { _, owner in read[owner] })
        for messageID in ["msg_first_1", "msg_second_1"] {
            _ = activate(actions, messageID: messageID)
            await actions.refresh(messageID: messageID)
            await actions.setLabel("travel", on: messageID, selected: true)
            XCTAssertEqual(try store.labelAssignments(for: MessageID(messageID)).map(\.labelID), ["travel"], messageID)
        }
        try fixture.switchToNode(fixture.second)
        await actions.setLabel("travel", on: "msg_second_1", selected: false)
        XCTAssertEqual(try store.labelAssignments(for: MessageID("msg_second_1")).map(\.labelID), ["travel"])
    }

    func testSelectedDirectLabelActionsRejectCapturedGenerationAfterSourceRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-label-generation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("generation-account")
        let account = Account(
            id: accountID, displayName: "Generation",
            email: EmailAddress("generation@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let initialSource = try AccountMailSource(
            accountID: accountID, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("generation-inbox"), accountID: accountID,
                           name: "Inbox", path: "INBOX", specialUse: nil),
            source: initialSource
        )
        _ = try store.commitIncomingMessage(
            MessageSummary(id: MessageID("generation-message"), threadID: nil,
                           from: EmailAddress("sender@example.com"), subject: "Subject",
                           preview: "Preview", smartCategory: .personal),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ), accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationEligible: false
        )
        try store.saveMailLabel(try .validated(
            id: "travel", title: "Travel", description: "",
            isSmartInboxEnabled: false, scope: .allAccounts
        ))
        let actions = AccountBoundMessageLabelActionsFactory.make(
            store: store, selectedAccountID: accountID, sourceGeneration: 1
        )

        _ = activate(actions, messageID: "generation-message")
        await actions.refresh(messageID: "generation-message")
        XCTAssertFalse(actions.menuItems(for: "generation-message").isEmpty)
        let node = initialSource.nodeBacked(
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: account.email.rawValue
        )
        try store.replaceMailSource(node, expectedGeneration: 1)
        try store.replaceMailSource(node.revertedToDirect(), expectedGeneration: 2)

        let actor = Actor(
            id: "local-user", kind: .user, displayName: "Local User",
            permissions: .guiUser
        )
        XCTAssertThrowsError(try store.establishUserLabel(
            labelID: "travel", on: MessageID("generation-message"), actor: actor,
            selectedDirectSource: (accountID, 1)
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }

        await actions.refresh(messageID: "generation-message")
        await actions.setLabel("travel", on: "generation-message", selected: true)

        // The retained menu may still render its earlier snapshot, but its
        // captured mutation closure must refuse to apply it to generation 3.
        XCTAssertTrue(try store.labelAssignments(for: MessageID("generation-message")).isEmpty)
    }

    func testMenuSelectionAddsUserOwnerAndClearsExclusion() async throws {
        let fixture = try MessageLabelActionFixture(
            sources: [.smartInbox],
            excluded: true
        )

        await fixture.actions.setLabel("travel", on: fixture.messageID.rawValue, selected: true)

        XCTAssertEqual(fixture.store.sources(for: "travel"), [.user])
        XCTAssertFalse(fixture.store.isExcluded("travel"))
        XCTAssertTrue(fixture.actions.isEffectivelySelected("travel", on: fixture.messageID.rawValue))
    }

    func testDeselectRuleOwnedLabelLeavesItEffective() async throws {
        let fixture = try MessageLabelActionFixture(
            sources: [.user, .rule(ruleID: "r1")]
        )

        await fixture.actions.setLabel("travel", on: fixture.messageID.rawValue, selected: false)

        XCTAssertEqual(fixture.store.sources(for: "travel"), [.rule(ruleID: "r1")])
        XCTAssertTrue(fixture.actions.isEffectivelySelected("travel", on: fixture.messageID.rawValue))
    }

    func testMenuUsesOnlyGlobalAndMessageAccountDefinitions() async throws {
        let fixture = try MessageLabelActionFixture(
            sources: [],
            labels: [
                .validated(
                    id: "global",
                    title: "Global",
                    description: "",
                    isSmartInboxEnabled: false,
                    scope: .allAccounts
                ),
                .validated(
                    id: "account-a",
                    title: "Account A",
                    description: "",
                    isSmartInboxEnabled: false,
                    scope: .account(AccountID("a"))
                ),
                .validated(
                    id: "account-b",
                    title: "Account B",
                    description: "",
                    isSmartInboxEnabled: false,
                    scope: .account(AccountID("b"))
                ),
            ]
        )

        await fixture.actions.refresh(messageID: fixture.messageID.rawValue)

        XCTAssertEqual(
            fixture.actions.menuItems(for: fixture.messageID.rawValue).map(\.id),
            ["account-a", "global"]
        )
    }

    func testOwnershipHelpNamesEveryOwnerOnlyOnMenuItem() async throws {
        let fixture = try MessageLabelActionFixture(
            sources: [.user, .smartInbox, .rule(ruleID: "r1")],
            ruleNames: ["r1": "Travel alerts"]
        )

        await fixture.actions.refresh(messageID: fixture.messageID.rawValue)

        let item = try XCTUnwrap(
            fixture.actions.menuItems(for: fixture.messageID.rawValue).first
        )
        XCTAssertEqual(
            item.ownershipHelp,
            "Added manually, Added by Smart Inbox, Added by rule: Travel alerts"
        )
        XCTAssertTrue(item.hasUserOrSmartInboxOwnership)
        XCTAssertTrue(item.isEffective)
    }

    func testOwnershipHelpFallsBackToRuleIdentifierWhenRuleNameIsMissing() async throws {
        let fixture = try MessageLabelActionFixture(
            sources: [.rule(ruleID: "missing-rule")]
        )

        await fixture.actions.refresh(messageID: fixture.messageID.rawValue)

        let item = try XCTUnwrap(
            fixture.actions.menuItems(for: fixture.messageID.rawValue).first
        )
        XCTAssertEqual(item.ownershipHelp, "Added by rule: missing-rule")
    }

    func testScopedLabelPanelRoutesAddAndRemoveButIgnoresRuleOwnedCommands() async throws {
        let recorder = ScopedLabelMutationRecorder()
        let actions = MessageLabelActions(
            loadItems: { _ in [] },
            mutate: { labelID, messageID, selected in
                await recorder.record(
                    labelID: labelID,
                    messageID: messageID.rawValue,
                    selected: selected
                )
            }
        )
        _ = activate(actions, messageID: "m1")
        let model = MessageLabelCommandCenterViewModel()
        model.open(context: .init(messageID: "m1", sender: "A", subject: "B"))
        let panel = MessageLabelCommandCenterPanel(
            viewModel: model,
            labelActions: actions,
            reduceMotion: false
        )

        await panel.execute(
            MessageLabelCommand(
                labelID: "important",
                labelTitle: "Important",
                kind: .add,
                ownershipHelp: nil
            )
        )
        await panel.execute(
            MessageLabelCommand(
                labelID: "news",
                labelTitle: "Newsletters",
                kind: .remove,
                ownershipHelp: "Added manually"
            )
        )
        await panel.execute(
            MessageLabelCommand(
                labelID: "automation",
                labelTitle: "Automation",
                kind: .ruleOwned(ruleNames: ["Travel alerts"]),
                ownershipHelp: "Added by rule: Travel alerts"
            )
        )

        let mutations = await recorder.mutations
        XCTAssertEqual(
            mutations,
            [
                .init(labelID: "important", messageID: "m1", selected: true),
                .init(labelID: "news", messageID: "m1", selected: false),
            ]
        )
        XCTAssertTrue(model.isPresented)
    }

    func testDeletedDefinitionDisappearsSafelyAfterMutationRefresh() async throws {
        let fixture = try MessageLabelActionFixture(sources: [])
        await fixture.actions.refresh(messageID: fixture.messageID.rawValue)
        XCTAssertEqual(fixture.actions.menuItems(for: fixture.messageID.rawValue).map(\.id), ["travel"])
        fixture.store.deleteDefinition(id: "travel")

        await fixture.actions.setLabel("travel", on: fixture.messageID.rawValue, selected: true)

        XCTAssertTrue(fixture.actions.menuItems(for: fixture.messageID.rawValue).isEmpty)
        XCTAssertNil(fixture.actions.errorEvent)
    }

    func testInvalidationAdvancesRevisionAndRefreshesVisibleMessage() async throws {
        let loader = SequentialMessageLabelLoader(steps: [
            .items([try menuItem(id: "before", title: "Before")]),
            .items([try menuItem(id: "after", title: "After")]),
        ])
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        _ = activate(actions)
        await actions.refresh(messageID: "m1")
        let initialRevision = actions.revision

        actions.invalidate()
        await actions.refresh(messageID: "m1")

        XCTAssertEqual(actions.revision, initialRevision &+ 1)
        XCTAssertEqual(actions.menuItems(for: "m1").map(\.id), ["after"])
    }

    func testDisappearingRowEvictsItemsAndBlocksLatePublication() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        let appearance = activate(actions)
        let refresh = Task { await actions.refresh(messageID: "m1") }
        await loader.waitUntilStarted(callCount: 1)

        actions.endAppearance(appearance)
        await loader.complete(call: 0, with: .success([try menuItem(id: "late", title: "Late")]))
        await refresh.value

        XCTAssertTrue(actions.menuItems(for: "m1").isEmpty)
        XCTAssertEqual(actions.cachedMessageCount, 0)
        XCTAssertNil(actions.errorEvent)
    }

    func testInterleavedRefreshKeepsNewestGeneration() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        _ = activate(actions)
        let first = Task { await actions.refresh(messageID: "m1") }
        await loader.waitUntilStarted(callCount: 1)
        let second = Task { await actions.refresh(messageID: "m1") }
        await loader.waitUntilStarted(callCount: 2)

        await loader.complete(call: 1, with: .success([try menuItem(id: "new", title: "New")]))
        await second.value
        await loader.complete(call: 0, with: .success([try menuItem(id: "old", title: "Old")]))
        await first.value

        XCTAssertEqual(actions.menuItems(for: "m1").map(\.id), ["new"])
    }

    func testCancelledRefreshDoesNotPublishItemsOrError() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        _ = activate(actions)
        let refresh = Task { await actions.refresh(messageID: "m1") }
        await loader.waitUntilStarted(callCount: 1)

        refresh.cancel()
        await loader.complete(call: 0, with: .failure(CancellationError()))
        await refresh.value

        XCTAssertTrue(actions.menuItems(for: "m1").isEmpty)
        XCTAssertNil(actions.errorEvent)
    }

    func testMutationFailureAfterRowDisappearsDoesNotPublishError() async throws {
        let mutation = ControlledMessageLabelMutation()
        let actions = MessageLabelActions(
            loadItems: { _ in [try menuItem(id: "travel", title: "Travel")] },
            mutate: { labelID, messageID, selected in
                try await mutation.run(labelID: labelID, messageID: messageID, selected: selected)
            }
        )
        let appearance = activate(actions)
        let update = Task {
            await actions.setLabel("travel", on: "m1", selected: true)
        }
        await mutation.waitUntilStarted()

        actions.endAppearance(appearance)
        await mutation.complete(with: .failure(MessageLabelActionTestError.forced))
        await update.value

        XCTAssertNil(actions.errorEvent)
        XCTAssertEqual(actions.trackedMessageCount, 0)
    }

    func testOverlappingMutationsSerializeAndStayPendingUntilQueueDrains() async throws {
        let mutation = QueuedControlledMessageLabelMutation()
        let actions = MessageLabelActions(
            loadItems: { _ in [try menuItem(id: "travel", title: "Travel")] },
            mutate: { labelID, messageID, selected in
                try await mutation.run(
                    labelID: labelID,
                    messageID: messageID,
                    selected: selected
                )
            }
        )
        _ = activate(actions)
        let first = Task {
            await actions.setLabel("travel", on: "m1", selected: true)
        }
        await mutation.waitUntilStarted(callCount: 1)
        let second = Task {
            await actions.setLabel("travel", on: "m1", selected: false)
        }
        for _ in 0..<100 where await mutation.startedCallCount < 2 {
            await Task.yield()
        }

        let startsBeforeFirstCompletion = await mutation.startedCallCount
        XCTAssertEqual(startsBeforeFirstCompletion, 1)
        XCTAssertTrue(actions.isPending(messageID: "m1"))

        await mutation.complete(call: 0, with: .success(()))
        await mutation.waitUntilStarted(callCount: 2)
        await first.value
        XCTAssertTrue(actions.isPending(messageID: "m1"))

        await mutation.complete(call: 1, with: .success(()))
        await second.value

        XCTAssertFalse(actions.isPending(messageID: "m1"))
        let selections = await mutation.selections
        XCTAssertEqual(
            selections,
            [true, false]
        )
    }

    func testLoaderFailurePreservesLastGoodItems() async throws {
        let loader = SequentialMessageLabelLoader(steps: [
            .items([try menuItem(id: "last-good", title: "Last Good")]),
            .failure,
        ])
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        _ = activate(actions)
        await actions.refresh(messageID: "m1")

        await actions.refresh(messageID: "m1")

        XCTAssertEqual(actions.menuItems(for: "m1").map(\.id), ["last-good"])
        XCTAssertEqual(actions.errorEvent?.message, "Unable to load labels. Try again.")
    }

    func testRootRevisionRestartFailurePreservesLastGoodItemsUntilRowCancellation() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        actions.transitionMailboxSurface(to: "smartInbox")
        let originalRowTask = Task {
            await actions.runAppearanceTask(messageID: "m1")
        }
        await loader.waitUntilStarted(callCount: 1)
        await loader.complete(
            call: 0,
            with: .success([try menuItem(id: "last-good", title: "Last Good")])
        )
        while actions.menuItems(for: "m1").isEmpty {
            await Task.yield()
        }

        actions.invalidate()
        let replacementRowTask = Task {
            await actions.runAppearanceTask(messageID: "m1")
        }
        await loader.waitUntilStarted(callCount: 2)
        originalRowTask.cancel()
        await originalRowTask.value
        await loader.complete(
            call: 1,
            with: .failure(MessageLabelActionTestError.forced)
        )
        while actions.errorEvent == nil {
            await Task.yield()
        }

        XCTAssertEqual(actions.menuItems(for: "m1").map(\.id), ["last-good"])
        XCTAssertEqual(
            actions.errorEvent?.message,
            "Unable to load labels. Try again."
        )

        replacementRowTask.cancel()
        await replacementRowTask.value
        XCTAssertTrue(actions.menuItems(for: "m1").isEmpty)
        XCTAssertEqual(actions.cachedMessageCount, 0)
    }

    func testPostWriteRefreshFailureIsSurfacedAndPreservesLastGoodItems() async throws {
        let loader = SequentialMessageLabelLoader(steps: [
            .items([try menuItem(id: "travel", title: "Travel")]),
            .failure,
        ])
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        _ = activate(actions)
        await actions.refresh(messageID: "m1")

        await actions.setLabel("travel", on: "m1", selected: true)

        XCTAssertEqual(actions.menuItems(for: "m1").map(\.id), ["travel"])
        XCTAssertEqual(
            actions.errorEvent?.message,
            "Label updated, but its latest state could not be loaded. Try again."
        )
    }

    func testRepeatedIdenticalErrorsAreRedeliveredAfterConsumption() async throws {
        let actions = MessageLabelActions(
            loadItems: { _ in throw MessageLabelActionTestError.forced },
            mutate: { _, _, _ in }
        )
        _ = activate(actions)
        await actions.refresh(messageID: "m1")
        let first = try XCTUnwrap(actions.errorEvent)
        actions.consumeError(id: first.id)

        await actions.refresh(messageID: "m1")
        let second = try XCTUnwrap(actions.errorEvent)

        XCTAssertEqual(second.message, first.message)
        XCTAssertNotEqual(second.id, first.id)
    }

    func testSurfaceExitInvalidatesLateMutationWithoutOnDisappear() async throws {
        let mutation = ControlledMessageLabelMutation()
        let actions = MessageLabelActions(
            loadItems: { _ in [try menuItem(id: "travel", title: "Travel")] },
            mutate: { labelID, messageID, selected in
                try await mutation.run(labelID: labelID, messageID: messageID, selected: selected)
            }
        )
        actions.transitionMailboxSurface(to: "smartInbox")
        _ = try XCTUnwrap(actions.beginAppearance(messageID: "m1"))
        let update = Task {
            await actions.setLabel("travel", on: "m1", selected: true)
        }
        await mutation.waitUntilStarted()

        actions.transitionMailboxSurface(to: nil)
        await mutation.complete(with: .failure(MessageLabelActionTestError.forced))
        await update.value

        XCTAssertNil(actions.errorEvent)
        XCTAssertEqual(actions.trackedMessageCount, 0)
        XCTAssertEqual(actions.cachedMessageCount, 0)
    }

    func testSameMessageReappearanceInvalidatesOldMutation() async throws {
        let mutation = ControlledMessageLabelMutation()
        let actions = MessageLabelActions(
            loadItems: { _ in [try menuItem(id: "travel", title: "Travel")] },
            mutate: { labelID, messageID, selected in
                try await mutation.run(labelID: labelID, messageID: messageID, selected: selected)
            }
        )
        actions.transitionMailboxSurface(to: "smartInbox")
        let firstAppearance = try XCTUnwrap(actions.beginAppearance(messageID: "m1"))
        let update = Task {
            await actions.setLabel("travel", on: "m1", selected: true)
        }
        await mutation.waitUntilStarted()

        actions.endAppearance(firstAppearance)
        let secondAppearance = try XCTUnwrap(actions.beginAppearance(messageID: "m1"))
        await mutation.complete(with: .failure(MessageLabelActionTestError.forced))
        await update.value

        XCTAssertNil(actions.errorEvent)
        XCTAssertEqual(actions.currentAppearance(for: "m1"), secondAppearance)
        XCTAssertEqual(actions.trackedMessageCount, 1)
    }

    func testCancellingLongLivedRowTaskCleansAppearanceAndPayload() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        actions.transitionMailboxSurface(to: "smartInbox")
        let rowTask = Task {
            await actions.runAppearanceTask(messageID: "m1")
        }
        await loader.waitUntilStarted(callCount: 1)

        rowTask.cancel()
        await loader.complete(call: 0, with: .failure(CancellationError()))
        await rowTask.value

        XCTAssertEqual(actions.trackedMessageCount, 0)
        XCTAssertEqual(actions.cachedMessageCount, 0)
        XCTAssertEqual(actions.menuContent(for: "m1"), .empty)
    }

    func testMoreThanSixtyFourTrulyVisibleRowsRemainLoaded() async throws {
        let actions = MessageLabelActions(
            loadItems: { messageID in
                [try menuItem(id: messageID.rawValue, title: messageID.rawValue)]
            },
            mutate: { _, _, _ in }
        )
        actions.transitionMailboxSurface(to: "allInboxes")
        for index in 0..<80 {
            let messageID = "m\(index)"
            let appearance = try XCTUnwrap(actions.beginAppearance(messageID: messageID))
            await actions.refresh(appearance)
        }

        XCTAssertEqual(actions.trackedMessageCount, 80)
        XCTAssertEqual(actions.cachedMessageCount, 80)
        XCTAssertEqual(actions.menuItems(for: "m0").map(\.id), ["m0"])
        XCTAssertEqual(actions.menuItems(for: "m79").map(\.id), ["m79"])
    }

    func testManyScrolledRowsStayBoundedAfterTaskCancellation() async throws {
        let actions = MessageLabelActions(
            loadItems: { messageID in
                [try menuItem(id: messageID.rawValue, title: messageID.rawValue)]
            },
            mutate: { _, _, _ in }
        )
        actions.transitionMailboxSurface(to: "allInboxes")

        for index in 0..<100 {
            let task = Task {
                await actions.runAppearanceTask(messageID: "m\(index)")
            }
            while actions.trackedMessageCount == 0 {
                await Task.yield()
            }
            task.cancel()
            await task.value
        }

        XCTAssertEqual(actions.trackedMessageCount, 0)
        XCTAssertEqual(actions.cachedMessageCount, 0)
    }

    func testInitialSnapshotShowsLoadingBeforeGenuinelyEmpty() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        actions.transitionMailboxSurface(to: "smartInbox")
        let appearance = try XCTUnwrap(actions.beginAppearance(messageID: "m1"))

        XCTAssertEqual(actions.menuContent(for: "m1"), .loading)
        let refresh = Task { await actions.refresh(appearance) }
        await loader.waitUntilStarted(callCount: 1)
        XCTAssertEqual(actions.menuContent(for: "m1"), .loading)

        await loader.complete(call: 0, with: .success([]))
        await refresh.value

        XCTAssertEqual(actions.menuContent(for: "m1"), .empty)
    }

    func testInitialLoadFailureOffersRetryThatReloadsCurrentAppearance() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        actions.transitionMailboxSurface(to: "smartInbox")
        let appearance = try XCTUnwrap(actions.beginAppearance(messageID: "m1"))
        let initialLoad = Task {
            await actions.refresh(appearance)
        }
        await loader.waitUntilStarted(callCount: 1)
        await loader.complete(
            call: 0,
            with: .failure(MessageLabelActionTestError.forced)
        )
        await initialLoad.value

        XCTAssertEqual(actions.menuContent(for: "m1"), .loadFailed)

        let retry = Task {
            await actions.retry(messageID: "m1")
        }
        await loader.waitUntilStarted(callCount: 2)
        XCTAssertEqual(actions.menuContent(for: "m1"), .loading)
        await loader.complete(
            call: 1,
            with: .success([try menuItem(id: "travel", title: "Travel")])
        )
        await retry.value

        guard case .items(let items) = actions.menuContent(for: "m1") else {
            return XCTFail("Expected retry to publish the current appearance payload.")
        }
        XCTAssertEqual(items.map(\.id), ["travel"])
    }

    func testFailedInitialLoadActualRowExposesRetrySubmenuControl() async throws {
        let actions = MessageLabelActions(
            loadItems: { _ in throw MessageLabelActionTestError.forced },
            mutate: { _, _, _ in }
        )
        _ = activate(actions)
        await actions.refresh(messageID: "m1")
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
            labelActions: actions,
            performMessageAction: { _, _ in }
        )

        XCTAssertEqual(nativeRow.labelMenuControls, [.retry])
        XCTAssertEqual(MessageLabelMenuControl.retry.title, "Retry Loading Labels")
        XCTAssertEqual(MessageLabelMenuControl.retry.systemImage, "arrow.clockwise")
        XCTAssertEqual(
            MailMessageListRow.actionSurface.contextMenuActions,
            [.archive, .readState, .flag, .move, .labels, .separator, .delete]
        )
    }

    func testRetryFromReplacedAppearanceCannotPublishLateError() async throws {
        let loader = ControlledMessageLabelLoader()
        let actions = MessageLabelActions(
            loadItems: { try await loader.load($0) },
            mutate: { _, _, _ in }
        )
        actions.transitionMailboxSurface(to: "smartInbox")
        let firstAppearance = try XCTUnwrap(actions.beginAppearance(messageID: "m1"))
        let initialLoad = Task {
            await actions.refresh(firstAppearance)
        }
        await loader.waitUntilStarted(callCount: 1)
        await loader.complete(
            call: 0,
            with: .failure(MessageLabelActionTestError.forced)
        )
        await initialLoad.value
        let initialError = try XCTUnwrap(actions.errorEvent)
        actions.consumeError(id: initialError.id)

        let retry = Task {
            await actions.retry(messageID: "m1")
        }
        await loader.waitUntilStarted(callCount: 2)
        let replacement = try XCTUnwrap(actions.beginAppearance(messageID: "m1"))
        await loader.complete(
            call: 1,
            with: .failure(MessageLabelActionTestError.forced)
        )
        await retry.value

        XCTAssertEqual(actions.currentAppearance(for: "m1"), replacement)
        XCTAssertEqual(actions.menuContent(for: "m1"), .loading)
        XCTAssertNil(actions.errorEvent)
    }

    func testProductionFactoryInjectsAsyncSQLiteSnapshotLoader() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-message-label-actions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(
            id: AccountID("a"),
            displayName: "Work",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        try store.saveMailLabel(try .validated(
            id: "travel",
            title: "Travel",
            description: "",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        ))
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("m1"),
                threadID: nil,
                from: EmailAddress("sender@example.com"),
                subject: "Trip",
                preview: "Preview",
                smartCategory: .personal
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let actions = ProductionMessageLabelActionsFactory.make(store: store)
        _ = activate(actions)

        await actions.refresh(messageID: "m1")

        XCTAssertEqual(actions.menuItems(for: "m1").map(\.id), ["travel"])
        XCTAssertNil(actions.errorEvent)

        let system = Actor(
            id: "system",
            kind: .system,
            displayName: "System",
            permissions: .guiUser
        )
        let user = Actor(
            id: "local-user",
            kind: .user,
            displayName: "Local User",
            permissions: .guiUser
        )
        try store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: system
        )
        actions.invalidate()
        await actions.refresh(messageID: "m1")
        XCTAssertEqual(
            actions.menuItems(for: "m1").first?.sources,
            [.smartInbox]
        )

        try store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: system
        )
        actions.invalidate()
        await actions.refresh(messageID: "m1")
        XCTAssertEqual(
            actions.menuItems(for: "m1").first?.sources,
            [.smartInbox, .rule(ruleID: "r1")]
        )

        try store.establishUserLabel(
            labelID: "travel",
            on: MessageID("m1"),
            actor: user
        )
        actions.invalidate()
        await actions.refresh(messageID: "m1")
        XCTAssertEqual(
            actions.menuItems(for: "m1").first?.sources,
            [.user, .rule(ruleID: "r1")]
        )

        _ = try store.removeLabel(
            "Travel",
            from: MessageID("m1"),
            actor: user
        )
        actions.invalidate()
        await actions.refresh(messageID: "m1")
        XCTAssertEqual(
            actions.menuItems(for: "m1").first?.sources,
            [.rule(ruleID: "r1")]
        )
    }
}

@MainActor
private final class MessageLabelActionFixture {
    let messageID = MessageID("m1")
    let store: MessageLabelActionStoreProbe
    let actions: MessageLabelActions

    init(
        sources: Set<MailLabelAssignmentSource>,
        excluded: Bool = false,
        labels: [MailLabelDefinition]? = nil,
        ruleNames: [String: String] = [:]
    ) throws {
        let definitions = try labels ?? [
            .validated(
                id: "travel",
                title: "Travel",
                description: "",
                isSmartInboxEnabled: false,
                scope: .allAccounts
            )
        ]
        let store = MessageLabelActionStoreProbe(
            messageID: messageID,
            accountID: AccountID("a"),
            definitions: definitions,
            sourcesByLabelID: ["travel": sources],
            excludedLabelIDs: excluded ? ["travel"] : [],
            ruleNames: ruleNames
        )
        self.store = store
        self.actions = MessageLabelActions(
            snapshots: store,
            assignments: store
        )
        _ = activate(self.actions, messageID: messageID.rawValue)
    }
}

private enum MessageLabelActionTestError: Error {
    case forced
}

@MainActor
@discardableResult
private func activate(
    _ actions: MessageLabelActions,
    messageID: String = "m1",
    destination: String = "smartInbox"
) -> MessageLabelAppearanceToken {
    actions.transitionMailboxSurface(to: destination)
    guard let appearance = actions.beginAppearance(messageID: messageID) else {
        preconditionFailure("Expected an active mailbox label surface.")
    }
    return appearance
}

private func menuItem(id: String, title: String) throws -> MessageLabelMenuItem {
    MessageLabelMenuItem(
        label: try .validated(
            id: id,
            title: title,
            description: "",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        ),
        sources: [],
        isExcluded: false,
        ruleNames: [:]
    )
}

private actor SequentialMessageLabelLoader {
    enum Step: Sendable {
        case items([MessageLabelMenuItem])
        case failure
    }

    private var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    func load(_ messageID: MessageID) throws -> [MessageLabelMenuItem] {
        guard !steps.isEmpty else {
            throw MessageLabelActionTestError.forced
        }
        switch steps.removeFirst() {
        case .items(let items):
            return items
        case .failure:
            throw MessageLabelActionTestError.forced
        }
    }
}

private actor ScopedLabelMutationRecorder {
    struct Mutation: Equatable, Sendable {
        let labelID: String
        let messageID: String
        let selected: Bool
    }

    private(set) var mutations: [Mutation] = []

    func record(labelID: String, messageID: String, selected: Bool) {
        mutations.append(
            Mutation(
                labelID: labelID,
                messageID: messageID,
                selected: selected
            )
        )
    }
}

private actor ControlledMessageLabelLoader {
    private var starts = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resultWaiters: [Int: CheckedContinuation<[MessageLabelMenuItem], Error>] = [:]

    func load(_ messageID: MessageID) async throws -> [MessageLabelMenuItem] {
        let call = starts
        starts += 1
        resumeSatisfiedStartWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            resultWaiters[call] = continuation
        }
    }

    func waitUntilStarted(callCount: Int) async {
        guard starts < callCount else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((callCount, continuation))
        }
    }

    func complete(
        call: Int,
        with result: Result<[MessageLabelMenuItem], Error>
    ) {
        guard let continuation = resultWaiters.removeValue(forKey: call) else {
            return
        }
        continuation.resume(with: result)
    }

    private func resumeSatisfiedStartWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in startWaiters {
            if starts >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        startWaiters = remaining
    }
}

private actor ControlledMessageLabelMutation {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiter: CheckedContinuation<Void, Error>?

    func run(labelID: String, messageID: MessageID, selected: Bool) async throws {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        try await withCheckedThrowingContinuation { continuation in
            resultWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func complete(with result: Result<Void, Error>) {
        resultWaiter?.resume(with: result)
        resultWaiter = nil
    }
}

private actor QueuedControlledMessageLabelMutation {
    private var starts = 0
    private var selectedValues: [Bool] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resultWaiters: [Int: CheckedContinuation<Void, Error>] = [:]

    var startedCallCount: Int {
        starts
    }

    var selections: [Bool] {
        selectedValues
    }

    func run(labelID: String, messageID: MessageID, selected: Bool) async throws {
        let call = starts
        starts += 1
        selectedValues.append(selected)
        resumeSatisfiedStartWaiters()
        try await withCheckedThrowingContinuation { continuation in
            resultWaiters[call] = continuation
        }
    }

    func waitUntilStarted(callCount: Int) async {
        guard starts < callCount else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((callCount, continuation))
        }
    }

    func complete(call: Int, with result: Result<Void, Error>) {
        guard let continuation = resultWaiters.removeValue(forKey: call) else {
            return
        }
        continuation.resume(with: result)
    }

    private func resumeSatisfiedStartWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in startWaiters {
            if starts >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        startWaiters = remaining
    }
}

private final class MessageLabelActionStoreProbe:
    MessageLabelAssignmentRepository,
    MessageLabelActionSnapshotRepository,
    @unchecked Sendable
{
    private struct State {
        var definitions: [MailLabelDefinition]
        var sourcesByLabelID: [String: Set<MailLabelAssignmentSource>]
        var excludedLabelIDs: Set<String>
        var ruleNames: [String: String]
    }

    private let lock = NSLock()
    private let messageID: MessageID
    private let messageAccountID: AccountID
    private var state: State

    init(
        messageID: MessageID,
        accountID: AccountID,
        definitions: [MailLabelDefinition],
        sourcesByLabelID: [String: Set<MailLabelAssignmentSource>],
        excludedLabelIDs: Set<String>,
        ruleNames: [String: String]
    ) {
        self.messageID = messageID
        self.messageAccountID = accountID
        self.state = State(
            definitions: definitions,
            sourcesByLabelID: sourcesByLabelID,
            excludedLabelIDs: excludedLabelIDs,
            ruleNames: ruleNames
        )
    }

    func sources(for labelID: String) -> Set<MailLabelAssignmentSource> {
        lock.withLock { state.sourcesByLabelID[labelID] ?? [] }
    }

    func isExcluded(_ labelID: String) -> Bool {
        lock.withLock { state.excludedLabelIDs.contains(labelID) }
    }

    func deleteDefinition(id: String) {
        lock.withLock {
            state.definitions.removeAll { $0.id == id }
            state.sourcesByLabelID[id] = nil
            state.excludedLabelIDs.remove(id)
        }
    }

    func messageLabelActionSnapshot(
        for messageID: MessageID
    ) async throws -> MessageLabelActionSnapshot {
        guard messageID == self.messageID else {
            return MessageLabelActionSnapshot(
                accountID: nil,
                labels: [],
                assignments: [],
                exclusions: [],
                ruleNames: [:]
            )
        }
        return lock.withLock {
            let assignments = state.sourcesByLabelID.flatMap { labelID, sources in
                sources.map {
                    MailLabelAssignment(
                        messageID: messageID,
                        labelID: labelID,
                        source: $0,
                        createdAt: .distantPast
                    )
                }
            }
            let exclusions = state.excludedLabelIDs.map {
                MailLabelExclusion(
                    messageID: messageID,
                    labelID: $0,
                    createdAt: .distantPast
                )
            }
            return MessageLabelActionSnapshot(
                accountID: messageAccountID,
                // Deliberately return the full catalog so the action layer proves
                // it enforces the message-account scope itself.
                labels: state.definitions,
                assignments: assignments,
                exclusions: exclusions,
                ruleNames: state.ruleNames
            )
        }
    }

    func labelAssignments(for messageID: MessageID) throws -> [MailLabelAssignment] {
        guard messageID == self.messageID else { return [] }
        return lock.withLock {
            state.sourcesByLabelID.flatMap { labelID, sources in
                sources.map {
                    MailLabelAssignment(
                        messageID: messageID,
                        labelID: labelID,
                        source: $0,
                        createdAt: .distantPast
                    )
                }
            }
        }
    }

    func labelExclusions(for messageID: MessageID) throws -> [MailLabelExclusion] {
        guard messageID == self.messageID else { return [] }
        return lock.withLock {
            state.excludedLabelIDs.map {
                MailLabelExclusion(
                    messageID: messageID,
                    labelID: $0,
                    createdAt: .distantPast
                )
            }
        }
    }

    func addUserLabel(labelID: String, to messageID: MessageID, actor: Actor) throws {
        guard messageID == self.messageID else {
            throw MailLabelValidationError.unknownLabel
        }
        try lock.withLock {
            guard state.definitions.contains(where: { $0.id == labelID }) else {
                throw MailLabelValidationError.unknownLabel
            }
            state.sourcesByLabelID[labelID, default: []].insert(.user)
            state.excludedLabelIDs.remove(labelID)
        }
    }

    func establishUserLabel(labelID: String, on messageID: MessageID, actor: Actor) throws {
        guard messageID == self.messageID else {
            throw MailLabelValidationError.unknownLabel
        }
        try lock.withLock {
            guard state.definitions.contains(where: { $0.id == labelID }) else {
                throw MailLabelValidationError.unknownLabel
            }
            state.sourcesByLabelID[labelID, default: []].remove(.smartInbox)
            state.sourcesByLabelID[labelID, default: []].insert(.user)
            state.excludedLabelIDs.remove(labelID)
        }
    }

    func removeUserOrSmartInboxLabel(
        labelID: String,
        from messageID: MessageID,
        actor: Actor
    ) throws {
        guard messageID == self.messageID else {
            throw MailLabelValidationError.unknownLabel
        }
        try lock.withLock {
            guard state.definitions.contains(where: { $0.id == labelID }) else {
                throw MailLabelValidationError.unknownLabel
            }
            let hadSmartInbox = state.sourcesByLabelID[labelID]?.contains(.smartInbox) == true
            state.sourcesByLabelID[labelID]?.remove(.user)
            state.sourcesByLabelID[labelID]?.remove(.smartInbox)
            if hadSmartInbox {
                state.excludedLabelIDs.insert(labelID)
            }
        }
    }

    func replaceRuleLabels(
        ruleID: String,
        labelIDs: [String],
        on messageID: MessageID,
        actor: Actor
    ) throws {}

    func replaceSmartInboxLabels(
        labelIDs: [String],
        on messageID: MessageID,
        actor: Actor
    ) throws {}
}
