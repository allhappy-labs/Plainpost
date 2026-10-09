import Foundation
import LocalAuthentication
import Security

public enum KeychainCredentialError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData
    case timedOut
}

public enum KeychainCredentialAvailability: Equatable, Sendable {
    case available
    case missing
    case interactionRequired
    case unavailable(OSStatus)

    public init(status: OSStatus) {
        switch status {
        case errSecSuccess:
            self = .available
        case errSecItemNotFound:
            self = .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            self = .interactionRequired
        default:
            self = .unavailable(status)
        }
    }
}

public struct KeychainCredentialStore: Sendable {
    private let service: String
    private static let readQueue = DispatchQueue(label: "com.marynavdovenko.Plainpost.keychain-read")
    private static let interactiveReadQueue = DispatchQueue(label: "com.marynavdovenko.Plainpost.keychain-interactive-read")

    public init(service: String = "Plainpost") {
        self.service = service
    }

    public func savePassword(_ password: String, account: String) throws {
        try deletePassword(account: account)
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    @discardableResult
    public func addDeviceOnlyDataIfAbsent(_ data: Data, account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return false
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        return true
    }

    public func readPassword(account: String) throws -> String? {
        let service = service

        return try Self.awaitRead {
            let context = LAContext()
            context.interactionNotAllowed = true
            let query = Self.readQuery(service: service, account: account, context: context)
            return try Self.readPassword(matching: query)
        }
    }

    public func credentialAvailability(account: String) -> KeychainCredentialAvailability {
        do {
            return try itemExists(account: account) ? .interactionRequired : .missing
        } catch KeychainCredentialError.unexpectedStatus(let status) {
            return KeychainCredentialAvailability(status: status)
        } catch {
            return .unavailable(errSecInternalError)
        }
    }

    public func unlockPassword(account: String, prompt: String) throws -> String? {
        let service = service
        return try Self.awaitInteractiveRead {
            let context = LAContext()
            return try Self.readPassword(
                matching: Self.interactiveReadQuery(
                    service: service,
                    account: account,
                    prompt: prompt,
                    context: context
                )
            )
        }
    }

    static func awaitInteractiveRead<Value: Sendable>(
        operation: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        let result = KeychainReadResult<Value>()
        let completion = DispatchSemaphore(value: 0)
        interactiveReadQueue.async {
            result.set(Result(catching: operation))
            completion.signal()
        }
        completion.wait()
        guard let outcome = result.value else {
            throw KeychainCredentialError.timedOut
        }
        return try outcome.get()
    }

    public func readData(account: String) throws -> Data? {
        let service = service
        return try Self.awaitRead {
            let context = LAContext()
            context.interactionNotAllowed = true
            let query = Self.readQuery(service: service, account: account, context: context)
            return try Self.readData(matching: query)
        }
    }

    private func itemExists(account: String) throws -> Bool {
        let service = service
        return try Self.awaitRead {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(
                Self.metadataQuery(service: service, account: account) as CFDictionary,
                &result
            )
            switch status {
            case errSecSuccess:
                return true
            case errSecItemNotFound:
                return false
            default:
                throw KeychainCredentialError.unexpectedStatus(status)
            }
        }
    }

    static func awaitRead<Value: Sendable>(
        timeout: TimeInterval = 5,
        operation: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        let result = KeychainReadResult<Value>()
        let completion = DispatchSemaphore(value: 0)
        readQueue.async {
            result.set(Result(catching: operation))
            completion.signal()
        }
        guard completion.wait(timeout: .now() + timeout) == .success else {
            throw KeychainCredentialError.timedOut
        }
        guard let outcome = result.value else {
            throw KeychainCredentialError.timedOut
        }
        return try outcome.get()
    }

    private static func readPassword(matching query: [String: Any]) throws -> String? {
        guard let data = try readData(matching: query) else { return nil }
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError.invalidData
        }
        return password
    }

    private static func readData(matching query: [String: Any]) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainCredentialError.invalidData
        }
        return data
    }

    static func readQuery(service: String, account: String, context: LAContext) -> [String: Any] {
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            // Legacy macOS Keychain ACL prompts are not governed reliably by
            // LAContext.interactionNotAllowed. Skip protected matches here and
            // detect their existence separately through unencrypted metadata.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
    }

    static func metadataQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
    }

    static func interactiveReadQuery(
        service: String,
        account: String,
        prompt: String,
        context: LAContext
    ) -> [String: Any] {
        context.interactionNotAllowed = false
        context.localizedReason = prompt
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    public func deletePassword(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }
}

private final class KeychainReadResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
