import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class SessionKeyManifestTests: XCTestCase {
    func testNewRootScopedCacheIgnoresAndPreservesOldRootRecord() throws {
        let document = SessionKeyManifestStore.bundledManifest
        let oldRoot = BootstrapKeyManifestStore.bundledOfflineRootPublicKey
        let now = try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-09-06T12:00:00Z"))
        let secrets = InMemoryAccountSecretStore()
        let legacyKey = RootScopedManifestCache.key(
            prefix: "session-key-manifest.high-water.v2",
            rootKeyID: BootstrapKeyManifestStore.bundledOfflineRootKeyID,
            rootPublicKey: oldRoot
        )
        let legacyValue = Data("old-root-high-water-must-remain-untouched".utf8)
        XCTAssertTrue(try secrets.compareAndSwap(expected: nil, replacement: legacyValue, key: legacyKey, attributes: .deviceOnly))

        let first = try SessionKeyManifestStore(
            bundledDocument: document,
            offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
            secretStore: secrets,
            clock: { now }
        )
        XCTAssertEqual(try first.verifier().manifestVersion, 1)
        XCTAssertEqual(try secrets.load(legacyKey)?.value, legacyValue)

        let relaunched = try SessionKeyManifestStore(
            bundledDocument: document,
            offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
            secretStore: secrets,
            clock: { now }
        )
        XCTAssertEqual(try relaunched.verifier().documentDigest, try first.verifier().documentDigest)
        XCTAssertEqual(try secrets.load(legacyKey)?.value, legacyValue)
    }

    func testBundledProductionArtifactsUseDistinctAuthoritiesAndAuthenticateOnlyTheirOwnManifest() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures")
        let sessionDocument = try Data(contentsOf: fixtures.appendingPathComponent("production-session-key-manifest-v1.json"))
        let accountDocument = try Data(contentsOf: fixtures.appendingPathComponent("central-bootstrap-manifest-v1.json"))
        let now = try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-09-06T12:00:00Z"))

        XCTAssertEqual(SessionKeyManifestStore.bundledOfflineRootKeyID, "plainpost-session-root-prod-2026-09")
        XCTAssertNotEqual(SessionKeyManifestStore.bundledOfflineRootKeyID, BootstrapKeyManifestStore.bundledOfflineRootKeyID)
        XCTAssertNotEqual(SessionKeyManifestStore.bundledOfflineRootPublicKey, BootstrapKeyManifestStore.bundledOfflineRootPublicKey)
        XCTAssertEqual(SessionKeyManifestStore.bundledManifest, sessionDocument)
        XCTAssertEqual(SessionKeyManifestStore.bundledRootDescriptor, try Data(contentsOf: fixtures.appendingPathComponent("production-session-root-descriptor.json")))

        XCTAssertNoThrow(try SessionKeyManifestVerifier(
            document: sessionDocument,
            offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
            now: now
        ))
        XCTAssertThrowsError(try SessionKeyManifestVerifier(
            document: sessionDocument,
            offlineRootKeyID: BootstrapKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: BootstrapKeyManifestStore.bundledOfflineRootPublicKey,
            now: now
        ))
        XCTAssertNoThrow(try BootstrapKeyManifestStore(
            bundledManifest: accountDocument,
            offlineRootKeyID: BootstrapKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: BootstrapKeyManifestStore.bundledOfflineRootPublicKey,
            secretStore: InMemoryAccountSecretStore(),
            clock: { now }
        ))
        XCTAssertThrowsError(try BootstrapKeyManifestStore(
            bundledManifest: accountDocument,
            offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
            secretStore: InMemoryAccountSecretStore(),
            clock: { now }
        ))
    }

    func testProductionSessionLeafSetMatchesAccountRootSignedMigrationFixture() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let newManifest = try AccountSessionManifestCodec.decodeResponse(Data(contentsOf: fixtures.appendingPathComponent("Protocol/account-v1/fixtures/production-session-key-manifest-v1.json"))).current
        let oldManifest = try AccountSessionManifestCodec.decodeResponse(Data(contentsOf: fixtures.appendingPathComponent("Protocol/account-v1/fixtures/account-root-signed-production-session-key-manifest-test-v1.json"))).current

        XCTAssertEqual(newManifest.manifestVersion, oldManifest.manifestVersion)
        XCTAssertEqual(newManifest.notBefore, oldManifest.notBefore)
        XCTAssertEqual(newManifest.expiresAt, oldManifest.expiresAt)
        XCTAssertEqual(newManifest.keys, oldManifest.keys)
        XCTAssertNotEqual(newManifest.rootKeyID, oldManifest.rootKeyID)
        XCTAssertNotEqual(newManifest.rootSignature, oldManifest.rootSignature)
    }

    func testBundledControllerConstructsWithSessionAuthority() throws {
        let credentials = AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "com.marynavdovenko.Plainpost.AccountTests.SessionAuthority")
        let bootstrap = try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore(), clock: { Date(timeIntervalSince1970: 1_788_696_000) })

        XCTAssertNoThrow(try AccountSessionRuntimeAssembly.bundledController(
            credentials: credentials,
            bootstrapManifest: bootstrap,
            sessionManifestSecretStore: InMemoryAccountSecretStore(),
            baseURL: try XCTUnwrap(URL(string: "https://central.example"))
        ))
    }

    func testCrossLanguageManifestAuthenticatesOfflineLeaseForBoundAccountAndDevice() throws {
        let object = try fixture()
        let manifest = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["manifest"]))
        let root = try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(object["offlineRootPublicKey"] as? String)))
        let now = try XCTUnwrap(AccountWireCodec.parseTimestamp(try XCTUnwrap(object["verificationTime"] as? String)))
        let verifier = try SessionKeyManifestVerifier(document: manifest, offlineRootKeyID: try XCTUnwrap(object["offlineRootKeyID"] as? String), offlineRootPublicKey: root, now: now)
        let account = try PlainpostAccountID(try XCTUnwrap(object["accountID"] as? String))
        let device = try AccountDeviceID(try XCTUnwrap(object["deviceID"] as? String))
        let lease = try XCTUnwrap(object["offlineLease"] as? String)
        XCTAssertEqual(verifier.offlineLeaseVerifier(accountID: account, deviceID: device)(lease, now), AccountWireCodec.parseTimestamp(try XCTUnwrap(object["leaseExpiresAt"] as? String)))
        XCTAssertNil(verifier.offlineLeaseVerifier(accountID: account, deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))(lease, now))
    }

    func testManifestVerifiesCanonicalNodeEnrollmentLeaseByKeyIDAndSignature() throws {
        let object = try fixture()
        let manifest = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["manifest"]))
        let root = try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(object["offlineRootPublicKey"] as? String)))
        let now = try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-05T12:00:01Z"))
        let verifier = try SessionKeyManifestVerifier(document: manifest, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, now: now)
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let node = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let binding = try AccountNodeOperationBindingV1(accountID: account, trustEpoch: AccountTrustEpoch(rawValue: PositiveUInt64(1)), claimID: NodeEnrollmentClaimID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), nodeDeviceID: node, centralAudience: "central.test", action: .enroll, replacedNodeID: nil, replacementRevocationDigest: nil, admissionEvidenceDigest: Data(repeating: 1, count: 32), issuanceDigest: Data(repeating: 2, count: 32))
        let unsigned = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z", serverKeyID: "offline-test-1", signature: Data(repeating: 0, count: 64))
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3]))
        let lease = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: unsigned.leaseID, issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt, serverKeyID: unsigned.serverKeyID, signature: try privateKey.signature(for: AccountTranscript.nodeOfflineLease(unsigned)).rawRepresentation)
        XCTAssertTrue(verifier.verifiesNodeEnrollmentLease(lease, at: now))
        let wrongKey = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: lease.leaseID, issuedAt: lease.issuedAt, expiresAt: lease.expiresAt, serverKeyID: "access-test-1", signature: lease.signature)
        XCTAssertFalse(verifier.verifiesNodeEnrollmentLease(wrongKey, at: now))
        var substituted = lease.signature; substituted[0] ^= 1
        let wrongSignature = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: lease.leaseID, issuedAt: lease.issuedAt, expiresAt: lease.expiresAt, serverKeyID: lease.serverKeyID, signature: substituted)
        XCTAssertFalse(verifier.verifiesNodeEnrollmentLease(wrongSignature, at: now))
    }

    func testManifestRejectsTamperedRootSignature() throws {
        let object = try fixture()
        var response = try XCTUnwrap(object["manifest"] as? [String: Any])
        var current = try XCTUnwrap(response["current"] as? [String: Any]); current["rootSignature"] = String(repeating: "A", count: 86); response["current"] = current
        let root = try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(object["offlineRootPublicKey"] as? String)))
        XCTAssertThrowsError(try SessionKeyManifestVerifier(document: JSONSerialization.data(withJSONObject: response), offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, now: Date(timeIntervalSince1970: 1_786_100_000)))
    }

    func testManifestRejectsDuplicateFieldsBeforeJSONMaterialization() throws {
        let root = Data(repeating: 0, count: 65)
        XCTAssertThrowsError(try SessionKeyManifestVerifier(document: Data(#"{"kind":"account.session-key-manifest-response.v1","kind":"account.session-key-manifest-response.v1","current":{}}"#.utf8), offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, now: Date()))
    }

    func testDeviceOnlyHighWaterAndBoundedWellKnownFetch() async throws {
        let object = try fixture(), document = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["manifest"])), root = try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(object["offlineRootPublicKey"] as? String))), now = try XCTUnwrap(AccountWireCodec.parseTimestamp(try XCTUnwrap(object["verificationTime"] as? String)))
        let secrets = InMemoryAccountSecretStore(), store = try SessionKeyManifestStore(bundledDocument: document, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: secrets, clock: { now })
        try store.accept(document)
        let transport = ManifestTransport(response: AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: document))
        try await store.fetch(using: transport)
        let fetchedPath = await transport.path; XCTAssertEqual(fetchedPath, "/.well-known/plainpost/session-keys")
        let oversized = ManifestTransport(response: AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: Data(repeating: 1, count: AccountWireCodec.maxBodyBytes + 1)))
        await XCTAssertThrowsErrorAsync { try await store.fetch(using: oversized) }
    }

    func testCrossInstanceHighWaterRejectsEqualVersionDocumentEquivocation() throws {
        let object = try fixture(), document = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["manifest"])), root = try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(object["offlineRootPublicKey"] as? String))), now = try XCTUnwrap(AccountWireCodec.parseTimestamp(try XCTUnwrap(object["verificationTime"] as? String)))
        let secrets = InMemoryAccountSecretStore()
        let first = try SessionKeyManifestStore(bundledDocument: document, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: secrets, clock: { now })
        _ = try SessionKeyManifestStore(bundledDocument: document, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: secrets, clock: { now })
        var equivalent = document; equivalent.append(0x20)
        XCTAssertThrowsError(try first.accept(equivalent))
        try first.accept(document)
    }

    func testRotationSafeInitializationPrefersNewerCacheOverExpiredBundleAndAdvancesOlderCache() throws {
        let object = try fixture(), base = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["manifest"])), root = try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(object["offlineRootPublicKey"] as? String)))
        let newer = try signedManifest(from: try XCTUnwrap(object["manifest"] as? [String: Any]), version: 2, expiresAt: "2028-08-01T00:00:00Z")
        let initial = Date(timeIntervalSince1970: 1_786_100_000), afterBundleExpiry = try XCTUnwrap(AccountWireCodec.parseTimestamp("2027-08-02T00:00:00Z"))
        let cacheFirst = InMemoryAccountSecretStore(), first = try SessionKeyManifestStore(bundledDocument: base, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: cacheFirst, clock: { initial })
        try first.accept(newer)
        let restored = try SessionKeyManifestStore(bundledDocument: base, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: cacheFirst, clock: { afterBundleExpiry })
        XCTAssertEqual(try restored.verifier().manifestVersion, 2)
        XCTAssertThrowsError(try SessionKeyManifestStore(bundledDocument: base, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: InMemoryAccountSecretStore(), clock: { afterBundleExpiry }))

        let bundleFirst = InMemoryAccountSecretStore()
        _ = try SessionKeyManifestStore(bundledDocument: base, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: bundleFirst, clock: { initial })
        let advanced = try SessionKeyManifestStore(bundledDocument: newer, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: bundleFirst, clock: { initial })
        XCTAssertEqual(try advanced.verifier().manifestVersion, 2)
        XCTAssertEqual(try SessionKeyManifestStore(bundledDocument: base, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, secretStore: bundleFirst, clock: { initial }).verifier().manifestVersion, 2)
    }

    func testProductionAssemblyUsesValidAuthenticatedCacheOnlyForTypedNetworkFailure() async throws {
        let object = try fixture(), document = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["manifest"])), root = try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(object["offlineRootPublicKey"] as? String)))
        let credentialSecrets = InMemoryAccountSecretStore()
        let credentialService = "com.marynavdovenko.Plainpost.AccountTests.Assembly"
        let credentials = AccountCredentialStore(
            secretStore: credentialSecrets,
            service: credentialService,
            secureEnclaveIdentityProvider: nil,
            secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil,
            secureEnclaveAgreementResolver: nil,
            trustStore: AccountTrustStore(
                secretStore: credentialSecrets,
                service: credentialService + ".Trust",
                operationFence: ImmediateSessionManifestTestFence()
            )
        )
        let (activation, genesisMaterial) = try genesisActivationFixture()
        let account = activation.accountID, device = activation.deviceID
        let session = try AccountSessionCredentials(accountID: account, deviceID: device, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 1, count: 32), offlineLease: try XCTUnwrap(object["offlineLease"] as? String))
        try credentials.commitActivation(activation, credentials: session, genesisMaterial: genesisMaterial)
        let bootstrap = try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore(), clock: { Date(timeIntervalSince1970: 1_788_696_000) })
        _ = try await AccountSessionRuntimeAssembly.production(credentials: credentials, bootstrapManifest: bootstrap, bundledSessionManifest: document, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, sessionManifestSecretStore: InMemoryAccountSecretStore(), transport: FailingManifestTransport(error: AccountRuntimeError.transportFailure), baseURL: URL(string: "https://central.example")!)
        await XCTAssertThrowsErrorAsync { _ = try await AccountSessionRuntimeAssembly.production(credentials: credentials, bootstrapManifest: bootstrap, bundledSessionManifest: document, offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: root, sessionManifestSecretStore: InMemoryAccountSecretStore(), transport: ManifestTransport(response: AccountHTTPResponse(statusCode: 500, headers: ["content-type": "application/json"], body: Data("{}".utf8))), baseURL: URL(string: "https://central.example")!) }
    }

    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func signedManifest(from response: [String: Any], version: UInt64, expiresAt: String) throws -> Data {
        var response = response, current = try XCTUnwrap(response["current"] as? [String: Any]), keys = try XCTUnwrap(current["keys"] as? [[String: Any]])
        current["manifestVersion"] = String(version); current["expiresAt"] = expiresAt
        for index in keys.indices { keys[index]["expiresAt"] = expiresAt }; current["keys"] = keys
        func bytes(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func bytes(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func lp(_ value: Data) -> Data { var length = UInt32(value.count).bigEndian; return withUnsafeBytes(of: &length) { Data($0) } + value }
        var parts = [Data("Plainpost.SessionKeyManifest.v1".utf8), bytes(UInt16(1)), Data("session-root-test-1".utf8), bytes(version), Data("2026-08-01T00:00:00Z".utf8), Data(expiresAt.utf8), bytes(UInt16(keys.count))]
        for key in keys { parts += [Data(try XCTUnwrap(key["keyID"] as? String).utf8), Data(try XCTUnwrap(key["purpose"] as? String).utf8), try XCTUnwrap(Data(testBase64URL: try XCTUnwrap(key["publicKey"] as? String))), Data("2026-08-01T00:00:00Z".utf8), Data(expiresAt.utf8), Data("active".utf8)] }
        let transcript = parts.reduce(into: Data()) { $0.append(lp($1)) }
        let rootPrivate = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([5]))
        var compatibleSignature: Data?
        for _ in 0 ..< 128 {
            let candidate = try AccountWireCodec.normalizedLowSSignature(rootPrivate.signature(for: transcript).rawRepresentation)
            if rootPrivate.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: candidate), for: transcript) { compatibleSignature = candidate; break }
        }
        current["rootSignature"] = AccountWireCodec.encodeBase64URL(try XCTUnwrap(compatibleSignature))
        response["current"] = current
        return try JSONSerialization.data(withJSONObject: response)
    }
}

private actor ManifestTransport: AccountHTTPTransport {
    let response: AccountHTTPResponse; private(set) var path: String?
    init(response: AccountHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse { path = request.url?.path; return response }
}
private struct FailingManifestTransport: AccountHTTPTransport { let error: AccountRuntimeError; func send(_ request: URLRequest) async throws -> AccountHTTPResponse { throw error } }

private struct ImmediateSessionManifestTestFence: AccountOperationFencing {
    func withLock<T>(accountID _: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        try operation()
    }
}

private extension Data {
    init?(testBase64URL value: String) { self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)) }
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async { do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {} }
