import XCTest
import PlainpostAccountProtocol
import PlainpostNodeTransport
@testable import PlainpostAccountRuntime

final class SyncNodeProviderControllerTests: XCTestCase {
    func testGoogleAuthorizationUsesSystemPKCEAndHandsOneTimeCodeToNode() async throws {
        let node = ProviderControllerTestClient()
        let controller = SyncNodeProviderController(client: node)
        let request = try controller.makeGoogleAuthorizationRequest(
            clientID: "ios-client",
            redirectURI: "https://mail.example.test/oauth/google"
        )

        XCTAssertEqual(request.authorizationURL.scheme, "https")
        XCTAssertFalse(request.codeVerifier.isEmpty)
        XCTAssertFalse(request.state.isEmpty)
        XCTAssertNil(request.authorizationCode)

        let result = try await controller.completeGoogleAuthorization(
            callbackURL: URL(string: "https://mail.example.test/oauth/google?code=one-time-code&state=\(request.state)")!
        )

        XCTAssertEqual(result.providerIdentity, "google:user@example.com")
        let call = await node.lastCall
        XCTAssertEqual(call?.authorizationCode, "one-time-code")
        XCTAssertEqual(call?.codeVerifier, request.codeVerifier)
        XCTAssertNil(call?.clientSecret)
    }

    func testMalformedOrStaleCallbackDoesNotReachNode() async throws {
        let node = ProviderControllerTestClient()
        let controller = SyncNodeProviderController(client: node)
        let request = try controller.makeGoogleAuthorizationRequest(clientID: "ios-client", redirectURI: "https://mail.example.test/oauth/google")

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.completeGoogleAuthorization(
                callbackURL: URL(string: "https://mail.example.test/oauth/google?code=stale&state=wrong")!
            )
        }
        let call = await node.lastCallValue()
        XCTAssertNil(call)
        XCTAssertNil(request.authorizationCode)
    }

    func testStatusCallbacksCanBeReadAndReplacedConcurrently() async {
        let controller = SyncNodeProviderController(client: ProviderControllerTestClient())

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    controller.onStatusRefresh = { _ in }
                    _ = controller.onStatusRefresh
                    controller.onAssignmentOutcomeAmbiguous = {}
                    _ = controller.onAssignmentOutcomeAmbiguous
                }
            }
        }
    }

    func testAssignmentReadinessWaitsThroughTransientProviderStatusBeforeMutation() async throws {
        let node = ProviderControllerTransientReadinessClient()
        let controller = SyncNodeProviderController(client: node)
        let status = try await controller.waitForTrustedProviderStatus(
            timeout: .seconds(1), pollInterval: .milliseconds(1)
        )

        XCTAssertEqual(status.state, "ready")
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )
        _ = try await controller.assignGoogleMailboxes([selection])
        let statusCallCount = await node.statusCallCount()
        let assignmentStatusCall = await node.assignmentStatusCall()
        XCTAssertEqual(statusCallCount, 5)
        XCTAssertEqual(assignmentStatusCall, 4, "PUT must wait for trusted status")
    }

    func testTrustedReadinessDeadlineDoesNotWaitForNonCooperativeStatus() async throws {
        let node = ProviderControllerNonCooperativeStatusClient()
        let controller = SyncNodeProviderController(client: node)
        let published = LockedFlag()
        controller.onStatusRefresh = { _ in published.value = true }
        let started = ContinuousClock.now

        do {
            _ = try await controller.waitForTrustedProviderStatus(
                timeout: .milliseconds(20), pollInterval: .milliseconds(1)
            )
            XCTFail("a non-cooperative status call must not defeat the deadline")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }

        let elapsed = started.duration(to: ContinuousClock.now)
        XCTAssertLessThan(elapsed, .milliseconds(100))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(published.value)
        XCTAssertTrue(node.wasCancellationRequested(), "timeout must invoke the provider status cancellation contract")
        await node.waitUntilFinished()
    }

    func testTrustedReadinessPreservesExternalCancellationAndCancelsStatus() async throws {
        let node = ProviderControllerCancellableStatusClient()
        let controller = SyncNodeProviderController(client: node)
        let task = Task {
            try await controller.waitForTrustedProviderStatus(
                timeout: .seconds(5), pollInterval: .milliseconds(1)
            )
        }
        await node.waitUntilCalled()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // The caller's cancellation must not be mapped to provider outage.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await node.waitUntilCancelled()
        let wasCancelled = await node.wasCancelled()
        XCTAssertTrue(wasCancelled)
    }

    func testPreCancelledTrustedReadinessPreservesCancellationError() async throws {
        let node = ProviderControllerTrackedStatusClient()
        let controller = SyncNodeProviderController(client: node)
        let wait = Task {
            try await controller.waitForTrustedProviderStatus(
                timeout: .milliseconds(20), pollInterval: .milliseconds(1)
            )
        }
        wait.cancel()

        do {
            _ = try await wait.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // A cancellation observed before the readiness worker installs
            // must not be rewritten as a provider timeout.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testTrustedReadinessTimeoutTerminatesCooperativeStatusWorkerAndReleasesResource() async throws {
        let node = ProviderControllerTrackedStatusClient()
        let controller = SyncNodeProviderController(client: node)
        let wait = Task {
            try await controller.waitForTrustedProviderStatus(
                timeout: .milliseconds(20), pollInterval: .milliseconds(1)
            )
        }
        await node.waitUntilStarted()

        do {
            _ = try await wait.value
            XCTFail("expected readiness timeout")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        await node.waitUntilFinished()
        let activeWorkers = await node.activeWorkers()
        XCTAssertEqual(activeWorkers, 0)
    }

    func testTrustedReadinessTimeoutReturnsBeforeCancellationDrainFinishes() async throws {
        let node = ProviderControllerStalledStatusCancellationClient()
        let controller = SyncNodeProviderController(client: node)
        let wait = Task {
            try await controller.waitForTrustedProviderStatus(
                timeout: .milliseconds(20), pollInterval: .milliseconds(1)
            )
        }
        guard await node.waitUntilStarted() else {
            XCTFail("status worker did not start")
            return
        }

        let completed = LockedFlag()
        let waiter = Task {
            _ = try? await wait.value
            completed.value = true
        }
        guard await node.waitUntilCancellationStarted() else {
            XCTFail("cancellation cleanup did not start")
            return
        }
        let timeoutCancellationCalls = await node.cancellationCallCount()
        XCTAssertEqual(timeoutCancellationCalls, 1)
        let completedBeforeDeadline = await waitUntil({ completed.value })
        XCTAssertTrue(completedBeforeDeadline, "readiness timeout must not wait for cancellation drain")
        let timeoutDrainFinished = await node.cancellationDrainFinished()
        XCTAssertFalse(timeoutDrainFinished)

        await node.releaseCancellationDrain()
        await waiter.value
        let timeoutDrainCompleted = await node.waitUntilCancellationFinished()
        XCTAssertTrue(timeoutDrainCompleted)
    }

    func testProductionNodeProviderAdapterCancelsItsScopedStatusRequest() async throws {
        let sender = AdapterScopedStatusSender()
        let controller = SyncNodeProviderController(client: NodeSyncClient(sender: sender))
        // Cancelled by the test once the request is on the wire, not by a
        // short timeout: under load a 20 ms timeout could fire before the
        // request even started, leaving nothing to cancel. The wait's
        // timeout and caller cancellation end in the same request-scoped
        // cleanup.
        let wait = Task {
            try await controller.waitForTrustedProviderStatus(
                timeout: .seconds(600), pollInterval: .milliseconds(1)
            )
        }
        await sender.waitUntilStarted()
        wait.cancel()

        do {
            _ = try await wait.value
            XCTFail("the adapter status request must end when its wait ends")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // The cleanup runs after the caller has its outcome.
        await sender.waitUntilFinished()
        XCTAssertTrue(sender.wasCancelled(), "the production adapter must expose request-scoped cancellation")
    }

    func testPreCancelledProductionStatusScopeReturnsPromptly() async throws {
        let sender = AdapterScopedStatusSender()
        let adapter = NodeSyncProviderClientAdapter(client: NodeSyncClient(sender: sender))
        let scope = adapter.makeStatusCancellation()
        await scope.cancelAndWait()
        let started = ContinuousClock.now

        do {
            _ = try await adapter.status(using: scope)
            XCTFail("a pre-cancelled status scope must not start transport")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(100))
        XCTAssertFalse(sender.wasStarted(), "pre-cancelled scope must not create a transport request")
    }

    func testPreCancelledStatusScopeDoesNotRetainOrphanedTokensAcrossConcurrentCancelAndWait() async {
        let scope = StatusCancellationScope()
        await scope.cancelAndWait()

        let neverStarted = NodeHTTPTransportRequestCancellation()
        let cancellationObserved = LockedFlag()
        neverStarted.install { cancellationObserved.value = true }
        XCTAssertTrue(scope.install(neverStarted))
        XCTAssertFalse(scope.hasInstalledCancellation)

        let completed = LockedFlag()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { await scope.cancelAndWait() }
            }
            await group.waitForAll()
        }
        completed.value = true

        XCTAssertTrue(completed.value)
        XCTAssertFalse(cancellationObserved.value)
    }

    func testConcurrentProductionStatusScopesCancelOnlyTheirOwnRequest() async throws {
        let sender = ConcurrentAdapterStatusSender()
        let controller = SyncNodeProviderController(client: NodeSyncClient(sender: sender))
        let first = Task {
            try await controller.waitForTrustedProviderStatus(timeout: .milliseconds(30), pollInterval: .milliseconds(1))
        }
        let second = Task {
            try await controller.waitForTrustedProviderStatus(timeout: .seconds(5), pollInterval: .milliseconds(1))
        }
        await sender.waitUntilStarted(count: 2)

        do {
            _ = try await first.value
            XCTFail("first readiness wait must time out")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        let cancellationObserved = await sender.waitUntilCancelled(count: 1)
        XCTAssertTrue(cancellationObserved, "scoped status request was not cancelled")
        XCTAssertEqual(sender.cancelledCount(), 1, "only the timed-out readiness request may be cancelled")
        sender.releaseUncancelled()
        let status = try await second.value
        XCTAssertEqual(status.providerIdentity, "provider-a@example.com")
        XCTAssertEqual(sender.finishedCount(), 2, "both readiness workers must be drained")
    }

    func testTrustedReadinessCancellationReturnsBeforeCancellationDrainFinishes() async throws {
        let node = ProviderControllerStalledStatusCancellationClient()
        let controller = SyncNodeProviderController(client: node)
        let wait = Task {
            try await controller.waitForTrustedProviderStatus(
                timeout: .seconds(5), pollInterval: .milliseconds(1)
            )
        }
        guard await node.waitUntilStarted() else {
            XCTFail("status worker did not start")
            return
        }
        wait.cancel()

        let completed = LockedFlag()
        let waiter = Task {
            _ = try? await wait.value
            completed.value = true
        }
        guard await node.waitUntilCancellationStarted() else {
            XCTFail("cancellation cleanup did not start")
            return
        }
        let cancellationCalls = await node.cancellationCallCount()
        XCTAssertEqual(cancellationCalls, 1)
        let completedBeforeDeadline = await waitUntil({ completed.value })
        XCTAssertTrue(completedBeforeDeadline, "caller cancellation must not wait for cancellation drain")

        await node.releaseCancellationDrain()
        await waiter.value
        do {
            _ = try await wait.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Caller cancellation must not wait for a stalled transport drain.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let cancellationDrainCompleted = await node.waitUntilCancellationFinished()
        XCTAssertTrue(cancellationDrainCompleted)
    }

    func testTrustedReadinessCancellationWinsWhileDeadlineIsPending() async throws {
        let node = ProviderControllerStalledStatusCancellationClient()
        let controller = SyncNodeProviderController(client: node)
        let wait = Task {
            try await controller.waitForTrustedProviderStatus(
                timeout: .seconds(1), pollInterval: .milliseconds(1)
            )
        }
        guard await node.waitUntilStarted() else {
            XCTFail("status worker did not start")
            return
        }
        // Keep the timeout pending while coordination, rather than elapsed
        // wall-clock time, establishes the cancellation-vs-timeout race.
        wait.cancel()

        do {
            _ = try await wait.value
            XCTFail("expected cancellation while the readiness deadline is pending")
        } catch is CancellationError {
            // The caller's cancellation must win over the timeout claim.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        guard await node.waitUntilCancellationStarted() else {
            XCTFail("cancellation cleanup did not start")
            return
        }
        let cancellationCalls = await node.cancellationCallCount()
        XCTAssertEqual(cancellationCalls, 1)

        await node.releaseCancellationDrain()
        let cancellationDrainCompleted = await node.waitUntilCancellationFinished()
        XCTAssertTrue(cancellationDrainCompleted)
    }

    func testGoogleAuthorizationRejectsStatusIdentityChangeBeforePublishing() async throws {
        let node = ProviderControllerConfiguredChangingIdentityClient()
        let controller = SyncNodeProviderController(client: node)
        let request = try controller.makeGoogleAuthorizationRequest(
            clientID: "ios-client", redirectURI: "https://mail.example.test/oauth/google"
        )
        let callback = URL(string: "https://mail.example.test/oauth/google?code=one-time-code&state=\(request.state)")!
        do {
            _ = try await controller.completeGoogleAuthorization(callbackURL: callback)
            XCTFail("OAuth must reject a provider identity changed in its authenticated status")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        let assignmentWasCalled = await node.assignmentWasCalled()
        XCTAssertFalse(assignmentWasCalled)
    }

    func testTrustedProviderIdentityMustRemainStableBeforeAssignment() async throws {
        let node = ProviderControllerChangingIdentityClient()
        let controller = SyncNodeProviderController(client: node)
        let identity = "provider-a@example.com"
        _ = try await controller.waitForTrustedProviderStatus(
            timeout: .seconds(1), pollInterval: .milliseconds(1), expectedProviderIdentity: identity
        )
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        do {
            _ = try await controller.assignGoogleMailboxes([selection])
            XCTFail("a changed provider identity must not pass assignment reconciliation")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        let assignmentWasCalled = await node.assignmentWasCalled()
        XCTAssertFalse(assignmentWasCalled)
    }

    func testExpectedProviderIdentityCannotOverrideRetainedIdentity() async throws {
        let node = ProviderControllerChangingIdentityClient()
        let controller = SyncNodeProviderController(client: node, trustedProviderIdentity: "provider-a@example.com")

        do {
            _ = try await controller.waitForTrustedProviderStatus(
                timeout: .seconds(1), pollInterval: .milliseconds(1), expectedProviderIdentity: "provider-b@example.com"
            )
            XCTFail("a caller expectation must not override the retained identity")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    func testConcurrentFirstProviderIdentityBindsAreAtomic() async {
        let node = ProviderControllerAlternatingIdentityClient()
        let controller = SyncNodeProviderController(client: node)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0 ..< 2 {
                group.addTask {
                    do {
                        _ = try await controller.waitForTrustedProviderStatus(
                            timeout: .seconds(1), pollInterval: .milliseconds(1)
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(outcomes.filter { !$0 }.count, 1)
    }

    func testConcurrentCallbacksConsumeTheAuthorizationCodeExactlyOnce() async throws {
        let node = ProviderControllerTestClient()
        let controller = SyncNodeProviderController(client: node)
        let request = try controller.makeGoogleAuthorizationRequest(
            clientID: "ios-client",
            redirectURI: "https://mail.example.test/oauth/google"
        )
        let callback = URL(string: "https://mail.example.test/oauth/google?code=one-time-code&state=\(request.state)")!

        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    do {
                        _ = try await controller.completeGoogleAuthorization(callbackURL: callback)
                        return "success"
                    } catch let error as SyncNodeProviderController.Error {
                        return String(describing: error)
                    } catch {
                        return "unexpected"
                    }
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(outcomes.filter { $0 == "success" }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == "staleCallback" }.count, 7)
        let calls = await node.callCount
        XCTAssertEqual(calls, 1)
    }

    func testCancellationIsNotChangedIntoProviderUnavailable() async throws {
        let node = ProviderControllerCancellationClient()
        let controller = SyncNodeProviderController(client: node)
        let request = try controller.makeGoogleAuthorizationRequest(
            clientID: "ios-client",
            redirectURI: "https://mail.example.test/oauth/google"
        )
        let callback = URL(string: "https://mail.example.test/oauth/google?code=one-time-code&state=\(request.state)")!
        let task = Task { try await controller.completeGoogleAuthorization(callbackURL: callback) }
        await node.waitUntilCalled()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Preserve cancellation for the caller.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testGoogleAuthorizationRejectsUnconfiguredCustomSchemeRedirect() throws {
        let controller = SyncNodeProviderController(client: ProviderControllerTestClient())
        XCTAssertThrowsError(try controller.makeGoogleAuthorizationRequest(
            clientID: "ios-client",
            redirectURI: "plainpost://oauth/google"
        )) { error in
            XCTAssertEqual(error as? SyncNodeProviderController.Error, .invalidRequest)
        }
    }

    func testMailboxSelectionSubmitsExactAssignmentContract() async throws {
        let node = ProviderControllerAssignmentClient()
        let controller = SyncNodeProviderController(client: node)
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 9, count: 32)))
        let assignment = SyncNodeMailboxSelection(displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox", logicalMailboxID: logical)
        _ = try await controller.assignGoogleMailboxes([assignment])
        let submitted = await node.lastAssignments
        XCTAssertEqual(submitted, [assignment])
    }

    func testMailboxAssignmentFailsClosedWhenStatusRefreshFails() async throws {
        let node = ProviderControllerStatusFailureClient()
        let controller = SyncNodeProviderController(client: node)
        let assignment = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.assignGoogleMailboxes([assignment])
        }
        let wasAssignmentCalled = await node.wasAssignmentCalled()
        XCTAssertTrue(wasAssignmentCalled)
    }

    func testMailboxAssignmentRetryReusesOneLogicalMailboxIDForTheWholeBatch() async throws {
        let node = ProviderControllerRetryAssignmentClient()
        let controller = SyncNodeProviderController(client: node)
        let selections = [
            SyncNodeMailboxSelection(displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"),
            SyncNodeMailboxSelection(displayName: "Sent", mailboxHandle: String(repeating: "B", count: 43), role: "sent")
        ]

        await XCTAssertThrowsErrorAsync { _ = try await controller.assignGoogleMailboxes(selections) }
        _ = try await controller.assignGoogleMailboxes(selections)

        let calls = await node.assignmentCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].map(\.logicalMailboxID), calls[1].map(\.logicalMailboxID))
        XCTAssertNotNil(calls[0].first?.logicalMailboxID)
        XCTAssertEqual(Set(calls[0].compactMap(\.logicalMailboxID)).count, 1)
    }

    func testMailboxAssignmentRejectsChangedRetryBatchAndRetainsOriginalIntent() async throws {
        let node = ProviderControllerAlwaysUnavailableClient()
        let controller = SyncNodeProviderController(client: node)
        let original = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )
        let changed = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "B", count: 43), role: "inbox"
        )

        await XCTAssertThrowsErrorAsync { _ = try await controller.assignGoogleMailboxes([original]) }

        do {
            _ = try await controller.assignGoogleMailboxes([changed])
            XCTFail("a retry with a changed batch must be rejected")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .invalidRequest)
        }
        let assignmentCallCount = await node.assignmentCalls.count
        XCTAssertEqual(assignmentCallCount, 1)
    }

    func testMailboxAssignmentRejectsStatusFromDifferentProviderOrState() async throws {
        let node = ProviderControllerMismatchedStatusClient(mismatch: .state)
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        do {
            _ = try await controller.assignGoogleMailboxes([selection])
            XCTFail("a stale provider status must not publish assignment success")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        let assignmentWasCalled = await node.assignmentWasCalled
        XCTAssertFalse(assignmentWasCalled)
    }

    func testMailboxAssignmentRejectsStatusFromDifferentProviderIndependently() async throws {
        let node = ProviderControllerMismatchedStatusClient(mismatch: .provider)
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.assignGoogleMailboxes([selection])
        }

        let assignmentWasCalled = await node.assignmentWasCalled
        XCTAssertTrue(assignmentWasCalled)
    }

    func testMailboxAssignmentRejectsUnreachableStatusIndependently() async throws {
        let node = ProviderControllerMismatchedStatusClient(mismatch: .reachability)
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.assignGoogleMailboxes([selection])
        }

        let assignmentWasCalled = await node.assignmentWasCalled
        XCTAssertTrue(assignmentWasCalled)
    }

    func testMailboxAssignmentRejectsMismatchedAssignmentsIndependently() async throws {
        let node = ProviderControllerMismatchedStatusClient(mismatch: .assignments)
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.assignGoogleMailboxes([selection])
        }

        let assignmentWasCalled = await node.assignmentWasCalled
        XCTAssertTrue(assignmentWasCalled)
    }

    func testMailboxAssignmentRejectsConcurrentBatchWhileOriginalIsInFlight() async throws {
        let node = ProviderControllerBlockingAssignmentClient()
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )
        let first = Task { try await controller.assignGoogleMailboxes([selection]) }
        await node.waitUntilAssignmentStarted()

        do {
            _ = try await controller.assignGoogleMailboxes([selection])
            XCTFail("concurrent assignment must not create a second in-flight batch")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .invalidRequest)
        }
        await node.releaseAssignment()
        _ = try await first.value
    }

    func testMailboxAssignmentReconcilesCommittedMutationAfterLostStatusAcknowledgement() async throws {
        let node = ProviderControllerLostStatusAcknowledgementClient()
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )
        let invalidation = LockedFlag()
        controller.onAssignmentOutcomeAmbiguous = { invalidation.value = true }

        let result = try await controller.assignGoogleMailboxes([selection])

        XCTAssertTrue(invalidation.value)
        XCTAssertEqual(result.providerIdentity, "user@example.com")
        let statusCalls = await node.statusCalls
        XCTAssertEqual(statusCalls, 3)
    }

    func testMailboxAssignmentReconcilesCommittedMutationWhenAssignmentResponseIsLost() async throws {
        let node = ProviderControllerLostAssignmentResponseClient()
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        let result = try await controller.assignGoogleMailboxes([selection])

        XCTAssertEqual(result.providerIdentity, "user@example.com")
        let statusCalls = await node.statusCalls
        XCTAssertEqual(statusCalls, 2)
    }

    func testMailboxAssignmentCancellationAfterDispatchInvalidatesAuthority() async throws {
        let node = ProviderControllerCancellationAfterDispatchClient()
        let controller = SyncNodeProviderController(client: node)
        let invalidation = LockedFlag()
        controller.onAssignmentOutcomeAmbiguous = { invalidation.value = true }
        let selection = SyncNodeMailboxSelection(displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox")
        let task = Task { try await controller.assignGoogleMailboxes([selection]) }
        await node.waitUntilAssignmentStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(invalidation.value)
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testMappedAssignmentAmbiguityPreservesCancellationDuringStatusReconciliation() async throws {
        let node = ProviderControllerMappedAmbiguousStatusCancellationClient()
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox")

        do {
            _ = try await controller.assignGoogleMailboxes([selection])
            XCTFail("mapped assignment ambiguity must preserve cancellation from status reconciliation")
        } catch is CancellationError {
            // The caller must be able to cancel while the ambiguous PUT is
            // being reconciled; it must not be rewritten as provider outage.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let statusCalls = await node.statusCallCount()
        XCTAssertEqual(statusCalls, 2)
    }

    func testGenericAssignmentAmbiguityPreservesCancellationDuringStatusReconciliation() async throws {
        let node = ProviderControllerGenericAmbiguousStatusCancellationClient()
        let controller = SyncNodeProviderController(client: node)
        let selection = SyncNodeMailboxSelection(displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox")

        do {
            _ = try await controller.assignGoogleMailboxes([selection])
            XCTFail("generic assignment ambiguity must preserve cancellation from status reconciliation")
        } catch is CancellationError {
            // Preserve cancellation through the generic recovery branch too.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let statusCalls = await node.statusCallCount()
        XCTAssertEqual(statusCalls, 2)
    }

    func testMailboxAssignmentCancellationBeforeDispatchDoesNotInvalidateAuthority() async throws {
        let node = ProviderControllerCancellationBeforeDispatchClient()
        let controller = SyncNodeProviderController(client: node)
        let invalidation = LockedFlag()
        controller.onAssignmentOutcomeAmbiguous = { invalidation.value = true }
        let selection = SyncNodeMailboxSelection(displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox")

        do {
            _ = try await controller.assignGoogleMailboxes([selection])
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(invalidation.value)
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testProductionNodeClientAdapterPreservesProviderIdentityForExactAssignmentMatch() async throws {
        let sender = AdapterAssignmentSender()
        let controller = SyncNodeProviderController(client: NodeSyncClient(sender: sender))
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        let result = try await controller.assignGoogleMailboxes([selection])

        XCTAssertEqual(result.providerIdentity, "user@example.com")
        XCTAssertFalse(result.providerIdentity.isEmpty)
        let assignmentRequestCount = await sender.assignmentRequestCount
        XCTAssertEqual(assignmentRequestCount, 1)
    }

    func testProductionNodeClientAdapterReconcilesMappedPostDispatchAssignment() async throws {
        let sender = AdapterAssignmentAmbiguitySender()
        let controller = SyncNodeProviderController(client: NodeSyncClient(sender: sender))
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: String(repeating: "A", count: 43), role: "inbox"
        )

        let result = try await controller.assignGoogleMailboxes([selection])

        XCTAssertEqual(result.providerIdentity, "user@example.com")
        let assignmentRequestCount = await sender.assignmentRequestCount
        let statusCalls = await sender.statusCalls
        XCTAssertEqual(assignmentRequestCount, 1)
        XCTAssertEqual(statusCalls, 2)
    }
}

private actor AdapterAssignmentSender: NodeSessionRequestSending {
    private(set) var statusCalls = 0
    private(set) var assignmentRequestCount = 0
    private var assignment: NodeSyncMailboxAssignment?

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let url = URL(string: "https://node.example.ts.net:443\(path)")!
        if method == "GET" && path == "/v1/status" {
            let mailboxes: [NodeSyncDiscoveredMailbox]
            if let assignment {
                mailboxes = [try NodeSyncDiscoveredMailbox(
                    displayName: "Inbox", logicalMailboxID: assignment.logicalMailboxID,
                    mailboxHandle: assignment.mailboxHandle, role: "inbox"
                )]
            } else {
                mailboxes = []
            }
            let status = try NodeSyncStatusResult(
                revision: "1", state: "ready", reachability: "reachable", providerIdentity: "user@example.com", assignments: mailboxes
            )
            statusCalls += 1
            return NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: try NodeSyncCodec.encodeStatusResult(status))
        }
        if method == "PUT" && path == "/v1/mailboxes/assignments" {
            let request = try NodeSyncCodec.decodeMailboxAssignmentsRequest(body)
            assignment = try XCTUnwrap(request.assignments.first)
            assignmentRequestCount += 1
            let mailbox = try NodeSyncDiscoveredMailbox(
                displayName: "Inbox", logicalMailboxID: assignment?.logicalMailboxID,
                mailboxHandle: assignment?.mailboxHandle ?? "", role: "inbox"
            )
            let result = try NodeSyncMailboxAssignmentsResult(assignments: [mailbox])
            return NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: try NodeSyncCodec.encodeMailboxAssignmentsResult(result))
        }
        throw NodeSyncClientError.invalidResponse
    }
}

private actor AdapterAssignmentAmbiguitySender: NodeSessionRequestSending {
    private(set) var statusCalls = 0
    private(set) var assignmentRequestCount = 0
    private var assignment: NodeSyncMailboxAssignment?

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let url = URL(string: "https://node.example.ts.net:443\(path)")!
        if method == "GET" && path == "/v1/status" {
            statusCalls += 1
            let assignments: [NodeSyncDiscoveredMailbox]
            if let assignment {
                assignments = [try NodeSyncDiscoveredMailbox(displayName: "Inbox", logicalMailboxID: assignment.logicalMailboxID, mailboxHandle: assignment.mailboxHandle, role: "inbox")]
            } else {
                assignments = []
            }
            let status = try NodeSyncStatusResult(revision: "1", state: "ready", reachability: "reachable", providerIdentity: "user@example.com", assignments: assignments)
            return NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: try NodeSyncCodec.encodeStatusResult(status))
        }
        if method == "PUT" && path == "/v1/mailboxes/assignments" {
            let request = try NodeSyncCodec.decodeMailboxAssignmentsRequest(body)
            assignment = try XCTUnwrap(request.assignments.first)
            assignmentRequestCount += 1
            throw NodeSessionError.transportFailureAfterDispatch
        }
        throw NodeSyncClientError.invalidResponse
    }
}

private actor ProviderControllerTestClient: SyncNodeProviderClient {
    struct Call: Sendable {
        let authorizationCode: String
        let codeVerifier: String
        let clientSecret: String?
    }

    private(set) var lastCall: Call?
    private(set) var callCount = 0

    func configureGoogle(
        authorizationCode: String,
        clientID: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> SyncNodeProviderResult {
        lastCall = Call(authorizationCode: authorizationCode, codeVerifier: codeVerifier, clientSecret: nil)
        callCount += 1
        return SyncNodeProviderResult(providerIdentity: "google:user@example.com", discoveredMailboxes: [])
    }

    func lastCallValue() -> Call? { lastCall }
}

private actor ProviderControllerCancellationClient: SyncNodeProviderClient {
    private var called = false

    func configureGoogle(
        authorizationCode: String,
        clientID: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> SyncNodeProviderResult {
        called = true
        while !Task.isCancelled { await Task.yield() }
        throw CancellationError()
    }

    func waitUntilCalled() async {
        while !called { await Task.yield() }
    }
}

private actor ProviderControllerAssignmentClient: SyncNodeProviderClient {
    private(set) var lastAssignments: [SyncNodeMailboxSelection] = []

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ assignments: [SyncNodeMailboxSelection]) async throws {
        lastAssignments = assignments
    }

    func status() async throws -> SyncNodeStatus {
        return SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed",
            providerIdentity: "user@example.com",
            assignments: lastAssignments.map { SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID) },
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }
}

private actor ProviderControllerTransientReadinessClient: SyncNodeProviderClient {
    private var statusCalls = 0
    private var assignmentStatus: Int?
    private var assignments: [SyncNodeMailboxSelection] = []

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        assignmentStatus = statusCalls
        assignments = selections
    }

    func status() async throws -> SyncNodeStatus {
        statusCalls += 1
        if statusCalls == 1 {
            throw SyncNodeProviderController.Error.providerUnavailable
        }
        let ready = statusCalls >= 3
        return SyncNodeStatus(
            state: ready ? "ready" : "degraded",
            version: "node-sync-v1",
            reachability: ready ? "reachable" : "unreachable",
            syncLag: ready ? "0" : "1",
            storage: "managed",
            providerIdentity: ready ? "user@example.com" : nil,
            assignments: assignments.map {
                SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID)
            },
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }

    func statusCallCount() -> Int { statusCalls }
    func assignmentStatusCall() -> Int? { assignmentStatus }
}

private actor ProviderControllerStatusFailureClient: SyncNodeProviderClient {
    private(set) var assignmentWasCalled = false

    func wasAssignmentCalled() -> Bool { assignmentWasCalled }

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        assignmentWasCalled = true
    }

    func status() async throws -> SyncNodeStatus {
        if !assignmentWasCalled {
            return SyncNodeStatus(
                state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed",
                providerIdentity: "user@example.com", assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
            )
        }
        throw SyncNodeProviderController.Error.providerUnavailable
    }
}

private actor ProviderControllerRetryAssignmentClient: SyncNodeProviderClient {
    private(set) var assignmentCalls: [[SyncNodeMailboxSelection]] = []
    private var statusCalls = 0

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        assignmentCalls.append(selections)
    }

    func status() async throws -> SyncNodeStatus {
        statusCalls += 1
        let assignments = statusCalls >= 4 ? assignmentCalls.last ?? [] : []
        return SyncNodeStatus(state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed", providerIdentity: "user@example.com", assignments: assignments.map { SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID) }, backup: "not_reported", endpoint: "session-scoped", updateStatus: "current")
    }
}

private actor ProviderControllerAlwaysUnavailableClient: SyncNodeProviderClient {
    private(set) var assignmentCalls: [[SyncNodeMailboxSelection]] = []
    private var statusCalls = 0

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        assignmentCalls.append(selections)
    }

    func status() async throws -> SyncNodeStatus {
        statusCalls += 1
        if statusCalls == 1 {
            return SyncNodeStatus(
                state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed",
                providerIdentity: "user@example.com", assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
            )
        }
        throw SyncNodeProviderController.Error.providerUnavailable
    }
}

private actor ProviderControllerMismatchedStatusClient: SyncNodeProviderClient {
    enum Mismatch: Sendable, Equatable {
        case state
        case provider
        case reachability
        case assignments
    }

    private let mismatch: Mismatch
    private(set) var assignmentWasCalled = false
    private var statusCalls = 0

    init(mismatch: Mismatch) {
        self.mismatch = mismatch
    }

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        assignmentWasCalled = true
    }

    func status() async throws -> SyncNodeStatus {
        statusCalls += 1
        let assignments: [SyncNodeProviderMailbox]
        if mismatch == .assignments, statusCalls > 1 {
            assignments = [SyncNodeProviderMailbox(
                displayName: "Sent", mailboxHandle: String(repeating: "B", count: 43), role: "sent"
            )]
        } else {
            assignments = []
        }
        return SyncNodeStatus(
            revision: "2",
            state: mismatch == .state ? "degraded" : "ready",
            version: "node-sync-v1",
            reachability: mismatch == .reachability && statusCalls > 1 ? "unreachable" : "reachable",
            syncLag: "1",
            storage: "managed",
            providerIdentity: mismatch == .provider && statusCalls > 1
                ? "other@example.com"
                : "user@example.com",
            assignments: assignments,
            backup: "not_reported",
            endpoint: "session-scoped",
            updateStatus: "current"
        )
    }
}

private actor ProviderControllerBlockingAssignmentClient: SyncNodeProviderClient {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var committed: [SyncNodeMailboxSelection] = []

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        started = true
        committed = selections
        await withCheckedContinuation { continuation = $0 }
    }

    func status() async throws -> SyncNodeStatus {
        SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed",
            providerIdentity: "user@example.com",
            assignments: committed.map { SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID) },
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }

    func waitUntilAssignmentStarted() async {
        while !started { await Task.yield() }
    }

    func releaseAssignment() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ProviderControllerLostStatusAcknowledgementClient: SyncNodeProviderClient {
    private(set) var statusCalls = 0
    private var committed: [SyncNodeMailboxSelection] = []

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        committed = selections
    }

    func status() async throws -> SyncNodeStatus {
        statusCalls += 1
        if statusCalls == 1 {
            return SyncNodeStatus(
                state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed",
                providerIdentity: "user@example.com", assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
            )
        }
        if statusCalls == 2 { throw SyncNodeProviderController.Error.providerUnavailable }
        return SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed",
            providerIdentity: "user@example.com",
            assignments: committed.map {
                SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID)
            }, backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }
}

private actor ProviderControllerLostAssignmentResponseClient: SyncNodeProviderClient {
    private(set) var statusCalls = 0
    private var committed: [SyncNodeMailboxSelection] = []

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        committed = selections
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func status() async throws -> SyncNodeStatus {
        statusCalls += 1
        return SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed",
            providerIdentity: "user@example.com",
            assignments: statusCalls == 1 ? [] : committed.map {
                SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID)
            }, backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }
}

private actor ProviderControllerCancellationAfterDispatchClient: SyncNodeProviderClient {
    private var started = false
    private var committed: [SyncNodeMailboxSelection] = []

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        started = true
        committed = selections
        throw SyncNodeProviderController.Error.assignmentCancellationAfterDispatch
    }

    func status() async throws -> SyncNodeStatus {
        SyncNodeStatus(state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed", providerIdentity: "user@example.com", assignments: committed.map { SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID) }, backup: "not_reported", endpoint: "session-scoped", updateStatus: "current")
    }

    func waitUntilAssignmentStarted() async {
        while !started { await Task.yield() }
    }
}

private actor ProviderControllerCancellationBeforeDispatchClient: SyncNodeProviderClient {
    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        throw CancellationError()
    }

    func status() async throws -> SyncNodeStatus {
        SyncNodeStatus(state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed", providerIdentity: "user@example.com", assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current")
    }
}

private actor ProviderControllerMappedAmbiguousStatusCancellationClient: SyncNodeProviderClient {
    private var calls = 0

    func statusCallCount() -> Int { calls }

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.assignmentOutcomeAmbiguous
    }

    func status() async throws -> SyncNodeStatus {
        calls += 1
        if calls == 1 {
            return SyncNodeStatus(state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed", providerIdentity: "user@example.com", assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current")
        }
        throw CancellationError()
    }
}

private actor ProviderControllerGenericAmbiguousStatusCancellationClient: SyncNodeProviderClient {
    private var calls = 0

    func statusCallCount() -> Int { calls }

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func status() async throws -> SyncNodeStatus {
        calls += 1
        if calls == 1 {
            return SyncNodeStatus(state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "1", storage: "managed", providerIdentity: "user@example.com", assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current")
        }
        throw CancellationError()
    }
}

private final class ProviderControllerNonCooperativeStatusClient: SyncNodeProviderClient, SyncNodeProviderStatusCancelling, @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var finished = false

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func status() async throws -> SyncNodeStatus {
        while !lock.withLock({ stopRequested }) { await Task.yield() }
        lock.withLock { finished = true }
        throw CancellationError()
    }

    func stop() { lock.withLock { stopRequested = true } }

    func cancelStatusRequests() async { lock.withLock { stopRequested = true } }

    func wasCancellationRequested() -> Bool { lock.withLock { stopRequested } }

    func waitUntilFinished() async {
        while !lock.withLock({ finished }) { await Task.yield() }
    }
}

private actor ProviderControllerStalledStatusCancellationClient: SyncNodeProviderClient, SyncNodeProviderStatusCancelling {
    private var started = false
    private var cancellationStarted = false
    private var cancellationCalls = 0
    private var cancellationFinished = false
    private var releaseCancellation: CheckedContinuation<Void, Never>?

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func status() async throws -> SyncNodeStatus {
        started = true
        while true {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func cancelStatusRequests() async {
        cancellationCalls += 1
        cancellationStarted = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseCancellation = continuation
        }
        cancellationFinished = true
    }

    func waitUntilStarted(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !started && ContinuousClock.now < deadline { await Task.yield() }
        return started
    }

    func waitUntilCancellationStarted(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !cancellationStarted && ContinuousClock.now < deadline { await Task.yield() }
        return cancellationStarted
    }

    func cancellationDrainFinished() -> Bool { cancellationFinished }

    func cancellationCallCount() -> Int { cancellationCalls }

    func releaseCancellationDrain() {
        releaseCancellation?.resume()
        releaseCancellation = nil
    }

    func waitUntilCancellationFinished(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !cancellationFinished && ContinuousClock.now < deadline { await Task.yield() }
        return cancellationFinished
    }
}

private actor ProviderControllerCancellableStatusClient: SyncNodeProviderClient {
    private var called = false
    private var cancelled = false

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func status() async throws -> SyncNodeStatus {
        called = true
        do {
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func waitUntilCalled() async {
        while !called { await Task.yield() }
    }

    func wasCancelled() -> Bool { cancelled }

    func waitUntilCancelled() async {
        while !cancelled { await Task.yield() }
    }
}

private actor ProviderControllerTrackedStatusClient: SyncNodeProviderClient {
    private var started = false
    private var finished = false
    private var active = 0

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func status() async throws -> SyncNodeStatus {
        started = true
        active += 1
        defer {
            active -= 1
            finished = true
        }
        while true {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func waitUntilFinished() async {
        while !finished { await Task.yield() }
    }

    func activeWorkers() -> Int { active }
}

private actor ProviderControllerChangingIdentityClient: SyncNodeProviderClient {
    private var statusCalls = 0
    private var assignmentCalled = false

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        assignmentCalled = true
    }

    func status() async throws -> SyncNodeStatus {
        statusCalls += 1
        return SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0", storage: "managed",
            providerIdentity: statusCalls == 1 ? "provider-a@example.com" : "provider-b@example.com",
            assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }

    func assignmentWasCalled() -> Bool { assignmentCalled }
}

private actor ProviderControllerConfiguredChangingIdentityClient: SyncNodeProviderClient {
    private var assignmentCalled = false

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        SyncNodeProviderResult(providerIdentity: "provider-a@example.com", discoveredMailboxes: [])
    }

    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        assignmentCalled = true
    }

    func status() async throws -> SyncNodeStatus {
        SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0", storage: "managed",
            providerIdentity: "provider-b@example.com", assignments: [], backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }

    func assignmentWasCalled() -> Bool { assignmentCalled }
}

private actor ProviderControllerAlternatingIdentityClient: SyncNodeProviderClient {
    private var calls = 0

    func configureGoogle(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) async throws -> SyncNodeProviderResult {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.providerUnavailable
    }

    func status() async throws -> SyncNodeStatus {
        calls += 1
        return SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0", storage: "managed",
            providerIdentity: calls == 1 ? "provider-a@example.com" : "provider-b@example.com", assignments: [],
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )
    }
}

private final class AdapterScopedStatusSender: NodeSessionRequestScopedSending, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var finished = false
    private var waiter: CheckedContinuation<NodeHTTPResponse, Error>?

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSyncClientError.transport
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        cancellation.install { [weak self] in self?.cancel() }
        defer { cancellation.markCompleted() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NodeHTTPResponse, Error>) in
            lock.withLock {
                started = true
                waiter = continuation
            }
        }
    }

    private func cancel() {
        let continuation: CheckedContinuation<NodeHTTPResponse, Error>? = lock.withLock {
            cancelled = true
            finished = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(throwing: CancellationError())
    }

    func waitUntilStarted() async {
        await waitUntil { self.lock.withLock { self.started } }
    }

    func waitUntilFinished() async {
        await waitUntil { self.lock.withLock { self.finished } }
    }

    /// Polls against a deadline rather than spinning on yields.
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition did not become true") }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func wasCancelled() -> Bool { lock.withLock { cancelled } }

    func wasStarted() -> Bool { lock.withLock { started } }
}

private final class ConcurrentAdapterStatusSender: NodeSessionRequestScopedSending, @unchecked Sendable {
    private struct Request {
        let id: Int
        var continuation: CheckedContinuation<NodeHTTPResponse, Error>?
        var cancelled = false
        var finished = false
    }

    private let lock = NSLock()
    private var nextID = 0
    private var requests: [Request] = []
    private let successfulResponse: NodeHTTPResponse

    init() {
        let status = try! NodeSyncStatusResult(
            revision: "1", state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0",
            storage: "managed", providerIdentity: "provider-a@example.com", assignments: [], backup: "not_reported",
            endpoint: "session-scoped", updateStatus: "current"
        )
        successfulResponse = NodeHTTPResponse(
            statusCode: 200, url: URL(string: "https://node.example.test/v1/status")!, headers: [:],
            body: try! NodeSyncCodec.encodeStatusResult(status)
        )
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSyncClientError.transport
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        let id = lock.withLock {
            defer { nextID += 1 }
            let id = nextID
            requests.append(Request(id: id, continuation: nil))
            return id
        }
        cancellation.install { [weak self] in self?.cancel(id: id) }
        defer {
            cancellation.markCompleted()
            lock.withLock {
                guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
                requests[index].finished = true
            }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NodeHTTPResponse, Error>) in
            let cancelled = lock.withLock {
                guard let index = requests.firstIndex(where: { $0.id == id }) else { return true }
                if requests[index].cancelled {
                    requests[index].finished = true
                    return true
                }
                requests[index].continuation = continuation
                return false
            }
            if cancelled { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func cancel(id: Int) {
        let continuation: CheckedContinuation<NodeHTTPResponse, Error>? = lock.withLock {
            guard let index = requests.firstIndex(where: { $0.id == id }), !requests[index].finished else { return nil }
            requests[index].cancelled = true
            requests[index].finished = true
            defer { requests[index].continuation = nil }
            return requests[index].continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func waitUntilStarted(count: Int) async {
        while lock.withLock({ requests.count < count }) { await Task.yield() }
    }

    func releaseUncancelled() {
        let continuation: CheckedContinuation<NodeHTTPResponse, Error>? = lock.withLock {
            guard let index = requests.firstIndex(where: { !$0.cancelled && !$0.finished && $0.continuation != nil }) else { return nil }
            requests[index].finished = true
            defer { requests[index].continuation = nil }
            return requests[index].continuation
        }
        continuation?.resume(returning: successfulResponse)
    }

    func cancelledCount() -> Int { lock.withLock { requests.filter(\.cancelled).count } }

    func waitUntilCancelled(count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while cancelledCount() < count && ContinuousClock.now < deadline { await Task.yield() }
        return cancelledCount() >= count
    }

    func finishedCount() -> Int { lock.withLock { requests.filter(\.finished).count } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () -> Bool,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() && ContinuousClock.now < deadline { await Task.yield() }
    return condition()
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch { }
}
