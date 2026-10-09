import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostLocalAPI
import PlainpostOperationRuntime
import PlainpostOperations

public struct LocalAPISendParameters: Codable, Sendable {
    public let draftID: String
    public let expectedHash: String
    public let idempotencyKey: String

    public init(draftID: String, expectedHash: String, idempotencyKey: String) {
        self.draftID = draftID
        self.expectedHash = expectedHash
        self.idempotencyKey = idempotencyKey
    }
}

public enum LocalAPIDeliveryState: String, Codable, Equatable, Sendable {
    case sent
    case failed
    case deliveryUncertain
    /// A Node-backed account's reply was queued for the Sync Node (or
    /// admitted and unfinished): not sent yet, and never resent.
    case waitingForNode

    /// The state of a finished approved-delivery job: a job that routed the
    /// send through the mail-intent journal completes while the send request
    /// may still be `sending` (queued) or later settle.
    public static func completedDelivery(requestStatus: SendRequestStatus) -> LocalAPIDeliveryState {
        switch requestStatus {
        case .sent: .sent
        case .failed, .cancelled, .denied, .expired: .failed
        case .deliveryUncertain: .deliveryUncertain
        case .sending, .approved, .pending: .waitingForNode
        }
    }
}

public struct LocalAPIDeliveryResult: Codable, Equatable, Sendable {
    public let requestID: String
    public let jobID: String
    public let state: LocalAPIDeliveryState

    public init(requestID: String, jobID: String, state: LocalAPIDeliveryState) {
        self.requestID = requestID
        self.jobID = jobID
        self.state = state
    }
}

public protocol BrowserReplyDelivering: Sendable {
    func send(draftID: String, expectedHash: String, idempotencyKey: String) async throws
        -> LocalAPIDeliveryResult
}

public final class ReplySendRoute: LocalAPIRoute, @unchecked Sendable {
    public let method = LocalAPIMethod.replySend

    private let deliveryService: any BrowserReplyDelivering

    public init(deliveryService: any BrowserReplyDelivering) {
        self.deliveryService = deliveryService
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPISendParameters> = try decodeRequest(requestData)
        let result = try await deliveryService.send(
            draftID: request.parameters.draftID,
            expectedHash: request.parameters.expectedHash,
            idempotencyKey: request.parameters.idempotencyKey
        )
        return try encodeSuccess(requestID: requestID, result: result)
    }
}

public actor BrowserReplyDeliveryService: BrowserReplyDelivering {
    private static let idempotencyPrefix = "browser-send:"
    private static let authorizationReason = "Direct reply authorized in Plainpost browser extension"

    private let store: SQLiteMailStore
    private let runtime: LocalOperationRuntime

    public init(store: SQLiteMailStore, runtime: LocalOperationRuntime) {
        self.store = store
        self.runtime = runtime
    }

    public func send(
        draftID: String,
        expectedHash: String,
        idempotencyKey: String
    ) async throws -> LocalAPIDeliveryResult {
        let jobKey = try normalizedJobKey(idempotencyKey)
        let draft = try browserDraft(id: DraftID(draftID), store: store)
        try requireHash(expectedHash, matches: draft)

        let authorization: PlainpostApprovedDeliveryAuthorization
        do {
            authorization = try store.authorizeAndEnqueueApprovedDelivery(
                draftID: draft.id,
                expectedHash: expectedHash,
                actor: browserActor,
                reason: Self.authorizationReason,
                idempotencyKey: jobKey,
                requiredDraftIDPrefix: "drf_browser_"
            )
        } catch PlainpostError.validationFailed(let message) {
            throw LocalAPIRouteError(code: .conflict, safeMessage: message)
        } catch let error as PlainpostError {
            throw routeError(for: error)
        }
        return try await receipt(for: authorization.job)
    }

    private func normalizedJobKey(_ idempotencyKey: String) throws -> String {
        guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 128 else {
            throw LocalAPIRouteError(
                code: .invalidRequest,
                safeMessage: "The idempotency key is invalid."
            )
        }
        return Self.idempotencyPrefix + idempotencyKey
    }

    private func receipt(for job: PlainpostDurableJob) async throws -> LocalAPIDeliveryResult {
        guard job.kind == .approvedDelivery,
              let input = try? JSONDecoder().decode(
                  PlainpostApprovalDecisionInput.self,
                  from: Data(job.payloadJSON.utf8)
              ) else {
            throw LocalAPIRouteError(
                code: .unavailable,
                safeMessage: "The delivery receipt is unavailable."
            )
        }

        let terminal: PlainpostDurableJob
        switch job.state {
        case .completed, .failed, .cancelled, .deliveryUncertain:
            terminal = job
        case .queued, .running, .paused:
            terminal = try await runtime.runUntilTerminalState(jobID: job.id)
        }

        let state: LocalAPIDeliveryState
        switch terminal.state {
        case .completed:
            let request = try? store.sendRequest(id: input.requestID)
            state = request.map { LocalAPIDeliveryState.completedDelivery(requestStatus: $0.status) } ?? .sent
        case .deliveryUncertain:
            state = .deliveryUncertain
        case .failed, .cancelled:
            state = .failed
        case .queued, .running, .paused:
            throw LocalAPIRouteError(
                code: .unavailable,
                safeMessage: "The delivery is not yet complete."
            )
        }
        return LocalAPIDeliveryResult(
            requestID: input.requestID.rawValue,
            jobID: terminal.id,
            state: state
        )
    }
}
