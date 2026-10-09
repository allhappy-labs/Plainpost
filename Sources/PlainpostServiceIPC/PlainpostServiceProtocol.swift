@_exported import PlainpostXPCObjC
import PlainpostCore

public struct PlainpostVaultStatus: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case locked
        case unlocked
        case keyMissing
        case keyAmbiguous
        case ciphertextInvalid
        case unsupportedVersion(Int)
    }

    public let availability: Availability
    public let matchingKeyItemCount: Int

    public init(
        availability: Availability,
        matchingKeyItemCount: Int
    ) {
        self.availability = availability
        self.matchingKeyItemCount = matchingKeyItemCount
    }

    public init(dto: PlainpostVaultStatusDTO) throws {
        switch dto.availability {
        case .locked:
            availability = .locked
        case .unlocked:
            availability = .unlocked
        case .keyMissing:
            availability = .keyMissing
        case .keyAmbiguous:
            availability = .keyAmbiguous
        case .ciphertextInvalid:
            availability = .ciphertextInvalid
        case .unsupportedVersion:
            availability = .unsupportedVersion(dto.detail)
        @unknown default:
            throw PlainpostServiceClientError.serviceUnavailable
        }
        matchingKeyItemCount = dto.matchingKeyItemCount
    }
}

public enum PlainpostServiceClientError: Error, Equatable, Sendable {
    case vaultLocked
    case authorizationCancelled
    case authorizationFailed
    case vaultKeyMissing
    case vaultKeyAmbiguous
    case ciphertextInvalid
    case unsupportedVaultVersion(Int)
    case clientUnauthorized
    case serviceUnavailable
    case timedOut
    case invalidRequest
    case operationFailed
    case accountDeletionCleanupPending
    case accountDeletionCompensationFailed
    case nodeSession(PlainpostNodeSessionFailure)
    /// An archive or delete the service refused, with its reason.
    case mailActionRefused(MailActionRefusal)

    public init(dto: PlainpostXPCErrorDTO) {
        switch dto.code {
        case .vaultLocked:
            self = .vaultLocked
        case .authorizationCancelled:
            self = .authorizationCancelled
        case .authorizationFailed:
            self = .authorizationFailed
        case .vaultKeyMissing:
            self = .vaultKeyMissing
        case .vaultKeyAmbiguous:
            self = .vaultKeyAmbiguous
        case .ciphertextInvalid:
            self = .ciphertextInvalid
        case .unsupportedVaultVersion:
            self = .unsupportedVaultVersion(dto.detail)
        case .clientUnauthorized:
            self = .clientUnauthorized
        case .invalidRequest:
            self = .invalidRequest
        case .operationFailed:
            self = MailActionRefusal(rawValue: dto.detail).map { .mailActionRefused($0) } ?? .operationFailed
        case .accountDeletionCleanupPending:
            self = .accountDeletionCleanupPending
        case .accountDeletionCompensationFailed:
            self = .accountDeletionCompensationFailed
        case .nodeSessionFailed:
            self = .nodeSession(PlainpostNodeSessionFailure(rawValue: dto.detail) ?? .unavailable)
        @unknown default:
            self = .operationFailed
        }
    }
}

public struct PlainpostBackgroundJobResult: Equatable, Sendable {
    public let recoveredJobCount: Int
    public let processedJobCount: Int

    public init(recoveredJobCount: Int, processedJobCount: Int) {
        self.recoveredJobCount = recoveredJobCount
        self.processedJobCount = processedJobCount
    }

    init(dto: PlainpostBackgroundJobResultDTO) throws {
        guard dto.schemaVersion == 1,
              dto.recoveredJobCount >= 0,
              dto.processedJobCount >= 0
        else {
            throw PlainpostServiceClientError.serviceUnavailable
        }
        recoveredJobCount = dto.recoveredJobCount
        processedJobCount = dto.processedJobCount
    }

    public func dto() throws -> PlainpostBackgroundJobResultDTO {
        guard let result = PlainpostBackgroundJobResultDTO(
            schemaVersion: 1,
            recoveredJobCount: recoveredJobCount,
            processedJobCount: processedJobCount
        ) else {
            throw PlainpostServiceClientError.operationFailed
        }
        return result
    }
}

public enum PlainpostSmartInboxBatchContract {
    public static let maximumAffectedMessageCount = 1_024
    public static let categories: Set<String> = [
        "personal",
        "notification",
        "newsletter",
        "seen",
    ]
    public static let actions: Set<String> = ["archive_read"]
}

public struct PlainpostSmartInboxBatchRequest: Equatable, Sendable {
    public let accountID: String
    public let category: String
    public let action: String
    public let archiveMailbox: String

    public init(
        accountID: String,
        category: String,
        action: String,
        archiveMailbox: String
    ) {
        self.accountID = accountID
        self.category = category
        self.action = action
        self.archiveMailbox = archiveMailbox
    }

    public init(dto: PlainpostSmartInboxBatchRequestDTO) throws {
        guard dto.schemaVersion == 1,
              PlainpostSmartInboxBatchContract.categories.contains(
                  dto.category
              ),
              PlainpostSmartInboxBatchContract.actions.contains(dto.action)
        else {
            throw PlainpostServiceClientError.invalidRequest
        }
        self.init(
            accountID: dto.accountID,
            category: dto.category,
            action: dto.action,
            archiveMailbox: dto.archiveMailbox
        )
    }

    public func dto() throws -> PlainpostSmartInboxBatchRequestDTO {
        guard PlainpostSmartInboxBatchContract.categories.contains(category),
              PlainpostSmartInboxBatchContract.actions.contains(action),
              let request = PlainpostSmartInboxBatchRequestDTO(
                  schemaVersion: 1,
                  accountID: accountID,
                  category: category,
                  action: action,
                  archiveMailbox: archiveMailbox
              )
        else {
            throw PlainpostServiceClientError.invalidRequest
        }
        return request
    }
}

public struct PlainpostSmartInboxBatchResult: Equatable, Sendable {
    public let accountID: String
    public let category: String
    public let action: String
    public let affectedMessageIDs: [String]
    public let archiveMailbox: String

    public init(
        accountID: String,
        category: String,
        action: String,
        affectedMessageIDs: [String],
        archiveMailbox: String
    ) {
        self.accountID = accountID
        self.category = category
        self.action = action
        self.affectedMessageIDs = affectedMessageIDs
        self.archiveMailbox = archiveMailbox
    }

    init(dto: PlainpostSmartInboxBatchResultDTO) throws {
        guard dto.schemaVersion == 1,
              PlainpostSmartInboxBatchContract.categories.contains(
                  dto.category
              ),
              PlainpostSmartInboxBatchContract.actions.contains(dto.action),
              dto.affectedMessageIDs.count
                  <= PlainpostSmartInboxBatchContract
                      .maximumAffectedMessageCount,
              Set(dto.affectedMessageIDs).count
                  == dto.affectedMessageIDs.count
        else {
            throw PlainpostServiceClientError.serviceUnavailable
        }
        self.init(
            accountID: dto.accountID,
            category: dto.category,
            action: dto.action,
            affectedMessageIDs: dto.affectedMessageIDs,
            archiveMailbox: dto.archiveMailbox
        )
    }

    public func dto() throws -> PlainpostSmartInboxBatchResultDTO {
        guard PlainpostSmartInboxBatchContract.categories.contains(category),
              PlainpostSmartInboxBatchContract.actions.contains(action),
              affectedMessageIDs.count
                  <= PlainpostSmartInboxBatchContract
                      .maximumAffectedMessageCount,
              Set(affectedMessageIDs).count == affectedMessageIDs.count,
              let result = PlainpostSmartInboxBatchResultDTO(
                  schemaVersion: 1,
                  accountID: accountID,
                  category: category,
                  action: action,
                  affectedMessageIDs: affectedMessageIDs,
                  archiveMailbox: archiveMailbox
              )
        else {
            throw PlainpostServiceClientError.operationFailed
        }
        return result
    }
}

public struct PlainpostBrowserApprovedReplyResult: Equatable, Sendable {
    public let requestID: String
    public let jobID: String
    public let state: String

    public init(requestID: String, jobID: String, state: String) {
        self.requestID = requestID
        self.jobID = jobID
        self.state = state
    }

    init(dto: PlainpostBrowserApprovedReplyResultDTO) throws {
        guard dto.schemaVersion == 1 else {
            throw PlainpostServiceClientError.serviceUnavailable
        }
        requestID = dto.requestID
        jobID = dto.jobID
        state = dto.state
    }

    public func dto() throws -> PlainpostBrowserApprovedReplyResultDTO {
        guard let result = PlainpostBrowserApprovedReplyResultDTO(
            schemaVersion: 1,
            requestID: requestID,
            jobID: jobID,
            state: state
        ) else {
            throw PlainpostServiceClientError.operationFailed
        }
        return result
    }
}

public struct PlainpostDraftSyncResult: Equatable, Sendable {
    public let draftID: String
    public let mailbox: String
    public let serverDraftUID: Int?

    public init(
        draftID: String,
        mailbox: String,
        serverDraftUID: Int?
    ) {
        self.draftID = draftID
        self.mailbox = mailbox
        self.serverDraftUID = serverDraftUID
    }

    init(dto: PlainpostDraftSyncResultDTO) throws {
        guard dto.schemaVersion == 1 else {
            throw PlainpostServiceClientError.serviceUnavailable
        }
        draftID = dto.draftID
        mailbox = dto.mailbox
        serverDraftUID = dto.serverDraftUID == 0
            ? nil
            : dto.serverDraftUID
    }

    public func dto() throws -> PlainpostDraftSyncResultDTO {
        guard let result = PlainpostDraftSyncResultDTO(
            schemaVersion: 1,
            draftID: draftID,
            mailbox: mailbox,
            serverDraftUID: serverDraftUID ?? 0
        ) else {
            throw PlainpostServiceClientError.operationFailed
        }
        return result
    }
}

public protocol PlainpostServiceClientProtocol: Sendable {
    func status() async throws -> PlainpostVaultStatus
    func unlock(reason: String) async throws
    /// "Start Over with Saved Sign-ins" (app only): archives the saved
    /// sign-ins a lost vault key can no longer open, then unlocks a fresh
    /// vault. The service refuses unless the key is missing.
    func startOverAfterVaultKeyLoss(reason: String) async throws
    func lock() async throws
    func processBackgroundJobs() async throws -> PlainpostBackgroundJobResult
    func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequest
    ) async throws -> PlainpostSmartInboxBatchResult
    func sendBrowserApprovedReply(
        jobID: String
    ) async throws -> PlainpostBrowserApprovedReplyResult
    func syncDraftToServer(
        draftID: String,
        mailbox: String
    ) async throws -> PlainpostDraftSyncResult
    func perform(_ operation: PlainpostForegroundOperation) async throws
        -> PlainpostForegroundOperationResult
    /// Sends one Node session request through the service-owned broker.
    /// Only the app may call it; the service allowlists the route.
    func performNodeSessionRequest(
        _ request: PlainpostNodeSessionRequest
    ) async throws -> PlainpostNodeSessionResponse
    /// Drops the broker's resolved Node session after enrollment, activation
    /// or replacement committed in the app.
    func invalidateNodeSession() async throws
    func nodeSessionIdentityReadiness() async throws
        -> PlainpostNodeSessionIdentityReadiness
    /// The service's Sync Node mail-mode status (app only). The app renders
    /// it and holds no Node session of its own for mail.
    func nodeMailModeStatus() async throws -> PlainpostNodeMailModeStatus
    /// The running service's bundle path and build stamp; nil when the
    /// service runs outside a bundle.
    func serviceIdentity() async throws -> PlainpostServiceBuildIdentity?
}

extension PlainpostServiceClientProtocol {
    public func startOverAfterVaultKeyLoss(reason: String) async throws {
        _ = reason
        throw PlainpostServiceClientError.operationFailed
    }

    public func processBackgroundJobs() async throws
        -> PlainpostBackgroundJobResult
    {
        throw PlainpostServiceClientError.operationFailed
    }

    public func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequest
    ) async throws -> PlainpostSmartInboxBatchResult {
        _ = request
        throw PlainpostServiceClientError.operationFailed
    }

    public func sendBrowserApprovedReply(
        jobID: String
    ) async throws -> PlainpostBrowserApprovedReplyResult {
        _ = jobID
        throw PlainpostServiceClientError.operationFailed
    }

    public func syncDraftToServer(
        draftID: String,
        mailbox: String
    ) async throws -> PlainpostDraftSyncResult {
        _ = draftID
        _ = mailbox
        throw PlainpostServiceClientError.operationFailed
    }

    public func perform(_ operation: PlainpostForegroundOperation) async throws
        -> PlainpostForegroundOperationResult
    {
        _ = operation
        throw PlainpostServiceClientError.operationFailed
    }

    public func performNodeSessionRequest(
        _ request: PlainpostNodeSessionRequest
    ) async throws -> PlainpostNodeSessionResponse {
        _ = request
        throw PlainpostServiceClientError.operationFailed
    }

    public func invalidateNodeSession() async throws {
        throw PlainpostServiceClientError.operationFailed
    }

    public func nodeSessionIdentityReadiness() async throws
        -> PlainpostNodeSessionIdentityReadiness
    {
        throw PlainpostServiceClientError.operationFailed
    }

    public func nodeMailModeStatus() async throws -> PlainpostNodeMailModeStatus {
        throw PlainpostServiceClientError.operationFailed
    }

    public func serviceIdentity() async throws -> PlainpostServiceBuildIdentity? {
        throw PlainpostServiceClientError.operationFailed
    }
}

extension PlainpostVaultStatusDTO: @retroactive @unchecked Sendable {}
extension PlainpostXPCErrorDTO: @retroactive @unchecked Sendable {}
extension PlainpostBackgroundJobResultDTO: @retroactive @unchecked Sendable {}
extension PlainpostSmartInboxBatchRequestDTO:
    @retroactive @unchecked Sendable {}
extension PlainpostSmartInboxBatchResultDTO:
    @retroactive @unchecked Sendable {}
extension PlainpostBrowserApprovedReplyRequestDTO:
    @retroactive @unchecked Sendable {}
extension PlainpostBrowserApprovedReplyResultDTO:
    @retroactive @unchecked Sendable {}
extension PlainpostDraftSyncRequestDTO: @retroactive @unchecked Sendable {}
extension PlainpostDraftSyncResultDTO: @retroactive @unchecked Sendable {}
extension PlainpostForegroundOperationRequestDTO: @retroactive @unchecked Sendable {}
extension PlainpostForegroundOperationResultDTO: @retroactive @unchecked Sendable {}
