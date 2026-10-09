import Foundation

public struct AccountVerificationMessage: Equatable, Sendable {
    public static let subject = "Plainpost account verification"
    public static let body = "Testing local SMTP credentials."
    public static let markerHeaderName = "X-Plainpost-Account-Verification"
    public static let markerHeaderValue = "v1"

    public let accountEmail: EmailAddress
    public let messageID: String

    public init(accountEmail: EmailAddress, identifier: UUID = UUID()) {
        self.accountEmail = accountEmail
        self.messageID = "<plainpost-account-verification-\(identifier.uuidString.lowercased())@local.plainpost>"
    }

    public var smtpData: String {
        [
            "From: <\(accountEmail.rawValue)>",
            "To: <\(accountEmail.rawValue)>",
            "Subject: \(Self.subject)",
            "Message-ID: \(messageID)",
            "\(Self.markerHeaderName): \(Self.markerHeaderValue)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            Self.body,
        ].joined(separator: "\r\n")
    }

    public func matchesDeliveryHeader(_ header: String) -> Bool {
        Self.matchesHeader(
            header,
            accountEmail: accountEmail,
            requiredMessageID: messageID
        )
    }

    public static func recognizes(
        header: String,
        body: String,
        accountEmail: EmailAddress
    ) -> Bool {
        guard let messageID = headerValue(named: "Message-ID", in: header),
              isVerificationMessageID(messageID)
        else { return false }
        return matchesHeader(
            header,
            accountEmail: accountEmail,
            requiredMessageID: messageID
        ) && withoutSMTPLineEnding(body) == Self.body
    }

    /// SMTP DATA ends the last body line with CRLF, so a delivered copy holds
    /// one trailing line ending that `smtpData` does not. Drop only that one.
    private static func withoutSMTPLineEnding(_ body: String) -> String {
        for ending in ["\r\n", "\n"] where body.hasSuffix(ending) {
            return String(body.dropLast(ending.count))
        }
        return body
    }

    private static func matchesHeader(
        _ header: String,
        accountEmail: EmailAddress,
        requiredMessageID: String
    ) -> Bool {
        normalizedAddress(headerValue(named: "From", in: header)) == accountEmail.rawValue.lowercased()
            && headerValue(named: "Subject", in: header) == subject
            && headerValue(named: "Message-ID", in: header)?.lowercased() == requiredMessageID.lowercased()
            && headerValue(named: markerHeaderName, in: header)?.lowercased() == markerHeaderValue
    }

    private static func isVerificationMessageID(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let prefix = "<plainpost-account-verification-"
        let suffix = "@local.plainpost>"
        guard lowercased.hasPrefix(prefix), lowercased.hasSuffix(suffix) else { return false }
        let start = lowercased.index(lowercased.startIndex, offsetBy: prefix.count)
        let end = lowercased.index(lowercased.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(lowercased[start..<end])) != nil
    }

    private static func normalizedAddress(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let start = value.lastIndex(of: "<"),
           let end = value[value.index(after: start)...].firstIndex(of: ">") {
            value = String(value[value.index(after: start)..<end])
        }
        return value.lowercased()
    }

    private static func headerValue(named name: String, in text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let prefix = "\(name.lowercased()):"
        var values: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if values.isEmpty {
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                      trimmed.lowercased().hasPrefix(prefix) else { continue }
                values.append(String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                values.append(trimmed)
            } else {
                break
            }
        }
        let value = values.joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}
