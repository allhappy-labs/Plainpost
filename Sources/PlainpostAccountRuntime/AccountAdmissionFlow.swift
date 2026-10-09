import Combine
import Foundation

/// App-owned lifecycle adapter around the protocol-valid pending controller.
/// It keeps roots testable without duplicating rendezvous or trust logic.
@MainActor
public struct AccountPendingAdmissionFlow {
    public let states: AnyPublisher<AccountAdmissionController.State, Never>
    private let startOperation: (Date) -> Void
    private let cancelOperation: () -> Void

    public init(
        states: AnyPublisher<AccountAdmissionController.State, Never>,
        start: @escaping (Date) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.states = states
        startOperation = start
        cancelOperation = cancel
    }

    public init(controller: AccountAdmissionController) {
        self.init(
            states: controller.$state.eraseToAnyPublisher(),
            start: { controller.start(now: $0) },
            cancel: { controller.cancel() }
        )
    }

    public func start(now: Date) { startOperation(now) }
    public func cancel() { cancelOperation() }
}

/// App-owned lifecycle adapter around the protocol-valid active-owner
/// controller. Views receive only bounded prompts and a single-use capability.
@MainActor
public struct AccountActiveAdmissionFlow {
    public let states: AnyPublisher<AccountActiveAdmissionController.State, Never>
    private let refreshOperation: () -> Void
    private let beginOperation: (AccountActiveAdmissionController.PendingPrompt) -> Void
    private let capabilityOperation: () -> AccountDeviceApprovalCapability?
    private let authorizeOperation: (String, Data) async throws -> AccountDeviceApprovalCapability
    private let cancelOperation: () -> Void

    public init(
        states: AnyPublisher<AccountActiveAdmissionController.State, Never>,
        refresh: @escaping () -> Void,
        begin: @escaping (AccountActiveAdmissionController.PendingPrompt) -> Void,
        currentApprovalCapability: @escaping () -> AccountDeviceApprovalCapability?,
        authorizeCurrentApproval: @escaping (String, Data) async throws -> AccountDeviceApprovalCapability = { _, _ in throw AccountRuntimeError.untrustedResponse },
        cancel: @escaping () -> Void
    ) {
        self.states = states
        refreshOperation = refresh
        beginOperation = begin
        capabilityOperation = currentApprovalCapability
        authorizeOperation = authorizeCurrentApproval
        cancelOperation = cancel
    }

    public init(controller: AccountActiveAdmissionController) {
        self.init(
            states: controller.$state.eraseToAnyPublisher(),
            refresh: { controller.refresh() },
            begin: { controller.begin($0) },
            currentApprovalCapability: { controller.currentApprovalCapability() },
            authorizeCurrentApproval: { try await controller.authorizeCurrentApproval(identityToken: $0, appleNonce: $1) },
            cancel: { controller.cancel() }
        )
    }

    public func refresh() { refreshOperation() }
    public func begin(_ prompt: AccountActiveAdmissionController.PendingPrompt) { beginOperation(prompt) }
    public func currentApprovalCapability() -> AccountDeviceApprovalCapability? { capabilityOperation() }
    public func authorizeCurrentApproval(identityToken: String, appleNonce: Data) async throws -> AccountDeviceApprovalCapability { try await authorizeOperation(identityToken, appleNonce) }
    public func cancel() { cancelOperation() }
}
