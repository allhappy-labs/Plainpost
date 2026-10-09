import CryptoKit
import Foundation

/// A user mail change or credential push journaled before it is dispatched.
/// The journal carries no bodies, recipients or credentials: a
/// `credential_push` row names only its account, and the secret is re-read
/// from the vault at push time.
public enum MailIntentKind: String, Codable, Sendable, CaseIterable {
    case markRead = "mark_read", markUnread = "mark_unread", archive, delete
    case flag, unflag
    /// Journals its destination folder in `archiveMailbox`.
    case move
    case saveDraft = "save_draft", send
    case credentialPush = "credential_push"

    /// Mail changes that act on one stored message.
    public var targetsMessage: Bool {
        switch self {
        case .markRead, .markUnread, .archive, .delete, .flag, .unflag, .move: true
        case .saveDraft, .send, .credentialPush: false
        }
    }

    /// Mail changes that act on one draft.
    public var targetsDraft: Bool {
        self == .saveDraft || self == .send
    }
}

/// The refusal a Sync Node gives a change it won't make, as the app shows it.
public enum MailIntentRouterRefusal {
    public static let genericMessage = "The Sync Node refused this change."
}

public enum MailIntentRoute: String, Codable, Sendable, CaseIterable { case node, direct }

public enum MailIntentState: String, Codable, Sendable, CaseIterable {
    case pending            // journaled, not dispatched, route may be nil
    case dispatching        // route fixed, request leaving this process
    case admitted           // Node returned "pending"
    case confirmed          // Node "applied" or direct success
    case uncertain          // acknowledgement lost after dispatch or Node "delivery_uncertain"
    case failed             // Node "rejected"/"conflicted" or direct failure before provider effect
    case unconfirmedAfterRemoval = "unconfirmed_after_removal"
    /// Terminal: an uncertain intent whose exact replay the Node answered
    /// `conflicted`. It may have taken effect, is never resent and shows no
    /// badge (spec amendment, Task 16 review).
    case unconfirmed
}

/// Why a direct dispatch was deferred for a transient, pre-effect reason.
/// A closed set: the journal stores the code, never provider text, and the
/// text is fixed here.
public enum DirectDeferralReason: String, CaseIterable, Equatable, Sendable {
    case mailServerUnreachable = "mail_server_unreachable"
    case signInRefusedForNow = "sign_in_refused_for_now"
    case googleUnreachable = "google_unreachable"

    public var message: String {
        switch self {
        case .mailServerUnreachable: "Plainpost couldn't reach your mail server."
        case .signInRefusedForNow: "Your mail server refused sign-in for now."
        case .googleUnreachable: "Plainpost couldn't reach Google to sign in."
        }
    }
}

/// A direct dispatch deferred for a transient, pre-effect reason (the mail
/// server or Google unreachable, a temporary sign-in refusal) and its run.
public struct TransientDirectDeferral: Equatable, Sendable {
    public let reason: DirectDeferralReason
    /// Attempts in the current run, this one included.
    public let attempts: Int
    public let startedAt: Date
    public let nextAttemptAt: Date

    public init(reason: DirectDeferralReason, attempts: Int, startedAt: Date, nextAttemptAt: Date) {
        self.reason = reason
        self.attempts = attempts
        self.startedAt = startedAt
        self.nextAttemptAt = nextAttemptAt
    }
}

/// An account in fallback whose change waits on a transient failure.
public struct PendingDirectDeferral: Equatable, Sendable {
    public let accountID: AccountID
    public let accountName: String
    public let reason: DirectDeferralReason

    public init(accountID: AccountID, accountName: String, reason: DirectDeferralReason) {
        self.accountID = accountID
        self.accountName = accountName
        self.reason = reason
    }
}

public struct MailIntentRecord: Equatable, Sendable {
    public let operationID: String        // UUID lower-case; Node idempotency key derives from it
    public let accountID: AccountID
    public let kind: MailIntentKind
    public let route: MailIntentRoute?
    public let state: MailIntentState
    public let messageID: MessageID?
    public let draftID: DraftID?
    public let createdAt: Date
    public let updatedAt: Date
    /// The Node idempotency key the intent is (or will be) signed under:
    /// its operation ID, or the key it was re-signed under after a stale
    /// authority epoch.
    public let idempotencyKey: String
    /// A send's approved draft content hash; dispatch refuses a draft that
    /// changed since. Nil for every other kind.
    public let contentHash: String?
    /// An archive's destination mailbox as the user or rule requested it.
    public let archiveMailbox: String?
    /// A send's Node draft revision after its approved save: the only
    /// revision the send may be signed at. Nil until the save is signed.
    public let sendRevision: String?
    /// Direct dispatches deferred for a transient, pre-effect reason (the
    /// mail server or Google unreachable, a temporary sign-in refusal).
    public let deferralCount: Int
    /// The latest transient deferral's reason (user-facing, no identity).
    /// A passing deferral (locked, back in node mode) never replaces it. It
    /// stays on a row failed after its deferrals, for the notice.
    public let deferralReason: DirectDeferralReason?
    /// When the current run of transient deferrals began.
    public let firstDeferredAt: Date?
    /// When the latest transient deferral made the row due again. Unlike
    /// `nextAttemptAt` it survives the attempt: a long gap between it and
    /// the next attempt (sleep, a locked vault, node mode) starts a new run.
    public let deferralDueAt: Date?
    /// A deferred row is not dispatched directly again before this.
    public let nextAttemptAt: Date?

    public init(
        operationID: String,
        accountID: AccountID,
        kind: MailIntentKind,
        route: MailIntentRoute?,
        state: MailIntentState,
        messageID: MessageID?,
        draftID: DraftID?,
        createdAt: Date,
        updatedAt: Date,
        idempotencyKey: String? = nil,
        contentHash: String? = nil,
        archiveMailbox: String? = nil,
        sendRevision: String? = nil,
        deferralCount: Int = 0,
        deferralReason: DirectDeferralReason? = nil,
        firstDeferredAt: Date? = nil,
        deferralDueAt: Date? = nil,
        nextAttemptAt: Date? = nil
    ) {
        self.deferralDueAt = deferralDueAt
        self.deferralCount = deferralCount
        self.deferralReason = deferralReason
        self.firstDeferredAt = firstDeferredAt
        self.nextAttemptAt = nextAttemptAt
        self.operationID = operationID
        self.accountID = accountID
        self.kind = kind
        self.route = route
        self.state = state
        self.messageID = messageID
        self.draftID = draftID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.idempotencyKey = idempotencyKey ?? operationID
        self.contentHash = contentHash
        self.archiveMailbox = archiveMailbox
        self.sendRevision = sendRevision
    }

    /// Operation IDs are canonical lower-case UUIDs, so one intent has exactly
    /// one spelling and one Node idempotency key.
    public static func isValidOperationID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    /// Message kinds name a message, draft kinds a draft, and credential
    /// pushes only their account.
    /// An archive may name its archive folder and a move must name its destination; no other
    /// kind carries a folder.
    public static func hasValidFolder(kind: MailIntentKind, folder: String?) -> Bool {
        switch kind {
        case .archive: true
        case .move: folder?.isEmpty == false
        default: folder == nil
        }
    }

    public static func hasValidTarget(kind: MailIntentKind, messageID: MessageID?, draftID: DraftID?) -> Bool {
        (messageID != nil) == kind.targetsMessage && (draftID != nil) == kind.targetsDraft
    }
}

public enum MailIntentGuard {
    /// Direct dispatch is allowed only for work that never left toward the Node.
    public static func mayDispatchDirect(_ record: MailIntentRecord) -> Bool {
        record.state == .pending && record.route == nil && record.kind != .credentialPush
    }

    /// True while the UI must show "Waiting for Sync Node".
    public static func waitsForNode(_ record: MailIntentRecord) -> Bool {
        record.route == .node && (record.state == .admitted || record.state == .uncertain)
    }

    /// False for anything that may already have reached the provider or the
    /// Node: dispatching, admitted, uncertain, unconfirmedAfterRemoval and
    /// confirmed work is never sent again.
    public static func mayResend(_ record: MailIntentRecord) -> Bool {
        switch record.state {
        case .pending: record.route == nil
        case .failed: true
        case .dispatching, .admitted, .confirmed, .uncertain, .unconfirmedAfterRemoval, .unconfirmed: false
        }
    }
}

/// The per-intent outcome transitions. Every other move is account-level and
/// has one owner: `pending → dispatching` (`beginMailIntentDispatch`),
/// `pending → failed` for superseded credential pushes
/// (`supersedePendingCredentialPushes`), `{dispatching, admitted, uncertain}`
/// on the Node route `→ unconfirmedAfterRemoval` (`markNodeIntentsUnconfirmed`)
/// and `dispatching(node) → uncertain` after a crash
/// (`recoverInterruptedMailIntentDispatches`), and `pending → failed` with no
/// route for a row-specific refusal before dispatch
/// (`refuseUnroutedMailIntent`).
///
/// Spec amendment (Task 16 review): `uncertain → failed` only when replaying
/// the exact signed bytes (same key and digest) returns `rejected`, and
/// `uncertain → unconfirmed` only when it returns `conflicted`. The router
/// owns that rule; this table only admits the moves.
public enum MailIntentTransition {
    public static func mayRecordOutcome(
        from: MailIntentState,
        to: MailIntentState,
        route: MailIntentRoute?
    ) -> Bool {
        switch (route, from) {
        case (.node?, .dispatching):
            return [.admitted, .confirmed, .uncertain, .failed].contains(to)
        case (.direct?, .dispatching):
            return to == .confirmed || to == .failed
        case (.node?, .admitted):
            return [.confirmed, .uncertain, .failed].contains(to)
        case (.node?, .uncertain):
            return [.confirmed, .failed, .unconfirmed].contains(to)
        default:
            return false
        }
    }
}

public extension MailIntentRecord {
    /// A stable lower-case UUID derived from `seed` (for example a durable
    /// job or send request ID), so a retried caller journals the same
    /// intent again.
    static func operationID(derivedFrom seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}
