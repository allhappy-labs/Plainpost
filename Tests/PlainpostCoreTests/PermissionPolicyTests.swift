import XCTest
@testable import PlainpostCore

final class PermissionPolicyTests: XCTestCase {
    func testAgentCannotSendOrApproveEvenIfPermissionInputRequestsIt() {
        let permissions = AgentPermissions.agentRequested(
            readBody: true,
            createDrafts: true,
            requestSend: true,
            sendWithoutConfirmation: true,
            approveSend: true
        )

        XCTAssertTrue(permissions.readBody)
        XCTAssertTrue(permissions.createDrafts)
        XCTAssertTrue(permissions.requestSend)
        XCTAssertFalse(permissions.sendWithoutConfirmation)
        XCTAssertFalse(permissions.approveSend)
    }

    func testApprovalPolicyRejectsAgentApprovalActors() {
        let actor = Actor(
            id: "codex",
            kind: .cli,
            displayName: "Codex CLI",
            permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
        )

        XCTAssertThrowsError(try ApprovalPolicy.ensureCanApprove(actor: actor)) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Only the local GUI user can approve sends."))
        }
    }

    func testBodyReadPolicyRequiresReadBodyPermission() {
        let restricted = Actor(
            id: "limited-agent",
            kind: .mcpAgent,
            displayName: "Limited Agent",
            permissions: .agentRequested(readBody: false, createDrafts: true, requestSend: true)
        )
        let fullReadAgent = Actor(
            id: "codex",
            kind: .cli,
            displayName: "Codex CLI",
            permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
        )
        let guiUser = Actor(
            id: "local-user",
            kind: .user,
            displayName: "Local User",
            permissions: .guiUser
        )

        XCTAssertThrowsError(try MessageReadPolicy.validateBodyRead(actor: restricted)) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to read message bodies."))
        }
        XCTAssertNoThrow(try MessageReadPolicy.validateBodyRead(actor: fullReadAgent))
        XCTAssertNoThrow(try MessageReadPolicy.validateBodyRead(actor: guiUser))
    }

    func testAttachmentReadPolicyRequiresAttachmentPermission() {
        let restricted = Actor(
            id: "limited-agent",
            kind: .mcpAgent,
            displayName: "Limited Agent",
            permissions: .agentRequested(
                readBody: true,
                readAttachments: false,
                createDrafts: true,
                requestSend: true
            )
        )
        let attachmentReadAgent = Actor(
            id: "codex",
            kind: .cli,
            displayName: "Codex CLI",
            permissions: .agentRequested(
                readBody: true,
                readAttachments: true,
                createDrafts: true,
                requestSend: true
            )
        )
        let guiUser = Actor(
            id: "local-user",
            kind: .user,
            displayName: "Local User",
            permissions: .guiUser
        )

        XCTAssertThrowsError(try MessageReadPolicy.validateAttachmentRead(actor: restricted)) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to read attachments."))
        }
        XCTAssertNoThrow(try MessageReadPolicy.validateAttachmentRead(actor: attachmentReadAgent))
        XCTAssertNoThrow(try MessageReadPolicy.validateAttachmentRead(actor: guiUser))
    }
}
