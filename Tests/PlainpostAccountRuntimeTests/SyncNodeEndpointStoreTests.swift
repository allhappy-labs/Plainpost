import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport

final class SyncNodeEndpointStoreTests: XCTestCase {
    func testSessionSequenceAdvancesExactlyOnceAndSurvivesRestart() throws {
        let backing = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node")
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1))
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 1)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 2)
        let restarted = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node")
        XCTAssertEqual(try restarted.consumeNextSequence(for: reference), 3)
    }

    func testSequenceDoesNotWrapAndForeignReferenceCannotReadStoredSession() throws {
        let backing = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node")
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: UInt64.max))
        XCTAssertEqual(try store.consumeNextSequence(for: reference), UInt64.max)
        XCTAssertThrowsError(try store.consumeNextSequence(for: reference))
        let foreign = try SyncNodeEndpointReference(accountID: PlainpostAccountID("33333333-3333-4333-8333-333333333333"), nodeID: reference.nodeID, trustEpoch: reference.trustEpoch, endpointCiphertext: reference.endpointCiphertext)
        XCTAssertThrowsError(try store.load(for: foreign))
    }

    func testRepeatedSaveCannotMoveConsumedSequenceBackward() throws {
        let backing = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node")
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        let session = try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1)
        try store.save(reference: reference, session: session)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 1)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 2)
        try store.save(reference: reference, session: session)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 3)
    }

    func testRepeatedSaveCannotReplaceSignedActivationDocuments() throws {
        let backing = InMemoryAccountSecretStore(), store = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node-documents")
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        let original = try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1)
        try store.save(reference: reference, session: original)
        let substituted = try SyncNodeStoredSession(resultWire: Data([9]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1)
        XCTAssertThrowsError(try store.save(reference: reference, session: substituted))
        XCTAssertEqual(try store.load(for: reference), original)
    }

    // Catches a regression where an ambiguous retry can replace its signed
    // timestamp after restart, producing a different transcript at the same
    // sequence. The retained field is public metadata only; payload and
    // signature stay out of the durable reservation.
    func testPendingRequestRetainsOnlyCanonicalWholeSecondIssuedAt() throws {
        let digest = Data(repeating: 7, count: 32)
        let pending = try SyncNodePendingRequest(
            sequence: 9,
            issuedAt: "2026-08-16T09:10:11Z",
            requestTranscriptDigest: digest
        )

        XCTAssertEqual(pending.sequence, 9)
        XCTAssertEqual(pending.issuedAt, "2026-08-16T09:10:11Z")
        XCTAssertEqual(pending.requestTranscriptDigest, digest)
        XCTAssertThrowsError(try SyncNodePendingRequest(sequence: 9, issuedAt: "2026-08-16T09:10:11.000Z", requestTranscriptDigest: digest))
    }

    func testDurablePendingReservationContainsNoRequestBodyHeaderOrSignature() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.pending-privacy"
        let store = try SyncNodeEndpointStore(secretStore: backing, service: service)
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))
        _ = try store.reservePending(for: reference, sequence: 7, issuedAt: "2026-08-16T09:10:11Z", requestTranscriptDigest: Data(repeating: 9, count: 32))

        let key = AccountSecretKey(service: service, account: "v1.\(reference.accountID.rawValue).\(reference.nodeID.rawValue).\(reference.trustEpoch.wireValue)")
        let record = try XCTUnwrap(backing.records[key])
        let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.value) as? [String: Any])
        let pending = try XCTUnwrap(state["pending"] as? [String: Any])
        XCTAssertEqual(Set(pending.keys), ["sequence", "issuedAt", "requestTranscriptDigest"])
    }

    func testDurableReservationRejectsProviderBodyInsteadOfPersistingCredentials() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.provider-privacy"
        let store = try SyncNodeEndpointStore(secretStore: backing, service: service)
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))

        let providerBody = Data("code=oauth-secret&code_verifier=pkce-secret".utf8)
        _ = try store.reservePending(for: reference, sequence: 7, issuedAt: "2026-08-16T09:10:11Z", requestTranscriptDigest: Data(repeating: 9, count: 32), method: "POST", path: "/v1/providers/google", body: providerBody)
        XCTAssertEqual(try store.loadPending(for: reference)?.body, providerBody, "the live request may finish, but this is process-local only")
        let restarted = try SyncNodeEndpointStore(secretStore: backing, service: service)
        XCTAssertNil(try restarted.loadPending(for: reference)?.body, "an ambiguous provider request fails closed after restart")

        let key = AccountSecretKey(service: service, account: "v1.\(reference.accountID.rawValue).\(reference.nodeID.rawValue).\(reference.trustEpoch.wireValue)")
        XCTAssertFalse(try XCTUnwrap(backing.records[key]).value.contains(providerBody))
    }

    func testMutationReservationRejectsMalformedCanonicalPayload() throws {
        let backing = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node.canonical-replay")
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        try store.save(reference: reference, session: try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7))

        XCTAssertThrowsError(try store.reservePending(for: reference, sequence: 7, issuedAt: "2026-08-16T09:10:11Z", requestTranscriptDigest: Data(repeating: 9, count: 32), method: "POST", path: "/v1/mutations", body: Data("not-a-mutation-request".utf8)))
    }

    func testLegacyV4CanonicalMutationMigratesOnlyFromExactWire() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.legacy-v4"
        let store = try SyncNodeEndpointStore(secretStore: backing, service: service)
        let reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
        let session = try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 7)
        let operation = try validCanonicalMutationForStoreTest()
        let pending = LegacyV4PendingForStoreTest(sequence: 7, issuedAt: "2026-08-16T09:10:11Z", requestTranscriptDigest: Data(repeating: 9, count: 32), method: "POST", path: "/v1/mutations", body: operation)
        let state = LegacyV4StateForStoreTest(version: 4, reference: reference, session: session, pending: nil, retainedMutation: pending)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let wire = try encoder.encode(state)
        let key = AccountSecretKey(service: service, account: "v1.\(reference.accountID.rawValue).\(reference.nodeID.rawValue).\(reference.trustEpoch.wireValue)")
        try backing.replace(wire, key: key, attributes: .deviceOnly)

        let migrated = try XCTUnwrap(store.loadRetainedMutation(for: reference))
        XCTAssertEqual(migrated.body, operation)

        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        unknown["unknown"] = true
        let unknownWire = try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
        try backing.replace(unknownWire, key: key, attributes: .deviceOnly)
        XCTAssertThrowsError(try store.load(for: reference))

        let nonCanonical = Data(wire + Data([0x0a]))
        try backing.replace(nonCanonical, key: key, attributes: .deviceOnly)
        XCTAssertThrowsError(try store.load(for: reference))
    }

    // macOS keeps the default Keychain group: no record names a group and no
    // legacy group is consulted.
    func testDefaultStoreKeepsTheDefaultKeychainGroup() throws {
        let backing = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node.default-group")
        XCTAssertNil(store.accessGroup)
        XCTAssertNil(store.legacyAccessGroup)
        let reference = try groupTestReference()
        try store.save(reference: reference, session: try groupTestSession(nextSequence: 1))
        try store.saveEndpoint(URL(string: "https://node.tail1234.ts.net:8443")!, for: reference, identity: try groupTestIdentity())
        try store.saveActivationCompletionJournal(accountID: reference.accountID, wire: Data([1, 2, 3]))
        XCTAssertEqual(backing.records.count, 3)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == nil })
    }

    // iOS stores the Node refresh credential in the app's own group, never in
    // the notifications group the Notification Service extension shares, and
    // moves an existing notifications-group record there on first use.
    func testIOSStoreMovesNotificationsGroupRecordsIntoTheAppGroup() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.ios-migration"
        let reference = try groupTestReference(), identity = try groupTestIdentity()
        let endpoint = URL(string: "https://node.tail1234.ts.net:8443")!
        let legacy = try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
        try legacy.save(reference: reference, session: try groupTestSession(nextSequence: 1))
        XCTAssertEqual(try legacy.consumeNextSequence(for: reference), 1)
        try legacy.saveEndpoint(endpoint, for: reference, identity: identity)
        try legacy.saveActivationCompletionJournal(accountID: reference.accountID, wire: Data([1, 2, 3]))
        let legacyValues = Set(backing.records.values.map(\.value))
        XCTAssertEqual(backing.records.count, 3)

        let store = try groupTestIOSStore(backing, service: service)
        XCTAssertEqual(store.accessGroup, PlainpostIOSAppKeychain.accessGroup)
        XCTAssertEqual(store.legacyAccessGroup, PlainpostIOSAppKeychain.notificationsAccessGroup)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 2)
        XCTAssertEqual(try store.loadEndpoint(for: reference, identity: identity), endpoint)
        XCTAssertEqual(try store.loadActivationCompletionJournal(accountID: reference.accountID), Data([1, 2, 3]))
        XCTAssertEqual(backing.records.count, 3)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == PlainpostIOSAppKeychain.accessGroup })
        XCTAssertTrue(backing.records.values.allSatisfy { $0.attributes == .deviceOnly })
        XCTAssertEqual(backing.records.values.filter { legacyValues.contains($0.value) }.count, 2, "endpoint and journal are copied byte for byte")

        let restarted = try groupTestIOSStore(backing, service: service)
        XCTAssertEqual(try restarted.consumeNextSequence(for: reference), 3)
        XCTAssertEqual(try restarted.loadEndpoint(for: reference, identity: identity), endpoint)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == PlainpostIOSAppKeychain.accessGroup })
    }

    func testIOSStoreSavesNewRecordsOnlyInTheAppGroup() throws {
        let backing = InMemoryAccountSecretStore()
        let store = try groupTestIOSStore(backing, service: "test.sync-node.ios-new")
        let reference = try groupTestReference()
        try store.save(reference: reference, session: try groupTestSession(nextSequence: 1))
        try store.saveEndpoint(URL(string: "https://node.tail1234.ts.net:8443")!, for: reference, identity: try groupTestIdentity())
        try store.saveActivationCompletionJournal(accountID: reference.accountID, wire: Data([4]))
        XCTAssertEqual(backing.records.count, 3)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == PlainpostIOSAppKeychain.accessGroup })
    }

    func testFailedAppGroupWriteKeepsTheLegacyCredential() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.ios-write-failure"
        let reference = try groupTestReference()
        let legacy = try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
        try legacy.save(reference: reference, session: try groupTestSession(nextSequence: 4))
        let before = backing.records

        let failing = GroupWriteFailingSecretStore(backing: backing, failingGroup: PlainpostIOSAppKeychain.accessGroup)
        let store = try groupTestIOSStore(failing, service: service)
        XCTAssertThrowsError(try store.consumeNextSequence(for: reference))
        XCTAssertEqual(backing.records, before, "a failed copy must neither delete nor change the legacy record")

        failing.failWrites = false
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 4)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == PlainpostIOSAppKeychain.accessGroup })
    }

    func testFailedLegacyDeleteKeepsTheMigratedCredentialAndRetries() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.ios-delete-failure"
        let reference = try groupTestReference()
        let legacy = try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
        try legacy.save(reference: reference, session: try groupTestSession(nextSequence: 1))

        let failing = GroupWriteFailingSecretStore(backing: backing, failingGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
        failing.failWrites = false; failing.failDeletes = true
        let store = try groupTestIOSStore(failing, service: service)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 1)
        XCTAssertEqual(Set(backing.records.keys.map(\.accessGroup)), [PlainpostIOSAppKeychain.accessGroup, PlainpostIOSAppKeychain.notificationsAccessGroup])

        failing.failDeletes = false
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 2)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == PlainpostIOSAppKeychain.accessGroup })
    }

    // A copy interrupted before the legacy delete leaves both records. The
    // app-group copy may already have consumed sequences, so it always wins:
    // resurrecting the stale legacy record would reuse a client sequence.
    func testInterruptedMigrationPrefersTheAppGroupRecord() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.ios-interrupted"
        let reference = try groupTestReference()
        let legacy = try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
        try legacy.save(reference: reference, session: try groupTestSession(nextSequence: 1))
        let appOnly = try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.accessGroup)
        try appOnly.save(reference: reference, session: try groupTestSession(nextSequence: 5))
        XCTAssertEqual(backing.records.count, 2)

        let store = try groupTestIOSStore(backing, service: service)
        XCTAssertEqual(try store.consumeNextSequence(for: reference), 5)
        XCTAssertEqual(backing.records.count, 1)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == PlainpostIOSAppKeychain.accessGroup })
    }

    func testRemoveDeletesTheRecordFromBothGroups() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.ios-remove"
        let reference = try groupTestReference()
        try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
            .save(reference: reference, session: try groupTestSession(nextSequence: 1))
        try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.accessGroup)
            .save(reference: reference, session: try groupTestSession(nextSequence: 3))

        let store = try groupTestIOSStore(backing, service: service)
        try store.remove(for: reference)
        XCTAssertTrue(backing.records.isEmpty, "a removed credential must not come back from the legacy group")
        XCTAssertThrowsError(try store.load(for: reference))
    }

    // `delete` removes the legacy copy first, precisely so a failed legacy
    // delete leaves the app-group record untouched. If the order were
    // reversed, a failed legacy delete here would strand the app-group
    // record gone while the legacy record survives, and a later read could
    // migrate the stale legacy copy back to life.
    func testRemoveFailingToDeleteTheLegacyRecordLeavesTheAppGroupRecordInPlace() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.ios-remove-legacy-delete-failure"
        let reference = try groupTestReference()
        try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
            .save(reference: reference, session: try groupTestSession(nextSequence: 1))
        try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.accessGroup)
            .save(reference: reference, session: try groupTestSession(nextSequence: 3))

        let failing = GroupWriteFailingSecretStore(backing: backing, failingGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
        failing.failWrites = false; failing.failDeletes = true
        let store = try groupTestIOSStore(failing, service: service)

        XCTAssertThrowsError(try store.remove(for: reference))
        XCTAssertTrue(backing.records.keys.contains { $0.accessGroup == PlainpostIOSAppKeychain.accessGroup },
                       "a failed legacy delete must not remove the app-group record, or a stale legacy copy could migrate back")
    }

    func testLegacyRecordThatIsNotDeviceOnlyIsNeverCopied() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "test.sync-node.ios-not-device-only"
        let reference = try groupTestReference()
        try SyncNodeEndpointStore(secretStore: backing, service: service, accessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
            .save(reference: reference, session: try groupTestSession(nextSequence: 1))
        let key = try XCTUnwrap(backing.records.keys.first)
        let value = try XCTUnwrap(backing.records[key]?.value)
        try backing.replace(value, key: key, attributes: AccountSecretAttributes(accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: true))

        let store = try groupTestIOSStore(backing, service: service)
        XCTAssertThrowsError(try store.load(for: reference))
        XCTAssertEqual(Array(backing.records.keys), [key])
    }

    // The Mac app and the service share the Node session records through the
    // AccountShared group: every query the store makes names that group, so
    // neither process falls back to its own default group.
    func testMacStoreNamesTheAccountSharedGroupOnEveryKeychainQuery() throws {
        let backing = KeyRecordingSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: backing, service: "test.sync-node.account-shared", accessGroup: PlainpostAccountSharedKeychain.accessGroup)
        let reference = try groupTestReference(), identity = try groupTestIdentity()
        try store.save(reference: reference, session: try groupTestSession(nextSequence: 1))
        XCTAssertEqual(try store.loadReference(accountID: reference.accountID, nodeID: reference.nodeID, trustEpoch: reference.trustEpoch).reference, reference)
        try store.saveEndpoint(URL(string: "https://node.tail1234.ts.net:8443")!, for: reference, identity: identity)
        _ = try store.loadEndpoint(for: reference, identity: identity)
        let reservation = try store.reservePending(for: reference, sequence: 1, issuedAt: "2026-08-16T09:10:11Z", requestTranscriptDigest: Data(repeating: 9, count: 32), method: "GET", path: "/v1/status")
        _ = try store.loadPending(for: reference)
        try store.commitPending(for: reference, sequence: reservation.reservation.sequence, retainMutation: false)
        _ = try store.consumeNextSequence(for: reference)
        try store.saveActivationCompletionJournal(accountID: reference.accountID, wire: Data([1, 2, 3]))
        _ = try store.loadActivationCompletionJournal(accountID: reference.accountID)
        try store.clearActivationCompletionJournal(accountID: reference.accountID)
        try store.remove(for: reference)
        XCTAssertGreaterThan(backing.keys.count, 10)
        XCTAssertEqual(Set(backing.keys.map(\.accessGroup)), [PlainpostAccountSharedKeychain.accessGroup])
    }

    func testLegacyGroupRequiresADifferentAppGroup() {
        let backing = InMemoryAccountSecretStore()
        XCTAssertThrowsError(try SyncNodeEndpointStore(secretStore: backing, legacyAccessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup))
        XCTAssertThrowsError(try SyncNodeEndpointStore(secretStore: backing, accessGroup: PlainpostIOSAppKeychain.accessGroup, legacyAccessGroup: PlainpostIOSAppKeychain.accessGroup))
        XCTAssertThrowsError(try SyncNodeEndpointStore(secretStore: backing, accessGroup: ""))
    }

    func testNotificationsGroupConstantNamesTheNotificationServiceGroup() {
        XCTAssertEqual(PlainpostIOSAppKeychain.notificationsAccessGroup, "9XN7WN8JN2.com.marynavdovenko.Plainpost.notifications")
        XCTAssertNotEqual(PlainpostIOSAppKeychain.notificationsAccessGroup, PlainpostIOSAppKeychain.accessGroup)
    }
}

private struct LegacyV4PendingForStoreTest: Codable {
    let sequence: UInt64
    let issuedAt: String
    let requestTranscriptDigest: Data
    let method: String
    let path: String
    let body: Data
}

private struct LegacyV4StateForStoreTest: Codable {
    let version: Int
    let reference: SyncNodeEndpointReference
    let session: SyncNodeStoredSession
    let pending: SyncNodePendingRequest?
    let retainedMutation: LegacyV4PendingForStoreTest
}

private func validCanonicalMutationForStoreTest() throws -> Data {
    let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
    let unsigned = try NodeSyncUnsignedOperation(accountID: "11111111-1111-4111-8111-111111111111", authorityEpoch: "9", clientID: "33333333-3333-4333-8333-333333333333", idempotencyKey: "legacy-v4", issuedAt: "2026-08-16T09:10:11Z", logicalMailboxID: mailbox, nodeID: "22222222-2222-4222-8222-222222222222", operation: .setRead(messageIDs: ["message-1"], read: true), trustEpoch: "1")
    let operation = try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64))
    return try NodeSyncCodec.encodeMutationRequest(try NodeSyncMutationRequest(canonicalOperation: NodeSyncCodec.encodeOperation(operation)))
}

private func groupTestReference() throws -> SyncNodeEndpointReference {
    try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: try AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 4, count: 48))
}

private func groupTestSession(nextSequence: UInt64) throws -> SyncNodeStoredSession {
    try SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: nextSequence)
}

private func groupTestIdentity() throws -> AccountDeviceIdentity {
    try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
}

private func groupTestIOSStore(_ secretStore: any AccountSecretStoring, service: String) throws -> SyncNodeEndpointStore {
    try SyncNodeEndpointStore(secretStore: secretStore, service: service, accessGroup: PlainpostIOSAppKeychain.accessGroup, legacyAccessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
}

/// Fails writes or deletes aimed at one Keychain access group.
private final class GroupWriteFailingSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore
    private let failingGroup: String
    private let lock = NSLock()
    private var writesFail = true, deletesFail = false
    var failWrites: Bool { get { lock.lock(); defer { lock.unlock() }; return writesFail } set { lock.lock(); writesFail = newValue; lock.unlock() } }
    var failDeletes: Bool { get { lock.lock(); defer { lock.unlock() }; return deletesFail } set { lock.lock(); deletesFail = newValue; lock.unlock() } }
    init(backing: InMemoryAccountSecretStore, failingGroup: String) { self.backing = backing; self.failingGroup = failingGroup }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        if failWrites, key.accessGroup == failingGroup { throw AccountRuntimeError.secretUnavailable }
        try backing.replace(value, key: key, attributes: attributes)
    }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        if failWrites, key.accessGroup == failingGroup { throw AccountRuntimeError.secretUnavailable }
        return try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws {
        if failDeletes, key.accessGroup == failingGroup { throw AccountRuntimeError.secretUnavailable }
        try backing.delete(key)
    }
}

/// Records the key of every Keychain operation.
private final class KeyRecordingSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing = InMemoryAccountSecretStore()
    private let lock = NSLock()
    private var recorded: [AccountSecretKey] = []
    var keys: [AccountSecretKey] { lock.withLock { recorded } }
    private func record(_ key: AccountSecretKey) { lock.withLock { recorded.append(key) } }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { record(key); return try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws { record(key); try backing.replace(value, key: key, attributes: attributes) }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        record(key); return try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws { record(key); try backing.delete(key) }
}
