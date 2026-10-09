import CryptoKit
import Foundation

public struct AccountID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MailboxID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MessageID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ThreadID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct DraftID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct SendRequestID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct EmailAddress: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PlainpostError: Error, Equatable, Sendable {
    case permissionDenied(String)
    case validationFailed(String)
    case notFound(String)
}

public struct MessageSummary: Equatable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case threadID
        case from
        case fromDisplayName
        case subject
        case preview
        case body
        case bodyHTML
        case smartCategory
        case labels
        case isSeen
        case mailboxPath
        case isDeleted
        case sentAt
        case rfcMessageID
        case inReplyTo
        case references
        case replyTo
        case to
        case cc
        case attachments
    }

    public let id: MessageID
    public let threadID: ThreadID?
    public let from: EmailAddress
    public let fromDisplayName: String?
    public let subject: String
    public let preview: String
    public let body: String
    public let bodyHTML: String?
    public let smartCategory: SmartCategory
    public let labels: [String]
    public let isSeen: Bool
    /// Some copy of the message carries \\Flagged. Read from the store; not part of the
    /// encoded summary.
    public var isFlagged: Bool = false
    public let mailboxPath: String
    public let isDeleted: Bool
    public let sentAt: Date?
    public let rfcMessageID: String?
    public let inReplyTo: String?
    public let references: [String]
    public let replyTo: EmailAddress?
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let attachments: [MailAttachment]

    /// The same summary with `isFlagged` set.
    public func flagged(_ flagged: Bool) -> MessageSummary {
        var copy = self
        copy.isFlagged = flagged
        return copy
    }

    public init(
        id: MessageID,
        threadID: ThreadID?,
        from: EmailAddress,
        fromDisplayName: String? = nil,
        subject: String,
        preview: String,
        smartCategory: SmartCategory,
        labels: [String] = [],
        isSeen: Bool = false,
        sentAt: Date? = nil
    ) {
        self.init(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: smartCategory,
            labels: labels,
            isSeen: isSeen,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: preview,
            sentAt: sentAt
        )
    }

    public init(
        id: MessageID,
        threadID: ThreadID?,
        from: EmailAddress,
        fromDisplayName: String? = nil,
        subject: String,
        preview: String,
        body: String,
        bodyHTML: String? = nil,
        smartCategory: SmartCategory,
        labels: [String] = [],
        isSeen: Bool = false,
        sentAt: Date? = nil
    ) {
        self.init(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: smartCategory,
            labels: labels,
            isSeen: isSeen,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: body,
            bodyHTML: bodyHTML,
            sentAt: sentAt
        )
    }

    public init(
        id: MessageID,
        threadID: ThreadID?,
        from: EmailAddress,
        fromDisplayName: String? = nil,
        subject: String,
        preview: String,
        smartCategory: SmartCategory,
        labels: [String],
        isSeen: Bool,
        mailboxPath: String,
        isDeleted: Bool,
        sentAt: Date? = nil
    ) {
        self.init(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: smartCategory,
            labels: labels,
            isSeen: isSeen,
            mailboxPath: mailboxPath,
            isDeleted: isDeleted,
            body: preview,
            sentAt: sentAt
        )
    }

    public init(
        id: MessageID,
        threadID: ThreadID?,
        from: EmailAddress,
        fromDisplayName: String? = nil,
        subject: String,
        preview: String,
        smartCategory: SmartCategory,
        labels: [String],
        isSeen: Bool,
        mailboxPath: String,
        isDeleted: Bool,
        body: String,
        bodyHTML: String? = nil,
        sentAt: Date? = nil,
        rfcMessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        replyTo: EmailAddress? = nil,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        attachments: [MailAttachment] = []
    ) {
        self.id = id
        self.threadID = threadID
        self.from = from
        self.fromDisplayName = fromDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyModelValue
        self.subject = subject
        self.preview = preview
        self.body = body.isEmpty ? preview : body
        self.bodyHTML = bodyHTML?.isEmpty == false ? bodyHTML : nil
        self.smartCategory = smartCategory
        self.labels = labels
        self.isSeen = isSeen
        self.mailboxPath = mailboxPath
        self.isDeleted = isDeleted
        self.sentAt = sentAt
        self.rfcMessageID = rfcMessageID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyModelValue
        self.inReplyTo = inReplyTo?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyModelValue
        self.references = references
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MessageID.self, forKey: .id)
        threadID = try container.decodeIfPresent(ThreadID.self, forKey: .threadID)
        from = try container.decode(EmailAddress.self, forKey: .from)
        fromDisplayName = try container.decodeIfPresent(String.self, forKey: .fromDisplayName)?.nonEmptyModelValue
        subject = try container.decode(String.self, forKey: .subject)
        preview = try container.decode(String.self, forKey: .preview)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? preview
        bodyHTML = try container.decodeIfPresent(String.self, forKey: .bodyHTML)
        smartCategory = try container.decode(SmartCategory.self, forKey: .smartCategory)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        isSeen = try container.decodeIfPresent(Bool.self, forKey: .isSeen) ?? false
        mailboxPath = try container.decodeIfPresent(String.self, forKey: .mailboxPath) ?? "INBOX"
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
        rfcMessageID = try container.decodeIfPresent(String.self, forKey: .rfcMessageID)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        references = try container.decodeIfPresent([String].self, forKey: .references) ?? []
        replyTo = try container.decodeIfPresent(EmailAddress.self, forKey: .replyTo)
        to = try container.decodeIfPresent([EmailAddress].self, forKey: .to) ?? []
        cc = try container.decodeIfPresent([EmailAddress].self, forKey: .cc) ?? []
        attachments = try container.decodeIfPresent([MailAttachment].self, forKey: .attachments) ?? []
    }

    public func withLabels(_ labels: [String]) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: smartCategory,
            labels: labels,
            isSeen: isSeen,
            mailboxPath: mailboxPath,
            isDeleted: isDeleted,
            body: body,
            bodyHTML: bodyHTML,
            sentAt: sentAt,
            rfcMessageID: rfcMessageID,
            inReplyTo: inReplyTo,
            references: references,
            replyTo: replyTo,
            to: to,
            cc: cc,
            attachments: attachments
        )
    }

    public func withSmartCategory(_ category: SmartCategory) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: category,
            labels: labels,
            isSeen: isSeen,
            mailboxPath: mailboxPath,
            isDeleted: isDeleted,
            body: body,
            bodyHTML: bodyHTML,
            sentAt: sentAt,
            rfcMessageID: rfcMessageID,
            inReplyTo: inReplyTo,
            references: references,
            replyTo: replyTo,
            to: to,
            cc: cc,
            attachments: attachments
        )
    }

    public func withSeen(_ seen: Bool) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: smartCategory,
            labels: labels,
            isSeen: seen,
            mailboxPath: mailboxPath,
            isDeleted: isDeleted,
            body: body,
            bodyHTML: bodyHTML,
            sentAt: sentAt,
            rfcMessageID: rfcMessageID,
            inReplyTo: inReplyTo,
            references: references,
            replyTo: replyTo,
            to: to,
            cc: cc,
            attachments: attachments
        )
    }

    public func withMailboxPath(_ mailboxPath: String) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: smartCategory,
            labels: labels,
            isSeen: isSeen,
            mailboxPath: mailboxPath,
            isDeleted: isDeleted,
            body: body,
            bodyHTML: bodyHTML,
            sentAt: sentAt,
            rfcMessageID: rfcMessageID,
            inReplyTo: inReplyTo,
            references: references,
            replyTo: replyTo,
            to: to,
            cc: cc,
            attachments: attachments
        )
    }

    public func withDeleted(_ deleted: Bool) -> MessageSummary {
        MessageSummary(
            id: id,
            threadID: threadID,
            from: from,
            fromDisplayName: fromDisplayName,
            subject: subject,
            preview: preview,
            smartCategory: smartCategory,
            labels: labels,
            isSeen: isSeen,
            mailboxPath: mailboxPath,
            isDeleted: deleted,
            body: body,
            bodyHTML: bodyHTML,
            sentAt: sentAt,
            rfcMessageID: rfcMessageID,
            inReplyTo: inReplyTo,
            references: references,
            replyTo: replyTo,
            to: to,
            cc: cc,
            attachments: attachments
        )
    }
}

public struct MailboxMessageMembership: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public let mailboxPath: String
    public let uidValidity: Int
    public let uid: Int
    public let messageID: MessageID

    public init(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        messageID: MessageID
    ) {
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.uidValidity = uidValidity
        self.uid = uid
        self.messageID = messageID
    }
}

public enum SmartInboxClassificationFingerprint {
    public static func message(_ message: MessageSummary) -> String {
        self.message(message, classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator)
    }

    public static func message(
        _ message: MessageSummary,
        classifierDiscriminator: String = SmartInboxClassifierContract.legacyDiscriminator
    ) -> String {
        fingerprint(
            classifierDiscriminator: classifierDiscriminator,
            id: message.id.rawValue,
            from: message.from.rawValue,
            fromDisplayName: message.fromDisplayName,
            subject: message.subject,
            preview: message.preview
        )
    }

    public static func message(_ message: MailboxListMessage) -> String {
        self.message(message, classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator)
    }

    public static func message(
        _ message: MailboxListMessage,
        classifierDiscriminator: String = SmartInboxClassifierContract.legacyDiscriminator
    ) -> String {
        fingerprint(
            classifierDiscriminator: classifierDiscriminator,
            id: message.id.rawValue,
            from: message.from.rawValue,
            fromDisplayName: message.fromDisplayName,
            subject: message.subject,
            preview: message.preview
        )
    }

    public static func message(
        _ input: SmartInboxClassificationInput,
        classifierDiscriminator: String = SmartInboxClassifierContract.legacyDiscriminator
    ) -> String {
        let metadata = [
            classifierDiscriminator,
            input.message.id.rawValue,
            input.accountID.rawValue,
            input.message.from.rawValue.lowercased(),
            input.message.fromDisplayName ?? "",
            input.recipients.map(\.rawValue).map(canonicalize).sorted().joined(separator: "\n"),
            input.message.subject,
            input.message.preview,
        ].map(canonicalize)
        return digest(metadata + [String(input.bodyExcerpt.prefix(3_000))])
    }

    public static func workSet(
        inputs: [SmartInboxClassificationInput],
        discriminator: String,
        classifierDiscriminator: String,
        catalogFingerprint: String
    ) -> String {
        let fingerprints = inputs
            .filter { !$0.message.isDeleted }
            .sorted { $0.message.id.rawValue < $1.message.id.rawValue }
            .map { message($0, classifierDiscriminator: classifierDiscriminator) }
        return digest([
            "smart-inbox-labels-v1",
            discriminator,
            classifierDiscriminator,
            catalogFingerprint,
        ] + fingerprints)
    }

    public static func workSet(messages: [MessageSummary], discriminator: String) -> String {
        workSet(
            messages: messages,
            discriminator: discriminator,
            classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator
        )
    }

    public static func workSet(
        messages: [MessageSummary],
        discriminator: String,
        classifierDiscriminator: String
    ) -> String {
        let inputs = messages
            .filter { !$0.isDeleted }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { message($0, classifierDiscriminator: classifierDiscriminator) }
        return digest(["smart-inbox-v4", discriminator, classifierDiscriminator] + inputs)
    }


    public static func workSet(messages: [MailboxListMessage], discriminator: String) -> String {
        workSet(
            messages: messages,
            discriminator: discriminator,
            classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator
        )
    }

    public static func workSet(
        messages: [MailboxListMessage],
        discriminator: String,
        classifierDiscriminator: String
    ) -> String {
        let inputs = messages
            .filter { !$0.isDeleted }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { message($0, classifierDiscriminator: classifierDiscriminator) }
        return digest(["smart-inbox-v4", discriminator, classifierDiscriminator] + inputs)
    }

    private static func fingerprint(
        classifierDiscriminator: String,
        id: String,
        from: String,
        fromDisplayName: String?,
        subject: String,
        preview: String
    ) -> String {
        digest([
            classifierDiscriminator,
            id,
            from.lowercased(),
            fromDisplayName ?? "",
            subject,
            preview,
        ].map(canonicalize))
    }

    private static func canonicalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func digest(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nonEmptyModelValue: String? {
        isEmpty ? nil : self
    }
}

public struct Account: Equatable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case email
        case username
        case sentMailbox
        case imapHost
        case imapPort
        case smtpHost
        case smtpPort
    }

    public let id: AccountID
    public let displayName: String
    public let email: EmailAddress
    public let username: String
    public let sentMailbox: String
    public let imapHost: String
    public let imapPort: UInt16
    public let smtpHost: String
    public let smtpPort: Int

    public init(
        id: AccountID,
        displayName: String,
        email: EmailAddress,
        imapHost: String,
        imapPort: UInt16 = 993,
        smtpHost: String,
        smtpPort: Int = 587
    ) {
        self.init(
            id: id,
            displayName: displayName,
            email: email,
            username: nil,
            sentMailbox: nil,
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort
        )
    }

    public init(
        id: AccountID,
        displayName: String,
        email: EmailAddress,
        username: String? = nil,
        sentMailbox: String? = nil,
        imapHost: String,
        imapPort: UInt16 = 993,
        smtpHost: String,
        smtpPort: Int = 587
    ) {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedSentMailbox = sentMailbox?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.id = id
        self.displayName = displayName
        self.email = email
        self.username = trimmedUsername.isEmpty ? email.rawValue : trimmedUsername
        self.sentMailbox = trimmedSentMailbox.isEmpty ? "Sent" : trimmedSentMailbox
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let email = try container.decode(EmailAddress.self, forKey: .email)
        self.init(
            id: try container.decode(AccountID.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            email: email,
            username: try container.decodeIfPresent(String.self, forKey: .username),
            sentMailbox: try container.decodeIfPresent(String.self, forKey: .sentMailbox),
            imapHost: try container.decode(String.self, forKey: .imapHost),
            imapPort: try container.decodeIfPresent(UInt16.self, forKey: .imapPort) ?? 993,
            smtpHost: try container.decode(String.self, forKey: .smtpHost),
            smtpPort: try container.decodeIfPresent(Int.self, forKey: .smtpPort) ?? 587
        )
    }
}

public struct Mailbox: Equatable, Codable, Sendable {
    public let id: MailboxID
    public let accountID: AccountID
    public let name: String
    public let path: String
    public let specialUse: String?

    public init(id: MailboxID, accountID: AccountID, name: String, path: String, specialUse: String?) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.path = path
        self.specialUse = specialUse
    }
}

public struct MailThread: Equatable, Codable, Sendable {
    public let id: ThreadID
    public let accountID: AccountID
    public let subjectNormalized: String
    public let participantEmails: [EmailAddress]

    public init(id: ThreadID, accountID: AccountID, subjectNormalized: String, participantEmails: [EmailAddress]) {
        self.id = id
        self.accountID = accountID
        self.subjectNormalized = subjectNormalized
        self.participantEmails = participantEmails
    }
}
