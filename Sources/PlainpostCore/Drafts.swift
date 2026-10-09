import PlainpostComposeHash
import Foundation

public struct Draft: Equatable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case from
        case to
        case cc
        case bcc
        case subject
        case bodyPlain
        case bodyMarkdown
        case createdBy
        case aiGenerated
        case sourceThreadID
        case inReplyTo
        case references
        case attachments
        case serverDraftUID
        case serverDraftMailboxID
    }

    public let id: DraftID
    public let accountID: AccountID
    public let from: EmailAddress
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let subject: String
    public let bodyPlain: String
    /// Canonical Markdown authored in the rich composer. Nil preserves legacy plain-text drafts.
    public let bodyMarkdown: String?
    public let createdBy: String
    public let aiGenerated: Bool
    public let sourceThreadID: ThreadID?
    public let inReplyTo: String?
    public let references: [String]
    public let attachments: [DraftAttachment]
    public let serverDraftUID: Int?
    public let serverDraftMailboxID: String?

    public init(
        id: DraftID,
        accountID: AccountID,
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        subject: String,
        bodyPlain: String,
        createdBy: String,
        aiGenerated: Bool,
        sourceThreadID: ThreadID?,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [DraftAttachment] = [],
        serverDraftUID: Int? = nil,
        serverDraftMailboxID: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyMarkdown = nil
        self.createdBy = createdBy
        self.aiGenerated = aiGenerated
        self.sourceThreadID = sourceThreadID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.serverDraftUID = serverDraftUID
        self.serverDraftMailboxID = serverDraftMailboxID
    }

    public init(
        id: DraftID,
        accountID: AccountID,
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        subject: String,
        bodyPlain: String,
        bodyMarkdown: String?,
        createdBy: String,
        aiGenerated: Bool,
        sourceThreadID: ThreadID?,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [DraftAttachment] = [],
        serverDraftUID: Int? = nil,
        serverDraftMailboxID: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyMarkdown = bodyMarkdown
        self.createdBy = createdBy
        self.aiGenerated = aiGenerated
        self.sourceThreadID = sourceThreadID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.serverDraftUID = serverDraftUID
        self.serverDraftMailboxID = serverDraftMailboxID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(DraftID.self, forKey: .id),
            accountID: try container.decode(AccountID.self, forKey: .accountID),
            from: try container.decode(EmailAddress.self, forKey: .from),
            to: try container.decode([EmailAddress].self, forKey: .to),
            cc: try container.decodeIfPresent([EmailAddress].self, forKey: .cc) ?? [],
            bcc: try container.decodeIfPresent([EmailAddress].self, forKey: .bcc) ?? [],
            subject: try container.decode(String.self, forKey: .subject),
            bodyPlain: try container.decode(String.self, forKey: .bodyPlain),
            bodyMarkdown: try container.decodeIfPresent(String.self, forKey: .bodyMarkdown),
            createdBy: try container.decode(String.self, forKey: .createdBy),
            aiGenerated: try container.decode(Bool.self, forKey: .aiGenerated),
            sourceThreadID: try container.decodeIfPresent(ThreadID.self, forKey: .sourceThreadID),
            inReplyTo: try container.decodeIfPresent(String.self, forKey: .inReplyTo),
            references: try container.decodeIfPresent([String].self, forKey: .references) ?? [],
            attachments: try container.decodeIfPresent([DraftAttachment].self, forKey: .attachments) ?? [],
            serverDraftUID: try container.decodeIfPresent(Int.self, forKey: .serverDraftUID),
            serverDraftMailboxID: try container.decodeIfPresent(String.self, forKey: .serverDraftMailboxID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(cc, forKey: .cc)
        try container.encode(bcc, forKey: .bcc)
        try container.encode(subject, forKey: .subject)
        try container.encode(bodyPlain, forKey: .bodyPlain)
        try container.encodeIfPresent(bodyMarkdown, forKey: .bodyMarkdown)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(aiGenerated, forKey: .aiGenerated)
        try container.encodeIfPresent(sourceThreadID, forKey: .sourceThreadID)
        try container.encodeIfPresent(inReplyTo, forKey: .inReplyTo)
        if !references.isEmpty {
            try container.encode(references, forKey: .references)
        }
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(serverDraftUID, forKey: .serverDraftUID)
        try container.encodeIfPresent(serverDraftMailboxID, forKey: .serverDraftMailboxID)
    }

    public var contentHash: String {
        ComposeContentHash.hash(
            from: from.rawValue,
            to: to.map(\.rawValue),
            cc: cc.map(\.rawValue),
            bcc: bcc.map(\.rawValue),
            subject: subject,
            bodyPlain: bodyPlain,
            bodyMarkdown: bodyMarkdown,
            aiGenerated: aiGenerated,
            sourceThreadID: sourceThreadID?.rawValue,
            inReplyTo: inReplyTo,
            references: references,
            attachmentContentComponents: attachments.map(\.contentHashComponent)
        )
    }

    public func validated() throws -> Draft {
        try DraftAttachmentContract.validate(attachments)
        return self
    }

    public func applying(_ patch: DraftPatch) -> Draft {
        Draft(
            id: id,
            accountID: accountID,
            from: patch.from ?? from,
            to: patch.to ?? to,
            cc: patch.cc ?? cc,
            bcc: patch.bcc ?? bcc,
            subject: patch.subject ?? subject,
            bodyPlain: patch.bodyPlain ?? bodyPlain,
            bodyMarkdown: patch.bodyMarkdown ?? bodyMarkdown,
            createdBy: createdBy,
            aiGenerated: patch.aiGenerated ?? aiGenerated,
            sourceThreadID: sourceThreadID,
            inReplyTo: inReplyTo,
            references: references,
            attachments: patch.attachments ?? attachments,
            serverDraftUID: serverDraftUID,
            serverDraftMailboxID: serverDraftMailboxID
        )
    }

    public func recordingServerDraft(uid: Int?, mailboxID: String) -> Draft {
        Draft(
            id: id,
            accountID: accountID,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            bodyPlain: bodyPlain,
            bodyMarkdown: bodyMarkdown,
            createdBy: createdBy,
            aiGenerated: aiGenerated,
            sourceThreadID: sourceThreadID,
            inReplyTo: inReplyTo,
            references: references,
            attachments: attachments,
            serverDraftUID: uid,
            serverDraftMailboxID: mailboxID
        )
    }
}

public struct DraftPatch: Equatable, Sendable {
    public let from: EmailAddress?
    public let to: [EmailAddress]?
    public let cc: [EmailAddress]?
    public let bcc: [EmailAddress]?
    public let subject: String?
    public let bodyPlain: String?
    public let bodyMarkdown: String?
    public let aiGenerated: Bool?
    public let attachments: [DraftAttachment]?

    public init(
        from: EmailAddress? = nil,
        to: [EmailAddress]? = nil,
        cc: [EmailAddress]? = nil,
        bcc: [EmailAddress]? = nil,
        subject: String? = nil,
        bodyPlain: String? = nil,
        aiGenerated: Bool? = nil,
        attachments: [DraftAttachment]? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyMarkdown = nil
        self.aiGenerated = aiGenerated
        self.attachments = attachments
    }

    public init(
        from: EmailAddress? = nil,
        to: [EmailAddress]? = nil,
        cc: [EmailAddress]? = nil,
        bcc: [EmailAddress]? = nil,
        subject: String? = nil,
        bodyPlain: String? = nil,
        bodyMarkdown: String?,
        aiGenerated: Bool? = nil,
        attachments: [DraftAttachment]? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyMarkdown = bodyMarkdown
        self.aiGenerated = aiGenerated
        self.attachments = attachments
    }
}

public enum ReplyAddressPolicy {
    public static func recipient(replyTo: EmailAddress?, from: EmailAddress) -> EmailAddress? {
        if let replyTo, isSafe(replyTo) {
            return replyTo
        }
        return isSafe(from) ? from : nil
    }

    public static func isSafe(_ address: EmailAddress) -> Bool {
        let rawAddress = address.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddress.contains(where: \.isWhitespace) else { return false }

        let parts = rawAddress.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }

        return true
    }

    public static func isLikelyAutomated(_ address: EmailAddress) -> Bool {
        let rawAddress = address.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPart = rawAddress.split(separator: "@", maxSplits: 1).first.map(String.init)?.lowercased()
        let deniedLocalParts = Set([
            "noreply",
            "no-reply",
            "notifications",
            "notification",
            "mailer-daemon",
        ])
        return localPart.map(deniedLocalParts.contains) ?? false
    }
}

public enum ReplyDraftKind: String, Codable, Equatable, Sendable {
    case reply
    case replyAll
    case forward
}

public struct ReplyDraftFactory: Sendable {
    public init() {}

    public func makeDraft(
        source: MessageSummary,
        account: Account,
        actor: Actor,
        id: DraftID
    ) throws -> Draft {
        try makeDraft(source: source, account: account, actor: actor, id: id, kind: .reply)
    }

    public func makeDraft(
        source: MessageSummary,
        account: Account,
        actor: Actor,
        id: DraftID,
        kind: ReplyDraftKind
    ) throws -> Draft {
        if kind == .forward {
            return Draft(
                id: id,
                accountID: account.id,
                from: account.email,
                to: [],
                cc: [],
                bcc: [],
                subject: prefixedSubject(source.subject, prefix: "Fwd:"),
                bodyPlain: quotedBody(source.body),
                bodyMarkdown: quotedBody(source.body),
                createdBy: actor.id,
                aiGenerated: false,
                sourceThreadID: source.threadID,
                inReplyTo: nil,
                references: []
            )
        }

        guard let recipient = ReplyAddressPolicy.recipient(replyTo: source.replyTo, from: source.from) else {
            throw PlainpostError.validationFailed("This message does not have a safe reply address.")
        }

        var to = [recipient]
        var cc: [EmailAddress] = []
        if kind == .replyAll {
            let localAddress = account.email.rawValue.lowercased()
            var seen = Set([localAddress])
            to = []
            if seen.insert(recipient.rawValue.lowercased()).inserted {
                to.append(recipient)
            }
            for address in source.to where ReplyAddressPolicy.isSafe(address) {
                if seen.insert(address.rawValue.lowercased()).inserted {
                    to.append(address)
                }
            }
            for address in source.cc where ReplyAddressPolicy.isSafe(address) {
                if seen.insert(address.rawValue.lowercased()).inserted {
                    cc.append(address)
                }
            }
        }

        var ancestry = source.references
        if ancestry.isEmpty,
           let parent = source.inReplyTo,
           isValidMessageIdentifier(parent) {
            ancestry.append(parent)
        }
        let references = orderedUnique(ancestry + [source.rfcMessageID].compactMap { $0 })
        return Draft(
            id: id,
            accountID: account.id,
            from: account.email,
            to: to,
            cc: cc,
            bcc: [],
            subject: prefixedSubject(source.subject, prefix: "Re:"),
            bodyPlain: "",
            bodyMarkdown: "",
            createdBy: actor.id,
            aiGenerated: false,
            sourceThreadID: source.threadID,
            inReplyTo: source.rfcMessageID,
            references: references
        )
    }

    private func prefixedSubject(_ subject: String, prefix: String) -> String {
        subject.range(of: prefix, options: [.anchored, .caseInsensitive]) == nil
            ? "\(prefix) \(subject)"
            : subject
    }

    private func quotedBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func isValidMessageIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 900
            && value.range(of: #"^<[^<>\s]+>$"#, options: .regularExpression) != nil
    }
}

public struct DraftAttachment: Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(id: String, filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    fileprivate var contentHashComponent: String {
        ComposeContentHash.attachmentComponent(
            id: id,
            filename: filename,
            mimeType: mimeType,
            data: data
        )
    }
}

public enum DraftAttachmentContract {
    public static let maximumCount = 10
    public static let maximumBytesPerAttachment = 2 * 1_024 * 1_024
    public static let maximumAggregateBytes = 8 * 1_024 * 1_024
    public static let maximumIDUTF8Length = 128
    public static let maximumFilenameUTF8Length = 255
    public static let maximumMIMETypeUTF8Length = 127
    private static let forbiddenFilenameBytes: Set<UInt8> = [0, 10, 13, 47, 92]

    public static func validate(_ attachments: [DraftAttachment]) throws {
        guard attachments.count <= maximumCount,
              Set(attachments.map(\.id)).count == attachments.count else {
            throw PlainpostError.validationFailed("The attachment list is invalid.")
        }

        var aggregateBytes = 0
        for attachment in attachments {
            guard !attachment.id.isEmpty,
                  attachment.id.utf8.count <= maximumIDUTF8Length,
                  !attachment.filename.isEmpty,
                  attachment.filename.utf8.count <= maximumFilenameUTF8Length,
                  attachment.filename != ".",
                  attachment.filename != "..",
                  attachment.filename.utf8.allSatisfy({ !forbiddenFilenameBytes.contains($0) }),
                  !attachment.mimeType.isEmpty,
                  attachment.mimeType.utf8.count <= maximumMIMETypeUTF8Length,
                  isValidMIMEType(attachment.mimeType),
                  attachment.data.count <= maximumBytesPerAttachment else {
                throw PlainpostError.validationFailed("An attachment is invalid.")
            }

            aggregateBytes += attachment.data.count
            guard aggregateBytes <= maximumAggregateBytes else {
                throw PlainpostError.validationFailed("Attachments exceed the draft size limit.")
            }
        }
    }

    private static func isValidMIMEType(_ value: String) -> Bool {
        let parts = value.utf8.split(separator: 47, omittingEmptySubsequences: false)
        let allowedPunctuation: Set<UInt8> = [33, 35, 36, 38, 94, 95, 46, 43, 45]
        let isAllowed: (UInt8) -> Bool = { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || allowedPunctuation.contains(byte)
        }
        return parts.count == 2
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(isAllowed) }
    }
}

public struct RenderedMessage: Equatable, Sendable {
    public let headers: String
    public let body: String
    public let envelopeRecipients: [EmailAddress]

    public init(headers: String, body: String, envelopeRecipients: [EmailAddress]) {
        self.headers = headers
        self.body = body
        self.envelopeRecipients = envelopeRecipients
    }
}

public struct DraftRenderer: Sendable {
    /// The fixed Date header that Sync Node draft saves have always carried.
    /// The weekday is wrong for that date; it stays byte-for-byte as it was.
    public static let stableSaveDateHeader = "Thu, 08 Jul 2026 20:00:00 +0000"

    private let dateHeader: @Sendable () -> String

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.dateHeader = { Self.dateHeaderValue(now()) }
    }

    public init(dateHeader: String) {
        self.dateHeader = { dateHeader }
    }

    public func render(_ draft: Draft) throws -> RenderedMessage {
        _ = try draft.validated()
        let recipientCount = draft.to.count + draft.cc.count + draft.bcc.count
        guard recipientCount > 0, recipientCount <= 256 else {
            throw PlainpostError.validationFailed("Draft must have between 1 and 256 recipients.")
        }
        try validateHeaderValue(draft.from.rawValue)
        try validateHeaderValue(draft.subject)
        try (draft.to + draft.cc + draft.bcc).forEach { try validateHeaderValue($0.rawValue) }

        var headerLines = [
            "From: \(draft.from.rawValue)",
            "To: \(draft.to.map(\.rawValue).joined(separator: ", "))",
            "Subject: \(encodedHeaderText(draft.subject, nameLength: "Subject: ".utf8.count))",
            "Date: \(dateHeader())",
            "Message-ID: <\(draft.id.rawValue)@plainpost.local>",
            "MIME-Version: 1.0"
        ]

        if !draft.cc.isEmpty {
            headerLines.append("Cc: \(draft.cc.map(\.rawValue).joined(separator: ", "))")
        }

        if let inReplyTo = draft.inReplyTo {
            try validateMessageIdentifier(inReplyTo)
            headerLines.append("In-Reply-To: \(inReplyTo)")
        }
        if !draft.references.isEmpty {
            let references = orderedUnique(draft.references)
            try references.forEach(validateMessageIdentifier)
            headerLines.append(contentsOf: foldedHeaderLines(name: "References", values: references))
        }

        let body: String
        if let markdown = draft.bodyMarkdown {
            let plainText = draft.bodyPlain
            let html = MarkdownEmailRenderer.html(from: markdown)
            if draft.attachments.isEmpty {
                let boundary = "plainpost-\(draft.id.rawValue)-alternative"
                headerLines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
                body = alternativeBody(plainText: plainText, html: html, boundary: boundary)
            } else {
                let boundary = "plainpost-\(draft.id.rawValue)"
                headerLines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
                body = multipartBody(for: draft, plainText: plainText, html: html, boundary: boundary)
            }
        } else if draft.attachments.isEmpty {
            headerLines.append("Content-Type: text/plain; charset=utf-8")
            body = draft.bodyPlain
        } else {
            let boundary = "plainpost-\(draft.id.rawValue)"
            headerLines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            body = multipartBody(for: draft, boundary: boundary)
        }

        return RenderedMessage(
            headers: headerLines.joined(separator: "\r\n"),
            body: body,
            envelopeRecipients: draft.to + draft.cc + draft.bcc
        )
    }

    private func alternativeBody(plainText: String, html: String, boundary: String) -> String {
        [
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            plainText,
            "--\(boundary)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            html,
            "--\(boundary)--"
        ].joined(separator: "\r\n")
    }

    private func multipartBody(
        for draft: Draft,
        plainText: String? = nil,
        html: String? = nil,
        boundary: String
    ) -> String {
        if let plainText, let html {
            let alternativeBoundary = "\(boundary)-alternative"
            var parts: [String] = [
                "--\(boundary)",
                "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"",
                "",
                alternativeBody(plainText: plainText, html: html, boundary: alternativeBoundary)
            ]
            appendAttachments(draft.attachments, to: &parts, boundary: boundary)
            parts.append("--\(boundary)--")
            return parts.joined(separator: "\r\n")
        }
        var parts: [String] = [
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            draft.bodyPlain
        ]

        appendAttachments(draft.attachments, to: &parts, boundary: boundary)
        parts.append("--\(boundary)--")
        return parts.joined(separator: "\r\n")
    }

    private func appendAttachments(_ attachments: [DraftAttachment], to parts: inout [String], boundary: String) {
        for attachment in attachments {
            let filename = attachment.filename.replacingOccurrences(of: "\"", with: "\\\"")
            parts.append(contentsOf: [
                "--\(boundary)",
                "Content-Type: \(attachment.mimeType); name=\"\(filename)\"",
                "Content-Transfer-Encoding: base64",
                "Content-Disposition: attachment; filename=\"\(filename)\"",
                "",
                attachment.data.base64EncodedString()
            ])
        }

    }

    private static func dateHeaderValue(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Non-ASCII header text goes out as RFC 2047 encoded words, so a server
    /// without SMTPUTF8 (Purelymail) still accepts it. Words are folded onto
    /// lines of at most 78 characters, and a character never splits across words.
    private func encodedHeaderText(_ value: String, nameLength: Int) -> String {
        guard value.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return value }
        // `=?UTF-8?B?` and `?=` take 12 characters; base64 turns 3 bytes into 4.
        // A continuation line starts with a space; 45 bytes keep a word within 75.
        let firstWordBytes = max(3, (78 - nameLength - 12) / 4 * 3)
        let wordBytes = 45
        var words: [String] = []
        var chunk = Data()
        for character in value {
            let bytes = Data(String(character).utf8)
            let limit = words.isEmpty ? firstWordBytes : wordBytes
            if !chunk.isEmpty, chunk.count + bytes.count > limit {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty {
            words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
        }
        return words.joined(separator: "\r\n ")
    }

    private func validateHeaderValue(_ value: String) throws {
        if value.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw PlainpostError.validationFailed("Header values cannot contain CR or LF.")
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func validateMessageIdentifier(_ value: String) throws {
        try validateHeaderValue(value)
        guard value.utf8.count <= 900,
              value.range(of: #"^<[^<>\s]+>$"#, options: .regularExpression) != nil else {
            throw PlainpostError.validationFailed("Reply message identifiers are invalid.")
        }
    }

    private func foldedHeaderLines(name: String, values: [String], preferredLimit: Int = 78) -> [String] {
        let prefix = "\(name):"
        var lines: [String] = []
        var current = prefix
        for value in values {
            let candidate = "\(current) \(value)"
            if current != prefix, candidate.utf8.count > preferredLimit {
                lines.append(current)
                current = " \(value)"
            } else {
                current = candidate
            }
        }
        if current != prefix {
            lines.append(current)
        }
        return lines
    }
}
