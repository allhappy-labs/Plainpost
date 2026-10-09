import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB

public enum DirectMailboxAction: Sendable, Equatable {
    case markRead
    case markUnread
    /// Sets or clears \\Flagged on the copy acted on.
    case flag
    case unflag
    /// Moves the copy acted on to `to`, one of the account's folders (its path).
    case move(to: String)
    case archive
    /// Moves the message to Trash; a message already in Trash is left alone.
    case delete
    /// Erases a message that is in Trash. Only an explicit "Delete
    /// Permanently" request asks for this; outside Trash it is refused.
    case deletePermanently
}

/// The message after an action, and for a Delete what it did.
public struct DirectMailboxActionResult: Sendable {
    public let message: MessageSummary
    public let deleteOutcome: DeleteOutcome?
    /// An Archive of a copy already in the account's Archive: nothing was sent
    /// and nothing changed, as a Delete in Trash.
    public let alreadyArchived: Bool

    public init(message: MessageSummary, deleteOutcome: DeleteOutcome? = nil, alreadyArchived: Bool = false) {
        self.message = message
        self.deleteOutcome = deleteOutcome
        self.alreadyArchived = alreadyArchived
    }
}

/// Account-owned provider actions shared by the service and device-local runtime.
/// Read state is durable offline; destructive actions require provider confirmation.
public struct DirectMailboxActionService: Sendable {
    private let store: SQLiteMailStore
    private let credentials: MailCredentialResolver
    private let requireExplicitDirectSource: Bool
    private let selectedAccountID: AccountID?
    private let selectedSourceGeneration: Int64?
    private let imapClientFactory: @Sendable (String, UInt16) -> IMAPClientProtocol
    private let signalFlagWork: @Sendable () async throws -> Void
    private let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

    public init(
        store: SQLiteMailStore,
        credentials: MailCredentialResolver,
        requireExplicitDirectSource: Bool,
        selectedAccountID: AccountID? = nil,
        imapClientFactory: @escaping @Sendable (String, UInt16) -> IMAPClientProtocol = {
            MailTransportClientFactory.imapClient(host: $0, port: $1)
        },
        signalFlagWork: @escaping @Sendable () async throws -> Void
    ) {
        self.store = store
        self.credentials = credentials
        self.requireExplicitDirectSource = requireExplicitDirectSource
        self.selectedAccountID = selectedAccountID
        if let selectedAccountID,
           let source = try? store.explicitMailSource(accountID: selectedAccountID),
           source.kind == .direct {
            self.selectedSourceGeneration = source.generation
        } else {
            self.selectedSourceGeneration = nil
        }
        self.imapClientFactory = imapClientFactory
        self.signalFlagWork = signalFlagWork
    }

    public func perform(
        _ action: DirectMailboxAction,
        messageID: MessageID,
        archiveMailbox: String? = nil,
        shownIn shownMailbox: String? = nil,
        shownUID: Int? = nil
    ) async throws -> DirectMailboxActionResult {
        // Archive and delete act on the copy the user acted on: the one in the
        // mailbox they were looking at (see `actionMembership`).
        let membership = action == .markRead || action == .markUnread
            ? try store.membership(for: messageID)
            : try store.actionMembership(for: messageID, shownIn: shownMailbox, uid: shownUID)
        guard membership.messageID == messageID else {
            throw PlainpostError.validationFailed("Message membership does not match the action target.")
        }
        guard selectedAccountID == nil || membership.accountID == selectedAccountID else {
            throw PlainpostError.permissionDenied("The message does not belong to the selected account.")
        }
        // Single-row reads: bulk Ask Mail actions call this once per message.
        if let threadID = try store.messageSummary(id: messageID)?.threadID,
           let thread = try store.thread(id: threadID),
           thread.accountID != membership.accountID {
            throw PlainpostError.validationFailed("Message and thread owners do not match.")
        }
        let sourceSnapshot = try directSourceSnapshot(accountID: membership.accountID)
        if selectedAccountID != nil {
            guard let selectedSourceGeneration else {
                throw NodeMailModeStoreError.generationConflict
            }
            switch sourceSnapshot {
            case .direct(let generation) where generation == selectedSourceGeneration:
                break
            default:
                throw NodeMailModeStoreError.generationConflict
            }
        }
        guard let account = store.accounts.first(where: { $0.id == membership.accountID }) else {
            throw PlainpostError.notFound("Owning account was not found.")
        }

        switch action {
        case .markRead, .markUnread:
            let message: MessageSummary
            if let selectedAccountID, let selectedSourceGeneration {
                message = try store.markSelectedDirectSeen(
                    messageID,
                    seen: action == .markRead,
                    actor: actor,
                    accountID: selectedAccountID,
                    expectedSourceGeneration: selectedSourceGeneration
                )
            } else if requireExplicitDirectSource, case .direct(let generation) = sourceSnapshot {
                // No selected account (the device-wide iOS runtime): fence the owner's own
                // source, and give its flag job the generation a worker claims it against.
                message = try store.markSelectedDirectSeen(
                    messageID,
                    seen: action == .markRead,
                    actor: actor,
                    accountID: membership.accountID,
                    expectedSourceGeneration: generation
                )
            } else {
                message = try store.markSeen(messageID, seen: action == .markRead, actor: actor)
            }
            try? await signalFlagWork()
            return DirectMailboxActionResult(message: message)
        case .flag, .unflag:
            let flagged = action == .flag
            do {
                try await credentials.withIMAPAuthentication(for: account) { [self] authentication in
                    try requireUnchangedDirectSource(accountID: membership.accountID, snapshot: sourceSnapshot)
                    let client = imapClientFactory(account.imapHost, account.imapPort)
                    do {
                        try await client.authenticate(username: account.username, authentication: authentication)
                        let selection = try await client.selectMailbox(membership.mailboxPath)
                        guard IMAPSyncService.uidValidity(from: selection) == membership.uidValidity else {
                            throw PlainpostError.validationFailed("Mailbox state changed. Sync is required before updating this message.")
                        }
                        try await client.setFlags(
                            uid: membership.uid, add: flagged ? ["\\Flagged"] : [], remove: flagged ? [] : ["\\Flagged"],
                            expectedModSequence: nil
                        )
                        await client.disconnect()
                    } catch {
                        await client.disconnect()
                        throw error
                    }
                }
            } catch MailCredentialError.unavailable {
                throw PlainpostError.validationFailed("IMAP credentials are not available.")
            }
            let message = try store.applyConfirmedMailboxAction(
                .flag(flagged), membership: membership, sourceSnapshot: sourceSnapshot, actor: actor
            )
            return DirectMailboxActionResult(message: message)
        case .move(let destination):
            let accountMailboxes = store.mailboxes.filter { $0.accountID == membership.accountID }
            guard accountMailboxes.contains(where: { $0.path == destination }) else {
                throw PlainpostError.validationFailed("That folder isn't in this account.")
            }
            guard destination != membership.mailboxPath else {
                // Already there: nothing to send.
                guard let message = try store.messageSummary(id: messageID) else { throw PlainpostError.notFound("Message not found.") }
                return DirectMailboxActionResult(message: message.withMailboxPath(membership.mailboxPath))
            }
            let moved: IMAPMoveResult
            let duplicates = try store.duplicateCopyUIDs(of: membership)
            let confirmedDuplicates: [Int]
            do {
                (moved, confirmedDuplicates) = try await credentials.withIMAPAuthentication(for: account) { [self] authentication in
                    try requireUnchangedDirectSource(accountID: membership.accountID, snapshot: sourceSnapshot)
                    let client = imapClientFactory(account.imapHost, account.imapPort)
                    do {
                        try await client.authenticate(username: account.username, authentication: authentication)
                        let selection = try await client.selectMailbox(membership.mailboxPath)
                        guard IMAPSyncService.uidValidity(from: selection) == membership.uidValidity else {
                            throw PlainpostError.validationFailed("Mailbox state changed. Sync is required before updating this message.")
                        }
                        try requireUnchangedDirectSource(accountID: membership.accountID, snapshot: sourceSnapshot)
                        // Reports where the copy landed (COPYUID), so it never keeps the source UID.
                        let result = try await client.move(uid: membership.uid, to: destination)
                        let confirmedDuplicates = await client.moveDuplicates(duplicates, to: destination)
                        await client.disconnect()
                        return (result, confirmedDuplicates)
                    } catch {
                        await client.disconnect()
                        throw error
                    }
                }
            } catch MailCredentialError.unavailable {
                throw PlainpostError.validationFailed("IMAP credentials are not available.")
            }
            let message = try store.applyConfirmedMailboxAction(
                .archive(to: moved.mailbox, uidValidity: moved.uidValidity, uid: moved.uid),
                membership: membership, duplicateUIDs: confirmedDuplicates,
                sourceSnapshot: sourceSnapshot, actor: actor
            )
            return DirectMailboxActionResult(message: message)
        case .archive, .delete, .deletePermanently:
            let permanent = action == .deletePermanently
            let accountMailboxes = store.mailboxes.filter { $0.accountID == membership.accountID }
            if action != .archive,
               TrashDelete.precheck(
                   sourceMailbox: membership.mailboxPath, cachedMailboxes: accountMailboxes, permanent: permanent
               ) == .alreadyInTrash,
               let message = try store.messageSummary(id: messageID) {
                // A plain Delete never erases: a message already in Trash stays, untouched.
                return DirectMailboxActionResult(message: message, deleteOutcome: .alreadyInTrash)
            }
            if action == .archive,
               ArchiveMailbox.isAlreadyArchived(
                   sourceMailbox: membership.mailboxPath, requested: archiveMailbox, cachedMailboxes: accountMailboxes
               ),
               let message = try store.messageSummary(id: messageID) {
                // The copy is already in the Archive: no move into its own mailbox.
                return DirectMailboxActionResult(
                    message: message.withMailboxPath(membership.mailboxPath), alreadyArchived: true
                )
            }
            let duplicates = try store.duplicateCopyUIDs(of: membership)
            let confirmedStep: (cache: ConfirmedMailboxCacheAction?, outcome: DeleteOutcome?, confirmedDuplicates: [Int])
            do {
                confirmedStep = try await credentials.withIMAPAuthentication(for: account) { [self] authentication in
                    try requireUnchangedDirectSource(accountID: membership.accountID, snapshot: sourceSnapshot)
                    _ = try store.membership(
                        for: messageID, accountID: membership.accountID,
                        mailboxPath: membership.mailboxPath,
                        uidValidity: membership.uidValidity, uid: membership.uid
                    )
                    let client = imapClientFactory(account.imapHost, account.imapPort)
                    do {
                        try await client.authenticate(username: account.username, authentication: authentication)
                        let selection = try await client.selectMailbox(membership.mailboxPath)
                        guard IMAPSyncService.uidValidity(from: selection) == membership.uidValidity else {
                            throw PlainpostError.validationFailed("Mailbox state changed. Sync is required before updating this message.")
                        }
                        // Decide before the last checks, so nothing changes on a refusal:
                        // an account without Trash, or without an Archive, refuses here.
                        let deletePlan = action == .archive ? nil : try await TrashDelete.plan(
                            client: client, sourceMailbox: membership.mailboxPath,
                            cachedMailboxes: accountMailboxes, permanent: permanent
                        )
                        let archiveDestination = action == .archive ? try await ArchiveMailbox.resolve(
                            requested: archiveMailbox, client: client, cachedMailboxes: accountMailboxes
                        ) : nil
                        try requireUnchangedDirectSource(accountID: membership.accountID, snapshot: sourceSnapshot)
                        _ = try store.membership(
                            for: messageID, accountID: membership.accountID,
                            mailboxPath: membership.mailboxPath,
                            uidValidity: membership.uidValidity, uid: membership.uid
                        )
                        let confirmed: (cache: ConfirmedMailboxCacheAction?, outcome: DeleteOutcome?, confirmedDuplicates: [Int])
                        if let deletePlan {
                            let step = try await MailActionServerRefusal.mapping(.delete) {
                                try await TrashDelete.execute(deletePlan, client: client, uid: membership.uid)
                            }
                            switch step {
                            case .moved(let moved):
                                // Delete moves the message to Trash, as Apple Mail does.
                                confirmed = (
                                    .trash(to: moved.mailbox, uidValidity: moved.uidValidity, uid: moved.uid), .movedToTrash,
                                    await client.moveDuplicates(duplicates, to: moved.mailbox)
                                )
                            case .alreadyInTrash:
                                confirmed = (nil, .alreadyInTrash, [])
                            case .erased:
                                // Only an explicit Delete Permanently, in Trash, erases.
                                confirmed = (.delete, .deletedPermanently, await client.deleteDuplicates(duplicates))
                            }
                        } else {
                            guard let archiveDestination else {
                                throw PlainpostError.validationFailed(ArchiveMailbox.noArchiveMessage)
                            }
                            guard archiveDestination.caseInsensitiveCompare(membership.mailboxPath) != .orderedSame else {
                                // Found by the server's list: already in the Archive, nothing to send.
                                await client.disconnect()
                                return (nil, nil, [])
                            }
                            // A move that reports where the copy landed (COPYUID), so the
                            // Archive copy never keeps the source UID.
                            let moved = try await MailActionServerRefusal.mapping(.archive) {
                                try await client.move(uid: membership.uid, to: archiveDestination)
                            }
                            confirmed = (
                                .archive(to: moved.mailbox, uidValidity: moved.uidValidity, uid: moved.uid), nil,
                                await client.moveDuplicates(duplicates, to: archiveDestination)
                            )
                        }
                        await client.disconnect()
                        return confirmed
                    } catch {
                        await client.disconnect()
                        throw error
                    }
                }
            } catch MailCredentialError.unavailable {
                throw PlainpostError.validationFailed("IMAP credentials are not available.")
            }
            guard let cacheAction = confirmedStep.cache else {
                guard let message = try store.messageSummary(id: messageID) else {
                    throw PlainpostError.notFound("Message not found.")
                }
                if action == .archive {
                    return DirectMailboxActionResult(
                        message: message.withMailboxPath(membership.mailboxPath), alreadyArchived: true
                    )
                }
                return DirectMailboxActionResult(message: message, deleteOutcome: confirmedStep.outcome)
            }
            let message = try store.applyConfirmedMailboxAction(
                cacheAction,
                membership: membership,
                duplicateUIDs: confirmedStep.confirmedDuplicates,
                sourceSnapshot: sourceSnapshot,
                actor: actor
            )
            return DirectMailboxActionResult(message: message, deleteOutcome: confirmedStep.outcome)
        }
    }


    private func directSourceSnapshot(accountID: AccountID) throws -> ConfirmedMailboxSourceSnapshot {
        if requireExplicitDirectSource {
            try store.requireDirectSyncSource(accountID: accountID)
        }
        guard let source = try store.explicitMailSource(accountID: accountID) else {
            return .implicitDirect
        }
        // A Node account in fallback is synced, and acted on, by this device.
        guard source.runsDirectSync else { throw NodeMailModeStoreError.generationConflict }
        return .direct(generation: source.generation)
    }

    private func requireUnchangedDirectSource(
        accountID: AccountID,
        snapshot: ConfirmedMailboxSourceSnapshot
    ) throws {
        let current = try directSourceSnapshot(accountID: accountID)
        switch (snapshot, current) {
        case (.implicitDirect, .implicitDirect): return
        case (.direct(let expected), .direct(let actual)) where expected == actual: return
        default:
            throw NodeMailModeStoreError.generationConflict
        }
    }
}
