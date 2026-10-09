import Foundation

/// Why the iPhone mail UI is read-only: the one-line reason a mailbox list and Compose show.
/// The host app knows the reason; the shell only knows that mutations are refused. These are
/// the runtime's two: an offline lease (a Plainpost account session, or a Node session the
/// broker admits read-only) and a provider account that needs reauthorization.
public enum MobileReadOnlyReason: Equatable, Sendable {
    /// The session is admitted only by its offline lease: cached mail stays readable until
    /// `expiresAt`, when known, and nothing can change until Plainpost reconnects.
    case offlineLease(expiresAt: Date?)
    /// The selected provider account needs reauthorization, which happens on the Mac.
    case reauthorization

    /// Under a mailbox list: why rows can't be archived, deleted or marked.
    public var changesLine: String {
        switch self {
        case let .offlineLease(expiresAt?):
            "Offline: cached mail is read-only until \(Self.format(expiresAt))."
        case .offlineLease(nil):
            "Offline: cached mail is read-only until Plainpost reconnects."
        case .reauthorization:
            "Sign in to this account again on your Mac to make changes."
        }
    }

    /// In Compose: why Send is refused.
    public var sendingLine: String {
        switch self {
        case .offlineLease:
            "Sending is paused while you're offline."
        case .reauthorization:
            "Sign in to this account again on your Mac to send."
        }
    }

    /// For a read-only session whose host gave no reason.
    static let unknownChangesLine = "Changes are paused while this account is read-only."
    static let unknownSendingLine = "Sending is paused while this account is read-only."

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

public extension Optional where Wrapped == MobileReadOnlyReason {
    /// The list line for a read-only session, with a generic fallback when the host gave none.
    var changesLine: String { self?.changesLine ?? MobileReadOnlyReason.unknownChangesLine }
    /// The Compose line for a read-only session, with a generic fallback.
    var sendingLine: String { self?.sendingLine ?? MobileReadOnlyReason.unknownSendingLine }
}
