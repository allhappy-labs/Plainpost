import AuthenticationServices
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostUI
import SwiftUI

/// The iOS Plainpost Account settings page: trusted devices, security activity and account
/// deletion. Protected changes confirm, then go through the shared Apple sheet.
struct MobilePlainpostAccountPage: View {
    @ObservedObject var model: MobileAccountSecurityModel
    @State private var confirming: AccountSecurityProtectedChange?
    @State private var hasAppeared = false

    var body: some View {
        Form {
            Section("Trusted Devices") {
                ForEach(model.devices) { device in
                    NavigationLink {
                        MobileTrustedDevicePage(model: model, device: device)
                    } label: {
                        TrustedDeviceRow(device: device)
                    }
                    // Opening a device mid-change would cancel the change (the page cancels
                    // its model when it disappears).
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("account-security.device.\(device.id.rawValue)")
                }
            }
            Section {
                NavigationLink("Security Activity") {
                    MobileSecurityActivityPage(events: model.events)
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("account-security.activity")
            }
            if model.deletionResult != nil {
                Section { Text("Plainpost account deleted.") }
            } else if model.workingAction == .deleteAccount {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Deleting your Plainpost account…")
                    }
                }
            } else {
                Section {
                    Button("Delete Plainpost Account…", role: .destructive) {
                        confirming = .deleteAccount
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("account-security.delete-account")
                } footer: {
                    Text("Your mail provider account and its mail aren't deleted.")
                }
                if model.isWorking {
                    Section { ProgressView() }
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .accountSecurityConfirmation($confirming, isWorking: model.isWorking) { change in
            model.authorization(for: change, deviceID: nil)
        }
        .task {
            guard !model.isWorking else { return }
            // Back from a device page keeps the list: a rename there refreshes it, and a
            // refresh here would cancel that save.
            if hasAppeared, !model.devices.isEmpty { return }
            hasAppeared = true
            model.refresh()
        }
        .onDisappear { model.cancel() }
    }
}

/// The shared device page, observing the model so status and progress stay current.
private struct MobileTrustedDevicePage: View {
    @ObservedObject var model: MobileAccountSecurityModel
    let device: AccountLifecycleDeviceSummary

    var body: some View {
        let current = model.devices.first { $0.id == device.id }
        TrustedDeviceDetailPage(
            device: current ?? device,
            isRemoved: current == nil,
            isWorking: model.isWorking,
            errorMessage: model.errorMessage,
            save: { model.renameDevice(device.id, label: $0) },
            authorize: { model.authorization(for: $0, deviceID: device.id) }
        )
    }
}

private struct MobileSecurityActivityPage: View {
    let events: [AccountSecurityEventV1]

    var body: some View {
        List {
            if events.isEmpty {
                Text("No recent security activity").foregroundStyle(.secondary)
            }
            ForEach(events, id: \.handle) { event in
                LabeledContent(
                    AccountSecurityPresentation.eventTitle(event.category),
                    value: AccountSecurityPresentation.relative(event.occurredAt) ?? ""
                )
            }
        }
        .navigationTitle("Security Activity")
    }
}

extension MobileAccountSecurityModel {
    /// The Apple sheet's handle on this model for `change`: the sheet's request configures
    /// the attempt, and its result completes that attempt only.
    func authorization(
        for change: AccountSecurityProtectedChange,
        deviceID: AccountDeviceID?
    ) -> AccountSecurityAuthorization? {
        guard !isWorking else { return nil }
        let action: Action
        switch (change, deviceID) {
        case (.suspend, let deviceID?): action = .suspend(deviceID)
        case (.revoke, let deviceID?): action = .revoke(deviceID)
        case (.deleteAccount, _): action = .deleteAccount
        default: return nil
        }
        return AccountSecurityAuthorization(
            change: change,
            configure: { [weak self] request in self?.configure(request, action: action) },
            complete: { [weak self] result, id in self?.complete(result, id: id) },
            // Only the Apple attempt this sheet started; a rename or refresh started since
            // keeps going.
            cancel: { [weak self] in
                guard let self, self.hasPendingAppleAuthorization else { return }
                self.cancel()
            }
        )
    }
}
