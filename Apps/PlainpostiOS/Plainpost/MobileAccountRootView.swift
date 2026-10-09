import AuthenticationServices
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostUI
import SwiftUI
import UIKit

struct MobileAccountRootView<AuthorizedContent: View>: View {
    @ObservedObject var model: MobileAccountModel
    @State private var appleAttemptID: UUID?
    @State private var approvalAppleAttemptID: UUID?
    @State private var showsSecurity = false
    @State private var isKeyboardVisible = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let changeServer: (() -> Void)?
    @ViewBuilder let authorizedContent: (_ readOnly: Bool, _ expiresAt: Date?) -> AuthorizedContent

    init(
        model: MobileAccountModel,
        changeServer: (() -> Void)? = nil,
        @ViewBuilder authorizedContent: @escaping (_ readOnly: Bool, _ expiresAt: Date?) -> AuthorizedContent
    ) {
        self.model = model
        self.changeServer = changeServer
        self.authorizedContent = authorizedContent
    }

    var body: some View {
        Group {
        switch model.presentation {
        case .signInRequired:
            VStack(spacing: 20) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 44))
                Text("Your mail, privately synced")
                    .font(.title2.bold())
                if let error = model.appleSignInErrorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("account.sign-in-error")
                }
                SignInWithAppleButton(.continue) { request in
                    guard appleAttemptID == nil, let id = model.configureAppleRequest(request) else { return }
                    appleAttemptID = id
                } onCompletion: { result in
                    let id = appleAttemptID
                    appleAttemptID = nil
                    model.completeAppleAuthorization(result, attemptID: id)
                }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .disabled(model.isAppleSignInInFlight || appleAttemptID != nil)
                    .accessibilityIdentifier("account.sign-in-with-apple")
                if let changeServer {
                    Button("Change Server", action: changeServer)
                        .accessibilityIdentifier("central-server.change")
                }
            }
            .padding(28)
        case .pendingApproval(let matchingCode):
            ScrollView {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Approve this device")
                        .font(.title2.bold())
                    Text("Confirm this code on a trusted device")
                    if let code = MobileAccountPresentation.pendingApproval(matchingCode: matchingCode).matchingCodeDisplay {
                        Text(code)
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .accessibilityIdentifier("account.matching-code")
                    }
                    Button("Cancel approval", role: .cancel) { model.cancelPendingApproval() }
                    if model.appleSignInForRecovery() != nil, model.securityModel != nil {
                        // Without another trusted device the request can't be approved.
                        Button("Can’t use another device? Recover instead") {
                            model.cancelPendingApproval()
                            showsSecurity = true
                        }
                        .accessibilityIdentifier("account-approval.recover-instead")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            }
        case .active:
            // The account controls are stacked above the mail rather than
            // floated over it. Floating, they covered the mail's navigation
            // bar (title, mode picker, Compose, Ask Mail, Command Center), the
            // embedded composer's close button and Send bar, and the
            // failed-send snackbar.
            VStack(spacing: 0) {
                if !isCompactKeyboardEditing {
                    activeAccountChrome
                }
                authorizedContent(false, nil)
                    .environment(\.mobileCompactKeyboardEditing, isCompactKeyboardEditing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
        case .offlineLease(let expiresAt):
            VStack(spacing: 0) {
                Text("Offline · read-only until \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.18))
                authorizedContent(true, expiresAt)
            }
        case .suspended:
            VStack(spacing: 16) {
                accountStatus("Access suspended", "Another device recovered or suspended your Plainpost Account, so it's locked on this iPhone. Sign in again, then approve this iPhone on a trusted device.", "hand.raised.fill")
                if model.canSignInAgainAfterSuspension {
                    Button("Sign In Again") { model.signInAgainAfterSuspension() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("account-suspended.sign-in-again")
                }
            }
        case .cleanupRequired:
            accountStatus("Finishing account erasure", "Plainpost data remains locked while cleanup resumes.", "trash.fill")
        case .deleted:
            accountStatus("Plainpost account deleted", "Plainpost-managed data on this device was erased. Mail stored by your provider was not deleted.", "checkmark.shield.fill")
        case .recoveryRequired:
            VStack(spacing: 16) {
                accountStatus("Recovery required", "Reconnect your account to open mail.", "key.fill")
                if model.securityModel != nil {
                    Button("Recover Plainpost Account") { showsSecurity = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        }
        // Recovery only: Plainpost Account and Sync Node are Settings pages.
        .sheet(isPresented: $showsSecurity) {
            if let security = model.securityModel {
                MobileAccountRecoveryView(model: security, recentAppleSignIn: { model.appleSignInForRecovery() })
            }
        }
    }

    /// An iPhone in landscape has about 200 pt above the keyboard. While
    /// typing there the account bar steps aside so the composer keeps it; it
    /// returns as soon as the keyboard goes.
    private var isCompactKeyboardEditing: Bool {
        verticalSizeClass == .compact && isKeyboardVisible
    }

    /// One bar above the mail: any device-approval prompt. Everything here takes its own
    /// space. Notifications and Plainpost Account are in Settings.
    private var activeAccountChrome: some View {
        VStack(spacing: 0) {
            if let prompt = model.deviceApprovalPrompt {
                HStack(spacing: 12) {
                    Text("Confirm device code \(prompt.matchingCode)").font(.headline.monospacedDigit())
                    SignInWithAppleButton(.continue) { request in
                        guard approvalAppleAttemptID == nil, let id = model.configureDeviceApprovalAppleRequest(request) else { return }
                        approvalAppleAttemptID = id
                    } onCompletion: { result in
                        let id = approvalAppleAttemptID
                        approvalAppleAttemptID = nil
                        model.completeDeviceApprovalAppleAuthorization(result, attemptID: id)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(width: 170, height: 40)
                }.padding(10).background(.regularMaterial, in: Capsule()).padding(8)
            } else {
                PendingDeviceApprovalPill(
                    presentation: model.pendingDeviceApproval,
                    review: { model.beginApproval() },
                    dismiss: { model.dismissPendingDeviceApproval() }
                )
            }
        }
        .background(.bar)
    }

    private func accountStatus(_ title: String, _ detail: String, _ icon: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(detail))
    }
}

/// The Plainpost-account push rows in Settings ▸ Notifications on iOS: the notification
/// detail, Turn On while never set up, the per-mailbox sheet, and one Fix row when
/// registration needs attention.
struct MobilePushNotificationRows: View {
    @ObservedObject var model: MobileAccountModel

    var body: some View {
        Picker("Detail", selection: Binding(get: { model.notificationPreviewPolicy }, set: { model.setNotificationPreviewPolicy($0) })) {
            Text("Full").tag(NotificationPreviewPolicy.rich)
            Text("Sender + subject").tag(NotificationPreviewPolicy.senderAndSubject)
            Text("Generic").tag(NotificationPreviewPolicy.generic)
            Text("Off").tag(NotificationPreviewPolicy.off)
        }
        .accessibilityIdentifier("notifications.registration-status")
        if model.notificationStatus == .unconfigured {
            // Enables with the detail shown above, including the default a picker can't
            // re-select.
            Button("Turn On Notifications") { model.enableNotifications(policy: model.notificationPreviewPolicy) }
                .disabled(model.notificationPreviewPolicy == .off)
                .accessibilityIdentifier("notifications.turn-on")
        }
        if model.hasMailboxNotificationPolicyRows {
            Button("Per-mailbox settings") { model.isMailboxNotificationPolicyPresented = true }
                .accessibilityIdentifier("notifications.per-mailbox-detail")
        }
        if let action = model.notificationStatus.recoveryAction {
            LabeledContent("Notifications need attention") {
                Button("Fix") { fix(action) }
                    .accessibilityIdentifier("notifications.fix")
            }
        }
        // A Mac with the same Direct account sees its mail within seconds and pushes it here;
        // without one, this iPhone checks in the background when iOS allows.
        ForEach(model.directMacAlertAccounts) { account in
            LabeledContent(account.email) {
                if account.usesMac {
                    Text("Instant alerts from Mac")
                } else {
                    Button("Use Mac") { model.useMacForInstantAlerts(accountID: account.accountID) }
                        .accessibilityIdentifier("notifications.use-mac.\(account.accountID.rawValue)")
                }
            }
        }
    }

    private func fix(_ action: NotificationRecoveryAction) {
        switch action {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .selectProducer: model.selectNotificationProducer()
        case .reapprove: model.reapproveNotifications()
        case .refreshToken: model.refreshNotificationToken()
        case .retry: model.retryNotifications()
        }
    }
}
