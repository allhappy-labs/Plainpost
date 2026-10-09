import Darwin
import Foundation
import XCTest
@testable import PlainpostSecrets

final class CredentialCapabilityTests: XCTestCase {
    func testRoundTripPreservesSemanticRecords() throws {
        let records = [
            CredentialRecordKey(rawValue: "account:alpha:imap-password"): Data("imap secret".utf8),
            CredentialRecordKey(rawValue: "account:alpha:smtp-password"): Data("smtp secret".utf8),
        ]

        let encoded = try CredentialCapabilityCodec.encode(records: records)
        XCTAssertEqual(try CredentialCapabilityCodec.decode(encoded), records)
    }

    func testPermitsGoogleRefreshTokenSuffixAndStillRejectsUnknownSuffixes() throws {
        let permitted = [
            CredentialRecordKey(rawValue: "account:alpha:google-refresh-token"): Data("1//refresh".utf8),
            CredentialRecordKey(rawValue: "account:alpha:imap-password"): Data("imap".utf8),
        ]
        XCTAssertEqual(try CredentialCapabilityCodec.decode(CredentialCapabilityCodec.encode(records: permitted)), permitted)

        for rawKey in [
            "account:alpha:google-access-token",
            "account::google-refresh-token",
            "account:google-refresh-token",
            "alpha:google-refresh-token",
            "account:alpha:google-refresh-token-extra",
        ] {
            XCTAssertThrowsError(
                try CredentialCapabilityCodec.encode(records: [CredentialRecordKey(rawValue: rawKey): Data("x".utf8)]),
                rawKey
            )
        }
    }

    func testPermitsMicrosoftRefreshTokenButNotAccessToken() throws {
        let key = CredentialRecordKey(rawValue: "account:alpha:microsoft-refresh-token")
        let records = [key: Data("refresh".utf8)]
        XCTAssertEqual(try CredentialCapabilityCodec.decode(CredentialCapabilityCodec.encode(records: records)), records)
        XCTAssertThrowsError(try CredentialCapabilityCodec.encode(records: [
            CredentialRecordKey(rawValue: "account:alpha:microsoft-access-token"): Data("secret".utf8)
        ]))
    }

    func testDecodeRejectsTamperedAndTruncatedPayloads() throws {
        let records = [
            CredentialRecordKey(rawValue: "account:alpha:imap-password"): Data("imap secret".utf8),
            CredentialRecordKey(rawValue: "account:alpha:smtp-password"): Data("smtp secret".utf8),
        ]
        let encoded = try CredentialCapabilityCodec.encode(records: records)
        var tampered = encoded
        tampered[tampered.startIndex] ^= 0x01

        XCTAssertThrowsError(try CredentialCapabilityCodec.decode(tampered))
        XCTAssertThrowsError(try CredentialCapabilityCodec.decode(encoded.dropLast()))
    }

    func testDecodeRejectsDuplicateRecordKeys() throws {
        let key = CredentialRecordKey(rawValue: "account:alpha:imap-password")
        let encoded = try CredentialCapabilityCodec.encodeUncheckedForTesting([
            (key, Data("one".utf8)),
            (key, Data("two".utf8)),
        ])

        XCTAssertThrowsError(try CredentialCapabilityCodec.decode(encoded))
    }

    func testRoundTripPermitsSinglePurposeAccountCredential() throws {
        let records = [
            CredentialRecordKey(rawValue: "account:alpha:imap-password"): Data("secret".utf8),
        ]

        XCTAssertEqual(try CredentialCapabilityCodec.decode(CredentialCapabilityCodec.encode(records: records)), records)
    }

    func testRoundTripPreservesMultipleCompleteAccounts() throws {
        let records = [
            CredentialRecordKey(rawValue: "account:alpha:imap-password"): Data("imap alpha".utf8),
            CredentialRecordKey(rawValue: "account:alpha:smtp-password"): Data("smtp alpha".utf8),
            CredentialRecordKey(rawValue: "account:beta:imap-password"): Data("imap beta".utf8),
            CredentialRecordKey(rawValue: "account:beta:smtp-password"): Data("smtp beta".utf8),
        ]

        XCTAssertEqual(try CredentialCapabilityCodec.decode(CredentialCapabilityCodec.encode(records: records)), records)
    }

    func testEncodeRejectsOversizedSecrets() {
        let records = [
            CredentialRecordKey(rawValue: "account:alpha:imap-password"): Data(repeating: 0x42, count: CredentialCapabilityCodec.maximumSecretLength + 1)
        ]

        XCTAssertThrowsError(try CredentialCapabilityCodec.encode(records: records))
    }

    func testRequiredInheritedCapabilityRejectsMissingDescriptor() async {
        do {
            _ = try await InheritedCredentialCapability.readVault(required: true)
            XCTFail("Expected a missing inherited credential descriptor to fail.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .clientUnauthorized)
        }
    }

    func testInheritedCapabilityReadsPartialPipeWritesAndClosesDescriptor() async throws {
        let encoded = try CredentialCapabilityCodec.encode(records: [
            CredentialRecordKey(rawValue: "account:alpha:imap-password"): Data("imap".utf8),
            CredentialRecordKey(rawValue: "account:alpha:smtp-password"): Data("smtp".utf8),
        ])

        let maybeVault = try await withCapabilityPayload([Data(encoded.prefix(7)), Data(encoded.dropFirst(7))]) {
            try await InheritedCredentialCapability.readVault(
                required: true,
                descriptor: InheritedCredentialCapability.fileDescriptor
            )
        }
        let vault = try XCTUnwrap(maybeVault)

        let imap = try await vault.load(CredentialRecordKey(rawValue: "account:alpha:imap-password"))
        XCTAssertEqual(imap, Data("imap".utf8))
        XCTAssertEqual(fcntl(InheritedCredentialCapability.fileDescriptor, F_GETFD), -1)
    }

    func testSinglePurposeInheritedCapabilityClassifiesAbsentCompanionAsMissing() async throws {
        let imapKey = CredentialRecordKey(rawValue: "account:alpha:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:alpha:smtp-password")
        let imapOnly = try CredentialCapabilityCodec.encode(records: [imapKey: Data("imap".utf8)])

        let maybeIMAPVault = try await withCapabilityPayload([imapOnly]) {
            try await InheritedCredentialCapability.readVault(
                required: true,
                descriptor: InheritedCredentialCapability.fileDescriptor
            )
        }
        let imapVault = try XCTUnwrap(maybeIMAPVault)

        let imap = try await imapVault.load(imapKey)
        let smtp = try await imapVault.load(smtpKey)
        XCTAssertEqual(imap, Data("imap".utf8))
        XCTAssertNil(smtp)

        let smtpOnly = try CredentialCapabilityCodec.encode(records: [smtpKey: Data("smtp".utf8)])
        let maybeSMTPVault = try await withCapabilityPayload([smtpOnly]) {
            try await InheritedCredentialCapability.readVault(
                required: true,
                descriptor: InheritedCredentialCapability.fileDescriptor
            )
        }
        let smtpVault = try XCTUnwrap(maybeSMTPVault)

        let absentIMAP = try await smtpVault.load(imapKey)
        let smtpResult = try await smtpVault.load(smtpKey)
        XCTAssertNil(absentIMAP)
        XCTAssertEqual(smtpResult, Data("smtp".utf8))
    }

    func testMalformedPresentInheritedCapabilityFailsWithoutFallbackAndClosesDescriptor() async throws {
        do {
            _ = try await withCapabilityPayload([Data("malformed".utf8)]) {
                try await InheritedCredentialCapability.readVault(
                    required: true,
                    descriptor: InheritedCredentialCapability.fileDescriptor
                )
            }
            XCTFail("Expected malformed capability to fail closed.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .ciphertextInvalid)
        }
        XCTAssertEqual(fcntl(InheritedCredentialCapability.fileDescriptor, F_GETFD), -1)
    }

    private func withCapabilityPayload<T>(
        _ chunks: [Data],
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        let original = dup(InheritedCredentialCapability.fileDescriptor)
        XCTAssertEqual(dup2(descriptors[0], InheritedCredentialCapability.fileDescriptor), InheritedCredentialCapability.fileDescriptor)
        _ = close(descriptors[0])

        let writer = descriptors[1]
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                _ = close(writer)
                completion.signal()
            }
            for chunk in chunks {
                try? Self.writeAll(chunk, to: writer)
            }
        }

        defer {
            _ = close(InheritedCredentialCapability.fileDescriptor)
            if original >= 0 {
                _ = dup2(original, InheritedCredentialCapability.fileDescriptor)
                _ = close(original)
            }
        }
        let result = try await operation()
        XCTAssertEqual(completion.wait(timeout: .now() + 1), .success)
        return result
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var base = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = write(descriptor, base, remaining)
                guard count > 0 else { throw POSIXError(.EIO) }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
    }
}
