import Foundation
import PlainpostCore

/// Status of one section's bulk-action commit: pending (undoable), applying, or done.
public struct AskMailActionReceipt: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case pending, applying, done(applied: Int) }
    public var phase: Phase
    public var text: String
    public var canUndo: Bool { phase == .pending }
}

/// Applies Ask Mail bulk actions (Mark read / Mark unread / Archive) after a grace window so
/// Undo can cancel before anything actually happens. Keyed by "\(blockID)/\(sectionID)".
@MainActor
public final class AskMailActionCoordinator: ObservableObject {
    @Published public private(set) var receipts: [String: AskMailActionReceipt] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Ownership token per key: a task may only touch `receipts`/`tasks` for its key while its
    /// own token still matches, so a superseded pending action can't clobber the one that replaced it.
    private var tokens: [String: UUID] = [:]
    private let graceDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let perform: @MainActor (InboxMailAction, MessageID) async -> Bool
    private let onBatchSettled: @MainActor () -> Void

    /// - Parameter onBatchSettled: called once after a section's messages have all been attempted
    ///   (whether or not some failed); never for an action that was undone or replaced.
    public init(graceDelay: Duration = .seconds(5),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                perform: @escaping @MainActor (InboxMailAction, MessageID) async -> Bool,
                onBatchSettled: @escaping @MainActor () -> Void = {}) {
        self.graceDelay = graceDelay
        self.sleep = sleep
        self.perform = perform
        self.onBatchSettled = onBatchSettled
    }

    /// Schedules `action` for each section after the grace delay. Re-applying to a key that is
    /// still `.pending` cancels and replaces that action (nothing ran yet). Re-applying to a key
    /// that is already `.applying` is refused for that section — the running action and its
    /// receipt are left untouched.
    ///
    /// - Returns: `true` if every section was scheduled; `false` if at least one section was
    ///   refused because its key was already `.applying`.
    @discardableResult
    public func apply(_ action: AskMailBulkAction, blockID: String,
                       sections: [(id: String, noun: String, messageIDs: [MessageID], total: Int)]) -> Bool {
        var allScheduled = true
        for section in sections where !section.messageIDs.isEmpty {
            let key = "\(blockID)/\(section.id)"
            if receipts[key]?.phase == .applying {
                allScheduled = false
                continue
            }
            tasks[key]?.cancel()
            let token = UUID()
            tokens[key] = token
            receipts[key] = AskMailActionReceipt(
                phase: .pending, text: Self.text(action, count: section.messageIDs.count, total: section.total, noun: section.noun))
            tasks[key] = Task { [weak self, graceDelay, sleep] in
                do { try await sleep(graceDelay) } catch { return }
                guard let self, !Task.isCancelled, self.tokens[key] == token, self.receipts[key]?.phase == .pending else { return }
                self.receipts[key]?.phase = .applying
                var applied = 0
                for id in section.messageIDs where await self.perform(Self.inboxAction(action), id) { applied += 1 }
                self.onBatchSettled()
                guard self.tokens[key] == token else { return }
                self.receipts[key] = AskMailActionReceipt(
                    phase: .done(applied: applied),
                    text: Self.doneText(action, applied: applied, attempted: section.messageIDs.count, total: section.total, noun: section.noun))
                self.tasks[key] = nil
            }
        }
        return allScheduled
    }

    public func undo(blockID: String, sectionID: String) {
        let key = "\(blockID)/\(sectionID)"
        guard receipts[key]?.canUndo == true else { return }
        tasks[key]?.cancel()
        tasks[key] = nil
        tokens[key] = nil
        receipts[key] = nil
    }

    /// New conversation: forget finished receipts. Pending/applying actions keep running to
    /// completion even if the panel closes, so their tasks and receipts are left untouched.
    public func reset() {
        receipts = receipts.filter { tasks[$0.key] != nil }
    }

    /// Test hook: wait for every in-flight commit task to finish.
    func waitForIdle() async { for task in Array(tasks.values) { await task.value } }

    private static func inboxAction(_ action: AskMailBulkAction) -> InboxMailAction {
        switch action {
        case .markRead: .markRead
        case .markUnread: .markUnread
        case .archive: .archive
        }
    }

    private static let singularNouns: [String: String] = [
        "notifications": "notification", "newsletters": "newsletter", "receipts": "receipt",
        "messages": "message", "invitations": "invitation",
    ]

    /// The section noun for `count` messages: singular for exactly one when known, else as given.
    static func noun(_ noun: String, count: Int) -> String {
        count == 1 ? singularNouns[noun] ?? noun : noun
    }

    private static func text(_ action: AskMailBulkAction, count: Int, total: Int, noun rawNoun: String) -> String {
        let amount = count < total ? "\(count) of \(total)" : "\(count)"
        // "1 of 3 notifications" stays plural; only a bare "1" takes the singular.
        let noun = count < total ? rawNoun : noun(rawNoun, count: count)
        switch action {
        case .markRead: return "Marked \(amount) \(noun) read"
        case .markUnread: return "Marked \(amount) \(noun) unread"
        case .archive: return "Archived \(amount) \(noun)"
        }
    }

    /// The done receipt's text: the usual "{n}[ of total] {noun}[ read]" copy, with
    /// " · {n} failed" appended when some of the attempted messages could not be applied.
    private static func doneText(_ action: AskMailBulkAction, applied: Int, attempted: Int, total: Int, noun: String) -> String {
        let base = text(action, count: applied, total: total, noun: noun)
        let failed = attempted - applied
        return failed > 0 ? "\(base) · \(failed) failed" : base
    }
}
