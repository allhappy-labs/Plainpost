import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeMailMode
@testable import PlainpostNodeTransport
@testable import PlainpostServiceIPC

final class NodeSessionBrokerTests: XCTestCase {
    func testCurrentAdmissionReflectsLeaseChangeWithoutReusingCachedState() async throws {
        let admission = LockedAdmission(.readWrite)
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", BrokerCapabilityTransport()) }, check: {
            NodeSessionCheck(admission: admission.value, binding: "account/node/epoch")
        })
        let initially = try await broker.currentAdmission()
        XCTAssertEqual(initially, .readWrite)
        let expiry = Date().addingTimeInterval(60)
        admission.set(.readOnly(expiresAt: expiry))
        let afterExpiry = try await broker.currentAdmission()
        XCTAssertEqual(afterExpiry, .readOnly(expiresAt: expiry))
    }

    func testExpiredTokenNeedsVerifiedUnexpiredLease() throws {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(try NodeSessionAdmissionPolicy.admission(accessExpiresAt: now.addingTimeInterval(1), verifiedLeaseExpiresAt: nil, now: now), .readWrite)
        XCTAssertEqual(try NodeSessionAdmissionPolicy.admission(accessExpiresAt: now, verifiedLeaseExpiresAt: now.addingTimeInterval(1), now: now), .readOnly(expiresAt: now.addingTimeInterval(1)))
        XCTAssertThrowsError(try NodeSessionAdmissionPolicy.admission(accessExpiresAt: now, verifiedLeaseExpiresAt: now, now: now))
    }

    func testLeaseAllowsReadButRefusesMutationBeforeTransport() async throws {
        let transport = BrokerTestTransport()
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: .readOnly(expiresAt: Date().addingTimeInterval(60)), binding: "account/node/epoch")
        })
        let client = try await broker.sessionSender()
        _ = try await client.sender.send(method: "POST", path: "/v1/mail/snapshot", body: Data(), maximumResponseBytes: 1024)
        do {
            _ = try await client.sender.send(method: "POST", path: "/v1/mail/send", body: Data(), maximumResponseBytes: 1024)
            XCTFail("lease permitted mutation")
        } catch NodeSessionBrokerError.readOnly {}
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testBindingChangeInvalidatesHandedOutSender() async throws {
        let binding = LockedBinding("account/node/epoch1")
        let transport = BrokerTestTransport()
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: .readWrite, binding: binding.value)
        })
        let old = try await broker.sessionSender()
        binding.set("account/node/epoch2")
        do {
            _ = try await old.sender.send(method: "GET", path: "/v1/status", body: Data(), maximumResponseBytes: 1024)
            XCTFail("old epoch sent")
        } catch NodeSessionBrokerError.unavailable {}
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }

    func testAdmissionIsRecheckedAfterPendingRequestReconciliation() async throws {
        let admission = LockedAdmission(.readWrite)
        let transport = BrokerTestTransport(onReconcile: { admission.set(.readOnly(expiresAt: Date().addingTimeInterval(60))) })
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: admission.value, binding: "account/node/epoch")
        })
        let client = try await broker.sessionSender()
        do {
            _ = try await client.sender.send(method: "POST", path: "/v1/mail/send", body: Data(), maximumResponseBytes: 1024)
            XCTFail("mutation sent after admission changed")
        } catch NodeSessionBrokerError.readOnly {}
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }

    func testCompletedRequestDoesNotExposeResponseAfterBindingChanges() async throws {
        let binding = LockedBinding("account/node/epoch1")
        let transport = BrokerTestTransport(onSend: { binding.set("account/node/epoch2") })
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: .readWrite, binding: binding.value)
        })
        let sender = try await broker.sessionSender().sender
        do {
            _ = try await sender.send(method: "GET", path: "/v1/status", body: Data(), maximumResponseBytes: 1024)
            XCTFail("response from old binding escaped")
        } catch NodeSessionBrokerError.unavailable {}
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testBrokeredSenderExposesPendingResponseToMutationClient() async throws {
        let pending = NodeHTTPResponse(
            statusCode: 200, url: URL(string: "https://node.example.test/v1/mutations")!,
            headers: [:], body: Data("pending-result".utf8)
        )
        let transport = BrokerTestTransport(pendingResponse: pending)
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: .readWrite, binding: "account/node/epoch")
        })
        let session = try await broker.sessionSender()
        let reconciler = try XCTUnwrap(session.sender as? any NodePendingRequestReconciling)
        let result = try await reconciler.reconcilePendingRequest()
        XCTAssertEqual(result?.body, pending.body)
        let sendCount = await transport.count
        XCTAssertEqual(sendCount, 0)
    }

    func testBrokeredCapabilitiesForwardOnlyForCurrentWritableBinding() async throws {
        let binding = LockedBinding("account/node/epoch1")
        let admission = LockedAdmission(.readWrite)
        let transport = BrokerCapabilityTransport()
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: admission.value, binding: binding.value)
        })
        let sender = try await broker.sessionSender().sender
        let signer = try XCTUnwrap(sender as? any NodeMutationOperationSigning)
        let updater = try XCTUnwrap(sender as? any NodeAuthorityEpochUpdating)
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        try updater.setAuthorityEpoch("9", for: mailbox)
        XCTAssertEqual(try signer.signMutation(
            variant: .setRead(messageIDs: ["message-1"], read: true), logicalMailboxID: mailbox,
            idempotencyKey: "operation-1", issuedAt: "2026-08-28T10:00:00Z"
        ), Data("signed-9".utf8))
        XCTAssertEqual(transport.signCount, 1)
        admission.set(.readOnly(expiresAt: Date().addingTimeInterval(60)))
        XCTAssertThrowsError(try signer.signMutation(
            variant: .setRead(messageIDs: ["message-1"], read: true), logicalMailboxID: mailbox,
            idempotencyKey: "operation-2", issuedAt: "2026-08-28T10:00:01Z"
        ))
        XCTAssertEqual(transport.signCount, 1)
        binding.set("account/node/epoch2")
        XCTAssertThrowsError(try updater.setAuthorityEpoch("10", for: mailbox))
        XCTAssertEqual(transport.authorityEpoch, "9")
    }

    func testBrokeredStreamReconcilesAndRejectsStaleBinding() async throws {
        let binding = LockedBinding("account/node/epoch1")
        let transport = BrokerCapabilityTransport(onReconcile: { binding.set("account/node/epoch2") })
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: .readWrite, binding: binding.value)
        })
        let sender = try await broker.sessionSender().sender
        let streamer = try XCTUnwrap(sender as? any NodeSessionStreamingRequestSending)
        do {
            _ = try await streamer.stream(method: "GET", path: "/v1/mail/attachments/item", body: Data(), maximumResponseBytes: 1024)
            XCTFail("stale binding dispatched stream")
        } catch NodeSessionBrokerError.unavailable {}
        XCTAssertEqual(transport.streamCount, 0)
    }

    func testBrokeredStreamAllowsReadOnlyAttachmentButRefusesMutation() async throws {
        let transport = BrokerCapabilityTransport()
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: .readOnly(expiresAt: Date().addingTimeInterval(60)), binding: "account/node/epoch")
        })
        let sender = try await broker.sessionSender().sender
        let streamer = try XCTUnwrap(sender as? any NodeSessionStreamingRequestSending)
        let response = try await streamer.stream(method: "GET", path: "/v1/mail/attachments/item", body: Data(), maximumResponseBytes: 1024)
        var bytes = Data()
        for try await chunk in response.bytes { bytes.append(chunk) }
        XCTAssertEqual(bytes, Data("attachment".utf8))
        do {
            _ = try await streamer.stream(method: "POST", path: "/v1/mail/send", body: Data(), maximumResponseBytes: 1024)
            XCTFail("read-only stream dispatched mutation")
        } catch NodeSessionBrokerError.readOnly {}
        XCTAssertEqual(transport.streamCount, 1)
    }

    func testBrokeredStreamDiscardsResponseWhenBindingChangesDuringAwait() async throws {
        let binding = LockedBinding("account/node/epoch1")
        let transport = BrokerCapabilityTransport(onStream: { binding.set("account/node/epoch2") })
        let broker = NodeSessionBroker(resolveSender: { ("trusted-node", transport) }, check: {
            NodeSessionCheck(admission: .readWrite, binding: binding.value)
        })
        let sender = try await broker.sessionSender().sender
        let streamer = try XCTUnwrap(sender as? any NodeSessionStreamingRequestSending)
        do {
            _ = try await streamer.stream(method: "GET", path: "/v1/mail/attachments/item", body: Data(), maximumResponseBytes: 1024)
            XCTFail("stale stream response escaped")
        } catch NodeSessionBrokerError.unavailable {}
        XCTAssertEqual(transport.streamCount, 1)
    }

    private static let nodeID = "30000000-0000-4000-8000-000000000801"

    func testAppProxyIsAllowlistedAndAllSendsShareOneSerializedTransport() async throws {
        let transport = RecordingBrokerTransport(delay: .milliseconds(20))
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })

        async let app = broker.proxy(try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()), caller: .app)
        async let service: Void = { _ = try await broker.client().client.requestProviderSync() }()
        _ = try await (app, service)
        XCTAssertEqual(transport.maximumConcurrentSends, 1)

        for path in ["/v1/mutations", "/v1/mail/providers/google/import", "/v1/mail/mirror/coordinates", "/v1/mail/snapshot"] {
            do {
                _ = try await broker.proxy(try PlainpostNodeSessionRequest(method: "POST", path: path, body: Data("{}".utf8)), caller: .app)
                XCTFail("app reached \(path)")
            } catch NodeSessionBrokerError.pathNotAllowed {}
        }
        XCTAssertEqual(Set(transport.paths), ["/v1/status", "/v1/provider-sync"])
    }

    func testAppAllowlistMatchesMethodAndPathSegmentBoundaries() async throws {
        let transport = RecordingBrokerTransport()
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        let allowed: [(String, String)] = [
            ("GET", "/v1/status"),
            ("GET", "/v1/mail/capabilities"),
            ("GET", "/v1/mail/accounts"),
            ("GET", "/v1/mail/accounts?after=abc"),
            ("GET", "/v1/mailboxes/assignments"),
            ("GET", "/v1/calendar/capabilities"),
            ("POST", "/v1/calendar/connections/configure"),
            ("POST", "/v1/calendar/window"),
            ("POST", "/v1/operations/backup"),
            ("POST", "/v1/operations/erase"),
            ("POST", "/v1/notifications/policy/read"),
            ("PUT", "/v1/notifications/policy"),
        ]
        for (method, path) in allowed {
            let response = try await broker.proxy(try PlainpostNodeSessionRequest(method: method, path: path, body: Data()), caller: .app)
            XCTAssertEqual(response.statusCode, 200, "\(method) \(path)")
        }
        let rejected: [(String, String)] = [
            ("POST", "/v1/status"),
            ("GET", "/v1/statusx"),
            ("GET", "/v1/status/extra"),
            ("PUT", "/v1/mailboxes/assignments"),
            ("GET", "/v1/calendar"),
            ("POST", "/v1/calendar/../mutations"),
            ("POST", "/v1/calendar/./window"),
            ("POST", "/v1/calendar//window"),
            ("GET", "/v1/operations/backup"),
            ("DELETE", "/v1/notifications/policy"),
            ("PUT", "/v1/notifications/recipient"),
            ("POST", "/v1/deltas"),
            ("GET", "/v1/messages/abc"),
            ("POST", "/v1/mail/providers/generic"),
        ]
        for (method, path) in rejected {
            do {
                _ = try await broker.proxy(try PlainpostNodeSessionRequest(method: method, path: path, body: Data()), caller: .app)
                XCTFail("app reached \(method) \(path)")
            } catch NodeSessionBrokerError.pathNotAllowed {}
        }
        XCTAssertEqual(transport.paths.count, allowed.count)
    }

    func testServiceCallerIsNotRestrictedByTheAppAllowlist() async throws {
        let transport = RecordingBrokerTransport()
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        let response = try await broker.proxy(try PlainpostNodeSessionRequest(method: "POST", path: "/v1/mail/snapshot", body: Data("{}".utf8)), caller: .service)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(transport.paths, ["/v1/mail/snapshot"])
    }

    func testProxyRelaysNodeResponseBytesAndHeaders() async throws {
        let transport = RecordingBrokerTransport(response: NodeHTTPResponse(statusCode: 409, url: URL(string: "https://node.example.test:8443/v1/status")!, headers: ["Content-Type": "application/json"], body: Data(#"{"kind":"problem"}"#.utf8)))
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        let response = try await broker.proxy(try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()), caller: .app)
        XCTAssertEqual(response.statusCode, 409)
        XCTAssertEqual(response.headers, ["Content-Type": "application/json"])
        XCTAssertEqual(response.body, Data(#"{"kind":"problem"}"#.utf8))
    }

    func testResolverNeverCreatesDeviceIdentity() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: #function,
                                                 accessGroup: PlainpostAccountSharedKeychain.accessGroup)
        let broker = NodeSessionBroker.production(credentials: credentials, configurationStore: .inMemoryForTesting(),
                                                  endpointStore: try SyncNodeEndpointStore(secretStore: InMemoryAccountSecretStore(), accessGroup: PlainpostAccountSharedKeychain.accessGroup))
        do { _ = try await broker.client(); XCTFail("resolved without a session") } catch NodeSessionBrokerError.noActiveSession {}
        do {
            _ = try await broker.proxy(try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()), caller: .app)
            XCTFail("proxied without a session")
        } catch NodeSessionBrokerError.noActiveSession {}
        XCTAssertNil(try credentials.loadExistingDeviceIdentity())
        XCTAssertTrue(secrets.records.isEmpty, "the service resolver must never write account Keychain items")
        let readiness = await broker.identityReadiness()
        XCTAssertEqual(readiness, .noSession)

        // An active session whose device identity is missing (the app has
        // not created it, or it is unreadable from this group) still never
        // makes the service create one.
        let accountID = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let deviceID = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        try credentials.saveSession(AccountSession(credentials: try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "access", accessExpiresAt: Date().addingTimeInterval(600), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")))
        let sessionOnly = secrets.records
        do { _ = try await broker.client(); XCTFail("resolved without a device identity") } catch NodeSessionBrokerError.noActiveSession {}
        XCTAssertNil(try credentials.loadExistingDeviceIdentity())
        XCTAssertEqual(secrets.records, sessionOnly, "the resolver wrote Keychain items")
    }

    func testIdentityReadinessIsReadyOnlyWhenSessionAndIdentityLoad() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: #function, accessGroup: PlainpostAccountSharedKeychain.accessGroup)
        let accountID = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let deviceID = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        try credentials.saveSession(AccountSession(credentials: try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "access", accessExpiresAt: Date().addingTimeInterval(600), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")))
        let broker = NodeSessionBroker.production(credentials: credentials, configurationStore: .inMemoryForTesting(), endpointStore: try SyncNodeEndpointStore(secretStore: InMemoryAccountSecretStore(), accessGroup: PlainpostAccountSharedKeychain.accessGroup))
        let withoutIdentity = await broker.identityReadiness()
        XCTAssertEqual(withoutIdentity, .noSession, "a session without an existing identity is not ready")
        _ = try credentials.loadOrCreateDeviceIdentity()
        let ready = await broker.identityReadiness()
        XCTAssertEqual(ready, .ready)
        XCTAssertTrue(secrets.records.keys.allSatisfy { $0.accessGroup == PlainpostAccountSharedKeychain.accessGroup })
    }

    func testTrustEpochChangeInvalidationRebuildsTheTransport() async throws {
        let first = RecordingBrokerTransport()
        let second = RecordingBrokerTransport()
        let resolutions = ResolutionScript([first, second])
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, try resolutions.next()) })
        let status = try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data())

        _ = try await broker.proxy(status, caller: .app)
        _ = try await broker.proxy(status, caller: .app)
        XCTAssertEqual(resolutions.count, 1, "a resolved transport is reused")

        // Enrollment, replacement or a trust epoch change commits in the app,
        // which then invalidates the broker's session.
        await broker.invalidate()
        _ = try await broker.proxy(status, caller: .app)
        XCTAssertEqual(resolutions.count, 2)
        XCTAssertEqual(first.paths.count, 2)
        XCTAssertEqual(second.paths.count, 1)
    }

    func testAuthenticationRejectionDropsTheCachedTransport() async throws {
        let stale = RecordingBrokerTransport(failure: NodeSessionError.authenticationRejected)
        let current = RecordingBrokerTransport()
        let resolutions = ResolutionScript([stale, current])
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, try resolutions.next()) })
        let status = try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data())
        do {
            _ = try await broker.proxy(status, caller: .app)
            XCTFail("stale epoch accepted")
        } catch let error as NodeSessionError { XCTAssertEqual(error, .authenticationRejected) }
        _ = try await broker.proxy(status, caller: .app)
        XCTAssertEqual(resolutions.count, 2, "a Node that rejects the session's epoch forces a fresh resolution")
        XCTAssertEqual(current.paths, ["/v1/status"])
    }

    func testStaleServiceClientFailsClosedAfterInvalidation() async throws {
        let transport = RecordingBrokerTransport()
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        let held = try await broker.client().client
        await broker.invalidate()
        do {
            try await held.requestProviderSync()
            XCTFail("an invalidated session sent a request")
        } catch {}
        XCTAssertTrue(transport.paths.isEmpty)
        try await broker.client().client.requestProviderSync()
        XCTAssertEqual(transport.paths, ["/v1/provider-sync"])
    }

    func testRetainedAmbiguousRequestIsReconciledBeforeTheNextSend() async throws {
        // A previous service run left an ambiguous request in the Keychain
        // pending record; the transport reports it through reconciliation.
        let transport = RecordingBrokerTransport(retainedPendingRequest: true)
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        _ = try await broker.proxy(try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()), caller: .app)
        XCTAssertEqual(transport.events, ["reconcile:replayed", "send:/v1/status"])

        let serviceTransport = RecordingBrokerTransport(retainedPendingRequest: true)
        let serviceBroker = NodeSessionBroker(resolveSender: { (Self.nodeID, serviceTransport) })
        try await serviceBroker.client().client.requestProviderSync()
        XCTAssertEqual(serviceTransport.events.first, "reconcile:replayed")
        XCTAssertEqual(serviceTransport.events.last, "send:/v1/provider-sync")
    }

    func testResolverFailuresMapToTypedBrokerErrors() async throws {
        let broker = NodeSessionBroker(resolveSender: { throw AccountRuntimeError.transportFailure })
        do {
            _ = try await broker.client()
            XCTFail("resolved")
        } catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .unavailable) }
        XCTAssertEqual(NodeSessionBroker.failure(for: NodeSessionBrokerError.noEnrolledNode), .noEnrolledNode)
        XCTAssertEqual(NodeSessionBroker.failure(for: NodeSessionError.transportFailureAfterDispatch), .transportFailureAfterDispatch)
        XCTAssertEqual(NodeSessionBroker.failure(for: NodeSessionError.authenticationRejected), .authenticationRejected)
        XCTAssertEqual(NodeSessionBroker.failure(for: CancellationError()), .unavailable)
    }

    func testIPCRequestLimitMatchesTheNodeSessionTransport() {
        XCTAssertEqual(PlainpostNodeSessionLimits.maximumRequestBodyBytes, NodeSessionLimits.maximumRequestBodyBytes)
        XCTAssertEqual(PlainpostNodeSessionLimits.maximumResponseBodyBytes, NodeTLSClient.maximumBufferedResponseBytes(method: "POST", path: "/v1/calendar/window"))
    }
}

extension KeychainCentralServerConfigurationStore {
    static func inMemoryForTesting() -> KeychainCentralServerConfigurationStore {
        KeychainCentralServerConfigurationStore(secretStore: InMemoryAccountSecretStore(), accessGroup: PlainpostAccountSharedKeychain.accessGroup)
    }
}

private final class ResolutionScript: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [RecordingBrokerTransport]
    private(set) var count = 0
    init(_ transports: [RecordingBrokerTransport]) { remaining = transports }
    func next() throws -> RecordingBrokerTransport {
        lock.lock(); defer { lock.unlock() }
        count += 1
        guard !remaining.isEmpty else { throw NodeSessionBrokerError.unavailable }
        return remaining.count == 1 ? remaining[0] : remaining.removeFirst()
    }
}

/// Records the paths it sends and the largest number of sends in flight.
final class RecordingBrokerTransport: NodeSessionRequestSending, NodePendingRequestReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private let response: NodeHTTPResponse?
    private var failure: Error?
    private var retainedPendingRequest: Bool
    private var inFlight = 0
    private(set) var maximumConcurrentSends = 0
    private(set) var paths: [String] = []
    private(set) var events: [String] = []

    init(delay: Duration = .zero, response: NodeHTTPResponse? = nil, failure: Error? = nil, retainedPendingRequest: Bool = false) {
        self.delay = delay; self.response = response; self.failure = failure; self.retainedPendingRequest = retainedPendingRequest
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let failure: Error? = lock.withLock {
            inFlight += 1
            maximumConcurrentSends = max(maximumConcurrentSends, inFlight)
            return self.failure
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        lock.withLock {
            inFlight -= 1
            if failure == nil { paths.append(path); events.append("send:\(path)") }
        }
        if let failure { throw failure }
        return response ?? NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.test:8443\(path)")!, headers: [:], body: Data("{}".utf8))
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        lock.withLock {
            guard retainedPendingRequest else { return nil }
            retainedPendingRequest = false
            events.append("reconcile:replayed")
            return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.test:8443/v1/status")!, headers: [:], body: Data("{}".utf8))
        }
    }
}



private final class LockedBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String
    init(_ value: String) { storage = value }
    var value: String { lock.withLock { storage } }
    func set(_ value: String) { lock.withLock { storage = value } }
}

private final class LockedAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: NodeSessionAdmission
    init(_ value: NodeSessionAdmission) { storage = value }
    var value: NodeSessionAdmission { lock.withLock { storage } }
    func set(_ value: NodeSessionAdmission) { lock.withLock { storage = value } }
}

private actor BrokerTestTransport: NodeSessionRequestSending, NodePendingRequestReconciling {
    var count = 0
    private let onReconcile: @Sendable () -> Void
    private let onSend: @Sendable () -> Void
    private let pendingResponse: NodeHTTPResponse?
    init(onReconcile: @escaping @Sendable () -> Void = {}, onSend: @escaping @Sendable () -> Void = {},
         pendingResponse: NodeHTTPResponse? = nil) {
        self.onReconcile = onReconcile
        self.onSend = onSend
        self.pendingResponse = pendingResponse
    }
    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { onReconcile(); return pendingResponse }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        count += 1
        onSend()
        return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.test\(path)")!, headers: [:], body: Data())
    }
}

private final class BrokerCapabilityTransport: NodeSessionRequestSending, NodePendingRequestReconciling,
    NodeSessionStreamingRequestSending, NodeMutationOperationSigning, NodeAuthorityEpochUpdating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEpoch: String?
    private var storedSignCount = 0
    private var storedStreamCount = 0
    private let onReconcile: @Sendable () -> Void
    private let onStream: @Sendable () -> Void

    init(onReconcile: @escaping @Sendable () -> Void = {}, onStream: @escaping @Sendable () -> Void = {}) {
        self.onReconcile = onReconcile
        self.onStream = onStream
    }
    var authorityEpoch: String? { lock.withLock { storedEpoch } }
    var signCount: Int { lock.withLock { storedSignCount } }
    var streamCount: Int { lock.withLock { storedStreamCount } }

    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        lock.withLock { storedEpoch = epoch }
    }

    func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID,
                      idempotencyKey: String, issuedAt: String) throws -> Data {
        lock.withLock {
            storedSignCount += 1
            return Data("signed-\(storedEpoch ?? "missing")".utf8)
        }
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { onReconcile(); return nil }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSessionBrokerError.unavailable
    }
    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        lock.withLock { storedStreamCount += 1 }
        onStream()
        let bytes = PlainpostByteStream(capacity: 1)
        let producer = bytes.producer
        Task { try? await producer.send(Data("attachment".utf8)); producer.finish() }
        return NodeHTTPStreamResponse(statusCode: 200, url: URL(string: "https://node.example.test\(path)")!, headers: [:], bytes: bytes)
    }
}
