#if os(iOS)
import SwiftUI

/// First-run account setup: today's setup flow, full-screen, with no Back to a mailbox that
/// doesn't exist yet. Sub-project 2 redesigns it.
struct MobileAccountSetupScreen: View {
    let session: MailSession
    @ObservedObject var environment: MobileMailEnvironment
    @ObservedObject var accountSetup: AccountSetupViewModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if accountSetup.selectedProvider == nil {
                    Text("Connect an account")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                AccountSetupWorkspace(viewModel: accountSetup)
            }
            .navigationTitle("Account Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // There are no Mailboxes yet, so Settings (Plainpost Account, Sync Node) is
                // reached from here.
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: MobileRoute.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("account-setup.settings")
                }
            }
            .navigationDestination(for: MobileRoute.self) { route in
                switch route {
                case .settings:
                    MobileSettingsListScreen(environment: environment, accountSetup: accountSetup)
                case let .settingsDestination(destination):
                    MobileSettingsDestinationScreen(session: session, destination: destination)
                default:
                    EmptyView()
                }
            }
        }
    }
}
#endif
