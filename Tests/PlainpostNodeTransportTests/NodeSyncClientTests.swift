import CryptoKit
import Foundation
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostNodeTransport

final class NodeSyncClientTests: XCTestCase {
    func testProviderSyncUsesAuthenticatedCanonicalWakeRoute() async throws {
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 204, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
        ])

        try await NodeSyncClient(sender: sender).requestProviderSync()

        let requests = await sender.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/provider-sync")
        XCTAssertEqual(try NodeSyncCodec.decodeProviderSyncRequest(request.body), NodeSyncProviderSyncRequest())
    }

    func testNotificationRecipientRemovalUsesAuthenticatedRetryableRoute() async throws {
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 204, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
        ])

        try await NodeSyncClient(sender: sender).removeNotificationRecipient()

        let requests = await sender.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/v1/notifications/recipient")
        XCTAssertEqual(try NodeSyncCodec.decodeNotificationRecipientRemovalRequest(request.body), NodeSyncNotificationRecipientRemovalRequest())
    }

    func testNotificationPolicyRoundTripsOpaqueMailboxAndUsesExactUpdateRetry() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x2A, count: 32)))
        let state = try NodeSyncNotificationPolicy(logicalMailboxID: mailbox, mode: .senderSubject, version: "2", scopeVersion: "2", override: true)
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeNotificationPolicy(state)),
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeNotificationPolicy(state))
        ])
        let client = NodeSyncClient(sender: sender, maximumAttempts: 2)
        let request = try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .senderSubject, expectedVersion: "1", idempotencyKey: "policy-retry")
        let result = try await client.updateNotificationPolicy(request)
        XCTAssertEqual(result, state)
        let recorded = await sender.requests()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(try NodeSyncCodec.decodeNotificationPolicyUpdateRequest(recorded[0].body), request)
        XCTAssertFalse(String(decoding: recorded[0].body, as: UTF8.self).contains("provider"))
    }

    func testCentralVersionZeroBootstrapCannotReachNodeWire() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x2E, count: 32)))
        XCTAssertThrowsError(try NodeSyncNotificationPolicyUpdateRequest(
            logicalMailboxID: mailbox, mode: .generic, expectedVersion: "0", idempotencyKey: "central-bootstrap"
        ))
    }
    func testMessageEncodesRawIdentifierAsCanonicalBase64URLPathToken() async throws {
        let messageID = "<unicode-é@example.test>"
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: messageID,
            inReplyTo: [], labels: [], receivedAt: "2026-08-27T10:00:00Z", references: [],
            replyTo: [], sentAt: nil, subject: "Message", textBody: NodeSyncBody(state: .complete, value: "Body"),
            threadID: "thread-1", to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")]
        )
        let result = try NodeSyncMessageResult(message: message)
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeMessageResult(result))
        ])

        _ = try await NodeSyncClient(sender: sender).message(id: messageID)

        let requests = await sender.requests()
        let request = try XCTUnwrap(requests.first)
        let expectedToken = Data(messageID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(request.path, "/v1/messages/\(expectedToken)")
    }

    func testMailAccountsInstallsTheAuthorityEpochOfEveryListedAccount() async throws {
        let ada = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 1, count: 32)))
        let grace = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 2, count: 32)))
        func mailbox(_ logical: LogicalMailboxID, _ role: String, _ epoch: String) throws -> NodeSyncDiscoveredMailbox {
            try NodeSyncDiscoveredMailbox(displayName: role, logicalMailboxID: logical, mailboxHandle: role.uppercased(), role: role, authorityEpoch: epoch)
        }
        let listed = try NodeSyncMailAccountsResult(accounts: [
            try NodeSyncMailAccount(assignments: [try mailbox(ada, "inbox", "7"), try mailbox(ada, "drafts", "7")], logicalMailboxID: ada, primary: true, providerIdentity: "ada@example.test", providerKind: "gmail", state: .ready),
            try NodeSyncMailAccount(assignments: [try mailbox(grace, "inbox", "3")], logicalMailboxID: grace, primary: false, providerIdentity: "grace@example.test", providerKind: "generic", state: .authenticationRequired),
        ], primaryState: .available)
        let sender = EpochRecordingNodeSessionSender(response: NodeHTTPResponse(
            statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:],
            body: try NodeSyncMailModeCodec.encodeMailAccountsResult(listed)
        ))

        _ = try await NodeSyncClient(sender: sender).mailAccounts()

        let installed = sender.installed()
        XCTAssertEqual(installed[ada], "7")
        XCTAssertEqual(installed[grace], "3", "a non-primary account needs its own epoch to sign mutations")
        XCTAssertEqual(installed.count, 2)
    }

    func testScopedMessageAndAttachmentReadsNameTheLogicalMailboxInTheRoute() async throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 2, count: 32)))
        let encodedLogical = try NodeSyncCodec.encodeLogicalMailboxID(logical)
        let messageID = "gm2.0123456789abcdef0123456789abcdef01234567"
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: messageID,
            inReplyTo: [], labels: [], receivedAt: "2026-08-27T10:00:00Z", references: [],
            replyTo: [], sentAt: nil, subject: "Message", textBody: NodeSyncBody(state: .complete, value: "Body"),
            threadID: "thread-1", to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")]
        )
        let url = URL(string: "https://node.example.ts.net:443")!
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: try NodeSyncCodec.encodeMessageResult(try NodeSyncMessageResult(message: message))),
            NodeHTTPResponse(statusCode: 404, url: url, headers: [:], body: try NodeSyncCodec.encodeProblem(NodeSyncProblemResult(category: .conflict))),
        ])
        let client = NodeSyncClient(sender: sender)

        let read = try await client.mailMessage(id: messageID, logicalMailboxID: logical)
        XCTAssertEqual(read.id, messageID)
        do {
            _ = try await client.mailMessage(id: "foreign", logicalMailboxID: logical)
            XCTFail("a message outside the logical mailbox is not found")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .notFound)
        }
        let requests = await sender.requests()
        let token = Data(messageID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(requests.map(\.path), ["/v1/mail/messages/\(encodedLogical)/\(token)", "/v1/mail/messages/\(encodedLogical)/Zm9yZWlnbg"])
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"], "a not-found read is not retried")
        XCTAssertTrue(requests.allSatisfy { $0.body.isEmpty })

        let payload = Data("attachment".utf8)
        let streaming = StreamingRecordingNodeSessionSender(payload: payload, headers: [
            "Content-Type": "text/plain", "Content-Length": String(payload.count), "Content-Disposition": "attachment; filename=note.txt",
        ])
        let download = try await NodeSyncClient(sender: streaming).mailAttachment(id: "attachment-1", logicalMailboxID: logical)
        var collected = Data()
        for try await chunk in download.bytes { collected.append(chunk) }
        XCTAssertEqual(collected, payload)
        let streamed = await streaming.paths()
        XCTAssertEqual(streamed, ["/v1/mail/attachments/\(encodedLogical)/attachment-1"])
    }

    func testSnapshotUsesCanonicalRequestAndMapsWirePage() async throws {
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: ["seen"],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.com")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-1",
            inReplyTo: [], labels: [], receivedAt: "2026-08-26T10:00:00Z", references: [],
            replyTo: [], sentAt: "2026-08-26T10:00:00Z", subject: "Hello",
            textBody: NodeSyncBody(state: .complete, value: "Body"), threadID: "thread-1",
            to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.com")]
        )
        let page = try NodeSyncSnapshotPage(messages: [message], nextCursor: "next", revision: "3")
        let sender = RecordingNodeSessionSender(responses: [NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeSnapshotPage(page))])
        let client = NodeSyncClient(sender: sender)

        let result = try await client.snapshot(after: nil, limit: 25)
        XCTAssertEqual(result, page)
        let recordedRequests = await sender.requests()
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/snapshot")
        XCTAssertEqual(try NodeSyncCodec.decodeSnapshotRequest(request.body).after, "")
    }

    func testDeltaUsesCanonicalRequestAndMapsWirePage() async throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 3, count: 32)))
        let change = try NodeSyncChange(kind: "upsert", logicalMailboxID: logical, messageID: "message-2", threadID: "thread-2")
        let page = try NodeSyncDeltaPage(changes: [change], nextCursor: "tail", revision: "4")
        let sender = RecordingNodeSessionSender(responses: [NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeDeltaPage(page))])
        let client = NodeSyncClient(sender: sender)

        let result = try await client.delta(after: "baseline", limit: 25)
        XCTAssertEqual(result, page)
        let requests = await sender.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/deltas")
        XCTAssertEqual(try NodeSyncCodec.decodeDeltaRequest(request.body).after, "baseline")
    }

    func testFailedReadRetriesWithTheSameCanonicalRequest() async throws {
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 503, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data()),
            NodeHTTPResponse(statusCode: 503, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data()),
        ])
        let client = NodeSyncClient(sender: sender, maximumAttempts: 2)

        do {
            _ = try await client.snapshot(after: nil, limit: 25)
            XCTFail("snapshot should fail after the bounded retry")
        } catch {
            let requests = await sender.requests()
            XCTAssertEqual(requests.count, 2)
            guard requests.count == 2 else { return }
            XCTAssertEqual(requests[0].body, requests[1].body)
        }
    }

    func testStatusUsesBodylessGetContract() async throws {
        let result = try NodeSyncStatusResult(revision: "7", state: "ready")
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeStatusResult(result))
        ])

        let actual = try await NodeSyncClient(sender: sender).status()
        XCTAssertEqual(actual, result)
        let requests = await sender.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/status")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testNotificationRecipientTransferUsesAuthenticatedVersionedRoute() async throws {
        let result = try NodeSyncNotificationRecipientResult(state: "applied")
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeNotificationRecipientResult(result))
        ])
        let request = try NodeSyncNotificationRecipientRequest(
            accountID: "10000000-0000-4000-8000-000000000801", deviceID: "20000000-0000-4000-8000-000000000801", trustEpoch: "1", trustRevision: "3",
            trustHead: Data(repeating: 1, count: 32), routingHandle: Data(repeating: 2, count: 32), agreementPublicKey: Data([4] + Array(repeating: 3, count: 64)), deviceSignature: Data(repeating: 4, count: 64), trustCommit: Data("commit".utf8)
        )
        let actual = try await NodeSyncClient(sender: sender).applyNotificationRecipient(request)
        XCTAssertEqual(actual, result)
        let requests = await sender.requests()
        let recorded = try XCTUnwrap(requests.first)
        XCTAssertEqual(recorded.method, "PUT")
        XCTAssertEqual(recorded.path, "/v1/notifications/recipient")
        XCTAssertEqual(try NodeSyncCodec.decodeNotificationRecipientRequest(recorded.body), request)
    }

    func testBackupAndEraseUseAuthenticatedNonRetryingOperationRoutes() async throws {
        let backup = try NodeSyncOperationResult(state: "verified", backup: "verified", completedAt: "2026-08-27T10:00:00Z", upgradeStatus: "ready")
        let erase = try NodeSyncOperationResult(state: "erased", backup: "unchanged", completedAt: nil, upgradeStatus: "blocked")
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try encodeOperationResult(backup, kind: "node-sync.backup-result.v1")),
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try encodeOperationResult(erase, kind: "node-sync.erase-result.v1"))
        ])
        let client = NodeSyncClient(sender: sender)

        let actualBackup = try await client.backup()
        let actualErase = try await client.erase(confirmation: "ERASE SYNC NODE")
        XCTAssertEqual(actualBackup, backup)
        XCTAssertEqual(actualErase, erase)
        let requests = await sender.requests()
        XCTAssertEqual(requests.map(\.path), ["/v1/operations/backup", "/v1/operations/erase"])
        XCTAssertEqual(requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(try decodeRequestKind(requests[0].body), "node-sync.backup-request.v1")
        XCTAssertEqual(try decodeRequestKind(requests[1].body), "node-sync.erase-request.v1")
    }

    func testOperationResultRejectsUnknownStateAndRouteMismatch() throws {
        let unknown = Data(#"{"backup":"verified","kind":"node-sync.backup-result.v1","state":"future","upgradeStatus":"ready"}"#.utf8)
        XCTAssertThrowsError(try NodeSyncCodec.decodeOperationResult(unknown))

        let mismatch = Data(#"{"backup":"unchanged","kind":"node-sync.backup-result.v1","state":"erased","upgradeStatus":"blocked"}"#.utf8)
        XCTAssertThrowsError(try NodeSyncCodec.decodeOperationResult(mismatch))
    }

    func testBackupAndEraseRejectOppositeOperationResponseFamilies() async throws {
        let backup = try NodeSyncOperationResult(state: "verified", backup: "verified", completedAt: "2026-08-27T10:00:00Z", upgradeStatus: "ready")
        let erase = try NodeSyncOperationResult(state: "erased", backup: "unchanged", completedAt: nil, upgradeStatus: "blocked")
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try encodeOperationResult(erase, kind: "node-sync.erase-result.v1")),
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try encodeOperationResult(backup, kind: "node-sync.backup-result.v1")),
        ])
        let client = NodeSyncClient(sender: sender)

        do {
            _ = try await client.backup()
            XCTFail("backup must reject an erase response")
        } catch { }
        do {
            _ = try await client.erase(confirmation: "ERASE SYNC NODE")
            XCTFail("erase must reject a backup response")
        } catch { }
    }

    func testAttachmentStreamCanBeCancelledExplicitly() async throws {
        let cancellationProbe = ExplicitCancellationProbe()
        let stream = PlainpostByteStream(capacity: 1, onCancellation: cancellationProbe.markCancelled)
        stream.cancel()
        stream.cancel()
        XCTAssertEqual(cancellationProbe.count, 1)
    }

    private func encodeOperationResult(_ value: NodeSyncOperationResult, kind: String) throws -> Data {
        var object: [String: Any] = ["backup": value.backup.rawValue, "kind": kind, "state": value.state.rawValue, "upgradeStatus": value.upgradeStatus.rawValue]
        if let completedAt = value.completedAt { object["completedAt"] = completedAt }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func decodeRequestKind(_ body: Data) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(object["kind"] as? String)
    }

    func testStatusAcceptsFreshAccountProjectionRevisionZeroForOnboarding() throws {
        let status = try NodeSyncStatusResult(revision: "0", state: "degraded")
        let encoded = try NodeSyncCodec.encodeStatusResult(status)
        XCTAssertEqual(try NodeSyncCodec.decodeStatusResult(encoded), status)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"revision\":\"0\""))
    }

    func testStatusCarriesProviderIdentityAndDurableAssignments() throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let mailbox = try NodeSyncDiscoveredMailbox(
            displayName: "Inbox", logicalMailboxID: logical,
            mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )
        let expected = try NodeSyncStatusResult(
            revision: "8", state: "ready",
            providerIdentity: "user@example.com", assignments: [mailbox]
        )
        let decoded = try NodeSyncCodec.decodeStatusResult(NodeSyncCodec.encodeStatusResult(expected))
        XCTAssertEqual(decoded, expected)
    }

    func testAssignmentCarriesAuthenticatedAuthorityEpochWithoutExposingProviderIdentity() throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 9, count: 32)))
        let mailbox = try NodeSyncDiscoveredMailbox(
            displayName: "Inbox", logicalMailboxID: logical,
            mailboxHandle: String(repeating: "B", count: 43), role: "inbox", authorityEpoch: "12"
        )
        let encoded = try NodeSyncCodec.encodeMailboxAssignmentsResult(
            try NodeSyncMailboxAssignmentsResult(assignments: [mailbox])
        )
        let decoded = try NodeSyncCodec.decodeMailboxAssignmentsResult(encoded)
        XCTAssertEqual(decoded.assignments.first?.authorityEpoch, "12")
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("provider"))
    }

    func testMailboxAssignmentsUsesReadOnlyGetContract() async throws {
        let result = try NodeSyncMailboxAssignmentsResult(assignments: [])
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeMailboxAssignmentsResult(result))
        ])

        let actual = try await NodeSyncClient(sender: sender).mailboxAssignments()
        XCTAssertEqual(actual, result)
        let requests = await sender.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/mailboxes/assignments")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testMutationRetriesByteIdenticalCanonicalOperation() async throws {
        let operation = try validCanonicalOperation()
        let result = try NodeSyncMutationResult(idempotencyKey: "mutation-1", state: "applied")
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 503, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data()),
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeMutationResult(result))
        ])
        let client = NodeSyncClient(sender: sender, maximumAttempts: 2)

        let actual = try await client.mutation(canonicalOperation: operation)
        XCTAssertEqual(actual, result)
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].body, requests[1].body)
        XCTAssertEqual(try NodeSyncCodec.decodeMutationRequest(requests[0].body).canonicalOperation, operation)
    }

    func testMutationReconcilesDurablePendingBeforeDispatchingNewOperation() async throws {
        let recovered = try NodeSyncMutationResult(idempotencyKey: "old-operation", state: "applied")
        let applied = try NodeSyncMutationResult(idempotencyKey: "new-operation", state: "applied")
        let sender = PendingMutationReconciliationSender(
            recovery: NodeHTTPResponse(
                statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:],
                body: try NodeSyncCodec.encodeMutationResult(recovered)
            ),
            response: NodeHTTPResponse(
                statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:],
                body: try NodeSyncCodec.encodeMutationResult(applied)
            )
        )

        let result = try await NodeSyncClient(sender: sender).mutation(canonicalOperation: try validCanonicalOperation())

        XCTAssertEqual(result, applied)
        let reconciliationCalls = await sender.reconciliationCalls()
        let dispatchCalls = await sender.dispatchCalls()
        XCTAssertEqual(reconciliationCalls, 1)
        XCTAssertEqual(dispatchCalls, 1)
    }

    func testReadReconcilesRetainedAssignmentBeforeDispatchingStatus() async throws {
        let page = try NodeSyncStatusResult(
            revision: "1", state: "ready", version: "test", reachability: "reachable",
            syncLag: "0s", storage: "filesystem", providerIdentity: nil,
            assignments: [], backup: "verified", endpoint: "node.example.ts.net", updateStatus: "current"
        )
        let sender = PendingRequestReconciliationSender(
            recovery: NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data("assignment-result".utf8)),
            response: NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: try NodeSyncCodec.encodeStatusResult(page))
        )

        let result = try await NodeSyncClient(sender: sender).status()

        XCTAssertEqual(result, page)
        let reconciliationCalls = await sender.reconciliationCalls()
        let dispatchCalls = await sender.dispatchCalls()
        XCTAssertEqual(reconciliationCalls, 1)
        XCTAssertEqual(dispatchCalls, 1)
    }

    func testDraftStateUsesDedicatedAuthenticatedRouteAndPreservesRevision() async throws {
        let expected = try NodeSyncDraftState(draftID: "existing-draft", revision: "4", state: "appended")
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(
                statusCode: 200, url: URL(string: "https://node.example.ts.net:443")!, headers: [:],
                body: try NodeSyncCodec.encodeDraftState(expected)
            )
        ])

        let actual = try await NodeSyncClient(sender: sender).draftState(id: expected.draftID)

        XCTAssertEqual(actual, expected)
        let requests = await sender.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/drafts/existing-draft")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testStaleCursorProblemIsNotRetried() async throws {
        let problem = try NodeSyncCodec.encodeProblem(NodeSyncProblemResult(category: .staleCursor))
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 409, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: problem)
        ])
        let client = NodeSyncClient(sender: sender, maximumAttempts: 3)

        do {
            _ = try await client.snapshot(after: "cursor", limit: 25)
            XCTFail("stale cursor should fail")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .problem(.staleCursor))
        }
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testAttachmentResponseIsStreamedWithoutChangingBytes() async throws {
        let payload = Data(repeating: 0x61, count: 2 * 1_048_576)
        let sender = StreamingRecordingNodeSessionSender(payload: payload, headers: [
            "Content-Type": "text/plain",
            "Content-Length": String(payload.count),
            "Content-Disposition": "attachment; filename=note.txt",
        ])
        let client = NodeSyncClient(sender: sender)

        let download = try await client.attachment(id: "attachment-1")
        var collected = Data()
        for try await chunk in download.bytes { collected.append(chunk) }
        XCTAssertEqual(collected, payload)
        XCTAssertEqual(download.metadata?.filename, "note.txt")
        XCTAssertEqual(download.metadata?.size, String(payload.count))
    }

    func testAttachmentAdmissionSettlesRetainedMutationBeforeStreaming() async throws {
        let sender = AdmissionStreamingSender(payload: Data("body".utf8))
        let download = try await NodeSyncClient(sender: sender).attachment(id: "attachment-1")
        var collected = Data()
        for try await chunk in download.bytes { collected.append(chunk) }

        XCTAssertEqual(collected, Data("body".utf8))
        let events = await sender.events()
        XCTAssertEqual(events, ["reconcile", "stream"])
    }

    func testAttachmentResponseSuppliesDigestForUnhydratedSnapshotMetadata() async throws {
        let payload = Data("body".utf8)
        let digest = Data(SHA256.hash(data: payload))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let sender = StreamingRecordingNodeSessionSender(payload: payload, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(payload.count),
            "Content-Disposition": "attachment; filename=fixture.bin",
            "Content-Digest": "sha-256=:\(Data(SHA256.hash(data: payload)).base64EncodedString()):",
        ])
        let snapshotMetadata = NodeSyncAttachment(
            contentDigest: nil, contentID: "cid-fixture", disposition: "attachment",
            filename: "fixture.bin", id: "attachment-1", mime: "application/octet-stream",
            size: String(payload.count)
        )

        let download = try await NodeSyncClient(sender: sender).attachment(id: snapshotMetadata.id, metadata: snapshotMetadata)

        XCTAssertEqual(download.metadata?.contentDigest, digest)
        XCTAssertEqual(download.metadata?.contentID, snapshotMetadata.contentID)
    }

    func testAttachmentMetadataMismatchCancelsRejectedResponseStream() async throws {
        let cancellation = ExplicitCancellationProbe()
        let sender = StreamingRecordingNodeSessionSender(payload: Data("body".utf8), headers: [
            "Content-Type": "text/plain",
            "Content-Length": "4",
            "Content-Disposition": "attachment; filename=response.txt",
        ], cancellationProbe: cancellation)
        let snapshotMetadata = NodeSyncAttachment(
            contentDigest: nil, contentID: nil, disposition: "attachment",
            filename: "snapshot.txt", id: "attachment-1", mime: "text/plain", size: "4"
        )

        do {
            _ = try await NodeSyncClient(sender: sender).attachment(id: snapshotMetadata.id, metadata: snapshotMetadata)
            XCTFail("mismatched attachment metadata should fail")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(cancellation.count, 1)
    }

    func testAttachmentNonSuccessStatusCancelsRejectedResponseStream() async throws {
        let cancellation = ExplicitCancellationProbe()
        let sender = StreamingRecordingNodeSessionSender(payload: Data("missing".utf8), headers: [:], statusCode: 404, cancellationProbe: cancellation)

        do {
            _ = try await NodeSyncClient(sender: sender).attachment(id: "attachment-1")
            XCTFail("non-success attachment response should fail")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertEqual(cancellation.count, 1)
    }

    func testAttachmentMetadataDecodesUnicodeSemicolonFilenameFromRFCDisposition() async throws {
        let sender = StreamingRecordingNodeSessionSender(payload: Data("body".utf8), headers: [
            "Content-Type": "text/plain",
            "Content-Length": "4",
            "Content-Disposition": "attachment; filename*=UTF-8''caf%C3%A9%3B%20notes.txt",
        ])

        let download = try await NodeSyncClient(sender: sender).attachment(id: "attachment-1")

        XCTAssertEqual(download.metadata?.filename, "café; notes.txt")
        XCTAssertEqual(download.metadata?.mime, "text/plain")
        XCTAssertEqual(download.metadata?.size, "4")
    }

    func testAttachmentMetadataAcceptsInlineDispositionWithExplicitFilename() async throws {
        let sender = StreamingRecordingNodeSessionSender(payload: Data("body".utf8), headers: [
            "Content-Type": "text/plain",
            "Content-Length": "4",
            "Content-Disposition": "inline; filename=note.txt",
            "Content-Digest": "sha-256=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:",
        ])

        let download = try await NodeSyncClient(sender: sender).attachment(id: "attachment-1")

        XCTAssertEqual(download.metadata?.disposition, "inline")
        XCTAssertEqual(download.metadata?.filename, "note.txt")
        XCTAssertEqual(download.metadata?.contentDigest, String(repeating: "A", count: 43))
    }

    func testAttachmentMetadataRejectsMissingFilenameInvalidDispositionSizeAndDigest() async throws {
        let invalidHeaders: [[String: String]] = [
            ["Content-Type": "text/plain", "Content-Length": "4", "Content-Disposition": "attachment"],
            ["Content-Type": "text/plain", "Content-Length": "4", "Content-Disposition": "form-data; filename=note.txt"],
            ["Content-Type": "text/plain", "Content-Length": "4", "Content-Disposition": "attachment filename=note.txt"],
            ["Content-Type": "text/plain", "Content-Length": "-1", "Content-Disposition": "attachment; filename=note.txt"],
            ["Content-Type": "text/plain", "Content-Length": String(NodeTLSClient.maximumAttachmentResponseBytes + 1), "Content-Disposition": "attachment; filename=note.txt"],
            ["Content-Type": "text/plain", "Content-Length": "4", "Content-Disposition": "attachment; filename=note.txt", "Content-Digest": "sha-256=:Zm9v"],
            ["Content-Type": "text/plain", "Content-Length": "4", "Content-Disposition": "attachment; filename=note.txt", "Content-Digest": "sha-256:Zm9v"],
        ]

        for headers in invalidHeaders {
            let sender = StreamingRecordingNodeSessionSender(payload: Data("body".utf8), headers: headers)
            let download = try await NodeSyncClient(sender: sender).attachment(id: "attachment-1")
            XCTAssertNil(download.metadata, headers.description)
        }
    }

    func testAttachmentStreamCancellationClosesUnderlyingTransfer() async throws {
        let sender = StreamingRecordingNodeSessionSender(payload: Data(repeating: 0x62, count: 2 * 1_048_576), headers: [:], blockAfterFirstChunk: true)
        let client = NodeSyncClient(sender: sender)
        let download = try await client.attachment(id: "attachment-1")
        let consumer = Task {
            for try await chunk in download.bytes {
                return !chunk.isEmpty
            }
            return false
        }
        let receivedFirstChunk = try await consumer.value
        XCTAssertTrue(receivedFirstChunk)
        download.bytes.cancel()
        download.bytes.cancel()
        do {
            let iterator = download.bytes.makeAsyncIterator()
            iterator.cancel()
        }
        let producerWasCancelled = await sender.waitUntilCancelled()
        let transportWasCancelled = await sender.waitUntilTransportCancelled()
        XCTAssertTrue(producerWasCancelled)
        XCTAssertTrue(transportWasCancelled)
        let wasCancelled = await sender.wasCancelled()
        let wasNormalFinish = await sender.wasNormalFinish()
        let transportCancellations = await sender.transportCancellationCount()
        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(wasNormalFinish)
        XCTAssertEqual(transportCancellations, 1)
    }

    func testSessionAuthenticationRejectionIsNotRetried() async throws {
        let sender = RejectingSessionSender()
        let client = NodeSyncClient(sender: sender, maximumAttempts: 3)

        do {
            _ = try await client.snapshot(after: nil, limit: 25)
            XCTFail("a rejected signed session should fail")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .problem(.unauthorized))
        }
        let calls = await sender.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testCancellationDuringTransportIsPreserved() async throws {
        let sender = BlockingNodeSessionSender()
        let client = NodeSyncClient(sender: sender)
        let request = Task { try await client.snapshot(after: nil, limit: 25) }
        await sender.waitUntilCalled()
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("cancelled snapshot should not fall back or retry")
        } catch is CancellationError {
            let calls = await sender.callCount()
            XCTAssertEqual(calls, 1)
        }
    }

    func testRetryCancellationWaitsForTheActiveAttemptToDrain() async throws {
        let sender = RetryableScopedStatusSender()
        let client = NodeSyncClient(sender: sender, maximumAttempts: 2)
        let cancellation = NodeHTTPTransportRequestCancellation()
        let request = Task { try await client.status(cancellation: cancellation) }

        await sender.waitUntilSecondAttemptStarted()
        let cancellationWaitFinished = LockedFlag()
        let cancellationWait = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 16 {
                    group.addTask { await cancellation.cancelAndWait() }
                }
                await group.waitForAll()
            }
            cancellationWaitFinished.value = true
        }
        await sender.waitUntilCancellationRequested()
        for _ in 0 ..< 100 { await Task.yield() }

        XCTAssertFalse(cancellationWaitFinished.value, "request cancellation must wait for the active retry attempt")

        await sender.releaseSecondAttempt()
        await cancellationWait.value
        do {
            _ = try await request.value
            XCTFail("a cancelled retry must not publish a late result")
        } catch is CancellationError {
            // expected
        }
        XCTAssertTrue(cancellationWaitFinished.value)
        let attemptCount = await sender.attemptCount()
        let secondAttemptDrained = await sender.didDrainSecondAttempt()
        let cancellationRequestCount = await sender.cancellationRequestCount()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertTrue(secondAttemptDrained)
        XCTAssertEqual(cancellationRequestCount, 1, "concurrent cancellation must invoke the active attempt once")
    }

    func testInvalidPaginationFailsBeforeDispatch() async throws {
        let sender = RecordingNodeSessionSender(responses: [])
        let client = NodeSyncClient(sender: sender)
        do {
            _ = try await client.snapshot(after: nil, limit: 201)
            XCTFail("pagination above the wire bound should fail")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 0)
    }

    func testUnauthorizedSessionIsNotRetried() async throws {
        let problem = try NodeSyncCodec.encodeProblem(NodeSyncProblemResult(category: .unauthorized))
        let sender = RecordingNodeSessionSender(responses: [
            NodeHTTPResponse(statusCode: 401, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: problem),
        ])
        let client = NodeSyncClient(sender: sender, maximumAttempts: 3)
        do {
            _ = try await client.snapshot(after: nil, limit: 25)
            XCTFail("unauthorized session should fail")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .problem(.unauthorized))
        }
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testMutationPostDispatchFailureIsAmbiguousAndNeverRetried() async throws {
        let sender = PostDispatchFailureSender()
        let client = NodeSyncClient(sender: sender, maximumAttempts: 3)
        do {
            _ = try await client.mutation(canonicalOperation: try validCanonicalOperation())
            XCTFail("mutation should surface ambiguous dispatch")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .transportAfterDispatch)
        }
        let calls = await sender.callCount()
        XCTAssertEqual(calls, 1)
    }

    private func validCanonicalOperation() throws -> Data {
        let mailbox = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "11111111-1111-4111-8111-111111111111",
            authorityEpoch: "2",
            clientID: "22222222-2222-4222-8222-222222222222",
            idempotencyKey: "mutation-1",
            issuedAt: "2026-08-20T12:34:56Z",
            logicalMailboxID: mailbox,
            nodeID: "33333333-3333-4333-8333-333333333333",
            operation: .setRead(messageIDs: ["message-1"], read: true),
            trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)))
    }
}

private final class ExplicitCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func markCancelled() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private actor RetryableScopedStatusSender: NodeSessionRequestScopedSending {
    private var attempts = 0
    private var secondAttemptStarted = false
    private var cancellationRequested = false
    private var cancellationRequests = 0
    private var secondAttemptDidDrain = false
    private var secondAttemptContinuation: CheckedContinuation<Void, Error>?

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSyncClientError.transport
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        attempts += 1
        if attempts == 1 {
            cancellation.markCompleted()
            return NodeHTTPResponse(
                statusCode: 503,
                url: URL(string: "https://node.example.ts.net:443")!,
                headers: [:],
                body: Data()
            )
        }

        secondAttemptStarted = true
        cancellation.install { [weak self] in
            Task { await self?.markCancellationRequested() }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                secondAttemptContinuation = continuation
            }
        } catch {
            secondAttemptDidDrain = true
            cancellation.markCompleted()
            throw error
        }
        secondAttemptDidDrain = true
        cancellation.markCompleted()
        throw CancellationError()
    }

    func waitUntilSecondAttemptStarted() async {
        while !secondAttemptStarted { await Task.yield() }
    }

    func waitUntilCancellationRequested() async {
        while !cancellationRequested { await Task.yield() }
    }

    func markCancellationRequested() {
        cancellationRequested = true
        cancellationRequests += 1
    }

    func releaseSecondAttempt() {
        secondAttemptContinuation?.resume(throwing: CancellationError())
        secondAttemptContinuation = nil
    }

    func attemptCount() -> Int { attempts }
    func didDrainSecondAttempt() -> Bool { secondAttemptDidDrain }
    func cancellationRequestCount() -> Int { cancellationRequests }
}

actor RecordingNodeSessionSender: NodeSessionRequestSending {
    private var values: [NodeHTTPRequest] = []
    private var responses: [NodeHTTPResponse]

    init(responses: [NodeHTTPResponse]) { self.responses = responses }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        values.append(NodeHTTPRequest(endpoint: try NodeEndpointURL("https://node.example.ts.net:443"), method: method, path: path, body: body))
        guard !responses.isEmpty else { throw NodeSyncClientError.transport }
        return responses.removeFirst()
    }

    func requests() -> [NodeHTTPRequest] { values }
}

/// Records authority epoch installs; the transport, not the client, owns
/// monotonic ordering, so this records the last value per logical mailbox.
final class EpochRecordingNodeSessionSender: NodeSessionRequestSending, NodeAuthorityEpochUpdating, @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [LogicalMailboxID: String] = [:]
    private let response: NodeHTTPResponse

    init(response: NodeHTTPResponse) { self.response = response }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { response }

    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        lock.lock(); epochs[logicalMailboxID] = epoch; lock.unlock()
    }

    func installed() -> [LogicalMailboxID: String] {
        lock.lock(); defer { lock.unlock() }
        return epochs
    }
}

actor PendingMutationReconciliationSender: NodeSessionRequestSending, NodePendingMutationReconciling {
    private let recovery: NodeHTTPResponse
    private let response: NodeHTTPResponse
    private var reconciliationCount = 0
    private var dispatchCount = 0

    init(recovery: NodeHTTPResponse, response: NodeHTTPResponse) {
        self.recovery = recovery
        self.response = response
    }

    func reconcilePendingMutation() async throws -> NodeHTTPResponse? {
        reconciliationCount += 1
        return recovery
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        dispatchCount += 1
        return response
    }

    func reconciliationCalls() -> Int { reconciliationCount }
    func dispatchCalls() -> Int { dispatchCount }
}

actor PendingRequestReconciliationSender: NodeSessionRequestSending, NodePendingRequestReconciling {
    private let recovery: NodeHTTPResponse
    private let response: NodeHTTPResponse
    private var reconciliationCount = 0
    private var dispatchCount = 0

    init(recovery: NodeHTTPResponse, response: NodeHTTPResponse) {
        self.recovery = recovery
        self.response = response
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        reconciliationCount += 1
        return recovery
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        dispatchCount += 1
        return response
    }

    func reconciliationCalls() -> Int { reconciliationCount }
    func dispatchCalls() -> Int { dispatchCount }
}

actor AdmissionStreamingSender: NodeSessionStreamingRequestSending, NodePendingRequestReconciling {
    private let payload: Data
    private var recordedEvents: [String] = []

    init(payload: Data) { self.payload = payload }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        recordedEvents.append("reconcile")
        return NodeHTTPResponse(statusCode: 204, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSyncClientError.transport
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        recordedEvents.append("stream")
        let bytes = PlainpostByteStream(capacity: 1)
        let producer = bytes.producer
        Task {
            try? await producer.send(payload)
            producer.finish()
        }
        return NodeHTTPStreamResponse(
            statusCode: 200,
            url: URL(string: "https://node.example.ts.net:443")!,
            headers: [
                "Content-Type": "text/plain",
                "Content-Length": String(payload.count),
                "Content-Disposition": "attachment; filename=note.txt",
            ],
            bytes: bytes
        )
    }

    func events() -> [String] { recordedEvents }
}

actor PostDispatchFailureSender: NodeSessionRequestSending {
    private var calls = 0

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls += 1
        throw NodeSessionError.transportFailureAfterDispatch
    }

    func callCount() -> Int { calls }
}

actor StreamingRecordingNodeSessionSender: NodeSessionStreamingRequestSending {
    private let payload: Data
    private let headers: [String: String]
    private let blockAfterFirstChunk: Bool
    private let statusCode: Int
    private let cancellationProbe: ExplicitCancellationProbe?
    private var cancelled = false
    private var normalFinish = false
    private var transportCancellations = 0
    private var streamedPaths: [String] = []

    func paths() -> [String] { streamedPaths }

    fileprivate init(payload: Data, headers: [String: String], blockAfterFirstChunk: Bool = false, statusCode: Int = 200, cancellationProbe: ExplicitCancellationProbe? = nil) {
        self.payload = payload
        self.headers = headers
        self.blockAfterFirstChunk = blockAfterFirstChunk
        self.statusCode = statusCode
        self.cancellationProbe = cancellationProbe
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        fatalError("attachment tests must use the streaming boundary")
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        streamedPaths.append(path)
        let cancellationProbe = self.cancellationProbe
        let stream = PlainpostByteStream(capacity: 1, onCancellation: { [weak self] in
            cancellationProbe?.markCancelled()
            Task { await self?.markTransportCancelled() }
        })
        let producer = stream.producer
        Task { [weak self] in
            guard let self else { return }
            do {
                try await producer.send(Data(payload.prefix(1)))
                if await self.shouldBlockAfterFirstChunk() {
                    // NodeSyncClient pumps through another bounded stream, so keep
                    // producing a tiny chunk until backpressure guarantees suspension.
                    let blockingChunk = Data(payload.suffix(1))
                    while true { try await producer.send(blockingChunk) }
                } else {
                    try await producer.send(Data(payload.dropFirst()))
                    await self.markNormalFinish()
                    producer.finish()
                }
            } catch is CancellationError {
                await self.markCancelled()
            } catch {
                producer.fail(error)
            }
        }
        return NodeHTTPStreamResponse(statusCode: statusCode, url: URL(string: "https://node.example.ts.net:443")!, headers: headers, bytes: stream)
    }

    func shouldBlockAfterFirstChunk() -> Bool { blockAfterFirstChunk }
    func markCancelled() {
        cancelled = true
    }
    func waitUntilCancelled(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !cancelled && ContinuousClock.now < deadline { await Task.yield() }
        return cancelled
    }
    func waitUntilTransportCancelled(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while transportCancellations == 0 && ContinuousClock.now < deadline { await Task.yield() }
        return transportCancellations > 0
    }
    func markTransportCancelled() { transportCancellations += 1 }
    func transportCancellationCount() -> Int { transportCancellations }
    func markNormalFinish() { normalFinish = true }
    func wasCancelled() -> Bool { cancelled }
    func wasNormalFinish() -> Bool { normalFinish }
}

private actor RejectingSessionSender: NodeSessionRequestSending {
    private var calls = 0

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls += 1
        throw NodeSessionError.authenticationRejected
    }

    func callCount() -> Int { calls }
}

actor BlockingNodeSessionSender: NodeSessionRequestSending {
    private var called = false

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        called = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }

    func waitUntilCalled() async {
        while !called { await Task.yield() }
    }

    func callCount() -> Int { called ? 1 : 0 }
}
