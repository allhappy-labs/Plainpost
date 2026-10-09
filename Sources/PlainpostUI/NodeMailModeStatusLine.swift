import Combine
import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostServiceIPC
import SwiftUI

/// The mailbox header's Sync Node status line. The service owns the Node
/// session, fallback and reconnect; the app only renders the status it
/// reports and holds no Node session for mail.
public enum NodeMailModeStatusLine {
    public static func text(for status: PlainpostNodeMailModeStatus?) -> String? {
        switch status?.state {
        case .connectedDirectly: "Sync Node unavailable — connected directly"
        case .updateRequired: "Update your Sync Node"
        case .reconnectRequired: "Reconnect Sync Node"
        case .connected, .noNode, nil: nil
        }
    }
}

/// A send the service reported as queued ("Queued for Sync Node") that later
/// ended without a confirmed delivery.
public struct NodeSendOutcomeNotice: Equatable, Identifiable, Sendable {
    /// The intent's operation ID.
    public let id: String
    public let message: String
    let settledAt: Date

    /// At most this many outcomes are read per refresh.
    static let loadLimit = 20
    static let noSubject = "(no subject)"

    static func message(for state: MailIntentState, subject: String, reason: DirectDeferralReason? = nil) -> String? {
        switch state {
        case .failed:
            if let reason {
                "Couldn't send “\(subject)”. \(reason.message) It's in Drafts."
            } else {
                "Couldn't send “\(subject)”. It's in Drafts."
            }
        case .unconfirmed, .unconfirmedAfterRemoval:
            "“\(subject)” may have been sent. Check Sent before sending it again."
        case .pending, .dispatching, .admitted, .confirmed, .uncertain:
            nil
        }
    }

    /// Send outcomes settled after `watermark` that no request reported
    /// (the router marks the ones it returned to the user's own request),
    /// oldest first. An indexed, bounded query; a read error yields none and
    /// the next refresh retries.
    static func load(store: SQLiteMailStore, after watermark: Date, afterOperationID: String = "") -> [NodeSendOutcomeNotice] {
        guard let rows = try? store.unreportedSendOutcomes(after: watermark, afterOperationID: afterOperationID, limit: loadLimit)
        else { return [] }
        return rows.compactMap { row in
            let subject = row.draftID
                .flatMap { try? store.draft(id: $0).subject }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? noSubject
            guard let message = message(for: row.state, subject: subject, reason: row.deferralReason) else { return nil }
            return NodeSendOutcomeNotice(id: row.operationID, message: message, settledAt: row.updatedAt)
        }
    }
}

/// Polls the service's `nodeMailModeStatus()` for the status line (every
/// 5 s while the mailbox is visible, and on `.accounts` changes) and reads
/// the shared store's journal for send outcome notices. A dismissed notice
/// never returns: the dismissal watermark is kept in user defaults.
@MainActor
public final class NodeMailModeStatusModel: ObservableObject {
    public static let pollInterval: Duration = .seconds(5)
    static let watermarkKey = "PlainpostNodeSendNoticeWatermark"
    /// The dismissed notice's operation ID: the watermark's tiebreak, so a
    /// second outcome with the same timestamp is still shown.
    static let watermarkIDKey = "PlainpostNodeSendNoticeWatermarkID"

    @Published public private(set) var statusLine: String?
    @Published public private(set) var notice: NodeSendOutcomeNotice?

    private let fetchStatus: (@Sendable () async throws -> PlainpostNodeMailModeStatus)?
    private let store: SQLiteMailStore?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var pending: [NodeSendOutcomeNotice] = []
    private var refreshGeneration: UInt64 = 0

    public init(
        fetchStatus: (@Sendable () async throws -> PlainpostNodeMailModeStatus)?,
        store: SQLiteMailStore?,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetchStatus = fetchStatus
        self.store = store
        self.defaults = defaults
        self.now = now
    }

    /// No service and no store: shows nothing (previews, iOS without a service).
    public static func inactive() -> NodeMailModeStatusModel {
        NodeMailModeStatusModel(fetchStatus: nil, store: nil)
    }

    public func refresh() async {
        await refresh(canPublish: { true })
    }

    func refresh(canPublish: () -> Bool) async {
        guard !Task.isCancelled else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let line: String?
        if let fetchStatus {
            let status = try? await fetchStatus()
            guard !Task.isCancelled, generation == refreshGeneration, canPublish() else { return }
            line = NodeMailModeStatusLine.text(for: status) ?? deferralLine()
        } else {
            guard canPublish() else { return }
            line = deferralLine()
        }
        statusLine = line
        loadNotices()
    }

    /// A change of an account in fallback that is waiting because the mail
    /// server or Google could not be reached: it is retried, then fails. The
    /// line names the account (the most recent one when several wait).
    private func deferralLine() -> String? {
        guard let waiting = (try? store?.pendingDirectDeferrals())?.first else { return nil }
        return "\(waiting.accountName): \(waiting.reason.message) It will retry."
    }

    public func dismissNotice() {
        guard let notice else { return }
        let current = currentWatermark()
        if (notice.settledAt, notice.id) > (current.date, current.id) {
            defaults.set(notice.settledAt.timeIntervalSince1970, forKey: Self.watermarkKey)
            defaults.set(notice.id, forKey: Self.watermarkIDKey)
        }
        let watermark = currentWatermark()
        pending.removeAll { ($0.settledAt, $0.id) <= (watermark.date, watermark.id) }
        self.notice = pending.first
    }

    /// Refreshes every `interval` until the calling task is cancelled (the
    /// view disappeared).
    public func pollWhileVisible(interval: Duration = NodeMailModeStatusModel.pollInterval) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    private func currentWatermark() -> (date: Date, id: String) {
        if defaults.object(forKey: Self.watermarkKey) != nil {
            return (Date(timeIntervalSince1970: defaults.double(forKey: Self.watermarkKey)),
                    defaults.string(forKey: Self.watermarkIDKey) ?? "")
        }
        // First run: outcomes from before this app knew about notices are
        // not replayed.
        let start = now()
        defaults.set(start.timeIntervalSince1970, forKey: Self.watermarkKey)
        defaults.set("", forKey: Self.watermarkIDKey)
        return (start, "")
    }

    private func loadNotices() {
        guard let store else {
            pending = []
            notice = nil
            return
        }
        let watermark = currentWatermark()
        pending = NodeSendOutcomeNotice.load(store: store, after: watermark.date, afterOperationID: watermark.id)
        notice = pending.first
    }
}

/// The status line under the mailbox title: small, secondary, no action.
struct NodeMailModeStatusLineView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(MailDesign.secondaryText)
            .lineLimit(1)
            .accessibilityIdentifier("mailbox.header.sync-node-status")
    }
}

/// A dismissable notice for a send that did not go out as confirmed.
struct NodeSendOutcomeNoticeView: View {
    let notice: NodeSendOutcomeNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mailbox.sync-node.send-notice")
    }
}
