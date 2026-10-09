import AuthenticationServices
import SwiftUI

struct AccountRecoveryActions: View {
    let recover: (() -> Void)?
    let changeServer: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if let recover {
                Button("Recover Plainpost Account", action: recover)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("account-recovery-open")
            }
            if let changeServer {
                Button("Change Server", action: changeServer)
                    .plainpostLinkButtonStyle()
                    .accessibilityIdentifier("central-server.change")
            }
        }
    }
}

struct AccountRecoverySheet: View {
    @ObservedObject var model: AccountSecurityViewModel
    var recentAppleSignIn: () -> RecentAppleSignIn? = { nil }
    @Environment(\.dismiss) private var dismiss

    private var sheetWidth: CGFloat? {
        #if os(macOS)
        520
        #else
        nil
        #endif
    }

    var body: some View {
        AccountRecoveryView(model: model, recentAppleSignIn: recentAppleSignIn)
            .frame(width: sheetWidth)
            .onChange(of: model.recoveryDidComplete) { _, didComplete in
                if didComplete { dismiss() }
            }
    }
}

public struct AccountSessionRootView<AuthorizedContent: View>: View {
    @ObservedObject private var model: AccountSessionViewModel
    @State private var appleAttemptID: UUID?
    @State private var approvalAppleAttemptID: UUID?
    @State private var showsRecovery = false
    private let changeServer: (() -> Void)?
    @ViewBuilder private let authorizedContent: (_ readOnly: Bool, _ expiresAt: Date?) -> AuthorizedContent

    private var deviceName: String {
        #if os(iOS)
        "device"
        #else
        "Mac"
        #endif
    }

    public init(
        model: AccountSessionViewModel,
        changeServer: (() -> Void)? = nil,
        @ViewBuilder authorizedContent: @escaping (_ readOnly: Bool, _ expiresAt: Date?) -> AuthorizedContent
    ) {
        self.model = model
        self.changeServer = changeServer
        self.authorizedContent = authorizedContent
    }

    static func showsRecoveryAction(
        presentation: AccountSessionViewModel.Presentation,
        hasSecurityModel: Bool
    ) -> Bool {
        presentation == .recoveryRequired && hasSecurityModel
    }

    public var body: some View {
        Group {
        switch model.presentation {
        case .signInRequired:
            VStack(spacing: 22) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 48))
                Text("Sign in to Plainpost").font(.title.bold())
                Text("Your mailbox stays locked until this \(deviceName) is authorized.")
                    .foregroundStyle(.secondary)
                SignInWithAppleButton(.continue) { authorizationRequest in
                    guard appleAttemptID == nil, let request = try? model.beginAppleSignIn() else { return }
                    appleAttemptID = request.id
                    authorizationRequest.nonce = request.nonce
                } onCompletion: { result in
                    let completedAttemptID = appleAttemptID
                    appleAttemptID = nil
                    guard let completedAttemptID else { return }
                    model.completeAppleAuthorization(result, for: completedAttemptID)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(width: 280, height: 48)
                .disabled(model.isAppleSignInInFlight || appleAttemptID != nil)
                if model.isAppleSignInInFlight {
                    ProgressView("Signing in…")
                } else if let errorMessage = model.appleSignInErrorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                if model.showsSyncNodeBootstrapImport,
                   let importModel = model.syncNodeBootstrapImportModel {
                    Divider().frame(width: 280)
                    SyncNodeBootstrapImportView(model: importModel)
                        .frame(maxWidth: 360)
                }
                if let changeServer {
                    Button("Change Server", action: changeServer)
                        .plainpostLinkButtonStyle()
                        .accessibilityIdentifier("central-server.change")
                }
            }
            .padding(36)
        case .pendingApproval:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Approve this \(deviceName)").font(.title2.bold())
                Text("Confirm the matching code on a trusted device.")
                if let code = model.presentation.matchingCodeDisplay {
                    Text(code).font(.system(.title, design: .monospaced).weight(.semibold))
                }
                Button("Cancel approval", role: .cancel) { model.cancelPendingApproval() }
                if model.appleSignInForRecovery() != nil, model.securityModel != nil {
                    // Without another trusted device the request can't be approved; recover
                    // now with this sign-in instead of waiting for it to expire.
                    Button("Can’t use another device? Recover instead") {
                        model.cancelPendingApproval()
                        showsRecovery = true
                    }
                    .plainpostLinkButtonStyle()
                    .accessibilityIdentifier("account-approval.recover-instead")
                }
            }
            .padding(36)
        case .active:
            ZStack(alignment: .top) {
                authorizedContent(false, nil)
                if let prompt = model.deviceApprovalPrompt {
                    HStack(spacing: 12) {
                        Text("Confirm device code \(prompt.matchingCode)").font(.headline.monospacedDigit())
                        SignInWithAppleButton(.continue) { request in
                            guard approvalAppleAttemptID == nil, let attempt = try? model.beginDeviceApprovalAppleSignIn() else { return }
                            approvalAppleAttemptID = attempt.id
                            request.nonce = attempt.nonce
                        } onCompletion: { result in
                            guard let id = approvalAppleAttemptID else { return }
                            approvalAppleAttemptID = nil
                            model.completeDeviceApprovalAppleAuthorization(result, for: id)
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(width: 180, height: 40)
                    }.padding(10).background(.regularMaterial, in: Capsule()).padding()
                } else {
                    PendingDeviceApprovalPill(
                        presentation: model.pendingDeviceApproval,
                        review: { model.beginApproval() },
                        dismiss: { model.dismissPendingDeviceApproval() }
                    )
                }
            }
        case .offlineLease(let expiresAt):
            VStack(spacing: 0) {
                Text("Offline · cached mail is read-only until \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.18))
                authorizedContent(true, expiresAt)
            }
        case .suspended:
            VStack(spacing: 20) {
                ContentUnavailableView(
                    "Access suspended", systemImage: "hand.raised.fill",
                    description: Text("Another device recovered or suspended your Plainpost Account, so it's locked on this \(deviceName). Sign in again, then approve this \(deviceName) on a trusted device.")
                )
                if model.canSignInAgainAfterSuspension {
                    Button("Sign In Again") { model.signInAgainAfterSuspension() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("account-suspended.sign-in-again")
                }
            }
            .padding(36)
        case .cleanupRequired:
            ContentUnavailableView("Finishing account erasure", systemImage: "trash.fill", description: Text("Plainpost data remains locked while cleanup resumes."))
        case .deleted:
            ContentUnavailableView("Plainpost account deleted", systemImage: "checkmark.shield.fill", description: Text("Plainpost-managed data on this \(deviceName) was erased. Mail stored by your provider was not deleted."))
        case .recoveryRequired:
            VStack(spacing: 20) {
                ContentUnavailableView("Recovery required", systemImage: "key.fill", description: Text("Reconnect your account to open mail."))
                AccountRecoveryActions(
                    recover: Self.showsRecoveryAction(
                        presentation: model.presentation,
                        hasSecurityModel: model.securityModel != nil
                    ) ? { showsRecovery = true } : nil,
                    changeServer: changeServer
                )
            }
            .padding(36)
        }
        }
        .task(id: model.presentation) { await model.prepareCalendarAuthority() }
        .sheet(isPresented: $showsRecovery) {
            if let securityModel = model.securityModel {
                AccountRecoverySheet(model: securityModel, recentAppleSignIn: { model.appleSignInForRecovery() })
            }
        }
    }
}
