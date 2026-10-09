import AuthenticationServices
import PlainpostAccountRuntime
import SwiftUI

/// A Plainpost Account change that needs Apple confirmation. The Mac and iOS security models
/// have their own action types; the shared pages speak this one.
public enum AccountSecurityProtectedChange: Equatable, Sendable {
    case suspend
    case revoke
    case deleteAccount

    /// The confirmation dialog title; `deviceName` names the device a Suspend or Revoke acts on.
    func confirmationTitle(deviceName: String?) -> String {
        switch self {
        case .suspend: "Suspend \(deviceName ?? "Device")?"
        case .revoke: "Revoke \(deviceName ?? "Device")?"
        case .deleteAccount: "Delete Plainpost Account?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .suspend: "The device will be blocked from your Plainpost account."
        case .revoke: "The device will be removed from your Plainpost account permanently."
        case .deleteAccount: "Plainpost-managed data will be deleted from registered clients and Sync Nodes. Your mail provider account and its mail aren't deleted."
        }
    }

    var authorizationTitle: String {
        switch self {
        case .suspend: "Suspend trusted device"
        case .revoke: "Revoke trusted device"
        case .deleteAccount: "Delete Plainpost account"
        }
    }

    var authorizationDetail: String {
        switch self {
        case .suspend: "Confirm with Apple to stop this device from accessing the account."
        case .revoke: "Confirm with Apple to permanently remove this device from the account trust set."
        case .deleteAccount: "Confirm with Apple to delete Plainpost-managed account data. Provider-hosted mail is not deleted."
        }
    }
}

/// One Apple confirmation for a protected change, adapted to the platform's security model:
/// `configure` sets the request nonce and returns the attempt id that `complete` gets back.
public struct AccountSecurityAuthorization: Identifiable {
    public let id = UUID()
    public let change: AccountSecurityProtectedChange
    let configure: @MainActor (ASAuthorizationAppleIDRequest) -> UUID?
    let complete: @MainActor (Result<ASAuthorization, Error>, UUID?) -> Void
    let cancel: @MainActor () -> Void

    public init(
        change: AccountSecurityProtectedChange,
        configure: @escaping @MainActor (ASAuthorizationAppleIDRequest) -> UUID?,
        complete: @escaping @MainActor (Result<ASAuthorization, Error>, UUID?) -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.change = change
        self.configure = configure
        self.complete = complete
        self.cancel = cancel
    }
}

public extension View {
    /// Confirms `change`, then shows the Apple sheet for the authorization `authorize`
    /// returns (nil when the model can't start one).
    func accountSecurityConfirmation(
        _ change: Binding<AccountSecurityProtectedChange?>,
        deviceName: String? = nil,
        isWorking: Bool,
        authorize: @escaping @MainActor (AccountSecurityProtectedChange) -> AccountSecurityAuthorization?
    ) -> some View {
        modifier(AccountSecurityConfirmationModifier(
            change: change,
            deviceName: deviceName,
            isWorking: isWorking,
            authorize: authorize
        ))
    }
}

private struct AccountSecurityConfirmationModifier: ViewModifier {
    @Binding var change: AccountSecurityProtectedChange?
    let deviceName: String?
    let isWorking: Bool
    let authorize: @MainActor (AccountSecurityProtectedChange) -> AccountSecurityAuthorization?
    @State private var pending: AccountSecurityAuthorization?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                change?.confirmationTitle(deviceName: deviceName) ?? "",
                isPresented: Binding(get: { change != nil }, set: { if !$0 { change = nil } }),
                titleVisibility: .visible,
                presenting: change
            ) { change in
                Button("Continue to Apple Confirmation", role: change == .suspend ? nil : .destructive) {
                    pending = authorize(change)
                }
                Button("Cancel", role: .cancel) {}
            } message: { change in
                Text(change.confirmationMessage)
            }
            .sheet(item: $pending) { authorization in
                AccountSecurityAuthorizationSheet(
                    authorization: authorization,
                    isWorking: isWorking,
                    dismiss: { pending = nil }
                )
            }
    }
}

/// The Apple confirmation sheet for a protected change, on both platforms.
public struct AccountSecurityAuthorizationSheet: View {
    let authorization: AccountSecurityAuthorization
    let isWorking: Bool
    let dismiss: () -> Void
    @State private var attemptID: UUID?

    public init(authorization: AccountSecurityAuthorization, isWorking: Bool, dismiss: @escaping () -> Void) {
        self.authorization = authorization
        self.isWorking = isWorking
        self.dismiss = dismiss
    }

    public var body: some View {
        #if os(iOS)
        ScrollView {
            sheetContent
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        #else
        sheetContent
            .frame(width: 420)
        #endif
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(.blue)

            Text(authorization.change.authorizationTitle)
                .font(.title2.bold())

            Text(authorization.change.authorizationDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SignInWithAppleButton(.continue) { request in
                attemptID = authorization.configure(request)
            } onCompletion: { result in
                let id = attemptID
                attemptID = nil
                dismiss()
                authorization.complete(result, id)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 46)
            .disabled(isWorking)
            .accessibilityIdentifier("account-security.authorization.apple")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                    authorization.cancel()
                }
                .accessibilityIdentifier("account-security.authorization.cancel")
            }
        }
        .padding(24)
    }
}

/// A trusted device in the Plainpost Account list: platform icon, name with a "This Mac" tag
/// when renamed, and status · last activity. The row is a navigation link's label.
public struct TrustedDeviceRow: View {
    let device: AccountLifecycleDeviceSummary

    public init(device: AccountLifecycleDeviceSummary) {
        self.device = device
    }

    public var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(
                symbol: AccountSecurityPresentation.deviceSymbol(device.platform),
                tint: device.isCurrentDevice ? .green : .blue
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(AccountSecurityPresentation.deviceName(device))
                    if let tag = AccountSecurityPresentation.deviceTag(device) {
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(AccountSecurityPresentation.deviceDetail(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One trusted device: its name, status and last activity, and Suspend or Revoke for
/// another device. The name saves on Return, focus loss and leaving the page. A device the
/// account no longer lists (revoked) says so and offers nothing more.
public struct TrustedDeviceDetailPage: View {
    let device: AccountLifecycleDeviceSummary
    let isRemoved: Bool
    let isWorking: Bool
    let errorMessage: String?
    let save: @MainActor (String) -> Void
    let authorize: @MainActor (AccountSecurityProtectedChange) -> AccountSecurityAuthorization?
    @State private var label: String
    @State private var lastSavedLabel: String
    @State private var confirming: AccountSecurityProtectedChange?
    @FocusState private var isLabelFocused: Bool

    public init(
        device: AccountLifecycleDeviceSummary,
        isRemoved: Bool = false,
        isWorking: Bool,
        errorMessage: String?,
        save: @escaping @MainActor (String) -> Void,
        authorize: @escaping @MainActor (AccountSecurityProtectedChange) -> AccountSecurityAuthorization?
    ) {
        self.device = device
        self.isRemoved = isRemoved
        self.isWorking = isWorking
        self.errorMessage = errorMessage
        self.save = save
        self.authorize = authorize
        _label = State(initialValue: device.localLabel ?? "")
        _lastSavedLabel = State(initialValue: device.localLabel ?? "")
    }

    public var body: some View {
        Form {
            Section {
                TextField("Name", text: $label, prompt: Text(AccountSecurityPresentation.deviceName(device)))
                    .focused($isLabelFocused)
                    .onSubmit(saveLabel)
                    .disabled(isRemoved)
                    .accessibilityIdentifier("account-security.device-detail.name")
                LabeledContent("Status", value: AccountSecurityPresentation.deviceStatus(device.status))
                    .accessibilityIdentifier("account-security.device-detail.status")
                if let lastActivity = AccountSecurityPresentation.relative(device.lastSecurityEventAt) {
                    LabeledContent("Last activity", value: lastActivity)
                        .accessibilityIdentifier("account-security.device-detail.last-activity")
                }
            }
            if isRemoved {
                Section {
                    Text("This device was removed.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("account-security.device-detail.removed")
                }
            } else if !device.isCurrentDevice {
                Section {
                    Button("Suspend…") { confirming = .suspend }
                        .accessibilityIdentifier("account-security.device-detail.suspend")
                    Button("Revoke…", role: .destructive) { confirming = .revoke }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("account-security.device-detail.revoke")
                } footer: {
                    Text("Suspend blocks this device from your account. Revoke removes it permanently.")
                }
                .disabled(isWorking)
            }
            if isWorking {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Completing protected account change…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AccountSecurityPresentation.deviceName(device))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accountSecurityConfirmation(
            $confirming,
            deviceName: AccountSecurityPresentation.deviceName(device),
            isWorking: isWorking,
            authorize: authorize
        )
        .onChange(of: isLabelFocused) { _, focused in
            if !focused { saveLabel() }
        }
        // Back keeps the edit.
        .onDisappear(perform: saveLabel)
    }

    private func saveLabel() {
        guard !isRemoved, let changed = AccountSecurityPresentation.deviceLabelToSave(label, lastSaved: lastSavedLabel) else { return }
        lastSavedLabel = changed
        save(changed)
    }
}
