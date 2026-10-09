import Foundation
import Security

public protocol VaultKeyProvider: Sendable {
    func createIfMissing() async throws
    func load(interactive: Bool, prompt: String?) async throws -> Data?
    func countMatchingItems() async throws -> Int
}

public enum MacVaultKeyProviderError: Error, Equatable, Sendable {
    case accessControlCreationFailed
    case invalidResult
    case randomGenerationFailed(OSStatus)
    case unexpectedStatus(OSStatus)
}

public struct MacVaultKeyProvider: VaultKeyProvider, Sendable {
    public static let defaultService = "com.marynavdovenko.Plainpost.Vault"
    public static let defaultAccount = "primary-v1"

    private static let label = "Plainpost Vault Key"
    private static let defaultOperationPrompt =
        "Unlock Plainpost to access your saved mail credentials."

    struct SecItemResult: @unchecked Sendable {
        let status: OSStatus
        let value: Any?
    }

    struct SecItemOperations: @unchecked Sendable {
        let add: @Sendable ([String: Any]) -> OSStatus
        let copyMatching: @Sendable ([String: Any]) -> SecItemResult
        let makeAccessControl:
            @Sendable (CFString, SecAccessControlCreateFlags) -> Any?
        let randomData: @Sendable (Int) throws -> Data

        static let live = Self(
            add: { query in
                SecItemAdd(query as CFDictionary, nil)
            },
            copyMatching: { query in
                var value: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &value)
                return SecItemResult(status: status, value: value)
            },
            makeAccessControl: { accessibility, flags in
                SecAccessControlCreateWithFlags(nil, accessibility, flags, nil)
            },
            randomData: { count in
                var data = Data(count: count)
                let status = data.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return errSecParam
                    }
                    return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
                }
                guard status == errSecSuccess else {
                    throw MacVaultKeyProviderError.randomGenerationFailed(status)
                }
                return data
            }
        )
    }

    private let service: String
    private let account: String
    private let operations: SecItemOperations

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.init(service: service, account: account, operations: .live)
    }

    static func injecting(_ operations: SecItemOperations) -> Self {
        Self(operations: operations)
    }

    private init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        operations: SecItemOperations
    ) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    public func createIfMissing() async throws {
        switch try await countMatchingItems() {
        case 1:
            return
        case 0:
            break
        default:
            throw CredentialVaultError.keyAmbiguous
        }

        guard let accessControl = operations.makeAccessControl(
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence
        ) else {
            throw MacVaultKeyProviderError.accessControlCreationFailed
        }
        let keyData = try operations.randomData(32)
        guard keyData.count == 32 else {
            throw CredentialVaultError.invalidKeyLength
        }

        var query = identityQuery
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecValueData as String] = keyData

        let status = operations.add(query)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // A race or duplicate identity means the sole-key invariant is no
            // longer proven. Never select an arbitrary winner.
            throw CredentialVaultError.keyAmbiguous
        default:
            throw MacVaultKeyProviderError.unexpectedStatus(status)
        }
    }

    public func load(interactive: Bool, prompt: String?) async throws -> Data? {
        var query = identityQuery
        query[kSecReturnData as String] = true
        // Request every exact-identity match so a duplicate can never be
        // silently reduced to an arbitrary first result.
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        if interactive {
            let operationPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            query[kSecUseOperationPrompt as String] =
                operationPrompt?.isEmpty == false
                ? operationPrompt
                : Self.defaultOperationPrompt
        } else {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        let result = operations.copyMatching(query)
        switch result.status {
        case errSecSuccess:
            if let data = result.value as? Data {
                return data
            }
            guard let values = result.value as? [Any] else {
                throw MacVaultKeyProviderError.invalidResult
            }
            switch values.count {
            case 0:
                return nil
            case 1:
                guard let data = values[0] as? Data else {
                    throw MacVaultKeyProviderError.invalidResult
                }
                return data
            default:
                throw CredentialVaultError.keyAmbiguous
            }
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled:
            throw CredentialVaultError.authorizationCancelled
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw CredentialVaultError.authorizationFailed
        default:
            throw MacVaultKeyProviderError.unexpectedStatus(result.status)
        }
    }

    public func countMatchingItems() async throws -> Int {
        var query = identityQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        let result = operations.copyMatching(query)
        switch result.status {
        case errSecItemNotFound:
            return 0
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return 1
        case errSecSuccess:
            if let matches = result.value as? [Any] {
                return matches.count
            }
            if result.value is [String: Any] {
                return 1
            }
            throw MacVaultKeyProviderError.invalidResult
        default:
            throw MacVaultKeyProviderError.unexpectedStatus(result.status)
        }
    }

    private var identityQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: Self.label,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
