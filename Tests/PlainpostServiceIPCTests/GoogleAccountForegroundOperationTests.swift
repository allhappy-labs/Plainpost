import Foundation
import XCTest
import PlainpostServiceIPC

final class GoogleAccountForegroundOperationTests: XCTestCase {
    private let accessToken = "ya29.access-secret"
    private let refreshToken = "1//refresh-secret"

    func testGoogleAccountAddRoundTripsAndNeverRendersTokens() throws {
        let payload = PlainpostGoogleAccountSetupPayload(
            displayName: "Ada", email: "ada@gmail.com", identity: "ada@gmail.com",
            accessToken: accessToken, refreshToken: refreshToken, accessTokenExpiresAt: 1_800_003_600)
        let operation = PlainpostForegroundOperation.googleAccountAdd(payload)

        try operation.validate()
        let request = try operation.requestDTO()
        XCTAssertEqual(request.kind, .googleAccountAdd)
        let decoded = try PlainpostForegroundOperation(requestDTO: request)
        guard case .googleAccountAdd(let decodedPayload) = decoded else {
            return XCTFail("Expected Google account setup request.")
        }
        XCTAssertEqual(decodedPayload.email, "ada@gmail.com")
        XCTAssertEqual(decodedPayload.identity, "ada@gmail.com")
        XCTAssertEqual(decodedPayload.accessToken, accessToken)
        XCTAssertEqual(decodedPayload.refreshToken, refreshToken)
        XCTAssertEqual(decodedPayload.accessTokenExpiresAt, 1_800_003_600)

        let result = PlainpostForegroundOperationResult.googleAccountAdd(
            PlainpostAccountSetupSemanticResult(
                accountID: "acc_ada_gmail_com", email: "ada@gmail.com", isIMAPVerified: true,
                isSMTPVerified: true, syncedMessageCount: 3))
        let decodedResult = try PlainpostForegroundOperationResult(responseDTO: result.responseDTO())
        guard case .googleAccountAdd(let semantic) = decodedResult else {
            return XCTFail("Expected Google account setup result.")
        }
        XCTAssertEqual(semantic.accountID, "acc_ada_gmail_com")
        XCTAssertTrue(decodedResult.isSemanticallyCorrelated(with: operation))

        assertRedacted([
            String(describing: payload), String(reflecting: payload),
            String(describing: operation), String(reflecting: operation),
            String(decoding: try result.responseDTO().archivedPayload, as: UTF8.self),
            Mirror(reflecting: payload).children.map { String(describing: $0.value) }.joined(separator: "|"),
            dumped(payload),
        ])
    }

    func testGoogleCredentialReplacementRoundTripsWithEmptyResultAndRedacts() throws {
        let payload = PlainpostGoogleCredentialReplacementPayload(
            accountID: "acc_ada_gmail_com", identity: "ada@gmail.com", accessToken: accessToken,
            refreshToken: refreshToken, accessTokenExpiresAt: 1_800_003_600)
        let operation = PlainpostForegroundOperation.replaceGoogleAccountCredential(payload)

        try operation.validate()
        let request = try operation.requestDTO()
        XCTAssertEqual(request.kind, .replaceGoogleAccountCredential)
        guard case .replaceGoogleAccountCredential(let decodedPayload) = try PlainpostForegroundOperation(requestDTO: request) else {
            return XCTFail("Expected Google credential replacement request.")
        }
        XCTAssertEqual(decodedPayload.accountID, "acc_ada_gmail_com")
        XCTAssertEqual(decodedPayload.refreshToken, refreshToken)

        let result = PlainpostForegroundOperationResult.replaceGoogleAccountCredential
        let response = try result.responseDTO()
        XCTAssertEqual(String(decoding: response.archivedPayload, as: UTF8.self), "{}")
        guard case .replaceGoogleAccountCredential = try PlainpostForegroundOperationResult(responseDTO: response) else {
            return XCTFail("Expected empty replacement result.")
        }

        assertRedacted([
            String(describing: payload), String(reflecting: payload),
            String(describing: operation), String(reflecting: operation),
            Mirror(reflecting: payload).children.map { String(describing: $0.value) }.joined(separator: "|"),
            dumped(payload),
        ])
    }

    func testValidationRejectsMalformedTokensIdentitiesAndExpiry() throws {
        let valid = (identity: "ada@gmail.com", token: accessToken, expiry: 1_800_003_600.0)
        let invalid: [(String, String, String, Double)] = [
            ("", valid.token, refreshToken, valid.expiry),
            ("ada gmail.com", valid.token, refreshToken, valid.expiry),
            ("ada@gmail.com\n", valid.token, refreshToken, valid.expiry),
            (valid.identity, "", refreshToken, valid.expiry),
            (valid.identity, "ya29 token", refreshToken, valid.expiry),
            (valid.identity, valid.token, "1//refresh\r\n", valid.expiry),
            (valid.identity, valid.token, String(repeating: "r", count: 16_385), valid.expiry),
            (valid.identity, valid.token, refreshToken, .nan),
            (valid.identity, valid.token, refreshToken, 0),
        ]
        for (identity, access, refresh, expiry) in invalid {
            let add = PlainpostForegroundOperation.googleAccountAdd(
                PlainpostGoogleAccountSetupPayload(
                    displayName: "Ada", email: "ada@gmail.com", identity: identity, accessToken: access,
                    refreshToken: refresh, accessTokenExpiresAt: expiry))
            XCTAssertThrowsError(try add.validate()) {
                XCTAssertEqual($0 as? PlainpostForegroundOperationError, .invalidEnvelope)
            }
            let replace = PlainpostForegroundOperation.replaceGoogleAccountCredential(
                PlainpostGoogleCredentialReplacementPayload(
                    accountID: "acc_ada_gmail_com", identity: identity, accessToken: access,
                    refreshToken: refresh, accessTokenExpiresAt: expiry))
            XCTAssertThrowsError(try replace.validate())
        }
    }

    func testMismatchedKindNeverEchoesTokens() throws {
        let request = try PlainpostForegroundOperation.replaceGoogleAccountCredential(
            PlainpostGoogleCredentialReplacementPayload(
                accountID: "acc_ada_gmail_com", identity: "ada@gmail.com", accessToken: accessToken,
                refreshToken: refreshToken, accessTokenExpiresAt: 1_800_003_600)
        ).requestDTO()
        let mismatched = try XCTUnwrap(
            PlainpostForegroundOperationRequestDTO(
                schemaVersion: request.schemaVersion, kind: .googleAccountAdd,
                archivedPayload: request.archivedPayload))

        XCTAssertThrowsError(try PlainpostForegroundOperation(requestDTO: mismatched)) {
            XCTAssertEqual($0 as? PlainpostForegroundOperationError, .invalidEnvelope)
            assertRedacted([String(describing: $0), String(reflecting: $0)])
        }
    }

    private func assertRedacted(_ renderings: [String], file: StaticString = #filePath, line: UInt = #line) {
        for rendering in renderings {
            XCTAssertFalse(rendering.contains("access-secret"), rendering, file: file, line: line)
            XCTAssertFalse(rendering.contains("refresh-secret"), rendering, file: file, line: line)
        }
    }

    private func dumped<T>(_ value: T) -> String {
        var output = ""
        dump(value, to: &output)
        return output
    }
}
