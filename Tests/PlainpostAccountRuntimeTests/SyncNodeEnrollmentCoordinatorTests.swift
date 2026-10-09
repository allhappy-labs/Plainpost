import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport

@MainActor
final class SyncNodeEnrollmentCoordinatorTests: XCTestCase {
    func testAdmissionResponseUsesReceiptClockAfterRequestCrossesSecondBoundary() async throws {
        let fixture = try Fixture()
        let responseNow = fixture.now.addingTimeInterval(1)
        let verifier = ReceiptClockResponseVerifier(expected: responseNow)
        let coordinator = try fixture.coordinator(
            remote: SyncNodeRemoteFixture(fixture: fixture),
            activeNodeID: nil,
            responseVerifier: verifier,
            responseValidationClock: { responseNow }
        )

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("fresh response was rejected at a second boundary") }
        XCTAssertTrue(verifier.didVerifyExpectedTime)
    }

    func testVerifiedV2AdmissionActivatesBeforeTrustIsAccepted() async throws {
        let fixture = try Fixture()
        let remote = V2SyncNodeRemoteFixture(fixture: fixture)
        let activation = RecordingSyncNodeActivator()
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil, activation: activation)

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let captured = await activation.snapshot()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].request.evidence.claimID, fixture.claim.claimID)
        XCTAssertNotNil(captured[0].response.cleanupCapability)
        XCTAssertFalse(coordinator.retainsSetupVerifierMaterial)
    }

    func testUncertainV2ActivationReplaysWithoutResubmittingCentral() async throws {
        let fixture = try Fixture()
        let remote = V2SyncNodeRemoteFixture(fixture: fixture)
        let activation = UncertainSyncNodeActivator()
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil, activation: activation)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)
        XCTAssertEqual(coordinator.state, .activationResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingActivationReplay)
        await coordinator.retryActivation()
        guard case .installed = coordinator.state else { return XCTFail("expected installed") }
        let attempts = await activation.attempts()
        XCTAssertEqual(attempts, 2)
    }

    func testCancelAndResetRetainPossiblyCommittedActivationRecovery() async throws {
        let fixture = try Fixture()
        let remote = V2SyncNodeRemoteFixture(fixture: fixture)
        let activation = UncertainSyncNodeActivator()
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil, activation: activation)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)
        XCTAssertEqual(coordinator.state, .activationResponseUncertain)

        await coordinator.cancel()
        coordinator.reset()
        XCTAssertEqual(coordinator.state, .activationResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingActivationReplay)
        let cancelled = await remote.cancelledClaimIDs()
        let cancellationCalls = await activation.cancellations()
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(cancellationCalls, 1)
    }

    // A presentation cancel/reset while V3 is in flight must retain the
    // claimed recovery path, but it may never install the successor until
    // that activation owner has actually completed.
    func testInFlightActivationCancelAndResetCannotAcceptTrustSuccessorPrematurely() async throws {
        let fixture = try Fixture()
        let remote = V2SyncNodeRemoteFixture(fixture: fixture)
        let activation = BlockingSyncNodeActivator()
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil, activation: activation)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }
        let commit = Task { @MainActor in await coordinator.confirmMatchingString(matching, now: fixture.now) }
        await activation.waitUntilStarted()

        await coordinator.cancel()
        coordinator.reset()
        let beforeAcceptance = await fixture.trust.acceptanceCount()
        XCTAssertEqual(beforeAcceptance, 0)
        XCTAssertEqual(coordinator.state, .committing)
        XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)

        await activation.release()
        await commit.value
        guard case .installed = coordinator.state else { return XCTFail("completed activation must install exactly once") }
        let afterAcceptance = await fixture.trust.acceptanceCount()
        XCTAssertEqual(afterAcceptance, 1)
    }

    func testEnrollmentWalksExplicitApprovalStatesAndCommitsCanonicalEvidence() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)

        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation, got \(coordinator.state)") }
        let beforeCommit = await remote.snapshot()
        XCTAssertEqual(beforeCommit.states, [.lookup, .stepUp(.enroll)])
        await coordinator.confirmMatchingString(matching, now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let afterCommit = await remote.snapshot()
        XCTAssertEqual(afterCommit.committedRequest?.evidence.action, .enroll)
        XCTAssertNil(afterCommit.committedRequest?.evidence.replacedNodeID)
        XCTAssertEqual(coordinator.activeNodeID, afterCommit.committedRequest?.evidence.nodeDeviceID)
        XCTAssertEqual(afterCommit.states, [.lookup, .stepUp(.enroll), .commit(.enroll)])
        XCTAssertEqual(afterCommit.committedRequest?.evidence.matchingTranscriptDigest.count, 32)
        let successor = try XCTUnwrap(afterCommit.committedRequest?.trustCommit)
        XCTAssertNotEqual(successor, fixture.trustCommit, "Sync Node admission must submit a signed successor, never the unchanged prior head")
        XCTAssertEqual(successor.state.revision.value, fixture.trustCommit.state.revision.value + 1)
        XCTAssertEqual(successor.state.transition.kind, .admission)
        XCTAssertEqual(successor.state.transition.targetDeviceIDs, [fixture.claim.nodeDeviceID])
        XCTAssertEqual(successor.state.members.first(where: { $0.deviceID == fixture.claim.nodeDeviceID })?.platform, .syncNode)
    }

    func testLostCommitResponseReplaysTheExactAdmissionWithoutCancellingTheClaim() async throws {
        let fixture = try Fixture()
        let remote = ResponseLossRemote(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }

        await coordinator.confirmMatchingString(matching, now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)
        let firstAttempts = await remote.requests()
        let first = try XCTUnwrap(firstAttempts.first)

        await coordinator.retryCommit(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected replayed admission to install") }
        let attempts = await remote.requests()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[1].evidence, first.evidence)
        XCTAssertEqual(attempts[1].claimProofSignature, first.claimProofSignature)
        XCTAssertEqual(attempts[1].matchingConfirmationSignature, first.matchingConfirmationSignature)
        XCTAssertEqual(attempts[1].admissionApprovalSignature, first.admissionApprovalSignature)
        XCTAssertEqual(attempts[1].idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(attempts[1].trustCommit, first.trustCommit)
        let cancelled = await remote.cancelledClaimIDs()
        XCTAssertEqual(cancelled, [])
        XCTAssertFalse(coordinator.hasPendingCommitReplay)
        XCTAssertFalse(coordinator.retainsSetupVerifierMaterial)
    }

    func testCancellingAnUncertainCommitPreservesExactReplayAndDoesNotInvalidateClaim() async throws {
        let fixture = try Fixture()
        let remote = ResponseLossRemote(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)

        await coordinator.cancel()

        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)
        let cancelled = await remote.cancelledClaimIDs()
        XCTAssertEqual(cancelled, [])
    }

    func testViewDisappearancePreservesAnUncertainCommitForExactRetry() async throws {
        let fixture = try Fixture()
        let remote = ResponseLossRemote(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected matching confirmation") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        let firstAttempts = await remote.requests()
        let first = try XCTUnwrap(firstAttempts.first)

        await coordinator.viewDidDisappear()

        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)
        let cancelledAfterDisappearance = await remote.cancelledClaimIDs()
        XCTAssertEqual(cancelledAfterDisappearance, [])

        await coordinator.retryCommit(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected replayed admission to install") }
        let attempts = await remote.requests()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[1].evidence, first.evidence)
        XCTAssertEqual(attempts[1].claimProofSignature, first.claimProofSignature)
        XCTAssertEqual(attempts[1].matchingConfirmationSignature, first.matchingConfirmationSignature)
        XCTAssertEqual(attempts[1].admissionApprovalSignature, first.admissionApprovalSignature)
        XCTAssertEqual(attempts[1].idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(attempts[1].trustCommit, first.trustCommit)
        XCTAssertFalse(coordinator.hasPendingCommitReplay)
        XCTAssertFalse(coordinator.retainsSetupVerifierMaterial)
    }

    func testMatchingRejectionAndCancelInvalidateClaim() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.rejectMatchingString()

        XCTAssertEqual(coordinator.state, .enterCode)
        let cancelled = await remote.snapshot()
        XCTAssertEqual(cancelled.cancelledClaimIDs, [fixture.claim.claimID])
    }

    func testFailureAfterLookupStillInvalidatesClaim() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil, localAuthenticator: FailingLocalAuthenticator())
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        XCTAssertEqual(coordinator.state, .failed)
        let failed = await remote.snapshot()
        XCTAssertEqual(failed.cancelledClaimIDs, [fixture.claim.claimID])
        XCTAssertFalse(coordinator.retainsSetupVerifierMaterial)
    }

    func testCancellationFencesStaleLookupAndInvalidatesExactlyOnce() async throws {
        let fixture = try Fixture()
        let remote = BlockingLookupRemote(claim: fixture.claim)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)
        coordinator.start(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await remote.waitUntilLookupStarts()

        await coordinator.cancel()
        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .enterCode)
        await remote.releaseLookup()
        await remote.waitUntilCancelled()

        let calls = await remote.calls
        XCTAssertEqual(calls, [.lookup, .cancel])
        XCTAssertEqual(coordinator.state, .enterCode)
        XCTAssertFalse(coordinator.retainsSetupVerifierMaterial)
    }

    func testLateOldLookupCannotCancelOrWipeNewAttemptUsingSameLiveClaim() async throws {
        let fixture = try Fixture()
        let remote = FirstLookupBlockingRemote(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)
        coordinator.start(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await remote.waitUntilFirstLookupStarts()

        await coordinator.cancel()
        let fresh = Task { @MainActor in
            await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        }
        for _ in 0 ..< 100 {
            if case .matchingStringConfirmation = coordinator.state { break }
            await Task.yield()
        }
        guard case .matchingStringConfirmation = coordinator.state else {
            return XCTFail("fresh attempt did not reach approval")
        }

        await remote.releaseFirstLookup()
        await fresh.value
        for _ in 0 ..< 10 { await Task.yield() }

        guard case .matchingStringConfirmation = coordinator.state else {
            return XCTFail("late lookup changed the fresh attempt")
        }
        XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)
        let cancelled = await remote.cancelledClaimIDs()
        XCTAssertEqual(cancelled, [])
    }

    func testDelayedOldCancellationCannotWipeNewAttemptUsingSameLiveClaim() async throws {
        let fixture = try Fixture()
        let remote = DelayedCancellationRemote(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = coordinator.state else {
            return XCTFail("first attempt did not reach approval")
        }

        let cancellation = Task { @MainActor in await coordinator.cancel() }
        await remote.waitUntilCancellationStarts()
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = coordinator.state else {
            return XCTFail("fresh attempt did not reach approval")
        }

        await remote.releaseCancellation()
        await cancellation.value

        guard case .matchingStringConfirmation = coordinator.state else {
            return XCTFail("old cancellation changed the fresh attempt")
        }
        XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)
    }

    func testProvisionedConnectOrdersFetchAndPinVerificationBeforeApprovalAndActivation() async throws {
        let fixture = try Fixture()
        let events = EnrollmentOrderRecorder()
        let presenter = OrderedEnrollmentPresenter(presentation: fixture.presentation, events: events)
        let remote = OrderedEnrollmentRemote(base: V2SyncNodeRemoteFixture(fixture: fixture), events: events)
        let verifier = OrderedBootstrapVerifier(origin: fixture.expectedOrigin, events: events)
        let local = OrderedLocalAuthenticator(events: events)
        let activation = OrderedSyncNodeActivator(events: events)
        let coordinator = SyncNodeEnrollmentCoordinator(
            remote: remote,
            presenter: presenter,
            bootstrapVerifier: verifier,
            localAuthenticator: local,
            responseVerifier: AcceptingResponseVerifier(),
            trust: fixture.trust,
            activation: activation,
            credentials: fixture.credentials,
            credentialsProvider: { [credentials = fixture.credentials] in credentials },
            device: fixture.identity,
            activeNodeID: nil,
            random: { _ in Data(repeating: 8, count: 32) }
        )
        events.record("apple")

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = coordinator.state else {
            return XCTFail("expected pinned approval")
        }
        events.record("approve")
        await coordinator.approvePinnedTarget(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed") }
        let ordered = events.values()
        XCTAssertEqual(ordered, ["apple", "fetch", "lookup", "verifyPins", "localAuth", "stepUp", "approve", "admission", "activate"])
        let origins = await activation.origins()
        XCTAssertEqual(origins, [fixture.expectedOrigin])
    }

    func testExpiredApprovalRequiresFreshExplicitProvisionedAttempt() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let presenter = CountingProvisionedPresenter(presentation: fixture.presentation)
        let coordinator = SyncNodeEnrollmentCoordinator(
            remote: remote,
            presenter: presenter,
            bootstrapVerifier: OrderedBootstrapVerifier(origin: fixture.expectedOrigin, events: EnrollmentOrderRecorder()),
            localAuthenticator: PassingLocalAuthenticator(),
            responseVerifier: AcceptingResponseVerifier(),
            trust: fixture.trust,
            activation: RecordingSyncNodeActivator(),
            credentials: fixture.credentials,
            credentialsProvider: { [credentials = fixture.credentials] in credentials },
            device: fixture.identity,
            activeNodeID: nil,
            random: { _ in Data(repeating: 8, count: 32) }
        )
        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = coordinator.state else { return XCTFail("expected approval") }

        await coordinator.approvePinnedTarget(now: fixture.presentation.expiresAt)

        XCTAssertEqual(coordinator.state, .failed)
        coordinator.reset()
        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = coordinator.state else {
            return XCTFail("fresh explicit attempt did not obtain a new presentation")
        }
        let presentationCount = await presenter.count()
        let states = (await remote.snapshot()).states
        XCTAssertEqual(presentationCount, 2)
        XCTAssertEqual(states, [.lookup, .stepUp(.enroll), .lookup, .stepUp(.enroll)])
    }

    func testCancellationWhileTrustCommitIsSuspendedFencesAllLaterEffects() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let trust = BlockingCommitTrust(base: fixture.trust)
        let coordinator = SyncNodeEnrollmentCoordinator(
            remote: remote,
            localAuthenticator: PassingLocalAuthenticator(),
            responseVerifier: AcceptingResponseVerifier(),
            trust: trust,
            activation: RecordingSyncNodeActivator(),
            credentials: fixture.credentials,
            credentialsProvider: { [credentials = fixture.credentials] in credentials },
            device: fixture.identity,
            activeNodeID: nil,
            random: { _ in Data(repeating: 8, count: 32) }
        )
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected approval") }
        let approval = Task { @MainActor in await coordinator.confirmMatchingString(matching, now: fixture.now) }
        await trust.waitUntilCommitStarts()

        await coordinator.cancel()
        await trust.releaseCommit()
        await approval.value

        XCTAssertEqual(coordinator.state, .enterCode)
        let states = (await remote.snapshot()).states
        let acceptances = await trust.acceptanceCount()
        XCTAssertEqual(states, [.lookup, .stepUp(.enroll)])
        XCTAssertEqual(acceptances, 0)
    }

    func testReplacementRequiresExactSelectedAndConfirmedCurrentNode() async throws {
        let fixture = try Fixture()
        let current = try AccountDeviceID("90000000-0000-4000-8000-000000000099")
        let wrong = try AccountDeviceID("90000000-0000-4000-8000-000000000098")
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: current)

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        XCTAssertEqual(coordinator.state, .failed)
        coordinator.reset()
        coordinator.selectReplacement(of: wrong)
        coordinator.confirmReplacement(of: wrong)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        XCTAssertEqual(coordinator.state, .failed)
        coordinator.reset()
        coordinator.selectReplacement(of: current)
        coordinator.confirmReplacement(of: current)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)

        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("replacement did not reach matching confirmation") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)
        guard case .installed = coordinator.state else { return XCTFail("replacement did not install") }
        let replacementEvents = await remote.snapshot()
        XCTAssertEqual(replacementEvents.states, [.lookup, .stepUp(.replace), .commit(.replace)])
        let request = try XCTUnwrap(replacementEvents.committedRequest)
        XCTAssertEqual(request.evidence.action, .replace)
        XCTAssertEqual(request.evidence.replacedNodeID, current)
        XCTAssertEqual(coordinator.activeNodeID, request.evidence.nodeDeviceID)
        let replaceRequests = await remote.requests()
        XCTAssertEqual(replaceRequests.last?.expectedCentralAudience, fixture.centralAudience)
        let publicKey = try P256.Signing.PublicKey(x963Representation: fixture.identity.publicBundle.signingKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: request.admissionApprovalSignature)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: AccountTranscript.nodeEnrollmentReplacementApproval(request.evidence, idempotencyKey: request.idempotencyKey)))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: AccountTranscript.nodeEnrollmentAdmissionApproval(request.evidence, idempotencyKey: request.idempotencyKey)))
    }

    func testTerminalReplacementPathsRequireFreshExactConfirmation() async throws {
        let fixture = try Fixture()
        let current = try AccountDeviceID("90000000-0000-4000-8000-000000000099")
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: current)

        coordinator.selectReplacement(of: current)
        coordinator.confirmReplacement(of: current)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = coordinator.state else { return XCTFail("expected pending replacement") }
        await coordinator.rejectMatchingString()

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        XCTAssertEqual(coordinator.state, .failed, "a rejected replacement cannot be reopened without exact reconfirmation")
        coordinator.reset()
        coordinator.selectReplacement(of: current)
        coordinator.confirmReplacement(of: current)
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = coordinator.state else { return XCTFail("fresh exact confirmation should permit replacement") }
        await coordinator.cancel()
        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        XCTAssertEqual(coordinator.state, .failed, "cancelled replacement cannot reuse prior consent")
    }

    func testOutdatedServerSetupStopsBeforeAnyNetworkOrApproval() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let presenter = CountingProvisionedPresenter(presentation: fixture.presentation)
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: presenter)
        let legacy = try SyncNodeBootstrapProfile(canonicalOrigin: fixture.expectedOrigin, nodeDeviceID: fixture.profile.nodeDeviceID, signingKeyDigest: fixture.profile.signingKeyDigest, capabilityID: fixture.profile.capabilityID, capability: fixture.profile.capability, centralAudience: nil)

        await coordinator.begin(profile: legacy, appleAuthorization: fixture.appleAuthorization, now: fixture.now)

        XCTAssertEqual(coordinator.state, .profileOutdated)
        let fetches = await presenter.count()
        let states = (await remote.snapshot()).states
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(states, [])
        coordinator.reset()
        XCTAssertEqual(coordinator.state, .enterCode)
    }

    func testClosedLeaseKeyWindowStopsBeforePresentation() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let presenter = CountingProvisionedPresenter(presentation: fixture.presentation)
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: presenter, responseVerifier: ClosedLeaseWindowVerifier())

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)

        XCTAssertEqual(coordinator.state, .failed)
        let fetches = await presenter.count()
        XCTAssertEqual(fetches, 0)
    }

    func testPostCommitAudienceMismatchIsStickyNeverCancelsAndRetryVerificationInstalls() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let verifier = AudienceMismatchThenAcceptVerifier(failures: 1)
        let activation = RecordingSyncNodeActivator()
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), responseVerifier: verifier, activation: activation)

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)

        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.audienceMismatch))
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        XCTAssertTrue(coordinator.retainsCommittedAdmission)
        coordinator.reset()
        await coordinator.cancel()
        await coordinator.viewDidDisappear()
        coordinator.invalidatePresentationOwnership()
        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.audienceMismatch))
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        let cancelledAfterFailure = (await remote.snapshot()).cancelledClaimIDs
        let activationsAfterFailure = await activation.snapshot().count
        XCTAssertEqual(cancelledAfterFailure, [])
        XCTAssertEqual(activationsAfterFailure, 0)

        await coordinator.retryCommitVerification(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let requests = await remote.requests()
        let cancelled = (await remote.snapshot()).cancelledClaimIDs
        let activations = await activation.snapshot().count
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
        XCTAssertEqual(requests[0].admissionApprovalSignature, requests[1].admissionApprovalSignature)
        XCTAssertEqual(requests.map(\.expectedCentralAudience), ["central.test", "central.test"])
        XCTAssertEqual(verifier.calls().map { $0.audience }, ["central.test", "central.test"])
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(activations, 1)
        XCTAssertFalse(coordinator.hasPendingCommitReplay)
    }

    func testCentralAudienceRejectionCancelsClaimAndIsRestartable() async throws {
        let fixture = try Fixture()
        let remote = CommitFailingRemote(fixture: fixture, error: SyncNodeEnrollmentCommitError.audienceMismatch)
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)

        XCTAssertEqual(coordinator.state, .serverAudienceMismatch)
        XCTAssertFalse(coordinator.hasPendingCommitReplay)
        XCTAssertFalse(coordinator.retainsCommittedAdmission)
        let requests = await remote.requests
        let cancelled = await remote.cancelled()
        XCTAssertEqual(requests.map(\.expectedCentralAudience), ["central.test"])
        XCTAssertEqual(cancelled, [fixture.claim.claimID])
        coordinator.reset()
        XCTAssertEqual(coordinator.state, .enterCode)
    }

    func testUndecodableSuccessIsUncertainAndKeepsTheClaim() async throws {
        let fixture = try Fixture()
        let remote = CommitFailingRemote(fixture: fixture, error: SyncNodeEnrollmentCommitError.undecodableSuccess)
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)

        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        let cancelled = await remote.cancelled()
        XCTAssertEqual(cancelled, [])
    }

    // Catches the iOS defect: a committed admission without V2 must never be
    // accepted into local trust without activating the Node.
    func testV1AdmissionNeverAcceptsTrustWithoutActivation() async throws {
        let fixture = try Fixture()
        let remote = V1OnlySyncNodeRemote(fixture: fixture)
        let trust = BlockingCommitTrust(base: fixture.trust)
        let activation = RecordingSyncNodeActivator()
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: activation, trust: trust)
        let approval = Task { @MainActor in
            await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
            await coordinator.approvePinnedTarget(now: fixture.now)
        }
        await trust.waitUntilCommitStarts()
        await trust.releaseCommit()
        await approval.value

        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.missingV2))
        let acceptances = await trust.acceptanceCount()
        let activations = await activation.snapshot().count
        let cancelled = await remote.cancelled()
        XCTAssertEqual(acceptances, 0)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(cancelled, [])
    }

    func testLegacySeamCarriesExplicitAudienceIntoCommit() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let coordinator = try fixture.coordinator(remote: remote, activeNodeID: nil)

        await coordinator.begin(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: "legacy.central", appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { return XCTFail("expected approval") }
        await coordinator.confirmMatchingString(matching, now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed") }
        let requests = await remote.requests()
        XCTAssertEqual(requests.map(\.expectedCentralAudience), ["legacy.central"])
    }

    // Central's audience and authorization gates run before its replay lookup,
    // so a definite rejection of a retry cannot prove that an earlier
    // uncertain attempt did not commit.
    func testRejectionOfRetryAfterUncertainCommitKeepsClaimAndExactReplay() async throws {
        let fixture = try Fixture()
        let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure, SyncNodeEnrollmentCommitError.audienceMismatch, AccountRuntimeError.untrustedResponse, nil])
        let activation = RecordingSyncNodeActivator()
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: activation)

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)

        await coordinator.retryCommit(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain, "a 422 after an uncertain attempt must stay recoverable")
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        XCTAssertTrue(coordinator.retainsCommittedAdmission)
        await coordinator.rejectMatchingString()
        await coordinator.cancel()
        coordinator.reset()
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)

        await coordinator.retryCommit(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain, "any definite rejection after an uncertain attempt must stay recoverable")
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        let cancelledBeforeInstall = await remote.cancelled()
        XCTAssertEqual(cancelledBeforeInstall, [])

        await coordinator.retryCommit(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let requests = await remote.requests
        let cancelled = await remote.cancelled()
        let activations = await activation.snapshot().count
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
        XCTAssertEqual(Set(requests.map(\.admissionApprovalSignature)).count, 1)
        XCTAssertEqual(requests.map(\.expectedCentralAudience), Array(repeating: "central.test", count: 4))
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(activations, 1)
    }

    // An undecodable 2xx is still a 2xx: a later definite rejection moves to
    // the sticky post-commit state and never cancels the claim.
    func testRejectionAfterUndecodableSuccessIsStickyPostCommitFailure() async throws {
        let fixture = try Fixture()
        let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [SyncNodeEnrollmentCommitError.undecodableSuccess, AccountRuntimeError.untrustedResponse, nil])
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)

        await coordinator.retryCommit(now: fixture.now)

        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.responseVerification))
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        let cancelledAfterRejection = await remote.cancelled()
        XCTAssertEqual(cancelledAfterRejection, [])

        await coordinator.retryCommitVerification(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let requests = await remote.requests
        let cancelled = await remote.cancelled()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
        XCTAssertEqual(cancelled, [])
    }

    // The client checks for cancellation after the request was sent, so a
    // CancellationError from commit may follow a committed admission.
    func testCancellationErrorFromCommitIsUncertainAndKeepsTheClaim() async throws {
        let fixture = try Fixture()
        let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [CancellationError(), nil])
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)

        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        let cancelledAfterCancellation = await remote.cancelled()
        XCTAssertEqual(cancelledAfterCancellation, [])

        await coordinator.retryCommit(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let requests = await remote.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
    }

    // MARK: Fix round 1: session credentials, retry fences and Stop and Start Over

    // Access tokens live 15 minutes. Every commit and replay reads the current
    // session credentials instead of the ones captured when the model was built.
    func testRetryAfterSessionTokenRotationUsesCurrentCredentials() async throws {
        let fixture = try Fixture()
        let session = SessionCredentialsBox(fixture.credentials)
        let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure, nil])
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), credentialsProvider: session.provider)

        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)

        session.value = try fixture.credentials(accessToken: "rotated-access-token")
        await coordinator.retryCommit(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let tokens = await remote.accessTokens
        let requests = await remote.requests
        XCTAssertEqual(tokens, ["access-token", "rotated-access-token"])
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
    }

    // A session that now belongs to another account or device must never be
    // used for the retained request, and the admission must stay recoverable.
    func testSessionOwnerChangeDuringRetryKeepsTheAdmissionAndSendsNothing() async throws {
        let fixture = try Fixture()
        let otherDevice = try AccountSessionCredentials(accountID: fixture.credentials.accountID, deviceID: AccountDeviceID("90000000-0000-4000-8000-0000000000aa"), accessToken: "other-device", accessExpiresAt: fixture.now.addingTimeInterval(300), refreshCredential: Data(repeating: 7, count: 32), offlineLease: "offline-lease")
        let otherAccount = try AccountSessionCredentials(accountID: PlainpostAccountID("91000000-0000-4000-8000-000000000001"), deviceID: fixture.credentials.deviceID, accessToken: "other-account", accessExpiresAt: fixture.now.addingTimeInterval(300), refreshCredential: Data(repeating: 7, count: 32), offlineLease: "offline-lease")
        for foreign in [otherDevice, otherAccount] {
            // Each pass installs into fresh trust.
            let fixture = try Fixture()
            let session = SessionCredentialsBox(fixture.credentials)
            let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure, nil])
            let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), credentialsProvider: session.provider)
            await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
            await coordinator.approvePinnedTarget(now: fixture.now)
            XCTAssertEqual(coordinator.state, .commitResponseUncertain)

            session.value = foreign
            await coordinator.retryCommit(now: fixture.now)
            XCTAssertEqual(coordinator.state, .commitResponseUncertain)
            XCTAssertTrue(coordinator.hasPendingCommitReplay)
            session.failure = AccountRuntimeError.secretUnavailable
            await coordinator.retryCommit(now: fixture.now)
            XCTAssertEqual(coordinator.state, .commitResponseUncertain)
            let requestsWhileForeign = await remote.requests.count
            let cancelledWhileForeign = await remote.cancelled()
            XCTAssertEqual(requestsWhileForeign, 1)
            XCTAssertEqual(cancelledWhileForeign, [])

            session.failure = nil
            session.value = fixture.credentials
            await coordinator.retryCommit(now: fixture.now)
            guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
            let requests = await remote.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
        }

        // After a 2xx the same fence keeps Retry Verification sticky.
        let session = SessionCredentialsBox(fixture.credentials)
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), responseVerifier: AudienceMismatchThenAcceptVerifier(failures: 1), credentialsProvider: session.provider)
        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.audienceMismatch))
        session.value = otherDevice
        await coordinator.retryCommitVerification(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.sessionUnavailable))
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        let requestsWhileForeign = await remote.requests().count
        XCTAssertEqual(requestsWhileForeign, 1)
        session.value = fixture.credentials
        await coordinator.retryCommitVerification(now: fixture.now)
        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let cancelled = (await remote.snapshot()).cancelledClaimIDs
        XCTAssertEqual(cancelled, [])
    }

    // The Node rejected the V3 replay after an uncertain first attempt. The
    // admission is still committed: nothing is cancelled and Retry
    // Verification activates again from the exact retained request.
    func testActivationRejectedAfterUncertainActivationIsStickyAndRetryVerificationInstalls() async throws {
        let fixture = try Fixture()
        let remote = SyncNodeRemoteFixture(fixture: fixture)
        let activation = ScriptedSyncNodeActivator(activations: [NodeActivationError.uncertain, nil], retries: [NodeActivationError.rejected])
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: activation)
        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(coordinator.state, .activationResponseUncertain)

        await coordinator.retryActivation()

        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.activationRejected))
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        XCTAssertTrue(coordinator.retainsCommittedAdmission)
        await coordinator.cancel()
        coordinator.reset()
        await coordinator.viewDidDisappear()
        coordinator.invalidatePresentationOwnership()
        XCTAssertEqual(coordinator.state, .commitVerificationFailed(.activationRejected))
        let cancelledBeforeRetry = (await remote.snapshot()).cancelledClaimIDs
        XCTAssertEqual(cancelledBeforeRetry, [])

        await coordinator.retryCommitVerification(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let requests = await remote.requests()
        let cancelled = (await remote.snapshot()).cancelledClaimIDs
        let counts = await activation.counts()
        let acceptances = await fixture.trust.acceptanceCount()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(counts.activations, 2)
        XCTAssertEqual(counts.retries, 1)
        XCTAssertEqual(acceptances, 1)
        XCTAssertFalse(coordinator.hasPendingCommitReplay)
    }

    // Once the Node accepted V3, a local trust-acceptance failure is retried
    // without contacting the Node again, whether activation finished on the
    // first attempt or on Retry Activation.
    func testTrustAcceptanceFailureRetryVerificationSkipsCompletedActivation() async throws {
        let fixture = try Fixture()
        for activationRetried in [false, true] {
            let fixture = try Fixture()
            let remote = SyncNodeRemoteFixture(fixture: fixture)
            let trust = FailingAcceptanceTrust(base: FixtureSyncNodeTrust(current: fixture.trustCommit), failures: 1)
            let activation = ScriptedSyncNodeActivator(activations: activationRetried ? [NodeActivationError.uncertain] : [nil], retries: [nil])
            let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: activation, trust: trust)
            await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
            await coordinator.approvePinnedTarget(now: fixture.now)
            if activationRetried {
                XCTAssertEqual(coordinator.state, .activationResponseUncertain)
                await coordinator.retryActivation()
            }

            XCTAssertEqual(coordinator.state, .commitVerificationFailed(.trustAcceptance))
            XCTAssertTrue(coordinator.hasPendingCommitReplay)
            let cancelledBeforeRetry = (await remote.snapshot()).cancelledClaimIDs
            XCTAssertEqual(cancelledBeforeRetry, [])

            await coordinator.retryCommitVerification(now: fixture.now)

            guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
            let requests = await remote.requests()
            let cancelled = (await remote.snapshot()).cancelledClaimIDs
            let counts = await activation.counts()
            let acceptances = await trust.successfulAcceptances()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
            XCTAssertEqual(cancelled, [])
            XCTAssertEqual(counts.activations, 1, "activation must be skipped once the Node accepted")
            XCTAssertEqual(counts.retries, activationRetried ? 1 : 0)
            XCTAssertEqual(acceptances, 1)
        }
    }

    func testActivationFailureLabelsDistinguishNodeRejectionFromOtherErrors() async throws {
        let fixture = try Fixture()
        let first = ScriptedSyncNodeActivator(activations: [CancellationError()], retries: [])
        let firstCoordinator = fixture.provisionedCoordinator(remote: SyncNodeRemoteFixture(fixture: fixture), presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: first)
        await firstCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await firstCoordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(firstCoordinator.state, .commitVerificationFailed(.activationFailed))

        let rejected = ScriptedSyncNodeActivator(activations: [NodeActivationError.rejected], retries: [])
        let rejectedCoordinator = fixture.provisionedCoordinator(remote: SyncNodeRemoteFixture(fixture: fixture), presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: rejected)
        await rejectedCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await rejectedCoordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(rejectedCoordinator.state, .commitVerificationFailed(.activationRejected))

        let nothingPending = ScriptedSyncNodeActivator(activations: [NodeActivationError.uncertain], retries: [AccountRuntimeError.untrustedResponse])
        let pendingCoordinator = fixture.provisionedCoordinator(remote: SyncNodeRemoteFixture(fixture: fixture), presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: nothingPending)
        await pendingCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await pendingCoordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(pendingCoordinator.state, .activationResponseUncertain)
        await pendingCoordinator.retryActivation()
        XCTAssertEqual(pendingCoordinator.state, .commitVerificationFailed(.activationFailed))
    }

    // Starting a new attempt must never wipe the only replay of a request
    // Central may have committed.
    func testStartWhileAdmissionIsRetainedLeavesReplayUntouched() async throws {
        let fixture = try Fixture()
        let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure, nil])
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)

        coordinator.start(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        coordinator.start(setupCode: fixture.setupCode, proof: fixture.proof, expectedOrigin: fixture.expectedOrigin, centralAudience: fixture.centralAudience, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.hasPendingCommitReplay)
        XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)

        await coordinator.retryCommit(now: fixture.now)

        guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
        let requests = await remote.requests
        let cancelled = await remote.cancelled()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
        XCTAssertEqual(cancelled, [])
    }

    // A second tap while the first retry is still being scheduled is a no-op.
    func testDoubleRetryTapSendsTheRetainedRequestOnce() async throws {
        let fixture = try Fixture()
        for verification in [false, true] {
            let fixture = try Fixture()
            let remote = ScriptedCommitRemote(fixture: fixture, outcomes: verification ? [] : [AccountRuntimeError.transportFailure, AccountRuntimeError.transportFailure, AccountRuntimeError.transportFailure])
            let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), responseVerifier: AudienceMismatchThenAcceptVerifier(failures: verification ? 1 : 0))
            await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
            await coordinator.approvePinnedTarget(now: fixture.now)
            XCTAssertTrue(coordinator.retainsCommittedAdmission)

            let first = Task { @MainActor in
                if verification { await coordinator.retryCommitVerification(now: fixture.now) } else { await coordinator.retryCommit(now: fixture.now) }
            }
            let second = Task { @MainActor () -> SyncNodeEnrollmentCoordinator.State in
                // The first tap has only scheduled its send; it must already
                // own the retry.
                let seen = coordinator.state
                if verification { await coordinator.retryCommitVerification(now: fixture.now) } else { await coordinator.retryCommit(now: fixture.now) }
                return seen
            }
            await first.value
            let seenBySecondTap = await second.value
            XCTAssertEqual(seenBySecondTap, .committing)

            let requests = await remote.requests
            XCTAssertEqual(requests.count, 2, "one original commit and one retry (verification: \(verification))")
            if verification {
                guard case .installed = coordinator.state else { return XCTFail("expected installed, got \(coordinator.state)") }
            } else {
                XCTAssertEqual(coordinator.state, .commitResponseUncertain)
            }
        }
    }

    // A 204 from the public claim cancel proves Central never consumed the
    // claim, so only then may the uncertain request be released.
    func testStopAndStartOverReleasesReplayOnlyAfterProvenCancellation() async throws {
        let fixture = try Fixture()
        let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure])
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        XCTAssertTrue(coordinator.canStopAndStartOver)

        let outcome = await coordinator.stopAndStartOver()

        XCTAssertEqual(outcome, .startedOver)
        XCTAssertEqual(coordinator.state, .enterCode)
        XCTAssertFalse(coordinator.hasPendingCommitReplay)
        XCTAssertFalse(coordinator.retainsSetupVerifierMaterial)
        XCTAssertFalse(coordinator.retainsCommittedAdmission)
        XCTAssertFalse(coordinator.canStopAndStartOver)
        let cancelled = await remote.cancelled()
        let attempts = await remote.cancelAttempts
        XCTAssertEqual(cancelled, [fixture.claim.claimID])
        XCTAssertEqual(attempts, 1)
        await coordinator.retryCommit(now: fixture.now)
        let requests = await remote.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testStopAndStartOverKeepsEverythingWhenCancellationIsNotProven() async throws {
        let fixture = try Fixture()
        // 409/404 reach Swift as untrustedResponse (or transportFailure for a
        // problem body), 5xx and transport loss as transportFailure.
        for failure in [AccountRuntimeError.untrustedResponse, AccountRuntimeError.transportFailure, CancellationError()] as [Error] {
            let fixture = try Fixture()
            let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure, nil], cancelOutcomes: [failure])
            let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
            await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
            await coordinator.approvePinnedTarget(now: fixture.now)

            let outcome = await coordinator.stopAndStartOver()

            XCTAssertEqual(outcome, .admissionRetained, "\(failure)")
            XCTAssertEqual(coordinator.state, .commitResponseUncertain)
            XCTAssertTrue(coordinator.hasPendingCommitReplay)
            XCTAssertTrue(coordinator.retainsSetupVerifierMaterial)
            XCTAssertTrue(coordinator.canStopAndStartOver)
            await coordinator.retryCommit(now: fixture.now)
            guard case .installed = coordinator.state else { return XCTFail("expected installed after \(failure), got \(coordinator.state)") }
            let requests = await remote.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1)
            let cancelled = await remote.cancelled()
            XCTAssertEqual(cancelled, [])
        }
    }

    func testStopAndStartOverIsNeverOfferedOnceACommitWasSeenOrOutsideUncertainCommit() async throws {
        let fixture = try Fixture()
        let observed = ScriptedCommitRemote(fixture: fixture, outcomes: [SyncNodeEnrollmentCommitError.undecodableSuccess])
        let observedCoordinator = fixture.provisionedCoordinator(remote: observed, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await observedCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await observedCoordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(observedCoordinator.state, .commitResponseUncertain)
        XCTAssertFalse(observedCoordinator.canStopAndStartOver)
        let observedOutcome = await observedCoordinator.stopAndStartOver()
        XCTAssertEqual(observedOutcome, .unavailable)
        XCTAssertEqual(observedCoordinator.state, .commitResponseUncertain)
        XCTAssertTrue(observedCoordinator.hasPendingCommitReplay)
        let observedAttempts = await observed.cancelAttempts
        XCTAssertEqual(observedAttempts, 0)

        let verification = SyncNodeRemoteFixture(fixture: fixture)
        let verificationCoordinator = fixture.provisionedCoordinator(remote: verification, presenter: CountingProvisionedPresenter(presentation: fixture.presentation), responseVerifier: AudienceMismatchThenAcceptVerifier(failures: 1))
        await verificationCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await verificationCoordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertFalse(verificationCoordinator.canStopAndStartOver)
        let verificationOutcome = await verificationCoordinator.stopAndStartOver()
        XCTAssertEqual(verificationOutcome, .unavailable)
        XCTAssertEqual(verificationCoordinator.state, .commitVerificationFailed(.audienceMismatch))

        let activation = fixture.provisionedCoordinator(remote: SyncNodeRemoteFixture(fixture: fixture), presenter: CountingProvisionedPresenter(presentation: fixture.presentation), activation: UncertainSyncNodeActivator())
        await activation.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await activation.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(activation.state, .activationResponseUncertain)
        XCTAssertFalse(activation.canStopAndStartOver)
        let activationOutcome = await activation.stopAndStartOver()
        XCTAssertEqual(activationOutcome, .unavailable)
        XCTAssertEqual(activation.state, .activationResponseUncertain)

        let cancelled = (await verification.snapshot()).cancelledClaimIDs
        XCTAssertEqual(cancelled, [])
    }

    // While the cancel is in flight a second tap and Retry Installation are
    // no-ops, so no replay can race the proof.
    func testStopAndStartOverIgnoresRepeatTapsAndRetriesWhileCancelling() async throws {
        let fixture = try Fixture()
        let remote = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure], blocksCancel: true)
        let coordinator = fixture.provisionedCoordinator(remote: remote, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await coordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await coordinator.approvePinnedTarget(now: fixture.now)

        let first = Task { @MainActor in await coordinator.stopAndStartOver() }
        await remote.waitUntilCancelStarts()
        let second = await coordinator.stopAndStartOver()
        await coordinator.retryCommit(now: fixture.now)
        XCTAssertEqual(second, .unavailable)
        XCTAssertEqual(coordinator.state, .commitResponseUncertain)
        let requestsWhileCancelling = await remote.requests.count
        XCTAssertEqual(requestsWhileCancelling, 1)

        await remote.releaseCancel()
        let outcome = await first.value
        XCTAssertEqual(outcome, .startedOver)
        XCTAssertEqual(coordinator.state, .enterCode)
        let attempts = await remote.cancelAttempts
        XCTAssertEqual(attempts, 1)
    }

    // The Node keeps presenting a pending claim until it expires, and Central
    // never looks up a cancelled claim. After a proven cancel the coordinator
    // records that expiry so Connect can wait for a fresh claim.
    func testProvenClaimCancellationRecordsWhenTheNodeCanPresentAFreshClaim() async throws {
        let fixture = try Fixture()
        let expiry = fixture.presentation.expiresAt

        let stopped = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure])
        let stoppedCoordinator = fixture.provisionedCoordinator(remote: stopped, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        XCTAssertNil(stoppedCoordinator.reconnectAvailableAt)
        await stoppedCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await stoppedCoordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertNil(stoppedCoordinator.reconnectAvailableAt, "nothing was cancelled yet")
        let stoppedOutcome = await stoppedCoordinator.stopAndStartOver()
        XCTAssertEqual(stoppedOutcome, .startedOver)
        XCTAssertEqual(stoppedCoordinator.reconnectAvailableAt, expiry)

        let refused = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.transportFailure], cancelOutcomes: [AccountRuntimeError.transportFailure])
        let refusedCoordinator = fixture.provisionedCoordinator(remote: refused, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await refusedCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await refusedCoordinator.approvePinnedTarget(now: fixture.now)
        let refusedOutcome = await refusedCoordinator.stopAndStartOver()
        XCTAssertEqual(refusedOutcome, .admissionRetained)
        XCTAssertNil(refusedCoordinator.reconnectAvailableAt, "an unproven cancel leaves the claim live")

        // The matching screen's Cancel cancels the same claim.
        let rejected = ScriptedCommitRemote(fixture: fixture, outcomes: [])
        let rejectedCoordinator = fixture.provisionedCoordinator(remote: rejected, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await rejectedCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        guard case .matchingStringConfirmation = rejectedCoordinator.state else { return XCTFail("expected approval") }
        await rejectedCoordinator.rejectMatchingString()
        XCTAssertEqual(rejectedCoordinator.state, .enterCode)
        XCTAssertEqual(rejectedCoordinator.reconnectAvailableAt, expiry)

        let rejectRefused = ScriptedCommitRemote(fixture: fixture, outcomes: [], cancelOutcomes: [AccountRuntimeError.transportFailure])
        let rejectRefusedCoordinator = fixture.provisionedCoordinator(remote: rejectRefused, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await rejectRefusedCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await rejectRefusedCoordinator.rejectMatchingString()
        XCTAssertEqual(rejectRefusedCoordinator.state, .enterCode)
        XCTAssertNil(rejectRefusedCoordinator.reconnectAvailableAt)

        // A cancel on disappearance, or a pre-commit failure, cancels it too.
        let cancelled = ScriptedCommitRemote(fixture: fixture, outcomes: [])
        let cancelledCoordinator = fixture.provisionedCoordinator(remote: cancelled, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await cancelledCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await cancelledCoordinator.viewDidDisappear()
        XCTAssertEqual(cancelledCoordinator.reconnectAvailableAt, expiry)

        let failed = ScriptedCommitRemote(fixture: fixture, outcomes: [AccountRuntimeError.untrustedResponse])
        let failedCoordinator = fixture.provisionedCoordinator(remote: failed, presenter: CountingProvisionedPresenter(presentation: fixture.presentation))
        await failedCoordinator.begin(profile: fixture.profile, appleAuthorization: fixture.appleAuthorization, now: fixture.now)
        await failedCoordinator.approvePinnedTarget(now: fixture.now)
        XCTAssertEqual(failedCoordinator.state, .failed)
        XCTAssertEqual(failedCoordinator.reconnectAvailableAt, expiry)
        failedCoordinator.reset()
        XCTAssertEqual(failedCoordinator.reconnectAvailableAt, expiry, "reset must not forget a cancelled claim")
    }
}

private struct Fixture {
    let now = Date(timeIntervalSince1970: 1_786_260_000)
    let setupCode = NodeSessionWire.encodeBase64URL(Data(repeating: 1, count: 32))
    let expectedOrigin = try! NodeEndpointURL("https://node.tail1234.ts.net:18443")
    let centralAudience = "central.test"
    let trustCommit: AccountTrustStateCommit
    let trust: FixtureSyncNodeTrust
    let credentials: AccountSessionCredentials
    let identity: AccountDeviceIdentity
    let claim: AccountNodeEnrollmentPublicClaimV1
    let proof: SyncNodeEnrollmentNodeProof
    let appleAuthorization: SyncNodeEnrollmentAppleAuthorization
    let profile: SyncNodeBootstrapProfile
    let presentation: SyncNodeEnrollmentPresentation

    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let genesis = try XCTUnwrap(((root["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any])
        let decodedCommit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(genesis["genesisCommit"])))
        let accountID = decodedCommit.state.accountID
        let deviceID = decodedCommit.state.members[0].deviceID
        let generatedIdentity = try AccountDeviceIdentity.generate()
        let trustedMember = try AccountDeviceTrustRecord(
            accountID: accountID,
            epoch: decodedCommit.state.epoch,
            revision: decodedCommit.state.revision,
            deviceID: deviceID,
            platform: decodedCommit.state.members[0].platform,
            publicBundle: generatedIdentity.publicBundle,
            signerDeviceID: deviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let trustedState = try AccountTrustState(
            accountID: accountID,
            epoch: decodedCommit.state.epoch,
            revision: decodedCommit.state.revision,
            previousCommitDigest: decodedCommit.state.previousCommitDigest,
            transition: decodedCommit.state.transition,
            keyGeneration: decodedCommit.state.keyGeneration,
            keyCommitment: decodedCommit.state.keyCommitment,
            members: [trustedMember],
            signerDeviceID: deviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let templatePackage = try XCTUnwrap(decodedCommit.keyPackages.first)
        let trustedStateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(trustedState)))
        let trustedPackage = try AccountGroupKeyPackage(
            accountID: accountID,
            epoch: trustedState.epoch,
            stateRevision: trustedState.revision,
            keyGeneration: trustedState.keyGeneration,
            stateDigest: trustedStateDigest,
            keyCommitment: trustedState.keyCommitment,
            recipientDeviceID: deviceID,
            senderDeviceID: deviceID,
            senderEphemeralPublicKey: templatePackage.senderEphemeralPublicKey,
            nonce: templatePackage.nonce,
            encryptedKeyMaterial: templatePackage.encryptedKeyMaterial,
            signature: Data(repeating: 1, count: 64)
        )
        trustCommit = try AccountTrustStateCommit(state: trustedState, keyPackages: [trustedPackage])
        trust = FixtureSyncNodeTrust(current: trustCommit)
        credentials = try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "access-token", accessExpiresAt: now.addingTimeInterval(300), refreshCredential: Data(repeating: 7, count: 32), offlineLease: "offline-lease")
        identity = generatedIdentity
        let signing = P256.Signing.PrivateKey().publicKey.x963Representation
        let agreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        claim = try AccountNodeEnrollmentPublicClaimV1(claimID: NodeEnrollmentClaimID("90000000-0000-4000-8000-000000000001"), nodeDeviceID: AccountDeviceID("90000000-0000-4000-8000-000000000002"), signingPublicKey: signing, agreementPublicKey: agreement, noiseStaticPublicKey: Data(repeating: 9, count: 32), endpointDigest: Data(repeating: 4, count: 32), createdAt: "2026-08-14T11:59:00Z", expiresAt: "2026-08-14T12:04:00Z")
        proof = try SyncNodeEnrollmentNodeProof(claimProofSignature: Data(repeating: 2, count: 64))
        appleAuthorization = try SyncNodeEnrollmentAppleAuthorization(identityToken: "a.b.c", nonce: Data(repeating: 5, count: 32))
        profile = try SyncNodeBootstrapProfile(canonicalOrigin: expectedOrigin, nodeDeviceID: claim.nodeDeviceID, signingKeyDigest: Data(SHA256.hash(data: claim.signingPublicKey)), capabilityID: Data(repeating: 7, count: 16), capability: Data(repeating: 8, count: 32), centralAudience: "central.test")
        presentation = try SyncNodeEnrollmentPresentation(setupCode: setupCode, expiresAt: try XCTUnwrap(AccountWireCodec.parseTimestamp(claim.expiresAt)), claimProofSignature: proof.claimProofSignature, claimFingerprint: "123456")
    }

    @MainActor func coordinator(remote: any SyncNodeEnrollmentRemote, activeNodeID: AccountDeviceID?, localAuthenticator: any SyncNodeEnrollmentLocalAuthenticating = PassingLocalAuthenticator(), activation: any SyncNodeEnrollmentActivating = RecordingSyncNodeActivator(), responseVerifier: any SyncNodeEnrollmentResponseVerifying = AcceptingResponseVerifier(), responseValidationClock: @escaping @Sendable () -> Date = Date.init) throws -> SyncNodeEnrollmentCoordinator {
        let selectedTrust: FixtureSyncNodeTrust
        if let activeNodeID {
            selectedTrust = FixtureSyncNodeTrust(current: try trustCommitWithActiveNode(activeNodeID))
        } else {
            selectedTrust = trust
        }
        return SyncNodeEnrollmentCoordinator(remote: remote, localAuthenticator: localAuthenticator, responseVerifier: responseVerifier, trust: selectedTrust, activation: activation, credentials: credentials, credentialsProvider: { [credentials] in credentials }, device: identity, activeNodeID: activeNodeID, random: { _ in Data(repeating: 8, count: 32) }, responseValidationClock: responseValidationClock)
    }

    @MainActor func provisionedCoordinator(remote: any SyncNodeEnrollmentRemote, presenter: CountingProvisionedPresenter, responseVerifier: any SyncNodeEnrollmentResponseVerifying = AcceptingResponseVerifier(), activation: any SyncNodeEnrollmentActivating = RecordingSyncNodeActivator(), trust: (any SyncNodeEnrollmentTrustCoordinating)? = nil, credentialsProvider: SyncNodeEnrollmentCredentialsProvider? = nil) -> SyncNodeEnrollmentCoordinator {
        SyncNodeEnrollmentCoordinator(remote: remote, presenter: presenter, bootstrapVerifier: OrderedBootstrapVerifier(origin: expectedOrigin, events: EnrollmentOrderRecorder()), localAuthenticator: PassingLocalAuthenticator(), responseVerifier: responseVerifier, trust: trust ?? self.trust, activation: activation, credentials: credentials, credentialsProvider: credentialsProvider ?? { [credentials] in credentials }, device: identity, activeNodeID: nil, random: { _ in Data(repeating: 8, count: 32) })
    }

    func credentials(accessToken: String) throws -> AccountSessionCredentials {
        try AccountSessionCredentials(accountID: credentials.accountID, deviceID: credentials.deviceID, accessToken: accessToken, accessExpiresAt: now.addingTimeInterval(900), refreshCredential: credentials.refreshCredential, offlineLease: credentials.offlineLease)
    }

    private func trustCommitWithActiveNode(_ activeNodeID: AccountDeviceID) throws -> AccountTrustStateCommit {
        let revision = try PositiveUInt64(trustCommit.state.revision.value + 1)
        let nodeBundle = try AccountPublicKeyBundle(
            signingKey: P256.Signing.PrivateKey().publicKey.x963Representation,
            agreementKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        )
        let activeNode = try AccountDeviceTrustRecord(
            accountID: trustCommit.state.accountID,
            epoch: trustCommit.state.epoch,
            revision: revision,
            deviceID: activeNodeID,
            platform: .syncNode,
            publicBundle: nodeBundle,
            signerDeviceID: credentials.deviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let state = try AccountTrustState(
            accountID: trustCommit.state.accountID,
            epoch: trustCommit.state.epoch,
            revision: revision,
            previousCommitDigest: AccountTranscript.trustCommitDigest(trustCommit),
            transition: try AccountTrustTransition(
                kind: .admission,
                targetDeviceIDs: [activeNodeID],
                priorRecordDigests: [],
                handshakeDigest: Data(repeating: 3, count: 32),
                pendingDeviceDigest: Data(repeating: 4, count: 32)
            ),
            keyGeneration: trustCommit.state.keyGeneration,
            keyCommitment: trustCommit.state.keyCommitment,
            members: trustCommit.state.members + [activeNode],
            signerDeviceID: credentials.deviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let template = try XCTUnwrap(trustCommit.keyPackages.first)
        let packages = try state.members.map { member in
            try AccountGroupKeyPackage(
                accountID: state.accountID,
                epoch: state.epoch,
                stateRevision: state.revision,
                keyGeneration: state.keyGeneration,
                stateDigest: stateDigest,
                keyCommitment: state.keyCommitment,
                recipientDeviceID: member.deviceID,
                senderDeviceID: state.signerDeviceID,
                senderEphemeralPublicKey: template.senderEphemeralPublicKey,
                nonce: template.nonce,
                encryptedKeyMaterial: template.encryptedKeyMaterial,
                signature: Data(repeating: 1, count: 64)
            )
        }
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }
}

private func syncNodeFixtureV2Response() throws -> SyncNodeEnrollmentAdmissionResponse {
    try SyncNodeEnrollmentAdmissionResponse(v2: AccountWireCodec.decodeNodeEnrollmentAdmissionResponseV2(SyncNodeAdmissionWireTests.v2ResponseWire()))
}

private struct PassingLocalAuthenticator: SyncNodeEnrollmentLocalAuthenticating { func authenticateSyncNodeEnrollment() async throws {} }
private struct FailingLocalAuthenticator: SyncNodeEnrollmentLocalAuthenticating { func authenticateSyncNodeEnrollment() async throws { throw AccountRuntimeError.cancelled } }
private struct AcceptingResponseVerifier: SyncNodeEnrollmentResponseVerifying { func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {} }

private final class ReceiptClockResponseVerifier: SyncNodeEnrollmentResponseVerifying, @unchecked Sendable {
    private let expected: Date
    private let lock = NSLock()
    private var verified = false

    init(expected: Date) { self.expected = expected }

    var didVerifyExpectedTime: Bool { lock.withLock { verified } }

    func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {
        guard now == expected else { throw AccountRuntimeError.untrustedResponse }
        lock.withLock { verified = true }
    }
}

private actor RecordingSyncNodeActivator: SyncNodeEnrollmentActivating {
    struct Capture: Sendable { let response: AccountNodeEnrollmentAdmissionResponseV2; let request: SyncNodeEnrollmentAdmissionRequest }
    private var captures: [Capture] = []
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws { captures.append(Capture(response: response, request: request)) }
    func retryUncertainActivation() async throws { XCTFail("unexpected activation retry") }
    func cancelPendingActivation() async { }
    func snapshot() -> [Capture] { captures }
}

private actor UncertainSyncNodeActivator: SyncNodeEnrollmentActivating {
    private var count = 0, cancelled = 0
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws { count += 1; throw NodeActivationError.uncertain }
    func retryUncertainActivation() async throws { count += 1 }
    func cancelPendingActivation() async { cancelled += 1 }
    func attempts() -> Int { count }
    func cancellations() -> Int { cancelled }
}

private actor BlockingSyncNodeActivator: SyncNodeEnrollmentActivating {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {
        started = true
        startedWaiters.forEach { $0.resume() }; startedWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func retryUncertainActivation() async throws { XCTFail("unexpected activation retry") }
    func cancelPendingActivation() async { }
    func waitUntilStarted() async { if started { return }; await withCheckedContinuation { startedWaiters.append($0) } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class AudienceMismatchThenAcceptVerifier: SyncNodeEnrollmentResponseVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var seen: [(audience: String, idempotencyKey: Data)] = []
    init(failures: Int) { remainingFailures = failures }
    func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {
        let fail = lock.withLock { () -> Bool in
            seen.append((centralAudience, request.idempotencyKey))
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if fail { throw SyncNodeEnrollmentVerificationError.audienceMismatch }
    }
    func calls() -> [(audience: String, idempotencyKey: Data)] { lock.withLock { seen } }
}

private struct ClosedLeaseWindowVerifier: SyncNodeEnrollmentResponseVerifying {
    func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {}
    func canVerifyNodeEnrollmentLease(at now: Date) -> Bool { false }
}

private actor CommitFailingRemote: SyncNodeEnrollmentRemote {
    private let base: SyncNodeRemoteFixture
    private let error: Error
    private(set) var requests: [SyncNodeEnrollmentAdmissionRequest] = []
    init(fixture: Fixture, error: Error) { base = SyncNodeRemoteFixture(fixture: fixture); self.error = error }
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { try await base.lookupSyncNodeClaim(setupCode: setupCode) }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws { try await base.cancelSyncNodeClaim(claimID: claimID, setupCode: setupCode) }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { try await base.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: authorization, credentials: credentials, device: device, trustCommit: trustCommit, now: now) }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse { requests.append(request); throw error }
    func cancelled() async -> [NodeEnrollmentClaimID] { (await base.snapshot()).cancelledClaimIDs }
}

/// Answers each commit with the next scripted outcome; `nil` returns the
/// shared V2 admission vector.
private actor ScriptedCommitRemote: SyncNodeEnrollmentRemote {
    private let base: SyncNodeRemoteFixture
    private var outcomes: [Error?]
    private var cancelOutcomes: [Error?]
    private let blocksCancel: Bool
    private var cancelStarted = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [SyncNodeEnrollmentAdmissionRequest] = []
    private(set) var accessTokens: [String] = []
    private(set) var cancelAttempts = 0
    /// `cancelOutcomes` scripts the public claim cancel: an error models any
    /// answer other than 204; `nil` or an exhausted script is a 204.
    init(fixture: Fixture, outcomes: [Error?], cancelOutcomes: [Error?] = [], blocksCancel: Bool = false) { base = SyncNodeRemoteFixture(fixture: fixture); self.outcomes = outcomes; self.cancelOutcomes = cancelOutcomes; self.blocksCancel = blocksCancel }
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { try await base.lookupSyncNodeClaim(setupCode: setupCode) }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        cancelAttempts += 1
        if blocksCancel {
            cancelStarted = true
            cancelWaiters.forEach { $0.resume() }; cancelWaiters.removeAll()
            await withCheckedContinuation { cancelContinuation = $0 }
        }
        if !cancelOutcomes.isEmpty, let failure = cancelOutcomes.removeFirst() { throw failure }
        try await base.cancelSyncNodeClaim(claimID: claimID, setupCode: setupCode)
    }
    func waitUntilCancelStarts() async { if cancelStarted { return }; await withCheckedContinuation { cancelWaiters.append($0) } }
    func releaseCancel() { cancelContinuation?.resume(); cancelContinuation = nil }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { try await base.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: authorization, credentials: credentials, device: device, trustCommit: trustCommit, now: now) }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        requests.append(request)
        accessTokens.append(credentials.accessToken)
        let outcome = outcomes.isEmpty ? nil : outcomes.removeFirst()
        if let outcome { throw outcome }
        return try syncNodeFixtureV2Response()
    }
    func cancelled() async -> [NodeEnrollmentClaimID] { (await base.snapshot()).cancelledClaimIDs }
}

private actor V1OnlySyncNodeRemote: SyncNodeEnrollmentRemote {
    private let fixture: Fixture
    private let base: SyncNodeRemoteFixture
    init(fixture: Fixture) { self.fixture = fixture; base = SyncNodeRemoteFixture(fixture: fixture) }
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { try await base.lookupSyncNodeClaim(setupCode: setupCode) }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws { try await base.cancelSyncNodeClaim(claimID: claimID, setupCode: setupCode) }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { try await base.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: authorization, credentials: credentials, device: device, trustCommit: trustCommit, now: now) }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        let binding = try AccountNodeOperationBindingV1(accountID: credentials.accountID, trustEpoch: request.evidence.trustEpoch, claimID: request.evidence.claimID, nodeDeviceID: request.evidence.nodeDeviceID, centralAudience: "central.test", action: request.evidence.action, replacedNodeID: request.evidence.replacedNodeID, replacementRevocationDigest: request.evidence.action == .replace ? Data(repeating: 1, count: 32) : nil, admissionEvidenceDigest: Data(repeating: 2, count: 32), issuanceDigest: Data(repeating: 3, count: 32))
        let result = try AccountNodeEnrollmentResultV1(binding: binding, committedAt: "2026-08-14T12:01:00Z")
        let lease = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: "90000000-0000-4000-8000-000000000004", issuedAt: "2026-08-14T12:01:00Z", expiresAt: "2026-08-14T12:02:00Z", serverKeyID: "test-key", signature: try fixture.identity.signature(for: Data("lease".utf8)))
        let refresh = try AccountNodeRefreshCredentialV1(binding: binding, credentialID: "90000000-0000-4000-8000-000000000005", issuedAt: "2026-08-14T12:01:00Z", expiresAt: "2026-08-14T12:02:00Z", credential: Data(repeating: 5, count: 32))
        return try SyncNodeEnrollmentAdmissionResponse(result: result, refreshCredential: refresh, offlineLease: lease)
    }
    func cancelled() async -> [NodeEnrollmentClaimID] { (await base.snapshot()).cancelledClaimIDs }
}

private actor V2SyncNodeRemoteFixture: SyncNodeEnrollmentRemote {
    private let base: SyncNodeRemoteFixture
    private let response: SyncNodeEnrollmentAdmissionResponse
    init(fixture: Fixture) {
        base = SyncNodeRemoteFixture(fixture: fixture)
        response = try! syncNodeFixtureV2Response()
    }
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { try await base.lookupSyncNodeClaim(setupCode: setupCode) }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws { try await base.cancelSyncNodeClaim(claimID: claimID, setupCode: setupCode) }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { try await base.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: authorization, credentials: credentials, device: device, trustCommit: trustCommit, now: now) }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse { response }
    func cancelledClaimIDs() async -> [NodeEnrollmentClaimID] { (await base.snapshot()).cancelledClaimIDs }
}

private actor FixtureSyncNodeTrust: SyncNodeEnrollmentTrustCoordinating {
    private var current: AccountTrustStateCommit
    init(current: AccountTrustStateCommit) { self.current = current }

    func currentTrustCommit() async throws -> AccountTrustStateCommit? { current }

    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit {
        let predecessor = current
        let revision = try PositiveUInt64(predecessor.state.revision.value + 1)
        let bundle = try AccountPublicKeyBundle(signingKey: evidence.signingPublicKey, agreementKey: evidence.agreementPublicKey)
        let transition: AccountTrustTransition
        let members: [AccountDeviceTrustRecord]
        switch evidence.action {
        case .enroll:
            transition = try AccountTrustTransition(kind: .admission, targetDeviceIDs: [evidence.nodeDeviceID], priorRecordDigests: [], handshakeDigest: evidence.matchingTranscriptDigest, pendingDeviceDigest: Data(repeating: 7, count: 32))
            members = predecessor.state.members + [try AccountDeviceTrustRecord(accountID: predecessor.state.accountID, epoch: predecessor.state.epoch, revision: revision, deviceID: evidence.nodeDeviceID, platform: .syncNode, publicBundle: bundle, signerDeviceID: evidence.approverDeviceID, signature: Data(repeating: 1, count: 64))]
        case .replace:
            guard let replacedNodeID = evidence.replacedNodeID,
                  let old = predecessor.state.members.first(where: { $0.deviceID == replacedNodeID })
            else { throw AccountRuntimeError.untrustedResponse }
            transition = try AccountTrustTransition(kind: .revocation, targetDeviceIDs: [replacedNodeID], priorRecordDigests: [try AccountPriorRecordDigest(deviceID: replacedNodeID, recordDigest: Data(SHA256.hash(data: AccountTranscript.signedTrustRecord(old))))])
            members = predecessor.state.members.filter { $0.deviceID != replacedNodeID } + [try AccountDeviceTrustRecord(accountID: predecessor.state.accountID, epoch: predecessor.state.epoch, revision: revision, deviceID: evidence.nodeDeviceID, platform: .syncNode, publicBundle: bundle, signerDeviceID: evidence.approverDeviceID, signature: Data(repeating: 1, count: 64))]
        }
        let state = try AccountTrustState(accountID: predecessor.state.accountID, epoch: predecessor.state.epoch, revision: revision, previousCommitDigest: AccountTranscript.trustCommitDigest(predecessor), transition: transition, keyGeneration: predecessor.state.keyGeneration, keyCommitment: predecessor.state.keyCommitment, members: members.sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }, signerDeviceID: evidence.approverDeviceID, signature: Data(repeating: 1, count: 64))
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let template = try XCTUnwrap(predecessor.keyPackages.first)
        let packages = try state.members.map { member in
            try AccountGroupKeyPackage(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: stateDigest, keyCommitment: state.keyCommitment, recipientDeviceID: member.deviceID, senderDeviceID: state.signerDeviceID, senderEphemeralPublicKey: template.senderEphemeralPublicKey, nonce: template.nonce, encryptedKeyMaterial: template.encryptedKeyMaterial, signature: Data(repeating: 1, count: 64))
        }
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }

    private var accepted = 0
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws { current = commit; accepted += 1 }
    func acceptanceCount() -> Int { accepted }
}

private actor SyncNodeRemoteFixture: SyncNodeEnrollmentRemote {
    enum Event: Equatable { case lookup, stepUp(AccountNodeEnrollmentAction), commit(AccountNodeEnrollmentAction) }
    private let fixture: Fixture
    private(set) var states: [Event] = []
    private(set) var cancelledClaimIDs: [NodeEnrollmentClaimID] = []
    private(set) var committedRequests: [SyncNodeEnrollmentAdmissionRequest] = []
    init(fixture: Fixture) { self.fixture = fixture }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { XCTAssertEqual(setupCode, fixture.setupCode); states.append(.lookup); return fixture.claim }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws { XCTAssertEqual(setupCode, fixture.setupCode); cancelledClaimIDs.append(claimID) }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        states.append(.stepUp(action))
        let target = action == .enroll ? claim.nodeDeviceID : replacedNodeID
        let signature = try fixture.identity.signature(for: Data("step-up".utf8))
        return try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("90000000-0000-4000-8000-000000000003"), accountID: credentials.accountID, actorDeviceID: credentials.deviceID, targetDeviceID: target, action: action == .enroll ? .enrollSyncNode : .replaceSyncNode, currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit), requestDigest: Data(repeating: 6, count: 32), issuedAt: "2026-08-14T12:00:00Z", expiresAt: "2026-08-14T12:05:00Z", serverKeyID: "test-key", serverSignature: signature)
    }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        states.append(.commit(request.evidence.action)); committedRequests.append(request)
        return try syncNodeFixtureV2Response()
    }
    func snapshot() -> (states: [Event], cancelledClaimIDs: [NodeEnrollmentClaimID], committedRequest: SyncNodeEnrollmentAdmissionRequest?) { (states, cancelledClaimIDs, committedRequests.last) }
    func requests() -> [SyncNodeEnrollmentAdmissionRequest] { committedRequests }
}

private actor ResponseLossRemote: SyncNodeEnrollmentRemote {
    private let fixture: Fixture
    private var committedRequests: [SyncNodeEnrollmentAdmissionRequest] = []
    private var cancelled: [NodeEnrollmentClaimID] = []

    init(fixture: Fixture) { self.fixture = fixture }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 {
        XCTAssertEqual(setupCode, fixture.setupCode)
        return fixture.claim
    }

    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        XCTAssertEqual(setupCode, fixture.setupCode)
        cancelled.append(claimID)
    }

    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        let target = action == .enroll ? claim.nodeDeviceID : replacedNodeID
        return try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID("90000000-0000-4000-8000-000000000003"), accountID: credentials.accountID, actorDeviceID: credentials.deviceID, targetDeviceID: target, action: action == .enroll ? .enrollSyncNode : .replaceSyncNode, currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit), requestDigest: Data(repeating: 6, count: 32), issuedAt: "2026-08-14T12:00:00Z", expiresAt: "2026-08-14T12:05:00Z", serverKeyID: "test-key", serverSignature: try fixture.identity.signature(for: Data("step-up".utf8)))
    }

    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        committedRequests.append(request)
        if committedRequests.count == 1 { throw AccountRuntimeError.transportFailure }
        return try syncNodeFixtureV2Response()
    }

    func requests() -> [SyncNodeEnrollmentAdmissionRequest] { committedRequests }
    func cancelledClaimIDs() -> [NodeEnrollmentClaimID] { cancelled }
}

private actor BlockingLookupRemote: SyncNodeEnrollmentRemote {
    enum Call: Equatable { case lookup, cancel }
    let claim: AccountNodeEnrollmentPublicClaimV1
    private(set) var calls: [Call] = []
    private var lookupContinuation: CheckedContinuation<AccountNodeEnrollmentPublicClaimV1, Never>?
    private var lookupWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    init(claim: AccountNodeEnrollmentPublicClaimV1) { self.claim = claim }
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 {
        calls.append(.lookup); lookupWaiters.forEach { $0.resume() }; lookupWaiters.removeAll()
        return await withCheckedContinuation { lookupContinuation = $0 }
    }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        calls.append(.cancel); cancelWaiters.forEach { $0.resume() }; cancelWaiters.removeAll()
    }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.untrustedResponse }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse { throw AccountRuntimeError.untrustedResponse }
    func waitUntilLookupStarts() async { if calls.contains(.lookup) { return }; await withCheckedContinuation { lookupWaiters.append($0) } }
    func waitUntilCancelled() async { if calls.contains(.cancel) { return }; await withCheckedContinuation { cancelWaiters.append($0) } }
    func releaseLookup() { lookupContinuation?.resume(returning: claim); lookupContinuation = nil }
}

private actor FirstLookupBlockingRemote: SyncNodeEnrollmentRemote {
    private let base: SyncNodeRemoteFixture
    private let claim: AccountNodeEnrollmentPublicClaimV1
    private var lookupCount = 0
    private var firstContinuation: CheckedContinuation<AccountNodeEnrollmentPublicClaimV1, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(fixture: Fixture) { base = SyncNodeRemoteFixture(fixture: fixture); claim = fixture.claim }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 {
        lookupCount += 1
        if lookupCount == 1 {
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return try await base.lookupSyncNodeClaim(setupCode: setupCode)
    }

    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        try await base.cancelSyncNodeClaim(claimID: claimID, setupCode: setupCode)
    }

    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        try await base.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: authorization, credentials: credentials, device: device, trustCommit: trustCommit, now: now)
    }

    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        try await base.commitSyncNodeAdmission(request, credentials: credentials, device: device, now: now)
    }

    func waitUntilFirstLookupStarts() async {
        if lookupCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstLookup() {
        firstContinuation?.resume(returning: claim)
        firstContinuation = nil
    }

    func cancelledClaimIDs() async -> [NodeEnrollmentClaimID] {
        (await base.snapshot()).cancelledClaimIDs
    }
}

private actor DelayedCancellationRemote: SyncNodeEnrollmentRemote {
    private let base: SyncNodeRemoteFixture
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationStarted = false

    init(fixture: Fixture) { base = SyncNodeRemoteFixture(fixture: fixture) }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 {
        try await base.lookupSyncNodeClaim(setupCode: setupCode)
    }

    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        cancellationStarted = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
        await withCheckedContinuation { cancellationContinuation = $0 }
    }

    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        try await base.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: authorization, credentials: credentials, device: device, trustCommit: trustCommit, now: now)
    }

    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        try await base.commitSyncNodeAdmission(request, credentials: credentials, device: device, now: now)
    }

    func waitUntilCancellationStarts() async {
        if cancellationStarted { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}

private final class EnrollmentOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.withLock { events.append(event) } }
    func values() -> [String] { lock.withLock { events } }
}

private struct OrderedEnrollmentPresenter: SyncNodeEnrollmentPresenting {
    let presentation: SyncNodeEnrollmentPresentation
    let events: EnrollmentOrderRecorder
    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation {
        events.record("fetch")
        return presentation
    }
}

private actor CountingProvisionedPresenter: SyncNodeEnrollmentPresenting {
    private let presentation: SyncNodeEnrollmentPresentation
    private var fetches = 0
    init(presentation: SyncNodeEnrollmentPresentation) { self.presentation = presentation }
    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation { fetches += 1; return presentation }
    func count() -> Int { fetches }
}

private actor BlockingCommitTrust: SyncNodeEnrollmentTrustCoordinating {
    private let base: FixtureSyncNodeTrust
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var accepted = 0
    init(base: FixtureSyncNodeTrust) { self.base = base }
    func currentTrustCommit() async throws -> AccountTrustStateCommit? { try await base.currentTrustCommit() }
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit {
        started = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return try await base.makeSyncNodeEnrollmentCommit(evidence: evidence)
    }
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws {
        accepted += 1
        try await base.acceptSyncNodeEnrollmentCommit(commit, evidence: evidence)
    }
    func waitUntilCommitStarts() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseCommit() { continuation?.resume(); continuation = nil }
    func acceptanceCount() -> Int { accepted }
}

private struct OrderedBootstrapVerifier: SyncNodeBootstrapClaimVerifying {
    let origin: NodeEndpointURL
    let events: EnrollmentOrderRecorder
    func verify(profile: SyncNodeBootstrapProfile, presentation: SyncNodeEnrollmentPresentation, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data) throws -> NodeEndpointURL {
        events.record("verifyPins")
        return origin
    }
}

private struct OrderedLocalAuthenticator: SyncNodeEnrollmentLocalAuthenticating {
    let events: EnrollmentOrderRecorder
    func authenticateSyncNodeEnrollment() async throws { events.record("localAuth") }
}

private actor OrderedEnrollmentRemote: SyncNodeEnrollmentRemote {
    let base: any SyncNodeEnrollmentRemote
    let events: EnrollmentOrderRecorder

    init(base: any SyncNodeEnrollmentRemote, events: EnrollmentOrderRecorder) {
        self.base = base
        self.events = events
    }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 {
        events.record("lookup")
        return try await base.lookupSyncNodeClaim(setupCode: setupCode)
    }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        try await base.cancelSyncNodeClaim(claimID: claimID, setupCode: setupCode)
    }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        events.record("stepUp")
        return try await base.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: authorization, credentials: credentials, device: device, trustCommit: trustCommit, now: now)
    }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        events.record("admission")
        return try await base.commitSyncNodeAdmission(request, credentials: credentials, device: device, now: now)
    }
}

private actor OrderedSyncNodeActivator: SyncNodeEnrollmentActivating {
    let events: EnrollmentOrderRecorder
    private var capturedOrigins: [NodeEndpointURL] = []
    init(events: EnrollmentOrderRecorder) { self.events = events }
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {
        capturedOrigins.append(expectedOrigin)
        events.record("activate")
    }
    func retryUncertainActivation() async throws {}
    func cancelPendingActivation() async {}
    func origins() -> [NodeEndpointURL] { capturedOrigins }
}

/// The session credentials a provider returns now; tests rotate or replace
/// them between attempts.
private final class SessionCredentialsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AccountSessionCredentials
    private var currentFailure: Error?
    init(_ value: AccountSessionCredentials) { current = value }
    var value: AccountSessionCredentials {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    var failure: Error? {
        get { lock.withLock { currentFailure } }
        set { lock.withLock { currentFailure = newValue } }
    }
    var provider: SyncNodeEnrollmentCredentialsProvider { { try self.read() } }
    private func read() throws -> AccountSessionCredentials {
        try lock.withLock {
            if let currentFailure { throw currentFailure }
            return current
        }
    }
}

/// Each `activate` and `retryUncertainActivation` call takes the next scripted
/// outcome; `nil` (or an exhausted script) succeeds.
private actor ScriptedSyncNodeActivator: SyncNodeEnrollmentActivating {
    private var activations: [Error?]
    private var retries: [Error?]
    private var activationCount = 0
    private var retryCount = 0
    init(activations: [Error?], retries: [Error?]) { self.activations = activations; self.retries = retries }
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {
        activationCount += 1
        if !activations.isEmpty, let failure = activations.removeFirst() { throw failure }
    }
    func retryUncertainActivation() async throws {
        retryCount += 1
        if !retries.isEmpty, let failure = retries.removeFirst() { throw failure }
    }
    func cancelPendingActivation() async {}
    func counts() -> (activations: Int, retries: Int) { (activationCount, retryCount) }
}

private actor FailingAcceptanceTrust: SyncNodeEnrollmentTrustCoordinating {
    private let base: FixtureSyncNodeTrust
    private var failures: Int
    private var accepted = 0
    init(base: FixtureSyncNodeTrust, failures: Int) { self.base = base; self.failures = failures }
    func currentTrustCommit() async throws -> AccountTrustStateCommit? { try await base.currentTrustCommit() }
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit { try await base.makeSyncNodeEnrollmentCommit(evidence: evidence) }
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws {
        if failures > 0 { failures -= 1; throw AccountRuntimeError.corruptSecret }
        try await base.acceptSyncNodeEnrollmentCommit(commit, evidence: evidence)
        accepted += 1
    }
    func successfulAcceptances() -> Int { accepted }
}
