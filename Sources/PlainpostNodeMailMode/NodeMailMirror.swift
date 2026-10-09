import Foundation
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport

/// Mirrors one Sync Node's mail into the local store for every account that
/// is Node-backed for that Node. The local store stays the UI's source; the
/// Node is upstream. Every write goes through a store API that re-checks,
/// inside its transaction, that the account is still Node-backed for this
/// Node and logical mailbox, so a Direct account is never written and a flip
/// or rebind mid-pass stops the pass (`mirrorScopeChanged`).
///
/// `runPass`, `hydrate` and `seedCursor` never overlap, even when called
/// from different tasks.
public actor NodeMailMirror {
    public struct PassResult: Equatable, Sendable {
        public let committed: Int
        public let removed: Int
        public let bootstrapped: Bool
        /// True when every account of the Node is bootstrapped and the pass
        /// did not stop at its page budget.
        public let complete: Bool
        /// The pass stopped at its page budget: run another one now. Work that
        /// only a later change or tick can unblock (a conflicting ID, an
        /// account the Node does not list yet) never sets this, so the loop
        /// cannot spin on it.
        public let hasMore: Bool
        /// Records skipped because a stable key holds a message with another
        /// RFC Message-ID (or every key is held by another local message).
        public let identityMismatches: Int
        /// IDs that still conflicted at batch size 1; retried later.
        public let coordinateConflicts: Int
        /// IDs without coordinates or messages right now; retried later, never removed.
        public let skipped: Int

        public init(
            committed: Int, removed: Int, bootstrapped: Bool, complete: Bool, hasMore: Bool = false,
            identityMismatches: Int = 0, coordinateConflicts: Int = 0, skipped: Int = 0
        ) {
            self.committed = committed
            self.removed = removed
            self.bootstrapped = bootstrapped
            self.complete = complete
            self.hasMore = hasMore
            self.identityMismatches = identityMismatches
            self.coordinateConflicts = coordinateConflicts
            self.skipped = skipped
        }
    }

    struct Limits: Sendable {
        var maximumPagesPerPass = 20
        var coordinateBatch = 200
        var attachmentBytes = IncomingMessageAttachmentPayload.maximumDecodedBytesPerAttachment
        var aggregateAttachmentBytes = IncomingMessageAttachmentPayload.maximumAggregateDecodedBytes
        var attachmentCount = IncomingMessageAttachmentPayload.maximumAttachmentCount
        /// An ID an audit cannot resolve is retried after this, not every pass.
        var auditRetryDelay: TimeInterval = 3_600
    }

    private struct Tally {
        var committed = 0
        var removed = 0
        var bootstrapped = false
        var hasMore = false
        var identityMismatches = 0
        var coordinateConflicts = 0
        var skipped = 0
    }

    private struct StaleDeltaCursor: Error {}

    private let store: SQLiteMailStore
    private var client: NodeSyncClient
    public nonisolated let nodeID: String
    private let pageSize: Int
    private let now: @Sendable () -> Date
    private let limits: Limits
    private let jitter: @Sendable () -> Double
    private let classifier = SmartCategoryClassifier()
    private let lane = MirrorLane()
    /// How many of an account's newest messages to keep; `nil` mirrors the
    /// whole history.
    private let window: @Sendable (AccountID) -> Int?

    public init(
        store: SQLiteMailStore, client: NodeSyncClient, nodeID: String, pageSize: Int = 50,
        now: @escaping @Sendable () -> Date = Date.init,
        window: @escaping @Sendable (AccountID) -> Int? = { _ in nil }
    ) {
        self.init(store: store, client: client, nodeID: nodeID, pageSize: pageSize, now: now, limits: Limits(), window: window)
    }

    init(
        store: SQLiteMailStore, client: NodeSyncClient, nodeID: String, pageSize: Int = 50,
        now: @escaping @Sendable () -> Date = Date.init, limits: Limits,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1) },
        window: @escaping @Sendable (AccountID) -> Int? = { _ in nil }
    ) {
        self.window = window
        self.store = store
        self.client = client
        self.nodeID = nodeID.lowercased()
        self.pageSize = min(max(pageSize, 1), 200)
        self.now = now
        self.limits = limits
        self.jitter = jitter
    }

    /// The loop hands every pass the broker's current client: a client from
    /// before an invalidation fails closed.
    func use(client: NodeSyncClient) {
        self.client = client
    }

    /// One bounded pass for every Node-backed account of this Node.
    public func runPass() async throws -> PassResult {
        try await lane.run { try await self.pass() }
    }

    /// Fetches omitted bodies and attachment payloads for at most `limit`
    /// mirrored messages. Returns how many were hydrated.
    public func hydrate(limit: Int) async throws -> Int {
        try await lane.run { try await self.hydrateMessages(limit: limit) }
    }

    /// Handover step, run before the flip: (re)opens the account's bootstrap
    /// for its target binding on this Node and captures the Node delta cursor
    /// only if there is none yet. Writes no mail; the first pass after the
    /// flip snapshots the account.
    public func seedCursor(accountID: AccountID, logicalMailboxID: String) async throws {
        try await lane.run { try await self.seed(accountID: accountID, logicalMailboxID: logicalMailboxID) }
    }

    // MARK: - Pass

    private func pass() async throws -> PassResult {
        try store.requireNodeMirrorSchema()
        let accounts = try nodeAccounts()
        guard !accounts.isEmpty else { return PassResult(committed: 0, removed: 0, bootstrapped: false, complete: true) }
        try prepareBootstrapRows(accounts)
        var tally = Tally()
        do {
            try await passBody(accounts, tally: &tally)
        } catch is StaleDeltaCursor {
            // A stale cursor or a rebuilt Node: re-mirror everything by
            // stable key. Existing rows resolve to their IDs, so nothing is
            // duplicated and nothing notifies again.
            try store.resetNodeMirror(nodeID: nodeID)
            do {
                try await passBody(accounts, tally: &tally)
            } catch is StaleDeltaCursor {
                // Stale again straight after a fresh bootstrap: back off.
                try store.resetNodeMirror(nodeID: nodeID)
                throw NodeSyncClientError.problem(.staleCursor)
            }
        }
        if tally.committed + tally.removed > 0 {
            MailStoreChangeSignal.post(scope: .mailbox)
        }
        let complete = try store.nodeMirrorCursor(nodeID: nodeID)?.complete == true && !tally.hasMore
        return PassResult(
            committed: tally.committed, removed: tally.removed, bootstrapped: tally.bootstrapped,
            complete: complete, hasMore: tally.hasMore, identityMismatches: tally.identityMismatches,
            coordinateConflicts: tally.coordinateConflicts, skipped: tally.skipped
        )
    }

    private func passBody(_ accounts: [String: NodeMirrorScope], tally: inout Tally) async throws {
        var cursor: NodeMirrorCursor
        if let stored = try store.nodeMirrorCursor(nodeID: nodeID) {
            cursor = stored
        } else {
            cursor = try await captureCursor()
        }
        try await bootstrap(accounts, tally: &tally)
        let allComplete = try accounts.values.allSatisfy { try store.nodeMirrorAccountBootstrap(accountID: $0.accountID)?.complete == true }
        if cursor.complete != allComplete {
            let updated = NodeMirrorCursor(nodeID: nodeID, deltaCursor: cursor.deltaCursor, revision: cursor.revision,
                                           complete: allComplete)
            try store.saveNodeMirrorCursor(updated, expected: cursor)
            cursor = updated
        }
        try await applyDeltas(accounts, cursor: cursor, tally: &tally)
        if !tally.hasMore {
            // Deltas since the replay start are applied, so a message the
            // fresh snapshot missed but that still exists was re-upserted.
            try sweep(accounts, tally: &tally)
        }
        try await audit(accounts, tally: &tally)
        try await retryAudits(accounts, tally: &tally)
    }

    private func sweep(_ accounts: [String: NodeMirrorScope], tally: inout Tally) throws {
        for scope in accounts.values.sorted(by: { $0.accountID.rawValue < $1.accountID.rawValue }) {
            guard let row = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID),
                  row.complete, row.sweepPending else { continue }
            tally.removed += try store.sweepUnlistedMirroredMessages(scope: scope)
        }
    }

    private func captureCursor() async throws -> NodeMirrorCursor {
        let page = try await client.mailDeltas(after: "", limit: pageSize)
        let cursor = NodeMirrorCursor(nodeID: nodeID, deltaCursor: page.nextCursor, revision: page.revision, complete: false)
        try store.saveNodeMirrorCursor(cursor, expected: nil)
        return cursor
    }

    /// Node-backed accounts of this Node, keyed by logical mailbox.
    private func nodeAccounts() throws -> [String: NodeMirrorScope] {
        var accounts: [String: NodeMirrorScope] = [:]
        for source in try store.mailSources() {
            guard let scope = NodeMirrorScope(source: source), scope.nodeID == nodeID else { continue }
            accounts[scope.logicalMailboxID] = scope
        }
        return accounts
    }

    /// Reconnect after fallback happens one account at a time. A pass that
    /// runs while an account of this Node is out of node mode moves the shared
    /// delta cursor past that account's changes, so the account is flagged
    /// before the pass and, once it is back in node mode, re-seeded (a full
    /// re-snapshot with a sweep) before any delta is applied to it. The mirror
    /// is therefore correct whatever order the reconnect flips accounts in.
    private func prepareBootstrapRows(_ accounts: [String: NodeMirrorScope]) throws {
        try store.markNodeMirrorAccountsExcluded(nodeID: nodeID, mirrored: accounts.values.map(\.accountID))
        for scope in accounts.values.sorted(by: { $0.accountID.rawValue < $1.accountID.rawValue }) {
            guard let row = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID) else {
                try store.saveNodeMirrorAccountBootstrap(Self.freshBootstrap(scope))
                continue
            }
            if row.scope != scope {
                try store.rebindNodeMirrorAccount(scope)
            } else if row.needsReseed {
                try store.seedNodeMirrorAccount(scope)
            }
        }
    }

    private func bootstrap(_ accounts: [String: NodeMirrorScope], tally: inout Tally) async throws {
        var pending: [NodeMirrorAccountBootstrap] = []
        for scope in accounts.values.sorted(by: { $0.accountID.rawValue < $1.accountID.rawValue }) {
            guard let row = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID), !row.complete else { continue }
            // A snapshot the Node refused waits for its retry time.
            if let retry = row.snapshotRetryAt, retry > now() { continue }
            pending.append(row)
        }
        guard !pending.isEmpty else { return }
        // Only accounts the Node lists can be snapshotted; the rest wait.
        let listed = Set(try await client.mailAccounts().accounts.compactMap { try? NodeMailMirrorMapping.logicalMailboxKey($0.logicalMailboxID) })
        var pages = 0
        for var row in pending {
            guard listed.contains(row.logicalMailboxID) else { continue }
            let logical = try NodeMailMirrorMapping.logicalMailboxID(row.logicalMailboxID)
            var restarted = false
            while !row.complete {
                guard pages < limits.maximumPagesPerPass else {
                    tally.hasMore = true
                    return
                }
                pages += 1
                let page: NodeSyncSnapshotPage
                do {
                    page = try await client.mailSnapshot(NodeSyncAccountSnapshotRequest(
                        after: row.snapshotCursor, limit: UInt16(pageSize), logicalMailboxID: logical
                    ))
                } catch NodeSyncClientError.problem(.staleCursor) {
                    guard !restarted else {
                        // Stale again: leave this account as it is and go on
                        // with the others and the deltas.
                        break
                    }
                    // Restart this account's snapshot; the delta cursor stays.
                    restarted = true
                    row = row.updating(snapshotCursor: "", complete: false)
                    try store.saveNodeMirrorAccountBootstrap(row)
                    continue
                } catch NodeSyncClientError.conflict {
                    // The Node cannot page past a message that fits no page.
                    // Leave this account incomplete, retry it slowly, and go
                    // on with the others and the deltas.
                    tally.skipped += 1
                    row = row.retryingSnapshot(at: now().addingTimeInterval(limits.auditRetryDelay * min(max(jitter(), 0.5), 1)))
                    try store.saveNodeMirrorAccountBootstrap(row)
                    break
                }
                // First bootstrap: establish the watermark, since the account's
                // whole history arrives now. A re-bootstrap of an account that
                // completed before may carry mail that arrived while this Mac
                // was not following the Node: it is a candidate. The store
                // notifies only a new canonical message within 15 minutes of
                // its arrival, so mail already present or old stays quiet.
                let reBootstrap = row.everComplete
                // Pages come newest first, so a window keeps the head of the
                // snapshot and ends it once full.
                var messages = page.messages
                var windowFull = false
                if let limit = window(row.accountID) {
                    let room = max(limit - (try store.nodeMirrorListedCount(accountID: row.accountID)), 0)
                    windowFull = messages.count >= room
                    messages = Array(messages.prefix(room))
                }
                try await commit(messages, scope: row.scope, notification: { message in
                    reBootstrap ? .candidate(providerArrivalAt: NodeMailMirrorMapping.date(message.receivedAt)) : .establishWatermark
                }, tally: &tally)
                try store.markNodeMirrorLinksListed(accountID: row.accountID, nodeMessageIDs: messages.map(\.id))
                // The Node sets a next cursor only while pages remain; a page
                // may hold fewer than `pageSize` messages to fit its byte cap.
                let done = page.nextCursor.isEmpty || windowFull
                row = row.updating(snapshotCursor: page.nextCursor, complete: done).retryingSnapshot(at: nil)
                try store.saveNodeMirrorAccountBootstrap(row)
                tally.bootstrapped = true
            }
        }
    }

    private func applyDeltas(_ accounts: [String: NodeMirrorScope], cursor start: NodeMirrorCursor, tally: inout Tally) async throws {
        var cursor = start
        var pages = 0
        while true {
            guard pages < limits.maximumPagesPerPass else {
                tally.hasMore = true
                return
            }
            pages += 1
            let page: NodeSyncMailDeltaPage
            do {
                page = try await client.mailDeltas(after: cursor.deltaCursor, limit: pageSize)
            } catch NodeSyncClientError.problem(.staleCursor) {
                throw StaleDeltaCursor()
            }
            try await apply(page.changes, accounts: accounts, tally: &tally)
            // Only after every change of the page is committed.
            let next = NodeMirrorCursor(nodeID: nodeID, deltaCursor: page.nextCursor, revision: page.revision,
                                        complete: cursor.complete)
            try store.saveNodeMirrorCursor(next, expected: cursor)
            cursor = next
            if page.changes.count < pageSize { return }
        }
    }

    private func apply(_ changes: [NodeSyncChange], accounts: [String: NodeMirrorScope], tally: inout Tally) async throws {
        var lastKind: [String: [String: String]] = [:]     // logical -> message -> last kind
        var order: [String: [String]] = [:]
        var states: [String: NodeMirrorReconcileState] = [:]
        for change in changes {
            // A change of a logical mailbox no local account mirrors is ignored.
            guard let key = try? NodeMailMirrorMapping.logicalMailboxKey(change.logicalMailboxID),
                  let scope = accounts[key] else { continue }
            switch change.kind {
            case "upsert", "tombstoned":
                guard let messageID = change.messageID else { continue }
                if lastKind[key]?[messageID] == nil { order[key, default: []].append(messageID) }
                lastKind[key, default: [:]][messageID] = change.kind
            case "membership_removed", "epoch_reset", "baseline_complete":
                let current = try states[key] ?? store.nodeMirrorAccountBootstrap(accountID: scope.accountID)?.reconcileState ?? .none
                states[key] = Self.reconcileState(after: change.kind, from: current)
            default:
                continue
            }
        }
        for key in order.keys.sorted() {
            guard let scope = accounts[key], let ids = order[key], let kinds = lastKind[key] else { continue }
            // A re-bootstrap (re-seed, reset) still notifies fresh arrivals:
            // only an account that never completed a bootstrap establishes
            // its watermark.
            let bootstrapComplete = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID)?.everComplete == true
            let upserts = ids.filter { kinds[$0] == "upsert" }
            try await upsert(upserts, scope: scope, fresh: bootstrapComplete, tally: &tally)
            // Existing on the Node: a pending sweep must keep them even when
            // their commit was skipped.
            try store.markNodeMirrorLinksListed(accountID: scope.accountID, nodeMessageIDs: upserts)
            for id in ids where kinds[id] == "tombstoned" {
                if try store.removeMirroredMessage(nodeMessageID: id, scope: scope) { tally.removed += 1 }
            }
        }
        for (key, state) in states.sorted(by: { $0.key < $1.key }) {
            guard let scope = accounts[key], let row = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID),
                  row.reconcileState != state else { continue }
            try store.saveNodeMirrorAccountBootstrap(row.updating(reconcileState: state))
        }
    }

    /// `membership_removed` and `epoch_reset` name no message. A removal asks
    /// for an audit of the account's links; an epoch reset defers it until
    /// the new baseline completes, because until then the new epoch has no
    /// coordinates and omission must not remove rows.
    static func reconcileState(after kind: String, from current: NodeMirrorReconcileState) -> NodeMirrorReconcileState {
        switch kind {
        case "epoch_reset": return .awaitingBaseline
        case "baseline_complete": return current == .awaitingBaseline ? .audit : current
        case "membership_removed": return current == .awaitingBaseline ? .awaitingBaseline : .audit
        default: return current
        }
    }

    private func upsert(_ ids: [String], scope: NodeMirrorScope, fresh: Bool, tally: inout Tally) async throws {
        guard !ids.isEmpty else { return }
        let logical = try NodeMailMirrorMapping.logicalMailboxID(scope.logicalMailboxID)
        var messages: [NodeSyncMessage] = []
        for id in ids {
            do {
                messages.append(try await client.mailMessage(id: id, logicalMailboxID: logical))
            } catch NodeSyncClientError.notFound, NodeSyncClientError.conflict {
                // Gone, not addressable or not representable right now; a
                // later change says which. One message never wedges the stream.
                tally.skipped += 1
            }
        }
        messages = try withinWindow(messages, scope: scope)
        // Only a fresh arrival after the account's bootstrap may notify, and
        // the store lets only an INBOX membership of a new message do so.
        try await commit(messages, scope: scope, notification: { message in
            fresh ? .candidate(providerArrivalAt: NodeMailMirrorMapping.date(message.receivedAt)) : .establishWatermark
        }, tally: &tally)
    }

    /// A change never pulls in a message older than a full window: one not
    /// mirrored yet and sent before the oldest mirrored message stays out.
    /// Messages already mirrored always update.
    private func withinWindow(_ messages: [NodeSyncMessage], scope: NodeMirrorScope) throws -> [NodeSyncMessage] {
        guard let limit = window(scope.accountID), !messages.isEmpty else { return messages }
        let mirrored = try store.nodeMirrorWindow(accountID: scope.accountID)
        guard mirrored.count >= limit, let floor = mirrored.oldestSentAt else { return messages }
        return try messages.filter { message in
            if try store.messageID(forNodeMessageID: message.id, accountID: scope.accountID) != nil { return true }
            guard let sent = message.sentAt.flatMap(NodeMailMirrorMapping.date) else { return true }
            return sent >= floor
        }
    }

    /// Resolves coordinates for `messages` and commits each into `scope`.
    private func commit(
        _ messages: [NodeSyncMessage], scope: NodeMirrorScope,
        notification: (NodeSyncMessage) -> IncomingNotificationDisposition, tally: inout Tally
    ) async throws {
        guard !messages.isEmpty else { return }
        let resolved = try await coordinates(for: messages.map(\.id), tally: &tally)
        for message in messages {
            guard let record = resolved.records[message.id] else {
                if !resolved.conflicted.contains(message.id) { tally.skipped += 1 }
                continue
            }
            let memberships = NodeMailMirrorMapping.memberships(of: record, scope: scope)
            guard !memberships.isEmpty else {
                tally.skipped += 1
                continue
            }
            guard let target = try resolveTarget(record: record, scope: scope, memberships: memberships, tally: &tally) else {
                continue
            }
            let content = NodeMailMirrorMapping.content(
                of: message, messageID: target.messageID, accountID: scope.accountID,
                rfcMessageID: record.rfcMessageID, memberships: target.memberships, classifier: classifier
            )
            do {
                _ = try store.commitMirroredMessage(
                    content.summary, metadata: content.metadata, scope: scope, nodeMessageID: message.id,
                    memberships: target.memberships, notification: notification(message),
                    preserveExistingBodies: content.preserveExistingBodies, hydration: content.hydration,
                    nodeAttachmentIDs: content.attachmentIDs, thread: content.thread
                )
                tally.committed += 1
            } catch NodeMailModeStoreError.messageIdentityMismatch {
                // A key changed hands since it was verified; never overwrite.
                tally.identityMismatches += 1
            }
        }
    }

    /// The local message a Node message resolves to, and the memberships it
    /// may take. A key holding a message with another RFC Message-ID skips
    /// the whole record. Otherwise the linked message wins, then the message
    /// already at one of its keys, then direct sync's computed ID; a key held
    /// by a different local message is left to it.
    private func resolveTarget(
        record: NodeSyncMirrorCoordinate, scope: NodeMirrorScope, memberships: [MirroredMembership], tally: inout Tally
    ) throws -> (messageID: MessageID, memberships: [MirroredMembership])? {
        var existing: [StableMessageKey: MessageID] = [:]
        do {
            for membership in memberships {
                if let id = try store.verifyStableMessageKey(membership.key, rfcMessageID: record.rfcMessageID) {
                    existing[membership.key] = id
                }
            }
        } catch NodeMailModeStoreError.messageIdentityMismatch {
            tally.identityMismatches += 1
            return nil
        }
        let linked = try store.messageID(forNodeMessageID: record.messageID, accountID: scope.accountID)
        let atLowestKey = memberships
            .sorted { NodeMailMirrorMapping.lowest([$0, $1])?.key == $0.key }
            .lazy.compactMap { existing[$0.key] }.first
        guard let target = linked ?? atLowestKey ?? NodeMailMirrorMapping.computedMessageID(
            accountID: scope.accountID, rfcMessageID: record.rfcMessageID, memberships: memberships
        ) else { return nil }
        let kept = memberships.filter { existing[$0.key].map { $0 == target } ?? true }
        guard !kept.isEmpty else {
            tally.identityMismatches += 1
            return nil
        }
        return (target, kept)
    }

    /// Coordinates in batches of up to 200, halving on `conflict`. An ID that
    /// still conflicts alone is skipped, counted and retried on a later pass.
    private func coordinates(
        for ids: [String], tally: inout Tally
    ) async throws -> (records: [String: NodeSyncMirrorCoordinate], conflicted: Set<String>) {
        var unique: [String] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted { unique.append(id) }
        unique.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var batches: [ArraySlice<String>] = stride(from: 0, to: unique.count, by: limits.coordinateBatch).map {
            unique[$0..<min($0 + limits.coordinateBatch, unique.count)]
        }
        var records: [String: NodeSyncMirrorCoordinate] = [:]
        var conflicted = Set<String>()
        while !batches.isEmpty {
            let batch = batches.removeFirst()
            do {
                let result = try await client.mirrorCoordinates(messageIDs: Array(batch))
                let requested = Set(batch)
                for record in result.records where requested.contains(record.messageID) {
                    records[record.messageID] = record
                }
            } catch NodeSyncClientError.conflict {
                if batch.count == 1 {
                    tally.coordinateConflicts += 1
                    conflicted.insert(batch[batch.startIndex])
                } else {
                    let middle = batch.startIndex + batch.count / 2
                    batches.insert(contentsOf: [batch[batch.startIndex..<middle], batch[middle..<batch.endIndex]], at: 0)
                }
            }
        }
        return (records, conflicted)
    }

    /// Re-coordinates the linked messages of accounts whose removals or
    /// completed epoch baseline asked for it. A linked message the Node no
    /// longer lists with a membership in the account was removed there.
    private func audit(_ accounts: [String: NodeMirrorScope], tally: inout Tally) async throws {
        for scope in accounts.values.sorted(by: { $0.accountID.rawValue < $1.accountID.rawValue }) {
            guard let row = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID) else { continue }
            if row.reconcileState == .awaitingBaseline { continue }
            guard row.reconcileState == .audit else { continue }
            var after = ""
            while true {
                let ids = try store.mirroredNodeMessageIDs(accountID: scope.accountID, after: after, limit: limits.coordinateBatch)
                guard let last = ids.last else { break }
                try await reconcileLinks(ids, scope: scope, tally: &tally)
                after = last
            }
            // IDs that still conflict were scheduled for a slow retry; the
            // audit itself is done, so it never re-runs every pass.
            guard let current = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID),
                  current.reconcileState == .audit else { continue }
            try store.saveNodeMirrorAccountBootstrap(current.updating(reconcileState: NodeMirrorReconcileState.none))
        }
    }

    /// Links an earlier audit could not resolve, once their retry time passed.
    private func retryAudits(_ accounts: [String: NodeMirrorScope], tally: inout Tally) async throws {
        for scope in accounts.values.sorted(by: { $0.accountID.rawValue < $1.accountID.rawValue }) {
            guard let row = try store.nodeMirrorAccountBootstrap(accountID: scope.accountID),
                  row.reconcileState != .awaitingBaseline else { continue }
            let due = try store.dueMirrorAuditRetries(accountID: scope.accountID, now: now(), limit: limits.coordinateBatch)
            if !due.isEmpty { try await reconcileLinks(due, scope: scope, tally: &tally) }
        }
    }

    /// Re-coordinates linked messages: memberships are synced, and a message
    /// without a membership in the account is removed. An ID that still
    /// conflicts is retried after `auditRetryDelay` (jittered).
    private func reconcileLinks(_ ids: [String], scope: NodeMirrorScope, tally: inout Tally) async throws {
        let resolved = try await coordinates(for: ids, tally: &tally)
        for id in ids where !resolved.conflicted.contains(id) {
            let memberships = resolved.records[id].map { NodeMailMirrorMapping.memberships(of: $0, scope: scope) } ?? []
            if memberships.isEmpty {
                if try store.removeMirroredMessage(nodeMessageID: id, scope: scope) { tally.removed += 1 }
                continue
            }
            do {
                try store.syncMirroredMemberships(scope: scope, nodeMessageID: id, memberships: memberships)
            } catch NodeMailModeStoreError.messageIdentityMismatch {
                tally.identityMismatches += 1
            }
        }
        let conflicted = ids.filter(resolved.conflicted.contains)
        if !conflicted.isEmpty {
            let delay = limits.auditRetryDelay * min(max(jitter(), 0.5), 1)
            try store.scheduleMirrorAuditRetry(accountID: scope.accountID, nodeMessageIDs: conflicted,
                                               at: now().addingTimeInterval(delay))
        }
    }

    // MARK: - Hydration

    private func hydrateMessages(limit: Int) async throws -> Int {
        guard limit > 0 else { return 0 }
        try store.requireNodeMirrorSchema()
        var remaining = limit
        var hydrated = 0
        for scope in try nodeAccounts().values.sorted(by: { $0.accountID.rawValue < $1.accountID.rawValue }) where remaining > 0 {
            let logical = try NodeMailMirrorMapping.logicalMailboxID(scope.logicalMailboxID)
            for item in try store.pendingMirrorHydration(accountID: scope.accountID, limit: remaining, now: now()) {
                remaining -= 1
                do {
                    let message = try await client.mailMessage(id: item.nodeMessageID, logicalMailboxID: logical)
                    let attachments = try await download(message.attachments, logical: logical)
                    try store.completeMirrorHydration(
                        messageID: item.messageID, scope: scope,
                        textBody: message.textBody.state == .complete ? message.textBody.value : nil,
                        htmlBody: message.htmlBody.state == .complete ? message.htmlBody.value : nil,
                        attachments: attachments
                    )
                    hydrated += 1
                } catch let error where Self.isMessageLevelFailure(error) {
                    try store.failMirrorHydration(messageID: item.messageID, scope: scope, now: now(), jitter: jitter())
                }
            }
        }
        if hydrated > 0 { MailStoreChangeSignal.post(scope: .mailbox) }
        return hydrated
    }

    /// Payloads within the per-attachment and aggregate bounds; an attachment
    /// beyond them keeps only its metadata and is fetched on demand.
    private func download(_ attachments: [NodeSyncAttachment], logical: LogicalMailboxID) async throws -> [IncomingMessageAttachmentPayload] {
        var payloads: [IncomingMessageAttachmentPayload] = []
        var total = 0
        for (index, attachment) in attachments.prefix(limits.attachmentCount).enumerated() {
            guard let size = Int(attachment.size), size <= limits.attachmentBytes,
                  size <= limits.aggregateAttachmentBytes - total else { continue }
            let download = try await client.mailAttachment(id: attachment.id, logicalMailboxID: logical)
            var data = Data()
            do {
                for try await chunk in download.bytes {
                    guard chunk.count <= size - data.count else { throw NodeSyncClientError.invalidResponse }
                    data.append(chunk)
                }
            } catch {
                download.bytes.cancel()
                throw error
            }
            guard data.count == size else { throw NodeSyncClientError.invalidResponse }
            total += size
            payloads.append(IncomingMessageAttachmentPayload(partPath: String(index + 1), filename: attachment.filename,
                                                             mimeType: attachment.mime, data: data))
        }
        return payloads
    }

    /// Failures of one message that a later pass retries without stopping
    /// the others. Transport, admission and store errors stop the pass.
    private static func isMessageLevelFailure(_ error: Error) -> Bool {
        switch error {
        case NodeSyncClientError.notFound, NodeSyncClientError.invalidResponse, NodeSyncClientError.conflict,
             NodeSyncClientError.problem(.invalidRequest), NodeMailModeStoreError.invalidMirrorPayload:
            return true
        default:
            return false
        }
    }

    // MARK: - Seeding

    private func seed(accountID: AccountID, logicalMailboxID: String) async throws {
        try store.requireNodeMirrorSchema()
        let logical = try NodeMailMirrorMapping.logicalMailboxID(logicalMailboxID)
        let scope = NodeMirrorScope(accountID: accountID, nodeID: nodeID,
                                    logicalMailboxID: try NodeMailMirrorMapping.logicalMailboxKey(logical))
        try store.seedNodeMirrorAccount(scope)
        if let cursor = try store.nodeMirrorCursor(nodeID: nodeID) {
            if cursor.complete {
                try store.saveNodeMirrorCursor(NodeMirrorCursor(nodeID: nodeID, deltaCursor: cursor.deltaCursor,
                                                                revision: cursor.revision, complete: false),
                                               expected: cursor)
            }
        } else {
            _ = try await captureCursor()
        }
    }

    private static func freshBootstrap(_ scope: NodeMirrorScope) -> NodeMirrorAccountBootstrap {
        NodeMirrorAccountBootstrap(accountID: scope.accountID, nodeID: scope.nodeID, logicalMailboxID: scope.logicalMailboxID,
                                   snapshotCursor: "", complete: false)
    }
}

/// A FIFO async lane: one body at a time, in arrival order.
actor MirrorLane {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
