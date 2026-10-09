import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
public final class NotificationPermissionModel: ObservableObject {
    static let calloutDismissedKey = "Plainpost.notifications.enablementCalloutDismissed"

    @Published private(set) var status: LocalNotificationAuthorization = .unavailable
    @Published private var calloutDismissed: Bool

    private let center: any SystemNotificationCenterAdapting
    private let defaults: UserDefaults

    init(
        center: any SystemNotificationCenterAdapting,
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        calloutDismissed = defaults.bool(forKey: Self.calloutDismissedKey)
    }

    #if canImport(UserNotifications)
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(center: SystemUserNotificationCenterAdapter(), defaults: defaults)
    }
    #endif

    var shouldShowEnablementCallout: Bool {
        newMailPreferenceEnabled && status == .notDetermined && !calloutDismissed
    }

    var settingsLabel: String {
        switch status {
        case .authorized: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not requested"
        case .unavailable: "Temporarily unavailable"
        }
    }

    func refresh() async {
        status = await center.authorizationStatus()
    }

    func enable() async {
        let current = await center.authorizationStatus()
        status = current
        switch current {
        case .authorized:
            defaults.set(true, forKey: PlainpostNotificationPreference.newMailKey)
            calloutDismissed = true
            defaults.set(true, forKey: Self.calloutDismissedKey)
        case .notDetermined:
            do {
                let result = try await center.requestAuthorization()
                status = result
                if result == .authorized {
                    defaults.set(true, forKey: PlainpostNotificationPreference.newMailKey)
                }
                calloutDismissed = true
                defaults.set(true, forKey: Self.calloutDismissedKey)
            } catch {
                status = .unavailable
            }
        case .denied, .unavailable:
            break
        }
    }

    func dismissCallout() {
        calloutDismissed = true
        defaults.set(true, forKey: Self.calloutDismissedKey)
    }

    private var newMailPreferenceEnabled: Bool {
        guard defaults.object(forKey: PlainpostNotificationPreference.newMailKey) != nil else {
            return true
        }
        return defaults.bool(forKey: PlainpostNotificationPreference.newMailKey)
    }
}

private struct NotificationPermissionModelKey: EnvironmentKey {
    static let defaultValue: NotificationPermissionModel? = nil
}

extension EnvironmentValues {
    var notificationPermissionModel: NotificationPermissionModel? {
        get { self[NotificationPermissionModelKey.self] }
        set { self[NotificationPermissionModelKey.self] = newValue }
    }
}

#if os(macOS) || os(iOS)
private struct NotificationPermissionModifier: ViewModifier {
    @ObservedObject var model: NotificationPermissionModel

    func body(content: Content) -> some View {
        content
            .environment(\.notificationPermissionModel, model)
            .task { await model.refresh() }
            .onReceive(
                NotificationCenter.default.publisher(for: Self.didBecomeActive)
            ) { _ in
                Task { await model.refresh() }
            }
    }

    // The user may change the permission in System Settings and come back.
    #if os(macOS)
    private static let didBecomeActive = NSApplication.didBecomeActiveNotification
    #else
    private static let didBecomeActive = UIApplication.didBecomeActiveNotification
    #endif
}

public extension View {
    func notificationPermission(
        _ model: NotificationPermissionModel
    ) -> some View {
        modifier(NotificationPermissionModifier(model: model))
    }
}
#endif
