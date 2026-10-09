import Foundation
import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI
import PlainpostRuntimeTestSupport
import XCTest

/// The Mac composer offers every account as From; the service sends each draft through its
/// own account.
@MainActor
final class MacComposerFromAccountTests: XCTestCase {
    private var savedLastFrom: String?

    override func setUp() async throws {
        savedLastFrom = UserDefaults.standard.string(forKey: ComposerFromAccountPreference.key)
        UserDefaults.standard.removeObject(forKey: ComposerFromAccountPreference.key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedLastFrom, forKey: ComposerFromAccountPreference.key)
    }

    /// A Mac runtime: no selected account and no iOS runtime dependencies.
    private func macRuntime(
        _ fixture: TwoDirectAccountsFixture,
        undoSendSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws -> PlainpostAppRuntime {
        try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: fixture.databaseURL, serviceClient: RuntimeServiceClientFake()
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            undoSendSleep: undoSendSleep
        )
    }

    func testMacNewMessageOffersEveryAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try macRuntime(fixture)
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareNewMessage()
        XCTAssertEqual(Set(composer.fromAccounts.map(\.id)), [fixture.first.id, fixture.second.id])
        XCTAssertNotNil(composer.fromAccountID)
        composer.selectFromAccount(fixture.second.id)
        composer.to = "someone@example.com"
        composer.subject = "From second"
        composer.bodyMarkdown = "Body"
        try await composer.saveDraft()
        XCTAssertEqual(try fixture.store().draft(id: DraftID(try XCTUnwrap(composer.lastDraftID))).accountID, fixture.second.id)
    }

    /// The embedded composer is built once; a reply prepared on it still goes out from the
    /// original's account.
    func testMacEmbeddedComposerReplyUsesTheOriginalsAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try macRuntime(fixture)
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareReply(context: try XCTUnwrap(runtime.makeComposerReplyContext(sourceMessageID: "msg_second_1")))
        XCTAssertEqual(composer.fromAccountID, fixture.second.id)
        XCTAssertTrue(composer.fromAccounts.isEmpty)
        composer.bodyMarkdown = "Thanks"
        try await composer.saveDraft()
        XCTAssertEqual(try fixture.store().draft(id: DraftID(try XCTUnwrap(composer.lastDraftID))).accountID, fixture.second.id)
    }

    func testMacFromSwitchAfterAutosaveDeletesTheOldDraft() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try macRuntime(fixture)
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareNewMessage()
        composer.to = "someone@example.com"
        composer.subject = "Moving"
        composer.bodyMarkdown = "Body"
        try await composer.saveDraft()
        let firstDraft = DraftID(try XCTUnwrap(composer.lastDraftID))
        let firstAccount = try XCTUnwrap(composer.fromAccountID)
        let other = firstAccount == fixture.first.id ? fixture.second.id : fixture.first.id
        composer.selectFromAccount(other)
        XCTAssertEqual(composer.fromAccountID, other)
        XCTAssertThrowsError(try fixture.store().draft(id: firstDraft), "the old account's draft is gone")
    }

    func testMacSendRecordsTheLastFromAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try macRuntime(fixture, undoSendSleep: { _ in })
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareNewMessage()
        composer.selectFromAccount(fixture.second.id)
        composer.to = "someone@example.com"
        composer.subject = "Sent"
        composer.bodyMarkdown = "Body"
        let scheduled = try await composer.send()
        XCTAssertTrue(scheduled)
        for _ in 0..<200 where UserDefaults.standard.string(forKey: ComposerFromAccountPreference.key) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(UserDefaults.standard.string(forKey: ComposerFromAccountPreference.key), fixture.second.id.rawValue)
        let next = runtime.makeComposerViewModel()
        next.prepareNewMessage()
        XCTAssertEqual(next.fromAccountID, fixture.second.id, "New Message defaults to the last account sent from")
    }

    /// A restored draft never moves to another account by being saved again under its id.
    func testMacRestoredDraftNeverMovesAccounts() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try macRuntime(fixture)
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareReply(context: try XCTUnwrap(runtime.makeComposerReplyContext(sourceMessageID: "msg_second_1")))
        composer.bodyMarkdown = "Thanks"
        try await composer.saveDraft()
        let draftID = try XCTUnwrap(composer.lastDraftID)
        let snapshot = composer.restorationSnapshot
        let moved = ComposerRestoreSnapshot(
            to: snapshot.to, cc: snapshot.cc, bcc: snapshot.bcc, subject: snapshot.subject,
            bodyMarkdown: snapshot.bodyMarkdown, presentationMode: .newMessage, replyContext: nil,
            includesQuotedHistory: true, draftID: draftID, fromAccountID: fixture.first.id
        )
        let other = runtime.makeComposerViewModel()
        other.restore(from: moved)
        other.bodyMarkdown = "Changed"
        try? await other.saveDraft()
        XCTAssertEqual(try fixture.store().draft(id: DraftID(draftID)).accountID, fixture.second.id)
    }

    /// Mac sends from any account now, so a send left uncertain by any account is surfaced.
    func testMacSurfacesAnUncertainSendFromAnyAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let store = try fixture.store()
        let draft = try store.createDraft(Draft(
            id: DraftID("drf_uncertain_second"), accountID: fixture.second.id, from: fixture.second.email,
            to: [EmailAddress("friend@example.com")], cc: [], bcc: [], subject: "Review",
            bodyPlain: "Body", createdBy: "local-user", aiGenerated: false, sourceThreadID: nil
        ), actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
        _ = try store.reserveDirectSend(draftID: draft.id, contentHash: draft.contentHash, accountID: fixture.second.id)
        try store.markDirectSendSubmitting(draftID: draft.id, contentHash: draft.contentHash)
        try store.markDirectSendUncertain(draftID: draft.id, contentHash: draft.contentHash)
        let runtime = try macRuntime(fixture)
        defer { Task { await runtime.shutdown() } }
        XCTAssertTrue(runtime.hasUncertainSend)
    }
}
