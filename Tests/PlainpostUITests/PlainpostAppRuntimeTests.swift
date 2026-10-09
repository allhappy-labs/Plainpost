import XCTest
import SwiftUI
import Combine
import CryptoKit
import AuthenticationServices
@testable import PlainpostAI
import PlainpostBrowserIntegration
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostLocalAPI
@testable import PlainpostLocalServer
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
import PlainpostTestSupport
import PlainpostRuntimeTestSupport
import PlainpostAccountProtocol
import PlainpostAccountRuntime
@testable import PlainpostUI

final class PlainpostAppRuntimeTests: XCTestCase {
    @MainActor
    func testSmartInboxReenableRequestsPendingMailOnceAndShutdownJoinsOwnedRequest() async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("pp-se-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "SmartInboxReenable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSmartInboxMode(.off)
        let client = SuspendedMaintenanceOperationClient()
        let runtime = try PlainpostAppRuntime(configuration: selectedDirectRuntimeConfiguration(
            databaseURL: directory.appendingPathComponent("mail.sqlite"),
            keychainService: "SmartInboxReenable.\(UUID().uuidString)", account: PlainpostFixtures.personalAccount),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in client }, aiProviderPreferences: preferences)
        let settings = runtime.makeAIProviderSettingsViewModel()
        settings.setSmartInboxMode(.allMail)
        settings.setSmartInboxMode(.allMail)
        let started = await client.waitUntilAICallStarts()
        XCTAssertTrue(started)
        let callCount = await client.aiCallCount
        let input = await client.lastAIInput
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(input?.operation, .recategorizeInbox)
        XCTAssertEqual(input?.accountID, PlainpostFixtures.personalAccount.id)
        XCTAssertNotNil(input?.expectedDirectSourceGeneration)
        XCTAssertEqual(input?.smartInboxRunMode, .incremental)
        XCTAssertEqual(input?.enqueueOnly, false)
        let completion = SmartInboxRuntimeShutdownCompletion()
        let closing = Task { await runtime.shutdown(); await completion.markFinished() }
        for _ in 0..<100 {
            if await client.cancellationCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let cancellations = await client.cancellationCount
        let closedBeforeJoin = await completion.finished
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(closedBeforeJoin)
        await client.releaseFirstAICall()
        await closing.value
        let closed = await completion.finished
        XCTAssertTrue(closed)
        XCTAssertTrue(try runtime.store.smartInboxEnabled())
        XCTAssertTrue(preferences.smartInboxEnabled())
    }

    @MainActor
    func testSmartInboxReadonlyPreferenceMirrorsBeforeWritableOwnerConstructionAcrossStores() async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("pp-si-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "SmartInboxRuntime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        let isolation = RuntimeKeychainIsolation(testCase: self,
            databaseURL: directory.appendingPathComponent("cached.sqlite"),
            keychainService: "SmartInboxRuntime.\(UUID().uuidString)")
        let seed = try SQLiteMailStore(path: isolation.configuration.databaseURL.path)
        try seed.migrate()
        let readonly = try PlainpostAppRuntime(configuration: isolation.configuration,
            notificationScheduler: NoopLocalNotificationScheduler(),
            packagedOperationWorkerSignalFactory: { XCTFail("Readonly constructed worker"); return nil },
            browserNativeHostStartup: { _ in XCTFail("Readonly started browser") },
            accountAccess: .cachedReadOnly, aiProviderPreferences: preferences)
        let settings = readonly.makeAIProviderSettingsViewModel()
        XCTAssertTrue(settings === readonly.makeAIProviderSettingsViewModel())
        settings.setSmartInboxMode(.off)
        XCTAssertFalse(settings.smartInboxEnabled)
        XCTAssertTrue(try seed.smartInboxEnabled(), "Readonly must never write worker policy")
        XCTAssertEqual(isolation.runtimeDependencies.constructionCallCount, 0)
        await readonly.shutdown()
        for name in ["cached.sqlite", "switched.sqlite"] {
            let configuration = PlainpostAppRuntimeConfiguration(
                databaseURL: directory.appendingPathComponent(name), serviceClient: RuntimeServiceClientFake())
            var factorySawDisabledPolicy = false
            let writable = try PlainpostAppRuntime(configuration: configuration,
                notificationScheduler: NoopLocalNotificationScheduler(),
                packagedOperationWorkerSignalFactory: {
                    let service = try! SQLiteMailStore(path: configuration.databaseURL.path)
                    factorySawDisabledPolicy = (try? service.smartInboxEnabled()) == false
                    return nil
                }, browserNativeHostStartup: { _ in }, aiProviderPreferences: preferences)
            XCTAssertTrue(factorySawDisabledPolicy)
            XCTAssertFalse(writable.makeAIProviderSettingsViewModel().smartInboxEnabled)
            await writable.shutdown()
        }
        XCTAssertFalse(try seed.smartInboxEnabled())
    }

    func testSelectedDirectAccountIdentityDoesNotUseFirstAccount() {
        let first = Account(
            id: AccountID("first"), displayName: "First", email: EmailAddress("first@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let second = Account(
            id: AccountID("second"), displayName: "Second", email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )

        XCTAssertEqual(
            PlainpostAppRuntime.projectedAccount(in: [first, second], selectedAccountID: second.id)?.id,
            second.id
        )
        XCTAssertNil(PlainpostAppRuntime.projectedAccount(
            in: [first, second], selectedAccountID: AccountID("missing")
        ))
        XCTAssertEqual(PlainpostAppRuntime.projectedAccount(
            in: [first, second], selectedAccountID: nil
        )?.id, first.id)
    }

    @MainActor func testAccountRootOwnsPendingFlowFromWaitingThroughMatchingCodeAndAdmission() async throws {
        let subject = PassthroughSubject<AccountAdmissionController.State, Never>()
        let lifecycle = AccountFlowLifecycleRecorder()
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            mode: .pending
        )
        let flow = AccountPendingAdmissionFlow(
            states: subject.eraseToAnyPublisher(),
            start: { _ in lifecycle.start() },
            cancel: { lifecycle.cancel() }
        )
        let model = AccountSessionViewModel(
            prepareSession: { _ in .provisional(activation) },
            admissionFactory: { _ in flow }
        )

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where lifecycle.starts == 0 { await Task.yield() }
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(model.presentation, .pendingApproval(matchingCode: nil))

        subject.send(.matchingCode("123456"))
        XCTAssertEqual(model.presentation.matchingCodeDisplay, "123 456")
        subject.send(.admitted)
        XCTAssertEqual(model.presentation, .active)

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_001))
        for _ in 0 ..< 100 where lifecycle.cancels == 0 { await Task.yield() }
        XCTAssertEqual(lifecycle.cancels, 1)
    }

    @MainActor func testAccountRootOwnsActiveDiscoveryConfirmationAndSingleUseLocalApproval() async throws {
        let subject = PassthroughSubject<AccountActiveAdmissionController.State, Never>()
        let lifecycle = AccountFlowLifecycleRecorder()
        let approvals = AccountApprovalRecorder()
        let context = try AccountDeviceApprovalContext(
            pendingID: "pending-app-flow",
            offerDigest: Data(repeating: 0x31, count: 32),
            responseDigest: Data(repeating: 0x32, count: 32),
            generation: 1,
            matchingCode: "654321",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_060)
        )
        let capability = AccountDeviceApprovalCapability(
            context: context,
            approve: { await approvals.record(context) },
            cancel: {}
        )
        let flow = AccountActiveAdmissionFlow(
            states: subject.eraseToAnyPublisher(),
            refresh: { lifecycle.refresh() },
            begin: { _ in lifecycle.begin() },
            currentApprovalCapability: { capability },
            cancel: { lifecycle.cancel() }
        )
        let model = AccountSessionViewModel(
            prepareSession: { _ in .active },
            activeAdmissionFactory: { flow },
            localApprovalAuthenticator: AllowingAccountAuthenticator()
        )

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where lifecycle.refreshes == 0 { await Task.yield() }
        XCTAssertEqual(lifecycle.refreshes, 1)

        let pending = AccountActiveAdmissionController.PendingPrompt(selection: 0, platform: .ios, requestID: "request-app-flow")
        subject.send(.idle([pending]))
        XCTAssertEqual(model.pendingApprovalPrompt, pending)
        model.beginApproval()
        XCTAssertEqual(lifecycle.begins, 1)
        subject.send(.awaitingResponse)

        let prompt = AccountActiveAdmissionController.ConfirmationPrompt(
            matchingCode: context.matchingCode,
            expiresAt: context.expiresAt
        )
        subject.send(.awaitingConfirmation(prompt))
        XCTAssertEqual(model.deviceApprovalPrompt, prompt)
        model.confirmApproval()
        await model.waitForDeviceApprovalToSettle()
        let approvalCount = await approvals.count
        XCTAssertEqual(approvalCount, 1)
    }

    @MainActor private func makeActiveApprovalModel() async -> (
        model: AccountSessionViewModel,
        subject: PassthroughSubject<AccountActiveAdmissionController.State, Never>,
        lifecycle: AccountFlowLifecycleRecorder
    ) {
        let subject = PassthroughSubject<AccountActiveAdmissionController.State, Never>()
        let lifecycle = AccountFlowLifecycleRecorder()
        let flow = AccountActiveAdmissionFlow(
            states: subject.eraseToAnyPublisher(),
            refresh: { lifecycle.refresh() },
            begin: { _ in lifecycle.begin() },
            currentApprovalCapability: { nil },
            cancel: { lifecycle.cancel() }
        )
        let model = AccountSessionViewModel(
            prepareSession: { _ in .active },
            activeAdmissionFactory: { flow },
            localApprovalAuthenticator: AllowingAccountAuthenticator()
        )
        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where lifecycle.refreshes == 0 { await Task.yield() }
        return (model, subject, lifecycle)
    }

    @MainActor func testPendingDeviceReviewShowsProgressBlocksReentryAndSurfacesRetryableFailure() async throws {
        let (model, subject, lifecycle) = await makeActiveApprovalModel()
        let pending = AccountActiveAdmissionController.PendingPrompt(selection: 0, platform: .macos, requestID: "request-a")
        subject.send(.idle([pending]))
        XCTAssertEqual(model.pendingDeviceApproval, .review(pending))

        model.beginApproval()
        XCTAssertEqual(lifecycle.begins, 1)
        XCTAssertEqual(model.pendingDeviceApproval, .contacting(pending))
        subject.send(.awaitingResponse)
        XCTAssertEqual(model.pendingDeviceApproval, .contacting(pending))
        model.beginApproval()
        model.dismissPendingDeviceApproval()
        XCTAssertEqual(lifecycle.begins, 1, "A review in flight must not be re-entered.")
        XCTAssertEqual(model.pendingDeviceApproval, .contacting(pending))

        subject.send(.failed(.unreachable))
        XCTAssertEqual(model.pendingDeviceApproval, .failed(.unreachable, retry: pending))
        XCTAssertEqual(model.pendingApprovalPrompt, pending)

        model.beginApproval()
        XCTAssertEqual(lifecycle.begins, 2)
        XCTAssertEqual(model.pendingDeviceApproval, .contacting(pending))
        subject.send(.failed(.other))
        XCTAssertEqual(model.pendingDeviceApproval, .failed(.other, retry: pending))
    }

    @MainActor func testExpiredPendingDeviceReviewClearsTheDeadRequestAndDismissRefreshesTheList() async throws {
        let (model, subject, lifecycle) = await makeActiveApprovalModel()
        let expired = AccountActiveAdmissionController.PendingPrompt(selection: 0, platform: .ios, requestID: "request-expired")
        subject.send(.idle([expired]))
        model.beginApproval()
        subject.send(.awaitingResponse)
        subject.send(.failed(.expired))

        XCTAssertNil(model.pendingApprovalPrompt)
        XCTAssertEqual(model.pendingDeviceApproval, .failed(.expired, retry: nil))
        model.beginApproval()
        XCTAssertEqual(lifecycle.begins, 1)

        model.dismissPendingDeviceApproval()
        XCTAssertEqual(model.pendingDeviceApproval, .hidden)
        XCTAssertEqual(lifecycle.refreshes, 2)

        subject.send(.idle([expired]))
        XCTAssertNil(model.pendingApprovalPrompt, "A dead request must not reappear from a stale list.")
        XCTAssertEqual(model.pendingDeviceApproval, .hidden)

        let fresh = AccountActiveAdmissionController.PendingPrompt(selection: 1, platform: .ios, requestID: "request-fresh")
        subject.send(.idle([expired, fresh]))
        XCTAssertEqual(model.pendingDeviceApproval, .review(fresh))
    }

    @MainActor func testDismissingPendingDeviceReviewHidesOnlyThatRequestForTheSession() async throws {
        let (model, subject, lifecycle) = await makeActiveApprovalModel()
        let first = AccountActiveAdmissionController.PendingPrompt(selection: 0, platform: .macos, requestID: "request-first")
        let second = AccountActiveAdmissionController.PendingPrompt(selection: 1, platform: .ios, requestID: "request-second")
        subject.send(.idle([first, second]))
        XCTAssertEqual(model.pendingDeviceApproval, .review(first))

        model.dismissPendingDeviceApproval()
        XCTAssertEqual(model.pendingDeviceApproval, .review(second))
        XCTAssertEqual(model.pendingApprovalPrompt, second)
        model.dismissPendingDeviceApproval()
        XCTAssertEqual(model.pendingDeviceApproval, .hidden)
        XCTAssertNil(model.pendingApprovalPrompt)
        model.beginApproval()
        XCTAssertEqual(lifecycle.begins, 0)

        subject.send(.idle([first, second]))
        XCTAssertEqual(model.pendingDeviceApproval, .hidden)

        // A background list refresh failure is not a review attempt and must
        // not surface an error over the mailbox.
        subject.send(.failed(.unreachable))
        XCTAssertEqual(model.pendingDeviceApproval, .hidden)

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_010))
        for _ in 0 ..< 100 where lifecycle.refreshes < 2 { await Task.yield() }
        subject.send(.idle([first, second]))
        XCTAssertEqual(model.pendingDeviceApproval, .hidden, "Dismissal lasts for the app session.")

        let third = AccountActiveAdmissionController.PendingPrompt(selection: 2, platform: .macos, requestID: "request-third")
        subject.send(.idle([first, second, third]))
        XCTAssertEqual(model.pendingDeviceApproval, .review(third))
    }

    func testPendingDeviceReviewCopyUsesHumanPlatformNamesAndBoundedFailureMessages() {
        XCTAssertEqual(AccountPlatform.macos.deviceDisplayName, "Mac")
        XCTAssertEqual(AccountPlatform.ios.deviceDisplayName, "iPhone or iPad")
        XCTAssertEqual(AccountPlatform.syncNode.deviceDisplayName, "Sync Node")
        XCTAssertEqual(
            PendingDeviceApprovalPresentation.reviewTitle(for: .init(selection: 0, platform: .macos, requestID: "a")),
            "Review new Mac"
        )
        XCTAssertEqual(
            PendingDeviceApprovalPresentation.reviewTitle(for: .init(selection: 0, platform: .syncNode, requestID: "b")),
            "Review new Sync Node"
        )
        XCTAssertEqual(PendingDeviceApprovalPresentation.contactingMessage, "Contacting the new device…")
        let messages: [AccountActiveAdmissionController.FailureReason: String] = [
            .expired: AccountActiveAdmissionController.FailureReason.expired.userMessage,
            .unreachable: AccountActiveAdmissionController.FailureReason.unreachable.userMessage,
            .other: AccountActiveAdmissionController.FailureReason.other.userMessage,
        ]
        XCTAssertEqual(Set(messages.values).count, 3)
        for message in messages.values {
            XCTAssertFalse(message.isEmpty)
            XCTAssertLessThanOrEqual(message.count, 90)
            XCTAssertFalse(message.contains("macos") || message.contains("sync_node") || message.contains("Error"))
        }
    }

    @MainActor func testActiveRootRegistersCleanupCapabilityButOfflineRootStartsNoRegistrationTraffic() async throws {
        let recorder = CleanupRegistrationRecorder()
        let active = AccountSessionViewModel(
            prepareSession: { _ in .active },
            activeCleanupRegistration: { await recorder.record() }
        )
        active.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        await recorder.waitForCount(1)
        let activeCount = await recorder.currentCount()
        XCTAssertEqual(activeCount, 1)

        let offline = AccountSessionViewModel(
            prepareSession: { _ in .offlineLease(expiresAt: Date(timeIntervalSince1970: 1_900_000_100)) },
            activeCleanupRegistration: { await recorder.record() }
        )
        offline.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 50 { await Task.yield() }
        let offlineCount = await recorder.currentCount()
        XCTAssertEqual(offlineCount, 1)
    }

    func testAccountRootPresentationBlocksMailboxUntilSessionAuthorizesReading() {
        XCTAssertFalse(AccountSessionViewModel.Presentation.signInRequired.allowsMailbox)
        XCTAssertFalse(AccountSessionViewModel.Presentation.pendingApproval(matchingCode: nil).allowsMailbox)
        XCTAssertTrue(AccountSessionViewModel.Presentation.active.allowsMailbox)
        XCTAssertTrue(AccountSessionViewModel.Presentation.offlineLease(expiresAt: Date(timeIntervalSince1970: 1_900_000_000)).allowsMailbox)
        XCTAssertFalse(AccountSessionViewModel.Presentation.suspended.allowsMailbox)
        XCTAssertFalse(AccountSessionViewModel.Presentation.cleanupRequired.allowsMailbox)
        XCTAssertFalse(AccountSessionViewModel.Presentation.deleted.allowsMailbox)
        XCTAssertFalse(AccountSessionViewModel.Presentation.recoveryRequired.allowsMailbox)
    }

    @MainActor func testIncompleteGenesisNeverUsesPendingApprovalPresentation() throws {
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            mode: .genesis
        )
        XCTAssertEqual(
            AccountSessionViewModel.presentation(
                for: .provisional(activation),
                now: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            .recoveryRequired
        )
    }

    func testPendingAccountRootFormatsOnlyTheSixDigitMatchingCode() {
        XCTAssertEqual(
            AccountSessionViewModel.Presentation.pendingApproval(matchingCode: "123456").matchingCodeDisplay,
            "123 456"
        )
        XCTAssertNil(AccountSessionViewModel.Presentation.pendingApproval(matchingCode: nil).matchingCodeDisplay)
        XCTAssertNil(AccountSessionViewModel.Presentation.pendingApproval(matchingCode: "raw-identity-token").matchingCodeDisplay)
    }

    func testOfflineAccountRootExposesLeaseExpiryWithoutUnlockingExpiredState() {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertEqual(AccountSessionViewModel.Presentation.offlineLease(expiresAt: expiry).offlineLeaseExpiry, expiry)
        XCTAssertNil(AccountSessionViewModel.Presentation.recoveryRequired.offlineLeaseExpiry)
    }

    @MainActor
    func testOfflineAccountRootClosesAtExactLeaseExpiryWithoutAnotherPrepare() async throws {
        let expiry = Date().addingTimeInterval(1)
        let model = AccountSessionViewModel(prepareSession: { _ in
            .offlineLease(expiresAt: expiry)
        })

        model.prepare(now: Date())
        for _ in 0..<50 where model.presentation != .offlineLease(expiresAt: expiry) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.presentation, .offlineLease(expiresAt: expiry))
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(model.presentation, .recoveryRequired)
    }

    @MainActor func testAppleSignInNonceIsFreshCanonicalAndExactlyThirtyTwoBytes() throws {
        var values = [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { values.removeFirst() },
            bootstrapAppleCredential: { _, _ in .active }
        )

        let first = try model.beginAppleSignIn()
        let second = try model.beginAppleSignIn()

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertFalse(first.nonce.contains("="))
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(first.nonce).count, 32)
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(second.nonce).count, 32)
    }

    /// A device another device's recovery suspended can sign in again like a new one.
    @MainActor func testASuspendedDeviceCanSignInAgain() async throws {
        let model = AccountSessionViewModel(
            prepareSession: { _ in .suspended },
            discardSuspendedSession: { _ in .signInRequired }
        )
        model.prepare(now: Date())
        for _ in 0..<200 where model.presentation != .suspended { await Task.yield() }
        XCTAssertEqual(model.presentation, .suspended)
        XCTAssertTrue(model.canSignInAgainAfterSuspension)

        model.signInAgainAfterSuspension()
        for _ in 0..<200 where model.presentation != .signInRequired { await Task.yield() }

        XCTAssertEqual(model.presentation, .signInRequired)
    }

    @MainActor func testAppleSignInRejectsStaleCallbackAndNeverPublishesIdentityToken() async throws {
        let recorder = AppleBootstrapRecorder()
        var values = [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { values.removeFirst() },
            bootstrapAppleCredential: { token, nonce in
                await recorder.record(token: token, nonce: nonce)
                return .active
            }
        )
        let stale = try model.beginAppleSignIn()
        let current = try model.beginAppleSignIn()

        model.submitAppleIdentityToken(Data("stale.token".utf8), for: stale.id)
        model.submitAppleIdentityToken(Data("current.token".utf8), for: current.id)
        await recorder.waitForCount(1)

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.token), ["current.token"])
        XCTAssertFalse(String(describing: model.presentation).contains("current.token"))
    }

    /// The completed sign-in stays available (in memory) so a recovery that follows doesn't
    /// ask Apple again; it's never part of the presentation.
    @MainActor func testCompletedAppleSignInIsKeptForRecoveryOnly() async throws {
        let nonce = Data(repeating: 3, count: 32)
        let recorder = AppleBootstrapRecorder()
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { nonce },
            bootstrapAppleCredential: { token, nonce in
                await recorder.record(token: token, nonce: nonce)
                return .active
            }
        )
        XCTAssertNil(model.appleSignInForRecovery())
        let request = try model.beginAppleSignIn()

        model.submitAppleIdentityToken(Data("first.sign.in".utf8), for: request.id)
        await recorder.waitForCount(1)
        for _ in 0..<200 where model.appleSignInForRecovery() == nil { await Task.yield() }

        let signIn = try XCTUnwrap(model.appleSignInForRecovery())
        XCTAssertEqual(signIn.identityToken, "first.sign.in")
        XCTAssertEqual(signIn.rawNonce, nonce)
        XCTAssertNil(model.appleSignInForRecovery(now: Date().addingTimeInterval(10 * 60)))
        XCTAssertFalse(String(describing: model.presentation).contains("first.sign.in"))
    }

    @MainActor func testAppleSignInRemainsBusyThroughBootstrapAndDuplicateSubmissionDispatchesOnce() async throws {
        let gate = ControlledAppleBootstrapGate()
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { Data(repeating: 0x31, count: 32) },
            bootstrapAppleCredential: { _, _ in try await gate.run() }
        )
        let request = try model.beginAppleSignIn()

        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)
        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)
        await gate.waitForCount(1)

        XCTAssertTrue(model.isAppleSignInInFlight)
        XCTAssertNil(model.appleSignInErrorMessage)
        let callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)
        var presentationWhenBusyFirstCleared: [AccountSessionViewModel.Presentation] = []
        let busyObservation = model.$isAppleSignInInFlight
            .dropFirst()
            .sink { isInFlight in
                if !isInFlight { presentationWhenBusyFirstCleared.append(model.presentation) }
            }

        await gate.resolve(0, with: .success(.active))
        for _ in 0 ..< 100 where model.presentation != .active { await Task.yield() }
        XCTAssertEqual(model.presentation, .active)
        XCTAssertFalse(model.isAppleSignInInFlight)
        XCTAssertEqual(presentationWhenBusyFirstCleared, [.active])
        withExtendedLifetime(busyObservation) {}
    }

    @MainActor func testAppleSignInBeginCannotReplaceBootstrapInFlight() async throws {
        let gate = ControlledAppleBootstrapGate()
        var nonceCalls = 0
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: {
                nonceCalls += 1
                return Data(repeating: UInt8(nonceCalls), count: 32)
            },
            bootstrapAppleCredential: { _, _ in try await gate.run() }
        )
        let request = try model.beginAppleSignIn()
        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)
        await gate.waitForCount(1)

        XCTAssertThrowsError(try model.beginAppleSignIn())
        XCTAssertEqual(nonceCalls, 1)
        XCTAssertTrue(model.isAppleSignInInFlight)
        XCTAssertNil(model.appleSignInErrorMessage)

        await gate.resolve(0, with: .success(.active))
        for _ in 0 ..< 100 where model.presentation != .active { await Task.yield() }
        XCTAssertEqual(model.presentation, .active)
    }

    @MainActor func testStaleAppleBootstrapSuccessCannotClearCurrentAttempt() async throws {
        let gate = ControlledAppleBootstrapGate()
        var nonces = [Data(repeating: 0x41, count: 32), Data(repeating: 0x42, count: 32)]
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { nonces.removeFirst() },
            bootstrapAppleCredential: { _, _ in try await gate.run() }
        )
        let stale = try model.beginAppleSignIn()
        model.submitAppleIdentityToken(Data("stale.token".utf8), for: stale.id)
        await gate.waitForCount(1)
        model.cancelAppleSignIn()
        let current = try model.beginAppleSignIn()
        model.submitAppleIdentityToken(Data("current.token".utf8), for: current.id)
        await gate.waitForCount(2)

        await gate.resolve(0, with: .success(.active))
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(model.presentation, .signInRequired)
        XCTAssertTrue(model.isAppleSignInInFlight)
        XCTAssertNil(model.appleSignInErrorMessage)

        await gate.resolve(1, with: .success(.active))
        for _ in 0 ..< 100 where model.presentation != .active { await Task.yield() }
        XCTAssertEqual(model.presentation, .active)
        XCTAssertFalse(model.isAppleSignInInFlight)
    }

    @MainActor func testStaleAppleBootstrapFailureCannotPublishErrorOrClearCurrentAttempt() async throws {
        let gate = ControlledAppleBootstrapGate()
        var nonces = [Data(repeating: 0x51, count: 32), Data(repeating: 0x52, count: 32)]
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { nonces.removeFirst() },
            bootstrapAppleCredential: { _, _ in try await gate.run() }
        )
        let stale = try model.beginAppleSignIn()
        model.submitAppleIdentityToken(Data("stale.token".utf8), for: stale.id)
        await gate.waitForCount(1)
        model.cancelAppleSignIn()
        let current = try model.beginAppleSignIn()
        model.submitAppleIdentityToken(Data("current.token".utf8), for: current.id)
        await gate.waitForCount(2)

        await gate.resolve(0, with: .failure(AppleBootstrapTestError.failed))
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertTrue(model.isAppleSignInInFlight)
        XCTAssertNil(model.appleSignInErrorMessage)

        await gate.resolve(1, with: .success(.active))
        for _ in 0 ..< 100 where model.presentation != .active { await Task.yield() }
        XCTAssertEqual(model.presentation, .active)
        XCTAssertFalse(model.isAppleSignInInFlight)
    }

    @MainActor func testAppleAuthorizationCancellationReturnsToQuietRetryableIdle() throws {
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { Data(repeating: 0x61, count: 32) },
            bootstrapAppleCredential: { _, _ in .active }
        )
        let request = try model.beginAppleSignIn()
        let cancellation = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.Code.canceled.rawValue
        )

        model.completeAppleAuthorization(.failure(cancellation), for: request.id)

        XCTAssertEqual(model.presentation, .signInRequired)
        XCTAssertFalse(model.isAppleSignInInFlight)
        XCTAssertNil(model.appleSignInErrorMessage)
        _ = try model.beginAppleSignIn()
    }

    @MainActor func testAppleAuthorizationFailurePublishesSafeRetryableError() throws {
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { Data(repeating: 0x62, count: 32) },
            bootstrapAppleCredential: { _, _ in .active }
        )
        let request = try model.beginAppleSignIn()
        let failure = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.Code.failed.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "sensitive provider detail"]
        )

        model.completeAppleAuthorization(.failure(failure), for: request.id)

        XCTAssertEqual(model.appleSignInErrorMessage, "Sign in couldn’t be completed. Try again.")
        XCTAssertFalse(model.appleSignInErrorMessage?.contains("sensitive") ?? true)
        XCTAssertFalse(model.isAppleSignInInFlight)
        _ = try model.beginAppleSignIn()
        XCTAssertNil(model.appleSignInErrorMessage)
    }

    @MainActor func testAppleNonceFailurePublishesSafeErrorWithoutLeavingBusyAttempt() throws {
        var shouldFail = true
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: {
                if shouldFail { throw AppleBootstrapTestError.failed }
                return Data(repeating: 0x63, count: 32)
            },
            bootstrapAppleCredential: { _, _ in .active }
        )

        XCTAssertThrowsError(try model.beginAppleSignIn())
        XCTAssertFalse(model.isAppleSignInInFlight)
        XCTAssertEqual(model.appleSignInErrorMessage, "Sign in couldn’t be completed. Try again.")

        shouldFail = false
        _ = try model.beginAppleSignIn()
        XCTAssertTrue(model.isAppleSignInInFlight)
        XCTAssertNil(model.appleSignInErrorMessage)
    }

    @MainActor func testAppleBootstrapFailureShowsErrorAndFreshRetryCanBecomeActive() async throws {
        let gate = ControlledAppleBootstrapGate()
        var nonces = [Data(repeating: 0x71, count: 32), Data(repeating: 0x72, count: 32)]
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            nonceGenerator: { nonces.removeFirst() },
            bootstrapAppleCredential: { _, _ in try await gate.run() }
        )
        let first = try model.beginAppleSignIn()
        model.submitAppleIdentityToken(Data("first.token".utf8), for: first.id)
        await gate.waitForCount(1)
        await gate.resolve(0, with: .failure(AppleBootstrapTestError.failed))
        for _ in 0 ..< 100 where model.isAppleSignInInFlight { await Task.yield() }

        XCTAssertEqual(model.presentation, .signInRequired)
        XCTAssertEqual(model.appleSignInErrorMessage, "Sign in couldn’t be completed. Try again.")

        let retry = try model.beginAppleSignIn()
        XCTAssertNil(model.appleSignInErrorMessage)
        model.submitAppleIdentityToken(Data("retry.token".utf8), for: retry.id)
        await gate.waitForCount(2)
        await gate.resolve(1, with: .success(.active))
        for _ in 0 ..< 100 where model.presentation != .active { await Task.yield() }

        XCTAssertEqual(model.presentation, .active)
        XCTAssertFalse(model.isAppleSignInInFlight)
        XCTAssertNil(model.appleSignInErrorMessage)
    }

    @MainActor func testPrepareCancelsAppleBootstrapAndStaleCompletionCannotPublishOrReuseNonce() async throws {
        let gate = NonCooperativeAppleBootstrapGate()
        let model = AccountSessionViewModel(
            prepareSession: { _ in .suspended },
            nonceGenerator: { Data(repeating: 0x55, count: 32) },
            bootstrapAppleCredential: { _, _ in await gate.run(); return .active }
        )
        let request = try model.beginAppleSignIn()
        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)
        await gate.waitUntilStarted()

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where model.presentation != .suspended { await Task.yield() }
        XCTAssertEqual(model.presentation, .suspended)
        XCTAssertFalse(model.isAppleSignInInFlight)

        await gate.finish()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(model.presentation, .suspended)
        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)
        let callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)
    }

    @MainActor func testSecurityAppleAttemptRejectsStaleCallbackAndClearsNonceOnEveryTerminalPath() throws {
        let model = AccountSecurityViewModel(
            controllerFactory: { throw AccountRuntimeError.untrustedResponse },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA1, count: 32) }
        )
        let target = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let stale = try model.begin(.revoke(target))
        let current = try model.begin(.revoke(target))
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(current.nonce), Data(repeating: 0xA1, count: 32))

        model.submitAppleIdentityToken(Data("stale-token".utf8), for: stale.id)
        XCTAssertTrue(model.hasPendingAppleAuthorization)
        XCTAssertNil(model.errorMessage)

        model.submitAppleIdentityToken(Data([0xFF]), for: current.id)
        XCTAssertFalse(model.hasPendingAppleAuthorization)
        XCTAssertEqual(model.errorMessage, "Apple authorization was cancelled.")

        _ = try model.begin(.deleteAccount)
        XCTAssertTrue(model.hasPendingAppleAuthorization)
        model.cancel()
        XCTAssertFalse(model.hasPendingAppleAuthorization)
    }

    @MainActor func testAccountGateConstructsMailboxOnlyForActiveOrUnexpiredOfflineAndTearsDownOnExit() async throws {
        var constructions: [AccountMailboxRuntimeGate<String>.Access] = []
        var teardowns: [String] = []
        let gate = AccountMailboxRuntimeGate<String>(
            makeRuntime: { access in
                constructions.append(access)
                return "runtime-\(constructions.count)"
            },
            tearDown: { teardowns.append($0) }
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        try await gate.transition(to: .signInRequired, now: now)
        try await gate.transition(to: .pendingApproval(matchingCode: "123456"), now: now)
        try await gate.transition(to: .suspended, now: now)
        try await gate.transition(to: .recoveryRequired, now: now)
        XCTAssertTrue(constructions.isEmpty)
        XCTAssertNil(gate.runtime)

        try await gate.transition(to: .active, now: now)
        XCTAssertEqual(constructions, [.readWrite])
        XCTAssertEqual(gate.runtime, "runtime-1")

        try await gate.transition(to: .suspended, now: now)
        XCTAssertEqual(teardowns, ["runtime-1"])
        XCTAssertNil(gate.runtime)

        let expiry = now.addingTimeInterval(60)
        try await gate.transition(to: .offlineLease(expiresAt: expiry), now: now)
        XCTAssertEqual(constructions, [.readWrite, .readOnly(expiresAt: expiry)])
        XCTAssertThrowsError(try gate.requireReadWrite())
        try await gate.transition(to: .offlineLease(expiresAt: expiry), now: expiry)
        XCTAssertEqual(teardowns, ["runtime-1", "runtime-2"])
        XCTAssertNil(gate.runtime)
    }

    @MainActor func testPendingApprovalAuthenticatesExactContextAndDenialEmitsNoApproval() async throws {
        let recorder = AccountApprovalRecorder()
        let lifecycle = AccountApprovalLifecycleRecorder()
        let denied = AccountDeviceApprovalCoordinator(authenticator: DenyingAccountAuthenticator())
        let context = try AccountDeviceApprovalContext(
            pendingID: "pending-1",
            offerDigest: Data(repeating: 1, count: 32),
            responseDigest: Data(repeating: 2, count: 32),
            generation: 7,
            matchingCode: "123456",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_060)
        )
        denied.present(AccountDeviceApprovalCapability(
            context: context,
            approve: { await recorder.record(context) },
            cancel: { await lifecycle.cancel() }
        ))
        denied.approve(now: Date(timeIntervalSince1970: 1_900_000_000))
        await denied.waitUntilIdle()
        let deniedCount = await recorder.count
        XCTAssertEqual(deniedCount, 0)
        let deniedCancellationCount = await lifecycle.cancelCount
        XCTAssertEqual(deniedCancellationCount, 1)

        let allowed = AccountDeviceApprovalCoordinator(authenticator: AllowingAccountAuthenticator())
        allowed.present(AccountDeviceApprovalCapability(
            context: context,
            approve: { await recorder.record(context) },
            cancel: {}
        ))
        allowed.approve(now: Date(timeIntervalSince1970: 1_900_000_000))
        allowed.approve(now: Date(timeIntervalSince1970: 1_900_000_000))
        await allowed.waitUntilIdle()
        let allowedCount = await recorder.count
        XCTAssertEqual(allowedCount, 1)

        let expired = AccountDeviceApprovalCoordinator(authenticator: AllowingAccountAuthenticator())
        expired.present(AccountDeviceApprovalCapability(
            context: context,
            approve: { await recorder.record(context) },
            cancel: { await lifecycle.cancel() }
        ))
        expired.approve(now: context.expiresAt)
        while await lifecycle.cancelCount < 2 { await Task.yield() }
        let finalApprovalCount = await recorder.count
        XCTAssertEqual(finalApprovalCount, 1)
    }

    @MainActor func testSessionReplacementCancelsDelayedNonCooperativeDeviceApproval() async throws {
        let authenticator = NonCooperativeDelayedAccountAuthenticator()
        let prepareGate = DelayedAccountStateGate(state: .suspended)
        let approvals = AccountApprovalRecorder()
        let lifecycle = AccountApprovalLifecycleRecorder()
        let model = AccountSessionViewModel(
            prepareSession: { _ in await prepareGate.run() },
            localApprovalAuthenticator: authenticator
        )
        let context = try AccountDeviceApprovalContext(
            pendingID: "pending-stale",
            offerDigest: Data(repeating: 3, count: 32),
            responseDigest: Data(repeating: 4, count: 32),
            generation: 9,
            matchingCode: "654321",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_060)
        )
        model.installApprovalCapability(AccountDeviceApprovalCapability(
            context: context,
            approve: { await approvals.record(context) },
            cancel: { await lifecycle.cancel() }
        ))
        model.confirmApproval()
        await authenticator.waitUntilStarted()

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        await prepareGate.waitUntilStarted()
        await authenticator.succeed()
        await model.waitForDeviceApprovalToSettle()

        let approvalCount = await approvals.count
        let cancellationCount = await lifecycle.cancelCount
        XCTAssertEqual(approvalCount, 0)
        XCTAssertEqual(cancellationCount, 1)
        await prepareGate.release()
        for _ in 0 ..< 100 where model.presentation != .suspended { await Task.yield() }
        XCTAssertEqual(model.presentation, .suspended)
    }

    @MainActor func testInjectedServiceClientMakesProductionRuntimeConstructible() throws {
        let directoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "pp-r4-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let databaseURL = directoryURL.appendingPathComponent("Plainpost.sqlite")
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: databaseURL, serviceClient: RuntimeServiceClientFake())

        let runtime = try PlainpostAppRuntime(
            configuration: configuration, notificationScheduler: NoopLocalNotificationScheduler())
        defer { Task { await runtime.shutdown() } }

        XCTAssertEqual(runtime.configuration.databaseURL, databaseURL)
    }

    @MainActor
    func testSecondRuntimeStartsPassivelyWhileFirstOwnsLocalAPI() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pp-passive-runtime-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: directoryURL.appendingPathComponent("Plainpost.sqlite"),
            serviceClient: RuntimeServiceClientFake()
        )
        let first = try makeRuntimeWithoutPackagedSideEffects(configuration)

        let second = try makeRuntimeWithoutPackagedSideEffects(configuration)

        XCTAssertEqual(first.localAPIOwnershipState, .owner)
        XCTAssertEqual(second.localAPIOwnershipState, .passive)
        await second.shutdown()
        await first.shutdown()
    }

    @MainActor
    func testPassiveRuntimeTakesOwnershipAfterFirstRuntimeShutsDown() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pp-runtime-takeover-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: directoryURL.appendingPathComponent("Plainpost.sqlite"),
            serviceClient: RuntimeServiceClientFake()
        )
        let first = try makeRuntimeWithoutPackagedSideEffects(configuration)
        let second = try makeRuntimeWithoutPackagedSideEffects(configuration)
        XCTAssertEqual(second.localAPIOwnershipState, .passive)

        await first.shutdown()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while second.localAPIOwnershipState != .owner,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(second.localAPIOwnershipState, .owner)
        let response = try LocalAPIUnixClient(
            socketURL: configuration.localAPISocketURL,
            startupTimeout: 0.1,
            operationTimeout: 0.5
        ).request(
            try LocalAPIJSON.makeEncoder().encode(
                LocalAPIRequest(
                    requestID: "runtime-takeover-status",
                    method: .sessionStatus,
                    parameters: LocalAPIEmptyParameters()
                )
            )
        )
        XCTAssertTrue(
            try JSONDecoder().decode(
                LocalAPISuccess<LocalAPISessionStatus>.self,
                from: response
            ).result.ready
        )
        await second.shutdown()
    }

    @MainActor
    func testShutdownReleasesLocalAPIBeforeUnrelatedBackgroundWorkDrains() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pp-runtime-early-release-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: directoryURL.appendingPathComponent("Plainpost.sqlite"),
            serviceClient: RuntimeServiceClientFake()
        )
        let first = try makeRuntimeWithoutPackagedSideEffects(configuration)
        let second = try makeRuntimeWithoutPackagedSideEffects(configuration)
        let unrelatedWork = NonCooperativeRuntimeWorkGate()
        let shutdownCompletion = RuntimeShutdownCompletion()
        addTeardownBlock { await unrelatedWork.release() }
        first.backgroundWork.start { await unrelatedWork.run() }
        await unrelatedWork.waitUntilStarted()

        let shutdown = Task { @MainActor in
            await first.shutdown()
            await shutdownCompletion.finish()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while second.localAPIOwnershipState != .owner,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(second.localAPIOwnershipState, .owner)
        let shutdownFinishedBeforeBackgroundDrain = await shutdownCompletion.isFinished()
        XCTAssertFalse(shutdownFinishedBeforeBackgroundDrain)
        if second.localAPIOwnershipState == .owner {
            let response = try LocalAPIUnixClient(
                socketURL: configuration.localAPISocketURL,
                startupTimeout: 0.1,
                operationTimeout: 0.5
            ).request(
                try LocalAPIJSON.makeEncoder().encode(
                    LocalAPIRequest(
                        requestID: "runtime-early-release-status",
                        method: .sessionStatus,
                        parameters: LocalAPIEmptyParameters()
                    )
                )
            )
            XCTAssertTrue(
                try JSONDecoder().decode(
                    LocalAPISuccess<LocalAPISessionStatus>.self,
                    from: response
                ).result.ready
            )
        }

        await unrelatedWork.release()
        await shutdown.value
        await second.shutdown()
    }

    @MainActor
    func testRuntimeStillThrowsForNonContentionLocalAPIStartFailure() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pp-invalid-runtime-lock-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: directoryURL.appendingPathComponent("Plainpost.sqlite"),
            serviceClient: RuntimeServiceClientFake()
        )
        let lockURL = configuration.localAPISocketURL
            .deletingPathExtension()
            .appendingPathExtension("lock")
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try makeRuntimeWithoutPackagedSideEffects(configuration)
        ) { error in
            let serverError = error as? LocalAPIUnixServerError
            XCTAssertNotNil(serverError)
            XCTAssertFalse(serverError?.isLifecycleLockContention ?? true)
        }
    }

    @MainActor
    func testShutdownCancelsPassiveTakeoverWithoutTouchingOwnerSocket() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pp-passive-shutdown-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: directoryURL.appendingPathComponent("Plainpost.sqlite"),
            serviceClient: RuntimeServiceClientFake()
        )
        let first = try makeRuntimeWithoutPackagedSideEffects(configuration)
        let second = try makeRuntimeWithoutPackagedSideEffects(configuration)
        XCTAssertEqual(second.localAPIOwnershipState, .passive)

        await second.shutdown()

        XCTAssertEqual(second.localAPIOwnershipState, .stopped)
        XCTAssertEqual(first.localAPIOwnershipState, .owner)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configuration.localAPISocketURL.path
            )
        )
        await first.shutdown()
    }

    @MainActor
    private func makeRuntimeWithoutPackagedSideEffects(
        _ configuration: PlainpostAppRuntimeConfiguration
    ) throws -> PlainpostAppRuntime {
        try PlainpostAppRuntime(
            configuration: configuration,
            notificationScheduler: NoopLocalNotificationScheduler(),
            packagedOperationWorkerSignalFactory: { nil },
            browserNativeHostStartup: { _ in }
        )
    }

    @MainActor
    func testProductionMailMonitorDoesNotEnqueueGUIOwnedSync() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pp-production-monitor-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let serviceClient = RuntimeServiceClientFake()
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: directoryURL.appendingPathComponent("Plainpost.sqlite"),
            serviceClient: serviceClient
        )
        let runtime = try makeRuntimeWithoutPackagedSideEffects(configuration)
        let account = Account(
            id: AccountID("acc-production-monitor"),
            displayName: "Production Monitor",
            email: EmailAddress("monitor@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try runtime.store.cacheAccounts([account])

        let monitor = Task {
            try await runtime.monitorMail(interval: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(60))
        monitor.cancel()
        _ = try? await monitor.value
        let snapshot = await serviceClient.snapshot()

        XCTAssertFalse(snapshot.foregroundOperationKinds.contains(.inboxSync))
        await runtime.shutdown()
    }

    func testMaintenanceFailureIsRecordedWithPrivacySafeDiagnostics() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-search-maintenance-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let coordinator = MailSearchMaintenanceCoordinator(
            service: FailingMaintenanceSearchService(),
            reportFailure: store.recordSearchMaintenanceFailure
        )

        await coordinator.perform(now: Date(timeIntervalSince1970: 1_720_000_000))

        let failure = try XCTUnwrap(
            try store.recentAuditEntries(limit: 10).first {
                $0.action == "search.maintenance.failed"
            }
        )
        XCTAssertEqual(failure.actorID, "plainpost-runtime")
        XCTAssertEqual(failure.targetType, "mail_search")
        XCTAssertEqual(failure.targetID, "maintenance")
        XCTAssertEqual(failure.result, "failed")
        let description = String(describing: failure)
        XCTAssertFalse(description.contains("private@example.com"))
        XCTAssertFalse(description.contains("/Users/private"))
    }

    @MainActor
    func testMaintenanceCancellationIsNotRecordedAsFailure() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-search-maintenance-cancel-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let service = CancellableMaintenanceSearchService()
        addTeardownBlock { await service.release() }
        let coordinator = MailSearchMaintenanceCoordinator(
            service: service,
            reportFailure: store.recordSearchMaintenanceFailure
        )
        let backgroundWork = RuntimeBackgroundWork()
        backgroundWork.start {
            await coordinator.perform(now: Date(timeIntervalSince1970: 1_720_000_000))
        }
        await service.waitUntilStarted()

        let drain = backgroundWork.beginShutdown()
        await service.waitUntilCancellationObserved()
        await service.release()
        await drain.value

        XCTAssertFalse(
            try store.recentAuditEntries(limit: 10).contains {
                $0.action == "search.maintenance.failed"
            }
        )
    }

    @MainActor
    func testNormalRuntimeStartsPackagedSideEffects() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-packaged-effects-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        var workerFactoryCalls = 0
        var browserStartupCalls = 0
        let signal = RecordingStartupWorkerSignal()

        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimePackagedEffects.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            packagedOperationWorkerSignalFactory: {
                workerFactoryCalls += 1
                return signal
            },
            browserNativeHostStartup: { _ in browserStartupCalls += 1 }
        )
        defer { Task { await runtime.shutdown() } }

        XCTAssertEqual(workerFactoryCalls, 1)
        XCTAssertEqual(browserStartupCalls, 1)
        await signal.waitUntilSignalCount(1)
        let signalCount = await signal.signalCount
        XCTAssertEqual(signalCount, 1)
    }

    @MainActor
    func testRuntimeShutdownJoinsGatedPackagedWorkerSignal() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-worker-shutdown-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let cancellationObserved = expectation(description: "worker signal observes cancellation")
        let cancellationBox = RuntimeCancellationExpectationBox(cancellationObserved)
        let signal = GatedStartupWorkerSignal(onCancellation: cancellationBox.fulfill)
        let unexpectedMaintenance = expectation(description: "post-shutdown maintenance does not run")
        unexpectedMaintenance.isInverted = true
        let maintenanceService = RecordingMaintenanceSearchService(
            onInvocation: RuntimeCancellationExpectationBox(unexpectedMaintenance).fulfill
        )
        addTeardownBlock { await signal.release() }
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeWorkerShutdown.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            operationWorkerSignal: signal,
            mailSearchMaintenanceService: maintenanceService
        )
        await signal.waitUntilSignalStarts()

        let shutdownCompletion = RuntimeShutdownCompletion()
        Task { @MainActor in
            await runtime.shutdown()
            await shutdownCompletion.finish()
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)
        let finishedBeforeRelease = await shutdownCompletion.isFinished()
        XCTAssertFalse(finishedBeforeRelease)

        await signal.release()
        await shutdownCompletion.waitUntilFinished()
        let signalFinished = await signal.isFinished()
        XCTAssertTrue(signalFinished)

        await runtime.didCompleteSync()
        await fulfillment(of: [unexpectedMaintenance], timeout: 0.1)
        let maintenanceInvocationCount = await maintenanceService.invocationCount()
        XCTAssertEqual(maintenanceInvocationCount, 0)
    }

    @MainActor
    func testCachedReadOnlyRuntimeStartsNoWorkerBrowserOrLocalAPISideEffects() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pp-off-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var workerFactoryCalls = 0
        var browserStartupCalls = 0
        let isolation = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: directory.appendingPathComponent("Plainpost.sqlite"),
            keychainService: "RuntimeAccountOffline.\(UUID().uuidString)"
        )
        let configuration = isolation.configuration

        let seed = try SQLiteMailStore(path: configuration.databaseURL.path)
        try seed.migrate()
        let databaseBefore = try Data(contentsOf: configuration.databaseURL)
        let auditDirectory = directory.appendingPathComponent("Audit", isDirectory: true)
        let auditBefore = try FileManager.default.contentsOfDirectory(
            at: auditDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ).map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url.lastPathComponent, values.contentModificationDate, values.fileSize)
        }

        let runtime = try PlainpostAppRuntime(
            configuration: configuration,
            notificationScheduler: NoopLocalNotificationScheduler(),
            packagedOperationWorkerSignalFactory: {
                workerFactoryCalls += 1
                return RecordingStartupWorkerSignal()
            },
            browserNativeHostStartup: { _ in browserStartupCalls += 1 },
            accountAccess: .cachedReadOnly
        )
        defer { Task { await runtime.shutdown() } }

        XCTAssertEqual(workerFactoryCalls, 0)
        XCTAssertEqual(browserStartupCalls, 0)
        XCTAssertEqual(isolation.runtimeDependencies.constructionCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.localAPISocketURL.path))
        XCTAssertEqual(try Data(contentsOf: configuration.databaseURL), databaseBefore)
        let auditAfter = try FileManager.default.contentsOfDirectory(
            at: auditDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ).map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url.lastPathComponent, values.contentModificationDate, values.fileSize)
        }
        XCTAssertEqual(auditAfter.map(\.0), auditBefore.map(\.0))
        XCTAssertEqual(auditAfter.map(\.1), auditBefore.map(\.1))
        XCTAssertEqual(auditAfter.map(\.2), auditBefore.map(\.2))
    }

    @MainActor
    func testCachedReadOnlyRuntimeRejectsInboxMutationsWithoutChangingCachedMail() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pp-off-actions-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = runtimeConfiguration(
            databaseURL: directory.appendingPathComponent("Plainpost.sqlite"),
            keychainService: "RuntimeAccountOfflineActions.\(UUID().uuidString)"
        )
        let seed = try SQLiteMailStore(path: configuration.databaseURL.path)
        try seed.migrate()
        let message = MessageSummary(
            id: MessageID("offline-message"),
            threadID: ThreadID("offline-thread"),
            from: EmailAddress("sender@example.com"),
            subject: "Cached",
            preview: "Cached body",
            body: "Cached body",
            smartCategory: .personal,
            isSeen: false
        )
        try seed.cacheMessage(message)
        let databaseBefore = try Data(contentsOf: configuration.databaseURL)

        let runtime = try PlainpostAppRuntime(
            configuration: configuration,
            notificationScheduler: NoopLocalNotificationScheduler(),
            accountAccess: .cachedReadOnly
        )
        defer { Task { await runtime.shutdown() } }

        let outcome = await runtime.makeInboxMailActionViewModel().perform(
            .markRead,
            messageID: message.id.rawValue
        )

        guard case .failed(let failure) = outcome else {
            return XCTFail("Offline cached mail mutation unexpectedly succeeded")
        }
        XCTAssertEqual(failure, "This cached mailbox is read-only while the account is offline.")
        XCTAssertFalse(try XCTUnwrap(runtime.store.messages.first { $0.id == message.id }).isSeen)
        XCTAssertThrowsError(try runtime.store.cacheMessage(message))
        XCTAssertEqual(try Data(contentsOf: configuration.databaseURL), databaseBefore)
    }

    /// Offline lease: Ask Mail still answers from the cached mail, without
    /// the operation queue and without writing to the cached database.
    @MainActor
    func testCachedReadOnlyRuntimeAnswersAskMailFromCachedMail() async throws {
        let fixture = try makeCachedReadOnlyAskMailFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let before = try fixture.databaseFiles()

        let answer = try await fixture.runtime.makeAskMailHandler(
            providerID: "deterministic", provider: DeterministicAIProvider()
        ).ask(question: "Group my unread emails", scope: .allMail, activeContext: nil, priorTurns: [])

        let titles = try XCTUnwrap(answer.askMailAnswer).blocks.compactMap { block -> String? in
            if case .messages(let list) = block { return list.title } else { return nil }
        }
        XCTAssertEqual(titles, ["Automated", "From people"])
        XCTAssertEqual(try fixture.databaseFiles(), before)
    }

    /// The free-text (evidence) path searches and generates over the cached
    /// mail too, and must leave every database file untouched.
    @MainActor
    func testCachedReadOnlyAskMailEvidenceAnswerWritesNothing() async throws {
        let fixture = try makeCachedReadOnlyAskMailFixture()
        addTeardownBlock { await fixture.cleanUp() }
        let before = try fixture.databaseFiles()

        let answer = try await fixture.runtime.makeAskMailHandler(
            providerID: "deterministic", provider: DeterministicAIProvider()
        ).ask(question: "What did Ada say about lunch on Friday?", scope: .allMail,
              activeContext: nil, priorTurns: [])

        XCTAssertFalse(answer.answer.isEmpty)
        XCTAssertEqual(answer.sources.map(\.messageID), [MessageID("offline-ask-3")])
        XCTAssertEqual(try fixture.databaseFiles(), before)
    }

    private struct CachedReadOnlyAskMailFixture {
        let runtime: PlainpostAppRuntime
        let directory: URL

        /// Every file under the data directory (database, WAL, SHM, audit log), by path.
        func databaseFiles() throws -> [String: Data] {
            let urls = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .allObjects as? [URL]) ?? []
            return try Dictionary(uniqueKeysWithValues: urls.filter { !$0.hasDirectoryPath }.map {
                ($0.path, try Data(contentsOf: $0))
            })
        }

        /// Shuts the runtime down before deleting its data directory so nothing writes into a
        /// directory that is being removed.
        func cleanUp() async {
            await runtime.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private func makeCachedReadOnlyAskMailFixture() throws -> CachedReadOnlyAskMailFixture {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pp-off-ask-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("Plainpost.sqlite")
        let isolation = RuntimeKeychainIsolation(
            testCase: self, databaseURL: databaseURL,
            keychainService: "RuntimeAccountOfflineAsk.\(UUID().uuidString)"
        )
        let account = Account(
            id: AccountID("offline-ask"), displayName: "Offline",
            email: EmailAddress("reader@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("offline-ask-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let messages: [(String, String, String, SmartCategory)] = [
            ("digest@news.example.test", "Weekly digest", "This week in design", .newsletter),
            ("letters@news.example.test", "Morning letter", "Five stories for today", .newsletter),
            ("alerts@service.example.test", "Backup finished", "Your backup finished", .notification),
            ("ada@example.test", "Lunch on Friday", "Can we meet for lunch on Friday at noon?", .personal),
        ]
        for (index, message) in messages.enumerated() {
            _ = try seed.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("offline-ask-\(index)"), threadID: nil,
                    from: EmailAddress(message.0), fromDisplayName: index == 3 ? "Ada" : nil,
                    subject: message.1, preview: message.2, smartCategory: message.3
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
                uid: index + 1, notificationEligible: false
            )
        }
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: account.id,
                runtimeDependencies: isolation.runtimeDependencies
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            accountAccess: .cachedReadOnly
        )
        return CachedReadOnlyAskMailFixture(runtime: runtime, directory: directory)
    }

    private func runtimeConfiguration(
        databaseURL: URL,
        keychainService: String
    ) -> PlainpostAppRuntimeConfiguration {
        RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: databaseURL,
            keychainService: keychainService
        ).configuration
    }

    private func selectedDirectRuntimeConfiguration(
        databaseURL: URL,
        keychainService: String,
        account: Account
    ) throws -> PlainpostAppRuntimeConfiguration {
        let isolation = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: databaseURL,
            keychainService: keychainService
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([account])
        _ = try seed.replaceMailSource(
            AccountMailSource(
                accountID: account.id,
                kind: .direct,
                mode: nil,
                nodeID: nil,
                logicalMailboxID: nil,
                providerIdentity: nil,
                generation: 1
            ),
            expectedGeneration: 0
        )
        return PlainpostAppRuntimeConfiguration(
            databaseURL: databaseURL,
            selectedAccountID: account.id,
            runtimeDependencies: isolation.runtimeDependencies
        )
    }

    func testRuntimeIsolationKeepsVaultFixturesBehindDistinctServiceFakes() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-isolation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let first = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: databaseURL,
            keychainService: "RuntimeIsolationFirst.\(UUID().uuidString)"
        )
        let second = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: databaseURL,
            keychainService: "RuntimeIsolationSecond.\(UUID().uuidString)"
        )
        let key = CredentialRecordKey(rawValue: "device:server-identity")

        try await first.credentials.store(Data("first".utf8), for: key)

        let firstValue = try await first.credentials.load(key)
        let secondValue = try await second.credentials.load(key)
        XCTAssertEqual(firstValue, Data("first".utf8))
        XCTAssertNil(secondValue)

        await first.serviceClient.setAvailability(.locked)
        let firstState = await PlainpostVaultReadinessGate(serviceClient: first.serviceClient)
            .evaluate()
        let secondState = await PlainpostVaultReadinessGate(serviceClient: second.serviceClient)
            .evaluate()
        XCTAssertEqual(firstState, .locked)
        XCTAssertEqual(secondState, .ready)
    }

    private func enqueueSmartInboxActivityJob(
        store: SQLiteMailStore,
        mode: PlainpostSmartInboxRunMode,
        suffix: String,
        priority: Int = 0
    ) throws -> PlainpostDurableJob {
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: mode
        ).resolvingSmartInboxClassifierIdentity()
        return try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                priority: priority,
                idempotencyKey: "runtime-smart-inbox-activity-\(suffix)-\(UUID().uuidString)"
            )
        )
    }

    private func decodeSmartInboxRunMode(
        _ job: PlainpostDurableJob
    ) throws -> PlainpostSmartInboxRunMode {
        try JSONDecoder().decode(
            PlainpostAIOperationInput.self,
            from: Data(job.payloadJSON.utf8)
        ).smartInboxRunMode
    }

    @MainActor
    func testSelectedDirectAccountScopesManualSmartInboxOrganization() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-scoped-smart-inbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("smart-inbox-second"), displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try seed.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ),
                expectedGeneration: 0
            )
        }
        let operationClient = RejectingMaintenanceOperationClient()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: second.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in operationClient }
        )
        defer { Task { await runtime.shutdown() } }

        do {
            _ = try await runtime.organizeSmartInbox(using: "deterministic", mode: .incremental)
            XCTFail("The recording operation client should stop this test before classification")
        } catch MaintenanceRuntimeClientError.stopped {
            let recordedScope = await operationClient.lastAIInput?.smartInboxRunRequest.scope
            XCTAssertEqual(
                recordedScope,
                .account(second.id)
            )
            let recordedInput = await operationClient.lastAIInput
            XCTAssertEqual(recordedInput?.accountID, second.id)
            XCTAssertEqual(recordedInput?.expectedDirectSourceGeneration, 1)
        }
    }

    @MainActor
    func testSelectedDirectRuntimeCannotShowOrPauseOtherAccountsSmartInboxJob() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-scoped-smart-inbox-actions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("smart-inbox-actions-second"), displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try seed.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
        }
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: second.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }

        func enqueue(_ accountID: AccountID, mode: PlainpostSmartInboxRunMode) throws -> PlainpostDurableJob {
            let input = PlainpostAIOperationInput(
                operation: .recategorizeInbox, recordID: "",
                accountID: accountID, expectedDirectSourceGeneration: 1,
                providerID: "deterministic",
                smartInboxRunRequest: .init(mode: mode, scope: .account(accountID), requestedLabelID: nil),
                smartInboxRequestID: UUID().uuidString
            )
            return try seed.enqueueJob(.init(
                kind: .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                idempotencyKey: UUID().uuidString
            ))
        }
        let foreign = try enqueue(first.id, mode: .rerunAll)
        let selected = try enqueue(second.id, mode: .incremental)

        XCTAssertEqual(try runtime.smartInboxActivityJob()?.id, selected.id)
        XCTAssertNil(try runtime.activeSmartInboxRerunJob())
        XCTAssertThrowsError(try runtime.pauseSmartInboxJob(id: foreign.id))
        XCTAssertEqual(try seed.job(id: foreign.id).state, .queued)
        try runtime.pauseSmartInboxJob(id: selected.id)
        XCTAssertEqual(try seed.job(id: selected.id).state, .paused)

        let source = try seed.mailSource(accountID: second.id)
        XCTAssertThrowsError(try seed.replaceMailSource(
            source.nodeBacked(
                nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: second.email.rawValue
            ), expectedGeneration: source.generation
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .operationUnresolved)
        }
        XCTAssertEqual(try seed.mailSource(accountID: second.id), source)
        try seed.requestJobCancellation(id: selected.id)
        XCTAssertEqual(try seed.job(id: selected.id).state, .cancelled)
        _ = try seed.replaceMailSource(
            source.nodeBacked(
                nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: second.email.rawValue
            ), expectedGeneration: source.generation
        )
        XCTAssertThrowsError(try runtime.smartInboxActivityJob())
        XCTAssertThrowsError(try runtime.pauseSmartInboxJob(id: selected.id))
        XCTAssertEqual(try seed.job(id: selected.id).state, .cancelled)
    }

    /// The device-wide iOS runtime organizes every account's inbox in one run.
    @MainActor
    func testDeviceWideDirectRuntimeOrganizesEveryAccount() async throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let operationClient = RejectingMaintenanceOperationClient()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: fixture.databaseURL,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in operationClient }
        )
        defer { Task { await runtime.shutdown() } }

        do {
            _ = try await runtime.organizeSmartInbox(using: "deterministic", mode: .incremental)
            XCTFail("The recording operation client should stop this test before classification")
        } catch MaintenanceRuntimeClientError.stopped {
            let recordedInput = await operationClient.lastAIInput
            XCTAssertEqual(recordedInput?.smartInboxRunRequest.scope, .allAccounts)
            XCTAssertNil(recordedInput?.accountID)
            XCTAssertNil(recordedInput?.expectedDirectSourceGeneration)
        }
    }

    @MainActor
    func testSelectedDirectAccountScopesSmartInboxAfterSync() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-scoped-post-sync-smart-inbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let account = PlainpostFixtures.personalAccount
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([account])
        _ = try seed.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil,
                providerIdentity: nil, generation: 1
            ),
            expectedGeneration: 0
        )
        let operationClient = RejectingMaintenanceOperationClient()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: account.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in operationClient }
        )
        defer { Task { await runtime.shutdown() } }

        await runtime.didCompleteSync()
        let scope = await operationClient.lastEnqueuedAIInput?.smartInboxRunRequest.scope
        XCTAssertEqual(scope, .account(account.id))
    }

    func testRuntimeCredentialsUseInMemoryVaultWithoutSecurityFramework() async throws {
        let credentials = InMemoryCredentialVault()
        let key = CredentialRecordKey(rawValue: "account:test:imap-password")

        try await credentials.store(Data("test-secret".utf8), for: key)
        let stored = try await credentials.load(key)
        XCTAssertEqual(stored, Data("test-secret".utf8))

        try await credentials.remove(key)
        let removed = try await credentials.load(key)
        XCTAssertNil(removed)
    }

    @MainActor
    func testRuntimeExposesSmartInboxMaintenanceAdapter() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-maintenance-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeMaintenance.\(UUID().uuidString)",
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )

        let status = try await runtime.runSmartInboxMaintenance(
            providerID: "foundation",
            mode: .incremental,
            requestID: "maintenance-request"
        )

        XCTAssertEqual(status, "Up to date")
    }

    @MainActor
    func testRuntimeRejectsConcurrentFreshRequestIDRerunsAcrossWindows() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-maintenance-gate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let operationClient = SuspendedMaintenanceOperationClient()
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeMaintenanceGate.\(UUID().uuidString)",
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in operationClient }
        )

        let first = Task {
            try await runtime.runSmartInboxMaintenance(
                providerID: "foundation",
                mode: .rerunAll,
                requestID: "first-\(UUID().uuidString.lowercased())"
            )
        }
        guard await operationClient.waitUntilAICallStarts() else {
            first.cancel()
            return XCTFail("The first rerun did not reach the operation client.")
        }

        do {
            _ = try await runtime.runSmartInboxMaintenance(
                providerID: "foundation",
                mode: .rerunAll,
                requestID: "second-\(UUID().uuidString.lowercased())"
            )
            XCTFail("A concurrent rerun with a fresh request ID must be rejected.")
        } catch let error as PlainpostSmartInboxMaintenanceError {
            XCTAssertEqual(error, .rerunAlreadyActive)
        }

        let callCount = await operationClient.aiCallCount
        XCTAssertEqual(callCount, 1)

        await operationClient.releaseFirstAICall()
        _ = await first.result
    }

    @MainActor
    func testRuntimeFactorySuccessfulRerunInvalidatesInboxProjectionExactlyOnce() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-maintenance-success-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let keychainService = "RuntimeMaintenanceSuccess.\(UUID().uuidString)"
        let operationClientBox = SuccessfulMaintenanceOperationClientBox()
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: keychainService,
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { store in
                let client = SuccessfulMaintenanceOperationClient(store: store)
                operationClientBox.client = client
                return client
            }
        )
        _ = try runtime.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_maintenance_before"),
                threadID: ThreadID("thr_maintenance_before"),
                from: EmailAddress("before@example.com"),
                subject: "Before maintenance",
                preview: "Cached before the rerun",
                smartCategory: .personal
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )

        let initial = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertEqual(initial.mailboxRevision >> 32, 1)
        XCTAssertEqual(initial.classicRows.map(\.id), ["msg_maintenance_before"])

        _ = try runtime.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_maintenance_after"),
                threadID: ThreadID("thr_maintenance_after"),
                from: EmailAddress("after@example.com"),
                subject: "After maintenance",
                preview: "Visible only after invalidation",
                smartCategory: .personal
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            notificationEligible: false
        )
        let stale = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertEqual(stale.mailboxRevision, initial.mailboxRevision)
        XCTAssertEqual(stale.classicRows.map(\.id), ["msg_maintenance_before"])

        let maintenance = runtime.makeMailMaintenanceViewModel(
            accountSetup: runtime.makeAccountSetupViewModel(),
            aiProviderSettings: .production()
        )
        await maintenance.rerunSmartInbox()

        XCTAssertEqual(
            maintenance.rerunState,
            .success(message: "Smart Inbox rerun finished.")
        )
        XCTAssertEqual(maintenance.successRevision, 1)
        let refreshed = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        XCTAssertEqual(refreshed.mailboxRevision >> 32, (initial.mailboxRevision >> 32) + 1)
        XCTAssertEqual(
            refreshed.mailboxRevision & UInt64(UInt32.max),
            initial.mailboxRevision & UInt64(UInt32.max)
        )
        XCTAssertEqual(
            Set(refreshed.classicRows.map(\.id)),
            Set(["msg_maintenance_before", "msg_maintenance_after"])
        )
        let operationClient = try XCTUnwrap(operationClientBox.client)
        let callCount = await operationClient.aiCallCount
        XCTAssertEqual(callCount, 1)
        await runtime.shutdown()
    }

    @MainActor
    func testRuntimeRejectsActiveRerunHiddenByRunningIncrementalActivity() async throws {
        for rerunState in [PlainpostOperationState.queued, .paused] {
            let databaseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "runtime-maintenance-masked-\(rerunState.rawValue)-\(UUID().uuidString).sqlite"
                )
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let operationClient = RejectingMaintenanceOperationClient()
            let runtime = try PlainpostAppRuntime(
                configuration: runtimeConfiguration(
                    databaseURL: databaseURL,
                    keychainService: "RuntimeMaintenanceMasked.\(UUID().uuidString)"
                ),
                notificationScheduler: NoopLocalNotificationScheduler(),
                aiOperationClientFactory: { _ in operationClient }
            )

            let rerun = try enqueueSmartInboxActivityJob(
                store: runtime.store,
                mode: .rerunAll,
                suffix: "masked-rerun-\(rerunState.rawValue)",
                priority: 10
            )
            let incremental = try enqueueSmartInboxActivityJob(
                store: runtime.store,
                mode: .incremental,
                suffix: "higher-priority-incremental-\(rerunState.rawValue)",
                priority: 20
            )
            let running = try XCTUnwrap(
                runtime.store.claimNextJob(allowedKinds: [.aiOperation])
            )
            XCTAssertEqual(running.id, incremental.id)
            if rerunState == .paused {
                try runtime.store.requestJobPause(id: rerun.id)
            }

            XCTAssertEqual(try runtime.smartInboxActivityJob()?.id, incremental.id)
            XCTAssertEqual(try runtime.store.activeSmartInboxRerunJob()?.id, rerun.id)

            do {
                _ = try await runtime.runSmartInboxMaintenance(
                    providerID: "foundation",
                    mode: .rerunAll,
                    requestID: "masked-\(UUID().uuidString.lowercased())"
                )
                XCTFail("A masked \(rerunState.rawValue) rerun must reject another rerun.")
            } catch let error as PlainpostSmartInboxMaintenanceError {
                XCTAssertEqual(error, .rerunAlreadyActive)
            }

            let callCount = await operationClient.aiCallCount
            XCTAssertEqual(callCount, 0)
            await runtime.shutdown()
        }
    }

    // The Settings page iOS shows is the session's maintenance model, so it must
    // follow the runtime's Low Power gate just like the Mac Settings window does.
    @MainActor
    func testMailSessionMaintenanceFollowsTheLowPowerGate() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-session-low-power-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let center = NotificationCenter()
        let lowPower = RuntimeLowPowerFlag(true)
        let gate = SmartInboxPowerGate(
            isLowPowerModeEnabled: { lowPower.value }, notificationCenter: center, appliesLowPowerMode: true
        )
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeSessionLowPower.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in RejectingMaintenanceOperationClient() },
            smartInboxPowerGate: gate
        )
        let session = runtime.makeMailSession(
            composerPresentationPolicy: .embedded,
            commitDelay: .zero,
            providerOnboarding: nil,
            accountSessionModel: nil,
            initialDestination: .settings,
            initialSelectedMessageID: nil,
            onAccountSetupConnected: { _ in },
            contactDirectory: nil
        )
        let maintenance = session.maintenance
        XCTAssertTrue(maintenance.isSmartInboxPausedForLowPower)
        XCTAssertFalse(maintenance.canRerunSmartInbox)
        XCTAssertTrue(session.smartInboxActivity === maintenance.smartInboxActivity)

        lowPower.value = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        for _ in 0..<200 where maintenance.isSmartInboxPausedForLowPower {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(maintenance.isSmartInboxPausedForLowPower)
        await runtime.shutdown()
    }

    // Low Power Mode pauses a running Re-sort All durably, and a launch outside
    // Low Power Mode lifts that pause even though the pausing runtime is gone.
    @MainActor
    func testLowPowerPauseOfReSortSurvivesARelaunchAndLiftsOutsideLowPower() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-low-power-relaunch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let configuration = runtimeConfiguration(
            databaseURL: databaseURL,
            keychainService: "RuntimeLowPowerRelaunch.\(UUID().uuidString)"
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        let rerun = try enqueueSmartInboxActivityJob(store: seed, mode: .rerunAll, suffix: "low-power-relaunch")
        XCTAssertEqual(try seed.claimNextJob(allowedKinds: [.aiOperation])?.id, rerun.id)

        func runtime(lowPower: Bool) throws -> PlainpostAppRuntime {
            try PlainpostAppRuntime(
                configuration: configuration,
                notificationScheduler: NoopLocalNotificationScheduler(),
                aiOperationClientFactory: { _ in RejectingMaintenanceOperationClient() },
                smartInboxPowerGate: SmartInboxPowerGate(
                    isLowPowerModeEnabled: { lowPower }, notificationCenter: NotificationCenter(),
                    appliesLowPowerMode: true
                )
            )
        }

        let inLowPower = try runtime(lowPower: true)
        await inLowPower.settleSmartInboxLowPowerPolicy()
        let paused = try inLowPower.store.job(id: rerun.id)
        XCTAssertTrue(paused.pauseRequested)
        XCTAssertEqual(paused.pauseReason, "low-power")
        await inLowPower.shutdown()

        let relaunched = try runtime(lowPower: false)
        await relaunched.settleSmartInboxLowPowerPolicy()
        let lifted = try relaunched.store.job(id: rerun.id)
        XCTAssertEqual(lifted.state, .running)
        XCTAssertFalse(lifted.pauseRequested)
        XCTAssertNil(lifted.pauseReason)
        await relaunched.shutdown()
    }

    @MainActor
    func testRecreatedRuntimeRejectsPersistedActiveRerunBeforeEnqueue() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-maintenance-recreated-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let keychainService = "RuntimeMaintenanceRecreated.\(UUID().uuidString)"
        var persistedRerunID = ""

        do {
            let original = try PlainpostAppRuntime(
                configuration: runtimeConfiguration(
                    databaseURL: databaseURL,
                    keychainService: keychainService
                ),
                notificationScheduler: NoopLocalNotificationScheduler()
            )
            let rerun = try enqueueSmartInboxActivityJob(
                store: original.store,
                mode: .rerunAll,
                suffix: "persisted-deterministic-rerun",
                priority: 10
            )
            persistedRerunID = rerun.id
            let incremental = try enqueueSmartInboxActivityJob(
                store: original.store,
                mode: .incremental,
                suffix: "persisted-running-incremental",
                priority: 20
            )
            XCTAssertEqual(
                try original.store.claimNextJob(allowedKinds: [.aiOperation])?.id,
                incremental.id
            )
            await original.shutdown()
        }

        let operationClient = RejectingMaintenanceOperationClient()
        let recreated = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: keychainService
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in operationClient }
        )
        defer { Task { await recreated.shutdown() } }
        let activeBefore = try XCTUnwrap(recreated.store.activeSmartInboxRerunJob())
        XCTAssertEqual(activeBefore.id, persistedRerunID)
        let jobCountBefore = try recreated.store.jobs(limit: 100).count

        do {
            _ = try await recreated.runSmartInboxMaintenance(
                providerID: "foundation",
                mode: .rerunAll,
                requestID: "recreated-\(UUID().uuidString.lowercased())"
            )
            XCTFail("A recreated runtime must reject the persisted rerun.")
        } catch let error as PlainpostSmartInboxMaintenanceError {
            XCTAssertEqual(error, .rerunAlreadyActive)
        }

        let callCount = await operationClient.aiCallCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try recreated.store.jobs(limit: 100).count, jobCountBefore)
        XCTAssertEqual(
            try recreated.store.activeSmartInboxRerunJob()?.id,
            persistedRerunID
        )
    }

    func testPackagedOperationWorkerLaunchesEmbeddedExecutableDirectly() async throws {
        let appBundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainpostApp-\(UUID().uuidString).app", isDirectory: true)
        let helperExecutableURL = appBundleURL
            .appendingPathComponent("Contents/Library/Helpers/PlainpostBackgroundAgent.app/Contents/MacOS/PlainpostBackgroundAgent")
        defer { try? FileManager.default.removeItem(at: appBundleURL) }
        try FileManager.default.createDirectory(
            at: helperExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: helperExecutableURL.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperExecutableURL.path
        )
        let launcher = RecordingEmbeddedWorkerLauncher()
        let signal = try XCTUnwrap(
            PackagedOperationWorkerSignal(appBundleURL: appBundleURL, launcher: launcher.launch)
        )

        try await signal.signalWork()

        XCTAssertEqual(launcher.launchedExecutableURLs, [helperExecutableURL])
    }

    func testPackagedOperationWorkerCoalescesSignalsWhileHelperIsRunning() async throws {
        let appBundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainpostApp-\(UUID().uuidString).app", isDirectory: true)
        let helperExecutableURL = appBundleURL
            .appendingPathComponent("Contents/Library/Helpers/PlainpostBackgroundAgent.app/Contents/MacOS/PlainpostBackgroundAgent")
        defer { try? FileManager.default.removeItem(at: appBundleURL) }
        try FileManager.default.createDirectory(
            at: helperExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: helperExecutableURL.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperExecutableURL.path
        )
        let launcher = RecordingEmbeddedWorkerLauncher()
        let signal = try XCTUnwrap(
            PackagedOperationWorkerSignal(appBundleURL: appBundleURL, launcher: launcher.launch)
        )

        try await signal.signalWork()
        try await signal.signalWork()

        XCTAssertEqual(launcher.launchedExecutableURLs, [helperExecutableURL])

        launcher.finishLatestLaunch()
        try await signal.signalWork()

        XCTAssertEqual(launcher.launchedExecutableURLs, [helperExecutableURL, helperExecutableURL])
    }

    @MainActor
    func testRuntimeSignalsPackagedOperationWorkerAtStartup() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-worker-startup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let signal = RecordingStartupWorkerSignal()

        _ = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeWorkerStartup.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            operationWorkerSignal: signal
        )

        await signal.waitUntilSignalCount(1)
        let signalCount = await signal.signalCount
        XCTAssertEqual(signalCount, 1)
    }

    @MainActor
    func testRootActivityProviderReturnsIncrementalAndRerunSmartInboxJobs() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smart-inbox-activity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let signal = ScriptedRuntimeWorkerSignal()
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeSmartInboxActivity.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            operationWorkerSignal: signal
        )
        await signal.waitUntilSignalCount(1)

        let incremental = try enqueueSmartInboxActivityJob(
            store: runtime.store,
            mode: .incremental,
            suffix: "incremental"
        )
        var activity = try runtime.smartInboxActivityJob()

        XCTAssertEqual(activity?.id, incremental.id)
        XCTAssertEqual(
            try activity.map(decodeSmartInboxRunMode),
            .incremental
        )

        try runtime.store.requestJobCancellation(id: incremental.id)
        let rerun = try enqueueSmartInboxActivityJob(
            store: runtime.store,
            mode: .rerunAll,
            suffix: "rerun"
        )
        activity = try runtime.smartInboxActivityJob()

        XCTAssertEqual(activity?.id, rerun.id)
        XCTAssertEqual(
            try activity.map(decodeSmartInboxRunMode),
            .rerunAll
        )
        await runtime.shutdown()
    }

    @MainActor
    func testRootPauseAndResumeMutateSameJobBeforeSignalingOnce() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smart-inbox-actions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let signal = ScriptedRuntimeWorkerSignal()
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeSmartInboxActions.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            operationWorkerSignal: signal
        )
        await signal.waitUntilSignalCount(1)
        let job = try enqueueSmartInboxActivityJob(
            store: runtime.store,
            mode: .incremental,
            suffix: "pause-resume"
        )
        try runtime.pauseSmartInboxJob(id: job.id)

        XCTAssertEqual(try runtime.store.job(id: job.id).state, .paused)
        XCTAssertEqual(try runtime.store.job(id: job.id).pauseReason, "user-requested")
        let signalCountAfterPause = await signal.signalCount
        XCTAssertEqual(signalCountAfterPause, 1)

        await signal.observeJobState(store: runtime.store, jobID: job.id)
        try await runtime.resumeSmartInboxJob(id: job.id)

        XCTAssertEqual(try runtime.store.job(id: job.id).state, .queued)
        let signalCountAfterResume = await signal.signalCount
        let observedStatesAfterResume = await signal.observedJobStates
        XCTAssertEqual(signalCountAfterResume, 2)
        XCTAssertEqual(observedStatesAfterResume, [.queued])
        await runtime.shutdown()
    }

    @MainActor
    func testRootSmartInboxStoreFailuresDoNotSignalWorker() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smart-inbox-store-failure-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let signal = ScriptedRuntimeWorkerSignal()
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeSmartInboxStoreFailure.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            operationWorkerSignal: signal
        )
        await signal.waitUntilSignalCount(1)

        XCTAssertThrowsError(
            try runtime.pauseSmartInboxJob(id: "missing-smart-inbox-job")
        )
        do {
            try await runtime.resumeSmartInboxJob(id: "missing-smart-inbox-job")
            XCTFail("Expected a missing Smart Inbox job to reject Resume.")
        } catch {
            XCTAssertFalse(error is SmartInboxActivityActionError)
        }

        let signalCount = await signal.signalCount
        XCTAssertEqual(signalCount, 1)
        await runtime.shutdown()
    }

    @MainActor
    func testResumeSignalFailureKeepsQueuedJobAndRetriesSignalOnlyOnce() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smart-inbox-signal-retry-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let signal = ScriptedRuntimeWorkerSignal()
        let retryGate = RuntimeSignalRetryGate()
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeSmartInboxSignalRetry.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            operationWorkerSignal: signal,
            smartInboxResumeSignalRetryDelay: {
                await retryGate.wait()
            }
        )
        await signal.waitUntilSignalCount(1)
        let job = try enqueueSmartInboxActivityJob(
            store: runtime.store,
            mode: .rerunAll,
            suffix: "signal-retry"
        )
        try runtime.store.requestJobPause(id: job.id)
        await signal.observeJobState(store: runtime.store, jobID: job.id)
        await signal.failNextObservedSignals(2)
        let initialJobCount = try runtime.store.jobs(limit: 100).count

        do {
            try await runtime.resumeSmartInboxJob(id: job.id)
            XCTFail("Expected the first worker signal to fail after Resume committed.")
        } catch let error as SmartInboxActivityActionError {
            XCTAssertTrue(error.didCommitResume)
        }

        let resumedJob = try runtime.store.job(id: job.id)
        XCTAssertEqual(resumedJob.state, .queued)
        XCTAssertEqual(try runtime.store.jobs(limit: 100).count, initialJobCount)
        let signalCountBeforeRetry = await signal.signalCount
        let observedStatesBeforeRetry = await signal.observedJobStates
        XCTAssertEqual(signalCountBeforeRetry, 2)
        XCTAssertEqual(observedStatesBeforeRetry, [.queued])

        await retryGate.waitUntilEntered()
        await retryGate.release()
        await signal.waitUntilSignalCount(3)

        let jobAfterRetry = try runtime.store.job(id: job.id)
        XCTAssertEqual(jobAfterRetry.state, .queued)
        XCTAssertEqual(jobAfterRetry.id, resumedJob.id)
        XCTAssertEqual(jobAfterRetry.attempt, resumedJob.attempt)
        XCTAssertEqual(jobAfterRetry.availableAt, resumedJob.availableAt)
        XCTAssertEqual(jobAfterRetry.updatedAt, resumedJob.updatedAt)
        XCTAssertEqual(try runtime.store.jobs(limit: 100).count, initialJobCount)
        let observedStatesAfterRetry = await signal.observedJobStates
        XCTAssertEqual(observedStatesAfterRetry, [.queued, .queued])
        try await Task.sleep(for: .milliseconds(20))
        let signalCountAfterRetry = await signal.signalCount
        XCTAssertEqual(signalCountAfterRetry, 3)
        await runtime.shutdown()
    }

    @MainActor
    func testRuntimeQueuesInboxSyncForPackagedWorker() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-worker-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let signal = RecordingStartupWorkerSignal()
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeWorkerSync.\(UUID().uuidString)",
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            operationWorkerSignal: signal
        )

        let accountSetup = runtime.makeAccountSetupViewModel()
        let sync = Task { await accountSetup.syncInbox() }
        try await Task.sleep(for: .milliseconds(150))
        sync.cancel()
        _ = await sync.result

        let signalCount = await signal.signalCount
        XCTAssertGreaterThanOrEqual(signalCount, 2)
        XCTAssertTrue(
            try runtime.store.jobs(limit: 10).contains {
                $0.kind == .inboxSync && ($0.state == .queued || $0.state == .running)
            }
        )
    }

    @MainActor
    func testRuntimeContrarySeenActionPersistsLocallyBeforeRemoteAvailability() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-contrary-seen-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "RuntimeContrarySeen.\(UUID().uuidString)",
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        _ = try runtime.store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(false),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        _ = try runtime.store.openMessageForHuman(
            PlainpostFixtures.aliceMessage.id,
            actor: PlainpostFixtures.guiUser
        )

        let actions = runtime.makeInboxMailActionViewModel()
        _ = await actions.perform(.markUnread, messageID: PlainpostFixtures.aliceMessage.id.rawValue)

        XCTAssertEqual(
            try runtime.store.desiredSeenState(messageID: PlainpostFixtures.aliceMessage.id),
            false
        )
        XCTAssertFalse(try XCTUnwrap(runtime.store.messageSummary(id: PlainpostFixtures.aliceMessage.id)).isSeen)
        XCTAssertEqual(actions.statusMessage, "Marked unread")
    }

    @MainActor
    func testOverlappingIncrementalOrganizationDoesNotEnqueueAfterFirstRequestCompletes() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smart-inbox-overlap-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let keychainService = "PlainpostRuntimeSmartInboxOverlap.\(UUID().uuidString)"
        let gate = IncrementalOrganizationOverlapGate()
        let provider = ClassificationCountingProvider()
        let resolver = ProviderResolutionCounter(provider: provider)
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: keychainService,
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { store in
                let operationRuntime = LocalOperationRuntime(
                    store: store,
                    credentials: InMemoryCredentialVault(),
                    allowedJobKinds: [.aiOperation, .searchRebuild],
                    aiProviderResolver: { input in resolver.resolve(input) }
                )
                return CoordinatedIncrementalOperationClient(
                    base: LocalOperationClient(runtime: operationRuntime),
                    gate: gate
                )
            }
        )
        try runtime.store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try runtime.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_overlap_runtime"),
                threadID: ThreadID("thr_overlap_runtime"),
                from: EmailAddress("alice@example.com"),
                subject: "Overlap",
                preview: "Organize exactly once",
                smartCategory: .unknown
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1, notificationEligible: false
        )

        let first = Task {
            try await runtime.organizeSmartInbox(using: "deterministic", mode: .incremental)
        }
        guard await gate.waitUntilCallCount(1) else {
            first.cancel()
            return XCTFail("The first organize request did not reach the operation client.")
        }
        let second = Task {
            try await runtime.organizeSmartInbox(using: "deterministic", mode: .incremental)
        }
        guard await gate.waitUntilCallCount(2) else {
            await gate.releaseFirstCall()
            _ = await first.result
            second.cancel()
            return XCTFail("The overlapping organize request did not reach the operation client.")
        }
        await gate.releaseFirstCall()

        let statuses = try await [first.value, second.value]

        XCTAssertEqual(statuses, ["Up to date", "Up to date"])
        XCTAssertEqual(
            try runtime.store.jobs(limit: 100).filter { $0.kind == .aiOperation }.count,
            1
        )
        XCTAssertEqual(
            resolver.resolvedClassifierDiscriminators,
            [
                SmartInboxClassifierIdentity.resolve(
                    providerID: AIProviderSelection.resolvedProviderID("deterministic"),
                    modelID: nil
                ).discriminator
            ]
        )
        XCTAssertEqual(resolver.resolutionCount, 1)
        XCTAssertEqual(provider.classificationCount, 1)
    }

    @MainActor
    func testIncrementalOrganizationIsUpToDateUntilClassifierIdentityChanges() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smart-inbox-cache-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let keychainService = "PlainpostRuntimeSmartInboxCache.\(UUID().uuidString)"
        let provider = ClassificationCountingProvider()
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: keychainService,
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { store in
                LocalOperationClient(
                    runtime: LocalOperationRuntime(
                        store: store,
                        credentials: InMemoryCredentialVault(),
                        allowedJobKinds: [.aiOperation, .searchRebuild],
                        aiProviderResolver: { _ in provider }
                    )
                )
            }
        )
        try runtime.store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try runtime.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_cached_runtime"),
                threadID: ThreadID("thr_cached_runtime"),
                from: EmailAddress("alice@example.com"),
                subject: "Cached",
                preview: "Classify once",
                smartCategory: .unknown
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1, notificationEligible: false
        )
        let firstStatus = try await runtime.organizeSmartInbox(using: "foundation", mode: .incremental)
        let identicalStatus = try await runtime.organizeSmartInbox(using: "foundation", mode: .incremental)
        let organizerCount = try runtime.store.jobs(limit: 100).filter { $0.kind == .aiOperation }.count

        let changedStatus = try await runtime.organizeSmartInbox(using: "ollama", mode: .incremental)

        XCTAssertEqual(firstStatus, "Up to date")
        XCTAssertEqual(identicalStatus, "Up to date")
        XCTAssertEqual(changedStatus, "Up to date")
        XCTAssertEqual(organizerCount, 1)
        XCTAssertEqual(
            try runtime.store.jobs(limit: 100).filter { $0.kind == .aiOperation }.count,
            2
        )
        XCTAssertEqual(provider.classificationCount, 2)
    }

    @MainActor
    func testOrganizeSmartInboxDelegatesEligibilityToOperationClientWhenCacheIsCurrent() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smart-inbox-delegation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let keychainService = "PlainpostRuntimeSmartInboxDelegation.\(UUID().uuidString)"
        let counter = AIOperationCallCounter()
        let provider = DeterministicAIProvider()
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: keychainService,
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { store in
                CountingAIOperationClient(
                    base: LocalOperationClient(
                        runtime: LocalOperationRuntime(
                            store: store,
                            credentials: InMemoryCredentialVault(),
                            allowedJobKinds: [.aiOperation, .searchRebuild],
                            aiProviderResolver: { _ in provider }
                        )
                    ),
                    counter: counter
                )
            }
        )
        try runtime.store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try runtime.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_delegated_runtime"),
                threadID: ThreadID("thr_delegated_runtime"),
                from: EmailAddress("alice@example.com"),
                subject: "Delegated",
                preview: "Classify once",
                smartCategory: .unknown
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1, notificationEligible: false
        )

        _ = try await runtime.organizeSmartInbox(using: "deterministic", mode: .incremental)
        _ = try await runtime.organizeSmartInbox(using: "deterministic", mode: .incremental)

        let callCount = await counter.count
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testRuntimeSearchUsesSQLiteMetadata() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-search-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: selectedDirectRuntimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeSearchTests.\(UUID().uuidString)",
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        try runtime.store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try runtime.store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage,
            metadata: .init(
                to: [EmailAddress("me@example.com")],
                cc: [],
                bcc: [],
                attachments: [.init(filename: "plan.pdf", mimeType: "application/pdf")],
                messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )

        let model = runtime.makeMailSearchViewModel()
        model.query = "has:attachment"
        model.submit()
        await waitForTerminalSearchState(model)

        XCTAssertEqual(
            model.rows.map { model.messageToOpen(for: $0) },
            [PlainpostFixtures.aliceMessage.id]
        )
    }

    @MainActor
    func testSelectedAccountRuntimeScopesSearchAndFilterChoices() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-scoped-search-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("acc_search_second"), displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let seed = try SQLiteMailStore(path: dbURL.path)
        try seed.migrate()
        try seed.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try seed.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                    logicalMailboxID: nil, providerIdentity: nil, generation: 1
                ),
                expectedGeneration: 0
            )
        }
        try seed.cacheMailboxes([
            Mailbox(id: MailboxID("mb_search_first"), accountID: first.id,
                    name: "Private Archive", path: "Archive", specialUse: nil),
            Mailbox(id: MailboxID("mb_search_second"), accountID: second.id,
                    name: "Second Archive", path: "Archive", specialUse: nil),
        ])
        let firstMessage = MessageSummary(
            id: MessageID("msg_search_first"), threadID: ThreadID("thr_search_first"),
            from: EmailAddress("alice@example.com"), subject: "Private orchid",
            preview: "Private orchid", smartCategory: .personal,
            sentAt: Date(timeIntervalSince1970: 1)
        )
        let secondMessage = MessageSummary(
            id: MessageID("msg_search_second"), threadID: ThreadID("thr_search_second"),
            from: EmailAddress("bob@example.com"), subject: "Blue receipt",
            preview: "Blue receipt", smartCategory: .personal,
            sentAt: Date(timeIntervalSince1970: 2)
        )
        for (account, message, uid) in [(first, firstMessage, 1), (second, secondMessage, 2)] {
            _ = try seed.commitIncomingMessage(
                message,
                metadata: .init(to: [account.email], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: uid,
                notificationEligible: false
            )
        }
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL, selectedAccountID: second.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(credentials: InMemoryCredentialVault())
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }
        let model = runtime.makeMailSearchViewModel()
        XCTAssertEqual(model.accounts.map(\.id), [second.id])
        await runtime.refreshMailSearchMailboxes(in: model, forceReload: false)
        XCTAssertEqual(model.mailboxes.map(\.id), [MailboxID("mb_search_second")])

        model.query = "orchid"
        model.submit()
        await waitForTerminalSearchState(model)
        XCTAssertTrue(model.rows.isEmpty)

        model.query = "receipt"
        model.submit()
        await waitForTerminalSearchState(model)
        XCTAssertEqual(model.rows.map { model.messageToOpen(for: $0) }, [secondMessage.id])

        let inbox = runtime.makeInboxViewModel(selectedMessageID: firstMessage.id.rawValue)
        XCTAssertEqual(inbox.classicRows.map(\.id), [secondMessage.id.rawValue])
        XCTAssertTrue(inbox.selectedThread.messages.isEmpty)
        let defaultInbox = runtime.makeInboxViewModel()
        XCTAssertEqual(defaultInbox.selectedThread.messages.map(\.id), [secondMessage.id.rawValue])
        let selectedSource = try seed.mailSource(accountID: second.id)
        let foreignMessageDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.messageToken(
                for: firstMessage.id.rawValue, accountID: first.id.rawValue,
                sourceKind: selectedSource.kind.rawValue, sourceGeneration: selectedSource.generation
            )
        )
        let ownMessageDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.messageToken(
                for: secondMessage.id.rawValue, accountID: second.id.rawValue,
                sourceKind: selectedSource.kind.rawValue, sourceGeneration: selectedSource.generation
            )
        )
        let legacyMessageDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.messageToken(for: secondMessage.id.rawValue)
        )
        let staleSourceDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.messageToken(
                for: secondMessage.id.rawValue, accountID: second.id.rawValue,
                sourceKind: selectedSource.kind.rawValue, sourceGeneration: selectedSource.generation + 1
            )
        )
        let foreignAccountDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.accountInboxToken(for: first.id.rawValue)
        )
        XCTAssertEqual(foreignMessageDestination, .allInboxes)
        XCTAssertEqual(ownMessageDestination, .message(secondMessage.id.rawValue))
        XCTAssertEqual(legacyMessageDestination, .allInboxes)
        XCTAssertEqual(staleSourceDestination, .allInboxes)
        XCTAssertEqual(foreignAccountDestination, .allInboxes)

        let foreignAction = await runtime.makeInboxMailActionViewModel().perform(
            .markRead, messageID: firstMessage.id.rawValue
        )
        guard case .failed = foreignAction else {
            return XCTFail("A selected Direct account accepted a foreign message action")
        }
        XCTAssertFalse(try XCTUnwrap(seed.messageSummary(id: firstMessage.id)).isSeen)
        XCTAssertNil(runtime.makeComposerReplyContext(sourceMessageID: firstMessage.id.rawValue))
        XCTAssertNotNil(runtime.makeComposerReplyContext(sourceMessageID: secondMessage.id.rawValue))

        let composer = runtime.makeComposerViewModel(sourceMessageID: firstMessage.id.rawValue)
        composer.to = "recipient@example.com"
        composer.subject = "Selected account draft"
        composer.bodyPlain = "Created while the other account is selected."
        try await composer.saveDraft()
        let draftID = try XCTUnwrap(composer.lastDraftID)
        let draft = try runtime.store.draft(id: DraftID(draftID))
        XCTAssertEqual(draft.accountID, second.id)
        XCTAssertEqual(draft.from, second.email)
    }

    @MainActor
    func testRuntimeRefreshesSearchMailboxMetadataThroughAsyncProjection() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-search-mailboxes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let configuration = try selectedDirectRuntimeConfiguration(
            databaseURL: dbURL,
            keychainService: "PlainpostRuntimeSearchMailboxTests.\(UUID().uuidString)",
            account: PlainpostFixtures.personalAccount
        )
        let runtime = try PlainpostAppRuntime(
            configuration: configuration,
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let account = PlainpostFixtures.personalAccount
        try runtime.store.cacheAccounts([account])
        try runtime.store.cacheMailboxes([
            Mailbox(
                id: MailboxID("archive"),
                accountID: account.id,
                name: "Project Archive",
                path: "Archive/Projects",
                specialUse: nil
            )
        ])
        let model = runtime.makeMailSearchViewModel()

        XCTAssertTrue(model.mailboxes.isEmpty)
        await runtime.refreshMailSearchMailboxes(in: model, forceReload: false)

        XCTAssertEqual(
            model.mailboxes,
            [
                MailSearchMailbox(
                    id: MailboxID("archive"),
                    accountID: account.id,
                    displayName: "Project Archive"
                )
            ]
        )
    }

    @MainActor
    func testCancelledSearchMailboxRefreshKeepsCachedMetadataAfterAdmittedRead() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-cancelled-search-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let configuration = try selectedDirectRuntimeConfiguration(
            databaseURL: dbURL,
            keychainService: "PlainpostRuntimeCancelledSearch.\(UUID().uuidString)",
            account: PlainpostFixtures.personalAccount
        )
        let runtime = try PlainpostAppRuntime(configuration: configuration,
                                             notificationScheduler: NoopLocalNotificationScheduler())
        let model = runtime.makeMailSearchViewModel()
        let cached = MailSearchMailbox(id: MailboxID("cached"), accountID: PlainpostFixtures.personalAccount.id,
                                       displayName: "Cached")
        let replacement = MailSearchMailbox(id: MailboxID("new"), accountID: PlainpostFixtures.personalAccount.id,
                                            displayName: "New")
        model.updateMailboxes([cached])
        let gate = MailRefreshTestBarrier()
        let refresh = Task {
            await runtime.refreshMailSearchMailboxes(in: model, forceReload: true) { forced in
                XCTAssertTrue(forced)
                await gate.wait()
                return [replacement]
            }
        }
        await gate.arrived.wait(for: 1)
        refresh.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        gate.release()
        await refresh.value
        XCTAssertEqual(model.mailboxes, [cached])

        enum ReadFailure: Error { case unavailable }
        await runtime.refreshMailSearchMailboxes(in: model, forceReload: true) { _ in
            throw ReadFailure.unavailable
        }
        XCTAssertEqual(model.mailboxes, [cached], "a failed refresh retains cached metadata")
    }

    @MainActor
    private func waitForTerminalSearchState(
        _ model: MailSearchViewModel,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while case .searching = model.state {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for mail search to reach a terminal state.")
                return
            }
            try? await clock.sleep(for: .milliseconds(10))
        }
    }

    func testDefaultNotificationSchedulerUsesNoopOutsideAppBundle() {
        let swiftPMExecutableURL = URL(fileURLWithPath: "/tmp/Plainpost/.build/debug/")
        let appBundleURL = URL(fileURLWithPath: "/Applications/Plainpost.app")

        XCTAssertEqual(defaultNotificationSchedulerSelection(bundleURL: swiftPMExecutableURL), .noop)
        XCTAssertEqual(defaultNotificationSchedulerSelection(bundleURL: appBundleURL), .userNotifications)
    }

    @MainActor
    func testApprovalSidebarBadgeCountsOnlyPendingRequests() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-approval-badge-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeApprovalBadgeTests.\(UUID().uuidString)",
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let draft = try runtime.store.createDraft(
            PlainpostFixtures.replyDraft,
            actor: PlainpostFixtures.codexActor
        )
        let request = try runtime.store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Review this"
        )

        XCTAssertEqual(
            runtime.makeInboxViewModel().sidebarItems.first { $0.title == "Agent approvals" }?.badge,
            1
        )

        _ = try runtime.store.updateSendRequest(
            id: request.id,
            status: .denied,
            approvedBy: "local-user",
            approvedDraftHash: nil
        )

        XCTAssertEqual(
            runtime.makeInboxViewModel().sidebarItems.first { $0.title == "Agent approvals" }?.badge,
            0
        )
    }

    @MainActor
    func testSelectedDirectAccountCannotReviewAnotherAccountsApproval() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-scoped-approvals-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("acc_approval_second"), displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let seed = try SQLiteMailStore(path: dbURL.path)
        try seed.migrate()
        try seed.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try seed.replaceMailSource(
                AccountMailSource(accountID: account.id, kind: .direct, mode: nil,
                                  nodeID: nil, logicalMailboxID: nil,
                                  providerIdentity: nil, generation: 1),
                expectedGeneration: 0)
        }
        let firstDraft = try seed.createDraft(
            Draft(id: DraftID("draft_approval_first"), accountID: first.id, from: first.email,
                  to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                  subject: "First account private approval", bodyPlain: "Private first body",
                  createdBy: PlainpostFixtures.codexActor.id, aiGenerated: false,
                  sourceThreadID: nil),
            actor: PlainpostFixtures.codexActor)
        let secondDraft = try seed.createDraft(
            Draft(id: DraftID("draft_approval_second"), accountID: second.id, from: second.email,
                  to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                  subject: "Second account approval", bodyPlain: "Second body",
                  createdBy: PlainpostFixtures.codexActor.id, aiGenerated: false,
                  sourceThreadID: nil),
            actor: PlainpostFixtures.codexActor)
        let firstRequest = try seed.requestSend(
            draftID: firstDraft.id, actor: PlainpostFixtures.codexActor, reason: "Review first")
        let secondRequest = try seed.requestSend(
            draftID: secondDraft.id, actor: PlainpostFixtures.codexActor, reason: "Review second")
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL, selectedAccountID: second.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(credentials: InMemoryCredentialVault())),
            notificationScheduler: NoopLocalNotificationScheduler())
        defer { Task { await runtime.shutdown() } }

        let queue = runtime.makeApprovalQueueViewModel()
        try await queue.refresh()
        XCTAssertEqual(queue.items.map(\.id), [secondRequest.id.rawValue])
        XCTAssertEqual(
            runtime.makeInboxViewModel().sidebarItems.first { $0.title == "Agent approvals" }?.badge,
            1
        )
        do {
            try await queue.deny(requestID: firstRequest.id.rawValue, reason: "wrong account")
            XCTFail("A selected Direct account denied another account's approval")
        } catch {
            guard case PlainpostError.permissionDenied = error else {
                return XCTFail("Expected an account-scoping denial, received: \(error)")
            }
            XCTAssertEqual(try seed.sendRequest(id: firstRequest.id).status, .pending)
        }
        do {
            try await queue.approve(requestID: firstRequest.id.rawValue, username: "", password: "")
            XCTFail("A selected Direct account approved another account's send")
        } catch {
            guard case PlainpostError.permissionDenied = error else {
                return XCTFail("Expected an account-scoping denial, received: \(error)")
            }
            XCTAssertEqual(try seed.sendRequest(id: firstRequest.id).status, .pending)
        }
    }

    @MainActor
    func testRuntimeAccountSetupUsesSQLiteAndVaultWithLocalHarnesses() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "runtime-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "runtime-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostRuntimeTests.\(UUID().uuidString)"
        let isolation = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: dbURL,
            keychainService: keychainService
        )
        let credentials = isolation.credentials

        let runtime = try makeRuntimeWithoutPackagedSideEffects(isolation.configuration)
        let accountSetup = runtime.makeAccountSetupViewModel()
        accountSetup.displayName = "Personal"
        accountSetup.email = "me@example.com"
        accountSetup.imapHost = "127.0.0.1"
        accountSetup.imapPort = "\(imap.port)"
        accountSetup.smtpHost = "127.0.0.1"
        accountSetup.smtpPort = "\(smtp.port)"
        accountSetup.username = "me@example.com"
        accountSetup.imapPassword = "runtime-imap-secret"
        accountSetup.smtpPassword = "runtime-smtp-secret"

        try await accountSetup.submit()

        XCTAssertEqual(accountSetup.status, AccountSetupStatus.connected(accountID: "acc_me_example_com"))
        let selectedRuntime = try makeRuntimeWithoutPackagedSideEffects(
            PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL, selectedAccountID: AccountID("acc_me_example_com"),
                runtimeDependencies: isolation.runtimeDependencies
            )
        )
        defer { Task { await selectedRuntime.shutdown() } }
        XCTAssertFalse(selectedRuntime.makeInboxViewModel().requiresAccountSetup)
        let connectedSetup = selectedRuntime.makeAccountSetupViewModel()
        XCTAssertEqual(connectedSetup.status, AccountSetupStatus.connected(accountID: "acc_me_example_com"))
        XCTAssertEqual(connectedSetup.lastConnectedEmail, "me@example.com")
        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts.map(\.email.rawValue), ["me@example.com"])
        let storedIMAP = try await credentials.load(
            CredentialRecordKey(rawValue: "account:acc_me_example_com:imap-password")
        )
        let storedSMTP = try await credentials.load(
            CredentialRecordKey(rawValue: "account:acc_me_example_com:smtp-password")
        )
        XCTAssertEqual(storedIMAP, Data("runtime-imap-secret".utf8))
        XCTAssertEqual(storedSMTP, Data("runtime-smtp-secret".utf8))
    }

    @MainActor
    func testRuntimeAccountSetupSyncsInitialInboxHistory() async throws {
        let imapPassword = "runtime-history-imap-secret"
        let smtpPassword = "runtime-history-smtp-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: imapPassword,
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: smtpPassword)
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostRuntimeHistoryTests.\(UUID().uuidString)"

        let isolation = RuntimeKeychainIsolation(
            testCase: self, databaseURL: dbURL, keychainService: keychainService
        )
        let runtime = try makeRuntimeWithoutPackagedSideEffects(isolation.configuration)
        let accountSetup = runtime.makeAccountSetupViewModel()
        accountSetup.displayName = "Personal"
        accountSetup.email = "me@example.com"
        accountSetup.imapHost = "127.0.0.1"
        accountSetup.imapPort = "\(imap.port)"
        accountSetup.smtpHost = "127.0.0.1"
        accountSetup.smtpPort = "\(smtp.port)"
        accountSetup.username = "me@example.com"
        accountSetup.imapPassword = imapPassword
        accountSetup.smtpPassword = smtpPassword

        try await accountSetup.submit()

        let selectedRuntime = try makeRuntimeWithoutPackagedSideEffects(
            PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL, selectedAccountID: AccountID("acc_me_example_com"),
                runtimeDependencies: isolation.runtimeDependencies
            )
        )
        defer { Task { await selectedRuntime.shutdown() } }
        let inbox = selectedRuntime.makeInboxViewModel()
        XCTAssertEqual(inbox.classicRows.map(\.subject), ["Availability"])
        XCTAssertEqual(inbox.selectedThread.messages.map(\.sender), ["alice@example.com"])

        let connectedAccount = selectedRuntime.makeAccountSetupViewModel()
        await connectedAccount.syncInbox()
        XCTAssertEqual(connectedAccount.lastSyncedMessageCount, 1)
        XCTAssertEqual(
            try selectedRuntime.store.mailboxSyncStatuses(accountID: AccountID("acc_me_example_com")).first?.downloaded,
            1
        )
        XCTAssertNil(connectedAccount.lastSyncError)
    }

    @MainActor
    func testRuntimeDeletesAccountThroughForegroundService() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-delete-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let account = Account(
            id: AccountID("acc_runtime_delete"),
            displayName: "Delete Me",
            email: EmailAddress("delete@example.com"),
            username: "delete@example.com",
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let seedStore = try SQLiteMailStore(path: databaseURL.path)
        try seedStore.migrate()
        try seedStore.cacheAccounts([account])
        let credentials = InMemoryCredentialVault()
        let serviceClient = RuntimeAccountDeletionServiceClient(
            databaseURL: databaseURL,
            credentials: credentials
        )
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                keychainService: "PlainpostRuntimeDelete.\(UUID().uuidString)",
                serviceClient: serviceClient
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }
        let viewModel = runtime.makeAccountSetupViewModel()

        await viewModel.deleteSelectedAccount()

        let deletedAccountIDs = await serviceClient.deletionSnapshot()
        XCTAssertEqual(deletedAccountIDs, [account.id])
        XCTAssertNil(viewModel.account)
        XCTAssertTrue(viewModel.accounts.isEmpty)
        XCTAssertEqual(viewModel.status, .idle)
        let reloaded = try SQLiteMailStore(path: databaseURL.path)
        try reloaded.migrate()
        XCTAssertTrue(reloaded.accounts.isEmpty)
    }

    @MainActor
    func testSelectedDirectAuditViewDoesNotShowOtherAccountOrRawCombinedFile() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-audit-scope-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("audit-runtime-second"), displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let node = Account(
            id: AccountID("audit-runtime-node"), displayName: "Node",
            email: EmailAddress("node@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([first, second, node])
        for account in [first, second] {
            _ = try seed.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
            _ = try seed.createDraft(
                Draft(
                    id: DraftID("audit-draft-\(account.id.rawValue)"),
                    accountID: account.id, from: account.email,
                    to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                    subject: "Audit isolation", bodyPlain: "Private draft",
                    createdBy: PlainpostFixtures.codexActor.id,
                    aiGenerated: false, sourceThreadID: nil
                ), actor: PlainpostFixtures.codexActor
            )
        }
        _ = try seed.replaceMailSource(
            AccountMailSource(
                accountID: node.id, kind: .nodeBacked, mode: .node,
                nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: node.email.rawValue, generation: 1
            ), expectedGeneration: 0
        )
        _ = try seed.createDraft(
            Draft(
                id: DraftID("audit-draft-\(node.id.rawValue)"),
                accountID: node.id, from: node.email,
                to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                subject: "Audit isolation", bodyPlain: "Private draft",
                createdBy: PlainpostFixtures.codexActor.id,
                aiGenerated: false, sourceThreadID: nil
            ), actor: PlainpostFixtures.codexActor
        )
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: second.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ), notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }

        // Harden the isolation claim below: prove the raw combined file genuinely holds
        // `first`'s and `node`'s entries (not just that the view model happens to omit
        // them), so hiding `auditLogURL` and scoping the export are actually load-bearing.
        let rawAuditLogContents = try String(contentsOf: seed.auditLogURL, encoding: .utf8)
        XCTAssertTrue(rawAuditLogContents.contains("audit-draft-\(first.id.rawValue)"))
        XCTAssertTrue(rawAuditLogContents.contains("audit-draft-\(node.id.rawValue)"))

        let audit = runtime.makeAuditLogViewModel()
        try await audit.refresh()

        // This runtime's one on-device database and rotating audit log hold every Direct
        // and Sync Node account on the device (commit 077feb952), so the raw combined file
        // must stay hidden; only an export of the selected account's own entries is safe to
        // hand out (e.g. to iOS's "Share Audit Log").
        XCTAssertNil(audit.auditLogURL)
        XCTAssertTrue(audit.rows.contains { $0.targetSummary.contains("audit-draft-\(second.id.rawValue)") })
        XCTAssertFalse(audit.rows.contains { $0.targetSummary.contains("audit-draft-\(first.id.rawValue)") })
        XCTAssertFalse(audit.rows.contains { $0.targetSummary.contains("audit-draft-\(node.id.rawValue)") })

        let exportedURL = try XCTUnwrap(audit.exportAuditLog?())
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let exportedContents = try String(contentsOf: exportedURL, encoding: .utf8)
        XCTAssertTrue(exportedContents.contains("audit-draft-\(second.id.rawValue)"))
        XCTAssertFalse(exportedContents.contains("audit-draft-\(first.id.rawValue)"))
        XCTAssertFalse(exportedContents.contains("audit-draft-\(node.id.rawValue)"))
    }

    @MainActor
    func testRuntimeViewModelsShareStoreForDraftAuditAndInboxActions() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-shared-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let account = PlainpostFixtures.personalAccount

        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeSharedTests.\(UUID().uuidString)",
                account: account
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let sentAt = Date(timeIntervalSince1970: 1_783_585_600)
        try runtime.store.cacheAccounts([account])
        _ = try runtime.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_uid_1"), threadID: ThreadID("thr_runtime"),
                from: EmailAddress("alice@example.com"), subject: "Runtime message",
                preview: "Shared store message", smartCategory: .personal, labels: [],
                isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                body: "Shared store message", sentAt: sentAt,
                replyTo: EmailAddress("replies@example.com")
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let inbox = runtime.makeInboxViewModel(selectedMessageID: "msg_uid_1")
        XCTAssertEqual(
            inbox.selectedThread.messages.first?.dateLabel,
            MailTimestampFormatter.readerLabel(for: sentAt)
        )
        XCTAssertEqual(inbox.selectedThread.messages.first?.replyTo, "replies@example.com")

        let composer = runtime.makeComposerViewModel()
        composer.to = "alice@example.com"
        composer.subject = "Runtime draft"
        composer.bodyPlain = "Created through the runtime composer."
        try await composer.saveDraft()

        let inboxActions = runtime.makeInboxMailActionViewModel()
        _ = await inboxActions.perform(.markRead, messageID: "msg_uid_1")

        let audit = runtime.makeAuditLogViewModel()
        try await audit.refresh()

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let draftID = try XCTUnwrap(composer.lastDraftID)
        XCTAssertEqual(try reloaded.draft(id: DraftID(draftID)).subject, "Runtime draft")
        XCTAssertEqual(reloaded.messages.first(where: { $0.id == MessageID("msg_uid_1") })?.isSeen, true)
        XCTAssertTrue(audit.rows.contains { $0.action == "draft.create" })
        XCTAssertTrue(audit.rows.contains { $0.action == "message.mark_seen" })
    }

    @MainActor
    func testRetainedNodeComposerResolvesSenderAfterAuthorityStatusRefresh() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-node-composer-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let authority = RuntimeComposerAuthority()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                mailAuthority: authority
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }

        let composer = runtime.makeComposerViewModel()
        composer.to = "alice@example.com"
        composer.subject = "Node sender refresh"
        composer.bodyPlain = "The sender is resolved at operation time."

        try await composer.saveDraft()
        XCTAssertEqual(composer.statusMessage, "No authenticated sender identity is available for this account.")

        authority.setSender(EmailAddress("refreshed@example.com"))
        try await composer.saveDraft()
        let draftValue = await authority.recordedDraft()
        let draft = try XCTUnwrap(draftValue)
        XCTAssertEqual(draft.from, EmailAddress("refreshed@example.com"))
    }

    /// `PlainpostNodeMailAuthority.onStatusRefresh` is a single-slot callback (see
    /// `PlainpostNodeMailAuthority.swift`): a second `SyncNodeSettingsViewModel` built by a
    /// second caller (the ⌘, Settings window, alongside the main window's session) would
    /// silently steal live status pushes from whichever model was built first. The runtime
    /// must hand every caller the same instance.
    @MainActor
    func testMakeNodeSettingsViewModelReturnsSameInstanceToEveryCaller() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-node-settings-shared-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let authority = RuntimeComposerAuthority()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                mailAuthority: authority
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }

        let fromMainWindowSession = try XCTUnwrap(runtime.makeNodeSettingsViewModel(onConnectProvider: {}))
        let fromSettingsWindow = try XCTUnwrap(runtime.makeNodeSettingsViewModel())
        XCTAssertTrue(fromMainWindowSession === fromSettingsWindow)
    }

    /// The embedded composer (iPhone/iPad) builds Reply All from the reader's thread
    /// messages, so a Sync Node thread message must carry the original To and Cc.
    @MainActor
    func testNodeThreadMessageCarriesToAndCcIntoReplyAll() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-node-reply-all-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let message = MessageSummary(
            id: MessageID("msg_node_reply_all"),
            threadID: ThreadID("thr_node_reply_all"),
            from: EmailAddress("maria@northwind.example"),
            subject: "Planning",
            preview: "Shall we meet?",
            smartCategory: .personal,
            labels: [],
            isSeen: false,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Shall we meet?",
            sentAt: Date(timeIntervalSince1970: 1),
            rfcMessageID: "<planning@northwind.example>",
            to: [EmailAddress("me@example.com"), EmailAddress("tom@northwind.example")],
            cc: [EmailAddress("ann@northwind.example")]
        )
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                mailAuthority: RuntimeComposerAuthority(messages: [message])
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }

        let inbox = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: "msg_node_reply_all")
        let threadMessage = try XCTUnwrap(inbox.selectedThread.messages.first)
        XCTAssertEqual(threadMessage.to, ["me@example.com", "tom@northwind.example"])
        XCTAssertEqual(threadMessage.cc, ["ann@northwind.example"])

        let compose = ComposeCoordinator(
            composer: ComposerViewModel(composer: UnavailableComposerDraftHandler()),
            undoSend: .preview(state: .sent),
            policy: .embedded,
            aiAssistant: .preview(),
            thread: { inbox.selectedThread },
            ownAddresses: { ["me@example.com"] }
        )
        let presentation = await compose.request(.replyAll(messageID: "msg_node_reply_all"))
        XCTAssertEqual(presentation, .embedded)
        XCTAssertEqual(compose.composer.to, "maria@northwind.example")
        XCTAssertEqual(compose.composer.cc, "tom@northwind.example, ann@northwind.example")
    }

    @MainActor
    func testFreshNodeRuntimeDoesNotReachLegacyCredentialSetupWithEmptySQLiteProjection() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-fresh-node-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                mailAuthority: RuntimeComposerAuthority()
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let setup = runtime.makeAccountSetupViewModel()
        setup.displayName = "Legacy must not be used"
        setup.email = "user@example.com"
        setup.imapHost = "imap.example.com"
        setup.smtpHost = "smtp.example.com"
        setup.username = "user@example.com"
        setup.imapPassword = "not-a-node-secret"
        setup.smtpPassword = "not-a-node-secret"

        do {
            try await setup.submit()
            XCTFail("Node-backed runtime must reject the legacy credential setup path")
        } catch {
            XCTAssertEqual(setup.status, .failed(message: "Account verification failed."))
        }
        XCTAssertTrue(runtime.store.accounts.isEmpty)
    }

    @MainActor
    func testSelectedNodeRuntimeUsesSharedStoreAndOnlyProjectsSelectedAccount() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-selected-node-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let selected = Account(
            id: AccountID("acc_node"), displayName: "Selected Node",
            email: EmailAddress("node@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        let foreign = Account(
            id: AccountID("acc_direct"), displayName: "Foreign Direct",
            email: EmailAddress("direct@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        for account in [foreign, selected] {
            try store.cacheAccountSetup(
                account: account,
                inbox: Mailbox(
                    id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                    name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
                ),
                source: try AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                    logicalMailboxID: nil, providerIdentity: nil, generation: 1
                )
            )
        }
        let source = try store.mailSource(accountID: selected.id)
        _ = try store.replaceMailSource(source.nodeBacked(
            nodeID: "00112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: selected.email.rawValue
        ), expectedGeneration: source.generation)
        for (index, account) in [foreign, selected].enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("message-\(account.id.rawValue)"), threadID: nil,
                    from: account.email, subject: account.displayName,
                    preview: "Account-specific mail", smartCategory: .personal
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
                uid: index + 1, notificationEligible: false
            )
        }
        let foreignDraft = try store.createDraft(
            Draft(
                id: DraftID("draft-foreign-direct"), accountID: foreign.id,
                from: foreign.email, to: [EmailAddress("recipient@example.test")],
                cc: [], bcc: [], subject: "Foreign approval",
                bodyPlain: "Private Direct content",
                createdBy: PlainpostFixtures.codexActor.id, aiGenerated: false,
                sourceThreadID: nil
            ),
            actor: PlainpostFixtures.codexActor
        )
        _ = try store.requestSend(
            draftID: foreignDraft.id, actor: PlainpostFixtures.codexActor,
            reason: "Foreign account review"
        )

        let aiClient = RejectingMaintenanceOperationClient()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                selectedAccountID: selected.id,
                mailAuthority: RuntimeComposerAuthority()
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            aiOperationClientFactory: { _ in aiClient }
        )
        defer { Task { await runtime.shutdown() } }
        XCTAssertEqual(runtime.configuration.databaseURL, databaseURL)
        XCTAssertEqual(runtime.configuration.selectedAccountID, selected.id)
        XCTAssertEqual(runtime.store.accounts.count, 2)
        XCTAssertEqual(runtime.makeMailSearchViewModel().accounts.map(\.id), [selected.id])
        XCTAssertEqual(runtime.makeMailRulesViewModel().accounts.map(\.id), [selected.id])
        XCTAssertEqual(runtime.makeMailLabelsViewModel().accounts.map(\.id), [selected.id])
        XCTAssertEqual(runtime.makeAccountSetupViewModel().accounts.map(\.id), [selected.id])
        let approvals = runtime.makeApprovalQueueViewModel()
        try await approvals.refresh()
        XCTAssertTrue(approvals.items.isEmpty)
        let foreignMessageToken = NotificationOpaqueIdentities.messageToken(
            for: "message-acc_direct"
        )
        let foreignInboxToken = NotificationOpaqueIdentities.accountInboxToken(
            for: foreign.id.rawValue
        )
        let resolvedForeignMessage = await runtime.resolveNotificationOpen(foreignMessageToken)
        let resolvedForeignInbox = await runtime.resolveNotificationOpen(foreignInboxToken)
        XCTAssertEqual(resolvedForeignMessage, .allInboxes)
        XCTAssertEqual(resolvedForeignInbox, .allInboxes)
        let audit = runtime.makeAuditLogViewModel()
        try await audit.refresh()
        XCTAssertNil(audit.auditLogURL)
        XCTAssertTrue(audit.rows.isEmpty)
        XCTAssertTrue(audit.operationRows.isEmpty)
        let assistant = runtime.makeThreadAIAssistantViewModel()
        runtime.configureThreadAIAssistant(assistant, providerID: "deterministic")
        await assistant.loadSummary(for: EmailSummaryContext(
            messageID: MessageID("message-acc_direct"),
            contentFingerprint: "foreign-node-runtime"
        ))
        let threadInput = await aiClient.lastAIInput
        XCTAssertNil(threadInput)
        let ask = runtime.makeAskMailViewModel()
        runtime.configureAskMail(ask, providerID: "deterministic")
        ask.input = "What is in my mail?"
        await ask.askCurrentQuestion()
        let askInput = await aiClient.lastAIInput
        XCTAssertNil(askInput)
        let inbox = runtime.makeInboxViewModel()
        XCTAssertEqual(inbox.accountIdentity?.email, selected.email.rawValue)
        XCTAssertEqual(inbox.classicRows.map(\.id), ["message-acc_node"])

        XCTAssertThrowsError(try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                selectedAccountID: foreign.id,
                mailAuthority: RuntimeComposerAuthority()
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        ), "A Node authority may not open a foreign Direct account")
    }

    @MainActor
    func testSelectedDirectRuntimeScopesAllDirectStoreAndFencesRetainedActions() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-mixed-direct-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let node = Account(
            id: AccountID("acc_mixed_node"), displayName: "Node A",
            email: EmailAddress("node-a@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        let selected = Account(
            id: AccountID("acc_mixed_selected"), displayName: "Direct B",
            email: EmailAddress("direct-b@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        let foreign = Account(
            id: AccountID("acc_mixed_foreign"), displayName: "Direct C",
            email: EmailAddress("direct-c@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        for (index, account) in [node, selected, foreign].enumerated() {
            try seed.cacheAccountSetup(
                account: account,
                inbox: Mailbox(
                    id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                    name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
                ),
                source: try AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil, providerIdentity: nil,
                    generation: 1
                )
            )
            _ = try seed.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("message-\(account.id.rawValue)"), threadID: nil,
                    from: account.email, subject: account.displayName,
                    preview: "Account-specific mail", smartCategory: .personal
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
                uid: index + 1, notificationEligible: false
            )
        }
        let nodeDirectSource = try seed.mailSource(accountID: node.id)
        _ = try seed.replaceMailSource(nodeDirectSource.nodeBacked(
            nodeID: "00112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: node.email.rawValue
        ), expectedGeneration: nodeDirectSource.generation)
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: selected.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }
        XCTAssertNil(runtime.mailAuthority)
        XCTAssertNil(runtime.localAPIOwnershipState)
        XCTAssertEqual(runtime.makeInboxViewModel().classicRows.map(\.id), ["message-acc_mixed_selected"])
        XCTAssertEqual(runtime.makeMailSearchViewModel().accounts.map(\.id), [selected.id])
        XCTAssertEqual(runtime.makeAccountSetupViewModel().accounts.map(\.id), [selected.id])
        XCTAssertEqual(runtime.makeMailRulesViewModel().accounts.map(\.id), [selected.id])
        XCTAssertEqual(runtime.makeMailLabelsViewModel().accounts.map(\.id), [selected.id])
        XCTAssertEqual(runtime.makeAIIndexStatusModel().detail, "1 message indexed")
        let search = runtime.makeMailSearchViewModel()
        await runtime.refreshMailSearchMailboxes(in: search, forceReload: false)
        XCTAssertEqual(search.mailboxes.map(\.accountID), [selected.id])
        search.query = "Direct B"
        search.submit()
        await waitForTerminalSearchState(search)
        XCTAssertEqual(search.rows.map { search.messageToOpen(for: $0) }, [MessageID("message-acc_mixed_selected")])
        let foreignInbox = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.accountInboxToken(for: node.id.rawValue)
        )
        XCTAssertEqual(foreignInbox, .allInboxes)
        let foreignAction = await runtime.makeInboxMailActionViewModel().perform(
            .markRead, messageID: "message-acc_mixed_node"
        )
        guard case .failed = foreignAction else {
            return XCTFail("Direct B accepted a Node A mail action")
        }
        let audit = runtime.makeAuditLogViewModel()
        try await audit.refresh()
        // This runtime's one on-device database and rotating audit log hold every Direct
        // and Sync Node account, so the raw combined file stays hidden on every route.
        XCTAssertNil(audit.auditLogURL)
        XCTAssertFalse(audit.rows.contains { $0.targetSummary.contains(node.id.rawValue) })
        let composer = runtime.makeComposerViewModel(sourceMessageID: "message-acc_mixed_node")
        composer.to = "recipient@example.test"
        composer.subject = "Selected account draft"
        composer.bodyPlain = "Only Direct B should own this draft."
        try await composer.saveDraft()
        let draft = try runtime.store.draft(id: DraftID(try XCTUnwrap(composer.lastDraftID)))
        XCTAssertEqual(draft.accountID, selected.id)
        XCTAssertEqual(try seed.mailSource(accountID: node.id).kind, .nodeBacked)

        do {
            try await runtime.openSelectedMessage(MessageID("message-acc_mixed_node"))
            XCTFail("A Direct B runtime opened Node A mail")
        } catch {}
        XCTAssertFalse(try XCTUnwrap(seed.messageSummary(id: MessageID("message-acc_mixed_node"))).isSeen)

        let selectedSource = try seed.mailSource(accountID: selected.id)
        let transientNodeSource = try seed.replaceMailSource(selectedSource.nodeBacked(
            nodeID: "11112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: selected.email.rawValue
        ), expectedGeneration: selectedSource.generation)
        _ = try seed.replaceMailSource(
            transientNodeSource.revertedToDirect(),
            expectedGeneration: transientNodeSource.generation
        )
        XCTAssertTrue(runtime.makeInboxViewModel().classicRows.isEmpty)
        XCTAssertEqual(runtime.makeAIIndexStatusModel().detail, "0 messages indexed")
        let refreshedRuntime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: selected.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ), notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await refreshedRuntime.shutdown() } }
        try await refreshedRuntime.openSelectedMessage(MessageID("message-acc_mixed_selected"))
        XCTAssertTrue(try XCTUnwrap(seed.messageSummary(
            id: MessageID("message-acc_mixed_selected")
        )).isSeen)
        let staleMessageToken = NotificationOpaqueIdentities.messageToken(
            for: "message-acc_mixed_selected", accountID: selected.id.rawValue,
            sourceKind: selectedSource.kind.rawValue,
            sourceGeneration: selectedSource.generation
        )
        let staleMessageDestination = await runtime.resolveNotificationOpen(staleMessageToken)
        let staleInboxDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.accountInboxToken(for: selected.id.rawValue)
        )
        XCTAssertEqual(staleMessageDestination, .allInboxes)
        XCTAssertEqual(staleInboxDestination, .allInboxes)
        XCTAssertNil(runtime.makeComposerReplyContext(
            sourceMessageID: "message-acc_mixed_selected"
        ))
        do {
            try await runtime.openSelectedMessage(MessageID("message-acc_mixed_selected"))
            XCTFail("A stale Direct B runtime opened a new Direct generation")
        } catch {}
        let staleComposer = runtime.makeComposerViewModel()
        staleComposer.to = "recipient@example.test"
        staleComposer.subject = "Stale draft"
        staleComposer.bodyPlain = "A previous Direct generation must not write."
        do {
            try await staleComposer.saveDraft()
            XCTFail("A stale Direct B runtime saved a draft in a new source generation")
        } catch {}
        XCTAssertNil(staleComposer.lastDraftID)

    }

    @MainActor
    func testNodeSettingsRemainVisibleForCachedAuthorityButProviderOnboardingIsActiveOnly() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-settings-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let writableStore = try SQLiteMailStore(path: databaseURL.path)
        try writableStore.migrate()
        let authority = RuntimeComposerAuthority()

        let active = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                mailAuthority: authority
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let activeSettings = try XCTUnwrap(
            active.makeNodeSettingsViewModel(onConnectProvider: {})
        )
        XCTAssertTrue(activeSettings.canConnectProvider)

        let cached = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                mailAuthority: authority
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            accountAccess: .cachedReadOnly
        )
        let cachedSettings = try XCTUnwrap(
            cached.makeNodeSettingsViewModel(onConnectProvider: {})
        )
        XCTAssertFalse(cachedSettings.canConnectProvider)
    }

    @MainActor
    func testRuntimeThreadAssistantUsesRuntimeStoreContext() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-ai-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let account = PlainpostFixtures.personalAccount

        let runtime = try PlainpostAppRuntime(
            configuration: try selectedDirectRuntimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeAITests.\(UUID().uuidString)",
                account: account
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        try runtime.store.cacheAccounts([account])
        try runtime.store.cacheThread(MailThread(
            id: ThreadID("thr_runtime_ai"),
            accountID: account.id,
            subjectNormalized: "runtime ai",
            participantEmails: []
        ))
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_runtime_ai_first"),
                threadID: ThreadID("thr_runtime_ai"),
                from: EmailAddress("alice@example.com"),
                subject: "Runtime AI",
                preview: "Can you meet next Tuesday?",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 1)
            )
        )
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_runtime_ai_second"),
                threadID: ThreadID("thr_runtime_ai"),
                from: EmailAddress("bob@example.com"),
                subject: "Re: Runtime AI",
                preview: "Tuesday works for me.",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 2)
            )
        )

        let assistant = runtime.makeThreadAIAssistantViewModel()
        runtime.configureThreadAIAssistant(assistant, providerID: "deterministic")
        await assistant.loadSummary(for: EmailSummaryContext(
            messageID: MessageID("msg_runtime_ai_second"),
            contentFingerprint: "runtime-ai"
        ))

        XCTAssertEqual(assistant.providerName, "Deterministic Local")
        XCTAssertEqual(assistant.modelID, "deterministic-local")
        XCTAssertEqual(assistant.contextMessageIDs, ["msg_runtime_ai_first", "msg_runtime_ai_second"])
        XCTAssertEqual(assistant.localityLabel, "On-device 🔒")

        assistant.chatInput = "Which day works?"
        await assistant.askCurrentQuestion()

        XCTAssertEqual(assistant.chatTurns.count, 1)
        XCTAssertEqual(assistant.chatTurns.first?.question, "Which day works?")
        XCTAssertFalse(assistant.chatTurns.first?.answer.isEmpty ?? true)
    }

    @MainActor
    func testRuntimeThreadTranslationUsesAndReconfiguresResolvedProviderIdentity() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-translation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = try SQLiteMailStore(path: dbURL.path)
        try store.migrate()
        let operationClient = RejectingMaintenanceOperationClient()
        let message = MessageSummary(
            id: MessageID("msg_runtime_translation"),
            threadID: ThreadID("thr_runtime_translation"),
            from: EmailAddress("sender@example.com"),
            subject: "Translate",
            preview: "Original",
            body: "Original",
            smartCategory: .personal
        )
        try store.cacheMessage(message)
        let readerMessage = ThreadMessageModel(
            id: message.id.rawValue,
            sender: message.from.rawValue,
            body: .plainText(message.body)
        )
        let configuration = ThreadTranslationConfiguration(
            targetLanguageID: "de",
            targetLanguageName: "German"
        )
        let foundation = try LocalAIProviderResolver.resolve(
            LocalAIProviderSelection(providerID: "foundation")
        )
        let unavailableOllamaFallback = DisabledAIProvider()
        func cache(for provider: any AIProvider, body: String) throws {
            let translation = CachedMessageTranslation(
                messageID: message.id,
                targetLanguageID: configuration.targetLanguageID,
                sourceFingerprint: MailTranslationFingerprint.message(message),
                providerID: provider.id,
                modelID: provider.chatModelID,
                contractVersion: MailTranslationContract.version,
                bodyKind: .plainText,
                translatedBody: body,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
            XCTAssertEqual(
                try store.compareAndSaveCachedTranslation(
                    translation,
                    expectedSourceFingerprint: translation.sourceFingerprint
                ),
                .saved
            )
        }

        try cache(for: foundation, body: "Stiftung")
        let translation = PlainpostAppRuntime.makeThreadTranslationViewModel(
            aiOperationClient: operationClient,
            store: store,
            providerID: "foundation"
        )
        await translation.prepare(
            messages: [readerMessage],
            configuration: configuration
        )
        XCTAssertEqual(translation.actionTitle, "Show Translation")

        PlainpostAppRuntime.configureThreadTranslation(
            translation,
            aiOperationClient: operationClient,
            store: store,
            providerID: "ollama"
        )
        XCTAssertEqual(translation.actionTitle, "Translate")
        try cache(for: unavailableOllamaFallback, body: "Unavailable")
        await translation.prepare(
            messages: [readerMessage],
            configuration: configuration
        )
        XCTAssertEqual(translation.actionTitle, "Show Translation")
        translation.showTranslation()
        XCTAssertEqual(
            translation.displayedBody(for: readerMessage).safeText,
            "Unavailable"
        )
    }

    @MainActor
    func testRuntimeInboxReaderContainsOnlyTheSelectedMessageThread() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-reader-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeReaderTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_first"),
                threadID: ThreadID("thr_first"),
                from: EmailAddress("first@example.com"),
                subject: "First thread",
                preview: "First preview",
                body: "Complete first thread body with preserved detail.",
                smartCategory: .personal
            )
        )
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_second"),
                threadID: ThreadID("thr_second"),
                from: EmailAddress("second@example.com"),
                subject: "Second thread",
                preview: "Second preview",
                body: "Complete second thread body with preserved detail.",
                smartCategory: .personal
            )
        )

        let inbox = runtime.makeInboxViewModel()
        XCTAssertEqual(inbox.selectedThread.subject, "First thread")
        XCTAssertEqual(inbox.selectedThread.messages.map(\.id), ["msg_first"])
        XCTAssertEqual(inbox.selectedThread.messages.first?.safeBodyText, "Complete first thread body with preserved detail.")

        let selectedInbox = runtime.makeInboxViewModel(selectedMessageID: "msg_second")
        XCTAssertEqual(selectedInbox.selectedThread.subject, "Second thread")
        XCTAssertEqual(selectedInbox.selectedThread.messages.map(\.id), ["msg_second"])
        XCTAssertEqual(selectedInbox.selectedThread.messages.first?.safeBodyText, "Complete second thread body with preserved detail.")
    }

    @MainActor
    func testDirectAttachmentReadRequiresSelectedAccountAndCurrentSourceGeneration() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-direct-attachment-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let selected = PlainpostFixtures.personalAccount
        let foreign = Account(
            id: AccountID("foreign-attachment-account"), displayName: "Foreign",
            email: EmailAddress("foreign@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([selected, foreign])
        for account in [selected, foreign] {
            _ = try seed.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
        }
        let payload = IncomingMessageAttachmentPayload(
            partPath: "2", filename: "report.txt", mimeType: "text/plain",
            data: Data("private attachment".utf8)
        )
        for (index, account) in [selected, foreign].enumerated() {
            _ = try seed.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("attachment-\(account.id.rawValue)"), threadID: nil,
                    from: account.email, subject: "Report", preview: "Attached",
                    smartCategory: .personal
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [],
                    attachments: [.init(filename: payload.filename, mimeType: payload.mimeType)],
                    messageIdentifiers: []
                ),
                attachments: [payload], accountID: account.id,
                mailboxPath: "INBOX", uidValidity: 1, uid: index + 1,
                notificationEligible: false
            )
        }
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: selected.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            packagedOperationWorkerSignalFactory: { nil },
            browserNativeHostStartup: { _ in }
        )
        defer { Task { await runtime.shutdown() } }
        let selectedID = DirectIncomingAttachmentID(
            accountID: selected.id, messageID: MessageID("attachment-\(selected.id.rawValue)"),
            partPath: "2", sourceGeneration: 1
        ).encoded
        let foreignID = DirectIncomingAttachmentID(
            accountID: foreign.id, messageID: MessageID("attachment-\(foreign.id.rawValue)"),
            partPath: "2", sourceGeneration: 1
        ).encoded
        let selectedAttachment = MailAttachment(
            id: selectedID, filename: payload.filename, mimeType: "text/plain",
            disposition: "attachment", byteCount: payload.byteCount,
            contentDigest: Data(SHA256.hash(data: payload.data)).base64EncodedString()
        )
        let foreignAttachment = MailAttachment(
            id: foreignID, filename: payload.filename, mimeType: "text/plain",
            disposition: "attachment", byteCount: payload.byteCount,
            contentDigest: Data(SHA256.hash(data: payload.data)).base64EncodedString()
        )

        XCTAssertThrowsError(try runtime.saveDirectAttachmentArtifact(foreignAttachment))
        XCTAssertThrowsError(try runtime.saveDirectAttachmentArtifact(MailAttachment(
            id: selectedID, filename: "different.txt", mimeType: "text/plain",
            disposition: "attachment", byteCount: payload.byteCount,
            contentDigest: selectedAttachment.contentDigest
        )))
        let artifact = try runtime.saveDirectAttachmentArtifact(selectedAttachment)
        XCTAssertEqual(try Data(contentsOf: artifact.url), payload.data)
        try artifact.cleanup()

        let current = try seed.mailSource(accountID: selected.id)
        _ = try seed.replaceMailSource(
            current.nodeBacked(
                nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: "selected@example.com"
            ), expectedGeneration: current.generation
        )
        XCTAssertThrowsError(try runtime.saveDirectAttachmentArtifact(selectedAttachment))
        let nodeSource = try seed.mailSource(accountID: selected.id)
        _ = try seed.replaceMailSource(
            nodeSource.revertedToDirect(), expectedGeneration: nodeSource.generation
        )
        XCTAssertThrowsError(try runtime.saveDirectAttachmentArtifact(selectedAttachment))
    }

    @MainActor
    func testRuntimeReusesMailboxSnapshotAcrossSelectionUntilInvalidated() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-snapshot-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeSnapshotTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_first"),
                threadID: ThreadID("thr_first"),
                from: EmailAddress("first@example.com"),
                subject: "First thread",
                preview: "First preview",
                body: "First body",
                smartCategory: .personal
            )
        )

        let initial = runtime.makeInboxSelectionViewModel(selectedMessageID: "msg_first")
        XCTAssertEqual(initial.classicRows.map(\.id), ["msg_first"])

        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_second"),
                threadID: ThreadID("thr_second"),
                from: EmailAddress("second@example.com"),
                subject: "Second thread",
                preview: "Second preview",
                body: "Second body",
                smartCategory: .personal
            )
        )

        let selectionOnlyRefresh = runtime.makeInboxSelectionViewModel(selectedMessageID: "msg_first")
        XCTAssertEqual(selectionOnlyRefresh.classicRows.map(\.id), ["msg_first"])

        runtime.invalidateInboxSnapshot()
        let mailboxRefresh = runtime.makeInboxSelectionViewModel(selectedMessageID: "msg_second")
        XCTAssertEqual(Set(mailboxRefresh.classicRows.map(\.id)), Set(["msg_first", "msg_second"]))
        XCTAssertEqual(mailboxRefresh.selectedThread.messages.map(\.id), ["msg_second"])
    }

    @MainActor
    func testRuntimeDefersGroupedHTMLBodiesUntilAConversationMessageIsExpanded() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-deferred-html-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeDeferredHTMLTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let repeatedHTML = String(repeating: "<table><tr><td>Listing</td></tr></table>", count: 1_000)
            + "<img src=\"https://example.com/listing.jpg\">"

        for index in 0..<13 {
            try runtime.store.cacheMessage(
                MessageSummary(
                    id: MessageID("msg_\(index)"),
                    threadID: ThreadID("thr_property_alert"),
                    from: EmailAddress("alerts@example.com"),
                    subject: "Property alert",
                    preview: "Listing \(index)",
                    body: "Listing \(index)",
                    bodyHTML: repeatedHTML,
                    smartCategory: .newsletter,
                    sentAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        let inbox = runtime.makeInboxSelectionViewModel(selectedMessageID: "msg_12")

        XCTAssertEqual(inbox.selectedThread.messages.count, 13)
        XCTAssertTrue(inbox.selectedThread.messages.allSatisfy { $0.safeHTML == nil })
        XCTAssertTrue(inbox.selectedThread.messages.allSatisfy { $0.deferredBody != nil })
        XCTAssertEqual(inbox.selectedThread.messages.reduce(0) { $0 + $1.blockedRemoteImageCount }, 13)
    }

    @MainActor
    func testRuntimeBuildsSelectionProjectionAsynchronously() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-async-selection-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeAsyncSelectionTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_large"),
                threadID: ThreadID("thr_large"),
                from: EmailAddress("alerts@example.com"),
                subject: "Large alert",
                preview: "Preview",
                body: "Readable fallback",
                bodyHTML: String(repeating: "<table><tr><td>Listing</td></tr></table>", count: 1_000),
                smartCategory: .newsletter
            )
        )

        let inbox = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: "msg_large")

        XCTAssertEqual(inbox.selectedThread.messages.map(\.id), ["msg_large"])
        XCTAssertNil(inbox.selectedThread.messages.first?.safeHTML)
    }

    @MainActor
    func testRuntimeGroupsAThreadIntoOneRowAndRendersMessagesChronologically() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-thread-grouping-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeThreadGroupingTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let threadID = ThreadID("thr_conversation")
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_original"),
                threadID: threadID,
                from: EmailAddress("alice@example.com"),
                subject: "Project update",
                preview: "Original message",
                body: "Original message",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 100)
            )
        )
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_reply"),
                threadID: threadID,
                from: EmailAddress("me@example.com"),
                subject: "Re: Project update",
                preview: "Latest reply",
                body: "Latest reply",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 200)
            )
        )

        let inbox = runtime.makeInboxViewModel(selectedMessageID: "msg_reply")

        XCTAssertEqual(inbox.classicRows.count, 1)
        XCTAssertEqual(inbox.classicRows.first?.id, "msg_reply")
        XCTAssertEqual(inbox.classicRows.first?.threadMessageCount, 2)
        XCTAssertEqual(inbox.selectedThread.subject, "Project update")
        XCTAssertEqual(inbox.selectedThread.messages.map(\.id), ["msg_original", "msg_reply"])
    }

    @MainActor
    func testInboxConversationIncludesSentReplyWithoutAddingAnInboxRow() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-sent-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: selectedDirectRuntimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeSentHistoryTests.\(UUID().uuidString)",
                account: PlainpostFixtures.personalAccount
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let threadID = ThreadID("thr_conversation")
        let account = PlainpostFixtures.personalAccount
        try runtime.store.cacheAccounts([account])
        try runtime.store.cacheThread(MailThread(
            id: threadID,
            accountID: account.id,
            subjectNormalized: "project update",
            participantEmails: [account.email, EmailAddress("alice@example.com")]
        ))
        _ = try runtime.store.commitIncomingMessage(MessageSummary(
            id: MessageID("msg_inbound"),
            threadID: threadID,
            from: EmailAddress("alice@example.com"),
            subject: "Project update",
            preview: "Original",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Original",
            sentAt: Date(timeIntervalSince1970: 100)
        ), metadata: IncomingMessageSearchMetadata(
            to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
        ), accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
        notificationEligible: false)
        _ = try runtime.store.commitIncomingMessage(MessageSummary(
            id: MessageID("msg_sent"),
            threadID: threadID,
            from: EmailAddress("me@example.com"),
            subject: "Re: Project update",
            preview: "Reply",
            smartCategory: .personal,
            labels: ["Sent"],
            isSeen: true,
            mailboxPath: "Sent",
            isDeleted: false,
            body: "Reply",
            sentAt: Date(timeIntervalSince1970: 200)
        ), metadata: IncomingMessageSearchMetadata(
            to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
        ), accountID: account.id, mailboxPath: "Sent", uidValidity: 1, uid: 2,
        notificationEligible: false)

        let inbox = runtime.makeInboxViewModel(selectedMessageID: "msg_inbound")

        XCTAssertEqual(inbox.classicRows.map(\.id), ["msg_inbound"])
        XCTAssertEqual(inbox.selectedThread.messages.map(\.id), ["msg_inbound", "msg_sent"])
    }

    @MainActor
    func testReplyComposerUsesTheAccountThatReceivedTheSourceMessage() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-reply-account-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeReplyAccountTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let first = Account(
            id: AccountID("acc_first"), displayName: "First", email: EmailAddress("first@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let second = Account(
            id: AccountID("acc_second"), displayName: "Second", email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try runtime.store.cacheAccounts([first, second])
        let message = MessageSummary(
            id: MessageID("msg_second_account"),
            threadID: ThreadID("thr_second_account"),
            from: EmailAddress("alice@example.com"),
            subject: "Account routing",
            preview: "Hello",
            body: "Hello",
            smartCategory: .personal
        )
        _ = try runtime.store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(to: [second.email], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: second.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )

        let composer = runtime.makeComposerViewModel(sourceMessageID: message.id.rawValue)
        composer.to = "alice@example.com"
        composer.subject = "Re: Account routing"
        composer.bodyPlain = "Reply"
        try await composer.saveDraft()

        let draft = try runtime.store.draft(id: DraftID(try XCTUnwrap(composer.lastDraftID)))
        XCTAssertEqual(draft.accountID, second.id)
        XCTAssertEqual(draft.from, second.email)
    }

    /// Reply All's macOS runtime window path (`makeComposerReplyAllContext`) must exclude
    /// every configured account's own address as well as the sender, matching the embedded
    /// coordinator's `ComposeCoordinator.replyAllRecipients`, which this reuses.
    @MainActor
    func testReplyAllComposerContextExcludesOwnAddressesAndSender() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-reply-all-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeReplyAllTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let first = Account(
            id: AccountID("acc_first"), displayName: "First", email: EmailAddress("first@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let second = Account(
            id: AccountID("acc_second"), displayName: "Second", email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try runtime.store.cacheAccounts([first, second])
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_reply_all"),
                threadID: ThreadID("thr_reply_all"),
                from: EmailAddress("alice@example.com"),
                subject: "Team plan",
                preview: "Hi",
                smartCategory: .personal,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                body: "Hi",
                to: [second.email, EmailAddress("tom@example.com")],
                cc: [first.email, EmailAddress("ann@example.com")]
            )
        )

        let context = try XCTUnwrap(runtime.makeComposerReplyAllContext(sourceMessageID: "msg_reply_all"))

        XCTAssertEqual(context.recipient, "alice@example.com")
        XCTAssertEqual(context.cc, ["tom@example.com", "ann@example.com"])
    }

    /// Forward's macOS runtime window path: the context comes from the selected Direct
    /// message, and its stored attachment bytes are carried into the draft. A file the
    /// draft can't carry is reported as unavailable instead of being silently dropped.
    @MainActor
    func testForwardComposerContextAndAttachmentsComeFromTheSelectedDirectMessage() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-forward-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let selected = PlainpostFixtures.personalAccount
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([selected])
        _ = try seed.replaceMailSource(
            AccountMailSource(
                accountID: selected.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil,
                providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let report = IncomingMessageAttachmentPayload(
            partPath: "2", filename: "report.txt", mimeType: "text/plain",
            data: Data("quarterly numbers".utf8)
        )
        let oversized = IncomingMessageAttachmentPayload(
            partPath: "3", filename: "footage.bin", mimeType: "application/octet-stream",
            data: Data(count: DraftAttachmentContract.maximumBytesPerAttachment + 1)
        )
        _ = try seed.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_forward"), threadID: ThreadID("thr_forward"),
                from: EmailAddress("aisha@studio.example"), fromDisplayName: "Aisha Khan",
                subject: "Quarterly report", preview: "Attached",
                smartCategory: .personal, labels: [], isSeen: false,
                mailboxPath: "INBOX", isDeleted: false,
                body: "Numbers attached."
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [],
                attachments: [report, oversized].map { .init(filename: $0.filename, mimeType: $0.mimeType) },
                messageIdentifiers: []
            ),
            attachments: [report, oversized], accountID: selected.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationEligible: false
        )
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: selected.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            packagedOperationWorkerSignalFactory: { nil },
            browserNativeHostStartup: { _ in }
        )
        defer { Task { await runtime.shutdown() } }

        let context = try XCTUnwrap(runtime.makeComposerForwardContext(sourceMessageID: "msg_forward"))
        XCTAssertEqual(context.sourceMessageID, MessageID("msg_forward"))
        XCTAssertEqual(context.subject, "Quarterly report")
        XCTAssertEqual(context.senderName, "Aisha Khan")
        XCTAssertEqual(context.senderAddress, "aisha@studio.example")
        XCTAssertEqual(context.quotedBody, "Numbers attached.")

        XCTAssertEqual(
            runtime.forwardAttachmentSources(for: "msg_forward").map(\.filename),
            ["report.txt", "footage.bin"]
        )
        let files = await runtime.forwardAttachments(for: "msg_forward")
        XCTAssertEqual(files.attachments.map(\.filename), ["report.txt"])
        XCTAssertEqual(files.attachments.map(\.data), [report.data])
        XCTAssertEqual(files.attachments.map(\.mimeType), ["text/plain"])
        XCTAssertEqual(files.unavailable, ["footage.bin"])
        XCTAssertNoThrow(try DraftAttachmentContract.validate(files.attachments))

        XCTAssertNil(runtime.makeComposerForwardContext(sourceMessageID: "msg_missing"))
        XCTAssertEqual(runtime.forwardAttachmentSources(for: "msg_missing"), [])
        let missing = await runtime.forwardAttachments(for: "msg_missing")
        XCTAssertEqual(missing.attachments, [])
        XCTAssertEqual(missing.unavailable, [])
    }

    @MainActor
    func testRuntimeGroupsLegacyPerUIDThreadIDsByNormalizedSubject() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-legacy-threading-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeLegacyThreadingTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        for (id, threadID, subject, sentAt) in [
            ("msg_original", "thr_uid_101", "Project update", 100.0),
            ("msg_reply", "thr_uid_102", "Re: Project update", 200.0)
        ] {
            try runtime.store.cacheMessage(
                MessageSummary(
                    id: MessageID(id),
                    threadID: ThreadID(threadID),
                    from: EmailAddress("alice@example.com"),
                    subject: subject,
                    preview: subject,
                    body: subject,
                    smartCategory: .personal,
                    sentAt: Date(timeIntervalSince1970: sentAt)
                )
            )
        }

        let inbox = runtime.makeInboxViewModel(selectedMessageID: "msg_reply")

        XCTAssertEqual(inbox.classicRows.count, 1)
        XCTAssertEqual(inbox.classicRows.first?.threadMessageCount, 2)
        XCTAssertEqual(inbox.selectedThread.messages.map(\.id), ["msg_original", "msg_reply"])
    }

    @MainActor
    func testRuntimeInboxReaderHasNoThreadWhenSelectionIsCleared() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-empty-reader-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let runtime = try PlainpostAppRuntime(
            configuration: runtimeConfiguration(
                databaseURL: dbURL,
                keychainService: "PlainpostRuntimeEmptyReaderTests.\(UUID().uuidString)"
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        try runtime.store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_present"),
                threadID: ThreadID("thr_present"),
                from: EmailAddress("sender@example.com"),
                subject: "Present message",
                preview: "Preview",
                body: "Full body",
                smartCategory: .personal
            )
        )

        let inbox = runtime.makeInboxViewModel(selectedMessageID: nil)

        XCTAssertEqual(inbox.selectedThread.subject, "No Thread")
        XCTAssertTrue(inbox.selectedThread.messages.isEmpty)
        XCTAssertTrue(inbox.selectedThread.availableActions.isEmpty)
    }

    @MainActor
    func testRuntimeInboxActionsQueueAndProductionWorkerUsesStoredIMAPCredentials() async throws {
        let imapPassword = "runtime-action-imap-secret"
        let smtpPassword = "runtime-action-smtp-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: imapPassword,
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: smtpPassword)
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-action-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostRuntimeActionTests.\(UUID().uuidString)"
        let isolation = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: dbURL,
            keychainService: keychainService
        )
        let credentials = isolation.credentials

        let setupRuntime = try makeRuntimeWithoutPackagedSideEffects(isolation.configuration)
        let accountSetup = setupRuntime.makeAccountSetupViewModel()
        accountSetup.displayName = "Personal"
        accountSetup.email = "me@example.com"
        accountSetup.imapHost = "127.0.0.1"
        accountSetup.imapPort = "\(imap.port)"
        accountSetup.smtpHost = "127.0.0.1"
        accountSetup.smtpPort = "\(smtp.port)"
        accountSetup.username = "me@example.com"
        accountSetup.imapPassword = imapPassword
        accountSetup.smtpPassword = smtpPassword
        try await accountSetup.submit()

        let runtime = try makeRuntimeWithoutPackagedSideEffects(
            PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL, selectedAccountID: AccountID("acc_me_example_com"),
                runtimeDependencies: isolation.runtimeDependencies
            )
        )
        defer { Task { await runtime.shutdown() } }

        let messageID = try XCTUnwrap(
            runtime.store.messages.first(where: { message in
                (try? runtime.store.membership(for: message.id).uid) == 1
            })?.id
        )
        XCTAssertEqual(try runtime.store.membership(for: messageID).uid, 1)

        let actions = runtime.makeInboxMailActionViewModel()
        _ = await actions.perform(.markUnread, messageID: messageID.rawValue)

        let queuedMailboxFlagJob = try XCTUnwrap(
            runtime.store.jobs(limit: 10).first(where: { $0.kind == .mailboxFlag })
        )
        XCTAssertEqual(queuedMailboxFlagJob.state, .queued)
        let worker = LocalOperationRuntime(
            store: runtime.store,
            credentials: credentials,
            allowedJobKinds: PlainpostBackgroundAgentJobPolicy.allowedKinds
        )
        _ = try await worker.processNextJob()
        let completedMailboxFlagJob = try runtime.store.job(id: queuedMailboxFlagJob.id)
        XCTAssertEqual(
            completedMailboxFlagJob.state,
            .completed,
            completedMailboxFlagJob.errorMessage ?? ""
        )
        let headerAfterMarkUnread = try await Self.remoteHeader(imap: imap, password: imapPassword)
        XCTAssertFalse(headerAfterMarkUnread.contains("\\Seen"))
        XCTAssertEqual(imap.loginAttempts.last, LocalIMAPLoginAttempt(username: "me@example.com", password: imapPassword))
        XCTAssertEqual(runtime.store.messages.first(where: { $0.id == messageID })?.isSeen, false)

        _ = await actions.perform(.archive, messageID: messageID.rawValue)

        XCTAssertEqual(imap.archivedUIDs, [1])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)
        XCTAssertEqual(runtime.store.messages.first(where: { $0.id == messageID })?.mailboxPath, "Archive")

        let sqliteBytes = try Data(contentsOf: dbURL)
        let sqliteText = String(decoding: sqliteBytes, as: UTF8.self)
        XCTAssertFalse(sqliteText.contains(imapPassword))
        XCTAssertFalse(sqliteText.contains(smtpPassword))
    }

    @MainActor
    func testRuntimeComposerSendUsesStoredCredentialsWithoutCreatingAnApproval() async throws {
        XCTAssertEqual(
            PlainpostAppRuntime.guiMailOperationJobKinds,
            [.inboxSync, .historicalSync, .approvedDelivery, .denySend]
        )
        let imapPassword = "runtime-approval-imap-secret"
        let smtpPassword = "runtime-approval-smtp-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: imapPassword,
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: smtpPassword)
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-runtime-approval-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostRuntimeApprovalTests.\(UUID().uuidString)"
        let isolation = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: dbURL,
            keychainService: keychainService
        )

        let sendGate = ComposeSendDelayGate()
        let setupRuntime = try makeRuntimeWithoutPackagedSideEffects(isolation.configuration)
        let accountSetup = setupRuntime.makeAccountSetupViewModel()
        accountSetup.displayName = "Personal"
        accountSetup.email = "me@example.com"
        accountSetup.imapHost = "127.0.0.1"
        accountSetup.imapPort = "\(imap.port)"
        accountSetup.smtpHost = "127.0.0.1"
        accountSetup.smtpPort = "\(smtp.port)"
        accountSetup.username = "me@example.com"
        accountSetup.imapPassword = imapPassword
        accountSetup.smtpPassword = smtpPassword
        try await accountSetup.submit()

        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL, selectedAccountID: AccountID("acc_me_example_com"),
                runtimeDependencies: isolation.runtimeDependencies
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            undoSendSleep: { _ in await sendGate.wait() }
        )

        var composer: ComposerViewModel? = runtime.makeComposerViewModel()
        weak let dismissedComposer = composer
        composer?.to = "alice@example.com"
        composer?.subject = "Runtime direct send"
        composer?.bodyPlain = "Sent through stored runtime credentials."
        let didSchedule = try await composer?.send() ?? false
        XCTAssertTrue(didSchedule)

        let scheduledMessages = await smtp.acceptedMessages()
        XCTAssertEqual(scheduledMessages.count, 1)
        await sendGate.waitUntilWaiting()
        composer = nil
        XCTAssertNil(dismissedComposer)

        await sendGate.resume()
        for _ in 0..<100 {
            if await smtp.acceptedMessages().count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 2)
        let sentMessage = try XCTUnwrap(accepted.last)
        XCTAssertEqual(sentMessage.mailFrom, EmailAddress("me@example.com"))
        XCTAssertEqual(sentMessage.recipients, [EmailAddress("alice@example.com")])
        XCTAssertTrue(sentMessage.data.contains("Subject: Runtime direct send"))
        XCTAssertTrue(sentMessage.data.contains("Sent through stored runtime credentials."))
        XCTAssertTrue(sentMessage.data.contains("Content-Type: multipart/alternative"))
        XCTAssertTrue(sentMessage.data.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertTrue(sentMessage.data.contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertFalse(sentMessage.data.contains("Bcc:"))
        XCTAssertEqual(imap.appendedMessages.map(\.mailbox), ["Sent"])
        XCTAssertEqual(imap.appendedMessages.first?.flags, ["\\Seen"])
        XCTAssertTrue(imap.appendedMessages.first?.data.contains("Subject: Runtime direct send") == true)
        XCTAssertTrue(runtime.store.approvalQueueRequests.isEmpty)
        XCTAssertEqual(runtime.store.messages.first(where: { $0.mailboxPath == "Sent" })?.subject, "Runtime direct send")
        XCTAssertTrue(runtime.store.auditEntries.contains { $0.action == "message.direct_send" })
        let sqliteBytes = try Data(contentsOf: dbURL)
        let sqliteText = String(decoding: sqliteBytes, as: UTF8.self)
        XCTAssertFalse(sqliteText.contains(imapPassword))
        XCTAssertFalse(sqliteText.contains(smtpPassword))
        XCTAssertFalse(sqliteText.contains("wrong-inline-password"))
    }

    private static func remoteHeader(imap: LocalIMAPServer, password: String) async throws -> String {
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await client.login(username: "me@example.com", password: password)
        _ = try await client.selectMailbox("INBOX")
        return try await client.fetchHeader(uid: 1)
    }
}

private final class RuntimeComposerAuthority: PlainpostMailAuthority, SyncNodeStatusProviding, @unchecked Sendable {
    let accountID: AccountID? = AccountID("acc_node")
    let snapshots: any MailSnapshotServing
    let search: any MailSearchService = RuntimeComposerSearchService()
    let messages: any MailMessageServing
    private let mutationService = RuntimeComposerMutationService()
    let mutations: any MailMutationServing
    let attachments: any MailAttachmentServing = RuntimeComposerAttachmentService()
    private let lock = NSLock()
    private var sender: EmailAddress?

    init(messages: [MessageSummary] = []) {
        snapshots = RuntimeComposerSnapshotService(messages: messages)
        self.messages = RuntimeComposerMessageService(messages: messages)
        mutations = mutationService
    }

    var senderAddress: EmailAddress? {
        lock.lock(); defer { lock.unlock() }
        return sender
    }

    func setSender(_ value: EmailAddress?) {
        lock.lock(); sender = value; lock.unlock()
    }

    func recordedDraft() async -> Draft? {
        await mutationService.lastDraft()
    }

    func status() async throws -> SyncNodeStatus {
        SyncNodeStatus(
            version: "node-test", reachability: "reachable", syncLag: "0",
            storage: "managed", providerIdentity: "sender@example.com",
            assignments: [], backup: "not_reported", endpoint: "session-scoped",
            updateStatus: "current"
        )
    }
}

private actor RuntimeComposerMutationService: MailMutationServing {
    private(set) var draft: Draft?

    func apply(canonicalOperation: Data) async throws -> MailMutationResult {
        MailMutationResult(idempotencyKey: "runtime", state: "applied")
    }

    func perform(_ intent: MailMutationIntent) async throws -> MailMutationResult {
        if case let .saveDraft(value) = intent { draft = value }
        return MailMutationResult(idempotencyKey: "runtime", state: "applied")
    }

    func lastDraft() -> Draft? { draft }
}

private struct RuntimeComposerSnapshotService: MailSnapshotServing {
    let messages: [MessageSummary]

    func snapshot(after: MailSearchCursor?, limit: Int) async throws -> MailSnapshotPage {
        MailSnapshotPage(messages: messages, nextCursor: nil, revision: "0")
    }
}

private struct RuntimeComposerSearchService: MailSearchService {
    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse { fatalError("not used") }
    func suggestions(_ request: MailSearchSuggestionRequest) async throws -> [MailSearchSuggestionSection] { [] }
    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws {}
    func performMaintenanceIfDue(now: Date) async throws {}
}

private struct RuntimeComposerMessageService: MailMessageServing {
    let messages: [MessageSummary]

    func message(id: MessageID) async throws -> MessageSummary {
        guard let message = messages.first(where: { $0.id == id }) else { throw PlainpostError.notFound("not used") }
        return message
    }
}

private struct RuntimeComposerAttachmentService: MailAttachmentServing {
    func attachment(id: String) async throws -> MailAttachmentStream { throw PlainpostError.notFound("not used") }
}

private actor AppleBootstrapRecorder {
    struct Call: Sendable {
        let token: String
        let nonce: Data
    }

    private(set) var calls: [Call] = []

    func record(token: String, nonce: Data) {
        calls.append(Call(token: token, nonce: nonce))
    }

    func waitForCount(_ expected: Int) async {
        while calls.count < expected { await Task.yield() }
    }

}

private enum AppleBootstrapTestError: Error {
    case failed
}

private actor ControlledAppleBootstrapGate {
    private(set) var callCount = 0
    private var continuations: [Int: CheckedContinuation<AccountSessionState, Error>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run() async throws -> AccountSessionState {
        let index = callCount
        callCount += 1
        let ready = countWaiters.filter { callCount >= $0.0 }
        countWaiters.removeAll { callCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func waitForCount(_ expected: Int) async {
        if callCount >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func resolve(_ index: Int, with result: Result<AccountSessionState, Error>) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(with: result)
    }
}

private actor AccountApprovalRecorder {
    private(set) var contexts: [AccountDeviceApprovalContext] = []
    var count: Int { contexts.count }
    func record(_ context: AccountDeviceApprovalContext) { contexts.append(context) }
}

private actor AccountApprovalLifecycleRecorder {
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
}

private struct DenyingAccountAuthenticator: LocalApprovalAuthenticating {
    func authenticate(reason: String) async throws { throw LocalApprovalAuthenticationError.denied }
}

private struct AllowingAccountAuthenticator: LocalApprovalAuthenticating {
    func authenticate(reason: String) async throws {}
}

private actor NonCooperativeDelayedAccountAuthenticator: LocalApprovalAuthenticating {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func authenticate(reason _: String) async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func succeed() { continuation?.resume(); continuation = nil }
}

private actor DelayedAccountStateGate {
    let state: AccountSessionState
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(state: AccountSessionState) { self.state = state }

    func run() async -> AccountSessionState {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
        return state
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RuntimeAccountDeletionServiceClient: PlainpostServiceClientProtocol {
    private let databaseURL: URL
    private let credentials: InMemoryCredentialVault
    private(set) var deletedAccountIDs: [AccountID] = []

    init(databaseURL: URL, credentials: InMemoryCredentialVault) {
        self.databaseURL = databaseURL
        self.credentials = credentials
    }

    func status() -> PlainpostVaultStatus {
        PlainpostVaultStatus(availability: .unlocked, matchingKeyItemCount: 1)
    }

    func unlock(reason: String) {}
    func lock() {}

    func deletionSnapshot() -> [AccountID] {
        deletedAccountIDs
    }

    func perform(_ operation: PlainpostForegroundOperation) async throws
        -> PlainpostForegroundOperationResult
    {
        guard case .deleteAccount(let input) = operation else {
            throw PlainpostServiceClientError.invalidRequest
        }
        let accountID = AccountID(input.accountID)
        deletedAccountIDs.append(accountID)
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try await store.deleteAccountData(
            accountID: accountID,
            credentials: credentials
        )
        return .deleteAccount
    }
}

private struct FailingMaintenanceSearchService: MailSearchService {
    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        throw MailSearchError.unavailable
    }

    func suggestions(
        _ request: MailSearchSuggestionRequest
    ) async throws -> [MailSearchSuggestionSection] { [] }

    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws {}

    func performMaintenanceIfDue(now: Date) async throws {
        throw SensitiveMaintenanceFailure()
    }
}

private actor CancellableMaintenanceSearchService: MailSearchService {
    private var started = false
    private var cancellationObserved = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        throw MailSearchError.unavailable
    }

    func suggestions(
        _ request: MailSearchSuggestionRequest
    ) async throws -> [MailSearchSuggestionSection] { [] }

    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws {}

    func performMaintenanceIfDue(now: Date) async throws {
        _ = now
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withTaskCancellationHandler {
            await withCheckedContinuation { releaseContinuation = $0 }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func recordCancellation() {
        cancellationObserved = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }
}

private actor RecordingMaintenanceSearchService: MailSearchService {
    private let onInvocation: @Sendable () -> Void
    private var count = 0

    init(onInvocation: @escaping @Sendable () -> Void) {
        self.onInvocation = onInvocation
    }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        throw MailSearchError.unavailable
    }

    func suggestions(
        _ request: MailSearchSuggestionRequest
    ) async throws -> [MailSearchSuggestionSection] { [] }

    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws {}

    func performMaintenanceIfDue(now: Date) async throws {
        _ = now
        count += 1
        onInvocation()
    }

    func invocationCount() -> Int { count }
}

private struct SensitiveMaintenanceFailure: Error, CustomStringConvertible {
    let description = "private@example.com /Users/private/Plainpost.sqlite password=hunter2"
}

private actor ComposeSendDelayGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            waitingContinuation?.resume()
            waitingContinuation = nil
        }
    }

    func waitUntilWaiting() async {
        if continuation != nil { return }
        await withCheckedContinuation { waitingContinuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private enum MaintenanceRuntimeClientError: Error {
    case stopped
    case unused
}

private actor SuspendedMaintenanceOperationClient: PlainpostOperationClientProtocol {
    private(set) var aiCallCount = 0
    private(set) var lastAIInput: PlainpostAIOperationInput?
    private(set) var cancellationCount = 0
    private func recordCancellation() { cancellationCount += 1 }
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFirstCallReleased = false

    func executeInboxSync(
        _ input: PlainpostInboxSyncInput
    ) async throws -> PlainpostInboxSyncResult {
        throw MaintenanceRuntimeClientError.unused
    }

    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        _ = try await executeAI(input)
    }

    func executeAI(
        _ input: PlainpostAIOperationInput
    ) async throws -> PlainpostAIOperationResult {
        aiCallCount += 1
        lastAIInput = input

        if aiCallCount == 1 && !isFirstCallReleased {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        throw MaintenanceRuntimeClientError.stopped
    }

    func approveSend(
        requestID: SendRequestID,
        approvedBy: String
    ) async throws {
        throw MaintenanceRuntimeClientError.unused
    }

    func denySend(
        requestID: SendRequestID,
        deniedBy: String
    ) async throws {
        throw MaintenanceRuntimeClientError.unused
    }

    func waitUntilAICallStarts(timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while aiCallCount == 0, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        return aiCallCount > 0
    }

    func releaseFirstAICall() {
        isFirstCallReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RejectingMaintenanceOperationClient: PlainpostOperationClientProtocol {
    private(set) var aiCallCount = 0
    private(set) var lastAIInput: PlainpostAIOperationInput?
    private(set) var lastEnqueuedAIInput: PlainpostAIOperationInput?

    func executeInboxSync(
        _ input: PlainpostInboxSyncInput
    ) async throws -> PlainpostInboxSyncResult {
        throw MaintenanceRuntimeClientError.unused
    }

    func executeAI(
        _ input: PlainpostAIOperationInput
    ) async throws -> PlainpostAIOperationResult {
        aiCallCount += 1
        lastAIInput = input
        throw MaintenanceRuntimeClientError.stopped
    }

    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        lastEnqueuedAIInput = input
    }

    func approveSend(
        requestID: SendRequestID,
        approvedBy: String
    ) async throws {
        throw MaintenanceRuntimeClientError.unused
    }

    func denySend(
        requestID: SendRequestID,
        deniedBy: String
    ) async throws {
        throw MaintenanceRuntimeClientError.unused
    }
}

@MainActor
private final class SuccessfulMaintenanceOperationClientBox {
    var client: SuccessfulMaintenanceOperationClient?
}

private actor SuccessfulMaintenanceOperationClient: PlainpostOperationClientProtocol {
    private let store: SQLiteMailStore
    private(set) var aiCallCount = 0

    init(store: SQLiteMailStore) {
        self.store = store
    }

    func executeInboxSync(
        _ input: PlainpostInboxSyncInput
    ) async throws -> PlainpostInboxSyncResult {
        throw MaintenanceRuntimeClientError.unused
    }

    func executeAI(
        _ input: PlainpostAIOperationInput
    ) async throws -> PlainpostAIOperationResult {
        aiCallCount += 1
        let artifactID = "artifact-maintenance-success-\(aiCallCount)"
        let payload = PlainpostLocalAIArtifactPayload(
            categorizedMessageCount: 0,
            unchangedMessageCount: 0,
            failedMessageCount: 0
        )
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: artifactID,
                kind: input.operation.rawValue,
                recordID: input.recordID,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(payload),
                    as: UTF8.self
                )
            ),
            input: input
        )
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: artifactID,
            jobID: "job-maintenance-success-\(aiCallCount)"
        )
    }

    func approveSend(
        requestID: SendRequestID,
        approvedBy: String
    ) async throws {
        throw MaintenanceRuntimeClientError.unused
    }

    func denySend(
        requestID: SendRequestID,
        deniedBy: String
    ) async throws {
        throw MaintenanceRuntimeClientError.unused
    }
}

private actor IncrementalOrganizationOverlapGate {
    private var callCount = 0
    private var firstCallReleased = false
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallCompleted = false
    private var firstCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async -> Int {
        callCount += 1
        let ordinal = callCount
        if ordinal == 1 {
            if !firstCallReleased {
                await withCheckedContinuation { firstReleaseWaiters.append($0) }
            }
        } else if !firstCallCompleted {
            await withCheckedContinuation { firstCompletionWaiters.append($0) }
        }
        return ordinal
    }

    func waitUntilCallCount(_ expected: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while callCount < expected, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        return callCount >= expected
    }

    func releaseFirstCall() {
        firstCallReleased = true
        let waiters = firstReleaseWaiters
        firstReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func completeFirstCall() {
        firstCallCompleted = true
        let waiters = firstCompletionWaiters
        firstCompletionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CoordinatedIncrementalOperationClient: PlainpostOperationClientProtocol {
    private let base: LocalOperationClient
    private let gate: IncrementalOrganizationOverlapGate

    init(base: LocalOperationClient, gate: IncrementalOrganizationOverlapGate) {
        self.base = base
        self.gate = gate
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        try await base.executeInboxSync(input)
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        let ordinal = await gate.enter()
        if ordinal == 1 {
            do {
                let result = try await base.executeAI(input)
                await gate.completeFirstCall()
                return result
            } catch {
                await gate.completeFirstCall()
                throw error
            }
        }
        return try await base.executeAI(input)
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        try await base.approveSend(requestID: requestID, approvedBy: approvedBy)
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        try await base.denySend(requestID: requestID, deniedBy: deniedBy)
    }
}

private actor AIOperationCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct CountingAIOperationClient: PlainpostOperationClientProtocol, Sendable {
    let base: LocalOperationClient
    let counter: AIOperationCallCounter

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        try await base.executeInboxSync(input)
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        await counter.increment()
        return try await base.executeAI(input)
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        try await base.approveSend(requestID: requestID, approvedBy: approvedBy)
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        try await base.denySend(requestID: requestID, deniedBy: deniedBy)
    }
}

private final class ClassificationCountingProvider: AIProvider, @unchecked Sendable {
    private let base = DeterministicAIProvider()
    private let lock = NSLock()
    private var count = 0

    var id: String { base.id }
    var displayName: String { base.displayName }
    var capabilities: AICapabilities { base.capabilities }
    var classificationCount: Int { lock.withLock { count } }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        try await base.generate(request)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        try await base.embed(request)
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        lock.withLock { count += 1 }
        return try await base.classify(request)
    }
}

private final class ProviderResolutionCounter: @unchecked Sendable {
    private let provider: any AIProvider
    private let lock = NSLock()
    private var count = 0
    private var classifierDiscriminators: [String] = []

    init(provider: any AIProvider) {
        self.provider = provider
    }

    var resolutionCount: Int { lock.withLock { count } }
    var resolvedClassifierDiscriminators: [String] {
        lock.withLock { classifierDiscriminators }
    }

    func resolve(_ input: PlainpostAIOperationInput) -> any AIProvider {
        lock.withLock {
            count += 1
            classifierDiscriminators.append(
                input.resolvedSmartInboxClassifierIdentity.discriminator
            )
        }
        return provider
    }
}

private final class RecordingEmbeddedWorkerLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var completions: [@Sendable () -> Void] = []

    var launchedExecutableURLs: [URL] {
        lock.withLock { urls }
    }

    func launch(
        _ executableURL: URL,
        didTerminate: @escaping @Sendable () -> Void
    ) throws {
        lock.withLock {
            urls.append(executableURL)
            completions.append(didTerminate)
        }
    }

    func finishLatestLaunch() {
        let completion: (@Sendable () -> Void)? = lock.withLock {
            completions.popLast()
        }
        completion?()
    }
}

private actor RecordingStartupWorkerSignal: OperationWorkerSignaling {
    private(set) var signalCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signalWork() async throws {
        signalCount += 1
        let ready = waiters.filter { signalCount >= $0.0 }
        waiters.removeAll { signalCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilSignalCount(_ expected: Int) async {
        if signalCount >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
}

private final class RuntimeCancellationExpectationBox: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private actor GatedStartupWorkerSignal: OperationWorkerSignaling {
    private let onCancellation: @Sendable () -> Void
    private var started = false
    private var finished = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(onCancellation: @escaping @Sendable () -> Void) {
        self.onCancellation = onCancellation
    }

    func signalWork() async throws {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withTaskCancellationHandler {
            await withCheckedContinuation { releaseContinuation = $0 }
        } onCancel: {
            onCancellation()
        }
        finished = true
    }

    func waitUntilSignalStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func isFinished() -> Bool { finished }
}

private actor RuntimeShutdownCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        finished = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func isFinished() -> Bool { finished }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor NonCooperativeRuntimeWorkGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum ScriptedRuntimeWorkerSignalError: Error {
    case failed
}

private actor ScriptedRuntimeWorkerSignal: OperationWorkerSignaling {
    private(set) var signalCount = 0
    private(set) var observedJobStates: [PlainpostOperationState?] = []
    private var remainingObservedFailures = 0
    private var observedJobState: (@Sendable () -> PlainpostOperationState?)?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func observeJobState(store: SQLiteMailStore, jobID: String) {
        observedJobState = {
            try? store.job(id: jobID).state
        }
    }

    func failNextObservedSignals(_ count: Int) {
        remainingObservedFailures = count
    }

    func signalWork() async throws {
        signalCount += 1
        if let observedJobState {
            observedJobStates.append(observedJobState())
        }
        let ready = waiters.filter { signalCount >= $0.0 }
        waiters.removeAll { signalCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        if observedJobState != nil, remainingObservedFailures > 0 {
            remainingObservedFailures -= 1
            throw ScriptedRuntimeWorkerSignalError.failed
        }
    }

    func waitUntilSignalCount(_ expected: Int) async {
        if signalCount >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
}

private actor RuntimeSignalRetryGate {
    private var hasEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor NonCooperativeAppleBootstrapGate {
    private(set) var callCount = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        callCount += 1
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { finishContinuation = $0 }
        } onCancel: {}
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor CleanupRegistrationRecorder {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }

    func currentCount() -> Int { count }
}

@MainActor
private final class AccountFlowLifecycleRecorder {
    private(set) var starts = 0
    private(set) var refreshes = 0
    private(set) var begins = 0
    private(set) var cancels = 0

    func start() { starts += 1 }
    func refresh() { refreshes += 1 }
    func begin() { begins += 1 }
    func cancel() { cancels += 1 }
}

extension PlainpostAppRuntimeTests {
    @MainActor
    func testAccountSessionExposesImportedServerSetupBeforeSignInAndFencesItWhenActive() async throws {
        let profileStore = SessionBootstrapProfileStore()
        let importModel = SyncNodeBootstrapImportViewModel(store: profileStore)
        let model = AccountSessionViewModel(
            prepareSession: { _ in .active },
            syncNodeBootstrapImportModel: importModel
        )

        XCTAssertTrue(model.showsSyncNodeBootstrapImport)
        XCTAssertTrue(model.syncNodeBootstrapImportModel === importModel)

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where model.presentation != .active { await Task.yield() }
        XCTAssertEqual(model.presentation, .active)
        XCTAssertFalse(model.showsSyncNodeBootstrapImport)
    }

    func testSignedApplicationRoutesOpenURLAndPackagerRegistersPlainpostServerDocument() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let application = try String(
            contentsOf: repository.appendingPathComponent("Sources/PlainpostApp/PlainpostApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(application.contains(".onOpenURL"))
        XCTAssertTrue(application.contains("accountLaunchModel.accountModel?.importSyncNodeBootstrapProfile"))

        let packageScript = try String(
            contentsOf: repository.appendingPathComponent("Scripts/package-app-bundle.sh"),
            encoding: .utf8
        )
        for required in [
            "CFBundleDocumentTypes",
            "UTExportedTypeDeclarations",
            "com.marynavdovenko.plainpost.server-setup",
            "plainpostserver",
            "public.json",
        ] {
            XCTAssertTrue(packageScript.contains(required), "missing \(required)")
        }
    }
}

private final class SessionBootstrapProfileStore: SyncNodeBootstrapProfileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: SyncNodeBootstrapProfile?

    func load() throws -> SyncNodeBootstrapProfile? {
        lock.withLock { profile }
    }

    func importProfile(_ profile: SyncNodeBootstrapProfile) throws {
        lock.withLock { self.profile = profile }
    }

    func retire(expectedCapabilityID: Data) throws {
        lock.withLock {
            guard profile?.capabilityID == expectedCapabilityID else { return }
            profile = nil
        }
    }
}

private actor SmartInboxRuntimeShutdownCompletion {
    private(set) var finished = false
    func markFinished() { finished = true }
}

private final class RuntimeLowPowerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
