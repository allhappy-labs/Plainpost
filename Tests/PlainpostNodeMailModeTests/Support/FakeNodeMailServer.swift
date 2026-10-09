import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// An in-memory Sync Node that answers the mail-mode mirror routes with bodies
/// encoded by the production codecs, so the mirror is exercised through the
/// real `NodeSyncClient`: `/v1/mail/accounts`, `/v1/mail/snapshot`,
/// `/v1/mail/deltas`, `/v1/mail/mirror/coordinates`, and the
/// logical-mailbox-scoped message and attachment routes. It also accepts
/// signed mutations (`POST /v1/mutations`) with scripted states, answers
/// `GET /v1/drafts/{id}`, and, like the Node, dedupes a mutation by its
/// idempotency key: the exact same canonical bytes replay the stored receipt,
/// other bytes under the same key are a `conflict`.
final class FakeNodeMailServer: NodeSessionStreamingRequestSending, NodePendingRequestReconciling,
    NodeMutationOperationSigning, NodeAuthorityEpochUpdating, @unchecked Sendable {
    struct Membership: Equatable {
        var logical: LogicalMailboxID
        var path: String
        var uidValidity: UInt32
        var uid: UInt32
        var flags: [String]
    }

    struct Attachment {
        var metadata: NodeSyncAttachment
        var bytes: Data
    }

    struct Stored {
        var message: NodeSyncMessage
        var logical: LogicalMailboxID
        var rfcMessageID: String?
        var memberships: [Membership]
        var attachments: [Attachment]
        /// Snapshot and delta pages omit the bodies (as the Node does to fit
        /// its page budget); the message route returns them.
        var omitBodiesInPages: Bool
        /// The message is served but has no addressable coordinates, as for
        /// an unobserved UIDVALIDITY or a non-decimal raw ID on the Node.
        var coordinatesHidden = false
        /// Too large for a page even with its bodies omitted: the Node
        /// answers `conflict` and never pages past it.
        var unfittable = false
    }

    static let accountA = LogicalMailboxID(rawValue: Data(repeating: 0x11, count: 32))!
    static let accountB = LogicalMailboxID(rawValue: Data(repeating: 0x22, count: 32))!
    static let foreignAccount = LogicalMailboxID(rawValue: Data(repeating: 0x33, count: 32))!

    private let lock = NSLock()
    private var messages: [String: Stored] = [:]
    private var changes: [(sequence: Int, change: NodeSyncChange)] = []
    private var sequence = 0
    private var listed: [LogicalMailboxID] = [FakeNodeMailServer.accountA, FakeNodeMailServer.accountB]
    private var staleDeltaFailures = 0
    private var staleDeltaAt: Set<Int> = []
    private var continuedDeltaRequests = 0
    private var staleSnapshotFailures = 0
    private var staleSnapshotByAccount: [LogicalMailboxID: Int] = [:]
    /// Like the Node's 1 MiB family cap: a page stops before the text bodies
    /// of its messages exceed this many bytes (at least one message).
    private var snapshotByteBudget: Int?
    /// Bytes the Node reserves in a page for its continuation cursor.
    static let cursorReserveBytes = 4
    /// Per-account projection head. A continued snapshot whose head moved
    /// is stale, as on the Node (`service.go:721-722`).
    private var heads: [LogicalMailboxID: Int] = [:]
    private var served: [String] = []
    private var afterSnapshotHook: (@Sendable (LogicalMailboxID, String) -> Void)?
    private var staleSnapshotHook: (@Sendable (LogicalMailboxID, Int) -> Void)?
    private var failures: [String: [NodeSyncProblem]] = [:]
    private var conflicting: Set<String> = []
    private var gates: [String: Gate] = [:]
    private var log: [String] = []
    private var snapshotCalls = 0
    /// Runs before each snapshot page is built, with the 1-based call number.
    var onSnapshot: (@Sendable (Int) -> Void)? {
        get { lock.withLock { snapshotHook } }
        set { lock.withLock { snapshotHook = newValue } }
    }
    private var snapshotHook: (@Sendable (Int) -> Void)?

    /// One operation the Node accepted (keyed by idempotency key).
    struct AcceptedMutation {
        var canonicalOperation: Data
        var state: String
        var logical: LogicalMailboxID
        var kind: String
    }

    private var mutationScript: [String] = []
    private var accepted: [String: AcceptedMutation] = [:]
    private var acceptedOrder: [String] = []
    private var mutationPosts = 0
    private var mutationLogicals: [LogicalMailboxID] = []
    private var failAfterDispatch = 0
    private var failBeforeDispatch = 0
    private var staleEpochAnswers = 0
    private var listingEpochs: [LogicalMailboxID: UInt64] = [:]
    private var retainedResponse: NodeHTTPResponse?
    private var draftRevisions: [String: UInt64] = [:]
    private var authorityEpochs: [LogicalMailboxID: String] = [:]
    private var signings = 0
    private var reconcileFailures = 0
    private var remoteEditsAfterSave = 0
    private var nodeID = "aaaaaaaa-bbbb-cccc-8ddd-eeeeeeeeeeee"
    private var healthy = true
    private var servesMailMode = true

    // MARK: - Health (reachability supervisor)

    /// While false every request fails before it leaves this device, as a
    /// TLS session to an unreachable Node does.
    func setHealthy(_ value: Bool) { lock.withLock { healthy = value } }
    var isHealthy: Bool { lock.withLock { healthy } }
    /// While false the Node answers `404` on `/v1/mail/capabilities`, like a
    /// Node that predates mail mode.
    func setServesMailMode(_ value: Bool) { lock.withLock { servesMailMode = value } }

    // MARK: - Test control

    func addMessage(
        nodeID: String, rfcMessageID: String?, memberships: [(String, UInt32, UInt32, [String])],
        logical: LogicalMailboxID = FakeNodeMailServer.accountA, subject: String = "Hello",
        from: String = "sender@example.test", receivedAt: Date = Date(), text: String = "Body text",
        html: String? = nil, omitBodiesInPages: Bool = false, attachments: [Attachment] = [],
        foreignMemberships: [(LogicalMailboxID, String, UInt32, UInt32)] = [], publish: Bool = true
    ) {
        let message = NodeSyncMessage(
            attachments: attachments.map(\.metadata), bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: from)],
            htmlBody: html.map { NodeSyncBody(state: .complete, value: $0) } ?? NodeSyncBody(state: .absent, value: nil),
            id: nodeID, inReplyTo: [], labels: [], receivedAt: Self.timestamp(receivedAt), references: [],
            replyTo: [], sentAt: Self.timestamp(receivedAt), subject: subject,
            textBody: NodeSyncBody(state: .complete, value: text), threadID: "t-" + nodeID,
            to: [NodeSyncAddress(displayName: "", mailbox: "me@example.test")]
        )
        lock.withLock {
            messages[nodeID] = Stored(
                message: message, logical: logical, rfcMessageID: rfcMessageID,
                memberships: memberships.map { Membership(logical: logical, path: $0.0, uidValidity: $0.1, uid: $0.2, flags: $0.3.sorted()) }
                    + foreignMemberships.map { Membership(logical: $0.0, path: $0.1, uidValidity: $0.2, uid: $0.3, flags: []) },
                attachments: attachments, omitBodiesInPages: omitBodiesInPages
            )
            if publish {
                appendLocked(kind: "upsert", logical: logical, messageID: nodeID, threadID: "t-" + nodeID)
            } else {
                heads[logical, default: 0] += 1
            }
        }
    }

    /// Replaces a message's memberships and publishes an upsert.
    func setMemberships(nodeID: String, _ memberships: [(String, UInt32, UInt32, [String])], publish: Bool = true) {
        lock.withLock {
            guard var stored = messages[nodeID] else { return }
            stored.memberships = memberships.map {
                Membership(logical: stored.logical, path: $0.0, uidValidity: $0.1, uid: $0.2, flags: $0.3.sorted())
            }
            messages[nodeID] = stored
            if publish {
                appendLocked(kind: "upsert", logical: stored.logical, messageID: nodeID, threadID: "t-" + nodeID)
            } else {
                heads[stored.logical, default: 0] += 1
            }
        }
    }

    func makeUnfittable(nodeID: String, _ unfittable: Bool = true) { lock.withLock { messages[nodeID]?.unfittable = unfittable } }
    /// IDs every snapshot page served, in order.
    var snapshotServed: [String] { lock.withLock { served } }
    /// Runs after each snapshot page is built, with its account and next cursor.
    func onAfterSnapshot(_ hook: (@Sendable (LogicalMailboxID, String) -> Void)?) { lock.withLock { afterSnapshotHook = hook } }
    /// Runs after a forced stale snapshot answer, with the account and the
    /// forced answers left.
    func onStaleSnapshot(_ hook: (@Sendable (LogicalMailboxID, Int) -> Void)?) { lock.withLock { staleSnapshotHook = hook } }

    func hideCoordinates(nodeID: String, _ hidden: Bool = true) {
        lock.withLock { messages[nodeID]?.coordinatesHidden = hidden }
    }

    /// Publishes an upsert without changing the message.
    func touch(nodeID: String) {
        lock.withLock {
            guard let stored = messages[nodeID] else { return }
            appendLocked(kind: "upsert", logical: stored.logical, messageID: nodeID, threadID: "t-" + nodeID)
        }
    }

    /// Removes one membership. Like the Node, the change names no message.
    func removeMembership(nodeID: String, path: String) {
        lock.withLock {
            guard var stored = messages[nodeID] else { return }
            stored.memberships.removeAll { $0.path == path }
            messages[nodeID] = stored
            appendLocked(kind: "membership_removed", logical: stored.logical, messageID: nil, threadID: nil)
        }
    }

    func tombstone(nodeID: String) {
        lock.withLock {
            guard let stored = messages.removeValue(forKey: nodeID) else { return }
            appendLocked(kind: "tombstoned", logical: stored.logical, messageID: nodeID, threadID: nil)
        }
    }

    /// A UIDVALIDITY change: the retired epoch's coordinates disappear until
    /// the new baseline records them.
    func epochReset(logical: LogicalMailboxID = FakeNodeMailServer.accountA) {
        lock.withLock { appendLocked(kind: "epoch_reset", logical: logical, messageID: nil, threadID: nil) }
    }

    func baselineComplete(logical: LogicalMailboxID = FakeNodeMailServer.accountA) {
        lock.withLock { appendLocked(kind: "baseline_complete", logical: logical, messageID: nil, threadID: nil) }
    }

    func failNextDeltaWithStaleCursor() { lock.withLock { staleDeltaFailures += 1 } }
    func failNextSnapshotWithStaleCursor() { lock.withLock { staleSnapshotFailures += 1 } }
    /// The `n`th continued (non-empty `after`) delta request from now is stale.
    func failDeltaWithStaleCursor(onContinuedRequest n: Int) {
        lock.withLock { staleDeltaAt.insert(continuedDeltaRequests + n) }
    }
    func failSnapshotsWithStaleCursor(logical: LogicalMailboxID, times: Int) {
        lock.withLock { staleSnapshotByAccount[logical, default: 0] += times }
    }
    func setSnapshotByteBudget(_ bytes: Int?) { lock.withLock { snapshotByteBudget = bytes } }
    /// The next requests whose path starts with `prefix` answer `problem`.
    func fail(_ prefix: String, with problem: NodeSyncProblem, times: Int = 1) {
        lock.withLock { failures[prefix, default: []] += Array(repeating: problem, count: times) }
    }
    func setConflicting(_ ids: Set<String>) { lock.withLock { conflicting = ids } }
    func setListedAccounts(_ accounts: [LogicalMailboxID]) { lock.withLock { listed = accounts } }
    /// Holds the next request whose path starts with `prefix` until released.
    func hold(_ prefix: String) -> Gate {
        let gate = Gate()
        lock.withLock { gates[prefix] = gate }
        return gate
    }
    var requests: [String] { lock.withLock { log } }
    func clearRequests() { lock.withLock { log.removeAll() } }
    func count(_ prefix: String) -> Int { lock.withLock { log.filter { $0.hasPrefix(prefix) }.count } }

    // MARK: - Mutation control

    /// States the next newly accepted mutations answer, in order; `applied`
    /// once the script is empty.
    func scriptMutationStates(_ states: [String]) { lock.withLock { mutationScript += states } }
    /// The next `count` mutation posts are accepted and then lose their
    /// response after dispatch; the answer stays retained for the session's
    /// next request (as the transport does).
    func failNextMutationAfterDispatch(times count: Int = 1) { lock.withLock { failAfterDispatch += count } }
    /// The next `count` mutation posts never leave this device.
    func failNextMutationBeforeDispatch(times count: Int = 1) { lock.withLock { failBeforeDispatch += count } }
    /// Like the Node after an authority-epoch change: the next newly accepted
    /// mutation signed under an older epoch binds its key and completes as
    /// `conflicted` (no child ran), and the account listing now reports the
    /// next epoch.
    func answerNextMutationAsStaleEpoch() { lock.withLock { staleEpochAnswers += 1 } }
    /// Binds `key` to other canonical bytes, as an earlier operation under the
    /// same key would: any other bytes under it answer `409 conflict`.
    func bindKey(_ key: String, state: String = "applied") {
        lock.withLock {
            accepted[key] = AcceptedMutation(canonicalOperation: Data("other-bytes-\(key)".utf8), state: state,
                                             logical: Self.accountA, kind: "other")
            acceptedOrder.append(key)
        }
    }
    /// The next `count` replays of the retained request cannot reach the Node;
    /// the request stays retained.
    func failNextReconcile(times count: Int = 1) { lock.withLock { reconcileFailures += count } }
    /// The Node device ID operations are signed for (the session's Node).
    func setSigningNodeID(_ id: String) { lock.withLock { nodeID = id } }
    /// Another device edits the draft on the Node right after the next
    /// applied save: its revision moves on by one more save.
    func editDraftOnAnotherDeviceAfterNextSave() { lock.withLock { remoteEditsAfterSave += 1 } }
    /// Settles every accepted `pending` mutation to `state`.
    func settlePendingMutations(to state: String) {
        lock.withLock {
            for key in acceptedOrder where accepted[key]?.state == "pending" { accepted[key]?.state = state }
        }
    }
    /// A retained answer for `key` the session replays on its next request.
    func retainAnswer(for key: String, state: String) throws {
        let body = try NodeSyncCodec.encodeMutationResult(NodeSyncMutationResult(idempotencyKey: key, state: state))
        lock.withLock {
            accepted[key]?.state = state
            retainedResponse = NodeHTTPResponse(statusCode: 200, url: Self.url.appendingPathComponent("v1/mutations"), headers: [:], body: body)
        }
    }
    /// Distinct operations the Node accepted (each at most once, by key).
    var mutationCount: Int { lock.withLock { acceptedOrder.count } }
    /// Every `POST /v1/mutations` that reached the Node, replays included.
    var mutationPostCount: Int { lock.withLock { mutationPosts } }
    var acceptedIdempotencyKeys: [String] { lock.withLock { acceptedOrder } }
    var acceptedKinds: [String] { lock.withLock { acceptedOrder.compactMap { accepted[$0]?.kind } } }
    var lastMutationLogicalMailboxID: LogicalMailboxID? { lock.withLock { mutationLogicals.last } }
    var signedMutationCount: Int { lock.withLock { signings } }
    func acceptedOperation(_ key: String) -> Data? { lock.withLock { accepted[key]?.canonicalOperation } }
    func acceptedState(_ key: String) -> String? { lock.withLock { accepted[key]?.state } }
    var acceptedStates: [String] { lock.withLock { acceptedOrder.compactMap { accepted[$0]?.state } } }

    // MARK: - Signing (behaves like the session transport)

    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        lock.withLock {
            if let installed = authorityEpochs[logicalMailboxID].flatMap(UInt64.init), let incoming = UInt64(epoch), installed >= incoming { return }
            authorityEpochs[logicalMailboxID] = epoch
        }
    }

    func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        let epoch = try lock.withLock { () -> String in
            guard let epoch = authorityEpochs[logicalMailboxID] else { throw NodeSyncClientError.invalidResponse }
            signings += 1
            return epoch
        }
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "00112233-4455-6677-8899-aabbccddeeff", authorityEpoch: epoch,
            clientID: "11111111-2222-3333-8444-555555555555", idempotencyKey: idempotencyKey,
            issuedAt: issuedAt, logicalMailboxID: logicalMailboxID,
            nodeID: lock.withLock { nodeID }, operation: variant, trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)))
    }

    // MARK: - NodeSessionRequestSending

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        try lock.withLock {
            guard retainedResponse != nil else { return nil }
            if reconcileFailures > 0 {
                reconcileFailures -= 1
                throw NodeSessionError.transportFailure
            }
            defer { retainedResponse = nil }
            return retainedResponse
        }
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let routeKey = method + " " + path
        guard lock.withLock({ () -> Bool in
            if !healthy { log.append(routeKey + " (unreachable)") }
            return healthy
        }) else { throw NodeSessionError.transportFailure }
        if let gate = lock.withLock({ () -> Gate? in
            log.append(routeKey)
            guard let key = gates.keys.first(where: { path.hasPrefix($0) }) else { return nil }
            return gates.removeValue(forKey: key)
        }) {
            await gate.arrive()
            try Task.checkCancellation()
        }
        if let problem = lock.withLock({ () -> NodeSyncProblem? in
            guard let key = failures.keys.first(where: { path.hasPrefix($0) }), var queue = failures[key], !queue.isEmpty else { return nil }
            let problem = queue.removeFirst()
            failures[key] = queue.isEmpty ? nil : queue
            return problem
        }) {
            return try problemResponse(problem)
        }
        switch (method, path) {
        case ("POST", "/v1/mutations"):
            return try mutation(body)
        case ("GET", _) where path.hasPrefix("/v1/drafts/"):
            return try draftState(String(path.dropFirst("/v1/drafts/".count)))
        case ("GET", "/v1/status"):
            return try ok(NodeSyncCodec.encodeStatusResult(NodeSyncStatusResult(revision: "1", state: "ready")))
        case ("GET", "/v1/mail/capabilities"):
            guard lock.withLock({ servesMailMode }) else {
                return NodeHTTPResponse(statusCode: 404, url: Self.url, headers: [:], body: Data())
            }
            return try ok(NodeSyncMailModeCodec.encodeMailCapabilities(
                NodeSyncMailCapabilities(googleImport: true, imapImport: true, mirrorCoordinates: true, multiAccount: true)))
        case ("GET", "/v1/mail/accounts"):
            return try ok(NodeSyncMailModeCodec.encodeMailAccountsResult(accounts()))
        case ("POST", "/v1/mail/deltas"):
            return try deltas(NodeSyncCodec.decodeDeltaRequest(body))
        case ("POST", "/v1/mail/snapshot"):
            return try snapshot(NodeSyncMailModeCodec.decodeAccountSnapshotRequest(body))
        case ("POST", "/v1/mail/mirror/coordinates"):
            return try coordinates(NodeSyncMailModeCodec.decodeMirrorCoordinatesRequest(body))
        case ("GET", _) where path.hasPrefix("/v1/mail/messages/"):
            return try message(path)
        default:
            return NodeHTTPResponse(statusCode: 404, url: Self.url, headers: [:], body: Data())
        }
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        lock.withLock { log.append(method + " " + path) }
        let parts = path.split(separator: "/").map(String.init)
        guard method == "GET", parts.count == 5, parts[0] == "v1", parts[1] == "mail", parts[2] == "attachments",
              let logical = try? NodeSyncCodec.decodeLogicalMailboxID(parts[3]),
              let attachment = lock.withLock({
                  messages.values.first { $0.logical == logical && $0.attachments.contains { $0.metadata.id == parts[4] } }?
                      .attachments.first { $0.metadata.id == parts[4] }
              })
        else {
            let stream = PlainpostByteStream()
            stream.producer.finish()
            return NodeHTTPStreamResponse(statusCode: 404, url: Self.url, headers: [:], bytes: stream)
        }
        let stream = PlainpostByteStream(capacity: 4)
        let producer = stream.producer
        let bytes = attachment.bytes
        Task {
            do {
                if !bytes.isEmpty { try await producer.send(bytes) }
                producer.finish()
            } catch {
                producer.fail(error)
            }
        }
        return NodeHTTPStreamResponse(statusCode: 200, url: Self.url, headers: [
            "Content-Type": attachment.metadata.mime,
            "Content-Length": String(bytes.count),
            "Content-Disposition": "attachment; filename=\(attachment.metadata.filename)",
        ], bytes: stream)
    }

    // MARK: - Routes

    private func accounts() throws -> NodeSyncMailAccountsResult {
        let listed = lock.withLock { self.listed }
        let accounts = try listed.enumerated().map { index, logical in
            try NodeSyncMailAccount(assignments: [
                NodeSyncDiscoveredMailbox(displayName: "Inbox", logicalMailboxID: logical, mailboxHandle: "INBOX", role: "inbox",
                                          authorityEpoch: String(epoch(logical))),
                NodeSyncDiscoveredMailbox(displayName: "Drafts", logicalMailboxID: logical, mailboxHandle: "Drafts", role: "drafts",
                                          authorityEpoch: String(epoch(logical))),
            ], logicalMailboxID: logical, primary: index == 0,
                                    providerIdentity: "user\(index)@example.test", providerKind: "gmail", state: .ready)
        }
        return try NodeSyncMailAccountsResult(accounts: accounts, primaryState: accounts.isEmpty ? .none : .available)
    }

    private func epoch(_ logical: LogicalMailboxID) -> UInt64 {
        lock.withLock { listingEpochs[logical, default: 1] }
    }

    private func deltas(_ request: NodeSyncDeltaRequest) throws -> NodeHTTPResponse {
        let result = lock.withLock { () -> (stale: Bool, changes: [NodeSyncChange], next: String, revision: String) in
            if !request.after.isEmpty {
                continuedDeltaRequests += 1
                if staleDeltaAt.remove(continuedDeltaRequests) != nil { return (true, [], "", "") }
            }
            if !request.after.isEmpty, staleDeltaFailures > 0 {
                staleDeltaFailures -= 1
                return (true, [], "", "")
            }
            let revision = String(sequence + 1)
            guard !request.after.isEmpty else { return (false, [], "d:\(sequence)", revision) }
            let start = Int(request.after.dropFirst(2)) ?? 0
            let page = changes.filter { $0.sequence > start }.prefix(Int(request.limit))
            return (false, page.map(\.change), "d:\(page.last?.sequence ?? start)", revision)
        }
        if result.stale { return try problemResponse(.staleCursor) }
        return try ok(NodeSyncMailModeCodec.encodeMailDeltaPage(
            NodeSyncMailDeltaPage(changes: result.changes, nextCursor: result.next, revision: result.revision, waitingAccounts: [])
        ))
    }

    private enum SnapshotOutcome {
        case stale(remaining: Int?)
        case conflict
        case page([NodeSyncMessage], next: String, revision: String)
    }

    /// Pages like the Node: by `(receivedAt, id)`, pinned to the account's
    /// head, trimmed to the byte budget with room for the continuation
    /// cursor, bodies omitted before a lone oversized message is `conflict`,
    /// and a next cursor only while pages remain.
    private func snapshot(_ request: NodeSyncAccountSnapshotRequest) throws -> NodeHTTPResponse {
        let (hook, call) = lock.withLock { () -> ((@Sendable (Int) -> Void)?, Int) in
            snapshotCalls += 1
            return (snapshotHook, snapshotCalls)
        }
        hook?(call)
        let logical = request.logicalMailboxID
        let outcome = lock.withLock { () -> SnapshotOutcome in
            if staleSnapshotFailures > 0, !request.after.isEmpty {
                staleSnapshotFailures -= 1
                return .stale(remaining: nil)
            }
            if !request.after.isEmpty, let remaining = staleSnapshotByAccount[logical], remaining > 0 {
                staleSnapshotByAccount[logical] = remaining - 1
                return .stale(remaining: remaining - 1)
            }
            let head = heads[logical, default: 0]
            var boundary: (String, String)?
            if !request.after.isEmpty {
                let parts = request.after.split(separator: "|", maxSplits: 2).map(String.init)
                guard parts.count == 3, Int(parts[0]) == head else { return .stale(remaining: nil) }
                boundary = (parts[1], parts[2])
            }
            let ordered = messages.values
                .filter { $0.logical == logical && !$0.memberships.isEmpty }
                // Newest first, as the Node pages (`received_at DESC, id ASC`).
                .sorted { $0.message.receivedAt != $1.message.receivedAt
                    ? $0.message.receivedAt > $1.message.receivedAt : $0.message.id < $1.message.id }
                .filter { stored in
                    boundary.map { stored.message.receivedAt < $0.0 || (stored.message.receivedAt == $0.0 && stored.message.id > $0.1) } ?? true
                }
            var page: [Stored] = []
            var sizes: [Int] = []
            var omitted: [Bool] = []
            for stored in ordered.prefix(Int(request.limit)) {
                let size = (pageMessage(stored).textBody.value ?? "").utf8.count
                let total = sizes.reduce(0, +)
                if let budget = snapshotByteBudget, total + size > budget || stored.unfittable {
                    guard page.isEmpty else { break }
                    // A lone message: omit its bodies before refusing it.
                    if stored.unfittable { return .conflict }
                    page.append(stored)
                    sizes.append(0)
                    omitted.append(true)
                    continue
                }
                if stored.unfittable {
                    guard page.isEmpty else { break }
                    return .conflict
                }
                page.append(stored)
                sizes.append(size)
                omitted.append(false)
            }
            if page.isEmpty, !ordered.isEmpty { return .conflict }
            var more = page.count < ordered.count
            if more, let budget = snapshotByteBudget {
                // Room for the continuation cursor: end the page one record earlier.
                while page.count > 1, sizes.reduce(0, +) + Self.cursorReserveBytes > budget {
                    page.removeLast()
                    sizes.removeLast()
                    omitted.removeLast()
                }
                if sizes.reduce(0, +) + Self.cursorReserveBytes > budget {
                    sizes[0] = 0
                    omitted[0] = true
                }
                more = page.count < ordered.count
            }
            let messagesOut = page.enumerated().map { index, stored -> NodeSyncMessage in
                omitted[index] ? omitBodies(stored.message) : pageMessage(stored)
            }
            served.append(contentsOf: messagesOut.map(\.id))
            let next = more ? "\(head)|\(page.last!.message.receivedAt)|\(page.last!.message.id)" : ""
            return .page(messagesOut, next: next, revision: String(sequence + 1))
        }
        switch outcome {
        case .stale(let remaining):
            if let remaining, let hook = lock.withLock({ staleSnapshotHook }) { hook(logical, remaining) }
            return try problemResponse(.staleCursor)
        case .conflict:
            return try problemResponse(.conflict)
        case .page(let page, let next, let revision):
            if let hook = lock.withLock({ afterSnapshotHook }) { hook(logical, next) }
            return try ok(NodeSyncCodec.encodeSnapshotPage(NodeSyncSnapshotPage(messages: page, nextCursor: next, revision: revision)))
        }
    }

    private static func coordinateOrderKey(_ membership: NodeSyncMirrorMembership) -> [UInt8] {
        let logical: [UInt8] = Array(membership.logicalMailboxID.rawValue)
        let path: [UInt8] = Array(membership.mailboxPath.utf8)
        return logical + [0] + path
    }

    private func coordinates(_ request: NodeSyncMirrorCoordinatesRequest) throws -> NodeHTTPResponse {
        let records = try lock.withLock { () -> [NodeSyncMirrorCoordinate]? in
            if request.messageIDs.contains(where: conflicting.contains) { return nil }
            return try request.messageIDs.compactMap { id -> NodeSyncMirrorCoordinate? in
                guard let stored = messages[id], !stored.memberships.isEmpty, !stored.coordinatesHidden else { return nil }
                let memberships: [NodeSyncMirrorMembership] = try stored.memberships.map {
                    try NodeSyncMirrorMembership(flags: $0.flags, logicalMailboxID: $0.logical, mailboxPath: $0.path,
                                                 uid: $0.uid, uidValidity: $0.uidValidity)
                }.sorted { Self.coordinateOrderKey($0).lexicographicallyPrecedes(Self.coordinateOrderKey($1)) }
                return try NodeSyncMirrorCoordinate(memberships: memberships, messageID: id, rfcMessageID: stored.rfcMessageID)
            }
        }
        guard let records else { return try problemResponse(.conflict) }
        return try ok(NodeSyncMailModeCodec.encodeMirrorCoordinatesResult(NodeSyncMirrorCoordinatesResult(records: records)))
    }

    private func message(_ path: String) throws -> NodeHTTPResponse {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 5, let logical = try? NodeSyncCodec.decodeLogicalMailboxID(parts[3]),
              let id = Self.decodeToken(parts[4]),
              let stored = lock.withLock({ messages[id] }), stored.logical == logical, !stored.memberships.isEmpty
        else { return NodeHTTPResponse(statusCode: 404, url: Self.url, headers: [:], body: Data()) }
        return try ok(NodeSyncCodec.encodeMessageResult(NodeSyncMessageResult(message: stored.message)))
    }

    private func mutation(_ body: Data) throws -> NodeHTTPResponse {
        let canonical = try NodeSyncCodec.decodeMutationRequest(body).canonicalOperation
        let operation = try NodeSyncCodec.decodeOperation(canonical)
        let key = operation.unsigned.idempotencyKey
        enum Answer { case notDispatched, conflict, state(String, afterDispatchFailure: Bool) }
        let answer = lock.withLock { () -> Answer in
            if failBeforeDispatch > 0 {
                failBeforeDispatch -= 1
                return .notDispatched
            }
            mutationPosts += 1
            mutationLogicals.append(operation.unsigned.logicalMailboxID)
            // Like the Node, the key and digest are bound before anything else
            // is decided: other bytes under a bound key are a 409.
            let state: String
            if let stored = accepted[key] {
                guard stored.canonicalOperation == canonical else { return .conflict }
                state = stored.state
            } else {
                let logical = operation.unsigned.logicalMailboxID
                let signedEpoch = UInt64(operation.unsigned.authorityEpoch) ?? 0
                let currentEpoch = listingEpochs[logical, default: 1]
                if staleEpochAnswers > 0 {
                    staleEpochAnswers -= 1
                    listingEpochs[logical] = max(currentEpoch, signedEpoch) + 1
                    state = "conflicted"
                } else if signedEpoch < currentEpoch {
                    state = "conflicted"
                } else if let expected = Self.expectedDraftRevision(operation.unsigned.operation),
                          expected.revision != draftRevisions[expected.draftID, default: 0] {
                    // The Node's draft CAS: a save or send at another revision.
                    state = "conflicted"
                } else {
                    state = mutationScript.isEmpty ? "applied" : mutationScript.removeFirst()
                }
                accepted[key] = AcceptedMutation(canonicalOperation: canonical, state: state,
                                                 logical: operation.unsigned.logicalMailboxID, kind: Self.kind(operation.unsigned.operation))
                acceptedOrder.append(key)
                if state == "applied", case let .saveDraft(draftID, _, _, _) = operation.unsigned.operation {
                    draftRevisions[draftID, default: 0] += 2
                    if remoteEditsAfterSave > 0 {
                        remoteEditsAfterSave -= 1
                        draftRevisions[draftID, default: 0] += 2
                    }
                }
            }
            let failAfter = failAfterDispatch > 0
            if failAfter { failAfterDispatch -= 1 }
            return .state(state, afterDispatchFailure: failAfter)
        }
        switch answer {
        case .notDispatched:
            throw NodeSessionError.transportFailure
        case .conflict:
            return try problemResponse(.conflict)
        case let .state(state, afterDispatchFailure):
            let response = ok(try NodeSyncCodec.encodeMutationResult(NodeSyncMutationResult(idempotencyKey: key, state: state)))
            if afterDispatchFailure {
                lock.withLock { retainedResponse = response }
                throw NodeSessionError.transportFailureAfterDispatch
            }
            return response
        }
    }

    private func draftState(_ draftID: String) throws -> NodeHTTPResponse {
        guard let revision = lock.withLock({ draftRevisions[draftID] }) else {
            return NodeHTTPResponse(statusCode: 404, url: Self.url, headers: [:], body: Data())
        }
        return ok(try NodeSyncCodec.encodeDraftState(NodeSyncDraftState(draftID: draftID, revision: String(revision), state: "appended")))
    }

    private static func expectedDraftRevision(_ variant: NodeSyncOperationVariant) -> (draftID: String, revision: UInt64)? {
        switch variant {
        case let .saveDraft(draftID, expected, _, _), let .send(draftID, expected):
            return UInt64(expected).map { (draftID, $0) }
        default:
            return nil
        }
    }

    private static func kind(_ variant: NodeSyncOperationVariant) -> String {
        switch variant {
        case .saveDraft: "save_draft"
        case .send: "send"
        case let .setRead(_, read): read ? "set_read" : "set_unread"
        case .archive: "archive"
        case .delete: "delete"
        case .setLabels: "set_labels"
        case .deleteDraft: "delete_draft"
        case let .setFlagged(_, flagged): flagged ? "set_flagged" : "set_unflagged"
        case .move: "move"
        }
    }

    // MARK: - Helpers

    private func appendLocked(kind: String, logical: LogicalMailboxID, messageID: String?, threadID: String?) {
        sequence += 1
        heads[logical, default: 0] += 1
        changes.append((sequence, try! NodeSyncChange(kind: kind, logicalMailboxID: logical, messageID: messageID, threadID: threadID)))
    }

    private func pageMessage(_ stored: Stored) -> NodeSyncMessage {
        guard stored.omitBodiesInPages else { return stored.message }
        return omitBodies(stored.message)
    }

    private func omitBodies(_ message: NodeSyncMessage) -> NodeSyncMessage {
        let omitted = NodeSyncBody(state: .omittedOversized, value: nil)
        return NodeSyncMessage(
            attachments: message.attachments, bcc: message.bcc, cc: message.cc, flags: message.flags, from: message.from,
            htmlBody: message.htmlBody.state == .complete ? omitted : message.htmlBody, id: message.id,
            inReplyTo: message.inReplyTo, labels: message.labels, receivedAt: message.receivedAt,
            references: message.references, replyTo: message.replyTo, sentAt: message.sentAt, subject: message.subject,
            textBody: message.textBody.state == .complete ? omitted : message.textBody, threadID: message.threadID,
            to: message.to
        )
    }

    private func ok(_ body: Data) -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 200, url: Self.url, headers: [:], body: body)
    }

    private func problemResponse(_ problem: NodeSyncProblem) throws -> NodeHTTPResponse {
        let status = switch problem {
        case .conflict, .staleCursor: 409
        case .unauthorized: 401
        case .invalidRequest: 400
        case .unavailable: 503
        }
        return NodeHTTPResponse(statusCode: status, url: Self.url, headers: [:],
                                body: try NodeSyncCodec.encodeProblem(NodeSyncProblemResult(category: problem)))
    }

    private static let url = URL(string: "https://node.example.ts.net:443")!

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    private static func decodeToken(_ token: String) -> String? {
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Suspends a request until the test releases it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var arrived = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        func arrive() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    arrived = true
                    if released { return true }
                    waiter = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        var hasArrived: Bool { lock.withLock { arrived } }

        func release() {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume()
        }
    }
}
