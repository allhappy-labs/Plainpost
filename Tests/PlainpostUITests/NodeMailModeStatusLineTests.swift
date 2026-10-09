import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostServiceIPC
@testable import PlainpostUI
import PlainpostRuntimeTestSupport

final class NodeMailModeStatusLineTests: XCTestCase {
    func testTheStatusLineTextForEveryState() {
        func line(_ state: PlainpostNodeMailModeStatus.State) -> String? {
            NodeMailModeStatusLine.text(for: PlainpostNodeMailModeStatus(state: state, nodeBackedAccountCount: 1, waitingIntentCount: 0))
        }
        XCTAssertEqual(line(.connectedDirectly), "Sync Node unavailable — connected directly")
        XCTAssertEqual(line(.updateRequired), "Update your Sync Node")
        XCTAssertEqual(line(.reconnectRequired), "Reconnect Sync Node")
        XCTAssertNil(line(.connected))
        XCTAssertNil(line(.noNode))
        XCTAssertNil(NodeMailModeStatusLine.text(for: nil), "an unreachable or older service shows nothing")
    }

    func testTheMailboxHeaderCarriesTheStatusLine() {
        let presentation = MailboxHeaderPresentation(title: "Inbox", conversationCountLabel: "2 conversations",
                                                     statusLine: "Sync Node unavailable — connected directly")
        XCTAssertEqual(presentation.statusLine, "Sync Node unavailable — connected directly")
        let plain = MailboxHeaderPresentation.make(title: "Inbox", availableRows: [], mode: .focusedList, destination: .allInboxes)
        XCTAssertNil(plain.statusLine)
    }

    @MainActor
    func testADirectChangeWaitingOnAnUnreachableServerShowsItsReason() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanUp() }
        try fixture.setMode(.fallback)
        let model = NodeMailModeStatusModel(fetchStatus: { .noNode }, store: fixture.store, defaults: fixture.defaults)
        await model.refresh()
        XCTAssertNil(model.statusLine)
        let id = try fixture.queueSend(subject: "Later")
        _ = try fixture.store.beginMailIntentDispatch(operationID: id, route: .direct, now: Date())
        _ = try fixture.store.deferDirectMailIntent(operationID: id, now: Date(), transient: TransientDirectDeferral(
            reason: .mailServerUnreachable, attempts: 1, startedAt: Date(),
            nextAttemptAt: Date().addingTimeInterval(30)))
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Notice: Plainpost couldn't reach your mail server. It will retry.",
                       "the line names the account")

        // A later passing deferral (the vault locked) keeps the transient reason.
        _ = try fixture.store.beginMailIntentDispatch(operationID: id, route: .direct, now: Date())
        _ = try fixture.store.deferDirectMailIntent(operationID: id, now: Date())
        XCTAssertEqual(try fixture.store.mailIntent(operationID: id)?.deferralReason, .mailServerUnreachable)
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Notice: Plainpost couldn't reach your mail server. It will retry.")

        // Back in Node mode the row no longer waits on the mail server.
        try fixture.setMode(.node)
        await model.refresh()
        XCTAssertNil(model.statusLine, "only rows pending a direct dispatch count")
    }

    @MainActor
    func testASendThatFailedAfterRetriesSaysWhy() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanUp() }
        try fixture.setMode(.fallback)
        let start = fixture.start
        let model = NodeMailModeStatusModel(fetchStatus: { .noNode }, store: fixture.store, defaults: fixture.defaults,
                                            now: { start })
        await model.refresh()
        let id = try fixture.queueSend(subject: "Later", at: fixture.start.addingTimeInterval(10))
        _ = try fixture.store.beginMailIntentDispatch(operationID: id, route: .direct, now: fixture.start.addingTimeInterval(11))
        _ = try fixture.store.failDeferredDirectMailIntent(operationID: id, reason: .mailServerUnreachable,
                                                           now: fixture.start.addingTimeInterval(12))
        await model.refresh()
        XCTAssertEqual(model.notice?.message,
                       "Couldn't send “Later”. Plainpost couldn't reach your mail server. It's in Drafts.")
    }

    @MainActor
    func testTheModelPollsTheServiceAndClearsTheLineWhenTheServiceCannotAnswer() async throws {
        let answers = StatusAnswers([
            .success(PlainpostNodeMailModeStatus(state: .connectedDirectly, nodeBackedAccountCount: 1, waitingIntentCount: 2)),
            .success(PlainpostNodeMailModeStatus(state: .reconnectRequired, nodeBackedAccountCount: 1, waitingIntentCount: 0)),
            .failure(PlainpostServiceClientError.serviceUnavailable),
        ])
        let fixture = try NoticeFixture()
        defer { fixture.cleanUp() }
        let model = NodeMailModeStatusModel(
            fetchStatus: { try answers.next() }, store: fixture.store, defaults: fixture.defaults
        )
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Sync Node unavailable — connected directly")
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Reconnect Sync Node")
        await model.refresh()
        XCTAssertNil(model.statusLine)
    }

    @MainActor
    func testASendThatLaterFailsOrIsUnconfirmedShowsANoticeNamingTheMessage() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanUp() }
        let model = NodeMailModeStatusModel(fetchStatus: { .noNode }, store: fixture.store, defaults: fixture.defaults,
                                            now: { [start = fixture.start] in start })
        await model.refresh()                       // first run: only later outcomes are shown
        XCTAssertNil(model.notice)

        let failed = try fixture.failSend(subject: "Quarterly plan", at: fixture.start.addingTimeInterval(120))
        await model.refresh()
        XCTAssertEqual(model.notice?.id, failed)
        XCTAssertEqual(model.notice?.message, "Couldn't send “Quarterly plan”. It's in Drafts.")

        let unconfirmed = try fixture.unconfirmSend(subject: "Offer letter", at: fixture.start.addingTimeInterval(180))
        await model.refresh()
        XCTAssertEqual(model.notice?.id, failed, "notices show oldest first")
        model.dismissNotice()
        XCTAssertEqual(model.notice?.id, unconfirmed)
        XCTAssertEqual(model.notice?.message, "“Offer letter” may have been sent. Check Sent before sending it again.")
        model.dismissNotice()
        XCTAssertNil(model.notice)

        // A dismissed notice never returns, also for a new model (a relaunch).
        let relaunched = NodeMailModeStatusModel(fetchStatus: { .noNode }, store: fixture.store, defaults: fixture.defaults)
        await relaunched.refresh()
        XCTAssertNil(relaunched.notice)
    }

    /// A parent re-render calls `makeRootView` again: it must reuse the one
    /// status model, so the status line and the notice survive and no
    /// orphaned model keeps polling.
    @MainActor
    func testAParentReRenderKeepsTheStatusModel() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("node-status-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: RuntimeKeychainIsolation(
                testCase: self, databaseURL: databaseURL,
                keychainService: "NodeMailModeStatusLineTests.\(UUID().uuidString)"
            ).configuration,
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let first = runtime.makeNodeMailModeStatusModel()
        _ = runtime.makeRootView()
        _ = runtime.makeRootView()
        XCTAssertTrue(runtime.makeNodeMailModeStatusModel() === first)
    }

    @MainActor
    func testWhoReportedTheOutcomeDecidesTheNoticeNotHowLongItTook() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanUp() }
        let model = NodeMailModeStatusModel(fetchStatus: { .noNode }, store: fixture.store, defaults: fixture.defaults,
                                            now: { [start = fixture.start] in start })
        await model.refresh()
        // A queued send the drain failed within a second: nobody told the user.
        let drained = try fixture.failSend(subject: "Fast drain", at: fixture.start.addingTimeInterval(60), after: 1)
        // An interactive send that took 30 s and was reported to the composer.
        let reported = try fixture.failSend(subject: "Slow request", at: fixture.start.addingTimeInterval(90), after: 30)
        try fixture.store.markMailIntentReported(operationID: reported)
        await model.refresh()
        XCTAssertEqual(model.notice?.id, drained)
        XCTAssertEqual(model.notice?.message, "Couldn't send “Fast drain”. It's in Drafts.")
        model.dismissNotice()
        XCTAssertNil(model.notice, "the composer already reported the slow failure")
    }

    @MainActor
    func testTwoOutcomesWithOneTimestampAreBothShown() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanUp() }
        let model = NodeMailModeStatusModel(fetchStatus: { .noNode }, store: fixture.store, defaults: fixture.defaults,
                                            now: { [start = fixture.start] in start })
        await model.refresh()
        let at = fixture.start.addingTimeInterval(60)
        let first = try fixture.failSend(subject: "One", at: at)
        let second = try fixture.failSend(subject: "Two", at: at)
        await model.refresh()
        let ordered = [first, second].sorted()
        XCTAssertEqual(model.notice?.id, ordered[0])
        model.dismissNotice()
        XCTAssertEqual(model.notice?.id, ordered[1])
        let relaunched = NodeMailModeStatusModel(fetchStatus: { .noNode }, store: fixture.store, defaults: fixture.defaults)
        await relaunched.refresh()
        XCTAssertEqual(relaunched.notice?.id, ordered[1], "a relaunch still shows the second one")
    }

    @MainActor
    func testTheNoticeQueryIsBoundedAndStartsAfterTheWatermark() async throws {
        let fixture = try NoticeFixture()
        defer { fixture.cleanUp() }
        for index in 0..<25 {
            _ = try fixture.failSend(subject: "Old \(index)", at: fixture.start.addingTimeInterval(Double(index)))
        }
        let rows = try fixture.store.unreportedSendOutcomes(after: fixture.start.addingTimeInterval(4.5), limit: 20)
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(rows.first?.updatedAt, fixture.start.addingTimeInterval(5))
        XCTAssertEqual(NodeSendOutcomeNotice.load(store: fixture.store, after: fixture.start.addingTimeInterval(20)).count, 5,
                       "an outcome at the watermark instant counts unless its ID was dismissed")
        XCTAssertEqual(NodeSendOutcomeNotice.load(store: fixture.store, after: fixture.start.addingTimeInterval(20),
                                                  afterOperationID: "ffffffff-ffff-4fff-bfff-ffffffffffff").count, 4)
    }
}

private final class StatusAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<PlainpostNodeMailModeStatus, any Error>]
    init(_ answers: [Result<PlainpostNodeMailModeStatus, any Error>]) { self.answers = answers }
    func next() throws -> PlainpostNodeMailModeStatus {
        try lock.withLock { answers.removeFirst() }.get()
    }
}

private struct NoticeFixture {
    let directory: URL
    let store: SQLiteMailStore
    let defaults: UserDefaults
    let suite: String
    let accountID = AccountID("acc-notice")
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-send-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteMailStore(path: directory.appendingPathComponent("plainpost.sqlite").path)
        try store.migrate()
        try store.cacheAccounts([Account(id: accountID, displayName: "Notice", email: EmailAddress("notice@example.test"),
                                         imapHost: "imap.example.test", smtpHost: "smtp.example.test")])
        suite = "plainpost-send-notice-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func draft(subject: String?) throws -> Draft {
        try store.createDraft(
            Draft(id: DraftID("drf_notice_\(UUID().uuidString.prefix(8).lowercased())"), accountID: accountID,
                  from: EmailAddress("notice@example.test"), to: [EmailAddress("to@example.test")], cc: [], bcc: [],
                  subject: subject ?? "", bodyPlain: "Hello", createdBy: "local-user", aiGenerated: false, sourceThreadID: nil),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
    }

    func setMode(_ mode: NodeBackedMode) throws {
        var current = try store.mailSource(accountID: accountID)
        if current.kind != .nodeBacked {
            current = try store.replaceMailSource(
                current.nodeBacked(nodeID: "40000000-0000-4000-8000-000000000917",
                                   logicalMailboxID: String(repeating: "A", count: 43), providerIdentity: "notice@example.test"),
                expectedGeneration: current.generation)
        }
        if current.mode != mode {
            _ = try store.replaceMailSource(current.withMode(mode), expectedGeneration: current.generation)
        }
    }

    /// A journaled, not yet dispatched send.
    func queueSend(subject: String, at date: Date = Date()) throws -> String {
        let draft = try draft(subject: subject)
        let id = UUID().uuidString.lowercased()
        _ = try store.journalMailIntent(operationID: id, accountID: accountID, kind: .send, messageID: nil, draftID: draft.id,
                                        contentHash: draft.contentHash, now: date)
        return id
    }

    /// A queued send refused `after` seconds after it was journaled.
    func failSend(subject: String?, at date: Date, after: TimeInterval = 60) throws -> String {
        let draft = try draft(subject: subject)
        let id = UUID().uuidString.lowercased()
        _ = try store.journalMailIntent(operationID: id, accountID: accountID, kind: .send, messageID: nil, draftID: draft.id,
                                        contentHash: draft.contentHash, now: date.addingTimeInterval(-after))
        _ = try store.refuseUnroutedMailIntent(operationID: id, now: date)
        return id
    }

    /// A Node send whose replay the Node answered `conflicted`.
    func unconfirmSend(subject: String, at date: Date) throws -> String {
        let draft = try draft(subject: subject)
        let id = UUID().uuidString.lowercased()
        _ = try store.journalMailIntent(operationID: id, accountID: accountID, kind: .send, messageID: nil, draftID: draft.id,
                                        contentHash: draft.contentHash, now: date.addingTimeInterval(-300))
        _ = try store.beginMailIntentDispatch(operationID: id, route: .node, now: date.addingTimeInterval(-299))
        _ = try store.recordMailIntentOutcome(operationID: id, state: .uncertain, now: date.addingTimeInterval(-298))
        _ = try store.recordMailIntentOutcome(operationID: id, state: .unconfirmed, now: date)
        return id
    }
}
