import CryptoKit
import XCTest
@testable import PlainpostSecrets

final class VaultCryptorTests: XCTestCase {
    func testCiphertextRoundTripsForItsRecordKey() throws {
        let master = SymmetricKey(size: .bits256)
        let cryptor = VaultCryptor()
        let key = CredentialRecordKey(rawValue: "account:a:imap")

        let sealed = try cryptor.seal(Data("secret".utf8), for: key, using: master)

        XCTAssertEqual(try cryptor.open(sealed, for: key, using: master), Data("secret".utf8))
    }

    func testCiphertextCannotMoveBetweenRecordKeys() throws {
        let master = SymmetricKey(size: .bits256)
        let cryptor = VaultCryptor()
        let source = CredentialRecordKey(rawValue: "account:a:imap")
        let destination = CredentialRecordKey(rawValue: "account:b:imap")
        let sealed = try cryptor.seal(Data("secret".utf8), for: source, using: master)

        XCTAssertThrowsError(try cryptor.open(sealed, for: destination, using: master))
    }

    func testCiphertextRejectsAnUnsupportedVersion() throws {
        let cryptor = VaultCryptor()
        let key = CredentialRecordKey(rawValue: "account:a:imap")
        let sealed = SealedCredential(combined: Data([2]))

        XCTAssertThrowsError(try cryptor.open(sealed, for: key, using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CredentialVaultError, .unsupportedVersion(2))
        }
    }

    func testCiphertextRejectsMalformedPayload() throws {
        let cryptor = VaultCryptor()
        let key = CredentialRecordKey(rawValue: "account:a:imap")
        let sealed = SealedCredential(combined: Data([1]))

        XCTAssertThrowsError(try cryptor.open(sealed, for: key, using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CredentialVaultError, .ciphertextInvalid)
        }
    }

    func testSealRejectsNon256BitMasterKeys() throws {
        let cryptor = VaultCryptor()
        let recordKey = CredentialRecordKey(rawValue: "account:a:imap")

        for keySize: SymmetricKeySize in [.bits128, .bits192] {
            XCTAssertThrowsError(
                try cryptor.seal(
                    Data("secret".utf8),
                    for: recordKey,
                    using: SymmetricKey(size: keySize)
                )
            ) { error in
                XCTAssertEqual(error as? CredentialVaultError, .invalidKeyLength)
            }
        }
    }

    func testOpenRejectsNon256BitMasterKeys() throws {
        let cryptor = VaultCryptor()
        let recordKey = CredentialRecordKey(rawValue: "account:a:imap")
        let sealed = try cryptor.seal(
            Data("secret".utf8),
            for: recordKey,
            using: SymmetricKey(size: .bits256)
        )

        for keySize: SymmetricKeySize in [.bits128, .bits192] {
            XCTAssertThrowsError(
                try cryptor.open(
                    sealed,
                    for: recordKey,
                    using: SymmetricKey(size: keySize)
                )
            ) { error in
                XCTAssertEqual(error as? CredentialVaultError, .invalidKeyLength)
            }
        }
    }
}
