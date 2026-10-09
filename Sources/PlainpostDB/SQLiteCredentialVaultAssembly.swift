import Foundation
import PlainpostSecrets

public struct SQLiteCredentialVaultAssembly: Sendable {
    public let vault: EncryptedCredentialVault
    public let session: VaultSession

    private let provider: any VaultKeyProvider
    private let repository: SQLiteCredentialCiphertextRepository
    private let store: SQLiteMailStore

    public init(
        store: SQLiteMailStore,
        provider: any VaultKeyProvider
    ) {
        let repository = SQLiteCredentialCiphertextRepository(
            databaseWriter: store.databaseWriter
        )
        let session = VaultSession(provider: provider)
        self.provider = provider
        self.repository = repository
        self.store = store
        self.session = session
        vault = EncryptedCredentialVault(repository: repository, session: session)
    }

    public func prepareForegroundUnlock() async throws {
        let hasRecords = try await repository.hasRecords()
        switch try await provider.countMatchingItems() {
        case 0 where hasRecords:
            throw CredentialVaultError.keyMissing
        case 0:
            try await provider.createIfMissing()
        case 1:
            break
        default:
            throw CredentialVaultError.keyAmbiguous
        }
    }

    /// "Start Over with Saved Sign-ins": when the key that opens the saved
    /// sign-ins can never be read again (Plainpost reinstalled under another
    /// developer identity), moves every encrypted credential into the archive
    /// table, kept rather than deleted, so a fresh key can be created. Each
    /// account that lost its sign-in is marked as needing to sign in again.
    ///
    /// Refuses while any key item exists, so it can never set aside
    /// credentials a present key could still open. With no records it changes
    /// nothing.
    public func archiveRecordsAfterKeyLoss() async throws {
        switch try await provider.countMatchingItems() {
        case 0:
            break
        case 1:
            throw VaultStartOverRefusal.keyPresent
        default:
            throw CredentialVaultError.keyAmbiguous
        }
        if try await repository.archiveAllAfterKeyLoss() > 0 {
            MailStoreChangeSignal.post(scope: .accounts)
        }
    }

    public func unlockForeground(prompt: String) async throws {
        try await prepareForegroundUnlock()
        try await session.unlock(prompt: prompt)
        try await recoverPendingAccountDeletions()
    }

    public func recoverPendingAccountDeletions() async throws {
        try await store.recoverPendingAccountDeletions(credentials: vault)
    }
}

/// Why "Start Over with Saved Sign-ins" was refused.
public enum VaultStartOverRefusal: Error, Equatable, Sendable {
    /// A vault key item exists: the saved sign-ins may still be readable.
    case keyPresent
}
