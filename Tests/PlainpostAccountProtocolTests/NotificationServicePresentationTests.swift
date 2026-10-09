import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol

final class NotificationServicePresentationTests: XCTestCase {
    func testNotificationCompletionGateDeliversOnlyOnceAndClearsHandler() {
        var delivered: [Int] = []
        let gate = NotificationCompletionGate<Int> { delivered.append($0) }

        XCTAssertTrue(gate.finish(1))
        XCTAssertFalse(gate.finish(2))
        XCTAssertEqual(delivered, [1])
    }

    func testReplayEntryExpiresAfterTwentyFourHours() {
        let clock = ReplayTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let replay = InMemoryNotificationReplayStore(capacity: 2, clock: { clock.now })
        let replayID = Data(repeating: 0x61, count: 32)

        XCTAssertTrue(replay.claim(replayID))
        XCTAssertFalse(replay.claim(replayID))
        clock.now.addTimeInterval(24 * 60 * 60 + 1)
        XCTAssertTrue(replay.claim(replayID), "expired replay identifiers must not remain accepted forever")
    }

    #if canImport(Security)
    func testKeychainReplayPurgesEntriesOlderThanTwentyFourHours() {
        let clock = ReplayTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let replayID = Data(repeating: 0x62, count: 32)
        let backing = TimedReplayBacking(records: [replayID: clock.now.addingTimeInterval(-InMemoryNotificationReplayStore.lifetime - 1)])
        let replay = NotificationReplayKeychainStore(backing: backing, clock: { clock.now })

        XCTAssertTrue(replay.claim(replayID), "expired keychain replay identifiers must be reclaimed")
        XCTAssertTrue(backing.contains(replayID))
    }
    #endif

    func testMalformedEnvelopeLeavesGenericFallbackAndNeverLeaksCiphertext() throws {
        let original = NotificationServicePresentation.fallback
        let result = try NotificationServicePresentation.render(
            userInfo: ["plainpost.envelope": AccountWireCodec.encodeBase64URL(Data("not-an-envelope".utf8))],
            context: .testFixture(policy: .rich),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(result, original)
        XCTAssertFalse(result.body.contains("not-an-envelope"))
        XCTAssertNil(result.deepLinkToken)
    }

    func testReplayIsRejectedWithoutChangingFallback() throws {
        let (wire, base) = try fixtureContext(policy: .generic)
        let now = Date(timeIntervalSince1970: 1_787_227_320)
        let first = try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: base, now: now)
        let second = try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: base, now: now)
        XCTAssertNotEqual(first, .fallback)
        XCTAssertEqual(second, .fallback)
    }

    func testPoliciesProduceBoundedPrivacySafePresentationAndOpaqueGrouping() throws {
        let (wire, richContext) = try fixtureContext(policy: .rich)
        let now = Date(timeIntervalSince1970: 1_787_227_320)
        let rich = try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: richContext, now: now)
        XCTAssertEqual(rich.title, "sender")
        XCTAssertEqual(rich.subtitle, "subject")
        XCTAssertEqual(rich.body, "preview")
        XCTAssertEqual(rich.badge, 1)
        XCTAssertTrue(rich.threadIdentifier?.hasPrefix("plainpost-mail-") == true)
        XCTAssertEqual(rich.categoryIdentifier, "PLAINPOST_MAIL")
        XCTAssertEqual(rich.deepLinkToken, "message")

        let (_, senderSubjectContext) = try fixtureContext(policy: .senderAndSubject)
        let senderSubject = try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: senderSubjectContext, now: now)
        XCTAssertEqual(senderSubject.title, "sender")
        XCTAssertEqual(senderSubject.subtitle, "subject")
        XCTAssertEqual(senderSubject.body, "")

        let (_, genericContext) = try fixtureContext(policy: .generic)
        let generic = try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: genericContext, now: now)
        XCTAssertNil(generic.title)
        XCTAssertNil(generic.subtitle)
        XCTAssertEqual(generic.body, "New mail is available.")

        let (_, offContext) = try fixtureContext(policy: .off)
        XCTAssertEqual(try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: offContext, now: now), .fallback)
    }

    func testOnlyOffPolicySuppressesGenericFallbackAlert() {
        XCTAssertTrue(NotificationServicePresentation.shouldSuppressFallback(policy: .off))
        XCTAssertFalse(NotificationServicePresentation.shouldSuppressFallback(policy: .rich))
        XCTAssertFalse(NotificationServicePresentation.shouldSuppressFallback(policy: .senderAndSubject))
        XCTAssertFalse(NotificationServicePresentation.shouldSuppressFallback(policy: .generic))
    }

    func testGroupingUsesMailboxAndConversationNotMessageIdentity() {
        let first = NotificationServicePresentation.groupIdentifier(mailboxToken: "mailbox", threadToken: "thread")
        let secondMessage = NotificationServicePresentation.groupIdentifier(mailboxToken: "mailbox", threadToken: "thread")
        let otherConversation = NotificationServicePresentation.groupIdentifier(mailboxToken: "mailbox", threadToken: "other-thread")
        XCTAssertEqual(first, secondMessage)
        XCTAssertNotEqual(first, otherConversation)
    }

    func testTrustRotationAndExpiryKeepGenericFallback() throws {
        let (wire, context) = try fixtureContext(policy: .rich)
        let now = Date(timeIntervalSince1970: 1_787_227_320)
        let rotated = NotificationServicePresentation.Context(recipientAgreementPrivateKey: context.recipientAgreementPrivateKey, authority: context.authority, trustEpoch: context.trustEpoch + 1, trustRevision: context.trustRevision, trustHead: context.trustHead, policy: context.policy, replay: InMemoryNotificationReplayStore())
        XCTAssertEqual(try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: rotated, now: now), .fallback)
        XCTAssertEqual(try NotificationServicePresentation.render(userInfo: envelopeInfo(wire), context: context, now: now.addingTimeInterval(901)), .fallback)
    }

    func testMailboxScopedContextSelectsOnlyMatchingPPR2Mailbox() throws {
        let (wire, context) = try fixtureContext(policy: .rich)
        let mailbox = try RichNotificationEnvelope.mailboxID(in: wire)
        let now = Date(timeIntervalSince1970: 1_787_227_320)
        let selected = try NotificationServicePresentation.render(
            userInfo: envelopeInfo(wire), contexts: [mailbox: context], now: now
        )
        XCTAssertEqual(selected.title, "sender")
        XCTAssertEqual(
            try NotificationServicePresentation.render(
                userInfo: envelopeInfo(wire), contexts: [:], now: now
            ), .fallback
        )
        let otherMailbox = Data(repeating: 0x7f, count: 32)
        XCTAssertNotEqual(otherMailbox, mailbox)
        XCTAssertEqual(
            try NotificationServicePresentation.render(
                userInfo: envelopeInfo(wire), contexts: [otherMailbox: context], now: now
            ), .fallback
        )
    }

    func testConcurrentKeychainStyleReplayClaimsAcceptExactlyOne() {
        let backing = AtomicReplayBacking()
        let replay = NotificationReplayKeychainStore(backing: backing)
        let replayID = Data(repeating: 0x5A, count: 32)
        let lock = NSLock()
        var accepted = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if replay.claim(replayID) {
                lock.lock(); accepted += 1; lock.unlock()
            }
        }
        XCTAssertEqual(accepted, 1)
    }

    func testReplayCapNeverEvictsTheNewlyClaimedIdentifier() {
        let backing = AtomicReplayBacking()
        let replay = NotificationReplayKeychainStore(backing: backing)
        for index in 0..<128 {
            backing.seed(Data(String(format: "old-%03d", index).utf8))
        }
        let newlyClaimed = Data(repeating: 0, count: 32)

        XCTAssertTrue(replay.claim(newlyClaimed))
        XCTAssertTrue(backing.contains(newlyClaimed), "replay cap evicted the newly claimed identifier")
    }

    #if canImport(Security)
    func testNotificationPurgeCoversRegistrationAttestationRoutingAndReplayState() {
        let required = Set([
            "attestKeyID", "pendingAttestation", "routingHandle", "recipientDeviceID",
            "nodeDeviceID", "nodeSigningPublicKey", "registrationState",
        ])
        XCTAssertTrue(required.isSubset(of: Set(NotificationSharedKeychainStore.managedAccounts)))
    }

    func testKeychainReplayAccountsRemainDistinctConcurrently() {
        let replayIDs = (0..<8).map { Data(repeating: UInt8($0 + 1), count: 32) }
        let accounts = LockedStringSet()
        DispatchQueue.concurrentPerform(iterations: replayIDs.count) { index in
            accounts.insert(NotificationReplayKeychainStore.accountName(for: replayIDs[index]))
        }

        XCTAssertEqual(accounts.values.count, replayIDs.count)
        XCTAssertFalse(accounts.values.contains("replay.(AccountWireCodec.encodeBase64URL(replayIDs[0]))"))
    }
    #endif

    private func envelopeInfo(_ wire: Data) -> [AnyHashable: Any] {
        ["plainpost.envelope": AccountWireCodec.encodeBase64URL(wire)]
    }

    private func fixtureContext(policy: NotificationPreviewPolicy) throws -> (Data, NotificationServicePresentation.Context) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try Data(contentsOf: root.appendingPathComponent("Protocol/node-notification-v1/fixtures/envelope-v1.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: document) as? [String: Any])
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["wire_base64"] as? String)))
        let authority = try RichNotificationEnvelope.Authority(
            recipientDeviceID: try AccountDeviceID("20000000-0000-4000-8000-000000000002"),
            nodeID: try AccountDeviceID("30000000-0000-4000-8000-000000000003"),
            nodeSigningPublicKey: try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3])).publicKey.x963Representation
        )
        let privateKey = Data(repeating: 0, count: 31) + Data([2])
        let opened = try RichNotificationEnvelope.open(wire, recipientAgreementPrivateKey: privateKey, authority: authority, now: Date(timeIntervalSince1970: 1_787_227_320))
        return (wire, NotificationServicePresentation.Context(recipientAgreementPrivateKey: privateKey, authority: authority, trustEpoch: opened.header.trustEpoch, trustRevision: opened.header.trustRevision, trustHead: opened.header.trustHead, policy: policy, replay: InMemoryNotificationReplayStore()))
    }
}

private final class ReplayTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class AtomicReplayBacking: NotificationReplayAtomicStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<Data> = []

    func addIfAbsent(_ replayID: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values.insert(replayID).inserted else { return false }
        return true
    }

    func prune(maximum: Int, preserving replayID: Data) throws {
        lock.lock(); defer { lock.unlock() }
        while values.count > maximum {
            let oldest = values
                .filter { $0 != replayID }
                .sorted { $0.lexicographicallyPrecedes($1) }
                .first!
            values.remove(oldest)
        }
    }

    func purgeExpired(before: Date) throws {}

    func seed(_ value: Data) { lock.lock(); values.insert(value); lock.unlock() }
    func contains(_ value: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(value) }
}

#if canImport(Security)
private final class TimedReplayBacking: NotificationReplayAtomicStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data: Date]

    init(records: [Data: Date]) { self.records = records }

    func addIfAbsent(_ replayID: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard records[replayID] == nil else { return false }
        records[replayID] = Date()
        return true
    }

    func prune(maximum: Int, preserving replayID: Data) throws {}

    func purgeExpired(before date: Date) throws {
        lock.lock(); defer { lock.unlock() }
        let cutoff = date.addingTimeInterval(-InMemoryNotificationReplayStore.lifetime)
        records = records.filter { $0.value > cutoff }
    }

    func contains(_ replayID: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return records[replayID] != nil
    }
}
#endif

private final class LockedStringSet: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<String> = []
    func insert(_ value: String) { lock.lock(); storage.insert(value); lock.unlock() }
    var values: Set<String> { lock.lock(); defer { lock.unlock() }; return storage }
}
