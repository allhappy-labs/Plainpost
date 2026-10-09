import Combine
import Foundation
import PlainpostCore
import PlainpostDB

public enum PlainpostComposerWindowRequest: Codable, Hashable, Sendable {
    case newMessage
    case reply(sourceMessageID: String)
    case replyAll(sourceMessageID: String)
    case forward(sourceMessageID: String)
    case aiReply(sourceMessageID: String, bodyMarkdown: String, recipient: String)
    case restore(ComposerRestoreSnapshot)
}

public enum ComposerPresentationPolicy: Equatable, Sendable {
    case embedded
    case runtimeWindow
    case snapshotWindow

    public func windowRequest(
        runtimeRequest: PlainpostComposerWindowRequest,
        snapshot: ComposerRestoreSnapshot
    ) -> PlainpostComposerWindowRequest? {
        switch self {
        case .embedded:
            nil
        case .runtimeWindow:
            runtimeRequest
        case .snapshotWindow:
            .restore(snapshot)
        }
    }
}

public struct ComposerReplyContext: Codable, Equatable, Hashable, Sendable {
    public let sourceThreadID: ThreadID?
    public let sourceMessageID: MessageID
    public let rfcMessageID: String?
    public let sourceInReplyTo: String?
    public let references: [String]
    public let recipient: String
    public let subject: String
    public let senderName: String
    public let dateLabel: String
    public let quotedBody: String
    public let cc: [String]

    public init(
        sourceThreadID: ThreadID?,
        sourceMessageID: MessageID,
        rfcMessageID: String?,
        sourceInReplyTo: String? = nil,
        references: [String],
        recipient: String,
        subject: String,
        senderName: String,
        dateLabel: String,
        quotedBody: String,
        cc: [String] = []
    ) {
        self.sourceThreadID = sourceThreadID
        self.sourceMessageID = sourceMessageID
        self.rfcMessageID = rfcMessageID
        self.sourceInReplyTo = sourceInReplyTo
        self.references = references
        self.recipient = recipient
        self.subject = subject
        self.senderName = senderName
        self.dateLabel = dateLabel
        self.quotedBody = quotedBody
        self.cc = cc
    }

    private enum CodingKeys: String, CodingKey {
        case sourceThreadID
        case sourceMessageID
        case rfcMessageID
        case sourceInReplyTo
        case references
        case recipient
        case subject
        case senderName
        case dateLabel
        case quotedBody
        case cc
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceThreadID = try container.decodeIfPresent(ThreadID.self, forKey: .sourceThreadID)
        sourceMessageID = try container.decode(MessageID.self, forKey: .sourceMessageID)
        rfcMessageID = try container.decodeIfPresent(String.self, forKey: .rfcMessageID)
        sourceInReplyTo = try container.decodeIfPresent(String.self, forKey: .sourceInReplyTo)
        references = try container.decode([String].self, forKey: .references)
        recipient = try container.decode(String.self, forKey: .recipient)
        subject = try container.decode(String.self, forKey: .subject)
        senderName = try container.decode(String.self, forKey: .senderName)
        dateLabel = try container.decode(String.self, forKey: .dateLabel)
        quotedBody = try container.decode(String.self, forKey: .quotedBody)
        cc = try container.decodeIfPresent([String].self, forKey: .cc) ?? []
    }
}

/// What a forward quotes: the original's subject, sender, date, and body.
public struct ComposerForwardContext: Codable, Equatable, Hashable, Sendable {
    public let sourceMessageID: MessageID
    public let subject: String
    public let senderName: String
    public let senderAddress: String
    public let dateLabel: String
    public let quotedBody: String

    public init(
        sourceMessageID: MessageID,
        subject: String,
        senderName: String,
        senderAddress: String,
        dateLabel: String,
        quotedBody: String
    ) {
        self.sourceMessageID = sourceMessageID
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.dateLabel = dateLabel
        self.quotedBody = quotedBody
    }
}

public protocol ComposerHandling: Sendable {
    func saveDraft(input: ComposerDraftInput) throws -> Draft
}

public protocol ComposerDraftSessionHandling: ComposerHandling {
    func beginNewDraftSession()
    func restoreDraftSession(draftID: String)
    func discardDraft(draftID: String) throws
}

public struct UnavailableComposerDraftHandler: ComposerHandling {
    public init() {}
    public func saveDraft(input _: ComposerDraftInput) throws -> Draft {
        throw PlainpostError.validationFailed("No authenticated sender identity is available for this account.")
    }
}

public struct DirectComposerSendResult: Equatable, Sendable {
    public let messageID: String
    public let remoteSentCopyAppended: Bool
    /// The send is queued for, or admitted by, the Sync Node and has not gone
    /// out yet: the UI must not report it as sent.
    public let isQueuedForSyncNode: Bool

    public init(messageID: String, remoteSentCopyAppended: Bool, isQueuedForSyncNode: Bool = false) {
        self.messageID = messageID
        self.remoteSentCopyAppended = remoteSentCopyAppended
        self.isQueuedForSyncNode = isQueuedForSyncNode
    }
}

public protocol AsyncComposerHandling: Sendable {
    func saveDraft(input: ComposerDraftInput) async throws -> Draft
    func discardDraft(draftID: String) async throws
    /// Starts a new composer session and releases any remote draft identity.
    func beginNewDraftSession()
    /// Rehydrates an existing remote draft identity after undo/failure restore.
    func restoreDraftSession(draftID: String)
}

public extension AsyncComposerHandling {
    func discardDraft(draftID _: String) async throws {
        throw PlainpostError.validationFailed("This saved draft cannot be deleted here.")
    }
    func beginNewDraftSession() {}
    func restoreDraftSession(draftID _: String) {}
}

/// Delivers a message that the local user explicitly sent from the composer.
/// Agent/MCP sends intentionally use `SendRequestRepository` instead.
public protocol DirectComposerSending: Sendable {
    func send(draft: Draft) async throws -> DirectComposerSendResult
}

@MainActor
public protocol ComposerSendScheduling: AnyObject {
    var isSendPending: Bool { get }

    @discardableResult
    func schedule(draft: Draft, restoring snapshot: ComposerRestoreSnapshot) -> Bool
}

public struct ComposerDraftInput: Equatable, Sendable {
    public let to: String
    public let cc: String
    public let bcc: String
    public let subject: String
    public let bodyPlain: String
    public let bodyMarkdown: String
    public let sourceThreadID: ThreadID?
    public let inReplyTo: String?
    public let references: [String]
    public let attachments: [DraftAttachment]

    public init(
        to: String,
        cc: String,
        bcc: String,
        subject: String,
        bodyPlain: String,
        bodyMarkdown: String? = nil,
        sourceThreadID: ThreadID? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [DraftAttachment] = []
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyMarkdown = bodyMarkdown ?? MarkdownEmailRenderer.canonicalize(bodyPlain)
        self.sourceThreadID = sourceThreadID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }
}

public enum ComposerPresentationMode: Codable, Equatable, Hashable, Sendable {
    case newMessage
    case reply(recipient: String, subject: String)
}

public extension ComposerRestoreSnapshot {
    static func preview() -> ComposerRestoreSnapshot {
        ComposerRestoreSnapshot(
            to: "alice@example.com",
            cc: "",
            bcc: "",
            subject: "Undo send",
            bodyMarkdown: "Body",
            attachments: [],
            presentationMode: .newMessage,
            replyContext: nil,
            includesQuotedHistory: true
        )
    }
}

/// A picked-files import in progress: the file being read and how many are done.
public struct ComposerAttachmentImport: Equatable, Sendable {
    public let filename: String
    public let completed: Int
    public let total: Int
}

public protocol ComposerDraftStore: DraftRepository {}

extension InMemoryMailStore: ComposerDraftStore {}
extension SQLiteMailStore: ComposerDraftStore {}

enum ComposerDraftBuilder {
    static func makeDraft(
        input: ComposerDraftInput,
        id: DraftID,
        accountID: AccountID,
        from: EmailAddress,
        actor: Actor
    ) throws -> Draft {
        let to = parseRecipients(input.to)
        let cc = parseRecipients(input.cc)
        let bcc = parseRecipients(input.bcc)
        return Draft(
            id: id,
            accountID: accountID,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: input.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyPlain: input.bodyPlain,
            bodyMarkdown: input.bodyMarkdown,
            createdBy: actor.id,
            aiGenerated: false,
            sourceThreadID: input.sourceThreadID,
            inReplyTo: input.inReplyTo,
            references: input.references,
            attachments: input.attachments
        )
    }

    static func recipientsAreSendable(to: String, cc: String, bcc: String) -> Bool {
        let recipients = [to, cc, bcc].flatMap(parseRecipients)
        return !recipients.isEmpty && recipients.allSatisfy { $0.rawValue.isPlausibleEmailAddress }
    }

    private static func parseRecipients(_ rawValue: String) -> [EmailAddress] {
        let pieces = rawValue
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Drafts may contain a name or partially typed address. Validation is
        // applied when sending, after the recipient has been completed.
        return pieces.map { EmailAddress($0) }
    }
}

public final class ComposerDraftService<Store: ComposerDraftStore>: ComposerHandling, @unchecked Sendable {
    private let store: Store
    private let accountID: AccountID
    private let from: EmailAddress
    private let actor: Actor
    private let idGenerator: @Sendable () -> DraftID

    public init(
        store: Store,
        accountID: AccountID,
        from: EmailAddress,
        actor: Actor,
        idGenerator: @escaping @Sendable () -> DraftID = { DraftID("drf_\(UUID().uuidString.lowercased())") }
    ) {
        self.store = store
        self.accountID = accountID
        self.from = from
        self.actor = actor
        self.idGenerator = idGenerator
    }

    public func saveDraft(input: ComposerDraftInput) throws -> Draft {
        let draft = try makeDraft(input: input)
        _ = try draft.validated()
        return try store.createDraft(draft, actor: actor)
    }

    private func makeDraft(input: ComposerDraftInput) throws -> Draft {
        try ComposerDraftBuilder.makeDraft(
            input: input,
            id: idGenerator(),
            accountID: accountID,
            from: from,
            actor: actor
        )
    }
}

@MainActor
public final class ComposerViewModel: ObservableObject {
    @Published public var to: String { didSet { draftDidChange() } }
    @Published public var cc: String { didSet { draftDidChange() } }
    @Published public var bcc: String { didSet { draftDidChange() } }
    @Published public var subject: String { didSet { draftDidChange() } }
    @Published public var bodyMarkdown: String { didSet { draftDidChange() } }
    @Published public var attachments: [DraftAttachment] { didSet { draftDidChange() } }
    @Published public private(set) var presentationMode: ComposerPresentationMode
    @Published public private(set) var isWorking: Bool
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var lastDraftID: String?
    @Published public private(set) var lastSentMessageID: String?
    @Published public private(set) var replyContext: ComposerReplyContext?
    @Published public var includesQuotedHistory: Bool
    @Published public private(set) var isSendScheduled: Bool
    /// The composer holds edits that are neither saved nor sent. Content the
    /// composer was prepared with, or a restored saved draft, is not an edit.
    @Published public private(set) var hasUnsavedChanges = false
    /// Original files a forward is still loading. The draft can't be sent until they arrive,
    /// so a forward never goes out silently without them.
    @Published public private(set) var pendingForwardAttachmentCount = 0
    /// Why nothing can be sent right now, whatever the draft holds: the account is read-only.
    /// The composer shows it; nil lets Send follow the draft. Only the iPhone sheet sets it.
    @Published public var sendBlockedReason: String?
    /// Draft with AI is writing this draft's body. Send waits, so the draft can't go out
    /// while its body is about to change.
    @Published public internal(set) var isDraftingAIBody = false
    /// Picked files still being read into attachments. Send waits for them.
    @Published public private(set) var attachmentImport: ComposerAttachmentImport?

    public var isLoadingForwardAttachments: Bool { pendingForwardAttachmentCount > 0 }

    private var composer: ComposerHandling
    /// The accounts a new message can be sent from, when there's a choice; empty when the
    /// From account is fixed (a reply or forward, or only one account).
    @Published public private(set) var fromAccounts: [Account] = []
    /// The account this draft is saved and sent through, when the composer chooses it.
    @Published public private(set) var fromAccountID: AccountID?
    /// The address a reply or forward is sent from, shown (not offered) when there's more
    /// than one account.
    @Published public private(set) var fixedFromAddress: String?
    private let fromAccountSource: ComposerFromAccounts?
    /// Advances on every edit, so a save only settles the edits it read.
    private var editRevision: UInt64 = 0
    /// A `send()` has passed its checks and not yet returned.
    private var isSendInFlight = false
    /// Advances when an attachment import starts or is dropped, so a file read that finishes
    /// late never lands in a draft that was closed or replaced.
    private var attachmentImportGeneration: UInt64 = 0
    /// What an AI body replaced, for `undoAIDraftBody`: the edit it was, and whether the draft
    /// had unsaved changes before it. Cleared by a save or send, after which Undo is an edit.
    private var aiBodyUndo: AIBodyUndo?

    private struct AIBodyUndo {
        let revision: UInt64
        let hadUnsavedChanges: Bool
    }
    private let asyncComposer: (any AsyncComposerHandling)?
    private let sendScheduler: any ComposerSendScheduling

    public init(
        composer: ComposerHandling,
        asyncComposer: (any AsyncComposerHandling)? = nil,
        directSender: any DirectComposerSending = UnconfiguredDirectComposerSender(),
        sendScheduler: (any ComposerSendScheduling)? = nil,
        to: String = "",
        cc: String = "",
        bcc: String = "",
        subject: String = "",
        bodyPlain: String = "",
        bodyMarkdown: String? = nil,
        attachments: [DraftAttachment] = [],
        presentationMode: ComposerPresentationMode = .newMessage,
        fromAccounts: ComposerFromAccounts? = nil
    ) {
        self.composer = composer
        self.fromAccountSource = fromAccounts
        self.asyncComposer = asyncComposer
        self.sendScheduler = sendScheduler ?? UndoSendCoordinator(sender: directSender)
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyMarkdown = MarkdownEmailRenderer.canonicalize(bodyMarkdown ?? bodyPlain)
        self.attachments = attachments
        self.presentationMode = presentationMode
        self.isWorking = false
        self.replyContext = nil
        self.includesQuotedHistory = true
        self.isSendScheduled = false
        if let fromAccounts { useFromAccount(fromAccounts.defaultAccountID(), offersChoice: true) }
    }

    /// Sends this draft from `accountID`, one of `fromAccounts`. A draft already saved through
    /// the previous account is deleted there, so it never lingers under the wrong account.
    public func selectFromAccount(_ accountID: AccountID) {
        guard fromAccountSource != nil, accountID != fromAccountID,
              fromAccounts.contains(where: { $0.id == accountID }) else { return }
        if let lastDraftID, let session = composer as? any ComposerDraftSessionHandling {
            do {
                try session.discardDraft(draftID: lastDraftID)
            } catch {
                // Never leave the saved draft behind under the old account.
                statusMessage = "The draft couldn't be moved to that account. Delete it, then start again."
                return
            }
            self.lastDraftID = nil
        }
        useFromAccount(accountID, offersChoice: true)
        hasUnsavedChanges = hasDraftContent
    }

    /// Points the draft at `accountID` (else the first account), offering the others only for
    /// a new message.
    private func useFromAccount(_ accountID: AccountID?, offersChoice: Bool) {
        guard let source = fromAccountSource else { return }
        let accounts = source.accounts()
        // A reply or forward goes out only from its original's account: when that account is
        // gone, or no longer Direct, the draft is blocked instead of falling back to another.
        let requested = accounts.first(where: { $0.id == accountID })
        guard let account = requested ?? (offersChoice ? accounts.first : nil) else {
            composer = UnavailableComposerDraftHandler()
            fromAccountID = nil
            fromAccounts = []
            fixedFromAddress = nil
            sendBlockedReason = Self.missingFromAccountReason
            return
        }
        if sendBlockedReason == Self.missingFromAccountReason { sendBlockedReason = nil }
        if account.id != fromAccountID {
            composer = source.makeComposer(account)
            fromAccountID = account.id
        }
        fromAccounts = offersChoice && accounts.count > 1 ? accounts : []
        fixedFromAddress = !offersChoice && accounts.count > 1 ? account.email.rawValue : nil
    }

    static let missingFromAccountReason =
        "The account this message was sent to isn't available on this device, so it can't be answered from here."

    static let removedFromAccountReason =
        "The account this message was being sent from was removed from this device, so it can't be sent."

    /// Whether the composer holds anything a close would lose.
    public var hasDraftText: Bool { hasDraftContent }

    /// Checks the From account against the accounts the composer may send from. When it is
    /// gone, Send is blocked with the reason and this returns true; it never moves the
    /// draft to another account.
    @discardableResult
    public func fromAccountWasRemoved() -> Bool {
        guard let source = fromAccountSource, let fromAccountID,
              !source.accounts().contains(where: { $0.id == fromAccountID }) else { return false }
        composer = UnavailableComposerDraftHandler()
        self.fromAccountID = nil
        fromAccounts = []
        fixedFromAddress = nil
        sendBlockedReason = Self.removedFromAccountReason
        return true
    }

    public var canSaveDraft: Bool {
        !isWorking && hasDraftContent
    }

    public var canSend: Bool {
        canSaveDraft
            && ComposerDraftBuilder.recipientsAreSendable(to: to, cc: cc, bcc: bcc)
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSendScheduled && lastSentMessageID == nil
            && !isLoadingForwardAttachments
            && sendBlockedReason == nil
            && attachmentImport == nil
            && !isDraftingAIBody
    }

    public var hasSavedDraft: Bool { lastDraftID != nil }

    public var canDeleteSavedDraft: Bool {
        asyncComposer != nil || composer is any ComposerDraftSessionHandling
    }

    public var restorationSnapshot: ComposerRestoreSnapshot {
        ComposerRestoreSnapshot(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            bodyMarkdown: bodyMarkdown,
            attachments: attachments,
            presentationMode: presentationMode,
            replyContext: replyContext,
            includesQuotedHistory: includesQuotedHistory,
            draftID: lastDraftID,
            fromAccountID: fromAccountID
        )
    }

    public var displayStatusMessage: String {
        if let statusMessage {
            return statusMessage
        }
        if isLoadingForwardAttachments {
            return Self.forwardLoadingStatus(count: pendingForwardAttachmentCount)
        }
        if hasDraftContent {
            return "Unsaved changes"
        }
        return "New local draft"
    }

    public func prepareNewMessage() {
        presentationMode = .newMessage
        replyContext = nil
        useFromAccount(fromAccountSource?.defaultAccountID(), offersChoice: true)
        resetDraft(to: "", subject: "")
    }

    public func prepareReply(to recipient: String, subject originalSubject: String) {
        replyContext = nil
        prepareReplyFields(to: recipient, subject: originalSubject)
    }

    public func prepareReply(context: ComposerReplyContext) {
        replyContext = context
        includesQuotedHistory = true
        // A reply goes out from the account the original was sent to.
        useFromAccount(fromAccountSource?.owner(context.sourceMessageID), offersChoice: false)
        prepareReplyFields(to: context.recipient, subject: context.subject)
    }

    public func prepareReplyAll(context: ComposerReplyContext) {
        prepareReply(context: context)
        cc = context.cc.joined(separator: ", ")
    }

    private func prepareReplyFields(to recipient: String, subject originalSubject: String) {
        let trimmedSubject = originalSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let replySubject = trimmedSubject.range(of: "re:", options: [.anchored, .caseInsensitive]) != nil
            ? trimmedSubject
            : "Re: \(trimmedSubject)"
        presentationMode = .reply(recipient: recipient, subject: trimmedSubject)
        resetDraft(to: recipient, subject: replySubject)
    }

    public func prepareAIDraftReply(to recipient: String, subject: String, bodyMarkdown: String) {
        prepareReply(to: recipient, subject: subject)
        self.bodyMarkdown = MarkdownEmailRenderer.canonicalize(bodyMarkdown)
        statusMessage = aiDraftStatusMessage(recipient: recipient)
    }

    public func prepareAIDraftReply(context: ComposerReplyContext, bodyMarkdown: String) {
        prepareReply(context: context)
        self.bodyMarkdown = MarkdownEmailRenderer.canonicalize(bodyMarkdown)
        statusMessage = aiDraftStatusMessage(recipient: context.recipient)
    }

    /// Puts an AI-written reply in the body of the open draft. Recipients, subject,
    /// attachments, the reply context and the saved draft stay as they are, and the new body
    /// counts as an edit to save.
    func applyAIDraftBody(_ markdown: String) {
        let hadUnsavedChanges = hasUnsavedChanges
        bodyMarkdown = MarkdownEmailRenderer.canonicalize(markdown)
        aiBodyUndo = AIBodyUndo(revision: editRevision, hadUnsavedChanges: hadUnsavedChanges)
    }

    /// Undo for an AI body: puts `previousBody` back. When nothing else changed or was saved
    /// since the AI wrote, the draft returns to the state it was in, so a saved draft isn't left
    /// looking unsaved.
    func undoAIDraftBody(_ previousBody: String) {
        let undo = aiBodyUndo
        bodyMarkdown = previousBody
        if let undo, editRevision == undo.revision &+ 1 {
            hasUnsavedChanges = undo.hadUnsavedChanges
        }
        aiBodyUndo = nil
    }

    /// A new message (no recipients, no reply threading) that quotes `context` and carries
    /// the original's files. `unavailable` names files that could not be loaded; they are
    /// reported in the status message rather than silently dropped.
    public func prepareForward(
        context: ComposerForwardContext,
        attachments: [DraftAttachment],
        unavailable: [String]
    ) {
        prepareNewMessage()
        // A forward goes out from the account the original was sent to.
        useFromAccount(fromAccountSource?.owner(context.sourceMessageID), offersChoice: false)
        let trimmed = context.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        subject = trimmed.range(of: "fwd:", options: [.anchored, .caseInsensitive]) != nil
            ? trimmed
            : "Fwd: \(trimmed)"
        bodyMarkdown = """


        ---------- Forwarded message ----------
        From: \(context.senderName) <\(context.senderAddress)>
        Date: \(context.dateLabel)
        Subject: \(trimmed)

        \(context.quotedBody)
        """
        appendForwardedFiles(attachments, unavailable: unavailable)
    }

    /// Marks a prepared forward as still loading `count` original files: it can't be sent
    /// until `attachForwardedFiles` delivers them. Used where the composer is shown before
    /// the files load (the macOS composer window).
    public func beginAttachingForwardedFiles(count: Int) {
        guard count > 0 else { return }
        pendingForwardAttachmentCount = count
        statusMessage = Self.forwardLoadingStatus(count: count)
    }

    /// Delivers the files `beginAttachingForwardedFiles` announced, keeping any edits made
    /// while they loaded. Ignored once the draft was replaced (a new message, a restore, a
    /// discard). Files that arrive after the draft was sent are reported, not attached, and
    /// files that arrive after a save leave the draft unsaved and say so.
    public func attachForwardedFiles(_ files: [DraftAttachment], unavailable: [String]) {
        guard isLoadingForwardAttachments else { return }
        pendingForwardAttachmentCount = 0
        if isSendScheduled || lastSentMessageID != nil || isSendInFlight {
            // Unreachable while `canSend` waits for the files; kept so a late arrival is never silent.
            let names = (files.map(\.filename) + unavailable).joined(separator: ", ")
            statusMessage = "Sent without the original files (\(names)). Forward again to include them."
            return
        }
        let arrivedAfterSave = lastDraftID != nil || isWorking
        appendForwardedFiles(files, unavailable: unavailable)
        if arrivedAfterSave, !files.isEmpty {
            let notice = "Original files attached after the draft was saved. Save again to keep them."
            statusMessage = [statusMessage, notice].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func appendForwardedFiles(_ files: [DraftAttachment], unavailable: [String]) {
        if !files.isEmpty {
            attachments += files
        }
        if !unavailable.isEmpty {
            let pronoun = unavailable.count == 1 ? "it" : "them"
            statusMessage = "Couldn't attach \(unavailable.joined(separator: ", ")). Forwarding without \(pronoun)."
        }
    }

    /// Reads picked files into attachments one at a time, off the main actor, since a file can
    /// be large or still downloading from iCloud. Each is checked against the files already
    /// attached. Returns "name: reason" for each file that wasn't attached. Nothing lands when
    /// the draft is replaced or `cancelAttachmentImport()` runs first.
    func importAttachments(
        from urls: [URL],
        read: @escaping @Sendable (URL, [DraftAttachment]) throws -> DraftAttachment
    ) async -> [String] {
        guard !urls.isEmpty else { return [] }
        attachmentImportGeneration &+= 1
        let generation = attachmentImportGeneration
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            attachmentImport = ComposerAttachmentImport(filename: url.lastPathComponent, completed: index, total: urls.count)
            let existing = attachments
            let result = await Task.detached(priority: .userInitiated) {
                Result { try read(url, existing) }
            }.value
            guard generation == attachmentImportGeneration else { return [] }
            switch result {
            case let .success(attachment):
                attachments.append(attachment)
            case let .failure(failure as MobileAttachmentImport.Failure):
                failures.append("\(url.lastPathComponent): \(failure.localizedDescription)")
            case .failure:
                failures.append("\(url.lastPathComponent): Plainpost couldn't read that file.")
            }
        }
        attachmentImport = nil
        return failures
    }

    /// Drops an attachment import in progress: files still being read are not attached.
    func cancelAttachmentImport() {
        attachmentImportGeneration &+= 1
        attachmentImport = nil
    }

    static func forwardLoadingStatus(count: Int) -> String {
        count == 1 ? "Attaching 1 original file..." : "Attaching \(count) original files..."
    }

    private func aiDraftStatusMessage(recipient: String) -> String {
        recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "AI draft ready. Add a recipient before sending."
            : "AI draft ready for review"
    }

    public var quotedHistoryMarkdown: String? {
        guard includesQuotedHistory, let replyContext else { return nil }
        let attribution = replyContext.dateLabel.isEmpty
            ? "\(replyContext.senderName) wrote:"
            : "On \(replyContext.dateLabel), \(replyContext.senderName) wrote:"
        let quotedLines = replyContext.quotedBody
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "\(attribution)\n\(quotedLines)"
    }

    private var quotedHistoryPlainText: String? {
        guard includesQuotedHistory, let replyContext else { return nil }
        let attribution = replyContext.dateLabel.isEmpty
            ? "\(replyContext.senderName) wrote:"
            : "On \(replyContext.dateLabel), \(replyContext.senderName) wrote:"
        let quotedLines = replyContext.quotedBody
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "\(attribution)\n\(quotedLines)"
    }

    public func saveDraft() async throws {
        let savedRevision = editRevision
        isWorking = true
        statusMessage = "Saving draft..."
        defer { isWorking = false }
        do {
            let draft = if let asyncComposer {
                try await asyncComposer.saveDraft(input: input)
            } else {
                try composer.saveDraft(input: input)
            }
            lastDraftID = draft.id.rawValue
            statusMessage = "Draft saved"
            aiBodyUndo = nil
            settleUnsavedChanges(savedRevision)
        } catch PlainpostError.validationFailed(let message) {
            statusMessage = message
        } catch {
            statusMessage = "Draft could not be saved. Try again."
            throw error
        }
    }

    public func discardDraft() async throws {
        if let lastDraftID {
            do {
                if let asyncComposer {
                    try await asyncComposer.discardDraft(draftID: lastDraftID)
                } else if let localSession = composer as? any ComposerDraftSessionHandling {
                    try localSession.discardDraft(draftID: lastDraftID)
                } else {
                    throw PlainpostError.validationFailed("This saved draft cannot be deleted here.")
                }
            } catch PlainpostError.validationFailed(let message) {
                statusMessage = message
                throw PlainpostError.validationFailed(message)
            } catch {
                statusMessage = "Draft could not be deleted. Try again."
                throw error
            }
        }
        resetDraft(to: "", subject: "")
    }

    @discardableResult
    public func send() async throws -> Bool {
        guard canSend else { return false }
        let sentRevision = editRevision
        isWorking = true
        isSendInFlight = true
        defer {
            isWorking = false
            isSendInFlight = false
        }
        guard !sendScheduler.isSendPending else {
            statusMessage = "A send is already pending"
            return false
        }
        do {
            let draft = if let asyncComposer {
                try await asyncComposer.saveDraft(input: input)
            } else {
                try composer.saveDraft(input: input)
            }
            lastDraftID = draft.id.rawValue
            guard sendScheduler.schedule(draft: draft, restoring: restorationSnapshot) else {
                statusMessage = "A send is already pending"
                return false
            }
            isSendScheduled = true
            statusMessage = "Sending in 10s"
            aiBodyUndo = nil
            settleUnsavedChanges(sentRevision)
            return true
        } catch PlainpostError.validationFailed(let message) {
            statusMessage = message
            return false
        } catch {
            statusMessage = "Message could not be sent. Try again."
            throw error
        }
    }

    public func restore(from snapshot: ComposerRestoreSnapshot) {
        // Back to the account it was going out from: fixed for a reply, a choice for a new message.
        if fromAccountSource != nil, snapshot.fromAccountID != nil {
            useFromAccount(snapshot.fromAccountID, offersChoice: snapshot.replyContext == nil)
        }
        if let draftID = snapshot.draftID {
            asyncComposer?.restoreDraftSession(draftID: draftID)
            (composer as? any ComposerDraftSessionHandling)?.restoreDraftSession(draftID: draftID)
        } else {
            asyncComposer?.beginNewDraftSession()
            (composer as? any ComposerDraftSessionHandling)?.beginNewDraftSession()
        }
        to = snapshot.to
        cc = snapshot.cc
        bcc = snapshot.bcc
        subject = snapshot.subject
        bodyMarkdown = snapshot.bodyMarkdown
        attachments = snapshot.attachments
        presentationMode = snapshot.presentationMode
        replyContext = snapshot.replyContext
        includesQuotedHistory = snapshot.includesQuotedHistory
        lastDraftID = snapshot.draftID
        lastSentMessageID = nil
        isSendScheduled = false
        pendingForwardAttachmentCount = 0
        cancelAttachmentImport()
        aiBodyUndo = nil
        statusMessage = "Draft restored"
        // A snapshot with a draft identity was saved before it was scheduled.
        hasUnsavedChanges = snapshot.draftID == nil && hasDraftContent
    }

    public static func preview() -> ComposerViewModel {
        ComposerViewModel(
            composer: PreviewComposer(),
            to: "Jessica Sun <jessica@bbb.vc>",
            subject: "Re: Intro Emily <> Max",
            bodyMarkdown: """
            Hi Jessica,

            Thanks so much for the introduction.

            I'd love to connect with Max and learn more about BB8's vision and how AAA Capital can be most helpful. I'm generally available early next week - please suggest a couple of times that work for you both.

            Best,
            Emily
            """,
            presentationMode: .reply(
                recipient: "Jessica Sun <jessica@bbb.vc>",
                subject: "Intro Emily <> Max"
            )
        )
    }

    private var hasDraftContent: Bool {
        !attachments.isEmpty || [to, cc, bcc, subject, bodyMarkdown].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func resetDraft(to recipient: String, subject: String) {
        asyncComposer?.beginNewDraftSession()
        (composer as? any ComposerDraftSessionHandling)?.beginNewDraftSession()
        to = recipient
        cc = ""
        bcc = ""
        self.subject = subject
        bodyMarkdown = ""
        attachments = []
        statusMessage = nil
        lastDraftID = nil
        lastSentMessageID = nil
        isSendScheduled = false
        pendingForwardAttachmentCount = 0
        cancelAttachmentImport()
        aiBodyUndo = nil
        hasUnsavedChanges = false
    }

    private func settleUnsavedChanges(_ revision: UInt64) {
        guard editRevision == revision else { return }
        hasUnsavedChanges = false
    }

    private func draftDidChange() {
        editRevision &+= 1
        hasUnsavedChanges = hasDraftContent
        guard !isWorking else {
            return
        }
        statusMessage = nil
        lastSentMessageID = nil
        isSendScheduled = false
    }

    private var input: ComposerDraftInput {
        let authoredMarkdown = MarkdownEmailRenderer.canonicalize(bodyMarkdown)
        let markdown = [authoredMarkdown, quotedHistoryMarkdown]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let replyReferences = orderedUnique(
            (replyContext?.references ?? [])
                + [replyContext?.sourceInReplyTo, replyContext?.rfcMessageID].compactMap { $0 }
        )
        let plainText = [MarkdownEmailRenderer.plainText(from: authoredMarkdown), quotedHistoryPlainText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return ComposerDraftInput(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            bodyPlain: plainText,
            bodyMarkdown: markdown,
            sourceThreadID: replyContext?.sourceThreadID,
            inReplyTo: replyContext?.rfcMessageID,
            references: replyReferences,
            attachments: attachments
        )
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Compatibility bridge for clients that still provide plain text.
    public var bodyPlain: String {
        get { MarkdownEmailRenderer.plainText(from: bodyMarkdown) }
        set { bodyMarkdown = MarkdownEmailRenderer.canonicalize(newValue) }
    }
}

extension UndoSendCoordinator: ComposerSendScheduling {}

/// Whether a runtime's embedded composer is open with unsaved changes. The
/// root view reports it; an owner that would discard the composer, such as an
/// iOS account switch, reads it first.
@MainActor
public final class PlainpostComposerActivity: ObservableObject {
    @Published public private(set) var hasUnsavedOpenComposer = false

    public init() {}

    public func update(hasUnsavedOpenComposer value: Bool) {
        guard hasUnsavedOpenComposer != value else { return }
        hasUnsavedOpenComposer = value
    }

    /// Publishes the current value, then every change.
    public var unsavedOpenComposerPublisher: AnyPublisher<Bool, Never> {
        $hasUnsavedOpenComposer.removeDuplicates().eraseToAnyPublisher()
    }
}

private struct PreviewComposer: ComposerHandling {
    func saveDraft(input: ComposerDraftInput) throws -> Draft {
        Draft(
            id: DraftID("drf_preview"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: input.subject,
            bodyPlain: input.bodyPlain,
            createdBy: "preview",
            aiGenerated: false,
            sourceThreadID: input.sourceThreadID,
            inReplyTo: input.inReplyTo,
            references: input.references,
            attachments: input.attachments
        )
    }

}

public struct UnconfiguredDirectComposerSender: DirectComposerSending {
    public init() {}

    public func send(draft: Draft) async throws -> DirectComposerSendResult {
        throw PlainpostError.validationFailed("Set up an account before sending mail.")
    }
}

/// A Node account must send through its signed Node operation capability. Do
/// not silently send a Node draft through the legacy provider/service path.
public struct NodeAuthorityDirectComposerSender: DirectComposerSending {
    private let mutations: (any MailMutationServing)?

    public init() { mutations = nil }

    public init(mutations: any MailMutationServing) {
        self.mutations = mutations
    }

    public func send(draft: Draft) async throws -> DirectComposerSendResult {
        guard let mutations else {
            throw PlainpostError.validationFailed("Node mail sending requires an authenticated Node operation.")
        }
        let result = try await mutations.perform(.send(draft))
        return DirectComposerSendResult(
            messageID: result.idempotencyKey,
            remoteSentCopyAppended: result.state == "applied"
        )
    }
}

public struct NodeAuthorityComposerDraftHandler: AsyncComposerHandling {
    private let accountID: AccountID
    private let from: EmailAddress?
    private let senderProvider: (@Sendable () -> EmailAddress?)?
    private let actor: Actor
    private let mutations: any MailMutationServing
    private let idGenerator: @Sendable () -> DraftID
    private let draftIdentity: ComposerDraftIdentity

    public init(
        accountID: AccountID,
        from: EmailAddress,
        actor: Actor,
        mutations: any MailMutationServing,
        senderProvider: (@Sendable () -> EmailAddress?)? = nil,
        idGenerator: @escaping @Sendable () -> DraftID = { DraftID("drf_\(UUID().uuidString.lowercased())") }
    ) {
        self.accountID = accountID
        self.from = from
        self.senderProvider = senderProvider
        self.actor = actor
        self.mutations = mutations
        self.idGenerator = idGenerator
        self.draftIdentity = ComposerDraftIdentity()
    }

    /// Builds a Node composer whose sender is resolved only when the draft is
    /// submitted. This keeps a first-time status refresh from leaving a
    /// retained composer bound to a stale or placeholder identity.
    public init(
        accountID: AccountID,
        actor: Actor,
        mutations: any MailMutationServing,
        senderProvider: @escaping @Sendable () -> EmailAddress?
    ) {
        self.accountID = accountID
        self.from = nil
        self.senderProvider = senderProvider
        self.actor = actor
        self.mutations = mutations
        self.idGenerator = { DraftID("drf_\(UUID().uuidString.lowercased())") }
        self.draftIdentity = ComposerDraftIdentity()
    }

    public func saveDraft(input: ComposerDraftInput) async throws -> Draft {
        guard let sender = senderProvider?() ?? from else {
            throw PlainpostError.validationFailed("No authenticated sender identity is available for this account.")
        }
        let draft = try ComposerDraftBuilder.makeDraft(
            input: input,
            id: draftIdentity.current(orCreate: idGenerator),
            accountID: accountID,
            from: sender,
            actor: actor
        )
        _ = try draft.validated()
        _ = try await mutations.perform(.saveDraft(draft))
        return draft
    }

    public func discardDraft(draftID: String) async throws {
        guard !draftID.isEmpty else { return }
        let result = try await mutations.perform(.deleteDraft(DraftID(draftID)))
        guard result.state == "applied" else {
            throw PlainpostError.validationFailed("The Node could not confirm draft deletion.")
        }
        draftIdentity.reset()
    }

    public func beginNewDraftSession() {
        draftIdentity.reset()
    }

    public func restoreDraftSession(draftID: String) {
        guard !draftID.isEmpty else { return }
        draftIdentity.restore(DraftID(draftID))
    }
}

final class ComposerDraftIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DraftID?

    func current(orCreate generator: @Sendable () -> DraftID) -> DraftID {
        lock.lock(); defer { lock.unlock() }
        if let value { return value }
        let generated = generator()
        value = generated
        return generated
    }

    func reset() {
        lock.lock(); value = nil; lock.unlock()
    }

    func restore(_ draftID: DraftID) {
        lock.lock(); value = draftID; lock.unlock()
    }
}

private extension String {
    var isPlausibleEmailAddress: Bool {
        let parts = split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first,
              let domain = parts.last,
              !local.isEmpty,
              domain.contains("."),
              !contains(" ")
        else {
            return false
        }
        return true
    }
}

/// Where a composer that chooses its From account gets its choices: the accounts it can send
/// from, the default for a new message, the account a message was sent to (for replies and
/// forwards), and a draft handler bound to one account.
public struct ComposerFromAccounts {
    let accounts: () -> [Account]
    let defaultAccountID: () -> AccountID?
    let owner: (MessageID) -> AccountID?
    let makeComposer: (Account) -> ComposerHandling
}
