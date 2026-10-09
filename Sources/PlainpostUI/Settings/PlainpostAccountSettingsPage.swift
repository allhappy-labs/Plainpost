import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Readable copy for the Plainpost Account and Sync Node pages: no raw platform, status or
/// category values and no ISO timestamps. Shared with the iOS app target.
public enum AccountSecurityPresentation {
    /// The device name to save when an edit ends (Return, focus loss, or leaving the page),
    /// or nil when it matches what was last saved, so an untouched field never re-saves.
    public static func deviceLabelToSave(_ label: String, lastSaved: String) -> String? {
        label == lastSaved ? nil : label
    }

    @MainActor
    public static func deviceName(_ device: AccountLifecycleDeviceSummary) -> String {
        if let label = device.localLabel, !label.isEmpty { return label }
        switch device.platform {
        case .macos: return device.isCurrentDevice ? "This Mac" : "Mac"
        case .ios: return device.isCurrentDevice ? thisIOSDevice : "iPhone or iPad"
        case .syncNode: return "Sync Node"
        }
    }

    /// The tag beside a trusted device's name: "This Mac" or "This iPhone" for the current
    /// device, only when a custom name replaced that wording.
    @MainActor
    public static func deviceTag(_ device: AccountLifecycleDeviceSummary) -> String? {
        guard device.isCurrentDevice, let label = device.localLabel, !label.isEmpty else { return nil }
        switch device.platform {
        case .macos: return "This Mac"
        case .ios: return thisIOSDevice
        case .syncNode: return nil
        }
    }

    /// A trusted device row's second line: "Active · Last activity 2 hours ago".
    public static func deviceDetail(_ device: AccountLifecycleDeviceSummary, now: Date = Date()) -> String {
        [
            deviceStatus(device.status),
            relative(device.lastSecurityEventAt, now: now).map { "Last activity \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    public static func deviceSymbol(_ platform: AccountPlatform) -> String {
        switch platform {
        case .macos: "desktopcomputer"
        case .ios: "iphone"
        case .syncNode: "server.rack"
        }
    }

    public static func deviceStatus(_ status: String) -> String {
        switch status {
        case "active": "Active"
        case "suspended": "Suspended"
        case "revoked": "Revoked"
        case "pending": "Pending"
        default: "Needs attention"
        }
    }

    public static func eventTitle(_ category: AccountSecurityEventCategory) -> String {
        switch category {
        case .deviceAdded: "New device added"
        case .deviceRevoked: "Device revoked"
        case .deviceSuspended: "Device suspended"
        case .accountRecovered: "Account recovered"
        case .accountDeleted: "Account deleted"
        case .cleanupAcknowledged: "Device cleanup finished"
        }
    }

    /// "2 hours ago", in the user's locale; nil when the timestamp doesn't parse.
    public static func relative(_ iso8601: String?, now: Date = Date()) -> String? {
        guard let iso8601 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: iso8601) ?? ISO8601DateFormatter().date(from: iso8601) else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }

    public static func host(_ origin: String?) -> String? {
        origin.flatMap(URL.init(string:))?.host()
    }

    /// The current iOS device's name, without "iPhone" on an iPad.
    @MainActor
    private static var thisIOSDevice: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #else
        "This iPhone or iPad"
        #endif
    }
}

/// The Plainpost Account page: trusted devices, security activity and account deletion. The
/// iOS app supplies its own page through `PlainpostSettingsHost.plainpostAccountPage`.
struct PlainpostAccountSettingsPage: View {
    let accountSessionModel: AccountSessionViewModel?
    @Environment(\.plainpostSettingsHost) private var host

    var body: some View {
        if let accountSessionModel, let securityModel = accountSessionModel.securityModel {
            SettingsPage(.plainpostAccount) {
                AccountSecuritySettingsPanel(session: accountSessionModel, model: securityModel)
            }
        } else if let page = host.plainpostAccountPage {
            page()
        } else {
            SettingsPage(.plainpostAccount) {
                Section {
                    Button("Connect Plainpost Account") { host.connectPlainpostAccount?() }
                        .disabled(host.connectPlainpostAccount == nil)
                } footer: {
                    Text("Use your Plainpost account to add a Sync Node and manage trusted devices.")
                }
            }
        }
    }
}
