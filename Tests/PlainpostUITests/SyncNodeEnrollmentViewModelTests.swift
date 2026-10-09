import CryptoKit
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport
@testable import PlainpostUI

@MainActor
final class SyncNodeEnrollmentViewModelTests: XCTestCase {
    func testAppleClientsBuildEnrollmentOnlyThroughTheSharedAssembly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/PlainpostUI/AccountSessionViewModel.swift", "Apps/PlainpostiOS/Plainpost/MobileAccountModel.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("SyncNodeEnrollmentCoordinator("), "\(path) must use SyncNodeEnrollmentAssembly")
            XCTAssertTrue(source.contains("SyncNodeEnrollmentAssembly.makeModel("), "\(path) must use SyncNodeEnrollmentAssembly")
            XCTAssertTrue(source.contains("SyncNodeEnrollmentAssembly.activeSessionOwner("), "\(path) must gate a retained enrollment by its owner")
            XCTAssertFalse(source.contains(".audience"), "\(path) must not derive a Central audience")
        }
        let assembly = try String(contentsOf: root.appendingPathComponent("Sources/PlainpostUI/SyncNodeEnrollmentAssembly.swift"), encoding: .utf8)
        XCTAssertTrue(assembly.contains("PrivateSyncNodeEnrollmentActivator("))
    }

    // The Node refresh credential must not live in the notifications Keychain
    // group the iOS Notification Service extension shares. Every iOS endpoint
    // store comes from the one app-group factory; the shared assembly takes
    // the store from its caller instead of choosing a group itself.
    func testIOSBuildsEveryEndpointStoreInTheAppKeychainGroup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mobile = try String(contentsOf: root.appendingPathComponent("Apps/PlainpostiOS/Plainpost/MobileAccountModel.swift"), encoding: .utf8)
        // Matches a store construction, not the `makeSyncNodeEndpointStore(` factory name.
        let construction = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])SyncNodeEndpointStore\((\))?"#)
        let constructions = construction.matches(in: mobile, range: NSRange(mobile.startIndex..., in: mobile))
        XCTAssertEqual(constructions.count, 1, "iOS builds the endpoint store only in makeSyncNodeEndpointStore")
        XCTAssertTrue(constructions.allSatisfy { $0.range(at: 1).location == NSNotFound }, "iOS must not use the default Keychain group for the Node credential")
        XCTAssertTrue(mobile.contains("accessGroup: PlainpostIOSAppKeychain.accessGroup, legacyAccessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup"))
        XCTAssertEqual(mobile.components(separatedBy: "MobileAccountModel.makeSyncNodeEndpointStore()").count - 1, 2, "notification policy and enrollment use the app-group store")
        let app = try String(contentsOf: root.appendingPathComponent("Apps/PlainpostiOS/Plainpost/PlainpostApp.swift"), encoding: .utf8)
        XCTAssertEqual(app.components(separatedBy: "MobileAccountModel.makeSyncNodeEndpointStore()").count - 1, 2, "the broker and explicit attach use the same app-group store")
        let assembly = try String(contentsOf: root.appendingPathComponent("Sources/PlainpostUI/SyncNodeEnrollmentAssembly.swift"), encoding: .utf8)
        XCTAssertTrue(construction.matches(in: assembly, range: NSRange(assembly.startIndex..., in: assembly)).isEmpty, "the shared assembly must not pick a Keychain group")
    }

    // iOS renders a retained connection only for its owner, like macOS, and
    // shows the Server Setup import with it. The Settings Sync Node page owns
    // this; the account bar and the recovery sheet show no Sync Node UI.
    func testIOSSyncNodePageRendersOnlyTheOwnersSyncNodeConnection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Apps/PlainpostiOS/Plainpost/MobileSyncNodePage.swift"), encoding: .utf8)
        for required in [
            "account.presentableSyncNodeEnrollmentModel",
            "account.syncNodeEnrollmentAwaitsOwner",
            "account.syncNodeBootstrapImportModel",
            "account.handleSyncNodeBootstrapFileImporter",
            "SyncNodePageContent(",
            ".syncNodeEnrollmentLifecycle(account.presentableSyncNodeEnrollmentModel)",
        ] {
            XCTAssertTrue(page.contains(required), "MobileSyncNodePage lacks \(required)")
        }
        XCTAssertFalse(page.contains("account.syncNodeEnrollmentModel"))
        for file in ["MobileAccountRootView.swift", "MobileAccountSecurityView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Apps/PlainpostiOS/Plainpost/\(file)"), encoding: .utf8)
            XCTAssertFalse(source.contains("SyncNodeEnrollment"), "\(file) still renders Sync Node UI")
            XCTAssertFalse(source.contains("SyncNodeBootstrapImport"), "\(file) still renders Server Setup")
        }
    }

    func testNoActiveNodeExposesProvisionedConnectTarget() throws {
        let fixture = try UIEnrollmentFixture()
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil),
            profile: fixture.profile
        )

        XCTAssertTrue(model.canAddNode)
        XCTAssertFalse(model.canReplaceNode)
        XCTAssertEqual(model.targetOrigin, fixture.profile.canonicalOrigin.url.absoluteString)
        XCTAssertFalse(try XCTUnwrap(model.targetFingerprint).isEmpty)
    }

    func testReplacementNeedsExactCurrentNodeConfirmation() throws {
        let fixture = try UIEnrollmentFixture()
        let current = try AccountDeviceID("90000000-0000-4000-8000-000000000099")
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: current),
            profile: fixture.profile
        )

        model.requestReplacement()
        XCTAssertEqual(model.selectedReplacementNodeID, current)
        XCTAssertTrue(model.isReplacementConfirmationVisible)
        model.confirmReplacement()
        XCTAssertTrue(model.isReplacementReady)
        XCTAssertFalse(model.isReplacementConfirmationVisible)
    }

    func testConnectDoesNotFetchPresentationUntilOwnedAppleCompletion() async throws {
        let fixture = try UIEnrollmentFixture()
        let presenter = CountingEnrollmentPresenter(presentation: fixture.presentation)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: presenter),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )

        let attempt = try model.beginConnectAppleAuthorization()
        XCTAssertEqual(model.connectionPresentation, .authorizing)
        let beforeApple = await presenter.fetchCount()
        XCTAssertEqual(beforeApple, 0)
        XCTAssertThrowsError(try model.beginConnectAppleAuthorization())

        model.submitAppleIdentityToken(Data("apple-token".utf8), for: attempt.id)
        let failedBy = ContinuousClock.now + .seconds(20)
        while model.state != .failed, ContinuousClock.now < failedBy { try await Task.sleep(for: .milliseconds(2)) }

        let afterApple = await presenter.fetchCount()
        XCTAssertEqual(afterApple, 1)
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.connectionPresentation, .failed)
    }

    func testCancelFencesLateAppleCompletionAndKeepsRetryQuiet() async throws {
        let fixture = try UIEnrollmentFixture()
        let presenter = CountingEnrollmentPresenter(presentation: fixture.presentation)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: presenter),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let attempt = try model.beginConnectAppleAuthorization()

        await model.cancel()
        model.submitAppleIdentityToken(Data("late-token".utf8), for: attempt.id)
        for _ in 0 ..< 10 { await Task.yield() }

        let fetches = await presenter.fetchCount()
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(model.connectionPresentation, .ready)
        XCTAssertEqual(model.state, .enterCode)
    }

    func testConnectionRetryUsesOnlyCachedConnectionCheck() async throws {
        let fixture = try UIEnrollmentFixture()
        let checks = ConnectionCheckRecorder()
        let presenter = CountingEnrollmentPresenter(presentation: fixture.presentation)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID, presenter: presenter),
            profile: nil,
            initialConnectionPresentation: .connectionFailed,
            verifyConnection: { try await checks.check() }
        )

        await model.retryConnection()

        XCTAssertEqual(model.connectionPresentation, .connected)
        let checkCount = await checks.count()
        let presentationFetches = await presenter.fetchCount()
        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(presentationFetches, 0)
    }

    func testDisappearancePreservesInstalledConnectionPresentations() async throws {
        let fixture = try UIEnrollmentFixture()
        for presentation in [SyncNodeEnrollmentViewModel.ConnectionPresentation.connected, .connectionFailed] {
            let model = SyncNodeEnrollmentViewModel(
                coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
                profile: nil,
                initialConnectionPresentation: presentation
            )

            await model.viewDidDisappear()

            XCTAssertEqual(model.connectionPresentation, presentation)
            XCTAssertEqual(model.activeNodeID, fixture.profile.nodeDeviceID)
        }
    }

    func testPresentationMappingKeepsCommittedStatesConnectingAndPreCommitStatesFailed() {
        typealias VM = SyncNodeEnrollmentViewModel
        XCTAssertEqual(VM.connectionPresentation(for: .commitVerificationFailed(.audienceMismatch)), .connecting)
        XCTAssertEqual(VM.connectionPresentation(for: .commitResponseUncertain), .connecting)
        XCTAssertEqual(VM.connectionPresentation(for: .activationResponseUncertain), .connecting)
        XCTAssertEqual(VM.connectionPresentation(for: .matchingStringConfirmation("123456")), .ready)
        XCTAssertEqual(VM.connectionPresentation(for: .serverAudienceMismatch), .failed)
        XCTAssertEqual(VM.connectionPresentation(for: .profileOutdated), .failed)
        XCTAssertEqual(VM.connectionPresentation(for: .failed), .failed)
    }

    func testFailureCopyIsSpecificAndNeverSuggestsStartingOverAfterCommit() throws {
        let fixture = try UIEnrollmentFixture()
        typealias VM = SyncNodeEnrollmentViewModel
        XCTAssertEqual(VM.failureMessage(for: .commitVerificationFailed(.responseVerification), profile: fixture.profile), "Plainpost couldn’t verify the server’s approval. Your approval is saved, so don’t start over.")
        XCTAssertEqual(VM.failureMessage(for: .serverAudienceMismatch, profile: fixture.profile), "This Server Setup file doesn’t match your Plainpost server. Create a new one for this server.")
        XCTAssertEqual(VM.failureMessage(for: .profileOutdated, profile: fixture.profile), "This Server Setup file is out of date. Create a new one for this server.")
        XCTAssertEqual(VM.failureMessage(for: .failed, profile: fixture.profile), "Sync Node connection couldn’t be completed. Try again.")
        XCTAssertNil(VM.failureMessage(for: .enterCode, profile: fixture.profile))
    }

    func testOutdatedProfileBlocksConnectBeforeAppleAuthorization() throws {
        let fixture = try UIEnrollmentFixture()
        let legacy = try SyncNodeBootstrapProfile(canonicalOrigin: fixture.profile.canonicalOrigin, nodeDeviceID: fixture.profile.nodeDeviceID, signingKeyDigest: fixture.profile.signingKeyDigest, capabilityID: fixture.profile.capabilityID, capability: fixture.profile.capability, centralAudience: nil)
        let model = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: legacy)

        XCTAssertTrue(model.isProfileOutdated)
        XCTAssertFalse(model.canBeginConnect)
        XCTAssertThrowsError(try model.beginConnectAppleAuthorization())
        XCTAssertEqual(SyncNodeEnrollmentViewModel.failureMessage(for: model.state, profile: legacy), SyncNodeEnrollmentViewModel.outdatedProfileMessage)
    }

    // A failed Apple authorization leaves the coordinator in `.enterCode`, so
    // the state mapping alone has no message. The generic failure and Retry
    // must still show.
    func testFailedAppleAuthorizationShowsGenericFailureAndRetry() throws {
        let fixture = try UIEnrollmentFixture()
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let attempt = try model.beginConnectAppleAuthorization()

        model.submitAppleIdentityToken(Data(), for: attempt.id)

        XCTAssertEqual(model.state, .enterCode)
        XCTAssertEqual(model.connectionPresentation, .failed)
        XCTAssertNil(SyncNodeEnrollmentViewModel.failureMessage(for: model.state, profile: fixture.profile))
        XCTAssertEqual(model.presentedFailureMessage, SyncNodeEnrollmentViewModel.genericFailureMessage)
        model.resetAfterFailure()
        XCTAssertEqual(model.connectionPresentation, .ready)
        XCTAssertNil(model.presentedFailureMessage)
    }

    // Replace Sync Node is the recovery path for a device without the private
    // session or a reachable Node. Confirmation, not selection, unlocks it.
    func testConfirmedReplacementCanBeginFromRecoveryRequiredAndConnectionFailed() throws {
        let fixture = try UIEnrollmentFixture()
        let current = try AccountDeviceID("90000000-0000-4000-8000-000000000099")
        for presentation in [SyncNodeEnrollmentViewModel.ConnectionPresentation.recoveryRequired, .connectionFailed] {
            let model = SyncNodeEnrollmentViewModel(
                coordinator: fixture.coordinator(activeNodeID: current),
                profile: fixture.profile,
                initialConnectionPresentation: presentation,
                nonceGenerator: { Data(repeating: 4, count: 32) }
            )
            XCTAssertFalse(model.canBeginConnect)

            model.requestReplacement()
            XCTAssertEqual(model.connectionPresentation, presentation)
            XCTAssertFalse(model.canBeginConnect)
            model.confirmReplacement()

            XCTAssertTrue(model.isReplacementReady)
            XCTAssertEqual(model.connectionPresentation, .ready)
            XCTAssertTrue(model.canBeginConnect)
            _ = try model.beginConnectAppleAuthorization()
            XCTAssertEqual(model.connectionPresentation, .authorizing)
        }
        // Settings > Sync Node offers Replace next to a connected Node; a
        // confirmed replacement must reach Continue with Apple there too.
        let connected = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: current), profile: fixture.profile, initialConnectionPresentation: .connected, nonceGenerator: { Data(repeating: 4, count: 32) })
        connected.requestReplacement()
        connected.confirmReplacement()
        XCTAssertEqual(connected.connectionPresentation, .ready)
        XCTAssertTrue(connected.canBeginConnect)
        _ = try connected.beginConnectAppleAuthorization()
        XCTAssertEqual(connected.connectionPresentation, .authorizing)
    }

    // Confirming Replace only unlocks Connect. When the replacement ends
    // without installing, the still-active Node is presented as it was.
    func testEndingReplacementWithoutInstallingRestoresThePriorPresentation() async throws {
        let fixture = try UIEnrollmentFixture()
        let current = try AccountDeviceID("90000000-0000-4000-8000-000000000099")
        for presentation in [SyncNodeEnrollmentViewModel.ConnectionPresentation.connected, .connectionFailed, .recoveryRequired] {
            let model = SyncNodeEnrollmentViewModel(
                coordinator: fixture.coordinator(activeNodeID: current),
                profile: fixture.profile,
                initialConnectionPresentation: presentation,
                nonceGenerator: { Data(repeating: 4, count: 32) }
            )
            model.requestReplacement()
            model.confirmReplacement()
            XCTAssertEqual(model.connectionPresentation, .ready)

            model.cancelReplacement()
            XCTAssertEqual(model.connectionPresentation, presentation, "consent cleared")
            XCTAssertFalse(model.isReplacementReady)
            XCTAssertNil(model.selectedReplacementNodeID)
            XCTAssertFalse(model.canBeginConnect)

            model.requestReplacement()
            model.confirmReplacement()
            await model.viewDidDisappear()
            XCTAssertEqual(model.connectionPresentation, presentation, "page disappeared")
            XCTAssertFalse(model.isReplacementReady)
        }

        // A proven Stop and Start Over in a Replace flow leaves the old Node
        // active, so it shows Connected again.
        let stopRemote = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 1)
        let stopped = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: current, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: stopRemote, trust: fixture.trust),
            profile: fixture.profile,
            initialConnectionPresentation: .connected,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        stopped.requestReplacement()
        stopped.confirmReplacement()
        try await reachPinnedTarget(stopped)
        await stopped.approvePinnedTarget()
        XCTAssertEqual(stopped.state, .commitResponseUncertain)
        let replaceRequests = await stopRemote.requests()
        XCTAssertEqual(replaceRequests.first?.evidence.replacedNodeID, current)
        await stopped.cancel()
        XCTAssertEqual(stopped.connectionPresentation, .connecting, "a retained admission keeps its presentation")
        await stopped.stopAndStartOver()
        XCTAssertEqual(stopped.state, .enterCode)
        XCTAssertEqual(stopped.activeNodeID, current)
        XCTAssertEqual(stopped.connectionPresentation, .connected)
        XCTAssertFalse(stopped.isReplacementReady)

        // So does the matching screen's Cancel, and Retry after a pre-commit failure.
        let rejected = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: current, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture), trust: fixture.trust),
            profile: fixture.profile,
            initialConnectionPresentation: .connected,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        rejected.requestReplacement()
        rejected.confirmReplacement()
        try await reachPinnedTarget(rejected)
        await rejected.rejectPinnedTarget()
        XCTAssertEqual(rejected.connectionPresentation, .connected)

        let failed = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: current, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0, rejection: .audienceMismatch), trust: fixture.trust),
            profile: fixture.profile,
            initialConnectionPresentation: .connectionFailed,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        failed.requestReplacement()
        failed.confirmReplacement()
        try await reachPinnedTarget(failed)
        await failed.approvePinnedTarget()
        XCTAssertEqual(failed.connectionPresentation, .failed)
        failed.resetAfterFailure()
        XCTAssertEqual(failed.connectionPresentation, .connectionFailed)
    }

    // A replacement that installs retires the old Node, so nothing restores.
    func testInstalledReplacementNeverRestoresTheReplacedNodePresentation() async throws {
        let fixture = try UIEnrollmentFixture()
        let current = try AccountDeviceID("90000000-0000-4000-8000-000000000099")
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: current, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0), trust: fixture.trust),
            profile: fixture.profile,
            initialConnectionPresentation: .recoveryRequired,
            nonceGenerator: { Data(repeating: 4, count: 32) },
            verifyConnection: { throw AccountRuntimeError.transportFailure }
        )
        model.requestReplacement()
        model.confirmReplacement()
        try await reachPinnedTarget(model)
        await model.approvePinnedTarget()
        guard case .installed = model.state else { return XCTFail("expected installed, got \(model.state)") }
        XCTAssertEqual(model.activeNodeID, fixture.claim.nodeDeviceID)
        XCTAssertEqual(model.connectionPresentation, .connectionFailed)
        await model.viewDidDisappear()
        model.cancelReplacement()
        XCTAssertEqual(model.connectionPresentation, .connectionFailed)
    }

    // The Sync Node page is the only Sync Node surface: it composes the shared enrollment
    // flow and never shows the node ID.
    func testSyncNodeSettingsPageComposesTheSharedEnrollmentFlow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/PlainpostUI/SyncNodeSettingsPage.swift"), encoding: .utf8)
        for required in [
            "session.presentableSyncNodeEnrollmentModel",
            "session.syncNodeEnrollmentAwaitsOwner",
            "SyncNodeOverviewSection(overview: SyncNodeOverview(.init(awaitsOwner: true)))",
            "SyncNodeStatusSection(model: nodeSettings)",
            "SyncNodeEraseSection(model: nodeSettings)",
            "SyncNodeEnrollmentView(model: enrollment, placement: .connectStep)",
            "SyncNodeEnrollmentView(model: enrollment, placement: .replacement)",
            "SyncNodeServerSetupStep(",
            ".syncNodeEnrollmentLifecycle(session.presentableSyncNodeEnrollmentModel)",
            "session.handleSyncNodeBootstrapFileImporter",
            "session.updateSyncNodeServerOrigin",
            "session.retrySyncNodeEnrollment()",
            "await session.prepareCalendarAuthority()",
            #"Button("Verify Fingerprint…")"#,
            #"Button("Change Server Address…")"#,
            #"Button("Replace Server Setup…")"#,
            ".textSelection(.enabled)",
        ] {
            XCTAssertTrue(page.contains(required), "SyncNodeSettingsPage lacks \(required)")
        }
        for removed in ["Current Sync Node", "activeNodeID.rawValue", "nodeID.rawValue", "Private Node health"] {
            XCTAssertFalse(page.contains(removed), "SyncNodeSettingsPage still shows \(removed)")
        }
        let security = try String(contentsOf: root.appendingPathComponent("Sources/PlainpostUI/AccountSecuritySettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(security.contains("SyncNodeEnrollment"), "the Plainpost Account page has no Sync Node group")
    }

    func testRetryVerificationKeepsCommittedAdmissionThenInstallsWithSameReplay() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0)
        let trust = UIEnrollmentTrust(commit: fixture.trustCommit, acceptanceFailures: 1)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        try await reachPinnedTarget(model)
        await model.approvePinnedTarget()

        XCTAssertEqual(model.state, .commitVerificationFailed(.trustAcceptance))
        XCTAssertEqual(model.connectionPresentation, .connecting)
        XCTAssertTrue(model.canRetryCommitVerification)
        XCTAssertTrue(model.retainsInstallationReplay)
        XCTAssertTrue(model.showsKeepOpenGuidance)
        XCTAssertEqual(model.presentedFailureMessage, SyncNodeEnrollmentViewModel.verificationFailureMessage)
        XCTAssertFalse(model.canBeginConnect)

        await model.cancel()
        model.resetAfterFailure()
        await model.viewDidDisappear()
        XCTAssertEqual(model.state, .commitVerificationFailed(.trustAcceptance))
        XCTAssertEqual(model.connectionPresentation, .connecting)

        await model.retryCommitVerification()

        guard case .installed = model.state else { return XCTFail("expected Retry Verification to install") }
        XCTAssertEqual(model.connectionPresentation, .connected)
        XCTAssertFalse(model.canRetryCommitVerification)
        XCTAssertFalse(model.showsKeepOpenGuidance)
        XCTAssertNil(model.presentedFailureMessage)
        let requests = await remote.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].idempotencyKey, requests[0].idempotencyKey)
        XCTAssertEqual(requests[1].trustCommit, requests[0].trustCommit)
    }

    // The uncertain state can outlast every retry when nothing committed, so
    // it must tell the user to keep Plainpost open and what to do next, and it
    // must not present as a failure with Retry or Continue with Apple.
    func testUncertainCommitTellsUserToKeepPlainpostOpenWithoutFailureCopy() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 1)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        try await reachPinnedTarget(model)
        await model.approvePinnedTarget()

        XCTAssertEqual(model.state, .commitResponseUncertain)
        XCTAssertEqual(model.connectionPresentation, .connecting)
        XCTAssertTrue(model.canRetryCommit)
        XCTAssertFalse(model.canRetryCommitVerification)
        XCTAssertTrue(model.showsKeepOpenGuidance)
        XCTAssertNil(model.presentedFailureMessage)
        XCTAssertFalse(model.canBeginConnect)
        XCTAssertTrue(model.canStopAndStartOver)
        XCTAssertEqual(model.retainedAdmissionGuidance, "\(SyncNodeEnrollmentViewModel.keepOpenMessage) If retrying keeps failing, choose Stop and Start Over.")
        XCTAssertTrue(model.retainedAdmissionGuidance?.hasPrefix(SyncNodeEnrollmentViewModel.keepOpenMessage) == true)
    }

    // Each retained state gets guidance that is true for it: only an uncertain
    // commit Central never answered 2xx points to Stop and Start Over, and a
    // verification failure never suggests quitting or starting over.
    func testRetainedAdmissionGuidanceMatchesWhatIsSafeInEachState() async throws {
        #if os(macOS)
        XCTAssertEqual(SyncNodeEnrollmentViewModel.keepOpenMessage, "Keep Plainpost open while this finishes.")
        #endif
        XCTAssertEqual(SyncNodeEnrollmentViewModel.quittingLosesApprovalGuidance, "The server may have finished this step. Choose Retry Installation to check.")
        let fixture = try UIEnrollmentFixture()

        let verification = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0), trust: UIEnrollmentTrust(commit: fixture.trustCommit, acceptanceFailures: 1)),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        try await reachPinnedTarget(verification)
        await verification.approvePinnedTarget()
        XCTAssertEqual(verification.state, .commitVerificationFailed(.trustAcceptance))
        XCTAssertEqual(verification.retainedAdmissionGuidance, SyncNodeEnrollmentViewModel.keepOpenMessage)
        XCTAssertFalse(verification.canStopAndStartOver)

        let observed = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0, rejection: .undecodableSuccess), trust: fixture.trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        try await reachPinnedTarget(observed)
        await observed.approvePinnedTarget()
        XCTAssertEqual(observed.state, .commitResponseUncertain)
        XCTAssertFalse(observed.canStopAndStartOver)
        XCTAssertEqual(observed.retainedAdmissionGuidance, "\(SyncNodeEnrollmentViewModel.keepOpenMessage) \(SyncNodeEnrollmentViewModel.quittingLosesApprovalGuidance)")

        let activation = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0), trust: fixture.trust, activation: UIScriptedEnrollmentActivator(uncertainActivations: 1)),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        try await reachPinnedTarget(activation)
        await activation.approvePinnedTarget()
        XCTAssertEqual(activation.state, .activationResponseUncertain)
        XCTAssertFalse(activation.canStopAndStartOver)
        XCTAssertEqual(activation.retainedAdmissionGuidance, SyncNodeEnrollmentViewModel.activationResumesGuidance)
        for guidance in [SyncNodeEnrollmentViewModel.keepOpenMessage, SyncNodeEnrollmentViewModel.activationResumesGuidance, SyncNodeEnrollmentViewModel.stopAndStartOverGuidance] {
            XCTAssertFalse(guidance.contains("quit Plainpost and"), guidance)
        }
    }

    // Stop and Start Over returns to Connect only after Central proves the
    // claim was never consumed; otherwise the admission stays for Retry.
    func testStopAndStartOverReturnsToConnectOnlyAfterProvenCancellation() async throws {
        let fixture = try UIEnrollmentFixture()
        let refused = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 1, cancelFailure: AccountRuntimeError.untrustedResponse)
        let retained = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: refused, trust: fixture.trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        try await reachPinnedTarget(retained)
        await retained.approvePinnedTarget()
        XCTAssertEqual(retained.state, .commitResponseUncertain)

        await retained.stopAndStartOver()

        XCTAssertEqual(retained.state, .commitResponseUncertain)
        XCTAssertTrue(retained.retainsInstallationReplay)
        XCTAssertTrue(retained.canRetryCommit)
        XCTAssertFalse(retained.canBeginConnect)
        XCTAssertFalse(retained.isStoppingAndStartingOver)
        XCTAssertEqual(retained.startOverFailureMessage, SyncNodeEnrollmentViewModel.startOverUnconfirmedMessage)
        // A refused cancel (404 or 5xx alike) proves nothing, so the copy must
        // not send the user back to Stop and Start Over.
        let refusedCopy = [retained.retainedAdmissionGuidance, retained.startOverFailureMessage].compactMap { $0 }
        XCTAssertEqual(retained.retainedAdmissionGuidance, SyncNodeEnrollmentViewModel.keepOpenMessage)
        XCTAssertFalse(refusedCopy.contains { $0.contains("Stop and Start Over") }, "\(refusedCopy)")
        XCTAssertTrue(SyncNodeEnrollmentViewModel.startOverUnconfirmedMessage.contains("may have gone through"))
        XCTAssertTrue(SyncNodeEnrollmentViewModel.startOverUnconfirmedMessage.contains("Retry Installation"))
        XCTAssertTrue(retained.canStopAndStartOver, "the proof may still succeed later, so the action stays available")
        await retained.retryCommit()
        guard case .installed = retained.state else { return XCTFail("expected the retained request to install") }
        XCTAssertNil(retained.startOverFailureMessage)

        let accepted = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 1)
        let clock = UIEnrollmentClock(fixture.presentation.expiresAt.addingTimeInterval(SyncNodeEnrollmentViewModel.reconnectClockSkewGrace))
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: accepted, trust: UIEnrollmentTrust(commit: fixture.trustCommit)),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) },
            clock: { clock.now }
        )
        try await reachPinnedTarget(model)
        await model.approvePinnedTarget()

        await model.stopAndStartOver()

        XCTAssertEqual(model.state, .enterCode)
        XCTAssertEqual(model.connectionPresentation, .ready)
        XCTAssertFalse(model.retainsInstallationReplay)
        XCTAssertFalse(model.showsKeepOpenGuidance)
        XCTAssertNil(model.startOverFailureMessage)
        XCTAssertTrue(model.canBeginConnect, "the clock is at the cancelled claim's expiry plus the skew grace")
        let cancels = await accepted.cancelCount()
        XCTAssertEqual(cancels, 1)
    }

    // After a proven Stop and Start Over the Node keeps presenting the claim
    // Central just cancelled, so Connect is certain to fail until it expires.
    // Connect stays disabled with a countdown that follows the clock, until
    // a 5-second clock-skew grace after the claim's expiry.
    func testSuccessfulStopDisablesConnectUntilTheCancelledClaimExpires() async throws {
        let fixture = try UIEnrollmentFixture()
        let expiry = fixture.presentation.expiresAt
        XCTAssertEqual(SyncNodeEnrollmentViewModel.reconnectClockSkewGrace, 5)
        let opensAt = expiry.addingTimeInterval(5)
        let clock = UIEnrollmentClock(opensAt.addingTimeInterval(-240))
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 1)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) },
            clock: { clock.now }
        )
        XCTAssertNil(model.reconnectWaitMessage)
        try await reachPinnedTarget(model)
        await model.approvePinnedTarget()
        XCTAssertEqual(model.state, .commitResponseUncertain)
        XCTAssertNil(model.reconnectWaitMessage)

        await model.stopAndStartOver()

        XCTAssertEqual(model.state, .enterCode)
        XCTAssertEqual(model.connectionPresentation, .ready)
        XCTAssertFalse(model.canBeginConnect)
        XCTAssertThrowsError(try model.beginConnectAppleAuthorization())
        XCTAssertEqual(model.connectionPresentation, .ready)
        XCTAssertEqual(model.reconnectWaitMessage, "You can connect again in about 4 minutes.")

        clock.now = opensAt.addingTimeInterval(-61)
        model.refreshReconnectAvailability()
        XCTAssertEqual(model.reconnectWaitMessage, "You can connect again in about 2 minutes.")
        XCTAssertFalse(model.canBeginConnect)

        clock.now = expiry
        model.refreshReconnectAvailability()
        XCTAssertEqual(model.reconnectWaitMessage, "You can connect again in about 1 minute.", "the countdown includes the grace")
        XCTAssertFalse(model.canBeginConnect, "the claim's expiry alone doesn't open Connect")

        clock.now = opensAt.addingTimeInterval(-0.5)
        model.refreshReconnectAvailability()
        XCTAssertEqual(model.reconnectWaitMessage, "You can connect again in about 1 minute.")
        XCTAssertFalse(model.canBeginConnect)
        XCTAssertThrowsError(try model.beginConnectAppleAuthorization())

        clock.now = opensAt
        XCTAssertTrue(model.canBeginConnect, "Connect follows the clock even before a refresh")
        model.refreshReconnectAvailability()
        XCTAssertNil(model.reconnectWaitMessage)
        _ = try model.beginConnectAppleAuthorization()
        XCTAssertEqual(model.connectionPresentation, .authorizing)
    }

    // The matching screen's Cancel cancels the claim the same way, while a
    // cancel Central didn't confirm leaves the claim live and Connect enabled.
    func testMatchingScreenCancelWaitsForTheCancelledClaimToExpire() async throws {
        let fixture = try UIEnrollmentFixture()
        let expiry = fixture.presentation.expiresAt
        let clock = UIEnrollmentClock(expiry.addingTimeInterval(-90))
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture), trust: fixture.trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) },
            clock: { clock.now }
        )
        try await reachPinnedTarget(model)

        await model.rejectPinnedTarget()

        XCTAssertEqual(model.state, .enterCode)
        XCTAssertFalse(model.canBeginConnect)
        XCTAssertEqual(model.reconnectWaitMessage, "You can connect again in about 2 minutes.")
        clock.now = expiry.addingTimeInterval(4)
        model.refreshReconnectAvailability()
        XCTAssertFalse(model.canBeginConnect, "inside the clock-skew grace")
        XCTAssertNotNil(model.reconnectWaitMessage)
        clock.now = expiry.addingTimeInterval(5)
        model.refreshReconnectAvailability()
        XCTAssertNil(model.reconnectWaitMessage)
        XCTAssertTrue(model.canBeginConnect)

        let unconfirmed = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: UIResponseLossEnrollmentRemote(fixture: fixture, cancelFailure: AccountRuntimeError.transportFailure), trust: fixture.trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) },
            clock: { expiry.addingTimeInterval(-90) }
        )
        try await reachPinnedTarget(unconfirmed)
        await unconfirmed.rejectPinnedTarget()
        XCTAssertNil(unconfirmed.reconnectWaitMessage)
        XCTAssertTrue(unconfirmed.canBeginConnect)
    }

    func testOutdatedAndMismatchedServerSetupSayWhereToImportANewOne() {
        #if os(macOS)
        XCTAssertEqual(SyncNodeEnrollmentViewModel.serverSetupImportHint, "Then choose Replace Server Setup on this page to import it.")
        #endif
    }

    // The page overview carries the shared enrollment copy and every retry; the enrollment
    // view keeps the Apple steps and Replace Sync Node.
    func testSyncNodeEnrollmentViewRendersSharedCopyAndRetryVerification() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let source = try read("Sources/PlainpostUI/SyncNodeEnrollmentViews.swift")
        let view = String(source[try XCTUnwrap(source.range(of: "public struct SyncNodeEnrollmentView: View")).lowerBound...])
        let overview = try read("Sources/PlainpostUI/Settings/SyncNodeOverview.swift")
        let page = try read("Sources/PlainpostUI/SyncNodeSettingsPage.swift")
        let setup = try read("Sources/PlainpostUI/SyncNodeBootstrapImportView.swift")
        let sources: [(String, String, [String])] = [
            ("SyncNodeOverview", overview, [
                "model.presentedFailureMessage",
                "model.retainedAdmissionGuidance",
                "model.canStopAndStartOver",
                "SyncNodeEnrollmentViewModel.serverSetupImportHint",
                "SyncNodeEnrollmentViewModel.commitUncertainMessage",
                "SyncNodeEnrollmentViewModel.activationUncertainMessage",
                "this device isn’t connected to it",
                #""sync-node-retry-verification""#,
                #""sync-node-stop-and-start-over""#,
                #""sync-node-retry-installation""#,
                #""sync-node-retry-activation""#,
                #""sync-node-start-over""#,
                #""sync-node-retry""#,
                #""sync-node-retry-connection""#,
            ]),
            ("SyncNodeSettingsPage", page, [
                "await enrollment.retryCommitVerification()",
                "await enrollment.stopAndStartOver()",
                "await enrollment.retryCommit()",
                "await enrollment.retryActivation()",
                "enrollment?.resetAfterFailure()",
                ".accessibilityIdentifier(action.accessibilityIdentifier)",
                ".disabled(overview.actionsDisabled)",
            ]),
            ("SyncNodeEnrollmentView", view, [
                "model.isReplacementConfirmationVisible { model.cancelReplacement() }",
                "model.reconnectWaitMessage",
                "next?.refreshReconnectAvailability()",
                "await current.viewDidDisappear()",
            ]),
            ("SyncNodeServerSetupStep", setup, [
                #"Button("Verify Fingerprint…")"#,
                "AccountSecurityPresentation.host(origin)",
            ]),
        ]
        for (name, text, required) in sources {
            for token in required {
                XCTAssertTrue(text.contains(token), "\(name) lacks \(token)")
            }
            for removed in ["Current Sync Node", "nodeID.rawValue", #"LabeledContent("Node""#] {
                XCTAssertFalse(text.contains(removed), "\(name) still shows \(removed)")
            }
        }
        XCTAssertFalse(view.contains("this Mac") || overview.contains("this Mac"), "shared view copy must say this device")
    }

    // A server mismatch is pre-commit: its Retry is a real start over that
    // returns to Continue with Apple, never a no-op.
    func testServerAudienceMismatchRetryStartsOver() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0, rejection: .audienceMismatch)
        let clock = UIEnrollmentClock(Date())
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) },
            clock: { clock.now }
        )
        try await reachPinnedTarget(model)
        await model.approvePinnedTarget()

        XCTAssertEqual(model.state, .serverAudienceMismatch)
        XCTAssertEqual(model.connectionPresentation, .failed)
        XCTAssertEqual(model.presentedFailureMessage, SyncNodeEnrollmentViewModel.serverMismatchMessage)
        XCTAssertFalse(model.retainsInstallationReplay)
        XCTAssertFalse(model.showsKeepOpenGuidance)
        XCTAssertFalse(model.canBeginConnect)

        model.resetAfterFailure()

        XCTAssertEqual(model.state, .enterCode)
        XCTAssertEqual(model.connectionPresentation, .ready)
        XCTAssertNil(model.presentedFailureMessage)
        // The rejection cancelled the claim, which the Node keeps presenting.
        XCTAssertFalse(model.canBeginConnect)
        XCTAssertNotNil(model.reconnectWaitMessage)
        clock.now = fixture.presentation.expiresAt
        XCTAssertFalse(model.canBeginConnect, "inside the clock-skew grace")
        clock.now = fixture.presentation.expiresAt.addingTimeInterval(SyncNodeEnrollmentViewModel.reconnectClockSkewGrace)
        XCTAssertTrue(model.canBeginConnect)
    }

    func testResetAfterFailureLeavesProfileOutdatedCoordinatorState() async throws {
        let fixture = try UIEnrollmentFixture()
        let coordinator = fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation))
        let model = SyncNodeEnrollmentViewModel(coordinator: coordinator, profile: fixture.profile)
        let legacy = try SyncNodeBootstrapProfile(canonicalOrigin: fixture.profile.canonicalOrigin, nodeDeviceID: fixture.profile.nodeDeviceID, signingKeyDigest: fixture.profile.signingKeyDigest, capabilityID: fixture.profile.capabilityID, capability: fixture.profile.capability, centralAudience: nil)
        await coordinator.begin(profile: legacy, appleAuthorization: try SyncNodeEnrollmentAppleAuthorization(identityToken: "apple-token", nonce: Data(repeating: 4, count: 32)))
        XCTAssertEqual(model.state, .profileOutdated)

        model.resetAfterFailure()

        XCTAssertEqual(model.state, .enterCode)
        XCTAssertEqual(model.connectionPresentation, .ready)
    }

    private func reachPinnedTarget(_ model: SyncNodeEnrollmentViewModel) async throws {
        let attempt = try model.beginConnectAppleAuthorization()
        model.submitAppleIdentityToken(Data("apple-token".utf8), for: attempt.id)
        // A deadline, not a yield count: under full-suite load the
        // coordinator's tasks can need far more than 200 scheduler turns.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if case .matchingStringConfirmation = model.state, model.connectionPresentation == .ready { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("pinned target confirmation did not appear")
    }
}

@MainActor
final class AccountSessionSyncNodeEnrollmentLifecycleTests: XCTestCase {
    func testSameAccountPrepareAndCancelRetainExactUncertainReplay() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture)
        let replayModel = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            owner: fixture.owner,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { replayModel },
            syncNodeEnrollmentOwnerReader: { fixture.owner }
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel === replayModel }
        try await reachUncertainCommit(replayModel)
        let initialRequests = await remote.requests()
        let first = try XCTUnwrap(initialRequests.first)

        account.prepare()
        account.cancel()
        XCTAssertTrue(account.syncNodeEnrollmentModel === replayModel)
        XCTAssertEqual(replayModel.state, .commitResponseUncertain)

        await replayModel.retryCommit()

        guard case .installed = replayModel.state else { return XCTFail("expected exact replay to install") }
        let requests = await remote.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].evidence, first.evidence)
        XCTAssertEqual(requests[1].claimProofSignature, first.claimProofSignature)
        XCTAssertEqual(requests[1].matchingConfirmationSignature, first.matchingConfirmationSignature)
        XCTAssertEqual(requests[1].admissionApprovalSignature, first.admissionApprovalSignature)
        XCTAssertEqual(requests[1].idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(requests[1].trustCommit, first.trustCommit)
    }

    // Every state holding the only in-memory replay survives a session refresh
    // and a Server Setup change. The new profile is published only after the
    // retained admission converges with the exact same request.
    func testSessionRefreshAndProfileChangeKeepEveryRetainedAdmission() async throws {
        let fixture = try UIEnrollmentFixture()
        for verificationFails in [false, true] {
            let remote = UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: verificationFails ? 0 : 1)
            let trust = UIEnrollmentTrust(commit: fixture.trustCommit, acceptanceFailures: verificationFails ? 1 : 0)
            let model = SyncNodeEnrollmentViewModel(
                coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: trust),
                profile: fixture.profile,
                owner: fixture.owner,
                nonceGenerator: { Data(repeating: 4, count: 32) }
            )
            let replacementProfile = try fixture.profile(capabilityByte: 18, nodeSuffix: "18")
            let replacementModel = SyncNodeEnrollmentViewModel(
                coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
                profile: replacementProfile,
                owner: fixture.owner
            )
            let importModel = SyncNodeBootstrapImportViewModel(store: UIEnrollmentProfileStore(profile: fixture.profile))
            let sequence = EnrollmentFactorySequence(models: [model, replacementModel])
            let refreshes = SessionRefreshCounter()
            let account = AccountSessionViewModel(
                prepareSession: { _ in refreshes.record(); return .active },
                syncNodeEnrollmentFactory: { try await sequence.make() },
                syncNodeEnrollmentOwnerReader: { fixture.owner },
                syncNodeBootstrapImportModel: importModel,
                automaticallyPrepareSyncNodeOnActive: true
            )
            await activate(account)
            await waitUntil { account.syncNodeEnrollmentModel === model }
            let expected: SyncNodeEnrollmentCoordinator.State = verificationFails ? .commitVerificationFailed(.trustAcceptance) : .commitResponseUncertain
            try await reachUncertainCommit(model, expecting: expected)

            account.prepare()
            await waitUntil { refreshes.count == 2 }
            for _ in 0 ..< 20 { await Task.yield() }
            XCTAssertTrue(account.syncNodeEnrollmentModel === model, "session refresh dropped \(expected)")
            XCTAssertEqual(model.state, expected)

            importModel.fileAccess = fileAccess(document: try replacementProfile.encodedForStorage())
            account.importSyncNodeBootstrapProfile(from: URL(fileURLWithPath: "/protected/retained-replacement.plainpostserver"))
            for _ in 0 ..< 20 { await Task.yield() }
            XCTAssertTrue(account.syncNodeEnrollmentModel === model, "profile change dropped \(expected)")
            XCTAssertEqual(model.state, expected)

            if verificationFails { await model.retryCommitVerification() } else { await model.retryCommit() }

            // Convergence publishes the new profile and retires this model.
            XCTAssertEqual(model.connectionPresentation, .connected, "expected \(expected) to install")
            await waitUntil { account.syncNodeEnrollmentModel === replacementModel }
            let requests = await remote.requests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[1].idempotencyKey, requests[0].idempotencyKey)
            XCTAssertEqual(requests[1].trustCommit, requests[0].trustCommit)
        }
    }

    func testNewProfileImportedDuringReplayIsPublishedAfterOldReplayConverges() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture)
        let firstModel = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            owner: fixture.owner,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let replacementProfile = try fixture.profile(capabilityByte: 17, nodeSuffix: "17")
        let replacementModel = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
            profile: replacementProfile,
            owner: fixture.owner
        )
        let store = UIEnrollmentProfileStore(profile: fixture.profile)
        let importModel = SyncNodeBootstrapImportViewModel(store: store)
        let sequence = EnrollmentFactorySequence(models: [firstModel, replacementModel])
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await sequence.make() },
            syncNodeEnrollmentOwnerReader: { fixture.owner },
            syncNodeBootstrapImportModel: importModel
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel === firstModel }
        try await reachUncertainCommit(firstModel)

        importModel.fileAccess = fileAccess(document: try replacementProfile.encodedForStorage())
        account.importSyncNodeBootstrapProfile(from: URL(fileURLWithPath: "/protected/new-replacement.plainpostserver"))
        XCTAssertTrue(account.syncNodeEnrollmentModel === firstModel)

        await firstModel.retryCommit()
        await waitUntil { account.syncNodeEnrollmentModel === replacementModel }

        XCTAssertEqual(try importModel.loadProfile(), replacementProfile)
        XCTAssertTrue(replacementModel.canReplaceNode)
        XCTAssertEqual(replacementModel.targetOrigin, replacementProfile.canonicalOrigin.url.absoluteString)
        let callCount = await sequence.count()
        XCTAssertEqual(callCount, 2)
    }

    // A Server Setup imported while an uncertain commit was retained is
    // published as soon as Stop and Start Over proves nothing committed.
    func testStopAndStartOverPublishesServerSetupImportedWhileRetained() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture)
        let firstModel = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            owner: fixture.owner,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let replacementProfile = try fixture.profile(capabilityByte: 19, nodeSuffix: "19")
        let replacementModel = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: replacementProfile, owner: fixture.owner)
        let importModel = SyncNodeBootstrapImportViewModel(store: UIEnrollmentProfileStore(profile: fixture.profile))
        let sequence = EnrollmentFactorySequence(models: [firstModel, replacementModel])
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await sequence.make() },
            syncNodeEnrollmentOwnerReader: { fixture.owner },
            syncNodeBootstrapImportModel: importModel
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel === firstModel }
        try await reachUncertainCommit(firstModel)

        importModel.fileAccess = fileAccess(document: try replacementProfile.encodedForStorage())
        account.importSyncNodeBootstrapProfile(from: URL(fileURLWithPath: "/protected/start-over.plainpostserver"))
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertTrue(account.syncNodeEnrollmentModel === firstModel)

        await firstModel.stopAndStartOver()
        await waitUntil { account.syncNodeEnrollmentModel === replacementModel }

        XCTAssertEqual(replacementModel.targetOrigin, replacementProfile.canonicalOrigin.url.absoluteString)
        let requests = await remote.requests()
        let cancels = await remote.cancelCount()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(cancels, 1)
    }

    // Only a positively different owner may drop a retained admission. A
    // session that reads as not active, or a Keychain read error, keeps it.
    func testUnknownOwnerKeepsRetainedAdmission() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            owner: fixture.owner,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let reader = EnrollmentOwnerReaderScript(fixture.owner)
        let sequence = EnrollmentFactorySequence(models: [model])
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await sequence.make() },
            syncNodeEnrollmentOwnerReader: { try reader.read() },
            automaticallyPrepareSyncNodeOnActive: true
        )
        await activate(account)
        await waitUntil { account.syncNodeEnrollmentModel === model }
        try await reachUncertainCommit(model)

        for outcome in [EnrollmentOwnerReaderScript.Outcome.none, .failure] {
            reader.outcome = outcome
            account.prepare()
            for _ in 0 ..< 20 { await Task.yield() }
            XCTAssertTrue(account.syncNodeEnrollmentModel === model, "\(outcome) dropped the retained admission")
            XCTAssertEqual(model.state, .commitResponseUncertain)
        }

        reader.outcome = .owner(fixture.owner)
        await model.retryCommit()
        guard case .installed = model.state else { return XCTFail("expected the retained request to install") }
        let requests = await remote.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].idempotencyKey, requests[0].idempotencyKey)
    }

    // A retained admission stays in memory after sign-out, but its server,
    // Node fingerprint and actions render only while its owner's session is
    // the active one.
    func testRetainedAdmissionIsPresentableOnlyForItsOwnersActiveSession() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            owner: fixture.owner,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let reader = EnrollmentOwnerReaderScript(fixture.owner)
        let session = SessionStateScript(.active)
        let account = AccountSessionViewModel(
            prepareSession: { _ in session.state },
            syncNodeEnrollmentFactory: { model },
            syncNodeEnrollmentOwnerReader: { try reader.read() },
            automaticallyPrepareSyncNodeOnActive: true
        )
        await activate(account)
        await waitUntil { account.syncNodeEnrollmentModel === model }
        try await reachUncertainCommit(model)
        XCTAssertTrue(account.presentableSyncNodeEnrollmentModel === model)
        XCTAssertFalse(account.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(AccountSessionViewModel.syncNodeEnrollmentOwnerRequiredMessage, "Finish this Sync Node connection when the account that started it is signed in and active.")

        // Signed out: the Keychain has no active session.
        reader.outcome = .none
        session.state = .signInRequired
        account.prepare()
        await waitUntil { account.presentation == .signInRequired }
        XCTAssertTrue(account.syncNodeEnrollmentModel === model, "the exact replay stays in memory")
        XCTAssertNil(account.presentableSyncNodeEnrollmentModel)
        XCTAssertTrue(account.syncNodeEnrollmentAwaitsOwner)

        // Neither an owner read without an active presentation, nor an active
        // presentation whose owner can't be read, renders the model.
        reader.outcome = .owner(fixture.owner)
        XCTAssertNil(account.presentableSyncNodeEnrollmentModel)
        reader.outcome = .failure
        session.state = .active
        account.prepare()
        await waitUntil { account.presentation == .active }
        XCTAssertTrue(account.syncNodeEnrollmentModel === model)
        XCTAssertNil(account.presentableSyncNodeEnrollmentModel)
        reader.outcome = .none
        XCTAssertNil(account.presentableSyncNodeEnrollmentModel)

        // The owner signs back in and finishes with the exact request.
        reader.outcome = .owner(fixture.owner)
        account.prepare()
        await waitUntil { account.presentation == .active && account.presentableSyncNodeEnrollmentModel === model }
        XCTAssertFalse(account.syncNodeEnrollmentAwaitsOwner)
        await model.retryCommit()
        guard case .installed = model.state else { return XCTFail("expected the retained request to install") }
        let requests = await remote.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].idempotencyKey, requests[0].idempotencyKey)
    }

    // The owner is read when the presentation or the model changes, never
    // while a view asks what to render: in production each read is a
    // Keychain read that can finish an activation journal.
    func testRenderingAccessorsNeverReadTheOwner() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture)
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            owner: fixture.owner,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let reader = EnrollmentOwnerReaderScript(fixture.owner)
        let session = SessionStateScript(.active)
        let account = AccountSessionViewModel(
            prepareSession: { _ in session.state },
            syncNodeEnrollmentFactory: { model },
            syncNodeEnrollmentOwnerReader: { try reader.read() },
            automaticallyPrepareSyncNodeOnActive: true
        )
        await activate(account)
        await waitUntil { account.syncNodeEnrollmentModel === model }
        try await reachUncertainCommit(model)

        func renderRepeatedly() -> Int {
            let before = reader.reads
            for _ in 0 ..< 20 {
                _ = account.presentableSyncNodeEnrollmentModel
                _ = account.syncNodeEnrollmentAwaitsOwner
            }
            return reader.reads - before
        }
        XCTAssertTrue(account.presentableSyncNodeEnrollmentModel === model)
        XCTAssertEqual(renderRepeatedly(), 0)

        // A change in the Keychain alone isn't observed until the session
        // state is applied again.
        reader.outcome = .failure
        XCTAssertTrue(account.presentableSyncNodeEnrollmentModel === model)
        XCTAssertEqual(renderRepeatedly(), 0)
        account.prepare()
        await waitUntil { account.presentableSyncNodeEnrollmentModel == nil }
        XCTAssertTrue(account.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(renderRepeatedly(), 0)

        // The owner signed in but not active reads the neutral copy, which
        // doesn't ask them to sign in again.
        reader.outcome = .owner(fixture.owner)
        session.state = .suspended
        account.prepare()
        await waitUntil { account.presentation == .suspended }
        XCTAssertTrue(account.syncNodeEnrollmentModel === model)
        XCTAssertTrue(account.syncNodeEnrollmentAwaitsOwner)
        XCTAssertFalse(AccountSessionViewModel.syncNodeEnrollmentOwnerRequiredMessage.hasPrefix("Sign in"))
        XCTAssertEqual(renderRepeatedly(), 0)

        session.state = .active
        account.prepare()
        await waitUntil { account.presentableSyncNodeEnrollmentModel === model }
        XCTAssertFalse(account.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(renderRepeatedly(), 0)
    }

    func testActiveAccountReplacementNeverExposesOrRetriesPriorOwnerReplay() async throws {
        let fixture = try UIEnrollmentFixture()
        let remote = UIResponseLossEnrollmentRemote(fixture: fixture)
        let priorModel = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: fixture.trust),
            profile: fixture.profile,
            owner: fixture.owner,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let replacementOwner = SyncNodeEnrollmentOwner(
            accountID: try PlainpostAccountID("91000000-0000-4000-8000-000000000001"),
            deviceID: try AccountDeviceID("91000000-0000-4000-8000-000000000002")
        )
        let replacementModel = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
            profile: nil,
            owner: replacementOwner,
            initialConnectionPresentation: .connected
        )
        let owner = EnrollmentOwnerBox(fixture.owner)
        let sequence = EnrollmentFactorySequence(models: [priorModel, replacementModel])
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await sequence.make() },
            syncNodeEnrollmentOwnerReader: { owner.value },
            automaticallyPrepareSyncNodeOnActive: true
        )
        await activate(account)
        await waitUntil { account.syncNodeEnrollmentModel === priorModel }
        try await reachUncertainCommit(priorModel)

        owner.value = replacementOwner
        account.prepare()
        await waitUntil { account.syncNodeEnrollmentModel === replacementModel }

        XCTAssertFalse(account.syncNodeEnrollmentModel === priorModel)
        XCTAssertEqual(priorModel.state, .commitResponseUncertain)
        let requestCount = await remote.requests().count
        let factoryCount = await sequence.count()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(factoryCount, 2)
    }

    func testNewImportDuringSuspendedFactoryPublishesOnlyNewGeneration() async throws {
        let fixture = try UIEnrollmentFixture()
        let firstModel = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: fixture.profile)
        let secondProfile = try fixture.profile(capabilityByte: 12, nodeSuffix: "12")
        let secondModel = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: secondProfile)
        let store = UIEnrollmentProfileStore(profile: fixture.profile)
        let importModel = SyncNodeBootstrapImportViewModel(store: store)
        let gate = SuspendedEnrollmentFactory(first: firstModel, later: secondModel)
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await gate.make() },
            syncNodeBootstrapImportModel: importModel
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await gate.waitUntilFirstStarts()

        importModel.fileAccess = fileAccess(document: try secondProfile.encodedForStorage())
        account.importSyncNodeBootstrapProfile(from: URL(fileURLWithPath: "/protected/new.plainpostserver"))
        await waitUntil { account.syncNodeEnrollmentModel === secondModel }
        await gate.releaseFirst()
        for _ in 0 ..< 20 { await Task.yield() }

        XCTAssertTrue(account.syncNodeEnrollmentModel === secondModel)
        XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, .ready)
        let callCount = await gate.count()
        XCTAssertEqual(callCount, 2)
    }

    func testNewImportReplacesAlreadyReadyEnrollmentModel() async throws {
        let fixture = try UIEnrollmentFixture()
        let firstModel = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: fixture.profile)
        let secondProfile = try fixture.profile(capabilityByte: 13, nodeSuffix: "13")
        let secondModel = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: secondProfile)
        let store = UIEnrollmentProfileStore(profile: fixture.profile)
        let importModel = SyncNodeBootstrapImportViewModel(store: store)
        let sequence = EnrollmentFactorySequence(models: [firstModel, secondModel])
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await sequence.make() },
            syncNodeBootstrapImportModel: importModel
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel === firstModel }

        importModel.fileAccess = fileAccess(document: try secondProfile.encodedForStorage())
        account.importSyncNodeBootstrapProfile(from: URL(fileURLWithPath: "/protected/replacement.plainpostserver"))
        await waitUntil { account.syncNodeEnrollmentModel === secondModel }

        XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, .ready)
        let callCount = await sequence.count()
        XCTAssertEqual(callCount, 2)
    }

    func testNewImportSynchronouslyFencesOldModelSuspendedInProtectedFetch() async throws {
        let fixture = try UIEnrollmentFixture()
        let blocker = BlockingEnrollmentPresenter(presentation: fixture.presentation)
        let remote = EnrollmentSideEffectRemote()
        let local = EnrollmentLocalAuthRecorder()
        let firstModel = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: blocker, remote: remote, localAuthenticator: local),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let secondProfile = try fixture.profile(capabilityByte: 16, nodeSuffix: "16")
        let secondModel = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: secondProfile)
        let store = UIEnrollmentProfileStore(profile: fixture.profile)
        let importModel = SyncNodeBootstrapImportViewModel(store: store)
        let sequence = EnrollmentFactorySequence(models: [firstModel, secondModel])
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await sequence.make() },
            syncNodeBootstrapImportModel: importModel
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel === firstModel }
        let apple = try firstModel.beginConnectAppleAuthorization()
        firstModel.submitAppleIdentityToken(Data("apple-token".utf8), for: apple.id)
        await blocker.waitUntilFetchStarts()

        importModel.fileAccess = fileAccess(document: try secondProfile.encodedForStorage())
        account.importSyncNodeBootstrapProfile(from: URL(fileURLWithPath: "/protected/new-owner.plainpostserver"))
        await waitUntil { account.syncNodeEnrollmentModel === secondModel }
        await blocker.releaseFetch()
        for _ in 0 ..< 20 { await Task.yield() }

        let lookups = await remote.lookupCount()
        let localAuthorizations = await local.count()
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(localAuthorizations, 0)
        XCTAssertEqual(firstModel.state, .enterCode)
        XCTAssertTrue(account.syncNodeEnrollmentModel === secondModel)
    }

    func testOwnedProfileRetirementAllowsFactoryResult() async throws {
        let fixture = try UIEnrollmentFixture()
        let enrollment = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: nil)
        let store = UIEnrollmentProfileStore(profile: fixture.profile)
        let importModel = SyncNodeBootstrapImportViewModel(store: store)
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: {
                try importModel.retireProfile(expectedCapabilityID: fixture.profile.capabilityID)
                return enrollment
            },
            syncNodeBootstrapImportModel: importModel
        )
        await activate(account)

        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel != nil }

        XCTAssertTrue(account.syncNodeEnrollmentModel === enrollment)
        XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, .ready)
        XCTAssertNil(try importModel.loadProfile())
    }

    func testFailedFactoryShowsRetryAndRetryPublishesWithoutDuplicateAttempt() async throws {
        let fixture = try UIEnrollmentFixture()
        let enrollment = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: fixture.profile)
        let sequence = FailingThenEnrollmentFactory(model: enrollment)
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await sequence.make() }
        )
        await activate(account)

        account.prepareSyncNodeEnrollment()
        account.prepareSyncNodeEnrollment()
        await waitUntil {
            if case .failed = account.syncNodeEnrollmentLoadPresentation { return true }
            return false
        }
        let failedCallCount = await sequence.count()
        XCTAssertEqual(failedCallCount, 1)

        account.retrySyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel === enrollment }

        XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, .ready)
        let successfulCallCount = await sequence.count()
        XCTAssertEqual(successfulCallCount, 2)
    }

    // Only the factory's deliberate "no Node and no Server Setup" error means No Sync Node;
    // every other failure is a real one, with a connection-specific message when offline.
    func testFactoryErrorsMapToNoSyncNodeOrAFailure() async throws {
        typealias Load = AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation
        let cases: [(any Error, Load)] = [
            (SyncNodeEnrollmentAssembly.LoadError.noSyncNode, .noSyncNode),
            (AccountRuntimeError.secretUnavailable, .failed(message: Load.failureMessage)),
            (AccountRuntimeError.corruptSecret, .failed(message: Load.failureMessage)),
            (AccountRuntimeError.untrustedResponse, .failed(message: Load.failureMessage)),
            (AccountRuntimeError.transportFailure, .failed(message: Load.unreachableMessage)),
            (URLError(.notConnectedToInternet), .failed(message: Load.unreachableMessage)),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(Load(loadError: error), expected, "\(error)")
            let account = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { throw error }
            )
            await activate(account)
            account.prepareSyncNodeEnrollment()
            await waitUntil { account.syncNodeEnrollmentLoadPresentation == expected }
            XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, expected, "\(error)")
        }
        XCTAssertEqual(Load.unreachableMessage, "Plainpost couldn’t reach its server. Check your connection and try again.")
    }

    // No Sync Node has no Try Again (setup is next); a Server Setup import loads again.
    func testNoSyncNodeIsNotRetriedButAnImportLoadsAgain() async throws {
        let fixture = try UIEnrollmentFixture()
        let enrollment = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: fixture.profile)
        let calls = NoNodeThenEnrollmentFactory(model: enrollment)
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await calls.make() }
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentLoadPresentation == .noSyncNode }

        account.retrySyncNodeEnrollment()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, .noSyncNode)
        let afterRetry = await calls.count()
        XCTAssertEqual(afterRetry, 1)

        // Re-preparing (the page opening again, or an import resetting the load) runs it again.
        account.prepareSyncNodeEnrollment()
        await waitUntil { account.syncNodeEnrollmentModel === enrollment }
        XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, .ready)
    }

    func testAccountGenerationCancellationFencesSuspendedFactoryResult() async throws {
        let fixture = try UIEnrollmentFixture()
        let enrollment = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: fixture.profile)
        let gate = SuspendedEnrollmentFactory(first: enrollment, later: enrollment)
        let account = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await gate.make() }
        )
        await activate(account)
        account.prepareSyncNodeEnrollment()
        await gate.waitUntilFirstStarts()

        account.cancel()
        await gate.releaseFirst()
        for _ in 0 ..< 20 { await Task.yield() }

        XCTAssertNil(account.syncNodeEnrollmentModel)
        XCTAssertEqual(account.syncNodeEnrollmentLoadPresentation, .idle)
    }

    func testActiveRestoreStartsFactoryOnlyWhenConfigured() async throws {
        let fixture = try UIEnrollmentFixture()
        let enrollment = SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID), profile: nil, initialConnectionPresentation: .connected)
        let automatic = EnrollmentFactorySequence(models: [enrollment])
        let automaticAccount = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await automatic.make() },
            automaticallyPrepareSyncNodeOnActive: true
        )
        await activate(automaticAccount)
        await waitUntil { automaticAccount.syncNodeEnrollmentModel === enrollment }
        let automaticCalls = await automatic.count()
        XCTAssertEqual(automaticCalls, 1)

        let direct = EnrollmentFactorySequence(models: [enrollment])
        let directAccount = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try await direct.make() }
        )
        await activate(directAccount)
        for _ in 0 ..< 20 { await Task.yield() }
        let directCalls = await direct.count()
        XCTAssertEqual(directCalls, 0)
        XCTAssertNil(directAccount.syncNodeEnrollmentModel)
    }

    private func activate(_ account: AccountSessionViewModel) async {
        account.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        await waitUntil { account.presentation == .active }
    }

    private func reachUncertainCommit(
        _ model: SyncNodeEnrollmentViewModel,
        expecting expected: SyncNodeEnrollmentCoordinator.State = .commitResponseUncertain
    ) async throws {
        let attempt = try model.beginConnectAppleAuthorization()
        model.submitAppleIdentityToken(Data("apple-token".utf8), for: attempt.id)
        await waitUntil {
            if case .matchingStringConfirmation = model.state,
               model.connectionPresentation == .ready { return true }
            return false
        }
        await model.approvePinnedTarget()
        XCTAssertEqual(model.state, expected)
    }

    /// Polls against a deadline, not a yield count: under full-suite load
    /// the coordinator's tasks can need far more than 200 scheduler turns.
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("condition did not become true")
    }

    private func fileAccess(document: Data) -> SyncNodeBootstrapFileAccess {
        SyncNodeBootstrapFileAccess(
            startAccessing: { _ in true },
            stopAccessing: { _ in },
            read: { _, _ in document }
        )
    }
}

private struct UIEnrollmentFixture {
    let trustCommit: AccountTrustStateCommit
    let identity: AccountDeviceIdentity
    let trust: UIEnrollmentTrust
    let claim: AccountNodeEnrollmentPublicClaimV1
    let profile: SyncNodeBootstrapProfile
    let presentation: SyncNodeEnrollmentPresentation

    var owner: SyncNodeEnrollmentOwner {
        SyncNodeEnrollmentOwner(accountID: trustCommit.state.accountID, deviceID: trustCommit.state.members[0].deviceID)
    }

    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let genesis = try XCTUnwrap(((root["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any])
        let decodedCommit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(genesis["genesisCommit"])))
        identity = try AccountDeviceIdentity.generate()
        let deviceID = decodedCommit.state.members[0].deviceID
        let trustedMember = try AccountDeviceTrustRecord(
            accountID: decodedCommit.state.accountID,
            epoch: decodedCommit.state.epoch,
            revision: decodedCommit.state.revision,
            deviceID: deviceID,
            platform: decodedCommit.state.members[0].platform,
            publicBundle: identity.publicBundle,
            signerDeviceID: deviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let trustedState = try AccountTrustState(
            accountID: decodedCommit.state.accountID,
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
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(trustedState)))
        let template = try XCTUnwrap(decodedCommit.keyPackages.first)
        let package = try AccountGroupKeyPackage(
            accountID: trustedState.accountID,
            epoch: trustedState.epoch,
            stateRevision: trustedState.revision,
            keyGeneration: trustedState.keyGeneration,
            stateDigest: stateDigest,
            keyCommitment: trustedState.keyCommitment,
            recipientDeviceID: deviceID,
            senderDeviceID: deviceID,
            senderEphemeralPublicKey: template.senderEphemeralPublicKey,
            nonce: template.nonce,
            encryptedKeyMaterial: template.encryptedKeyMaterial,
            signature: Data(repeating: 1, count: 64)
        )
        trustCommit = try AccountTrustStateCommit(state: trustedState, keyPackages: [package])
        trust = UIEnrollmentTrust(commit: trustCommit)
        let signing = P256.Signing.PrivateKey().publicKey.x963Representation
        let createdAt = uiEnrollmentTimestamp(Date().addingTimeInterval(-30))
        let expiresAt = uiEnrollmentTimestamp(Date().addingTimeInterval(240))
        claim = try AccountNodeEnrollmentPublicClaimV1(
            claimID: NodeEnrollmentClaimID("90000000-0000-4000-8000-000000000001"),
            nodeDeviceID: AccountDeviceID("90000000-0000-4000-8000-000000000002"),
            signingPublicKey: signing,
            agreementPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
            noiseStaticPublicKey: Data(repeating: 9, count: 32),
            endpointDigest: Data(repeating: 4, count: 32),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        profile = try SyncNodeBootstrapProfile(
            canonicalOrigin: NodeEndpointURL("https://node.tail1234.ts.net:18443"),
            nodeDeviceID: claim.nodeDeviceID,
            signingKeyDigest: Data(SHA256.hash(data: claim.signingPublicKey)),
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "central.test"
        )
        presentation = try SyncNodeEnrollmentPresentation(
            setupCode: NodeSessionWire.encodeBase64URL(Data(repeating: 1, count: 32)),
            expiresAt: try XCTUnwrap(AccountWireCodec.parseTimestamp(expiresAt)),
            claimProofSignature: Data(repeating: 10, count: 64),
            claimFingerprint: "123456"
        )
    }

    @MainActor
    func coordinator(
        activeNodeID: AccountDeviceID?,
        presenter: (any SyncNodeEnrollmentPresenting)? = nil,
        remote: any SyncNodeEnrollmentRemote = UIEnrollmentRemote(),
        localAuthenticator: any SyncNodeEnrollmentLocalAuthenticating = UIEnrollmentLocal(),
        trust: (any SyncNodeEnrollmentTrustCoordinating)? = nil,
        activation: any SyncNodeEnrollmentActivating = UIEnrollmentActivator()
    ) -> SyncNodeEnrollmentCoordinator {
        let credentials = try! AccountSessionCredentials(accountID: trustCommit.state.accountID, deviceID: trustCommit.state.members[0].deviceID, accessToken: "token", accessExpiresAt: Date().addingTimeInterval(60), refreshCredential: Data(repeating: 6, count: 32), offlineLease: "lease")
        return SyncNodeEnrollmentCoordinator(
            remote: remote,
            presenter: presenter,
            bootstrapVerifier: UIEnrollmentBootstrapVerifier(origin: profile.canonicalOrigin),
            localAuthenticator: localAuthenticator,
            responseVerifier: UIEnrollmentVerifier(),
            trust: trust ?? UIEnrollmentTrust(commit: trustCommit),
            activation: activation,
            credentials: credentials,
            credentialsProvider: { [credentials] in credentials },
            device: identity,
            activeNodeID: activeNodeID
        )
    }

    func profile(capabilityByte: UInt8, nodeSuffix: String) throws -> SyncNodeBootstrapProfile {
        try SyncNodeBootstrapProfile(
            canonicalOrigin: profile.canonicalOrigin,
            nodeDeviceID: AccountDeviceID("90000000-0000-4000-8000-0000000000\(nodeSuffix)"),
            signingKeyDigest: Data(repeating: capabilityByte, count: 32),
            capabilityID: Data(repeating: capabilityByte, count: 16),
            capability: Data(repeating: capabilityByte, count: 32),
            centralAudience: "central.test"
        )
    }

}

private func uiEnrollmentTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private final class SessionRefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func record() { lock.withLock { calls += 1 } }
}

@MainActor
private final class EnrollmentOwnerReaderScript {
    enum Outcome { case owner(SyncNodeEnrollmentOwner), none, failure }
    var outcome: Outcome
    private(set) var reads = 0
    init(_ owner: SyncNodeEnrollmentOwner) { outcome = .owner(owner) }
    func read() throws -> SyncNodeEnrollmentOwner? {
        reads += 1
        switch outcome {
        case .owner(let owner): return owner
        case .none: return nil
        case .failure: throw AccountRuntimeError.secretUnavailable
        }
    }
}

/// Injected wall clock for Connect's wait on a cancelled claim.
@MainActor
final class UIEnrollmentClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// The account state `prepareSession` reports next.
final class SessionStateScript: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountSessionState
    init(_ value: AccountSessionState) { self.value = value }
    var state: AccountSessionState {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
final class SettingsOwnerReaderScript {
    var owner: SyncNodeEnrollmentOwner?
    /// Models a Keychain read error for `readOrThrow()`.
    var fails = false
    private(set) var reads = 0
    init(_ owner: SyncNodeEnrollmentOwner?) { self.owner = owner }
    func read() -> SyncNodeEnrollmentOwner? {
        reads += 1
        return owner
    }
    func readOrThrow() throws -> SyncNodeEnrollmentOwner? {
        reads += 1
        if fails { throw AccountRuntimeError.secretUnavailable }
        return owner
    }
}

@MainActor
private final class EnrollmentOwnerBox {
    var value: SyncNodeEnrollmentOwner
    init(_ value: SyncNodeEnrollmentOwner) { self.value = value }
}

private actor ConnectionCheckRecorder {
    private var checks = 0
    func check() throws { checks += 1 }
    func count() -> Int { checks }
}

private final class UIEnrollmentProfileStore: SyncNodeBootstrapProfileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: SyncNodeBootstrapProfile?
    init(profile: SyncNodeBootstrapProfile?) { self.profile = profile }
    func load() throws -> SyncNodeBootstrapProfile? { lock.withLock { profile } }
    func importProfile(_ profile: SyncNodeBootstrapProfile) throws { lock.withLock { self.profile = profile } }
    func retire(expectedCapabilityID: Data) throws { lock.withLock { if profile?.capabilityID == expectedCapabilityID { profile = nil } } }
}

private actor SuspendedEnrollmentFactory {
    private let first: SyncNodeEnrollmentViewModel
    private let later: SyncNodeEnrollmentViewModel
    private var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(first: SyncNodeEnrollmentViewModel, later: SyncNodeEnrollmentViewModel) { self.first = first; self.later = later }
    func make() async throws -> SyncNodeEnrollmentViewModel {
        calls += 1
        if calls == 1 {
            waiters.forEach { $0.resume() }; waiters.removeAll()
            await withCheckedContinuation { firstContinuation = $0 }
            return first
        }
        return later
    }
    func waitUntilFirstStarts() async { if calls > 0 { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseFirst() { firstContinuation?.resume(); firstContinuation = nil }
    func count() -> Int { calls }
}

private actor EnrollmentFactorySequence {
    private let models: [SyncNodeEnrollmentViewModel]
    private var calls = 0
    init(models: [SyncNodeEnrollmentViewModel]) { self.models = models }
    func make() throws -> SyncNodeEnrollmentViewModel { defer { calls += 1 }; return models[min(calls, models.count - 1)] }
    func count() -> Int { calls }
}

private actor NoNodeThenEnrollmentFactory {
    private let model: SyncNodeEnrollmentViewModel
    private var calls = 0
    init(model: SyncNodeEnrollmentViewModel) { self.model = model }
    func make() throws -> SyncNodeEnrollmentViewModel { calls += 1; if calls == 1 { throw SyncNodeEnrollmentAssembly.LoadError.noSyncNode }; return model }
    func count() -> Int { calls }
}

private actor FailingThenEnrollmentFactory {
    private let model: SyncNodeEnrollmentViewModel
    private var calls = 0
    init(model: SyncNodeEnrollmentViewModel) { self.model = model }
    func make() throws -> SyncNodeEnrollmentViewModel { calls += 1; if calls == 1 { throw AccountRuntimeError.secretUnavailable }; return model }
    func count() -> Int { calls }
}

private actor CountingEnrollmentPresenter: SyncNodeEnrollmentPresenting {
    private let presentation: SyncNodeEnrollmentPresentation
    private var count = 0
    init(presentation: SyncNodeEnrollmentPresentation) { self.presentation = presentation }
    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation {
        count += 1
        return presentation
    }
    func fetchCount() -> Int { count }
}

private struct UIProvisionedEnrollmentPresenter: SyncNodeEnrollmentPresenting {
    let presentation: SyncNodeEnrollmentPresentation
    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation { presentation }
}

private actor BlockingEnrollmentPresenter: SyncNodeEnrollmentPresenting {
    private let presentation: SyncNodeEnrollmentPresentation
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    init(presentation: SyncNodeEnrollmentPresentation) { self.presentation = presentation }
    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation {
        started = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return presentation
    }
    func waitUntilFetchStarts() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseFetch() { continuation?.resume(); continuation = nil }
}

private actor EnrollmentSideEffectRemote: SyncNodeEnrollmentRemote {
    private var lookups = 0
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { lookups += 1; throw AccountRuntimeError.untrustedResponse }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {}
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.untrustedResponse }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse { throw AccountRuntimeError.untrustedResponse }
    func lookupCount() -> Int { lookups }
}

private actor EnrollmentLocalAuthRecorder: SyncNodeEnrollmentLocalAuthenticating {
    private var calls = 0
    func authenticateSyncNodeEnrollment() async throws { calls += 1 }
    func count() -> Int { calls }
}

private struct UIEnrollmentBootstrapVerifier: SyncNodeBootstrapClaimVerifying {
    let origin: NodeEndpointURL
    func verify(profile: SyncNodeBootstrapProfile, presentation: SyncNodeEnrollmentPresentation, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data) throws -> NodeEndpointURL { origin }
}
private struct UIEnrollmentLocal: SyncNodeEnrollmentLocalAuthenticating { func authenticateSyncNodeEnrollment() async throws {} }
private struct UIEnrollmentVerifier: SyncNodeEnrollmentResponseVerifying { func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {} }
private actor UIEnrollmentTrust: SyncNodeEnrollmentTrustCoordinating {
    private var commit: AccountTrustStateCommit
    private var acceptanceFailures: Int
    init(commit: AccountTrustStateCommit, acceptanceFailures: Int = 0) { self.commit = commit; self.acceptanceFailures = acceptanceFailures }
    func currentTrustCommit() async throws -> AccountTrustStateCommit? { commit }
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit {
        let prior = commit
        let revision = try PositiveUInt64(prior.state.revision.value + 1)
        let bundle = try AccountPublicKeyBundle(signingKey: evidence.signingPublicKey, agreementKey: evidence.agreementPublicKey)
        let member = try AccountDeviceTrustRecord(
            accountID: prior.state.accountID,
            epoch: prior.state.epoch,
            revision: revision,
            deviceID: evidence.nodeDeviceID,
            platform: .syncNode,
            publicBundle: bundle,
            signerDeviceID: prior.state.signerDeviceID,
            signature: Data(repeating: 1, count: 64)
        )
        // A replacement is an atomic revocation of the replaced Node.
        let transition = if let replacedNodeID = evidence.replacedNodeID {
            try AccountTrustTransition(kind: .revocation, targetDeviceIDs: [replacedNodeID], priorRecordDigests: [AccountPriorRecordDigest(deviceID: replacedNodeID, recordDigest: Data(repeating: 5, count: 32))])
        } else {
            try AccountTrustTransition(
                kind: .admission,
                targetDeviceIDs: [evidence.nodeDeviceID],
                priorRecordDigests: [],
                handshakeDigest: Data(repeating: 3, count: 32),
                pendingDeviceDigest: Data(repeating: 4, count: 32)
            )
        }
        let state = try AccountTrustState(
            accountID: prior.state.accountID,
            epoch: prior.state.epoch,
            revision: revision,
            previousCommitDigest: AccountTranscript.trustCommitDigest(prior),
            transition: transition,
            keyGeneration: prior.state.keyGeneration,
            keyCommitment: prior.state.keyCommitment,
            members: (prior.state.members.filter { $0.deviceID != evidence.replacedNodeID } + [member]).sorted { $0.deviceID.rawValue < $1.deviceID.rawValue },
            signerDeviceID: prior.state.signerDeviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let digest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let template = try XCTUnwrap(prior.keyPackages.first)
        let packages = try state.members.map { member in
            try AccountGroupKeyPackage(
                accountID: state.accountID,
                epoch: state.epoch,
                stateRevision: state.revision,
                keyGeneration: state.keyGeneration,
                stateDigest: digest,
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
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws {
        if acceptanceFailures > 0 { acceptanceFailures -= 1; throw AccountRuntimeError.untrustedResponse }
        self.commit = commit
    }
}

private actor UIResponseLossEnrollmentRemote: SyncNodeEnrollmentRemote {
    private let fixture: UIEnrollmentFixture
    private let lostResponses: Int
    private let rejection: SyncNodeEnrollmentCommitError?
    private let cancelFailure: Error?
    private var committed: [SyncNodeEnrollmentAdmissionRequest] = []
    private var cancels = 0

    /// `cancelFailure` models any claim-cancel answer other than 204.
    init(fixture: UIEnrollmentFixture, lostResponses: Int = 1, rejection: SyncNodeEnrollmentCommitError? = nil, cancelFailure: Error? = nil) {
        self.fixture = fixture
        self.lostResponses = lostResponses
        self.rejection = rejection
        self.cancelFailure = cancelFailure
    }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { fixture.claim }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        cancels += 1
        if let cancelFailure { throw cancelFailure }
    }
    func cancelCount() -> Int { cancels }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        try AccountStepUpAuthorizationV1(
            authorizationID: AccountAuthorizationID("90000000-0000-4000-8000-000000000003"),
            accountID: credentials.accountID,
            actorDeviceID: credentials.deviceID,
            targetDeviceID: action == .enroll ? claim.nodeDeviceID : replacedNodeID,
            action: action == .enroll ? .enrollSyncNode : .replaceSyncNode,
            currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit),
            requestDigest: Data(repeating: 6, count: 32),
            issuedAt: uiEnrollmentTimestamp(now.addingTimeInterval(-1)),
            expiresAt: uiEnrollmentTimestamp(now.addingTimeInterval(240)),
            serverKeyID: "test-key",
            serverSignature: try fixture.identity.signature(for: Data("step-up".utf8))
        )
    }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        committed.append(request)
        if let rejection { throw rejection }
        if committed.count <= lostResponses { throw AccountRuntimeError.transportFailure }
        return try uiEnrollmentV2Response()
    }
    func requests() -> [SyncNodeEnrollmentAdmissionRequest] { committed }
}

private func uiEnrollmentV2Response() throws -> SyncNodeEnrollmentAdmissionResponse {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let vector = try XCTUnwrap(root["syncNodeEnrollmentV2"] as? [String: Any])
    func object(_ key: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(vector[key] as? String).utf8)) }
    let wire = try JSONSerialization.data(withJSONObject: [
        "kind": "account.sync-node-admission-response.v2",
        "result": try object("resultCanonicalJSON"),
        "refreshCredential": try object("refreshCanonicalJSON"),
        "offlineLease": try object("leaseCanonicalJSON"),
        "cleanupCapability": try object("capabilityCanonicalJSON"),
    ], options: [.sortedKeys, .withoutEscapingSlashes])
    return try SyncNodeEnrollmentAdmissionResponse(v2: AccountWireCodec.decodeNodeEnrollmentAdmissionResponseV2(wire))
}

/// The first `uncertainActivations` activations end without a Node answer;
/// Retry Activation then succeeds.
private actor UIScriptedEnrollmentActivator: SyncNodeEnrollmentActivating {
    private var uncertainActivations: Int
    private(set) var retries = 0
    init(uncertainActivations: Int) { self.uncertainActivations = uncertainActivations }
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {
        if uncertainActivations > 0 { uncertainActivations -= 1; throw NodeActivationError.uncertain }
    }
    func retryUncertainActivation() async throws { retries += 1 }
    func cancelPendingActivation() async {}
}

private actor UIEnrollmentActivator: SyncNodeEnrollmentActivating {
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {}
    func retryUncertainActivation() async throws {}
    func cancelPendingActivation() async {}
}
private actor UIEnrollmentRemote: SyncNodeEnrollmentRemote {
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { throw AccountRuntimeError.untrustedResponse }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {}
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.untrustedResponse }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse { throw AccountRuntimeError.untrustedResponse }
}

/// Exposes this file's private enrollment fixture to hosted settings tests
/// without widening the fixture's protocol doubles.
@MainActor
struct SyncNodeSettingsEnrollmentFixture {
    private let fixture: UIEnrollmentFixture

    init() throws { fixture = try UIEnrollmentFixture() }

    var profile: SyncNodeBootstrapProfile { fixture.profile }
    var owner: SyncNodeEnrollmentOwner { fixture.owner }

    func profileDocument() throws -> Data { try fixture.profile.encodedForStorage() }

    func profileStore(imported: Bool) -> any SyncNodeBootstrapProfileStoring {
        UIEnrollmentProfileStore(profile: imported ? fixture.profile : nil)
    }

    /// A provisioned target for an account without a Sync Node.
    func connectModel() -> SyncNodeEnrollmentViewModel {
        SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: fixture.profile)
    }

    /// A provisioned target imported from a v1 Server Setup file.
    func outdatedProfileModel() throws -> SyncNodeEnrollmentViewModel {
        let legacy = try SyncNodeBootstrapProfile(
            canonicalOrigin: fixture.profile.canonicalOrigin,
            nodeDeviceID: fixture.profile.nodeDeviceID,
            signingKeyDigest: fixture.profile.signingKeyDigest,
            capabilityID: fixture.profile.capabilityID,
            capability: fixture.profile.capability,
            centralAudience: nil
        )
        return SyncNodeEnrollmentViewModel(coordinator: fixture.coordinator(activeNodeID: nil), profile: legacy)
    }
    /// A committed admission whose local trust acceptance failed once, so
    /// Retry Verification installs it.
    func verificationFailedModel() async throws -> SyncNodeEnrollmentViewModel {
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(
                activeNodeID: nil,
                presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation),
                remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0),
                trust: UIEnrollmentTrust(commit: fixture.trustCommit, acceptanceFailures: 1)
            ),
            profile: fixture.profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let attempt = try model.beginConnectAppleAuthorization()
        model.submitAppleIdentityToken(Data("apple-token".utf8), for: attempt.id)
        let confirmationBy = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < confirmationBy {
            if case .matchingStringConfirmation = model.state, model.connectionPresentation == .ready { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await model.approvePinnedTarget()
        guard model.canRetryCommitVerification else { throw AccountRuntimeError.untrustedResponse }
        return model
    }
    /// An uncertain commit Central never answered 2xx. `cancelFails` makes
    /// the claim cancel answer something other than 204.
    func uncertainCommitModel(cancelFails: Bool = false, owned: Bool = false) async throws -> SyncNodeEnrollmentViewModel {
        try await approvedModel(remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 1, cancelFailure: cancelFails ? AccountRuntimeError.untrustedResponse : nil), owner: owned ? fixture.owner : nil)
    }
    /// A verified admission whose first Node activation response was lost.
    func activationUncertainModel() async throws -> SyncNodeEnrollmentViewModel {
        try await approvedModel(remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0), activation: UIScriptedEnrollmentActivator(uncertainActivations: 1))
    }
    /// Central rejected the declared audience before committing. `clock`
    /// drives Connect's wait for the claim that rejection cancelled.
    func serverMismatchModel(clock: @escaping () -> Date = Date.init) async throws -> SyncNodeEnrollmentViewModel {
        try await approvedModel(remote: UIResponseLossEnrollmentRemote(fixture: fixture, lostResponses: 0, rejection: .audienceMismatch), clock: clock)
    }
    /// When the fixture's claim expires.
    var claimExpiry: Date { fixture.presentation.expiresAt }
    private func approvedModel(remote: UIResponseLossEnrollmentRemote, activation: any SyncNodeEnrollmentActivating = UIEnrollmentActivator(), clock: @escaping () -> Date = Date.init, owner: SyncNodeEnrollmentOwner? = nil) async throws -> SyncNodeEnrollmentViewModel {
        let model = SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: nil, presenter: UIProvisionedEnrollmentPresenter(presentation: fixture.presentation), remote: remote, trust: UIEnrollmentTrust(commit: fixture.trustCommit), activation: activation),
            profile: fixture.profile,
            owner: owner,
            nonceGenerator: { Data(repeating: 4, count: 32) },
            clock: clock
        )
        let attempt = try model.beginConnectAppleAuthorization()
        model.submitAppleIdentityToken(Data("apple-token".utf8), for: attempt.id)
        let confirmationBy = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < confirmationBy {
            if case .matchingStringConfirmation = model.state, model.connectionPresentation == .ready { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await model.approvePinnedTarget()
        return model
    }
    /// A trusted Node this device has no private session for, with a new
    /// provisioned target that can replace it.
    func recoveryModel() -> SyncNodeEnrollmentViewModel {
        SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
            profile: fixture.profile,
            initialConnectionPresentation: .recoveryRequired,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
    }
    /// A connected Sync Node with a newly imported Server Setup that can
    /// replace it.
    func connectedReplaceableModel() -> SyncNodeEnrollmentViewModel {
        SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
            profile: fixture.profile,
            initialConnectionPresentation: .connected,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
    }
    /// A trusted Node this device lacks a session for, with only a v1
    /// Server Setup file imported.
    func outdatedRecoveryModel(presentation: SyncNodeEnrollmentViewModel.ConnectionPresentation) throws -> SyncNodeEnrollmentViewModel {
        let legacy = try SyncNodeBootstrapProfile(canonicalOrigin: fixture.profile.canonicalOrigin, nodeDeviceID: fixture.profile.nodeDeviceID, signingKeyDigest: fixture.profile.signingKeyDigest, capabilityID: fixture.profile.capabilityID, capability: fixture.profile.capability, centralAudience: nil)
        return SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
            profile: legacy,
            initialConnectionPresentation: presentation
        )
    }
    /// An account whose trust set already contains the fixture Sync Node.
    func enrolledModel(
        initialConnectionPresentation: SyncNodeEnrollmentViewModel.ConnectionPresentation = .connected,
        verifyConnection: @escaping @Sendable () async throws -> Void = {}
    ) -> SyncNodeEnrollmentViewModel {
        SyncNodeEnrollmentViewModel(
            coordinator: fixture.coordinator(activeNodeID: fixture.profile.nodeDeviceID),
            profile: nil,
            initialConnectionPresentation: initialConnectionPresentation,
            verifyConnection: verifyConnection
        )
    }
}
