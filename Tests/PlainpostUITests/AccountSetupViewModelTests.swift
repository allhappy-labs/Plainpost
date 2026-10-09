import Combine
import XCTest
@testable import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
import PlainpostTestSupport
import PlainpostRuntimeTestSupport
import PlainpostAccountRuntime
@testable import PlainpostUI

final class AccountSetupViewModelTests: XCTestCase {
    @MainActor
    func testSelectingGmailUsesGuidedFieldsAndSubmitsResolvedRequest() async throws {
        let service = RecordingAccountSetupService()
        let viewModel = AccountSetupViewModel(setup: service)

        viewModel.selectProvider(.gmail)
        viewModel.displayName = "Personal"
        viewModel.email = "me@gmail.com"
        viewModel.gmailAppPassword = "abcd efgh ijkl mnop"

        XCTAssertFalse(viewModel.isConnectDisabled)
        try await viewModel.submit()

        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.imapHost, "imap.gmail.com")
        XCTAssertEqual(request.imapPort, 993)
        XCTAssertEqual(request.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(request.smtpPort, 587)
        XCTAssertEqual(request.username, "me@gmail.com")
        XCTAssertEqual(request.sentMailbox, "[Gmail]/Sent Mail")
        XCTAssertEqual(request.imapPassword, "abcdefghijklmnop")
        XCTAssertEqual(request.smtpPassword, "abcdefghijklmnop")
        XCTAssertEqual(viewModel.gmailAppPassword, "")
    }

    @MainActor
    func testGmailRejectsInvalidAppPasswordWithoutSubmitting() async throws {
        let service = RecordingAccountSetupService()
        let viewModel = AccountSetupViewModel(setup: service)
        viewModel.selectProvider(.gmail)
        viewModel.displayName = "Personal"
        viewModel.email = "me@gmail.com"
        viewModel.gmailAppPassword = "normal-google-password"

        XCTAssertTrue(viewModel.isConnectDisabled)
        try await viewModel.submit()

        XCTAssertEqual(
            viewModel.status,
            .failed(message: "Enter the 16-character Google App Password.")
        )
        XCTAssertTrue(service.requests.isEmpty)
    }

    @MainActor
    func testGmailReadinessExplainsTheCurrentBlocker() {
        let viewModel = AccountSetupViewModel(setup: RecordingAccountSetupService())
        viewModel.selectProvider(.gmail)

        XCTAssertEqual(viewModel.gmailReadinessMessage, "Enter the name shown to recipients.")

        viewModel.displayName = "Personal"
        XCTAssertEqual(viewModel.gmailReadinessMessage, "Enter a valid Google account email address.")
        viewModel.email = "me@gmail.com"
        XCTAssertEqual(viewModel.gmailReadinessMessage, "Create and paste a Google App Password.")

        viewModel.gmailAppPassword = "abcd efgh"
        XCTAssertEqual(viewModel.gmailAppPasswordCharacterCount, 8)
        XCTAssertFalse(viewModel.isGmailAppPasswordValid)
        XCTAssertEqual(viewModel.gmailReadinessMessage, "The App Password must contain 16 characters.")

        viewModel.gmailAppPassword = "abcd efgh ijkl mnop"
        XCTAssertEqual(viewModel.gmailAppPasswordCharacterCount, 16)
        XCTAssertTrue(viewModel.isGmailAppPasswordValid)
        XCTAssertEqual(viewModel.gmailReadinessMessage, "Ready to connect securely.")
    }

    @MainActor
    func testGmailEmailValidationSupportsGmailAndWorkspaceAddresses() {
        let cases: [(email: String, valid: Bool)] = [
            ("me@gmail.com", true),
            ("person+mail@company.example", true),
            ("missing-at.example", false),
            ("@gmail.com", false),
            ("me@", false),
            ("me@gmail", false),
            ("me @gmail.com", false),
            ("me@gmail.com ", true)
        ]

        for item in cases {
            let viewModel = AccountSetupViewModel(setup: RecordingAccountSetupService())
            viewModel.selectProvider(.gmail)
            viewModel.displayName = "Personal"
            viewModel.email = item.email
            viewModel.gmailAppPassword = "abcdefghijklmnop"

            XCTAssertEqual(viewModel.isGmailEmailValid, item.valid, "Email: \(item.email)")
            XCTAssertEqual(viewModel.isConnectDisabled, !item.valid, "Email: \(item.email)")
        }
    }

    @MainActor
    func testGmailPasswordReadinessUsesNormalizedLengthBoundaries() {
        let cases: [(raw: String, count: Int, valid: Bool, message: String)] = [
            ("", 0, false, "Create and paste a Google App Password."),
            ("   \t\n", 0, false, "Create and paste a Google App Password."),
            ("abcdefghijklmno", 15, false, "The App Password must contain 16 characters."),
            ("abcd efgh ijkl mnop", 16, true, "Ready to connect securely."),
            ("abcd\tefgh\nijkl mnop", 16, true, "Ready to connect securely."),
            ("abcdefghijklmnopq", 17, false, "The App Password must contain 16 characters.")
        ]

        for item in cases {
            let viewModel = AccountSetupViewModel(setup: RecordingAccountSetupService())
            viewModel.selectProvider(.gmail)
            viewModel.displayName = "Personal"
            viewModel.email = "me@gmail.com"
            viewModel.gmailAppPassword = item.raw

            XCTAssertEqual(viewModel.gmailAppPasswordCharacterCount, item.count, "Raw value: \(item.raw)")
            XCTAssertEqual(viewModel.isGmailAppPasswordValid, item.valid, "Raw value: \(item.raw)")
            XCTAssertEqual(viewModel.isConnectDisabled, !item.valid, "Raw value: \(item.raw)")
            XCTAssertEqual(viewModel.gmailReadinessMessage, item.message, "Raw value: \(item.raw)")
        }
    }

    @MainActor
    func testReturningToProviderChooserKeepsManualDraft() {
        let viewModel = AccountSetupViewModel(setup: RecordingAccountSetupService())
        viewModel.selectProvider(.other)
        viewModel.imapHost = "imap.example.com"
        viewModel.smtpHost = "smtp.example.com"
        viewModel.imapPassword = "imap-secret"
        viewModel.smtpPassword = "smtp-secret"

        viewModel.showProviderChooser()

        XCTAssertNil(viewModel.selectedProvider)
        XCTAssertEqual(viewModel.imapHost, "imap.example.com")
        XCTAssertEqual(viewModel.smtpHost, "smtp.example.com")
        XCTAssertEqual(viewModel.imapPassword, "")
        XCTAssertEqual(viewModel.smtpPassword, "")
    }

    @MainActor
    func testReturningToProviderChooserClearsGmailCredentialDraft() {
        let viewModel = AccountSetupViewModel(setup: RecordingAccountSetupService())
        viewModel.selectProvider(.gmail)
        viewModel.gmailAppPassword = "abcdefghijklmnop"

        viewModel.showProviderChooser()

        XCTAssertNil(viewModel.selectedProvider)
        XCTAssertEqual(viewModel.gmailAppPassword, "")
    }

    @MainActor
    func testOtherProviderSubmitsTheManualAccountDraft() async throws {
        let service = RecordingAccountSetupService()
        let viewModel = AccountSetupViewModel(setup: service)
        viewModel.selectProvider(.other)
        viewModel.displayName = "Hosted mail"
        viewModel.email = "me@example.com"
        viewModel.imapHost = "imap.example.com"
        viewModel.imapPort = "993"
        viewModel.smtpHost = "smtp.example.com"
        viewModel.smtpPort = "587"
        viewModel.username = "mail-user"
        viewModel.imapPassword = "imap-secret"
        viewModel.smtpPassword = "smtp-secret"

        try await viewModel.submit()

        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.username, "mail-user")
        XCTAssertEqual(request.imapHost, "imap.example.com")
        XCTAssertEqual(request.smtpHost, "smtp.example.com")
        XCTAssertEqual(viewModel.imapPassword, "")
        XCTAssertEqual(viewModel.smtpPassword, "")
    }

    @MainActor
    func testGmailFailureUsesSafeProviderSpecificMessage() async {
        let viewModel = AccountSetupViewModel(setup: FailingAccountSetupService())
        viewModel.selectProvider(.gmail)
        viewModel.displayName = "Personal"
        viewModel.email = "me@gmail.com"
        viewModel.gmailAppPassword = "abcdefghijklmnop"

        do {
            try await viewModel.submit()
            XCTFail("Expected Gmail setup to fail.")
        } catch {}

        XCTAssertEqual(
            viewModel.status,
            .failed(message: "Gmail setup failed. Check your connection and account details, then try again.")
        )
        XCTAssertFalse(viewModel.isSubmitting)
        XCTAssertFalse(String(describing: viewModel.status).contains("abcdefghijklmnop"))
    }

    @MainActor
    func testICloudGuidedSetupIgnoresStaleManualServersAndUsesOnePassword() async throws {
        let service = RecordingAccountSetupService()
        let model = AccountSetupViewModel(setup: service)
        model.imapHost = "wrong.example"
        model.imapPort = "143"
        model.smtpHost = "wrong.example"
        model.smtpPort = "25"
        model.username = "short-name"
        model.selectProvider(.icloud)
        model.displayName = "Personal"
        model.email = " person@icloud.com "
        model.icloudAppPassword = "abcd efgh ijkl mnop"

        XCTAssertFalse(model.isConnectDisabled)
        try await model.submit()

        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.username, "person@icloud.com")
        XCTAssertEqual(request.imapHost, "imap.mail.me.com")
        XCTAssertEqual(request.imapPort, 993)
        XCTAssertEqual(request.smtpHost, "smtp.mail.me.com")
        XCTAssertEqual(request.smtpPort, 587)
        XCTAssertEqual(request.imapPassword, "abcdefghijklmnop")
        XCTAssertEqual(request.smtpPassword, request.imapPassword)
        XCTAssertEqual(model.icloudAppPassword, "")
        XCTAssertEqual(model.status, .connected(accountID: "acc_me_example_com"))
    }

    @MainActor
    func testICloudMissingPasswordAndFailureDoNotPublishAccountOrRevealSecret() async {
        let model = AccountSetupViewModel(setup: FailingAccountSetupService(), selectedProvider: .icloud)
        model.displayName = "Personal"
        model.email = "person@icloud.com"
        XCTAssertTrue(model.isConnectDisabled)
        try? await model.submit()
        XCTAssertNil(model.account)

        model.icloudAppPassword = "sensitive-secret"
        XCTAssertFalse(model.isConnectDisabled)
        do {
            try await model.submit()
            XCTFail("Expected iCloud verification to fail")
        } catch {}
        XCTAssertNil(model.account)
        XCTAssertFalse(String(describing: model.status).contains("sensitive-secret"))
        XCTAssertEqual(model.status, .failed(message: "iCloud setup failed. Check your app-specific password and connection, then try again."))
        model.showProviderChooser()
        XCTAssertEqual(model.icloudAppPassword, "")
    }

    @MainActor
    func testResetForNewAccountClearsProviderAndCredentialDrafts() {
        let viewModel = AccountSetupViewModel(setup: RecordingAccountSetupService())
        viewModel.selectProvider(.gmail)
        viewModel.gmailAppPassword = "abcdefghijklmnop"
        viewModel.imapPassword = "imap-secret"
        viewModel.smtpPassword = "smtp-secret"

        viewModel.resetForNewAccount()

        XCTAssertNil(viewModel.selectedProvider)
        XCTAssertEqual(viewModel.gmailAppPassword, "")
        XCTAssertEqual(viewModel.imapPassword, "")
        XCTAssertEqual(viewModel.smtpPassword, "")
    }

    @MainActor
    func testSubmitAddsAccountThroughRealLocalIMAPAndSMTPHarnesses() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ui-account-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let credentials = InMemoryCredentialVault()

        let service = AccountSetupService(
            store: try SQLiteMailStore(path: dbURL.path),
            credentials: credentials
        )
        let viewModel = AccountSetupViewModel(setup: service)
        viewModel.displayName = "Personal"
        viewModel.email = "me@example.com"
        viewModel.imapHost = "127.0.0.1"
        viewModel.imapPort = "\(imap.port)"
        viewModel.smtpHost = "127.0.0.1"
        viewModel.smtpPort = "\(smtp.port)"
        viewModel.username = "me@example.com"
        viewModel.imapPassword = "imap-secret"
        viewModel.smtpPassword = "smtp-secret"

        try await viewModel.submit()

        XCTAssertEqual(viewModel.status, .connected(accountID: "acc_me_example_com"))
        XCTAssertFalse(viewModel.isSubmitting)
        XCTAssertEqual(viewModel.lastConnectedEmail, "me@example.com")

        let additionalAccount = AccountSetupViewModel(setup: service)
        additionalAccount.displayName = "Work"
        additionalAccount.email = "work@example.com"
        additionalAccount.imapHost = "127.0.0.1"
        additionalAccount.imapPort = "\(imap.port)"
        additionalAccount.smtpHost = "127.0.0.1"
        additionalAccount.smtpPort = "\(smtp.port)"
        additionalAccount.username = "me@example.com"
        additionalAccount.imapPassword = "imap-secret"
        additionalAccount.smtpPassword = "smtp-secret"

        try await additionalAccount.submit()

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts.map(\.email.rawValue), ["me@example.com", "work@example.com"])
        for accountID in ["acc_me_example_com", "acc_work_example_com"] {
            let imap = try await credentials.load(
                CredentialRecordKey(rawValue: "account:\(accountID):imap-password")
            )
            let smtp = try await credentials.load(
                CredentialRecordKey(rawValue: "account:\(accountID):smtp-password")
            )
            XCTAssertEqual(imap, Data("imap-secret".utf8))
            XCTAssertEqual(smtp, Data("smtp-secret".utf8))
        }
    }

    @MainActor
    func testInvalidPortsStayLocalAndDoNotSubmit() async throws {
        let service = RecordingAccountSetupService()
        let viewModel = AccountSetupViewModel(setup: service)
        viewModel.displayName = "Personal"
        viewModel.email = "me@example.com"
        viewModel.imapHost = "imap.example.com"
        viewModel.imapPort = "not-a-port"
        viewModel.smtpHost = "smtp.example.com"
        viewModel.smtpPort = "587"
        viewModel.username = "me@example.com"
        viewModel.imapPassword = "imap-secret"
        viewModel.smtpPassword = "smtp-secret"

        try await viewModel.submit()

        XCTAssertEqual(viewModel.status, .failed(message: "Enter valid IMAP and SMTP ports."))
        XCTAssertTrue(service.requests.isEmpty)
    }

    @MainActor
    func testCanInitializeWithConnectedAccountState() {
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            displayName: "Personal",
            email: "me@example.com",
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com",
            username: "me@example.com",
            status: .connected(accountID: "acc_me_example_com"),
            lastConnectedEmail: "me@example.com"
        )

        XCTAssertEqual(viewModel.status, .connected(accountID: "acc_me_example_com"))
        XCTAssertEqual(viewModel.lastConnectedEmail, "me@example.com")
        XCTAssertFalse(viewModel.isSubmitting)
    }

    @MainActor
    func testDisplayNameSavesToItsOwnAccountAfterTheSelectionMoved() {
        let personal = Account(
            id: AccountID("acc_personal"), displayName: "Personal", email: EmailAddress("me@example.com"),
            username: "me@example.com", imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let work = Account(
            id: AccountID("acc_work"), displayName: "Work", email: EmailAddress("me@work.example"),
            username: "me@work.example", imapHost: "imap.work.example", smtpHost: "smtp.work.example")
        let recorder = AccountSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: work,
            accounts: [personal, work],
            accountSaver: recorder.save
        )
        viewModel.selectAccount(id: work.id)
        // The Work page left a half-edited server field behind; the Personal name save must
        // not carry it.
        viewModel.imapHost = "half-typed"

        viewModel.saveDisplayName("  Home  ", accountID: personal.id)

        XCTAssertEqual(recorder.savedAccount?.id, personal.id)
        XCTAssertEqual(recorder.savedAccount?.displayName, "Home")
        XCTAssertEqual(recorder.savedAccount?.imapHost, "imap.example.com")
        XCTAssertEqual(viewModel.accounts.map(\.displayName), ["Home", "Work"])
        XCTAssertEqual(viewModel.account?.id, work.id)
        XCTAssertEqual(viewModel.displayName, "Work")
        XCTAssertNil(viewModel.accountSettingsMessage)
    }

    @MainActor
    func testDisplayNameSaveSkipsUnchangedAndReportsBlankOrFailedSaves() {
        let personal = Account(
            id: AccountID("acc_personal"), displayName: "Personal", email: EmailAddress("me@example.com"),
            username: "me@example.com", imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let recorder = AccountSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: personal,
            accounts: [personal],
            accountSaver: recorder.save
        )

        viewModel.saveDisplayName("Personal", accountID: personal.id)
        XCTAssertNil(recorder.savedAccount)

        viewModel.saveDisplayName("   ", accountID: personal.id)
        XCTAssertNil(recorder.savedAccount)
        XCTAssertEqual(viewModel.accountSettingsMessage, "Enter a name for this account.")
        XCTAssertTrue(viewModel.accountSettingsSaveFailed)

        let failing = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: personal,
            accounts: [personal],
            accountSaver: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        failing.saveDisplayName("Home", accountID: personal.id)
        XCTAssertEqual(failing.accountSettingsMessage, "Account settings could not be saved.")
        XCTAssertTrue(failing.accountSettingsSaveFailed, "the page shows the message only when this is set")
        XCTAssertEqual(failing.accounts.map(\.displayName), ["Personal"])

        viewModel.saveDisplayName("Home", accountID: personal.id)
        XCTAssertFalse(viewModel.accountSettingsSaveFailed)
    }

    @MainActor
    func testFailedServerSettingsSaveIsReportedAsAFailure() {
        let personal = Account(
            id: AccountID("acc_personal"), displayName: "Personal", email: EmailAddress("me@example.com"),
            username: "me@example.com", imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            displayName: personal.displayName,
            email: personal.email.rawValue,
            imapHost: personal.imapHost,
            smtpHost: personal.smtpHost,
            username: personal.username,
            status: .connected(accountID: personal.id.rawValue),
            account: personal,
            accounts: [personal],
            accountSaver: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        viewModel.imapHost = "imap.new.example"

        viewModel.saveAccountSettings()

        XCTAssertEqual(viewModel.accountSettingsMessage, "Account settings could not be saved.")
        XCTAssertTrue(viewModel.accountSettingsSaveFailed)
    }

    @MainActor
    func testConnectedAccountFieldsSaveWithoutChangingStableAccountID() {
        let original = Account(
            id: AccountID("acc_personal"),
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            username: "me@example.com",
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let recorder = AccountSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            displayName: original.displayName,
            email: original.email.rawValue,
            imapHost: original.imapHost,
            smtpHost: original.smtpHost,
            username: original.username,
            status: .connected(accountID: original.id.rawValue),
            account: original,
            accounts: [original],
            accountSaver: recorder.save
        )

        viewModel.displayName = "Work"
        viewModel.imapHost = "imap.work.example"
        XCTAssertFalse(viewModel.isAccountSaveDisabled)

        viewModel.saveAccountSettings()

        XCTAssertEqual(recorder.savedAccount?.id, original.id)
        XCTAssertEqual(recorder.savedAccount?.displayName, "Work")
        XCTAssertEqual(recorder.savedAccount?.imapHost, "imap.work.example")
        XCTAssertEqual(viewModel.accountSettingsMessage, "Account settings saved.")
        XCTAssertFalse(viewModel.accountSettingsSaveFailed)
        XCTAssertTrue(viewModel.isAccountSaveDisabled)
    }

    @MainActor
    func testConnectedAccountSettingsSavePreservesAccountScopedDefinition() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-account-save-upsert-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        defer { try? FileManager.default.removeItem(at: store.auditLogURL) }
        try store.migrate()
        let original = Account(
            id: AccountID("acc_work"),
            displayName: "Work",
            email: EmailAddress("me@work.example"),
            username: "me@work.example",
            imapHost: "imap.work.example",
            smtpHost: "smtp.work.example"
        )
        try store.cacheAccounts([original])
        try store.saveMailLabel(try MailLabelDefinition.validated(
            id: "work-label",
            title: "Work Label",
            description: "Account-scoped definition",
            isSmartInboxEnabled: true,
            scope: .account(original.id)
        ))
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            displayName: original.displayName,
            email: original.email.rawValue,
            imapHost: original.imapHost,
            smtpHost: original.smtpHost,
            username: original.username,
            status: .connected(accountID: original.id.rawValue),
            account: original,
            accounts: [original],
            accountSaver: { try store.cacheAccounts([$0]) }
        )
        viewModel.displayName = "Renamed Work"
        viewModel.email = "renamed@work.example"

        viewModel.saveAccountSettings()

        XCTAssertEqual(viewModel.accountSettingsMessage, "Account settings saved.")
        XCTAssertEqual(store.accounts.first?.displayName, "Renamed Work")
        XCTAssertEqual(store.accounts.first?.email, EmailAddress("renamed@work.example"))
        XCTAssertEqual(
            try store.mailLabels(effectiveFor: original.id).map(\.id),
            ["work-label"]
        )
    }

    @MainActor
    func testSelectingAnotherAccountLoadsEditableConnectionState() {
        let personal = Account(
            id: AccountID("acc_personal"),
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let work = Account(
            id: AccountID("acc_work"),
            displayName: "Work",
            email: EmailAddress("me@work.example"),
            imapHost: "imap.work.example",
            smtpHost: "smtp.work.example"
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            displayName: personal.displayName,
            email: personal.email.rawValue,
            imapHost: personal.imapHost,
            smtpHost: personal.smtpHost,
            username: personal.username,
            status: .connected(accountID: personal.id.rawValue),
            account: personal,
            accounts: [personal, work]
        )

        viewModel.selectAccount(id: work.id)

        XCTAssertEqual(viewModel.account?.id, work.id)
        XCTAssertEqual(viewModel.displayName, "Work")
        XCTAssertEqual(viewModel.email, "me@work.example")
        XCTAssertEqual(viewModel.imapHost, "imap.work.example")
        XCTAssertEqual(viewModel.smtpHost, "smtp.work.example")
    }

    @MainActor
    func testOnlyFreshSetupPublishesMailRouteSelection() async throws {
        let personal = Account(
            id: AccountID("acc_personal"), displayName: "Personal", email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let work = Account(
            id: AccountID("acc_work"), displayName: "Work", email: EmailAddress("me@work.example"),
            imapHost: "imap.work.example", smtpHost: "smtp.work.example"
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(), status: .connected(accountID: personal.id.rawValue),
            account: personal, accounts: [personal, work]
        )
        var activeMailRoute = personal.id
        var switches: [AccountID] = []
        let observation = viewModel.$completedAddEvent.compactMap { $0 }.sink { event in
            activeMailRoute = event.accountID
            switches.append(event.accountID)
        }
        defer { observation.cancel() }

        viewModel.selectAccount(id: work.id)
        await viewModel.syncInbox()
        XCTAssertEqual(activeMailRoute, personal.id)
        XCTAssertTrue(switches.isEmpty)

        viewModel.resetForNewAccount()
        viewModel.selectProvider(.other)
        viewModel.displayName = "New"
        viewModel.email = "new@example.com"
        viewModel.imapHost = "imap.example.com"
        viewModel.smtpHost = "smtp.example.com"
        viewModel.imapPassword = "imap-secret"
        viewModel.smtpPassword = "smtp-secret"
        try await viewModel.submit()
        XCTAssertEqual(switches, [AccountID("acc_me_example_com")])
        XCTAssertEqual(activeMailRoute, AccountID("acc_me_example_com"))

        viewModel.selectAccount(id: work.id)
        await viewModel.syncInbox()
        XCTAssertEqual(switches.count, 1)
        XCTAssertEqual(activeMailRoute, AccountID("acc_me_example_com"))
    }

    @MainActor
    func testSettingsAddSheetForwardsCompletedAddExactlyOnce() async throws {
        let work = Account(
            id: AccountID("acc_work"), displayName: "Work", email: EmailAddress("me@work.example"),
            imapHost: "imap.work.example", smtpHost: "smtp.work.example"
        )
        let parent = AccountSetupViewModel(
            setup: RecordingAccountSetupService(), status: .connected(accountID: work.id.rawValue),
            account: work, accounts: [work]
        )
        var routed: [AccountID] = []
        let observation = parent.$completedAddEvent.compactMap { $0 }.sink { routed.append($0.accountID) }
        defer { observation.cancel() }
        let sheet = parent.makeAdditionalAccountViewModel()
        sheet.selectProvider(.other)
        sheet.displayName = "New"
        sheet.email = "new@example.com"
        sheet.imapHost = "imap.example.com"
        sheet.smtpHost = "smtp.example.com"
        sheet.imapPassword = "imap-secret"
        sheet.smtpPassword = "smtp-secret"

        try await sheet.submit()
        XCTAssertEqual(routed, [AccountID("acc_me_example_com")])
        XCTAssertEqual(parent.account?.id, work.id)

        parent.selectAccount(id: work.id)
        await parent.syncInbox()
        XCTAssertEqual(routed, [AccountID("acc_me_example_com")])
    }

    @MainActor
    func testDeleteSelectedAccountReloadsAndSelectsFirstRemainingAccount() async {
        let first = deletionTestAccount(id: "acc_first", email: "first@example.com")
        let selected = deletionTestAccount(id: "acc_selected", email: "selected@example.com")
        let last = deletionTestAccount(id: "acc_last", email: "last@example.com")
        let deletion = AccountDeletionTestState(accounts: [first, selected, last])
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: selected,
            accounts: [first, selected, last],
            accountsProvider: deletion.loadAccounts,
            accountDeleter: deletion.delete
        )

        await viewModel.deleteSelectedAccount()

        XCTAssertEqual(deletion.deletedAccountIDs, [selected.id])
        XCTAssertEqual(viewModel.accounts.map(\.id), [first.id, last.id])
        XCTAssertEqual(viewModel.account?.id, first.id)
        XCTAssertEqual(viewModel.email, "first@example.com")
        XCTAssertFalse(viewModel.isDeletingAccount)
        XCTAssertNil(viewModel.accountDeletionMessage)
    }

    @MainActor
    func testDeleteLastAccountLoadsIdleZeroAccountState() async {
        let account = deletionTestAccount(id: "acc_only", email: "only@example.com")
        let deletion = AccountDeletionTestState(accounts: [account])
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            selectedProvider: .other,
            displayName: account.displayName,
            email: account.email.rawValue,
            imapHost: account.imapHost,
            smtpHost: account.smtpHost,
            username: account.username,
            status: .connected(accountID: account.id.rawValue),
            account: account,
            accounts: [account],
            accountsProvider: deletion.loadAccounts,
            accountDeleter: deletion.delete
        )

        await viewModel.deleteSelectedAccount()

        XCTAssertNil(viewModel.account)
        XCTAssertTrue(viewModel.accounts.isEmpty)
        XCTAssertEqual(viewModel.status, .idle)
        XCTAssertNil(viewModel.selectedProvider)
        XCTAssertEqual(viewModel.displayName, "")
        XCTAssertEqual(viewModel.email, "")
        XCTAssertEqual(viewModel.username, "")
        XCTAssertEqual(viewModel.imapHost, "")
        XCTAssertEqual(viewModel.smtpHost, "")
        XCTAssertNil(viewModel.lastConnectedEmail)
        XCTAssertFalse(viewModel.isDeletingAccount)
        XCTAssertNil(viewModel.accountDeletionMessage)
    }

    @MainActor
    func testDeleteSelectedAccountPrecommitFailuresKeepSelectionAndExposeSafeMessage() async {
        let account = deletionTestAccount(id: "acc_failure", email: "failure@example.com")
        let failures: [Error] = [
            TestError.failed,
            PlainpostServiceClientError.accountDeletionCompensationFailed,
        ]

        for failure in failures {
            let deletion = AccountDeletionTestState(accounts: [account], failure: failure)
            let viewModel = AccountSetupViewModel(
                setup: RecordingAccountSetupService(),
                account: account,
                accounts: [account],
                accountsProvider: deletion.loadAccounts,
                accountDeleter: deletion.delete
            )

            await viewModel.deleteSelectedAccount()

            XCTAssertEqual(deletion.deletedAccountIDs, [account.id])
            XCTAssertEqual(viewModel.account?.id, account.id)
            XCTAssertEqual(viewModel.accounts.map(\.id), [account.id])
            XCTAssertEqual(
                viewModel.accountDeletionMessage,
                "Account could not be deleted from Plainpost."
            )
            XCTAssertFalse(viewModel.isDeletingAccount)
        }
    }

    @MainActor
    func testDeleteSelectedAccountCleanupPendingReloadsFirstRemainingAccount() async {
        let remaining = deletionTestAccount(id: "acc_remaining", email: "remaining@example.com")
        let deleted = deletionTestAccount(id: "acc_cleanup", email: "cleanup@example.com")
        let deletion = AccountDeletionTestState(
            accounts: [remaining, deleted],
            failure: PlainpostServiceClientError.accountDeletionCleanupPending,
            removesBeforeFailure: true
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: deleted,
            accounts: [remaining, deleted],
            accountsProvider: deletion.loadAccounts,
            accountDeleter: deletion.delete
        )

        await viewModel.deleteSelectedAccount()

        XCTAssertEqual(viewModel.accounts.map(\.id), [remaining.id])
        XCTAssertEqual(viewModel.account?.id, remaining.id)
        XCTAssertEqual(
            viewModel.accountDeletionMessage,
            "Account deleted from Plainpost. Local audit cleanup will finish automatically."
        )
        XCTAssertFalse(viewModel.isDeletingAccount)
    }

    @MainActor
    func testDeleteLastAccountCleanupPendingLoadsZeroAccountState() async {
        let account = deletionTestAccount(id: "acc_cleanup_only", email: "cleanup-only@example.com")
        let deletion = AccountDeletionTestState(
            accounts: [account],
            failure: PlainpostServiceClientError.accountDeletionCleanupPending,
            removesBeforeFailure: true
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accounts: [account],
            accountsProvider: deletion.loadAccounts,
            accountDeleter: deletion.delete
        )

        await viewModel.deleteSelectedAccount()

        XCTAssertTrue(viewModel.accounts.isEmpty)
        XCTAssertNil(viewModel.account)
        XCTAssertEqual(viewModel.status, .idle)
        XCTAssertEqual(
            viewModel.accountDeletionMessage,
            "Account deleted from Plainpost. Local audit cleanup will finish automatically."
        )
        XCTAssertFalse(viewModel.isDeletingAccount)
    }

    @MainActor
    func testDeleteSelectedAccountIgnoresDuplicateCallsWhileExecuting() async {
        let account = deletionTestAccount(id: "acc_duplicate", email: "duplicate@example.com")
        let deletion = SuspendedAccountDeletionTestState(accounts: [account])
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accounts: [account],
            accountsProvider: deletion.loadAccounts,
            accountDeleter: deletion.delete
        )

        let first = Task { await viewModel.deleteSelectedAccount() }
        await deletion.waitUntilStarted()
        XCTAssertTrue(viewModel.isDeletingAccount)
        await viewModel.deleteSelectedAccount()
        XCTAssertEqual(deletion.deletedAccountIDs, [account.id])

        deletion.succeed()
        await first.value
        XCTAssertEqual(deletion.deletedAccountIDs, [account.id])
        XCTAssertFalse(viewModel.isDeletingAccount)
    }

    @MainActor
    func testAdditionalAccountViewModelRetainsDeletionHandler() async {
        let account = deletionTestAccount(id: "acc_additional", email: "additional@example.com")
        let deletion = AccountDeletionTestState(accounts: [account])
        let parent = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            accountsProvider: deletion.loadAccounts,
            accountDeleter: deletion.delete
        )
        let additional = parent.makeAdditionalAccountViewModel()
        additional.reloadAccounts(selecting: account.id)

        await additional.deleteSelectedAccount()

        XCTAssertEqual(deletion.deletedAccountIDs, [account.id])
        XCTAssertNil(additional.account)
        XCTAssertTrue(additional.accounts.isEmpty)
    }

    @MainActor
    func testConnectedAccountPasswordsSaveToCredentialHandlerAndClearFields() async {
        let account = Account(
            id: AccountID("acc_personal"),
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let recorder = CredentialSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            displayName: account.displayName,
            email: account.email.rawValue,
            imapHost: account.imapHost,
            smtpHost: account.smtpHost,
            username: account.username,
            status: .connected(accountID: account.id.rawValue),
            account: account,
            accountCredentialSaver: recorder.save
        )
        viewModel.imapPassword = "new-imap-secret"
        viewModel.smtpPassword = "new-smtp-secret"

        await viewModel.saveAccountPasswords()

        XCTAssertEqual(recorder.accountID, account.id)
        XCTAssertEqual(recorder.imapPassword, "new-imap-secret")
        XCTAssertEqual(recorder.smtpPassword, "new-smtp-secret")
        XCTAssertEqual(viewModel.imapPassword, "")
        XCTAssertEqual(viewModel.smtpPassword, "")
        XCTAssertEqual(viewModel.credentialSettingsMessage, "Passwords updated.")
    }

    @MainActor
    func testGmailCredentialReplacementDetectsCanonicalServersAndExplainsSharedPassword() {
        let account = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@company.example"),
            imapHost: "IMAP.GMAIL.COM",
            smtpHost: "smtp.gmail.com"
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account
        )

        XCTAssertTrue(viewModel.isSelectedAccountGmail)
        XCTAssertEqual(
            viewModel.credentialReplacementHelp,
            "One 16-character Google App Password covers incoming and outgoing mail."
        )
    }

    @MainActor
    func testGmailCredentialReplacementNormalizesTheSharedPasswordBeforeSaving() async {
        let account = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        let recorder = CredentialSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: recorder.save
        )
        viewModel.imapPassword = "abcd efgh\nijkl mnop"

        await viewModel.saveAccountPasswords()

        XCTAssertEqual(recorder.accountID, account.id)
        XCTAssertEqual(recorder.imapPassword, "abcdefghijklmnop")
        XCTAssertEqual(recorder.smtpPassword, "abcdefghijklmnop")
        XCTAssertEqual(viewModel.imapPassword, "")
        XCTAssertEqual(viewModel.smtpPassword, "")
    }

    @MainActor
    func testGmailCredentialReplacementRejectsAnInvalidDraftWithoutSavingIt() async {
        let account = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        let recorder = CredentialSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: recorder.save
        )
        let draft = "abcd efgh ijkl mno"
        viewModel.imapPassword = draft

        XCTAssertTrue(viewModel.isCredentialSaveDisabled)
        await viewModel.saveAccountPasswords()

        XCTAssertNil(recorder.accountID)
        XCTAssertEqual(viewModel.imapPassword, draft)
        let message = try? XCTUnwrap(viewModel.credentialSettingsMessage)
        XCTAssertEqual(message, "Enter the 16-character Google App Password.")
        XCTAssertFalse(message?.contains(draft) ?? true)
    }

    @MainActor
    func testICloudCredentialReplacementSavesTheOneAppPasswordForBothServers() async {
        let account = Account(
            id: AccountID("acc_icloud"),
            displayName: "iCloud",
            email: EmailAddress("me@icloud.com"),
            imapHost: "imap.mail.me.com",
            smtpHost: "smtp.mail.me.com"
        )
        let recorder = CredentialSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: recorder.save
        )
        XCTAssertTrue(viewModel.usesSharedAppPassword)
        XCTAssertTrue(viewModel.isCredentialSaveDisabled)
        viewModel.imapPassword = "abcd-efgh-ijkl-mnop"
        XCTAssertFalse(viewModel.isCredentialSaveDisabled)

        await viewModel.saveAccountPasswords()

        XCTAssertEqual(recorder.imapPassword, recorder.smtpPassword)
        XCTAssertEqual(recorder.accountID, account.id)
        XCTAssertEqual(viewModel.credentialSettingsMessage, "Passwords updated.")
    }

    @MainActor
    func testGmailCredentialReplacementUsesFixedCopyForMaliciousValidationFailure() async {
        let account = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: { _, _, _ in
                throw PlainpostError.validationFailed("submitted secret: abcd efgh ijkl mnop")
            }
        )
        let sharedDraft = "abcd efgh ijkl mnop"
        viewModel.imapPassword = sharedDraft

        await viewModel.saveAccountPasswords()

        XCTAssertEqual(viewModel.imapPassword, sharedDraft)
        XCTAssertEqual(
            viewModel.credentialSettingsMessage,
            "Check the 16-character Google App Password and try again."
        )
        XCTAssertFalse(viewModel.credentialSettingsMessage?.contains(sharedDraft) ?? true)
        XCTAssertFalse(viewModel.credentialSettingsMessage?.contains("submitted secret") ?? true)
    }

    @MainActor
    func testGmailCredentialReplacementUsesFixedCopyForXPCOperationFailure() async {
        let account = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: { _, _, _ in
                throw PlainpostServiceClientError.operationFailed
            }
        )
        let sharedDraft = "abcd efgh ijkl mnop"
        viewModel.imapPassword = sharedDraft

        await viewModel.saveAccountPasswords()

        XCTAssertEqual(viewModel.imapPassword, sharedDraft)
        XCTAssertEqual(
            viewModel.credentialSettingsMessage,
            "Check the 16-character Google App Password and try again."
        )
    }

    @MainActor
    func testNonGmailCredentialReplacementKeepsIndependentPasswords() async {
        let account = Account(
            id: AccountID("acc_custom"),
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let recorder = CredentialSaveRecorder()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: recorder.save
        )
        viewModel.imapPassword = " incoming password "
        viewModel.smtpPassword = "outgoing password"

        XCTAssertFalse(viewModel.isSelectedAccountGmail)
        XCTAssertFalse(viewModel.isCredentialSaveDisabled)
        await viewModel.saveAccountPasswords()

        XCTAssertEqual(recorder.imapPassword, " incoming password ")
        XCTAssertEqual(recorder.smtpPassword, "outgoing password")
    }

    @MainActor
    func testNonGmailCredentialReplacementUsesFixedRetryCopyForOpaqueFailure() async {
        let account = Account(
            id: AccountID("acc_custom"),
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: { _, _, _ in throw TestError.failed }
        )
        viewModel.imapPassword = "incoming-secret"
        viewModel.smtpPassword = "outgoing-secret"

        await viewModel.saveAccountPasswords()

        XCTAssertEqual(viewModel.imapPassword, "incoming-secret")
        XCTAssertEqual(viewModel.smtpPassword, "outgoing-secret")
        XCTAssertEqual(
            viewModel.credentialSettingsMessage,
            "Passwords could not be updated. Check both passwords and try again."
        )
        XCTAssertFalse(viewModel.credentialSettingsMessage?.contains("incoming-secret") ?? true)
        XCTAssertFalse(viewModel.credentialSettingsMessage?.contains("outgoing-secret") ?? true)
    }

    @MainActor
    func testCredentialReplacementIgnoresDuplicateSubmissionAndDoesNotMutateAnotherAccount() async {
        let gmail = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        let custom = Account(
            id: AccountID("acc_custom"),
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let gate = SuspendedCredentialSaver()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: gmail,
            accounts: [gmail, custom],
            accountCredentialSaver: gate.save
        )
        viewModel.imapPassword = "abcd efgh ijkl mnop"
        viewModel.smtpPassword = "abcd efgh ijkl mnop"

        let save = Task { await viewModel.saveAccountPasswords() }
        await gate.waitUntilStarted()

        XCTAssertTrue(viewModel.isSavingAccountCredentials)
        XCTAssertTrue(viewModel.isCredentialSaveDisabled)
        await viewModel.saveAccountPasswords()
        let requestCount = await gate.requestCount
        XCTAssertEqual(requestCount, 1)

        viewModel.selectAccount(id: custom.id)
        viewModel.imapPassword = "custom incoming"
        viewModel.smtpPassword = "custom outgoing"
        await gate.succeed()
        await save.value

        XCTAssertFalse(viewModel.isSavingAccountCredentials)
        XCTAssertEqual(viewModel.account?.id, custom.id)
        XCTAssertEqual(viewModel.imapPassword, "custom incoming")
        XCTAssertEqual(viewModel.smtpPassword, "custom outgoing")
        XCTAssertNil(viewModel.credentialSettingsMessage)
    }

    @MainActor
    func testCredentialReplacementCompletionDoesNotMutateEditedDraftForSameAccount() async {
        let account = Account(
            id: AccountID("acc_custom"),
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let gate = SuspendedCredentialSaver()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: gate.save
        )
        viewModel.imapPassword = "first incoming"
        viewModel.smtpPassword = "first outgoing"

        let save = Task { await viewModel.saveAccountPasswords() }
        await gate.waitUntilStarted()
        viewModel.imapPassword = "edited incoming"
        viewModel.smtpPassword = "edited outgoing"
        await gate.succeed()
        await save.value

        XCTAssertEqual(viewModel.imapPassword, "edited incoming")
        XCTAssertEqual(viewModel.smtpPassword, "edited outgoing")
        XCTAssertNil(viewModel.credentialSettingsMessage)
    }

    @MainActor
    func testCredentialReplacementCompletionRejectsSameIDProviderConfigurationChange() async {
        let sharedID = AccountID("acc_shared")
        let gmail = Account(
            id: sharedID,
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        let custom = Account(
            id: sharedID,
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let gate = SuspendedCredentialSaver()
        let sharedDraft = "abcd efgh ijkl mnop"
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: gmail,
            accounts: [gmail],
            accountsProvider: { [custom] },
            accountCredentialSaver: gate.save
        )
        viewModel.imapPassword = sharedDraft
        viewModel.smtpPassword = sharedDraft

        let save = Task { await viewModel.saveAccountPasswords() }
        await gate.waitUntilStarted()
        viewModel.reloadAccounts(selecting: sharedID)
        viewModel.imapPassword = sharedDraft
        viewModel.smtpPassword = sharedDraft
        await gate.succeed()
        await save.value

        XCTAssertFalse(viewModel.isSelectedAccountGmail)
        XCTAssertEqual(viewModel.account?.imapHost, "imap.example.com")
        XCTAssertEqual(viewModel.imapPassword, sharedDraft)
        XCTAssertNil(viewModel.credentialSettingsMessage)
    }

    @MainActor
    func testCredentialReplacementCompletionRejectsABASelectionWithUnchangedDrafts() async {
        let first = Account(
            id: AccountID("acc_first"),
            displayName: "First",
            email: EmailAddress("first@example.com"),
            imapHost: "imap.first.example",
            smtpHost: "smtp.first.example"
        )
        let second = Account(
            id: AccountID("acc_second"),
            displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.second.example",
            smtpHost: "smtp.second.example"
        )
        let gate = SuspendedCredentialSaver()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: first,
            accounts: [first, second],
            accountCredentialSaver: gate.save
        )
        viewModel.imapPassword = "incoming draft"
        viewModel.smtpPassword = "outgoing draft"

        let save = Task { await viewModel.saveAccountPasswords() }
        await gate.waitUntilStarted()
        viewModel.selectAccount(id: second.id)
        viewModel.selectAccount(id: first.id)
        viewModel.imapPassword = "incoming draft"
        viewModel.smtpPassword = "outgoing draft"
        await gate.succeed()
        await save.value

        XCTAssertEqual(viewModel.account?.id, first.id)
        XCTAssertEqual(viewModel.imapPassword, "incoming draft")
        XCTAssertEqual(viewModel.smtpPassword, "outgoing draft")
        XCTAssertNil(viewModel.credentialSettingsMessage)
    }

    @MainActor
    func testValidCredentialRetryClearsStaleStatusWhileRequestIsInFlight() async {
        let account = Account(
            id: AccountID("acc_custom"),
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let saver = FailingThenSuspendedCredentialSaver()
        let viewModel = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accountCredentialSaver: saver.save
        )
        viewModel.imapPassword = "incoming secret"
        viewModel.smtpPassword = "outgoing secret"

        await viewModel.saveAccountPasswords()
        XCTAssertEqual(
            viewModel.credentialSettingsMessage,
            "Passwords could not be updated. Check both passwords and try again."
        )

        let retry = Task { await viewModel.saveAccountPasswords() }
        await saver.waitUntilRetryStarted()

        XCTAssertTrue(viewModel.isSavingAccountCredentials)
        XCTAssertNil(viewModel.credentialSettingsMessage)

        await saver.succeed()
        await retry.value
    }

    @MainActor
    func testFailedMailboxSelectionSaveRestoresThePreviousMode() {
        let viewModel = connectedAccountViewModel(
            mailboxPreferences: [.init(accountID: accountID, mailboxPath: "Archive", mode: .recent)],
            mailboxPreferenceSaver: { _ in throw TestError.failed }
        )

        viewModel.setMailboxSelected(false, path: "Archive")

        XCTAssertTrue(viewModel.isMailboxSelected("Archive"))
        XCTAssertEqual(viewModel.mailboxModes["Archive"], .recent)
        XCTAssertEqual(viewModel.lastSyncError, "Mailbox selection could not be saved.")
    }

    @MainActor
    func testFailedMailboxSelectionSaveRestoresTheCompleteMode() {
        let viewModel = connectedAccountViewModel(
            mailboxPreferences: [.init(accountID: accountID, mailboxPath: "Archive", mode: .complete)],
            mailboxPreferenceSaver: { _ in throw TestError.failed }
        )

        viewModel.setMailboxSelected(false, path: "Archive")

        XCTAssertTrue(viewModel.isMailboxSelected("Archive"))
        XCTAssertEqual(viewModel.mailboxModes["Archive"], .complete)
        XCTAssertEqual(viewModel.lastSyncError, "Mailbox selection could not be saved.")
    }

    @MainActor
    func testEnableMailboxSyncChangesDisabledMailboxToRecent() async {
        let viewModel = connectedAccountViewModel(
            mailboxPreferences: [.init(accountID: accountID, mailboxPath: "Archive", mode: .off)]
        )

        await viewModel.enableMailboxSync(path: "Archive")

        XCTAssertEqual(viewModel.mailboxModes["Archive"], .recent)
        XCTAssertFalse(viewModel.isMailboxSyncDisabled(path: "Archive"))
    }

    @MainActor
    func testFailedSyncPreferenceSaveRestoresAllFormerValues() {
        let viewModel = connectedAccountViewModel(syncPreferencesSaver: { _ in throw TestError.failed })

        viewModel.updateSyncPreferences(
            downloadCompleteHistory: true,
            recentMessageLimit: 500,
            realTimeMonitoringEnabled: false
        )

        XCTAssertFalse(viewModel.downloadCompleteHistory)
        XCTAssertEqual(viewModel.recentMessageLimit, 100)
        XCTAssertTrue(viewModel.realTimeMonitoringEnabled)
        XCTAssertEqual(viewModel.lastSyncError, "Sync preferences could not be saved.")
    }

    private var accountID: AccountID { AccountID("acc_personal") }

    @MainActor
    private func connectedAccountViewModel(
        syncPreferences: MailSyncPreferences? = nil,
        syncPreferencesSaver: (@Sendable (MailSyncPreferences) throws -> Void)? = nil,
        mailboxPreferences: [MailboxSyncPreference] = [],
        mailboxPreferenceSaver: (@Sendable (MailboxSyncPreference) throws -> Void)? = nil
    ) -> AccountSetupViewModel {
        let account = Account(
            id: accountID,
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        return AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            displayName: account.displayName,
            email: account.email.rawValue,
            imapHost: account.imapHost,
            smtpHost: account.smtpHost,
            username: account.username,
            status: .connected(accountID: account.id.rawValue),
            account: account,
            syncPreferences: syncPreferences,
            syncPreferencesSaver: syncPreferencesSaver,
            mailboxPreferences: mailboxPreferences,
            availableMailboxPaths: ["Archive", "INBOX"],
            mailboxPreferenceSaver: mailboxPreferenceSaver
        )
    }
}

private enum TestError: Error {
    case failed
}

private func deletionTestAccount(id: String, email: String) -> Account {
    Account(
        id: AccountID(id),
        displayName: id,
        email: EmailAddress(email),
        username: email,
        imapHost: "imap.\(email)",
        smtpHost: "smtp.\(email)"
    )
}

private final class AccountDeletionTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAccounts: [Account]
    private var requests: [AccountID] = []
    private let failure: Error?
    private let removesBeforeFailure: Bool

    init(
        accounts: [Account],
        failure: Error? = nil,
        removesBeforeFailure: Bool = false
    ) {
        storedAccounts = accounts
        self.failure = failure
        self.removesBeforeFailure = removesBeforeFailure
    }

    var deletedAccountIDs: [AccountID] {
        lock.withLock { requests }
    }

    func loadAccounts() -> [Account] {
        lock.withLock { storedAccounts }
    }

    func delete(_ accountID: AccountID) async throws {
        lock.withLock { requests.append(accountID) }
        if removesBeforeFailure {
            lock.withLock {
                storedAccounts.removeAll { $0.id == accountID }
            }
        }
        if let failure { throw failure }
        if !removesBeforeFailure {
            lock.withLock {
                storedAccounts.removeAll { $0.id == accountID }
            }
        }
    }
}

private final class SuspendedAccountDeletionTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAccounts: [Account]
    private var requests: [AccountID] = []
    private var started = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    init(accounts: [Account]) {
        storedAccounts = accounts
    }

    var deletedAccountIDs: [AccountID] {
        lock.withLock { requests }
    }

    func loadAccounts() -> [Account] {
        lock.withLock { storedAccounts }
    }

    func delete(_ accountID: AccountID) async {
        lock.withLock {
            requests.append(accountID)
            started = true
            let continuations = startedContinuations
            startedContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
        await withCheckedContinuation { continuation in
            lock.withLock { completion = continuation }
        }
        lock.withLock {
            storedAccounts.removeAll { $0.id == accountID }
        }
    }

    func waitUntilStarted() async {
        if lock.withLock({ started }) { return }
        await withCheckedContinuation { continuation in
            lock.withLock { startedContinuations.append(continuation) }
        }
    }

    func succeed() {
        lock.withLock {
            completion?.resume()
            completion = nil
        }
    }
}

private final class AccountSaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var account: Account?

    var savedAccount: Account? {
        lock.withLock { account }
    }

    func save(_ account: Account) {
        lock.withLock { self.account = account }
    }
}

private final class CredentialSaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: (AccountID, String, String)?

    var accountID: AccountID? { lock.withLock { saved?.0 } }
    var imapPassword: String? { lock.withLock { saved?.1 } }
    var smtpPassword: String? { lock.withLock { saved?.2 } }

    func save(accountID: AccountID, imapPassword: String, smtpPassword: String) {
        lock.withLock { saved = (accountID, imapPassword, smtpPassword) }
    }
}

private actor SuspendedCredentialSaver {
    private(set) var requestCount = 0
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func save(accountID: AccountID, imapPassword: String, smtpPassword: String) async {
        requestCount += 1
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard requestCount == 1 else { return }
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeed() {
        completion?.resume()
        completion = nil
    }
}

private actor FailingThenSuspendedCredentialSaver {
    private var requestCount = 0
    private var retryStarted = false
    private var retryWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func save(accountID: AccountID, imapPassword: String, smtpPassword: String) async throws {
        requestCount += 1
        if requestCount == 1 {
            throw TestError.failed
        }
        retryStarted = true
        let waiters = retryWaiters
        retryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilRetryStarted() async {
        guard !retryStarted else { return }
        await withCheckedContinuation { retryWaiters.append($0) }
    }

    func succeed() {
        completion?.resume()
        completion = nil
    }
}

private final class RecordingAccountSetupService: AccountSetupHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [AccountSetupRequest] = []

    var requests: [AccountSetupRequest] {
        lock.withLock { recordedRequests }
    }

    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        lock.withLock {
            recordedRequests.append(request)
        }
        return AccountSetupResult(
            account: Account(
                id: AccountID("acc_me_example_com"),
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

private struct FailingAccountSetupService: AccountSetupHandling {
    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        throw PlainpostError.validationFailed("secret provider detail")
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        throw PlainpostError.validationFailed("not used")
    }
}

// MARK: - Google sign-in

extension AccountSetupViewModelTests {
    #if os(iOS)
    @MainActor
    func testIPhoneGmailSignInNeedsNoTypedNameOrAddress() async {
        let setup = RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com")
        let model = AccountSetupViewModel(setup: setup, selectedProvider: .gmail)
        let hints = LoginHintRecorder()
        model.googleAuthorization = { hint in
            hints.values.append(hint)
            return GmailAuthorizationCode(code: "4/code", verifier: String(repeating: "v", count: 43),
                                          redirectURI: "com.googleusercontent.apps.fixture:/oauth2redirect")
        }

        XCTAssertFalse(model.isGoogleSignInDisabled)
        await model.signInWithGoogle()

        XCTAssertEqual(hints.values, [""])
        XCTAssertEqual(setup.addedAccounts, ["ada@gmail.com"])
        XCTAssertEqual(model.account?.email.rawValue, "ada@gmail.com")
    }
    #endif

    @MainActor
    func testGmailSignInRefusesMismatchedGoogleIdentityWithoutAddingAccount() async {
        let setup = RecordingGoogleSetupHandler(verifiedIdentity: "someone-else@gmail.com")
        let model = AccountSetupViewModel(setup: setup, selectedProvider: .gmail, displayName: "Ada", email: "ada@gmail.com")
        model.googleAuthorization = { _ in GmailAuthorizationCode(code: "c", verifier: String(repeating: "v", count: 43), redirectURI: "http://127.0.0.1:5000/oauth/mail/google") }
        await model.signInWithGoogle()
        XCTAssertEqual(model.status, .failed(message: "You signed in to Google as someone-else@gmail.com, but this account is ada@gmail.com. Sign in with ada@gmail.com to continue."))
        XCTAssertEqual(setup.addedAccounts, [])
    }

    @MainActor
    func testGmailCardNoLongerAsksForAppPassword() {
        let model = AccountSetupViewModel(setup: RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com"), selectedProvider: .gmail)
        XCTAssertFalse(model.gmailSetupRequiresAppPassword)
        XCTAssertTrue(model.otherIMAPDetail.contains("Gmail App Passwords"))
        XCTAssertEqual(model.gmailProviderDetail, "Sign in with Google. No App Password needed.")
    }

    @MainActor
    func testGmailSignInAddsAccountWithTheEnteredAddressAsLoginHint() async throws {
        let setup = RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com")
        let model = AccountSetupViewModel(setup: setup, selectedProvider: .gmail, displayName: "Ada", email: " ada@gmail.com ")
        let hints = LoginHintRecorder()
        model.googleAuthorization = { hint in
            hints.values.append(hint)
            return GmailAuthorizationCode(code: "4/code", verifier: String(repeating: "v", count: 43), redirectURI: "http://127.0.0.1:5000/oauth/mail/google")
        }
        XCTAssertEqual(model.gmailSignInState, .idle)
        XCTAssertFalse(model.isGoogleSignInDisabled)

        await model.signInWithGoogle()

        XCTAssertEqual(hints.values, ["ada@gmail.com"])
        XCTAssertEqual(setup.addedAccounts, ["ada@gmail.com"])
        XCTAssertEqual(setup.receivedCodes, ["4/code"])
        XCTAssertEqual(model.status, .connected(accountID: "acc_ada_gmail_com"))
        XCTAssertEqual(model.gmailSignInState, .idle)
        XCTAssertEqual(model.account?.imapHost, "imap.gmail.com")
        XCTAssertFalse(String(describing: model.status).contains("4/code"))
    }

    @MainActor
    func testGmailSignInExplainsDenialTimeoutMissingRefreshTokenAndMissingClient() async {
        let cases: [(Error, String)] = [
            (GmailOAuthAuthorizer.Error.denied, "Google sign-in was cancelled."),
            (GmailOAuthAuthorizer.Error.timedOut, "Google sign-in timed out. Try again."),
            (GoogleOAuthError.invalidResponse, "Google didn't return a usable sign-in for Gmail. Try again."),
            (GoogleOAuthError.gmailAPIUnavailable, "The Gmail API is disabled for Plainpost's Google project. Enable it in Google Cloud, then try again."),
            (GoogleOAuthError.gmailAccessDenied, "Google refused Gmail access after sign-in. Check your Google account or Workspace app policy."),
            (GoogleOAuthError.scopeMissing, "Google did not grant the Gmail scope Plainpost needs. Check the consent screen and OAuth app configuration."),
            (GoogleOAuthError.notConfigured, "Google sign-in isn't available in this build."),
        ]
        for (error, message) in cases {
            let setup = RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com", failure: error is GoogleOAuthError ? error : nil)
            let model = AccountSetupViewModel(setup: setup, selectedProvider: .gmail, displayName: "Ada", email: "ada@gmail.com")
            model.googleAuthorization = { _ in
                if error is GmailOAuthAuthorizer.Error { throw error }
                return GmailAuthorizationCode(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:5000/oauth/mail/google")
            }
            await model.signInWithGoogle()
            XCTAssertEqual(model.status, .failed(message: message))
            XCTAssertEqual(model.gmailSignInState, .failed(message))
            XCTAssertEqual(setup.addedAccounts, [])
        }
    }

    @MainActor
    func testGmailSignInIsUnavailableWithoutAPackagedClient() async {
        let setup = RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com")
        let model = AccountSetupViewModel(setup: setup, selectedProvider: .gmail, displayName: "Ada", email: "ada@gmail.com")

        XCTAssertEqual(model.gmailSignInState, .unavailable)
        XCTAssertFalse(model.isGoogleSignInAvailable)
        XCTAssertTrue(model.isGoogleSignInDisabled)
        XCTAssertEqual(model.gmailSignInReadinessMessage, "Google sign-in isn't available in this build.")
        await model.signInWithGoogle()
        XCTAssertEqual(model.status, .failed(message: "Google sign-in isn't available in this build."))
        XCTAssertEqual(setup.addedAccounts, [])
    }

    @MainActor
    func testBackCancelsTheInFlightGoogleAuthorization() async throws {
        let setup = RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com")
        let model = AccountSetupViewModel(setup: setup, selectedProvider: .gmail, displayName: "Ada", email: "ada@gmail.com")
        let observed = LoginHintRecorder()
        model.googleAuthorization = { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                observed.values.append("cancelled")
                throw GmailOAuthAuthorizer.Error.cancelled
            }
            return GmailAuthorizationCode(code: "late", verifier: "v", redirectURI: "http://127.0.0.1:5000/oauth/mail/google")
        }

        let signIn = Task { await model.signInWithGoogle() }
        for _ in 0..<200 where model.gmailSignInState != .waitingForBrowser {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.gmailSignInState, .waitingForBrowser)
        model.showProviderChooser()
        await signIn.value

        XCTAssertNil(model.selectedProvider)
        XCTAssertEqual(model.gmailSignInState, .idle)
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(observed.values, ["cancelled"])
        XCTAssertEqual(setup.addedAccounts, [])
        XCTAssertFalse(model.isSubmitting)
    }

    @MainActor
    func testBackDiscardsGoogleAccountReturnedAfterCancellation() async throws {
        let setup = LateGoogleSetupHandler()
        let model = AccountSetupViewModel(
            setup: setup, selectedProvider: .gmail, displayName: "Ada", email: "ada@gmail.com")
        model.googleAuthorization = { _ in
            GmailAuthorizationCode(code: "code", verifier: String(repeating: "v", count: 43),
                                   redirectURI: "http://127.0.0.1:5000/oauth/mail/google")
        }
        let signIn = Task { await model.signInWithGoogle() }
        for _ in 0..<200 where !setup.started {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(setup.started)
        model.showProviderChooser()
        await signIn.value
        XCTAssertEqual(setup.discarded, [AccountID("acc_ada_gmail_com")])
        XCTAssertNil(model.account)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertEqual(model.status, .idle)
    }

    @MainActor
    func testCancelledGmailCleanupFailureReloadsDurableAccountList() async throws {
        let setup = LateGoogleSetupHandler(cleanupFails: true)
        let model = AccountSetupViewModel(
            setup: setup, selectedProvider: .gmail, displayName: "Ada", email: "ada@gmail.com",
            accountsProvider: { setup.persistedAccounts })
        model.googleAuthorization = { _ in
            GmailAuthorizationCode(code: "code", verifier: String(repeating: "v", count: 43),
                                   redirectURI: "http://127.0.0.1:5000/oauth/mail/google")
        }
        let signIn = Task { await model.signInWithGoogle() }
        for _ in 0..<200 where !setup.started {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(setup.started)
        model.showProviderChooser()
        await signIn.value
        XCTAssertEqual(model.accounts.map(\.id), [AccountID("acc_ada_gmail_com")])
        XCTAssertNotNil(model.accountSettingsMessage)
        XCTAssertNotNil(model.googleSetupRecoveryMessage)
        XCTAssertEqual(model.status, .idle, "cancelled attempt must not overwrite a later provider selection")
    }

    @MainActor
    func testLateGmailResultFailedDiscardDoesNotReplaceNewerProviderSetup() async throws {
        let setup = LateGoogleSetupHandler(discardFails: true)
        let model = AccountSetupViewModel(
            setup: setup, selectedProvider: .gmail, displayName: "Ada", email: "ada@gmail.com",
            accountsProvider: { setup.persistedAccounts })
        model.googleAuthorization = { _ in
            GmailAuthorizationCode(code: "code", verifier: String(repeating: "v", count: 43),
                                   redirectURI: "http://127.0.0.1:5000/oauth/mail/google")
        }
        let signIn = Task { await model.signInWithGoogle() }
        for _ in 0..<200 where !setup.started {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(setup.started)
        model.selectProvider(.icloud)
        await signIn.value
        XCTAssertEqual(model.selectedProvider, .icloud)
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.account)
        XCTAssertEqual(model.accounts.map(\.id), [AccountID("acc_ada_gmail_com")])
        XCTAssertEqual(setup.discarded, [AccountID("acc_ada_gmail_com")])
        XCTAssertEqual(model.googleSetupRecoveryAccountID, AccountID("acc_ada_gmail_com"))
        XCTAssertNotNil(model.googleSetupRecoveryMessage)
        model.openRecoveredGoogleAccount()
        XCTAssertEqual(model.account?.id, AccountID("acc_ada_gmail_com"))
    }

    @MainActor
    func testReauthorizeGmailReplacesGrantAndClearsTheBannerState() async throws {
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"))
        let setup = RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com")
        let states = AuthenticationStateBox(AccountAuthenticationSummary(method: .googleOAuth, state: .reauthorizationRequired))
        let model = AccountSetupViewModel(
            setup: setup, account: account, accounts: [account],
            googleAuthorization: { _ in GmailAuthorizationCode(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:5000/oauth/mail/google") },
            accountAuthenticationProvider: { _ in states.value }
        )
        setup.onReauthorize = { states.value = AccountAuthenticationSummary(method: .googleOAuth, state: .ready) }

        XCTAssertEqual(model.reauthorizationRequiredAccountIDs, [account.id])
        XCTAssertTrue(model.selectedAccountNeedsReauthorization)
        XCTAssertTrue(model.isSelectedAccountGoogleOAuth)
        XCTAssertTrue(model.isCredentialSaveDisabled)

        await model.reauthorizeGmail(accountID: account.id)

        XCTAssertEqual(setup.reauthorizedAccounts, [account.id])
        XCTAssertEqual(model.reauthorizationRequiredAccountIDs, [])
        XCTAssertFalse(model.selectedAccountNeedsReauthorization)
        XCTAssertEqual(model.gmailReauthorizationMessage, "Gmail is signed in with Google.")
    }

    @MainActor
    func testEnteringThePasswordAgainClearsTheSignInAgainBanner() async throws {
        let account = Account(
            id: AccountID("acc_custom"),
            displayName: "Work",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let states = AuthenticationStateBox(AccountAuthenticationSummary(method: .password, state: .reauthorizationRequired))
        let model = AccountSetupViewModel(
            setup: RecordingAccountSetupService(),
            account: account,
            accounts: [account],
            accountCredentialSaver: { _, _, _ in
                states.value = AccountAuthenticationSummary(method: .password, state: .ready)
            },
            accountAuthenticationProvider: { _ in states.value }
        )
        XCTAssertTrue(model.selectedAccountNeedsReauthorization)
        XCTAssertTrue(model.selectedAccountNeedsPasswordAgain)

        model.imapPassword = "imap-secret"
        model.smtpPassword = "smtp-secret"
        await model.saveAccountPasswords()

        XCTAssertEqual(model.credentialSettingsMessage, "Passwords updated.")
        XCTAssertFalse(model.selectedAccountNeedsReauthorization)
        XCTAssertFalse(model.selectedAccountNeedsPasswordAgain)
        XCTAssertEqual(model.reauthorizationRequiredAccountIDs, [])
    }

    /// Settings refreshes on an account change another process committed. The
    /// root view owns the one `MailStoreChangeMonitor`; the view model no
    /// longer observes notifications itself.
    @MainActor
    func testCrossProcessAccountChangeRefreshesTheReauthorizationBanner() async throws {
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"))
        let states = AuthenticationStateBox(AccountAuthenticationSummary(method: .googleOAuth, state: .ready))
        let model = AccountSetupViewModel(
            setup: RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com"), account: account, accounts: [account],
            accountAuthenticationProvider: { _ in states.value }
        )
        let signals = MailStoreChangeSignalCenters()
        let monitor = signals.makeMonitor()
        let wiring = monitor.$accountRevision.dropFirst().sink { _ in
            MainActor.assumeIsolated { model.applyAccountStoreChange() }
        }
        defer { wiring.cancel() }
        XCTAssertFalse(model.selectedAccountNeedsReauthorization)

        // The service marks the grant refused and posts `.accounts` from its
        // own process, which arrives on the distributed center only.
        states.value = AccountAuthenticationSummary(method: .googleOAuth, state: .reauthorizationRequired)
        signals.postFromAnotherProcess(.accounts)
        let marked = await waitForMainActor { model.selectedAccountNeedsReauthorization }
        XCTAssertTrue(marked)
        XCTAssertEqual(model.reauthorizationRequiredAccountIDs, [account.id])

        states.value = AccountAuthenticationSummary(method: .googleOAuth, state: .ready)
        signals.postFromAnotherProcess(.all)
        let cleared = await waitForMainActor { !model.selectedAccountNeedsReauthorization }
        XCTAssertTrue(cleared)
    }

    /// `MailStoreChangeSignal.post` fires the local and the distributed
    /// notification in one call, so an in-process `.accounts` signal reaches
    /// the monitor twice. Each refresh is an O(accounts) synchronous SQLite
    /// read on the main actor, so the pair must still cost one refresh.
    @MainActor
    func testAnInProcessAccountSignalCostsOneRefreshNotTwo() async throws {
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"))
        let reads = ReadCounter()
        let model = AccountSetupViewModel(
            setup: RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com"), accounts: [account],
            accountAuthenticationProvider: { _ in
                reads.increment()
                return AccountAuthenticationSummary(method: .googleOAuth, state: .ready)
            }
        )
        let signals = MailStoreChangeSignalCenters()
        let monitor = signals.makeMonitor()
        let wiring = monitor.$accountRevision.dropFirst().sink { _ in
            MainActor.assumeIsolated { model.applyAccountStoreChange() }
        }
        defer { wiring.cancel() }
        let initialReads = reads.value

        signals.postInProcess(.accounts)
        let refreshed = await waitForMainActor { reads.value > initialReads }
        XCTAssertTrue(refreshed)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(reads.value - initialReads, 1, "one account signal, one account-authentication read")
    }

    /// Mailbox and operation signals must never read authentication state.
    @MainActor
    func testMailboxStoreSignalDoesNotReadAuthenticationState() async throws {
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"))
        let reads = ReadCounter()
        let model = AccountSetupViewModel(
            setup: RecordingGoogleSetupHandler(verifiedIdentity: "ada@gmail.com"), account: account, accounts: [account],
            accountAuthenticationProvider: { _ in
                reads.increment()
                return AccountAuthenticationSummary(method: .googleOAuth, state: .ready)
            }
        )
        let signals = MailStoreChangeSignalCenters()
        let monitor = signals.makeMonitor()
        let wiring = monitor.$accountRevision.dropFirst().sink { _ in
            MainActor.assumeIsolated { model.applyAccountStoreChange() }
        }
        defer { wiring.cancel() }
        let initialReads = reads.value
        signals.postInProcess(.mailbox)
        signals.postInProcess(.operations)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(reads.value, initialReads)
        XCTAssertEqual(monitor.accountRevision, 0)
    }

    @MainActor
    func testServiceAdapterExchangesInTheAppChecksIdentityAndSendsOnlyTheGrant() async throws {
        let client = RuntimeServiceClientFake()
        let tokens = GoogleOAuthTokenClient(
            client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")),
            http: SetupGoogleHTTP(email: "someone-else@gmail.com", refreshToken: "1//refresh"))
        let adapter = PlainpostServiceAccountSetupAdapter(serviceClient: client, googleOAuthTokens: tokens)
        let code = GmailAuthorizationCode(code: "c", verifier: String(repeating: "v", count: 43), redirectURI: "http://127.0.0.1:5000/oauth/mail/google")

        do {
            _ = try await adapter.addGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"), authorization: code, progress: { _ in })
            XCTFail("mismatched identity reached the service")
        } catch GoogleAccountSetupError.signedInAsDifferentAccount(let signedIn, let expected) {
            XCTAssertEqual(signedIn, "someone-else@gmail.com")
            XCTAssertEqual(expected, "ada@gmail.com")
        }
        let refused = await client.snapshot()
        XCTAssertEqual(refused.foregroundOperationKinds, [])

        let matching = PlainpostServiceAccountSetupAdapter(
            serviceClient: client,
            googleOAuthTokens: GoogleOAuthTokenClient(
                client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")),
                http: SetupGoogleHTTP(email: "ada@gmail.com", refreshToken: "1//refresh")))
        let result = try await matching.addGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"), authorization: code, progress: { _ in })
        XCTAssertEqual(result.account.imapHost, "imap.gmail.com")
        try await matching.reauthorizeGoogleAccount(accountID: result.account.id, email: EmailAddress("ada@gmail.com"), authorization: code)
        let sent = await client.snapshot()
        XCTAssertEqual(sent.foregroundOperationKinds, [.googleAccountAdd, .replaceGoogleAccountCredential])

        let withoutRefresh = PlainpostServiceAccountSetupAdapter(
            serviceClient: client,
            googleOAuthTokens: GoogleOAuthTokenClient(
                client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")),
                http: SetupGoogleHTTP(email: "ada@gmail.com", refreshToken: nil)))
        do {
            _ = try await withoutRefresh.addGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"), authorization: code, progress: { _ in })
            XCTFail("a grant without a refresh token was accepted")
        } catch GoogleOAuthError.invalidResponse {}
    }
}

private final class LateGoogleSetupHandler: AccountSetupHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var discardedIDs: [AccountID] = []
    private var persisted: [Account] = []
    private let cleanupFails: Bool
    private let discardFails: Bool
    init(cleanupFails: Bool = false, discardFails: Bool = false) {
        self.cleanupFails = cleanupFails
        self.discardFails = discardFails
    }
    var started: Bool { lock.withLock { began } }
    var discarded: [AccountID] { lock.withLock { discardedIDs } }
    var persistedAccounts: [Account] { lock.withLock { persisted } }

    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult { throw AccountSetupHandlingError.unsupported }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult { throw AccountSetupHandlingError.unsupported }

    func addGoogleAccount(
        displayName: String, email: EmailAddress, authorization: GmailAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        lock.withLock { began = true }
        // A poorly behaved provider callback returns after cancellation. The
        // UI must still remove its just-published account.
        do { try await Task.sleep(for: .seconds(30)) } catch { }
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: displayName, email: email)
        lock.withLock { persisted = [account] }
        if cleanupFails { throw GoogleAccountSetupError.cleanupFailed(accountID: account.id) }
        return AccountSetupResult(
            account: account,
            imapVerified: true, smtpVerified: true)
    }

    func discardAddedGoogleAccount(accountID: AccountID) async throws {
        lock.withLock { discardedIDs.append(accountID) }
        if discardFails { throw CredentialVaultError.locked }
    }
}

private final class RecordingGoogleSetupHandler: AccountSetupHandling, @unchecked Sendable {
    private let lock = NSLock()
    private let verifiedIdentity: String
    private let failure: Error?
    private var added: [String] = []
    private var codes: [String] = []
    private var reauthorized: [AccountID] = []
    var onReauthorize: (@Sendable () -> Void)?

    init(verifiedIdentity: String, failure: Error? = nil) {
        self.verifiedIdentity = verifiedIdentity
        self.failure = failure
    }

    var addedAccounts: [String] { lock.withLock { added } }
    var receivedCodes: [String] { lock.withLock { codes } }
    var reauthorizedAccounts: [AccountID] { lock.withLock { reauthorized } }

    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        XCTFail("guided Gmail must not submit an App Password request")
        throw AccountSetupHandlingError.unsupported
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        IMAPSyncResult(syncedMessageCount: 0)
    }

    func addGoogleAccount(
        displayName: String,
        email: EmailAddress,
        authorization: GmailAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        if let failure { throw failure }
        #if os(iOS)
        let resolvedEmail = email.rawValue.isEmpty ? EmailAddress(verifiedIdentity) : email
        let resolvedName = displayName.isEmpty ? "Ada" : displayName
        #else
        let resolvedEmail = email
        let resolvedName = displayName
        #endif
        guard verifiedIdentity == resolvedEmail.rawValue.lowercased() else {
            throw GoogleAccountSetupError.signedInAsDifferentAccount(signedIn: verifiedIdentity, expected: email.rawValue.lowercased())
        }
        lock.withLock {
            added.append(resolvedEmail.rawValue)
            codes.append(authorization.code)
        }
        await progress(.verifyingIMAP)
        return AccountSetupResult(
            account: MailProviderProfile.gmail.makeGoogleAccount(displayName: resolvedName, email: resolvedEmail),
            imapVerified: true, smtpVerified: true)
    }

    func reauthorizeGoogleAccount(accountID: AccountID, email: EmailAddress, authorization: GmailAuthorizationCode) async throws {
        if let failure { throw failure }
        lock.withLock { reauthorized.append(accountID) }
        onReauthorize?()
    }
}

@MainActor
private final class LoginHintRecorder {
    var values: [String] = []
}

private final class AuthenticationStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AccountAuthenticationSummary

    init(_ value: AccountAuthenticationSummary) { current = value }

    var value: AccountAuthenticationSummary {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Google token and profile endpoints for the app-side exchange. Token values
/// are fixtures; nothing is recorded.
private struct SetupGoogleHTTP: GoogleOAuthHTTP {
    let email: String
    let refreshToken: String?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let body: String
        if url.path == "/token" {
            let refresh = refreshToken.map { #","refresh_token":"\#($0)""# } ?? ""
            body = #"{"access_token":"ya29.fixture","expires_in":3599,"scope":"https://mail.google.com/","token_type":"Bearer"\#(refresh)}"#
        } else {
            body = #"{"emailAddress":"\#(email)","historyId":"1","messagesTotal":0,"threadsTotal":0}"#
        }
        return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)))
    }
}

/// The two notification centers `MailStoreChangeSignal.post` writes to. Private
/// instances keep a test's signals in-process: the real
/// `DistributedNotificationCenter` reaches every process on the Mac, including
/// a running Plainpost app and service.
@MainActor
private final class MailStoreChangeSignalCenters {
    let local = NotificationCenter()
    let distributed = NotificationCenter()

    func makeMonitor() -> MailStoreChangeMonitor {
        MailStoreChangeMonitor(notificationCenter: local, distributedNotificationCenter: distributed)
    }

    /// What `MailStoreChangeSignal.post` does in this process: both centers.
    func postInProcess(_ scope: MailStoreChangeScope) {
        postMailStoreChangeSignal(scope, on: local)
        postMailStoreChangeSignal(scope, on: distributed)
    }

    /// What another process's `post` delivers here: the distributed center only.
    func postFromAnotherProcess(_ scope: MailStoreChangeScope) {
        postMailStoreChangeSignal(scope, on: distributed)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
private func waitForMainActor(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Posts a `MailStoreChangeSignal` directly on `center`, unlike
/// `MailStoreChangeSignal.post`, which also broadcasts on
/// `DistributedNotificationCenter` and would reach every process on the Mac.
private func postMailStoreChangeSignal(_ scope: MailStoreChangeScope, on center: NotificationCenter) {
    center.post(
        name: MailStoreChangeSignal.notificationName,
        object: nil,
        userInfo: [MailStoreChangeSignal.scopeUserInfoKey: scope.rawValue]
    )
}
