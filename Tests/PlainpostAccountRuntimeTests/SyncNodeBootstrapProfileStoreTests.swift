
import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport
import XCTest
@testable import PlainpostAccountRuntime

final class SyncNodeBootstrapProfileStoreTests: XCTestCase {
    func testImportUsesFixedCurrentSharedDeviceOnlyKeyAndCAS() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let profile = try bootstrapProfile(capabilityByte: 0x31)

        try store.importProfile(profile)

        let snapshot = secrets.snapshot()
        XCTAssertEqual(snapshot.casCalls.count, 1)
        XCTAssertEqual(snapshot.casCalls[0].key.service, "com.marynavdovenko.Plainpost.SyncNodeBootstrapProfile.v1")
        XCTAssertEqual(snapshot.casCalls[0].key.account, "current")
        XCTAssertEqual(snapshot.casCalls[0].key.accessGroup, PlainpostAccountSharedKeychain.accessGroup)
        XCTAssertEqual(snapshot.casCalls[0].attributes, .deviceOnly)
        XCTAssertNil(snapshot.casCalls[0].expected)
        XCTAssertEqual(try store.load(), profile)
    }

    func testStoreUsesInjectedAccessGroupForEveryOperation() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets, accessGroup: PlainpostIOSAppKeychain.accessGroup)
        XCTAssertEqual(store.accessGroup, PlainpostIOSAppKeychain.accessGroup)
        let iOSKey = AccountSecretKey(
            service: SyncNodeBootstrapProfileStore.storageKey.service,
            account: SyncNodeBootstrapProfileStore.storageKey.account,
            accessGroup: PlainpostIOSAppKeychain.accessGroup
        )
        let profile = try bootstrapProfile(capabilityByte: 0x31)
        try store.importProfile(profile)
        XCTAssertEqual(try store.load(), profile)
        let moved = try store.replaceOrigin(
            NodeEndpointURL("https://replacement.tail1234.ts.net:18443"),
            expectedCapabilityID: profile.capabilityID
        )
        XCTAssertEqual(try store.load(), moved)
        try store.retire(expectedCapabilityID: profile.capabilityID)
        XCTAssertNil(try store.load())

        let calls = secrets.snapshot().casCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.key == iOSKey })
        let tombstone = try XCTUnwrap(secrets.record(for: iOSKey))
        XCTAssertEqual(tombstone.attributes, .deviceOnly)
        XCTAssertEqual(
            String(decoding: tombstone.value, as: UTF8.self),
            #"{"capabilityID":"MTExMTExMTExMTExMTExMQ","kind":"sync-node.bootstrap-profile-retired.v1"}"# + "\n"
        )
        XCTAssertFalse(secrets.snapshot().casCalls.contains { $0.key == SyncNodeBootstrapProfileStore.storageKey })
        XCTAssertNil(secrets.record(for: SyncNodeBootstrapProfileStore.storageKey))
    }

    func testLegacyV1ProfileImportsLoadsAndRetires() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let legacy = try bootstrapProfile(capabilityByte: 0x31, centralAudience: nil)

        try store.importProfile(legacy)
        let stored = try XCTUnwrap(secrets.currentRecord())
        XCTAssertTrue(String(decoding: stored.value, as: UTF8.self).contains(#""kind":"sync-node.bootstrap-profile.v1""#))
        XCTAssertFalse(String(decoding: stored.value, as: UTF8.self).contains("centralAudience"))
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded, legacy)
        XCTAssertNil(loaded.centralAudience)

        try store.retire(expectedCapabilityID: legacy.capabilityID)
        XCTAssertNil(try store.load())
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(secrets.currentRecord()).value, as: UTF8.self),
            #"{"capabilityID":"MTExMTExMTExMTExMTExMQ","kind":"sync-node.bootstrap-profile-retired.v1"}"# + "\n"
        )
    }

    // Server Setup profiles are bearer capabilities. On iOS they live in the
    // app's own application-identifier group, never in the notifications
    // group shared with the Notification Service extension.
    func testKeychainGroupsKeepServerSetupOutOfSharedExtensionGroups() {
        XCTAssertEqual(PlainpostIOSAppKeychain.accessGroup, "9XN7WN8JN2.com.marynavdovenko.Plainpost.iOS")
        XCTAssertFalse(PlainpostIOSAppKeychain.accessGroup.hasSuffix(".notifications"))
        XCTAssertNotEqual(PlainpostIOSAppKeychain.accessGroup, PlainpostAccountSharedKeychain.accessGroup)
        XCTAssertEqual(SyncNodeBootstrapProfileStore(secretStore: RecordingBootstrapSecretStore()).accessGroup, PlainpostAccountSharedKeychain.accessGroup)
    }

    func testImportReplacesTheLoadedSlotByCASAndExactDuplicateIsIdempotent() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let first = try bootstrapProfile(capabilityByte: 0x31)
        let replacement = try bootstrapProfile(capabilityByte: 0x32)

        try store.importProfile(first)
        let firstWire = try XCTUnwrap(secrets.currentRecord()?.value)
        try store.importProfile(replacement)
        let afterReplacement = secrets.snapshot()
        XCTAssertEqual(afterReplacement.casCalls.count, 2)
        XCTAssertEqual(afterReplacement.casCalls[1].expected, firstWire)
        XCTAssertEqual(try store.load(), replacement)

        try store.importProfile(replacement)
        XCTAssertEqual(secrets.snapshot().casCalls.count, 2)
    }

    func testReplaceOriginPreservesPinnedIdentityAndSecretUsingCAS() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let original = try bootstrapProfile(capabilityByte: 0x31)
        let replacementOrigin = try NodeEndpointURL("https://replacement.tail1234.ts.net:18443")
        try store.importProfile(original)
        let originalWire = try XCTUnwrap(secrets.currentRecord()?.value)

        let replacement = try store.replaceOrigin(
            replacementOrigin,
            expectedCapabilityID: original.capabilityID
        )

        XCTAssertEqual(replacement.canonicalOrigin, replacementOrigin)
        XCTAssertEqual(replacement.nodeDeviceID, original.nodeDeviceID)
        XCTAssertEqual(replacement.signingKeyDigest, original.signingKeyDigest)
        XCTAssertEqual(replacement.capabilityID, original.capabilityID)
        XCTAssertEqual(replacement.capability, original.capability)
        XCTAssertEqual(try store.load(), replacement)
        let calls = secrets.snapshot().casCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].expected, originalWire)
    }

    func testReplaceOriginRejectsStaleCapabilityWithoutChangingSlot() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let original = try bootstrapProfile(capabilityByte: 0x31)
        try store.importProfile(original)
        let before = secrets.currentRecord()

        XCTAssertThrowsError(
            try store.replaceOrigin(
                NodeEndpointURL("https://replacement.tail1234.ts.net:18443"),
                expectedCapabilityID: Data(repeating: 0x32, count: 16)
            )
        )

        XCTAssertEqual(secrets.currentRecord(), before)
        XCTAssertEqual(secrets.snapshot().casCalls.count, 1)
    }

    func testCASConflictDoesNotOverwriteAConcurrentNewerProfile() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let first = try bootstrapProfile(capabilityByte: 0x31)
        let requested = try bootstrapProfile(capabilityByte: 0x32)
        let concurrent = try bootstrapProfile(capabilityByte: 0x33)
        try store.importProfile(first)
        secrets.replaceOnNextCASFailure(with: try concurrent.encodedForStorage())

        XCTAssertThrowsError(try store.importProfile(requested))
        XCTAssertEqual(try store.load(), concurrent)
    }

    func testSameCapabilityIDRejectsDivergentSecretOrPinsWithoutChangingSlot() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let original = try bootstrapProfile(capabilityByte: 0x31)
        try store.importProfile(original)
        let divergent: [SyncNodeBootstrapProfile] = [
            try bootstrapProfile(capabilityByte: 0x32, capabilityIDByte: 0x31),
            try SyncNodeBootstrapProfile(
                canonicalOrigin: NodeEndpointURL("https://other.tail1234.ts.net:18443"),
                nodeDeviceID: original.nodeDeviceID,
                signingKeyDigest: original.signingKeyDigest,
                capabilityID: original.capabilityID,
                capability: Data(repeating: 0x31, count: 32),
                centralAudience: "central.test"
            ),
            try SyncNodeBootstrapProfile(
                canonicalOrigin: original.canonicalOrigin,
                nodeDeviceID: AccountDeviceID("22222222-2222-4222-8222-222222222222"),
                signingKeyDigest: Data(repeating: 0x22, count: 32),
                capabilityID: original.capabilityID,
                capability: Data(repeating: 0x31, count: 32),
                centralAudience: "central.test"
            ),
        ]

        for candidate in divergent {
            XCTAssertThrowsError(try store.importProfile(candidate))
            XCTAssertEqual(try store.load(), original)
        }
        XCTAssertEqual(secrets.snapshot().casCalls.count, 1)

        try store.retire(expectedCapabilityID: original.capabilityID)
        XCTAssertThrowsError(try store.importProfile(original))
        XCTAssertNil(try store.load())
    }

    func testRetirementIsCapabilityGuardedAndWritesSecretFreeTombstone() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let old = try bootstrapProfile(capabilityByte: 0x31)
        let current = try bootstrapProfile(capabilityByte: 0x32)
        try store.importProfile(old)
        try store.importProfile(current)

        try store.retire(expectedCapabilityID: old.capabilityID)
        XCTAssertEqual(try store.load(), current)

        try store.retire(expectedCapabilityID: current.capabilityID)
        XCTAssertNil(try store.load())
        let tombstone = try XCTUnwrap(secrets.currentRecord())
        XCTAssertEqual(tombstone.attributes, .deviceOnly)
        XCTAssertEqual(
            String(decoding: tombstone.value, as: UTF8.self),
            #"{"capabilityID":"MjIyMjIyMjIyMjIyMjIyMg","kind":"sync-node.bootstrap-profile-retired.v1"}"# + "\n"
        )
        XCTAssertFalse(String(decoding: tombstone.value, as: UTF8.self).contains("MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjI"))

        let callsBeforeRetry = secrets.snapshot().casCalls.count
        try store.retire(expectedCapabilityID: current.capabilityID)
        XCTAssertEqual(secrets.snapshot().casCalls.count, callsBeforeRetry)
    }

    func testRetirementRejectsMalformedCapabilityIDWithoutChangingSlot() throws {
        let secrets = RecordingBootstrapSecretStore()
        let store = SyncNodeBootstrapProfileStore(secretStore: secrets)
        let current = try bootstrapProfile(capabilityByte: 0x32)
        try store.importProfile(current)
        let before = secrets.currentRecord()

        for invalid in [Data(), Data(repeating: 0, count: 16), Data(repeating: 1, count: 15)] {
            XCTAssertThrowsError(try store.retire(expectedCapabilityID: invalid))
        }
        XCTAssertEqual(secrets.currentRecord(), before)
    }

    func testLoadRejectsWrongKeychainAttributesAndNoncanonicalTombstone() throws {
        let key = SyncNodeBootstrapProfileStore.storageKey
        let wrongAttributes = RecordingBootstrapSecretStore(records: [
            key: AccountSecretRecord(
                value: try bootstrapProfile(capabilityByte: 0x31).encodedForStorage(),
                attributes: AccountSecretAttributes(accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: true)
            )
        ])
        XCTAssertThrowsError(try SyncNodeBootstrapProfileStore(secretStore: wrongAttributes).load())

        let noncanonical = RecordingBootstrapSecretStore(records: [
            key: AccountSecretRecord(
                value: Data(#"{"kind":"sync-node.bootstrap-profile-retired.v1","capabilityID":"MTExMTExMTExMTExMTExMQ"}"#.utf8),
                attributes: .deviceOnly
            )
        ])
        XCTAssertThrowsError(try SyncNodeBootstrapProfileStore(secretStore: noncanonical).load())
    }
}

private func bootstrapProfile(capabilityByte: UInt8, capabilityIDByte: UInt8? = nil, centralAudience: String? = "central.test") throws -> SyncNodeBootstrapProfile {
    try SyncNodeBootstrapProfile(
        canonicalOrigin: NodeEndpointURL("https://node.tail1234.ts.net:18443"),
        nodeDeviceID: AccountDeviceID("11111111-1111-4111-8111-111111111111"),
        signingKeyDigest: Data(repeating: 0x11, count: 32),
        capabilityID: Data(repeating: capabilityIDByte ?? capabilityByte, count: 16),
        capability: Data(repeating: capabilityByte, count: 32),
        centralAudience: centralAudience
    )
}

private final class RecordingBootstrapSecretStore: AccountSecretStoring, @unchecked Sendable {
    struct CASCall {
        let expected: Data?
        let replacement: Data
        let key: AccountSecretKey
        let attributes: AccountSecretAttributes
    }

    struct Snapshot {
        let casCalls: [CASCall]
    }

    private let lock = NSLock()
    private var records: [AccountSecretKey: AccountSecretRecord]
    private var casCalls: [CASCall] = []
    private var nextConflictReplacement: Data?

    init(records: [AccountSecretKey: AccountSecretRecord] = [:]) {
        self.records = records
    }

    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? {
        lock.withLock { records[key] }
    }

    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        XCTFail("profile storage must use compareAndSwap")
    }

    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        lock.withLock {
            casCalls.append(CASCall(expected: expected, replacement: replacement, key: key, attributes: attributes))
            if let nextConflictReplacement {
                records[key] = AccountSecretRecord(value: nextConflictReplacement, attributes: .deviceOnly)
                self.nextConflictReplacement = nil
                return false
            }
            guard records[key]?.value == expected else { return false }
            records[key] = AccountSecretRecord(value: replacement, attributes: attributes)
            return true
        }
    }

    func delete(_ key: AccountSecretKey) throws {
        XCTFail("profile storage must retain a tombstone")
    }

    func replaceOnNextCASFailure(with value: Data) {
        lock.withLock { nextConflictReplacement = value }
    }

    func currentRecord() -> AccountSecretRecord? {
        lock.withLock { records[SyncNodeBootstrapProfileStore.storageKey] }
    }

    func record(for key: AccountSecretKey) -> AccountSecretRecord? {
        lock.withLock { records[key] }
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(casCalls: casCalls) }
    }
}
