import PlainpostCore
import PlainpostDB
import SwiftUI

/// One direct mail account's settings: name and sign-in, what syncs, server settings for plain
/// IMAP accounts, and removal.
struct AccountSettingsPage: View {
    let accountID: AccountID
    @ObservedObject var viewModel: AccountSetupViewModel
    @Environment(\.plainpostDownloadCompleteHistory) private var downloadCompleteHistory
    @Environment(\.plainpostHistoryDownloadStatus) private var historyDownloadStatus
    @Environment(\.plainpostHistoryDownloadAccountID) private var historyDownloadAccountID
    @Environment(\.plainpostSettingsHost) private var host
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDeletion = false
    @State private var showsPasswordSheet = false
    /// The name being edited, kept on the page so it is saved to this page's account even after
    /// another page has taken the shared selection.
    @State private var name = ""
    @State private var isNameLoaded = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Section { header }
            if viewModel.selectedAccountNeedsReauthorization {
                Section {
                    OAuthReauthorizationBanner(viewModel: viewModel, enterPassword: { showsPasswordSheet = true })
                }
            }
            if let syncNodeSignIn {
                syncNodeSection(syncNodeSignIn)
            }
            Section("Account") {
                TextField("Name", text: $name)
                    .focused($isNameFocused)
                    .onSubmit(saveName)
                // A Sync Node account's sign-in is its Sync Node section's.
                if syncNodeSignIn == nil { signInRow }
                if viewModel.accountSettingsSaveFailed, let message = viewModel.accountSettingsMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("Sync") {
                LabeledContent("Status", value: AccountHistoryDownloadScope.status(
                    lastSyncError: viewModel.lastSyncError,
                    hostStatus: historyDownloadStatus,
                    pageAccountID: accountID,
                    hostAccountID: historyDownloadAccountID,
                    syncStatusMessage: viewModel.syncStatusMessage
                ))
                Picker("Keep on this device", selection: keepOnDevice) {
                    ForEach(KeepOnDeviceOption.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Instant updates", isOn: Binding(
                    get: { viewModel.realTimeMonitoringEnabled },
                    set: { applySync(realTime: $0) }
                ))
                NavigationLink {
                    AccountFoldersPage(viewModel: viewModel)
                } label: {
                    LabeledContent("Folders", value: folderSummary)
                }
                // It attaches this page's account.
                if syncNodeSignIn == nil, let useSyncNode = host.useSyncNodeForAccount {
                    Button("Use Sync Node for This Account") { useSyncNode(accountID) }
                        .accessibilityIdentifier("local-mail.attach-node")
                }
            }
            if syncNodeSignIn == nil, !viewModel.isSelectedAccountOAuth, !viewModel.isSelectedAccountICloud,
               !viewModel.isSelectedAccountGmail {
                Section {
                    NavigationLink("Server Settings") { AccountServerSettingsPage(viewModel: viewModel) }
                }
            }
            AccountDeletionDangerSection(viewModel: viewModel, requestConfirmation: { confirmsDeletion = true })
        }
        .formStyle(.grouped)
        .task(id: accountID) {
            viewModel.selectAccount(id: accountID)
            name = viewModel.accounts.first { $0.id == accountID }?.displayName ?? viewModel.displayName
            isNameLoaded = true
            // Settings may open long after the service marked a grant refused.
            viewModel.refreshAccountAuthentications()
            viewModel.refreshMailboxSyncStatuses()
            await viewModel.refreshSyncNodeSignIns()
        }
        .onChange(of: isNameFocused) { _, focused in
            if !focused { saveName() }
        }
        // Leaving the page (another sidebar row, Back) keeps the edit.
        .onDisappear(perform: saveName)
        .onChange(of: historyDownloadStatus) { _, _ in
            viewModel.refreshMailboxSyncStatuses()
        }
        .onReceive(MailStoreChangeSignal.mainThreadChanges) { scope in
            guard scope == .operations else { return }
            Task { @MainActor in viewModel.refreshMailboxSyncStatuses() }
        }
        .onChange(of: viewModel.accounts.map(\.id)) { _, ids in
            // A pushed page (iPhone) leaves once its account is removed; selection-driven hosts
            // reconcile the selection instead.
            if isPresented, !ids.contains(accountID) { dismiss() }
        }
        .alert(AccountDeletionConfirmation.title(email: viewModel.email), isPresented: $confirmsDeletion) {
            AccountDeletionConfirmationActions(viewModel: viewModel)
        } message: {
            Text(AccountDeletionConfirmation.message(email: viewModel.email))
        }
        .sheet(isPresented: $showsPasswordSheet) {
            NavigationStack {
                Form { CredentialReplacementSection(viewModel: viewModel) }
                    .formStyle(.grouped)
                    .navigationTitle("Change Password")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showsPasswordSheet = false }
                        }
                    }
            }
        }
    }

    private var account: Account? {
        viewModel.accounts.first { $0.id == accountID }
    }

    /// Set for a Sync Node account: whether this iPhone can keep it syncing while its Node
    /// is away.
    private var syncNodeSignIn: SyncNodeSignIn? { viewModel.syncNodeSignIns[accountID] }

    private func syncNodeSection(_ signIn: SyncNodeSignIn) -> some View {
        Section {
            switch signIn {
            case .signedIn:
                Label("Signed in on this iPhone", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("account.sync-node.signed-in")
            case .googleAvailable:
                Button("Sign in to Keep Syncing") {
                    Task { await viewModel.reauthorizeGmail(accountID: accountID) }
                }
                .disabled(viewModel.reauthorizingAccountID != nil || !viewModel.isGoogleSignInAvailable)
                .accessibilityIdentifier("account.sync-node.sign-in")
                if let message = viewModel.gmailReauthorizationMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            case .unavailable:
                LabeledContent("Syncs through", value: "Your Sync Node")
            }
        } header: {
            Text("Sync Node")
        } footer: {
            Text(Self.syncNodeFooter(signIn))
        }
    }

    static func syncNodeFooter(_ signIn: SyncNodeSignIn) -> String {
        switch signIn {
        case .signedIn:
            "Your Sync Node syncs this account. When it can't be reached, this iPhone keeps the account syncing with your sign-in."
        case .googleAvailable:
            "Your Sync Node syncs this account. Sign in with Google on this iPhone to keep it syncing when your Sync Node can't be reached."
        case .unavailable:
            "Your Sync Node syncs this account. When it can't be reached, your changes wait on this iPhone and go once it's back."
        }
    }

    private var providerName: String {
        guard let account else { return "IMAP" }
        return SettingsAccountRow.providerName(account, method: viewModel.accountAuthentications[accountID]?.method)
    }

    static func providerSymbol(_ providerName: String) -> String {
        switch providerName {
        case "Gmail": "g.circle.fill"
        case "Microsoft": "m.square.fill"
        case "iCloud": "icloud.fill"
        default: "server.rack"
        }
    }

    /// Provider icon, address and provider name: a plain row, not a page hero.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.providerSymbol(providerName))
                .font(.title)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account?.email.rawValue ?? viewModel.email)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(providerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var signInRow: some View {
        if viewModel.isSelectedAccountGoogleOAuth || viewModel.isSelectedAccountMicrosoftOAuth {
            // CredentialReplacementSection's OAuth branch renders the "Sign-in" row.
            CredentialReplacementSection(viewModel: viewModel)
        } else {
            LabeledContent("Sign-in") {
                HStack {
                    Button("Change Password…") { showsPasswordSheet = true }
                    if viewModel.isSelectedAccountGmail, viewModel.isGoogleSignInAvailable {
                        Button("Switch to Google sign-in") {
                            Task { await viewModel.reauthorizeGmail(accountID: accountID) }
                        }
                        .disabled(viewModel.reauthorizingAccountID != nil)
                        .accessibilityIdentifier("credential-replacement-google-sign-in")
                    }
                }
                // Two actions in one Form row: each button takes only its own taps.
                .buttonStyle(.borderless)
            }
        }
    }

    private func saveName() {
        guard isNameLoaded else { return }
        viewModel.saveDisplayName(name, accountID: accountID)
    }

    private var keepOnDevice: Binding<KeepOnDeviceOption> {
        Binding(
            get: {
                KeepOnDeviceOption.current(
                    downloadCompleteHistory: viewModel.downloadCompleteHistory,
                    recentMessageLimit: viewModel.recentMessageLimit
                )
            },
            set: { option in
                applySync(option: option)
                // Only start the download once the preference actually saved, for this page's
                // account.
                if option == .allMail, viewModel.downloadCompleteHistory {
                    downloadCompleteHistory?(accountID)
                }
            }
        )
    }

    private func applySync(option: KeepOnDeviceOption? = nil, realTime: Bool? = nil) {
        let option = option ?? KeepOnDeviceOption.current(
            downloadCompleteHistory: viewModel.downloadCompleteHistory,
            recentMessageLimit: viewModel.recentMessageLimit
        )
        viewModel.updateSyncPreferences(
            downloadCompleteHistory: option == .allMail,
            // Choosing All mail keeps the stored limit, so switching back restores it.
            recentMessageLimit: option.limit ?? viewModel.recentMessageLimit,
            realTimeMonitoringEnabled: realTime ?? viewModel.realTimeMonitoringEnabled
        )
    }

    private var folderSummary: String {
        let names = viewModel.availableMailboxPaths
            .filter(viewModel.isMailboxSelected)
            .map(MailboxDisplayName.name(for:))
        return names.isEmpty ? "None" : ListFormatter.localizedString(byJoining: names)
    }
}

/// The folders an account syncs, by friendly name, each with its download progress.
struct AccountFoldersPage: View {
    @ObservedObject var viewModel: AccountSetupViewModel

    var body: some View {
        Form {
            ForEach(viewModel.availableMailboxPaths, id: \.self) { path in
                Toggle(isOn: Binding(
                    get: { viewModel.isMailboxSelected(path) },
                    set: { viewModel.setMailboxSelected($0, path: path) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MailboxDisplayName.name(for: path))
                        if let status = viewModel.mailboxSyncStatuses.first(where: { $0.mailboxPath == path }),
                           let text = MailboxSyncStatusText.text(status) {
                            Text(text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(viewModel.isMailboxSyncDisabled(path: path))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Folders")
    }
}

/// Incoming and outgoing servers for a plain IMAP account.
struct AccountServerSettingsPage: View {
    @ObservedObject var viewModel: AccountSetupViewModel

    var body: some View {
        Form {
            Section("Incoming mail (IMAP)") {
                TextField("Server", text: $viewModel.imapHost)
                TextField("Port", text: $viewModel.imapPort)
                TextField("Username", text: $viewModel.username)
            }
            Section("Outgoing mail (SMTP)") {
                TextField("Server", text: $viewModel.smtpHost)
                TextField("Port", text: $viewModel.smtpPort)
            }
            Section {
                Button("Save") { viewModel.saveAccountSettings() }
                    .disabled(viewModel.isAccountSaveDisabled)
                if let message = viewModel.accountSettingsMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server Settings")
    }
}

/// Add Account: the setup flow on its own model, so the page being edited isn't disturbed.
/// A finished add reloads the account list and, where Settings has a selection, opens the new
/// account's page.
struct AddAccountSettingsPage: View {
    @ObservedObject var accountSetup: AccountSetupViewModel
    /// In Sync Node mode, Gmail connects the Google mailbox to the Node ("Connect Google").
    let nodeSettings: SyncNodeSettingsViewModel?
    var selection: Binding<PlainpostSettingsDestination?>?
    @StateObject private var newAccount: AccountSetupViewModel

    init(
        accountSetup: AccountSetupViewModel,
        nodeSettings: SyncNodeSettingsViewModel? = nil,
        selection: Binding<PlainpostSettingsDestination?>?
    ) {
        self.accountSetup = accountSetup
        self.nodeSettings = nodeSettings
        self.selection = selection
        _newAccount = StateObject(wrappedValue: accountSetup.makeAdditionalAccountViewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = accountSetup.accountDeletionMessage {
                AccountDeletionStatusNotice(message: message)
                    .padding(.horizontal, 24)
            }
            AccountSetupWorkspace(viewModel: newAccount, connectNodeGoogle: connectNodeGoogle)
        }
        .onChange(of: newAccount.completedAddEvent) { _, event in
            guard let event else { return }
            accountSetup.reloadAccounts(selecting: event.accountID)
            selection?.wrappedValue = .account(event.accountID)
        }
    }

    private var connectNodeGoogle: (() -> Void)? {
        guard let nodeSettings, nodeSettings.canConnectProvider else { return nil }
        return { nodeSettings.connectProvider() }
    }
}
