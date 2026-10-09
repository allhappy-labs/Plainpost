import CryptoKit
import Foundation

public struct CachedMessageTranslation: Equatable, Sendable {
    public let messageID: MessageID
    public let targetLanguageID: String
    public let sourceFingerprint: String
    public let providerID: String
    public let modelID: String
    public let contractVersion: String
    public let bodyKind: EmailBodyKind
    public let translatedBody: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        messageID: MessageID,
        targetLanguageID: String,
        sourceFingerprint: String,
        providerID: String,
        modelID: String,
        contractVersion: String,
        bodyKind: EmailBodyKind,
        translatedBody: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.messageID = messageID
        self.targetLanguageID = targetLanguageID
        self.sourceFingerprint = sourceFingerprint
        self.providerID = providerID
        self.modelID = modelID
        self.contractVersion = contractVersion
        self.bodyKind = bodyKind
        self.translatedBody = translatedBody
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MailTranslationFingerprint {
    public static func message(_ message: MessageSummary) -> String {
        source(
            messageID: message.id,
            plainBody: message.body,
            htmlBody: message.bodyHTML
        )
    }

    public static func source(
        messageID: MessageID,
        plainBody: String,
        htmlBody: String?
    ) -> String {
        digest(
            messageID: messageID,
            bodyKind: htmlBody == nil ? .plainText : .html,
            plainBody: plainBody,
            htmlBody: htmlBody
        )
    }

    public static func source(
        messageID: MessageID,
        body: EmailBodyInput
    ) -> String {
        switch body {
        case let .plainText(text):
            digest(
                messageID: messageID,
                bodyKind: .plainText,
                plainBody: text,
                htmlBody: nil
            )
        case let .html(html):
            digest(
                messageID: messageID,
                bodyKind: .html,
                plainBody: "",
                htmlBody: html
            )
        }
    }

    public static func source(
        messageID: MessageID,
        renderedBody: RenderedEmailBody
    ) -> String {
        switch renderedBody.kind {
        case .plainText:
            source(messageID: messageID, body: .plainText(renderedBody.safeText))
        case .html:
            source(
                messageID: messageID,
                body: .html(renderedBody.safeHTML ?? "")
            )
        }
    }

    private static func digest(
        messageID: MessageID,
        bodyKind: EmailBodyKind,
        plainBody: String,
        htmlBody: String?
    ) -> String {
        var canonicalData = Data()
        appendLengthPrefixed("message-translation-source-v2", to: &canonicalData)
        appendLengthPrefixed(messageID.rawValue, to: &canonicalData)
        appendLengthPrefixed(bodyKind.rawValue, to: &canonicalData)
        appendLengthPrefixed(htmlBody == nil ? "html-absent" : "html-present", to: &canonicalData)
        appendLengthPrefixed(plainBody, to: &canonicalData)
        if let htmlBody {
            appendLengthPrefixed(htmlBody, to: &canonicalData)
        }
        return SHA256.hash(data: canonicalData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var byteCount = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &byteCount) {
            data.append(contentsOf: $0)
        }
        data.append(bytes)
    }
}
