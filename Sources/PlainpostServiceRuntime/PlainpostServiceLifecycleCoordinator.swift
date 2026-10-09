import PlainpostSecrets
import PlainpostServiceIPC

public actor PlainpostServiceLifecycleCoordinator {
    private enum Phase {
        case active
        case shuttingDown
        case shutdown
    }

    private enum TransitionKind {
        case lock
        case unlock
    }

    private enum TransitionAcquisition {
        case owner
        case completed
        case rejected
    }

    private struct QueuedTransition {
        let kind: TransitionKind
        let continuation:
            CheckedContinuation<TransitionAcquisition, Never>
    }

    private let vaultSession: VaultSession
    private let prepareForegroundUnlock: @Sendable () async throws -> Void
    private let archiveCredentialsAfterKeyLoss: @Sendable () async throws -> Void
    private let beginVaultLockdown: @Sendable () async -> Void
    private let confirmVaultLocked: @Sendable () async -> Void
    private let recoverAfterUnlock: @Sendable () async throws -> Void
    private let reopenRuntimeConstruction: @Sendable () async -> Void
    private var phase: Phase = .active
    private var shutdownRequested = false
    private var isTransitioning = false
    private var transitionWaiters: [QueuedTransition] = []
    private var shutdownOwnerWaiter: CheckedContinuation<Void, Never>?
    private var shutdownLockWaiters: [
        CheckedContinuation<TransitionAcquisition, Never>
    ] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastFailure: CredentialVaultError?

    public init(
        vaultSession: VaultSession,
        prepareForegroundUnlock: @escaping @Sendable () async throws -> Void,
        archiveCredentialsAfterKeyLoss: @escaping @Sendable () async throws -> Void = {
            throw PlainpostServiceClientError.operationFailed
        },
        beginVaultLockdown: @escaping @Sendable () async -> Void,
        confirmVaultLocked: @escaping @Sendable () async -> Void,
        recoverAfterUnlock: @escaping @Sendable () async throws -> Void = {},
        reopenRuntimeConstruction: @escaping @Sendable () async -> Void
    ) {
        self.vaultSession = vaultSession
        self.prepareForegroundUnlock = prepareForegroundUnlock
        self.archiveCredentialsAfterKeyLoss = archiveCredentialsAfterKeyLoss
        self.beginVaultLockdown = beginVaultLockdown
        self.confirmVaultLocked = confirmVaultLocked
        self.recoverAfterUnlock = recoverAfterUnlock
        self.reopenRuntimeConstruction = reopenRuntimeConstruction
    }

    public func status() async throws -> PlainpostVaultStatus {
        let matchingKeyItemCount =
            try await vaultSession.matchingKeyItemCount()
        guard matchingKeyItemCount >= 0 else {
            throw CredentialVaultError.keyAmbiguous
        }
        let availability: PlainpostVaultStatus.Availability
        switch matchingKeyItemCount {
        case 0:
            availability = .keyMissing
        case 1:
            if let failureAvailability {
                availability = failureAvailability
            } else {
                availability =
                    await vaultSession.state == .unlocked
                    ? .unlocked
                    : .locked
            }
        default:
            availability = .keyAmbiguous
        }
        return PlainpostVaultStatus(
            availability: availability,
            matchingKeyItemCount: matchingKeyItemCount
        )
    }

    public func unlock(
        prompt: String,
        capability: PlainpostClientCapability
    ) async throws {
        guard capability == .app || capability == .cli else {
            throw CredentialVaultError.locked
        }
        guard case .owner = await acquireTransition(.unlock) else {
            throw CredentialVaultError.locked
        }
        if await vaultSession.state == .unlocked {
            guard case .active = phase else {
                finishOwnedTransition()
                throw CredentialVaultError.locked
            }
            lastFailure = nil
            finishOwnedTransition()
            return
        }
        try await unlockOwningTransition(prompt: prompt)
    }

    /// "Start Over with Saved Sign-ins" (app only). When the vault key is
    /// gone for good, archives the saved sign-ins it can no longer open, then
    /// runs the normal unlock, which creates a fresh key. Serialized with
    /// lock and unlock, and refused unless no key item exists.
    public func startOverAfterVaultKeyLoss(
        prompt: String,
        capability: PlainpostClientCapability
    ) async throws {
        guard PlainpostClientValidator.permits(.startOverAfterVaultKeyLoss, for: capability) else {
            throw CredentialVaultError.clientUnauthorized
        }
        guard case .owner = await acquireTransition(.unlock) else {
            throw CredentialVaultError.locked
        }
        do {
            guard try await vaultSession.matchingKeyItemCount() == 0 else {
                throw PlainpostServiceClientError.invalidRequest
            }
            try await archiveCredentialsAfterKeyLoss()
            guard case .active = phase else {
                throw CredentialVaultError.locked
            }
        } catch {
            finishOwnedTransition()
            throw error
        }
        try await unlockOwningTransition(prompt: prompt)
    }

    /// The unlock itself, run by the transition's owner; it always finishes
    /// the owned transition.
    private func unlockOwningTransition(prompt: String) async throws {
        do {
            try await prepareForegroundUnlock()
            guard case .active = phase else {
                throw CredentialVaultError.locked
            }
            try await vaultSession.unlock(prompt: prompt)
            guard case .active = phase else {
                throw CredentialVaultError.locked
            }
            try await recoverAfterUnlock()
            guard case .active = phase else {
                throw CredentialVaultError.locked
            }
            await reopenRuntimeConstruction()
            guard case .active = phase else {
                throw CredentialVaultError.locked
            }
            lastFailure = nil
            finishOwnedTransition()
        } catch {
            if let error = error as? CredentialVaultError {
                lastFailure = error
            }
            if case .active = phase {
                await vaultSession.lock()
            }
            finishOwnedTransition()
            throw error
        }
    }

    public func lock() async {
        guard case .owner = await acquireTransition(.lock) else {
            return
        }
        await beginVaultLockdown()
        await vaultSession.lock()
        await confirmVaultLocked()
        finishOwnedTransition()
    }

    public func shutdown() async {
        switch phase {
        case .shutdown:
            return
        case .shuttingDown:
            await withCheckedContinuation {
                shutdownWaiters.append($0)
            }
            return
        case .active:
            guard !shutdownRequested else {
                await withCheckedContinuation {
                    shutdownWaiters.append($0)
                }
                return
            }
            shutdownRequested = true
        }

        let queuedTransitions = transitionWaiters
        transitionWaiters.removeAll()
        for transition in queuedTransitions {
            switch transition.kind {
            case .lock:
                shutdownLockWaiters.append(transition.continuation)
            case .unlock:
                transition.continuation.resume(returning: .rejected)
            }
        }

        if isTransitioning {
            await withCheckedContinuation {
                shutdownOwnerWaiter = $0
            }
        }

        isTransitioning = true
        phase = .shuttingDown
        await beginVaultLockdown()
        await vaultSession.lock()
        await confirmVaultLocked()
        phase = .shutdown
        isTransitioning = false

        let lockWaiters = shutdownLockWaiters
        shutdownLockWaiters.removeAll()
        for waiter in lockWaiters {
            waiter.resume(returning: .completed)
        }

        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    var pendingTransitionWaiterCount: Int {
        transitionWaiters.count + shutdownLockWaiters.count
    }

    var isShutdownRequested: Bool {
        shutdownRequested
    }

    var isShutdownInProgress: Bool {
        switch phase {
        case .active:
            return false
        case .shuttingDown, .shutdown:
            return true
        }
    }

    private var failureAvailability:
        PlainpostVaultStatus.Availability?
    {
        switch lastFailure {
        case .ciphertextInvalid:
            return .ciphertextInvalid
        case let .unsupportedVersion(version) where version > 0:
            return .unsupportedVersion(version)
        case .none, .locked, .authorizationCancelled,
             .authorizationFailed, .keyMissing, .keyAmbiguous,
             .invalidKeyLength, .clientUnauthorized, .unsupportedVersion:
            return nil
        }
    }

    private func acquireTransition(
        _ kind: TransitionKind
    ) async -> TransitionAcquisition {
        switch phase {
        case .active:
            if shutdownRequested {
                guard case .lock = kind else {
                    return .rejected
                }
                return await withCheckedContinuation {
                    shutdownLockWaiters.append($0)
                }
            }
            guard isTransitioning else {
                isTransitioning = true
                return .owner
            }
            return await withCheckedContinuation { continuation in
                transitionWaiters.append(
                    QueuedTransition(
                        kind: kind,
                        continuation: continuation
                    )
                )
            }
        case .shuttingDown:
            guard case .lock = kind else {
                return .rejected
            }
            return await withCheckedContinuation {
                shutdownLockWaiters.append($0)
            }
        case .shutdown:
            switch kind {
            case .lock:
                return .completed
            case .unlock:
                return .rejected
            }
        }
    }

    private func finishOwnedTransition() {
        switch phase {
        case .active:
            if shutdownRequested {
                isTransitioning = false
                let waiter = shutdownOwnerWaiter
                shutdownOwnerWaiter = nil
                waiter?.resume()
                return
            }
            guard !transitionWaiters.isEmpty else {
                isTransitioning = false
                return
            }
            let next = transitionWaiters.removeFirst()
            next.continuation.resume(returning: .owner)
        case .shuttingDown:
            guard let shutdownOwnerWaiter else {
                return
            }
            self.shutdownOwnerWaiter = nil
            shutdownOwnerWaiter.resume()
        case .shutdown:
            isTransitioning = false
        }
    }
}
