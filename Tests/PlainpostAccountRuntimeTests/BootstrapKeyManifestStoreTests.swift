import Foundation
import CryptoKit
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class BootstrapKeyManifestStoreTests: XCTestCase {
    func testRootMigrationIgnoresAndPreservesLegacyCacheRecord() throws {
        let secrets = InMemoryAccountSecretStore()
        let legacyKey = AccountSecretKey(service: "com.marynavdovenko.Plainpost.Account", account: "manifest.cache.v2")
        let legacyValue = Data("old-root-cache-must-remain-untouched".utf8)
        XCTAssertTrue(try secrets.compareAndSwap(expected: nil, replacement: legacyValue, key: legacyKey, attributes: .deviceOnly))

        let first = try testManifestStore(secretStore: secrets, clock: { Date(timeIntervalSince1970: 1_786_017_600) })
        XCTAssertEqual(first.currentManifest().manifestVersion.wireValue, "1")
        XCTAssertEqual(try secrets.load(legacyKey)?.value, legacyValue)

        let relaunched = try testManifestStore(secretStore: secrets, clock: { Date(timeIntervalSince1970: 1_786_017_600) })
        XCTAssertEqual(relaunched.currentManifest(), first.currentManifest())
        XCTAssertEqual(try secrets.load(legacyKey)?.value, legacyValue)
    }

    func testBundledTrustAnchorIsTheProductionRootRatherThanTheTaskOneFixtureRoot() throws {
        XCTAssertEqual(BootstrapKeyManifestStore.bundledOfflineRootKeyID, "plainpost-root-prod-2026-09")
        XCTAssertFalse(String(decoding: BootstrapKeyManifestStore.bundledManifest, as: UTF8.self).contains("plainpost-root-2026-01"))
    }

    func testBundledProductionArtifactsAreByteIdenticalToCommittedPublicFixtures() throws {
        XCTAssertEqual(BootstrapKeyManifestStore.bundledManifest, try Data(contentsOf: publicFixture("central-bootstrap-manifest-v1.json")))
        XCTAssertEqual(BootstrapKeyManifestStore.bundledRootDescriptor, try Data(contentsOf: publicFixture("production-root-descriptor.json")))
    }

    func testBundledProductionManifestVerifiesUnderTheDescriptorRootAndContainsAllRequiredRoles() throws {
        let descriptor = try XCTUnwrap(try JSONSerialization.jsonObject(with: BootstrapKeyManifestStore.bundledRootDescriptor) as? [String: Any])
        XCTAssertEqual(descriptor["rootKeyID"] as? String, "plainpost-root-prod-2026-09")
        XCTAssertEqual(descriptor["publicKeySHA256"] as? String, "6dbbc1742af735a411f8121ce75572166ef9adc4c3b6727a1ceefc1a6a575ea6")
        XCTAssertEqual(descriptor["publicKey"] as? String, AccountWireCodec.encodeBase64URL(BootstrapKeyManifestStore.bundledOfflineRootPublicKey))

        let manifest = try AccountWireCodec.decodeManifest(BootstrapKeyManifestStore.bundledManifest)
        XCTAssertEqual(manifest.rootKeyID, "plainpost-root-prod-2026-09")
        XCTAssertEqual(Set(manifest.keys.map(\.purpose)), Set([.bootstrapChallenge, .trustPagination, .recoveryAuthorization]))
        XCTAssertNoThrow(try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore(), clock: { Date(timeIntervalSince1970: 1_788_696_000) }))
    }

    func testManifestSelectsOnlyActivePurposeKeyAtSignedObjectTime() throws {
        let store = try testManifestStore(clock: { Date(timeIntervalSince1970: 1_786_017_600) })
        let bootstrap = try store.key(id: "bootstrap-2026-01", purpose: AccountKeyPurpose.bootstrapChallenge, signedAt: "2026-08-03T10:00:00Z")
        XCTAssertEqual(bootstrap.count, 65)
        XCTAssertThrowsError(try store.key(id: "bootstrap-2026-01", purpose: AccountKeyPurpose.recoveryAuthorization, signedAt: "2026-08-03T10:00:00Z"))
        XCTAssertThrowsError(try store.key(id: "bootstrap-2026-01", purpose: AccountKeyPurpose.bootstrapChallenge, signedAt: "2028-01-01T00:00:00Z"))
    }

    func testManifestRejectsUnknownRootBeforePersistingIt() throws {
        var manifest = try fixtureJSONObject()
        manifest["rootKeyID"] = "attacker-root"
        let store = try testManifestStore(clock: { Date(timeIntervalSince1970: 1_786_017_600) })
        XCTAssertThrowsError(try store.accept(JSONSerialization.data(withJSONObject: manifest)))
        XCTAssertEqual(store.currentManifest().rootKeyID, "plainpost-root-2026-01")
    }

    func testManifestAcceptsSkippedHigherVersionAndRejectsRollbackOrSameVersionEquivocation() throws {
        let store = try testManifestStore(clock: { Date(timeIntervalSince1970: 1_786_017_600) })
        let higher = try signedManifest(version: "3")
        try store.accept(higher)
        XCTAssertEqual(store.currentManifest().manifestVersion.wireValue, "3")

        XCTAssertThrowsError(try store.accept(try fixtureData()))
        var equivocation = try fixtureJSONObject()
        equivocation["manifestVersion"] = "3"
        var keys = try XCTUnwrap(equivocation["keys"] as? [[String: Any]])
        keys[0]["status"] = "revoked"
        equivocation["keys"] = keys
        XCTAssertThrowsError(try store.accept(try signedManifest(equivocation)))
        XCTAssertEqual(store.currentManifest().manifestVersion.wireValue, "3")
    }

    func testResponseAcceptancePersistsTheHigherManifestForRelaunch() throws {
        let secrets = InMemoryAccountSecretStore()
        let first = try testManifestStore(secretStore: secrets, clock: { Date(timeIntervalSince1970: 1_786_017_600) })
        let higher = try signedManifest(version: "3")
        let response: [String: Any] = [
            "kind": "central.bootstrap-key-manifest-response.v1",
            "current": try XCTUnwrap(try JSONSerialization.jsonObject(with: higher) as? [String: Any]),
            "overlap": [],
        ]
        try first.acceptManifestResponse(try JSONSerialization.data(withJSONObject: response))

        let relaunched = try testManifestStore(secretStore: secrets, clock: { Date(timeIntervalSince1970: 1_786_017_600) })
        XCTAssertEqual(relaunched.currentManifest().manifestVersion.wireValue, "3")
    }

    func testRecoveryAuthorizationUsesOnlyItsPurposeScopedManifestKeyAndMatchesExpectedRecovery() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let message = try XCTUnwrap((root["recoveryAuthorization"] as? [String: Any])?["message"])
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: message))
        let store = try testManifestStore(clock: { Date(timeIntervalSince1970: 1_785_751_620) })
        XCTAssertNoThrow(try verify(authorization, with: store))
        let wrongPurpose = try AccountRecoveryAuthorization(authorizationID: authorization.authorizationID, accountID: authorization.accountID, epoch: authorization.epoch, deviceID: authorization.deviceID, platform: authorization.platform, publicBundle: authorization.publicBundle, priorCommitDigest: authorization.priorCommitDigest, exchangeRequestDigest: authorization.exchangeRequestDigest, issuedAt: authorization.issuedAt, expiresAt: authorization.expiresAt, serverKeyID: "bootstrap-2026-01", serverSignature: authorization.serverSignature)
        XCTAssertThrowsError(try verify(wrongPurpose, with: store))

        XCTAssertThrowsError(try store.verifyRecoveryAuthorization(authorization, expectedAccountID: try PlainpostAccountID("00000000-0000-0000-0000-000000000099"), expectedEpoch: authorization.epoch, expectedDeviceID: authorization.deviceID, expectedPlatform: authorization.platform, expectedPublicBundle: authorization.publicBundle, expectedPriorCommitDigest: authorization.priorCommitDigest, expectedExchangeRequestDigest: authorization.exchangeRequestDigest))
        XCTAssertThrowsError(try store.verifyRecoveryAuthorization(authorization, expectedAccountID: authorization.accountID, expectedEpoch: AccountTrustEpoch(rawValue: try PositiveUInt64(authorization.epoch.value + 1)), expectedDeviceID: authorization.deviceID, expectedPlatform: authorization.platform, expectedPublicBundle: authorization.publicBundle, expectedPriorCommitDigest: authorization.priorCommitDigest, expectedExchangeRequestDigest: authorization.exchangeRequestDigest))
        XCTAssertThrowsError(try store.verifyRecoveryAuthorization(authorization, expectedAccountID: authorization.accountID, expectedEpoch: authorization.epoch, expectedDeviceID: try AccountDeviceID("00000000-0000-0000-0000-000000000099"), expectedPlatform: authorization.platform, expectedPublicBundle: authorization.publicBundle, expectedPriorCommitDigest: authorization.priorCommitDigest, expectedExchangeRequestDigest: authorization.exchangeRequestDigest))
        XCTAssertThrowsError(try store.verifyRecoveryAuthorization(authorization, expectedAccountID: authorization.accountID, expectedEpoch: authorization.epoch, expectedDeviceID: authorization.deviceID, expectedPlatform: authorization.platform == .macos ? .ios : .macos, expectedPublicBundle: authorization.publicBundle, expectedPriorCommitDigest: authorization.priorCommitDigest, expectedExchangeRequestDigest: authorization.exchangeRequestDigest))
        XCTAssertThrowsError(try store.verifyRecoveryAuthorization(authorization, expectedAccountID: authorization.accountID, expectedEpoch: authorization.epoch, expectedDeviceID: authorization.deviceID, expectedPlatform: authorization.platform, expectedPublicBundle: try alternateBundle(), expectedPriorCommitDigest: authorization.priorCommitDigest, expectedExchangeRequestDigest: authorization.exchangeRequestDigest))
        XCTAssertThrowsError(try store.verifyRecoveryAuthorization(authorization, expectedAccountID: authorization.accountID, expectedEpoch: authorization.epoch, expectedDeviceID: authorization.deviceID, expectedPlatform: authorization.platform, expectedPublicBundle: authorization.publicBundle, expectedPriorCommitDigest: Data(repeating: 0, count: 32), expectedExchangeRequestDigest: authorization.exchangeRequestDigest))
        XCTAssertThrowsError(try store.verifyRecoveryAuthorization(authorization, expectedAccountID: authorization.accountID, expectedEpoch: authorization.epoch, expectedDeviceID: authorization.deviceID, expectedPlatform: authorization.platform, expectedPublicBundle: authorization.publicBundle, expectedPriorCommitDigest: authorization.priorCommitDigest, expectedExchangeRequestDigest: Data(repeating: 0, count: 32)))
    }

    func testLiveRecoverySelectsAndReturnsTheExactStillLiveOverlapManifest() throws {
        let now = Date(timeIntervalSince1970: 1_785_751_620)
        let store = try testManifestStore(clock: { now })
        let oldObject = try fixtureJSONObject()
        var currentObject = oldObject
        currentObject["manifestVersion"] = "2"
        currentObject["previousManifestDigest"] = NSNull()
        currentObject["keys"] = try XCTUnwrap(oldObject["keys"] as? [[String: Any]]).map { item in
            var changed = item
            changed["keyID"] = "v2-" + (try XCTUnwrap(item["keyID"] as? String))
            return changed
        }.sorted { ($0["keyID"] as! String) < ($1["keyID"] as! String) }
        let signedCurrent = try XCTUnwrap(JSONSerialization.jsonObject(with: signedManifest(currentObject)) as? [String: Any])
        let response: [String: Any] = [
            "kind": "central.bootstrap-key-manifest-response.v1",
            "current": signedCurrent,
            "overlap": [oldObject],
        ]
        try store.acceptManifestResponse(try JSONSerialization.data(withJSONObject: response))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: publicFixture("crypto-vectors-v1.json"))) as? [String: Any])
        let message = try XCTUnwrap((root["recoveryAuthorization"] as? [String: Any])?["message"])
        let authorization = try AccountWireCodec.decodeRecoveryAuthorization(JSONSerialization.data(withJSONObject: message))
        let selected = try store.verifyRecoveryAuthorization(
            authorization,
            expectedAccountID: authorization.accountID,
            expectedEpoch: authorization.epoch,
            expectedDeviceID: authorization.deviceID,
            expectedPlatform: authorization.platform,
            expectedPublicBundle: authorization.publicBundle,
            expectedPriorCommitDigest: authorization.priorCommitDigest,
            expectedExchangeRequestDigest: authorization.exchangeRequestDigest
        )
        XCTAssertEqual(selected, try AccountWireCodec.decodeManifest(fixtureData()))
        XCTAssertNotEqual(selected, store.currentManifest())
    }

    private func fixtureData() throws -> Data {
        let fixture = publicFixture("central-bootstrap-manifest-test-v1.json")
        return try Data(contentsOf: fixture)
    }
    private func publicFixture(_ name: String) -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/\(name)") }
    private func testManifestStore(secretStore: InMemoryAccountSecretStore = InMemoryAccountSecretStore(), clock: @escaping @Sendable () -> Date) throws -> BootstrapKeyManifestStore {
        try BootstrapKeyManifestStore(
            bundledManifest: fixtureData(),
            offlineRootKeyID: "plainpost-root-2026-01",
            offlineRootPublicKey: try XCTUnwrap(Data(base64URLEncoded: "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU")),
            secretStore: secretStore,
            clock: clock
        )
    }
    private func fixtureJSONObject() throws -> [String: Any] { try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any]) }
    private func signedManifest(version: String) throws -> Data { var root = try fixtureJSONObject(); root["manifestVersion"] = version; return try signedManifest(root) }
    private func signedManifest(_ object: [String: Any]) throws -> Data {
        var result = object
        let parsed = try AccountWireCodec.decodeManifest(try JSONSerialization.data(withJSONObject: result))
        let signature = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1])).signature(for: AccountTranscript.manifest(rootKeyID: parsed.rootKeyID, version: parsed.manifestVersion, notBefore: parsed.notBefore, expiresAt: parsed.expiresAt, previousDigest: parsed.previousManifestDigest, keys: parsed.keys)).rawRepresentation
        result["rootSignature"] = AccountWireCodec.encodeBase64URL(lowS(signature))
        return try JSONSerialization.data(withJSONObject: result)
    }
    private func lowS(_ signature: Data) -> Data {
        let order = Data(hexManifest: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!
        let half = Data(hexManifest: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")!
        let s = Data(signature.suffix(32)); guard half.lexicographicallyPrecedes(s), s != half else { return signature }
        var normalized = Array(order); let source = Array(s); var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) { let difference = Int(normalized[index]) - Int(source[index]) - borrow; if difference < 0 { normalized[index] = UInt8(difference + 256); borrow = 1 } else { normalized[index] = UInt8(difference); borrow = 0 } }
        return Data(signature.prefix(32)) + Data(normalized)
    }
    private func verify(_ authorization: AccountRecoveryAuthorization, with store: BootstrapKeyManifestStore) throws {
        _ = try store.verifyRecoveryAuthorization(authorization, expectedAccountID: authorization.accountID, expectedEpoch: authorization.epoch, expectedDeviceID: authorization.deviceID, expectedPlatform: authorization.platform, expectedPublicBundle: authorization.publicBundle, expectedPriorCommitDigest: authorization.priorCommitDigest, expectedExchangeRequestDigest: authorization.exchangeRequestDigest)
    }
    private func alternateBundle() throws -> AccountPublicKeyBundle {
        try AccountPublicKeyBundle(signingKey: P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([21])).publicKey.x963Representation, agreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([22])).publicKey.x963Representation)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    init?(hexManifest: String) { guard hexManifest.count.isMultiple(of: 2) else { return nil }; var data = Data(); for index in stride(from: 0, to: hexManifest.count, by: 2) { let start = hexManifest.index(hexManifest.startIndex, offsetBy: index); let end = hexManifest.index(start, offsetBy: 2); guard let byte = UInt8(hexManifest[start..<end], radix: 16) else { return nil }; data.append(byte) }; self = data }
}
