import AuthenticationServices
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import SwiftUI

/// The Plainpost Account page content: trusted devices, security activity and account
/// deletion. The Sync Node has its own page.
public struct AccountSecuritySettingsPanel: View {
    private let session: AccountSessionViewModel
    @ObservedObject private var model: AccountSecurityViewModel
    @State private var confirming: AccountSecurityProtectedChange?
    @State private var hasAppeared = false
    private let loadsOnAppear: Bool

    public init(
        session: AccountSessionViewModel,
        model: AccountSecurityViewModel
    ) {
        self.init(session: session, model: model, loadsOnAppear: true)
    }

    private init(
        session: AccountSessionViewModel,
        model: AccountSecurityViewModel,
        loadsOnAppear: Bool
    ) {
        self.session = session
        self.model = model
        self.loadsOnAppear = loadsOnAppear
    }

    public var body: some View {
        snapshotContent
        deleteAccountSection
    }

    @ViewBuilder
    private var snapshotContent: some View {
        switch model.loadState {
        case .idle, .loading:
            Section("Trusted Devices") {
                AccountSecurityStatusRow(
                    title: "Loading trusted devices…",
                    detail: "",
                    systemImage: "desktopcomputer",
                    tint: .blue,
                    showsProgress: true
                )
            }
        case .loaded:
            AccountSecurityDevicesSection(
                model: model,
                authorize: authorize
            )
            Section {
                NavigationLink("Security Activity") {
                    AccountSecurityActivityPage(events: model.events)
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("account-security.activity")
            }
        case .failed(let message):
            Section("Trusted Devices") {
                AccountSecurityStatusRow(
                    title: "Account security unavailable",
                    detail: message,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    Button("Retry") { model.refresh() }
                }
            }
        }
    }

    /// The page's lifecycle and sheets hang off this section's button, a single view in
    /// both the Mac stack and the iOS form.
    private var deleteAccountSection: some View {
        Section {
            Button("Delete Plainpost Account…", role: .destructive) {
                confirming = .deleteAccount
            }
            // A destructive role alone doesn't tint a Mac form button.
            .foregroundStyle(.red)
            .disabled(model.isWorking)
            .accessibilityIdentifier("account-security.delete-account")
            .task {
                guard loadsOnAppear, !model.isWorking else { return }
                // Back from a device page keeps the list: a rename there refreshes it, and a
                // refresh here would cancel that save.
                if hasAppeared, model.loadState == .loaded { return }
                hasAppeared = true
                model.refresh()
            }
            .onDisappear { model.cancel() }
            .accountSecurityConfirmation($confirming, isWorking: model.isWorking) { change in
                authorize(change, nil)
            }

            if let operationErrorMessage = model.operationErrorMessage {
                Label(operationErrorMessage, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }

            if model.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Completing protected account change…")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Your mail provider account and its mail aren't deleted.")
        }
    }

    private func authorize(
        _ change: AccountSecurityProtectedChange,
        _ deviceID: AccountDeviceID?
    ) -> AccountSecurityAuthorization? {
        model.authorization(for: change, deviceID: deviceID)
    }
}

extension AccountSecurityViewModel {
    /// Starts this model's Apple attempt for `change`; the sheet sets its nonce and hands the
    /// result back for this attempt only. Its Cancel ends that attempt and nothing else.
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
        // The model rejects malformed nonce material before any request is shown.
        guard let request = try? begin(action) else { return nil }
        return AccountSecurityAuthorization(
            change: change,
            configure: { appleRequest in
                appleRequest.nonce = request.nonce
                return request.id
            },
            complete: { [weak self] result, _ in self?.completeAppleAuthorization(result, for: request.id) },
            cancel: { [weak self] in
                guard let self, self.isPendingAppleAuthorization(request.id) else { return }
                self.cancel()
            }
        )
    }
}

@_spi(DesignPreview)
public extension AccountSecuritySettingsPanel {
    static func designPreview(
        loadState: AccountSecurityViewModel.LoadState,
        devices: [AccountLifecycleDeviceSummary] = [],
        events: [AccountSecurityEventV1] = []
    ) -> AccountSecuritySettingsPanel {
        let model = AccountSecurityViewModel(
            loadSnapshot: { .init(devices: devices, events: events) },
            performAction: { _, _, _ in nil },
            saveLabel: { _, _ in },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA5, count: 32) },
            initialSnapshot: .init(devices: devices, events: events),
            initialLoadState: loadState
        )
        return AccountSecuritySettingsPanel(
            session: AccountSessionViewModel(prepareSession: { _ in .active }),
            model: model,
            loadsOnAppear: false
        )
    }
}

/// The Plainpost Account settings window for design snapshots: the settings list and the
/// Plainpost Account page, nothing else.
@_spi(DesignPreview)
public struct AccountSecuritySettingsDesignPreview: View {
    private let panel: AccountSecuritySettingsPanel

    public init(
        loadState: AccountSecurityViewModel.LoadState,
        devices: [AccountLifecycleDeviceSummary] = [],
        events: [AccountSecurityEventV1] = []
    ) {
        panel = .designPreview(loadState: loadState, devices: devices, events: events)
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsRootList(selection: .constant(.section(.plainpostAccount)), accountRows: [], navigation: .selection)
                .frame(width: 260)
                .background(.regularMaterial)

            Divider()

            NavigationStack {
                SettingsPage(.plainpostAccount) { panel }
                    .background(MailDesign.background)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Trusted devices as navigation rows; each opens the shared detail page, whose Suspend and
/// Revoke confirm through the page's `authorize`.
private struct AccountSecurityDevicesSection: View {
    @ObservedObject var model: AccountSecurityViewModel
    let authorize: @MainActor (AccountSecurityProtectedChange, AccountDeviceID?) -> AccountSecurityAuthorization?

    var body: some View {
        Section("Trusted Devices") {
            if model.devices.isEmpty {
                Text("No trusted devices")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.devices) { device in
                    NavigationLink {
                        AccountSecurityDeviceDestination(model: model, device: device, authorize: authorize)
                    } label: {
                        TrustedDeviceRow(device: device)
                    }
                    // Opening a device mid-change would cancel the change (the page cancels
                    // its model when it disappears).
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("account-security.device.\(device.id.rawValue)")
                }
            }
        }
    }
}

/// The detail page, observing the model so status and progress stay current while it's open.
private struct AccountSecurityDeviceDestination: View {
    @ObservedObject var model: AccountSecurityViewModel
    let device: AccountLifecycleDeviceSummary
    let authorize: @MainActor (AccountSecurityProtectedChange, AccountDeviceID?) -> AccountSecurityAuthorization?

    var body: some View {
        let current = model.devices.first { $0.id == device.id }
        TrustedDeviceDetailPage(
            device: current ?? device,
            isRemoved: current == nil,
            isWorking: model.isWorking,
            errorMessage: model.operationErrorMessage,
            save: { model.renameDevice(device.id, label: $0) },
            authorize: { authorize($0, device.id) }
        )
    }
}

/// Security Activity: readable event names and relative dates.
private struct AccountSecurityActivityPage: View {
    let events: [AccountSecurityEventV1]

    var body: some View {
        Form {
            if events.isEmpty {
                Text("No recent security activity")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events, id: \.handle) { event in
                    LabeledContent(
                        AccountSecurityPresentation.eventTitle(event.category),
                        value: AccountSecurityPresentation.relative(event.occurredAt) ?? ""
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Security Activity")
    }
}

private struct AccountSecuritySettingsRow<Accessory: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        #if os(iOS)
        ViewThatFits(in: .horizontal) {
            horizontalLayout
                .fixedSize(horizontal: true, vertical: false)
            stackedLayout
        }
        #else
        horizontalLayout
        #endif
    }

    private var horizontalLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsRowIcon(symbol: systemImage, tint: tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SettingsRowIcon(symbol: systemImage, tint: tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            accessory
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

private struct AccountSecurityStatusRow<Accessory: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let showsProgress: Bool
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        showsProgress: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.showsProgress = showsProgress
        self.accessory = accessory()
    }

    var body: some View {
        AccountSecuritySettingsRow(
            title: title,
            detail: detail,
            systemImage: systemImage,
            tint: tint
        ) {
            if showsProgress { ProgressView().controlSize(.small) }
            accessory
        }
    }
}

private extension AccountSecurityStatusRow where Accessory == EmptyView {
    init(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        showsProgress: Bool = false
    ) {
        self.init(
            title: title,
            detail: detail,
            systemImage: systemImage,
            tint: tint,
            showsProgress: showsProgress,
            accessory: { EmptyView() }
        )
    }
}
