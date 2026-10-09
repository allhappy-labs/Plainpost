import Foundation
import PlainpostCore
import PlainpostDB
@testable import PlainpostUI
import PlainpostRuntimeTestSupport
import PlainpostSecrets
import XCTest

@MainActor
final class ComposerFromAccountTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "compose-from-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    func testDefaultsToTheFirstAccountThenToTheLastSentFrom() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let preference = ComposerFromAccountPreference(defaults: defaults())
        XCTAssertEqual(preference.defaultAccount(among: [fixture.first, fixture.second])?.id, fixture.first.id)
        preference.recordSent(from: fixture.second.id)
        XCTAssertEqual(preference.defaultAccount(among: [fixture.first, fixture.second])?.id, fixture.second.id)
    }

    func testAForgottenLastAccountFallsBackToTheFirst() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let preference = ComposerFromAccountPreference(defaults: defaults())
        preference.recordSent(from: AccountID("acc_gone"))
        XCTAssertEqual(preference.defaultAccount(among: [fixture.first, fixture.second])?.id, fixture.first.id)
    }

    func testNewMessageOffersEveryAccountAndSavesThroughTheChosenOne() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareNewMessage()
        XCTAssertEqual(composer.fromAccounts.map(\.id), [fixture.first.id, fixture.node!.id, fixture.second.id])
        XCTAssertEqual(composer.fromAccountID, fixture.first.id)
        XCTAssertNil(composer.fixedFromAddress)
        composer.selectFromAccount(fixture.second.id)
        composer.to = "someone@example.com"
        composer.subject = "From second"
        composer.bodyMarkdown = "Body"
        try await composer.saveDraft()
        let draft = try fixture.store().draft(id: DraftID(try XCTUnwrap(composer.lastDraftID)))
        XCTAssertEqual(draft.accountID, fixture.second.id)
        XCTAssertEqual(draft.from, fixture.second.email)
    }

    func testAReplyIsFixedToTheAccountTheOriginalCameTo() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        let context = try XCTUnwrap(runtime.makeComposerReplyContext(sourceMessageID: "msg_second_1"))
        composer.prepareReply(context: context)
        XCTAssertEqual(composer.fromAccountID, fixture.second.id)
        XCTAssertTrue(composer.fromAccounts.isEmpty, "a reply's From is fixed")
        XCTAssertEqual(composer.fixedFromAddress, fixture.second.email.rawValue, "shown, not chosen")
        composer.bodyMarkdown = "Thanks"
        try await composer.saveDraft()
        let draft = try fixture.store().draft(id: DraftID(try XCTUnwrap(composer.lastDraftID)))
        XCTAssertEqual(draft.accountID, fixture.second.id)
        composer.prepareNewMessage()
        XCTAssertEqual(composer.fromAccounts.count, 2, "a new message offers every account again")
    }

    /// A reply whose original's account is gone is blocked, never sent from another account.
    func testAReplyIsBlockedWhenTheOriginalsAccountIsRemoved() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        let context = try XCTUnwrap(runtime.makeComposerReplyContext(sourceMessageID: "msg_second_1"))
        try await fixture.store().deleteAccountData(accountID: fixture.second.id, credentials: InMemoryCredentialVault())
        composer.prepareReply(context: context)
        XCTAssertNotEqual(composer.fromAccountID, fixture.first.id, "never falls back to another account")
        XCTAssertNotNil(composer.sendBlockedReason)
        composer.bodyMarkdown = "Thanks"
        XCTAssertFalse(composer.canSend)
    }

    /// Restoring an undone or failed send keeps the account it was going out from, even after
    /// a new message has reset the composer's From.
    func testRestoringASendKeepsItsFromAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareReply(context: try XCTUnwrap(runtime.makeComposerReplyContext(sourceMessageID: "msg_second_1")))
        composer.bodyMarkdown = "Thanks"
        try await composer.saveDraft()
        let snapshot = composer.restorationSnapshot
        XCTAssertEqual(snapshot.fromAccountID, fixture.second.id)
        composer.prepareNewMessage()
        XCTAssertEqual(composer.fromAccountID, fixture.first.id)
        composer.restore(from: snapshot)
        XCTAssertEqual(composer.fromAccountID, fixture.second.id)
        try await composer.saveDraft()
        let draft = try fixture.store().draft(id: DraftID(try XCTUnwrap(composer.lastDraftID)))
        XCTAssertEqual(draft.accountID, fixture.second.id)
    }

    /// A saved draft never moves to another account by being saved again under its id.
    func testADraftIDOwnedByAnotherAccountIsNotTakenOver() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let store = try fixture.store()
        func draft(_ account: Account) -> Draft {
            Draft(id: DraftID("shared-draft"), accountID: account.id, from: account.email,
                  to: [EmailAddress("someone@example.com")], cc: [], bcc: [], subject: "S", bodyPlain: "B",
                  createdBy: "local-user", aiGenerated: false, sourceThreadID: nil)
        }
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        _ = try store.createDirectDraft(draft(fixture.second), actor: actor, expectedDirectSourceGeneration: 1)
        XCTAssertThrowsError(try store.createDirectDraft(draft(fixture.first), actor: actor, expectedDirectSourceGeneration: 1))
        XCTAssertEqual(try store.draft(id: DraftID("shared-draft")).accountID, fixture.second.id)
    }

    /// A draft saves through its account's current source: a Direct → Sync Node → Direct
    /// round trip after the composer opened doesn't leave it unable to save.
    func testADraftSavesAfterItsAccountsSourceRoundTrips() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareNewMessage()
        try fixture.switchToNode(fixture.first)
        try fixture.switchToDirect(fixture.first)
        composer.to = "someone@example.com"
        composer.subject = "Still here"
        composer.bodyMarkdown = "Body"
        try await composer.saveDraft()
        let draft = try fixture.store().draft(id: DraftID(try XCTUnwrap(composer.lastDraftID)))
        XCTAssertEqual(draft.accountID, fixture.first.id)
    }

    /// Switching From never leaves a saved draft behind under the old account: when it can't
    /// be removed there, From stays and the user is told.
    func testAFromSwitchThatCantRemoveTheOldDraftIsRefused() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let runtime = try fixture.deviceWideRuntime()
        defer { Task { await runtime.shutdown() } }
        let composer = runtime.makeComposerViewModel()
        composer.prepareNewMessage()
        composer.to = "someone@example.com"
        composer.subject = "Saved"
        composer.bodyMarkdown = "Body"
        try await composer.saveDraft()
        let saved = try XCTUnwrap(composer.lastDraftID)
        try fixture.switchToNode(fixture.first)
        composer.selectFromAccount(fixture.second.id)
        XCTAssertEqual(composer.fromAccountID, fixture.first.id)
        XCTAssertEqual(composer.lastDraftID, saved)
        XCTAssertNotNil(composer.statusMessage)
    }
}
