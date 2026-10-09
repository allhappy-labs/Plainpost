import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
import PlainpostTestSupport

/// A background drain runs `recoverBackgroundAgentJobs` whenever it starts,
/// for example on an IDLE signal, the fallback poll or a wake. That pass must
/// leave alone an approved delivery that another runtime is sending under a
/// live lease. It may mark a delivery uncertain only after the lease expires.
final class ApprovedDeliveryLeaseRecoveryTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-delivery-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testRecoveryLeavesApprovedDeliveryWithLiveLeaseRunning() throws {
        let (store, jobID) = try storeWithApprovedDeliveryJob()
        let claimedAt = Date(timeIntervalSince1970: 2_100_000_000)
        let running = try XCTUnwrap(
            store.claimNextJob(now: claimedAt, leaseDuration: 180, allowedKinds: [.approvedDelivery])
        )
        XCTAssertEqual(running.id, jobID)
        let leaseToken = try XCTUnwrap(running.leaseToken)

        // A concurrent background drain one second into a 180-second lease.
        let summary = try store.recoverBackgroundAgentJobs(
            allowedKinds: PlainpostBackgroundAgentJobPolicyKinds.all,
            now: claimedAt.addingTimeInterval(1)
        )

        let afterRecovery = try store.job(id: jobID)
        XCTAssertEqual(summary.requeuedExpiredCount, 0)
        XCTAssertEqual(afterRecovery.state, .running)
        XCTAssertEqual(afterRecovery.leaseToken, leaseToken)
        XCTAssertNil(afterRecovery.errorCode)
        // The sender that still holds the lease can finish the job.
        XCTAssertNoThrow(try store.completeJob(id: jobID, leaseToken: leaseToken, resultArtifactID: nil))
        XCTAssertEqual(try store.job(id: jobID).state, .completed)
    }

    func testRecoveryStillMarksApprovedDeliveryUncertainOnceItsLeaseExpires() throws {
        let (store, jobID) = try storeWithApprovedDeliveryJob()
        let claimedAt = Date(timeIntervalSince1970: 2_100_000_000)
        let running = try XCTUnwrap(
            store.claimNextJob(now: claimedAt, leaseDuration: 180, allowedKinds: [.approvedDelivery])
        )
        let leaseToken = try XCTUnwrap(running.leaseToken)

        // Exactly at expiry the lease is still live; strictly after it is not.
        _ = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.approvedDelivery],
            now: claimedAt.addingTimeInterval(180)
        )
        XCTAssertEqual(try store.job(id: jobID).state, .running)

        _ = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.approvedDelivery],
            now: claimedAt.addingTimeInterval(181)
        )
        let recovered = try store.job(id: jobID)
        XCTAssertEqual(recovered.state, .deliveryUncertain)
        XCTAssertNil(recovered.leaseToken)
        XCTAssertEqual(recovered.errorCode, "DELIVERY_UNCERTAIN")
        XCTAssertThrowsError(try store.completeJob(id: jobID, leaseToken: leaseToken, resultArtifactID: nil))
    }

    func testRecoveryMarksTheSendRequestUncertainWithTheExpiredDelivery() throws {
        let (store, jobID, requestID) = try storeWithSendingApprovedDelivery()
        let claimedAt = Date(timeIntervalSince1970: 2_100_000_000)
        _ = try XCTUnwrap(store.claimNextJob(now: claimedAt, leaseDuration: 10, allowedKinds: [.approvedDelivery]))

        _ = try store.recoverBackgroundAgentJobs(allowedKinds: [.approvedDelivery], now: claimedAt.addingTimeInterval(11))

        XCTAssertEqual(try store.job(id: jobID).state, .deliveryUncertain)
        XCTAssertEqual(try store.sendRequest(id: requestID).status, .deliveryUncertain)
    }

    func testClaimRecoveryMarksAnExpiredDeliveryUncertainInsteadOfRequeueingItDead() throws {
        let (store, jobID, requestID) = try storeWithSendingApprovedDelivery()
        let claimedAt = Date(timeIntervalSince1970: 2_100_000_000)
        let running = try XCTUnwrap(
            store.claimNextJob(now: claimedAt, leaseDuration: 10, allowedKinds: [.approvedDelivery])
        )
        XCTAssertEqual(running.attempt, 1)

        // Any runtime's next claim, of any kind, recovers expired leases.
        XCTAssertNil(try store.claimNextJob(now: claimedAt.addingTimeInterval(11), leaseDuration: 10, allowedKinds: nil))

        let recovered = try store.job(id: jobID)
        XCTAssertEqual(recovered.state, .deliveryUncertain, "A one-shot delivery must not be requeued dead.")
        XCTAssertNil(recovered.leaseToken)
        XCTAssertEqual(recovered.errorCode, "DELIVERY_UNCERTAIN")
        XCTAssertEqual(try store.sendRequest(id: requestID).status, .deliveryUncertain)
        XCTAssertNil(try store.claimNextJob(now: claimedAt.addingTimeInterval(20), leaseDuration: 10, allowedKinds: nil))
    }

    func testClaimRecoveryDoesNotCallAnExpiredCancelledDeliveryCancelled() throws {
        let (store, jobID, _) = try storeWithSendingApprovedDelivery()
        let claimedAt = Date(timeIntervalSince1970: 2_100_000_000)
        _ = try XCTUnwrap(store.claimNextJob(now: claimedAt, leaseDuration: 10, allowedKinds: [.approvedDelivery]))
        try store.requestJobCancellation(id: jobID)

        _ = try store.claimNextJob(now: claimedAt.addingTimeInterval(11), leaseDuration: 10, allowedKinds: nil)

        // The sender may have crossed the SMTP boundary before it stopped.
        XCTAssertEqual(try store.job(id: jobID).state, .deliveryUncertain)
    }

    func testClaimRecoveryKeepsAnExpiredOneShotJobClaimable() throws {
        let store = try SQLiteMailStore(path: directoryURL.appendingPathComponent("Plainpost.sqlite").path)
        try store.migrate()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let deny = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .denySend,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(
                        PlainpostApprovalDecisionInput(requestID: request.id, actorID: PlainpostFixtures.guiUser.id)
                    ),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "deny-send:\(request.id.rawValue)"
            )
        )
        let claimedAt = Date().addingTimeInterval(60)
        _ = try XCTUnwrap(store.claimNextJob(now: claimedAt, leaseDuration: 10, allowedKinds: [.denySend]))

        let reclaimed = try store.claimNextJob(
            now: claimedAt.addingTimeInterval(11),
            leaseDuration: 10,
            allowedKinds: [.denySend]
        )

        XCTAssertEqual(reclaimed?.id, deny.id, "An expired one-shot job must stay claimable, not sit queued forever.")
        XCTAssertEqual(reclaimed?.attempt, 1)
    }

    /// An approved delivery whose send request has already moved to
    /// `sending`, as it does just before SMTP.
    private func storeWithSendingApprovedDelivery() throws -> (SQLiteMailStore, String, SendRequestID) {
        let (store, jobID) = try storeWithApprovedDeliveryJob()
        let job = try store.job(id: jobID)
        let input = try JSONDecoder().decode(PlainpostApprovalDecisionInput.self, from: Data(job.payloadJSON.utf8))
        let request = try store.sendRequest(id: input.requestID)
        let draft = try store.draft(id: request.draftID)
        _ = try store.claimSendRequestForDelivery(
            id: request.id,
            currentDraftHash: draft.contentHash,
            actor: PlainpostFixtures.guiUser
        )
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sending)
        return (store, jobID, request.id)
    }

    private func storeWithApprovedDeliveryJob() throws -> (SQLiteMailStore, String) {
        let store = try SQLiteMailStore(path: directoryURL.appendingPathComponent("Plainpost.sqlite").path)
        try store.migrate()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let payload = String(
            decoding: try JSONEncoder().encode(
                PlainpostApprovalDecisionInput(requestID: request.id, actorID: PlainpostFixtures.guiUser.id)
            ),
            as: UTF8.self
        )
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .approvedDelivery,
                payloadJSON: payload,
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "approved-delivery:\(request.id.rawValue)"
            )
        )
        return (store, job.id)
    }
}

/// Mirrors `PlainpostBackgroundAgentJobPolicy.allowedKinds`, which lives in
/// PlainpostOperationRuntime; the DB tests do not depend on that module.
private enum PlainpostBackgroundAgentJobPolicyKinds {
    static let all: Set<PlainpostOperationKind> = [
        .inboxSync, .historicalSync, .approvedDelivery, .denySend,
        .aiOperation, .searchRebuild, .mailboxFlag, .mailboxArchive,
    ]
}
