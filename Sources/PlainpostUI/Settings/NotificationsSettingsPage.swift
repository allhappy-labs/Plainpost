import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The Notifications settings page: new-mail alerts, approval and sync-failure alerts, the
/// system notification permission and (macOS only) Open at Login. Mail-sync-completed alerts are gone;
/// `PlainpostNotificationPreference.isEnabled` never posts them.
struct NotificationsSettingsPage: View {
    @AppStorage(PlainpostNotificationPreference.newMailKey) private var newMail = true
    @AppStorage(PlainpostNotificationPreference.newMailPreviewKey) private var newMailPreview = true
    @AppStorage(PlainpostNotificationPreference.notificationSoundsKey) private var sounds = true
    @AppStorage(PlainpostNotificationPreference.pendingSendApprovalsKey) private var approvals = true
    @AppStorage(PlainpostNotificationPreference.syncFailuresKey) private var syncFailures = true
    @Environment(\.plainpostSettingsHost) private var host
    @Environment(\.notificationPermissionModel) private var permission
    #if os(macOS)
    @Environment(\.plainpostLoginItemModel) private var loginItem
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        SettingsPage(.notifications) {
            #if os(macOS)
            Section {
                LabeledContent("macOS notifications") {
                    HStack {
                        Text(permission?.settingsLabel ?? "Temporarily unavailable")
                        if permission?.status != .authorized {
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                    openURL(url)
                                }
                            }
                        }
                    }
                }
            }
            #elseif os(iOS)
            if let permission {
                IOSNotificationPermissionSection(model: permission)
            }
            #endif
            Section("New Mail") {
                Toggle("New messages", isOn: newMailBinding)
                if let pushRows = host.pushNotificationRows {
                    pushRows()
                } else {
                    Toggle("Show preview", isOn: $newMailPreview).disabled(!newMail)
                }
                Toggle("Sounds", isOn: $sounds).disabled(!newMail && !approvals && !syncFailures)
            }
            Section("Alerts") {
                Toggle("Send approvals", isOn: $approvals)
                Toggle("Sync failures", isOn: $syncFailures)
            }
            #if os(macOS)
            if let loginItem {
                PlainpostLoginItemSettingsGroup(model: loginItem)
            }
            #endif
        }
    }

    private var newMailBinding: Binding<Bool> {
        Binding(get: { newMail }, set: { enabled in
            newMail = enabled
            if enabled, let permission { Task { await permission.enable() } }
        })
    }
}

#if os(iOS)
/// Plainpost asks for the permission only when the user taps Allow (or turns New messages
/// on); a denied permission can only be changed in the Settings app.
private struct IOSNotificationPermissionSection: View {
    @ObservedObject var model: NotificationPermissionModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            switch model.status {
            case .notDetermined:
                Button("Allow Notifications") { Task { await model.enable() } }
            case .denied:
                LabeledContent("Notifications", value: model.settingsLabel)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            case .authorized, .unavailable:
                LabeledContent("Notifications", value: model.settingsLabel)
            }
        } footer: {
            Text("Plainpost checks for new mail in the background when iOS allows it, so an alert can arrive a while after the message.")
        }
    }
}
#endif
