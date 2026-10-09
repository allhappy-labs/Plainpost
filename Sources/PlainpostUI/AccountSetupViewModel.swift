import Foundation
import PlainpostAccountRuntime
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostServiceIPC

public protocol AccountSetupHandling: Sendable {
    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult
    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult
    func addGoogleAccount(
        displayName: String,
        email: EmailAddress,
        authorization: GmailAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult
    func reauthorizeGoogleAccount(
        accountID: AccountID,
        email: EmailAddress,
        authorization: GmailAuthorizationCode
    ) async throws

    /// Removes a just-published Direct Gmail account when the user cancelled
    /// while the setup result was crossing back to the UI.
    func discardAddedGoogleAccount(accountID: AccountID) async throws
    func addMicrosoftAccount(
        displayName: String, email: EmailAddress, authorization: MicrosoftAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult
    func discardAddedMicrosoftAccount(accountID: AccountID) async throws
    func reauthorizeMicrosoftAccount(
        accountID: AccountID, email: EmailAddress, authorization: MicrosoftAuthorizationCode
    ) async throws
}

/// Thrown by account setup handlers that do not support a capability, for
/// example fixtures without Google sign-in.
public enum AccountSetupHandlingError: Error, Equatable, Sendable {
    case unsupported
}

public extension AccountSetupHandling {
    /// Adds a Gmail account from a Google authorization code. The handler
    /// exchanges the code, checks the Google identity against `email`, and hands
    /// only the resulting grant to the service.
    func addGoogleAccount(
        displayName: String,
        email: EmailAddress,
        authorization: GmailAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        throw AccountSetupHandlingError.unsupported
    }

    /// Replaces an existing Gmail account's Google grant ("Reauthorize Gmail"),
    /// converting an App Password account to Google sign-in.
    func reauthorizeGoogleAccount(
        accountID: AccountID,
        email: EmailAddress,
        authorization: GmailAuthorizationCode
    ) async throws {
        throw AccountSetupHandlingError.unsupported
    }

    func discardAddedGoogleAccount(accountID: AccountID) async throws {
        throw AccountSetupHandlingError.unsupported
    }

    func addMicrosoftAccount(
        displayName: String, email: EmailAddress, authorization: MicrosoftAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult { throw AccountSetupHandlingError.unsupported }

    func discardAddedMicrosoftAccount(accountID: AccountID) async throws {
        throw AccountSetupHandlingError.unsupported
    }

    func reauthorizeMicrosoftAccount(
        accountID: AccountID, email: EmailAddress, authorization: MicrosoftAuthorizationCode
    ) async throws { throw AccountSetupHandlingError.unsupported }
}

extension AccountSetupService: AccountSetupHandling {}

public enum GmailSignInState: Equatable, Sendable {
    case idle
    case waitingForBrowser
    case verifying
    /// This build has no registered OAuth client for the selected provider.
    case unavailable
    case failed(String)
}

/// The account's Direct-mode authentication as the Mac UI shows it.
public struct AccountAuthenticationSummary: Equatable, Sendable {
    public let method: AccountAuthenticationMethod
    public let state: AccountAuthenticationState

    public init(method: AccountAuthenticationMethod, state: AccountAuthenticationState) {
        self.method = method
        self.state = state
    }
}

public enum AccountSetupStatus: Equatable, Sendable {
    case idle
    case validating
    case syncing(progress: IMAPSyncProgress)
    case connected(accountID: String)
    case failed(message: String)
}

public struct AccountSetupCompletedAddEvent: Equatable, Sendable {
    public let id: UUID
    public let accountID: AccountID

    public init(accountID: AccountID) {
        self.id = UUID()
        self.accountID = accountID
    }
}

@MainActor
public final class AccountSetupViewModel: ObservableObject {
    @Published public private(set) var selectedProvider: MailProviderKind?
    @Published public var displayName: String
    @Published public var email: String
    @Published public var imapHost: String
    @Published public var imapPort: String
    @Published public var smtpHost: String
    @Published public var smtpPort: String
    @Published public var username: String
    @Published public var imapPassword: String
    @Published public var smtpPassword: String
    @Published public var gmailAppPassword: String
    @Published public var icloudAppPassword: String
    @Published public private(set) var isSubmitting: Bool
    @Published public private(set) var isSyncing: Bool
    @Published public private(set) var isSavingAccountCredentials: Bool
    @Published public private(set) var isDeletingAccount: Bool
    @Published public private(set) var status: AccountSetupStatus
    @Published public private(set) var completedAddEvent: AccountSetupCompletedAddEvent?
    @Published public private(set) var lastConnectedEmail: String?
    @Published public private(set) var account: Account?
    @Published public private(set) var accounts: [Account]
    @Published public private(set) var lastSyncedMessageCount: Int?
    @Published public private(set) var lastSyncError: String?
    @Published public private(set) var accountSettingsMessage: String?
    /// Whether the last account-settings save (name or servers) failed, so pages can show
    /// `accountSettingsMessage` as an error without parsing it.
    @Published public private(set) var accountSettingsSaveFailed = false
    @Published public private(set) var googleSetupRecoveryMessage: String?
    @Published public private(set) var googleSetupRecoveryAccountID: AccountID?
    @Published public private(set) var microsoftSetupRecoveryMessage: String?
    @Published public private(set) var microsoftSetupRecoveryAccountID: AccountID?
    @Published public private(set) var credentialSettingsMessage: String?
    @Published public private(set) var accountDeletionMessage: String?
    @Published public var downloadCompleteHistory: Bool
    @Published public var recentMessageLimit: Int
    @Published public var realTimeMonitoringEnabled: Bool
    @Published public private(set) var mailboxModes: [String: MailboxSyncMode]
    @Published public private(set) var mailboxSyncStatuses: [MailboxSyncStatus]
    @Published public private(set) var gmailSignInState: GmailSignInState
    @Published public private(set) var microsoftSignInState: GmailSignInState
    @Published public private(set) var accountAuthentications: [AccountID: AccountAuthenticationSummary]
    /// Each Sync Node account's sign-in on this device; Direct accounts have none.
    @Published public private(set) var syncNodeSignIns: [AccountID: SyncNodeSignIn] = [:]
    @Published public private(set) var gmailReauthorizationMessage: String?
    @Published public private(set) var microsoftReauthorizationMessage: String?
    @Published public private(set) var reauthorizingAccountID: AccountID?

    /// Opens Google consent for a login hint and returns the loopback
    /// authorization code. `nil` means Google sign-in isn't available in this
    /// build. Cancelling the calling task cancels the authorization.
    public var googleAuthorization: (@MainActor @Sendable (String) async throws -> GmailAuthorizationCode)? {
        didSet { refreshGmailAvailability() }
    }
    public var microsoftAuthorization: (@MainActor @Sendable (String) async throws -> MicrosoftAuthorizationCode)? {
        didSet { microsoftSignInState = microsoftAuthorization == nil ? .unavailable : .idle }
    }

    private let setup: AccountSetupHandling
    private let accountAuthenticationProvider: (@Sendable (AccountID) throws -> AccountAuthenticationSummary)?
    private let syncNodeSignInProvider: (@Sendable (AccountID) async -> SyncNodeSignIn?)?
    private var googleSignInTask: Task<Void, Never>?
    private var googleSignInGeneration: UInt64 = 0
    private var microsoftSignInTask: Task<Void, Never>?
    private var microsoftSignInGeneration: UInt64 = 0
    private let accountsProvider: (@Sendable () throws -> [Account])?
    private let accountSaver: (@Sendable (Account) throws -> Void)?
    private let accountCredentialSaver: (@Sendable (AccountID, String, String) async throws -> Void)?
    private let accountDeleter: (@Sendable (AccountID) async throws -> Void)?
    private let syncPreferencesProvider: (@Sendable (AccountID) throws -> MailSyncPreferences?)?
    private let mailboxPreferencesProvider: (@Sendable (AccountID) throws -> [MailboxSyncPreference])?
    private let mailboxPathsProvider: (@Sendable (AccountID) throws -> [String])?
    private let syncPreferencesSaver: (@Sendable (MailSyncPreferences) throws -> Void)?
    private let mailboxPreferenceSaver: (@Sendable (MailboxSyncPreference) throws -> Void)?
    private let mailboxStatusProvider: (@Sendable () throws -> [MailboxSyncStatus])?
    private let accountMailboxStatusProvider: (@Sendable (AccountID) throws -> [MailboxSyncStatus])?
    private var accountConfigurationGeneration: UInt64
    private let onCompletedAdd: @MainActor (AccountID) -> Void

    public init(
        setup: AccountSetupHandling,
        selectedProvider: MailProviderKind? = nil,
        displayName: String = "",
        email: String = "",
        imapHost: String = "",
        imapPort: String = "993",
        smtpHost: String = "",
        smtpPort: String = "587",
        username: String = "",
        imapPassword: String = "",
        smtpPassword: String = "",
        gmailAppPassword: String = "",
        icloudAppPassword: String = "",
        status: AccountSetupStatus = .idle,
        lastConnectedEmail: String? = nil,
        account: Account? = nil,
        accounts: [Account] = [],
        lastSyncedMessageCount: Int? = nil,
        lastSyncError: String? = nil,
        accountsProvider: (@Sendable () throws -> [Account])? = nil,
        accountSaver: (@Sendable (Account) throws -> Void)? = nil,
        accountCredentialSaver: (@Sendable (AccountID, String, String) async throws -> Void)? = nil,
        accountDeleter: (@Sendable (AccountID) async throws -> Void)? = nil,
        syncPreferences: MailSyncPreferences? = nil,
        syncPreferencesProvider: (@Sendable (AccountID) throws -> MailSyncPreferences?)? = nil,
        syncPreferencesSaver: (@Sendable (MailSyncPreferences) throws -> Void)? = nil,
        mailboxPreferences: [MailboxSyncPreference] = [],
        availableMailboxPaths: [String] = ["INBOX"],
        mailboxPreferencesProvider: (@Sendable (AccountID) throws -> [MailboxSyncPreference])? = nil,
        mailboxPathsProvider: (@Sendable (AccountID) throws -> [String])? = nil,
        mailboxPreferenceSaver: (@Sendable (MailboxSyncPreference) throws -> Void)? = nil,
        mailboxSyncStatuses: [MailboxSyncStatus] = [],
        mailboxStatusProvider: (@Sendable () throws -> [MailboxSyncStatus])? = nil,
        accountMailboxStatusProvider: (@Sendable (AccountID) throws -> [MailboxSyncStatus])? = nil,
        googleAuthorization: (@MainActor @Sendable (String) async throws -> GmailAuthorizationCode)? = nil,
        microsoftAuthorization: (@MainActor @Sendable (String) async throws -> MicrosoftAuthorizationCode)? = nil,
        accountAuthenticationProvider: (@Sendable (AccountID) throws -> AccountAuthenticationSummary)? = nil,
        syncNodeSignInProvider: (@Sendable (AccountID) async -> SyncNodeSignIn?)? = nil,
        onCompletedAdd: @escaping @MainActor (AccountID) -> Void = { _ in }
    ) {
        self.setup = setup
        self.syncNodeSignInProvider = syncNodeSignInProvider
        self.googleAuthorization = googleAuthorization
        self.microsoftAuthorization = microsoftAuthorization
        self.accountAuthenticationProvider = accountAuthenticationProvider
        self.gmailSignInState = googleAuthorization == nil ? .unavailable : .idle
        self.microsoftSignInState = microsoftAuthorization == nil ? .unavailable : .idle
        self.accountAuthentications = [:]
        self.gmailReauthorizationMessage = nil
        self.microsoftReauthorizationMessage = nil
        self.reauthorizingAccountID = nil
        self.selectedProvider = selectedProvider
        self.displayName = displayName
        self.email = email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.username = username
        self.imapPassword = imapPassword
        self.smtpPassword = smtpPassword
        self.gmailAppPassword = gmailAppPassword
        self.icloudAppPassword = icloudAppPassword
        self.isSubmitting = false
        self.isSyncing = false
        self.isSavingAccountCredentials = false
        self.isDeletingAccount = false
        self.status = status
        self.completedAddEvent = nil
        self.onCompletedAdd = onCompletedAdd
        self.lastConnectedEmail = lastConnectedEmail
        self.account = account
        self.accounts = accounts.isEmpty ? [account].compactMap { $0 } : accounts
        self.lastSyncedMessageCount = lastSyncedMessageCount
        self.lastSyncError = lastSyncError
        self.accountSettingsMessage = nil
        self.accountSettingsSaveFailed = false
        self.googleSetupRecoveryMessage = nil
        self.googleSetupRecoveryAccountID = nil
        self.microsoftSetupRecoveryMessage = nil
        self.microsoftSetupRecoveryAccountID = nil
        self.credentialSettingsMessage = nil
        self.accountDeletionMessage = nil
        self.downloadCompleteHistory = syncPreferences?.downloadCompleteHistory ?? false
        self.recentMessageLimit = syncPreferences?.recentMessageLimit ?? 100
        self.realTimeMonitoringEnabled = syncPreferences?.realTimeMonitoringEnabled ?? true
        self.accountsProvider = accountsProvider
        self.accountSaver = accountSaver
        self.accountCredentialSaver = accountCredentialSaver
        self.accountDeleter = accountDeleter
        self.syncPreferencesProvider = syncPreferencesProvider
        self.syncPreferencesSaver = syncPreferencesSaver
        self.mailboxModes = MailboxSyncSelection.effectiveModes(
            availableMailboxPaths: availableMailboxPaths,
            preferences: mailboxPreferences
        )
        self.mailboxPreferencesProvider = mailboxPreferencesProvider
        self.mailboxPathsProvider = mailboxPathsProvider
        self.mailboxPreferenceSaver = mailboxPreferenceSaver
        self.mailboxSyncStatuses = mailboxSyncStatuses
        self.mailboxStatusProvider = mailboxStatusProvider
        self.accountMailboxStatusProvider = accountMailboxStatusProvider
        self.accountConfigurationGeneration = 0
        refreshAccountAuthentications()
    }

    /// Applies an account-scope store change, whichever process committed it:
    /// the service marks a refused Google grant and posts `.accounts` from its
    /// own process. The surface's single `MailStoreChangeMonitor` calls this;
    /// this model deliberately observes no notifications itself, so one signal
    /// never costs two reads of the store.
    public func applyAccountStoreChange() {
        refreshAccountAuthentications()
        refreshMailboxSyncStatuses()
    }

    public var isConnectDisabled: Bool {
        if selectedProvider == .icloud {
            return isSubmitting || displayName.trimmedForAccountSetup.isEmpty
                || !isGmailEmailValid || !isICloudAppPasswordValid
        }
        if selectedProvider == .gmail {
            return isSubmitting ||
                displayName.trimmedForAccountSetup.isEmpty ||
                !isGmailEmailValid ||
                !isGmailAppPasswordValid
        }
        return isSubmitting ||
            displayName.trimmedForAccountSetup.isEmpty ||
            email.trimmedForAccountSetup.isEmpty ||
            imapHost.trimmedForAccountSetup.isEmpty ||
            smtpHost.trimmedForAccountSetup.isEmpty ||
            username.trimmedForAccountSetup.isEmpty ||
            imapPassword.isEmpty ||
            smtpPassword.isEmpty
    }

    public var gmailAppPasswordCharacterCount: Int {
        MailProviderProfile.gmail.normalizedAppPassword(gmailAppPassword).count
    }

    public var isGmailEmailValid: Bool {
        let value = email.trimmedForAccountSetup
        guard !value.isEmpty,
              !value.contains(where: \Character.isWhitespace)
        else { return false }

        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let domain = String(parts[1])
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    public var isGmailAppPasswordValid: Bool {
        MailProviderProfile.gmail.isValidAppPassword(gmailAppPassword)
    }

    public var isICloudAppPasswordValid: Bool {
        !MailProviderProfile.icloud.normalizedAppPassword(icloudAppPassword).isEmpty
    }

    public var icloudReadinessMessage: String {
        if displayName.trimmedForAccountSetup.isEmpty { return "Enter the name shown to recipients." }
        if !isGmailEmailValid { return "Enter your full iCloud Mail email address." }
        if !isICloudAppPasswordValid { return "Paste an Apple app-specific password." }
        return "Ready to connect securely."
    }

    public var gmailReadinessMessage: String {
        if displayName.trimmedForAccountSetup.isEmpty {
            return "Enter the name shown to recipients."
        }
        if !isGmailEmailValid {
            return "Enter a valid Google account email address."
        }
        if gmailAppPasswordCharacterCount == 0 {
            return "Create and paste a Google App Password."
        }
        if !isGmailAppPasswordValid {
            return "The App Password must contain 16 characters."
        }
        return "Ready to connect securely."
    }

    public func submit() async throws {
        if selectedProvider == .icloud {
            guard !displayName.trimmedForAccountSetup.isEmpty, isGmailEmailValid,
                  isICloudAppPasswordValid else {
                status = .failed(message: icloudReadinessMessage)
                return
            }
            try await submit(
                MailProviderProfile.icloud.makeRequest(
                    displayName: displayName.trimmedForAccountSetup,
                    email: EmailAddress(email.trimmedForAccountSetup),
                    appPassword: icloudAppPassword
                ),
                provider: .icloud
            )
            return
        }
        if selectedProvider == .gmail {
            let normalizedPassword = MailProviderProfile.gmail.normalizedAppPassword(gmailAppPassword)
            guard MailProviderProfile.gmail.isValidAppPassword(gmailAppPassword) else {
                status = .failed(message: "Enter the 16-character Google App Password.")
                return
            }
            guard !displayName.trimmedForAccountSetup.isEmpty,
                  isGmailEmailValid
            else {
                status = .failed(message: "Enter your name and a valid Google account email address.")
                return
            }

            try await submit(
                MailProviderProfile.gmail.makeRequest(
                    displayName: displayName.trimmedForAccountSetup,
                    email: EmailAddress(email.trimmedForAccountSetup),
                    appPassword: normalizedPassword
                ),
                provider: .gmail
            )
            return
        }

        guard let parsedIMAPPort = UInt16(imapPort.trimmedForAccountSetup),
              let parsedSMTPPort = Int(smtpPort.trimmedForAccountSetup),
              (1...65535).contains(parsedSMTPPort)
        else {
            status = .failed(message: "Enter valid IMAP and SMTP ports.")
            return
        }

        try await submit(
            AccountSetupRequest(
                displayName: displayName.trimmedForAccountSetup,
                email: EmailAddress(email.trimmedForAccountSetup),
                imapHost: imapHost.trimmedForAccountSetup,
                imapPort: parsedIMAPPort,
                smtpHost: smtpHost.trimmedForAccountSetup,
                smtpPort: parsedSMTPPort,
                username: username.trimmedForAccountSetup,
                imapPassword: imapPassword,
                smtpPassword: smtpPassword
            ),
            provider: selectedProvider
        )
    }

    public func selectProvider(_ provider: MailProviderKind) {
        cancelGoogleSignIn()
        cancelMicrosoftSignIn()
        selectedProvider = provider
        status = .idle
    }

    // MARK: Google sign-in

    /// Guided Gmail setup signs in with Google; App Passwords are entered only
    /// through "Other IMAP account".
    public var gmailSetupRequiresAppPassword: Bool { false }

    public var isGoogleSignInAvailable: Bool { googleAuthorization != nil }
    public var isMicrosoftSignInAvailable: Bool { microsoftAuthorization != nil }
    public var isMicrosoftSignInInProgress: Bool {
        microsoftSignInState == .waitingForBrowser || microsoftSignInState == .verifying
    }
    public var isMicrosoftSignInDisabled: Bool {
        !isMicrosoftSignInAvailable || isMicrosoftSignInInProgress || isSubmitting
            || displayName.trimmedForAccountSetup.isEmpty || !isGmailEmailValid
    }
    public static let microsoftSignInUnavailableMessage = "Microsoft sign-in isn't available in this build."
    public var microsoftSignInReadinessMessage: String {
        switch microsoftSignInState {
        case .unavailable: Self.microsoftSignInUnavailableMessage
        case .waitingForBrowser: "Finish signing in with Microsoft in your browser."
        case .verifying: "Checking Microsoft account and mail access…"
        case .failed(let message): message
        case .idle:
            displayName.trimmedForAccountSetup.isEmpty ? "Enter the name shown to recipients."
                : (!isGmailEmailValid ? "Enter a valid Microsoft account email address."
                   : "Ready to sign in with Microsoft.")
        }
    }

    public var gmailProviderDetail: String {
        "Sign in with Google. No App Password needed."
    }

    public var otherIMAPDetail: String {
        "Enter custom incoming and outgoing mail server settings. Use this for Gmail App Passwords."
    }

    public var isGoogleSignInInProgress: Bool {
        gmailSignInState == .waitingForBrowser || gmailSignInState == .verifying
    }

    public var isGoogleSignInDisabled: Bool {
        #if os(iOS)
        return !isGoogleSignInAvailable || isGoogleSignInInProgress || isSubmitting
        #else
        !isGoogleSignInAvailable || isGoogleSignInInProgress || isSubmitting
            || displayName.trimmedForAccountSetup.isEmpty || !isGmailEmailValid
        #endif
    }

    public var gmailSignInReadinessMessage: String {
        switch gmailSignInState {
        case .unavailable:
            return Self.googleSignInUnavailableMessage
        case .waitingForBrowser:
            return "Finish signing in with Google in your browser."
        case .verifying:
            return "Checking your Google account and Gmail access…"
        case .failed(let message):
            return message
        case .idle:
            #if os(iOS)
            return "Sign in with Google to connect Gmail."
            #else
            if displayName.trimmedForAccountSetup.isEmpty {
                return "Enter the name shown to recipients."
            }
            if !isGmailEmailValid {
                return "Enter a valid Google account email address."
            }
            return "Ready to sign in with Google."
            #endif
        }
    }

    public static let googleSignInUnavailableMessage = "Google sign-in isn't available in this build."

    /// Accounts whose Google grant was refused and need "Reauthorize Gmail".
    public var reauthorizationRequiredAccountIDs: [AccountID] {
        accounts.map(\.id).filter { accountAuthentications[$0]?.state == .reauthorizationRequired }
    }

    public var isSelectedAccountGoogleOAuth: Bool {
        guard let account else { return false }
        return accountAuthentications[account.id]?.method == .googleOAuth
    }

    public var isSelectedAccountMicrosoftOAuth: Bool {
        guard let account else { return false }
        return accountAuthentications[account.id]?.method == .microsoftOAuth
    }

    public var isSelectedAccountOAuth: Bool {
        isSelectedAccountGoogleOAuth || isSelectedAccountMicrosoftOAuth
    }

    public func needsReauthorization(_ accountID: AccountID) -> Bool {
        accountAuthentications[accountID]?.state == .reauthorizationRequired
    }

    /// The account list label: the address, marked when Gmail needs the user to sign in again.
    public func accountListTitle(for account: Account) -> String {
        needsReauthorization(account.id)
            ? "\(account.email.rawValue) — Needs you to sign in again"
            : account.email.rawValue
    }

    public var selectedAccountNeedsReauthorization: Bool {
        guard let account else { return false }
        return accountAuthentications[account.id]?.state == .reauthorizationRequired
    }

    /// A password account asked to sign in again: "Start Over with Saved
    /// Sign-ins" set its saved password aside, so it needs the password again.
    public var selectedAccountNeedsPasswordAgain: Bool {
        selectedAccountNeedsReauthorization && !isSelectedAccountOAuth
    }

    /// Opens Google sign-in for the entered address, then adds the Gmail
    /// account through the setup handler. Only a successful, identity-checked
    /// grant reaches the service.
    public func signInWithGoogle() async {
        guard !isGoogleSignInInProgress, !isSubmitting else { return }
        guard let googleAuthorization else {
            gmailSignInState = .unavailable
            status = .failed(message: Self.googleSignInUnavailableMessage)
            return
        }
        #if os(iOS)
        // The iPhone presents no manual Gmail fields. A prefilled value may
        // still be supplied by a deep link or test; the verified Google
        // profile remains the account identity in the local setup handler.
        let name = displayName.trimmedForAccountSetup
        let emailAddress = EmailAddress(email.trimmedForAccountSetup)
        #else
        let name = displayName.trimmedForAccountSetup
        guard !name.isEmpty, isGmailEmailValid else {
            status = .failed(message: "Enter your name and a valid Google account email address.")
            return
        }
        let emailAddress = EmailAddress(email.trimmedForAccountSetup)
        #endif
        googleSignInGeneration += 1
        let generation = googleSignInGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.gmailSignInState = .waitingForBrowser
                self.status = .idle
                let code = try await googleAuthorization(emailAddress.rawValue)
                try Task.checkCancellation()
                guard self.googleSignInGeneration == generation else { return }
                self.gmailSignInState = .verifying
                self.status = .validating
                self.isSubmitting = true
                defer { self.isSubmitting = false }
                let result = try await self.setup.addGoogleAccount(
                    displayName: name, email: emailAddress, authorization: code
                ) { [weak self] progress in
                    await self?.receive(progress)
                }
                if self.googleSignInGeneration != generation || Task.isCancelled {
                    do {
                        try await Task {
                            try await self.setup.discardAddedGoogleAccount(accountID: result.account.id)
                        }.value
                    } catch {
                        // The old attempt may have published an account, but
                        // a newer setup now owns the form and route.
                        self.reconcileFailedGoogleCleanup(
                            accountID: result.account.id, expectedEmail: result.account.email,
                            currentAttempt: false, fallback: result.account)
                    }
                    return
                }
                self.account = result.account
                self.accounts = self.refreshedAccounts(fallback: result.account)
                self.advanceAccountConfigurationGeneration()
                self.lastConnectedEmail = result.account.email.rawValue
                self.lastSyncedMessageCount = result.syncedMessageCount
                self.lastSyncError = nil
                self.gmailAppPassword = ""
                self.refreshAccountAuthentications()
                self.gmailSignInState = .idle
                self.publishCompletedAdd(result.account.id)
                self.status = .connected(accountID: result.account.id.rawValue)
            } catch {
                if case GoogleAccountSetupError.cleanupFailed(let accountID) = error {
                    self.reconcileFailedGoogleCleanup(
                        accountID: accountID, expectedEmail: emailAddress,
                        currentAttempt: self.googleSignInGeneration == generation && !Task.isCancelled)
                    return
                }
                guard self.googleSignInGeneration == generation, !Task.isCancelled else { return }
                if Self.isSilentCancellation(error) {
                    self.gmailSignInState = .idle
                    self.status = .idle
                    return
                }
                let message = Self.googleSignInMessage(for: error, email: emailAddress.rawValue)
                self.gmailSignInState = .failed(message)
                self.status = .failed(message: message)
            }
        }
        googleSignInTask = task
        await task.value
        if googleSignInGeneration == generation { googleSignInTask = nil }
    }

    public func signInWithMicrosoft() async {
        guard !isMicrosoftSignInInProgress, !isSubmitting else { return }
        guard let microsoftAuthorization else {
            microsoftSignInState = .unavailable
            status = .failed(message: Self.microsoftSignInUnavailableMessage)
            return
        }
        let name = displayName.trimmedForAccountSetup
        guard !name.isEmpty, isGmailEmailValid else {
            status = .failed(message: "Enter your name and a valid Microsoft account email address.")
            return
        }
        let address = EmailAddress(email.trimmedForAccountSetup)
        microsoftSignInGeneration += 1
        let generation = microsoftSignInGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.microsoftSignInState = .waitingForBrowser
                self.status = .idle
                let code = try await microsoftAuthorization(address.rawValue)
                try Task.checkCancellation()
                guard self.microsoftSignInGeneration == generation else { return }
                self.microsoftSignInState = .verifying
                self.status = .validating
                self.isSubmitting = true
                defer { self.isSubmitting = false }
                let result = try await self.setup.addMicrosoftAccount(
                    displayName: name, email: address, authorization: code
                ) { [weak self] progress in
                    guard let self, await self.microsoftSignInGeneration == generation else { return }
                    await self.receive(progress)
                }
                if self.microsoftSignInGeneration != generation || Task.isCancelled {
                    do {
                        try await Task { try await self.setup.discardAddedMicrosoftAccount(accountID: result.account.id) }.value
                    } catch {
                        self.reconcileFailedMicrosoftCleanup(
                            accountID: result.account.id, expectedEmail: address,
                            currentAttempt: false, fallback: result.account)
                    }
                    return
                }
                self.account = result.account
                self.accounts = self.refreshedAccounts(fallback: result.account)
                self.advanceAccountConfigurationGeneration()
                self.lastConnectedEmail = result.account.email.rawValue
                self.lastSyncedMessageCount = result.syncedMessageCount
                self.lastSyncError = nil
                self.refreshAccountAuthentications()
                self.microsoftSignInState = .idle
                self.publishCompletedAdd(result.account.id)
                self.status = .connected(accountID: result.account.id.rawValue)
            } catch {
                if case MicrosoftAccountSetupError.cleanupFailed(let accountID) = error {
                    self.reconcileFailedMicrosoftCleanup(
                        accountID: accountID, expectedEmail: address,
                        currentAttempt: self.microsoftSignInGeneration == generation && !Task.isCancelled)
                    return
                }
                guard self.microsoftSignInGeneration == generation, !Task.isCancelled else { return }
                let message = Self.microsoftSignInMessage(for: error)
                self.microsoftSignInState = .failed(message)
                self.status = .failed(message: message)
            }
        }
        microsoftSignInTask = task
        await task.value
        if microsoftSignInGeneration == generation { microsoftSignInTask = nil }
    }

    private func reconcileFailedMicrosoftCleanup(
        accountID: AccountID, expectedEmail: EmailAddress, currentAttempt: Bool,
        fallback: Account? = nil
    ) {
        let explanation = "Microsoft setup was interrupted. Check connected accounts before retrying."
        let persisted = try? accountsProvider?()
        let connected = persisted?.first(where: {
            $0.id == accountID && $0.email.rawValue.caseInsensitiveCompare(expectedEmail.rawValue) == .orderedSame
        }) ?? (persisted == nil ? fallback.flatMap {
            $0.id == accountID && $0.email.rawValue.caseInsensitiveCompare(expectedEmail.rawValue) == .orderedSame
                ? $0 : nil
        } : nil)
        guard let connected else {
            accountSettingsMessage = explanation
            accountSettingsSaveFailed = false
            microsoftSetupRecoveryMessage = explanation
            microsoftSetupRecoveryAccountID = nil
            if currentAttempt { status = .failed(message: explanation) }
            return
        }
        accounts = persisted ?? refreshedAccounts(fallback: connected)
        accountSettingsMessage = explanation
        accountSettingsSaveFailed = false
        microsoftSetupRecoveryMessage = explanation
        microsoftSetupRecoveryAccountID = connected.id
        if currentAttempt {
            account = connected
            refreshAccountAuthentications()
            publishCompletedAdd(connected.id)
            status = .connected(accountID: connected.id.rawValue)
        }
    }

    public func openRecoveredMicrosoftAccount() {
        guard let accountID = microsoftSetupRecoveryAccountID,
              accounts.contains(where: { $0.id == accountID }) else { return }
        selectAccount(id: accountID)
        microsoftSetupRecoveryMessage = nil
        microsoftSetupRecoveryAccountID = nil
        publishCompletedAdd(accountID)
    }

    private static func microsoftSignInMessage(for error: Error) -> String {
#if os(iOS)
        if let native = error as? IOSMailOAuthSession.Failure {
            switch native {
            case .cancelled, .denied: return "Microsoft sign-in was cancelled."
            case .busy: return "Microsoft sign-in is already open. Finish or cancel it first."
            case .cannotStart: return "Plainpost couldn't open Microsoft sign-in. Try again."
            case .invalidCallback: return "Microsoft sign-in returned an unexpected response. Try again."
            case .invalidConfiguration: return microsoftSignInUnavailableMessage
            }
        }
#endif
        switch error {
        case MicrosoftOAuthError.notConfigured, AccountSetupHandlingError.unsupported,
             MicrosoftAccountSetupError.notConfigured: return microsoftSignInUnavailableMessage
        case MicrosoftOAuthError.identityMismatch: return "Sign in with the Microsoft account matching the entered email address."
        case MicrosoftOAuthError.scopeMissing: return "Allow Plainpost to access Microsoft Mail, then try again."
        case MicrosoftOAuthError.wrongAudience: return "This Microsoft account isn't supported by this app registration."
        case MicrosoftOAuthError.invalidGrant: return "Microsoft sign-in expired. Try again."
        case MicrosoftAccountSetupError.incompatibleMailbox(let service):
            return "Microsoft \(service) is disabled for this mailbox. Ask your Microsoft 365 administrator to enable it."
        case MicrosoftAccountSetupError.cleanupFailed:
            return "Microsoft setup was interrupted. Check connected accounts before retrying."
        case is CancellationError: return "Microsoft sign-in was cancelled."
        default: return "Microsoft Mail setup failed. Check your connection and try again."
        }
    }

    private func reconcileFailedGoogleCleanup(
        accountID: AccountID, expectedEmail: EmailAddress, currentAttempt: Bool,
        fallback: Account? = nil
    ) {
        let explanation = "Gmail setup was interrupted, and Plainpost couldn't finish removing the account. Check connected accounts before retrying."
        let persisted = try? accountsProvider?()
        let connected = persisted?.first(where: {
            $0.id == accountID && $0.email.rawValue.caseInsensitiveCompare(expectedEmail.rawValue) == .orderedSame
        }) ?? (persisted == nil ? fallback.flatMap {
            $0.id == accountID && $0.email.rawValue.caseInsensitiveCompare(expectedEmail.rawValue) == .orderedSame
                ? $0 : nil
        } : nil)
        guard let connected else {
            accountSettingsMessage = explanation
            accountSettingsSaveFailed = false
            googleSetupRecoveryMessage = explanation
            googleSetupRecoveryAccountID = nil
            if currentAttempt { status = .failed(message: explanation) }
            return
        }
        accounts = persisted ?? refreshedAccounts(fallback: connected)
        accountSettingsMessage = explanation
        accountSettingsSaveFailed = false
        googleSetupRecoveryMessage = explanation
        googleSetupRecoveryAccountID = connected.id
        if currentAttempt {
            account = connected
            refreshAccountAuthentications()
            publishCompletedAdd(connected.id)
            status = .connected(accountID: connected.id.rawValue)
        }
    }

    public func openRecoveredGoogleAccount() {
        guard let accountID = googleSetupRecoveryAccountID,
              accounts.contains(where: { $0.id == accountID }) else { return }
        selectAccount(id: accountID)
        googleSetupRecoveryMessage = nil
        googleSetupRecoveryAccountID = nil
        publishCompletedAdd(accountID)
    }

    /// "Reauthorize Gmail": signs in with Google for an existing Gmail account
    /// and replaces its grant in the service. An App Password Gmail account
    /// becomes a Google sign-in account and its passwords are erased.
    public func reauthorizeGmail(accountID: AccountID) async {
        guard reauthorizingAccountID == nil,
              let target = accounts.first(where: { $0.id == accountID }) ?? (account?.id == accountID ? account : nil)
        else { return }
        guard let googleAuthorization else {
            gmailReauthorizationMessage = Self.googleSignInUnavailableMessage
            return
        }
        guard MailProviderProfile.gmail.matches(target) else {
            gmailReauthorizationMessage = "Only Gmail accounts can sign in with Google."
            return
        }
        gmailReauthorizationMessage = nil
        reauthorizingAccountID = accountID
        defer { reauthorizingAccountID = nil }
        do {
            let code = try await googleAuthorization(target.email.rawValue)
            try await setup.reauthorizeGoogleAccount(
                accountID: accountID, email: target.email, authorization: code)
            refreshAccountAuthentications()
            await refreshSyncNodeSignIns()
            gmailReauthorizationMessage = "Gmail is signed in with Google."
        } catch {
            if Self.isSilentCancellation(error) { return }
            gmailReauthorizationMessage = Self.googleSignInMessage(for: error, email: target.email.rawValue)
        }
    }

    public func reauthorizeMicrosoft(accountID: AccountID) async {
        guard reauthorizingAccountID == nil,
              let target = accounts.first(where: { $0.id == accountID })
                ?? (account?.id == accountID ? account : nil),
              accountAuthentications[accountID]?.method == .microsoftOAuth
        else { return }
        guard let microsoftAuthorization else {
            microsoftReauthorizationMessage = Self.microsoftSignInUnavailableMessage
            return
        }
        microsoftReauthorizationMessage = nil
        reauthorizingAccountID = accountID
        defer { reauthorizingAccountID = nil }
        do {
            let code = try await microsoftAuthorization(target.email.rawValue)
            try await setup.reauthorizeMicrosoftAccount(
                accountID: accountID, email: target.email, authorization: code)
            refreshAccountAuthentications()
            microsoftReauthorizationMessage = "Microsoft Mail is signed in again."
        } catch {
            if Self.isSilentCancellation(error) { return }
            microsoftReauthorizationMessage = Self.microsoftSignInMessage(for: error)
        }
    }

    /// Cancels an in-flight Google sign-in (for example when the user goes
    /// Back); a late result is ignored.
    public func cancelGoogleSignIn() {
        guard let googleSignInTask else { return }
        googleSignInGeneration += 1
        googleSignInTask.cancel()
        self.googleSignInTask = nil
        isSubmitting = false
        gmailSignInState = isGoogleSignInAvailable ? .idle : .unavailable
        if case .validating = status { status = .idle }
    }

    public func cancelMicrosoftSignIn() {
        guard let microsoftSignInTask else { return }
        microsoftSignInGeneration += 1
        microsoftSignInTask.cancel()
        self.microsoftSignInTask = nil
        isSubmitting = false
        microsoftSignInState = isMicrosoftSignInAvailable ? .idle : .unavailable
        if case .validating = status { status = .idle }
    }

    public func refreshAccountAuthentications() {
        guard let accountAuthenticationProvider else { return }
        var summaries: [AccountID: AccountAuthenticationSummary] = [:]
        for candidate in accounts + [account].compactMap({ $0 }) {
            if let summary = try? accountAuthenticationProvider(candidate.id) {
                summaries[candidate.id] = summary
            }
        }
        accountAuthentications = summaries
    }

    /// Reads each Sync Node account's sign-in on this device again.
    public func refreshSyncNodeSignIns() async {
        guard let syncNodeSignInProvider else { return }
        var signIns: [AccountID: SyncNodeSignIn] = [:]
        for candidate in accounts + [account].compactMap({ $0 }) where signIns[candidate.id] == nil {
            if let signIn = await syncNodeSignInProvider(candidate.id) { signIns[candidate.id] = signIn }
        }
        if signIns != syncNodeSignIns { syncNodeSignIns = signIns }
    }

    private func refreshGmailAvailability() {
        if googleAuthorization == nil {
            gmailSignInState = .unavailable
        } else if gmailSignInState == .unavailable {
            gmailSignInState = .idle
        }
    }

    private static func isSilentCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return false
    }

    static func googleSignInMessage(for error: Error, email: String) -> String {
#if os(iOS)
        if let native = error as? IOSMailOAuthSession.Failure {
            switch native {
            case .cancelled, .denied: return "Google sign-in was cancelled."
            case .cannotStart: return "Plainpost couldn't open Google sign-in. Try again."
            case .invalidCallback: return "Google sign-in returned an unexpected response. Try again."
            case .invalidConfiguration: return googleSignInUnavailableMessage
            case .busy: return "Google sign-in is already open. Finish or cancel it first."
            }
        }
#endif
        switch error {
        case GoogleAccountSetupError.signedInAsDifferentAccount(let signedIn, let expected):
            return "You signed in to Google as \(signedIn), but this account is \(expected). Sign in with \(expected) to continue."
        case GoogleAccountSetupError.identityMismatch(let expected):
            return "You signed in to Google with a different account. Sign in with \(expected) to continue."
        case GoogleAccountSetupError.notGmailAccount:
            return "Only Gmail accounts can sign in with Google."
        case GoogleAccountSetupError.cleanupFailed:
            return "Gmail setup was interrupted, and Plainpost couldn't finish removing the account. Check connected accounts before retrying."
        case GmailOAuthAuthorizer.Error.denied, GmailOAuthAuthorizer.Error.cancelled:
            return "Google sign-in was cancelled."
        case GmailOAuthAuthorizer.Error.timedOut:
            return "Google sign-in timed out. Try again."
        case GmailOAuthAuthorizer.Error.cannotStart:
            return "Plainpost couldn't open Google sign-in in your browser. Try again."
        case GmailOAuthAuthorizer.Error.invalidCallback:
            return "Google sign-in returned an unexpected response. Try again."
        case GmailOAuthAuthorizer.Error.invalidConfiguration, GoogleOAuthError.notConfigured,
             MailCredentialError.oauthNotConfigured, AccountSetupHandlingError.unsupported:
            return googleSignInUnavailableMessage
        case GoogleOAuthError.invalidResponse:
            return "Google didn't return a usable sign-in for Gmail. Try again."
        case GoogleOAuthError.scopeMissing:
            return "Google did not grant the Gmail scope Plainpost needs. Check the consent screen and OAuth app configuration."
        case GoogleOAuthError.gmailAPIUnavailable:
            return "The Gmail API is disabled for Plainpost's Google project. Enable it in Google Cloud, then try again."
        case GoogleOAuthError.gmailAccessDenied:
            return "Google refused Gmail access after sign-in. Check your Google account or Workspace app policy."
        case GoogleOAuthError.invalidGrant:
            return "Google sign-in expired before it finished. Try again."
        case GoogleOAuthError.unavailable:
            return "Plainpost couldn't reach Google. Check your connection and try again."
        default:
            return "Gmail setup failed. Check your connection and account details, then try again."
        }
    }

    public func showProviderChooser() {
        cancelGoogleSignIn()
        cancelMicrosoftSignIn()
        selectedProvider = nil
        status = .idle
        gmailAppPassword = ""
        icloudAppPassword = ""
        imapPassword = ""
        smtpPassword = ""
    }

    public var hasConnectedAccount: Bool {
        account != nil
    }

    public var isAccountSaveDisabled: Bool {
        guard let account else { return true }
        guard let editedAccount = editedAccount(id: account.id) else { return true }
        return editedAccount == account
    }

    public func selectAccount(id: AccountID) {
        guard let selected = accounts.first(where: { $0.id == id }) else { return }
        load(selected)
    }

    public func reloadAccounts(selecting accountID: AccountID? = nil) {
        advanceAccountConfigurationGeneration()
        if let refreshed = try? accountsProvider?() {
            accounts = refreshed
        }
        refreshAccountAuthentications()
        let selected = accountID.flatMap { id in accounts.first { $0.id == id } }
            ?? account.flatMap { current in accounts.first { $0.id == current.id } }
            ?? accounts.first
        if let selected {
            load(selected)
        } else {
            loadNoAccount()
        }
    }

    public func deleteSelectedAccount() async {
        guard !isDeletingAccount,
              let accountID = account?.id,
              let accountDeleter
        else { return }
        accountDeletionMessage = nil
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await accountDeleter(accountID)
            reloadAccounts()
        } catch PlainpostServiceClientError.accountDeletionCleanupPending {
            reloadAccounts()
            accountDeletionMessage =
                "Account deleted from Plainpost. Local audit cleanup will finish automatically."
        } catch {
            accountDeletionMessage =
                "Account could not be deleted from Plainpost."
        }
    }

    public func saveAccountSettings() {
        guard let current = account,
              let edited = editedAccount(id: current.id)
        else {
            accountSettingsMessage = "Enter valid account and server details."
            accountSettingsSaveFailed = true
            return
        }

        do {
            try accountSaver?(edited)
            account = edited
            lastConnectedEmail = edited.email.rawValue
            accounts = accounts.map { $0.id == edited.id ? edited : $0 }
            advanceAccountConfigurationGeneration()
            accountSettingsMessage = "Account settings saved."
            accountSettingsSaveFailed = false
        } catch {
            accountSettingsMessage = "Account settings could not be saved."
            accountSettingsSaveFailed = true
        }
    }

    /// Saves a new name for one account, whichever account is selected now, so an edit made on
    /// an account's page lands on that account even after another page took the selection.
    /// Leaves the shared, possibly half-edited server fields alone.
    public func saveDisplayName(_ name: String, accountID: AccountID) {
        guard let current = accounts.first(where: { $0.id == accountID }) else { return }
        let trimmed = name.trimmedForAccountSetup
        guard !trimmed.isEmpty else {
            accountSettingsMessage = "Enter a name for this account."
            accountSettingsSaveFailed = true
            return
        }
        guard trimmed != current.displayName else { return }
        let edited = Account(
            id: current.id, displayName: trimmed,
            email: current.email, username: current.username, sentMailbox: current.sentMailbox,
            imapHost: current.imapHost, imapPort: current.imapPort,
            smtpHost: current.smtpHost, smtpPort: current.smtpPort)
        do {
            try accountSaver?(edited)
            accounts = accounts.map { $0.id == edited.id ? edited : $0 }
            if account?.id == accountID {
                account = edited
                displayName = trimmed
            }
            advanceAccountConfigurationGeneration()
            accountSettingsMessage = nil
            accountSettingsSaveFailed = false
        } catch {
            accountSettingsMessage = "Account settings could not be saved."
            accountSettingsSaveFailed = true
        }
    }

    public var isSelectedAccountGmail: Bool {
        account.map(MailProviderProfile.gmail.matches) ?? false
    }

    public var isSelectedAccountICloud: Bool {
        account.map(MailProviderProfile.icloud.matches) ?? false
    }

    public var credentialReplacementHelp: String {
        if isSelectedAccountGoogleOAuth {
            return "This Gmail account signs in with Google. Passwords aren't used."
        }
        if isSelectedAccountMicrosoftOAuth {
            return "This Microsoft Mail account signs in with Microsoft. Passwords aren't used."
        }
        if isSelectedAccountGmail {
            return "One 16-character Google App Password covers incoming and outgoing mail."
        }
        if isSelectedAccountICloud {
            return "One Apple app-specific password covers incoming and outgoing mail."
        }
        #if os(iOS)
        return "Passwords are stored only in this device's Keychain."
        #else
        return "Passwords are stored only in macOS Keychain."
        #endif
    }

    /// Gmail and iCloud use one app password for IMAP and SMTP, so the replacement form
    /// asks for it once (in `imapPassword`) and saves it to both.
    public var usesSharedAppPassword: Bool {
        isSelectedAccountGmail || isSelectedAccountICloud
    }

    public var isCredentialSaveDisabled: Bool {
        guard account != nil, !isSavingAccountCredentials,
              !isSelectedAccountGoogleOAuth, !isSelectedAccountMicrosoftOAuth else { return true }
        if isSelectedAccountGmail {
            return MailProviderProfile.gmail.normalizedAppPassword(imapPassword).count != 16
        }
        if isSelectedAccountICloud {
            return MailProviderProfile.icloud.normalizedAppPassword(imapPassword).isEmpty
        }
        return imapPassword.isEmpty || smtpPassword.isEmpty
    }

    public func saveAccountPasswords() async {
        guard !isSavingAccountCredentials, let account,
              !isSelectedAccountGoogleOAuth, !isSelectedAccountMicrosoftOAuth else { return }
        let submittedAccountID = account.id
        let submittedIMAPDraft = imapPassword
        let submittedSMTPDraft = smtpPassword
        let submittedForGmail = MailProviderProfile.gmail.matches(account)
        let submittedForICloud = MailProviderProfile.icloud.matches(account)
        let submittedGeneration = accountConfigurationGeneration
        let replacement: (imap: String, smtp: String)
        if submittedForGmail {
            let imap = MailProviderProfile.gmail.normalizedAppPassword(submittedIMAPDraft)
            guard imap.count == 16 else {
                credentialSettingsMessage = "Enter the 16-character Google App Password."
                return
            }
            replacement = (imap, imap)
        } else if submittedForICloud {
            let imap = MailProviderProfile.icloud.normalizedAppPassword(submittedIMAPDraft)
            guard !imap.isEmpty else {
                credentialSettingsMessage = "Enter the Apple app-specific password."
                return
            }
            replacement = (imap, imap)
        } else {
            guard !isCredentialSaveDisabled else { return }
            replacement = (submittedIMAPDraft, submittedSMTPDraft)
        }

        credentialSettingsMessage = nil
        isSavingAccountCredentials = true
        defer { isSavingAccountCredentials = false }
        do {
            try await accountCredentialSaver?(submittedAccountID, replacement.imap, replacement.smtp)
            guard isCurrentCredentialReplacement(
                accountID: submittedAccountID,
                imapDraft: submittedIMAPDraft,
                smtpDraft: submittedSMTPDraft,
                generation: submittedGeneration
            ) else { return }
            imapPassword = ""
            smtpPassword = ""
            credentialSettingsMessage = "Passwords updated."
            // Saving the password clears an account's "sign in again" state.
            refreshAccountAuthentications()
        } catch {
            guard isCurrentCredentialReplacement(
                accountID: submittedAccountID,
                imapDraft: submittedIMAPDraft,
                smtpDraft: submittedSMTPDraft,
                generation: submittedGeneration
            ) else { return }
            credentialSettingsMessage = if submittedForGmail {
                "Check the 16-character Google App Password and try again."
            } else if submittedForICloud {
                "Check the Apple app-specific password and try again."
            } else {
                "Passwords could not be updated. Check both passwords and try again."
            }
        }
    }

    private func isCurrentCredentialReplacement(
        accountID: AccountID,
        imapDraft: String,
        smtpDraft: String,
        generation: UInt64
    ) -> Bool {
        accountConfigurationGeneration == generation
            && account?.id == accountID
            && imapPassword == imapDraft
            && smtpPassword == smtpDraft
    }

    private func advanceAccountConfigurationGeneration() {
        accountConfigurationGeneration += 1
    }

    public func makeAdditionalAccountViewModel() -> AccountSetupViewModel {
        AccountSetupViewModel(
            setup: setup,
            accountsProvider: accountsProvider,
            accountSaver: accountSaver,
            accountCredentialSaver: accountCredentialSaver,
            accountDeleter: accountDeleter,
            syncPreferencesProvider: syncPreferencesProvider,
            syncPreferencesSaver: syncPreferencesSaver,
            mailboxPreferencesProvider: mailboxPreferencesProvider,
            mailboxPathsProvider: mailboxPathsProvider,
            mailboxPreferenceSaver: mailboxPreferenceSaver,
            accountMailboxStatusProvider: accountMailboxStatusProvider,
            googleAuthorization: googleAuthorization,
            microsoftAuthorization: microsoftAuthorization,
            accountAuthenticationProvider: accountAuthenticationProvider,
            syncNodeSignInProvider: syncNodeSignInProvider,
            onCompletedAdd: { [weak self] accountID in self?.publishCompletedAdd(accountID) }
        )
    }

    private func publishCompletedAdd(_ accountID: AccountID) {
        completedAddEvent = AccountSetupCompletedAddEvent(accountID: accountID)
        onCompletedAdd(accountID)
    }

    public func resetForNewAccount() {
        cancelGoogleSignIn()
        cancelMicrosoftSignIn()
        advanceAccountConfigurationGeneration()
        selectedProvider = nil
        displayName = ""
        email = ""
        imapHost = ""
        imapPort = "993"
        smtpHost = ""
        smtpPort = "587"
        username = ""
        imapPassword = ""
        smtpPassword = ""
        gmailAppPassword = ""
        icloudAppPassword = ""
        account = nil
        status = .idle
        lastConnectedEmail = nil
        lastSyncedMessageCount = nil
        lastSyncError = nil
        accountSettingsMessage = nil
        accountSettingsSaveFailed = false
        credentialSettingsMessage = nil
    }

    public var syncStatusMessage: String {
        if let lastSyncError {
            return lastSyncError
        }
        if case .syncing(let progress) = status {
            return Self.syncProgressMessage(progress)
        }
        if lastSyncedMessageCount != nil {
            return "Up to date"
        }
        return "Not synced yet"
    }

    nonisolated static func syncProgressMessage(_ progress: IMAPSyncProgress) -> String {
        switch progress {
        case .connecting:
            return "Connecting…"
        case .discoveringMailboxes, .discoveringMessages:
            return "Checking for mail…"
        case .downloading(let completed, let total):
            return total == 0 ? "No messages yet" : "Downloading \(completed.formatted()) of \(total.formatted()) messages"
        case .syncingMailbox(_, _, let completed, let total):
            return total == 0 ? "Downloading" : "Downloading \(completed.formatted()) of \(total.formatted()) messages"
        }
    }

    public var syncStatusValue: String {
        if isSyncing {
            return "Syncing"
        }
        if lastSyncError != nil {
            return "Needs attention"
        }
        if let lastSyncedMessageCount {
            return "\(lastSyncedMessageCount) synced"
        }
        return "Not synced"
    }

    public func syncInbox() async {
        guard let account, !isSyncing else {
            return
        }

        isSyncing = true
        lastSyncError = nil
        status = .syncing(progress: .connecting)
        defer { isSyncing = false }

        do {
            let result = try await setup.syncInbox(for: account) { [weak self] progress in
                await self?.receive(.syncingInbox(progress))
            }
            lastSyncedMessageCount = result.syncedMessageCount
            mailboxSyncStatuses = (try? accountMailboxStatusProvider?(account.id))
                ?? (try? mailboxStatusProvider?())
                ?? mailboxSyncStatuses
            status = .connected(accountID: account.id.rawValue)
        } catch {
            lastSyncError = "Inbox sync failed. Check the IMAP settings and try again."
            status = .connected(accountID: account.id.rawValue)
        }
    }

    public func saveSyncPreferences() {
        updateSyncPreferences(
            downloadCompleteHistory: downloadCompleteHistory,
            recentMessageLimit: recentMessageLimit,
            realTimeMonitoringEnabled: realTimeMonitoringEnabled
        )
    }

    public func updateSyncPreferences(
        downloadCompleteHistory: Bool,
        recentMessageLimit: Int,
        realTimeMonitoringEnabled: Bool
    ) {
        let previous = (
            self.downloadCompleteHistory,
            self.recentMessageLimit,
            self.realTimeMonitoringEnabled
        )
        self.downloadCompleteHistory = downloadCompleteHistory
        self.recentMessageLimit = recentMessageLimit
        self.realTimeMonitoringEnabled = realTimeMonitoringEnabled
        do {
            try saveCurrentSyncPreferences()
            lastSyncError = nil
        } catch {
            (
                self.downloadCompleteHistory,
                self.recentMessageLimit,
                self.realTimeMonitoringEnabled
            ) = previous
            lastSyncError = "Sync preferences could not be saved."
        }
    }

    private func saveCurrentSyncPreferences() throws {
        guard let account else { return }
        let preferences = MailSyncPreferences(
            accountID: account.id,
            downloadCompleteHistory: downloadCompleteHistory,
            recentMessageLimit: recentMessageLimit,
            realTimeMonitoringEnabled: realTimeMonitoringEnabled
        )
        try syncPreferencesSaver?(preferences)
        recentMessageLimit = preferences.recentMessageLimit
    }

    public func refreshMailboxSyncStatuses() {
        if let account {
            mailboxSyncStatuses = (try? accountMailboxStatusProvider?(account.id))
                ?? (try? mailboxStatusProvider?())
                ?? mailboxSyncStatuses
        }
    }

    public var availableMailboxPaths: [String] {
        mailboxModes.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func isMailboxSelected(_ path: String) -> Bool {
        mailboxModes[path] != .off
    }

    public func isMailboxSyncDisabled(path: String) -> Bool {
        mailboxModes[path] == .off
    }

    public func enableMailboxSync(path: String) async {
        guard let account, mailboxModes[path] == .off else { return }
        let preference = MailboxSyncPreference(
            accountID: account.id,
            mailboxPath: path,
            mode: .recent
        )
        do {
            try mailboxPreferenceSaver?(preference)
            mailboxModes[path] = .recent
            lastSyncError = nil
            await syncInbox()
        } catch {
            lastSyncError = "Mailbox sync could not be enabled."
        }
    }

    public func setMailboxSelected(_ selected: Bool, path: String) {
        guard let account else { return }
        let previousMode = mailboxModes[path] ?? .off
        let requestedMode: MailboxSyncMode = selected
            ? (downloadCompleteHistory ? .complete : .recent)
            : .off
        mailboxModes[path] = requestedMode
        do {
            try mailboxPreferenceSaver?(
                MailboxSyncPreference(accountID: account.id, mailboxPath: path, mode: requestedMode)
            )
            lastSyncError = nil
        } catch {
            mailboxModes[path] = previousMode
            lastSyncError = "Mailbox selection could not be saved."
        }
    }

    private func receive(_ progress: AccountSetupProgress) {
        switch progress {
        case .verifyingIMAP, .verifyingSMTP:
            status = .validating
        case .syncingInbox(let syncProgress):
            status = .syncing(progress: syncProgress)
        }
    }

    private func submit(
        _ request: AccountSetupRequest,
        provider: MailProviderKind?
    ) async throws {
        status = .validating
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let result = try await setup.addAccount(request) { [weak self] progress in
                await self?.receive(progress)
            }
            account = result.account
            accounts = refreshedAccounts(fallback: result.account)
            advanceAccountConfigurationGeneration()
            lastConnectedEmail = result.account.email.rawValue
            lastSyncedMessageCount = result.syncedMessageCount
            lastSyncError = nil
            imapPassword = ""
            smtpPassword = ""
            gmailAppPassword = ""
            icloudAppPassword = ""
            publishCompletedAdd(result.account.id)
            status = .connected(accountID: result.account.id.rawValue)
        } catch {
            let failureMessage: String
            switch provider {
            case .gmail:
                failureMessage = "Gmail setup failed. Check your connection and account details, then try again."
            case .microsoft:
                failureMessage = "Microsoft Mail setup failed. Check your connection and try again."
            case .icloud:
                failureMessage = "iCloud setup failed. Check your app-specific password and connection, then try again."
            case .other, nil:
                failureMessage = "Account verification failed."
            }
            status = .failed(message: failureMessage)
            throw error
        }
    }

    private func refreshedAccounts(fallback: Account) -> [Account] {
        if let refreshed = try? accountsProvider?() {
            return refreshed
        }
        var merged = accounts.filter { $0.id != fallback.id }
        merged.append(fallback)
        return merged.sorted { $0.email.rawValue.localizedCaseInsensitiveCompare($1.email.rawValue) == .orderedAscending }
    }

    private func editedAccount(id: AccountID) -> Account? {
        if isSelectedAccountOAuth {
            guard let current = account, current.id == id,
                  !displayName.trimmedForAccountSetup.isEmpty else { return nil }
            return Account(
                id: current.id, displayName: displayName.trimmedForAccountSetup,
                email: current.email, username: current.username, sentMailbox: current.sentMailbox,
                imapHost: current.imapHost, imapPort: current.imapPort,
                smtpHost: current.smtpHost, smtpPort: current.smtpPort)
        }
        guard let imapPort = UInt16(imapPort.trimmedForAccountSetup),
              let smtpPort = Int(smtpPort.trimmedForAccountSetup),
              (1...65535).contains(smtpPort),
              !displayName.trimmedForAccountSetup.isEmpty,
              !email.trimmedForAccountSetup.isEmpty,
              !username.trimmedForAccountSetup.isEmpty,
              !imapHost.trimmedForAccountSetup.isEmpty,
              !smtpHost.trimmedForAccountSetup.isEmpty
        else { return nil }

        return Account(
            id: id,
            displayName: displayName.trimmedForAccountSetup,
            email: EmailAddress(email.trimmedForAccountSetup),
            username: username.trimmedForAccountSetup,
            sentMailbox: account?.sentMailbox,
            imapHost: imapHost.trimmedForAccountSetup,
            imapPort: imapPort,
            smtpHost: smtpHost.trimmedForAccountSetup,
            smtpPort: smtpPort
        )
    }

    private func load(_ selected: Account) {
        advanceAccountConfigurationGeneration()
        account = selected
        gmailReauthorizationMessage = nil
        microsoftReauthorizationMessage = nil
        displayName = selected.displayName
        email = selected.email.rawValue
        username = selected.username
        imapHost = selected.imapHost
        imapPort = String(selected.imapPort)
        smtpHost = selected.smtpHost
        smtpPort = String(selected.smtpPort)
        imapPassword = ""
        smtpPassword = ""
        lastConnectedEmail = selected.email.rawValue
        lastSyncedMessageCount = nil
        lastSyncError = nil
        status = .connected(accountID: selected.id.rawValue)
        accountSettingsMessage = nil
        accountSettingsSaveFailed = false
        credentialSettingsMessage = nil

        let preferences: MailSyncPreferences?
        if let syncPreferencesProvider {
            preferences = try? syncPreferencesProvider(selected.id)
        } else {
            preferences = nil
        }
        downloadCompleteHistory = preferences?.downloadCompleteHistory ?? false
        recentMessageLimit = preferences?.recentMessageLimit ?? 100
        realTimeMonitoringEnabled = preferences?.realTimeMonitoringEnabled ?? true

        let mailboxPreferences = (try? mailboxPreferencesProvider?(selected.id)) ?? []
        let paths = (try? mailboxPathsProvider?(selected.id)) ?? ["INBOX"]
        mailboxModes = MailboxSyncSelection.effectiveModes(
            availableMailboxPaths: paths,
            preferences: mailboxPreferences
        )
        mailboxSyncStatuses = (try? accountMailboxStatusProvider?(selected.id)) ?? []
    }

    private func loadNoAccount() {
        advanceAccountConfigurationGeneration()
        selectedProvider = nil
        displayName = ""
        email = ""
        imapHost = ""
        imapPort = "993"
        smtpHost = ""
        smtpPort = "587"
        username = ""
        imapPassword = ""
        smtpPassword = ""
        gmailAppPassword = ""
        icloudAppPassword = ""
        account = nil
        accounts = []
        status = .idle
        lastConnectedEmail = nil
        lastSyncedMessageCount = nil
        lastSyncError = nil
        accountSettingsMessage = nil
        accountSettingsSaveFailed = false
        credentialSettingsMessage = nil
        downloadCompleteHistory = false
        recentMessageLimit = 100
        realTimeMonitoringEnabled = true
        mailboxModes = [:]
        mailboxSyncStatuses = []
    }

    public static func preview() -> AccountSetupViewModel {
        return AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            displayName: "Personal",
            email: "me@example.com",
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com",
            username: "me@example.com"
        )
    }

    public static func connectedPreview() -> AccountSetupViewModel {
        let account = Account(
            id: AccountID("acc_preview"),
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            imapPort: 993,
            smtpHost: "smtp.example.com",
            smtpPort: 587
        )
        return AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            displayName: "Personal",
            email: "me@example.com",
            imapHost: "imap.example.com",
            imapPort: "993",
            smtpHost: "smtp.example.com",
            smtpPort: "587",
            username: "me@example.com",
            status: .connected(accountID: "acc_preview"),
            lastConnectedEmail: "me@example.com",
            account: account,
            lastSyncedMessageCount: 128
        )
    }

    /// Preview-only Google authorization that never opens a browser.
    private static let previewGoogleAuthorization: @MainActor @Sendable (String) async throws -> GmailAuthorizationCode = { _ in
        throw CancellationError()
    }

    public static func gmailPreview() -> AccountSetupViewModel {
        AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            selectedProvider: .gmail,
            displayName: "Personal Gmail",
            email: "alex@gmail.com",
            googleAuthorization: previewGoogleAuthorization
        )
    }

    public static func gmailRecoveryPreview() -> AccountSetupViewModel {
        let account = MailProviderProfile.gmail.makeGoogleAccount(
            displayName: "Personal Gmail", email: EmailAddress("alex@gmail.com"))
        let model = AccountSetupViewModel(
            setup: PreviewAccountSetupService(), accounts: [account],
            googleAuthorization: previewGoogleAuthorization)
        model.googleSetupRecoveryMessage = "Gmail setup was interrupted. Check the connected account before retrying."
        model.googleSetupRecoveryAccountID = account.id
        return model
    }

    public static func otherPreview() -> AccountSetupViewModel {
        AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            selectedProvider: .other,
            displayName: "Personal",
            email: "me@example.com",
            imapHost: "imap.example.com",
            imapPort: "993",
            smtpHost: "smtp.example.com",
            smtpPort: "587",
            username: "me@example.com"
        )
    }

    public static func gmailEmptyPreview() -> AccountSetupViewModel {
        AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            selectedProvider: .gmail,
            googleAuthorization: previewGoogleAuthorization
        )
    }

    public static func gmailFailurePreview() -> AccountSetupViewModel {
        let message = googleSignInMessage(
            for: GoogleAccountSetupError.signedInAsDifferentAccount(
                signedIn: "alex.work@gmail.com", expected: "alex@gmail.com"),
            email: "alex@gmail.com"
        )
        let viewModel = AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            selectedProvider: .gmail,
            displayName: "Personal Gmail",
            email: "alex@gmail.com",
            status: .failed(message: message),
            googleAuthorization: previewGoogleAuthorization
        )
        viewModel.gmailSignInState = .failed(message)
        return viewModel
    }

    public static func gmailWaitingForBrowserPreview() -> AccountSetupViewModel {
        let viewModel = gmailPreview()
        viewModel.gmailSignInState = .waitingForBrowser
        return viewModel
    }

    public static func gmailUnavailablePreview() -> AccountSetupViewModel {
        AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            selectedProvider: .gmail,
            displayName: "Personal Gmail",
            email: "alex@gmail.com"
        )
    }

    /// A connected Gmail account whose Google grant needs reauthorization.
    public static func gmailReauthorizationPreview() -> AccountSetupViewModel {
        let account = MailProviderProfile.gmail.makeGoogleAccount(
            displayName: "Personal Gmail", email: EmailAddress("alex@gmail.com"))
        return AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            displayName: account.displayName,
            email: account.email.rawValue,
            imapHost: account.imapHost,
            imapPort: String(account.imapPort),
            smtpHost: account.smtpHost,
            smtpPort: String(account.smtpPort),
            username: account.username,
            status: .connected(accountID: account.id.rawValue),
            lastConnectedEmail: account.email.rawValue,
            account: account,
            lastSyncedMessageCount: 128,
            googleAuthorization: previewGoogleAuthorization,
            accountAuthenticationProvider: { _ in
                AccountAuthenticationSummary(method: .googleOAuth, state: .reauthorizationRequired)
            }
        )
    }

    public static func gmailPartialPasswordPreview() -> AccountSetupViewModel {
        AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            selectedProvider: .gmail,
            displayName: "Personal Gmail",
            email: "alex@gmail.com",
            gmailAppPassword: "abcdefgh"
        )
    }

    public static func gmailConnectingPreview() -> AccountSetupViewModel {
        let viewModel = AccountSetupViewModel(
            setup: PreviewAccountSetupService(),
            selectedProvider: .gmail,
            displayName: "Personal Gmail",
            email: "alex@gmail.com",
            status: .validating,
            googleAuthorization: previewGoogleAuthorization
        )
        viewModel.gmailSignInState = .verifying
        viewModel.isSubmitting = true
        return viewModel
    }
}

private struct PreviewAccountSetupService: AccountSetupHandling {
    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        AccountSetupResult(
            account: Account(
                id: AccountID("acc_preview"),
                displayName: request.displayName,
                email: request.email,
                imapHost: request.imapHost,
                imapPort: request.imapPort,
                smtpHost: request.smtpHost,
                smtpPort: request.smtpPort
            ),
            imapVerified: true,
            smtpVerified: true
        )
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        IMAPSyncResult(syncedMessageCount: 0)
    }
}

private extension String {
    var trimmedForAccountSetup: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A Sync Node account's sign-in on this device: with it, the device keeps the account
/// syncing while the Node is away.
public enum SyncNodeSignIn: Equatable, Sendable {
    /// The account's provider sign-in is on this device.
    case signedIn
    /// Gmail, without its sign-in here yet: Google sign-in adds it.
    case googleAvailable
    /// No sign-in on this device can be added for this account yet.
    case unavailable
}
