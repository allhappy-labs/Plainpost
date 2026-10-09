import Foundation
import PlainpostCore
import PlainpostSecrets
import PlainpostServiceIPC

public typealias PlainpostForegroundOperationHandler =
    @Sendable (PlainpostForegroundOperation) async throws -> PlainpostForegroundOperationResult
public typealias PlainpostBackgroundJobHandler =
    @Sendable () async throws -> PlainpostBackgroundJobResult
public typealias PlainpostSmartInboxBatchHandler =
    @Sendable (PlainpostSmartInboxBatchRequest) async throws
        -> PlainpostSmartInboxBatchResult
public typealias PlainpostBrowserApprovedReplyHandler =
    @Sendable (String) async throws -> PlainpostBrowserApprovedReplyResult
public typealias PlainpostDraftSyncHandler =
    @Sendable (String, String) async throws -> PlainpostDraftSyncResult

/// The service-owned Node session broker as seen by the XPC listener. The
/// composition maps broker failures to `PlainpostServiceClientError.nodeSession`.
public struct PlainpostNodeSessionHandlers: Sendable {
    public let perform: @Sendable (PlainpostNodeSessionRequest) async throws -> PlainpostNodeSessionResponse
    public let invalidate: @Sendable () async -> Void
    public let identityReadiness: @Sendable () async -> PlainpostNodeSessionIdentityReadiness
    /// The reachability supervisor's status; nil answers `no_node`.
    public let mailModeStatus: (@Sendable () async -> PlainpostNodeMailModeStatus)?

    public init(
        perform: @escaping @Sendable (PlainpostNodeSessionRequest) async throws -> PlainpostNodeSessionResponse,
        invalidate: @escaping @Sendable () async -> Void,
        identityReadiness: @escaping @Sendable () async -> PlainpostNodeSessionIdentityReadiness,
        mailModeStatus: (@Sendable () async -> PlainpostNodeMailModeStatus)? = nil
    ) {
        self.perform = perform
        self.invalidate = invalidate
        self.identityReadiness = identityReadiness
        self.mailModeStatus = mailModeStatus
    }
}

public final class PlainpostServiceListener:
    NSObject,
    NSXPCListenerDelegate
{
    private let lifecycleCoordinator:
        PlainpostServiceLifecycleCoordinator
    private let performForegroundOperation: PlainpostForegroundOperationHandler?
    private let processBackgroundJobs: PlainpostBackgroundJobHandler?
    private let performSmartInboxBatch: PlainpostSmartInboxBatchHandler?
    private let sendBrowserApprovedReply: PlainpostBrowserApprovedReplyHandler?
    private let syncDraftToServer: PlainpostDraftSyncHandler?
    private let nodeSession: PlainpostNodeSessionHandlers?
    private let capabilityForConnection: @Sendable (NSXPCConnection) -> PlainpostClientCapability?
    /// Captured when the service starts, so a reinstall that replaces the
    /// files underneath it cannot make a stale process look current.
    private let serviceIdentity = PlainpostServiceBuildIdentity.of(bundleURL: Bundle.main.bundleURL)

    public init(
        lifecycleCoordinator: PlainpostServiceLifecycleCoordinator,
        performForegroundOperation: PlainpostForegroundOperationHandler? = nil,
        processBackgroundJobs: PlainpostBackgroundJobHandler? = nil,
        performSmartInboxBatch: PlainpostSmartInboxBatchHandler? = nil,
        sendBrowserApprovedReply: PlainpostBrowserApprovedReplyHandler? = nil,
        syncDraftToServer: PlainpostDraftSyncHandler? = nil,
        nodeSession: PlainpostNodeSessionHandlers? = nil
    ) {
        let validator = PlainpostClientValidator()
        self.lifecycleCoordinator = lifecycleCoordinator
        self.performForegroundOperation = performForegroundOperation
        self.processBackgroundJobs = processBackgroundJobs
        self.performSmartInboxBatch = performSmartInboxBatch
        self.sendBrowserApprovedReply = sendBrowserApprovedReply
        self.syncDraftToServer = syncDraftToServer
        self.nodeSession = nodeSession
        capabilityForConnection = { validator.capability(for: $0) }
    }

    init(
        lifecycleCoordinator: PlainpostServiceLifecycleCoordinator,
        performForegroundOperation: PlainpostForegroundOperationHandler? = nil,
        processBackgroundJobs: PlainpostBackgroundJobHandler? = nil,
        performSmartInboxBatch: PlainpostSmartInboxBatchHandler? = nil,
        sendBrowserApprovedReply: PlainpostBrowserApprovedReplyHandler? = nil,
        syncDraftToServer: PlainpostDraftSyncHandler? = nil,
        nodeSession: PlainpostNodeSessionHandlers? = nil,
        capabilityForConnection: @escaping @Sendable (NSXPCConnection) -> PlainpostClientCapability?
    ) {
        self.lifecycleCoordinator = lifecycleCoordinator
        self.performForegroundOperation = performForegroundOperation
        self.processBackgroundJobs = processBackgroundJobs
        self.performSmartInboxBatch = performSmartInboxBatch
        self.sendBrowserApprovedReply = sendBrowserApprovedReply
        self.syncDraftToServer = syncDraftToServer
        self.nodeSession = nodeSession
        self.capabilityForConnection = capabilityForConnection
    }

    func exportedService(
        for capability: PlainpostClientCapability
    ) -> PlainpostServiceXPCProtocol {
        PlainpostServiceExport(
            capability: capability, lifecycleCoordinator: lifecycleCoordinator,
            performForegroundOperation: performForegroundOperation,
            processBackgroundJobs: processBackgroundJobs,
            performSmartInboxBatch: performSmartInboxBatch,
            sendBrowserApprovedReply: sendBrowserApprovedReply,
            syncDraftToServer: syncDraftToServer,
            nodeSession: nodeSession,
            serviceIdentity: serviceIdentity)
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let capability = capabilityForConnection(connection) else {
            connection.invalidate()
            return false
        }
        connection.exportedInterface = PlainpostServiceXPCInterface.make()
        connection.exportedObject = exportedService(for: capability)
        connection.activate()
        return true
    }
}

private final class PlainpostServiceExport:
    NSObject,
    PlainpostServiceXPCProtocol,
    @unchecked Sendable
{
    private let capability: PlainpostClientCapability
    private let lifecycleCoordinator:
        PlainpostServiceLifecycleCoordinator
    private let performForegroundOperation: PlainpostForegroundOperationHandler?
    private let processBackgroundJobs: PlainpostBackgroundJobHandler?
    private let performSmartInboxBatch: PlainpostSmartInboxBatchHandler?
    private let sendBrowserApprovedReply: PlainpostBrowserApprovedReplyHandler?
    private let syncDraftToServer: PlainpostDraftSyncHandler?
    private let nodeSession: PlainpostNodeSessionHandlers?
    private let serviceIdentity: PlainpostServiceBuildIdentity?

    init(
        capability: PlainpostClientCapability,
        lifecycleCoordinator: PlainpostServiceLifecycleCoordinator,
        performForegroundOperation: PlainpostForegroundOperationHandler?,
        processBackgroundJobs: PlainpostBackgroundJobHandler?,
        performSmartInboxBatch: PlainpostSmartInboxBatchHandler?,
        sendBrowserApprovedReply: PlainpostBrowserApprovedReplyHandler?,
        syncDraftToServer: PlainpostDraftSyncHandler?,
        nodeSession: PlainpostNodeSessionHandlers?,
        serviceIdentity: PlainpostServiceBuildIdentity?
    ) {
        self.serviceIdentity = serviceIdentity
        self.capability = capability
        self.lifecycleCoordinator = lifecycleCoordinator
        self.performForegroundOperation = performForegroundOperation
        self.processBackgroundJobs = processBackgroundJobs
        self.performSmartInboxBatch = performSmartInboxBatch
        self.sendBrowserApprovedReply = sendBrowserApprovedReply
        self.syncDraftToServer = syncDraftToServer
        self.nodeSession = nodeSession
    }

    func status(
        reply: @escaping (
            PlainpostVaultStatusDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                let status = try await lifecycleCoordinator.status()
                reply.value(
                    PlainpostServiceErrorMapper.dto(from: status),
                    nil
                )
            } catch {
                reply.value(
                    nil,
                    PlainpostServiceErrorMapper.dto(from: error)
                )
            }
        }
    }

    func unlock(
        reason: String,
        reply: @escaping (PlainpostXPCErrorDTO?) -> Void
    ) {
        guard capability == .app || capability == .cli else {
            reply(
                PlainpostServiceErrorMapper.dto(
                    from: CredentialVaultError.locked
                )
            )
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                try await lifecycleCoordinator.unlock(
                    prompt: reason,
                    capability: capability
                )
                reply.value(nil)
            } catch {
                reply.value(PlainpostServiceErrorMapper.dto(from: error))
            }
        }
    }

    func lock(reply: @escaping (PlainpostXPCErrorDTO?) -> Void) {
        guard capability == .app || capability == .cli else {
            reply(
                PlainpostServiceErrorMapper.dto(
                    from: CredentialVaultError.clientUnauthorized
                )
            )
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            await lifecycleCoordinator.lock()
            reply.value(nil)
        }
    }

    func processBackgroundJobs(
        reply: @escaping (
            PlainpostBackgroundJobResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        guard capability == .agent else {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: CredentialVaultError.clientUnauthorized
                )
            )
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                try await requireUnlockedVault()
                guard let processBackgroundJobs else {
                    throw PlainpostServiceClientError.operationFailed
                }
                reply.value(
                    try await processBackgroundJobs().dto(),
                    nil
                )
            } catch {
                reply.value(
                    nil,
                    PlainpostServiceErrorMapper.dto(from: error)
                )
            }
        }
    }

    func performSmartInboxBatch(
        _ requestDTO: PlainpostSmartInboxBatchRequestDTO,
        reply: @escaping (
            PlainpostSmartInboxBatchResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        guard capability == .cli else {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: CredentialVaultError.clientUnauthorized
                )
            )
            return
        }
        let request: PlainpostSmartInboxBatchRequest
        do {
            request = try PlainpostSmartInboxBatchRequest(dto: requestDTO)
        } catch {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: PlainpostServiceClientError.invalidRequest
                )
            )
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                try await requireUnlockedVault()
                guard let performSmartInboxBatch else {
                    throw PlainpostServiceClientError.operationFailed
                }
                let result = try await performSmartInboxBatch(request)
                guard result.accountID == request.accountID,
                      result.category == request.category,
                      result.action == request.action,
                      ArchiveMailbox.answers(result.archiveMailbox, requested: request.archiveMailbox)
                else {
                    throw PlainpostServiceClientError.operationFailed
                }
                reply.value(try result.dto(), nil)
            } catch {
                reply.value(
                    nil,
                    PlainpostServiceErrorMapper.dto(from: error)
                )
            }
        }
    }

    func sendBrowserApprovedReply(
        _ request: PlainpostBrowserApprovedReplyRequestDTO,
        reply: @escaping (
            PlainpostBrowserApprovedReplyResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        guard capability == .browserHost else {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: CredentialVaultError.clientUnauthorized
                )
            )
            return
        }
        guard request.schemaVersion == 1,
              Self.isValidStableID(request.jobID)
        else {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: PlainpostServiceClientError.invalidRequest
                )
            )
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                try await requireUnlockedVault()
                guard let sendBrowserApprovedReply else {
                    throw PlainpostServiceClientError.operationFailed
                }
                let result = try await sendBrowserApprovedReply(request.jobID)
                guard result.jobID == request.jobID else {
                    throw PlainpostServiceClientError.operationFailed
                }
                reply.value(try result.dto(), nil)
            } catch {
                reply.value(
                    nil,
                    PlainpostServiceErrorMapper.dto(from: error)
                )
            }
        }
    }

    func syncDraftToServer(
        _ request: PlainpostDraftSyncRequestDTO,
        reply: @escaping (
            PlainpostDraftSyncResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        guard capability == .cli else {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: CredentialVaultError.clientUnauthorized
                )
            )
            return
        }
        guard request.schemaVersion == 1,
              Self.isValidStableID(request.draftID),
              Self.isValidStableID(request.mailbox)
        else {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: PlainpostServiceClientError.invalidRequest
                )
            )
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                try await requireUnlockedVault()
                guard let syncDraftToServer else {
                    throw PlainpostServiceClientError.operationFailed
                }
                let result = try await syncDraftToServer(
                    request.draftID,
                    request.mailbox
                )
                guard result.draftID == request.draftID else {
                    throw PlainpostServiceClientError.operationFailed
                }
                reply.value(try result.dto(), nil)
            } catch {
                reply.value(
                    nil,
                    PlainpostServiceErrorMapper.dto(from: error)
                )
            }
        }
    }

    func performForegroundOperation(
        _ request: PlainpostForegroundOperationRequestDTO,
        reply: @escaping (PlainpostForegroundOperationResultDTO?, PlainpostXPCErrorDTO?) -> Void
    ) {
        let operation: PlainpostForegroundOperation
        do {
            operation = try PlainpostForegroundOperation(
                requestDTO: request
            )
        } catch {
            reply(
                nil,
                PlainpostServiceErrorMapper.dto(
                    from: PlainpostServiceClientError.invalidRequest
                )
            )
            return
        }
        guard Self.allows(operation.kind, for: capability) else {
            reply(
                nil, PlainpostServiceErrorMapper.dto(from: CredentialVaultError.clientUnauthorized))
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                let status = try await lifecycleCoordinator.status()
                guard status.availability == .unlocked else {
                    reply.value(
                        nil,
                        PlainpostServiceErrorMapper.dto(from: Self.error(for: status.availability)))
                    return
                }
                guard let performForegroundOperation else {
                    throw PlainpostServiceClientError.operationFailed
                }
                let result = try await performForegroundOperation(operation)
                guard result.isSemanticallyCorrelated(with: operation) else {
                    throw PlainpostServiceClientError.operationFailed
                }
                reply.value(try result.responseDTO(), nil)
            } catch { reply.value(nil, PlainpostServiceErrorMapper.dto(from: error)) }
        }
    }

    /// Node session calls need no unlocked vault: the broker signs with the
    /// shared device identity and never reads vault-held credentials.
    func performNodeSessionRequest(
        _ requestDTO: PlainpostNodeSessionRequestDTO,
        reply: @escaping (PlainpostNodeSessionResponseDTO?, PlainpostXPCErrorDTO?) -> Void
    ) {
        guard PlainpostClientValidator.permits(.performNodeSessionRequest, for: capability) else {
            reply(nil, PlainpostServiceErrorMapper.dto(from: CredentialVaultError.clientUnauthorized))
            return
        }
        let request: PlainpostNodeSessionRequest
        do {
            request = try PlainpostNodeSessionRequest(dto: requestDTO)
        } catch {
            reply(nil, PlainpostServiceErrorMapper.dto(from: PlainpostServiceClientError.invalidRequest))
            return
        }
        guard let nodeSession else {
            reply(nil, PlainpostServiceErrorMapper.dto(from: PlainpostServiceClientError.nodeSession(.unavailable)))
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                let response = try await nodeSession.perform(request)
                reply.value(try response.dto(), nil)
            } catch {
                reply.value(nil, PlainpostServiceErrorMapper.dto(from: error))
            }
        }
    }

    func invalidateNodeSession(reply: @escaping (PlainpostXPCErrorDTO?) -> Void) {
        guard PlainpostClientValidator.permits(.invalidateNodeSession, for: capability) else {
            reply(PlainpostServiceErrorMapper.dto(from: CredentialVaultError.clientUnauthorized))
            return
        }
        guard let nodeSession else {
            reply(nil)
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            await nodeSession.invalidate()
            reply.value(nil)
        }
    }

    func nodeSessionIdentityReadiness(reply: @escaping (String?, PlainpostXPCErrorDTO?) -> Void) {
        guard PlainpostClientValidator.permits(.nodeSessionIdentityReadiness, for: capability) else {
            reply(nil, PlainpostServiceErrorMapper.dto(from: CredentialVaultError.clientUnauthorized))
            return
        }
        guard let nodeSession else {
            reply(PlainpostNodeSessionIdentityReadiness.noSession.rawValue, nil)
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            let readiness = await nodeSession.identityReadiness()
            reply.value(readiness.rawValue, nil)
        }
    }

    /// Status only: a closed state and two counts. It needs no unlocked
    /// vault, and only the app may read it.
    func nodeMailModeStatus(reply: @escaping (PlainpostNodeMailModeStatusDTO?, PlainpostXPCErrorDTO?) -> Void) {
        guard PlainpostClientValidator.permits(.nodeMailModeStatus, for: capability) else {
            reply(nil, PlainpostServiceErrorMapper.dto(from: CredentialVaultError.clientUnauthorized))
            return
        }
        guard let status = nodeSession?.mailModeStatus else {
            reply(try? PlainpostNodeMailModeStatus.noNode.dto(), nil)
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                reply.value(try await status().dto(), nil)
            } catch {
                reply.value(nil, PlainpostServiceErrorMapper.dto(from: error))
            }
        }
    }

    /// The service bundle path and build stamp only: no account, vault or
    /// user data. Needs no unlocked vault; only the app may read it.
    func serviceIdentity(reply: @escaping (String?, String?, PlainpostXPCErrorDTO?) -> Void) {
        guard PlainpostClientValidator.permits(.serviceIdentity, for: capability) else {
            reply(nil, nil, PlainpostServiceErrorMapper.dto(from: CredentialVaultError.clientUnauthorized))
            return
        }
        reply(serviceIdentity?.bundlePath, serviceIdentity?.buildStamp, nil)
    }

    func startOverAfterVaultKeyLoss(
        reason: String,
        reply: @escaping (PlainpostXPCErrorDTO?) -> Void
    ) {
        guard PlainpostClientValidator.permits(.startOverAfterVaultKeyLoss, for: capability) else {
            reply(PlainpostServiceErrorMapper.dto(from: CredentialVaultError.clientUnauthorized))
            return
        }
        let reply = UnsafeServiceReply(reply)
        Task {
            do {
                try await lifecycleCoordinator.startOverAfterVaultKeyLoss(
                    prompt: reason,
                    capability: capability
                )
                reply.value(nil)
            } catch {
                reply.value(PlainpostServiceErrorMapper.dto(from: error))
            }
        }
    }

    private func requireUnlockedVault() async throws {
        let status = try await lifecycleCoordinator.status()
        guard status.availability == .unlocked else {
            throw Self.error(for: status.availability)
        }
    }

    private static func allows(
        _ kind: PlainpostForegroundOperationKind,
        for capability: PlainpostClientCapability
    ) -> Bool {
        if capability == .app {
            return true
        }
        guard capability == .cli else {
            return false
        }
        switch kind {
        case .inboxSync, .historicalSync,
             .accountAdd, .accountTest, .replaceAccountCredentials,
             .archive, .delete, .markRead, .markUnread,
             .addLabel, .removeLabel, .labelCommand:
            return true
        case .AI, .translateMessage, .approveSend, .denySend,
             .deliverDirectDraft, .deliverBrowserReply, .deleteAccount,
             .googleAccountAdd, .replaceGoogleAccountCredential:
            return false
        @unknown default:
            return false
        }
    }

    private static func isValidStableID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 1_024
            && value == value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func error(for availability: PlainpostVaultStatus.Availability)
        -> CredentialVaultError
    {
        switch availability {
        case .locked:
            return .locked
        case .unlocked:
            preconditionFailure("Unlocked availability has no vault error")
        case .keyMissing:
            return .keyMissing
        case .keyAmbiguous:
            return .keyAmbiguous
        case .ciphertextInvalid:
            return .ciphertextInvalid
        case let .unsupportedVersion(version):
            return .unsupportedVersion(version)
        }
    }
}

private struct UnsafeServiceReply<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
