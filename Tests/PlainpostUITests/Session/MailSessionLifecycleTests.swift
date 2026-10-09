import AppKit
import SwiftUI
import XCTest
import PlainpostAI
import PlainpostCore
import PlainpostDB
import PlainpostAccountRuntime
import PlainpostTestSupport
@testable import PlainpostUI

private final class PublicationMailboxHints: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private actor PublicationFetchGate {
    nonisolated let arrived: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(arrived: XCTestExpectation) { self.arrived = arrived }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            arrived.fulfill()
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor PublicationIMAPClient: IMAPClientProtocol {
    private let accountID: AccountID
    private let discovery: PublicationFetchGate
    private let history: PublicationFetchGate
    private var uids = [1, 2, 3]
    init(accountID: AccountID, discovery: PublicationFetchGate, history: PublicationFetchGate) {
        self.accountID = accountID; self.discovery = discovery; self.history = history
    }
    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(id: MailboxID("publication-inbox"), accountID: accountID, name: "Inbox", path: "INBOX", specialUse: nil)]
    }
    func selectMailbox(_ path: String) async throws -> String { "* OK [UIDVALIDITY 7]" }
    func allMessageUIDs() async throws -> [Int] {
        await discovery.wait()
        return uids
    }
    func messageUIDs(after uid: Int?) async throws -> [Int] { uids.filter { $0 > (uid ?? 0) } }
    func fetchHeader(uid: Int) async throws -> String {
        if uid == 2 { await history.wait() }
        return "From: sender@example.test\r\nSubject: Publication \(uid)\r\nMessage-ID: <publication-\(uid)@example.test>\r\n"
    }
    func fetchBody(uid: Int) async throws -> String {
        if uid == 1 { uids.append(4) }
        return "Synthetic publication body"
    }
    func fetchInternalDate(uid: Int) async throws -> Date? { Date(timeIntervalSince1970: 1_700_000_000) }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        .init(mailbox: mailbox, uid: nil)
    }
}

@MainActor
final class MailSessionLifecycleTests: XCTestCase {
    func testFailedAtomicIncomingCommitRollsBackWithoutMailboxHint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-publication-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let hints = PublicationMailboxHints()
        let observation = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName, object: nil, queue: nil
        ) { notification in
            if [.mailbox, .all].contains(MailStoreChangeSignal.scope(from: notification)) { hints.record() }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let message = MessageSummary(id: MessageID("publication-rollback"), threadID: nil,
            from: EmailAddress("sender@example.test"), subject: "Rollback", preview: "Synthetic", smartCategory: .personal)
        let metadata = IncomingMessageSearchMetadata(to: [], cc: [], bcc: [],
            attachments: [.init(filename: "different.pdf", mimeType: "application/pdf")], messageIdentifiers: [])
        let payload = IncomingMessageAttachmentPayload(partPath: "2", filename: "actual.pdf",
            mimeType: "application/pdf", data: Data("synthetic".utf8))
        XCTAssertThrowsError(try store.commitIncomingMessage(message, metadata: metadata, attachments: [payload],
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 7, uid: 44, notificationEligible: false))
        XCTAssertNil(try store.messageSummary(id: message.id))
        XCTAssertTrue(try store.incomingMessageAttachments(messageID: message.id).isEmpty)
        XCTAssertFalse(try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7).contains(44))
        XCTAssertEqual(hints.count, 0, "A rolled-back transaction must not emit a committed-mail hint")
        // Notifications post synchronously: positive acknowledgment validates
        // this observer without a negative sleep or an inverted expectation.
        MailStoreChangeSignal.post(scope: .mailbox)
        XCTAssertEqual(hints.count, 1)
    }

    func testAtomicHistoryArrivalPublishesSessionInboxBeforeHistoryCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let center = NotificationCenter()
        let monitor = MailStoreChangeMonitor(notificationCenter: center, observeDistributedNotifications: false)
        // Only this selected test runs in this process. Bridge the owned store's
        // property-list scope hints, never payloads or distributed notifications.
        let observation = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName, object: nil, queue: nil
        ) { notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            center.post(name: MailStoreChangeSignal.notificationName, object: nil,
                userInfo: [MailStoreChangeSignal.scopeUserInfoKey: scope.rawValue])
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let session = MailSession.make(
            aiProviderSettings: .preview(), initialDestination: .allInboxes,
            viewModelProvider: { _ in
                let rows = MessageRowModel.threadedRows(from: store.messages(
                    inMailboxPath: "INBOX", accountID: account.id
                ))
                let preview = InboxViewModel.preview()
                return InboxViewModel(chrome: preview.chrome, sidebarItems: preview.sidebarItems,
                    smartCards: SmartInboxCardModel.cards(from: rows), classicRows: rows,
                    selectedThread: preview.selectedThread, aiIndexStatus: preview.aiIndexStatus)
            }
        )
        // Use the session's actual snapshot, bus and models with the production
        // activity wiring; its monitor alone is private to this causal fixture.
        let activity = MailActivityCoordinator(
            refreshBus: session.refreshBus, inboxSnapshot: session.inboxSnapshot,
            approvalQueue: session.approvalQueue, nodeStatus: session.nodeStatus,
            accountSetup: session.accountSetup, storeChanges: monitor,
            smartInbox: session.smartInboxActivity, maintenance: session.maintenance,
            selectedMessageID: { nil }, invalidateSnapshot: {}, refreshSearchMailboxes: { _ in },
            refreshSmartInbox: {}, locale: Locale(identifier: "en_US")
        )
        let attachment = Task { await activity.attach() }
        let discovery = PublicationFetchGate(arrived: expectation(description: "Initial SEARCH held"))
        let history = PublicationFetchGate(arrived: expectation(description: "Old history UID 2 held"))
        let client = PublicationIMAPClient(accountID: account.id, discovery: discovery, history: history)
        let sync = Task {
            try await IMAPSyncService(client: client, cache: store).syncInbox(
                credentials: IMAPAccountCredentials(accountID: account.id, email: account.email,
                    username: "synthetic@example.test", password: "synthetic-fixture"),
                options: .init(recentMessageLimit: 1, downloadCompleteHistory: true, batchSize: 1)
            )
        }
        do {
            await fulfillment(of: [discovery.arrived], timeout: 5)
            // Discovery posts accounts. Drain that earlier refresh before any
            // message is admitted, so it cannot mask a missing commit signal.
            let discoverySettled = await publicationWait {
                monitor.accountRevision > 0 && session.inboxSnapshot.completedRefreshes >= 2
            }
            XCTAssertTrue(discoverySettled, "Account signal and initial empty projection must be acknowledged")
            XCTAssertTrue(session.inboxSnapshot.model.classicRows.isEmpty)
            let operationRevision = monitor.operationRevision
            await discovery.release()
            await fulfillment(of: [history.arrived], timeout: 5)
            XCTAssertTrue(try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7).contains(4))
            XCTAssertFalse(try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7).contains(2))
            let newMessage = try XCTUnwrap(store.messages(inMailboxPath: "INBOX", accountID: account.id)
                .first { $0.subject == "Publication 4" })
            let deliveredProgress = await publicationWait { monitor.operationRevision > operationRevision }
            XCTAssertTrue(deliveredProgress, "The slower operations debounce acknowledges delivered store progress")
            let publishedBeforeSignal = session.inboxSnapshot.model.classicRows.contains { $0.id == newMessage.id.rawValue }
            print("PUBLICATION_DIAGNOSTIC db_has_arrival=true history_held=true mailbox_revision=\(monitor.mailboxRevision) snapshot_has_arrival=\(publishedBeforeSignal)")
            XCTAssertTrue(publishedBeforeSignal, "Committed fresh mail must reach the actual session snapshot while old history remains held")

            // Positive control: the identical SQL-backed projection must update
            // while history is still held once a mailbox hint is delivered.
            let refreshed = session.inboxSnapshot.completedRefreshes
            center.post(name: MailStoreChangeSignal.notificationName, object: nil,
                userInfo: [MailStoreChangeSignal.scopeUserInfoKey: MailStoreChangeScope.mailbox.rawValue])
            let positiveControl = await publicationWait {
                session.inboxSnapshot.completedRefreshes > refreshed
                    && session.inboxSnapshot.model.classicRows.contains { $0.id == newMessage.id.rawValue }
            }
            XCTAssertTrue(positiveControl, "Explicit mailbox signal must publish the committed arrival before history is released")
            XCTAssertFalse(try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7).contains(2))
            print("PUBLICATION_DIAGNOSTIC mailbox_positive_control=\(positiveControl) history_still_held=true")
        } catch {
            await discovery.release()
            await history.release()
            sync.cancel()
            _ = try? await sync.value
            attachment.cancel()
            await attachment.value
            throw error
        }
        await discovery.release()
        await history.release()
        let completion = await sync.result
        attachment.cancel()
        await attachment.value
        _ = try completion.get()
    }

    private func publicationWait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testDisabledSmartInboxPreferenceUsesAllInboxesAtSessionLaunchAndRejectsReentry() throws {
        let suite = "SmartInboxSessionPolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "Plainpost.smartInbox.enabled")
        let settings = AIProviderSettingsViewModel.preview(
            preferenceStore: UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        )
        let session = MailSession.make(aiProviderSettings: settings, initialDestination: .smartInbox)
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        session.mailbox.enterMailbox(.smartInbox, unreadOnly: false)
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        session.mailbox.showSmartInboxOverview()
        XCTAssertEqual(session.mailbox.currentListContext(), .mailbox(destination: .allInboxes, mode: .focusedList))
    }

    func testUnavailableAIGenerationHidesSmartInboxFromTheSession() throws {
        let suite = "SmartInboxSessionPreIOS26.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSmartInboxMode(.allMail)
        let settings = AIProviderSettingsViewModel.production(
            preferenceStore: preferences, aiGenerationAvailable: false
        )
        let session = MailSession.make(aiProviderSettings: settings, initialDestination: .smartInbox)
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        session.mailbox.enterMailbox(.smartInbox, unreadOnly: false)
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        XCTAssertFalse(session.maintenance.smartInboxEnabled)
        XCTAssertFalse(session.commandCenter.filteredCommands.contains { $0.id == "go_smart_inbox" })
    }

    func testDisablingSmartInboxReroutesOpenReaderAndRetainedCommandsWhileOtherActivityRemains() {
        let settings = AIProviderSettingsViewModel.preview()
        let session = MailSession.make(aiProviderSettings: settings, initialDestination: .smartInbox)
        session.mailbox.openMessage("m1", from: .smartInboxOverview)
        settings.setSmartInboxMode(.off)
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        XCTAssertEqual(session.mailbox.mailboxNavigation.route, .list(.mailbox(destination: .allInboxes, mode: .focusedList)))
        session.mailbox.setDestination(.smartInbox)
        session.mailbox.showSmartInboxOverview()
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        XCTAssertFalse(session.maintenance.smartInboxEnabled)
        XCTAssertFalse(session.commandCenter.filteredCommands.contains { $0.id == "go_smart_inbox" })
        XCTAssertThrowsError(try session.commandCenter.execute(commandID: "go_smart_inbox"))
        XCTAssertTrue(session.commandCenter.filteredCommands.contains { $0.id == "search_mail" })
        session.activity.hostActivities = [.hostSync(accountTitle: "Synthetic", detail: nil, fraction: nil)]
        XCTAssertEqual(session.activity.activities.map(\.kind), [.sync])
        settings.setSmartInboxMode(.allMail)
        XCTAssertTrue(session.maintenance.smartInboxEnabled)
        session.mailbox.enterMailbox(.smartInbox, unreadOnly: false)
        XCTAssertEqual(session.mailbox.selectedDestination, .smartInbox)
    }

    func testSwitchingBetweenEnabledSmartInboxModesPreservesCommandCenterSelection() {
        let settings = AIProviderSettingsViewModel.preview()
        let commandCenter = CommandCenterViewModel()
        let session = MailSession.make(commandCenter: commandCenter, aiProviderSettings: settings)
        commandCenter.select(commandID: "go_drafts")
        XCTAssertEqual(session.commandCenter.selectedCommandID, "go_drafts")
        // .allMail -> .newMailOnly is enabled -> enabled: it must not look like a disable/re-enable
        // to subscribers, or it clobbers unrelated state such as the command palette's selection.
        settings.setSmartInboxMode(.newMailOnly)
        XCTAssertTrue(settings.smartInboxEnabled)
        XCTAssertEqual(
            session.commandCenter.selectedCommandID, "go_drafts",
            "Switching between enabled Smart Inbox modes must not reset the command palette selection"
        )
    }

    func testRetainedSmartInboxMessageCallbackAfterDisableKeepsAllInboxesReaderAndBack() {
        let settings = AIProviderSettingsViewModel.preview()
        let session = MailSession.make(aiProviderSettings: settings, initialDestination: .smartInbox)
        let retainedRowOpen = { session.openMailboxMessage("m1", destination: .smartInbox, from: .smartInboxOverview) }
        settings.setSmartInboxMode(.off)
        retainedRowOpen()
        XCTAssertFalse(settings.smartInboxEnabled)
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        XCTAssertEqual(session.mailbox.mailboxNavigation.route,
            .reader(messageID: "m1", returnContext: .mailbox(destination: .allInboxes, mode: .focusedList)))
        session.mailbox.returnToList()
        XCTAssertEqual(session.mailbox.selectedDestination, .allInboxes)
        XCTAssertEqual(session.mailbox.mailboxNavigation.route,
            .list(.mailbox(destination: .allInboxes, mode: .focusedList)))
        settings.setSmartInboxMode(.allMail)
        retainedRowOpen()
        XCTAssertEqual(session.mailbox.selectedDestination, .smartInbox)
        XCTAssertEqual(session.mailbox.mailboxNavigation.route,
            .reader(messageID: "m1", returnContext: .smartInboxOverview))
    }

    private func hooks(
        failures: @escaping @MainActor (String) -> Void = { _ in },
        askMail: @escaping @MainActor (String) -> Void = { _ in },
        approvals: @escaping @MainActor () -> Void = {},
        allowsRefresh: @escaping @MainActor () -> Bool = { true },
        markReadFailed: @escaping @MainActor () -> Void = {},
        attachmentEvent: @escaping @MainActor (PlainpostAttachmentEvent) -> Void = { _ in }
    ) -> MailSessionLifecycleHooks {
        MailSessionLifecycleHooks(
            reportFailure: failures,
            presentAskMail: askMail,
            didRefreshApprovals: approvals,
            allowsSmartInboxRefreshOnAppear: allowsRefresh,
            markReadFailed: markReadFailed,
            attachmentEvent: attachmentEvent
        )
    }

    private struct FailingMailAction: InboxMailActionHandling {
        func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
            throw PlainpostError.permissionDenied("IMAP refused")
        }
    }

    func testConnectRoutesActionFailuresToTheHost() async {
        let session = MailSession.make(inboxMailActions: InboxMailActionViewModel(handler: FailingMailAction()))
        var failures: [String] = []
        session.connectLifecycle(hooks(failures: { failures.append($0) }), locale: Locale(identifier: "en_US"))

        let succeeded = await session.actions.performReturningOutcome(.archive, messageID: "m1", origin: .mailbox)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(failures, ["IMAP refused"])
    }

    func testSearchHandsItsQueryToAskMailAndPresentsIt() {
        let session = MailSession.make()
        var presented: [String] = []
        session.connectLifecycle(hooks(askMail: { presented.append($0) }), locale: .current)

        session.search.askMail("invoices from May")

        XCTAssertEqual(session.askMail.input, "invoices from May")
        XCTAssertEqual(presented, ["invoices from May"])
    }

    func testActivityTakesTheHostLocaleAndApprovalHook() {
        let session = MailSession.make()
        var approvalsLoaded = 0
        session.connectLifecycle(hooks(approvals: { approvalsLoaded += 1 }), locale: Locale(identifier: "de_CH"))

        session.activity.didRefreshApprovals()

        XCTAssertEqual(session.activity.locale.identifier, "de_CH")
        XCTAssertEqual(approvalsLoaded, 1)
    }

    func testOnAppearSmartInboxRefreshAsksTheHostFirst() async {
        var runs = 0
        let session = MailSession.make(
            refreshSmartInbox: { _, _, _ in runs += 1; return "Up to date" },
            aiGenerationAvailable: { true }
        )
        session.connectLifecycle(hooks(allowsRefresh: { false }), locale: .current)
        await session.activity.refreshSmartInbox()
        XCTAssertEqual(runs, 0, "a design preview or pending setup skips the refresh")

        session.connectLifecycle(hooks(allowsRefresh: { true }), locale: .current)
        await session.activity.refreshSmartInbox()
        XCTAssertEqual(runs, 1)
    }

    /// Ledger Task 6: the iPhone shell skips the on-appear Smart Inbox run while first-run setup
    /// shows, with the same hook it builds from `isAccountSetupPending`. Calls
    /// `MailSession.allowsSmartInboxRefreshOnAppear` directly (task-3-review Minor 7, Ruling 8)
    /// rather than restating its `!isAccountSetupPending` logic inline, so a regression in that
    /// shared predicate — the one `MobileMailShell`'s hook actually calls — fails this test too.
    func testSmartInboxRefreshWaitsForAPendingAccountSetup() async {
        var runs = 0
        let session = MailSession.make(
            viewModel: .loading(requiresAccountSetup: true),
            refreshSmartInbox: { _, _, _ in runs += 1; return "Up to date" },
            aiGenerationAvailable: { true }
        )
        XCTAssertTrue(session.isAccountSetupPending)
        session.connectLifecycle(
            hooks(allowsRefresh: { [weak session] in
                MailSession.allowsSmartInboxRefreshOnAppear(isAccountSetupPending: session?.isAccountSetupPending ?? true)
            }),
            locale: .current
        )
        await session.activity.refreshSmartInbox()
        XCTAssertEqual(runs, 0, "no Smart Inbox run while setup is pending")

        XCTAssertFalse(MailSession.make().isAccountSetupPending, "an account is set up")
    }

    func testOnAppearSmartInboxRefreshNeedsAI() async {
        var runs = 0
        let session = MailSession.make(
            refreshSmartInbox: { _, _, _ in runs += 1; return "Up to date" },
            aiGenerationAvailable: { false }
        )
        session.connectLifecycle(hooks(), locale: .current)
        await session.activity.refreshSmartInbox()
        XCTAssertEqual(runs, 0)
    }

    /// These tests mount the real shared modifier, so omitted event wiring fails at its
    /// host boundary rather than passing by calling a controller callback directly.
    private func host(_ session: MailSession, hooks: MailSessionLifecycleHooks) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(
            Color.clear.modifier(MailSessionLifecycle(session: session, hooks: hooks))
                .frame(width: 120, height: 80)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func detach(_ host: NSHostingView<AnyView>) {
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
    }

    func testHostedLifecycleConfiguresAllAIConsumersOnAttachAndProviderChange() async {
        let providers = AIProviderSettingsViewModel(statuses: [
            AIProviderStatusService.foundation(availability: .available),
            AIProviderStatusSnapshot(providerID: "ollama", displayName: "Ollama", state: .ready,
                                     chatModelID: "chat", embeddingModelID: "embed", localOnly: true, detail: "Ready")
        ], selectedProviderID: "foundation")
        let attached = MailRefreshTestCounter()
        let changed = MailRefreshTestCounter()
        var assistant: [String] = []
        var ask: [(model: AskMailViewModel, id: String)] = []
        var translation: [String] = []
        let session = MailSession.make(
            aiProviderSettings: providers,
            configureAIAssistant: { _, id in assistant.append(id) },
            configureAskMail: { model, id in ask.append((model, id)) },
            configureThreadTranslation: { _, id in
                translation.append(id)
                if id == "ollama" { changed.record() }
            }
        )
        // Both Ask Mails follow the provider: the global one and the ✦ pane's.
        func askConfigurations() -> [String] {
            ask.map { ($0.model === session.askMail ? "global " : $0.model === session.conversationAskMail ? "pane " : "other ") + $0.id }
        }
        let view = host(session, hooks: hooks(approvals: { attached.record() }))
        defer { detach(view) }
        await attached.wait(for: 1)
        XCTAssertEqual(assistant, ["foundation"])
        XCTAssertEqual(askConfigurations(), ["global foundation", "pane foundation"])
        XCTAssertEqual(translation, ["foundation"])

        providers.selectProvider("ollama")
        await changed.wait(for: 1)
        XCTAssertEqual(assistant, ["foundation", "ollama"])
        XCTAssertEqual(askConfigurations(), ["global foundation", "pane foundation", "global ollama", "pane ollama"])
        XCTAssertEqual(translation, ["foundation", "ollama"])
    }

    /// A provider change makes the assistant forget the ✦ pane's conversation; the real modifier
    /// tells the pane, which prepares it again.
    func testHostedProviderChangePreparesThePanesConversationAgain() async {
        let providers = AIProviderSettingsViewModel(statuses: [
            AIProviderStatusService.foundation(availability: .available),
            AIProviderStatusSnapshot(providerID: "ollama", displayName: "Ollama", state: .ready,
                                     chatModelID: "chat", embeddingModelID: "embed", localOnly: true, detail: "Ready")
        ], selectedProviderID: "foundation")
        let attached = MailRefreshTestCounter()
        let changed = MailRefreshTestCounter()
        let session = MailSession.make(
            aiProviderSettings: providers,
            configureAIAssistant: { model, id in model.configure(assistant: PaneAssistant(), providerID: id) },
            configureThreadTranslation: { _, id in
                if id == "ollama" { changed.record() }
            }
        )
        let view = host(session, hooks: hooks(approvals: { attached.record() }))
        defer { detach(view) }
        await attached.wait(for: 1)
        session.conversationAI.setConversation(planContext(selected: "m2"))
        XCTAssertTrue(session.conversationAI.summaryIsCurrent)

        providers.selectProvider("ollama")
        await changed.wait(for: 1)
        for _ in 0..<100 where !session.conversationAI.summaryIsCurrent {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(session.conversationAI.localityLabel, "Ollama", "the assistant was configured again")
        XCTAssertTrue(session.conversationAI.summaryIsCurrent, "the pane prepared its conversation again")
    }

    func testHostedAccountChangesCoalesceSearchReadsAndDetachCancelsTheirOwner() async {
        let setup = AccountSetupViewModel.connectedPreview()
        let attached = MailRefreshTestCounter()
        let updated = MailRefreshTestCounter()
        let searchGate = MailRefreshTestBarrier()
        let session = MailSession.make(accountSetup: setup, refreshMailSearchMailboxes: { _ in
            await searchGate.wait()
        })
        let view = host(session, hooks: hooks(approvals: { attached.record() }))
        await attached.wait(for: 1)
        let subscription = session.mailSearch.$accounts.dropFirst().sink { _ in updated.record() }
        for (offset, title) in ["Work", "Personal again", "Current account"].enumerated() {
            setup.displayName = title
            setup.saveAccountSettings()
            view.layoutSubtreeIfNeeded()
            await updated.wait(for: offset + 1)
            // Let the host finish this render transaction before the next account edit.
            await Task.yield()
            if offset == 0 { await searchGate.arrived.wait(for: 1) }
        }
        XCTAssertEqual(session.mailSearch.accounts.first?.displayName, "Current account")
        XCTAssertEqual(searchGate.arrived.count, 1, "account changes merge into the attach-owned search worker")

        detach(view)
        await fulfillment(of: [searchGate.cancelled], timeout: 5)
        searchGate.release()
        await searchGate.departed.wait(for: searchGate.arrived.count)
        subscription.cancel()
        XCTAssertEqual(searchGate.arrived.count, 1, "detach closes admission for the merged account refresh")
    }

    func testHostedMessageOpenReportsReadFailureForTheSelection() async {
        let opened = MailRefreshTestCounter()
        let reported = MailRefreshTestCounter()
        var openedIDs: [String] = []
        let session = MailSession.make(openMessage: { id in
            openedIDs.append(id)
            opened.record()
            throw PlainpostError.permissionDenied("Read refused")
        }, initialSelectedMessageID: "m-read")
        let view = host(session, hooks: hooks(markReadFailed: { reported.record() }))
        defer { detach(view) }

        await opened.wait(for: 1)
        await reported.wait(for: 1)

        XCTAssertEqual(openedIDs, ["m-read"])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(session.mailbox.selectedMessageID, "m-read")
    }

    /// Marking read and refreshing the mailbox can take seconds on a large store; the reader
    /// shows the opened conversation without waiting for either.
    func testOpenedMessageShowsItsThreadBeforeMarkingItRead() async {
        let gate = MailRefreshTestBarrier()
        var snapshotReads = 0
        let session = MailSession.make(openMessage: { _ in
            await gate.wait()
        }, initialSelectedMessageID: "m-open", viewModelProvider: { _ in
            snapshotReads += 1
            return .preview()
        }, threadProvider: { id in Self.thread(containing: id) })
        let opening = Task { await session.markOpenedMessageRead(reportFailure: {}) }
        await gate.arrived.wait(for: 1)
        XCTAssertEqual(session.inboxSnapshot.model.selectedThread.messages.map(\.id), ["m-open"])
        XCTAssertEqual(snapshotReads, 0, "the thread shows before the mailbox refresh")
        gate.release()
        await opening.value
        XCTAssertEqual(snapshotReads, 1)
    }

    /// Back on the iPhone clears the selection; opening the same message again shows its
    /// conversation in the same turn, not after another read.
    func testReopenedMessageShowsItsLastThreadAtOnce() async {
        let session = MailSession.make(viewModelProvider: { _ in
            InboxViewModel.preview().withMailboxLoadFailure(nil, selectedThread: Self.thread(containing: nil))
        }, threadProvider: { id in Self.thread(containing: id) })
        let context = MailboxListContext.mailbox(destination: .allInboxes, mode: .focusedList)
        session.openMailboxMessage("m-again", destination: .allInboxes, from: context)
        await session.markOpenedMessageRead(reportFailure: {})
        session.mailbox.returnToList()
        await session.inboxSnapshot.refresh(selectedMessageID: nil)
        XCTAssertTrue(session.inboxSnapshot.model.selectedThread.messages.isEmpty)

        session.openMailboxMessage("m-again", destination: .allInboxes, from: context)
        XCTAssertEqual(session.inboxSnapshot.model.selectedThread.messages.map(\.id), ["m-again"])

        session.inboxSnapshot.forgetRecentThreads()
        await session.inboxSnapshot.refresh(selectedMessageID: nil)
        session.inboxSnapshot.showRecentThread(containing: "m-again")
        XCTAssertTrue(session.inboxSnapshot.model.selectedThread.messages.isEmpty, "an account change forgets it")
    }

    private static func thread(containing messageID: String?) -> ThreadDetailModel {
        ThreadDetailModel(
            subject: "Thread", participants: [], summaryStatus: "Not summarized",
            actionItems: [], availableActions: [],
            messages: messageID.map { id in
                [ThreadMessageModel(id: id, sender: "a@example.com", dateLabel: "Now", body: .plainText("Hi"))]
            } ?? []
        )
    }

    func testSupersededMessageOpenCannotReportFailureOrRefreshTheNewSelection() async {
        let gate = MailRefreshTestBarrier()
        var failures = 0
        var snapshotReads = 0
        let session = MailSession.make(openMessage: { _ in
            await gate.wait()
            throw PlainpostError.permissionDenied("Old message refused")
        }, initialSelectedMessageID: "old", viewModelProvider: { _ in
            snapshotReads += 1
            return .preview()
        })
        let opening = Task { await session.markOpenedMessageRead(reportFailure: { failures += 1 }) }
        await gate.arrived.wait(for: 1)
        session.mailbox.openMessage("new", from: .mailbox(destination: .allInboxes, mode: .focusedList))
        gate.release()
        await opening.value
        XCTAssertEqual(failures, 0, "an old message's error cannot be presented on the new selection")
        XCTAssertEqual(snapshotReads, 0, "an old completion cannot start a refresh for the new selection")
    }

    func testDetachedMessageOpenJoinsWithoutPresentingItsLateFailure() async {
        let gate = MailRefreshTestBarrier()
        var failures = 0
        let session = MailSession.make(openMessage: { _ in
            await gate.wait()
            throw PlainpostError.permissionDenied("Detached read refused")
        }, initialSelectedMessageID: "old")
        let opening = Task { await session.markOpenedMessageRead(reportFailure: { failures += 1 }) }
        await gate.arrived.wait(for: 1)
        opening.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        gate.release()
        await opening.value
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(session.inboxSnapshot.completedRefreshes, 0)
    }

    func testAccountRevisionFencesOldReadFailureButCurrentFailureStillReports() async {
        let gate = MailRefreshTestBarrier()
        let accountChanged = MailRefreshTestCounter()
        var failures = 0
        var snapshotReads = 0
        let session = MailSession.make(openMessage: { _ in
            await gate.wait()
            throw PlainpostError.permissionDenied("Read refused")
        }, initialSelectedMessageID: "same-local-id", viewModelProvider: { _ in
            snapshotReads += 1
            return .preview()
        })
        let opening = Task { await session.markOpenedMessageRead(reportFailure: { failures += 1 }) }
        await gate.arrived.wait(for: 1)
        let subscription = session.storeChangeMonitor.$accountRevision.dropFirst().sink { _ in accountChanged.record() }
        NotificationCenter.default.post(name: MailStoreChangeSignal.notificationName, object: nil,
                                        userInfo: [MailStoreChangeSignal.scopeUserInfoKey: "accounts"])
        await accountChanged.wait(for: 1)
        gate.release()
        await opening.value
        subscription.cancel()
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(snapshotReads, 0)

        await session.markOpenedMessageRead(reportFailure: { failures += 1 })
        XCTAssertEqual(failures, 1, "the active source's error remains visible")
        XCTAssertEqual(snapshotReads, 1)
    }

    func testSelectionChangeDuringOpenedMessageRefreshRejectsTheOldSnapshot() async {
        let gate = MailRefreshTestBarrier()
        let session = MailSession.make(initialSelectedMessageID: "old", viewModelProvider: { _ in
            await gate.wait()
            return .preview()
        })
        let opening = Task { await session.markOpenedMessageRead(reportFailure: {}) }
        await gate.arrived.wait(for: 1)
        session.mailbox.openMessage("new", from: .mailbox(destination: .allInboxes, mode: .focusedList))
        gate.release()
        await opening.value
        XCTAssertEqual(session.inboxSnapshot.completedRefreshes, 0, "the stale read cannot publish over a new selection")
    }

    func testHostedAccountRevisionReattachesAskMailWithCurrentMutationAuthority() async {
        let session = MailSession.make(allowsMailboxMutations: { false })
        let attached = MailRefreshTestCounter()
        let reattached = MailRefreshTestCounter()
        let view = host(session, hooks: hooks(approvals: { attached.record() }))
        defer { detach(view) }
        await attached.wait(for: 1)
        // An old sheet's host is deliberately permissive; a source revision must replace it.
        session.askMail.setHost(.preview)
        let subscription = session.askMail.$host.dropFirst().sink { _ in reattached.record() }
        defer { subscription.cancel() }
        NotificationCenter.default.post(name: MailStoreChangeSignal.notificationName, object: nil,
                                        userInfo: [MailStoreChangeSignal.scopeUserInfoKey: "accounts"])
        await reattached.wait(for: 1)

        XCTAssertFalse(session.askMail.host.allowsMutations())
        let result = await session.askMail.host.mailAction(.archive, MessageID("m1"))
        XCTAssertFalse(result, "reattaching must preserve the current account's read-only authority")
        XCTAssertNil(session.actions.pendingUndo)
    }

    func testHostedOnboardingForwardsCompletedAccountAndUpdatesSearch() async throws {
        let setup = AccountSetupViewModel.preview()
        let attached = MailRefreshTestCounter()
        let connected = MailRefreshTestCounter()
        let accountsUpdated = MailRefreshTestCounter()
        var connections: [AccountID] = []
        let session = MailSession.make(accountSetup: setup, onAccountSetupConnected: {
            connections.append($0)
            connected.record()
        })
        let view = host(session, hooks: hooks(approvals: { attached.record() }))
        defer { detach(view) }
        await attached.wait(for: 1)
        let subscription = session.mailSearch.$accounts.dropFirst().sink { accounts in
            if accounts.map(\.id) == [AccountID("acc_preview")] { accountsUpdated.record() }
        }
        defer { subscription.cancel() }

        try await setup.submit()
        await connected.wait(for: 1)
        await accountsUpdated.wait(for: 1)
        XCTAssertEqual(connections, [AccountID("acc_preview")])
        XCTAssertEqual(session.mailSearch.accounts.map(\.id), [AccountID("acc_preview")])

        setup.selectAccount(id: AccountID("acc_preview"))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(connections.count, 1, "editing or selecting an account does not repeat onboarding")
    }

    func testAttachmentCompletionAfterAccountSwitchCannotReachTheNewHost() async throws {
        let oldState = PlainpostAttachmentState(accountID: "old")
        let oldToken = oldState.begin(attachmentID: "attachment")
        let oldSession = MailSession.make(attachmentState: oldState)
        let oldAttached = MailRefreshTestCounter()
        var oldEvents: [PlainpostAttachmentEvent] = []
        let oldView = host(oldSession, hooks: hooks(approvals: { oldAttached.record() },
                                                  attachmentEvent: { oldEvents.append($0) }))
        await oldAttached.wait(for: 1)
        detach(oldView)
        // Runtime shutdown clears admitted attachment tokens before the new runtime appears.
        oldState.clear()

        let newState = PlainpostAttachmentState(accountID: "new")
        let newSession = MailSession.make(attachmentState: newState)
        let newAttached = MailRefreshTestCounter()
        let presented = MailRefreshTestCounter()
        var newEvents: [PlainpostAttachmentEvent] = []
        let newView = host(newSession, hooks: hooks(approvals: { newAttached.record() }, attachmentEvent: {
            newEvents.append($0)
            presented.record()
        }))
        defer { detach(newView); newState.clear() }
        await newAttached.wait(for: 1)

        let staleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-stale-\(UUID())")
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        let staleURL = staleDirectory.appendingPathComponent("stale.txt")
        try Data("old account".utf8).write(to: staleURL)
        let stale = PlainpostAttachmentEvent(accountID: "old", attachmentID: "attachment", operationToken: oldToken,
                                            outcome: .saved(.init(url: staleURL, filename: "stale.txt")))
        oldState.publish(stale)
        XCTAssertNil(oldState.event)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory.path))

        let currentToken = newState.begin(attachmentID: "attachment")
        newState.publish(stale)
        let current = PlainpostAttachmentEvent(accountID: "new", attachmentID: "attachment", operationToken: currentToken,
                                              outcome: .failed("Current account download refused"))
        newState.publish(current)
        await presented.wait(for: 1)
        XCTAssertEqual(newEvents, [current], "only this runtime's current operation reaches presentation")
        XCTAssertEqual(oldEvents, [])
    }

    func testConnectedLifecycleReleasesSessionAndHostHooksAfterDetachJoins() async {
        final class HostState { var approvals = 0 }
        weak var releasedSession: MailSession?
        weak var releasedHost: HostState?
        let gate = MailRefreshTestBarrier()
        do {
            let hostState = HostState()
            let session = MailSession.make(viewModelProvider: { _ in
                await gate.wait()
                return .preview()
            })
            releasedSession = session
            releasedHost = hostState
            session.connectLifecycle(hooks(approvals: { hostState.approvals += 1 }), locale: .current)
            session.attachAskMailHost()
            let attachment = Task { await session.activity.attach() }
            await gate.arrived.wait(for: 1)
            attachment.cancel()
            await fulfillment(of: [gate.cancelled], timeout: 5)
            gate.release()
            await attachment.value
            XCTAssertEqual(hostState.approvals, 0, "a detached bootstrap cannot present approvals")
        }
        XCTAssertNil(releasedSession)
        XCTAssertNil(releasedHost, "session callbacks must release their host's presentation state")
    }

    // MARK: Background commit

    /// Records the background-task hooks `MailSessionBackgroundCommit` calls.
    @MainActor
    private final class AssertionRecorder {
        var begun: [String] = []
        var ended: [Int] = []
        var expiry: (@MainActor @Sendable () -> Void)?

        var commit: MailSessionBackgroundCommit {
            MailSessionBackgroundCommit(
                begin: { name, expiry in
                    self.begun.append(name)
                    self.expiry = expiry
                    return 42
                },
                end: { self.ended.append($0) }
            )
        }
    }

    /// Holds the backend's answer until `open()`, so a test can act while a commit is in flight.
    @MainActor
    private final class BackendGate {
        var performed: [String] = []
        private var waiting: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func perform(_ messageID: String) async -> InboxMailActionOutcome {
            performed.append(messageID)
            if !isOpen { await withCheckedContinuation { waiting = $0 } }
            return .succeeded(.init(messageID: MessageID(messageID), action: .archive))
        }

        func open() {
            isOpen = true
            waiting?.resume()
            waiting = nil
        }
    }

    /// The iPhone's 4 s Undo window, with a real sleep that only a commit or Undo ends early.
    private func graceActions(_ backend: BackendGate) -> MessageActionController {
        let mailbox = MailboxController(
            destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue, selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
        )
        return MessageActionController(
            mailbox: mailbox, refreshBus: MailboxRefreshBus(), commitDelay: .seconds(600),
            perform: { _, id in await backend.perform(id) },
            reproject: {}, reportFailure: { _ in }
        )
    }

    func testBackgroundWithNothingPendingTakesNoAssertion() {
        let backend = BackendGate()
        let recorder = AssertionRecorder()

        XCTAssertNil(recorder.commit.run(graceActions(backend)))

        XCTAssertEqual(recorder.begun, [])
        XCTAssertEqual(recorder.ended, [])
    }

    func testBackgroundWithAPendingArchiveCommitsOnceAndEndsTheAssertion() async throws {
        let backend = BackendGate()
        backend.open()
        let actions = graceActions(backend)
        let recorder = AssertionRecorder()
        actions.perform(.archive, messageID: "m1")
        XCTAssertEqual(backend.performed, [], "still inside the Undo window")

        let commit = try XCTUnwrap(recorder.commit.run(actions))
        let started = ContinuousClock.now
        await commit.value

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "backgrounding ends the 600 s wait")
        XCTAssertEqual(recorder.begun, [MailSessionBackgroundCommit.taskName])
        XCTAssertEqual(backend.performed, ["m1"], "the archive reaches the backend exactly once")
        XCTAssertEqual(recorder.ended, [42], "the assertion ends once the backend has answered")
        XCTAssertFalse(actions.hasPendingGraceActions)

        await actions.waitForStartedActions()
        recorder.expiry?()
        XCTAssertEqual(backend.performed, ["m1"])
        XCTAssertEqual(recorder.ended, [42], "a late expiry doesn't end the assertion twice")
    }

    func testBackgroundExpiryEndsTheAssertionOnceAndTheArchiveStillCommitsOnce() async throws {
        let backend = BackendGate()
        let actions = graceActions(backend)
        let recorder = AssertionRecorder()
        actions.perform(.archive, messageID: "m1")

        let commit = try XCTUnwrap(recorder.commit.run(actions))
        let deadline = ContinuousClock.now + .seconds(5)
        while backend.performed.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(backend.performed, ["m1"], "the commit is in flight")

        // The system runs out of time before the backend answers.
        try XCTUnwrap(recorder.expiry)()
        XCTAssertEqual(recorder.ended, [42], "expiry ends the assertion at once")

        backend.open()
        await commit.value
        XCTAssertEqual(backend.performed, ["m1"], "the archive is sent once, not retried")
        XCTAssertEqual(recorder.ended, [42], "finishing after expiry doesn't end it again")
    }
}
