import Combine
import Foundation
import PlainpostCore
import PlainpostDB

public struct ComposerRestoreSnapshot: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case to
        case cc
        case bcc
        case subject
        case bodyMarkdown
        case attachments
        case presentationMode
        case replyContext
        case includesQuotedHistory
        case draftID
        case fromAccountID
    }

    public let to: String
    public let cc: String
    public let bcc: String
    public let subject: String
    public let bodyMarkdown: String
    public let attachments: [DraftAttachment]
    public let presentationMode: ComposerPresentationMode
    public let replyContext: ComposerReplyContext?
    public let includesQuotedHistory: Bool
    public let draftID: String?
    /// The account the draft goes out from, when the composer chose it.
    public let fromAccountID: AccountID?

    public init(
        to: String,
        cc: String,
        bcc: String,
        subject: String,
        bodyMarkdown: String,
        attachments: [DraftAttachment] = [],
        presentationMode: ComposerPresentationMode,
        replyContext: ComposerReplyContext?,
        includesQuotedHistory: Bool,
        draftID: String? = nil,
        fromAccountID: AccountID? = nil
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyMarkdown = bodyMarkdown
        self.attachments = attachments
        self.presentationMode = presentationMode
        self.replyContext = replyContext
        self.includesQuotedHistory = includesQuotedHistory
        self.draftID = draftID
        self.fromAccountID = fromAccountID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            to: try container.decode(String.self, forKey: .to),
            cc: try container.decode(String.self, forKey: .cc),
            bcc: try container.decode(String.self, forKey: .bcc),
            subject: try container.decode(String.self, forKey: .subject),
            bodyMarkdown: try container.decode(String.self, forKey: .bodyMarkdown),
            attachments: try container.decodeIfPresent([DraftAttachment].self, forKey: .attachments) ?? [],
            presentationMode: try container.decode(ComposerPresentationMode.self, forKey: .presentationMode),
            replyContext: try container.decodeIfPresent(ComposerReplyContext.self, forKey: .replyContext),
            includesQuotedHistory: try container.decode(Bool.self, forKey: .includesQuotedHistory),
            draftID: try container.decodeIfPresent(String.self, forKey: .draftID),
            fromAccountID: try container.decodeIfPresent(AccountID.self, forKey: .fromAccountID)
        )
    }

}

public enum UndoSendSnackbarState: Equatable {
    case pending(snapshot: ComposerRestoreSnapshot, deadline: Date)
    case sending
    case sent
    /// Accepted for the Sync Node but not sent yet ("Queued for Sync Node").
    case queuedForSyncNode
    case uncertain
    case failed(snapshot: ComposerRestoreSnapshot)
}

@MainActor
public final class UndoSendCoordinator: ObservableObject {
    @Published public private(set) var snackbarState: UndoSendSnackbarState?

    private let sender: any DirectComposerSending
    private let delay: Duration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var deliveryTask: Task<Void, Never>?
    private var confirmationClearTask: Task<Void, Never>?
    private var uncertainDraftKeys: Set<String>
    /// Read when Send is tapped (the draft's account source as of then), and handed to
    /// `validateBeforeSend` when the Undo window ends.
    private let sourceAtSchedule: @MainActor (Draft) -> Int64?
    /// Checked when the Undo window ends, just before delivery: a failure keeps the draft for
    /// the user instead of sending it (its From account was removed or changed source since
    /// Send was tapped).
    private let validateBeforeSend: @Sendable (Draft, Int64?) throws -> Void
    private let didSend: @MainActor (Draft) -> Void

    public init(
        sender: any DirectComposerSending,
        uncertainIntents: [DirectSendIntent] = [],
        delay: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        sourceAtSchedule: @escaping @MainActor (Draft) -> Int64? = { _ in nil },
        validateBeforeSend: @escaping @Sendable (Draft, Int64?) throws -> Void = { _, _ in },
        didSend: @escaping @MainActor (Draft) -> Void = { _ in }
    ) {
        self.sourceAtSchedule = sourceAtSchedule
        self.validateBeforeSend = validateBeforeSend
        self.didSend = didSend
        self.sender = sender
        self.delay = delay
        self.now = now
        self.sleep = sleep
        uncertainDraftKeys = Set(uncertainIntents.map { Self.draftKey(id: $0.draftID, hash: $0.contentHash) })
        snackbarState = uncertainDraftKeys.isEmpty ? nil : .uncertain
    }

    deinit {
        deliveryTask?.cancel()
        confirmationClearTask?.cancel()
    }

    public var isSendPending: Bool {
        Self.isSendPending(snackbarState)
    }

    public var hasUncertainSend: Bool {
        if case .uncertain = snackbarState { return true }
        return false
    }

    private nonisolated static func draftKey(id: DraftID, hash: String) -> String {
        "\(id.rawValue):\(hash)"
    }

    /// Publishes `isSendPending` whenever it changes, starting with the current
    /// value. Releasing the coordinator while a send is pending cancels that
    /// delivery, so owners observe this to keep it alive until it settles.
    public var sendPendingPublisher: AnyPublisher<Bool, Never> {
        $snackbarState.map(Self.isSendPending).removeDuplicates().eraseToAnyPublisher()
    }

    private nonisolated static func isSendPending(_ state: UndoSendSnackbarState?) -> Bool {
        switch state {
        case .pending, .sending:
            true
        case .none, .sent, .queuedForSyncNode, .uncertain, .failed:
            false
        }
    }

    @discardableResult
    public func schedule(draft: Draft, restoring snapshot: ComposerRestoreSnapshot) -> Bool {
        if uncertainDraftKeys.contains(Self.draftKey(id: draft.id, hash: draft.contentHash)) {
            snackbarState = .uncertain
            return false
        }
        guard !isSendPending else {
            return false
        }
        confirmationClearTask?.cancel()
        snackbarState = .pending(snapshot: snapshot, deadline: now().addingTimeInterval(delay.timeInterval))
        let scheduledSource = sourceAtSchedule(draft)

        deliveryTask = Task.detached { [weak self, sender, delay, sleep, validateBeforeSend] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            guard await self.beginDelivery() else {
                return
            }

            do {
                try validateBeforeSend(draft, scheduledSource)
                let result = try await sender.send(draft: draft)
                guard !Task.isCancelled else {
                    return
                }
                await self.recordSuccessfulDelivery(queued: result.isQueuedForSyncNode, draft: draft)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await self.recordFailedDelivery(snapshot, draft: draft, error: error)
            }
        }
        return true
    }

    public func undoLatestSend() -> ComposerRestoreSnapshot? {
        guard case let .pending(snapshot, deadline) = snackbarState, now() < deadline else {
            return nil
        }
        deliveryTask?.cancel()
        deliveryTask = nil
        confirmationClearTask?.cancel()
        confirmationClearTask = nil
        snackbarState = nil
        return snapshot
    }

    /// True while a delivery failure waits for the user to reopen its draft
    /// or dismiss it.
    public var hasFailedSend: Bool {
        if case .failed = snackbarState { return true }
        return false
    }

    /// Acknowledges a delivery failure without reopening its draft.
    public func dismissFailedSend() {
        guard hasFailedSend else { return }
        snackbarState = nil
    }

    public func restoreFailedSend() -> ComposerRestoreSnapshot? {
        guard case let .failed(snapshot) = snackbarState else {
            return nil
        }
        snackbarState = nil
        return snapshot
    }

    public static func preview(state: UndoSendSnackbarState) -> UndoSendCoordinator {
        let coordinator = UndoSendCoordinator(sender: UnconfiguredDirectComposerSender())
        coordinator.snackbarState = state
        return coordinator
    }

    private func scheduleSentConfirmationClear() {
        confirmationClearTask?.cancel()
        confirmationClearTask = Task.detached { [weak self, delay, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            await self.clearSentConfirmation()
        }
    }

    private func beginDelivery() -> Bool {
        guard case .pending = snackbarState else {
            return false
        }
        snackbarState = .sending
        return true
    }

    private func recordSuccessfulDelivery(queued: Bool, draft: Draft) {
        guard !Task.isCancelled else {
            return
        }
        didSend(draft)
        deliveryTask = nil
        snackbarState = queued ? .queuedForSyncNode : .sent
        scheduleSentConfirmationClear()
    }

    private func recordFailedDelivery(_ snapshot: ComposerRestoreSnapshot, draft: Draft, error: Error) {
        guard !Task.isCancelled else {
            return
        }
        deliveryTask = nil
        if case DirectSendIntentError.alreadySubmitted(.uncertain) = error {
            uncertainDraftKeys.insert(Self.draftKey(id: draft.id, hash: draft.contentHash))
            snackbarState = .uncertain
        } else if case DirectSendIntentError.alreadySubmitted(.submitting) = error {
            uncertainDraftKeys.insert(Self.draftKey(id: draft.id, hash: draft.contentHash))
            snackbarState = .uncertain
        } else if (error as? SMTPClientError) == .deliveryUncertain
                    || error is PostSMTPPersistenceError {
            uncertainDraftKeys.insert(Self.draftKey(id: draft.id, hash: draft.contentHash))
            snackbarState = .uncertain
        } else {
            snackbarState = .failed(snapshot: snapshot)
        }
    }

    private func clearSentConfirmation() {
        guard !Task.isCancelled, snackbarState == .sent || snackbarState == .queuedForSyncNode else {
            return
        }
        confirmationClearTask = nil
        snackbarState = nil
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

public extension ComposerRestoreSnapshot {
    /// Reopens a draft saved in the composer. Its body already holds the quote,
    /// so nothing is quoted again; a reply keeps its In-Reply-To and References.
    init(savedDraft draft: Draft, sourceMessageID: MessageID?) {
        let replyContext = draft.inReplyTo.map { inReplyTo in
            ComposerReplyContext(
                sourceThreadID: draft.sourceThreadID,
                sourceMessageID: sourceMessageID ?? MessageID(""),
                rfcMessageID: inReplyTo,
                references: draft.references,
                recipient: draft.to.first?.rawValue ?? "",
                subject: draft.subject,
                senderName: "",
                dateLabel: "",
                quotedBody: ""
            )
        }
        self.init(
            to: draft.to.map(\.rawValue).joined(separator: ", "),
            cc: draft.cc.map(\.rawValue).joined(separator: ", "),
            bcc: draft.bcc.map(\.rawValue).joined(separator: ", "),
            subject: draft.subject,
            bodyMarkdown: draft.bodyMarkdown ?? MarkdownEmailRenderer.canonicalize(draft.bodyPlain),
            attachments: draft.attachments,
            presentationMode: replyContext.map { .reply(recipient: $0.recipient, subject: draft.subject) } ?? .newMessage,
            replyContext: replyContext,
            includesQuotedHistory: false,
            draftID: draft.id.rawValue,
            fromAccountID: draft.accountID
        )
    }
}
