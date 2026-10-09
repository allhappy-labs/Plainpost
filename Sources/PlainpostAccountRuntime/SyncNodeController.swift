import Foundation
import PlainpostCore

/// Read-only, source-neutral Node diagnostics.  Keeping this capability
/// separate from provider onboarding lets cached authorities retain the
/// settings panel without exposing any provider mutation surface.
public protocol SyncNodeStatusProviding: Sendable {
    func status() async throws -> SyncNodeStatus
}

/// Chooses the one source of mail capabilities for an account. A cached
/// mailbox is a read-only capability, never a reason to resurrect provider
/// credentials or a legacy local transport.
public final class SyncNodeController: @unchecked Sendable {
    public enum Access: Sendable, Equatable {
        case authorized
        case cachedReadOnly
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case accessDenied
        case authorityUnavailable
    }

    public typealias AuthorityFactory = @Sendable (Access) throws -> any PlainpostMailAuthority

    public let access: Access
    public let cachedReadOnlyPermitted: Bool
    private let makeAuthority: AuthorityFactory
    private let selectionLock = NSLock()
    private var selectedAuthority: (any PlainpostMailAuthority)?

    public init(
        access: Access,
        cachedReadOnlyPermitted: Bool = true,
        makeAuthority: @escaping AuthorityFactory
    ) {
        self.access = access
        self.cachedReadOnlyPermitted = cachedReadOnlyPermitted
        self.makeAuthority = makeAuthority
    }

    @discardableResult
    public func resolve() throws -> any PlainpostMailAuthority {
        selectionLock.lock()
        defer { selectionLock.unlock() }
        if access == .cachedReadOnly && !cachedReadOnlyPermitted {
            throw Error.accessDenied
        }
        if let selectedAuthority {
            return selectedAuthority
        }
        do {
            let authority = try makeAuthority(access)
            let selected: any PlainpostMailAuthority
            if access == .cachedReadOnly {
                guard let readOnly = ReadOnlyNodeMailAuthority(authority) else {
                    throw Error.authorityUnavailable
                }
                selected = readOnly
            } else {
                selected = authority
            }
            selectedAuthority = selected
            return selected
        } catch let error as Error {
            throw error
        } catch {
            throw Error.authorityUnavailable
        }
    }

    public var authority: (any PlainpostMailAuthority)? {
        selectionLock.lock(); defer { selectionLock.unlock() }
        return selectedAuthority
    }

    public var snapshots: (any MailSnapshotServing)? { authority?.snapshots }
    public var search: (any MailSearchService)? { authority?.search }
    public var messages: (any MailMessageServing)? { authority?.messages }
    public var mutations: (any MailMutationServing)? { authority?.mutations }
    public var attachments: (any MailAttachmentServing)? { authority?.attachments }
}

private final class ReadOnlyNodeMailAuthority: PlainpostMailAuthority, SyncNodeStatusProviding, @unchecked Sendable {
    let accountID: AccountID?
    let senderAddress: EmailAddress?
    let snapshots: any MailSnapshotServing
    let search: any MailSearchService
    let messages: any MailMessageServing
    let mutations: any MailMutationServing = ReadOnlyMutationCapability()
    let attachments: any MailAttachmentServing
    let statusProvider: any SyncNodeStatusProviding

    init?(_ authority: any PlainpostMailAuthority) {
        guard let statusProvider = authority as? any SyncNodeStatusProviding else {
            return nil
        }
        accountID = authority.accountID
        senderAddress = authority.senderAddress
        snapshots = authority.snapshots
        search = authority.search
        messages = authority.messages
        attachments = authority.attachments
        self.statusProvider = statusProvider
    }

    func status() async throws -> SyncNodeStatus {
        try await statusProvider.status()
    }
}

private struct ReadOnlyMutationCapability: MailMutationServing {
    func perform(_ intent: MailMutationIntent) async throws -> MailMutationResult {
        _ = intent
        throw PlainpostError.permissionDenied("This cached mailbox is read-only while the account is offline.")
    }

    func apply(canonicalOperation: Data) async throws -> MailMutationResult {
        _ = canonicalOperation
        throw PlainpostError.permissionDenied("This cached mailbox is read-only while the account is offline.")
    }
}
