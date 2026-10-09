import AuthenticationServices
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostUI
import SwiftUI

@MainActor
final class MobileAccountSecurityModel: ObservableObject {
    enum Action: Equatable, Sendable { case revoke(AccountDeviceID), suspend(AccountDeviceID), deleteAccount, recoverAccount }
    struct AppleRequest: Equatable { let id: UUID; let nonce: String }
    typealias ControllerFactory = @MainActor @Sendable () throws -> AccountLifecycleController
    typealias SnapshotLoader = @MainActor @Sendable () async throws -> ([AccountLifecycleDeviceSummary], [AccountSecurityEventV1])
    typealias ActionPerformer = @MainActor @Sendable (Action, String, Data) async throws -> AccountDeletionResultV1?
    typealias LabelSaver = @MainActor @Sendable (AccountDeviceID, String) async throws -> Void

    @Published private(set) var devices: [AccountLifecycleDeviceSummary] = []
    @Published private(set) var events: [AccountSecurityEventV1] = []
    @Published private(set) var isWorking = false {
        didSet { if !isWorking { workingAction = nil } }
    }
    /// The protected change in progress, while `isWorking`.
    @Published private(set) var workingAction: Action?
    @Published private(set) var errorMessage: String?
    @Published private(set) var deletionResult: AccountDeletionResultV1?
    private let loadSnapshot: SnapshotLoader
    private let performAction: ActionPerformer
    private let saveLabel: LabelSaver
    private let stateChanged: @MainActor @Sendable () -> Void
    private let nonceGenerator: @MainActor @Sendable () -> Data
    private var attempt: (id: UUID, nonce: Data, action: Action)?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(controllerFactory: @escaping ControllerFactory, stateChanged: @escaping @MainActor @Sendable () -> Void) {
        loadSnapshot = {
            let controller = try controllerFactory()
            let page = try await controller.securityHistory(limit: 32)
            return (try await controller.devices(recentEvents: page.events), page.events)
        }
        performAction = { action, identityToken, nonce in
            let controller = try controllerFactory()
            switch action {
            case .revoke(let id): _ = try await controller.revokeDevice(id, identityToken: identityToken, appleNonce: nonce); return nil
            case .suspend(let id): _ = try await controller.suspendDevice(id, identityToken: identityToken, appleNonce: nonce); return nil
            case .deleteAccount: return try await controller.deleteAccount(identityToken: identityToken, appleNonce: nonce)
            case .recoverAccount: _ = try await controller.recover(identityToken: identityToken, appleNonce: nonce); return nil
            }
        }
        saveLabel = { deviceID, label in
            try await controllerFactory().setLocalDeviceLabel(label, for: deviceID)
        }
        self.stateChanged = stateChanged
        nonceGenerator = {
            var random = SystemRandomNumberGenerator()
            return Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        }
    }

    init(
        loadSnapshot: @escaping SnapshotLoader,
        performAction: @escaping ActionPerformer,
        saveLabel: @escaping LabelSaver,
        stateChanged: @escaping @MainActor @Sendable () -> Void,
        nonceGenerator: @escaping @MainActor @Sendable () -> Data
    ) {
        self.loadSnapshot = loadSnapshot
        self.performAction = performAction
        self.saveLabel = saveLabel
        self.stateChanged = stateChanged
        self.nonceGenerator = nonceGenerator
    }

    deinit { task?.cancel() }

    func refresh() {
        let operation = nextGeneration()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (devices, events) = try await loadSnapshot()
                guard !Task.isCancelled, generation == operation else { return }
                self.devices = devices
                self.events = events
                errorMessage = nil
            } catch is CancellationError {
                guard generation == operation else { return }
                isWorking = false
            } catch {
                guard generation == operation else { return }
                errorMessage = "Security information is unavailable."
            }
        }
    }

    /// Recovery with the Apple sign-in just completed on this iPhone: local confirmation
    /// only, no second Apple sheet.
    func recover(with signIn: RecentAppleSignIn) {
        _ = nextGeneration()
        let id = UUID()
        attempt = (id, signIn.rawNonce, .recoverAccount)
        submitAppleIdentityToken(Data(signIn.identityToken.utf8), id: id)
    }

    func configure(_ request: ASAuthorizationAppleIDRequest, action: Action) -> UUID? {
        _ = nextGeneration()
        attempt = nil
        let nonce = nonceGenerator()
        guard nonce.count == 32, !nonce.allSatisfy({ $0 == 0 }) else { return nil }
        let id = UUID()
        attempt = (id, nonce, action)
        request.nonce = AccountWireCodec.encodeBase64URL(nonce)
        return id
    }

    func complete(_ result: Result<ASAuthorization, Error>, id: UUID?) {
        guard let id, let current = attempt, current.id == id else { return }
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken else {
            attempt = nil
            errorMessage = "Apple authorization was cancelled."
            return
        }
        submitAppleIdentityToken(tokenData, id: id)
    }

    func submitAppleIdentityToken(_ tokenData: Data, id: UUID) {
        guard let current = attempt, current.id == id else { return }
        attempt = nil
        guard let identityToken = String(data: tokenData, encoding: .utf8), !identityToken.isEmpty else {
            errorMessage = "Apple authorization was cancelled."
            return
        }
        let operation = generation
        isWorking = true
        workingAction = current.action
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == operation { task = nil }
            }
            do {
                let deletion = try await performAction(current.action, identityToken, current.nonce)
                guard !Task.isCancelled, generation == operation else { return }
                if current.action == .deleteAccount { deletionResult = deletion }
                isWorking = false
                errorMessage = nil
                stateChanged()
                if current.action != .deleteAccount && current.action != .recoverAccount { refresh() }
            } catch is CancellationError {
                guard generation == operation else { return }
                isWorking = false
            } catch {
                guard generation == operation else { return }
                isWorking = false
                errorMessage = "The security change was not completed."
            }
        }
    }

    func cancel() { _ = nextGeneration(); attempt = nil; isWorking = false }

    var hasPendingAppleAuthorization: Bool { attempt != nil }

    func waitUntilIdle() async {
        let pending = task
        await pending?.value
    }

    func renameDevice(_ deviceID: AccountDeviceID, label: String) {
        let operation = nextGeneration()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await saveLabel(deviceID, label)
                guard !Task.isCancelled, generation == operation else { return }
                refresh()
            } catch {
                guard generation == operation else { return }
                errorMessage = "The local device label was not saved."
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

/// Account recovery, reached from the `.recoveryRequired` screen. Trusted devices, activity
/// and deletion are on the Settings Plainpost Account page; Sync Node is its own page.
struct MobileAccountRecoveryView: View {
    @ObservedObject var model: MobileAccountSecurityModel
    var recentAppleSignIn: () -> RecentAppleSignIn? = { nil }
    @State private var attemptID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Recovery creates fresh account keys on this device and suspends every prior Plainpost session.")
                    if let signIn = recentAppleSignIn() {
                        Button("Recover with This Apple Sign-in") { model.recover(with: signIn) }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("account-recovery.use-recent-sign-in")
                    } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recover Plainpost Account").font(.headline)
                        SignInWithAppleButton(.continue) { request in
                            attemptID = model.configure(request, action: .recoverAccount)
                        } onCompletion: { result in
                            let id = attemptID
                            attemptID = nil
                            model.complete(result, id: id)
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 46)
                        .accessibilityLabel("Recover Plainpost Account")
                        .disabled(model.isWorking)
                    }
                    }
                }
                if model.isWorking { ProgressView() }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Account Recovery")
            .onDisappear { model.cancel() }
        }
    }
}
