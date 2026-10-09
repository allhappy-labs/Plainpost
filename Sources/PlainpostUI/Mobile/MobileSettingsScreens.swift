#if os(iOS)
import SwiftUI

/// The iPhone Settings list: the mail account rows and Add Account first, then the Mail,
/// Plainpost and Troubleshooting groups. Each row pushes its page, except another local
/// account's row, which switches to that account first (the host then opens its page).
struct MobileSettingsListScreen: View {
    @Environment(\.plainpostSettingsHost) private var settingsHost
    @ObservedObject var environment: MobileMailEnvironment
    @ObservedObject var accountSetup: AccountSetupViewModel

    var body: some View {
        SettingsRootList(
            selection: .constant(nil),
            accountRows: SettingsAccountRow.rows(accountSetup: accountSetup, host: settingsHost),
            navigation: .push
        )
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        // A held switch's status (`mail-account.switch-hold`) shows on the screen where the
        // switch was made.
        .safeAreaInset(edge: .top, spacing: 0) { environment.banner }
        // Sync Node accounts read "Via Sync Node".
        .task { await accountSetup.refreshSyncNodeSignIns() }
    }
}

/// One Settings page (a section or an account) under a native title and without the mailbox
/// toolbar.
struct MobileSettingsDestinationScreen: View {
    @Environment(\.plainpostSettingsHost) private var settingsHost
    let session: MailSession
    let destination: PlainpostSettingsDestination
    @ObservedObject private var inboxSnapshot: InboxViewModelSnapshotStore
    @ObservedObject private var accountSetup: AccountSetupViewModel

    init(session: MailSession, destination: PlainpostSettingsDestination) {
        self.session = session
        self.destination = destination
        _inboxSnapshot = ObservedObject(wrappedValue: session.inboxSnapshot)
        _accountSetup = ObservedObject(wrappedValue: session.accountSetup)
    }

    var body: some View {
        SettingsDetailWorkspace(
            destination: destination,
            accountSetup: session.accountSetup,
            accountSessionModel: session.accountSessionModel,
            nodeSettings: session.nodeSettings,
            aiProviderSettings: session.aiProviderSettings,
            translationSettings: session.translationSettings,
            aiIndexStatus: inboxSnapshot.model.aiIndexStatus,
            auditLog: session.auditLog,
            mailRules: session.mailRules,
            mailLabels: session.mailLabels,
            maintenance: session.maintenance,
            searchIndexRebuild: session.searchIndexRebuild
        )
        .navigationTitle(destination.title(accountSetup: accountSetup, nodeAccounts: settingsHost.nodeMailAccounts))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
