import Foundation

public struct AccountDeviceApprovalContext: Equatable, Sendable {
    public let pendingID: String
    public let offerDigest: Data
    public let responseDigest: Data
    public let generation: UInt64
    public let matchingCode: String
    public let expiresAt: Date

    public init(pendingID: String, offerDigest: Data, responseDigest: Data, generation: UInt64, matchingCode: String, expiresAt: Date) throws {
        guard !pendingID.isEmpty, pendingID.utf8.count <= 128, offerDigest.count == 32, responseDigest.count == 32, generation > 0, matchingCode.utf8.count == 6, matchingCode.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw AccountRuntimeError.untrustedResponse }
        self.pendingID = pendingID; self.offerDigest = offerDigest; self.responseDigest = responseDigest; self.generation = generation; self.matchingCode = matchingCode; self.expiresAt = expiresAt
    }
}

public actor AccountDeviceApprovalCapability {
    public typealias Operation = @Sendable () async throws -> Void
    public nonisolated let id = UUID()
    public nonisolated let context: AccountDeviceApprovalContext
    private let approveOperation: Operation
    private let cancelOperation: @Sendable () async -> Void
    private var consumed = false

    public init(context: AccountDeviceApprovalContext, approve: @escaping Operation, cancel: @escaping @Sendable () async -> Void) {
        self.context = context; approveOperation = approve; cancelOperation = cancel
    }
    public func approve() async throws { guard !consumed else { throw AccountRuntimeError.cancelled }; consumed = true; try await approveOperation() }
    public func cancel() async { guard !consumed else { return }; consumed = true; await cancelOperation() }
}
