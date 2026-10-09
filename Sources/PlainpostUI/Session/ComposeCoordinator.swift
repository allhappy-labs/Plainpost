import Foundation
import PlainpostCore

/// What a platform asks the composer to show.
enum ComposeRequest: Equatable {
    case new
    case reply(messageID: String)
    case replyAll(messageID: String)
    /// Forwards the message with its quoted body and original files.
    case forward(messageID: String)
    /// A reply whose AI-written body is already known (Ask Mail's draft block).
    case aiDraftReply(messageID: String, bodyMarkdown: String, recipient: String)
    case restore(ComposerRestoreSnapshot)
    case undoLatestSend
    case restoreFailedSend
}

/// What ✦ Draft with AI did in an open composer.
enum ComposerAIBodyResult: Equatable {
    /// The body now holds the AI draft; `previousBody` is what it replaced, for Undo.
    case filled(previousBody: String)
    /// The body is unchanged, for this reason.
    case failed(String)
}

/// How the platform should show the result of a `ComposeRequest`.
enum ComposePresentation: Equatable {
    /// Nothing to show (e.g. no source message).
    case none
    /// Show the composer in-app (iPhone sheet / Mac embedded).
    case embedded
    /// Mac: `openWindow(value:)`.
    case window(PlainpostComposerWindowRequest)
}

/// Turns compose requests (new, reply, reply all, forward, AI reply, restore, undo send) into a prepared
/// composer and a presentation, independent of any platform UI. It sets `isPresented`
/// itself when it answers `.embedded`; the platform opens a window for `.window`.
@MainActor
final class ComposeCoordinator: ObservableObject {
    @Published var isPresented: Bool {
        didSet {
            guard oldValue, !isPresented else { return }
            closeCount &+= 1
            // Files still being read belong to the sheet that just closed.
            composer.cancelAttachmentImport()
        }
    }
    let composer: ComposerViewModel
    /// The open composer's account was removed while it held text: the platform asks whether
    /// to discard it. Keeping it leaves it open with Send blocked and the reason shown.
    @Published var asksToDiscardRemovedAccountDraft = false
    /// The thread the reader shows. Settable so a view can connect it once its own state exists.
    var thread: @MainActor () -> ThreadDetailModel?

    private let undoSend: UndoSendCoordinator
    private let policy: ComposerPresentationPolicy
    private let aiAssistant: ThreadAIAssistantViewModel
    private let ownAddresses: @MainActor () -> Set<String>
    private let loadForwardAttachments: (String) async -> (attachments: [DraftAttachment], unavailable: [String])
    /// Advances on every `request(_:)`. A request that awaits (Forward loading the original's
    /// files) re-checks it afterwards, so a newer request's draft is never overwritten.
    private var requestGeneration: UInt64 = 0
    /// Advances each time the composer closes, so work that finishes after a close (an AI
    /// draft) never lands in the hidden composer.
    private var closeCount: UInt64 = 0

    init(
        composer: ComposerViewModel,
        undoSend: UndoSendCoordinator,
        policy: ComposerPresentationPolicy,
        aiAssistant: ThreadAIAssistantViewModel,
        thread: @escaping @MainActor () -> ThreadDetailModel?,
        ownAddresses: @escaping @MainActor () -> Set<String> = { [] },
        loadForwardAttachments: @escaping (String) async -> (attachments: [DraftAttachment], unavailable: [String]) = { _ in ([], []) }
    ) {
        self.isPresented = false
        self.composer = composer
        self.undoSend = undoSend
        self.policy = policy
        self.aiAssistant = aiAssistant
        self.thread = thread
        self.ownAddresses = ownAddresses
        self.loadForwardAttachments = loadForwardAttachments
    }

    /// The device's accounts changed. An open composer whose account was removed closes when
    /// it holds nothing, and asks first when it does.
    func accountsChanged() {
        guard isPresented, composer.fromAccountWasRemoved() else { return }
        if composer.hasDraftText {
            asksToDiscardRemovedAccountDraft = true
        } else {
            isPresented = false
        }
    }

    func discardRemovedAccountDraft() {
        asksToDiscardRemovedAccountDraft = false
        isPresented = false
    }

    func request(_ request: ComposeRequest) async -> ComposePresentation {
        requestGeneration &+= 1
        switch request {
        case .new:
            return presentNewMessage()
        case let .reply(messageID):
            return presentReply(sourceMessageID: messageID)
        case let .replyAll(messageID):
            return presentReplyAll(sourceMessageID: messageID)
        case let .forward(messageID):
            return await presentForward(sourceMessageID: messageID)
        case let .aiDraftReply(messageID, bodyMarkdown, recipient):
            return presentAIDraftReply(
                sourceMessageID: messageID,
                bodyMarkdown: bodyMarkdown,
                recipient: recipient,
                in: thread()
            )
        case let .restore(snapshot):
            return restoreComposer(from: snapshot)
        case .undoLatestSend:
            guard let snapshot = undoSend.undoLatestSend() else { return .none }
            return restoreComposer(from: snapshot)
        case .restoreFailedSend:
            guard let snapshot = undoSend.restoreFailedSend() else { return .none }
            return restoreComposer(from: snapshot)
        }
    }

    /// ✦ Draft with AI inside an open composer: drafts a reply to the composer's own reply
    /// message (not the mailbox selection) and fills only the body, so recipients, subject,
    /// attachments and a saved draft's identity are kept. Nothing changes when it fails, when
    /// the composer moves on, or when it closes while the AI writes.
    func draftBodyWithAI() async -> ComposerAIBodyResult {
        guard let context = composer.replyContext else {
            return .failed("Draft with AI needs a message to reply to.")
        }
        guard !composer.isDraftingAIBody else {
            return .failed("Draft with AI is already writing this message.")
        }
        composer.isDraftingAIBody = true
        defer { composer.isDraftingAIBody = false }
        let generation = requestGeneration
        let closes = closeCount
        let previousBody = composer.bodyMarkdown
        let draft: Draft
        do {
            draft = try await aiAssistant.draftReplyBody(for: context.sourceMessageID)
        } catch let failure as ComposerAIDraftFailure {
            return .failed(failure.message)
        } catch {
            return .failed("Reply draft unavailable. Try again.")
        }
        guard closes == closeCount else {
            return .failed("The message was closed while the AI was writing, so its draft wasn't used.")
        }
        guard generation == requestGeneration,
              composer.replyContext == context,
              composer.bodyMarkdown == previousBody,
              !composer.isSendScheduled else {
            return .failed("The message changed while the AI was writing, so its draft wasn't used.")
        }
        composer.applyAIDraftBody(draft.bodyMarkdown ?? draft.bodyPlain)
        return .filled(previousBody: previousBody)
    }

    /// The message a reply answers: the selected one when `thread` has it, else its last message.
    static func replySourceMessageID(selectedMessageID: String?, in thread: ThreadDetailModel) -> String? {
        let sourceMessage = selectedMessageID.flatMap { selectedID in
            thread.messages.first(where: { $0.id == selectedID })
        } ?? thread.messages.last
        return sourceMessage?.id
    }

    static func replyContext(
        for message: ThreadMessageModel,
        subject: String,
        recipient: String?,
        cc: [String] = []
    ) -> ComposerReplyContext? {
        guard let resolvedRecipient = recipient ?? SourceVerifiedReplyTarget.recipient(for: message) else {
            return nil
        }
        return ComposerReplyContext(
            sourceThreadID: message.sourceThreadID,
            sourceMessageID: MessageID(message.id),
            rfcMessageID: message.rfcMessageID,
            sourceInReplyTo: message.inReplyTo,
            references: message.references,
            recipient: resolvedRecipient,
            subject: subject,
            senderName: message.senderDisplayName ?? message.sender,
            dateLabel: message.dateLabel,
            quotedBody: message.safeBodyText,
            cc: cc
        )
    }

    /// The reply-all recipients for a message: the reply target (honouring
    /// `Reply-To`) as `to`, and everyone else on the message (`to` + `cc`,
    /// minus the sender, the primary recipient, and `ownAddresses`) as `cc`.
    /// Shared by the embedded coordinator (`ThreadMessageModel`) and the
    /// macOS runtime window path (`MessageSummary`), which both reduce to
    /// these primitives so the address algorithm lives in exactly one place.
    static func replyAllRecipients(
        sender: String,
        replyTo: String?,
        to: [String],
        cc: [String],
        ownAddresses: Set<String>
    ) -> (to: String, cc: [String]) {
        let primary = ReplyAddressPolicy.recipient(
            replyTo: replyTo.map { EmailAddress($0) },
            from: EmailAddress(sender)
        )?.rawValue ?? sender
        var seen: Set<String> = [primary.lowercased(), sender.lowercased()]
        seen.formUnion(ownAddresses.map { $0.lowercased() })
        var result: [String] = []
        for address in to + cc {
            let key = MailSenderDisplay.address(address).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(MailSenderDisplay.address(address))
        }
        return (primary, result)
    }

    static func replyAllRecipients(message: ThreadMessageModel, ownAddresses: Set<String>) -> (to: String, cc: [String]) {
        replyAllRecipients(
            sender: message.sender,
            replyTo: message.replyTo,
            to: message.to,
            cc: message.cc,
            ownAddresses: ownAddresses
        )
    }

    private func presentReplyAll(sourceMessageID: String) -> ComposePresentation {
        if policy == .runtimeWindow {
            return .window(.replyAll(sourceMessageID: sourceMessageID))
        }
        guard let thread = thread(),
              let sourceMessage = thread.messages.first(where: { $0.id == sourceMessageID })
        else { return .none }
        let recipients = Self.replyAllRecipients(message: sourceMessage, ownAddresses: ownAddresses())
        guard let context = Self.replyContext(
            for: sourceMessage,
            subject: thread.subject,
            recipient: recipients.to,
            cc: recipients.cc
        ) else { return .none }
        composer.prepareReplyAll(context: context)
        if let request = policy.windowRequest(
            runtimeRequest: .replyAll(sourceMessageID: sourceMessage.id),
            snapshot: composer.restorationSnapshot
        ) {
            return .window(request)
        }
        return presentEmbedded()
    }

    /// The forward context for a message. Shared by the embedded coordinator
    /// (`ThreadMessageModel`) and the macOS runtime window path (`MessageSummary`),
    /// which both reduce to these primitives so the two never quote differently.
    static func forwardContext(
        sourceMessageID: String,
        subject: String,
        senderDisplayName: String?,
        sender: String,
        dateLabel: String,
        quotedBody: String
    ) -> ComposerForwardContext {
        ComposerForwardContext(
            sourceMessageID: MessageID(sourceMessageID),
            subject: subject,
            senderName: MailSenderDisplay.name(displayName: senderDisplayName, address: sender),
            senderAddress: MailSenderDisplay.address(sender),
            dateLabel: dateLabel,
            quotedBody: quotedBody
        )
    }

    static func forwardContext(for message: ThreadMessageModel, subject: String) -> ComposerForwardContext {
        forwardContext(
            sourceMessageID: message.id,
            subject: subject,
            senderDisplayName: message.senderDisplayName,
            sender: message.sender,
            dateLabel: message.dateLabel,
            quotedBody: message.safeBodyText
        )
    }

    private func presentForward(sourceMessageID: String) async -> ComposePresentation {
        if policy == .runtimeWindow {
            return .window(.forward(sourceMessageID: sourceMessageID))
        }
        guard let thread = thread(),
              let sourceMessage = thread.messages.first(where: { $0.id == sourceMessageID })
        else { return .none }
        let context = Self.forwardContext(for: sourceMessage, subject: thread.subject)
        let generation = requestGeneration
        let files = await loadForwardAttachments(sourceMessage.id)
        // Another compose request arrived while the files loaded: its draft wins. (The macOS
        // composer window drops late files the same way, through `attachForwardedFiles`.)
        guard generation == requestGeneration else { return .none }
        composer.prepareForward(context: context, attachments: files.attachments, unavailable: files.unavailable)
        if let request = policy.windowRequest(
            runtimeRequest: .forward(sourceMessageID: sourceMessage.id),
            snapshot: composer.restorationSnapshot
        ) {
            return .window(request)
        }
        return presentEmbedded()
    }

    private func presentNewMessage() -> ComposePresentation {
        if policy == .snapshotWindow {
            composer.prepareNewMessage()
        }
        if let request = policy.windowRequest(
            runtimeRequest: .newMessage,
            snapshot: composer.restorationSnapshot
        ) {
            return .window(request)
        }
        composer.prepareNewMessage()
        return presentEmbedded()
    }

    private func restoreComposer(from snapshot: ComposerRestoreSnapshot) -> ComposePresentation {
        if policy == .snapshotWindow {
            composer.restore(from: snapshot)
        }
        if let request = policy.windowRequest(
            runtimeRequest: .restore(snapshot),
            snapshot: composer.restorationSnapshot
        ) {
            return .window(request)
        }
        composer.restore(from: snapshot)
        return presentEmbedded()
    }

    private func presentReply(sourceMessageID: String) -> ComposePresentation {
        if policy == .runtimeWindow {
            return .window(.reply(sourceMessageID: sourceMessageID))
        }
        guard let thread = thread(),
              let sourceMessage = thread.messages.first(where: { $0.id == sourceMessageID }),
              let context = Self.replyContext(for: sourceMessage, subject: thread.subject, recipient: nil)
        else { return .none }
        composer.prepareReply(context: context)
        if let request = policy.windowRequest(
            runtimeRequest: .reply(sourceMessageID: sourceMessage.id),
            snapshot: composer.restorationSnapshot
        ) {
            return .window(request)
        }
        return presentEmbedded()
    }

    /// Opens an AI-written reply in the composer: a runtime window request, or the prepared
    /// composer for `thread` (which must contain the source message).
    private func presentAIDraftReply(
        sourceMessageID: String,
        bodyMarkdown: String,
        recipient: String,
        in thread: ThreadDetailModel?
    ) -> ComposePresentation {
        if policy == .runtimeWindow {
            return .window(
                .aiReply(
                    sourceMessageID: sourceMessageID,
                    bodyMarkdown: bodyMarkdown,
                    recipient: recipient
                )
            )
        }
        guard let thread,
              let sourceMessage = thread.messages.first(where: { $0.id == sourceMessageID }),
              let context = Self.replyContext(
                  for: sourceMessage,
                  subject: thread.subject,
                  recipient: recipient
              ) else { return .none }
        composer.prepareAIDraftReply(
            context: context,
            bodyMarkdown: bodyMarkdown
        )
        if let request = policy.windowRequest(
            runtimeRequest: .aiReply(
                sourceMessageID: sourceMessageID,
                bodyMarkdown: bodyMarkdown,
                recipient: recipient
            ),
            snapshot: composer.restorationSnapshot
        ) {
            return .window(request)
        }
        return presentEmbedded()
    }

    private func presentEmbedded() -> ComposePresentation {
        isPresented = true
        return .embedded
    }
}
