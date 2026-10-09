import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeMailMode
@testable import PlainpostNodeTransport
@testable import PlainpostServiceIPC

/// Task 12 fix round 1: the broker admits a session only the way the app
/// does, re-checks admission and the trusted-Node binding on every lane
/// operation, and settles its own ambiguous send in the same slot.
final class NodeSessionAdmissionTests: XCTestCase {
    private static let nodeID = "30000000-0000-4000-8000-000000000801"
    private let status = try! PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data())

    // MARK: I1 — admission policy

    func testValidLeaseAdmitsReadOnlyAndExpiredOrForgedLeaseIsNotAdmitted() throws {
        let vector = try LeaseVector()
        let expired = try vector.credentials(accessExpiresAt: vector.now.addingTimeInterval(-60))
        let verifier: NodeSessionAdmissionPolicy.LeaseVerifier = { credentials, now in
            vector.verifier.offlineLeaseVerifier(accountID: credentials.accountID, deviceID: credentials.deviceID)(credentials.offlineLease, now)
        }
        XCTAssertEqual(try NodeSessionAdmissionPolicy.admission(for: expired, now: vector.now, suspended: false, leaseVerifier: verifier), .readOnly(expiresAt: vector.leaseExpiresAt))

        // The lease has expired.
        XCTAssertThrowsError(try NodeSessionAdmissionPolicy.admission(for: expired, now: vector.leaseExpiresAt.addingTimeInterval(1), suspended: false, leaseVerifier: verifier)) {
            XCTAssertEqual($0 as? NodeSessionBrokerError, .notAdmitted)
        }
        // The lease signature does not verify.
        let forged = try vector.credentials(accessExpiresAt: vector.now.addingTimeInterval(-60), lease: vector.forgedLease)
        XCTAssertThrowsError(try NodeSessionAdmissionPolicy.admission(for: forged, now: vector.now, suspended: false, leaseVerifier: verifier)) {
            XCTAssertEqual($0 as? NodeSessionBrokerError, .notAdmitted)
        }
        // An unexpired access token is read-write without consulting the lease.
        let live = try vector.credentials(accessExpiresAt: vector.now.addingTimeInterval(600), lease: vector.forgedLease)
        XCTAssertEqual(try NodeSessionAdmissionPolicy.admission(for: live, now: vector.now, suspended: false, leaseVerifier: verifier), .readWrite)
        // A suspended account is never admitted, token or lease.
        XCTAssertThrowsError(try NodeSessionAdmissionPolicy.admission(for: live, now: vector.now, suspended: true, leaseVerifier: verifier)) {
            XCTAssertEqual($0 as? NodeSessionBrokerError, .notAdmitted)
        }
    }

    func testProductionCheckRefusesASuspendedOrUnleasedSession() throws {
        let credentials = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: #function, accessGroup: PlainpostAccountSharedKeychain.accessGroup)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = try AccountSessionCredentials(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), deviceID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), accessToken: "access", accessExpiresAt: now.addingTimeInterval(600), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "not-a-lease")
        try credentials.saveSession(AccountSession(credentials: session))
        let refusals = NodeSessionRefusals()
        let noLease: NodeSessionAdmissionPolicy.LeaseVerifier = { _, _ in nil }
        XCTAssertEqual(try NodeSessionBroker.productionCheck(credentials: credentials, leaseVerifier: noLease, refusals: refusals, now: now).admission, .readWrite)
        XCTAssertThrowsError(try NodeSessionBroker.productionCheck(credentials: credentials, leaseVerifier: noLease, refusals: refusals, now: now.addingTimeInterval(601))) {
            XCTAssertEqual($0 as? NodeSessionBrokerError, .notAdmitted)
        }
        refusals.mark(session)
        XCTAssertThrowsError(try NodeSessionBroker.productionCheck(credentials: credentials, leaseVerifier: noLease, refusals: refusals, now: now)) {
            XCTAssertEqual($0 as? NodeSessionBrokerError, .notAdmitted)
        }
    }

    // MARK: I1 — Central refusal never falls back

    func testCentralRefusalWithAValidTokenIsNotAdmittedAndNeverUsesTheCachedEndpoint() async throws {
        for refusal in [NodeSessionCentralRefusal.unauthorized, .suspended] {
            let cached = CallCounter(), refused = CallCounter()
            do {
                _ = try await NodeSessionBroker.endpointSender(
                    admission: .readWrite,
                    discover: { () async throws -> String? in throw refusal },
                    restoreCached: { cached.hit(); return "cached" },
                    onRefused: { refused.hit() }
                )
                XCTFail("\(refusal) admitted")
            } catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .notAdmitted) }
            XCTAssertEqual(cached.count, 0, "\(refusal) fell back to the cached endpoint")
            XCTAssertEqual(refused.count, 1, "\(refusal) must be remembered like the app clears or suspends the session")
        }
        XCTAssertEqual(StatusClassifyingEndpointRemote.failure(status: 401) as? NodeSessionCentralRefusal, .unauthorized)
        XCTAssertEqual(StatusClassifyingEndpointRemote.failure(status: 403) as? NodeSessionCentralRefusal, .unauthorized)
        XCTAssertEqual(StatusClassifyingEndpointRemote.failure(status: 423) as? NodeSessionCentralRefusal, .suspended)
        XCTAssertEqual(StatusClassifyingEndpointRemote.failure(status: 503) as? AccountRuntimeError, .transportFailure)
        XCTAssertEqual(StatusClassifyingEndpointRemote.failure(status: 404) as? AccountRuntimeError, .untrustedResponse)
    }

    func testOnlyReachabilityFailuresOrLeaseAdmissionUseTheCachedEndpoint() async throws {
        let unreachable = try await NodeSessionBroker.endpointSender(
            admission: .readWrite,
            discover: { () async throws -> String? in throw AccountRuntimeError.transportFailure },
            restoreCached: { "cached" }, onRefused: {}
        )
        XCTAssertEqual(unreachable, "cached")
        let discovered = try await NodeSessionBroker.endpointSender(admission: .readWrite, discover: { "discovered" }, restoreCached: { "cached" }, onRefused: {})
        XCTAssertEqual(discovered, "discovered")
        let discoveries = CallCounter()
        let leased = try await NodeSessionBroker.endpointSender(
            admission: .readOnly(expiresAt: Date().addingTimeInterval(60)),
            discover: { () async throws -> String? in discoveries.hit(); return "discovered" },
            restoreCached: { "cached" }, onRefused: {}
        )
        XCTAssertEqual(leased, "cached")
        XCTAssertEqual(discoveries.count, 0, "an expired token is not presented to Central")
        do {
            _ = try await NodeSessionBroker.endpointSender(admission: .readWrite, discover: { () async throws -> String? in throw AccountRuntimeError.untrustedResponse }, restoreCached: { "cached" }, onRefused: {})
            XCTFail("an untrusted Central answer fell back")
        } catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .unavailable) }
    }

    // MARK: Fix round 2 — production admission and binding

    func testCentral401IsRememberedSoTheLeaseCannotReadmitTheSession() async throws {
        let fixture = try ProductionFixture(epoch: 3, node: ProductionFixture.nodeA)
        let clock = TestClock(fixture.now)
        let remote = CountingRefusingRemote(refusal: .unauthorized)
        let broker = NodeSessionBroker.production(
            credentials: fixture.credentials,
            endpointStore: fixture.endpointStore,
            leaseVerifier: { _, now in now.addingTimeInterval(3_600) },
            remote: { remote },
            clock: { clock.now }
        )
        do { _ = try await broker.proxy(status, caller: .app); XCTFail("refused session admitted") }
        catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .notAdmitted) }
        do { _ = try await broker.proxy(status, caller: .app); XCTFail("refused session admitted") }
        catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .notAdmitted) }
        // The access token expires; the lease still verifies. The app would
        // be at sign-in, so the service must not serve from the cache.
        clock.now = fixture.accessExpiresAt.addingTimeInterval(60)
        do { _ = try await broker.proxy(status, caller: .app); XCTFail("lease readmitted a refused session") }
        catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .notAdmitted, "a restoreCached attempt would surface as noEnrolledNode") }
        XCTAssertEqual(remote.calls, 1, "Central is not asked again once it refused the session")
    }

    func testProductionBindingFollowsTheTrustEpochAndTheSyncNodeMember() throws {
        let base = try ProductionFixture(epoch: 3, node: ProductionFixture.nodeA)
        let newEpoch = try ProductionFixture(epoch: 4, node: ProductionFixture.nodeA)
        let newNode = try ProductionFixture(epoch: 4, node: ProductionFixture.nodeB)
        let bindings = try [base, newEpoch, newNode].map { try $0.check().binding }
        XCTAssertEqual(Set(bindings).count, 3, "\(bindings)")
        XCTAssertEqual(try base.check().binding, try ProductionFixture(epoch: 3, node: ProductionFixture.nodeA).check().binding)
        XCTAssertEqual(try base.check().admission, .readWrite)
    }

    func testProductionCheckRefusesADeletionInProgressAndACompletedDeletion() throws {
        let inProgress = try ProductionFixture(epoch: 3, node: ProductionFixture.nodeA)
        XCTAssertEqual(try inProgress.check().admission, .readWrite)
        _ = try inProgress.beginDeletion()
        XCTAssertNotNil(try inProgress.credentials.loadLocalDeletion())
        XCTAssertThrowsError(try inProgress.check()) { XCTAssertEqual($0 as? NodeSessionBrokerError, .notAdmitted) }

        let completed = try ProductionFixture(epoch: 3, node: ProductionFixture.nodeA)
        try completed.completeDeletion()
        XCTAssertNil(try completed.credentials.loadLocalDeletion(), "only the receipt remains")
        XCTAssertNotNil(try completed.credentials.loadCompletedDeletionReceipt())
        XCTAssertThrowsError(try completed.check()) { XCTAssertEqual($0 as? NodeSessionBrokerError, .notAdmitted) }
    }

    func testSigningChecksTheCurrentAdmissionAndBinding() async throws {
        let transport = SigningTransport()
        let state = CheckState(NodeSessionCheck(admission: .readWrite, binding: "a/3"))
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) }, check: { state.value }, identityReadiness: { .ready })
        let signer = try await broker.sessionSender().sender
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        func sign() throws -> Data { try signer.signMutation(variant: .setRead(messageIDs: ["m"], read: true), logicalMailboxID: mailbox, idempotencyKey: "k", issuedAt: "2026-09-25T10:00:00Z") }
        XCTAssertEqual(try sign(), Data("signed".utf8))
        // No lane operation ran since: signing must still see the change.
        state.value = NodeSessionCheck(admission: .readOnly(expiresAt: Date().addingTimeInterval(60)), binding: "a/3")
        XCTAssertThrowsError(try sign()) { XCTAssertEqual($0 as? NodeSessionBrokerError, .readOnly) }
        state.value = NodeSessionCheck(admission: .readWrite, binding: "b/4")
        XCTAssertThrowsError(try sign()) { XCTAssertEqual($0 as? NodeSessionBrokerError, .unavailable) }
    }

    func testReplayOfAnotherRequestIsNeverReturnedToTheCaller() async throws {
        let transport = HookedTransport()
        transport.failFirstSendAfterDispatch = true
        transport.replayPath = "/v1/mutations"
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        do {
            _ = try await broker.proxy(try PlainpostNodeSessionRequest(method: "POST", path: "/v1/calendar/commands", body: Data("{}".utf8)), caller: .app)
            XCTFail("another request's replay was returned")
        } catch let error as NodeSessionError { XCTAssertEqual(error, .transportFailureAfterDispatch) }
    }

    func testReadOnlyPostRoutesArePostReadRoutesOfTheNode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Services/PlainpostGo/internal/node/clientapi")
        let http = try String(contentsOf: root.appendingPathComponent("http.go"), encoding: .utf8)
        let mailMode = try String(contentsOf: root.appendingPathComponent("mail_mode_http.go"), encoding: .utf8)
        let calendar = try String(contentsOf: root.appendingPathComponent("calendar.go"), encoding: .utf8)
        XCTAssertTrue(NodeSessionAdmissionPolicy.readOnlyPostRoutes.contains("/v1/mail/mirror/coordinates"))
        for route in NodeSessionAdmissionPolicy.readOnlyPostRoutes {
            if route.hasPrefix("/v1/calendar/") {
                XCTAssertTrue(calendar.contains("case \"\(route)\":"), route)
            } else if route.hasPrefix("/v1/mail/") {
                XCTAssertTrue(mailMode.range(of: "\"\(route)\":\\s+http.MethodPost", options: .regularExpression) != nil, route)
            } else {
                let handler = try NSRegularExpression(pattern: "case path == \"\(NSRegularExpression.escapedPattern(for: route))\":\\s*\\n\\s*if !requireHTTPMethod\\(writer, request, http.MethodPost\\)[^\\n]*requireHTTPAdmission\\(")
                XCTAssertEqual(handler.numberOfMatches(in: http, range: NSRange(http.startIndex..., in: http)), 1, "\(route) is not a Node POST read route")
            }
        }
        // Every route the Node admits as a mutation stays refused.
        let mutation = try NSRegularExpression(pattern: "case path == \"([^\"]+)\":\\s*\\n[^\\n]*requireMutationHTTPAdmission")
        let mutating = mutation.matches(in: http, range: NSRange(http.startIndex..., in: http)).compactMap { Range($0.range(at: 1), in: http).map { String(http[$0]) } }
        XCTAssertFalse(mutating.isEmpty)
        for route in mutating { XCTAssertFalse(NodeSessionAdmissionPolicy.permitsReadOnly(method: "POST", path: route), route) }
    }

    // MARK: I1 — read-only lease and per-operation admission

    func testLeaseOnlyAdmissionRefusesMutations() async throws {
        let transport = RecordingBrokerTransport()
        let broker = NodeSessionBroker(
            resolveSender: { (Self.nodeID, transport) },
            check: { NodeSessionCheck(admission: .readOnly(expiresAt: Date().addingTimeInterval(600)), binding: "a") },
            identityReadiness: { .ready }
        )
        _ = try await broker.proxy(status, caller: .app)
        _ = try await broker.proxy(try PlainpostNodeSessionRequest(method: "POST", path: "/v1/mail/snapshot", body: Data("{}".utf8)), caller: .service)
        let refused: [(PlainpostNodeSessionRequest, NodeSessionCaller)] = [
            (try PlainpostNodeSessionRequest(method: "POST", path: "/v1/calendar/commands", body: Data("{}".utf8)), .app),
            (try PlainpostNodeSessionRequest(method: "PUT", path: "/v1/notifications/policy", body: Data("{}".utf8)), .app),
            (try PlainpostNodeSessionRequest(method: "POST", path: "/v1/operations/erase", body: Data("{}".utf8)), .app),
            (try PlainpostNodeSessionRequest(method: "POST", path: "/v1/mutations", body: Data("{}".utf8)), .service),
            (try PlainpostNodeSessionRequest(method: "PUT", path: "/v1/mailboxes/assignments", body: Data("{}".utf8)), .service),
        ]
        for (request, caller) in refused {
            do {
                _ = try await broker.proxy(request, caller: caller)
                XCTFail("read-only session sent \(request.method) \(request.path)")
            } catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .readOnly) }
        }
        do {
            try await broker.client().client.requestProviderSync()
            XCTFail("read-only service client sent a provider sync")
        } catch {}
        let session = try await broker.sessionSender().sender
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try session.signMutation(variant: .setRead(messageIDs: ["message-1"], read: true), logicalMailboxID: mailbox, idempotencyKey: "k", issuedAt: "2026-09-25T10:00:00Z")) {
            XCTAssertEqual($0 as? NodeSessionBrokerError, .readOnly)
        }
        XCTAssertEqual(transport.paths, ["/v1/status", "/v1/mail/snapshot"])
    }

    func testAdmissionIsCheckedAgainOnEveryOperationWhileTheSessionIsCached() async throws {
        let transport = RecordingBrokerTransport()
        let checks = CheckScript([
            .success(NodeSessionCheck(admission: .readWrite, binding: "a")),
            // Resolution rechecks admission after awaiting the sender. The
            // cached client is handed out only after both checks succeed.
            .success(NodeSessionCheck(admission: .readWrite, binding: "a")),
            .failure(NodeSessionBrokerError.notAdmitted),
        ])
        let resolutions = CallCounter()
        let broker = NodeSessionBroker(resolveSender: { resolutions.hit(); return (Self.nodeID, transport) }, check: { try checks.next() }, identityReadiness: { .ready })
        let held = try await broker.client().client
        do {
            try await held.requestProviderSync()
            XCTFail("expired session sent")
        } catch {}
        do {
            _ = try await broker.proxy(status, caller: .app)
            XCTFail("expired session proxied")
        } catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .notAdmitted) }
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertTrue(transport.paths.isEmpty)
    }

    // MARK: I2 — trusted-Node binding

    func testNodeReplacedFromAnotherDeviceReResolvesWithoutAnInvalidation() async throws {
        let old = RecordingBrokerTransport(), replacement = RecordingBrokerTransport()
        let bindings = BindingScript(["account/device/node-a/3"])
        let senders = SenderScript([old, replacement])
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, try senders.next()) }, check: { NodeSessionCheck(admission: .readWrite, binding: bindings.current) }, identityReadiness: { .ready })
        _ = try await broker.proxy(status, caller: .app)
        let held = try await broker.client().client
        // Another device replaces the Node; this Mac's trust head moves.
        bindings.set("account/device/node-b/4")
        do {
            try await held.requestProviderSync()
            XCTFail("the old Node's session kept sending")
        } catch {}
        _ = try await broker.proxy(status, caller: .app)
        XCTAssertEqual(senders.count, 2)
        XCTAssertEqual(old.paths, ["/v1/status"])
        XCTAssertEqual(replacement.paths, ["/v1/status"])
    }

    func testActivationResumedBeforeTheFenceReResolvesWithoutAnInvalidation() async throws {
        let stale = RecordingBrokerTransport(), activated = RecordingBrokerTransport()
        let bindings = BindingScript(["account/device/node-a/3"])
        let senders = SenderScript([stale, activated])
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, try senders.next()) }, check: { NodeSessionCheck(admission: .readWrite, binding: bindings.current) }, identityReadiness: { .ready })
        _ = try await broker.proxy(status, caller: .app)
        // The app's resumePendingActivation commits the same Node at a new
        // epoch before its enrollment fence exists; nobody calls invalidate().
        bindings.set("account/device/node-a/4")
        _ = try await broker.proxy(status, caller: .app)
        XCTAssertEqual(senders.count, 2)
        XCTAssertEqual(stale.paths, ["/v1/status"])
        XCTAssertEqual(activated.paths, ["/v1/status"])
    }

    // MARK: M1, M2

    func testInvalidationDuringReconcileStopsTheSend() async throws {
        let transport = HookedTransport()
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        transport.onReconcile = { await broker.invalidate() }
        do {
            _ = try await broker.proxy(status, caller: .app)
            XCTFail("sent on an invalidated session")
        } catch let error as NodeSessionBrokerError { XCTAssertEqual(error, .unavailable) }
        XCTAssertEqual(transport.sends, 0)
    }

    func testAmbiguousSendIsReplayedInTheSameSlotAndReturnsItsResult() async throws {
        let transport = HookedTransport()
        transport.failFirstSendAfterDispatch = true
        let broker = NodeSessionBroker(resolveSender: { (Self.nodeID, transport) })
        let response = try await broker.proxy(try PlainpostNodeSessionRequest(method: "POST", path: "/v1/calendar/commands", body: Data("{}".utf8)), caller: .app)
        XCTAssertEqual(response.body, Data("replayed".utf8))
        XCTAssertEqual(transport.events, ["reconcile:none", "send:failed-after-dispatch", "reconcile:replayed"])
    }

    func testAllowlistHasOneSource() {
        XCTAssertEqual(NodeSessionBroker.appAllowedPaths, [
            "/v1/status", "/v1/mail/capabilities", "/v1/mail/accounts", "/v1/mailboxes/assignments", "/v1/calendar/",
            "/v1/operations/backup", "/v1/operations/erase", "/v1/notifications/policy/read", "/v1/notifications/policy",
        ])
        for path in NodeSessionBroker.appAllowedPaths where !path.hasSuffix("/") {
            XCTAssertTrue(["GET", "POST", "PUT"].contains { NodeSessionBroker.appAllows(method: $0, path: path) }, path)
        }
    }
}

// MARK: - Fixtures

private struct LeaseVector {
    let verifier: SessionKeyManifestVerifier
    let now: Date
    let leaseExpiresAt: Date
    let accountID: PlainpostAccountID
    let deviceID: AccountDeviceID
    let lease: String

    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let manifest = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["manifest"]))
        let rootText = try XCTUnwrap(object["offlineRootPublicKey"] as? String)
        let root = try XCTUnwrap(Data(base64Encoded: rootText.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - rootText.count % 4) % 4)))
        now = try XCTUnwrap(AccountWireCodec.parseTimestamp(try XCTUnwrap(object["verificationTime"] as? String)))
        verifier = try SessionKeyManifestVerifier(document: manifest, offlineRootKeyID: try XCTUnwrap(object["offlineRootKeyID"] as? String), offlineRootPublicKey: root, now: now)
        accountID = try PlainpostAccountID(try XCTUnwrap(object["accountID"] as? String))
        deviceID = try AccountDeviceID(try XCTUnwrap(object["deviceID"] as? String))
        lease = try XCTUnwrap(object["offlineLease"] as? String)
        leaseExpiresAt = try XCTUnwrap(AccountWireCodec.parseTimestamp(try XCTUnwrap(object["leaseExpiresAt"] as? String)))
    }

    /// The same lease with one signature byte changed.
    var forgedLease: String {
        var parts = lease.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var signature = Array(parts[2])
        signature[4] = signature[4] == "A" ? "B" : "A"
        parts[2] = String(signature)
        return parts.joined(separator: ".")
    }

    func credentials(accessExpiresAt: Date, lease: String? = nil) throws -> AccountSessionCredentials {
        try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "access", accessExpiresAt: accessExpiresAt, refreshCredential: Data(repeating: 1, count: 32), offlineLease: lease ?? self.lease)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func hit() { lock.withLock { value += 1 } }
}

private final class CheckScript: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Result<NodeSessionCheck, Error>]
    init(_ steps: [Result<NodeSessionCheck, Error>]) { self.steps = steps }
    func next() throws -> NodeSessionCheck {
        try lock.withLock { steps.count > 1 ? steps.removeFirst() : steps[0] }.get()
    }
}

private final class BindingScript: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ values: [String]) { value = values[0] }
    var current: String { lock.withLock { value } }
    func set(_ next: String) { lock.withLock { value = next } }
}

private final class SenderScript: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [RecordingBrokerTransport]
    private(set) var count = 0
    init(_ senders: [RecordingBrokerTransport]) { remaining = senders }
    func next() throws -> RecordingBrokerTransport {
        try lock.withLock {
            count += 1
            guard !remaining.isEmpty else { throw NodeSessionBrokerError.unavailable }
            return remaining.count == 1 ? remaining[0] : remaining.removeFirst()
        }
    }
}

private final class HookedTransport: NodeSessionRequestSending, NodePendingRequestReconciling, @unchecked Sendable {
    private let lock = NSLock()
    var onReconcile: (@Sendable () async -> Void)?
    var failFirstSendAfterDispatch = false
    var replayPath = "/v1/calendar/commands"
    private var retained = false
    private(set) var sends = 0
    private(set) var events: [String] = []

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let fail: Bool = lock.withLock {
            sends += 1
            let fail = failFirstSendAfterDispatch
            failFirstSendAfterDispatch = false
            if fail { retained = true; events.append("send:failed-after-dispatch") } else { events.append("send:\(path)") }
            return fail
        }
        if fail { throw NodeSessionError.transportFailureAfterDispatch }
        return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.test:8443\(path)")!, headers: [:], body: Data("sent".utf8))
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        if let onReconcile { await onReconcile() }
        return lock.withLock {
            guard retained else { events.append("reconcile:none"); return nil }
            retained = false
            events.append("reconcile:replayed")
            return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.test:8443\(replayPath)")!, headers: [:], body: Data("replayed".utf8))
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

private final class CheckState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: NodeSessionCheck
    init(_ value: NodeSessionCheck) { current = value }
    var value: NodeSessionCheck { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
}

private final class CountingRefusingRemote: SyncNodeEndpointMetadataRemote, @unchecked Sendable {
    private let lock = NSLock()
    private let refusal: NodeSessionCentralRefusal
    private var count = 0
    init(refusal: NodeSessionCentralRefusal) { self.refusal = refusal }
    var calls: Int { lock.withLock { count } }
    func syncNodeEndpointRecord(accountID: PlainpostAccountID, recordID: AccountRecordID, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> EncryptedAccountRecordV1? {
        lock.withLock { count += 1 }
        throw refusal
    }
    func putSyncNodeEndpointRecord(_ record: EncryptedAccountRecordV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws {
        throw AccountRuntimeError.untrustedResponse
    }
}

private final class SigningTransport: NodeSessionRequestSending, NodePendingRequestReconciling, NodeMutationOperationSigning, @unchecked Sendable {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example.test:8443\(path)")!, headers: [:], body: Data())
    }
    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { nil }
    func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data { Data("signed".utf8) }
}

/// A real in-memory account: session, software device identity, a persisted
/// trust commit with a Sync Node member, and an empty endpoint store.
private struct ProductionFixture {
    static let nodeA = try! AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
    static let nodeB = try! AccountDeviceID("77777777-8888-4999-aaaa-cccccccccccc")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var accessExpiresAt: Date { now.addingTimeInterval(600) }
    let accountID = try! PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
    let deviceID = try! AccountDeviceID("22222222-3333-4444-5555-666666666666")
    let credentials: AccountCredentialStore
    let endpointStore: SyncNodeEndpointStore

    init(epoch: UInt64, node: AccountDeviceID) throws {
        let secrets = InMemoryAccountSecretStore()
        let service = "com.marynavdovenko.Plainpost.AccountTests.Broker"
        let trustStore = AccountTrustStore(secretStore: secrets, service: service + ".Trust")
        let (commit, material) = try Self.commit(account: accountID, mac: deviceID, node: node, epoch: epoch)
        _ = try trustStore.installVerifiedCommit(commit, openedMaterial: material, verifiedEntries: [try AccountTrustHistoryEntryV1(commit: commit, evidence: nil)], expected: nil)
        credentials = AccountCredentialStore(secretStore: secrets, service: service, accessGroup: nil, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore)
        try credentials.saveSession(AccountSession(credentials: try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "access", accessExpiresAt: now.addingTimeInterval(600), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")))
        _ = try credentials.loadOrCreateDeviceIdentity()
        endpointStore = try SyncNodeEndpointStore(secretStore: InMemoryAccountSecretStore())
    }

    func check() throws -> NodeSessionCheck {
        try NodeSessionBroker.productionCheck(credentials: credentials, leaseVerifier: { _, _ in nil }, refusals: NodeSessionRefusals(), now: now)
    }

    @discardableResult
    func beginDeletion() throws -> AccountLocalDeletionCheckpoint {
        let capability = try credentials.loadOrCreateCleanupCapability(accountID: accountID, deviceID: deviceID, kind: .macos)
        let head = Data(repeating: 0x5A, count: 32)
        let checkpoint = try AccountLocalDeletionCheckpoint(accountID: accountID, deviceID: deviceID, kind: .macos, targetHandle: capability.targetHandle, deletionGeneration: PositiveUInt64(1), phase: .prepared, resultDigest: nil)
        let authorization = try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("92000000-0000-4000-8000-000000000001"), accountID: accountID, actorDeviceID: deviceID, targetDeviceID: nil, action: .deleteAccount, currentCommitDigest: head, requestDigest: Data(repeating: 0xA3, count: 32), issuedAt: "2026-08-03T10:00:00Z", expiresAt: "2026-08-03T10:05:00Z", serverKeyID: "recovery-2026-01", serverSignature: Data(repeating: 0x11, count: 64))
        try credentials.beginLocalDeletion(checkpoint, capability: capability, authorization: authorization, headCommitDigest: head)
        return checkpoint
    }

    func completeDeletion() throws {
        let prepared = try beginDeletion()
        let accepted = try AccountLocalDeletionCheckpoint(accountID: accountID, deviceID: deviceID, kind: .macos, targetHandle: prepared.targetHandle, deletionGeneration: prepared.deletionGeneration, phase: .centralAccepted, resultDigest: nil)
        try credentials.advanceLocalDeletion(accepted)
        let purged = try AccountLocalDeletionCheckpoint(accountID: accountID, deviceID: deviceID, kind: .macos, targetHandle: prepared.targetHandle, deletionGeneration: prepared.deletionGeneration, phase: .localPurged, resultDigest: Data(repeating: 0x6B, count: 32))
        try credentials.advanceLocalDeletion(purged)
        try credentials.completeLocalDeletion(accountID: accountID)
    }

    private static func commit(account: PlainpostAccountID, mac: AccountDeviceID, node: AccountDeviceID, epoch epochValue: UInt64) throws -> (AccountTrustStateCommit, AccountTrustKeyMaterial) {
        let epoch = AccountTrustEpoch(rawValue: try PositiveUInt64(epochValue))
        let revision = try PositiveUInt64(2)
        let keyGeneration = try PositiveUInt64(1)
        let material = try AccountTrustKeyMaterial(accountID: account, epoch: epoch, keyGeneration: keyGeneration, trustRevision: revision, mailboxMatchingKey: Data(repeating: 0x41, count: 32), metadataKey: Data(repeating: 0x42, count: 32))
        func member(_ id: AccountDeviceID, platform: AccountPlatform) throws -> AccountDeviceTrustRecord {
            try AccountDeviceTrustRecord(
                accountID: account, epoch: epoch, revision: try PositiveUInt64(id == mac ? 1 : 2), deviceID: id, platform: platform,
                publicBundle: try AccountPublicKeyBundle(signingKey: P256.Signing.PrivateKey().publicKey.x963Representation, agreementKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation),
                signerDeviceID: mac, signature: Data(repeating: 0x43, count: 64)
            )
        }
        let members = try [member(mac, platform: .macos), member(node, platform: .syncNode)].sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
        let retired = try AccountDeviceID("88888888-9999-4aaa-bbbb-cccccccccccc")
        let transition = try AccountTrustTransition(kind: .revocation, targetDeviceIDs: [retired], priorRecordDigests: [try AccountPriorRecordDigest(deviceID: retired, recordDigest: Data(repeating: 0x44, count: 32))])
        let state = try AccountTrustState(accountID: account, epoch: epoch, revision: revision, previousCommitDigest: Data(repeating: 0x45, count: 32), transition: transition, keyGeneration: keyGeneration, keyCommitment: material.commitment, members: members, signerDeviceID: mac, signature: Data(repeating: 0x46, count: 64))
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let packages = try members.map { member in
            try AccountGroupKeyPackage(accountID: account, epoch: epoch, stateRevision: revision, keyGeneration: keyGeneration, stateDigest: stateDigest, keyCommitment: state.keyCommitment, recipientDeviceID: member.deviceID, senderDeviceID: mac, senderEphemeralPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, nonce: Data(repeating: 0x47, count: 12), encryptedKeyMaterial: Data(repeating: 0x48, count: 80), signature: Data(repeating: 0x49, count: 64))
        }
        return (try AccountTrustStateCommit(state: state, keyPackages: packages), material)
    }
}
