import Foundation

/// RFC 5322 thread identity. Prefer explicit reply ancestry; use a conservative
/// sender-and-subject fallback only when servers omit those headers.
public enum MailThreading {
    public static func threadID(
        accountID: AccountID,
        messageID: String?,
        inReplyTo: String?,
        references: [String],
        subject: String,
        sender: EmailAddress
    ) -> ThreadID {
        let root = references.first ?? inReplyTo ?? messageID
        let identity = root ?? "fallback|\(sender.rawValue.lowercased())|\(normalizedSubject(subject))"
        return ThreadID("thr_\(stableToken("\(accountID.rawValue)|\(identity)"))")
    }

    public static func normalizedSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = #"^(?:(?:re|fw|fwd)\s*(?:\[[0-9]+\])?\s*:\s*)+"#
        result = result.replacingOccurrences(of: prefixes, with: "", options: [.regularExpression, .caseInsensitive])
        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func conversationKey(for message: MessageSummary) -> String {
        guard let threadID = message.threadID?.rawValue else {
            return "message_\(message.id.rawValue)"
        }
        // Builds before RFC header threading assigned one ID per IMAP UID. Keep
        // those cached conversations together until their next mailbox sync.
        if threadID.hasPrefix("thr_uid_") {
            return "legacy_subject_\(normalizedSubject(message.subject))"
        }
        return threadID
    }

    private static func stableToken(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14695981039346656037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}
