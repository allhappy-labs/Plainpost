import SwiftUI
import PlainpostAI
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperations

private struct PlainpostDownloadCompleteHistoryKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AccountID) -> Void)? = nil
}

private struct PlainpostHistoryDownloadStatusKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct PlainpostHistoryDownloadAccountIDKey: EnvironmentKey {
    static let defaultValue: AccountID? = nil
}

public extension EnvironmentValues {
    /// Downloads one account's complete history.
    var plainpostDownloadCompleteHistory: (@MainActor (AccountID) -> Void)? {
        get { self[PlainpostDownloadCompleteHistoryKey.self] }
        set { self[PlainpostDownloadCompleteHistoryKey.self] = newValue }
    }

    var plainpostHistoryDownloadStatus: String? {
        get { self[PlainpostHistoryDownloadStatusKey.self] }
        set { self[PlainpostHistoryDownloadStatusKey.self] = newValue }
    }

    /// The account `plainpostHistoryDownloadStatus` reports on: the one whose history download
    /// the host last started.
    var plainpostHistoryDownloadAccountID: AccountID? {
        get { self[PlainpostHistoryDownloadAccountIDKey.self] }
        set { self[PlainpostHistoryDownloadAccountIDKey.self] = newValue }
    }
}

#if os(macOS)
import AppKit
#endif

#if os(iOS)
import UIKit

private let localDeviceName = "device"
private let localKeychainDescription = "this device's Keychain"
#else
private let localDeviceName = "Mac"
private let localKeychainDescription = "this Mac's Keychain"
#endif

enum PlainpostAIGenerationPolicy {
    static func isAvailable(
        isIOS: Bool,
        foundationAvailability: FoundationModelsAvailability
    ) -> Bool {
        !isIOS || foundationAvailability != .requiresNewerOS
    }

    static var current: Bool {
        #if os(iOS)
        isAvailable(isIOS: true, foundationAvailability: .current())
        #else
        true
        #endif
    }
}

enum MailSearchIndexRebuildState: Equatable, Sendable {
    case loading
    case preparing
    case ready
    case rebuilding
    case unavailable
    case failed
}

enum MailSearchIndexRebuildPresentation {
    static let confirmationMessage = "Plainpost will rebuild its local search index. Your mail is retained and never deleted. Search is unavailable until rebuilding finishes."
}

@MainActor
final class MailSearchIndexRebuildController: ObservableObject {
    typealias IndexState = () async -> MailSearchIndexState
    typealias Rebuild = () async throws -> Void
    typealias Announce = @MainActor (String) -> Void

    @Published private(set) var state: MailSearchIndexRebuildState = .loading
    @Published private(set) var accessibilityAnnouncement: String?
    let allowsRebuild: Bool

    private let indexStateAction: IndexState
    private let rebuildAction: Rebuild
    private let announceAction: Announce

    init(
        indexState: @escaping IndexState = { .unavailable },
        rebuild: @escaping Rebuild = {},
        allowsRebuild: Bool = true,
        announce: @escaping Announce = MailSearchIndexRebuildController.postAccessibilityAnnouncement
    ) {
        indexStateAction = indexState
        rebuildAction = rebuild
        self.allowsRebuild = allowsRebuild
        announceAction = announce
    }

    func refresh() async {
        let indexState = await indexStateAction()
        guard state != .rebuilding else { return }
        state = Self.presentationState(indexState)
    }

    func rebuild() async {
        guard allowsRebuild, state != .rebuilding else { return }
        state = .rebuilding
        publishAnnouncement("Search index rebuild started.")
        do {
            try await rebuildAction()
            state = Self.presentationState(await indexStateAction())
            publishAnnouncement(state == .ready
                ? "Search index rebuild completed."
                : "Search index rebuild finished. \(Self.accessibilityStatus(state))")
        } catch is CancellationError {
            state = Self.presentationState(await indexStateAction())
            publishAnnouncement("Search index rebuild cancelled.")
        } catch let error as MailSearchError where error == .cancelled {
            state = Self.presentationState(await indexStateAction())
            publishAnnouncement("Search index rebuild cancelled.")
        } catch {
            state = .failed
            publishAnnouncement("Search index rebuild failed. Try again.")
        }
    }

    private func publishAnnouncement(_ announcement: String) {
        accessibilityAnnouncement = announcement
        announceAction(announcement)
    }

    private static func postAccessibilityAnnouncement(_ announcement: String) {
#if os(macOS)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
#endif
    }

    private static func presentationState(
        _ state: MailSearchIndexState
    ) -> MailSearchIndexRebuildState {
        switch state {
        case .preparing: .preparing
        case .ready: .ready
        case .rebuilding: .rebuilding
        case .unavailable: .unavailable
        }
    }

    private static func accessibilityStatus(
        _ state: MailSearchIndexRebuildState
    ) -> String {
        switch state {
        case .loading: "Search index state is loading."
        case .preparing: "Search index is preparing."
        case .ready: "Search is ready."
        case .rebuilding: "Search index is rebuilding."
        case .unavailable: "Search is unavailable."
        case .failed: "Search index rebuild failed."
        }
    }
}

public struct SettingsWorkspace: View {
    @Environment(\.plainpostSettingsHost) private var settingsHost
    @Binding var selection: PlainpostSettingsDestination?
    /// Add Account was chosen only because no accounts had loaded yet; the first account
    /// replaces it once one arrives.
    @State private var showsAddAccountByDefault = false
    @ObservedObject var accountSetup: AccountSetupViewModel
    let accountSessionModel: AccountSessionViewModel?
    let nodeSettings: SyncNodeSettingsViewModel?
    @ObservedObject var aiProviderSettings: AIProviderSettingsViewModel
    @ObservedObject var translationSettings: TranslationLanguageSettingsViewModel
    let aiIndexStatus: AIIndexStatusModel
    @ObservedObject var auditLog: AuditLogViewModel
    @ObservedObject var mailRules: MailRulesViewModel
    @ObservedObject var mailLabels: MailLabelsViewModel
    @ObservedObject var maintenance: MailMaintenanceViewModel
    @StateObject var searchIndexRebuild: MailSearchIndexRebuildController

    public init(
        selection: Binding<PlainpostSettingsDestination?>,
        accountSetup: AccountSetupViewModel,
        accountSessionModel: AccountSessionViewModel? = nil,
        nodeSettings: SyncNodeSettingsViewModel? = nil,
        aiProviderSettings: AIProviderSettingsViewModel,
        translationSettings: TranslationLanguageSettingsViewModel? = nil,
        aiIndexStatus: AIIndexStatusModel,
        auditLog: AuditLogViewModel,
        mailRules: MailRulesViewModel,
        mailLabels: MailLabelsViewModel,
        maintenance: MailMaintenanceViewModel,
        searchIndexState: @escaping () async -> MailSearchIndexState = { .unavailable },
        rebuildSearchIndex: @escaping () async throws -> Void = {}
    ) {
        self._selection = selection
        self.accountSetup = accountSetup
        self.accountSessionModel = accountSessionModel
        self.nodeSettings = nodeSettings
        self.aiProviderSettings = aiProviderSettings
        self.translationSettings = translationSettings
            ?? TranslationLanguageSettingsViewModel(
                options: [
                    TranslationLanguageOption(
                        id: TranslationLanguageCatalog.defaultLanguageID,
                        localizedName: "English"
                    ),
                ]
            )
        self.aiIndexStatus = aiIndexStatus
        self.auditLog = auditLog
        self.mailRules = mailRules
        self.mailLabels = mailLabels
        self.maintenance = maintenance
        self._searchIndexRebuild = StateObject(
            wrappedValue: MailSearchIndexRebuildController(
                indexState: searchIndexState,
                rebuild: rebuildSearchIndex
            )
        )
    }

    init(
        selection: Binding<PlainpostSettingsDestination?>,
        accountSetup: AccountSetupViewModel,
        accountSessionModel: AccountSessionViewModel? = nil,
        nodeSettings: SyncNodeSettingsViewModel? = nil,
        aiProviderSettings: AIProviderSettingsViewModel,
        translationSettings: TranslationLanguageSettingsViewModel? = nil,
        aiIndexStatus: AIIndexStatusModel,
        auditLog: AuditLogViewModel,
        mailRules: MailRulesViewModel,
        mailLabels: MailLabelsViewModel,
        maintenance: MailMaintenanceViewModel,
        searchIndexRebuild: MailSearchIndexRebuildController
    ) {
        self._selection = selection
        self.accountSetup = accountSetup
        self.accountSessionModel = accountSessionModel
        self.nodeSettings = nodeSettings
        self.aiProviderSettings = aiProviderSettings
        self.translationSettings = translationSettings
            ?? TranslationLanguageSettingsViewModel(
                options: [
                    TranslationLanguageOption(
                        id: TranslationLanguageCatalog.defaultLanguageID,
                        localizedName: "English"
                    ),
                ]
            )
        self.aiIndexStatus = aiIndexStatus
        self.auditLog = auditLog
        self.mailRules = mailRules
        self.mailLabels = mailLabels
        self.maintenance = maintenance
        self._searchIndexRebuild = StateObject(wrappedValue: searchIndexRebuild)
    }

    private var accountRows: [SettingsAccountRow] {
        SettingsAccountRow.rows(accountSetup: accountSetup, host: settingsHost)
    }

    public var body: some View {
        let rows = accountRows
        let destination = selection ?? SettingsAccountRow.reconciledDestination(current: nil, rows: rows)
        HStack(spacing: 0) {
            SettingsRootList(selection: $selection, accountRows: rows, navigation: .selection)
                .frame(width: 260)
                .background(.regularMaterial)

            Divider()

            // Account pages push Folders and Server Settings.
            NavigationStack {
                SettingsDetailWorkspace(
                    destination: destination,
                    accountSetup: accountSetup,
                    accountSessionModel: accountSessionModel,
                    nodeSettings: nodeSettings,
                    aiProviderSettings: aiProviderSettings,
                    translationSettings: translationSettings,
                    aiIndexStatus: aiIndexStatus,
                    auditLog: auditLog,
                    mailRules: mailRules,
                    mailLabels: mailLabels,
                    maintenance: maintenance,
                    searchIndexRebuild: searchIndexRebuild,
                    selection: $selection
                )
            }
            // A new page starts a new stack, so a pushed Folders page doesn't outlive its account.
            .id(destination)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onChange(of: rows.map(\.destination), initial: true) { _, _ in
            reconcileSelection(rows: rows)
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection != .section(.accounts) { showsAddAccountByDefault = false }
        }
    }

    private func reconcileSelection(rows: [SettingsAccountRow]) {
        if selection == nil, rows.isEmpty { showsAddAccountByDefault = true }
        let reconciled = SettingsAccountRow.reconciledDestination(
            current: selection,
            rows: rows,
            promotingAddAccount: showsAddAccountByDefault
        )
        if reconciled != selection { selection = reconciled }
    }
}

struct SettingsDetailWorkspace: View {
    @Environment(\.plainpostCalendarAuthority) private var calendarAuthority
    let destination: PlainpostSettingsDestination
    @ObservedObject var accountSetup: AccountSetupViewModel
    let accountSessionModel: AccountSessionViewModel?
    let nodeSettings: SyncNodeSettingsViewModel?
    @ObservedObject var aiProviderSettings: AIProviderSettingsViewModel
    @ObservedObject var translationSettings: TranslationLanguageSettingsViewModel
    let aiIndexStatus: AIIndexStatusModel
    @ObservedObject var auditLog: AuditLogViewModel
    @ObservedObject var mailRules: MailRulesViewModel
    @ObservedObject var mailLabels: MailLabelsViewModel
    @ObservedObject var maintenance: MailMaintenanceViewModel
    @ObservedObject var searchIndexRebuild: MailSearchIndexRebuildController
    /// The host's settings selection, so a finished Add Account can open the new account.
    /// Nil where pages are pushed (iPhone).
    var selection: Binding<PlainpostSettingsDestination?>? = nil
    @Environment(\.plainpostSettingsHost) private var settingsHost

    var body: some View {
        Group {
            switch destination {
            case .section(let section):
                sectionDetail(section)
            case .account(let accountID):
                AccountSettingsPage(accountID: accountID, viewModel: accountSetup)
            case .nodeAccount(let id):
                if let account = settingsHost.nodeMailAccounts.first(where: { $0.logicalMailboxID == id }) {
                    NodeAccountSettingsPage(account: account)
                } else {
                    ContentUnavailableView("Account unavailable", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .background(MailDesign.background)
        .id(destination)
    }

    @ViewBuilder
    private func sectionDetail(_ selectedSection: PlainpostSettingsSection) -> some View {
        switch selectedSection {
        case .accounts:
            AddAccountSettingsPage(accountSetup: accountSetup, nodeSettings: nodeSettings, selection: selection)
        case .plainpostAccount:
            PlainpostAccountSettingsPage(accountSessionModel: accountSessionModel)
        case .syncNode:
            SyncNodeSettingsPage(session: accountSessionModel, nodeSettings: nodeSettings)
        case .smartInbox:
            SmartInboxSettingsPage(
                settings: aiProviderSettings,
                translation: translationSettings,
                maintenance: maintenance
            )
        case .rulesLabels:
            RulesLabelsSettingsPage(rules: mailRules, labels: mailLabels)
        case .notifications:
            NotificationsSettingsPage()
        case .privacy:
            PrivacySettingsPage()
        case .troubleshooting:
            TroubleshootingSettingsPage(
                auditLog: auditLog,
                maintenance: maintenance,
                accountSetup: accountSetup,
                searchIndexRebuild: searchIndexRebuild
            )
        #if os(macOS)
        case .calendars:
            calendarsDetail
        #endif
        }
    }

    #if os(macOS)
    private var calendarsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Only wire a real mailbox-discovery retry when the authority comes from
                // the live session; a design-preview or test override (the environment
                // value) has no session to re-read mailboxes from.
                let usesSessionAuthority = calendarAuthority == nil
                if let calendarAuthority = calendarAuthority ?? accountSessionModel?.calendarAuthority {
                    CalendarSettingsView(
                        service: calendarAuthority,
                        // Non-destructive: re-reads the session's mailbox assignments
                        // without invalidating or recreating `calendarAuthority`, which
                        // the week view and thread invitations may still be using.
                        refreshSendingMailboxes: usesSessionAuthority ? { [weak accountSessionModel] in
                            await accountSessionModel?.refreshCalendarSendingMailboxes() ?? []
                        } : nil
                    ).id(calendarAuthority.accountID)
                } else {
                    ContentUnavailableView("Calendar unavailable", systemImage: "calendar", description: Text("Connect your Sync Node to set up calendars."))
                    Button("Retry Calendar") { Task { await accountSessionModel?.prepareCalendarAuthority() } }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
    #endif
}

struct SearchIndexDiagnosticsPanel: View {
    @ObservedObject var controller: MailSearchIndexRebuildController
    @State private var confirmsRebuild = false

    var body: some View {
        Group {
            if controller.allowsRebuild {
                Section("Search Index") {
                    HStack {
                        Button("Rebuild Search Index") {
                            confirmsRebuild = true
                        }
                        .disabled(controller.state == .rebuilding)
                        .accessibilityHint("Mail is retained. Search is unavailable while rebuilding.")
                        Spacer()
                        statusLabel
                    }
                }
            }
        }
        .confirmationDialog(
            "Rebuild Search Index?",
            isPresented: $confirmsRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild Search Index") {
                Task { await controller.rebuild() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MailSearchIndexRebuildPresentation.confirmationMessage)
        }
        .task { await controller.refresh() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.state {
        case .loading:
            Label("Loading", systemImage: "ellipsis.circle")
        case .preparing:
            Label("Preparing", systemImage: "hourglass")
        case .ready:
            Label("Ready", systemImage: "checkmark.circle")
        case .rebuilding:
            Label("Rebuilding", systemImage: "arrow.triangle.2.circlepath")
        case .unavailable:
            Label("Unavailable", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

}

struct SettingsPageHeader: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        SystemSettingsHero(
            title: title,
            detail: detail,
            systemImage: systemImage,
            tint: tint
        )
    }
}

struct TranslationLanguagePickerPopover: View {
    @ObservedObject var viewModel: TranslationLanguageSettingsViewModel
    @Binding var isPresented: Bool
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Translation Language")
                .font(.headline)

            TextField("Search languages", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFieldFocused)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.filteredOptions) { option in
                        Button {
                            viewModel.selectLanguage(option.id)
                            isPresented = false
                        } label: {
                            HStack {
                                Text(option.localizedName)
                                Spacer()
                                if option.id == viewModel.selectedLanguageID {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 30)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            isSearchFieldFocused = true
        }
    }
}

struct AIIndexStatusWorkspace: View {
    let status: AIIndexStatusModel
    private var tint: Color { status.needsAttention ? .orange : MailDesign.accentTeal }

    var body: some View {
        Form {
            Section("On-device index") {
                LabeledContent("State") {
                    Label(status.title, systemImage: status.needsAttention ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .foregroundStyle(tint)
                }
                LabeledContent("Messages", value: status.detail)
                LabeledContent("Provider", value: "Local search index")
                LabeledContent("Storage", value: "On this \(localDeviceName)")
            }

            Section("Capabilities") {
                Label("Semantic mail search", systemImage: "magnifyingglass")
                Label("Local message embeddings", systemImage: "cpu")
                Label("Automatic freshness tracking", systemImage: "clock.arrow.circlepath")
            }

            Section("Privacy and maintenance") {
                LabeledContent("Local-only embeddings", value: "Enabled")
                LabeledContent("Remote provider isolation", value: "Enabled")
                LabeledContent("Freshness", value: status.needsAttention ? "Needs attention" : "Current")
                Text(
                    status.needsAttention
                        ? "Rebuild the index before relying on semantic search results."
                        : "The index is ready and current for the local mailbox cache."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("AI Index")
        .background(MailDesign.background)
    }
}

/// Shown above account settings when an account must sign in again: an OAuth
/// provider refused the grant, or "Start Over with Saved Sign-ins" set the
/// account's saved sign-in aside.
struct OAuthReauthorizationBanner: View {
    @ObservedObject var viewModel: AccountSetupViewModel
    /// Opens the password sheet, for a password account.
    var enterPassword: (() -> Void)?

    static func defaultMessage(microsoft: Bool) -> String {
        microsoft
            ? "Microsoft stopped accepting Plainpost's access to this mailbox. Mail won't sync or send until you sign in again."
            : "Google stopped accepting Plainpost's access to this account. Mail won't sync or send until you sign in again."
    }

    static let passwordTitle = "Enter your password again"
    static let passwordMessage =
        "Plainpost no longer has the saved password for this account. Mail won't sync or send until you enter it again."

    var body: some View {
        if viewModel.selectedAccountNeedsPasswordAgain {
            passwordBody
        } else {
            oauthBody
        }
    }

    private var passwordBody: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.passwordTitle)
                    .font(.headline)
                Text(Self.passwordMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let enterPassword {
                Button("Enter Password…", action: enterPassword)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("password-reenter")
            }
        }
        .padding(14)
        .frame(maxWidth: 820, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: MailDesign.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.panel).stroke(Color.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var oauthBody: some View {
        let microsoft = viewModel.isSelectedAccountMicrosoftOAuth
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(microsoft ? "Microsoft Mail needs you to sign in again" : "Gmail needs you to sign in again")
                    .font(.headline)
                Text((microsoft ? viewModel.microsoftReauthorizationMessage : viewModel.gmailReauthorizationMessage)
                     ?? Self.defaultMessage(microsoft: microsoft))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                guard let accountID = viewModel.account?.id else { return }
                Task {
                    if microsoft { await viewModel.reauthorizeMicrosoft(accountID: accountID) }
                    else { await viewModel.reauthorizeGmail(accountID: accountID) }
                }
            } label: {
                if viewModel.reauthorizingAccountID != nil {
                    ProgressView().controlSize(.small)
                    Text(microsoft ? "Waiting for Microsoft…" : "Waiting for Google…")
                } else {
                    Text("Sign in again")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.reauthorizingAccountID != nil ||
                      (microsoft ? !viewModel.isMicrosoftSignInAvailable : !viewModel.isGoogleSignInAvailable))
            .accessibilityIdentifier(microsoft ? "microsoft-reauthorize" : "gmail-reauthorize")
        }
        .padding(14)
        .frame(maxWidth: 820, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: MailDesign.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.panel).stroke(Color.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

struct CredentialReplacementSection: View {
    @ObservedObject var viewModel: AccountSetupViewModel

    var body: some View {
        if viewModel.isSelectedAccountGoogleOAuth {
            googleSignInSection
        } else if viewModel.isSelectedAccountMicrosoftOAuth {
            microsoftSignInSection
        } else {
            passwordSection
        }
    }

    /// OAuth accounts have no password to change: the row names the sign-in and offers it again.
    private var googleSignInSection: some View {
        LabeledContent("Sign-in") {
            HStack {
                Text("Google account").foregroundStyle(.secondary)
                reauthorizeButton(title: "Sign in again")
                    .accessibilityIdentifier("credential-replacement-google-reauthorize")
            }
        }
    }

    private var microsoftSignInSection: some View {
        LabeledContent("Sign-in") {
            HStack {
                Text("Microsoft account").foregroundStyle(.secondary)
                Button("Sign in again") {
                    guard let accountID = viewModel.account?.id else { return }
                    Task { await viewModel.reauthorizeMicrosoft(accountID: accountID) }
                }
                .disabled(viewModel.reauthorizingAccountID != nil || !viewModel.isMicrosoftSignInAvailable)
                .accessibilityIdentifier("credential-replacement-microsoft-sign-in")
            }
        }
    }

    private func reauthorizeButton(title: String) -> some View {
        Button(title) {
            guard let accountID = viewModel.account?.id else { return }
            Task { await viewModel.reauthorizeGmail(accountID: accountID) }
        }
        .disabled(viewModel.reauthorizingAccountID != nil || !viewModel.isGoogleSignInAvailable)
    }

    @ViewBuilder
    private var passwordSection: some View {
        Section("Credentials") {
            if viewModel.usesSharedAppPassword {
                // One app password covers incoming and outgoing mail.
                let label = viewModel.isSelectedAccountGmail ? "Google App Password" : "App-specific password"
                passwordField(label, prompt: label, text: $viewModel.imapPassword, identifier: "credential-replacement-incoming")
            } else {
                passwordField("IMAP password", prompt: "New IMAP password", text: $viewModel.imapPassword, identifier: "credential-replacement-incoming")
                passwordField("SMTP password", prompt: "New SMTP password", text: $viewModel.smtpPassword, identifier: "credential-replacement-outgoing")
            }

            HStack {
                if let message = viewModel.credentialSettingsMessage {
                    Label(
                        message,
                        systemImage: message.hasSuffix("updated.") ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(message.hasSuffix("updated.") ? Color.green : Color.orange)
                }
                Spacer()
                Button(viewModel.usesSharedAppPassword ? "Update Password" : "Update Passwords") {
                    Task {
                        await viewModel.saveAccountPasswords()
                    }
                }
                .disabled(viewModel.isCredentialSaveDisabled)
                .accessibilityIdentifier("credential-replacement-update")
            }
        }
    }

    private func passwordField(
        _ label: String, prompt: String, text: Binding<String>, identifier: String
    ) -> some View {
        LabeledContent(label) {
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: 360)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
    }
}

enum AccountDeletionConfirmation {
    static func title(email: String) -> String {
        "Delete \(email) from Plainpost?"
    }

    static func message(email: String) -> String {
        "This permanently removes \(email), its credentials, cached mail, attachments, drafts, queued work, and account rules from Plainpost. Mail on your provider is not deleted."
    }
}

/// The account page's last section: Remove Account… plus the outcome of the last removal.
struct AccountDeletionDangerSection: View {
    @ObservedObject var viewModel: AccountSetupViewModel
    let requestConfirmation: () -> Void

    var body: some View {
        Section {
            Button("Remove Account…", role: .destructive, action: requestConfirmation)
                .disabled(viewModel.isDeletingAccount)
                .accessibilityIdentifier("account-deletion-open-confirmation")
            if let message = viewModel.accountDeletionMessage {
                AccountDeletionStatusNotice(message: message)
            }
        }
    }
}

struct AccountDeletionStatusNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(message.hasPrefix("Account deleted") ? Color.green : Color.orange)
            .accessibilityLabel(message)
            .accessibilityIdentifier("account-deletion-status")
    }
}

struct AccountDeletionConfirmationActions: View {
    @ObservedObject var viewModel: AccountSetupViewModel

    var body: some View {
        Button("Cancel", role: .cancel) {}
            .accessibilityLabel("Cancel account deletion")
            .accessibilityIdentifier("account-deletion-cancel")

        Button("Delete from Plainpost", role: .destructive) {
            deleteAccount()
        }
        .disabled(viewModel.isDeletingAccount)
        .accessibilityLabel(
            Text(verbatim: "Delete \(viewModel.account?.email.rawValue ?? viewModel.email) from Plainpost")
        )
        .accessibilityIdentifier("account-deletion-confirm")
    }

    func deleteAccount() {
        Task { await viewModel.deleteSelectedAccount() }
    }
}

struct AccountSetupLayoutMetrics: Equatable {
    let contentMaxWidth: CGFloat
    let contentLeadingInset: CGFloat
    let panelSpacing: CGFloat
    let panelPadding: CGFloat
    let rowVerticalPadding: CGFloat
    let fieldLabelWidth: CGFloat
    let contentTopPadding: CGFloat
    let contentBottomPadding: CGFloat
    let headerHorizontalInset: CGFloat
    let backLaneWidth: CGFloat
    let headerTopPadding: CGFloat
    let headerBottomPadding: CGFloat
    let headerTextLayoutPriority: Double
    let headerTitleLineLimit: Int

    static let standard = AccountSetupLayoutMetrics(
        contentMaxWidth: 760,
        contentLeadingInset: 50,
        panelSpacing: 14,
        panelPadding: 16,
        rowVerticalPadding: 8,
        fieldLabelWidth: 128,
        contentTopPadding: 10,
        contentBottomPadding: 28,
        headerHorizontalInset: 28,
        backLaneWidth: 36,
        headerTopPadding: 26,
        headerBottomPadding: 0,
        headerTextLayoutPriority: 1,
        headerTitleLineLimit: 1
    )
}

struct AccountSetupLabeledContentStyle: LabeledContentStyle {
    let labelWidth: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
                .frame(width: labelWidth, alignment: .leading)

            configuration.content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct AccountSetupPanel<Content: View>: View {
    let title: String
    let footer: String?
    let layout: AccountSetupLayoutMetrics
    private let content: Content

    init(
        _ title: String,
        footer: String? = nil,
        layout: AccountSetupLayoutMetrics = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.layout = layout
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)

            content
                .labeledContentStyle(AccountSetupLabeledContentStyle(labelWidth: layout.fieldLabelWidth))
                .padding(.top, 8)

            if let footer {
                Divider()
                    .padding(.top, 10)
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
        .padding(layout.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: MailDesign.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: MailDesign.Radius.panel)
                .stroke(MailDesign.stroke)
        )
    }
}

public struct AccountSetupWorkspace: View {
    @ObservedObject var viewModel: AccountSetupViewModel
    /// In Sync Node mode the Gmail tile connects the Google mailbox to the Node instead of
    /// starting the direct Google flow.
    private let connectNodeGoogle: (() -> Void)?
    private let layout = AccountSetupLayoutMetrics.standard

    public init(viewModel: AccountSetupViewModel, connectNodeGoogle: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.connectNodeGoogle = connectNodeGoogle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recovery = viewModel.googleSetupRecoveryMessage {
                recoveryNotice(recovery, accountID: viewModel.googleSetupRecoveryAccountID, isGoogle: true)
            }
            if let recovery = viewModel.microsoftSetupRecoveryMessage {
                recoveryNotice(recovery, accountID: viewModel.microsoftSetupRecoveryAccountID, isGoogle: false)
            }
            switch viewModel.selectedProvider {
            case nil:
                providerChooser
            case .gmail:
                #if os(iOS)
                iosGmailSetup
                #else
                gmailSetup
                #endif
            case .microsoft:
                #if os(iOS)
                microsoftSetup
                #else
                otherAccountSetup
                #endif
            case .icloud:
                icloudSetup
            case .other:
                #if os(iOS)
                iosOtherAccountSetup
                #else
                otherAccountSetup
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailDesign.background)
        #if os(iOS)
        .navigationTitle(viewModel.selectedProvider == .gmail ? "Gmail" : "Account Setup")
        .navigationBarTitleDisplayMode(viewModel.selectedProvider == .gmail ? .inline : .automatic)
        #else
        .navigationTitle("Account Setup")
        #endif
    }

    private func recoveryNotice(_ message: String, accountID: AccountID?, isGoogle: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Spacer(minLength: 8)
            if let accountID, let recovered = viewModel.accounts.first(where: { $0.id == accountID }) {
                Button("Open \(recovered.email.rawValue)") {
                    if isGoogle { viewModel.openRecoveredGoogleAccount() }
                    else { viewModel.openRecoveredMicrosoftAccount() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(isGoogle
                    ? "account-setup.google-recovery.open" : "account-setup.microsoft-recovery.open")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .accessibilityIdentifier(isGoogle
            ? "account-setup.google-recovery" : "account-setup.microsoft-recovery")
    }

    private var providerChooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeader(
                eyebrow: "STEP 1 OF 2",
                title: "Add a mail account",
                detail: providerChooserDetail,
                symbol: "envelope.badge.shield.half.filled",
                tint: MailDesign.accentBlue
            )

            compactSetupContent {
                providerButton(
                    provider: .gmail,
                    title: "Gmail",
                    detail: viewModel.gmailProviderDetail,
                    symbol: "g.circle.fill",
                    tint: Color(red: 0.84, green: 0.23, blue: 0.18),
                    badge: "GUIDED"
                )
                #if os(iOS)
                providerButton(
                    provider: .microsoft,
                    title: "Microsoft Mail",
                    detail: "Sign in with Outlook.com or Microsoft 365. Mail access must be enabled for the mailbox.",
                    symbol: "m.square.fill",
                    tint: MailDesign.accentBlue,
                    badge: "GUIDED"
                )
                #endif
                providerButton(
                    provider: .icloud,
                    title: "iCloud Mail",
                    detail: "Connect with an Apple app-specific password. Servers are configured for you.",
                    symbol: "icloud.fill",
                    tint: MailDesign.accentBlue,
                    badge: "GUIDED"
                )
                providerButton(
                    provider: .other,
                    title: "Other IMAP account",
                    detail: viewModel.otherIMAPDetail,
                    symbol: "server.rack",
                    tint: MailDesign.accentBlue,
                    badge: nil
                )
                Label(
                    credentialStorageDescription,
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var providerChooserDetail: String {
        #if os(iOS)
        "Choose your provider. Gmail, Microsoft, and iCloud have guided setup; other providers can use manual IMAP and SMTP settings."
        #else
        "Choose your provider. Gmail and iCloud have guided setup; other providers can use manual IMAP and SMTP settings."
        #endif
    }

    private var credentialStorageDescription: String {
        #if os(iOS)
        return "Passwords stay in this device's Keychain. Cached mail stays on this device."
        #else
        return "Passwords and Google sign-in are stored in macOS Keychain. Mail and the AI index stay on this Mac by default."
        #endif
    }

    #if os(iOS)
    private var microsoftSetup: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeader(
                eyebrow: "STEP 2 OF 2", title: "Connect Microsoft Mail",
                detail: "Use your Microsoft account to connect Outlook.com or Microsoft 365 mail.",
                symbol: "m.square.fill", tint: MailDesign.accentBlue, showsBackButton: true
            )
            compactSetupContent {
                AccountSetupPanel("Your Microsoft Mail account", layout: layout) {
                    VStack(spacing: 0) {
                        accountSetupRow {
                            LabeledContent("Your name") {
                                TextField("Shown to recipients", text: $viewModel.displayName)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .accessibilityIdentifier("account-setup.microsoft-name")
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("Email address") {
                                TextField("name@outlook.com", text: $viewModel.email)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .textContentType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                    .accessibilityIdentifier("account-setup.microsoft-email")
                            }
                        }
                    }
                }
                if viewModel.isMicrosoftSignInAvailable {
                    AccountSetupPanel(
                        "Microsoft sign-in",
                        footer: "Plainpost asks for Microsoft Mail access. Credentials stay in \(localKeychainDescription).",
                        layout: layout
                    ) {
                        Text("Your browser opens Microsoft sign-in. Your mailbox must permit IMAP and SMTP AUTH.")
                            .font(.callout)
                            .padding(.vertical, layout.rowVerticalPadding)
                    }
                } else {
                    AccountSetupPanel("Microsoft sign-in", layout: layout) {
                        Label(AccountSetupViewModel.microsoftSignInUnavailableMessage,
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .padding(.vertical, layout.rowVerticalPadding)
                    }
                }
                connectPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailDesign.background)
    }
    #endif

#if os(iOS)
    private var iosGmailSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sign in with your Google account to connect Gmail.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await viewModel.signInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    if viewModel.isGoogleSignInInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "person.badge.key")
                    }
                    Text(iosGoogleSignInTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.isGoogleSignInAvailable || viewModel.isGoogleSignInInProgress || viewModel.isSubmitting)
            .accessibilityIdentifier("gmail-sign-in-with-google")

            if let message = iosGoogleSignInStatus {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(iosGoogleSignInHasError ? .red : MailDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gmail-sign-in-status")
            }

            Button("Choose another provider") {
                viewModel.showProviderChooser()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(viewModel.isSubmitting)
            .accessibilityIdentifier("gmail-choose-provider")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailDesign.background)
    }

    private var iosGoogleSignInTitle: String {
        switch viewModel.gmailSignInState {
        case .waitingForBrowser: "Waiting for Google…"
        case .verifying: "Connecting…"
        default: "Sign in with Google"
        }
    }

    private var iosGoogleSignInStatus: String? {
        switch viewModel.gmailSignInState {
        case .unavailable: AccountSetupViewModel.googleSignInUnavailableMessage
        case .waitingForBrowser: "Finish signing in with Google in your browser."
        case .verifying: "Connecting to Gmail…"
        case .failed(let message): message
        case .idle: nil
        }
    }

    private var iosGoogleSignInHasError: Bool {
        if case .unavailable = viewModel.gmailSignInState { return true }
        if case .failed = viewModel.gmailSignInState { return true }
        return false
    }
#else
    private var gmailSetup: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeader(
                eyebrow: "STEP 2 OF 2",
                title: "Connect Gmail",
                detail: "Sign in with Google in your browser. Plainpost configures the secure mail servers for you.",
                symbol: "g.circle.fill",
                tint: .red,
                showsBackButton: true
            )

            compactSetupContent {
                AccountSetupPanel("Your Google account", layout: layout) {
                    VStack(spacing: 0) {
                        accountSetupRow {
                            LabeledContent("Your name") {
                                TextField("Shown to recipients", text: $viewModel.displayName)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Your name")
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("Google account") {
                                TextField("name@gmail.com", text: $viewModel.email)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .textContentType(.emailAddress)
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Google account email address")
                                    .disabled(viewModel.isGoogleSignInInProgress)
                            }
                        }
                    }
                }

                if viewModel.isGoogleSignInAvailable {
                    AccountSetupPanel(
                        "Google sign-in",
                        footer: "Plainpost asks Google for Gmail access only. The sign-in stays in \(localKeychainDescription).",
                        layout: layout
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your browser opens Google's sign-in page. Choose the account above and allow Gmail access.")
                                .font(.callout)
                            Text("No App Password needed. Gmail sends one verification email to your own address during setup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, layout.rowVerticalPadding)
                    }
                    connectPanel
                } else {
                    AccountSetupPanel("Google sign-in", layout: layout) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(AccountSetupViewModel.googleSignInUnavailableMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("You can still add Gmail with a Google App Password as an Other IMAP account.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button {
                                viewModel.selectProvider(.other)
                            } label: {
                                Label("Use Other IMAP account", systemImage: "server.rack")
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.vertical, layout.rowVerticalPadding)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailDesign.background)
    }
#endif

    private var icloudSetup: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeader(
                eyebrow: "STEP 2 OF 2",
                title: "Connect iCloud Mail",
                detail: "Plainpost uses Apple's secure iCloud Mail servers on this device.",
                symbol: "icloud.fill",
                tint: MailDesign.accentBlue,
                showsBackButton: true
            )

            compactSetupContent {
                AccountSetupPanel("Your iCloud Mail account", layout: layout) {
                    VStack(spacing: 0) {
                        accountSetupRow {
                            LabeledContent("Your name") {
                                TextField("Shown to recipients", text: $viewModel.displayName)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Your name")
                                    .accessibilityIdentifier("account-setup.icloud-name")
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("Full email address") {
                                TextField("name@icloud.com", text: $viewModel.email)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .textContentType(.emailAddress)
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Full iCloud Mail email address")
                                    .accessibilityIdentifier("account-setup.icloud-email")
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("App-specific password") {
                                SecureField("Apple app-specific password", text: $viewModel.icloudAppPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Apple app-specific password")
                                    .accessibilityIdentifier("account-setup.icloud-password")
                            }
                        }
                    }
                }

                AccountSetupPanel("Create an app-specific password", layout: layout) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("At account.apple.com, open Sign-In and Security, then create an app-specific password. Apple Account two-factor authentication is required.")
                        Text("Paste that password above. Do not enter your Apple Account password. Plainpost uses your full email address for both incoming and outgoing mail.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.vertical, layout.rowVerticalPadding)
                    .accessibilityIdentifier("account-setup.icloud-guidance")
                }
                connectPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailDesign.background)
    }

    private var otherAccountSetup: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeader(
                eyebrow: "STEP 2 OF 2",
                title: "Connect another provider",
                detail: "Enter the secure IMAP and SMTP settings supplied by your mail provider.",
                symbol: "server.rack",
                tint: MailDesign.accentBlue,
                showsBackButton: true
            )

            compactSetupContent {
                AccountSetupPanel("Identity", layout: layout) {
                    VStack(spacing: 0) {
                        accountSetupRow {
                            LabeledContent("Display name") {
                                TextField("Personal", text: $viewModel.displayName)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Display name")
                                    .accessibilityIdentifier("account-setup.display-name")
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("Email address") {
                                TextField("me@example.com", text: $viewModel.email)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .textContentType(.emailAddress)
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Email address")
                                    .accessibilityIdentifier("account-setup.email")
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("Username") {
                                TextField("Username", text: $viewModel.username)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("Username")
                                    .accessibilityIdentifier("account-setup.username")
                            }
                        }
                    }
                }

                AccountSetupPanel("Incoming mail (IMAP)", layout: layout) {
                    VStack(spacing: 0) {
                        accountSetupRow {
                            LabeledContent("Server") {
                                HStack {
                                    TextField("imap.example.com", text: $viewModel.imapHost)
                                        .textFieldStyle(.roundedBorder)
                                        .labelsHidden()
                                        .accessibilityLabel("IMAP server")
                                        .accessibilityIdentifier("account-setup.imap-host")
                                    TextField("Port", text: $viewModel.imapPort)
                                        .textFieldStyle(.roundedBorder)
                                        .labelsHidden()
                                        .frame(width: 76)
                                        .accessibilityLabel("IMAP port")
                                        .accessibilityIdentifier("account-setup.imap-port")
                                }
                                .frame(maxWidth: 360)
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("Password") {
                                SecureField("IMAP password", text: $viewModel.imapPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("IMAP password")
                                    .accessibilityIdentifier("account-setup.imap-password")
                            }
                        }
                    }
                }

                AccountSetupPanel("Outgoing mail (SMTP)", layout: layout) {
                    VStack(spacing: 0) {
                        accountSetupRow {
                            LabeledContent("Server") {
                                HStack {
                                    TextField("smtp.example.com", text: $viewModel.smtpHost)
                                        .textFieldStyle(.roundedBorder)
                                        .labelsHidden()
                                        .accessibilityLabel("SMTP server")
                                        .accessibilityIdentifier("account-setup.smtp-host")
                                    TextField("Port", text: $viewModel.smtpPort)
                                        .textFieldStyle(.roundedBorder)
                                        .labelsHidden()
                                        .frame(width: 76)
                                        .accessibilityLabel("SMTP port")
                                        .accessibilityIdentifier("account-setup.smtp-port")
                                }
                                .frame(maxWidth: 360)
                            }
                        }
                        Divider()
                        accountSetupRow {
                            LabeledContent("Password") {
                                SecureField("SMTP password", text: $viewModel.smtpPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .accessibilityLabel("SMTP password")
                                    .accessibilityIdentifier("account-setup.smtp-password")
                            }
                        }
                    }
                }

                connectPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MailDesign.background)
    }

    #if os(iOS)
    private var iosOtherAccountSetup: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeader(
                eyebrow: "STEP 2 OF 2",
                title: "Connect another provider",
                detail: "Enter your provider's secure IMAP and SMTP settings.",
                symbol: "server.rack",
                tint: MailDesign.accentBlue,
                showsBackButton: true
            )
            Form {
                Section("Identity") {
                    TextField("Display name", text: $viewModel.displayName)
                        .accessibilityIdentifier("account-setup.display-name")
                    TextField("Email address", text: $viewModel.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("account-setup.email")
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("account-setup.username")
                }
                Section("Incoming mail (IMAP)") {
                    TextField("IMAP server", text: $viewModel.imapHost)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("account-setup.imap-host")
                    TextField("IMAP port", text: $viewModel.imapPort)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("account-setup.imap-port")
                    SecureField("IMAP password", text: $viewModel.imapPassword)
                        .accessibilityIdentifier("account-setup.imap-password")
                }
                Section("Outgoing mail (SMTP)") {
                    TextField("SMTP server", text: $viewModel.smtpHost)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("account-setup.smtp-host")
                    TextField("SMTP port", text: $viewModel.smtpPort)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("account-setup.smtp-port")
                    SecureField("SMTP password", text: $viewModel.smtpPassword)
                        .accessibilityIdentifier("account-setup.smtp-password")
                }
                Section("Connection") {
                    statusLabel
                    manualConnectButton
                    Text(manualConnectionFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                    .accessibilityIdentifier("account-setup.dismiss-keyboard")
                }
            }
        }
        .navigationTitle("Account Setup")
    }
    #endif

    private func compactSetupContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.panelSpacing) {
                content()
            }
            .frame(
                maxWidth: layout.contentMaxWidth - (layout.contentLeadingInset * 2),
                alignment: .leading
            )
            .padding(.horizontal, layout.contentLeadingInset)
            .padding(.top, layout.contentTopPadding)
            .padding(.bottom, layout.contentBottomPadding)
            .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MailDesign.background)
    }

    private func accountSetupRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, layout.rowVerticalPadding)
    }

    private func setupHeader(
        eyebrow: String,
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        showsBackButton: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            if showsBackButton {
                Button {
                    viewModel.showProviderChooser()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .frame(width: layout.backLaneWidth, height: 36)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isSubmitting)
                .accessibilityLabel("Back to provider selection")
                .accessibilityHint("Choose a different mail provider")
                .help("Choose another provider")
            }

            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(layout.headerTitleLineLimit)
                    .truncationMode(.tail)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(layout.headerTextLayoutPriority)
        }
        .padding(.horizontal, layout.headerHorizontalInset)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    private func providerButton(
        provider: MailProviderKind,
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        badge: String?
    ) -> some View {
        Button {
            if provider == .gmail, let connectNodeGoogle {
                connectNodeGoogle()
            } else {
                viewModel.selectProvider(provider)
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 5) {
                    providerTitle(title, badge: badge, tint: tint)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MailDesign.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-setup.provider.\(provider.rawValue)")
        .accessibilityHint(
            provider == .gmail ? "Opens guided Gmail and Google Workspace setup"
                : provider == .microsoft ? "Opens guided Microsoft Mail setup"
                : provider == .icloud ? "Opens guided iCloud Mail setup"
                : "Opens manual IMAP and SMTP setup"
        )
    }

    @ViewBuilder
    private func providerTitle(_ title: String, badge: String?, tint: Color) -> some View {
        #if os(iOS)
        ViewThatFits(in: .horizontal) {
            providerTitleRow(title, badge: badge, tint: tint)
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let badge {
                    providerBadge(badge, tint: tint)
                }
            }
        }
        #else
        providerTitleRow(title, badge: badge, tint: tint)
        #endif
    }

    private func providerTitleRow(_ title: String, badge: String?, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                #if os(iOS)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                #endif
            if let badge {
                providerBadge(badge, tint: tint)
            }
        }
    }

    private func providerBadge(_ badge: String, tint: Color) -> some View {
        Text(badge)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.11), in: Capsule())
    }

    private var connectPanel: some View {
        AccountSetupPanel(
            "Connection",
            footer: viewModel.selectedProvider == .gmail
                ? "You can cancel with Back while Plainpost waits for Google."
                : viewModel.selectedProvider == .microsoft
                ? "You can cancel with Back while Plainpost waits for Microsoft."
                : manualConnectionFooter,
            layout: layout
        ) {
            if case .failed = viewModel.status {
                VStack(alignment: .leading, spacing: 12) {
                    statusLabel
                    connectButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        statusLabel
                            .layoutPriority(1)
                        Spacer()
                        connectButton
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        statusLabel
                        connectButton
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var manualConnectionFooter: String {
        #if os(iOS)
        return "Plainpost sends one verification email to your address during setup. Passwords stay in this device's Keychain."
        #else
        return "Plainpost sends one verification email to your address during setup. Credentials are stored in the macOS Keychain."
        #endif
    }

    @ViewBuilder
    private var connectButton: some View {
        if viewModel.selectedProvider == .gmail {
            googleSignInButton
        } else if viewModel.selectedProvider == .microsoft {
            microsoftSignInButton
        } else {
            manualConnectButton
        }
    }

    private var googleSignInButton: some View {
        Button {
            Task { await viewModel.signInWithGoogle() }
        } label: {
            switch viewModel.gmailSignInState {
            case .waitingForBrowser:
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Google…")
            case .verifying:
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
            default:
                Label("Sign in with Google", systemImage: "person.badge.key")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minWidth: 190)
        .disabled(viewModel.isGoogleSignInDisabled)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("gmail-sign-in-with-google")
    }

    private var microsoftSignInButton: some View {
        Button {
            Task { await viewModel.signInWithMicrosoft() }
        } label: {
            switch viewModel.microsoftSignInState {
            case .waitingForBrowser:
                ProgressView().controlSize(.small)
                Text("Waiting for Microsoft…")
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            default:
                Label("Sign in with Microsoft", systemImage: "person.badge.key")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minWidth: 190)
        .disabled(viewModel.isMicrosoftSignInDisabled)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("microsoft-sign-in")
    }

    private var manualConnectButton: some View {
        Button {
            Task { try? await viewModel.submit() }
        } label: {
            if viewModel.isSubmitting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
            } else {
                Label("Connect Account", systemImage: "checkmark")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minWidth: 170)
        .disabled(viewModel.isConnectDisabled)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .idle where viewModel.selectedProvider == .gmail:
            Label(
                viewModel.gmailSignInReadinessMessage,
                systemImage: viewModel.gmailSignInState == .waitingForBrowser
                    ? "safari"
                    : (viewModel.isGoogleSignInDisabled ? "info.circle" : "lock.fill")
            )
                .foregroundStyle(MailDesign.secondaryText)
        case .idle where viewModel.selectedProvider == .microsoft:
            Label(viewModel.microsoftSignInReadinessMessage,
                  systemImage: viewModel.isMicrosoftSignInDisabled ? "info.circle" : "lock.fill")
                .foregroundStyle(MailDesign.secondaryText)
        case .idle where viewModel.selectedProvider == .icloud:
            Label(
                viewModel.icloudReadinessMessage,
                systemImage: viewModel.isConnectDisabled ? "info.circle" : "lock.fill"
            )
                .foregroundStyle(MailDesign.secondaryText)
        case .idle:
            Label(
                viewModel.isConnectDisabled
                    ? "Complete every field to enable Connect."
                    : "Ready to connect securely.",
                systemImage: viewModel.isConnectDisabled ? "info.circle" : "lock.fill"
            )
                .foregroundStyle(MailDesign.secondaryText)
        case .validating where viewModel.selectedProvider == .gmail:
            Label(viewModel.gmailSignInReadinessMessage, systemImage: "clock")
                .foregroundStyle(MailDesign.secondaryText)
        case .validating where viewModel.selectedProvider == .microsoft:
            Label(viewModel.microsoftSignInReadinessMessage, systemImage: "clock")
                .foregroundStyle(MailDesign.secondaryText)
        case .validating:
            Label("Validating account...", systemImage: "clock")
                .foregroundStyle(MailDesign.secondaryText)
        case .syncing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(viewModel.syncStatusMessage)
            }
            .foregroundStyle(MailDesign.secondaryText)
        case .connected:
            Label(viewModel.syncStatusMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(MailDesign.accentTeal)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

public struct MailLabelsSettingsPanel: View {
    @ObservedObject var viewModel: MailLabelsViewModel

    public init(viewModel: MailLabelsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        AccountScopedManagementPanel(
            selection: Binding(
                get: { viewModel.selection },
                set: { viewModel.selectAccount($0) }
            ),
            accounts: viewModel.accounts,
            itemTitle: "Labels",
            addAccessibilityLabel: "Add mail label",
            add: viewModel.addLabel,
            isConfirmationPresented: Binding(
                get: { viewModel.confirmation != nil },
                set: { if !$0 { viewModel.dismissConfirmation() } }
            ),
            isEditorPresented: Binding(
                get: { viewModel.draft != nil },
                set: { presented in
                    if !presented {
                        viewModel.selectedLabelID = nil
                        viewModel.draft = nil
                    }
                }
            )
        ) { showEditor in
            #if os(iOS)
            if viewModel.labels.isEmpty {
                MailLabelEmptyListContent()
            } else {
                ForEach(viewModel.labels) { label in
                    labelRow(label, showEditor: showEditor)
                }
            }
            #else
            if viewModel.labels.isEmpty {
                MailLabelEmptyListContent()
            } else {
                List(viewModel.labels, selection: selectedLabel(openEditor: showEditor)) { label in
                    labelRow(label, showEditor: showEditor)
                        .tag(label.id)
                }
                .listStyle(.inset)
            }
            #endif
        } editorContent: {
            Group {
                if viewModel.draft != nil {
                    MailLabelEditor(viewModel: viewModel)
                } else {
                    ContentUnavailableView("Select a Label", systemImage: "tag")
                }
            }
        } confirmation: {
            if let confirmation = viewModel.confirmation {
                MailLabelConfirmationSheet(
                    viewModel: viewModel,
                    confirmation: confirmation
                )
            }
        }
        .onAppear {
            Task { await viewModel.load() }
        }
    }

    private func selectedLabel(openEditor: @escaping () -> Void) -> Binding<String?> {
        Binding(
            get: { viewModel.selectedLabelID },
            set: {
                if let id = $0 {
                    viewModel.selectLabel(id: id)
                    openEditor()
                }
            }
        )
    }

    private func scopeLabel(_ scope: MailLabelScope) -> String {
        switch scope {
        case .allAccounts:
            "All Accounts"
        case .account(let id):
            viewModel.accounts.first { $0.id == id }?.displayName ?? "This Account"
        }
    }

    private func labelRow(_ label: MailLabelDefinition, showEditor: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { label.isSmartInboxEnabled },
                set: { enabled in
                    #if os(iOS)
                    // On iOS a selected label pushes the editor; the toggle changes only the flag.
                    Task { await viewModel.setSmartInboxEnabled(enabled, forLabelID: label.id) }
                    #else
                    viewModel.selectLabel(id: label.id)
                    viewModel.setSmartInboxEnabled(enabled)
                    guard viewModel.draft?.isSmartInboxEnabled == enabled else { return }
                    Task { await viewModel.save() }
                    #endif
                }
            ))
            .labelsHidden()
            .accessibilityIdentifier("label.smart-inbox-toggle.\(label.id)")
            VStack(alignment: .leading, spacing: 3) {
                Text(label.title).lineLimit(1)
                Text(scopeLabel(label.scope))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectLabel(id: label.id)
                showEditor()
            }
            .accessibilityAction(named: "Edit label") {
                viewModel.selectLabel(id: label.id)
                showEditor()
            }
            #endif
        }
        .accessibilityLabel("\(label.title), \(scopeLabel(label.scope))")
    }
}

struct MailLabelEmptyListContent: View {
    // The shared 240-point list pane after its 16-point horizontal padding.
    private static let maximumContentWidth: CGFloat = 208

    var body: some View {
        ContentUnavailableView(
            "No Labels",
            systemImage: "tag",
            description: Text("Create a label to organize mail.")
        )
        .fixedSize(horizontal: false, vertical: true)
        #if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        .frame(maxWidth: Self.maximumContentWidth, maxHeight: .infinity)
        #endif
        .clipped()
    }
}

private struct MailLabelEditor: View {
    @ObservedObject var viewModel: MailLabelsViewModel

    var body: some View {
        Form {
            Section("Label") {
                TextField("Title", text: draftBinding(\.title, default: ""))
                Toggle(
                    "Use in Smart Inbox",
                    isOn: Binding(
                        get: { viewModel.draft?.isSmartInboxEnabled == true },
                        set: { viewModel.setSmartInboxEnabled($0) }
                    )
                )
                LabeledContent("Scope", value: scopeText)
            }
            Section("Classification Description") {
                TextEditor(text: draftBinding(\.description, default: ""))
                    .frame(minHeight: 88)
                HStack {
                    Spacer()
                    Text("\(viewModel.draft?.description.count ?? 0) / 280")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = viewModel.validationMessage {
                Text(message).foregroundStyle(.red)
            }
            if let progress = viewModel.progress {
                Text(progress.summary).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save Label") {
                    Task { await viewModel.save() }
                }
                .buttonStyle(.borderedProminent)
                if viewModel.draft?.existingLabelID != nil {
                    Button("Reclassify Existing") {
                        Task { await viewModel.previewReclassification() }
                    }
                    Button("Delete", role: .destructive) {
                        Task { await viewModel.previewDeletion() }
                    }
                }
                if viewModel.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .padding(8)
    }

    private var scopeText: String {
        guard let draft = viewModel.draft else { return "" }
        return viewModel.scopeDisplayName(draft.scope)
    }

    private func draftBinding<T>(
        _ keyPath: WritableKeyPath<MailLabelDraft, T>,
        default value: T
    ) -> Binding<T> {
        Binding(
            get: { viewModel.draft?[keyPath: keyPath] ?? value },
            set: { newValue in
                guard var draft = viewModel.draft else { return }
                draft[keyPath: keyPath] = newValue
                viewModel.draft = draft
            }
        )
    }
}

@_spi(DesignPreview)
public struct MailLabelConfirmationDesignPreview: View {
    @ObservedObject private var viewModel: MailLabelsViewModel

    public init(viewModel: MailLabelsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let confirmation = viewModel.confirmation {
            MailLabelConfirmationSheet(
                viewModel: viewModel,
                confirmation: confirmation
            )
        }
    }
}

private struct MailLabelConfirmationSheet: View {
    @ObservedObject var viewModel: MailLabelsViewModel
    let confirmation: MailLabelConfirmation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(detail)
            List {
                switch confirmation {
                case .disableForEmptyDescription:
                    LabeledContent("Smart Inbox", value: "Will be disabled")
                case .reclassify(let preview):
                    LabeledContent("Scope", value: scopeText(preview.scope))
                    LabeledContent("Messages", value: "\(preview.affectedMessageCount)")
                    LabeledContent("Updates", value: "Category and Smart Inbox labels")
                case .delete(let preview):
                    LabeledContent("Scope", value: scopeText(preview.scope))
                    LabeledContent("Messages", value: "\(preview.affectedMessageCount)")
                    LabeledContent("Mail Rules", value: "\(preview.affectedRuleCount)")
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.dismissConfirmation()
                    dismiss()
                }
                if case .delete = confirmation {
                    Button("Delete", role: .destructive) {
                        confirm()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(confirmButtonTitle) {
                        confirm()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        #if os(iOS)
        .frame(maxWidth: .infinity, minHeight: 420)
        #else
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    private var title: String {
        switch confirmation {
        case .disableForEmptyDescription:
            "Disable Smart Inbox for This Label?"
        case .reclassify:
            "Reclassify Existing Mail?"
        case .delete:
            "Delete Label?"
        }
    }

    private var detail: String {
        switch confirmation {
        case .disableForEmptyDescription:
            "A description is required for Smart Inbox classification. Saving will disable Smart Inbox for this label."
        case .reclassify:
            "Unified Smart Inbox classification will update the built-in category and all Smart Inbox-owned labels in this scope."
        case .delete:
            "Assignments and exclusions will be removed. Affected label-only Mail Rules will be disabled."
        }
    }

    private var confirmButtonTitle: String {
        switch confirmation {
        case .disableForEmptyDescription: "Disable and Save"
        case .reclassify: "Reclassify"
        case .delete: "Delete"
        }
    }

    private func confirm() {
        Task {
            switch confirmation {
            case .disableForEmptyDescription:
                await viewModel.confirmDescriptionClearAndSave()
            case .reclassify:
                await viewModel.confirmReclassification()
            case .delete:
                await viewModel.confirmDeletion()
            }
            dismiss()
        }
    }

    private func scopeText(_ scope: MailLabelScope) -> String {
        viewModel.scopeDisplayName(scope)
    }
}

public struct MailRulesSettingsPanel: View {
    @ObservedObject var viewModel: MailRulesViewModel

    public init(viewModel: MailRulesViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        AccountScopedManagementPanel(
            selection: Binding(
                get: { viewModel.selection },
                set: { viewModel.selectAccount($0) }
            ),
            accounts: viewModel.accounts,
            itemTitle: "Rules",
            addAccessibilityLabel: "Add mail rule",
            add: viewModel.beginAddingRule,
            isConfirmationPresented: Binding(
                get: { viewModel.existingPreview != nil },
                set: { if !$0 { viewModel.dismissExistingPreview() } }
            ),
            isEditorPresented: Binding(
                get: { viewModel.draft != nil },
                set: { presented in
                    if !presented {
                        viewModel.selectedRuleID = nil
                        viewModel.draft = nil
                    }
                }
            )
        ) { showEditor in
            #if os(iOS)
            if viewModel.visibleRules.isEmpty {
                ContentUnavailableView(
                    "No Mail Rules",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Add a rule to reduce inbox noise.")
                )
            } else {
                ForEach(viewModel.visibleRules) { rule in
                    ruleRow(rule, showEditor: showEditor)
                }
            }
            #else
            if viewModel.visibleRules.isEmpty {
                ContentUnavailableView(
                    "No Mail Rules",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Add a rule to reduce inbox noise.")
                )
            } else {
                List(viewModel.visibleRules, selection: selectedRule(openEditor: showEditor)) { rule in
                    ruleRow(rule, showEditor: showEditor)
                        .tag(rule.id)
                }
                .listStyle(.inset)
            }
            #endif
        } editorContent: {
            Group {
                if viewModel.draft != nil {
                    MailRuleEditor(viewModel: viewModel)
                } else {
                    ContentUnavailableView(
                        "Select a Rule",
                        systemImage: "slider.horizontal.3",
                        description: Text("Choose a rule or add a new one.")
                    )
                }
            }
        } confirmation: {
            if let preview = viewModel.existingPreview {
                MailRuleExistingConfirmation(viewModel: viewModel, preview: preview)
            }
        }
        .onAppear {
            viewModel.reload()
            if viewModel.selectedRuleID == nil, let first = viewModel.visibleRules.first {
                viewModel.selectRule(id: first.id)
            }
        }
    }

    private func selectedRule(openEditor: @escaping () -> Void) -> Binding<String?> {
        Binding(
            get: { viewModel.selectedRuleID },
            set: {
                if let id = $0 {
                    viewModel.selectRule(id: id)
                    openEditor()
                }
            }
        )
    }

    private func scopeLabel(_ scope: MailRuleScope) -> String {
        switch scope {
        case .allAccounts: "All Accounts"
        case .account(let id): viewModel.accounts.first { $0.id == id }?.displayName ?? "This Account"
        }
    }

    private func ruleRow(_ rule: MailRule, showEditor: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { viewModel.setEnabled(id: rule.id, isEnabled: $0) }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name).lineLimit(1)
                Text(scopeLabel(rule.scope))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectRule(id: rule.id)
                showEditor()
            }
            .accessibilityAction(named: "Edit rule") {
                viewModel.selectRule(id: rule.id)
                showEditor()
            }
            #endif
        }
        .accessibilityLabel("\(rule.name), \(scopeLabel(rule.scope))")
    }
}

private struct MailRuleEditor: View {
    @ObservedObject var viewModel: MailRulesViewModel

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Rule name", text: draftBinding(\.name, default: ""))
                Toggle("Enabled", isOn: draftBinding(\.isEnabled, default: true))
                LabeledContent("Scope", value: scopeText)
            }
            Section("Match all conditions") {
                if let draft = viewModel.draft {
                    ForEach(Array(draft.conditions.enumerated()), id: \.element.id) { index, condition in
                        #if os(iOS)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Condition \(index + 1)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button(role: .destructive) { removeCondition(index) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove condition")
                            }
                            Picker("Field", selection: conditionBinding(index, \.field, condition.field)) {
                                ForEach(MailRuleConditionField.allCases, id: \.self) {
                                    Text(fieldTitle($0)).tag($0)
                                }
                            }
                            Picker("Match", selection: conditionBinding(index, \.operator, condition.operator)) {
                                ForEach(validOperators(for: condition.field), id: \.self) {
                                    Text(operatorTitle($0)).tag($0)
                                }
                            }
                            TextField("Value", text: conditionBinding(index, \.value, condition.value))
                                .textFieldStyle(.roundedBorder)
                        }
                        #else
                        HStack {
                            Picker("Field", selection: conditionBinding(index, \.field, condition.field)) {
                                ForEach(MailRuleConditionField.allCases, id: \.self) {
                                    Text(fieldTitle($0)).tag($0)
                                }
                            }
                            Picker("Match", selection: conditionBinding(index, \.operator, condition.operator)) {
                                ForEach(validOperators(for: condition.field), id: \.self) {
                                    Text(operatorTitle($0)).tag($0)
                                }
                            }
                            TextField("Value", text: conditionBinding(index, \.value, condition.value))
                            Button(role: .destructive) { removeCondition(index) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove condition")
                        }
                        #endif
                    }
                }
                Button("Add Condition", systemImage: "plus") { addCondition() }
            }
            Section("Actions") {
                ForEach(MailRuleAction.allCases, id: \.self) { action in
                    Toggle(actionTitle(action), isOn: actionBinding(action))
                }
            }
            if !viewModel.availableLabelActions.isEmpty {
                Section("Labels") {
                    ForEach(viewModel.availableLabelActions) { label in
                        Toggle(label.title, isOn: labelBinding(label.id))
                    }
                }
            }
            if let message = viewModel.validationMessage {
                Text(message).foregroundStyle(.red)
            }
            if let run = viewModel.activeRun {
                Text("Queued \(run.enqueuedItemCount) of \(run.totalItemCount) existing messages")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Save Rule") { viewModel.saveDraft() }
                    .buttonStyle(.borderedProminent)
                if viewModel.draft?.existingRuleID != nil {
                    Button("Apply to Existing") {
                        Task { await viewModel.previewExisting() }
                    }
                    Button("Delete", role: .destructive) { viewModel.deleteSelectedRule() }
                }
                if viewModel.isWorking { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .padding(8)
    }

    private var scopeText: String {
        guard let draft = viewModel.draft else { return "" }
        return switch draft.scope {
        case .allAccounts: "All Accounts"
        case .account: "Selected Account"
        }
    }

    private func draftBinding<T>(_ keyPath: WritableKeyPath<MailRuleDraft, T>, default value: T) -> Binding<T> {
        Binding(
            get: { viewModel.draft?[keyPath: keyPath] ?? value },
            set: { newValue in
                guard var draft = viewModel.draft else { return }
                draft[keyPath: keyPath] = newValue
                viewModel.draft = draft
            }
        )
    }

    private func conditionBinding<T>(
        _ index: Int,
        _ keyPath: KeyPath<MailRuleCondition, T>,
        _ fallback: T
    ) -> Binding<T> {
        Binding(
            get: { viewModel.draft?.conditions[safe: index]?[keyPath: keyPath] ?? fallback },
            set: { newValue in updateCondition(index, keyPath: keyPath, value: newValue) }
        )
    }

    private func updateCondition<T>(_ index: Int, keyPath: KeyPath<MailRuleCondition, T>, value: T) {
        guard var draft = viewModel.draft, draft.conditions.indices.contains(index) else { return }
        let old = draft.conditions[index]
        let field = keyPath == \MailRuleCondition.field ? value as! MailRuleConditionField : old.field
        let op = keyPath == \MailRuleCondition.operator ? value as! MailRuleConditionOperator : old.operator
        let text = keyPath == \MailRuleCondition.value ? value as! String : old.value
        draft.conditions[index] = .init(id: old.id, field: field, operator: op, value: text)
        viewModel.draft = draft
    }

    private func addCondition() {
        guard var draft = viewModel.draft else { return }
        draft.conditions.append(.init(field: .from, operator: .emailIs, value: ""))
        viewModel.draft = draft
    }

    private func removeCondition(_ index: Int) {
        guard var draft = viewModel.draft, draft.conditions.indices.contains(index) else { return }
        draft.conditions.remove(at: index)
        viewModel.draft = draft
    }

    private func actionBinding(_ action: MailRuleAction) -> Binding<Bool> {
        Binding(
            get: { viewModel.draft?.actions.contains(action) == true },
            set: { enabled in
                guard var draft = viewModel.draft else { return }
                if enabled { draft.actions.insert(action) } else { draft.actions.remove(action) }
                viewModel.draft = draft
            }
        )
    }

    private func labelBinding(_ labelID: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.draft?.selectedLabelIDs.contains(labelID) == true },
            set: { enabled in
                guard var draft = viewModel.draft else { return }
                if enabled {
                    draft.selectedLabelIDs.insert(labelID)
                } else {
                    draft.selectedLabelIDs.remove(labelID)
                }
                viewModel.draft = draft
            }
        )
    }

    private func validOperators(for field: MailRuleConditionField) -> [MailRuleConditionOperator] {
        field == .subject ? [.contains] : [.emailIs, .domainIs]
    }

    private func fieldTitle(_ field: MailRuleConditionField) -> String {
        switch field { case .from: "From"; case .recipients: "To / Cc"; case .subject: "Subject" }
    }

    private func operatorTitle(_ op: MailRuleConditionOperator) -> String {
        switch op { case .emailIs: "is email"; case .domainIs: "is domain"; case .contains: "contains" }
    }

    private func actionTitle(_ action: MailRuleAction) -> String {
        switch action {
        case .skipInbox: "Skip Inbox (Archive)"
        case .markAsRead: "Mark as Read"
        case .suppressNotification: "Suppress Notification"
        }
    }
}

private struct MailRuleExistingConfirmation: View {
    @ObservedObject var viewModel: MailRulesViewModel
    let preview: MailRuleExistingPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply Rule to Existing Mail?").font(.title2.bold())
            Text("\(preview.matches.count) messages match: \(preview.archiveCount) will be archived and \(preview.markReadCount) marked read.")
            List(preview.matches.prefix(100)) { match in
                VStack(alignment: .leading) {
                    Text(match.subject).lineLimit(1)
                    Text(match.sender.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.dismissExistingPreview(); dismiss() }
                Button("Apply") {
                    Task { await viewModel.confirmApplyExisting(); dismiss() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        #if os(iOS)
        .frame(maxWidth: .infinity, minHeight: 420)
        #else
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
