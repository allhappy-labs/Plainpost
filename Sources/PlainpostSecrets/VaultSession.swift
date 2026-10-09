import CryptoKit
import Darwin
import Foundation

public actor VaultSession {
    public enum State: Equatable, Sendable {
        case locked
        case unlocking
        case unlocked
    }

    public private(set) var state: State = .locked

    private let provider: any VaultKeyProvider
    private var keyBuffer: SensitiveKeyBuffer?
    private var unlockTask: Task<SensitiveKeyBuffer, Error>?
    private var generation: UInt64 = 0

    public init(provider: any VaultKeyProvider) {
        self.provider = provider
    }

    deinit {
        unlockTask?.cancel()
        keyBuffer?.clear()
    }

    public func unlock(prompt: String) async throws {
        let task: Task<SensitiveKeyBuffer, Error>
        let taskGeneration: UInt64

        switch state {
        case .unlocked:
            return
        case .unlocking:
            guard let existingTask = unlockTask else {
                state = .locked
                throw CredentialVaultError.locked
            }
            task = existingTask
            taskGeneration = generation
        case .locked:
            state = .unlocking
            generation &+= 1
            taskGeneration = generation
            let provider = provider
            task = Task {
                guard let data = try await provider.load(
                    interactive: true,
                    prompt: prompt
                ) else {
                    throw CredentialVaultError.keyMissing
                }

                let buffer = SensitiveKeyBuffer(data)
                do {
                    try Task.checkCancellation()
                    guard buffer.count == 32 else {
                        throw CredentialVaultError.invalidKeyLength
                    }
                    return buffer
                } catch {
                    buffer.clear()
                    throw error
                }
            }
            unlockTask = task
        }

        do {
            let loadedBuffer = try await task.value
            if generation == taskGeneration,
               state == .unlocked,
               keyBuffer === loadedBuffer
            {
                // A coalesced waiter resumed after the first waiter installed
                // the shared buffer.
                return
            }
            guard generation == taskGeneration, state == .unlocking else {
                loadedBuffer.clear()
                throw CredentialVaultError.locked
            }

            keyBuffer = loadedBuffer
            unlockTask = nil
            state = .unlocked
        } catch {
            if generation == taskGeneration, state == .unlocking {
                unlockTask = nil
                keyBuffer?.clear()
                keyBuffer = nil
                state = .locked
            }
            throw error
        }
    }

    public func lock() async {
        generation &+= 1
        state = .locked
        unlockTask?.cancel()
        unlockTask = nil
        keyBuffer?.clear()
        keyBuffer = nil
    }

    public func matchingKeyItemCount() async throws -> Int {
        try await provider.countMatchingItems()
    }

    public func withKey<T: Sendable>(
        _ operation: @Sendable (SymmetricKey) throws -> T
    ) async throws -> T {
        guard state == .unlocked, let keyBuffer else {
            throw CredentialVaultError.locked
        }
        return try keyBuffer.withKey(operation)
    }
}

/// Owns the session's mutable key bytes.
///
/// `explicit_bzero` clears this owned allocation on every explicit lifecycle
/// boundary and in `deinit`. This is best-effort zeroization: Swift `Data`,
/// CryptoKit, system frameworks, and callers may create copies outside this
/// buffer that this type cannot discover or erase.
private final class SensitiveKeyBuffer: @unchecked Sendable {
    private var data: Data
    private var isCleared = false

    init(_ data: Data) {
        self.data = data
    }

    deinit {
        clear()
    }

    var count: Int {
        data.count
    }

    func withKey<T: Sendable>(
        _ operation: @Sendable (SymmetricKey) throws -> T
    ) rethrows -> T {
        try operation(SymmetricKey(data: data))
    }

    func clear() {
        guard !isCleared else { return }
        data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else {
                return
            }
            explicit_bzero(baseAddress, bytes.count)
        }
        data.removeAll(keepingCapacity: false)
        isCleared = true
    }
}

/// Darwin exposes `memset_s` rather than a public `explicit_bzero` symbol.
/// Keep the lifecycle code expressed in explicit-bzero terms while using the
/// platform's guaranteed non-elidable zeroing primitive.
@inline(never)
private func explicit_bzero(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
    _ = memset_s(pointer, count, 0, count)
}
