import CryptoKit
import Foundation
import XCTest
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostNodeTransport
@testable import PlainpostAccountRuntime

final class OptionalNodeAttachTests: XCTestCase {
    func testAdmissionRequiresExactAccountCatalogAndSignedLease() throws {
        let fixture = try AttachFixture()
        let proposal = try fixture.proposal()
        XCTAssertEqual(proposal.accountID, fixture.account.id)
        XCTAssertEqual(proposal.kind, .nodeBacked)
        XCTAssertEqual(proposal.generation, 5)
        XCTAssertEqual(proposal.nodeID, fixture.nodeID.rawValue)
        XCTAssertEqual(proposal.providerIdentity, fixture.account.email.rawValue)

        XCTAssertThrowsError(try fixture.proposal(expectedGeneration: 3))
        XCTAssertThrowsError(try fixture.proposal(account: fixture.otherAccount))
        XCTAssertThrowsError(try fixture.proposal(plainpostAccountID: fixture.otherPlainpostID))
        XCTAssertThrowsError(try fixture.proposal(nodeID: fixture.otherNodeID))
        XCTAssertThrowsError(try fixture.proposal(trustEpoch: try AccountTrustEpoch(rawValue: PositiveUInt64(2))))
        XCTAssertThrowsError(try fixture.proposal(expectedAction: .replace))
        XCTAssertThrowsError(try fixture.proposal(lease: fixture.lease(action: .replace)))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(providerIdentity: "other@example.com")))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(providerKind: "unknown")))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [])))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [
            SyncNodeProviderMailbox(displayName: "Inbox", mailboxHandle: "inbox", role: "inbox", logicalMailboxID: fixture.otherMailboxID)
        ])))
        XCTAssertThrowsError(try fixture.proposal(now: try XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-05T12:05:00Z"))))
        XCTAssertThrowsError(try fixture.proposal(lease: fixture.lease(corruptSignature: true)))

        let inbox = fixture.inbox()
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [inbox, inbox])))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [
            inbox, fixture.mailbox(handle: "inbox", role: "sent")
        ])))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [
            inbox, fixture.mailbox(handle: " ", role: "sent")
        ])))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [
            inbox, fixture.mailbox(handle: " sent ", role: "sent")
        ])))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [
            inbox, fixture.mailbox(handle: "sent-1", role: "sent"),
            fixture.mailbox(handle: "sent-2", role: "sent")
        ])))
        XCTAssertThrowsError(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [
            inbox, fixture.mailbox(handle: "alien", role: "alien")
        ])))
        XCTAssertNoThrow(try fixture.proposal(nodeAccount: fixture.nodeAccount(mailboxes: [
            inbox, fixture.mailbox(handle: "other-1", role: "other"),
            fixture.mailbox(handle: "other-2", role: "other")
        ])))
    }
}

private struct AttachFixture {
    let now = try! XCTUnwrap(AccountWireCodec.parseTimestamp("2026-08-05T12:00:01Z"))
    let plainpostID = try! PlainpostAccountID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    let otherPlainpostID = try! PlainpostAccountID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    let nodeID = try! AccountDeviceID("11111111-2222-4333-8444-555555555555")
    let otherNodeID = try! AccountDeviceID("22222222-2222-4333-8444-555555555555")
    let mailboxID = LogicalMailboxID(rawValue: Data(repeating: 1, count: 32))!
    let otherMailboxID = LogicalMailboxID(rawValue: Data(repeating: 2, count: 32))!
    let account = Account(id: AccountID("provider-A"), displayName: "A", email: EmailAddress("a@example.com"), imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    let otherAccount = Account(id: AccountID("provider-B"), displayName: "B", email: EmailAddress("b@example.com"), imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    let manifest: SessionKeyManifestVerifier

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json"))
        let session = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let manifestData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(session["manifest"]))
        let rootKey = try XCTUnwrap(session["offlineRootPublicKey"] as? String)
        manifest = try SessionKeyManifestVerifier(
            document: manifestData, offlineRootKeyID: "session-root-test-1",
            offlineRootPublicKey: try AccountWireCodec.decodeBase64URL(rootKey, exactBytes: 65), now: now
        )
    }

    func mailbox(handle: String, role: String) -> SyncNodeProviderMailbox {
        SyncNodeProviderMailbox(displayName: role, mailboxHandle: handle, role: role, logicalMailboxID: mailboxID)
    }

    func inbox() -> SyncNodeProviderMailbox { mailbox(handle: "inbox", role: "inbox") }

    func nodeAccount(providerIdentity: String = "a@example.com", providerKind: String = "generic", mailboxes: [SyncNodeProviderMailbox]? = nil) -> NodeMailAccount {
        NodeMailAccount(
            logicalMailboxID: mailboxID, providerIdentity: providerIdentity, providerKind: providerKind,
            isPrimary: true, state: .ready,
            mailboxes: mailboxes ?? [inbox()]
        )
    }

    func lease(action: AccountNodeEnrollmentAction = .enroll, corruptSignature: Bool = false) throws -> AccountNodeOfflineLeaseV2 {
        let base = try AccountNodeOperationBindingV1(
            accountID: plainpostID, trustEpoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            claimID: NodeEnrollmentClaimID("33333333-3333-4333-8333-333333333333"), nodeDeviceID: nodeID,
            centralAudience: "central.test", action: action,
            replacedNodeID: action == .replace ? otherNodeID : nil,
            replacementRevocationDigest: action == .replace ? Data(repeating: 6, count: 32) : nil,
            admissionEvidenceDigest: Data(repeating: 3, count: 32),
            issuanceDigest: Data(repeating: 4, count: 32)
        )
        let binding = try AccountNodeOperationBindingV2(base: base, cleanupCapabilityDigest: Data(repeating: 5, count: 32))
        let unsigned = try AccountNodeOfflineLeaseV2(
            binding: binding, leaseID: "44444444-4444-4444-8444-444444444444",
            issuedAt: "2026-08-05T12:00:00Z", expiresAt: "2026-08-05T12:05:00Z",
            serverKeyID: "offline-test-1", signature: Data(repeating: 1, count: 64)
        )
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3]))
        var signature = try key.signature(for: AccountTranscript.nodeOfflineLeaseV2(unsigned)).rawRepresentation
        signature = lowS(signature)
        if corruptSignature { signature[0] ^= 1 }
        return try AccountNodeOfflineLeaseV2(
            binding: binding, leaseID: unsigned.leaseID, issuedAt: unsigned.issuedAt,
            expiresAt: unsigned.expiresAt, serverKeyID: unsigned.serverKeyID, signature: signature
        )
    }

    func proposal(
        account: Account? = nil, expectedGeneration: Int64 = 4,
        plainpostAccountID: PlainpostAccountID? = nil, nodeID: AccountDeviceID? = nil,
        trustEpoch: AccountTrustEpoch? = nil, nodeAccount: NodeMailAccount? = nil,
        lease: AccountNodeOfflineLeaseV2? = nil,
        expectedAction: AccountNodeEnrollmentAction = .enroll, now: Date? = nil
    ) throws -> AccountMailSource {
        let source = try AccountMailSource(
            accountID: self.account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 4
        )
        return try NodeAttachAdmission.propose(
            account: account ?? self.account, source: source, expectedGeneration: expectedGeneration,
            plainpostAccountID: plainpostAccountID ?? plainpostID,
            nodeID: nodeID ?? self.nodeID,
            trustEpoch: trustEpoch ?? AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            lease: lease ?? self.lease(), expectedAction: expectedAction, manifest: manifest,
            nodeAccount: nodeAccount ?? self.nodeAccount(), now: now ?? self.now
        )
    }
}

private func lowS(_ signature: Data) -> Data {
    let halfOrder = Data([0x7f, 0xff, 0xff, 0xff, 0x80, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xe7, 0x37, 0xd5, 0x6d, 0x38, 0xbc, 0xf4, 0x27, 0x9d, 0xce, 0x56, 0x01, 0x7e, 0x31, 0x92, 0xa8])
    guard signature.count == 64, halfOrder.lexicographicallyPrecedes(signature.suffix(32)) else { return signature }
    let order: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51]
    let high = [UInt8](signature.suffix(32))
    var result = Array(repeating: UInt8(0), count: 32), borrow = 0
    for index in stride(from: 31, through: 0, by: -1) {
        let value = Int(order[index]) - Int(high[index]) - borrow
        result[index] = UInt8(value < 0 ? value + 256 : value)
        borrow = value < 0 ? 1 : 0
    }
    return signature.prefix(32) + Data(result)
}
