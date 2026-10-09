import Foundation
import XCTest
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport
import PlainpostAccountProtocol

final class NotificationPolicyUpdaterTests: XCTestCase {
    func testNodePolicyDTORejectsVersionZeroForNodeWire() throws {
        XCTAssertThrowsError(try NodeSyncNotificationPolicy(
            logicalMailboxID: nil, mode: .richPreview, version: "0", scopeVersion: "0", override: false
        ))
        XCTAssertThrowsError(try NodeSyncNotificationPolicyUpdateRequest(
            logicalMailboxID: nil, mode: .richPreview, expectedVersion: "0", idempotencyKey: "node-request"
        ))
    }

    func testUpdaterNormalizesNodeConflictToCommonRemoteError() async throws {
        let sender = try ConflictNodeSessionSender()
        let updater = AccountNotificationPolicyUpdater(remote: NodeSyncClient(sender: sender))
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x42, count: 32)))
        let request = try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "1", idempotencyKey: "node-conflict")
        do {
            _ = try await updater.update(request)
            XCTFail("Node conflict was reported as success")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }
    }

    func testUpdaterNormalizesNodeConflictToCommonRemoteErrorOnClear() async throws {
        let sender = try ConflictNodeSessionSender()
        let updater = AccountNotificationPolicyUpdater(remote: NodeSyncClient(sender: sender))
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x43, count: 32)))
        do {
            _ = try await updater.clear(logicalMailboxID: mailbox, expectedVersion: "1", idempotencyKey: "node-clear-conflict")
            XCTFail("Node clear conflict was reported as success")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }
    }

    func testUpdaterExposesCurrentAndClearThroughNarrowRemote() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 4, count: 32)))
        let policy = try NodeSyncNotificationPolicy(logicalMailboxID: mailbox, mode: .generic, version: "2", scopeVersion: "2", override: true)
        let remote = PolicyRemoteSpy(policy: policy)
        let updater = AccountNotificationPolicyUpdater(remote: remote)
        let current = try await updater.current(logicalMailboxID: mailbox)
        XCTAssertEqual(current, policy)
        let cleared = try await updater.clear(logicalMailboxID: mailbox, expectedVersion: "2", idempotencyKey: "clear-1")
        XCTAssertEqual(cleared, policy)
        let request = await remote.lastRequest()
        XCTAssertEqual(request?.logicalMailboxID, Optional(mailbox))
        XCTAssertTrue(request?.clear == true)
        XCTAssertEqual(request?.expectedVersion, "2")
    }

}

private actor PolicyRemoteSpy: NotificationPolicyRemote {
    let policy: NodeSyncNotificationPolicy
    var request: NodeSyncNotificationPolicyUpdateRequest?
    init(policy: NodeSyncNotificationPolicy) { self.policy = policy }
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy { policy }
    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy { self.request = request; return policy }
    func lastRequest() -> NodeSyncNotificationPolicyUpdateRequest? { request }
}

private struct ConflictNodeSessionSender: NodeSessionRequestSending {
    let body: Data
    init() throws { body = try NodeSyncCodec.encodeProblem(NodeSyncProblemResult(category: .conflict)) }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 409, url: URL(string: "https://node.example")!, headers: [:], body: self.body)
    }
}
