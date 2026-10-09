import PlainpostAccountRuntime
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import SwiftUI

/// One mail account in the settings root: a direct account, or a Node account when a Sync Node
/// owns mail. Node accounts replace the direct rows.
struct SettingsAccountRow: Identifiable, Equatable {
    let destination: PlainpostSettingsDestination
    let title: String
    let subtitle: String
    let needsAttention: Bool
    var id: PlainpostSettingsDestination { destination }

    /// Node mailbox IDs are 32 raw bytes, so Node rows are identified by their provider address
    /// (the same key the iOS mail-account switcher uses).
    var accessibilityIdentifier: String {
        switch destination {
        case .section(let section): SettingsRootList.identifier(section)
        case .account(let id): "settings.account.\(id.rawValue)"
        case .nodeAccount: "settings.node-account.\(title)"
        }
    }

    static func rows(
        directAccounts: [Account],
        needsReauthorization: (AccountID) -> Bool,
        authenticationMethod: (AccountID) -> AccountAuthenticationMethod?,
        nodeAccounts: [NodeMailAccount],
        viaSyncNode: (AccountID) -> Bool = { _ in false }
    ) -> [SettingsAccountRow] {
        if !nodeAccounts.isEmpty {
            return nodeAccounts.map {
                SettingsAccountRow(destination: .nodeAccount($0.logicalMailboxID), title: $0.providerIdentity,
                                   subtitle: "Via Sync Node", needsAttention: $0.state != .ready)
            }
        }
        return directAccounts.map { account in
            SettingsAccountRow(
                destination: .account(account.id),
                title: account.email.rawValue,
                subtitle: viaSyncNode(account.id)
                    ? "Via Sync Node" : providerName(account, method: authenticationMethod(account.id)),
                needsAttention: needsReauthorization(account.id)
            )
        }
    }

    @MainActor
    static func rows(accountSetup: AccountSetupViewModel, host: PlainpostSettingsHost) -> [SettingsAccountRow] {
        rows(
            directAccounts: accountSetup.accounts,
            needsReauthorization: accountSetup.needsReauthorization,
            authenticationMethod: { accountSetup.accountAuthentications[$0]?.method },
            nodeAccounts: host.nodeMailAccounts,
            viaSyncNode: { accountSetup.syncNodeSignIns[$0] != nil }
        )
    }

    /// The page Settings should show for `current` given the account rows now listed.
    ///
    /// - A nil selection, or an account page whose account is gone, falls back to the first
    ///   account with a page here (or Add Account when there are none).
    /// - `promotingAddAccount` moves a default Add Account selection to the first account once
    ///   accounts arrive; the caller passes it only when it chose Add Account itself.
    static func reconciledDestination(
        current: PlainpostSettingsDestination?,
        rows: [SettingsAccountRow],
        promotingAddAccount: Bool = false
    ) -> PlainpostSettingsDestination {
        let fallback = rows.first?.destination ?? .section(.accounts)
        guard let current else { return fallback }
        switch current {
        case .account, .nodeAccount:
            return rows.contains { $0.destination == current } ? current : fallback
        case .section(.accounts) where promotingAddAccount:
            return fallback
        case .section:
            return current
        }
    }

    static func providerName(_ account: Account, method: AccountAuthenticationMethod?) -> String {
        if method == .microsoftOAuth || MailProviderProfile.microsoft.matches(account) { return "Microsoft" }
        if MailProviderProfile.gmail.matches(account) { return "Gmail" }
        if MailProviderProfile.icloud.matches(account) { return "iCloud" }
        return "IMAP"
    }
}

/// How a settings row opens its page.
enum SettingsRootListNavigation: Equatable {
    /// Rows are tagged and drive the `selection` binding: the Mac sidebar and the iPad split
    /// view column.
    case selection
    /// Rows push `MobileRoute.settingsDestination` onto the iPhone navigation stack.
    case push
}

/// The settings root. Accounts come first, then the Mail, Plainpost and Troubleshooting groups.
struct SettingsRootList: View {
    @Environment(\.plainpostSettingsHost) private var settingsHost
    @Binding var selection: PlainpostSettingsDestination?
    let accountRows: [SettingsAccountRow]
    let navigation: SettingsRootListNavigation

    init(
        selection: Binding<PlainpostSettingsDestination?>,
        accountRows: [SettingsAccountRow],
        navigation: SettingsRootListNavigation
    ) {
        self._selection = selection
        self.accountRows = accountRows
        self.navigation = navigation
    }

    var body: some View {
        switch navigation {
        case .selection:
            List(selection: $selection) { groups }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
        case .push:
            List { groups }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
        }
    }

    @ViewBuilder private var groups: some View {
        ForEach(PlainpostSettingsGroup.allCases) { group in
            Section {
                if group == .accounts {
                    ForEach(accountRows) { row in
                        link(row.destination, id: row.accessibilityIdentifier) {
                            SettingsAccountRowLabel(row: row)
                        }
                    }
                    link(.section(.accounts), id: Self.identifier(.accounts)) {
                        Label(PlainpostSettingsSection.accounts.title, systemImage: PlainpostSettingsSection.accounts.systemImage)
                    }
                }
                ForEach(group.sections) { section in
                    link(.section(section), id: Self.identifier(section)) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            } header: {
                if let title = group.title { Text(title) }
            }
        }
    }

    @ViewBuilder
    private func link<L: View>(
        _ destination: PlainpostSettingsDestination,
        id: String,
        @ViewBuilder label: () -> L
    ) -> some View {
        switch navigation {
        case .selection:
            // Not `Optional(destination)`: a List with an optional selection matches tags of the
            // wrapped type, and otherwise falls back to the ForEach ID, which only account rows share.
            label().tag(destination).accessibilityIdentifier(id)
        case .push:
            NavigationLink(value: MobileRoute.settingsDestination(destination)) { label() }
                .accessibilityIdentifier(id)
        }
    }

    static func identifier(_ section: PlainpostSettingsSection) -> String {
        "settings.section.\(section.rawValue)"
    }
}

private struct SettingsAccountRowLabel: View {
    let row: SettingsAccountRow

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).lineLimit(1)
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "envelope")
            }
            Spacer(minLength: 0)
            if row.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs attention")
            }
        }
    }
}

public extension PlainpostSettingsDestination {
    /// The page title: the section title, or the address of the selected account.
    @MainActor
    func title(accountSetup: AccountSetupViewModel, nodeAccounts: [NodeMailAccount]) -> String {
        switch self {
        case .section(let section):
            section.title
        case .account(let id):
            accountSetup.accounts.first { $0.id == id }?.email.rawValue ?? PlainpostSettingsSection.accounts.title
        case .nodeAccount(let id):
            nodeAccounts.first { $0.logicalMailboxID == id }?.providerIdentity ?? PlainpostSettingsSection.accounts.title
        }
    }
}
