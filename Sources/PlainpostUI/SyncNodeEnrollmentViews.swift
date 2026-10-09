import AuthenticationServices
import Combine
import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import SwiftUI

/// Presentation owner for one provisioned Node connection attempt. Apple
/// authorization completes before this model lets the runtime fetch a claim.
@MainActor
public final class SyncNodeEnrollmentViewModel: ObservableObject {
    public struct AppleAuthorizationRequest: Equatable, Sendable {
        public let id: UUID
        public let nonce: String
    }

    public enum ConnectionPresentation: Equatable, Sendable {
        case ready
        case authorizing
        case connecting
        case checking
        case connected
        case connectionFailed
        case recoveryRequired
        case failed
    }

    private enum AttemptPhase { case awaitingAuthorization, connecting }
    private struct Attempt {
        let id: UUID
        let nonce: Data
        let generation: UInt64
        var phase: AttemptPhase
    }

    @Published public private(set) var isReplacementConfirmationVisible = false
    @Published public private(set) var selectedReplacementNodeID: AccountDeviceID?
    @Published public private(set) var isReplacementReady = false
    @Published public private(set) var state: SyncNodeEnrollmentCoordinator.State
    @Published public private(set) var connectionPresentation: ConnectionPresentation
    /// A Stop and Start Over claim cancel is waiting for Central.
    @Published public private(set) var isStoppingAndStartingOver = false
    /// Shown after Stop and Start Over could not prove that nothing committed.
    @Published public private(set) var startOverFailureMessage: String?
    /// Shown while Connect waits for a claim Central cancelled to expire.
    @Published public private(set) var reconnectWaitMessage: String?

    private let coordinator: SyncNodeEnrollmentCoordinator
    private let profile: SyncNodeBootstrapProfile?
    /// The account and device that started this connection. Clients gate
    /// rendering a retained connection on it.
    public let enrollmentOwner: SyncNodeEnrollmentOwner?
    private let nonceGenerator: () throws -> Data
    private let retireProfile: @MainActor (Data) throws -> Void
    private let verifyConnection: @Sendable () async throws -> Void
    private let clock: () -> Date
    private var reconnectAvailableAt: Date?
    private var reconnectObservation: AnyCancellable?
    private var reconnectRefresh: Task<Void, Never>?
    private var installationConverged: (@MainActor () -> Void)?
    private var observation: AnyCancellable?
    private var attempt: Attempt?
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0
    /// What a confirmed Replace moved to `.ready`, and for which Node. It is
    /// restored when the replacement ends without installing while that Node
    /// is still the active one.
    private var presentationBeforeReplacement: (presentation: ConnectionPresentation, nodeID: AccountDeviceID)?

    public init(
        coordinator: SyncNodeEnrollmentCoordinator,
        profile: SyncNodeBootstrapProfile? = nil,
        owner: SyncNodeEnrollmentOwner? = nil,
        initialConnectionPresentation: ConnectionPresentation = .ready,
        nonceGenerator: (() throws -> Data)? = nil,
        retireProfile: @escaping @MainActor (Data) throws -> Void = { _ in },
        verifyConnection: @escaping @Sendable () async throws -> Void = {},
        clock: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.profile = profile
        self.enrollmentOwner = owner
        self.connectionPresentation = initialConnectionPresentation
        self.nonceGenerator = nonceGenerator ?? Self.secureNonce
        self.retireProfile = retireProfile
        self.verifyConnection = verifyConnection
        self.clock = clock
        state = coordinator.state
        observation = coordinator.$state.sink { [weak self] state in
            self?.state = state
            if state != .commitResponseUncertain { self?.startOverFailureMessage = nil }
            if case .installed = state { self?.clearReplacementConsent() }
            if case .failed = state { self?.clearReplacementConsent() }
            if case .profileOutdated = state { self?.clearReplacementConsent() }
            if case .serverAudienceMismatch = state { self?.clearReplacementConsent() }
            if case .enterCode = state { self?.clearReplacementConsent() }
        }
        reconnectObservation = coordinator.$reconnectAvailableAt.sink { [weak self] availableAt in
            self?.reconnectAvailableAt = availableAt
            self?.refreshReconnectAvailability()
        }
    }

    deinit { operation?.cancel(); reconnectRefresh?.cancel() }

    public static let genericFailureMessage = "Sync Node connection couldn’t be completed. Try again."
    public static let outdatedProfileMessage = "This Server Setup file is out of date. Create a new one for this server."
    public static let serverMismatchMessage = "This Server Setup file doesn’t match your Plainpost server. Create a new one for this server."
    public static let verificationFailureMessage = "Plainpost couldn’t verify the server’s approval. Your approval is saved, so don’t start over."
    public static let commitUncertainMessage = "The server may have saved your approval. Retry to check it safely."
    public static let activationUncertainMessage = "The server response was interrupted. Retry to finish connecting."
    #if os(macOS)
    /// The exact commit replay lives only in memory, so every retained state
    /// asks the user to keep Plainpost open.
    public static let keepOpenMessage = "Keep Plainpost open while this finishes."
    #else
    /// iOS may end Plainpost once it leaves the screen, which loses the
    /// in-memory replay just as quitting does.
    public static let keepOpenMessage = "Keep Plainpost on screen while this finishes."
    #endif
    /// An uncertain commit Central never answered 2xx can be stopped safely:
    /// the request is released only if Central proves nothing committed.
    public static let stopAndStartOverGuidance = "If retrying keeps failing, choose Stop and Start Over."
    /// Central answered 2xx at least once, so there is no safe way to start
    /// over; Retry Installation checks whether the approval was saved.
    public static let quittingLosesApprovalGuidance = "The server may have finished this step. Choose Retry Installation to check."
    /// The activator journals the exact Node request before sending it and
    /// resumes it when the Sync Node connection loads again.
    public static let activationResumesGuidance = keepOpenMessage
    /// Any answer but 204 (404, 5xx or a lost response alike) proves nothing,
    /// so this never points back to Stop and Start Over.
    public static let startOverUnconfirmedMessage = "The server didn’t confirm that it stopped this connection, so it may have gone through. Choose Retry Installation to check it safely."
    /// Where a new Server Setup file is imported, next to this view.
    #if os(macOS)
    public static let serverSetupImportHint = "Then choose Replace Server Setup on this page to import it."
    #else
    public static let serverSetupImportHint = "Then choose Replace Server Setup on this screen to import it."
    #endif

    public static func connectionPresentation(for state: SyncNodeEnrollmentCoordinator.State) -> ConnectionPresentation {
        switch state {
        case .matchingStringConfirmation, .enterCode: return .ready
        case .commitResponseUncertain, .activationResponseUncertain, .commitVerificationFailed, .committing: return .connecting
        case .installed: return .checking
        case .failed, .profileOutdated, .serverAudienceMismatch: return .failed
        case .fetching, .localAuthentication, .centralStepUp, .signing: return .connecting
        }
    }

    public static func failureMessage(for state: SyncNodeEnrollmentCoordinator.State, profile: SyncNodeBootstrapProfile?) -> String? {
        switch state {
        case .commitVerificationFailed: return verificationFailureMessage
        case .serverAudienceMismatch: return serverMismatchMessage
        case .profileOutdated: return outdatedProfileMessage
        case .failed: return genericFailureMessage
        case .enterCode where profile != nil && profile?.centralAudience == nil: return outdatedProfileMessage
        default: return nil
        }
    }

    /// The one failure message both Sync Node surfaces render. A failed Apple
    /// authorization leaves the coordinator at `.enterCode`, so the
    /// presentation supplies the generic message there.
    public var presentedFailureMessage: String? {
        Self.failureMessage(for: state, profile: profile) ?? (connectionPresentation == .failed ? Self.genericFailureMessage : nil)
    }

    public var activeNodeID: AccountDeviceID? { coordinator.activeNodeID }
    public var canAddNode: Bool { activeNodeID == nil }
    public var canReplaceNode: Bool { activeNodeID != nil }
    public var canRetryCommit: Bool { state == .commitResponseUncertain }
    public var canRetryActivation: Bool { state == .activationResponseUncertain }
    public var canRetryCommitVerification: Bool {
        if case .commitVerificationFailed = state { return true }
        return false
    }
    /// Offered only while Central never answered 2xx for the uncertain commit.
    public var canStopAndStartOver: Bool { state == .commitResponseUncertain && coordinator.canStopAndStartOver }
    /// Guidance for every state that retains a possibly committed admission.
    public var retainedAdmissionGuidance: String? {
        switch state {
        case .commitResponseUncertain:
            // After a refused cancel, Retry Installation is the next step.
            if startOverFailureMessage != nil { return Self.keepOpenMessage }
            // The commit replay lives only in memory, so the next step always
            // follows the keep-open warning.
            let next = canStopAndStartOver ? Self.stopAndStartOverGuidance : Self.quittingLosesApprovalGuidance
            return "\(Self.keepOpenMessage) \(next)"
        case .activationResponseUncertain: return Self.activationResumesGuidance
        case .commitVerificationFailed: return Self.keepOpenMessage
        default: return nil
        }
    }
    public var showsKeepOpenGuidance: Bool { retainedAdmissionGuidance != nil }
    /// The failure can only be fixed by importing a new Server Setup file.
    public var needsNewServerSetup: Bool { state == .profileOutdated || state == .serverAudienceMismatch || (state == .enterCode && isProfileOutdated) }
    public var isProfileOutdated: Bool { profile != nil && profile?.centralAudience == nil }
    public var hasProvisionedTarget: Bool { profile != nil }
    public var retainsInstallationReplay: Bool { coordinator.retainsCommittedAdmission }
    public var canBeginConnect: Bool {
        profile != nil && !isProfileOutdated && state == .enterCode && connectionPresentation == .ready && attempt == nil && operation == nil && !isWaitingForFreshClaim
    }
    /// The Node still presents a claim Central confirmed cancelled, so a
    /// Connect before it expires is certain to fail.
    public var isWaitingForFreshClaim: Bool {
        guard let reconnectOpensAt else { return false }
        return clock() < reconnectOpensAt
    }

    /// Covers a few seconds of clock skew between this device and the Node
    /// that decides when the cancelled claim expired.
    public static let reconnectClockSkewGrace: TimeInterval = 5

    /// When Connect opens: the cancelled claim's expiry plus the skew grace.
    private var reconnectOpensAt: Date? {
        reconnectAvailableAt?.addingTimeInterval(Self.reconnectClockSkewGrace)
    }

    public static func reconnectWaitMessage(remaining: TimeInterval) -> String {
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return minutes == 1 ? "You can connect again in about 1 minute." : "You can connect again in about \(minutes) minutes."
    }

    /// Updates the wait copy from the clock. Views call this when they appear;
    /// while waiting, the model also refreshes it as time passes.
    public func refreshReconnectAvailability() {
        reconnectRefresh?.cancel()
        reconnectRefresh = nil
        let remaining = reconnectOpensAt.map { $0.timeIntervalSince(clock()) } ?? 0
        let message = remaining > 0 ? Self.reconnectWaitMessage(remaining: remaining) : nil
        if reconnectWaitMessage != message { reconnectWaitMessage = message }
        guard remaining > 0 else { return }
        let delay = min(remaining, 15)
        reconnectRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.refreshReconnectAvailability()
        }
    }
    public var targetOrigin: String? { profile?.canonicalOrigin.url.absoluteString }
    var provisionedCapabilityID: Data? { profile?.capabilityID }
    public var targetFingerprint: String? {
        profile?.signingKeyDigest.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public func requestReplacement() {
        guard let activeNodeID else { return }
        selectedReplacementNodeID = activeNodeID
        isReplacementReady = false
        isReplacementConfirmationVisible = true
    }

    public func cancelReplacement() {
        clearReplacementConsent()
        restorePresentationBeforeReplacement()
    }
    public func confirmReplacement() {
        guard let selectedReplacementNodeID else { return }
        coordinator.selectReplacement(of: selectedReplacementNodeID)
        coordinator.confirmReplacement(of: selectedReplacementNodeID)
        isReplacementReady = true
        isReplacementConfirmationVisible = false
        // Replace Sync Node is offered from these presentations; a confirmed
        // replacement continues with Apple from `.ready` on every surface.
        if state == .enterCode, attempt == nil, operation == nil,
           connectionPresentation == .recoveryRequired || connectionPresentation == .connectionFailed || connectionPresentation == .connected {
            presentationBeforeReplacement = (connectionPresentation, selectedReplacementNodeID)
            connectionPresentation = .ready
        }
    }

    public func beginConnectAppleAuthorization() throws -> AppleAuthorizationRequest {
        guard profile != nil,
              !isProfileOutdated,
              attempt == nil,
              operation == nil,
              connectionPresentation == .ready,
              state == .enterCode,
              !isWaitingForFreshClaim else { throw AccountRuntimeError.cancelled }
        let nonce = try nonceGenerator()
        guard nonce.count == 32, !nonce.allSatisfy({ $0 == 0 }) else {
            connectionPresentation = .failed
            throw AccountRuntimeError.cryptographicFailure
        }
        generation &+= 1
        let id = UUID()
        attempt = Attempt(id: id, nonce: nonce, generation: generation, phase: .awaitingAuthorization)
        connectionPresentation = .authorizing
        return AppleAuthorizationRequest(id: id, nonce: AccountWireCodec.encodeBase64URL(nonce))
    }

    public func completeAppleAuthorization(_ result: Result<ASAuthorization, Error>, for id: UUID) {
        guard attempt?.id == id, attempt?.phase == .awaitingAuthorization else { return }
        switch result {
        case .failure(let error):
            finishAuthorization(id: id, cancelled: Self.isAppleAuthorizationCancellation(error))
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken else {
                finishAuthorization(id: id, cancelled: false)
                return
            }
            submitAppleIdentityToken(token, for: id)
        }
    }

    /// Testable native-completion seam; token bytes remain task-local.
    public func submitAppleIdentityToken(_ token: Data, for id: UUID) {
        var ownedToken = token
        defer { ownedToken.resetBytes(in: ownedToken.startIndex ..< ownedToken.endIndex) }
        guard var ownedAttempt = attempt,
              ownedAttempt.id == id,
              ownedAttempt.phase == .awaitingAuthorization,
              let profile,
              let tokenText = String(data: ownedToken, encoding: .utf8),
              !tokenText.isEmpty,
              let authorization = try? SyncNodeEnrollmentAppleAuthorization(identityToken: tokenText, nonce: ownedAttempt.nonce)
        else {
            finishAuthorization(id: id, cancelled: false)
            return
        }
        ownedAttempt.phase = .connecting
        attempt = ownedAttempt
        connectionPresentation = .connecting
        let expectedGeneration = ownedAttempt.generation
        operation = Task { [weak self] in
            guard let self else { return }
            await coordinator.begin(profile: profile, appleAuthorization: authorization)
            guard !Task.isCancelled,
                  generation == expectedGeneration,
                  attempt?.id == id,
                  attempt?.phase == .connecting else { return }
            if case .installed = coordinator.state {
                await finishInstalled(profile: profile, generation: expectedGeneration)
            } else {
                connectionPresentation = Self.connectionPresentation(for: coordinator.state)
            }
            attempt = nil
            operation = nil
        }
    }

    public func approvePinnedTarget() async {
        guard connectionPresentation == .ready else { return }
        let expectedGeneration = generation
        connectionPresentation = .connecting
        await coordinator.approvePinnedTarget()
        guard generation == expectedGeneration else { return }
        if case .installed = coordinator.state, let profile {
            await finishInstalled(profile: profile, generation: expectedGeneration)
        } else {
            connectionPresentation = Self.connectionPresentation(for: coordinator.state)
        }
    }

    public func retryCommit() async {
        await coordinator.retryCommit()
        await completeRetryIfInstalled()
    }

    public func retryActivation() async {
        await coordinator.retryActivation()
        await completeRetryIfInstalled()
    }

    public func retryCommitVerification() async {
        await coordinator.retryCommitVerification()
        await completeRetryIfInstalled()
    }

    /// Releases an uncertain commit only after Central proves it never
    /// committed; otherwise the admission stays retained for Retry.
    public func stopAndStartOver() async {
        guard canStopAndStartOver, !isStoppingAndStartingOver else { return }
        isStoppingAndStartingOver = true
        startOverFailureMessage = nil
        let outcome = await coordinator.stopAndStartOver()
        isStoppingAndStartingOver = false
        switch outcome {
        case .startedOver:
            generation &+= 1
            attempt = nil
            operation?.cancel(); operation = nil
            clearReplacementConsent()
            connectionPresentation = .ready
            restorePresentationBeforeReplacement()
            // The owner may now publish a Server Setup imported while the
            // admission was retained.
            installationConverged?()
        case .admissionRetained:
            startOverFailureMessage = Self.startOverUnconfirmedMessage
        case .unavailable:
            break
        }
    }

    public func retryConnection() async {
        guard connectionPresentation == .connectionFailed else { return }
        let expectedGeneration = generation
        connectionPresentation = .checking
        do {
            try await verifyConnection()
            guard generation == expectedGeneration else { return }
            connectionPresentation = .connected
        } catch {
            guard generation == expectedGeneration else { return }
            connectionPresentation = .connectionFailed
        }
    }

    public func rejectPinnedTarget() async {
        generation &+= 1
        attempt = nil
        operation?.cancel(); operation = nil
        await coordinator.rejectMatchingString()
        clearReplacementConsent()
        connectionPresentation = .ready
        restorePresentationBeforeReplacement()
    }

    public func cancel() async {
        generation &+= 1
        attempt = nil
        operation?.cancel(); operation = nil
        await coordinator.cancel()
        clearReplacementConsent()
        if !retainsInstallationReplay {
            connectionPresentation = .ready
            restorePresentationBeforeReplacement()
        }
    }

    public func viewDidDisappear() async {
        if retainsInstallationReplay { clearReplacementConsent(); return }
        if case .installed = state {
            clearReplacementConsent()
            return
        }
        if activeNodeID != nil,
           connectionPresentation == .connected
            || connectionPresentation == .connectionFailed
            || connectionPresentation == .checking
            || connectionPresentation == .recoveryRequired {
            clearReplacementConsent()
            return
        }
        generation &+= 1
        attempt = nil
        operation?.cancel(); operation = nil
        await coordinator.viewDidDisappear()
        clearReplacementConsent()
        connectionPresentation = .ready
        restorePresentationBeforeReplacement()
    }

    public func resetAfterFailure() {
        guard state == .failed || state == .profileOutdated || state == .serverAudienceMismatch || connectionPresentation == .failed else { return }
        generation &+= 1
        attempt = nil
        operation?.cancel(); operation = nil
        clearReplacementConsent()
        coordinator.reset()
        connectionPresentation = .ready
        restorePresentationBeforeReplacement()
    }

    /// Called by the account owner before replacing this model. The
    /// coordinator generation changes synchronously, so a suspended fetch or
    /// lookup cannot reach authorization after the model leaves the UI.
    public func invalidateForReplacement() {
        guard !retainsInstallationReplay else { return }
        generation &+= 1
        attempt = nil
        operation?.cancel()
        operation = nil
        coordinator.invalidatePresentationOwnership()
        clearReplacementConsent()
    }

    /// Called when this model stops retaining an admission: after an install
    /// converges, or after a proven Stop and Start Over. The account owner
    /// uses it to apply a Server Setup imported while the admission was
    /// retained.
    public func setInstallationConvergedHandler(_ handler: (@MainActor () -> Void)?) {
        installationConverged = handler
    }

    private func completeRetryIfInstalled() async {
        if case .installed = coordinator.state, let profile {
            await finishInstalled(profile: profile, generation: generation)
        } else {
            connectionPresentation = Self.connectionPresentation(for: coordinator.state)
        }
    }

    private func finishInstalled(profile: SyncNodeBootstrapProfile, generation expectedGeneration: UInt64) async {
        guard generation == expectedGeneration else { return }
        presentationBeforeReplacement = nil
        do { try retireProfile(profile.capabilityID) } catch { /* A newer import remains intact. */ }
        guard generation == expectedGeneration else { return }
        connectionPresentation = .checking
        do {
            try await verifyConnection()
            guard generation == expectedGeneration else { return }
            connectionPresentation = .connected
        } catch {
            guard generation == expectedGeneration else { return }
            connectionPresentation = .connectionFailed
        }
        installationConverged?()
    }

    private func finishAuthorization(id: UUID, cancelled: Bool) {
        guard attempt?.id == id else { return }
        attempt = nil
        operation?.cancel(); operation = nil
        connectionPresentation = cancelled ? .ready : .failed
    }

    /// Returns a still-active Node to how it was presented before a confirmed
    /// Replace, once that replacement has ended without installing.
    private func restorePresentationBeforeReplacement() {
        guard let saved = presentationBeforeReplacement else { return }
        guard activeNodeID == saved.nodeID else {
            presentationBeforeReplacement = nil
            return
        }
        guard !isReplacementReady, state == .enterCode, attempt == nil, operation == nil, connectionPresentation == .ready else { return }
        presentationBeforeReplacement = nil
        connectionPresentation = saved.presentation
    }

    private func clearReplacementConsent() {
        selectedReplacementNodeID = nil
        isReplacementReady = false
        isReplacementConfirmationVisible = false
    }

    private static func secureNonce() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func isAppleAuthorizationCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == ASAuthorizationError.errorDomain
            && error.code == ASAuthorizationError.Code.canceled.rawValue
    }
}

/// The enrollment flow's Apple steps on the Sync Node page. `.connectStep` is setup step 2,
/// Continue with Apple for a Node that isn't enrolled. `.replacement` is Replace Sync Node
/// and its Apple step, shown in the Server section once a new Server Setup is imported. The
/// page overview carries the status, failures and every retry; the page applies
/// `syncNodeEnrollmentLifecycle` for appearance.
public struct SyncNodeEnrollmentView: View {
    public enum Placement: Sendable {
        case connectStep
        case replacement
    }

    @ObservedObject private var model: SyncNodeEnrollmentViewModel
    @State private var appleAttemptID: UUID?
    private let placement: Placement

    public init(model: SyncNodeEnrollmentViewModel, placement: Placement) {
        self.model = model
        self.placement = placement
    }

    public var body: some View {
        switch placement {
        case .connectStep:
            if model.canAddNode && model.state == .enterCode && !showsFailure {
                connectAppleButton()
                    .accessibilityIdentifier("sync-node-connect")
                reconnectWait
            } else {
                Self.unavailableConnectButton
            }
        case .replacement:
            if model.activeNodeID != nil, !showsFailure, model.hasProvisionedTarget, model.state == .enterCode {
                Button("Replace Sync Node", role: .destructive) { model.requestReplacement() }
                    #if os(macOS)
                    // A Mac form button ignores the destructive role's colour.
                    .foregroundStyle(.red)
                    #endif
                    .accessibilityIdentifier("sync-node-replace")
                    .confirmationDialog("Replace Sync Node?", isPresented: replacementConfirmation) {
                        Button("Replace Sync Node", role: .destructive) { model.confirmReplacement() }
                        Button("Cancel", role: .cancel) { model.cancelReplacement() }
                    }
                if model.isReplacementReady {
                    connectAppleButton()
                        .accessibilityIdentifier("sync-node-connect")
                    reconnectWait
                }
            }
        }
    }

    /// Continue with Apple before there is anything to connect to.
    public static var unavailableConnectButton: some View {
        SignInWithAppleButton(.continue) { _ in } onCompletion: { _ in }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)
            .disabled(true)
            .opacity(0.4)
            .accessibilityIdentifier("sync-node-connect-unavailable")
    }

    /// A failure the overview reports; the Apple steps wait for its retry.
    private var showsFailure: Bool {
        model.presentedFailureMessage != nil
            && (model.connectionPresentation == .failed || model.isProfileOutdated || model.canRetryCommitVerification)
    }

    @ViewBuilder
    private var reconnectWait: some View {
        if let message = model.reconnectWaitMessage {
            Text(message).foregroundStyle(.secondary)
                .accessibilityIdentifier("sync-node-reconnect-wait")
        }
    }

    private var replacementConfirmation: Binding<Bool> {
        // SwiftUI also writes `false` after a dialog action runs; by then
        // `confirmReplacement()` has hidden the dialog, so keep its consent.
        Binding(get: { model.isReplacementConfirmationVisible }, set: { if !$0 && model.isReplacementConfirmationVisible { model.cancelReplacement() } })
    }

    private func connectAppleButton() -> some View {
        let disabled = !model.canBeginConnect || appleAttemptID != nil
        return SignInWithAppleButton(.continue) { request in
            guard appleAttemptID == nil, let attempt = try? model.beginConnectAppleAuthorization() else { return }
            appleAttemptID = attempt.id
            request.nonce = attempt.nonce
        } onCompletion: { result in
            guard let id = appleAttemptID else { return }
            appleAttemptID = nil
            model.completeAppleAuthorization(result, for: id)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 44)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

public extension View {
    /// Ties the presented enrollment model to the page rather than to one of its sections,
    /// which a lazy form can drop while scrolling: the model refreshes its reconnect wait
    /// when shown, and hears `viewDidDisappear()` when the page closes, the model is
    /// replaced or it stops being presentable.
    func syncNodeEnrollmentLifecycle(_ model: SyncNodeEnrollmentViewModel?) -> some View {
        modifier(SyncNodeEnrollmentLifecycle(model: model))
    }
}

private struct SyncNodeEnrollmentLifecycle: ViewModifier {
    let model: SyncNodeEnrollmentViewModel?
    @State private var shown = Shown()

    @MainActor
    private final class Shown {
        var model: SyncNodeEnrollmentViewModel?
    }

    func body(content: Content) -> some View {
        content
            .onAppear { show(model) }
            .onChange(of: model.map(ObjectIdentifier.init)) { _, _ in show(model) }
            .onDisappear { show(nil) }
    }

    private func show(_ next: SyncNodeEnrollmentViewModel?) {
        if let current = shown.model, current !== next {
            Task { await current.viewDidDisappear() }
        }
        shown.model = next
        next?.refreshReconnectAvailability()
    }
}
