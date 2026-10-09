import SwiftUI

/// Which single action a Contacts authorization state offers, if any.
enum ContactsAccessAction: Equatable {
    case allow, refresh, openSettings

    static func action(for authorization: ContactDirectoryAuthorization) -> ContactsAccessAction? {
        switch authorization {
        case .notDetermined: .allow
        case .authorized, .limited: .refresh
        case .denied, .restricted: .openSettings
        case .unavailable: nil
        }
    }
}

/// The Privacy settings page: mail privacy (remote images, site icons) and the Apple
/// Contacts directory. Replaces the old Privacy panel, which also showed a static,
/// never-changing "always on" status list that carried no information.
struct PrivacySettingsPage: View {
    @AppStorage(PlainpostPrivacyPreference.blockRemoteImagesKey) private var blockRemoteImages = true
    @AppStorage(SiteIconPreference.fetchEnabledKey) private var fetchSiteIcons = true
    @Environment(\.mailSiteIconDirectory) private var siteIconDirectory
    @Environment(\.mailContactDirectorySnapshot) private var contacts
    @Environment(\.mailContactDirectoryModel) private var contactModel
    @Environment(\.openURL) private var openURL
    @State private var isClearing = false

    var body: some View {
        SettingsPage(.privacy) {
            Section {
                Toggle("Block remote images", isOn: $blockRemoteImages)
                Toggle("Load site icons", isOn: $fetchSiteIcons)
                Button("Clear Site Icon Cache") {
                    isClearing = true
                    Task {
                        await siteIconDirectory?.clear()
                        isClearing = false
                    }
                }
                .disabled(isClearing)
            } header: {
                Text("Mail")
            } footer: {
                Text("Site icons are fetched from the sender's domain.")
            }
            Section {
                LabeledContent("Apple Contacts", value: contacts.authorization.settingsLabel)
                    // One element: the name as its label, the state as its value.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Apple Contacts")
                    .accessibilityValue(contacts.authorization.settingsLabel)
                switch ContactsAccessAction.action(for: contacts.authorization) {
                case .allow?:
                    Button("Allow Access") { Task { await contactModel?.requestAccessAndRefresh() } }
                case .refresh?:
                    Button("Refresh") { Task { await contactModel?.refresh() } }
                case .openSettings?:
                    Button("Open Settings") { openURL(Self.contactsSettingsURL) }
                case nil:
                    EmptyView()
                }
            } header: {
                Text("Contacts")
            } footer: {
                Text("Contact details stay on this device.")
            }
        }
    }

    private static var contactsSettingsURL: URL {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
        #else
        URL(string: "app-settings:")!
        #endif
    }
}
