import Foundation
import Security

public enum IOSDeviceCredentialVaultError: Error, Equatable, Sendable {
    case locked
    case unavailable(OSStatus)
    case invalidData
    case invalidRecordSet
    case rollbackIncomplete(writeStatus: OSStatus, removalStatus: OSStatus)
}

/// A narrow Security boundary so a failed write can be exercised without
/// replacing the Keychain's successful reads, writes, and rollback deletes.
protocol IOSKeychainClient: Sendable {
    func add(_ attributes: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemIOSKeychainClient: IOSKeychainClient {
    func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        SecItemCopyMatching(query, result)
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

/// Provider credentials for direct mail on this device only. This service is
/// separate from account/session credentials and is never synchronizable.
public actor IOSDeviceCredentialVault: CredentialVault {
    private let service: String
    private let client: any IOSKeychainClient

    public init(service: String = "com.marynavdovenko.Plainpost.iOS.mail") {
        self.service = service
        client = SystemIOSKeychainClient()
    }

    init(service: String, client: any IOSKeychainClient) {
        self.service = service
        self.client = client
    }

    public func store(_ secret: Data, for key: CredentialRecordKey) throws {
        let query = query(for: key)
        let changes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = client.update(query as CFDictionary, attributes: changes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw error(for: updateStatus) }

        var attributes = query
        attributes.merge(changes) { _, new in new }
        let addStatus = client.add(attributes as CFDictionary)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = client.update(query as CFDictionary, attributes: changes as CFDictionary)
            guard retryStatus == errSecSuccess else { throw error(for: retryStatus) }
            return
        }
        throw error(for: addStatus)
    }

    public func load(_ key: CredentialRecordKey) throws -> Data? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = client.copyMatching(query as CFDictionary, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(for: status) }
        guard let data = result as? Data else { throw IOSDeviceCredentialVaultError.invalidData }
        return data
    }

    public func remove(_ key: CredentialRecordKey) throws {
        let status = client.delete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(for: status) }
    }

    public func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        try Task.checkCancellation()
        let current = try keys.map { try load($0) }
        guard current.allSatisfy({ $0 == nil }) else { return current }

        let created = try create()
        guard keys.count == created.count, Set(keys).count == keys.count else {
            throw IOSDeviceCredentialVaultError.invalidRecordSet
        }
        try Task.checkCancellation()
        var inserted: [CredentialRecordKey] = []
        for (key, value) in zip(keys, created) {
            var attributes = query(for: key)
            attributes[kSecValueData as String] = value
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = client.add(attributes as CFDictionary)
            guard status == errSecSuccess else {
                var firstRemovalFailure: OSStatus?
                for insertedKey in inserted.reversed() {
                    let removalStatus = client.delete(query(for: insertedKey) as CFDictionary)
                    if removalStatus != errSecSuccess && removalStatus != errSecItemNotFound,
                       firstRemovalFailure == nil {
                        firstRemovalFailure = removalStatus
                    }
                }
                if let firstRemovalFailure {
                    throw IOSDeviceCredentialVaultError.rollbackIncomplete(
                        writeStatus: status,
                        removalStatus: firstRemovalFailure
                    )
                }
                throw error(for: status)
            }
            inserted.append(key)
        }
        return created.map(Optional.some)
    }

    private func query(for key: CredentialRecordKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    private func error(for status: OSStatus) -> IOSDeviceCredentialVaultError {
        if status == errSecInteractionNotAllowed { return .locked }
        return .unavailable(status)
    }
}
