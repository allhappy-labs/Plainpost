import PlainpostServiceIPC

public enum PlainpostVaultLaunchState: Equatable, Sendable {
    case checking
    case locked
    case ready
    case keyMissing
    case keyAmbiguous
    case ciphertextInvalid
    case unsupportedVersion(Int)
    case authorizationFailed
    case serviceUnavailable
}

public struct PlainpostVaultReadinessGate: Sendable {
    private let serviceClient: any PlainpostServiceClientProtocol

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        self.serviceClient = serviceClient
    }

    public func evaluate() async -> PlainpostVaultLaunchState {
        do { return Self.map(try await serviceClient.status()) } catch { return Self.map(error) }
    }

    public func unlock(reason: String) async -> PlainpostVaultLaunchState {
        do {
            try await serviceClient.unlock(reason: reason)
            return .ready
        } catch { return Self.map(error) }
    }

    /// "Start Over with Saved Sign-ins": the service archives the saved
    /// sign-ins a lost key can no longer open, then unlocks a fresh vault. A
    /// refusal or failure that names no vault state re-reads the vault, so a
    /// key that is still missing keeps its screen.
    public func startOver(reason: String) async -> PlainpostVaultLaunchState {
        do {
            try await serviceClient.startOverAfterVaultKeyLoss(reason: reason)
            return .ready
        } catch let error as PlainpostServiceClientError {
            if let state = Self.runtimeFailureState(for: error), state != .serviceUnavailable {
                return state
            }
            return await evaluate()
        } catch {
            return await evaluate()
        }
    }

    private static func map(_ status: PlainpostVaultStatus) -> PlainpostVaultLaunchState {
        switch status.availability {
        case .locked: return .locked
        case .unlocked: return .ready
        case .keyMissing: return .keyMissing
        case .keyAmbiguous: return .keyAmbiguous
        case .ciphertextInvalid: return .ciphertextInvalid
        case .unsupportedVersion(let version): return .unsupportedVersion(version)
        }
    }

    static func runtimeFailureState(
        for error: PlainpostServiceClientError
    ) -> PlainpostVaultLaunchState? {
        switch error {
        case .vaultLocked, .authorizationCancelled: return .locked
        case .vaultKeyMissing: return .keyMissing
        case .vaultKeyAmbiguous: return .keyAmbiguous
        case .ciphertextInvalid: return .ciphertextInvalid
        case .unsupportedVaultVersion(let version): return .unsupportedVersion(version)
        case .authorizationFailed: return .authorizationFailed
        case .clientUnauthorized, .serviceUnavailable, .timedOut: return .serviceUnavailable
        case .invalidRequest, .operationFailed,
            .accountDeletionCleanupPending,
            .accountDeletionCompensationFailed, .nodeSession, .mailActionRefused:
            return nil
        }
    }

    private static func map(_ error: Error) -> PlainpostVaultLaunchState {
        guard let error = error as? PlainpostServiceClientError else { return .serviceUnavailable }
        return runtimeFailureState(for: error) ?? .serviceUnavailable
    }
}
