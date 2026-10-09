import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class InMemoryMailStoreTests: XCTestCase {
    func testStoreCreatesDraftAndAuditsSendRequest() throws {
        let store = InMemoryMailStore()
        let actor = PlainpostFixtures.codexActor
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: actor)

        let request = try store.requestSend(draftID: draft.id, actor: actor, reason: "User asked me to reply")

        XCTAssertEqual(request.status, .pending)
        XCTAssertEqual(store.auditEntries.map(\.action), ["draft.create", "send.request"])
    }

    func testCancelSendRequestUpdatesStateAndAudits() throws {
        let store = InMemoryMailStore()
        let actor = PlainpostFixtures.codexActor
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: actor)
        let request = try store.requestSend(draftID: draft.id, actor: actor, reason: "User asked me to reply")

        let cancelled = try store.cancelSendRequest(id: request.id, actor: actor)

        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .cancelled)
        XCTAssertEqual(store.auditEntries.map(\.action), ["draft.create", "send.request", "send.cancel"])
        XCTAssertThrowsError(try store.cancelSendRequest(id: SendRequestID("srq_missing"), actor: actor)) { error in
            XCTAssertEqual(error as? PlainpostError, .notFound("Send request not found."))
        }
    }

    func testSeededStoreIncludesAccountMailboxThreadAndMessageFixtures() throws {
        let store = InMemoryMailStore.seededForStage0()

        XCTAssertEqual(store.accounts.map(\.id), [PlainpostFixtures.personalAccount.id])
        XCTAssertEqual(store.mailboxes.map(\.id), [PlainpostFixtures.inboxMailbox.id])
        XCTAssertEqual(store.messages.map(\.id), [PlainpostFixtures.aliceMessage.id])
        XCTAssertEqual(store.threads.map(\.id), [PlainpostFixtures.aliceThread.id])
    }

    func testStoreApprovalValidationRejectsAgentActor() throws {
        let store = InMemoryMailStore.seededForStage0()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)

        XCTAssertThrowsError(
            try store.validateAppApproval(
                requestID: request.id,
                currentDraftHash: draft.contentHash,
                actor: PlainpostFixtures.codexActor
            )
        ) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Only the local GUI user can approve sends."))
        }
    }

    func testMessageMutationPermissionsRejectRestrictedAgents() throws {
        let store = InMemoryMailStore.seededForStage0()
        let messageID = PlainpostFixtures.aliceMessage.id
        let restricted = Actor(
            id: "limited-agent",
            kind: .mcpAgent,
            displayName: "Limited Agent",
            permissions: .agentRequested(
                readBody: true,
                createDrafts: true,
                requestSend: true,
                addLabels: false,
                recategorize: false,
                markSeen: false
            )
        )

        XCTAssertThrowsError(try store.addLabel("Needs Reply", to: messageID, actor: restricted)) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to modify labels."))
        }
        XCTAssertThrowsError(try store.recategorize(messageID, as: .support, actor: restricted)) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to recategorize messages."))
        }
        XCTAssertThrowsError(try store.markSeen(messageID, seen: true, actor: restricted)) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to change seen state."))
        }
    }
}
