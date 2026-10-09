import os
import Foundation
import PlainpostAI
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB

protocol InboxProjectionSource: Sendable {
    func mailboxListMessages(limit: Int, query: String) throws -> [MailboxListMessage]
    func mailboxListMessageCount(query: String) throws -> Int
    /// One of `accounts()`'s folder's messages, newest first; none for another account.
    func folderListMessages(accountID: AccountID, path: String, limit: Int) throws -> [MailboxListMessage]
    func sentMailboxListMessages(limit: Int, query: String) throws -> [MailboxListMessage]
    func sentMailboxListMessageCount(query: String) throws -> Int
    func mailboxUnreadConversationCounts(query: String) throws -> MailboxUnreadConversationCounts
    func completeConversation(containing messageID: MessageID) throws -> [MessageSummary]
    func attachments(for message: MessageSummary) throws -> [MailAttachment]
    func accountID(containing messageID: MessageID) throws -> AccountID?
    func thread(id: ThreadID) throws -> MailThread?
    func accounts() throws -> [Account]
    func mailboxes(limit: Int) throws -> [Mailbox]
    /// Unread, non-deleted messages per mailbox path for one of `accounts()`; every path
    /// the account has mail in is a key.
    func folderUnreadCounts(accountID: AccountID) throws -> [String: Int]
    /// The people one of `accounts()` has mailed with, newest first, never one of
    /// `ownAddresses`.
    func recentCorrespondents(accountID: AccountID, ownAddresses: Set<String>) throws -> [Correspondent]
    func pendingApprovalCount() throws -> Int
    func readAuthority() throws -> InboxReadAuthority
    func waitingMessageIDs(_ messageIDs: [MessageID]) throws -> Set<MessageID>
    func notificationMessageIDs(after: MessageID?, limit: Int) throws -> [MessageID]
    func notificationMessageAccountID(_ messageID: MessageID) throws -> AccountID?
}

extension InboxProjectionSource {
    func readAuthority() throws -> InboxReadAuthority { .init(accountID: nil, source: nil) }
    func waitingMessageIDs(_ messageIDs: [MessageID]) throws -> Set<MessageID> { [] }
    func notificationMessageIDs(after: MessageID?, limit: Int) throws -> [MessageID] { [] }
    func notificationMessageAccountID(_ messageID: MessageID) throws -> AccountID? { nil }

    func attachments(for message: MessageSummary) throws -> [MailAttachment] {
        message.attachments
    }

    func folderListMessages(accountID: AccountID, path: String, limit: Int) throws -> [MailboxListMessage] {
        []
    }
}

struct DirectIncomingAttachmentID: Equatable, Sendable {
    let accountID: AccountID
    let messageID: MessageID
    let partPath: String
    let sourceGeneration: Int64

    var encoded: String {
        ["direct-v1", Self.hex(accountID.rawValue), Self.hex(messageID.rawValue),
         Self.hex(partPath), String(sourceGeneration)].joined(separator: "|")
    }

    func attachment(for metadata: SQLiteIncomingAttachmentMetadata) -> MailAttachment {
        let digest = Data(stride(from: 0, to: metadata.sha256.count, by: 2).compactMap { offset -> UInt8? in
            let start = metadata.sha256.index(metadata.sha256.startIndex, offsetBy: offset)
            let end = metadata.sha256.index(start, offsetBy: 2)
            return UInt8(metadata.sha256[start ..< end], radix: 16)
        }).base64EncodedString()
        return MailAttachment(
            id: encoded, filename: metadata.filename,
            mimeType: metadata.mimeType ?? "application/octet-stream",
            disposition: "attachment", byteCount: metadata.byteCount,
            contentDigest: digest
        )
    }

    static func decode(_ encoded: String) -> Self? {
        let components = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 5, components[0] == "direct-v1",
              let account = unhex(components[1]), !account.isEmpty,
              let message = unhex(components[2]), !message.isEmpty,
              let part = unhex(components[3]), !part.isEmpty,
              let generation = Int64(components[4]), generation >= 0 else { return nil }
        return Self(
            accountID: AccountID(account), messageID: MessageID(message),
            partPath: part, sourceGeneration: generation
        )
    }

    private static func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func unhex(_ value: Substring) -> String? {
        guard value.count.isMultiple(of: 2), value.count <= 2_048 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

struct SQLiteInboxProjectionSource: InboxProjectionSource, @unchecked Sendable {
    /// `deviceDirect` reads every account whose source is an explicit `.direct`, as of each
    /// read: the device-wide iOS runtime's projection.
    enum Scope { case deviceDirect }

    let store: SQLiteMailStore
    let accountID: AccountID?
    let requiresDirectSource: Bool
    let expectedDirectGeneration: Int64?
    let isDeviceDirect: Bool

    init(store: SQLiteMailStore, accountID: AccountID? = nil,
         requiresDirectSource: Bool = false, expectedDirectGeneration: Int64? = nil) {
        self.store = store
        self.accountID = accountID
        self.requiresDirectSource = requiresDirectSource
        self.expectedDirectGeneration = expectedDirectGeneration
        self.isDeviceDirect = false
    }

    init(store: SQLiteMailStore, scope: Scope) {
        self.store = store
        self.accountID = nil
        self.requiresDirectSource = true
        self.expectedDirectGeneration = nil
        self.isDeviceDirect = true
    }

    /// The accounts a read covers: one, every Direct account, or all.
    /// A device-wide source over a store with no accounts yet reads it all, as an unscoped
    /// runtime does: there is no Sync Node account's mail to keep out.
    private var accountFilter: MailboxAccountFilter {
        if isDeviceDirect, !store.accounts.isEmpty {
            return .accounts(DeviceMailScope.current(in: store).accountIDs)
        }
        return MailboxAccountFilter(accountID)
    }

    /// Whether `owner` is one of the accounts this source reads.
    private func covers(_ owner: AccountID) -> Bool {
        if isDeviceDirect, !store.accounts.isEmpty {
            return DeviceMailScope.current(in: store).accountIDs.contains(owner)
        }
        return accountID == nil || owner == accountID
    }

    func readAuthority() throws -> InboxReadAuthority {
        if isDeviceDirect {
            return InboxReadAuthority(accountID: nil, source: nil, deviceDirect: DeviceMailScope.current(in: store))
        }
        let accounts = try store.readAccounts()
        guard let accountID else {
            guard !requiresDirectSource || accounts.isEmpty else { throw InboxProjectionReadError.sourceChanged }
            return InboxReadAuthority(accountID: nil, source: nil)
        }
        guard accounts.contains(where: { $0.id == accountID }) else { throw InboxProjectionReadError.sourceChanged }
        if requiresDirectSource { try store.requireDirectMailSource(accountID: accountID) }
        let source = try store.mailSource(accountID: accountID)
        guard !requiresDirectSource || (source.kind == .direct && source.generation == expectedDirectGeneration)
        else { throw InboxProjectionReadError.sourceChanged }
        return InboxReadAuthority(accountID: accountID, source: source)
    }

    func waitingMessageIDs(_ messageIDs: [MessageID]) throws -> Set<MessageID> {
        try store.mailIntentsWaitingForNode(messageIDs: messageIDs)
    }

    func notificationMessageIDs(after: MessageID?, limit: Int) throws -> [MessageID] {
        try store.notificationMessageIDs(accountFilter: accountFilter, after: after, limit: limit)
    }

    func notificationMessageAccountID(_ messageID: MessageID) throws -> AccountID? {
        try store.notificationMessageAccountID(messageID)
    }

    func mailboxListMessages(limit: Int, query: String) throws -> [MailboxListMessage] {
        try store.mailboxListMessages(
            inMailboxPath: "INBOX",
            accountFilter: accountFilter,
            limit: limit,
            query: query
        )
    }

    func mailboxListMessageCount(query: String) throws -> Int {
        try store.mailboxListMessageCount(inMailboxPath: "INBOX", accountFilter: accountFilter, query: query)
    }

    func folderListMessages(accountID requested: AccountID, path: String, limit: Int) throws -> [MailboxListMessage] {
        guard covers(requested) else { return [] }
        return try store.folderListMessages(accountID: requested, mailboxPath: path, limit: limit)
    }

    func sentMailboxListMessages(limit: Int, query: String) throws -> [MailboxListMessage] {
        try store.sentMailboxListMessages(accountFilter: accountFilter, limit: limit, query: query)
    }

    func sentMailboxListMessageCount(query: String) throws -> Int {
        try store.sentMailboxListMessageCount(accountFilter: accountFilter, query: query)
    }

    func mailboxUnreadConversationCounts(query: String) throws -> MailboxUnreadConversationCounts {
        try store.mailboxUnreadConversationCounts(inMailboxPath: "INBOX", accountFilter: accountFilter, query: query)
    }

    func completeConversation(containing messageID: MessageID) throws -> [MessageSummary] {
        guard let selected = try store.messageSummary(id: messageID) else { return [] }
        guard let owner = store.accountID(forMessageID: messageID) else {
            return accountID == nil && (!isDeviceDirect || store.accounts.isEmpty) ? [selected] : []
        }
        guard covers(owner) else { return [] }
        guard let threadID = selected.threadID else { return [selected] }
        if !threadID.rawValue.hasPrefix("thr_uid_") {
            return try store.messageSummaries(threadID: threadID, accountID: owner)
        }
        let normalizedSubject = MailThreading.normalizedSubject(selected.subject)
        let inboxIDs = try store.legacyInboxConversationMessageIDs(
            accountID: owner, normalizedSubject: normalizedSubject
        ).filter { store.accountID(forMessageID: $0) == owner }
        // A sent reply can outlive its original Inbox membership. Always
        // retain the selected Sent copy when resolving a legacy UID thread.
        return try store.messageSummaries(ids: Array(Set(inboxIDs).union([messageID])))
    }

    func attachments(for message: MessageSummary) throws -> [MailAttachment] {
        guard let owner = store.accountID(forMessageID: message.id), covers(owner) else { return [] }
        let source = try store.mailSource(accountID: owner)
        guard source.kind == .direct else { return [] }
        return try store.incomingMessageAttachmentMetadata(messageID: message.id).map { metadata in
            DirectIncomingAttachmentID(
                accountID: owner, messageID: message.id,
                partPath: metadata.partPath, sourceGeneration: source.generation
            ).attachment(for: metadata)
        }
    }

    func accountID(containing messageID: MessageID) throws -> AccountID? {
        guard let owner = store.accountID(forMessageID: messageID) else { return nil }
        return covers(owner) ? owner : nil
    }

    func thread(id: ThreadID) throws -> MailThread? {
        guard let thread = try store.thread(id: id) else { return nil }
        return covers(thread.accountID) ? thread : nil
    }
    func accounts() throws -> [Account] {
        let filter = accountFilter
        return try store.readAccounts().filter { account in
            if case .accounts(let ids) = filter { return ids.contains(account.id) }
            return true
        }
    }
    func mailboxes(limit: Int) throws -> [Mailbox] {
        try store.mailboxes(limit: limit, accountFilter: accountFilter)
    }
    func folderUnreadCounts(accountID requested: AccountID) throws -> [String: Int] {
        guard covers(requested) else { return [:] }
        return try store.folderUnreadCounts(accountID: requested)
    }
    func recentCorrespondents(accountID requested: AccountID, ownAddresses: Set<String>) throws -> [Correspondent] {
        guard covers(requested) else { return [] }
        return try store.recentCorrespondents(accountID: requested, ownAddresses: ownAddresses)
    }
    func pendingApprovalCount() throws -> Int {
        try store.approvalQueueRequests.filter { request in
            guard request.status == .pending else { return false }
            let draft = try store.draft(id: request.draftID)
            return covers(draft.accountID)
        }.count
    }
}

enum InboxProjectionReadError: Error {
    case sourceChanged
}

struct InboxReadAuthority: Equatable, Sendable {
    let accountID: AccountID?
    let source: AccountMailSource?
    /// The device-wide runtime's Direct accounts and generations as of the read.
    var deviceDirect: DeviceMailSources? = nil
}

struct NotificationIdentityRead: Sendable {
    let destination: PlainpostNotificationOpenDestination?
    let authority: InboxReadAuthority
}

struct InboxMailboxPage: Sendable {
    let authority: InboxReadAuthority
    let waitingMessageIDs: Set<String>
    let revision: UInt64
    let rows: [MessageRowModel]
    let sentRows: [MessageRowModel]
    let totalRowCount: Int
    let hasMoreRows: Bool
    let hasMoreSentRows: Bool
    let smartCards: [SmartInboxCardModel]
    let sidebarItems: [SidebarItemModel]
    let aiIndexStatus: AIIndexStatusModel
    let accounts: [Account]
}

actor InboxProjectionRepository {
    static let pageSize = 200

    private struct Index: Sendable {
        let listMessages: [MailboxListMessage]
        let rows: [MessageRowModel]
        let sentListMessages: [MailboxListMessage]
        let sentRows: [MessageRowModel]
        let query: String
        let loadedLimit: Int
        let totalMessageCount: Int
        let totalSentMessageCount: Int
        let unreadCounts: SidebarUnreadCounts
        let accounts: [Account]
        let pendingApprovalCount: Int
    }

    private let signposter = OSSignposter(subsystem: "com.plainpost.performance", category: "projection")
    private let source: any InboxProjectionSource
    private var index: Index?
    private var indexAuthority: InboxReadAuthority?
    private var mailSearchMailboxCache: [MailSearchMailbox]?
    private(set) var indexBuildCount = 0
    var loadedListMessageCount: Int { index?.listMessages.count ?? 0 }

    init(source: any InboxProjectionSource) {
        self.source = source
    }

    func mailboxPage(limit: Int, query: String, forceReload: Bool) throws -> InboxMailboxPage {
        let interval = signposter.beginInterval("MailboxPage", id: signposter.makeSignpostID())
        defer { signposter.endInterval("MailboxPage", interval) }
        let authority = try source.readAuthority()
        if forceReload || indexAuthority != authority {
            index = nil
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = try currentIndex(limit: limit, query: normalizedQuery)
        indexAuthority = authority
        let boundedLimit = min(max(limit, 1), index.rows.count)
        let visibleRows = Array(index.rows.prefix(boundedLimit))
        let aiIndexStatus = AIIndexStatusModel(
            snapshot: AIIndexStatusSnapshot(
                state: .ready,
                indexedMessageCount: index.totalMessageCount,
                providerID: "local-search",
                modelID: "built-in-local-embeddings",
                isStale: false,
                localOnly: true
            )
        )
        // A journal read failure omits the badge; authority verification still
        // throws on source/account failure, including a change during this read.
        let waiting = (try? source.waitingMessageIDs(visibleRows.map { MessageID($0.id) })) ?? []
        try verifyAuthority(authority)
        return InboxMailboxPage(
            authority: authority,
            waitingMessageIDs: Set(waiting.map(\.rawValue)),
            revision: (UInt64(indexBuildCount) << 32) | UInt64(min(index.loadedLimit, Int(UInt32.max))),
            rows: visibleRows,
            sentRows: Array(index.sentRows.prefix(max(limit, 1))),
            totalRowCount: index.totalMessageCount,
            hasMoreRows: index.listMessages.count < index.totalMessageCount,
            hasMoreSentRows: index.sentListMessages.count < index.totalSentMessageCount,
            smartCards: SmartInboxCardModel.cards(from: visibleRows),
            sidebarItems: SidebarItemModel.defaultItems(
                unreadCounts: index.unreadCounts,
                pendingApprovalCount: index.pendingApprovalCount,
                aiIndexWarningCount: aiIndexStatus.needsAttention ? 1 : nil
            ),
            aiIndexStatus: aiIndexStatus,
            accounts: index.accounts
        )
    }

    func readAuthority() throws -> InboxReadAuthority { try source.readAuthority() }

    func verifyAuthority(_ authority: InboxReadAuthority) throws {
        guard try source.readAuthority() == authority else { throw InboxProjectionReadError.sourceChanged }
    }

    func account(id: AccountID?) throws -> Account? {
        guard let id else { return nil }
        return try source.accounts().first { $0.id == id }
    }

    /// Unknown tokens may visit every identity; only one bounded batch is retained.
    func notificationIdentity(_ token: String) throws -> NotificationIdentityRead {
        let interval = signposter.beginInterval("NotificationIdentityRead", id: signposter.makeSignpostID())
        defer { signposter.endInterval("NotificationIdentityRead", interval) }
        let authority = try source.readAuthority()
        var after: MessageID?
        while true {
            try Task.checkCancellation()
            let identities = try source.notificationMessageIDs(after: after, limit: 256)
            signposter.emitEvent("NotificationIdentityBatch", "identity_rows=\(identities.count, privacy: .public) body_rows=0")
            for id in identities {
                let candidate: String
                if let accountID = authority.accountID, let mailSource = authority.source {
                    candidate = NotificationOpaqueIdentities.messageToken(
                        for: id.rawValue, accountID: accountID.rawValue,
                        sourceKind: mailSource.kind.rawValue, sourceGeneration: mailSource.generation
                    )
                } else {
                    candidate = NotificationOpaqueIdentities.messageToken(for: id.rawValue)
                }
                if candidate == token {
                    try verifyAuthority(authority)
                    return NotificationIdentityRead(destination: .message(id.rawValue), authority: authority)
                }
            }
            guard identities.count == 256 else { break }
            after = identities.last
        }
        let account = try source.accounts().first {
            NotificationOpaqueIdentities.accountInboxToken(for: $0.id.rawValue) == token
        }
        try verifyAuthority(authority)
        return NotificationIdentityRead(destination: account.map { .accountInbox($0.id.rawValue) }, authority: authority)
    }

    func notificationMappingIsCurrent(messageID: String, authority: InboxReadAuthority) throws -> Bool {
        let ownerMatches = try authority.accountID == nil
            || source.notificationMessageAccountID(MessageID(messageID)) == authority.accountID
        try verifyAuthority(authority)
        return ownerMatches
    }

    func threadDetail(messageID: String) throws -> ThreadDetailModel {
        let interval = signposter.beginInterval("ThreadDetail", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ThreadDetail", interval) }
        let id = MessageID(messageID)
        let owner = try source.accountID(containing: id)
        let messages = try source.completeConversation(containing: id).sorted {
            let lhs = $0.sentAt ?? .distantPast
            let rhs = $1.sentAt ?? .distantPast
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
        }
        signposter.emitEvent("ConversationHydrated", "body_rows=\(messages.count, privacy: .public)")
        guard let selected = messages.first(where: { $0.id == id }) ?? messages.last else {
            return Self.emptyThread
        }
        let thread = try selected.threadID.flatMap { try source.thread(id: $0) }
        let threadParticipants = thread?.accountID == owner
            ? thread?.participantEmails.map(\.rawValue) ?? [] : []
        let messageParticipants = messages.map(\.from.rawValue)
        let accountParticipants = index?.accounts.first(where: { $0.id == owner })
            .map { [$0.email.rawValue] } ?? []
        let participants = Array(Set(threadParticipants + messageParticipants + accountParticipants)).sorted()
        return ThreadDetailModel(
            subject: messages.first?.subject ?? selected.subject,
            participants: participants,
            summaryStatus: "Not summarized",
            actionItems: [],
            availableActions: ["Reply", "Reply all", "Forward", "Archive", "Delete"],
            messages: try messages.map { message in
                let input = message.bodyHTML.map(EmailBodyInput.html) ?? .plainText(message.body)
                return ThreadMessageModel(
                    id: message.id.rawValue,
                    sender: message.from.rawValue,
                    senderDisplayName: message.fromDisplayName,
                    replyTo: message.replyTo?.rawValue,
                    dateLabel: MailTimestampFormatter.readerLabel(for: message.sentAt),
                    deferredBody: input,
                    fallbackText: message.body,
                    blockedRemoteImageURLs: message.bodyHTML.map(EmailBodyRenderer.remoteImageURLs(inHTML:)) ?? [],
                    translationSourceFingerprint: MailTranslationFingerprint.message(message),
                    sourceThreadID: message.threadID,
                    rfcMessageID: message.rfcMessageID,
                    inReplyTo: message.inReplyTo,
                    references: message.references,
                    attachments: try source.attachments(for: message),
                    to: message.to.map(\.rawValue),
                    cc: message.cc.map(\.rawValue)
                )
            }
        )
    }

    /// The unread messages of `messageID`'s conversation, the conversation the reader shows.
    func unreadConversationMessageIDs(containing messageID: MessageID) throws -> [MessageID] {
        try source.completeConversation(containing: messageID).filter { !$0.isSeen }.map(\.id)
    }

    func mailSearchMailboxes(forceReload: Bool) throws -> [MailSearchMailbox] {
        if forceReload { mailSearchMailboxCache = nil }
        if let mailSearchMailboxCache { return mailSearchMailboxCache }
        let mailboxes = try source.mailboxes(limit: MailSearchMailbox.maximumMetadataCount).map {
            MailSearchMailbox(
                id: $0.id,
                accountID: $0.accountID,
                displayName: $0.name.isEmpty ? $0.path : $0.name
            )
        }
        mailSearchMailboxCache = mailboxes
        return mailboxes
    }

    /// Each account's folders with their unread counts, for a Mailboxes list.
    func mailboxDirectory() throws -> [MailboxAccountSection] {
        let accounts = try source.accounts()
        var unreadCounts: [AccountID: [String: Int]] = [:]
        for account in accounts {
            unreadCounts[account.id] = try source.folderUnreadCounts(accountID: account.id)
        }
        return MailboxDirectoryModel.sections(
            accounts: accounts,
            mailboxes: try source.mailboxes(limit: MailboxDirectoryModel.mailboxLimit),
            unreadCounts: unreadCounts
        )
    }

    /// One account folder's messages, newest first, for the iPhone folder list. The source
    /// already returns them newest first (the store orders by date, then id).
    func folderRows(accountID: AccountID, path: String, limit: Int = pageSize) throws -> [MessageRowModel] {
        try source.folderListMessages(accountID: accountID, path: path, limit: limit)
            .map(MessageRowModel.init(message:))
    }

    /// The people the source's accounts have mailed with, merged newest first, for
    /// recipient suggestions. `ownAddresses` are every address the user sends from.
    func recentCorrespondents(ownAddresses: Set<String>) throws -> [Correspondent] {
        Correspondent.merged(try source.accounts().map { account in
            try source.recentCorrespondents(accountID: account.id, ownAddresses: ownAddresses)
        })
    }

    func invalidate() {
        index = nil
        mailSearchMailboxCache = nil
    }

    private func currentIndex(limit: Int, query: String) throws -> Index {
        let boundedLimit = max(limit, 1)
        if let index, index.query == query, index.loadedLimit >= boundedLimit {
            return index
        }
        let interval = signposter.beginInterval("ProjectionIndexBuild", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ProjectionIndexBuild", interval) }
        let previousIndex = index
        let isIncrementalExtension = previousIndex?.query == query
        let listMessages = try source.mailboxListMessages(limit: boundedLimit, query: query)
        let rows = MessageRowModel.threadedRows(from: listMessages)
        let sentListMessages = try source.sentMailboxListMessages(limit: boundedLimit, query: query)
        let sentRows = sentListMessages.map(MessageRowModel.init(message:))
        let unreadCounts: SidebarUnreadCounts
        if isIncrementalExtension, let previousIndex {
            unreadCounts = previousIndex.unreadCounts
        } else {
            unreadCounts = SidebarUnreadCounts(
                mailboxCounts: try source.mailboxUnreadConversationCounts(query: query)
            )
        }
        let built = Index(
            listMessages: listMessages,
            rows: rows,
            sentListMessages: sentListMessages,
            sentRows: sentRows,
            query: query,
            loadedLimit: boundedLimit,
            totalMessageCount: try source.mailboxListMessageCount(query: query),
            totalSentMessageCount: try source.sentMailboxListMessageCount(query: query),
            unreadCounts: unreadCounts,
            accounts: try source.accounts(),
            pendingApprovalCount: try source.pendingApprovalCount()
        )
        signposter.emitEvent("ProjectionRowsFetched", "inbox_rows=\(listMessages.count, privacy: .public) sent_rows=\(sentListMessages.count, privacy: .public)")
        index = built
        if !isIncrementalExtension {
            indexBuildCount += 1
        }
        return built
    }

    private static let emptyThread = ThreadDetailModel(
        subject: "No conversation selected",
        participants: [],
        summaryStatus: "Not summarized",
        actionItems: [],
        availableActions: []
    )
}
