import CryptoKit
import Foundation

public enum ComposeContentHash {
    public static func hash(
        from: String,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        bodyPlain: String,
        bodyMarkdown: String?,
        aiGenerated: Bool,
        sourceThreadID: String?,
        inReplyTo: String?,
        references: [String],
        attachmentContentComponents: [String]
    ) -> String {
        var parts = [
            from,
            to.joined(separator: ","),
            cc.joined(separator: ","),
            bcc.joined(separator: ","),
            subject,
            bodyPlain,
            String(aiGenerated),
            sourceThreadID ?? "",
            inReplyTo ?? "",
            references.joined(separator: " "),
        ]
        if let bodyMarkdown {
            parts.append("markdown:\(bodyMarkdown)")
        }
        let canonical = (parts + attachmentContentComponents)
            .joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func attachmentComponent(
        id: String,
        filename: String,
        mimeType: String,
        data: Data
    ) -> String {
        "\(id)|\(filename)|\(mimeType)|\(data.base64EncodedString())"
    }
}
