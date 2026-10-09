import Foundation
import PlainpostAccounts
import PlainpostCore
import Security
import XCTest
@testable import PlainpostSecrets

final class IOSDeviceCredentialVaultTests: XCTestCase {
    func testProviderPasswordsSurviveActorRecreationAndUseDeviceOnlyAccessibility() async throws {
        let service = "com.marynavdovenko.Plainpost.tests.\(UUID().uuidString)"
        let account = AccountID(rawValue: "ios-direct")
        let imap = MailCredentialKeys.imapPassword(account)
        let smtp = MailCredentialKeys.smtpPassword(account)
        let client = RecordingKeychainClient()

        let first = IOSDeviceCredentialVault(service: service, client: client)
        try await first.store(Data("imap-secret".utf8), for: imap)
        try await first.store(Data("smtp-secret".utf8), for: smtp)

        let reopened = IOSDeviceCredentialVault(service: service, client: client)
        let imapValue = try await reopened.load(imap)
        let smtpValue = try await reopened.load(smtp)
        XCTAssertEqual(imapValue, Data("imap-secret".utf8))
        XCTAssertEqual(smtpValue, Data("smtp-secret".utf8))
        XCTAssertEqual(client.accessibility(service: service, key: imap), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(client.accessibility(service: service, key: smtp), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        try await reopened.remove(imap)
        let removedValue = try await reopened.load(imap)
        let retainedValue = try await reopened.load(smtp)
        XCTAssertNil(removedValue)
        XCTAssertEqual(retainedValue, Data("smtp-secret".utf8))
    }

    func testFailedSecondAddRollsBackFirstNewRecord() async throws {
        let service = "com.marynavdovenko.Plainpost.tests.\(UUID().uuidString)"
        let account = AccountID(rawValue: "ios-rollback")
        let keys = [MailCredentialKeys.imapPassword(account), MailCredentialKeys.smtpPassword(account)]
        let client = RecordingKeychainClient(failingAddNumber: 2)
        let vault = IOSDeviceCredentialVault(service: service, client: client)

        do {
            _ = try await vault.loadOrCreate(keys) { [Data("imap".utf8), Data("smtp".utf8)] }
            XCTFail("The second Keychain add should fail")
        } catch IOSDeviceCredentialVaultError.unavailable(errSecInternalError) {
            // Expected failure after the first item was inserted.
        }
        let reopened = IOSDeviceCredentialVault(service: service, client: client)
        let firstAfterRollback = try await reopened.load(keys[0])
        let secondAfterRollback = try await reopened.load(keys[1])
        XCTAssertNil(firstAfterRollback)
        XCTAssertNil(secondAfterRollback)
    }

    func testExistingPartialSetIsReturnedWithoutCreatingOrReplacingRecords() async throws {
        let service = "com.marynavdovenko.Plainpost.tests.\(UUID().uuidString)"
        let account = AccountID(rawValue: "ios-partial")
        let keys = [MailCredentialKeys.imapPassword(account), MailCredentialKeys.smtpPassword(account)]
        let vault = IOSDeviceCredentialVault(service: service, client: RecordingKeychainClient())
        try await vault.store(Data("existing-imap".utf8), for: keys[0])

        let current = try await vault.loadOrCreate(keys) {
            XCTFail("Partial records must not trigger creation")
            return [Data("new-imap".utf8), Data("new-smtp".utf8)]
        }
        XCTAssertEqual(current[0], Data("existing-imap".utf8))
        XCTAssertNil(current[1])
        let missing = try await vault.load(keys[1])
        XCTAssertNil(missing)
    }

    func testRollbackAttemptsLaterDeletesAfterOneDeleteFails() async throws {
        let service = "com.marynavdovenko.Plainpost.tests.\(UUID().uuidString)"
        let account = AccountID(rawValue: "ios-incomplete-rollback")
        let keys = [
            MailCredentialKeys.imapPassword(account),
            MailCredentialKeys.smtpPassword(account),
            CredentialRecordKey(rawValue: "account:\(account.rawValue):third-password"),
        ]
        let client = RecordingKeychainClient(failingAddNumber: 3, failFirstDelete: true)
        let vault = IOSDeviceCredentialVault(service: service, client: client)

        do {
            _ = try await vault.loadOrCreate(keys) {
                [Data("imap".utf8), Data("smtp".utf8), Data("third".utf8)]
            }
            XCTFail("The third add and first rollback deletion should fail")
        } catch IOSDeviceCredentialVaultError.rollbackIncomplete(
            writeStatus: errSecInternalError,
            removalStatus: errSecInteractionNotAllowed
        ) {
            // The caller must know cleanup was incomplete.
        }

        let first = try await vault.load(keys[0])
        let second = try await vault.load(keys[1])
        let third = try await vault.load(keys[2])
        XCTAssertNil(first, "Rollback must continue to the later deletion")
        XCTAssertEqual(second, Data("smtp".utf8), "The failed deletion remains visible")
        XCTAssertNil(third, "The failed add must not publish its value")
    }

}

private final class RecordingKeychainClient: IOSKeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var adds = 0
    private var deletes = 0
    private var records: [String: [String: Any]] = [:]
    private let failingAddNumber: Int?
    private let failFirstDelete: Bool

    init(failingAddNumber: Int? = nil, failFirstDelete: Bool = false) {
        self.failingAddNumber = failingAddNumber
        self.failFirstDelete = failFirstDelete
    }

    func accessibility(service: String, key: CredentialRecordKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard copyMatching(query as CFDictionary, result: &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            adds += 1
            if adds == failingAddNumber { return errSecInternalError }
            let value = attributes as NSDictionary as! [String: Any]
            guard let id = identifier(value) else { return errSecParam }
            if records[id] != nil { return errSecDuplicateItem }
            records[id] = value
            return errSecSuccess
        }
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        lock.withLock {
            let value = query as NSDictionary as! [String: Any]
            guard let id = identifier(value) else { return errSecParam }
            guard let record = records[id] else { return errSecItemNotFound }
            if value[kSecReturnAttributes as String] as? Bool == true {
                result.pointee = record as CFDictionary
            } else {
                guard let data = record[kSecValueData as String] as? Data else { return errSecParam }
                result.pointee = data as CFData
            }
            return errSecSuccess
        }
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            let value = query as NSDictionary as! [String: Any]
            guard let id = identifier(value) else { return errSecParam }
            guard var record = records[id] else { return errSecItemNotFound }
            record.merge(attributes as NSDictionary as! [String: Any]) { _, new in new }
            records[id] = record
            return errSecSuccess
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            deletes += 1
            if failFirstDelete && deletes == 1 { return errSecInteractionNotAllowed }
            let value = query as NSDictionary as! [String: Any]
            guard let id = identifier(value) else { return errSecParam }
            return records.removeValue(forKey: id) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private func identifier(_ query: [String: Any]) -> String? {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String,
              query[kSecClass as String] as? String == kSecClassGenericPassword as String else {
            return nil
        }
        return "\(service)|\(account)"
    }
}
