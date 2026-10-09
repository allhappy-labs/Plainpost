import PlainpostCore
import PlainpostDB
import PlainpostSecrets
import PlainpostServiceIPC

public enum PlainpostServiceErrorMapper {
    public static func dto(from error: Error) -> PlainpostXPCErrorDTO {
        if let error = error as? PlainpostServiceClientError {
            switch error {
            case .vaultLocked:
                return makeDTO(code: .vaultLocked)
            case .authorizationCancelled:
                return makeDTO(code: .authorizationCancelled)
            case .authorizationFailed:
                return makeDTO(code: .authorizationFailed)
            case .vaultKeyMissing:
                return makeDTO(code: .vaultKeyMissing)
            case .vaultKeyAmbiguous:
                return makeDTO(code: .vaultKeyAmbiguous)
            case .ciphertextInvalid:
                return makeDTO(code: .ciphertextInvalid)
            case .unsupportedVaultVersion(let version) where version > 0:
                return makeDTO(
                    code: .unsupportedVaultVersion,
                    detail: version
                )
            case .clientUnauthorized:
                return makeDTO(code: .clientUnauthorized)
            case .invalidRequest:
                return makeDTO(code: .invalidRequest)
            case .operationFailed, .serviceUnavailable, .timedOut,
                 .unsupportedVaultVersion:
                return makeDTO(code: .operationFailed)
            case .accountDeletionCleanupPending:
                return makeDTO(code: .accountDeletionCleanupPending)
            case .accountDeletionCompensationFailed:
                return makeDTO(code: .accountDeletionCompensationFailed)
            case .nodeSession(let failure):
                return makeDTO(code: .nodeSessionFailed, detail: failure.rawValue)
            case .mailActionRefused(let refusal):
                return makeDTO(code: .operationFailed, detail: refusal.rawValue)
            }
        }
        // A delete or archive refusal keeps its reason across XPC.
        if case let .validationFailed(message)? = error as? PlainpostError,
           let refusal = MailActionRefusal(message: message) {
            return makeDTO(code: .operationFailed, detail: refusal.rawValue)
        }
        if error is AccountDeletionCleanupPendingError {
            return makeDTO(code: .accountDeletionCleanupPending)
        }
        if error is AccountDeletionCompensationError {
            return makeDTO(code: .accountDeletionCompensationFailed)
        }
        guard let error = error as? CredentialVaultError else {
            return makeDTO(code: .operationFailed)
        }
        switch error {
        case .locked:
            return makeDTO(code: .vaultLocked)
        case .authorizationCancelled:
            return makeDTO(code: .authorizationCancelled)
        case .authorizationFailed:
            return makeDTO(code: .authorizationFailed)
        case .keyMissing:
            return makeDTO(code: .vaultKeyMissing)
        case .keyAmbiguous:
            return makeDTO(code: .vaultKeyAmbiguous)
        case .ciphertextInvalid:
            return makeDTO(code: .ciphertextInvalid)
        case let .unsupportedVersion(version) where version > 0:
            return makeDTO(
                code: .unsupportedVaultVersion,
                detail: version
            )
        case .clientUnauthorized:
            return makeDTO(code: .clientUnauthorized)
        case .invalidKeyLength, .unsupportedVersion:
            return makeDTO(code: .operationFailed)
        }
    }

    static func dto(
        from status: PlainpostVaultStatus
    ) -> PlainpostVaultStatusDTO {
        let availability: PlainpostVaultAvailability
        let detail: Int
        switch status.availability {
        case .locked:
            availability = .locked
            detail = 0
        case .unlocked:
            availability = .unlocked
            detail = 0
        case .keyMissing:
            availability = .keyMissing
            detail = 0
        case .keyAmbiguous:
            availability = .keyAmbiguous
            detail = 0
        case .ciphertextInvalid:
            availability = .ciphertextInvalid
            detail = 0
        case let .unsupportedVersion(version):
            availability = .unsupportedVersion
            detail = version
        }
        guard let dto = PlainpostVaultStatusDTO(
            schemaVersion: 1,
            availability: availability,
            matchingKeyItemCount: status.matchingKeyItemCount,
            detail: detail
        ) else {
            preconditionFailure("Static Plainpost vault status is invalid")
        }
        return dto
    }

    private static func makeDTO(
        code: PlainpostXPCErrorCode,
        detail: Int = 0
    ) -> PlainpostXPCErrorDTO {
        guard let dto = PlainpostXPCErrorDTO(
            schemaVersion: 1,
            code: code,
            detail: detail
        ) else {
            preconditionFailure("Static Plainpost XPC error mapping is invalid")
        }
        return dto
    }
}
