#if DEBUG
import Combine
import Foundation
import PlainpostAccountProtocol
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport
import PlainpostUI
import SwiftUI

extension Notification.Name {
    /// Posted on the main actor with the fixture's description of each accepted mutation.
    static let plainpostDebugNodeMutation = Notification.Name("PlainpostDebugNodeMutation")
}

/// In-app two-account Sync Node for the multi-account UI acceptance fixture
/// (`PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE`). It serves `ada@example.test`
/// (primary) and `grace@example.test`, each with its own mailboxes and one
/// message, through the production codecs. Mutations are signed with a
/// placeholder signature for mailboxes whose authority epoch was installed,
/// accepted only for a listed account, and reported to the visible
/// `DebugNodeMutationLog` so a UI test can see which account an action used.
///
/// Optional failure modes, each behind its own launch environment variable:
/// - `failsSend` (`PLAINPOST_DEBUG_NODE_FAILING_SEND`): every send is rejected
///   and logged as "send rejected <account>".
/// - `dropsPrimaryAfterRejectedSend`
///   (`PLAINPOST_DEBUG_NODE_DROP_PRIMARY_AFTER_REJECTED_SEND`): once a send was
///   rejected, the account catalog stops listing the primary account, as when
///   it is removed on the Mac. Its mail stays readable.
/// - `singleAccount` (`PLAINPOST_DEBUG_NODE_SINGLE_ACCOUNT`): the catalog lists
///   only the primary account.
///
/// It also serves the mirror's routes (deltas and coordinates): an accepted
/// read, archive or delete changes the fixture message and publishes an
/// upsert, as the Node does, so the phone's mirror follows it.
actor DebugTwoAccountNodeSender: NodeSessionRequestSending, NodePendingRequestReconciling, NodeMutationOperationSigning,
    NodeAuthorityEpochUpdating {
    private struct Account {
        let logicalMailboxID: LogicalMailboxID
        let identity: String
        let primary: Bool
        let mailboxes: [(displayName: String, handle: String, role: String)]
        let messageID: String
        let subject: String
    }

    private let accounts = [
        Account(
            logicalMailboxID: LogicalMailboxID(rawValue: Data(repeating: 1, count: 32))!,
            identity: "ada@example.test", primary: true,
            mailboxes: [("Inbox", "INBOX", "inbox"), ("Drafts", "[Gmail]/Drafts", "drafts")],
            messageID: "ada-fixture-message", subject: "Analytical engine notes"
        ),
        Account(
            logicalMailboxID: LogicalMailboxID(rawValue: Data(repeating: 2, count: 32))!,
            identity: "grace@example.test", primary: false,
            mailboxes: [("Inbox", "INBOX", "inbox"), ("Drafts", "Drafts", "drafts"), ("Receipts", "Receipts", "other")],
            messageID: "gm2.00000000000000000000000000000000000000a2", subject: "Compiler review"
        ),
    ]
    private let url = URL(string: "https://node.example.ts.net:443")!
    /// The fixture Node's device id, as its signed operations name it.
    static let nodeID = "aaaaaaaa-bbbb-cccc-8ddd-eeeeeeeeeeee"
    private nonisolated let epochs = DebugAuthorityEpochs()
    private let failsSend: Bool
    private let dropsPrimaryAfterRejectedSend: Bool
    private let singleAccount: Bool
    private var rejectedSend = false
    /// Drafts saved through this fixture, so a send can read their state.
    private var savedDraftIDs: Set<String> = []
    /// Each fixture message's folder and flags, changed by accepted mutations.
    private var placement: [String: (path: String, flags: [String])] = [:]
    /// Published changes, oldest first; a delta cursor is "d:<count>".
    private var changes: [NodeSyncChange] = []

    init(failsSend: Bool = false, dropsPrimaryAfterRejectedSend: Bool = false, singleAccount: Bool = false) {
        self.failsSend = failsSend
        self.dropsPrimaryAfterRejectedSend = dropsPrimaryAfterRejectedSend
        self.singleAccount = singleAccount
    }

    /// Reads the failure modes from the launch environment.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DebugTwoAccountNodeSender {
        DebugTwoAccountNodeSender(
            failsSend: environment["PLAINPOST_DEBUG_NODE_FAILING_SEND"] == "1",
            dropsPrimaryAfterRejectedSend: environment["PLAINPOST_DEBUG_NODE_DROP_PRIMARY_AFTER_REJECTED_SEND"] == "1",
            singleAccount: environment["PLAINPOST_DEBUG_NODE_SINGLE_ACCOUNT"] == "1"
        )
    }

    private var listedAccounts: [Account] {
        if singleAccount { return accounts.filter(\.primary) }
        return dropsPrimaryAfterRejectedSend && rejectedSend ? accounts.filter { !$0.primary } : accounts
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { nil }

    nonisolated func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        epochs.set(epoch, for: logicalMailboxID)
    }

    nonisolated func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        guard let epoch = epochs.epoch(for: logicalMailboxID) else { throw NodeSyncError.invalidValue }
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "00112233-4455-6677-8899-aabbccddeeff", authorityEpoch: epoch,
            clientID: "11111111-2222-3333-8444-555555555555", idempotencyKey: idempotencyKey,
            issuedAt: issuedAt, logicalMailboxID: logicalMailboxID,
            nodeID: Self.nodeID, operation: variant, trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64)))
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        switch path {
        case "/v1/mail/capabilities":
            return ok(try NodeSyncMailModeCodec.encodeMailCapabilities(NodeSyncMailCapabilities(
                googleImport: false, imapImport: false, mirrorCoordinates: true, multiAccount: true
            )))
        case "/v1/mail/accounts":
            let listed = try listedAccounts.map {
                try NodeSyncMailAccount(
                    assignments: try assignments($0), logicalMailboxID: $0.logicalMailboxID, primary: $0.primary,
                    providerIdentity: $0.identity, providerKind: "gmail", state: .ready
                )
            }
            let primaryState: NodeSyncMailPrimaryState = listed.contains(where: \.primary) ? .available : .unavailable
            return ok(try NodeSyncMailModeCodec.encodeMailAccountsResult(try NodeSyncMailAccountsResult(accounts: listed, primaryState: primaryState)))
        case "/v1/mail/snapshot":
            let request = try NodeSyncMailModeCodec.decodeAccountSnapshotRequest(body)
            guard let account = accounts.first(where: { $0.logicalMailboxID == request.logicalMailboxID }) else { return status(403) }
            let listed = place(account).path == "Trash" ? [] : [message(account)]
            return ok(try NodeSyncCodec.encodeSnapshotPage(try NodeSyncSnapshotPage(messages: listed, nextCursor: "", revision: "1")))
        case "/v1/mail/deltas":
            let request = try NodeSyncCodec.decodeDeltaRequest(body)
            let start = request.after.isEmpty ? changes.count : Int(request.after.dropFirst(2)) ?? 0
            let page = Array(changes.dropFirst(start).prefix(Int(request.limit)))
            return ok(try NodeSyncMailModeCodec.encodeMailDeltaPage(try NodeSyncMailDeltaPage(
                changes: request.after.isEmpty ? [] : page, nextCursor: "d:\(start + (request.after.isEmpty ? 0 : page.count))",
                revision: String(changes.count + 1), waitingAccounts: []
            )))
        case "/v1/mail/mirror/coordinates":
            let request = try NodeSyncMailModeCodec.decodeMirrorCoordinatesRequest(body)
            let records = try request.messageIDs.compactMap { id -> NodeSyncMirrorCoordinate? in
                guard let index = accounts.firstIndex(where: { $0.messageID == id }) else { return nil }
                let account = accounts[index]
                let current = place(account)
                return try NodeSyncMirrorCoordinate(memberships: [try NodeSyncMirrorMembership(
                    flags: current.flags, logicalMailboxID: account.logicalMailboxID, mailboxPath: current.path,
                    uid: UInt32(index + 1), uidValidity: 1
                )], messageID: id, rfcMessageID: "<\(id)@fixture.test>")
            }
            return ok(try NodeSyncMailModeCodec.encodeMirrorCoordinatesResult(try NodeSyncMirrorCoordinatesResult(records: records)))
        case "/v1/status":
            let primary = accounts.first(where: \.primary)!
            return ok(try NodeSyncCodec.encodeStatusResult(try NodeSyncStatusResult(
                revision: "1", state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0",
                storage: "managed", providerIdentity: primary.identity, assignments: try assignments(primary),
                backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
            )))
        case "/v1/mailboxes/assignments":
            let primary = accounts.first(where: \.primary)!
            return ok(try NodeSyncCodec.encodeMailboxAssignmentsResult(try NodeSyncMailboxAssignmentsResult(assignments: try assignments(primary))))
        case "/v1/mutations":
            let operation = try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest(body).canonicalOperation)
            guard let account = accounts.first(where: { $0.logicalMailboxID == operation.unsigned.logicalMailboxID }) else { return status(403) }
            if failsSend, case .send = operation.unsigned.operation {
                rejectedSend = true
                let entry = "send rejected \(account.identity)"
                await MainActor.run { NotificationCenter.default.post(name: .plainpostDebugNodeMutation, object: entry) }
                // As the Node answers a send it refuses: a definite rejection, nothing sent.
                return ok(try NodeSyncCodec.encodeMutationResult(try NodeSyncMutationResult(
                    idempotencyKey: operation.unsigned.idempotencyKey, state: "rejected"
                )))
            }
            if case let .saveDraft(draftID, _, _, _) = operation.unsigned.operation {
                savedDraftIDs.insert(draftID)
            }
            try apply(operation.unsigned.operation, to: account)
            let entry = "\(Self.kind(of: operation.unsigned.operation)) \(account.identity)"
            await MainActor.run { NotificationCenter.default.post(name: .plainpostDebugNodeMutation, object: entry) }
            return ok(try NodeSyncCodec.encodeMutationResult(try NodeSyncMutationResult(
                idempotencyKey: operation.unsigned.idempotencyKey, state: "applied"
            )))
        case let path where path.hasPrefix("/v1/drafts/"):
            let draftID = String(path.dropFirst("/v1/drafts/".count))
            guard savedDraftIDs.contains(draftID) else { return status(404) }
            return ok(try NodeSyncCodec.encodeDraftState(try NodeSyncDraftState(draftID: draftID, revision: "1", state: "appended")))
        case "/v1/search":
            return ok(try NodeSyncCodec.encodeSearchPage(try NodeSyncSearchPage(messages: [], nextCursor: "", revision: "1")))
        case let path where path.hasPrefix("/v1/messages/"):
            guard let messageID = Self.decodeMessageToken(String(path.dropFirst("/v1/messages/".count))),
                  let account = accounts.first(where: { $0.messageID == messageID }) else { return status(404) }
            return ok(try NodeSyncCodec.encodeMessageResult(try NodeSyncMessageResult(message: message(account))))
        case let path where path.hasPrefix("/v1/mail/messages/"):
            // Scoped read: like the Node, a message of another account is
            // not found through this account's logical mailbox.
            let segments = path.dropFirst("/v1/mail/messages/".count).split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 2,
                  let scope = try? NodeSyncCodec.decodeLogicalMailboxID(String(segments[0])),
                  let messageID = Self.decodeMessageToken(String(segments[1])),
                  let account = accounts.first(where: { $0.logicalMailboxID == scope && $0.messageID == messageID }) else { return status(404) }
            return ok(try NodeSyncCodec.encodeMessageResult(try NodeSyncMessageResult(message: message(account))))
        default:
            return status(404)
        }
    }

    private func place(_ account: Account) -> (path: String, flags: [String]) {
        placement[account.messageID] ?? ("INBOX", [])
    }

    /// A read, archive or delete changes the message as the Node would, and publishes it.
    private func apply(_ operation: NodeSyncOperationVariant, to account: Account) throws {
        var current = place(account)
        switch operation {
        case let .setRead(_, read):
            current.flags = (read ? ["seen"] : []) + current.flags.filter { $0 == "flagged" }
        case .archive:
            current.path = "Archive"
        case .delete:
            current.path = "Trash"
        case let .setFlagged(_, flagged):
            current.flags = flagged ? Array(Set(current.flags + ["flagged"])).sorted() : current.flags.filter { $0 != "flagged" }
        case let .move(_, path):
            current.path = path
        default:
            return
        }
        placement[account.messageID] = current
        changes.append(try NodeSyncChange(
            kind: "upsert", logicalMailboxID: account.logicalMailboxID,
            messageID: account.messageID, threadID: "thread-\(account.messageID)"
        ))
    }

    private static func decodeMessageToken(_ token: String) -> String? {
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func kind(of operation: NodeSyncOperationVariant) -> String {
        switch operation {
        case .saveDraft: "saveDraft"
        case .deleteDraft: "deleteDraft"
        case .send: "send"
        case .setLabels: "setLabels"
        case let .setRead(_, read): read ? "markRead" : "markUnread"
        case .archive: "archive"
        case .delete: "delete"
        case let .setFlagged(_, flagged): flagged ? "flag" : "unflag"
        case .move: "move"
        }
    }

    private func assignments(_ account: Account) throws -> [NodeSyncDiscoveredMailbox] {
        try account.mailboxes.map {
            try NodeSyncDiscoveredMailbox(
                displayName: $0.displayName, logicalMailboxID: account.logicalMailboxID,
                mailboxHandle: $0.handle, role: $0.role, authorityEpoch: "1"
            )
        }
    }

    private func message(_ account: Account) -> NodeSyncMessage {
        NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: place(account).flags,
            from: [NodeSyncAddress(displayName: "Plainpost fixture", mailbox: "fixture@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: account.messageID,
            inReplyTo: [], labels: ["inbox"], receivedAt: "2026-09-14T10:00:00Z", references: [],
            replyTo: [], sentAt: "2026-09-14T10:00:00Z", subject: account.subject,
            textBody: NodeSyncBody(state: .complete, value: "Fixture message for \(account.identity)."),
            threadID: "thread-\(account.messageID)",
            to: [NodeSyncAddress(displayName: "", mailbox: account.identity)]
        )
    }

    private func ok(_ body: Data) -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: body)
    }

    private func status(_ code: Int) -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: code, url: url, headers: [:], body: Data())
    }
}

private final class DebugAuthorityEpochs: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [LogicalMailboxID: String] = [:]

    /// Monotonic, like `NodeSessionTransport`.
    func set(_ epoch: String, for logicalMailboxID: LogicalMailboxID) {
        lock.lock(); defer { lock.unlock() }
        if let installed = epochs[logicalMailboxID].flatMap(UInt64.init), let incoming = UInt64(epoch), installed >= incoming { return }
        epochs[logicalMailboxID] = epoch
    }

    func epoch(for logicalMailboxID: LogicalMailboxID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return epochs[logicalMailboxID]
    }
}

/// Shows the last mutation the fixture Node accepted, as "<kind> <account>".
struct DebugNodeMutationLog: ViewModifier {
    let isEnabled: Bool
    @State private var last: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if isEnabled, let last {
                    Text(last)
                        .font(.caption2)
                        .padding(4)
                        .background(.background)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("debug.node-mutation.last")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .plainpostDebugNodeMutation)) { notification in
                guard isEnabled, let entry = notification.object as? String else { return }
                last = entry
            }
    }
}

/// Removes every debug UI-acceptance fixture database left by a previous launch, before this
/// launch seeds its own. Each of the fixtures below (and the local-mail acceptance flow) seeds
/// a fresh, UUID-named directory under Application Support on every debug launch and never
/// removes it, so a simulator used for UI tests collects one directory per launch. Ledger Task 8.
enum DebugUIAcceptanceFixtures {
    private static let directoryPrefixes = [
        "Plainpost-approval-acceptance-",
        "Plainpost-search-acceptance-",
        "Plainpost-realistic-acceptance-",
        "Plainpost-ask-mail-acceptance-",
        "Plainpost-local-acceptance-",
    ]

    static func removeStale() {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where directoryPrefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

/// Seeds a pending agent request in the isolated UI acceptance database.
/// The test only reads this request; the fixture never invokes delivery.
@MainActor
enum DebugApprovalQueueFixture {
    static func seed(databaseURL: URL) throws {
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        if !(try store.approvalQueueRequests).isEmpty { return }
        let agent = Actor(
            id: "fixture-agent", kind: .mcpAgent, displayName: "Fixture Agent",
            permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
        )
        let draft = try store.createDraft(
            Draft(
                id: DraftID("draft_ui_approval"),
                // The fixture Node's primary account, as the phone adds it from the Node.
                accountID: AccountID.stableAccountID(email: EmailAddress("ada@example.test")),
                from: EmailAddress("ada@example.test"),
                to: [EmailAddress("reviewer@example.test")], cc: [], bcc: [],
                subject: "Review the quarterly plan",
                bodyPlain: "Please review the attached quarterly plan.",
                createdBy: agent.id, aiGenerated: false, sourceThreadID: nil,
                attachments: [DraftAttachment(
                    id: "quarterly-plan", filename: "Quarterly plan.txt",
                    mimeType: "text/plain", data: Data("Fixture attachment".utf8)
                )]
            ),
            actor: agent
        )
        _ = try store.requestSend(draftID: draft.id, actor: agent, reason: "Review before sending")
    }
}

enum DebugLocalSearchFixture {
    static func seed(databaseURL: URL) throws {
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("post-search-fixture"), displayName: "Search Fixture",
            email: EmailAddress("reader@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("post-search-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("post-search-message"), threadID: nil,
                from: EmailAddress("notifications@post.example.test"),
                fromDisplayName: "Post CH Ltd", subject: "Parcel update",
                preview: "Your parcel is on its way", smartCategory: .personal
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
            uid: 1, notificationEligible: false
        )
    }
}

/// A Direct account with four unread messages, for the Ask Mail clean-up
/// acceptance ("Group my unread emails"). Smart Inbox may reclassify the
/// seeded categories at launch (on the iPhone Air simulator 3 of 4 stay
/// automated); the acceptance relies only on the Automated block existing.
enum DebugAskMailFixture {
    static func seed(databaseURL: URL) throws {
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("ask-mail-fixture"), displayName: "Ask Mail Fixture",
            email: EmailAddress("reader@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("ask-mail-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let messages: [(String, String, String, SmartCategory)] = [
            ("digest@news.example.test", "Weekly Digest", "This week in design", .newsletter),
            ("letters@news.example.test", "Morning Letter", "Five stories for today", .newsletter),
            ("alerts@service.example.test", "Service Alerts", "Your backup finished", .notification),
            ("ada@example.test", "Ada Lovelace", "Lunch on Friday?", .personal),
        ]
        for (index, message) in messages.enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("ask-mail-message-\(index)"), threadID: nil,
                    from: EmailAddress(message.0), fromDisplayName: message.1,
                    subject: message.2, preview: message.2, smartCategory: message.3
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
                uid: index + 1, notificationEligible: false
            )
        }
    }
}

/// A realistic Direct-mail corpus for the iPhone UI suite, ported from the 2026-09-28 QA
/// audit's seed script: a three-message thread, people, newsletters, receipts, notifications,
/// an invitation, a raw-header sender, a long and an empty subject, and Sent, Archive and
/// Trash folders. The account has no server; its mail is already in the store.
enum DebugRealisticMailFixture {
    static let accountID = AccountID("realistic-fixture")

    private struct Seed {
        let id: String
        let from: String
        let name: String?
        let subject: String
        let body: String
        let category: SmartCategory
        let hoursAgo: Double
        var isSeen = false
        var mailbox = "INBOX"
        var thread: String?
    }

    private static let seeds: [Seed] = [
        Seed(id: "plan-1", from: "maria.chen@northwind.example", name: "Maria Chen", subject: "Quarterly planning — draft agenda",
             body: "Hi,\n\nAttached is the draft agenda for Thursday. Could you look at section 3 (hiring) and tell me if the numbers look right?\n\nThanks,\nMaria",
             category: .personal, hoursAgo: 50, isSeen: true, thread: "plan"),
        Seed(id: "plan-2", from: "reader@example.test", name: "Reader", subject: "Re: Quarterly planning — draft agenda",
             body: "Looks good overall. Section 3 is missing the two contractor roles.\n\n> Could you look at section 3",
             category: .personal, hoursAgo: 48, isSeen: true, mailbox: "Sent", thread: "plan"),
        Seed(id: "plan-3", from: "maria.chen@northwind.example", name: "Maria Chen", subject: "Re: Quarterly planning — draft agenda",
             body: "Good catch — updated. See you Thursday at 10:00 in the Harbour room.\n\nMaria",
             category: .personal, hoursAgo: 3, thread: "plan"),
        Seed(id: "dinner", from: "tom@okafor.example", name: "Tom Okafor", subject: "Dinner on Saturday?",
             body: "Hey! Are you free Saturday evening? Thinking of the new Georgian place on Main St. 7pm?\n\nTom",
             category: .personal, hoursAgo: 5),
        Seed(id: "appointment", from: "elena.rossi@clinic.example", name: "Dr. Elena Rossi", subject: "Your appointment is confirmed",
             body: "Dear Reader,\n\nYour appointment on Tuesday 6 October at 09:30 is confirmed. Please arrive 10 minutes early.\n\nKind regards,\nDr. Rossi",
             category: .personal, hoursAgo: 20),
        Seed(id: "boiler", from: "peter.novak@lettings.example", name: "Landlord — Peter Novak", subject: "Boiler service next week",
             body: "Hello,\n\nThe engineer will come on Wednesday between 8 and 12 to service the boiler. Please make sure someone is home.\n\nPeter",
             category: .personal, hoursAgo: 30, isSeen: true),
        Seed(id: "brief", from: "brief@news.example", name: "The Morning Brief", subject: "Tuesday: markets rally, a new comet, and what to cook tonight",
             body: "Markets rallied on Tuesday. A new comet is visible after dusk.", category: .newsletter, hoursAgo: 8),
        Seed(id: "producthunt", from: "hello@producthunt.example", name: "Product Hunt Daily", subject: "Top 5 launches today",
             body: "Five launches worth a look today.", category: .newsletter, hoursAgo: 12),
        Seed(id: "figma", from: "no-reply@figma.example", name: "Figma", subject: "What’s new in Figma this month",
             body: "New features for teams this month.", category: .newsletter, hoursAgo: 40, isSeen: true),
        Seed(id: "order", from: "auto-confirm@amazon.example", name: "Amazon.example", subject: "Your order #114-2231 has shipped",
             body: "Your package with 2 items is on the way. Arriving Thursday.", category: .receipt, hoursAgo: 15),
        Seed(id: "uber", from: "receipts@uber.example", name: "Uber Receipts", subject: "Your Thursday evening trip with Uber",
             body: "Total: CHF 23.40\nThanks for riding.", category: .receipt, hoursAgo: 44, isSeen: true),
        Seed(id: "parcel", from: "noreply@post.example", name: "Swiss Post", subject: "Parcel update: out for delivery",
             body: "Your parcel 99.00.123456.7890 is out for delivery today.", category: .notification, hoursAgo: 2),
        Seed(id: "github", from: "notifications@github.example", name: "GitHub", subject: "[plainpost/app] Fix compact navigation (#412)",
             body: "@olhapi requested your review on this pull request.", category: .notification, hoursAgo: 1),
        Seed(id: "invite", from: "calendar-notification@google.example", name: "Google Calendar", subject: "Invitation: Design review @ Fri 2 Oct 14:00",
             body: "You have been invited to Design review.", category: .invitation, hoursAgo: 26),
        Seed(id: "bank", from: "alerts@bank.example", name: "Bank of Example", subject: "Security alert: new sign-in",
             body: "We noticed a new sign-in to your account from Safari on macOS.", category: .security, hoursAgo: 4),
        Seed(id: "vercel", from: "Vercel <notifications@vercel.example>", name: nil, subject: "Deployment ready",
             body: "Your deployment is ready.", category: .notification, hoursAgo: 7),
        Seed(id: "long", from: "someone.with.a.really.long.address@subdomain.long-domain.example",
             name: "Very Long Sender Name That Keeps Going And Going",
             subject: "This is an extremely long subject line that should be truncated gracefully in the list view without breaking the layout of the row",
             body: String(repeating: "Paragraph. ", count: 80), category: .unknown, hoursAgo: 36, isSeen: true),
        Seed(id: "nosubject", from: "anon@example.test", name: "Anonymous", subject: "",
             body: "A message with no subject.", category: .personal, hoursAgo: 110, isSeen: true),
        Seed(id: "promo-0", from: "deals0@shop0.example", name: "Promo 0", subject: "🔥 20% off everything this weekend only",
             body: "Sale! Don’t miss out.", category: .newsletter, hoursAgo: 120, isSeen: true),
        Seed(id: "promo-1", from: "deals1@shop1.example", name: "Promo 1", subject: "🔥 25% off everything this weekend only",
             body: "Sale! Don’t miss out.", category: .newsletter, hoursAgo: 127, isSeen: true),
        Seed(id: "promo-2", from: "deals2@shop2.example", name: "Promo 2", subject: "🔥 30% off everything this weekend only",
             body: "Sale! Don’t miss out.", category: .newsletter, hoursAgo: 134, isSeen: true),
        Seed(id: "archived", from: "no-reply@figma.example", name: "Figma", subject: "Your weekly Figma digest",
             body: "This week in Figma.", category: .newsletter, hoursAgo: 200, isSeen: true, mailbox: "Archive"),
        Seed(id: "trashed", from: "deals9@shop9.example", name: "Promo 9", subject: "Last chance: 50% off",
             body: "Last chance.", category: .newsletter, hoursAgo: 300, isSeen: true, mailbox: "Trash"),
    ]

    /// A sign-in code mail, for the verification-code banner acceptance.
    private static let verificationCodeSeed = Seed(
        id: "code", from: "noreply@github.example", name: "GitHub", subject: "[GitHub] Please verify your device",
        body: "Hey Reader!\n\nA sign in attempt requires further verification because we did not recognize your device. "
            + "To complete the sign in, enter the verification code on the unrecognized device.\n\n"
            + "Verification code: 482913\n\nIf you did not attempt to sign in to your account, your password may be compromised.",
        category: .security, hoursAgo: 0.5
    )

    /// A second Direct account, for the Settings account-switch acceptance.
    static let secondAccountID = AccountID("realistic-fixture-work")

    static func seed(
        databaseURL: URL, now: Date = Date(), secondAccount: Bool = false, verificationCodeMail: Bool = false
    ) throws {
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        if secondAccount { try seedSecondAccount(store, now: now) }
        guard !store.accounts.contains(where: { $0.id == accountID }) else { return }
        let account = Account(
            id: accountID, displayName: "Reader", email: EmailAddress("reader@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("realistic-inbox"), accountID: accountID, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(
                accountID: accountID, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("realistic-sent"), accountID: accountID, name: "Sent", path: "Sent", specialUse: "\\Sent"),
            Mailbox(id: MailboxID("realistic-archive"), accountID: accountID, name: "Archive", path: "Archive", specialUse: "\\Archive"),
            Mailbox(id: MailboxID("realistic-trash"), accountID: accountID, name: "Trash", path: "Trash", specialUse: "\\Trash"),
            Mailbox(id: MailboxID("realistic-drafts"), accountID: accountID, name: "Drafts", path: "Drafts", specialUse: "\\Drafts"),
        ])
        try store.cacheThread(MailThread(
            id: ThreadID("realistic-thread-plan"), accountID: accountID, subjectNormalized: "quarterly planning — draft agenda",
            participantEmails: [EmailAddress("maria.chen@northwind.example"), account.email]
        ))
        for (index, seed) in (seeds + (verificationCodeMail ? [verificationCodeSeed] : [])).enumerated() {
            let recipient = EmailAddress(seed.mailbox == "Sent" ? "maria.chen@northwind.example" : "reader@example.test")
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("realistic-\(seed.id)"),
                    threadID: seed.thread.map { ThreadID("realistic-thread-\($0)") },
                    from: EmailAddress(seed.from), fromDisplayName: seed.name,
                    subject: seed.subject, preview: seed.body, smartCategory: seed.category,
                    labels: [], isSeen: seed.isSeen, mailboxPath: seed.mailbox, isDeleted: false,
                    body: seed.body, sentAt: now.addingTimeInterval(-seed.hoursAgo * 3600), to: [recipient]
                ),
                metadata: IncomingMessageSearchMetadata(to: [recipient], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: accountID, mailboxPath: seed.mailbox, uidValidity: 1,
                uid: index + 1, notificationEligible: false
            )
        }
    }

    private static func seedSecondAccount(_ store: SQLiteMailStore, now: Date) throws {
        guard !store.accounts.contains(where: { $0.id == secondAccountID }) else { return }
        let account = Account(
            id: secondAccountID, displayName: "Work", email: EmailAddress("work@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("realistic-work-inbox"), accountID: secondAccountID,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(
                accountID: secondAccountID, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let recipient = account.email
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("realistic-work-welcome"), threadID: nil,
                from: EmailAddress("it@work.example"), fromDisplayName: "Work IT",
                subject: "Welcome to the work account", preview: "Your work mailbox is ready.",
                smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                body: "Your work mailbox is ready.", sentAt: now.addingTimeInterval(-3600), to: [recipient]
            ),
            metadata: IncomingMessageSearchMetadata(to: [recipient], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: secondAccountID, mailboxPath: "INBOX", uidValidity: 1,
            uid: 1, notificationEligible: false
        )
    }
}
#endif
