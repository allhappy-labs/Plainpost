import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostNodeMailMode
import PlainpostOperationRuntime
import os

private let approvedSendLogger = Logger(subsystem: "com.marynavdovenko.Plainpost", category: "approved-send-routing")

/// Approved sends (agent approvals and browser replies) of Node-backed
/// accounts go through the mail-intent router, like the user's own sends:
/// to the Node, or directly to the provider in fallback.
///
/// - One approval, one intent: claiming the request (`pending`/`approved` →
///   `sending`, which validates the approval and the approved content) also
///   records a fresh operation ID on it (`deliveryOperationID`). A retried
///   job or a lease-recovered one finds that approval's intent and never
///   sends twice; the runtime never takes its direct SMTP path once that
///   intent exists. A new approval (the request is recreated for every send
///   request) gets a new intent, and an earlier approval's failed intent is
///   left untouched.
/// - A request already `sending` without an operation ID was claimed by an
///   attempt that did not route (direct SMTP before the account became
///   Node-backed): it may have been sent, so it becomes `deliveryUncertain`.
/// - A terminal outcome is written to the request at once; a queued or
///   admitted send leaves it `sending`, and `reconcile` (every supervisor
///   tick) moves it when the intent settles. A `dispatching(direct)` row the
///   router still holds is on the wire and never read as ambiguous.
enum ServiceApprovedSendRouting {
    static func handoff(router: MailIntentRouter, store: SQLiteMailStore) -> NodeModeApprovedSendHandoff {
        { work in
            let request = try store.sendRequest(id: work.requestID)
            let draft = try store.draft(id: request.draftID)
            let actor = Actor(id: work.actorID, kind: .user, displayName: "Authenticated Local User", permissions: .guiUser)
            let operationID: String
            switch request.status {
            case .pending, .approved:
                // A new approval: validated by the claim, with its own intent.
                let fresh = UUID().uuidString.lowercased()
                _ = try store.claimSendRequestForDelivery(
                    id: request.id, currentDraftHash: draft.contentHash, actor: actor, deliveryOperationID: fresh
                )
                operationID = fresh
            case .sending:
                guard let claimed = request.deliveryOperationID else {
                    // Claimed by an attempt that did not route: it may have sent.
                    do {
                        _ = try store.updateSendRequest(
                            id: request.id, status: .deliveryUncertain,
                            approvedBy: request.approvedBy ?? actor.id, approvedDraftHash: request.approvedDraftHash
                        )
                    } catch {
                        approvedSendLogger.error("An unrouted approved send's request could not be marked uncertain.")
                    }
                    return
                }
                // This approval's claim (a retried or lease-recovered job).
                operationID = claimed
            case .sent, .deliveryUncertain, .denied, .failed, .cancelled, .expired:
                return
            }
            let claimed = try store.sendRequest(id: request.id)
            let dispatch: MailIntentDispatch
            do {
                dispatch = try await router.sendIntent(
                    draft, approvedContentHash: claimed.approvedDraftHash ?? draft.contentHash, operationID: operationID
                )
            } catch MailIntentRouterError.sendInProgress {
                throw PlainpostError.validationFailed("This message is already being sent. Check Sent before sending it again.")
            } catch MailIntentRouterError.readOnly {
                // The row is failed; the request follows.
                await apply(state: .failed, route: nil, operationID: operationID, requestID: request.id, draft: draft,
                            actor: actor, store: store, router: router)
                return
            }
            // Not journaled (`notNodeBacked`, `journalUnavailable`) → thrown
            // above as-is and the job fails before anything was sent;
            // journaled → the row decides.
            await apply(state: dispatch.state, route: dispatch.route, operationID: operationID, requestID: request.id,
                        draft: draft, actor: actor, store: store, router: router)
        }
    }

    /// Moves every routed request whose intent has settled.
    /// - `sending` requests (only the few in flight) are read every time.
    /// - `deliveryUncertain` requests (set by lease recovery on missing
    ///   information) are found through their intents instead: only send
    ///   intents that became `confirmed` or `failed` after `changedAfter`
    ///   are looked at, so settled history is not re-read every tick.
    /// Returns the watermark for the next sweep: the largest `updated_at`
    /// this sweep saw (or `changedAfter` when it saw none), or nil when the
    /// intent query failed, so the caller keeps its previous watermark.
    @discardableResult
    static func reconcile(store: SQLiteMailStore, router: MailIntentRouter, changedAfter: Date = .distantPast) async -> Date? {
        if let ids = try? store.sendRequestIDs(status: .sending) {
            for id in ids { await reconcileRequest(id: id, store: store, router: router) }
        }
        guard let changed = try? store.sendIntents(states: [.confirmed, .failed], updatedAfter: changedAfter) else { return nil }
        for record in changed {
            guard let id = try? store.sendRequestID(deliveryOperationID: record.operationID),
                  (try? store.sendRequest(id: id))?.status == .deliveryUncertain
            else { continue }
            await reconcileRequest(id: id, store: store, router: router)
        }
        return changed.map(\.updatedAt).max() ?? changedAfter
    }

    /// Reconciles one routed request against its own intent.
    static func reconcileRequest(id: SendRequestID, store: SQLiteMailStore, router: MailIntentRouter) async {
        guard let request = try? store.sendRequest(id: id),
              let operationID = request.deliveryOperationID,
              request.status == .sending || request.status == .deliveryUncertain
        else { return }
        // Ask whether the router holds the row before reading it: a send
        // that finishes in between is then read in its final state.
        let held = await router.isHolding(operationID: operationID)
        guard let record = try? store.mailIntent(operationID: operationID) else { return }
        // Direct delivery removes the sent draft as part of its durable send
        // transition. Reconciliation still has the request and its journaled
        // outcome if the service stopped before settling the request.
        let draft = try? store.draft(id: request.draftID)
        // A possibly-sent request leaves `deliveryUncertain` only on its own
        // authoritative outcome: confirmed, or failed (pre-effect or an
        // exact-replay rejection, by the journal's rules).
        if request.status == .deliveryUncertain, record.state != .confirmed, record.state != .failed { return }
        let actor = Actor(id: request.approvedBy ?? request.requestedBy, kind: .user,
                          displayName: "Authenticated Local User", permissions: .guiUser)
        await apply(state: record.state, route: record.route, operationID: operationID, requestID: id,
                    draft: draft, actor: actor, store: store, router: router, heldByRouter: held)
    }

    /// The send request status an intent state settles to; nil while the
    /// send is queued, admitted or on the wire.
    static func requestStatus(for state: MailIntentState, route: MailIntentRoute?, heldByRouter: Bool) -> SendRequestStatus? {
        switch state {
        case .confirmed: .sent
        case .failed: .failed
        case .uncertain, .unconfirmed, .unconfirmedAfterRemoval: .deliveryUncertain
        // A direct send the router no longer holds ended ambiguously (or an
        // earlier process left it); while held it is still on the wire.
        case .dispatching where route == .direct: heldByRouter ? nil : .deliveryUncertain
        case .pending, .dispatching, .admitted: nil
        }
    }

    /// `heldByRouter`: nil asks the router now and, when it no longer holds
    /// the row, re-reads it, so a send that just finished is read in its
    /// final state rather than as an ambiguous `dispatching(direct)`.
    private static func apply(
        state: MailIntentState, route: MailIntentRoute?, operationID: String, requestID: SendRequestID, draft: Draft?,
        actor: Actor, store: SQLiteMailStore, router: MailIntentRouter, heldByRouter: Bool? = nil
    ) async {
        var state = state
        var route = route
        var held = heldByRouter ?? false
        if heldByRouter == nil, state == .dispatching, route == .direct {
            held = await router.isHolding(operationID: operationID)
            if !held, let fresh = try? store.mailIntent(operationID: operationID) {
                state = fresh.state
                route = fresh.route
            }
        }
        guard let status = requestStatus(for: state, route: route, heldByRouter: held) else { return }
        // A Node confirmation still needs its draft to create the local Sent
        // copy. Only direct delivery removes the draft during settlement.
        if status == .sent, route == .node, draft == nil { return }
        // One write, and only for this approval's operation: exactly one
        // caller (handoff or reconcile) moves the request.
        guard (try? store.settleRoutedSendRequest(id: requestID, operationID: operationID, to: status)) == true else {
            return
        }
        if status == .sent, route == .node, let draft {
            // The Node sent it and owns the Sent copy; the local record shares
            // its canonical ID, so the mirrored copy lands on the same message.
            // (A direct send recorded its own.)
            _ = try? store.recordDirectSentMessage(draft: draft, actor: actor)
        }
    }
}

/// Runs `ServiceApprovedSendRouting.reconcile` every supervisor tick,
/// remembering the newest send-intent change it has seen, so only intents
/// that changed since are looked up for `deliveryUncertain` requests. The
/// first sweep of a process looks at all of them.
actor ServiceApprovedSendReconciler {
    private let store: SQLiteMailStore
    private let router: MailIntentRouter
    private var lastSweep: Date = .distantPast

    init(store: SQLiteMailStore, router: MailIntentRouter) {
        self.store = store
        self.router = router
    }

    func sweep() async {
        // The watermark is the newest intent change actually seen, less a
        // second of overlap, so a row committed late with an earlier stamp
        // is still read; it moves only when the query succeeded.
        guard let seen = await ServiceApprovedSendRouting.reconcile(store: store, router: router, changedAfter: lastSweep)
        else { return }
        if seen > lastSweep {
            lastSweep = max(lastSweep, seen.addingTimeInterval(-1))
        }
    }

    /// Tests: the current watermark.
    var watermark: Date { lastSweep }
}
