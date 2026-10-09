import PlainpostAccountRuntime
import PlainpostNodeTransport
import SwiftUI

/// A mail account the Sync Node owns: read-only, since the Node manages its sign-in and sync.
struct NodeAccountSettingsPage: View {
    let account: NodeMailAccount

    var body: some View {
        Form {
            // The same header as a direct account's page.
            Section { header }
            Section {
                LabeledContent("Status", value: Self.status(account.state))
            } footer: {
                if let footer = Self.footer(account.state) {
                    Text(footer)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.title)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.providerIdentity)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(account.providerKind == "gmail" ? "Gmail" : "IMAP") · Via Sync Node")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The same on both platforms. There's no Mac re-sign-in for Node accounts yet, so the
    /// attention copy promises nothing more than reconnecting.
    static func footer(_ state: NodeSyncMailAccountState) -> String? {
        switch state {
        case .ready: "Your Sync Node signs in to this account and keeps it synced."
        case .degraded: nil
        case .authenticationRequired: "Your Sync Node can't sign in to this account, so it isn't syncing."
        }
    }

    static func status(_ state: NodeSyncMailAccountState) -> String {
        switch state {
        case .ready: "Ready"
        case .degraded: "Sync delayed"
        case .authenticationRequired: "Needs attention"
        }
    }
}
