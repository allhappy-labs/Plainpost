import Foundation
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport

/// One Node message prepared for `commitMirroredMessage`, built exactly the
/// way direct IMAP sync builds a message so both resolve to one local row.
struct NodeMirroredContent {
    let summary: MessageSummary
    let metadata: IncomingMessageSearchMetadata
    let thread: MailThread
    /// A body the Node did not deliver in full keeps the stored one.
    let preserveExistingBodies: Bool
    let hydration: NodeMirrorHydrationState
    let attachmentIDs: [String]
}

enum NodeMailMirrorMapping {
    /// The canonical base64url form `account_mail_sources` stores.
    static func logicalMailboxKey(_ id: LogicalMailboxID) throws -> String {
        try NodeSyncCodec.encodeLogicalMailboxID(id)
    }

    static func logicalMailboxID(_ key: String) throws -> LogicalMailboxID {
        try NodeSyncCodec.decodeLogicalMailboxID(key)
    }

    /// The single mailbox-path rule both sides share. The Node reports the
    /// provider mailbox name exactly as IMAP LIST sent it, and the Mac's
    /// `IMAPClient.listMailboxes` keeps the same wire name (neither decodes
    /// modified UTF-7 or enables UTF8=ACCEPT), so `Entw&APw-rfe` is
    /// `Entw&APw-rfe` on both. Paths therefore compare byte-exactly, as the
    /// stable-key lookup does; Unicode normalization here would break the
    /// match with direct rows instead of creating one.
    static func mailboxPathKey(_ path: String) -> String { path }

    /// The coordinate's memberships of this account's logical mailbox only;
    /// a membership of any other logical mailbox is ignored.
    static func memberships(of record: NodeSyncMirrorCoordinate, scope: NodeMirrorScope) -> [MirroredMembership] {
        record.memberships.compactMap { membership in
            guard (try? logicalMailboxKey(membership.logicalMailboxID)) == scope.logicalMailboxID else { return nil }
            return MirroredMembership(
                key: StableMessageKey(accountID: scope.accountID, mailboxPath: mailboxPathKey(membership.mailboxPath),
                                      uidValidity: Int(membership.uidValidity), uid: Int(membership.uid)),
                flags: membership.flags
            )
        }
    }

    /// Lowest by (mailbox path bytes, UIDVALIDITY, UID).
    static func lowest(_ memberships: [MirroredMembership]) -> MirroredMembership? {
        memberships.min { left, right in
            if left.key.mailboxPath != right.key.mailboxPath {
                return Array(left.key.mailboxPath.utf8).lexicographicallyPrecedes(Array(right.key.mailboxPath.utf8))
            }
            if left.key.uidValidity != right.key.uidValidity { return left.key.uidValidity < right.key.uidValidity }
            return left.key.uid < right.key.uid
        }
    }

    /// INBOX when present, else the lowest membership: the path the message
    /// row shows and whose flags set its seen and deleted state.
    static func preferred(_ memberships: [MirroredMembership]) -> MirroredMembership? {
        memberships.first { $0.key.mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame } ?? lowest(memberships)
    }

    /// Direct sync's identity: the account-scoped RFC Message-ID hash when
    /// there is one, else the local ID of the lowest membership.
    static func computedMessageID(accountID: AccountID, rfcMessageID: String?, memberships: [MirroredMembership]) -> MessageID? {
        if let rfcMessageID, !rfcMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MessageID(IMAPSyncService.canonicalMessageID(accountID: accountID, rfcMessageID: rfcMessageID))
        }
        guard let lowest = lowest(memberships) else { return nil }
        return MessageID(IMAPSyncService.localMessageID(
            accountID: accountID, mailboxPath: lowest.key.mailboxPath,
            uidValidity: lowest.key.uidValidity, uid: lowest.key.uid
        ))
    }

    static func content(
        of message: NodeSyncMessage, messageID: MessageID, accountID: AccountID, rfcMessageID: String?,
        memberships: [MirroredMembership], classifier: SmartCategoryClassifier
    ) -> NodeMirroredContent {
        let sender = message.from.first
        let from = EmailAddress(sender?.mailbox ?? "unknown@example.invalid")
        let text = message.textBody.state == .complete ? message.textBody.value ?? "" : ""
        let html = message.htmlBody.state == .complete ? message.htmlBody.value : nil
        let preview = concisePreview(text)
        let inReplyTo = message.inReplyTo.first
        let threadID = MailThreading.threadID(
            accountID: accountID, messageID: rfcMessageID, inReplyTo: inReplyTo,
            references: message.references, subject: message.subject, sender: from
        )
        let category = classifier.classify(CategoryInput(from: from.rawValue, subject: message.subject, headers: [:],
                                                         bodyPreview: preview))
        let preferred = preferred(memberships)
        let to = message.to.map { EmailAddress($0.mailbox) }
        let cc = message.cc.map { EmailAddress($0.mailbox) }
        let replyTo = message.replyTo.first.map { EmailAddress($0.mailbox) }
        let summary = MessageSummary(
            id: messageID, threadID: threadID, from: from,
            fromDisplayName: sender.map(\.displayName).flatMap { $0.isEmpty ? nil : $0 },
            subject: message.subject, preview: preview, smartCategory: category.category, labels: [],
            isSeen: preferred?.isSeen ?? false, mailboxPath: preferred?.key.mailboxPath ?? "INBOX",
            isDeleted: preferred?.isDeleted ?? false, body: text, bodyHTML: html,
            sentAt: message.sentAt.flatMap(date), rfcMessageID: rfcMessageID, inReplyTo: inReplyTo,
            references: message.references, replyTo: replyTo, to: to, cc: cc
        )
        let metadata = IncomingMessageSearchMetadata(
            to: to, cc: cc, bcc: message.bcc.map { EmailAddress($0.mailbox) },
            attachments: message.attachments.map { IncomingMessageAttachmentMetadata(filename: $0.filename, mimeType: $0.mime) },
            messageIdentifiers: [rfcMessageID, inReplyTo].compactMap { $0 } + message.references
        )
        let participants = [from, replyTo].compactMap { $0 } + to + cc
        let bodiesComplete = message.textBody.state == .complete && message.htmlBody.state == .complete
        let omitted = message.textBody.state == .omittedOversized || message.htmlBody.state == .omittedOversized
        return NodeMirroredContent(
            summary: summary,
            metadata: metadata,
            thread: MailThread(id: threadID, accountID: accountID,
                               subjectNormalized: MailThreading.normalizedSubject(message.subject),
                               participantEmails: participants),
            preserveExistingBodies: !bodiesComplete,
            hydration: omitted || !message.attachments.isEmpty ? .pending : .complete,
            attachmentIDs: message.attachments.map(\.id)
        )
    }

    /// Node timestamps are `yyyy-MM-ddTHH:mm:ssZ`.
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// The preview direct sync derives from a text body.
    static func concisePreview(_ text: String) -> String {
        MailPreviewNormalizer.normalized(text)
    }
}
