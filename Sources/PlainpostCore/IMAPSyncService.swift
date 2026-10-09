import CryptoKit
import Foundation

public struct IMAPAccountCredentials: Equatable, Sendable {
    public let accountID: AccountID
    public let email: EmailAddress
    public let username: String
    public let authentication: MailAuthentication

    public init(accountID: AccountID, email: EmailAddress, username: String, authentication: MailAuthentication) {
        self.accountID = accountID
        self.email = email
        self.username = username
        self.authentication = authentication
    }

    public init(accountID: AccountID, email: EmailAddress, username: String, password: String) {
        self.init(accountID: accountID, email: email, username: username, authentication: .password(password))
    }
}

public enum IMAPSyncSource: String, Codable, Equatable, Sendable {
    case recentImport
    case historicalBackfill
    case incremental
}

public struct IMAPSyncResult: Equatable, Sendable {
    public let syncedMessageCount: Int
    public let newlyDiscoveredMessageCount: Int
    public let source: IMAPSyncSource

    public init(
        syncedMessageCount: Int,
        newlyDiscoveredMessageCount: Int? = nil,
        source: IMAPSyncSource = .recentImport
    ) {
        self.syncedMessageCount = syncedMessageCount
        self.newlyDiscoveredMessageCount = newlyDiscoveredMessageCount ?? syncedMessageCount
        self.source = source
    }
}

public struct IMAPForegroundRefreshDemand: Equatable, Sendable {
    public let revision: Int64
    public let recentMessageLimit: Int

    public init(revision: Int64, recentMessageLimit: Int) {
        self.revision = revision
        self.recentMessageLimit = max(1, min(recentMessageLimit, 10_000))
    }
}

/// Optional leased-job integration, independent of any UI or database type.
/// Capture happens immediately before SEARCH; publish follows all target commits.
public struct IMAPForegroundRefreshCheckpointHooks: Sendable {
    public let capture: @Sendable () throws -> IMAPForegroundRefreshDemand?
    public let publish: @Sendable (IMAPForegroundRefreshDemand, String, Int, [Int], Int) throws -> Void

    public init(
        capture: @escaping @Sendable () throws -> IMAPForegroundRefreshDemand?,
        publish: @escaping @Sendable (IMAPForegroundRefreshDemand, String, Int, [Int], Int) throws -> Void
    ) {
        self.capture = capture
        self.publish = publish
    }
}

public enum IMAPSyncProgress: Equatable, Sendable {
    case connecting
    case discoveringMailboxes
    case discoveringMessages
    case downloading(completed: Int, total: Int)
    case syncingMailbox(path: String, phase: String, completed: Int, total: Int)
}

public struct IMAPSyncOptions: Equatable, Sendable {
    public let mailboxPaths: [String]
    public let recentMessageLimit: Int
    public let downloadCompleteHistory: Bool
    public let batchSize: Int
    public let incrementalOnly: Bool
    public let reconcileRemoteState: Bool
    public let notificationEligible: Bool
    public let notificationConfiguration: NotificationProducerConfiguration?

    public init(
        mailboxPaths: [String] = ["INBOX"],
        recentMessageLimit: Int = 100,
        downloadCompleteHistory: Bool = false,
        batchSize: Int = 50,
        incrementalOnly: Bool = false,
        reconcileRemoteState: Bool = false,
        notificationEligible: Bool = false,
        notificationConfiguration: NotificationProducerConfiguration? = nil
    ) {
        self.mailboxPaths = mailboxPaths
        self.recentMessageLimit = max(1, min(recentMessageLimit, 10_000))
        self.downloadCompleteHistory = downloadCompleteHistory
        self.batchSize = max(1, min(batchSize, 500))
        self.incrementalOnly = incrementalOnly
        self.reconcileRemoteState = reconcileRemoteState
        self.notificationEligible = notificationEligible
        self.notificationConfiguration = notificationConfiguration
    }
}

public enum MailboxGenerationStatus: Equatable, Sendable {
    case initialBaseline
    case unchanged
    case replacedBaseline
}

public protocol MailCache: AnyObject {
    func cacheMailboxes(_ mailboxes: [Mailbox]) throws
    func cacheMessage(_ message: MessageSummary) throws
}

public protocol ThreadMailCache: AnyObject {
    func cacheThread(_ thread: MailThread) throws
}

public protocol MailboxSyncCheckpointCache: AnyObject {
    /// Records the selected mailbox generation and returns true only when a previously
    /// established UIDVALIDITY changed, requiring a notification-suppressed bootstrap.
    func recordMailboxGeneration(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int
    ) throws -> MailboxGenerationStatus
    func markMailboxBaselineComplete(accountID: AccountID, mailboxPath: String, uidValidity: Int) throws
    func cachedUIDs(accountID: AccountID, mailboxPath: String, uidValidity: Int) throws -> Set<Int>
    func newestCachedUID(accountID: AccountID, mailboxPath: String, uidValidity: Int) throws -> Int?
    func recordCachedUID(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        messageID: MessageID
    ) throws
    func recordMailboxSyncProgress(
        accountID: AccountID,
        mailboxPath: String,
        phase: String,
        downloaded: Int,
        estimatedTotal: Int,
        complete: Bool,
        error: String?
    ) throws
}

public struct IncomingMessageAttachmentMetadata: Codable, Equatable, Hashable, Sendable {
    public let filename: String
    public let mimeType: String?

    public init(filename: String, mimeType: String?) {
        self.filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mimeType = MailSearchDocumentClassifier.canonicalMIMEType(mimeType)
    }
}

public struct IncomingMessageAttachmentPayload: Equatable, Sendable {
    public static let maximumPartPathUTF8Length = 512
    public static let maximumFilenameUTF8Length = 255
    public static let maximumMIMETypeUTF8Length = 255
    public static let maximumContentIDUTF8Length = 998
    public static let maximumAttachmentCount = 256
    public static let maximumAttachmentMetadataBytes = 64 * 1_024
    public static let maximumDecodedBytesPerAttachment = 50 * 1_024 * 1_024
    public static let maximumAggregateDecodedBytes = 100 * 1_024 * 1_024

    public let partPath: String
    public let filename: String
    public let mimeType: String?
    public let byteCount: Int
    public let sha256: String
    public let data: Data
    /// The part's Content-ID without angle brackets, which `cid:` URLs in the HTML name.
    public let contentID: String?

    public init(
        partPath: String,
        filename: String,
        mimeType: String?,
        data: Data,
        contentID: String? = nil
    ) {
        self.partPath = partPath
        self.filename = Self.safeDisplayFilename(filename)
        self.mimeType = MailSearchDocumentClassifier.canonicalMIMEType(mimeType)
        self.contentID = contentID
            .map(InlineImageResolver.normalizedContentID)
            .flatMap { $0.isEmpty || $0.utf8.count > Self.maximumContentIDUTF8Length ? nil : $0 }
        byteCount = data.count
        sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        self.data = data
    }

    private static func safeDisplayFilename(_ value: String) -> String {
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
            guard candidate.utf8.count <= 255 else { break }
            result = candidate
        }
        return result.isEmpty ? "Attachment" : result
    }
}

public struct IncomingMessageSearchMetadata: Equatable, Sendable {
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let attachments: [IncomingMessageAttachmentMetadata]
    public let messageIdentifiers: [String]

    public init(
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        attachments: [IncomingMessageAttachmentMetadata],
        messageIdentifiers: [String]
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.attachments = attachments
        self.messageIdentifiers = messageIdentifiers
    }
}

public struct IncomingMessageCommitResult: Equatable, Sendable {
    public let messageID: MessageID
    public let insertedMembership: Bool
    public let insertedCanonicalMessage: Bool

    public init(messageID: MessageID, insertedMembership: Bool, insertedCanonicalMessage: Bool = true) {
        self.messageID = messageID
        self.insertedMembership = insertedMembership
        self.insertedCanonicalMessage = insertedCanonicalMessage
    }
}

public protocol AtomicIncomingMessageCache: AnyObject {
    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfigVersion: String,
        notificationProducerGeneration: Int64
    ) throws -> IncomingMessageCommitResult

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfiguration: NotificationProducerConfiguration
    ) throws -> IncomingMessageCommitResult
}

public extension AtomicIncomingMessageCache {
    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfiguration: NotificationProducerConfiguration
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message, metadata: metadata, accountID: accountID, mailboxPath: mailboxPath,
            uidValidity: uidValidity, uid: uid,
            notificationDisposition: notificationDisposition,
            notificationConfigVersion: notificationConfiguration.configVersion,
            notificationProducerGeneration: notificationConfiguration.producerGeneration
        )
    }
}

public extension AtomicIncomingMessageCache {
    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfigVersion: String = "default",
        notificationProducerGeneration: Int64 = 0
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message, metadata: metadata, accountID: accountID,
            mailboxPath: mailboxPath, uidValidity: uidValidity, uid: uid,
            notificationEligible: notificationDisposition.isEligible
        )
    }
}

public protocol AtomicIncomingAttachmentCache: AtomicIncomingMessageCache {
    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfigVersion: String,
        notificationProducerGeneration: Int64
    ) throws -> IncomingMessageCommitResult

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfiguration: NotificationProducerConfiguration
    ) throws -> IncomingMessageCommitResult
}

public extension AtomicIncomingAttachmentCache {
    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message,
            metadata: metadata,
            attachments: [],
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid,
            notificationEligible: notificationEligible
        )
    }

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfigVersion: String = "default",
        notificationProducerGeneration: Int64 = 0
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message,
            metadata: metadata,
            attachments: attachments,
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid,
            notificationEligible: notificationDisposition.isEligible
        )
    }

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfiguration: NotificationProducerConfiguration
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message, metadata: metadata, attachments: attachments,
            accountID: accountID, mailboxPath: mailboxPath, uidValidity: uidValidity, uid: uid,
            notificationDisposition: notificationDisposition,
            notificationConfigVersion: notificationConfiguration.configVersion,
            notificationProducerGeneration: notificationConfiguration.producerGeneration
        )
    }

}

/// Mail cached while the Date header parser mistook a folded DKIM `h=Date:…`
/// continuation for the field has no sent date, so it sorts below everything.
public protocol MissingSentDateRepairCache: AnyObject {
    /// Cached UIDs in this mailbox generation whose message has no sent date, newest first.
    func cachedUIDsMissingSentDate(
        accountID: AccountID, mailboxPath: String, uidValidity: Int, limit: Int
    ) throws -> [(uid: Int, messageID: MessageID)]
    /// Sets the sent date of a message that still has none.
    func repairMissingSentDate(_ date: Date, messageID: MessageID) throws
}

/// Mail cached while the header parser could not see the first field of a
/// fetched header literal. A From read that way swallowed the following lines,
/// so its name holds a line break and its address is often a recipient's.
public protocol MisreadSenderRepairCache: AnyObject {
    /// Cached UIDs in this mailbox generation whose sender name holds a line break, newest first.
    func cachedUIDsWithMisreadSender(
        accountID: AccountID, mailboxPath: String, uidValidity: Int, limit: Int
    ) throws -> [(uid: Int, messageID: MessageID)]
    /// Replaces the sender and recipients of a message whose sender is still misread.
    func repairMisreadSender(
        messageID: MessageID, from: EmailAddress, displayName: String?,
        replyTo: EmailAddress?, to: [EmailAddress], cc: [EmailAddress]
    ) throws
}

public protocol MailboxStateReconciliationCache: AnyObject {
    func reconcileMailboxState(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        states: [IMAPRemoteMessageState]
    ) throws
}

public final class IMAPSyncService {
    private let client: IMAPClientProtocol
    private let cache: MailCache
    private let classifier: SmartCategoryClassifier

    public init(client: IMAPClientProtocol, cache: MailCache, classifier: SmartCategoryClassifier = SmartCategoryClassifier()) {
        self.client = client
        self.cache = cache
        self.classifier = classifier
    }

    public func syncInbox(
        credentials: IMAPAccountCredentials,
        options: IMAPSyncOptions = IMAPSyncOptions(),
        foregroundCheckpoint: IMAPForegroundRefreshCheckpointHooks? = nil,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void = { _ in }
    ) async throws -> IMAPSyncResult {
        await progress(.connecting)
        try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
        await progress(.discoveringMailboxes)
        let mailboxes = try await client.listMailboxes()
            .map { mailbox in
                Mailbox(
                    id: MailboxID("mbx_\(credentials.accountID.rawValue)_\(stableMailboxPathID(mailbox.path))"),
                    accountID: credentials.accountID,
                    name: mailbox.name,
                    path: mailbox.path,
                    specialUse: mailbox.specialUse
                )
            }
        try cache.cacheMailboxes(mailboxes)
        await progress(.discoveringMessages)
        var syncedCount = 0
        var newlyDiscoveredCount = 0
        let clock = ContinuousClock()
        var lastFreshnessCheck = clock.now
        var historySinceFreshnessCheck = 0
        var inboxImport: MailboxImportState?
        var imports: [MailboxImportState] = []
        var historyDiscoveryClosed = false
        let phase = options.downloadCompleteHistory ? "backfill" : "recent-import"

        func report(_ state: MailboxImportState) async throws {
            try (cache as? MailboxSyncCheckpointCache)?.recordMailboxSyncProgress(
                accountID: credentials.accountID, mailboxPath: state.context.path, phase: phase,
                downloaded: state.initialCachedCount + state.completed,
                estimatedTotal: state.candidates.count,
                complete: state.processed.isSuperset(of: state.candidates), error: nil
            )
            await progress(.syncingMailbox(
                path: state.context.path, phase: phase, completed: state.completed,
                total: state.candidates.count - state.initialCachedCount
            ))
        }

        func download(_ uid: Int, into state: MailboxImportState) async throws {
            guard !state.processed.contains(uid) else { return }
            // Keep the original canonical/attachment/membership atomic commit path.
            let inserted = try await downloadMessage(
                uid: uid, credentials: credentials, options: options, context: state.context
            )
            state.processed.insert(uid)
            state.freshPending.remove(uid)
            state.completed += 1
            if let inserted {
                syncedCount += 1
                if inserted { newlyDiscoveredCount += 1 }
            }
            try await report(state)
        }

        func selectCaptured(_ state: MailboxImportState) async throws {
            let selection = try await client.selectMailbox(state.context.path)
            let validity = Self.uidValidity(from: selection)
            if cache is MailboxSyncCheckpointCache, validity == nil {
                throw IMAPClientError.protocolError("Selected mailbox did not provide UIDVALIDITY.")
            }
            guard (validity ?? 0) == state.context.uidValidity else {
                // The captured UID queue belongs to another namespace. Retry
                // rediscovers it; never apply those UIDs to the new generation.
                throw IMAPClientError.protocolError("Mailbox UIDVALIDITY changed during history import.")
            }
        }

        func checkInboxFreshness(restoring state: MailboxImportState) async throws {
            guard let inboxImport else { return }
            try await selectCaptured(inboxImport)
            let discovered = try await client.messageUIDs(after: inboxImport.discoveredHighWater)
            for uid in discovered.sorted() where !inboxImport.candidates.contains(uid) {
                inboxImport.candidates.insert(uid)
                inboxImport.pending.append(uid)
                inboxImport.freshPending.insert(uid)
            }
            if let highest = discovered.max() {
                inboxImport.discoveredHighWater = max(inboxImport.discoveredHighWater ?? highest, highest)
            }
            // One finite window per boundary, followed by history progress.
            // The remaining arrivals stay in pending, independent of cache MAX.
            let window = inboxImport.freshPending.sorted(by: >).prefix(min(options.batchSize, 50))
            for uid in window { try await download(uid, into: inboxImport) }
            if state !== inboxImport { try await selectCaptured(state) }
            lastFreshnessCheck = clock.now
            historySinceFreshnessCheck = 0
        }

        func fulfillForeground(
            _ demand: IMAPForegroundRefreshDemand,
            discovered: [Int], in state: MailboxImportState
        ) async throws {
            let targets = Array(Set(discovered)).sorted().suffix(demand.recentMessageLimit)
            let candidates = options.downloadCompleteHistory && !historyDiscoveryClosed ? discovered : Array(targets)
            for uid in candidates.sorted() where !state.candidates.contains(uid) {
                state.candidates.insert(uid)
                state.pending.append(uid)
            }
            let newlyDiscoveredBefore = newlyDiscoveredCount
            for uid in targets.reversed() { try await download(uid, into: state) }
            // Verify the namespace again after awaits, before acknowledging.
            try await selectCaptured(state)
            try foregroundCheckpoint?.publish(
                demand, state.context.path, state.context.uidValidity, Array(targets),
                newlyDiscoveredCount - newlyDiscoveredBefore
            )
        }

        func checkForeground(restoring state: MailboxImportState) async throws {
            guard let foregroundCheckpoint, let inboxImport,
                  try foregroundCheckpoint.capture() != nil else { return }
            try await selectCaptured(inboxImport)
            // Capture again after SELECT, immediately before this full SEARCH.
            guard let demand = try foregroundCheckpoint.capture() else { return }
            let discovered = try await client.allMessageUIDs()
            try await fulfillForeground(demand, discovered: discovered, in: inboxImport)
            if state !== inboxImport { try await selectCaptured(state) }
        }

        func repairMissingSentDates(_ state: MailboxImportState) async throws {
            guard let repairCache = cache as? MissingSentDateRepairCache else { return }
            let missing = try repairCache.cachedUIDsMissingSentDate(
                accountID: credentials.accountID, mailboxPath: state.context.path,
                uidValidity: state.context.uidValidity, limit: Self.missingSentDateRepairLimit
            )
            // Best effort: the first failure ends this pass's repair, and the next pass resumes it.
            do {
                for (uid, messageID) in missing {
                    let header = try await client.fetchHeader(uid: uid)
                    let headerDate = IMAPMessageParser.parse(header: header, bodyData: Data()).sentAt
                    let date = if let headerDate { headerDate } else { try await client.fetchInternalDate(uid: uid) }
                    guard let date else { continue }
                    try repairCache.repairMissingSentDate(date, messageID: messageID)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }

        func repairMisreadSenders(_ state: MailboxImportState) async throws {
            guard let repairCache = cache as? MisreadSenderRepairCache else { return }
            let misread = try repairCache.cachedUIDsWithMisreadSender(
                accountID: credentials.accountID, mailboxPath: state.context.path,
                uidValidity: state.context.uidValidity, limit: Self.misreadSenderRepairLimit
            )
            // Best effort, like the sent-date repair: the next pass resumes it.
            do {
                for (uid, messageID) in misread {
                    let header = try await client.fetchHeader(uid: uid)
                    let parsed = try IMAPMessageParser.parseForSync(header: header, bodyData: Data())
                    guard parsed.from.rawValue != "unknown@example.invalid",
                          parsed.fromDisplayName?.contains(where: \.isNewline) != true else { continue }
                    try repairCache.repairMisreadSender(
                        messageID: messageID, from: parsed.from, displayName: parsed.fromDisplayName,
                        replyTo: parsed.replyTo, to: parsed.to, cc: parsed.cc
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }

        func finishMailbox(_ state: MailboxImportState) async throws {
            if options.reconcileRemoteState, let states = try await client.messageStates() {
                try (cache as? MailboxStateReconciliationCache)?.reconcileMailboxState(
                    accountID: credentials.accountID, mailboxPath: state.context.path,
                    uidValidity: state.context.uidValidity, states: states
                )
            }
            try await repairMissingSentDates(state)
            try await repairMisreadSenders(state)
            try (cache as? MailboxSyncCheckpointCache)?.markMailboxBaselineComplete(
                accountID: credentials.accountID, mailboxPath: state.context.path,
                uidValidity: state.context.uidValidity
            )
        }

        let paths: [String]
        if options.downloadCompleteHistory,
           let inbox = options.mailboxPaths.first(where: { $0.caseInsensitiveCompare("INBOX") == .orderedSame }) {
            paths = [inbox] + options.mailboxPaths.filter { $0 != inbox }
        } else {
            paths = options.mailboxPaths
        }
        for mailboxPath in paths {
            let selection = try await client.selectMailbox(mailboxPath)
            let parsedUIDValidity = Self.uidValidity(from: selection)
            if cache is MailboxSyncCheckpointCache, parsedUIDValidity == nil {
                throw IMAPClientError.protocolError("Selected mailbox did not provide UIDVALIDITY.")
            }
            let uidValidity = parsedUIDValidity ?? 0
            let generationStatus = try (cache as? MailboxSyncCheckpointCache)?.recordMailboxGeneration(
                accountID: credentials.accountID, mailboxPath: mailboxPath, uidValidity: uidValidity
            ) ?? .unchanged
            let newestCachedUID = try (cache as? MailboxSyncCheckpointCache)?.newestCachedUID(
                accountID: credentials.accountID, mailboxPath: mailboxPath, uidValidity: uidValidity
            )
            let initialForeground = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
                ? try foregroundCheckpoint?.capture() : nil
            let discoveredUIDs = options.incrementalOnly && initialForeground == nil
                ? try await client.messageUIDs(after: newestCachedUID)
                : try await client.allMessageUIDs()
            let allUIDs = options.downloadCompleteHistory
                ? Array(Set(discoveredUIDs)).sorted() : discoveredUIDs
            let candidateUIDs = options.downloadCompleteHistory
                ? allUIDs : Array(allUIDs.suffix(max(options.recentMessageLimit, initialForeground?.recentMessageLimit ?? 0)))
            let cachedUIDs = try (cache as? MailboxSyncCheckpointCache)?.cachedUIDs(
                accountID: credentials.accountID, mailboxPath: mailboxPath, uidValidity: uidValidity
            ) ?? []
            let state = MailboxImportState(
                context: .init(path: mailboxPath, uidValidity: uidValidity, generation: generationStatus),
                candidates: candidateUIDs, cached: cachedUIDs
            )
            syncedCount += state.initialCachedCount
            if mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame {
                // Keep every old gap even after a newest-first commit raises
                // newestCachedUID. That value is not a contiguous history cursor.
                if options.downloadCompleteHistory {
                    let recent = Set(candidateUIDs.suffix(options.recentMessageLimit))
                    state.pending = state.pending.filter { recent.contains($0) }.sorted(by: >)
                        + state.pending.filter { !recent.contains($0) }
                }
                inboxImport = state
            }
            imports.append(state)
            try await report(state)
            if let initialForeground {
                try await fulfillForeground(initialForeground, discovered: discoveredUIDs, in: state)
            }
            // Probe arrivals append to pending, but they cannot extend this
            // original history phase. A final discovery snapshot drains later.
            let originalHistoryEnd = state.pending.count
            while state.nextIndex < originalHistoryEnd {
                let uid = state.pending[state.nextIndex]
                state.nextIndex += 1
                guard !state.processed.contains(uid) else { continue }
                try await download(uid, into: state)
                // Foreground demand is serviced at each completed message
                // boundary, independently of the background 50/5s cadence.
                // One window per boundary keeps historical gaps progressing.
                try await checkForeground(restoring: state)
                historySinceFreshnessCheck += 1
                if options.downloadCompleteHistory,
                   historySinceFreshnessCheck >= options.batchSize
                    || lastFreshnessCheck.duration(to: clock.now) >= .seconds(5) {
                    try await checkInboxFreshness(restoring: state)
                }
                if state.completed.isMultiple(of: options.batchSize) { await Task.yield() }
            }
            if !options.downloadCompleteHistory {
                try await checkForeground(restoring: state)
                try await finishMailbox(state)
            }
        }
        if options.downloadCompleteHistory, let last = imports.last {
            try await checkForeground(restoring: last)
            // Also inspect arrivals during a final short non-INBOX batch.
            try await checkInboxFreshness(restoring: last)
            if let inboxImport {
                try await selectCaptured(inboxImport)
                // Discovery is now closed for this pass. Fetch every pending
                // UID in that finite snapshot; later arrivals belong to the next pass.
                let finalPendingEnd = inboxImport.pending.count
                historyDiscoveryClosed = true
                while inboxImport.nextIndex < finalPendingEnd {
                    let uid = inboxImport.pending[inboxImport.nextIndex]
                    inboxImport.nextIndex += 1
                    guard !inboxImport.processed.contains(uid) else { continue }
                    try await download(uid, into: inboxImport)
                    try await checkForeground(restoring: inboxImport)
                    if inboxImport.completed.isMultiple(of: options.batchSize) { await Task.yield() }
                }
            }
            // Baseline completion/reconciliation follows actual completion of
            // all discovered candidates, including deferred probe arrivals.
            for state in imports {
                try await selectCaptured(state)
                try await finishMailbox(state)
            }
        }
        let source: IMAPSyncSource = options.incrementalOnly
            ? .incremental
            : (options.downloadCompleteHistory ? .historicalBackfill : .recentImport)
        return IMAPSyncResult(
            syncedMessageCount: syncedCount,
            newlyDiscoveredMessageCount: newlyDiscoveredCount,
            source: source
        )
    }

    /// Bounds the extra header fetches one pass spends on old undated mail.
    static let missingSentDateRepairLimit = 200
    static let misreadSenderRepairLimit = 200

    private struct MailboxImportContext {
        let path: String
        let uidValidity: Int
        let generation: MailboxGenerationStatus
    }

    /// State owned by one sync invocation; no task or worker shares it.
    private final class MailboxImportState {
        let context: MailboxImportContext
        var candidates: Set<Int>
        var processed: Set<Int>
        var pending: [Int]
        var freshPending: Set<Int> = []
        var discoveredHighWater: Int?
        let initialCachedCount: Int
        var completed = 0
        var nextIndex = 0

        init(context: MailboxImportContext, candidates: [Int], cached: Set<Int>) {
            self.context = context
            self.candidates = Set(candidates)
            self.processed = cached
            self.pending = candidates.filter { !cached.contains($0) }
            self.discoveredHighWater = candidates.max()
            self.initialCachedCount = candidates.filter { cached.contains($0) }.count
        }
    }

    private func downloadMessage(
        uid: Int, credentials: IMAPAccountCredentials, options: IMAPSyncOptions,
        context: MailboxImportContext
    ) async throws -> Bool? {
        let mailboxPath = context.path
        let uidValidity = context.uidValidity
        let generationStatus = context.generation
        var newlyDiscovered = false
        let header = try await client.fetchHeader(uid: uid)
        let body = try await client.fetchBodyData(uid: uid)
        let attachmentSource = IMAPMessageParser.mimeSource(from: body)
        let parsed = try IMAPMessageParser.parseForSync(header: header, bodyData: body)
        if let verificationBody = MIMEMessageDecoder.exactPlainText(from: body),
           AccountVerificationMessage.recognizes(
            header: header,
            body: verificationBody,
            accountEmail: credentials.email
        ) {
            try? await client.delete(uid: uid)
            return nil
        }
        // Without a usable Date header, the server's arrival time keeps the message in order.
        let sentAt = if let sentAt = parsed.sentAt { sentAt } else { try await client.fetchInternalDate(uid: uid) }
        let threadID = MailThreading.threadID(
            accountID: credentials.accountID,
            messageID: parsed.messageID,
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            subject: parsed.subject,
            sender: parsed.from
        )
        let category = classifier.classify(
            CategoryInput(
                from: parsed.from.rawValue,
                subject: parsed.subject,
                headers: [:],
                bodyPreview: parsed.preview
            )
        )
        let messageID = MessageID(parsed.messageID.map {
            Self.canonicalMessageID(accountID: credentials.accountID, rfcMessageID: $0)
        } ?? Self.localMessageID(
            accountID: credentials.accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid
        ))
        let message = MessageSummary(
            id: messageID,
            threadID: threadID,
            from: parsed.from,
            fromDisplayName: parsed.fromDisplayName,
            subject: parsed.subject,
            preview: parsed.preview,
            smartCategory: category.category,
            labels: [],
            isSeen: false,
            mailboxPath: mailboxPath,
            isDeleted: false,
            body: parsed.body,
            bodyHTML: parsed.bodyHTML,
            sentAt: sentAt,
            rfcMessageID: parsed.messageID,
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            replyTo: parsed.replyTo,
            to: parsed.to,
            cc: parsed.cc
        )
        if let threadCache = cache as? ThreadMailCache {
            let participants = [parsed.from, parsed.replyTo].compactMap { $0 } + parsed.to + parsed.cc
            try threadCache.cacheThread(MailThread(
                id: threadID,
                accountID: credentials.accountID,
                subjectNormalized: MailThreading.normalizedSubject(parsed.subject),
                participantEmails: participants
            ))
        }
        let metadata = IncomingMessageSearchMetadata(
            to: parsed.to,
            cc: parsed.cc,
            bcc: parsed.bcc,
            attachments: parsed.attachments,
            messageIdentifiers: [parsed.messageID, parsed.inReplyTo].compactMap { $0 } + parsed.references
        )
        if let attachmentCache = cache as? AtomicIncomingAttachmentCache {
            let attachments = try MIMEMessageDecoder.decodedAttachments(from: attachmentSource)
            let commit = try attachmentCache.commitIncomingMessage(
                message,
                metadata: metadata,
                attachments: attachments,
                accountID: credentials.accountID,
                mailboxPath: mailboxPath,
                uidValidity: uidValidity,
                uid: uid,
                notificationDisposition: IncomingNotificationDisposition.forSync(
                    mailboxPath: mailboxPath,
                    source: options.incrementalOnly ? .incremental :
                        (options.downloadCompleteHistory ? .historicalBackfill : .recentImport),
                    generation: generationStatus,
                    providerArrivalAt: try await client.fetchInternalDate(uid: uid)
                ),
                notificationConfiguration: options.notificationConfiguration ?? NotificationProducerConfiguration(
                    logicalMailboxID: ""
                )
            )
            if commit.insertedCanonicalMessage,
               mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame,
               generationStatus == .unchanged {
                newlyDiscovered = true
            }
        } else if let atomicCache = cache as? AtomicIncomingMessageCache {
            let commit = try atomicCache.commitIncomingMessage(
                message,
                metadata: metadata,
                accountID: credentials.accountID,
                mailboxPath: mailboxPath,
                uidValidity: uidValidity,
                uid: uid,
                notificationDisposition: IncomingNotificationDisposition.forSync(
                    mailboxPath: mailboxPath,
                    source: options.incrementalOnly ? .incremental :
                        (options.downloadCompleteHistory ? .historicalBackfill : .recentImport),
                    generation: generationStatus,
                    providerArrivalAt: try await client.fetchInternalDate(uid: uid)
                ),
                notificationConfiguration: options.notificationConfiguration ?? NotificationProducerConfiguration(
                    logicalMailboxID: ""
                )
            )
            if commit.insertedCanonicalMessage,
               mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame,
               generationStatus == .unchanged {
                newlyDiscovered = true
            }
        } else {
            try cache.cacheMessage(message)
            try (cache as? MailboxSyncCheckpointCache)?.recordCachedUID(
                accountID: credentials.accountID,
                mailboxPath: mailboxPath,
                uidValidity: uidValidity,
                uid: uid,
                messageID: messageID
            )
            if mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame,
               generationStatus == .unchanged { newlyDiscovered = true }
        }
        return newlyDiscovered
    }

    public static func localMessageID(accountID: AccountID, mailboxPath: String, uidValidity: Int, uid: Int) -> String {
        "msg_\(stableID(accountID.rawValue))_\(stableID(mailboxPath))_\(uidValidity)_\(uid)"
    }

    public static func canonicalMessageID(accountID: AccountID, rfcMessageID: String) -> String {
        let normalized = rfcMessageID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data("\(accountID.rawValue)\u{1f}\(normalized)".utf8))
        return "msg_rfc_\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    package static func uidValidity(from selection: String) -> Int? {
        let expression = try? NSRegularExpression(pattern: #"UIDVALIDITY\s+(\d+)"#, options: .caseInsensitive)
        let range = NSRange(selection.startIndex..., in: selection)
        guard let match = expression?.firstMatch(in: selection, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: selection) else { return nil }
        return Int(selection[valueRange])
    }

    private static func stableID(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private func stableMailboxPathID(_ path: String) -> String {
        let normalized = path
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        return String(normalized)
    }
}

enum IMAPMessageParser {
    static func parse(header: String, bodyData: Data) -> ParsedIMAPMessage {
        parsedMessage(header: header, content: decodedBodyContent(from: bodyData))
    }

    static func parseForSync(header: String, bodyData: Data) throws -> ParsedIMAPMessage {
        let body = mimeSource(from: bodyData)
        let content = decodedBodyContent(
            from: body,
            attachmentMetadata: try MIMEMessageDecoder.attachmentMetadata(from: body)
        )
        return try parsedMessageForSync(header: header, content: content)
    }

    static func mimeSource(from body: Data) -> Data {
        guard body.starts(with: Data("* ".utf8)) else { return body }
        return Data(removingIMAPFraming(from: String(decoding: body, as: UTF8.self)).utf8)
    }

    static func parse(header: String, body: String) -> ParsedIMAPMessage {
        parsedMessage(header: header, content: decodedBodyContent(from: body))
    }

    private static func parsedMessage(header: String, content: ParsedBodyContent) -> ParsedIMAPMessage {
        let fromHeader = headerValue(named: "From", in: header) ?? inlineValue(after: "From:", in: header)
        let references = messageIDs(in: headerValue(named: "References", in: header))
        return ParsedIMAPMessage(
            from: EmailAddress(emailAddress(from: fromHeader) ?? "unknown@example.invalid"),
            fromDisplayName: displayName(from: fromHeader),
            replyTo: addresses(in: headerValue(named: "Reply-To", in: header)).first,
            messageID: firstMessageID(in: headerValue(named: "Message-ID", in: header)),
            inReplyTo: firstMessageID(in: headerValue(named: "In-Reply-To", in: header)),
            references: references,
            to: addresses(in: headerValue(named: "To", in: header)),
            cc: addresses(in: headerValue(named: "Cc", in: header)),
            bcc: addresses(in: headerValue(named: "Bcc", in: header)),
            subject: MIMEMessageDecoder.decodeHeader(
                headerValue(named: "Subject", in: header) ?? inlineValue(after: "Subject:", in: header) ?? "(No subject)"
            ),
            sentAt: messageDate(
                from: headerValue(named: "Date", in: header) ?? inlineValue(after: "Date:", in: header)
            ),
            preview: concisePreview(content.text),
            body: content.text,
            bodyHTML: content.html,
            attachments: content.attachments,
            attachmentPayloads: content.attachmentPayloads
        )
    }

    // Synchronization must share the canonical provider representation used by
    // the MIME corpus. The legacy display parser below remains permissive for
    // locally stored historical bodies; it is not the provider ingress path.
    private static func parsedMessageForSync(header: String, content: ParsedBodyContent) throws -> ParsedIMAPMessage {
        let fromHeader = headerValue(named: "From", in: header) ?? inlineValue(after: "From:", in: header)
        let from = try MIMEHeaderCanonicalizer.addresses(fromHeader).first
        let replyTo = try MIMEHeaderCanonicalizer.addresses(headerValue(named: "Reply-To", in: header)).first
        let to = try MIMEHeaderCanonicalizer.addresses(headerValue(named: "To", in: header))
        let cc = try MIMEHeaderCanonicalizer.addresses(headerValue(named: "Cc", in: header))
        let bcc = try MIMEHeaderCanonicalizer.addresses(headerValue(named: "Bcc", in: header))
        let messageID = try MIMEHeaderCanonicalizer.messageIDs(headerValue(named: "Message-ID", in: header)).first
        let inReplyTo = try MIMEHeaderCanonicalizer.messageIDs(headerValue(named: "In-Reply-To", in: header)).first
        let references = try MIMEHeaderCanonicalizer.messageIDs(headerValue(named: "References", in: header))
        let displayName = from?.displayName

        return ParsedIMAPMessage(
            from: EmailAddress(from?.mailbox ?? "unknown@example.invalid"),
            fromDisplayName: displayName?.isEmpty == true ? nil : displayName,
            replyTo: replyTo.map { EmailAddress($0.mailbox) },
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            to: to.map { EmailAddress($0.mailbox) },
            cc: cc.map { EmailAddress($0.mailbox) },
            bcc: bcc.map { EmailAddress($0.mailbox) },
            subject: MIMEHeaderCanonicalizer.text(
                MIMEMessageDecoder.decodeHeader(
                    headerValue(named: "Subject", in: header) ?? inlineValue(after: "Subject:", in: header) ?? "(No subject)"
                )
            ),
            sentAt: messageDate(
                from: headerValue(named: "Date", in: header) ?? inlineValue(after: "Date:", in: header)
            ),
            preview: concisePreview(content.text),
            body: content.text,
            bodyHTML: content.html,
            attachments: content.attachments,
            attachmentPayloads: content.attachmentPayloads
        )
    }

    private static func decodedBodyContent(from body: Data) -> ParsedBodyContent {
        if body.starts(with: Data("* ".utf8)) {
            return decodedBodyContent(from: String(decoding: body, as: UTF8.self))
        }
        let attachmentPayloads = nonSyncAttachmentPayloads(from: body)
        return decodedBodyContent(from: body, attachmentPayloads: attachmentPayloads)
    }

    private static func decodedBodyContent(
        from body: Data,
        attachmentPayloads: [IncomingMessageAttachmentPayload]
    ) -> ParsedBodyContent {
        let attachments = attachmentPayloads.map {
            IncomingMessageAttachmentMetadata(filename: $0.filename, mimeType: $0.mimeType)
        }
        return decodedBodyContent(
            from: body,
            attachmentMetadata: attachments,
            attachmentPayloads: attachmentPayloads
        )
    }

    private static func decodedBodyContent(
        from body: Data,
        attachmentMetadata: [IncomingMessageAttachmentMetadata]
    ) -> ParsedBodyContent {
        decodedBodyContent(from: body, attachmentMetadata: attachmentMetadata, attachmentPayloads: [])
    }

    private static func decodedBodyContent(
        from body: Data,
        attachmentMetadata: [IncomingMessageAttachmentMetadata],
        attachmentPayloads: [IncomingMessageAttachmentPayload]
    ) -> ParsedBodyContent {
        if let decoded = MIMEMessageDecoder.syncContent(from: body) {
            return ParsedBodyContent(
                text: decoded.safeText.trimmingCharacters(in: .whitespacesAndNewlines),
                html: decoded.safeHTML,
                raw: String(decoding: body, as: UTF8.self),
                attachments: attachmentMetadata,
                attachmentPayloads: attachmentPayloads
            )
        }
        let text = (
            String(data: body, encoding: .utf8)
                ?? String(data: body, encoding: .isoLatin1)
                ?? String(decoding: body, as: UTF8.self)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedBodyContent(
            text: text,
            html: nil,
            raw: text,
            attachments: attachmentMetadata,
            attachmentPayloads: attachmentPayloads
        )
    }

    private static func decodedBodyContent(from body: String) -> ParsedBodyContent {
        let message = removingIMAPFraming(from: body)
        let messageData = Data(message.utf8)
        let attachmentPayloads = nonSyncAttachmentPayloads(from: messageData)
        return decodedBodyContent(from: message, attachmentPayloads: attachmentPayloads)
    }

    private static func nonSyncAttachmentPayloads(
        from body: Data
    ) -> [IncomingMessageAttachmentPayload] {
        do {
            return try MIMEMessageDecoder.decodedAttachments(from: body)
        } catch {
            return []
        }
    }

    private static func decodedBodyContent(
        from body: String,
        attachmentPayloads: [IncomingMessageAttachmentPayload]
    ) -> ParsedBodyContent {
        let message = removingIMAPFraming(from: body)
        let messageData = Data(message.utf8)
        let attachments = attachmentPayloads.map {
            IncomingMessageAttachmentMetadata(filename: $0.filename, mimeType: $0.mimeType)
        }
        if let decoded = MIMEMessageDecoder.displayContent(from: messageData) {
            return ParsedBodyContent(
                text: decoded.safeText.trimmingCharacters(in: .whitespacesAndNewlines),
                html: decoded.safeHTML,
                raw: message,
                attachments: attachments,
                attachmentPayloads: attachmentPayloads
            )
        }
        if let separator = message.range(of: "\n\n") {
            return ParsedBodyContent(
                text: String(message[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines),
                html: nil,
                raw: message,
                attachments: attachments,
                attachmentPayloads: attachmentPayloads
            )
        }
        if let value = headerValue(named: "Body", in: message) {
            return ParsedBodyContent(
                text: value,
                html: nil,
                raw: message,
                attachments: attachments,
                attachmentPayloads: attachmentPayloads
            )
        }
        if let value = inlineValue(after: "Body:", in: message) {
            return ParsedBodyContent(
                text: value,
                html: nil,
                raw: message,
                attachments: attachments,
                attachmentPayloads: attachmentPayloads
            )
        }
        return ParsedBodyContent(
            text: message.trimmingCharacters(in: .whitespacesAndNewlines),
            html: nil,
            raw: message,
            attachments: attachments,
            attachmentPayloads: attachmentPayloads
        )
    }

    private static func addresses(in value: String?) -> [EmailAddress] {
        guard let value else { return [] }
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { EmailAddress(String(value[$0])) }
        }
    }

    private static func concisePreview(_ text: String) -> String {
        MailPreviewNormalizer.normalized(text)
    }

    private static func headerValue(named name: String, in text: String) -> String? {
        let normalized = headerLiteral(in: text).replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let prefix = "\(name.lowercased()):"
        var values: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if values.isEmpty {
                // A folded continuation (leading space or tab) never starts a field,
                // even when it reads `Date:From:…` inside a DKIM `h=` tag.
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                      trimmed.lowercased().hasPrefix(prefix) else {
                    continue
                }
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

    /// `IMAPClient` splices the header literal in right after
    /// `* n FETCH (… BODY[HEADER.FIELDS (…)] `, so the first field shares that
    /// line. Start at the literal so the first field begins a line of its own.
    private static func headerLiteral(in text: String) -> String {
        guard text.hasPrefix("* "),
              let section = text.range(of: "BODY[HEADER", options: .caseInsensitive),
              let close = text[section.upperBound...].range(of: "] ") else {
            return text
        }
        return String(text[close.upperBound...])
    }

    private static func emailAddress(from value: String?) -> String? {
        guard let value else {
            return nil
        }
        if let start = value.lastIndex(of: "<"),
           let end = value[value.index(after: start)...].firstIndex(of: ">") {
            return String(value[value.index(after: start)..<end])
        }
        return value
    }

    private static func displayName(from value: String?) -> String? {
        guard let value else {
            return nil
        }

        let decoded = MIMEMessageDecoder.decodeHeader(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let angleBracket = decoded.lastIndex(of: "<") else {
            return nil
        }

        let candidate = decoded[..<angleBracket]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !candidate.isEmpty, !candidate.contains("@") else {
            return nil
        }
        return candidate
    }

    private static func firstMessageID(in value: String?) -> String? {
        messageIDs(in: value).first
    }

    private static func messageIDs(in value: String?) -> [String] {
        guard let value else { return [] }
        let pattern = #"<[^<>\s]+>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]).lowercased() }
        }
    }

    private static func inlineValue(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker, options: .caseInsensitive) else {
            return nil
        }
        let remainder = text[range.upperBound...]
        let end = ["\n", " Subject:", " Date:", " Body:", "\")", "\" RFC822"]
            .compactMap { remainder.range(of: $0, options: .caseInsensitive)?.lowerBound }
            .min()
            ?? remainder.endIndex
        let value = String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        return value.isEmpty ? nil : value
    }

    private static func messageDate(from value: String?) -> Date? {
        guard let value else {
            return nil
        }

        let normalized = value
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy",
            "yyyy-MM-dd"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }

    private static func removingIMAPFraming(from body: String) -> String {
        var lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if lines.count > 1,
           lines.first?.hasPrefix("*") == true,
           lines.first?.localizedCaseInsensitiveContains("FETCH") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == ")" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

public enum IncomingMessageHeaderIdentity {
    public static func strictCanonicalMessageID(from header: String) -> String? {
        let lines = header
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var values: [String] = []
        var currentValueIndex: Int?

        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let currentValueIndex {
                    let continuation = line.trimmingCharacters(in: .whitespaces)
                    values[currentValueIndex].append(" \(continuation)")
                }
                continue
            }

            currentValueIndex = nil
            guard let separator = line.firstIndex(of: ":"),
                  line[..<separator].caseInsensitiveCompare("Message-ID") == .orderedSame else {
                continue
            }
            values.append(
                String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
            )
            currentValueIndex = values.index(before: values.endIndex)
        }

        guard values.count == 1 else {
            return nil
        }
        let value = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression = try? NSRegularExpression(
            pattern: #"^<[^<>\s@]+@[^<>\s@]+>$"#
        ),
            expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ) != nil else {
            return nil
        }
        return value
    }
}

struct ParsedIMAPMessage: Equatable, Sendable {
    let from: EmailAddress
    let fromDisplayName: String?
    let replyTo: EmailAddress?
    let messageID: String?
    let inReplyTo: String?
    let references: [String]
    let to: [EmailAddress]
    let cc: [EmailAddress]
    let bcc: [EmailAddress]
    let subject: String
    let sentAt: Date?
    let preview: String
    let body: String
    let bodyHTML: String?
    let attachments: [IncomingMessageAttachmentMetadata]
    let attachmentPayloads: [IncomingMessageAttachmentPayload]
}

private struct ParsedBodyContent {
    let text: String
    let html: String?
    let raw: String
    let attachments: [IncomingMessageAttachmentMetadata]
    let attachmentPayloads: [IncomingMessageAttachmentPayload]
}
