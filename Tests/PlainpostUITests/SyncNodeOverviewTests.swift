import Foundation
import XCTest
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport
@testable import PlainpostUI

/// Every row of the Sync Node page overview table in the 2026-10-04 settings UX spec.
@MainActor
final class SyncNodeOverviewTests: XCTestCase {
    private typealias Overview = SyncNodeOverview
    private let host = "sync.example.com"

    private func overview(_ input: Overview.Input) -> Overview { Overview(input) }

    private func enrolled(
        _ presentation: SyncNodeEnrollmentViewModel.ConnectionPresentation,
        state: SyncNodeEnrollmentCoordinator.State = .enterCode,
        hasProvisionedTarget: Bool = false
    ) -> Overview.Enrollment {
        Overview.Enrollment(state: state, presentation: presentation, isEnrolled: true, hasProvisionedTarget: hasProvisionedTarget, targetHost: host)
    }

    private func reachable(lag: String = "2s") -> Overview.NodeStatus {
        Overview.NodeStatus(hasStatus: true, reachability: "reachable", syncLag: lag)
    }

    func testSignedOutOffersConnectPlainpostAccountOnlyWhenTheHostCan() {
        let withAction = overview(.init(isSignedIn: false, canConnectPlainpostAccount: true))
        XCTAssertEqual(withAction.state, .signedOut)
        XCTAssertEqual(withAction.title, "Sign in to Plainpost")
        XCTAssertEqual(withAction.detail, ["A Sync Node is your own server that keeps mail synced while your devices are off. Sign in to set one up."])
        XCTAssertEqual(withAction.actions, [.connectPlainpostAccount])
        XCTAssertEqual(withAction.tint, .neutral)

        let withoutAction = overview(.init(isSignedIn: false, canConnectPlainpostAccount: false))
        XCTAssertEqual(withoutAction.state, .signedOut)
        XCTAssertEqual(withoutAction.actions, [])
    }

    // An account that exists but can't be used isn't asked to sign in.
    func testAnUnusableAccountPointsToPlainpostAccountInsteadOfSignIn() {
        for canConnect in [true, false] {
            let unavailable = overview(.init(isSignedIn: false, isAccountUnavailable: true, canConnectPlainpostAccount: canConnect))
            XCTAssertEqual(unavailable.state, .accountUnavailable)
            XCTAssertEqual(unavailable.title, "Plainpost account unavailable")
            XCTAssertEqual(unavailable.detail, ["Open Plainpost Account in Settings to see why."])
            XCTAssertEqual(unavailable.actions, [])
            XCTAssertEqual(unavailable.tint, .attention)
        }
        // Signed in, the flag is ignored.
        XCTAssertEqual(overview(.init(isAccountUnavailable: true)).state, .notSetUp)
    }

    func testLoadingShowsProgressWithoutDetailOrAction() {
        let loading = overview(.init(load: .loading))
        XCTAssertEqual(loading.state, .loading)
        XCTAssertEqual(loading.title, "Checking your Sync Node…")
        XCTAssertEqual(loading.detail, [])
        XCTAssertEqual(loading.actions, [])
        XCTAssertTrue(loading.showsProgress)
    }

    func testLoadFailedShowsTheMessageAndTryAgain() {
        let failed = overview(.init(load: .failed(message: "Couldn’t load.")))
        XCTAssertEqual(failed.state, .loadFailed)
        XCTAssertEqual(failed.title, "Sync Node unavailable")
        XCTAssertEqual(failed.detail, ["Couldn’t load."])
        XCTAssertEqual(failed.actions, [.tryAgain])
        XCTAssertEqual(failed.tint, .failure)
    }

    // Only a load that found no Node and no Server Setup means "No Sync Node"; its next step
    // is setup, so it offers no Try Again.
    func testNoSyncNodeLoadIsNotSetUp() {
        let none = overview(.init(load: .noSyncNode))
        XCTAssertEqual(none.state, .notSetUp)
        XCTAssertEqual(none.title, "No Sync Node")
        XCTAssertEqual(none.detail, [Overview.explanation])
        XCTAssertEqual(none.actions, [])
        // A Node that reports a status is shown as that Node.
        XCTAssertEqual(overview(.init(load: .noSyncNode, nodeStatus: reachable())).state, .connected)
    }

    // A Node that reports a status is enrolled, even with no Server Setup imported (it was
    // retired after install): a failed load is a real failure, never "No Sync Node".
    func testAFailedLoadWithANodeStatusIsNeverNoSyncNode() {
        let failed = overview(.init(load: .failed(message: "Couldn’t load."), nodeStatus: reachable()))
        XCTAssertEqual(failed.state, .loadFailed)
        XCTAssertEqual(failed.detail, ["Couldn’t load."])
        XCTAssertEqual(failed.actions, [.tryAgain])
    }

    // No enrollment model (a Mac offline lease leaves the load idle): the Node's status.
    func testAnIdleLoadWithANodeStatusReportsTheNode() {
        XCTAssertEqual(overview(.init(load: .idle, nodeStatus: reachable())).state, .connected)
        let unreachable = overview(.init(load: .idle, nodeStatus: .init(hasStatus: true, reachability: "Unavailable", syncLag: "1s")))
        XCTAssertEqual(unreachable.state, .unreachable)
        XCTAssertEqual(unreachable.actions, [.checkAgain])
        let unread = overview(.init(load: .idle, nodeStatus: .init(hasStatus: false, reachability: "Unavailable", syncLag: "Unknown")))
        XCTAssertEqual(unread.state, .loading)
    }

    func testOwnerRequiredShowsOnlyTheExistingMessageEvenSignedOut() {
        for signedIn in [true, false] {
            let owner = overview(.init(isSignedIn: signedIn, awaitsOwner: true, enrollment: enrolled(.connected)))
            XCTAssertEqual(owner.state, .ownerRequired)
            XCTAssertEqual(owner.title, AccountSessionViewModel.syncNodeEnrollmentOwnerRequiredMessage)
            XCTAssertEqual(owner.detail, [])
            XCTAssertEqual(owner.actions, [])
        }
    }

    func testNotSetUpExplainsWhatASyncNodeIs() {
        for input in [Overview.Input(), Overview.Input(load: .ready), Overview.Input(enrollment: .init(hasProvisionedTarget: false))] {
            let notSetUp = overview(input)
            XCTAssertEqual(notSetUp.state, .notSetUp)
            XCTAssertEqual(notSetUp.title, "No Sync Node")
            XCTAssertEqual(notSetUp.detail, ["A Sync Node is your own server that keeps mail synced while your devices are off."])
            XCTAssertEqual(notSetUp.actions, [])
        }
    }

    func testReadyToConnectNamesTheHostAndLeavesTheAppleButtonToStepTwo() {
        let ready = overview(.init(enrollment: .init(targetHost: host)))
        XCTAssertEqual(ready.state, .readyToConnect)
        XCTAssertEqual(ready.title, "Ready to connect")
        XCTAssertEqual(ready.detail, [host])
        XCTAssertEqual(ready.actions, [])
    }

    // A confirmed replacement moves an enrolled Node to `.ready` with the new Server Setup:
    // the overview is about connecting to it, not the current Node.
    func testAConfirmedReplacementIsReadyToConnectBeforeTheEnrolledNode() {
        let replacing = overview(.init(enrollment: enrolled(.ready, hasProvisionedTarget: true), nodeStatus: reachable()))
        XCTAssertEqual(replacing.state, .readyToConnect)
        XCTAssertEqual(replacing.detail, [host])
        // Without a new Server Setup, an enrolled `.ready` Node reports its status.
        XCTAssertEqual(overview(.init(enrollment: enrolled(.ready), nodeStatus: reachable())).state, .connected)
    }

    func testConnectingNamesTheCurrentStep() {
        let steps: [(SyncNodeEnrollmentCoordinator.State, SyncNodeEnrollmentViewModel.ConnectionPresentation, String)] = [
            (.fetching, .connecting, "Preparing the server connection…"),
            (.localAuthentication, .connecting, "Confirming on this device…"),
            (.centralStepUp, .connecting, "Confirming account access…"),
            (.signing, .connecting, "Signing approval…"),
            (.committing, .connecting, "Installing Sync Node…"),
            (.enterCode, .authorizing, "Waiting for Sign in with Apple…"),
            (.enterCode, .checking, "Checking the connection…"),
        ]
        for (state, presentation, step) in steps {
            let connecting = overview(.init(enrollment: .init(state: state, presentation: presentation, targetHost: host)))
            XCTAssertEqual(connecting.state, .connecting, "\(state)")
            XCTAssertEqual(connecting.title, "Connecting…")
            XCTAssertEqual(connecting.detail, [step])
            XCTAssertTrue(connecting.showsProgress)
            XCTAssertEqual(connecting.actions, [])
        }
    }

    func testConnectedNamesTheHostAndADelayedSync() {
        let connected = overview(.init(enrollment: enrolled(.connected), nodeStatus: reachable()))
        XCTAssertEqual(connected.state, .connected)
        XCTAssertEqual(connected.title, "Connected")
        XCTAssertEqual(connected.detail, [host])
        XCTAssertEqual(connected.tint, .positive)
        XCTAssertEqual(connected.actions, [])

        let delayed = overview(.init(enrollment: enrolled(.connected), nodeStatus: reachable(lag: "20m")))
        XCTAssertEqual(delayed.detail, ["\(host) · Sync delayed"])

        // Without a status model the enrollment's own verification is the evidence.
        XCTAssertEqual(overview(.init(enrollment: enrolled(.connected))).state, .connected)
    }

    // One truth: an enrolled Node whose status isn't reachable is never "Connected".
    func testUnreachableEnrolledNodeOffersCheckAgainAndNeverClaimsConnected() {
        for reachability in ["Unavailable", "unreachable", "Unknown"] {
            let unreachable = overview(.init(
                enrollment: enrolled(.connected),
                nodeStatus: .init(hasStatus: true, reachability: reachability, syncLag: "1s")
            ))
            XCTAssertEqual(unreachable.state, .unreachable)
            XCTAssertEqual(unreachable.title, "Can’t reach your Sync Node")
            XCTAssertEqual(unreachable.detail, ["Make sure it’s running and online."])
            XCTAssertEqual(unreachable.actions, [.checkAgain])
            XCTAssertEqual(unreachable.tint, .attention)
        }
        // A status that hasn't been read yet is checked, not reported.
        let unread = overview(.init(enrollment: enrolled(.connected), nodeStatus: .init(hasStatus: false, reachability: "Unavailable", syncLag: "Unknown")))
        XCTAssertEqual(unread.state, .loading)
    }

    func testInstalledNotReadyOffersRetryConnection() {
        let notReady = overview(.init(enrollment: enrolled(.connectionFailed)))
        XCTAssertEqual(notReady.state, .notReady)
        XCTAssertEqual(notReady.title, "Not ready yet")
        XCTAssertEqual(notReady.detail, ["The Sync Node is installed but isn’t answering yet."])
        XCTAssertEqual(notReady.actions, [.retryConnection])
        XCTAssertEqual(notReady.tint, .attention)
    }

    func testFailedKeepsTheExistingMessageAndRetryRules() {
        let generic = overview(.init(enrollment: .init(state: .failed, presentation: .failed, targetHost: host, failureMessage: SyncNodeEnrollmentViewModel.genericFailureMessage)))
        XCTAssertEqual(generic.state, .failed)
        XCTAssertEqual(generic.title, "Couldn’t connect")
        XCTAssertEqual(generic.detail, [SyncNodeEnrollmentViewModel.genericFailureMessage])
        XCTAssertEqual(generic.actions, [.retry])
        XCTAssertEqual(generic.tint, .failure)

        // The same Server Setup will mismatch again: Start Over, plus the import hint.
        let mismatch = overview(.init(enrollment: .init(
            state: .serverAudienceMismatch, presentation: .failed, targetHost: host,
            failureMessage: SyncNodeEnrollmentViewModel.serverMismatchMessage, needsNewServerSetup: true
        )))
        XCTAssertEqual(mismatch.detail, [SyncNodeEnrollmentViewModel.serverMismatchMessage, SyncNodeOverview.differentFileHint])
        XCTAssertEqual(mismatch.actions, [.startOver])

        // An outdated file can only be replaced, so no retry is offered.
        let outdated = overview(.init(enrollment: .init(
            targetHost: host, failureMessage: SyncNodeEnrollmentViewModel.outdatedProfileMessage,
            isProfileOutdated: true, needsNewServerSetup: true
        )))
        XCTAssertEqual(outdated.state, .failed)
        XCTAssertEqual(outdated.detail, [SyncNodeEnrollmentViewModel.outdatedProfileMessage, SyncNodeOverview.differentFileHint])
        XCTAssertEqual(outdated.actions, [])
    }

    func testFinishingKeepsTheExistingUncertainCopyGuidanceAndRetries() {
        let guidance = "\(SyncNodeEnrollmentViewModel.keepOpenMessage) \(SyncNodeEnrollmentViewModel.stopAndStartOverGuidance)"
        let commit = overview(.init(enrollment: .init(
            state: .commitResponseUncertain, presentation: .connecting,
            retainedAdmissionGuidance: guidance, canStopAndStartOver: true
        )))
        XCTAssertEqual(commit.state, .finishing)
        XCTAssertEqual(commit.title, "Finishing connection")
        XCTAssertEqual(commit.detail, [SyncNodeEnrollmentViewModel.commitUncertainMessage, guidance])
        XCTAssertEqual(commit.actions, [.retryInstallation, .stopAndStartOver])
        XCTAssertFalse(commit.actionsDisabled)

        let refused = overview(.init(enrollment: .init(
            state: .commitResponseUncertain, presentation: .connecting,
            retainedAdmissionGuidance: SyncNodeEnrollmentViewModel.keepOpenMessage,
            isStoppingAndStartingOver: true,
            startOverFailureMessage: SyncNodeEnrollmentViewModel.startOverUnconfirmedMessage
        )))
        XCTAssertEqual(refused.detail, [SyncNodeEnrollmentViewModel.commitUncertainMessage, SyncNodeEnrollmentViewModel.keepOpenMessage, SyncNodeEnrollmentViewModel.startOverUnconfirmedMessage])
        XCTAssertEqual(refused.actions, [.retryInstallation])
        XCTAssertTrue(refused.actionsDisabled)

        let activation = overview(.init(enrollment: .init(
            state: .activationResponseUncertain, presentation: .connecting,
            retainedAdmissionGuidance: SyncNodeEnrollmentViewModel.activationResumesGuidance
        )))
        XCTAssertEqual(activation.state, .finishing)
        XCTAssertEqual(activation.detail, [SyncNodeEnrollmentViewModel.activationUncertainMessage, SyncNodeEnrollmentViewModel.activationResumesGuidance])
        XCTAssertEqual(activation.actions, [.retryActivation])

        let verification = overview(.init(enrollment: .init(
            state: .commitVerificationFailed(.trustAcceptance), presentation: .connecting,
            failureMessage: SyncNodeEnrollmentViewModel.verificationFailureMessage,
            retainedAdmissionGuidance: SyncNodeEnrollmentViewModel.keepOpenMessage
        )))
        XCTAssertEqual(verification.state, .finishing)
        XCTAssertEqual(verification.detail, [SyncNodeEnrollmentViewModel.verificationFailureMessage, SyncNodeEnrollmentViewModel.keepOpenMessage])
        XCTAssertEqual(verification.actions, [.retryVerification])
        XCTAssertEqual(verification.tint, .attention)
    }

    // A possibly committed admission is finished by its own retry, whatever the Node's status.
    func testAnUncertainCommitIsFinishingEvenWhileTheNodeIsUnreachable() {
        let unreachable = Overview.NodeStatus(hasStatus: true, reachability: "Unavailable", syncLag: "Unknown")
        for isEnrolled in [false, true] {
            var enrollment = Overview.Enrollment(state: .commitResponseUncertain, presentation: .connecting, isEnrolled: isEnrolled, targetHost: host)
            enrollment.retainedAdmissionGuidance = SyncNodeEnrollmentViewModel.keepOpenMessage
            let commit = overview(.init(enrollment: enrollment, nodeStatus: unreachable))
            XCTAssertEqual(commit.state, .finishing)
            XCTAssertEqual(commit.actions, [.retryInstallation])
        }
    }

    func testApproveServerNamesTheHostWithApproveAndCancel() {
        let approve = overview(.init(enrollment: .init(state: .matchingStringConfirmation("ABC"), presentation: .ready, targetHost: host)))
        XCTAssertEqual(approve.state, .approveServer)
        XCTAssertEqual(approve.title, "Approve this server")
        XCTAssertEqual(approve.detail, ["Approve \(host) for your Plainpost account."])
        XCTAssertEqual(approve.actions, [.approve, .cancelApproval])

        // Once approved, the overview reports progress, and Cancel stays until the server
        // moves on.
        let approving = overview(.init(enrollment: .init(state: .matchingStringConfirmation("ABC"), presentation: .connecting, targetHost: host)))
        XCTAssertEqual(approving.state, .connecting)
        XCTAssertEqual(approving.actions, [.cancelApproval])
        XCTAssertFalse(approving.actionsDisabled)
        let signing = overview(.init(enrollment: .init(state: .signing, presentation: .connecting, targetHost: host)))
        XCTAssertEqual(signing.actions, [])
    }

    func testRecoveryRequiredKeepsTheExistingCopyAndExplainsAnOutdatedFile() {
        let recovery = overview(.init(enrollment: enrolled(.recoveryRequired)))
        XCTAssertEqual(recovery.state, .recoveryRequired)
        XCTAssertEqual(recovery.title, "This device needs to reconnect")
        // Without a Server Setup, it says how to get one before Replace Sync Node.
        XCTAssertEqual(recovery.detail, [SyncNodeOverview.recoveryDetail, SyncNodeOverview.recoveryImportDetail])
        XCTAssertEqual(recovery.actions, [])
        XCTAssertFalse(recovery.detail.joined().contains("private session"))

        // With one, Replace Sync Node is next.
        XCTAssertEqual(
            overview(.init(enrollment: enrolled(.recoveryRequired, hasProvisionedTarget: true))).detail,
            [SyncNodeOverview.recoveryDetail, SyncNodeOverview.recoveryReplaceDetail]
        )

        var outdated = enrolled(.recoveryRequired, hasProvisionedTarget: true)
        outdated.isProfileOutdated = true
        outdated.failureMessage = SyncNodeEnrollmentViewModel.outdatedProfileMessage
        XCTAssertEqual(
            overview(.init(enrollment: outdated)).detail,
            [SyncNodeOverview.recoveryDetail, SyncNodeOverview.recoveryImportDetail, SyncNodeEnrollmentViewModel.outdatedProfileMessage, SyncNodeEnrollmentViewModel.serverSetupImportHint]
        )
    }

    func testStatusOnlyHostsReportTheNodeStatus() {
        XCTAssertEqual(overview(.init(nodeStatus: reachable())).state, .connected)
        XCTAssertEqual(overview(.init(nodeStatus: .init(hasStatus: true, reachability: "Unavailable", syncLag: "1s"))).state, .unreachable)
    }

    func testEveryActionKeepsItsIdentifier() {
        XCTAssertEqual(Overview.Action.retryConnection.accessibilityIdentifier, "sync-node-retry-connection")
        XCTAssertEqual(Overview.Action.retry.accessibilityIdentifier, "sync-node-retry")
        XCTAssertEqual(Overview.Action.startOver.accessibilityIdentifier, "sync-node-start-over")
        XCTAssertEqual(Overview.Action.retryInstallation.accessibilityIdentifier, "sync-node-retry-installation")
        XCTAssertEqual(Overview.Action.stopAndStartOver.accessibilityIdentifier, "sync-node-stop-and-start-over")
        XCTAssertEqual(Overview.Action.retryActivation.accessibilityIdentifier, "sync-node-retry-activation")
        XCTAssertEqual(Overview.Action.retryVerification.accessibilityIdentifier, "sync-node-retry-verification")
        XCTAssertEqual(Overview.Action.approve.accessibilityIdentifier, "sync-node-approve-pinned-target")
    }

    // MARK: - Last operation

    func testOperationProblemNamesTheOperation() {
        XCTAssertEqual(SyncNodeStatusText.operationProblem(.backup), "Backup didn’t finish. Try again.")
        XCTAssertEqual(SyncNodeStatusText.operationProblem(.erase), "Erase didn’t finish. Check the Sync Node before trying again.")
        XCTAssertEqual(SyncNodeStatusText.operationProblem(nil), "The last Sync Node action didn’t finish. Try again.")
    }

    func testLastOperationIsSetWhenAnOperationStarts() async {
        let model = SyncNodeSettingsViewModel(
            operationsController: SyncNodeOperationsController(client: OverviewFailingOperationsClient(), authenticator: OverviewApprovingAuthenticator())
        )
        XCTAssertNil(model.lastOperation)

        await model.runBackup()
        XCTAssertEqual(model.lastOperation, .backup)
        XCTAssertEqual(model.operationPhase, .uncertain)

        // A mismatched confirmation still started (and failed) an erase.
        await model.runErase(confirmation: "erase")
        XCTAssertEqual(model.lastOperation, .erase)
        XCTAssertEqual(model.operationPhase, .failed)
    }

    // Back Up Now waits for a status only once one has been read.
    func testBackUpNowIsHeldOnlyForANodeKnownToBeUnreachable() {
        XCTAssertFalse(SyncNodeStatusSection.isKnownUnreachable(SyncNodeSettingsViewModel()), "before the first read")
        let unreachable = SyncNodeSettingsViewModel()
        unreachable.update(.init(
            version: "1", reachability: "Unavailable", syncLag: "Unknown", storage: "", provider: "",
            mailboxAssignments: [], backup: "unknown", endpoint: "", updateStatus: ""
        ))
        XCTAssertTrue(SyncNodeStatusSection.isKnownUnreachable(unreachable))
        let reachable = SyncNodeSettingsViewModel()
        reachable.update(.init(
            version: "1", reachability: "reachable", syncLag: "1s", storage: "", provider: "",
            mailboxAssignments: [], backup: "verified", endpoint: "", updateStatus: ""
        ))
        XCTAssertFalse(SyncNodeStatusSection.isKnownUnreachable(reachable))
    }

    func testWithoutAnOperationsControllerNothingStarts() async {
        let model = SyncNodeSettingsViewModel()
        await model.runBackup()
        XCTAssertNil(model.lastOperation)
    }
}

private struct OverviewFailingOperationsClient: SyncNodeOperationsClient {
    func status() async throws -> SyncNodeStatus { throw AccountRuntimeError.transportFailure }
    func backup() async throws -> SyncNodeStatus { throw AccountRuntimeError.transportFailure }
    func erase() async throws -> SyncNodeStatus { throw AccountRuntimeError.transportFailure }
}

private struct OverviewApprovingAuthenticator: LocalApprovalAuthenticating {
    func authenticate(reason: String) async throws {}
}
