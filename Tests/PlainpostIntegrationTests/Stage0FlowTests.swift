import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class Stage0FlowTests: XCTestCase {
    func testAgentCreatesDraftRequestsSendAndApprovalRequiresMatchingHash() throws {
        let store = InMemoryMailStore.seededForStage0()
        let actor = PlainpostFixtures.codexActor
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: actor)

        let request = try store.requestSend(draftID: draft.id, actor: actor, reason: "User asked me to reply")

        XCTAssertEqual(request.status, .pending)
        XCTAssertThrowsError(
            try store.validateAppApproval(
                requestID: request.id,
                currentDraftHash: "changed",
                actor: PlainpostFixtures.guiUser
            )
        )
        XCTAssertThrowsError(
            try store.validateAppApproval(
                requestID: request.id,
                currentDraftHash: draft.contentHash,
                actor: actor
            )
        )
        XCTAssertNoThrow(
            try store.validateAppApproval(
                requestID: request.id,
                currentDraftHash: draft.contentHash,
                actor: PlainpostFixtures.guiUser
            )
        )
    }
}
