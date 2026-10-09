import XCTest
@testable import PlainpostSecrets

final class CredentialVaultTests: XCTestCase {
    func testInMemoryVaultStoresOverwritesAndRemoves() async throws {
        let vault = InMemoryCredentialVault()
        let key = CredentialRecordKey(rawValue: "account:a:imap")

        try await vault.store(Data("first".utf8), for: key)
        try await vault.store(Data("second".utf8), for: key)

        let overwritten = try await vault.load(key)
        XCTAssertEqual(overwritten, Data("second".utf8))

        try await vault.remove(key)

        let removed = try await vault.load(key)
        XCTAssertNil(removed)
    }

    func testInMemoryVaultLoadOrCreatePreservesTheFirstPublishedValue() async throws {
        let vault = InMemoryCredentialVault()
        let key = CredentialRecordKey(rawValue: "device:recovery")

        let initial = try await vault.loadOrCreate([key]) {
            [Data("first-key".utf8)]
        }
        let repeated = try await vault.loadOrCreate([key]) {
            [Data("replacement-key".utf8)]
        }

        let loaded = try await vault.load(key)
        XCTAssertEqual(initial, [Data("first-key".utf8)])
        XCTAssertEqual(repeated, [Data("first-key".utf8)])
        XCTAssertEqual(loaded, Data("first-key".utf8))
    }
}
