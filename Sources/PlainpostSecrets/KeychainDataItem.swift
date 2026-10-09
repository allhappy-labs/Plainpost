import Foundation
import Security

public enum KeychainDataItemError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
}

/// One device-only generic-password item holding opaque data. With an access group it lives
/// in the data-protection keychain under that group; unsigned development builds, which lack
/// the group entitlement, fall back to the login keychain without one.
public struct KeychainDataItem: Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(service: String, account: String, accessGroup: String?) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() -> Data? {
        for query in queries() {
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecMissingEntitlement { continue }
            return status == errSecSuccess ? result as? Data : nil
        }
        return nil
    }

    public func save(_ data: Data) throws {
        var lastStatus = errSecSuccess
        for query in queries() {
            lastStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if lastStatus == errSecSuccess { return }
            if lastStatus == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                lastStatus = SecItemAdd(add as CFDictionary, nil)
                if lastStatus == errSecSuccess { return }
            }
            guard lastStatus == errSecMissingEntitlement else { break }
        }
        throw KeychainDataItemError.unexpectedStatus(lastStatus)
    }

    public func delete() throws {
        for query in queries() {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecMissingEntitlement { continue }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainDataItemError.unexpectedStatus(status)
            }
            return
        }
    }

    private func queries() -> [[String: Any]] {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        guard let accessGroup else { return [base] }
        var grouped = base
        grouped[kSecAttrAccessGroup as String] = accessGroup
        grouped[kSecUseDataProtectionKeychain as String] = true
        return [grouped, base]
    }
}
