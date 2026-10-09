import Foundation

public enum IncomingMessageAttachmentDecoder {
    public static func decode(
        from data: Data
    ) throws -> [IncomingMessageAttachmentPayload] {
        try MIMEMessageDecoder.decodedAttachments(from: data)
    }
}

struct MIMEMessageContent: Equatable, Sendable {
    let safeText: String
    let safeHTML: String?
}

// This package-scoped value is the production provider-ingress projection.
// It deliberately holds canonical metadata and safe body states rather than
// raw MIME entities or fixture dictionaries, so both sync and conformance
// owners cross the same small, typed seam.
package struct MIMEProviderProjection: Equatable, Sendable {
    package struct Address: Equatable, Sendable {
        package let displayName: String
        package let mailbox: String

        package init(displayName: String, mailbox: String) {
            self.displayName = displayName
            self.mailbox = mailbox
        }
    }

    package enum Body: Equatable, Sendable {
        case absent
        case complete(String)
        case malformed
        case omittedOversized
    }

    package struct Part: Equatable, Sendable {
        package let path: String
        package let filename: String
        package let mediaType: String
        package let disposition: String
        package let contentID: String
        package let declaredSize: Int

        package init(
            path: String,
            filename: String,
            mediaType: String,
            disposition: String,
            contentID: String,
            declaredSize: Int
        ) {
            self.path = path
            self.filename = filename
            self.mediaType = mediaType
            self.disposition = disposition
            self.contentID = contentID
            self.declaredSize = declaredSize
        }
    }

    package let subject: String
    package let rfcMessageID: String
    package let date: String
    package let from: [Address]
    package let sender: Address?
    package let replyTo: [Address]
    package let to: [Address]
    package let cc: [Address]
    package let bcc: [Address]
    package let inReplyTo: [String]
    package let references: [String]
    package let textBody: Body
    package let htmlBody: Body
    package let parts: [Part]

    package init(
        subject: String,
        rfcMessageID: String,
        date: String,
        from: [Address],
        sender: Address?,
        replyTo: [Address],
        to: [Address],
        cc: [Address],
        bcc: [Address],
        inReplyTo: [String],
        references: [String],
        textBody: Body,
        htmlBody: Body,
        parts: [Part]
    ) {
        self.subject = subject
        self.rfcMessageID = rfcMessageID
        self.date = date
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.references = references
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.parts = parts
    }
}

package struct MIMEAttachmentDecodingLimits: Equatable, Sendable {
    package let maximumPartCount: Int
    package let maximumAttachmentCount: Int
    package let maximumAttachmentMetadataBytes: Int
    package let maximumDecodedBytesPerAttachment: Int
    package let maximumAggregateDecodedBytes: Int

    package init(
        maximumPartCount: Int,
        maximumAttachmentCount: Int,
        maximumDecodedBytesPerAttachment: Int,
        maximumAggregateDecodedBytes: Int,
        maximumAttachmentMetadataBytes: Int = IncomingMessageAttachmentPayload.maximumAttachmentMetadataBytes
    ) {
        self.maximumPartCount = maximumPartCount
        self.maximumAttachmentCount = maximumAttachmentCount
        self.maximumAttachmentMetadataBytes = maximumAttachmentMetadataBytes
        self.maximumDecodedBytesPerAttachment = maximumDecodedBytesPerAttachment
        self.maximumAggregateDecodedBytes = maximumAggregateDecodedBytes
    }

    package static let production = MIMEAttachmentDecodingLimits(
        maximumPartCount: 2_000,
        maximumAttachmentCount: IncomingMessageAttachmentPayload.maximumAttachmentCount,
        maximumDecodedBytesPerAttachment:
            IncomingMessageAttachmentPayload.maximumDecodedBytesPerAttachment,
        maximumAggregateDecodedBytes:
            IncomingMessageAttachmentPayload.maximumAggregateDecodedBytes,
        maximumAttachmentMetadataBytes:
            IncomingMessageAttachmentPayload.maximumAttachmentMetadataBytes
    )
}

enum MIMEAttachmentDecodingError: Error, Equatable, Sendable {
    case malformedMessage
    case headerLimitExceeded
    case nestingDepthLimitExceeded
    case partCountLimitExceeded
    case attachmentCountLimitExceeded
    case attachmentMetadataLimitExceeded
    case decodedSizeLimitExceeded
}

package enum MIMEMessageDecoder {
    private static let maxNestingDepth = 64
    private static let maxHeaderBytes = 2 * 1024 * 1024
    private static let maxPartCount = 2_000
    private static let maxFixtureTextBytes = 1 * 1024 * 1024

    private static func parserLimitError(_ state: MIMEParserState) -> MIMEAttachmentDecodingError? {
        if state.exceededHeaderBytes { return .headerLimitExceeded }
        if state.exceededDepth { return .nestingDepthLimitExceeded }
        if state.exceededPartCount { return .partCountLimitExceeded }
        return nil
    }

    static func displayText(from message: String) -> String? {
        guard message.contains("\n\n") || message.contains("\r\n\r\n") else {
            return nil
        }
        return displayText(from: Data(message.utf8))
    }

    static func displayText(from data: Data) -> String? {
        displayContent(from: data)?.safeText
    }

    static func displayContent(from data: Data) -> MIMEMessageContent? {
        var parserState = MIMEParserState()
        guard let root = MIMEEntity.parse(
            data,
            defaultMediaType: "text/plain",
            depth: 0,
            parserState: &parserState,
            limits: .init(maxDepth: maxNestingDepth, maxHeaderBytes: maxHeaderBytes, maxParts: maxPartCount)
        ) else {
            return nil
        }

        let plainBody = root.body(of: .plainText)
        let htmlBody = root.body(of: .html)
        guard plainBody != nil || htmlBody != nil else {
            return nil
        }
        let renderedHTML = htmlBody.map { EmailBodyRenderer.render(.html($0.text)) }
        let safeText = plainBody
            .map { EmailBodyRenderer.render(.plainText($0.text)).safeText }
            ?? renderedHTML?.safeText
            ?? ""
        return MIMEMessageContent(safeText: safeText, safeHTML: renderedHTML?.safeHTML)
    }

    /// The provider sync boundary needs the canonical body projection rather
    /// than the display convenience fallback. In particular, HTML-only mail
    /// must not manufacture a plain-text body, attachment-only mail must not
    /// persist its raw RFC 5322 source as text, and a NUL-bearing body fails
    /// closed. The legacy display API intentionally keeps its rendered-HTML
    /// text fallback for UI callers.
    static func syncContent(from data: Data) -> MIMEMessageContent? {
        var parserState = MIMEParserState()
        guard let root = MIMEEntity.parse(
            data,
            defaultMediaType: "text/plain",
            depth: 0,
            parserState: &parserState,
            limits: .init(maxDepth: maxNestingDepth, maxHeaderBytes: maxHeaderBytes, maxParts: maxPartCount)
        ), !parserState.exceededDepth, !parserState.exceededPartCount else {
            return nil
        }

        let plainBody = root.body(of: .plainText)
        let htmlBody = root.body(of: .html)
        let safeText = plainBody.flatMap(syncPlainText) ?? ""
        let safeHTML = htmlBody.flatMap(syncHTML)
        return MIMEMessageContent(safeText: safeText, safeHTML: safeHTML)
    }

    private static func syncPlainText(_ body: MIMEBody) -> String? {
        guard body.text.utf8.count <= maxFixtureTextBytes,
              !body.text.unicodeScalars.contains(UnicodeScalar(0)!) else {
            return nil
        }
        return EmailBodyRenderer.render(.plainText(body.text)).safeText
    }

    private static func syncHTML(_ body: MIMEBody) -> String? {
        guard body.text.utf8.count <= maxFixtureTextBytes,
              !body.text.unicodeScalars.contains(UnicodeScalar(0)!) else {
            return nil
        }
        return EmailBodyRenderer.render(.html(body.text)).safeHTML
    }

    static func exactPlainText(from data: Data) -> String? {
        var parserState = MIMEParserState()
        guard let root = MIMEEntity.parse(
            data,
            defaultMediaType: "text/plain",
            depth: 0,
            parserState: &parserState,
            limits: .init(maxDepth: maxNestingDepth, maxHeaderBytes: maxHeaderBytes, maxParts: maxPartCount)
        ) else {
            return nil
        }
        return root.body(of: .plainText, decodeFlowed: false)?.text
    }

    static func decodedAttachments(
        from data: Data,
        limits: MIMEAttachmentDecodingLimits = .production
    ) throws -> [IncomingMessageAttachmentPayload] {
        guard limits.maximumPartCount > 0,
              limits.maximumAttachmentCount >= 0,
              limits.maximumAttachmentMetadataBytes >= 0,
              limits.maximumDecodedBytesPerAttachment >= 0,
              limits.maximumAggregateDecodedBytes >= 0
        else {
            throw MIMEAttachmentDecodingError.decodedSizeLimitExceeded
        }
        var parserState = MIMEParserState()
        guard let root = MIMEEntity.parse(
            data,
            defaultMediaType: "text/plain",
            depth: 0,
            parserState: &parserState,
            limits: .init(
                maxDepth: maxNestingDepth,
                maxHeaderBytes: maxHeaderBytes,
                // The root entity is structural; the frozen attachment and
                // leaf limits count descendant MIME parts, not that wrapper.
                maxParts: limits.maximumPartCount + 1
            )
        ) else {
            if let error = parserLimitError(parserState) { throw error }
            throw MIMEAttachmentDecodingError.malformedMessage
        }
        if let error = parserLimitError(parserState) { throw error }
        try validateAttachmentMetadata(
            root.fixtureAttachmentMetadata(),
            maximumBytes: limits.maximumAttachmentMetadataBytes
        )
        var attachments: [IncomingMessageAttachmentPayload] = []
        var aggregateDecodedBytes = 0
        try root.appendDecodedAttachments(
            partPath: nil,
            limits: limits,
            aggregateDecodedBytes: &aggregateDecodedBytes,
            to: &attachments
        )
        return attachments
    }

    /// Parses attachment descriptors without decoding transfer payloads.  The
    /// sync parser can safely persist searchable metadata first; byte decoding
    /// remains a separate hydration boundary for attachment-capable stores.
    static func attachmentMetadata(
        from data: Data,
        limits: MIMEAttachmentDecodingLimits = .production
    ) throws -> [IncomingMessageAttachmentMetadata] {
        try providerProjection(from: data, limits: limits).parts.map {
            IncomingMessageAttachmentMetadata(filename: $0.filename, mimeType: $0.mediaType)
        }
    }

    /// Produces the complete, content-free provider projection for an inbound
    /// RFC 5322 message. Sync uses its body/attachment fields directly and
    /// shared-fixture owners compare this typed value without a test-only
    /// dictionary projection in the production target.
    package static func providerProjection(
        from data: Data,
        limits: MIMEAttachmentDecodingLimits = .production
    ) throws -> MIMEProviderProjection {
        guard limits.maximumPartCount > 0,
              limits.maximumAttachmentCount >= 0,
              limits.maximumAttachmentMetadataBytes >= 0
        else {
            throw MIMEAttachmentDecodingError.decodedSizeLimitExceeded
        }
        var parserState = MIMEParserState()
        guard let root = MIMEEntity.parse(
            data,
            defaultMediaType: "text/plain",
            depth: 0,
            parserState: &parserState,
            limits: .init(
                maxDepth: maxNestingDepth,
                maxHeaderBytes: maxHeaderBytes,
                maxParts: limits.maximumPartCount + 1
            )
        ) else {
            if let error = parserLimitError(parserState) { throw error }
            throw MIMEAttachmentDecodingError.malformedMessage
        }
        if let error = parserLimitError(parserState) { throw error }

        let metadata = root.fixtureAttachmentMetadata()
        guard metadata.count <= limits.maximumAttachmentCount else {
            throw MIMEAttachmentDecodingError.attachmentCountLimitExceeded
        }
        try validateAttachmentMetadata(
            metadata,
            maximumBytes: limits.maximumAttachmentMetadataBytes
        )
        let body = { (value: MIMEBody?) -> MIMEProviderProjection.Body in
            guard let value else { return .absent }
            guard value.text.utf8.count <= maxFixtureTextBytes else {
                return .omittedOversized
            }
            guard !value.text.unicodeScalars.contains(UnicodeScalar(0)!) else {
                return .malformed
            }
            return .complete(MIMEHeaderCanonicalizer.text(value.text))
        }
        let address = { (value: MIMEHeaderCanonicalizer.Address) in
            MIMEProviderProjection.Address(displayName: value.displayName, mailbox: value.mailbox)
        }
        let headers = root.fixtureHeaders
        let messageIDs = try MIMEHeaderCanonicalizer.messageIDs(headers.firstValue(named: "message-id"))
        let from = try MIMEHeaderCanonicalizer.addresses(headers.firstValue(named: "from"))
        let sender = try MIMEHeaderCanonicalizer.addresses(headers.firstValue(named: "sender")).first
        let replyTo = try MIMEHeaderCanonicalizer.addresses(headers.firstValue(named: "reply-to"))
        let to = try MIMEHeaderCanonicalizer.addresses(headers.firstValue(named: "to"))
        let cc = try MIMEHeaderCanonicalizer.addresses(headers.firstValue(named: "cc"))
        let bcc = try MIMEHeaderCanonicalizer.addresses(headers.firstValue(named: "bcc"))
        return MIMEProviderProjection(
            subject: MIMEHeaderCanonicalizer.text(decodeHeader(headers.firstValue(named: "subject") ?? "")),
            rfcMessageID: messageIDs.first ?? "",
            date: MIMEHeaderCanonicalizer.text(headers.firstValue(named: "date") ?? ""),
            from: from.map(address),
            sender: sender.map(address),
            replyTo: replyTo.map(address),
            to: to.map(address),
            cc: cc.map(address),
            bcc: bcc.map(address),
            inReplyTo: try MIMEHeaderCanonicalizer.messageIDs(headers.firstValue(named: "in-reply-to")),
            references: try MIMEHeaderCanonicalizer.messageIDs(headers.firstValue(named: "references")),
            textBody: body(root.body(of: .plainText)),
            htmlBody: body(root.body(of: .html)),
            parts: metadata.map {
                .init(
                    path: $0.path,
                    filename: $0.filename,
                    mediaType: $0.mediaType,
                    disposition: $0.disposition,
                    contentID: $0.contentID,
                    declaredSize: $0.declaredSize
                )
            }
        )
    }

    static func decodeHeader(_ value: String) -> String {
        RFC2047Decoder.decode(value)
    }

    private static func validateAttachmentMetadata(
        _ metadata: [MIMEFixturePartMetadata],
        maximumBytes: Int
    ) throws {
        var usedBytes = 0
        for part in metadata {
            for value in [
                part.path,
                part.filename,
                part.mediaType,
                part.disposition,
                part.contentID,
            ] {
                let (next, overflow) = usedBytes.addingReportingOverflow(value.utf8.count)
                guard !overflow, next <= maximumBytes else {
                    throw MIMEAttachmentDecodingError.attachmentMetadataLimitExceeded
                }
                usedBytes = next
            }
        }
    }
}

// This is deliberately shared by the corpus projection and the shipping IMAP
// sync parser.  The provider contract preserves local-part and Message-ID
// spelling, lowercases only DNS domains, and fails closed instead of silently
// truncating a valid oversized list.
enum MIMEHeaderCanonicalizer {
    static let maximumAddressEntries = 256
    static let maximumAddressBytes = 64 * 1_024
    static let maximumMessageIDEntries = 256
    static let maximumMessageIDBytes = 64 * 1_024
    static let maximumMessageIDBytesPerValue = 998

    struct Address: Equatable, Sendable {
        let displayName: String
        let mailbox: String
    }

    static func dictionary(_ address: Address) -> [String: String] {
        ["displayName": address.displayName, "mailbox": address.mailbox]
    }

    static func addresses(_ value: String?) throws -> [Address] {
        guard let value else { return [] }
        var result: [Address] = []
        var usedBytes = 0
        for candidate in splitAddressList(value) {
            guard let address = address(candidate) else { continue }
            let addressBytes = address.displayName.utf8.count + address.mailbox.utf8.count
            guard result.count < maximumAddressEntries,
                  addressBytes <= maximumAddressBytes - usedBytes
            else {
                throw MIMEAttachmentDecodingError.headerLimitExceeded
            }
            usedBytes += addressBytes
            result.append(address)
        }
        return result
    }

    static func messageIDs(_ value: String?) throws -> [String] {
        guard let value,
              let expression = try? NSRegularExpression(pattern: #"<[^<>\s]+>"#)
        else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        var result: [String] = []
        var seen = Set<String>()
        var usedBytes = 0
        for match in expression.matches(in: value, range: range) {
            guard let valueRange = Range(match.range, in: value) else { continue }
            let identifier = String(value[valueRange])
            guard validMessageID(identifier), seen.insert(identifier).inserted else { continue }
            let identifierBytes = identifier.utf8.count
            guard result.count < maximumMessageIDEntries,
                  identifierBytes <= maximumMessageIDBytes - usedBytes
            else {
                throw MIMEAttachmentDecodingError.headerLimitExceeded
            }
            usedBytes += identifierBytes
            result.append(identifier)
        }
        return result
    }

    static func text(_ value: String) -> String {
        let mapped = String(value.unicodeScalars.compactMap { scalar -> Character? in
            if scalar == UnicodeScalar(0)! { return nil }
            if scalar.properties.generalCategory == .control,
               scalar != "\n", scalar != "\r", scalar != "\t" {
                return " "
            }
            return Character(String(scalar))
        })
        return mapped.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    private static func address(_ value: String) -> Address? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed.lastIndex(of: ">"),
           open < close {
            guard let mailbox = canonicalMailbox(
                text(String(trimmed[trimmed.index(after: open)..<close]))
            ) else { return nil }
            let displayName = text(
                MIMEMessageDecoder.decodeHeader(
                    String(trimmed[..<open])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                )
            )
            return Address(displayName: displayName, mailbox: mailbox)
        }
        guard let mailbox = canonicalMailbox(text(trimmed)) else { return nil }
        return Address(displayName: "", mailbox: mailbox)
    }

    private static func canonicalMailbox(_ value: String) -> String? {
        guard value.utf8.count <= 512,
              let at = value.lastIndex(of: "@"), at != value.startIndex,
              value.index(after: at) != value.endIndex,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        return "\(local)@\(domain.lowercased())"
    }

    private static func validMessageID(_ value: String) -> Bool {
        guard value.utf8.count >= 3,
              value.utf8.count <= maximumMessageIDBytesPerValue,
              value.first == "<", value.last == ">"
        else { return false }
        let interior = value.dropFirst().dropLast()
        return interior.filter({ $0 == "@" }).count == 1 &&
            interior.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7e && scalar != "<" && scalar != ">"
            }
    }

    private static func splitAddressList(_ value: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var angleDepth = 0
        var commentDepth = 0
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"", commentDepth == 0 {
                quoted.toggle()
            } else if character == "(", !quoted {
                commentDepth += 1
            } else if character == ")", !quoted, commentDepth > 0 {
                commentDepth -= 1
            } else if character == "<", !quoted, commentDepth == 0 {
                angleDepth += 1
            } else if character == ">", !quoted, commentDepth == 0, angleDepth > 0 {
                angleDepth -= 1
            }
            if character == ",", !quoted, commentDepth == 0, angleDepth == 0 {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        values.append(current)
        return values
    }
}

/// Converts stored message body fields into the same deliberate display-safe
/// representation used by IMAP ingestion. Plain storage can contain a legacy
/// full RFC822/MIME document, so callers must cross this boundary instead of
/// treating every non-HTML value as already-decoded text.
public enum StoredEmailBodyRenderer {
    private enum StoredBodyClassification {
        case ordinaryPlainText
        case decodeMIME
        case failClosed
    }

    public static func render(
        plainTextOrMIME: String,
        html: String?
    ) -> RenderedEmailBody {
        if let html {
            return EmailBodyRenderer.render(.html(html))
        }
        switch classify(plainTextOrMIME) {
        case .ordinaryPlainText:
            return EmailBodyRenderer.render(.plainText(plainTextOrMIME))
        case .failClosed:
            return emptyBody()
        case .decodeMIME:
            break
        }
        if let decoded = MIMEMessageDecoder.displayContent(
            from: Data(plainTextOrMIME.utf8)
        ) {
            let renderedHTML = decoded.safeHTML.map {
                EmailBodyRenderer.render(.html($0))
            }
            return RenderedEmailBody(
                kind: renderedHTML == nil ? .plainText : .html,
                safeText: EmailBodyRenderer.render(.plainText(decoded.safeText)).safeText,
                safeHTML: renderedHTML?.safeHTML,
                blockedRemoteImageURLs: renderedHTML?.blockedRemoteImageURLs ?? []
            )
        }
        return emptyBody()
    }

    private static func emptyBody() -> RenderedEmailBody {
        RenderedEmailBody(
            kind: .plainText,
            safeText: "",
            safeHTML: nil,
            blockedRemoteImageURLs: []
        )
    }

    private static func classify(_ value: String) -> StoredBodyClassification {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
        let strongHeaders: Set<String> = [
            "content-disposition",
            "content-transfer-encoding",
            "content-type",
            "mime-version",
        ]
        let envelopeHeaders: Set<String> = [
            "bcc", "cc", "date", "from", "message-id", "reply-to", "subject", "to",
        ]
        let transportHeaders = strongHeaders.union(envelopeHeaders)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let headerBodySeparatorIndex = lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var recognizedHeaders: [String] = []
        var structuralHeaderIndexes: [Int] = []
        var hasEnvelopeHeaderBeforeSeparator = false
        for (index, line) in lines.enumerated() {
            guard let name = recognizedHeaderName(in: line),
                  transportHeaders.contains(name) else {
                continue
            }
            recognizedHeaders.append(name)
            if strongHeaders.contains(name) {
                structuralHeaderIndexes.append(index)
            }
            if envelopeHeaders.contains(name),
               let headerBodySeparatorIndex,
               index < headerBodySeparatorIndex {
                hasEnvelopeHeaderBeforeSeparator = true
            }
        }
        if !structuralHeaderIndexes.isEmpty {
            if let headerBodySeparatorIndex,
               structuralHeaderIndexes.contains(where: { $0 < headerBodySeparatorIndex }) {
                return .decodeMIME
            }
            return .failClosed
        }
        if hasEnvelopeHeaderBeforeSeparator || recognizedHeaders.count >= 2 {
            return .failClosed
        }
        return .ordinaryPlainText
    }

    private static func recognizedHeaderName(in line: Substring) -> String? {
        let candidate = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let colon = candidate.firstIndex(of: ":") else {
            return nil
        }
        let name = candidate[..<colon].lowercased()
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        return name
    }
}

private struct MIMEParserLimits {
    let maxDepth: Int
    let maxHeaderBytes: Int
    let maxParts: Int
}

private struct MIMEParserState {
    var partCount = 0
    var exceededDepth = false
    var exceededPartCount = false
    var exceededHeaderBytes = false
}

fileprivate enum MIMEBodyKind {
    case plainText
    case html
}

fileprivate struct MIMEBody {
    let kind: MIMEBodyKind
    let text: String
}

private struct MIMEEntity {
    let headers: MIMEHeaders
    let contentType: MIMEStructuredHeader
    let declaredContentType: String?
    let disposition: MIMEStructuredHeader
    let transferEncoding: String
    let body: Data
    let children: [MIMEEntity]

    var isAttachment: Bool {
        disposition.value == "attachment" ||
            !(disposition.parameters["filename"] ?? contentType.parameters["name"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ||
            !(headers.firstValue(named: "content-id") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ||
            (contentType.value == "message/rfc822" && disposition.value == "inline")
    }

    var fixtureHeaders: MIMEHeaders { headers }

    func fixtureAttachmentMetadata(partPath: String? = nil) -> [MIMEFixturePartMetadata] {
        let rawFilename = (
            disposition.parameters["filename"]
                ?? contentType.parameters["name"]
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if isAttachment {
            return [MIMEFixturePartMetadata(
                path: partPath ?? "1",
                filename: Self.safeFilename(rawFilename),
                mediaType: contentType.value,
                disposition: disposition.value == "inline" ? "inline" : "attachment",
                contentID: headers.firstValue(named: "content-id") ?? "",
                declaredSize: Self.declaredSize(headers.firstValue(named: "content-length"))
            )]
        }
        return children.enumerated().flatMap { index, child in
            child.fixtureAttachmentMetadata(partPath: partPath.map { "\($0).\(index + 1)" } ?? "\(index + 1)")
        }
    }

    func appendDecodedAttachments(
        partPath: String?,
        limits: MIMEAttachmentDecodingLimits,
        aggregateDecodedBytes: inout Int,
        to attachments: inout [IncomingMessageAttachmentPayload]
    ) throws {
        let rawFilename = (
            disposition.parameters["filename"]
                ?? contentType.parameters["name"]
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if isAttachment || !rawFilename.isEmpty {
            guard attachments.count < limits.maximumAttachmentCount else {
                throw MIMEAttachmentDecodingError.attachmentCountLimitExceeded
            }
            let remainingAggregate = limits.maximumAggregateDecodedBytes - aggregateDecodedBytes
            guard remainingAggregate >= 0,
                  maximumDecodedByteCount <= limits.maximumDecodedBytesPerAttachment,
                  maximumDecodedByteCount <= remainingAggregate
            else {
                throw MIMEAttachmentDecodingError.decodedSizeLimitExceeded
            }
            let decoded = try MIMETransferDecoder.decodeAttachment(
                body,
                encoding: transferEncoding
            )
            guard decoded.count <= limits.maximumDecodedBytesPerAttachment,
                  decoded.count <= remainingAggregate
            else {
                throw MIMEAttachmentDecodingError.decodedSizeLimitExceeded
            }
            let (nextAggregate, overflow) = aggregateDecodedBytes.addingReportingOverflow(
                decoded.count
            )
            guard !overflow, nextAggregate <= limits.maximumAggregateDecodedBytes else {
                throw MIMEAttachmentDecodingError.decodedSizeLimitExceeded
            }
            aggregateDecodedBytes = nextAggregate
            attachments.append(IncomingMessageAttachmentPayload(
                partPath: partPath ?? "1",
                filename: rawFilename,
                mimeType: declaredContentType,
                data: decoded,
                contentID: headers.firstValue(named: "content-id")
            ))
            return
        }

        for (index, child) in children.enumerated() {
            let childPath = partPath.map { "\($0).\(index + 1)" } ?? "\(index + 1)"
            try child.appendDecodedAttachments(
                partPath: childPath,
                limits: limits,
                aggregateDecodedBytes: &aggregateDecodedBytes,
                to: &attachments
            )
        }
    }

    private var maximumDecodedByteCount: Int {
        switch transferEncoding {
        case "base64":
            // Base64's wire representation is larger than its attachment
            // value. Count non-whitespace characters and terminal padding so
            // the preflight remains exact at 50 MiB rather than rejecting an
            // otherwise valid exact-limit payload through a conservative +3.
            var encodedCount = 0
            var trailingPadding = 0
            for byte in body where byte != 9 && byte != 10 && byte != 13 && byte != 32 {
                let (next, overflow) = encodedCount.addingReportingOverflow(1)
                guard !overflow else { return Int.max }
                encodedCount = next
                trailingPadding = byte == 61 ? trailingPadding + 1 : 0
            }
            guard encodedCount.isMultiple(of: 4), trailingPadding <= 2 else {
                // Preserve the public malformed-message outcome. The strict decoder
                // below owns malformed base64 validation; this preflight only
                // estimates decoded bytes for structurally valid wire input.
                return 0
            }
            let (decoded, overflow) = (encodedCount / 4).multipliedReportingOverflow(by: 3)
            return overflow ? Int.max : decoded - trailingPadding
        default:
            return body.count
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let replaced = String(normalized.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" ||
                scalar.properties.generalCategory == .control {
                return "_"
            }
            return Character(String(scalar))
        })
        let trimmed = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty || trimmed == "." || trimmed == ".."
            ? "Attachment"
            : trimmed
        var result = ""
        for character in fallback {
            let candidate = result + String(character)
            guard candidate.utf8.count <= IncomingMessageAttachmentPayload.maximumFilenameUTF8Length else {
                break
            }
            result = candidate
        }
        return result.isEmpty ? "Attachment" : result
    }

    private static func declaredSize(_ value: String?) -> Int {
        guard let value,
              let size = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              size >= 0 else {
            return 0
        }
        return size
    }

    static func parse(
        _ data: Data,
        defaultMediaType: String,
        depth: Int,
        parserState: inout MIMEParserState,
        limits: MIMEParserLimits
    ) -> MIMEEntity? {
        guard depth <= limits.maxDepth else {
            parserState.exceededDepth = true
            return nil
        }
        guard parserState.partCount < limits.maxParts else {
            parserState.exceededPartCount = true
            return nil
        }
        parserState.partCount += 1

        let split: (headers: Data, body: Data)
        switch MIMEData.splitHeadersAndBody(data, maxHeaderBytes: limits.maxHeaderBytes) {
        case let .success(headers, body):
            split = (headers, body)
        case .headerLimitExceeded:
            parserState.exceededHeaderBytes = true
            return nil
        }
        let headers = MIMEHeaders(data: split.headers)
        let declaredContentTypeHeader = headers.firstValue(named: "content-type")
        let contentType = MIMEStructuredHeader(declaredContentTypeHeader ?? defaultMediaType)
        let disposition = MIMEStructuredHeader(
            headers.firstValue(named: "content-disposition") ?? ""
        )
        let transferEncoding = headers.firstValue(named: "content-transfer-encoding")?
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .first
            .map(String.init) ?? "8bit"

        var children: [MIMEEntity] = []
        if contentType.value.hasPrefix("multipart/"), let boundary = contentType.parameters["boundary"], !boundary.isEmpty {
            let childDefault = contentType.value == "multipart/digest" ? "message/rfc822" : "text/plain"
            for part in MIMEData.multipartParts(in: split.body, boundary: boundary) {
                if let child = parse(
                    part,
                    defaultMediaType: childDefault,
                    depth: depth + 1,
                    parserState: &parserState,
                    limits: limits
                ) {
                    children.append(child)
                }
            }
        } else if contentType.value == "message/rfc822", disposition.value != "attachment" {
            let nestedData = MIMETransferDecoder.decode(split.body, encoding: transferEncoding)
            if let child = parse(
                nestedData,
                defaultMediaType: "text/plain",
                depth: depth + 1,
                parserState: &parserState,
                limits: limits
            ) {
                children = [child]
            }
        }

        return MIMEEntity(
            headers: headers,
            contentType: contentType,
            declaredContentType: declaredContentTypeHeader.map {
                MIMEStructuredHeader($0).value
            },
            disposition: disposition,
            transferEncoding: transferEncoding,
            body: split.body,
            children: children
        )
    }

    func preferredBody() -> MIMEBody? {
        guard !isAttachment else {
            return nil
        }

        switch contentType.value {
        case "text/plain":
            return decodedTextBody(kind: .plainText)
        case "text/html":
            return decodedTextBody(kind: .html)
        case "message/rfc822":
            return children.first?.preferredBody()
        case "multipart/alternative":
            return preferredAlternative(kind: .plainText) ?? preferredAlternative(kind: .html)
        case "multipart/signed", "multipart/encrypted":
            return children.first?.preferredBody()
        case "multipart/related":
            return relatedRoot()?.preferredBody() ?? children.lazy.compactMap { $0.preferredBody() }.first
        default:
            guard contentType.value.hasPrefix("multipart/") else {
                return nil
            }
            // Like MimeKit, the first inline text entity in a mixed multipart is the body.
            for child in children {
                if let candidate = child.preferredBody() {
                    return candidate
                }
                if child.contentType.value.hasPrefix("multipart/") {
                    break
                }
            }
            return nil
        }
    }

    private func preferredAlternative(kind: MIMEBodyKind) -> MIMEBody? {
        for child in children.reversed() {
            if let candidate = child.body(of: kind) {
                return candidate
            }
        }
        return nil
    }

    fileprivate func body(of kind: MIMEBodyKind, decodeFlowed: Bool = true) -> MIMEBody? {
        guard !isAttachment else {
            return nil
        }
        if contentType.value == "text/plain", kind == .plainText {
            return decodedTextBody(kind: kind, decodeFlowed: decodeFlowed)
        }
        if contentType.value == "text/html", kind == .html {
            return decodedTextBody(kind: kind, decodeFlowed: decodeFlowed)
        }
        if contentType.value == "message/rfc822" {
            return children.first?.body(of: kind, decodeFlowed: decodeFlowed)
        }
        if contentType.value.hasPrefix("multipart/") {
            let sequence = contentType.value == "multipart/alternative" ? children.reversed() : children.reversed()
            for child in sequence {
                if let candidate = child.body(of: kind, decodeFlowed: decodeFlowed) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func relatedRoot() -> MIMEEntity? {
        guard let start = contentType.parameters["start"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) else {
            return children.first
        }
        return children.first { child in
            child.headers.firstValue(named: "content-id")?
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>")) == start
        } ?? children.first
    }

    private func decodedTextBody(kind: MIMEBodyKind, decodeFlowed: Bool = true) -> MIMEBody {
        let decoded = MIMETransferDecoder.decode(body, encoding: transferEncoding)
        var text = MIMECharsetDecoder.decode(decoded, charset: contentType.parameters["charset"])
        if decodeFlowed, kind == .plainText, contentType.parameters["format"]?.lowercased() == "flowed" {
            text = MIMEFlowedText.decode(
                text,
                deleteSpace: contentType.parameters["delsp"]?.lowercased() == "yes"
            )
        }
        return MIMEBody(kind: kind, text: text)
    }
}

private struct MIMEFixturePartMetadata {
    let path: String
    let filename: String
    let mediaType: String
    let disposition: String
    let contentID: String
    let declaredSize: Int
}

private struct MIMEHeaders {
    private let values: [String: [String]]

    init(data: Data) {
        let text = MIMECharsetDecoder.decode(data, charset: "iso-8859-1")
        var parsed: [String: [String]] = [:]
        var currentName: String?

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t") {
                if let currentName, var list = parsed[currentName], !list.isEmpty {
                    list[list.count - 1] += " " + rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    parsed[currentName] = list
                }
                continue
            }
            guard let colon = rawLine.firstIndex(of: ":") else {
                currentName = nil
                continue
            }
            let name = rawLine[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else {
                currentName = nil
                continue
            }
            let value = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsed[name, default: []].append(value)
            currentName = name
        }
        values = parsed
    }

    func firstValue(named name: String) -> String? {
        values[name.lowercased()]?.first
    }
}

private struct MIMEStructuredHeader {
    let value: String
    let parameters: [String: String]

    init(_ rawValue: String) {
        let input = Self.removingComments(from: rawValue)
        var segments: [String] = []
        var current = ""
        var quoted = false
        var escaped = false

        for character in input {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ";", !quoted {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)

        value = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var rawParameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else {
                continue
            }
            let parameterValue = pair.count > 1
                ? pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            rawParameters[key] = parameterValue
        }
        parameters = MIMEParameterDecoder.decode(rawParameters)
    }

    private static func removingComments(from value: String) -> String {
        var result = ""
        var commentDepth = 0
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                if commentDepth == 0 {
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
                if commentDepth == 0 {
                    result.append(character)
                }
            } else if character == "\"", commentDepth == 0 {
                quoted.toggle()
                result.append(character)
            } else if !quoted, character == "(" {
                commentDepth += 1
            } else if !quoted, character == ")", commentDepth > 0 {
                commentDepth -= 1
            } else if commentDepth == 0 {
                result.append(character)
            }
        }
        return result
    }
}

private enum MIMEParameterDecoder {
    static func decode(_ raw: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var continuations: [String: [(index: Int, encoded: Bool, value: String)]] = [:]

        for (key, value) in raw {
            if let continuation = continuationKey(key) {
                continuations[continuation.name, default: []].append(
                    (continuation.index, continuation.encoded, value)
                )
            } else if key.hasSuffix("*") {
                result[String(key.dropLast())] = decodeExtended(value)
            } else {
                result[key] = value
            }
        }

        for (name, pieces) in continuations {
            let sorted = pieces.sorted { $0.index < $1.index }
            guard sorted.first?.index == 0 else {
                continue
            }
            let joined = sorted.map(\.value).joined()
            result[name] = sorted.contains(where: \.encoded) ? decodeExtended(joined) : joined
        }
        return result
    }

    private static func continuationKey(_ key: String) -> (name: String, index: Int, encoded: Bool)? {
        let pattern = #"^(.+)\*(\d+)(\*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              let nameRange = Range(match.range(at: 1), in: key),
              let indexRange = Range(match.range(at: 2), in: key),
              let index = Int(key[indexRange]) else {
            return nil
        }
        return (String(key[nameRange]), index, match.range(at: 3).location != NSNotFound)
    }

    private static func decodeExtended(_ value: String) -> String {
        let components = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let charset = components.count == 3 ? String(components[0]) : "utf-8"
        let payload = components.count == 3 ? String(components[2]) : value
        var bytes: [UInt8] = []
        let source = Array(payload.utf8)
        var index = 0
        while index < source.count {
            if source[index] == 37, index + 2 < source.count,
               let high = MIMETransferDecoder.hexValue(source[index + 1]),
               let low = MIMETransferDecoder.hexValue(source[index + 2]) {
                bytes.append(high * 16 + low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return MIMECharsetDecoder.decode(Data(bytes), charset: charset)
    }
}

private enum MIMEData {
    enum HeaderSplit {
        case success(headers: Data, body: Data)
        case headerLimitExceeded
    }

    static func splitHeadersAndBody(_ data: Data, maxHeaderBytes: Int) -> HeaderSplit {
        let bytes = [UInt8](data)
        let searchLimit = min(bytes.count, maxHeaderBytes + 4)
        if searchLimit >= 4 {
            for index in 0...(searchLimit - 4) where bytes[index...index + 3].elementsEqual([13, 10, 13, 10]) {
                guard index <= maxHeaderBytes else { return .headerLimitExceeded }
                return .success(headers: Data(bytes[..<index]), body: Data(bytes[(index + 4)...]))
            }
        }
        if searchLimit >= 2 {
            for index in 0...(searchLimit - 2) where bytes[index] == 10 && bytes[index + 1] == 10 {
                guard index <= maxHeaderBytes else { return .headerLimitExceeded }
                return .success(headers: Data(bytes[..<index]), body: Data(bytes[(index + 2)...]))
            }
        }
        if data.count > maxHeaderBytes {
            return .headerLimitExceeded
        }
        return .success(headers: Data(), body: data)
    }

    static func multipartParts(in data: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](data)
        let marker = [45, 45] + Array(boundary.utf8)
        var parts: [Data] = []
        var currentStart: Int?
        var lineStart = 0
        var index = 0

        while index <= bytes.count {
            let atEnd = index == bytes.count
            if atEnd || bytes[index] == 10 {
                var contentEnd = index
                if contentEnd > lineStart, bytes[contentEnd - 1] == 13 {
                    contentEnd -= 1
                }
                let line = Array(bytes[lineStart..<contentEnd])
                if let closing = boundaryLine(line, marker: marker) {
                    if let start = currentStart {
                        var end = lineStart
                        if end > start, bytes[end - 1] == 10 {
                            end -= 1
                            if end > start, bytes[end - 1] == 13 {
                                end -= 1
                            }
                        }
                        if end >= start {
                            parts.append(Data(bytes[start..<end]))
                        }
                    }
                    currentStart = closing ? nil : min(index + (atEnd ? 0 : 1), bytes.count)
                    if closing {
                        break
                    }
                }
                lineStart = index + 1
            }
            index += 1
        }
        return parts
    }

    private static func boundaryLine(_ line: [UInt8], marker: [UInt8]) -> Bool? {
        guard line.count >= marker.count, line.prefix(marker.count).elementsEqual(marker) else {
            return nil
        }
        var suffix = Array(line.dropFirst(marker.count))
        let closing = suffix.starts(with: [45, 45])
        if closing {
            suffix.removeFirst(2)
        }
        guard suffix.allSatisfy({ $0 == 32 || $0 == 9 }) else {
            return nil
        }
        return closing
    }
}

private enum MIMETransferDecoder {
    static func decode(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "base64":
            return Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return quotedPrintable(data)
        default:
            return data
        }
    }

    static func decodeAttachment(_ data: Data, encoding: String) throws -> Data {
        switch encoding.lowercased() {
        case "", "7bit", "8bit", "binary":
            return data
        case "base64":
            let compact = Data(data.filter { byte in
                byte != 9 && byte != 10 && byte != 13 && byte != 32
            })
            guard !compact.isEmpty || data.isEmpty,
                  let decoded = Data(base64Encoded: compact)
            else {
                throw MIMEAttachmentDecodingError.malformedMessage
            }
            return decoded
        case "quoted-printable":
            let bytes = [UInt8](data)
            var index = 0
            while index < bytes.count {
                guard bytes[index] == 61 else {
                    index += 1
                    continue
                }
                if index + 2 < bytes.count,
                   bytes[index + 1] == 13,
                   bytes[index + 2] == 10 {
                    index += 3
                } else if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                } else if index + 2 < bytes.count,
                          hexValue(bytes[index + 1]) != nil,
                          hexValue(bytes[index + 2]) != nil {
                    index += 3
                } else {
                    throw MIMEAttachmentDecodingError.malformedMessage
                }
            }
            return quotedPrintable(data)
        default:
            throw MIMEAttachmentDecodingError.malformedMessage
        }
    }

    static func quotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 61 else {
                result.append(bytes[index])
                index += 1
                continue
            }
            if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                index += 3
            } else if index + 1 < bytes.count, bytes[index + 1] == 10 {
                index += 2
            } else if index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) {
                result.append(high * 16 + low)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return Data(result)
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

private enum MIMECharsetDecoder {
    static func decode(_ data: Data, charset: String?) -> String {
        let normalized = (charset ?? "utf-8")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let encodings: [String.Encoding]
        switch normalized {
        case "us-ascii", "ascii": encodings = [.ascii, .utf8, .isoLatin1]
        case "iso-8859-1", "latin1", "latin-1": encodings = [.isoLatin1, .windowsCP1252, .utf8]
        case "iso-8859-2", "latin2", "latin-2": encodings = [.isoLatin2, .windowsCP1250, .utf8]
        case "windows-1250", "cp1250": encodings = [.windowsCP1250, .isoLatin2, .utf8]
        case "windows-1251", "cp1251": encodings = [.windowsCP1251, .utf8]
        case "windows-1252", "cp1252": encodings = [.windowsCP1252, .isoLatin1, .utf8]
        case "shift-jis", "shift_jis", "sjis": encodings = [.shiftJIS, .utf8]
        case "euc-jp": encodings = [.japaneseEUC, .utf8]
        case "iso-2022-jp": encodings = [.iso2022JP, .utf8]
        case "utf-16", "utf16": encodings = [.utf16, .utf8]
        case "utf-16le": encodings = [.utf16LittleEndian, .utf8]
        case "utf-16be": encodings = [.utf16BigEndian, .utf8]
        default: encodings = [.utf8, .windowsCP1252, .isoLatin1]
        }
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum MIMEFlowedText {
    static func decode(_ text: String, deleteSpace: Bool) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result = ""
        for rawLine in lines {
            let line = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
            if result.hasSuffix(" "), result != "-- ", !result.hasSuffix("\n-- ") {
                if deleteSpace {
                    result.removeLast()
                }
                result += line
            } else {
                if !result.isEmpty {
                    result += "\n"
                }
                result += line
            }
        }
        return result
    }
}

private enum RFC2047Decoder {
    static func decode(_ value: String) -> String {
        let unfolded = value.replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        let pattern = #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return unfolded
        }
        let matches = regex.matches(in: unfolded, range: NSRange(unfolded.startIndex..., in: unfolded))
        guard !matches.isEmpty else {
            return unfolded
        }

        var result = ""
        var cursor = unfolded.startIndex
        var previousWasEncoded = false
        for match in matches {
            guard let range = Range(match.range, in: unfolded),
                  let charsetRange = Range(match.range(at: 1), in: unfolded),
                  let encodingRange = Range(match.range(at: 2), in: unfolded),
                  let payloadRange = Range(match.range(at: 3), in: unfolded) else {
                continue
            }
            let between = String(unfolded[cursor..<range.lowerBound])
            if !(previousWasEncoded && between.allSatisfy(\.isWhitespace)) {
                result += between
            }
            let payload = String(unfolded[payloadRange])
            let data: Data?
            if unfolded[encodingRange].lowercased() == "b" {
                data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
            } else {
                data = MIMETransferDecoder.quotedPrintable(
                    Data(payload.replacingOccurrences(of: "_", with: " ").utf8)
                )
            }
            result += data.map { MIMECharsetDecoder.decode($0, charset: String(unfolded[charsetRange])) } ?? String(unfolded[range])
            cursor = range.upperBound
            previousWasEncoded = true
        }
        result += unfolded[cursor...]
        return result
    }
}
