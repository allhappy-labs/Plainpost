import PlainpostAccountProtocol
import PlainpostAccountRuntime
import SwiftUI

extension AccountPlatform {
    /// User-facing device kind. `rawValue` is a wire value and must never be
    /// shown in UI copy.
    public var deviceDisplayName: String {
        switch self {
        case .macos: "Mac"
        case .ios: "iPhone or iPad"
        case .syncNode: "Sync Node"
        }
    }
}

extension AccountActiveAdmissionController.FailureReason {
    public var userMessage: String {
        switch self {
        case .expired: "This sign-in request expired. Start again on the new device."
        case .unreachable: "Couldn't reach the new device. Check your connection and try again."
        case .other: "Couldn't start the review for the new device."
        }
    }
}

/// What the active-account overlay shows for another device awaiting approval.
public enum PendingDeviceApprovalPresentation: Equatable, Sendable {
    public typealias Prompt = AccountActiveAdmissionController.PendingPrompt
    public typealias FailureReason = AccountActiveAdmissionController.FailureReason

    case hidden
    case review(Prompt)
    case contacting(Prompt)
    /// `retry` is nil when the request can no longer be approved.
    case failed(FailureReason, retry: Prompt?)

    public static let contactingMessage = "Contacting the new device…"

    public static func reviewTitle(for prompt: Prompt) -> String {
        "Review new \(prompt.platform.deviceDisplayName)"
    }
}

/// Session-scoped state for the pending-device overlay, shared by the macOS and
/// iOS account roots. It turns controller states and user actions into one
/// bounded presentation, remembers per-request dismissals, and drops requests
/// that can no longer be approved.
public struct PendingDeviceApprovalTracker: Equatable, Sendable {
    public typealias Prompt = AccountActiveAdmissionController.PendingPrompt

    public private(set) var presentation: PendingDeviceApprovalPresentation = .hidden
    private var pending: [Prompt] = []
    private var suppressedRequestIDs: Set<String> = []

    public init() {}

    /// The request a review would start for, or nil when none is actionable.
    public var actionablePrompt: Prompt? {
        switch presentation {
        case .review(let prompt): prompt
        case .failed(_, let retry): retry
        case .hidden, .contacting: nil
        }
    }

    /// The request the overlay is about, including one whose review is in
    /// flight. Nil once the request can no longer be approved.
    public var currentPrompt: Prompt? {
        switch presentation {
        case .review(let prompt), .contacting(let prompt): prompt
        case .failed(_, let retry): retry
        case .hidden: nil
        }
    }

    /// Returns the prompt to begin, or nil when a review is already in flight
    /// or nothing is actionable.
    public mutating func beginReview() -> Prompt? {
        guard let prompt = actionablePrompt else { return nil }
        presentation = .contacting(prompt)
        return prompt
    }

    /// Returns true when the dismissed request was dead and the pending list
    /// should be refreshed.
    public mutating func dismiss() -> Bool {
        let dismissed: Prompt?
        var shouldRefresh = false
        switch presentation {
        case .review(let prompt): dismissed = prompt
        case .failed(.expired, _): dismissed = nil; shouldRefresh = true
        case .failed(_, let retry): dismissed = retry
        case .hidden, .contacting: return false
        }
        if let dismissed { suppressedRequestIDs.insert(dismissed.requestID) }
        showNextPending()
        return shouldRefresh
    }

    public mutating func receive(_ state: AccountActiveAdmissionController.State) {
        switch state {
        case .idle(let prompts):
            pending = prompts
            // Keep a visible failure until the user acts on it.
            if case .failed = presentation { return }
            showNextPending()
        case .awaitingResponse:
            if case .contacting = presentation { return }
            if let prompt = actionablePrompt { presentation = .contacting(prompt) }
        case .awaitingConfirmation:
            break
        case .failed(let reason):
            // Only a review the user started can fail visibly; background list
            // refresh failures keep the current presentation.
            guard case .contacting(let prompt) = presentation else { return }
            if reason == .expired {
                suppressedRequestIDs.insert(prompt.requestID)
                pending.removeAll { $0.requestID == prompt.requestID }
                presentation = .failed(.expired, retry: nil)
            } else {
                presentation = .failed(reason, retry: prompt)
            }
        }
    }

    /// Clears flow-owned state while keeping session-scoped dismissals.
    public mutating func resetFlow() {
        pending = []
        presentation = .hidden
    }

    private mutating func showNextPending() {
        if let next = pending.first(where: { !suppressedRequestIDs.contains($0.requestID) }) {
            presentation = .review(next)
        } else {
            presentation = .hidden
        }
    }
}

/// Floating overlay pill for another device awaiting approval.
public struct PendingDeviceApprovalPill: View {
    private let presentation: PendingDeviceApprovalPresentation
    private let review: () -> Void
    private let dismiss: () -> Void

    public init(
        presentation: PendingDeviceApprovalPresentation,
        review: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.review = review
        self.dismiss = dismiss
    }

    public var body: some View {
        switch presentation {
        case .hidden:
            EmptyView()
        case .review(let prompt):
            HStack(spacing: 8) {
                Button(PendingDeviceApprovalPresentation.reviewTitle(for: prompt), action: review)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("account.pending-device.review")
                dismissButton
            }
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding()
        case .contacting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(PendingDeviceApprovalPresentation.contactingMessage)
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("account.pending-device.contacting")
            .padding()
        case .failed(let reason, let retry):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason.userMessage)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.pending-device.error")
                if retry != nil {
                    Button("Try Again", action: review)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account.pending-device.retry")
                }
                if retry == nil {
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account.pending-device.dismiss")
                } else {
                    dismissButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding()
        }
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Hide this request")
        .accessibilityLabel("Hide this request")
        .accessibilityIdentifier("account.pending-device.dismiss")
    }
}
