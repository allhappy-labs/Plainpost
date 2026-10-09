import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport

final class NodeSessionTransportTests: XCTestCase {
    func testMutationSignatureUsesMailboxAuthorityEpochDistinctFromTrustEpoch() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-epochs")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1))
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: try NodeEndpointURL("https://node.tail1234.ts.net:8443"), store: store, identity: identity)
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        try transport.setAuthorityEpoch("9", for: logical)

        let operation = try NodeSyncCodec.decodeOperation(try transport.signMutation(
            variant: .setRead(messageIDs: ["message-1"], read: true),
            logicalMailboxID: logical,
            idempotencyKey: "epoch-vector",
            issuedAt: "2026-08-28T10:00:00Z"
        ))
        XCTAssertEqual(operation.unsigned.authorityEpoch, "9")
        XCTAssertEqual(operation.unsigned.trustEpoch, "1")
    }

    func testAuthorityEpochInstallIsMonotonicForOutOfOrderAndConcurrentReads() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-epochs-monotonic")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1))
        let transport = try NodeSessionTransport(reference: reference, clientID: try AccountDeviceID("33333333-3333-4333-8333-333333333333"), endpoint: try NodeEndpointURL("https://node.tail1234.ts.net:8443"), store: store, identity: identity)
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let other = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 8, count: 32)))
        func signedEpoch(_ mailbox: LogicalMailboxID) throws -> String {
            try NodeSyncCodec.decodeOperation(try transport.signMutation(
                variant: .setRead(messageIDs: ["message-1"], read: true), logicalMailboxID: mailbox,
                idempotencyKey: "epoch-monotonic", issuedAt: "2026-08-28T10:00:00Z"
            )).unsigned.authorityEpoch
        }

        // A newer read (epoch 10) completes before an older one (epoch 9).
        try transport.setAuthorityEpoch("10", for: logical)
        try transport.setAuthorityEpoch("9", for: logical)
        XCTAssertEqual(try signedEpoch(logical), "10")
        try transport.setAuthorityEpoch("11", for: logical)
        XCTAssertEqual(try signedEpoch(logical), "11")

        // Many concurrent installs in shuffled order settle on the highest.
        let epochs = Array(1...200).shuffled()
        await withTaskGroup(of: Void.self) { group in
            for epoch in epochs {
                group.addTask { try? transport.setAuthorityEpoch(String(epoch), for: other) }
            }
        }
        XCTAssertEqual(try signedEpoch(other), "200")
        XCTAssertEqual(try signedEpoch(logical), "11", "another logical mailbox's epochs never affect this one")
    }

    func testSendSignsExactRequestAndConsumesSequenceBeforeTransport() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-session")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 9))
        let received = RequestCapture()
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let client = NodeTLSClient(transport: NodeHTTPTransportFixture { request in
            await received.set(request)
            return NodeHTTPResponse(statusCode: 204, url: endpoint.url, headers: [:], body: Data())
        })
        let transport = try NodeSessionTransport(reference: reference, clientID: try AccountDeviceID("33333333-3333-4333-8333-333333333333"), endpoint: endpoint, store: store, identity: identity, client: client)

        _ = try await transport.send(method: "POST", path: "/v1/messages?cursor=next", body: Data("body".utf8), now: Date(timeIntervalSince1970: 1_786_260_000))

        let captured = await received.value()
        let request = try XCTUnwrap(captured)
        let wire = try XCTUnwrap(request.value(forHTTPHeaderField: "Plainpost-Signed-Request"))
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: String])
        XCTAssertEqual(fields["sequence"], "9")
        XCTAssertEqual(fields["path"], "/v1/messages?cursor=next")
        XCTAssertEqual(fields["audience"], "node.tail1234.ts.net:8443")
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.url?.query, "cursor=next")
        XCTAssertEqual(request.httpBody, Data("body".utf8))
        let signed = try SignedRequestV1(accountID: account.rawValue, clientID: "33333333-3333-4333-8333-333333333333", nodeID: node.rawValue, trustEpoch: 1, audience: try XCTUnwrap(fields["audience"]), sequence: 9, method: "POST", path: try XCTUnwrap(fields["path"]), bodySHA256: try NodeSessionWire.decodeBase64URL(try XCTUnwrap(fields["bodySHA256"])), issuedAt: try XCTUnwrap(fields["issuedAt"]), signature: try NodeSessionWire.decodeBase64URL(try XCTUnwrap(fields["signature"])))
        let key = try P256.Signing.PublicKey(x963Representation: identity.publicBundle.signingKey)
        XCTAssertTrue(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signed.signature), for: try NodeSessionTranscript.request(signed)))
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 10)
    }

    func testConcurrentRequestsUseOneSerializedSessionLane() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-serialized-lane")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let probe = SerializedLaneProbe(endpoint: endpoint.url)
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: probe))

        async let first = transport.send(method: "GET", path: "/v1/status", body: Data())
        async let second = transport.send(method: "GET", path: "/v1/status", body: Data())
        _ = try await (first, second)

        let maximumActive = await probe.maximumActive()
        let sequences = await probe.sequences()
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(sequences, ["1", "2"])
        XCTAssertEqual(try store.load(for: reference).nextSequence, 3)
    }

    func testCancelledQueuedRequestIsRemovedWithoutIssuingIOTask() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-cancelled-lane")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let probe = SerializedLaneProbe(endpoint: endpoint.url, delay: .milliseconds(100))
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: probe))

        let first = Task { try await transport.send(method: "GET", path: "/v1/status", body: Data()) }
        for _ in 0..<100 {
            if await probe.activeCount() == 1 { break }
            await Task.yield()
        }
        let cancelled = Task { try await transport.send(method: "GET", path: "/v1/status", body: Data()) }
        cancelled.cancel()
        let third = Task { try await transport.send(method: "GET", path: "/v1/status", body: Data()) }

        _ = try await first.value
        do { _ = try await cancelled.value; XCTFail("cancelled queued request must not issue") }
        catch is CancellationError { }
        catch { XCTFail("unexpected cancellation error: \(error)") }
        _ = try await third.value

        let sequences = await probe.sequences()
        XCTAssertEqual(sequences, ["1", "2"])
        XCTAssertEqual(try store.load(for: reference).nextSequence, 3)
    }

    func testProviderReadinessCancellationRemovesStatusWaitingOnSessionLane() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-status-cancel-lane")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let probe = LaneHoldingTransport(endpoint: endpoint.url)
        let session = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: probe))

        let first = Task { try await session.send(method: "GET", path: "/v1/messages", body: Data()) }
        await probe.waitUntilFirstStarted()

        let controller = SyncNodeProviderController(client: NodeSyncClient(sender: session))
        let readiness = Task {
            try await controller.waitForTrustedProviderStatus(timeout: .milliseconds(30), pollInterval: .milliseconds(1))
        }
        do {
            _ = try await readiness.value
            XCTFail("queued status readiness must time out")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        let requestCount = await probe.requestCount()
        XCTAssertEqual(requestCount, 1, "cancelling queued status must not dispatch a second request")
        await probe.releaseFirst()
        _ = try await first.value
    }

    func testRestartLocatorRequiresMatchingMetadataAndThisDeviceOnlySession() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-locator")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let deviceID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "4"), endpointCiphertext: Data(repeating: 1, count: 48))
        let session = try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1)
        try store.save(reference: reference, session: session)
        let credentials = try AccountSessionCredentials(accountID: account, deviceID: deviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 9, count: 32), offlineLease: "lease")
        let published = try SyncNodePublishedEndpointV1(accountID: account, nodeID: node, trustEpoch: reference.trustEpoch, endpoint: URL(string: "https://node.tail1234.ts.net:8443")!)
        let restored = try SyncNodeSessionLocator.restore(published: published, credentials: credentials, device: identity, store: store, client: NodeTLSClient(transport: NodeHTTPTransportFixture { request in NodeHTTPResponse(statusCode: 204, url: request.url!, headers: [:], body: Data()) }))
        _ = try await restored.send(method: "GET", path: "/v1/status", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_000))

        let wrongEpoch = try SyncNodePublishedEndpointV1(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "5"), endpoint: published.endpoint)
        XCTAssertThrowsError(try SyncNodeSessionLocator.restore(published: wrongEpoch, credentials: credentials, device: identity, store: store))
    }

    func testCachedRestoreUsesOnlyThisDeviceEndpointAndDoesNotCallCentral() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-cached-locator")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let deviceID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let epoch = try AccountTrustEpoch(wire: "4")
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: epoch, endpointCiphertext: Data(repeating: 1, count: 48))
        let session = try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1)
        try store.save(reference: reference, session: session)
        let endpoint = URL(string: "https://node.tail1234.ts.net:8443")!
        try store.saveEndpoint(endpoint, for: reference, identity: identity)
        let credentials = try AccountSessionCredentials(accountID: account, deviceID: deviceID, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000), refreshCredential: Data(repeating: 9, count: 32), offlineLease: "lease")
        let nodeRequests = RequestCounter()
        let restored = try SyncNodeSessionLocator.restoreCached(credentials: credentials, nodeID: node, trustEpoch: epoch, device: identity, store: store, client: NodeTLSClient(transport: NodeHTTPTransportFixture { request in
            await nodeRequests.record(request)
            return NodeHTTPResponse(statusCode: 204, url: request.url!, headers: [:], body: Data())
        }))
        _ = try await restored.send(method: "GET", path: "/v1/status", body: Data())
        let requestCount = await nodeRequests.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testRestartedGenericBodyFailsClosedWithoutPersistingRequestContent() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-pending")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        let session = try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7)
        try store.save(reference: reference, session: session)
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = LostResponseCapture(endpoint: endpoint.url)
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        await XCTAssertThrowsErrorAsync(try await transport.send(method: "POST", path: "/v1/messages", body: Data("first".utf8)))
        let pending = try XCTUnwrap(store.loadPending(for: reference))
        XCTAssertEqual(pending.method, "POST")
        XCTAssertEqual(pending.path, "/v1/messages")
        XCTAssertEqual(pending.body, Data("first".utf8))
        let firstRequests = await capture.requests()
        let firstRequest = try XCTUnwrap(firstRequests.first)
        let firstIssuedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: try signedField(firstRequest, "issuedAt")))
        while Date() < firstIssuedAt.addingTimeInterval(1) {
            try await Task.sleep(for: .milliseconds(10))
        }
        await XCTAssertThrowsErrorAsync(try await transport.send(method: "POST", path: "/v1/messages", body: Data("different".utf8)))
        // A new owner cannot reconstruct arbitrary request bytes. It fails
        // closed instead of persisting or guessing the body.
        let restartedStore = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-pending")
        let restarted = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: restartedStore, identity: identity, client: NodeTLSClient(transport: capture))
        await XCTAssertThrowsErrorAsync(try await restarted.send(method: "POST", path: "/v1/messages", body: Data("first".utf8)))
        let requests = await capture.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try store.load(for: reference).nextSequence, 7)
    }

    func testAmbiguousAssignmentReplaysBeforeAStatusRequest() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-assignment-pending")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = LostResponseCapture(endpoint: endpoint.url)
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        await XCTAssertThrowsErrorAsync(try await transport.send(method: "PUT", path: "/v1/mailboxes/assignments", body: Data("assignment".utf8)))
        await XCTAssertThrowsErrorAsync(try await transport.send(method: "GET", path: "/v1/status", body: Data())) { error in
            XCTAssertEqual(error as? NodeSessionError, .applicationResultUncertain)
        }
        _ = try await transport.send(method: "GET", path: "/v1/status", body: Data())

        let requests = await capture.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[1].httpMethod, "PUT")
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[2].httpMethod, "GET")
        let sequences = try requests.map { try signedField($0, "sequence") }
        XCTAssertEqual(sequences, ["7", "7", "8"])
    }

    // Catches a regression where an authenticated duplicate response leaves
    // the durable reservation in place, permanently preventing the next
    // application request from advancing the strict Node sequence.
    func testDuplicateResponseCommitsPendingAsUncertainThenNextRequestAdvances() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-duplicate")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = SequenceResponseCapture(endpoint: endpoint.url, statuses: [409, 204])
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        await XCTAssertThrowsErrorAsync(try await transport.send(method: "POST", path: "/v1/messages", body: Data("possibly-applied".utf8), now: Date(timeIntervalSince1970: 1_786_260_000))) { error in
            XCTAssertEqual(error as? NodeSessionError, .applicationResultUncertain)
        }
        _ = try await transport.send(method: "POST", path: "/v1/messages", body: Data("next".utf8), now: Date(timeIntervalSince1970: 1_786_260_001))

        let sequences = await capture.sequences()
        XCTAssertEqual(sequences, ["7", "8"])
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 9)
    }

    // A Node authentication rejection happens before the Go middleware has
    // consumed its durable sequence. The typed outcome must release the
    // reservation without asking the generic client to retry this stale session.
    func testAuthenticationRejectionRollsBackReservationWithoutRetry() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-auth-rejection")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = SequenceResponseCapture(endpoint: endpoint.url, responses: [
            (401, middlewareProblem(type: "node-auth-rejected", status: 401)),
            (204, Data()),
        ])
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        await XCTAssertThrowsErrorAsync(try await transport.send(method: "POST", path: "/v1/messages", body: Data("retry".utf8), now: Date(timeIntervalSince1970: 1_786_260_000))) { error in
            XCTAssertEqual(error as? NodeSessionError, .authenticationRejected)
        }

        let requests = await capture.sentRequests()
        let sequences = await capture.sequences()
        XCTAssertEqual(sequences, ["7"])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 7)
    }

    func testDeterministicMutationRejectionClearsDurableReplayPayload() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-mutation-rejection")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = SequenceResponseCapture(endpoint: endpoint.url, responses: [
            (409, middlewareProblem(type: "node-sequence-rejected", status: 409)),
            (204, Data()),
        ])
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))
        let mutation = try validCanonicalMutation()

        await XCTAssertThrowsErrorAsync(try await transport.send(method: "POST", path: "/v1/mutations", body: mutation)) { error in
            XCTAssertEqual(error as? NodeSessionError, .invalidValue)
        }
        XCTAssertNil(try store.loadRetainedMutation(for: reference))
        _ = try await transport.send(method: "GET", path: "/v1/status", body: Data())
        let sequences = await capture.sequences()
        XCTAssertEqual(sequences, ["7", "7"])
        XCTAssertEqual(try store.load(for: reference).nextSequence, 8)
    }

    func testBareConflictIsAnApplicationResponseThatCommitsTheReservation() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-bare-conflict")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = SequenceResponseCapture(endpoint: endpoint.url, statuses: [409, 204], exactConflict: false)
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        let conflict = try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_000))
        XCTAssertEqual(conflict.statusCode, 409)
        _ = try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_001))
        let sequences = await capture.sequences()
        XCTAssertEqual(sequences, ["7", "8"])
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 9)
    }

    func testExactPreConsumptionMiddlewareProblemsReleaseTheReservation() async throws {
        for problem in try MiddlewareDispositionFixture.load().closedPreConsumption {
            let name = problem.name ?? problem.type ?? "unknown"
            let response = (problem.status, problem.body)
            let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-pre-consumption.\(name)")
            let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
            let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
            let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
            try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
            let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
            let capture = SequenceResponseCapture(endpoint: endpoint.url, responses: [response, (204, Data())])
            let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

            await XCTAssertThrowsErrorAsync(try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_000)))
            _ = try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_001))
            let sequences = await capture.sequences()
            XCTAssertEqual(sequences, ["7", "7"], name)
        }
    }

    func testEveryNonMiddlewareResponseCommitsAndReturnsItToTheApplication() async throws {
        let fixture = try MiddlewareDispositionFixture.load()
        let examples = fixture.postDispatchExamples + [.init(name: "bare-unauthorized", type: nil, status: 401)]
        for example in examples {
            let name = example.name ?? "unknown"
            let response = (example.status, name == "application-bad-request" ? Data("{\"type\":\"urn:plainpost:application-invalid\",\"status\":400}".utf8) : Data())
            let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-dispatched.\(name)")
            let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
            let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
            let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
            try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
            let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
            let capture = SequenceResponseCapture(endpoint: endpoint.url, responses: [response])
            let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

            let received = try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_000))
            XCTAssertEqual(received.statusCode, response.0, name)
            XCTAssertEqual(try store.consumeNextSequence(for: reference), 8, name)
        }
    }

    func testExactPreConsumptionUnavailableProblemRetriesWithRetainedTimestamp() async throws {
        let problem = try MiddlewareDispositionFixture.load().preConsumptionUncertain
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-pre-consumption-uncertain")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = SequenceResponseCapture(endpoint: endpoint.url, responses: [(problem.status, problem.body), (204, Data())])
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        await XCTAssertThrowsErrorAsync(try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_000))) { error in
            XCTAssertEqual(error as? NodeSessionError, .transportFailure)
        }
        _ = try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_001))
        let requests = await capture.sentRequests()
        let sequences = await capture.sequences()
        XCTAssertEqual(sequences, ["7", "7"])
        XCTAssertEqual(try signedField(requests[0], "issuedAt"), try signedField(requests[1], "issuedAt"))
        XCTAssertEqual(try store.load(for: reference).nextSequence, 8)
    }

    func testTransportFailureAfterRequestDispatchIsExplicitlyAmbiguous() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-transport-after-dispatch")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: NodeHTTPTransportFixture { _ in
            throw NodeSessionError.transportFailure
        }))

        do {
            _ = try await transport.send(method: "POST", path: "/v1/private", body: Data("outage".utf8))
            XCTFail("a transport failure after dispatch must not return")
        } catch let error as NodeSessionError {
            XCTAssertEqual(error, .transportFailureAfterDispatch)
        }
        XCTAssertEqual(try store.load(for: reference).nextSequence, 7)
    }

    // Catches a regression where malformed caller input reserves a sequence
    // before its signed envelope is complete, bricking the strict stream.
    func testPreIOValidationDoesNotReserveSequence() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-validation")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let capture = SequenceResponseCapture(endpoint: endpoint.url, statuses: [204])
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        await XCTAssertThrowsErrorAsync(try await transport.send(method: "post", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_000)))
        _ = try await transport.send(method: "POST", path: "/v1/messages", body: Data(), now: Date(timeIntervalSince1970: 1_786_260_000))

        let sequences = await capture.sequences()
        XCTAssertEqual(sequences, ["7"])
    }

    func testPostDispatchCancellationIsExplicitlyAmbiguous() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-post-dispatch-cancel")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: NodeHTTPTransportFixture { _ in
            try await Task.sleep(for: .seconds(10))
            return NodeHTTPResponse(statusCode: 204, url: endpoint.url, headers: [:], body: Data())
        }))
        let request = Task { try await transport.send(method: "POST", path: "/v1/mailboxes/assignments", body: Data("mutation".utf8)) }
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("post-dispatch cancellation must be explicit")
        } catch let error as NodeSessionError {
            XCTAssertEqual(error, .transportCancellationAfterDispatch)
        }
    }

    func testCancelledAfterDispatchCanReconcileExactPendingMutation() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-cancel-reconcile")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let result = try NodeSyncMutationResult(idempotencyKey: "retained-mutation", state: "applied")
        let canonicalOperation = try validCanonicalMutation()
        let transport = CancelThenMutationTransport(endpoint: endpoint.url, response: NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: [:], body: try NodeSyncCodec.encodeMutationResult(result)))
        let session = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: transport))

        let request = Task { try await session.send(method: "POST", path: "/v1/mutations", body: canonicalOperation) }
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("cancelled dispatch must remain ambiguous")
        } catch let error as NodeSessionError {
            XCTAssertEqual(error, .transportCancellationAfterDispatch)
        }

        let recreatedStore = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-cancel-reconcile")
        let recreated = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: recreatedStore, identity: identity, client: NodeTLSClient(transport: transport))
        let recovered = try await recreated.reconcilePendingMutation()
        XCTAssertEqual(recovered?.statusCode, 200)
        XCTAssertNil(try store.loadPending(for: reference))
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 8)
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testRetainedPendingMutationReplaysByteIdenticalOperationUntilTerminal() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-retained-pending-mutation")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let pending = try NodeSyncMutationResult(idempotencyKey: "retained-mutation", state: "pending")
        let applied = try NodeSyncMutationResult(idempotencyKey: "retained-mutation", state: "applied")
        let canonicalOperation = try validCanonicalMutation()
        let transport = RetainedPendingMutationTransport(endpoint: endpoint.url, responses: [
            NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: [:], body: try NodeSyncCodec.encodeMutationResult(pending)),
            NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: [:], body: try NodeSyncCodec.encodeMutationResult(pending)),
            NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: [:], body: try NodeSyncCodec.encodeMutationResult(pending)),
            NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: [:], body: try NodeSyncCodec.encodeMutationResult(applied))
        ])
        let session = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: transport))

        let request = Task { try await session.send(method: "POST", path: "/v1/mutations", body: canonicalOperation) }
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()
        await XCTAssertThrowsErrorAsync(try await request.value) { error in
            XCTAssertEqual(error as? NodeSessionError, .transportCancellationAfterDispatch)
        }

        let recreatedStore = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-retained-pending-mutation")
        let recreated = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: recreatedStore, identity: identity, client: NodeTLSClient(transport: transport))
        let first = try await recreated.reconcilePendingMutation()
        XCTAssertEqual(try NodeSyncCodec.decodeMutationResult(first!.body), applied)
        let second = try await recreated.reconcilePendingMutation()
        XCTAssertNil(second)
        XCTAssertNil(try store.loadRetainedMutation(for: reference))
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 11)
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 5)
        let bodies = await transport.mutationBodies()
        XCTAssertEqual(Set(bodies), [canonicalOperation])
    }

    func testPostDispatchMalformedResponseIsExplicitlyAmbiguous() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-post-dispatch-malformed")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: NodeHTTPTransportFixture { request in
            NodeHTTPResponse(statusCode: 204, url: URL(string: "https://other.example")!, headers: [:], body: Data())
        }))
        do {
            _ = try await transport.send(method: "POST", path: "/v1/mailboxes/assignments", body: Data("mutation".utf8))
            XCTFail("malformed post-dispatch response must be explicit")
        } catch let error as NodeSessionError {
            XCTAssertEqual(error, .transportFailureAfterDispatch)
        }
    }

    func testRecreatedStoreReconcilesMalformedMutationResponseByteIdentically() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-malformed-mutation")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let operation = try validCanonicalMutation()
        let result = try NodeSyncMutationResult(idempotencyKey: "retained-mutation", state: "applied")
        let capture = MalformedMutationResponseTransport(endpoint: endpoint.url, applied: try NodeSyncCodec.encodeMutationResult(result))
        let session = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        do {
            _ = try await session.send(method: "POST", path: "/v1/mutations", body: operation)
            XCTFail("malformed mutation response must remain ambiguous")
        } catch let error as NodeSessionError {
            XCTAssertEqual(error, .transportFailureAfterDispatch)
        }
        XCTAssertNotNil(try store.loadRetainedMutation(for: reference))

        let restartedStore = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-malformed-mutation")
        let restarted = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: restartedStore, identity: identity, client: NodeTLSClient(transport: capture))
        let recovered = try await restarted.reconcilePendingMutation()
        XCTAssertEqual(try NodeSyncCodec.decodeMutationResult(try XCTUnwrap(recovered).body), result)
        let mutationBodies = await capture.mutationBodies()
        XCTAssertEqual(mutationBodies, [operation, operation])
        XCTAssertNil(try restartedStore.loadRetainedMutation(for: reference))
    }

    func testWrongKeyMutationResultRetainsCanonicalReplayAcrossRecreatedStore() async throws {
        let secrets = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-wrong-key-mutation")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111"), node = try AccountDeviceID("22222222-2222-4222-8222-222222222222"), clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let operation = try validCanonicalMutation()
        let wrong = try NodeSyncCodec.encodeMutationResult(try NodeSyncMutationResult(idempotencyKey: "not-the-operation", state: "applied"))
        let applied = try NodeSyncCodec.encodeMutationResult(try NodeSyncMutationResult(idempotencyKey: "retained-mutation", state: "applied"))
        let capture = WrongMutationKeyResponseTransport(endpoint: endpoint.url, wrong: wrong, applied: applied)
        let session = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: NodeTLSClient(transport: capture))

        await XCTAssertThrowsErrorAsync(try await session.send(method: "POST", path: "/v1/mutations", body: operation)) { error in
            XCTAssertEqual(error as? NodeSessionError, .transportFailureAfterDispatch)
        }
        XCTAssertNotNil(try store.loadRetainedMutation(for: reference))

        let recreatedStore = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-wrong-key-mutation")
        let recreated = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: recreatedStore, identity: identity, client: NodeTLSClient(transport: capture))
        let recovered = try await recreated.reconcilePendingMutation()
        XCTAssertEqual(try NodeSyncCodec.decodeMutationResult(try XCTUnwrap(recovered).body).idempotencyKey, "retained-mutation")
        let mutationBodies = await capture.mutationBodies()
        XCTAssertEqual(mutationBodies, [operation, operation])
        XCTAssertNil(try recreatedStore.loadRetainedMutation(for: reference))
    }

    func testStreamingCommitFailureCancelsAcquiredResponse() async throws {
        let secrets = CommitFailingSecretStore(failStartingAtCompareAndSwap: 3)
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.node-stream-commit-failure")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        let reference = try SyncNodeEndpointReference(accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let cancellation = StreamCancellationProbe()
        let client = NodeTLSClient(transport: SuccessfulStreamingTransport(endpoint: endpoint.url, cancellation: cancellation))
        let transport = try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: endpoint, store: store, identity: identity, client: client)

        await XCTAssertThrowsErrorAsync(try await transport.stream(method: "GET", path: "/v1/attachments/item", body: Data(), maximumResponseBytes: 1024)) { error in
            XCTAssertEqual(error as? AccountRuntimeError, .secretUnavailable)
        }
        XCTAssertEqual(cancellation.count, 1)
    }
}

private actor RequestCounter {
    private var value = 0
    func record(_ request: URLRequest) { value += 1 }
    func count() -> Int { value }
}

private actor RequestCapture { private var request: URLRequest?; func set(_ request: URLRequest) { self.request = request }; func value() -> URLRequest? { request } }
private actor SerializedLaneProbe: NodeHTTPTransport {
    let endpoint: URL
    private let delay: Duration
    private var active = 0
    private var maximum = 0
    private var requests: [URLRequest] = []
    init(endpoint: URL, delay: Duration = .milliseconds(15)) { self.endpoint = endpoint; self.delay = delay }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        active += 1; maximum = max(maximum, active); requests.append(request)
        try await Task.sleep(for: delay)
        active -= 1
        return NodeHTTPResponse(statusCode: 204, url: endpoint, headers: [:], body: Data())
    }
    func activeCount() -> Int { active }
    func maximumActive() -> Int { maximum }
    func sequences() -> [String] { requests.compactMap { request in try? signedField(request, "sequence") } }
}

private actor LaneHoldingTransport: NodeHTTPTransportRequestScoped {
    private let endpoint: URL
    private var requests = 0
    private var firstStarted = false
    private var firstWaiter: CheckedContinuation<Void, Never>?

    init(endpoint: URL) { self.endpoint = endpoint }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        requests += 1
        if requests == 1 {
            firstStarted = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                firstWaiter = continuation
            }
        }
        return NodeHTTPResponse(statusCode: 204, url: endpoint, headers: [:], body: Data())
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        requests += 1
        throw NodeSessionError.transportFailure
    }

    func waitUntilFirstStarted() async {
        while !firstStarted { await Task.yield() }
    }

    func releaseFirst() {
        let waiter = firstWaiter
        firstWaiter = nil
        waiter?.resume()
    }

    func requestCount() -> Int { requests }
}
private actor LostResponseCapture: NodeHTTPTransport {
    private let endpoint: URL; private var sent: [URLRequest] = []
    init(endpoint: URL) { self.endpoint = endpoint }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        sent.append(request)
        if sent.count == 1 { throw NodeSessionError.transportFailure }
        return NodeHTTPResponse(statusCode: 204, url: endpoint, headers: [:], body: Data())
    }
    func requests() -> [URLRequest] { sent }
}
private actor SequenceResponseCapture: NodeHTTPTransport {
    private let endpoint: URL; private let statuses: [Int]; private let exactConflict: Bool; private var requests: [URLRequest] = []
    init(endpoint: URL, statuses: [Int], exactConflict: Bool = true) { self.endpoint = endpoint; self.statuses = statuses; self.exactConflict = exactConflict }
    init(endpoint: URL, responses: [(Int, Data)]) { self.endpoint = endpoint; statuses = responses.map { $0.0 }; exactConflict = false; responseBodies = responses.map { $0.1 } }
    private var responseBodies: [Data] = []
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        requests.append(request)
        let status = statuses[requests.count - 1]
        let body = responseBodies.indices.contains(requests.count - 1) ? responseBodies[requests.count - 1] : (status == 409 && exactConflict ? Data("{\"type\":\"urn:plainpost:node-sequence-consumed\",\"status\":409}\n".utf8) : Data())
        return NodeHTTPResponse(statusCode: status, url: endpoint, headers: [:], body: body)
    }
    func sequences() -> [String] {
        requests.compactMap { request in
            guard let header = request.value(forHTTPHeaderField: "Plainpost-Signed-Request"), let fields = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String] else { return nil }
            return fields["sequence"]
        }
    }
    func sentRequests() -> [URLRequest] { requests }
}
private struct NodeHTTPTransportFixture: NodeHTTPTransport { let handler: @Sendable (URLRequest) async throws -> NodeHTTPResponse; func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { try await handler(request) } }

private actor CancelThenMutationTransport: NodeHTTPTransport {
    let endpoint: URL
    let response: NodeHTTPResponse
    var calls = 0

    init(endpoint: URL, response: NodeHTTPResponse) {
        self.endpoint = endpoint
        self.response = response
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls += 1
        if calls == 1 {
            try await Task.sleep(for: .seconds(60))
        }
        return response
    }

    func callCount() -> Int { calls }
}

private actor RetainedPendingMutationTransport: NodeHTTPTransport {
    let endpoint: URL
    let responses: [NodeHTTPResponse]
    var calls = 0
    var requests: [URLRequest] = []

    init(endpoint: URL, responses: [NodeHTTPResponse]) {
        self.endpoint = endpoint
        self.responses = responses
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls += 1
        requests.append(request)
        if calls == 1 { try await Task.sleep(for: .seconds(60)) }
        let index = min(calls - 2, responses.count - 1)
        return responses[index]
    }

    func callCount() -> Int { calls }
    func mutationBodies() -> [Data] { requests.compactMap(\.httpBody) }
}

private actor MalformedMutationResponseTransport: NodeHTTPTransport {
    let endpoint: URL
    let applied: Data
    private var calls = 0
    private var bodies: [Data] = []

    init(endpoint: URL, applied: Data) { self.endpoint = endpoint; self.applied = applied }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls += 1
        bodies.append(request.httpBody ?? Data())
        if calls == 1 { return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: Data("truncated".utf8)) }
        return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: applied)
    }

    func mutationBodies() -> [Data] { bodies }
}

private actor WrongMutationKeyResponseTransport: NodeHTTPTransport {
    let endpoint: URL
    let wrong: Data
    let applied: Data
    private var calls = 0
    private var bodies: [Data] = []

    init(endpoint: URL, wrong: Data, applied: Data) { self.endpoint = endpoint; self.wrong = wrong; self.applied = applied }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls += 1
        bodies.append(request.httpBody ?? Data())
        return NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: calls == 1 ? wrong : applied)
    }

    func mutationBodies() -> [Data] { bodies }
}

private final class StreamCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func cancel() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct SuccessfulStreamingTransport: NodeHTTPStreamingTransport {
    let endpoint: URL
    let cancellation: StreamCancellationProbe
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        fatalError("streaming fixture must use stream(_:maximumResponseBytes:)")
    }
    func stream(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        NodeHTTPStreamResponse(statusCode: 204, url: endpoint, headers: [:], bytes: PlainpostByteStream(capacity: 1, onCancellation: cancellation.cancel))
    }
}

private final class CommitFailingSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let base = InMemoryAccountSecretStore()
    private let lock = NSLock()
    private let failureCall: Int
    private var compareAndSwapCalls = 0
    init(failStartingAtCompareAndSwap failureCall: Int) { self.failureCall = failureCall }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try base.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws { try base.replace(value, key: key, attributes: attributes) }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        lock.lock()
        compareAndSwapCalls += 1
        let shouldFail = compareAndSwapCalls >= failureCall
        lock.unlock()
        if shouldFail { return false }
        return try base.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws { try base.delete(key) }
}

private func signedField(_ request: URLRequest, _ name: String) throws -> String {
    let wire = try XCTUnwrap(request.value(forHTTPHeaderField: "Plainpost-Signed-Request"))
    return try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: String])?[name])
}

private func validCanonicalMutation() throws -> Data {
    let account = "11111111-1111-4111-8111-111111111111"
    let client = "33333333-3333-4333-8333-333333333333"
    let node = "22222222-2222-4222-8222-222222222222"
    let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
    let unsigned = try NodeSyncUnsignedOperation(
        accountID: account, authorityEpoch: "9", clientID: client,
        idempotencyKey: "retained-mutation", issuedAt: "2026-08-28T10:00:00Z",
        logicalMailboxID: mailbox, nodeID: node,
        operation: .setRead(messageIDs: ["message-1"], read: true), trustEpoch: "1"
    )
    let operation = try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64))
    return try NodeSyncCodec.encodeMutationRequest(try NodeSyncMutationRequest(canonicalOperation: NodeSyncCodec.encodeOperation(operation)))
}

private func middlewareProblem(type: String, status: Int) -> Data {
    Data("{\"type\":\"urn:plainpost:\(type)\",\"status\":\(status)}\n".utf8)
}

private struct MiddlewareDispositionFixture: Decodable {
    struct Problem: Decodable {
        let name: String?
        let type: String?
        let status: Int
        var body: Data { Data("{\"type\":\"\(type!)\",\"status\":\(status)}\n".utf8) }
    }
    let kind: String
    let schemaVersion: Int
    let closedPreConsumption: [Problem]
    let exactConsumed: Problem
    let preConsumptionUncertain: Problem
    let postDispatchExamples: [Problem]

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-session-v1/fixtures/middleware-disposition-v1.json")
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: root))
        guard fixture.kind == "node-session-v1.middleware-disposition", fixture.schemaVersion == 1,
              fixture.closedPreConsumption.count == 3, fixture.exactConsumed.type != nil,
              fixture.preConsumptionUncertain.type != nil
        else { throw NodeSessionError.invalidValue }
        return fixture
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure @escaping () async throws -> T, file: StaticString = #filePath, line: UInt = #line, verify: ((Error) -> Void)? = nil) async {
    do { _ = try await expression(); XCTFail("expected error", file: file, line: line) }
    catch { verify?(error) }
}
