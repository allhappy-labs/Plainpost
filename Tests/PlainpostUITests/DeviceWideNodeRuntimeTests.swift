import GRDB
import PlainpostAccountProtocol
import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI
import PlainpostRuntimeTestSupport
import PlainpostSecrets
import XCTest

/// The iPhone runtime with a Sync Node account next to two Direct ones: the Node account's
/// mirrored mail is in the same lists, and its changes go through the device's Sync Node.
@MainActor
final class DeviceWideNodeRuntimeTests: XCTestCase {
    private var savedLastFrom: String?

    override func setUp() async throws {
        savedLastFrom = UserDefaults.standard.string(forKey: ComposerFromAccountPreference.key)
        UserDefaults.standard.removeObject(forKey: ComposerFromAccountPreference.key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedLastFrom, forKey: ComposerFromAccountPreference.key)
    }

    private func fixture() throws -> (TwoDirectAccountsFixture, Account) {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        return (fixture, try XCTUnwrap(fixture.node))
    }

    func testAllInboxesListsTheSyncNodeAccountsMail() async throws {
        let (fixture, node) = try fixture()
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let model = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertEqual(model.classicRows.map(\.id), ["msg_node_1", "msg_first_2", "msg_second_1", "msg_first_1"])
        XCTAssertEqual(model.classicRows.first?.accountID, node.id)
    }

    func testTheSyncNodeAccountHasItsOwnMailboxesSection() async throws {
        let (fixture, node) = try fixture()
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let sections = await runtime.mailboxDirectorySections()
        XCTAssertEqual(Set(sections.map(\.id)), [fixture.first.id, fixture.second.id, node.id])
        let rows = try await runtime.folderRows(accountID: node.id, path: "INBOX", limit: 10)
        XCTAssertEqual(rows.map(\.id), ["msg_node_1"])
    }

    func testAnActionOnASyncNodeMessageGoesToTheSyncNode() async throws {
        let (fixture, _) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let actions = runtime.makeInboxMailActionViewModel()
        let outcome = await actions.perform(.archive, messageID: "msg_node_1", shownIn: "INBOX")
        guard case .succeeded = outcome else { return XCTFail("\(outcome)") }
        let performed = await bridge.performedKinds
        let messages = await bridge.performedMessageIDs
        XCTAssertEqual(performed, [.archive])
        XCTAssertEqual(messages, [MessageID("msg_node_1")])
    }

    func testFlagAndMoveOnASyncNodeMessageGoToTheSyncNode() async throws {
        let (fixture, _) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let actions = runtime.makeInboxMailActionViewModel()
        guard case .succeeded = await actions.perform(.flag, messageID: "msg_node_1") else { return XCTFail("flag") }
        guard case let .succeeded(moved) = await actions.perform(.move(to: "Receipts"), messageID: "msg_node_1") else {
            return XCTFail("move")
        }
        XCTAssertEqual(moved.mailboxPath, "Receipts")
        let kinds = await bridge.performedKinds
        let folders = await bridge.performedFolders
        XCTAssertEqual(kinds, [.flag, .move])
        XCTAssertEqual(folders, [nil, "Receipts"])
    }

    /// While its Node is away the account is in fallback: its mail stays listed where it was,
    /// and its changes still go through the device's Node journal, which picks the provider.
    func testAnAccountInFallbackStaysListedAndItsChangesGoThroughTheJournal() async throws {
        let (fixture, node) = try fixture()
        let store = try fixture.store()
        let source = try store.mailSource(accountID: node.id)
        _ = try store.replaceMailSource(source.withMode(.fallback), expectedGeneration: source.generation)
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        let model = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertTrue(model.classicRows.map(\.id).contains("msg_node_1"))
        let sections = await runtime.mailboxDirectorySections()
        XCTAssertTrue(sections.map(\.id).contains(node.id))
        guard case .succeeded = await runtime.makeInboxMailActionViewModel().perform(.archive, messageID: "msg_node_1", shownIn: "INBOX")
        else { return XCTFail("archive") }
        let performed = await bridge.performedKinds
        XCTAssertEqual(performed, [.archive])
    }

    func testAnOlderSyncNodeRefusingAMoveSaysToUpdateIt() async throws {
        let (fixture, _) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        await bridge.setOutcome(.failed(MailIntentRouterRefusal.genericMessage))
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let outcome = await runtime.makeInboxMailActionViewModel().perform(.move(to: "Receipts"), messageID: "msg_node_1")
        XCTAssertEqual(outcome, .failed(message: "Update your Sync Node to move messages."))
    }

    func testMoveDestinationsAreTheMessagesOwnAccountsOtherFolders() async throws {
        let (fixture, _) = try fixture()
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let session = runtime.makeMailSession(
            composerPresentationPolicy: .embedded, commitDelay: .zero, providerOnboarding: nil, accountSessionModel: nil,
            initialDestination: .allInboxes, initialSelectedMessageID: nil, onAccountSetupConnected: { _ in },
            contactDirectory: nil
        )
        await session.directory.refresh()
        let folders = session.moveDestinations(forMessageID: "msg_second_1", excluding: "INBOX")
        XCTAssertEqual(folders.map(\.path), ["Archive"])
        XCTAssertTrue(folders.allSatisfy { $0.accountID == fixture.second.id })
    }

    func testPermanentDeleteOfASyncNodeMessageIsRefused() async throws {
        let (fixture, _) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let outcome = await runtime.makeInboxMailActionViewModel().perform(.deletePermanently, messageID: "msg_node_1")
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        let performed = await bridge.performedKinds
        XCTAssertTrue(performed.isEmpty)
    }

    func testARefusalFromTheSyncNodeIsShown() async throws {
        let (fixture, _) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        await bridge.setOutcome(.failed("The Sync Node refused this change."))
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let outcome = await runtime.makeInboxMailActionViewModel().perform(.markRead, messageID: "msg_node_1")
        XCTAssertEqual(outcome, .failed(message: "The Sync Node refused this change."))
    }

    func testAnActionAfterTheAccountLeftSyncNodeIsRefused() async throws {
        let (fixture, node) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        try fixture.switchToDirect(node)
        let outcome = await runtime.makeInboxMailActionViewModel().perform(.archive, messageID: "msg_node_1")
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        let performed = await bridge.performedKinds
        XCTAssertTrue(performed.isEmpty, "never sent to the Node, nor to the provider")
    }

    func testWithoutASyncNodeOnThisDeviceAnActionSaysSo() async throws {
        let (fixture, _) = try fixture()
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let outcome = await runtime.makeInboxMailActionViewModel().perform(.archive, messageID: "msg_node_1")
        guard case let .failed(message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("Sync Node"), message)
    }

    func testOpeningASyncNodeMessageMarksItReadThroughTheSyncNode() async throws {
        let (fixture, _) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        try await runtime.openOwnedDirectMessage(MessageID("msg_node_1"))
        let performed = await bridge.performedKinds
        XCTAssertEqual(performed, [.markRead])
    }

    func testFromOffersTheSyncNodeAccountAndItsSendGoesToTheSyncNode() async throws {
        let (fixture, node) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: fixture.databaseURL,
                runtimeDependencies: InMemoryAppRuntimeDependencies(credentials: InMemoryCredentialVault(), deviceNodeMail: bridge)
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            undoSendSleep: { _ in }
        )
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareNewMessage()
        XCTAssertEqual(Set(composer.fromAccounts.map(\.id)), [fixture.first.id, fixture.second.id, node.id])
        composer.selectFromAccount(node.id)
        composer.to = "someone@example.com"
        composer.subject = "From the Node"
        composer.bodyMarkdown = "Body"
        let scheduled = try await composer.send()
        XCTAssertTrue(scheduled)
        for _ in 0..<200 where await bridge.sentDrafts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await bridge.sentDrafts
        XCTAssertEqual(sent.map(\.accountID), [node.id])
        XCTAssertEqual(sent.first?.subject, "From the Node")
    }

    func testAReplyToASyncNodeMessageComesFromThatAccount() async throws {
        let (fixture, node) = try fixture()
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel(sourceMessageID: "msg_node_1")
        XCTAssertEqual(composer.fromAccountID, node.id)
    }

    func testLabelsApplyToASyncNodeMessage() async throws {
        let (fixture, _) = try fixture()
        let store = try fixture.store()
        try store.saveMailLabel(try .validated(
            id: "travel", title: "Travel", description: "",
            isSmartInboxEnabled: false, scope: .allAccounts
        ))
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let actions = runtime.makeMessageLabelActions()
        actions.transitionMailboxSurface(to: "smartInbox")
        _ = actions.beginAppearance(messageID: "msg_node_1")
        await actions.refresh(messageID: "msg_node_1")
        await actions.setLabel("travel", on: "msg_node_1", selected: true)
        XCTAssertEqual(try store.labelAssignments(for: MessageID("msg_node_1")).map(\.labelID), ["travel"])
    }

    func testSearchFindsSyncNodeMail() async throws {
        let (fixture, node) = try fixture()
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let accounts = runtime.makeMailSearchViewModel().accounts.map(\.id)
        XCTAssertTrue(accounts.contains(node.id))
    }

    func testCompleteHistoryForASyncNodeAccountAsksTheMirror() async throws {
        let (fixture, node) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        try runtime.enableCompleteHistory(for: node.id)
        try await runtime.syncDirectMailHistoryNow(for: node.id)
        XCTAssertTrue(try fixture.store().syncPreferences(accountID: node.id).downloadCompleteHistory)
        let requests = await bridge.completeHistoryRequests
        XCTAssertEqual(requests, [node.id])
    }

    /// Settings knows each Sync Node account's sign-in on the phone; Direct accounts have
    /// none to show. The fixture's Node account isn't Gmail, so no sign-in can be added.
    func testSettingsKnowWhetherTheSyncNodeAccountCanKeepSyncingHere() async throws {
        let (fixture, node) = try fixture()
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let settings = runtime.makeAccountSetupViewModel()
        await settings.refreshSyncNodeSignIns()
        XCTAssertEqual(settings.syncNodeSignIns, [node.id: .unavailable])
        let rows = SettingsAccountRow.rows(accountSetup: settings, host: PlainpostSettingsHost())
        XCTAssertEqual(rows.first { $0.destination == .account(node.id) }?.subtitle, "Via Sync Node")
        XCTAssertNotEqual(rows.first { $0.destination == .account(fixture.first.id) }?.subtitle, "Via Sync Node")
        XCTAssertEqual(AccountSettingsPage.syncNodeFooter(.unavailable),
                       "Your Sync Node syncs this account. When it can't be reached, your changes wait on this iPhone and go once it's back.")
    }

    func testAnUnreachableSectionOffersItsAccountSettings() {
        XCTAssertEqual(AccountSyncStatus.syncNodeUnreachable.settingsTitle, "Account Settings")
        XCTAssertEqual(AccountSyncStatus.noLongerOnSyncNode.message, "No longer on your Sync Node")
        XCTAssertEqual(AccountSyncStatus.noLongerOnSyncNode.settingsTitle, "Account Settings")
        XCTAssertEqual(AccountSyncStatus.needsSignIn.settingsTitle, "Sign In Again")
        XCTAssertNil(AccountSyncStatus.failed.settingsTitle)
        XCTAssertNil(AccountSyncStatus.ok.settingsTitle)
    }

    // MARK: - A notification tap opens in place

    /// Links the fixture's Node message to the Node's own ID, as the mirror does.
    private func linkNodeMessage(_ fixture: TwoDirectAccountsFixture, _ node: Account, nodeMessageID: String) async throws {
        try await Self.link(store: fixture.store(), accountID: node.id, nodeMessageID: nodeMessageID)
    }

    private static func link(store: SQLiteMailStore, accountID: AccountID, nodeMessageID: String) async throws {
        try await store.databasePool.write { database in
            try database.execute(sql: """
                INSERT INTO node_mirror_message_links (account_id, node_message_id, message_id, hydration_state)
                VALUES (?, ?, 'msg_node_1', 'complete')
                """, arguments: [accountID.rawValue, nodeMessageID])
        }
    }

    /// A Sync Node push names the Node's message ID: the tap opens the mirrored message,
    /// with no account switch.
    func testASyncNodePushOpensItsMirroredMessageInPlace() async throws {
        let (fixture, node) = try fixture()
        try await linkNodeMessage(fixture, node, nodeMessageID: "node-message-7")
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let token = NotificationOpaqueIdentities.messageToken(for: "node-message-7")
        let hint = try fixture.store().mailSource(accountID: node.id).logicalMailboxID
        let destination = await runtime.resolveNotificationOpen(token, logicalMailboxHint: hint)
        XCTAssertEqual(destination, .message("msg_node_1"))
        let unhinted = await runtime.resolveNotificationOpen(token)
        XCTAssertEqual(unhinted, .message("msg_node_1"))
    }

    /// A push that arrives before the mirror has its message wakes the mirror and opens
    /// the message once it lands.
    func testAPushAheadOfTheMirrorOpensOnceTheMirrorHasIt() async throws {
        let (fixture, node) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let store = try fixture.store()
        let nodeID = node.id
        await bridge.setOnWake { try? await Self.link(store: store, accountID: nodeID, nodeMessageID: "node-message-9") }
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        let destination = await runtime.resolveNotificationOpen(NotificationOpaqueIdentities.messageToken(for: "node-message-9"))
        XCTAssertEqual(destination, .message("msg_node_1"))
        let wakes = await bridge.wakes
        XCTAssertEqual(wakes, 1)
    }

    /// A push for mail this device doesn't have (the account was removed, or the message is
    /// gone) says so instead of quietly landing on All Inboxes.
    func testAPushForMailThisDeviceDoesntHaveIsUnavailable() async throws {
        let (fixture, node) = try fixture()
        try await linkNodeMessage(fixture, node, nodeMessageID: "node-message-7")
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let unknown = await runtime.resolveNotificationOpen(NotificationOpaqueIdentities.messageToken(for: "node-message-8"))
        XCTAssertEqual(unknown, .messageUnavailable)
        try fixture.switchToDirect(node)
        let leftNode = await runtime.resolveNotificationOpen(NotificationOpaqueIdentities.messageToken(for: "node-message-7"))
        XCTAssertEqual(leftNode, .messageUnavailable, "an account no longer on its Sync Node doesn't answer for the Node's IDs")
    }

    // MARK: - Each account's section says when it can't sync

    func testAnUnreachableSyncNodeMarksOnlyItsAccountsSection() async throws {
        let (fixture, node) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        await bridge.setStates([node.id: .unreachable])
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        let statuses = Dictionary(uniqueKeysWithValues: await runtime.mailboxDirectorySections().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses, [fixture.first.id: .ok, fixture.second.id: .ok, node.id: .syncNodeUnreachable])
    }

    func testAnAccountTheNodeNoLongerListsSaysSoInItsSection() async throws {
        let (fixture, node) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        await bridge.setStates([node.id: .noLongerOnSyncNode])
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        let statuses = Dictionary(uniqueKeysWithValues: await runtime.mailboxDirectorySections().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses[node.id], .noLongerOnSyncNode)
    }

    func testAnAccountThatNeedsSignInSaysSoInItsSection() async throws {
        let (fixture, node) = try fixture()
        try fixture.store().setAccountAuthentication(accountID: fixture.second.id, method: .googleOAuth, state: .reauthorizationRequired)
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        let statuses = Dictionary(uniqueKeysWithValues: await runtime.mailboxDirectorySections().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses, [fixture.first.id: .ok, fixture.second.id: .needsSignIn, node.id: .ok])
        XCTAssertEqual(AccountSyncStatus.needsSignIn.message, "Sign in again to sync")
    }

    /// Neither Direct account can reach its server here: both sections say so, and the Sync
    /// Node account, which syncs through the Node, doesn't.
    func testEachFailedDirectAccountIsMarkedAndTheOthersAreNot() async throws {
        let (fixture, node) = try fixture()
        let runtime = try fixture.deviceWideRuntime(nodeMail: RecordingDeviceNodeMailBridge())
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.syncAllDirectMailNow()
        let statuses = Dictionary(uniqueKeysWithValues: await runtime.mailboxDirectorySections().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses, [fixture.first.id: .failed, fixture.second.id: .failed, node.id: .ok])
    }

    func testPullToRefreshAlsoWakesTheSyncNode() async throws {
        let (fixture, _) = try fixture()
        let bridge = RecordingDeviceNodeMailBridge()
        let runtime = try fixture.deviceWideRuntime(nodeMail: bridge)
        defer { Task { await runtime.shutdown() } }
        _ = await runtime.syncAllDirectMailNow()
        let wakes = await bridge.wakes
        XCTAssertEqual(wakes, 1)
    }
}
