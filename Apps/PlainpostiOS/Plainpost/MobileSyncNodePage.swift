import PlainpostAccountRuntime
import PlainpostUI
import SwiftUI
import UIKit

/// The iOS Sync Node settings page: the shared `SyncNodePageContent` over
/// `MobileAccountModel`'s enrollment models. It always shows the overview, so it is never
/// blank, including before the enrollment model loads or when it can't.
struct MobileSyncNodePage: View {
    @ObservedObject var account: MobileAccountModel
    let nodeSettings: SyncNodeSettingsViewModel?
    /// The Server Setup file is a bearer capability, so it travels only by AirDrop into this
    /// device's own files.
    @MainActor
    static var serverSetupTransferGuidance: String {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return "Transfer the Server Setup file only by AirDrop to On My \(device), and delete that file after the Sync Node connects."
    }

    var body: some View {
        Form {
            // Only the owner's own connection renders (`presentableSyncNodeEnrollmentModel`);
            // one kept for another account shows the owner-required message alone.
            SyncNodePageContent(
                isSignedIn: account.presentation.allowsMailbox,
                // Unreachable today: the account root replaces Mail (and Settings) whenever
                // the presentation doesn't allow the mailbox. Kept so the page never offers
                // sign-in for an account that exists.
                isAccountUnavailable: account.presentation != .signInRequired,
                awaitsOwner: account.syncNodeEnrollmentAwaitsOwner,
                enrollment: account.presentableSyncNodeEnrollmentModel,
                load: account.syncNodeEnrollmentLoadPresentation,
                importModel: account.syncNodeBootstrapImportModel,
                nodeSettings: nodeSettings,
                actions: SyncNodePageActions(
                    retryLoad: { account.retrySyncNodeEnrollment() },
                    completeFileImport: account.handleSyncNodeBootstrapFileImporter,
                    changeServerAddress: account.updateSyncNodeServerOrigin,
                    importProfile: account.importSyncNodeBootstrapProfile,
                    setupNote: Self.serverSetupTransferGuidance
                )
            )
        }
        .syncNodeEnrollmentLifecycle(account.presentableSyncNodeEnrollmentModel)
        .task { account.prepareSyncNodeEnrollment() }
    }
}
