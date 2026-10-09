import Foundation
import PlainpostCore
import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

/// What the "Open Plainpost at login" setting shows for a registrar status.
public struct PlainpostLoginItemPresentation: Equatable, Sendable {
    public static let approvalHint = "Allow Plainpost in System Settings → General → Login Items"

    public let hint: String?
    public let showsLoginItemsSettingsButton: Bool
    public let isToggleEnabled: Bool

    public init(status: PlainpostLoginItemRegistrar.Status, isEnabled: Bool) {
        switch status {
        case .requiresApproval where isEnabled:
            hint = Self.approvalHint
            showsLoginItemsSettingsButton = true
            isToggleEnabled = true
        case .unavailable:
            hint = "Available in the installed Plainpost app."
            showsLoginItemsSettingsButton = false
            isToggleEnabled = false
        case .enabledUntilQuit:
            hint = "Plainpost removes itself from Login Items the next time it opens at login."
            showsLoginItemsSettingsButton = false
            isToggleEnabled = true
        case .enabled, .disabled, .requiresApproval:
            hint = nil
            showsLoginItemsSettingsButton = false
            isToggleEnabled = true
        }
    }
}

/// Owns the "Open Plainpost at login" preference and keeps the bundled
/// login item in step with it.
@MainActor
public final class PlainpostLoginItemModel: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var status: PlainpostLoginItemRegistrar.Status

    private let registrar: PlainpostLoginItemRegistrar
    private let defaults: UserDefaults
    private let openLoginItemsSettingsAction: @MainActor () -> Void
    private var tail: Task<Void, Never>?

    public init(
        registrar: PlainpostLoginItemRegistrar,
        defaults: UserDefaults = .standard,
        openLoginItemsSettings: @escaping @MainActor () -> Void
    ) {
        self.registrar = registrar
        self.defaults = defaults
        openLoginItemsSettingsAction = openLoginItemsSettings
        isEnabled = PlainpostLoginLaunch.openAtLogin(in: defaults)
        status = registrar.currentStatus()
    }

    public var presentation: PlainpostLoginItemPresentation {
        PlainpostLoginItemPresentation(status: status, isEnabled: isEnabled)
    }

    /// Applies the stored preference. Calls run one at a time, in order.
    public func reconcile() async {
        let previous = tail
        let registrar = registrar
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let status = await registrar.reconcile(enabled: self.isEnabled)
            self.status = status
        }
        tail = task
        await task.value
    }

    public func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: PlainpostLoginLaunch.preferenceKey)
        isEnabled = enabled
        await reconcile()
    }

    public func openLoginItemsSettings() {
        openLoginItemsSettingsAction()
    }

    static let registeredInstallKey = "Plainpost.loginItemRegisteredInstall"

#if os(macOS)
    /// `SMAppService.agent` for the bundled login item plist. The status
    /// stays `.notFound` until the first registration, so it reads as off.
    public static func production(
        appBundleURL: URL = Bundle.main.bundleURL,
        isLoginLaunch: Bool
    ) -> PlainpostLoginItemModel {
        let plistName = PlainpostLoginLaunch.plistName
        let installKey = Self.registeredInstallKey
        let registrar = PlainpostLoginItemRegistrar(
            appBundleURL: appBundleURL,
            installedLocations: PlainpostLoginItemRegistrar.defaultInstalledLocations(),
            currentProcessIsLoginItem: isLoginLaunch,
            registrationStamp: .init(
                current: { PlainpostLoginLaunch.bundleFingerprint(appBundleURL: appBundleURL) },
                load: { UserDefaults.standard.string(forKey: installKey) },
                save: { install in UserDefaults.standard.set(install, forKey: installKey) }
            ),
            register: { try SMAppService.agent(plistName: plistName).register() },
            unregister: { try await SMAppService.agent(plistName: plistName).unregister() },
            status: {
                switch SMAppService.agent(plistName: plistName).status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                case .notRegistered, .notFound: .disabled
                @unknown default: .disabled
                }
            }
        )
        return PlainpostLoginItemModel(
            registrar: registrar,
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }
#endif
}

private struct PlainpostLoginItemModelKey: EnvironmentKey {
    static let defaultValue: PlainpostLoginItemModel? = nil
}

extension EnvironmentValues {
    public var plainpostLoginItemModel: PlainpostLoginItemModel? {
        get { self[PlainpostLoginItemModelKey.self] }
        set { self[PlainpostLoginItemModelKey.self] = newValue }
    }
}

#if os(macOS)
public struct PlainpostLoginItemSettingsGroup: View {
    @ObservedObject var model: PlainpostLoginItemModel

    public init(model: PlainpostLoginItemModel) { self.model = model }

    public var body: some View {
        let presentation = model.presentation
        VStack(alignment: .leading, spacing: 8) {
            SystemSettingsGroup("Background") {
                SettingsToggleRow(
                    title: "Open Plainpost at login",
                    detail: "Start hidden in the menu bar so new-mail notifications keep arriving with no window open.",
                    symbol: "power",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { enabled in Task { await model.setEnabled(enabled) } }
                    ),
                    showsSeparator: presentation.showsLoginItemsSettingsButton
                )
                .disabled(!presentation.isToggleEnabled)

                if presentation.showsLoginItemsSettingsButton {
                    Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                }
            }

            Text(presentation.hint ?? "Keeps notifications arriving with no window open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .accessibilityIdentifier("settings.login-item.hint")
        }
        .task { await model.reconcile() }
    }
}
#endif
