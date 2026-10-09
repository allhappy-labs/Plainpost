import AuthenticationServices
import Foundation
import OSLog
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import SwiftUI

private let accountSecurityViewLogger = Logger(
    subsystem: "com.marynavdovenko.Plainpost",
    category: "account-security"
)

@MainActor
public final class AccountSecurityViewModel: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public let devices: [AccountLifecycleDeviceSummary]
        public let events: [AccountSecurityEventV1]

        public init(
            devices: [AccountLifecycleDeviceSummary],
            events: [AccountSecurityEventV1]
        ) {
            self.devices = devices
            self.events = events
        }
    }

    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    public enum Action: Equatable, Sendable {
        case revoke(AccountDeviceID)
        case suspend(AccountDeviceID)
        case deleteAccount
        case recoverAccount
    }

    public struct AppleRequest: Equatable, Sendable {
        public let id: UUID
        public let nonce: String
    }

    public typealias SnapshotLoader = @MainActor @Sendable () async throws -> Snapshot
    public typealias ActionPerformer = @MainActor @Sendable (
        Action,
        String,
        Data
    ) async throws -> AccountDeletionResultV1?
    public typealias LabelSaver = @MainActor @Sendable (
        AccountDeviceID,
        String
    ) async throws -> Void

    @Published public private(set) var devices: [AccountLifecycleDeviceSummary]
    @Published public private(set) var events: [AccountSecurityEventV1]
    @Published public private(set) var loadState: LoadState
    @Published public private(set) var isWorking = false
    @Published public private(set) var operationErrorMessage: String?
    @Published public private(set) var deletionResult: AccountDeletionResultV1?
    @Published public private(set) var recoveryDidComplete = false

    public typealias ControllerFactory = @MainActor @Sendable () throws -> AccountLifecycleController
    private let loadSnapshot: SnapshotLoader
    private let performAction: ActionPerformer
    private let saveLabel: LabelSaver
    private let stateChanged: @MainActor @Sendable () -> Void
    private let nonceGenerator: @Sendable () throws -> Data
    private var attempt: (id: UUID, nonce: Data, action: Action)?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    public var errorMessage: String? {
        if let operationErrorMessage { return operationErrorMessage }
        guard case .failed(let message) = loadState else { return nil }
        return message
    }

    public convenience init(
        controllerFactory: @escaping ControllerFactory,
        recoveryControllerFactory: ControllerFactory? = nil,
        stateChanged: @escaping @MainActor @Sendable () -> Void,
        nonceGenerator: @escaping @Sendable () throws -> Data = {
            var generator = SystemRandomNumberGenerator()
            return Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }
    ) {
        let resolvedRecoveryControllerFactory = recoveryControllerFactory ?? controllerFactory
        self.init(
            loadSnapshot: {
                let controller = try controllerFactory()
                let snapshot = try await controller.securitySnapshot(limit: 32)
                return Snapshot(devices: snapshot.devices, events: snapshot.events)
            },
            performAction: { action, identityToken, nonce in
                let controller = try action == .recoverAccount
                    ? resolvedRecoveryControllerFactory()
                    : controllerFactory()
                switch action {
                case .revoke(let deviceID):
                    _ = try await controller.revokeDevice(
                        deviceID,
                        identityToken: identityToken,
                        appleNonce: nonce
                    )
                    return nil
                case .suspend(let deviceID):
                    _ = try await controller.suspendDevice(
                        deviceID,
                        identityToken: identityToken,
                        appleNonce: nonce
                    )
                    return nil
                case .deleteAccount:
                    return try await controller.deleteAccount(
                        identityToken: identityToken,
                        appleNonce: nonce
                    )
                case .recoverAccount:
                    _ = try await controller.recover(
                        identityToken: identityToken,
                        appleNonce: nonce
                    )
                    return nil
                }
            },
            saveLabel: { deviceID, label in
                let controller = try controllerFactory()
                try await controller.setLocalDeviceLabel(label, for: deviceID)
            },
            stateChanged: stateChanged,
            nonceGenerator: nonceGenerator
        )
    }

    init(
        loadSnapshot: @escaping SnapshotLoader,
        performAction: @escaping ActionPerformer,
        saveLabel: @escaping LabelSaver,
        stateChanged: @escaping @MainActor @Sendable () -> Void,
        nonceGenerator: @escaping @Sendable () throws -> Data,
        initialSnapshot: Snapshot = .init(devices: [], events: []),
        initialLoadState: LoadState = .idle
    ) {
        self.loadSnapshot = loadSnapshot
        self.performAction = performAction
        self.saveLabel = saveLabel
        self.stateChanged = stateChanged
        self.nonceGenerator = nonceGenerator
        devices = initialSnapshot.devices
        events = initialSnapshot.events
        loadState = initialLoadState
    }

    deinit { task?.cancel() }

    var hasPendingAppleAuthorization: Bool { attempt != nil }

    /// The Apple attempt `id` is still the one waiting for a result.
    func isPendingAppleAuthorization(_ id: UUID) -> Bool { attempt?.id == id }

    public func refresh() {
        let operation = nextGeneration()
        loadState = .loading
        operationErrorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await loadSnapshot()
                guard !Task.isCancelled, generation == operation else { return }
                devices = snapshot.devices
                events = snapshot.events
                loadState = .loaded
            } catch is CancellationError {
                guard generation == operation else { return }
                loadState = .idle
            } catch {
                guard generation == operation else { return }
                let stage = (error as? AccountSecuritySnapshotFailure)?.stage.rawValue
                    ?? "controller_factory"
                accountSecurityViewLogger.error(
                    "load_failed stage=\(stage, privacy: .public) error_type=\(String(reflecting: type(of: error)), privacy: .public)"
                )
                loadState = .failed(message: "Account security couldn’t be loaded.")
            }
        }
    }

    /// Recovery with the Apple sign-in the person just completed to sign in on this device,
    /// so it asks only for local confirmation, not a second Apple sheet.
    public func recover(with signIn: RecentAppleSignIn) {
        _ = nextGeneration()
        recoveryDidComplete = false
        let id = UUID()
        attempt = (id, signIn.rawNonce, .recoverAccount)
        operationErrorMessage = nil
        submitAppleIdentityToken(Data(signIn.identityToken.utf8), for: id)
    }

    public func begin(_ action: Action) throws -> AppleRequest {
        _ = nextGeneration()
        attempt = nil
        if action == .recoverAccount { recoveryDidComplete = false }
        let nonce = try nonceGenerator()
        guard nonce.count == 32, !nonce.allSatisfy({ $0 == 0 }) else {
            throw AccountRuntimeError.cryptographicFailure
        }
        let id = UUID()
        attempt = (id, nonce, action)
        operationErrorMessage = nil
        return AppleRequest(id: id, nonce: AccountWireCodec.encodeBase64URL(nonce))
    }

    public func completeAppleAuthorization(_ result: Result<ASAuthorization, Error>, for id: UUID) {
        guard let current = attempt, current.id == id else { return }
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken else {
            attempt = nil
            operationErrorMessage = "Apple authorization was cancelled."
            return
        }
        submitAppleIdentityToken(tokenData, for: id)
    }

    func submitAppleIdentityToken(_ tokenData: Data, for id: UUID) {
        guard let current = attempt, current.id == id else { return }
        attempt = nil
        guard let identityToken = String(data: tokenData, encoding: .utf8), !identityToken.isEmpty else {
            operationErrorMessage = "Apple authorization was cancelled."
            return
        }
        let operation = generation
        isWorking = true
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let deletionResult = try await performAction(
                    current.action,
                    identityToken,
                    current.nonce
                )
                guard !Task.isCancelled, generation == operation else { return }
                self.deletionResult = deletionResult
                isWorking = false
                operationErrorMessage = nil
                stateChanged()
                if current.action == .recoverAccount { recoveryDidComplete = true }
                if current.action != .deleteAccount && current.action != .recoverAccount { refresh() }
            } catch is CancellationError {
                guard generation == operation else { return }
                isWorking = false
            } catch {
                guard generation == operation else { return }
                isWorking = false
                operationErrorMessage = Self.operationFailureMessage(for: error, action: current.action)
            }
        }
    }

    private static func operationFailureMessage(for error: Error, action: Action) -> String {
        if error is AppleSignInIssuedForAnotherApp {
            #if os(macOS)
            return AppleSignInFailureMessages.issuedForAnotherApp(deviceName: "Mac")
            #else
            return AppleSignInFailureMessages.issuedForAnotherApp(deviceName: "device")
            #endif
        }
        guard action == .recoverAccount, let failure = error as? AccountRecoveryFailure else {
            return "The security change was not completed."
        }
        switch failure {
        case .requestPreparation:
            return "Plainpost could not prepare the recovery request."
        case .serverPreparation:
            return "Central could not prepare account recovery."
        case .responseDecoding:
            return "Plainpost could not read the recovery response."
        case .responseBinding:
            return "The recovery response did not match this device."
        case .authorizationVerification:
            return "Recovery authorization could not be verified."
        case .priorHistory:
            return "Account recovery history could not be verified."
        case .candidatePreparation:
            return "Plainpost could not prepare replacement account keys."
        case .localApproval:
            return "Account recovery was not confirmed on this device."
        case .checkpointPersistence:
            return "Plainpost could not securely save recovery progress."
        case .serverCommit:
            return "Central did not accept account recovery."
        case .localActivation:
            return "Recovery could not be activated on this device."
        }
    }

    public func cancel() {
        _ = nextGeneration()
        attempt = nil
        isWorking = false
        if loadState == .loading { loadState = .idle }
    }

    public func renameDevice(_ deviceID: AccountDeviceID, label: String) {
        let operation = nextGeneration()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await saveLabel(deviceID, label)
                guard !Task.isCancelled, generation == operation else { return }
                refresh()
            } catch {
                guard generation == operation else { return }
                operationErrorMessage = "The local device label was not saved."
            }
        }
    }

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        task?.cancel()
        task = nil
        return generation
    }
}

public struct AccountRecoveryView: View {
    @ObservedObject private var model: AccountSecurityViewModel
    @State private var appleRequest: AccountSecurityViewModel.AppleRequest?
    private let recentAppleSignIn: () -> RecentAppleSignIn?

    public init(model: AccountSecurityViewModel, recentAppleSignIn: @escaping () -> RecentAppleSignIn? = { nil }) {
        self.model = model
        self.recentAppleSignIn = recentAppleSignIn
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 18) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Recover Plainpost Account")
                .font(.title2.bold())

            Text("Recovery creates fresh account keys on this device and suspends every prior Plainpost session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let signIn = recentAppleSignIn() {
                // Sign-in just happened: recovery uses it instead of asking Apple again.
                Button("Recover with This Apple Sign-in") { model.recover(with: signIn) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("account-recovery.use-recent-sign-in")
            } else {
            VStack(alignment: .center, spacing: 10) {
                Text("Confirm account recovery with Apple")
                    .font(.headline)
                SignInWithAppleButton(.continue) { request in
                    guard appleRequest == nil,
                          let attempt = try? model.begin(.recoverAccount)
                    else { return }
                    appleRequest = attempt
                    request.nonce = attempt.nonce
                } onCompletion: { result in
                    guard let attempt = appleRequest else { return }
                    appleRequest = nil
                    model.completeAppleAuthorization(result, for: attempt.id)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 46)
                .disabled(model.isWorking || appleRequest != nil)
            }
            }

            if model.isWorking {
                ProgressView("Completing account recovery…")
            }

            if let operationErrorMessage = model.operationErrorMessage {
                Label(
                    operationErrorMessage,
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .top)
        .onDisappear { model.cancel() }
    }
}
