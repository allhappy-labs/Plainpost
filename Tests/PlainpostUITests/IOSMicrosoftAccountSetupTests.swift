import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import XCTest
@testable import PlainpostAccounts
@testable import PlainpostUI

@MainActor
final class IOSMicrosoftAccountSetupTests: XCTestCase {
    func testMicrosoftSignInUsesEnteredIdentityAndPublishesAccount() async throws {
        let setup = MicrosoftSetupRecorder()
        let model = AccountSetupViewModel(
            setup: setup, selectedProvider: .microsoft,
            displayName: "Ada", email: " ada@outlook.com ",
            microsoftAuthorization: { hint in
                XCTAssertEqual(hint, "ada@outlook.com")
                return MicrosoftAuthorizationCode(
                    code: "fixture-code", verifier: String(repeating: "v", count: 43),
                    redirectURI: "com.plainpost.mail:/oauth/microsoft")
            })

        await model.signInWithMicrosoft()

        XCTAssertEqual(setup.addedEmails, ["ada@outlook.com"])
        XCTAssertEqual(model.account?.imapHost, "outlook.office365.com")
        XCTAssertEqual(model.status, .connected(accountID: AccountID.stableAccountID(email: EmailAddress("ada@outlook.com")).rawValue))
    }

    func testMicrosoftUnavailableAndCancellationDoNotPublish() async {
        let setup = MicrosoftSetupRecorder()
        let model = AccountSetupViewModel(setup: setup, selectedProvider: .microsoft,
                                          displayName: "Ada", email: "ada@outlook.com")
        XCTAssertFalse(model.isMicrosoftSignInAvailable)
        await model.signInWithMicrosoft()
        XCTAssertEqual(setup.addedEmails, [])
        XCTAssertEqual(model.status, .failed(message: AccountSetupViewModel.microsoftSignInUnavailableMessage))
    }

    func testMicrosoftReauthorizationUsesExistingAccountIdentity() async throws {
        let setup = MicrosoftSetupRecorder()
        let account = MailProviderProfile.microsoft.makeOAuthAccount(
            displayName: "Ada", email: EmailAddress("ada@outlook.com"))
        let model = AccountSetupViewModel(
            setup: setup, account: account, accounts: [account],
            microsoftAuthorization: { hint in
                XCTAssertEqual(hint, account.email.rawValue)
                return MicrosoftAuthorizationCode(code: "replacement", verifier: String(repeating: "v", count: 43),
                                                  redirectURI: "com.plainpost.mail:/oauth/microsoft")
            },
            accountAuthenticationProvider: { _ in
                AccountAuthenticationSummary(method: .microsoftOAuth, state: .reauthorizationRequired)
            })
        XCTAssertTrue(model.isSelectedAccountMicrosoftOAuth)
        model.imapPassword = "should-not-be-used"
        model.smtpPassword = "should-not-be-used"
        XCTAssertTrue(model.isCredentialSaveDisabled)
        XCTAssertTrue(model.credentialReplacementHelp.contains("Passwords aren't used"))

        await model.reauthorizeMicrosoft(accountID: account.id)

        XCTAssertEqual(setup.reauthorizedAccounts, [account.id])
        XCTAssertEqual(model.microsoftReauthorizationMessage, "Microsoft Mail is signed in again.")
    }

    func testCancelledMicrosoftCleanupFailureKeepsDurableAccountDiscoverable() async throws {
        let setup = LateMicrosoftSetupRecorder()
        let model = AccountSetupViewModel(
            setup: setup, selectedProvider: .microsoft, displayName: "Ada", email: "ada@outlook.com",
            accountsProvider: { setup.persistedAccounts },
            microsoftAuthorization: { _ in
                MicrosoftAuthorizationCode(code: "fixture", verifier: String(repeating: "v", count: 43),
                                           redirectURI: "com.plainpost.mail:/oauth/microsoft")
            })
        let signIn = Task { await model.signInWithMicrosoft() }
        for _ in 0..<200 where !setup.started { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(setup.started)
        model.showProviderChooser()
        await signIn.value

        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.accounts.map(\.email.rawValue), ["ada@outlook.com"])
        XCTAssertEqual(model.microsoftSetupRecoveryAccountID, setup.persistedAccounts.first?.id)
        model.openRecoveredMicrosoftAccount()
        XCTAssertEqual(model.account?.email.rawValue, "ada@outlook.com")
    }

    func testOAuthAccountSettingsOnlyPersistDisplayName() {
        for (account, method) in [
            (MailProviderProfile.microsoft.makeOAuthAccount(
                displayName: "Before", email: EmailAddress("ada@outlook.com")),
             AccountAuthenticationMethod.microsoftOAuth),
            (MailProviderProfile.gmail.makeOAuthAccount(
                displayName: "Before", email: EmailAddress("ada@gmail.com")),
             AccountAuthenticationMethod.googleOAuth),
        ] {
            let saved = SavedAccountBox()
            let model = AccountSetupViewModel(
                setup: MicrosoftSetupRecorder(), account: account, accounts: [account],
                accountSaver: { saved.account = $0 },
                accountAuthenticationProvider: { _ in
                    AccountAuthenticationSummary(method: method, state: .ready)
                })
            model.displayName = "After"
            model.email = "attacker@example.com"
            model.username = "attacker@example.com"
            model.imapHost = "attacker.example.com"
            model.smtpHost = "attacker.example.com"

            model.saveAccountSettings()

            XCTAssertEqual(saved.account?.displayName, "After")
            XCTAssertEqual(saved.account?.email, account.email)
            XCTAssertEqual(saved.account?.username, account.username)
            XCTAssertEqual(saved.account?.imapHost, account.imapHost)
            XCTAssertEqual(saved.account?.smtpHost, account.smtpHost)
        }
    }
}

private final class SavedAccountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Account?
    var account: Account? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LateMicrosoftSetupRecorder: AccountSetupHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var persisted: [Account] = []
    var started: Bool { lock.withLock { began } }
    var persistedAccounts: [Account] { lock.withLock { persisted } }

    func addAccount(_ request: AccountSetupRequest,
                    progress: @escaping @Sendable (AccountSetupProgress) async -> Void) async throws -> AccountSetupResult {
        throw AccountSetupHandlingError.unsupported
    }
    func syncInbox(for account: Account,
                   progress: @escaping @Sendable (IMAPSyncProgress) async -> Void) async throws -> IMAPSyncResult {
        throw AccountSetupHandlingError.unsupported
    }
    func addMicrosoftAccount(displayName: String, email: EmailAddress,
                             authorization: MicrosoftAuthorizationCode,
                             progress: @escaping @Sendable (AccountSetupProgress) async -> Void) async throws -> AccountSetupResult {
        lock.withLock { began = true }
        do { try await Task.sleep(for: .seconds(30)) } catch { }
        let account = MailProviderProfile.microsoft.makeOAuthAccount(displayName: displayName, email: email)
        lock.withLock { persisted = [account] }
        throw MicrosoftAccountSetupError.cleanupFailed(accountID: account.id)
    }
}

private final class MicrosoftSetupRecorder: AccountSetupHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var emails: [String] = []
    private var reauthorized: [AccountID] = []
    var addedEmails: [String] { lock.withLock { emails } }
    var reauthorizedAccounts: [AccountID] { lock.withLock { reauthorized } }

    func addAccount(_ request: AccountSetupRequest,
                    progress: @escaping @Sendable (AccountSetupProgress) async -> Void) async throws -> AccountSetupResult {
        throw AccountSetupHandlingError.unsupported
    }

    func syncInbox(for account: Account,
                   progress: @escaping @Sendable (IMAPSyncProgress) async -> Void) async throws -> IMAPSyncResult {
        IMAPSyncResult(syncedMessageCount: 0)
    }

    func addMicrosoftAccount(displayName: String, email: EmailAddress,
                             authorization: MicrosoftAuthorizationCode,
                             progress: @escaping @Sendable (AccountSetupProgress) async -> Void) async throws -> AccountSetupResult {
        lock.withLock { emails.append(email.rawValue) }
        await progress(.verifyingIMAP)
        return AccountSetupResult(
            account: MailProviderProfile.microsoft.makeOAuthAccount(displayName: displayName, email: email),
            imapVerified: true, smtpVerified: true)
    }

    func reauthorizeMicrosoftAccount(accountID: AccountID, email: EmailAddress,
                                     authorization: MicrosoftAuthorizationCode) async throws {
        lock.withLock { reauthorized.append(accountID) }
    }
}
