import CryptoKit
import Foundation

/// Stable opaque coordinates used by notification payloads and local tap
/// resolution. Legacy Node tokens use durable coordinates without provider
/// or trust epochs. Local message tokens can also bind a source generation.
public struct NotificationOpaqueIdentities: Equatable, Sendable {
    public let mailboxToken: String
    public let threadToken: String
    public let messageToken: String

    public static func derive(mailboxBytes: Data, messageID: String, threadID: String) -> Self {
        Self(
            mailboxToken: token(kind: "mailbox", parts: [mailboxBytes]),
            threadToken: token(kind: "thread", parts: [Data(threadID.utf8)]),
            messageToken: token(kind: "message", parts: [Data(messageID.utf8)])
        )
    }

    public static func messageToken(for messageID: String) -> String {
        token(kind: "message", parts: [Data(messageID.utf8)])
    }

    /// Binds a local message tap to the account and confirmed mail source
    /// that issued it. A source transition invalidates an older tap even if
    /// the provider reuses the same message identifier.
    public static func messageToken(
        for messageID: String,
        accountID: String,
        sourceKind: String,
        sourceGeneration: Int64
    ) -> String {
        token(
            kind: "account-source-message",
            parts: [
                Data(accountID.utf8),
                Data(sourceKind.utf8),
                Data(String(sourceGeneration).utf8),
                Data(messageID.utf8)
            ]
        )
    }

    public static func accountInboxToken(for accountID: String) -> String {
        token(kind: "account-inbox", parts: [Data(accountID.utf8)])
    }

    private static func token(kind: String, parts: [Data]) -> String {
        var input = Data("plainpost.notification.identity.v1\0".utf8)
        append(Data(kind.utf8), to: &input)
        for part in parts { append(part, to: &input) }
        return AccountWireCodec.encodeBase64URL(Data(SHA256.hash(data: input)))
    }

    private static func append(_ part: Data, to data: inout Data) {
        var length = UInt32(part.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(part)
    }
}
