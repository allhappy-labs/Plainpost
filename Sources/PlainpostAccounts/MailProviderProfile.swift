import Foundation
import PlainpostCore

public enum MailProviderKind: String, CaseIterable, Equatable, Sendable {
    case gmail
    case microsoft
    case icloud
    case other
}

public struct MailProviderProfile: Equatable, Sendable {
    public let kind: MailProviderKind
    public let imapHost: String
    public let imapPort: UInt16
    public let smtpHost: String
    public let smtpPort: Int
    public let sentMailbox: String

    public init(
        kind: MailProviderKind,
        imapHost: String,
        imapPort: UInt16,
        smtpHost: String,
        smtpPort: Int,
        sentMailbox: String
    ) {
        self.kind = kind
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.sentMailbox = sentMailbox
    }

    public static let gmail = MailProviderProfile(
        kind: .gmail,
        imapHost: "imap.gmail.com",
        imapPort: 993,
        smtpHost: "smtp.gmail.com",
        smtpPort: 587,
        sentMailbox: "[Gmail]/Sent Mail"
    )

    public static let icloud = MailProviderProfile(
        kind: .icloud,
        imapHost: "imap.mail.me.com",
        imapPort: 993,
        smtpHost: "smtp.mail.me.com",
        smtpPort: 587,
        sentMailbox: "Sent Messages"
    )

    public static let microsoft = MailProviderProfile(
        kind: .microsoft,
        imapHost: "outlook.office365.com",
        imapPort: 993,
        smtpHost: "smtp.office365.com",
        smtpPort: 587,
        sentMailbox: "Sent Items"
    )

    public func normalizedAppPassword(_ value: String) -> String {
        String(value.filter { !$0.isWhitespace })
    }

    public func isValidAppPassword(_ value: String) -> Bool {
        normalizedAppPassword(value).count == 16
    }

    public func matches(_ account: Account) -> Bool {
        account.imapHost.caseInsensitiveCompare(imapHost) == .orderedSame
            && account.smtpHost.caseInsensitiveCompare(smtpHost) == .orderedSame
    }

    public func storesSentMessagesAutomatically(for account: Account) -> Bool {
        kind == .gmail && account.smtpHost.caseInsensitiveCompare(smtpHost) == .orderedSame
    }

    /// The Gmail account written by Google sign-in setup: Gmail's IMAP and
    /// SMTP endpoints with the Google address as the XOAUTH2 username.
    public func makeGoogleAccount(displayName: String, email: EmailAddress) -> Account {
        makeOAuthAccount(displayName: displayName, email: email)
    }

    /// A provider account using the verified address as its XOAUTH2 username.
    public func makeOAuthAccount(displayName: String, email: EmailAddress) -> Account {
        let normalized = EmailAddress(email.rawValue.lowercased())
        return Account(
            id: AccountID.stableAccountID(email: normalized),
            displayName: displayName,
            email: normalized,
            username: normalized.rawValue,
            sentMailbox: sentMailbox,
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort
        )
    }

    public func makeRequest(
        displayName: String,
        email: EmailAddress,
        appPassword: String
    ) -> AccountSetupRequest {
        let password = normalizedAppPassword(appPassword)
        return AccountSetupRequest(
            displayName: displayName,
            email: email,
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            username: email.rawValue,
            sentMailbox: sentMailbox,
            imapPassword: password,
            smtpPassword: password
        )
    }
}
