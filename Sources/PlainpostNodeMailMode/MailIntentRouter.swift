import CryptoKit
import Foundation
import OSLog
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport

/// What the caller learns about one mail change.
public enum MailIntentDispatchOutcome: Equatable, Sendable {
    /// The Node applied it, or the direct provider write succeeded.
    case confirmed
    /// The Node admitted it and has not finished, or the Node could not be
    /// reached yet and the intent is still unrouted (`pending`).
    case waitingForNode
    /// It may have taken effect: the acknowledgement was lost after dispatch,
    /// the Node reported `delivery_uncertain`, or a direct write ended
    /// ambiguously. Never resent automatically.
    case uncertain
    /// An authoritative refusal before any provider effect (or a Node
    /// `rejected`/`conflicted` receipt). Only an explicit user action resends.
    case failed(String)
}

/// The service's existing direct provider paths. An implementation throws
/// `DirectMailDispatchRefusal` only for a failure that provably happened
/// before the provider could act; every other error is an ambiguous outcome
/// and the intent is never recorded `failed` for it.
public protocol DirectMailDispatching: Sendable {   // implemented by the service's existing direct code paths
    /// `archiveMailbox` is the destination journaled with an archive intent.
    func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws
    func saveDraft(_ draft: Draft) async throws
    /// Delivers `draft` only while its content still has the hash the user
    /// approved; a changed draft is refused before any provider effect.
    func send(_ draft: Draft, approvedContentHash: String) async throws
}

/// A direct write refused before any provider effect.
public struct DirectMailDispatchRefusal: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// A direct write that provably never reached the provider for a passing
/// reason (the vault locked, the service runtime closed, the account left
/// fallback): the intent returns to `pending`, never `failed`, and a later
/// pass dispatches it by the account's mode then.
public struct DirectMailDispatchDeferral: Error, Equatable, Sendable {
    /// The cause, one sentence ("Plainpost couldn't reach your mail server.").
    public let reason: String
    /// A transient deferral's cause, from a closed set: the only reason the
    /// journal stores (never provider text).
    public let code: DirectDeferralReason?
    /// A network or temporary sign-in failure: the row is retried with
    /// back-off and fails (nothing was sent) after
    /// `MailIntentRouter.directDeferralLimit` attempts or
    /// `directDeferralWindow` in one run. A passing deferral (locked, back in
    /// node mode) does none of that.
    public var transient: Bool { code != nil }
    /// A passing deferral (locked, back in node mode).
    public init(reason: String) {
        self.reason = reason
        self.code = nil
    }
    /// A transient deferral.
    public init(transient code: DirectDeferralReason) {
        self.reason = code.message
        self.code = code
    }
}

public enum MailIntentRouterError: Error, Equatable, Sendable {
    /// Direct accounts never reach the router or the journal.
    case notNodeBacked
    /// The account is Node-backed but the intent journal is absent: the
    /// change cannot be routed, and it never falls back to direct.
    case journalUnavailable
    /// The Node session is admitted by its offline lease only (read-only).
    /// The intent is recorded `failed`; it is never queued to run later.
    case readOnly
    /// A send of this draft is already queued, in flight or done.
    case sendInProgress
    case invalidIntent
}

/// One routed intent: its journal identity, route and state after dispatch.
public struct MailIntentDispatch: Equatable, Sendable {
    public let operationID: String
    public let route: MailIntentRoute?
    public let state: MailIntentState
    public let outcome: MailIntentDispatchOutcome
    /// Why a row is waiting, when it was deferred ("Plainpost couldn't reach
    /// your mail server. It will retry.").
    public let detail: String?

    public init(operationID: String, route: MailIntentRoute?, state: MailIntentState, outcome: MailIntentDispatchOutcome,
                detail: String? = nil) {
        self.operationID = operationID
        self.route = route
        self.state = state
        self.outcome = outcome
        self.detail = detail
    }
}

/// Routes Node-backed accounts' mail changes to the Sync Node or, in
/// fallback, to the provider directly. It runs only inside `PlainpostService`
/// (the single dispatcher). Every change is journaled before any network
/// call; the operation ID is the Node idempotency key.
///
/// - Once a change is journaled, the router never reports a failure for a
///   row that stays dispatchable: a row-specific problem (its draft or
///   message is gone, the draft changed since the user approved the send)
///   refuses the row, and a transient error leaves it `pending`.
/// - A Node dispatch signs the operation first, then fixes the route and
///   stores the exact signed bytes (`beginMailIntentDispatch`), then sends
///   them. `admitted` and `uncertain` intents settle by replaying those
///   stored bytes, also after a restart; they are never re-encoded.
/// - A `409` is answered by replaying the exact bytes once; if the key stays
///   bound to other bytes the intent is `uncertain`, never `failed`. Only a
///   `conflicted` receipt of a never-admitted intent whose authority epoch
///   has since moved is re-signed, once, under a new key.
/// - Spec amendment (Task 16 review): an `uncertain` intent becomes `failed`
///   only when its exact replay answers `rejected`, and `unconfirmed` when it
///   answers `conflicted`.
/// - Before dispatching, the session's retained mutation receipt is settled
///   and attached to its own intent; it never fails the new change.
/// - `admitted`/`uncertain` Node intents are never dispatched directly, and
///   an ambiguous direct outcome stays `dispatching(direct)`.
private let routerLogger = Logger(subsystem: "com.marynavdovenko.Plainpost", category: "mail-intent-router")

public actor MailIntentRouter {
    /// Builds an encoder for one reachable client. An encoder is never kept
    /// across dispatches, so none outlives a transport rebuild or an epoch
    /// change (its draft cache is safe to lose).
    public typealias EncoderFactory = @Sendable (NodeSyncClient) -> NodeMailMutationEncoder

    public static let unsyncedMessage = "Message isn't synced with the Sync Node yet."
    public static let readOnlyMessage = "This Mac can only read mail from the Sync Node right now."
    public static let draftChangedMessage = "The draft changed after it was sent. Review it and send it again."
    /// A send whose draft could not be saved on the Sync Node never left.
    public static let sendNeverLeftMessage = "This message wasn't sent: the Sync Node couldn't save its draft. It's still in Drafts."
    static let refusedMessage = MailIntentRouterRefusal.genericMessage
    /// A change waiting behind an older one to the same message or draft.
    public static let waitingForEarlierChangeMessage = "Waiting for an earlier change to this message."

    /// A transient error may keep the oldest pending row from dispatching.
    /// After this many passes, or this long, it stops holding back the rows
    /// behind it (it is never failed for it).
    static let headStallPassLimit = 5
    static let headStallWindow: TimeInterval = 600

    /// A row deferred for a transient reason fails after this many attempts
    /// or this long (nothing was sent, so `failed` is safe and the user is
    /// told).
    static let directDeferralLimit = 10
    static let directDeferralWindow: TimeInterval = 1_800
    /// A longer gap since the last transient deferral (twice the longest
    /// back-off: the Mac slept, the vault was locked, or the account was in
    /// Node mode) starts a new run: its attempts and window restart.
    static let directDeferralRestartGap: TimeInterval = 600
    /// A direct-deferred row this old (since it was journaled) fails at its
    /// next transient deferral, whatever its run: retries across many sleep
    /// cycles are bounded too.
    static let directDeferralMaxAge: TimeInterval = 86_400

    /// Back-off before the next attempt of a transiently deferred row.
    public static func directDeferralBackoff(attempt: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(attempt, 1) - 1)), 300)
    }

    /// Scheduling metadata belongs to this invocation across actor reentrancy.
    /// The public dispatch and durable journal states remain unchanged.
    private struct DispatchResult {
        enum PendingReason { case targetBlocked, transient, unavailable }
        let dispatch: MailIntentDispatch
        let pendingReason: PendingReason?

        init(_ dispatch: MailIntentDispatch, pendingReason: PendingReason = .unavailable) {
            self.dispatch = dispatch
            self.pendingReason = dispatch.state == .pending ? pendingReason : nil
        }
    }

    private enum EncodeResult {
        case bytes(Data)
        case unreachable
        case refused(String)
        case readOnly
    }

    private enum NodeAnswer {
        case state(String)
        case conflict
        case refused(String)
        case ambiguous
    }

    /// What a re-sign encodes and how the new key and bytes are journaled.
    private enum SignTarget {
        case mutation(MailMutationIntent, storesOperation: Bool)
        case save(Draft, isSend: Bool)
        case send(Draft, revision: String)
    }

    private struct DraftChanged: Error {}
    /// The draft cannot be rendered (for example it has no recipients).
    private struct DraftUnrenderable: Error { let message: String }

    private let store: SQLiteMailStore
    private let makeEncoder: EncoderFactory
    private let direct: any DirectMailDispatching
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Checked immediately before each direct dispatch begins: false while
    /// the service runtime is closed (the vault is locked).
    private let directDispatchAllowed: @Sendable () async -> Bool
    private let directDeferralBackoff: @Sendable (Int) -> TimeInterval
    private let processStartedAt: Date
    private let pendingSaveReplays: Int
    private var needsRecovery: Bool
    private var sessions: (any NodeMailSessionProviding)?
    /// Exact draft-save bytes this process posted, by operation ID. Process
    /// memory only: they carry the message body, which the journal never
    /// stores. After a restart a save stage is redone under a fresh key.
    private var inflightSaves: [String: Data] = [:]
    /// Sends whose save was applied but whose own operation is not stored
    /// yet: the revision to sign the send at (also journaled).
    private var appliedSaves: [String: String] = [:]
    private var headStalls: [String: (passes: Int, since: Date)] = [:]
    /// Operation IDs this router is dispatching or settling right now. The
    /// actor is re-entrant at every await, so a second caller for the same
    /// row (a concurrent settle pass, a queue drain) only reports the row.
    private var rowsInFlight: Set<String> = []
    /// Targets ("message:…", "draft:…") whose change this router has begun
    /// dispatching and whose outcome is not recorded yet, with the row that
    /// holds each. A newer change to a held target waits (stays `pending`).
    private var targetHolders: [String: String] = [:]
    /// Node rows the Node definitely answered for in this process (so their
    /// bytes reached it), by operation ID: true while it still holds them
    /// `pending`. Process memory only: after a restart they are replayed.
    private var nodeAnswers: [String: Bool] = [:]
    /// Direct rows whose failure after their deferrals could be written
    /// neither as `failed` nor back to `pending` (a busy database): each
    /// drain of the account tries the failure again.
    private var strandedDeferralFailures: [String: (accountID: AccountID, reason: DirectDeferralReason)] = [:]
    private var singleFlight = true
    /// Tests only: runs before every begin-dispatch write.
    private var beginFailpoint: (@Sendable (String) throws -> Void)?
    /// Tests only: runs before the write that fails a row after its deferrals.
    private var failAfterDeferralsFailpoint: (@Sendable (FailAfterDeferralsStep) throws -> Void)?
    /// Tests only: runs before the same-target ordering read.
    private var orderingReadFailpoint: (@Sendable () throws -> Void)?

    /// - Parameters:
    ///   - processStartedAt: the service process start. Before its first
    ///     dispatch the router moves `dispatching(node)` intents written
    ///     before it to `uncertain` (`recoverInterruptedMailIntentDispatches`).
    ///   - recoveredInterruptedDispatches: true when the composition already
    ///     ran that recovery at service start.
    public init(
        store: SQLiteMailStore,
        encoders: @escaping EncoderFactory = { NodeMailMutationEncoder(client: $0) },
        direct: any DirectMailDispatching,
        now: @escaping @Sendable () -> Date = Date.init,
        processStartedAt: Date? = nil,
        recoveredInterruptedDispatches: Bool = false,
        pendingSaveReplays: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        directDispatchAllowed: @escaping @Sendable () async -> Bool = { true },
        directDeferralBackoff: @escaping @Sendable (Int) -> TimeInterval = MailIntentRouter.directDeferralBackoff(attempt:)
    ) {
        self.directDispatchAllowed = directDispatchAllowed
        self.directDeferralBackoff = directDeferralBackoff
        self.store = store
        self.makeEncoder = encoders
        self.direct = direct
        self.now = now
        self.sleep = sleep
        self.processStartedAt = processStartedAt ?? now()
        self.pendingSaveReplays = max(0, pendingSaveReplays)
        self.needsRecovery = !recoveredInterruptedDispatches
    }

    /// Late binding breaks the router ↔ supervisor construction cycle: composition calls this with the supervisor before
    /// `NodeReachabilitySupervisor.start()`. Until attached, every Node-mode client lookup is treated as unreachable.
    public func attach(sessions: any NodeMailSessionProviding) {
        self.sessions = sessions
    }

    /// True while this router is dispatching or settling the row (it may
    /// be on the wire right now). A `dispatching(direct)` row nobody holds
    /// ended ambiguously, or was left by an earlier process.
    public func isHolding(operationID: String) -> Bool {
        rowsInFlight.contains(operationID)
    }

    func setBeginFailpoint(_ failpoint: (@Sendable (String) throws -> Void)?) {
        beginFailpoint = failpoint
    }

    /// The writes `failAfterDeferrals` makes, for its test failpoint.
    enum FailAfterDeferralsStep: Sendable { case fail, revert }

    func setFailAfterDeferralsFailpoint(_ failpoint: (@Sendable (FailAfterDeferralsStep) throws -> Void)?) {
        failAfterDeferralsFailpoint = failpoint
    }

    func setOrderingReadFailpoint(_ failpoint: (@Sendable () throws -> Void)?) {
        orderingReadFailpoint = failpoint
    }

    /// Tests only: lets two passes work on one row at once, to prove the
    /// journal alone never fails a send whose bytes were stored.
    func disableSingleFlightForTesting() {
        singleFlight = false
    }

    private func claimRow(_ operationID: String) -> Bool {
        guard singleFlight else { return true }
        return rowsInFlight.insert(operationID).inserted
    }

    private func releaseRow(_ operationID: String) {
        guard singleFlight else { return }
        rowsInFlight.remove(operationID)
    }

    /// Tests only: forgets the save stage this process holds, as a restart does.
    func forgetProcessMemory() {
        inflightSaves.removeAll()
        appliedSaves.removeAll()
    }

    // MARK: - User changes

    public func perform(_ action: MailIntentKind, messageID: MessageID) async throws -> MailIntentDispatchOutcome {
        try await performIntent(action, messageID: messageID).outcome
    }

    public func saveDraft(_ draft: Draft) async throws -> MailIntentDispatchOutcome {
        try await saveDraftIntent(draft).outcome
    }

    public func send(_ draft: Draft) async throws -> MailIntentDispatchOutcome {
        try await sendIntent(draft).outcome
    }

    /// `operationID` defaults to a new lower-case UUID. A caller that may
    /// retry the same change (a durable job) passes a stable ID; the journal
    /// then returns the existing intent instead of adding a second one.
    /// `archiveMailbox` is journaled with an archive and used by its direct
    /// dispatch.
    public func performIntent(
        _ action: MailIntentKind, messageID: MessageID, archiveMailbox: String? = nil, operationID: String? = nil
    ) async throws -> MailIntentDispatch {
        guard action.targetsMessage, MailIntentRecord.hasValidFolder(kind: action, folder: archiveMailbox) else {
            throw MailIntentRouterError.invalidIntent
        }
        guard let accountID = store.accountID(forMessageID: messageID) else {
            throw PlainpostError.notFound("Message not found.")
        }
        return try await journalAndDispatch(
            accountID: accountID, kind: action, messageID: messageID, draft: nil,
            contentHash: nil, archiveMailbox: archiveMailbox, operationID: operationID
        )
    }

    public func saveDraftIntent(_ draft: Draft, operationID: String? = nil) async throws -> MailIntentDispatch {
        try await journalAndDispatch(accountID: draft.accountID, kind: .saveDraft, messageID: nil, draft: draft,
                                     contentHash: nil, archiveMailbox: nil, operationID: operationID)
    }

    /// Send = the draft save then the send, under one journal row; the row
    /// becomes `admitted` only when the Node admits the send itself. The
    /// approved content hash is journaled; every dispatch sends only that
    /// content, and the send is signed at the revision the approved save
    /// produced. A draft with a send queued, in flight or done is locked
    /// (`sendInProgress`).
    public func sendIntent(_ draft: Draft, approvedContentHash: String? = nil, operationID: String? = nil) async throws -> MailIntentDispatch {
        try await journalAndDispatch(accountID: draft.accountID, kind: .send, messageID: nil, draft: draft,
                                     contentHash: approvedContentHash ?? draft.contentHash, archiveMailbox: nil,
                                     operationID: operationID)
    }

    // MARK: - Account-level passes

    /// Settles the account's `admitted` and `uncertain` Node intents: a stored
    /// operation is replayed with its exact bytes; a draft-save stage (whose
    /// bytes are never stored) is replayed from this process's memory or,
    /// after a restart, redone under a fresh key, then its send follows.
    public func settleAdmittedIntents(accountID: AccountID) async {
        guard ensureRecovered(),
              let source = try? store.mailSource(accountID: accountID),
              source.kind == .nodeBacked,
              let nodeID = source.nodeID,
              let logical = source.logicalMailboxID.flatMap({ try? NodeSyncCodec.decodeLogicalMailboxID($0) }),
              let client = await sessions?.reachableClient(nodeID: nodeID),
              await settleRetainedReceipt(client),
              let records = try? store.mailIntents(accountID: accountID, states: [.admitted, .uncertain])
        else { return }
        for listed in records where listed.route == .node {
            // An earlier receipt in this pass may already have settled it.
            guard claimRow(listed.operationID) else { continue }
            defer { releaseRow(listed.operationID) }
            guard let record = try? store.mailIntent(operationID: listed.operationID),
                  record.state == .admitted || record.state == .uncertain,
                  let stored = try? store.mailIntentCanonicalOperation(operationID: record.operationID) as Data??
            else { continue }
            if let bytes = stored {
                // Only to the Node and logical mailbox it was signed for.
                guard Self.signedFor(bytes, nodeID: nodeID, logical: logical) else { continue }
                _ = resolve(record, answer: await post(bytes, key: record.idempotencyKey, client: client))
            } else if record.kind == .send || record.kind == .saveDraft {
                await resumeSave(record, client: client, logical: logical)
            }
        }
    }

    /// Reconnect: the account's unstarted intents (route-nil `pending`, not
    /// `credential_push`), which the next `dispatchPending` sends through
    /// the Node. Their route is fixed only when that dispatch begins, so
    /// nothing is written here. A read error propagates.
    public func rerouteUnstartedDirectIntents(accountID: AccountID) async throws -> Int {
        try store.rerouteUnstartedDirectIntents(accountID: accountID, now: now()).count
    }

    /// Dispatches `pending` mail intents (every kind except `credential_push`) for the account according to its current mode,
    /// always through MailIntentGuard. `credential_push` rows are owned by `NodeMailLifecycleCoordinator` (Task 21) and skipped.
    /// A row-specific refusal never blocks the queue. The pass stops at the
    /// first intent that stays pending: the Node is unreachable, the session
    /// is read-only for now, a direct dispatch was deferred, or a transient
    /// error (bounded: a head row stuck on transient errors stops holding
    /// back later rows after `headStallPassLimit` passes or
    /// `headStallWindow`, and is not failed).
    ///
    /// A direct deferral is not counted toward that stall bound. It ends the
    /// pass (one failing provider attempt per pass while the server is down)
    /// and then backs off: until its next attempt time later passes skip it,
    /// with its target, and dispatch the rows behind it. The back-off, not
    /// the stall bound, is what keeps other targets moving.
    public func dispatchPending(accountID: AccountID) async {
        guard ensureRecovered() else { return }
        retryStrandedDeferralFailures(accountID: accountID)
        guard let records = try? store.mailIntents(accountID: accountID, states: [.pending]) else { return }
        // Targets (a message or a draft) of rows skipped as stuck: a later
        // change to the same target never overtakes them.
        var blockedTargets: Set<String> = []
        for record in records where record.kind != .credentialPush && record.route == nil {
            // Shutdown: never start another dispatch.
            if Task.isCancelled { return }
            let targets = Self.targets(record)
            guard blockedTargets.isDisjoint(with: targets) else {
                blockedTargets.formUnion(targets)
                continue
            }
            // Backing off after a transient deferral: skip it (and later
            // changes to its target) without holding the others back. Only a
            // direct dispatch waits: in Node mode the row goes to the Node now.
            if isBackingOff(record) {
                blockedTargets.formUnion(targets)
                continue
            }
            guard let result = try? await dispatchGuarded(record, draft: nil, interactive: false) else { continue }
            guard result.dispatch.state == .pending else {
                headStalls[record.operationID] = nil
                continue
            }
            // Behind an earlier change to its target (on the wire right
            // now): the target waits, the others go on.
            if result.pendingReason == .targetBlocked {
                blockedTargets.formUnion(targets)
                continue
            }
            guard result.pendingReason == .transient else {
                headStalls[record.operationID] = nil
                return
            }
            let stall = headStalls[record.operationID] ?? (0, now())
            let next = (passes: stall.passes + 1, since: stall.since)
            headStalls[record.operationID] = next
            if next.passes < Self.headStallPassLimit && now().timeIntervalSince(next.since) < Self.headStallWindow { return }
            blockedTargets.formUnion(targets)
        }
    }

    /// A row whose next direct attempt is not due, while its account would
    /// dispatch it directly.
    private func isBackingOff(_ record: MailIntentRecord) -> Bool {
        guard let next = record.nextAttemptAt, next > now() else { return false }
        guard let source = try? store.mailSource(accountID: record.accountID) else { return true }
        return !(source.kind == .nodeBacked && source.mode == .node)
    }

    /// A stable lower-case UUID derived from `seed` (for example a durable
    /// job ID), so a retried caller journals the same intent again.
    public static func operationID(derivedFrom seed: String) -> String {
        MailIntentRecord.operationID(derivedFrom: seed)
    }

    private static func targets(_ record: MailIntentRecord) -> Set<String> {
        var targets: Set<String> = []
        if let messageID = record.messageID { targets.insert("message:" + messageID.rawValue) }
        if let draftID = record.draftID { targets.insert("draft:" + draftID.rawValue) }
        return targets
    }

    static func saveKey(for operationID: String) -> String {
        Self.operationID(derivedFrom: "plainpost.mail-intent.save-before-send\u{0}" + operationID)
    }

    /// A fresh key derived from the current one: a stale-epoch re-sign of a
    /// never-admitted intent, or a redone draft save. The old key stays bound
    /// on the Node.
    static func rekey(_ key: String) -> String {
        Self.operationID(derivedFrom: "plainpost.mail-intent.rekey\u{0}" + key)
    }

    // MARK: - Journal and route

    private func journalAndDispatch(
        accountID: AccountID, kind: MailIntentKind, messageID: MessageID?, draft: Draft?,
        contentHash: String?, archiveMailbox: String?, operationID: String?
    ) async throws -> MailIntentDispatch {
        // Source first: a Direct account never touches the journal.
        let source = try store.mailSource(accountID: accountID)
        guard source.kind == .nodeBacked else { throw MailIntentRouterError.notNodeBacked }
        let operationID = operationID ?? UUID().uuidString.lowercased()
        if kind == .send, let draftID = draft?.id, try store.mailIntent(operationID: operationID) == nil,
           try store.mailIntentSendInFlight(draftID: draftID) {
            throw MailIntentRouterError.sendInProgress
        }
        let record: MailIntentRecord
        do {
            record = try store.journalMailIntent(
                operationID: operationID, accountID: accountID, kind: kind,
                messageID: messageID, draftID: draft?.id, contentHash: contentHash, archiveMailbox: archiveMailbox,
                now: now()
            )
        } catch NodeMailModeStoreError.schemaUnavailable {
            throw MailIntentRouterError.journalUnavailable
        }
        postChange()
        // The session's admission, read locally at journal time (no Node
        // needed): a change made while the session is read-only is refused
        // now, even when the Node cannot be reached or recovery fails, so it
        // is never queued to be sent later.
        if record.state == .pending, record.route == nil, source.mode == .node, let nodeID = source.nodeID,
           case .readOnly? = await sessions?.sessionAdmission(nodeID: nodeID) {
            _ = refuse(record, message: Self.readOnlyMessage)
            markReported(record.operationID)
            throw MailIntentRouterError.readOnly
        }
        // A retried caller (a durable job) reusing the operation ID of a row
        // that is backing off does not spend an attempt early.
        if record.state == .pending, record.route == nil, isBackingOff(record) {
            return waiting(record, detail: record.deferralReason.map { $0.message + " It will retry." })
        }
        // From here on the row exists: only a read-only refusal of this
        // interactive change (which fails the row) is thrown; everything
        // else is the row's own state. Same-target ordering is checked in
        // the dispatch itself, right before the route is fixed and after
        // the read-only check, so a change made while read-only is always
        // refused, never queued behind an older one.
        let result: MailIntentDispatch
        do {
            result = try await dispatchGuarded(record, draft: draft, interactive: true).dispatch
        } catch {
            markReported(record.operationID)
            throw error
        }
        // A terminal outcome returned to this caller is reported by it: no
        // later notice repeats it.
        if [.confirmed, .failed, .unconfirmed, .unconfirmedAfterRemoval].contains(result.state) {
            markReported(record.operationID)
        }
        return result
    }

    private func waiting(_ record: MailIntentRecord, detail: String?) -> MailIntentDispatch {
        let waiting = describe(record)
        return MailIntentDispatch(operationID: waiting.operationID, route: waiting.route, state: waiting.state,
                                  outcome: waiting.outcome, detail: detail)
    }

    private func markReported(_ operationID: String) {
        try? store.markMailIntentReported(operationID: operationID)
    }

    /// `interactive` is the user's own change: under a read-only session it
    /// is refused with a typed error. A queue drain leaves the row pending
    /// instead, because read-only is a passing session state.
    private func dispatchGuarded(_ record: MailIntentRecord, draft: Draft?, interactive: Bool) async throws -> DispatchResult {
        do {
            return try await dispatch(record, draft: draft, interactive: interactive)
        } catch MailIntentRouterError.readOnly {
            throw MailIntentRouterError.readOnly
        } catch {
            if let message = Self.rowRefusal(error) { return DispatchResult(refuse(record, message: message)) }
            // Transient (a busy or unreadable store, …): the row stays
            // dispatchable and a later pass sends it.
            return DispatchResult((try? describeCurrent(record)) ?? describe(record), pendingReason: .transient)
        }
    }

    /// Problems of this row that no retry fixes. Anything else is transient.
    /// `permissionDenied` is transient here and in `classifyEncodeFailure`
    /// alike (an authority awaiting status confirmation).
    private static func rowRefusal(_ error: Error) -> String? {
        switch error {
        case is DraftChanged:
            return draftChangedMessage
        case let error as DraftUnrenderable:
            return error.message
        case let error as PlainpostError:
            switch error {
            case let .notFound(message): return message
            case .validationFailed, .permissionDenied: return nil
            }
        case NodeMailModeStoreError.messageIdentityMismatch:
            return "This message changed on the server. Try again after the next sync."
        case NodeMailModeStoreError.invalidMailIntent, MailIntentRouterError.invalidIntent:
            return "This change can't be sent."
        case is DraftOptimisticUpdateError:
            return draftChangedMessage
        default:
            return nil
        }
    }

    private func dispatch(_ record: MailIntentRecord, draft: Draft?, interactive: Bool) async throws -> DispatchResult {
        guard record.kind != .credentialPush, record.state == .pending, record.route == nil else { return DispatchResult(describe(record)) }
        guard claimRow(record.operationID) else { return DispatchResult(try describeCurrent(record)) }
        defer {
            releaseTargets(of: record.operationID)
            releaseRow(record.operationID)
        }
        guard ensureRecovered() else { return DispatchResult(describe(record)) }
        let source = try store.mailSource(accountID: record.accountID)
        if source.kind == .nodeBacked, source.mode == .node {
            return try await dispatchNode(record, source: source, draft: draft, interactive: interactive)
        }
        return try await dispatchDirect(record, draft: draft, source: source)
    }

    // MARK: - Same-target ordering

    /// Called right before a dispatch fixes its route (after the read-only
    /// check, with no suspension point before `begin`). Returns a waiting
    /// result when the change must not start yet; otherwise the row now
    /// holds its targets until `dispatch` returns with its outcome recorded.
    ///
    /// The rule: a newer change to a message or draft never starts while an
    /// older change to the same target
    /// - is still `pending` (unrouted);
    /// - has begun in this router with no recorded outcome (its request may
    ///   be on the wire; the actor re-enters during it); or
    /// - is an `admitted` or `uncertain` Node row with stored bytes (signed
    ///   for the account's Node) whose arrival at the Node this process has
    ///   not seen. `uncertain` does not prove the bytes left: the process
    ///   may have died between `begin` and the transport's reservation, or
    ///   the lane was cancelled or refused before dispatch, and nothing was
    ///   retained. A later settle would replay them after the newer change
    ///   and reverse the order. So a Node dispatch first replays them
    ///   exactly (`replayOlderNodeChanges`): an answer means they reached
    ///   the Node, which orders by arrival, and the newer change may follow.
    ///   Without an answer the newer change waits. A direct change also
    ///   waits while such a row is still `pending` on the Node (the Node may
    ///   apply it after the provider write); it cannot replay in fallback.
    ///
    /// Rows that do not block: a Node row the Node answered (in Node mode),
    /// a terminal row, and an ambiguous `dispatching(direct)` row, which is
    /// never resent. Waiting never suspends: the row stays `pending` and a
    /// later drain sends it, so nothing deadlocks. A read error propagates
    /// (the row stays pending and is retried): it never lets the change
    /// overtake.
    private func waitsForEarlierChange(
        _ record: MailIntentRecord, route: MailIntentRoute, source: AccountMailSource
    ) throws -> DispatchResult? {
        let targets = Self.targets(record)
        if targets.contains(where: { targetHolders[$0].map { $0 != record.operationID } ?? false }) {
            return DispatchResult(waiting(record, detail: Self.waitingForEarlierChangeMessage), pendingReason: .targetBlocked)
        }
        try orderingReadFailpoint?()
        if let older = try store.olderPendingIntent(sharingTargetWith: record.operationID) {
            // Its reason only while it is actually backing off.
            let reason = isBackingOff(older) ? older.deferralReason.map { $0.message + " It will retry." } : nil
            return DispatchResult(waiting(record, detail: reason ?? Self.waitingForEarlierChangeMessage), pendingReason: .targetBlocked)
        }
        for (older, _) in try olderNodeChanges(record, source: source) {
            let answered = nodeAnswers[older.operationID]
            if answered == nil || (answered == true && route == .direct) {
                return DispatchResult(waiting(record, detail: Self.waitingForEarlierChangeMessage), pendingReason: .targetBlocked)
            }
        }
        for target in targets { targetHolders[target] = record.operationID }
        return nil
    }

    /// Older `admitted` or `uncertain` Node changes to the record's targets
    /// with stored bytes signed for the account's Node and logical mailbox
    /// (bytes signed for another Node cannot be ordered here).
    private func olderNodeChanges(
        _ record: MailIntentRecord, source: AccountMailSource
    ) throws -> [(MailIntentRecord, Data)] {
        guard let nodeID = source.nodeID,
              let logical = source.logicalMailboxID.flatMap({ try? NodeSyncCodec.decodeLogicalMailboxID($0) })
        else { return [] }
        let targets = Self.targets(record)
        return try store.mailIntents(accountID: record.accountID, states: [.admitted, .uncertain]).compactMap { row in
            guard row.route == .node, row.operationID != record.operationID, Self.drainsBefore(row, record),
                  !Self.targets(row).isDisjoint(with: targets),
                  let bytes = try store.mailIntentCanonicalOperation(operationID: row.operationID),
                  Self.signedFor(bytes, nodeID: nodeID, logical: logical)
            else { return nil }
            return (row, bytes)
        }
    }

    private static func drainsBefore(_ lhs: MailIntentRecord, _ rhs: MailIntentRecord) -> Bool {
        lhs.createdAt < rhs.createdAt || (lhs.createdAt == rhs.createdAt && lhs.operationID < rhs.operationID)
    }

    /// Replays, with their exact bytes, the older Node changes to the
    /// record's targets whose arrival this process has not seen, before the
    /// newer change is signed off: the first arrival fixes a change's order
    /// on the Node, so they land first. An answer is recorded like a settle
    /// (`resolve`); a replay without one leaves the newer change waiting.
    private func replayOlderNodeChanges(_ record: MailIntentRecord, source: AccountMailSource, client: NodeSyncClient) async throws {
        for (older, bytes) in try olderNodeChanges(record, source: source) where nodeAnswers[older.operationID] == nil {
            guard claimRow(older.operationID) else { continue }
            defer { releaseRow(older.operationID) }
            guard let current = try store.mailIntent(operationID: older.operationID),
                  current.state == .admitted || current.state == .uncertain
            else { continue }
            _ = resolve(current, answer: await post(bytes, key: current.idempotencyKey, client: client))
        }
    }

    private func releaseTargets(of operationID: String) {
        targetHolders = targetHolders.filter { $0.value != operationID }
    }

    /// The draft a send delivers: re-read from the store and refused unless
    /// its content still has the journaled, approved hash.
    private func approvedDraft(_ record: MailIntentRecord) throws -> Draft {
        guard let approved = record.contentHash else { throw MailIntentRouterError.invalidIntent }
        let current = try loadDraft(record)
        guard current.contentHash == approved else { throw DraftChanged() }
        return try Self.renderable(current)
    }

    /// A draft that cannot be rendered is a row refusal, never "the Node is
    /// unreachable": no retry fixes it.
    private static func renderable(_ draft: Draft) throws -> Draft {
        do {
            _ = try DraftRenderer().render(draft)
            return draft
        } catch let error as PlainpostError {
            switch error {
            case let .validationFailed(message), let .notFound(message), let .permissionDenied(message):
                throw DraftUnrenderable(message: message)
            }
        }
    }

    // MARK: - Direct (fallback)

    private func dispatchDirect(_ record: MailIntentRecord, draft: Draft?, source: AccountMailSource) async throws -> DispatchResult {
        guard MailIntentGuard.mayDispatchDirect(record) else { return DispatchResult(describe(record)) }
        var payload: Draft?
        switch record.kind {
        case .send: payload = try approvedDraft(record)
        case .saveDraft: payload = try draft ?? loadDraft(record)
        default: break
        }
        // The vault gate, re-read right before the route is fixed: a lock
        // during a drain leaves the remaining rows pending.
        guard !Task.isCancelled, await directDispatchAllowed() else { return DispatchResult(describe(record)) }
        if let waiting = try waitsForEarlierChange(record, route: .direct, source: source) { return waiting }
        guard let begun = try begin(record, route: .direct) else { return DispatchResult(try describeCurrent(record)) }
        do {
            switch begun.kind {
            case .markRead, .markUnread, .archive, .delete, .flag, .unflag, .move:
                guard let messageID = begun.messageID else { throw MailIntentRouterError.invalidIntent }
                try await direct.perform(begun.kind, messageID: messageID, archiveMailbox: begun.archiveMailbox)
            case .saveDraft:
                guard let payload else { throw MailIntentRouterError.invalidIntent }
                try await direct.saveDraft(payload)
            case .send:
                guard let payload, let approved = begun.contentHash else { throw MailIntentRouterError.invalidIntent }
                try await direct.send(payload, approvedContentHash: approved)
            case .credentialPush:
                throw MailIntentRouterError.invalidIntent
            }
        } catch let deferral as DirectMailDispatchDeferral {
            // Provably before any provider effect: back to pending.
            var run: TransientDirectDeferral?
            if let code = deferral.code {
                let at = now()
                // A long gap between when the row was due and this attempt
                // (not a back-off: sleep, a locked vault, node mode) starts a
                // new run.
                let continuing = begun.deferralDueAt.map { at.timeIntervalSince($0) <= Self.directDeferralRestartGap } ?? false
                let attempts = (continuing ? begun.deferralCount : 0) + 1
                let started = continuing ? (begun.firstDeferredAt ?? at) : at
                if attempts >= Self.directDeferralLimit || at.timeIntervalSince(started) >= Self.directDeferralWindow
                    || at.timeIntervalSince(begun.createdAt) >= Self.directDeferralMaxAge {
                    // Nothing was sent: fail it, so the user hears of it.
                    return DispatchResult(failAfterDeferrals(begun, reason: code, attempts: attempts, startedAt: started, at: at))
                }
                // Not counted toward the head-stall bound: the pass ends here
                // and the back-off lets later passes skip the row.
                run = TransientDirectDeferral(reason: code, attempts: attempts, startedAt: started,
                                              nextAttemptAt: at.addingTimeInterval(directDeferralBackoff(attempts)))
            }
            if let deferred = try? store.deferDirectMailIntent(operationID: begun.operationID, now: now(), transient: run) {
                postChange()
                let waiting = describe(deferred)
                return DispatchResult(MailIntentDispatch(operationID: waiting.operationID, route: waiting.route, state: waiting.state,
                                          outcome: waiting.outcome,
                                          detail: deferral.transient ? deferral.reason + " It will retry." : deferral.reason))
            }
            return DispatchResult(MailIntentDispatch(operationID: begun.operationID, route: .direct, state: .dispatching, outcome: .uncertain))
        } catch let refusal as DirectMailDispatchRefusal {
            return DispatchResult(recordOutcome(begun, .failed, outcome: .failed(refusal.message)))
        } catch {
            // The provider may have acted: leave `dispatching(direct)`,
            // which the guard never resends.
            return DispatchResult(MailIntentDispatch(operationID: begun.operationID, route: .direct, state: .dispatching, outcome: .uncertain))
        }
        return DispatchResult(recordOutcome(begun, .confirmed, outcome: .confirmed))
    }

    // MARK: - Node

    private func dispatchNode(
        _ record: MailIntentRecord, source: AccountMailSource, draft: Draft?, interactive: Bool
    ) async throws -> DispatchResult {
        guard let nodeID = source.nodeID,
              let logical = source.logicalMailboxID.flatMap({ try? NodeSyncCodec.decodeLogicalMailboxID($0) })
        else { throw MailIntentRouterError.invalidIntent }
        // A gone or changed draft refuses even while the Node is away.
        var saveDraft: Draft?
        switch record.kind {
        case .markRead, .markUnread, .archive, .delete, .flag, .unflag, .move: break
        case .saveDraft: saveDraft = try Self.renderable(draft ?? loadDraft(record))
        case .send: saveDraft = try approvedDraft(record)
        case .credentialPush: return DispatchResult(describe(record))
        }
        guard let client = await sessions?.reachableClient(nodeID: nodeID),
              await settleRetainedReceipt(client)
        else { return DispatchResult(describe(record)) }
        if let saveDraft {
            return try await dispatchSave(record, draft: saveDraft, client: client, logical: logical, interactive: interactive,
                                          source: source)
        }
        // Resolved only once the Node is reachable: until then a fallback
        // may still send the change directly.
        guard let messageID = record.messageID else { throw MailIntentRouterError.invalidIntent }
        guard let nodeMessageID = try store.nodeMessageID(for: messageID) else {
            // Never falls back to direct: the account is in Node mode.
            return DispatchResult(refuse(record, message: Self.unsyncedMessage))
        }
        let intent = try Self.mutationIntent(record.kind, nodeMessageID: nodeMessageID, folder: record.archiveMailbox)
        switch await encode(.mutation(intent, storesOperation: true), key: record.operationID, client: client, logical: logical) {
        case .unreachable:
            return DispatchResult(describe(record))
        case let .refused(message):
            return DispatchResult(refuse(record, message: message))
        case .readOnly:
            return DispatchResult(try readOnlyBeforeDispatch(record, interactive: interactive))
        case let .bytes(bytes):
            try await replayOlderNodeChanges(record, source: source, client: client)
            if let waiting = try waitsForEarlierChange(record, route: .node, source: source) { return waiting }
            guard let begun = try begin(record, route: .node, canonicalOperation: bytes) else {
                return DispatchResult(try describeCurrent(record))
            }
            // From here on nothing throws: the request is leaving.
            let (current, answer, _) = await sendSigned(
                begun, bytes: bytes, key: begun.operationID, target: .mutation(intent, storesOperation: true),
                client: client, logical: logical
            )
            return DispatchResult(resolve(current, answer: answer))
        }
    }

    private func readOnlyBeforeDispatch(_ record: MailIntentRecord, interactive: Bool) throws -> MailIntentDispatch {
        guard interactive else { return describe(record) }
        _ = refuse(record, message: Self.readOnlyMessage)
        throw MailIntentRouterError.readOnly
    }

    /// Sends signed bytes. A 409 is replayed once with the exact bytes. A
    /// `conflicted` receipt of a never-admitted intent whose authority epoch
    /// moved is re-signed once under a new key, journaled before it leaves.
    private func sendSigned(
        _ record: MailIntentRecord, bytes: Data, key: String, target: SignTarget,
        client: NodeSyncClient, logical: LogicalMailboxID
    ) async -> (MailIntentRecord, NodeAnswer, Data) {
        var answer = await post(bytes, key: key, client: client)
        if case .conflict = answer { answer = await post(bytes, key: key, client: client) }
        guard case .state("conflicted") = answer, record.state == .dispatching,
              await authorityEpochMoved(since: bytes, client: client, logical: logical)
        else { return (record, answer, bytes) }
        let newKey = Self.rekey(key)
        guard case let .bytes(fresh) = await encode(target, key: newKey, client: client, logical: logical),
              let updated = journalSigned(record, target: target, key: newKey, bytes: fresh)
        else { return (record, answer, bytes) }
        var second = await post(fresh, key: newKey, client: client)
        if case .conflict = second { second = await post(fresh, key: newKey, client: client) }
        return (updated, second, fresh)
    }

    /// Journals a (re)signed key and, where the kind allows, its exact bytes.
    private func journalSigned(_ record: MailIntentRecord, target: SignTarget, key: String, bytes: Data) -> MailIntentRecord? {
        let updated: MailIntentRecord?
        switch target {
        case let .mutation(_, storesOperation) where storesOperation:
            updated = try? store.storeMailIntentOperation(operationID: record.operationID, idempotencyKey: key, canonicalOperation: bytes, now: now())
        case .send:
            updated = try? store.storeMailIntentOperation(operationID: record.operationID, idempotencyKey: key, canonicalOperation: bytes, now: now())
        case let .save(_, isSend):
            let revision = isSend ? NodeMailMutationEncoder.revisionAfterSave(canonicalOperation: bytes) : nil
            guard !isSend || revision != nil else { return nil }
            updated = try? store.storeMailIntentSaveKey(operationID: record.operationID, idempotencyKey: key, sendRevision: revision, now: now())
            if updated != nil { inflightSaves[record.operationID] = bytes }
        case .mutation:
            updated = record
        }
        if updated != nil { postChange() }
        return updated
    }

    // MARK: - Draft save stage (save_draft, and a send's save)

    /// Signs the draft save, journals its key (and a send's target revision)
    /// with the route, and sends it.
    private func dispatchSave(
        _ record: MailIntentRecord, draft: Draft, client: NodeSyncClient, logical: LogicalMailboxID, interactive: Bool,
        source: AccountMailSource
    ) async throws -> DispatchResult {
        let isSend = record.kind == .send
        let key = isSend ? Self.saveKey(for: record.operationID) : record.operationID
        switch await encode(.save(draft, isSend: isSend), key: key, client: client, logical: logical) {
        case .unreachable:
            return DispatchResult(describe(record))
        case let .refused(message):
            return DispatchResult(refuse(record, message: message))
        case .readOnly:
            return DispatchResult(try readOnlyBeforeDispatch(record, interactive: interactive))
        case let .bytes(bytes):
            let revision = isSend ? NodeMailMutationEncoder.revisionAfterSave(canonicalOperation: bytes) : nil
            guard !isSend || revision != nil else { return DispatchResult(refuse(record, message: Self.refusedMessage)) }
            try await replayOlderNodeChanges(record, source: source, client: client)
            if let waiting = try waitsForEarlierChange(record, route: .node, source: source) { return waiting }
            guard let begun = try begin(record, route: .node, idempotencyKey: key, sendRevision: revision) else {
                return DispatchResult(try describeCurrent(record))
            }
            inflightSaves[begun.operationID] = bytes
            return DispatchResult(await saveStage(begun, bytes: bytes, key: key, draft: draft, client: client, logical: logical))
        }
    }

    private func saveStage(
        _ record: MailIntentRecord, bytes: Data, key: String, draft: Draft, client: NodeSyncClient, logical: LogicalMailboxID
    ) async -> MailIntentDispatch {
        var (current, answer, sent) = await sendSigned(
            record, bytes: bytes, key: key, target: .save(draft, isSend: record.kind == .send), client: client, logical: logical
        )
        var replays = 0
        while case .state("pending") = answer, replays < pendingSaveReplays {
            replays += 1
            try? await sleep(.seconds(1))
            answer = await post(sent, key: current.idempotencyKey, client: client)
        }
        if let refreshed = try? store.mailIntent(operationID: current.operationID) { current = refreshed }
        _ = sent
        return await afterSave(current, draft: draft, answer: answer, client: client, logical: logical)
    }

    /// Records a draft save's answer. A save that did not apply has no
    /// effect, and a send whose own operation was never stored provably
    /// never left, so both may fail (and unlock the draft) from any state.
    private func afterSave(
        _ record: MailIntentRecord, draft: Draft, answer: NodeAnswer, client: NodeSyncClient, logical: LogicalMailboxID
    ) async -> MailIntentDispatch {
        let operationID = record.operationID
        switch answer {
        case .state("applied"):
            inflightSaves[operationID] = nil
            guard record.kind == .send else { return recordOutcome(record, .confirmed, outcome: .confirmed) }
            guard let revision = record.sendRevision else {
                return record.state == .dispatching ? recordOutcome(record, .uncertain, outcome: .uncertain) : describe(record)
            }
            return await sendStage(record, draft: draft, revision: revision, client: client, logical: logical)
        case .state("rejected"), .state("conflicted"), .conflict:
            inflightSaves[operationID] = nil
            return failSaveStage(record, message: record.kind == .send ? Self.sendNeverLeftMessage : Self.refusedMessage)
        case let .refused(message):
            inflightSaves[operationID] = nil
            return failSaveStage(record, message: record.kind == .send ? Self.sendNeverLeftMessage : message)
        case .state("pending") where record.kind == .saveDraft && record.state == .dispatching:
            return recordOutcome(record, .admitted, outcome: .waitingForNode)
        default:
            // The save may still land; a send was never dispatched.
            return record.state == .dispatching ? recordOutcome(record, .uncertain, outcome: .uncertain) : describe(record)
        }
    }

    /// Encodes, stores and dispatches a send at the revision its approved
    /// save produced. `record` is `dispatching`, or `uncertain` when a settle
    /// resumes it.
    private func sendStage(
        _ record: MailIntentRecord, draft: Draft, revision: String, client: NodeSyncClient, logical: LogicalMailboxID
    ) async -> MailIntentDispatch {
        let target = SignTarget.send(draft, revision: revision)
        switch await encode(target, key: record.operationID, client: client, logical: logical) {
        case let .bytes(bytes):
            // The send's bytes (IDs and a revision, no body) are stored
            // before they leave, so a restart can still settle it.
            guard let stored = try? store.storeMailIntentOperation(
                operationID: record.operationID, idempotencyKey: record.operationID, canonicalOperation: bytes, now: now()
            ) else {
                appliedSaves[record.operationID] = revision
                return record.state == .dispatching ? recordOutcome(record, .uncertain, outcome: .uncertain) : describe(record)
            }
            appliedSaves[record.operationID] = nil
            postChange()
            let (current, answer, _) = await sendSigned(stored, bytes: bytes, key: record.operationID, target: target,
                                                        client: client, logical: logical)
            return resolve(current, answer: answer)
        case .unreachable, .readOnly:
            // Not sent yet; a later settle signs it at the same revision.
            appliedSaves[record.operationID] = revision
            return record.state == .dispatching ? recordOutcome(record, .uncertain, outcome: .uncertain) : describe(record)
        case let .refused(message):
            // The send was never signed, so it never left.
            appliedSaves[record.operationID] = nil
            return failSaveStage(record, message: "This message wasn't sent: \(message)")
        }
    }

    /// Settles a draft-save stage that has no stored bytes (spec amendment,
    /// Task 16 review, second round). A gone or changed draft fails it (the
    /// send never left). A save this process posted is replayed exactly;
    /// after a restart the save is redone under a fresh key derived from the
    /// journaled one (a save of the approved content is idempotent), then the
    /// send follows at the new save's revision.
    private func resumeSave(_ record: MailIntentRecord, client: NodeSyncClient, logical: LogicalMailboxID) async {
        let draft: Draft
        do {
            draft = record.kind == .send ? try approvedDraft(record) : try Self.renderable(loadDraft(record))
        } catch {
            if let message = Self.rowRefusal(error) {
                inflightSaves[record.operationID] = nil
                appliedSaves[record.operationID] = nil
                _ = failSaveStage(record, message: record.kind == .send ? "This message wasn't sent: \(message)" : message)
            }
            return
        }
        if record.kind == .send, let revision = appliedSaves[record.operationID] {
            _ = await sendStage(record, draft: draft, revision: revision, client: client, logical: logical)
            return
        }
        if let bytes = inflightSaves[record.operationID] {
            _ = await afterSave(record, draft: draft, answer: await post(bytes, key: record.idempotencyKey, client: client),
                                client: client, logical: logical)
            return
        }
        let newKey = Self.rekey(record.idempotencyKey)
        let target = SignTarget.save(draft, isSend: record.kind == .send)
        switch await encode(target, key: newKey, client: client, logical: logical) {
        case let .bytes(bytes):
            guard let updated = journalSigned(record, target: target, key: newKey, bytes: bytes) else { return }
            _ = await saveStage(updated, bytes: bytes, key: newKey, draft: draft, client: client, logical: logical)
        case let .refused(message):
            // The redone save was refused before it left: the send never left.
            _ = failSaveStage(record, message: record.kind == .send ? "This message wasn't sent: \(message)" : message)
        case .unreachable, .readOnly:
            return
        }
    }

    // MARK: - Node plumbing

    private func encode(_ target: SignTarget, key: String, client: NodeSyncClient, logical: LogicalMailboxID) async -> EncodeResult {
        do {
            let encoder = makeEncoder(client)
            switch target {
            case let .mutation(intent, _):
                return .bytes(try await encoder.operation(for: intent, logicalMailboxID: logical, idempotencyKey: key))
            case let .save(draft, _):
                return .bytes(try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: logical, idempotencyKey: key))
            case let .send(draft, revision):
                return .bytes(try await encoder.sendOperation(draftID: draft.id, expectedRevision: revision,
                                                              logicalMailboxID: logical, idempotencyKey: key))
            }
        } catch {
            return Self.classifyEncodeFailure(error)
        }
    }

    /// Nothing has been dispatched yet: only an authoritative answer about
    /// this account or draft refuses; anything else means "not reachable now".
    /// `validationFailed` stays here only because the encoder maps the Node's
    /// transport and session failures to it (`NodeSyncCoreMapping.error`);
    /// a draft that cannot be rendered is refused before encoding
    /// (`renderable`), and `permissionDenied` is transient in both
    /// classifiers.
    private static func classifyEncodeFailure(_ error: Error) -> EncodeResult {
        switch error {
        case NodeSessionBrokerError.readOnly:
            return .readOnly
        case let error as PlainpostError:
            switch error {
            case let .notFound(message): return .refused(message)
            case .validationFailed, .permissionDenied: return .unreachable
            }
        case NodeSyncClientError.notFound:
            return .refused("The Sync Node doesn't have this draft yet.")
        case NodeSyncClientError.problem(.invalidRequest):
            return .refused(refusedMessage)
        default:
            return .unreachable
        }
    }

    /// True when `bytes` were signed for this Node and logical mailbox.
    private static func signedFor(_ bytes: Data, nodeID: String, logical: LogicalMailboxID) -> Bool {
        guard let operation = try? NodeSyncCodec.decodeOperation(bytes) else { return false }
        return operation.unsigned.nodeID.lowercased() == nodeID.lowercased() && operation.unsigned.logicalMailboxID == logical
    }

    /// True when the Node now lists a newer authority epoch for the logical
    /// mailbox than the one `bytes` were signed under: a `conflicted` receipt
    /// then came from the stale epoch, before any child ran.
    private func authorityEpochMoved(since bytes: Data, client: NodeSyncClient, logical: LogicalMailboxID) async -> Bool {
        guard let operation = try? NodeSyncCodec.decodeOperation(bytes),
              let signed = UInt64(operation.unsigned.authorityEpoch),
              let accounts = try? await client.mailAccounts()
        else { return false }
        return accounts.accounts
            .filter { $0.logicalMailboxID == logical }
            .flatMap(\.assignments)
            .compactMap { $0.authorityEpoch.flatMap(UInt64.init) }
            .contains { $0 > signed }
    }

    /// Sends exact signed bytes once. After an error that may have crossed
    /// dispatch, the session's retained exact request is replayed once.
    ///
    /// A failure before the transport's dispatch boundary still counts as
    /// ambiguous here: the session transport keeps the reserved request and
    /// replays it before its next request, so it can still leave later.
    private func post(_ bytes: Data, key: String, client: NodeSyncClient) async -> NodeAnswer {
        do {
            let result = try await client.mutation(canonicalOperation: bytes)
            return result.idempotencyKey == key ? .state(result.state) : .ambiguous
        } catch NodeSyncClientError.conflict {
            return .conflict
        } catch NodeSyncClientError.notFound {
            return .refused("The Sync Node couldn't find this message.")
        } catch NodeSyncClientError.problem(.invalidRequest) {
            return .refused(Self.refusedMessage)
        } catch {
            // Ambiguous: settle the session's retained request if it can.
        }
        if let recovered = try? await client.reconcilePendingMutation() {
            if recovered.idempotencyKey == key { return .state(recovered.state) }
            attachReceipt(recovered)
        }
        return .ambiguous
    }

    /// Settles a mutation the session retained from an earlier dispatch and
    /// attaches its receipt to its own intent. False when the Node cannot be
    /// reached; a definite but foreign answer lets the new change proceed.
    private func settleRetainedReceipt(_ client: NodeSyncClient) async -> Bool {
        do {
            if let receipt = try await client.reconcilePendingMutation() { attachReceipt(receipt) }
            return true
        } catch let error as NodeSyncClientError {
            switch error {
            case .conflict, .notFound, .invalidResponse, .problem(.invalidRequest), .problem(.staleCursor), .problem(.conflict):
                return true
            case .transport, .transportAfterDispatch, .cancelled, .cancelledAfterDispatch, .problem(.unavailable), .problem(.unauthorized):
                return false
            }
        } catch {
            return false
        }
    }

    /// A retained receipt is the answer to the session's replay of that exact
    /// request, so it settles its own intent like an exact replay. A draft
    /// save's key is journaled, so its receipt finds the intent after a
    /// restart too.
    private func attachReceipt(_ receipt: NodeSyncMutationResult) {
        guard MailIntentRecord.isValidOperationID(receipt.idempotencyKey),
              let record = try? store.mailIntent(idempotencyKey: receipt.idempotencyKey),
              // A row another caller is working on owns its own answer.
              !(singleFlight && rowsInFlight.contains(record.operationID)),
              record.route == .node, [.dispatching, .admitted, .uncertain].contains(record.state),
              let stored = try? store.mailIntentCanonicalOperation(operationID: record.operationID) as Data??
        else { return }
        guard stored == nil, record.kind == .send || record.kind == .saveDraft else {
            _ = resolve(record, answer: .state(receipt.state))
            return
        }
        // A draft-save stage; a live dispatch in this process owns its own answer.
        guard record.state != .dispatching else { return }
        switch receipt.state {
        case "applied":
            inflightSaves[record.operationID] = nil
            if record.kind == .saveDraft {
                _ = recordOutcome(record, .confirmed, outcome: .confirmed)
            } else if let revision = record.sendRevision {
                appliedSaves[record.operationID] = revision   // the next settle sends it
            }
        case "rejected", "conflicted":
            inflightSaves[record.operationID] = nil
            _ = failSaveStage(record, message: record.kind == .send ? Self.sendNeverLeftMessage : Self.refusedMessage)
        default:
            break
        }
    }

    /// Records the Node's answer for a stored Node operation in
    /// `dispatching`, `admitted` or `uncertain`. An `uncertain` intent's
    /// answers only ever come from replaying its exact bytes (the stored
    /// operation or the session's retained request), which is what the
    /// amended rule needs.
    ///
    /// A persistent 409 cannot be told apart on the wire (the Node's body
    /// carries only the `conflict` category for a key bound to other bytes,
    /// a deterministic invalid request, and a post-effect evidence conflict).
    /// It is never `failed`: in flight it is `uncertain`, and when the exact
    /// replay of an `uncertain` intent answers it again the intent ends
    /// `unconfirmed` (terminal, never resent, no badge) like a `conflicted`
    /// replay.
    private func resolve(_ record: MailIntentRecord, answer: NodeAnswer) -> MailIntentDispatch {
        // A definite answer proves the bytes reached the Node.
        switch answer {
        case let .state(state): nodeAnswers[record.operationID] = state == "pending"
        case .refused: nodeAnswers[record.operationID] = false
        case .conflict, .ambiguous: break
        }
        let inFlight = record.state == .dispatching || record.state == .admitted
        switch answer {
        case .state("applied"):
            return recordOutcome(record, .confirmed, outcome: .confirmed)
        case .state("pending"):
            return record.state == .dispatching ? recordOutcome(record, .admitted, outcome: .waitingForNode) : describe(record)
        case .state("rejected"):
            return recordOutcome(record, .failed, outcome: .failed(Self.refusedMessage))
        case .state("conflicted"):
            return inFlight
                ? recordOutcome(record, .failed, outcome: .failed(Self.refusedMessage))
                : recordOutcome(record, .unconfirmed, outcome: .uncertain)
        case .conflict:
            return inFlight ? recordOutcome(record, .uncertain, outcome: .uncertain) : recordOutcome(record, .unconfirmed, outcome: .uncertain)
        case let .refused(message):
            return inFlight ? recordOutcome(record, .failed, outcome: .failed(message)) : describe(record)
        case .state, .ambiguous:
            // delivery_uncertain or a lost answer: may have taken effect, never failed.
            return inFlight ? recordOutcome(record, .uncertain, outcome: .uncertain) : describe(record)
        }
    }

    // MARK: - Journal helpers

    private func ensureRecovered() -> Bool {
        guard needsRecovery else { return true }
        do {
            if try store.recoverInterruptedMailIntentDispatches(dispatchedBefore: processStartedAt, now: now()) > 0 {
                postChange()
            }
            needsRecovery = false
            return true
        } catch {
            return false
        }
    }

    /// `pending → dispatching(route)`; nil when another dispatcher won. A
    /// Node dispatch journals the key it signs under and, where the kind
    /// allows, the exact bytes it is about to send.
    private func begin(
        _ record: MailIntentRecord, route: MailIntentRoute, canonicalOperation: Data? = nil,
        idempotencyKey: String? = nil, sendRevision: String? = nil
    ) throws -> MailIntentRecord? {
        try beginFailpoint?(record.operationID)
        do {
            // One write: the row is never `dispatching(node)` without its key
            // and a send's target revision.
            let begun = try store.beginMailIntentDispatch(
                operationID: record.operationID, route: route, canonicalOperation: canonicalOperation,
                idempotencyKey: idempotencyKey, sendRevision: sendRevision, now: now()
            )
            postChange()
            return begun
        } catch NodeMailModeStoreError.generationConflict {
            return nil
        }
    }

    /// Fails a draft-save stage only while no send bytes are stored (the
    /// store checks that in the same write). Otherwise the send may have
    /// left: the row is reported as it is and settles by replay.
    private func failSaveStage(_ record: MailIntentRecord, message: String) -> MailIntentDispatch {
        do {
            let failed = try store.failMailIntentSaveStage(operationID: record.operationID, now: now())
            postChange()
            return MailIntentDispatch(operationID: failed.operationID, route: failed.route, state: .failed, outcome: .failed(message))
        } catch {
            return (try? describeCurrent(record)) ?? describe(record)
        }
    }

    /// A row-specific refusal before any dispatch: `pending` → `failed` with
    /// no route. Never throws; a lost race reports the row as it is.
    private func refuse(_ record: MailIntentRecord, message: String) -> MailIntentDispatch {
        do {
            let refused = try store.refuseUnroutedMailIntent(operationID: record.operationID, now: now())
            postChange()
            return MailIntentDispatch(operationID: refused.operationID, route: nil, state: .failed, outcome: .failed(message))
        } catch {
            return (try? describeCurrent(record)) ?? describe(record)
        }
    }

    /// Records an outcome after dispatch. It never throws: a caller seeing
    /// an error could resend. If the write fails the row keeps its guarded
    /// state and the caller learns the change may have taken effect.
    private func recordOutcome(_ record: MailIntentRecord, _ state: MailIntentState, outcome: MailIntentDispatchOutcome) -> MailIntentDispatch {
        do {
            let updated = try store.recordMailIntentOutcome(operationID: record.operationID, state: state, now: now())
            if state != .admitted && state != .uncertain { nodeAnswers[record.operationID] = nil }
            postChange()
            return MailIntentDispatch(operationID: updated.operationID, route: updated.route, state: updated.state, outcome: outcome)
        } catch {
            if let current = try? store.mailIntent(operationID: record.operationID) { return describe(current) }
            return MailIntentDispatch(operationID: record.operationID, route: record.route, state: record.state, outcome: .uncertain)
        }
    }

    /// A row deferred too often or too long: failed (nothing was sent) with
    /// its reason kept for the notice. Never throws, like `recordOutcome`.
    private func failAfterDeferrals(
        _ record: MailIntentRecord, reason: DirectDeferralReason, attempts: Int, startedAt: Date, at: Date
    ) -> MailIntentDispatch {
        do {
            try failAfterDeferralsFailpoint?(.fail)
            let failed = try store.failDeferredDirectMailIntent(operationID: record.operationID, reason: reason, now: now())
            postChange()
            return MailIntentDispatch(operationID: failed.operationID, route: failed.route, state: failed.state,
                                      outcome: .failed(reason.message + " Nothing was sent."))
        } catch {
            // The write failed (a busy database, twice): nothing was sent,
            // so put the row back to pending rather than leave it in
            // `dispatching(direct)`, which is never resent. The run is kept
            // at its limit with a scheduled next attempt, so that attempt,
            // if the server is still unreachable, fails the row again
            // (unless a long gap has started a new run by then); if the
            // server is back it simply delivers.
            let run = TransientDirectDeferral(reason: reason, attempts: attempts, startedAt: startedAt,
                                              nextAttemptAt: at.addingTimeInterval(directDeferralBackoff(attempts)))
            do {
                try failAfterDeferralsFailpoint?(.revert)
                let deferred = try store.deferDirectMailIntent(operationID: record.operationID, now: now(), transient: run)
                postChange()
                return waiting(deferred, detail: reason.message + " It will retry.")
            } catch {
                // Neither write landed: the row would sit in
                // `dispatching(direct)`, which is never resent. Say so, and
                // fail it (nothing was sent) at the account's next drain.
                routerLogger.error("A direct change that failed after its deferrals could not be written; the next drain fails it.")
                strandedDeferralFailures[record.operationID] = (record.accountID, reason)
            }
            if let current = try? store.mailIntent(operationID: record.operationID) { return describe(current) }
            return MailIntentDispatch(operationID: record.operationID, route: record.route, state: record.state, outcome: .uncertain)
        }
    }

    /// Fails the account's stranded rows (see `failAfterDeferrals`) now
    /// that the database may take the write. A row that left
    /// `dispatching(direct)` meanwhile is forgotten.
    private func retryStrandedDeferralFailures(accountID: AccountID) {
        for (operationID, stranded) in strandedDeferralFailures where stranded.accountID == accountID {
            do {
                try failAfterDeferralsFailpoint?(.fail)
                _ = try store.failDeferredDirectMailIntent(operationID: operationID, reason: stranded.reason, now: now())
                strandedDeferralFailures[operationID] = nil
                postChange()
            } catch NodeMailModeStoreError.generationConflict, NodeMailModeStoreError.mailIntentNotFound {
                strandedDeferralFailures[operationID] = nil
            } catch {
                routerLogger.error("A stranded direct change is still not written; the next drain tries again.")
            }
        }
    }

    private func describeCurrent(_ record: MailIntentRecord) throws -> MailIntentDispatch {
        describe(try store.mailIntent(operationID: record.operationID) ?? record)
    }

    private func describe(_ record: MailIntentRecord) -> MailIntentDispatch {
        let outcome: MailIntentDispatchOutcome = switch (record.state, record.route) {
        case (.pending, _), (.admitted, _), (.dispatching, .node?): .waitingForNode
        case (.confirmed, _): .confirmed
        // A direct row failed after its deferrals says why; nothing was sent.
        case (.failed, _): .failed(record.deferralReason.map { $0.message + " Nothing was sent." } ?? Self.refusedMessage)
        case (.dispatching, _), (.uncertain, _), (.unconfirmedAfterRemoval, _), (.unconfirmed, _): .uncertain
        }
        return MailIntentDispatch(operationID: record.operationID, route: record.route, state: record.state, outcome: outcome)
    }

    private func loadDraft(_ record: MailIntentRecord) throws -> Draft {
        guard let draftID = record.draftID else { throw MailIntentRouterError.invalidIntent }
        return try store.draft(id: draftID)
    }

    /// Journal writes post no store-change signal of their own; the badge
    /// projection reloads on this one.
    private func postChange() {
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    /// Every message kind names its own change; a kind that is not a message
    /// change is refused, never sent as a delete.
    static func mutationIntent(_ kind: MailIntentKind, nodeMessageID: String, folder: String? = nil) throws -> MailMutationIntent {
        let ids = [MessageID(nodeMessageID)]
        switch kind {
        case .markRead: return .setRead(messageIDs: ids, read: true)
        case .markUnread: return .setRead(messageIDs: ids, read: false)
        case .archive: return .archive(messageIDs: ids)
        case .delete: return .delete(messageIDs: ids)
        case .flag: return .setFlagged(messageIDs: ids, flagged: true)
        case .unflag: return .setFlagged(messageIDs: ids, flagged: false)
        case .move:
            guard let folder, !folder.isEmpty else { throw MailIntentRouterError.invalidIntent }
            return .move(messageIDs: ids, destinationMailboxPath: folder)
        case .saveDraft, .send, .credentialPush: throw MailIntentRouterError.invalidIntent
        }
    }
}
