import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets
import XCTest

/// Whether the phone holds an account's own provider sign-in, so a Sync Node account may
/// sync directly while its Node is away.
final class MailProviderSignInTests: XCTestCase {
    private func makeStore(imapHost: String = "imap.gmail.com") throws -> (SQLiteMailStore, AccountID) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sign-in-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("acc_user"), displayName: "User", email: EmailAddress("user@gmail.com"),
                              imapHost: imapHost, smtpHost: imapHost.isEmpty ? "" : "smtp.gmail.com")
        try store.cacheAccounts([account])
        return (store, account.id)
    }

    func testANodeCatalogAccountHasNoSignInUntilOneIsStored() async throws {
        let (store, id) = try makeStore()
        let vault = InMemoryCredentialVault()
        let none = await MailProviderSignIn.isStored(accountID: id, store: store, credentials: vault)
        XCTAssertFalse(none)
        try store.setAccountAuthentication(accountID: id, method: .googleOAuth, state: .ready)
        try await vault.store(Data("refresh".utf8), for: MailCredentialKeys.googleRefreshToken(id))
        let google = await MailProviderSignIn.isStored(accountID: id, store: store, credentials: vault)
        XCTAssertTrue(google)
        try store.setAccountAuthentication(accountID: id, method: .googleOAuth, state: .reauthorizationRequired)
        let expired = await MailProviderSignIn.isStored(accountID: id, store: store, credentials: vault)
        XCTAssertFalse(expired, "a grant that needs renewing can't sync")
    }

    func testPasswordsNeedBothAndAKnownServer() async throws {
        let (store, id) = try makeStore()
        let vault = InMemoryCredentialVault()
        try await vault.store(Data("imap".utf8), for: MailCredentialKeys.imapPassword(id))
        let half = await MailProviderSignIn.isStored(accountID: id, store: store, credentials: vault)
        XCTAssertFalse(half)
        try await vault.store(Data("smtp".utf8), for: MailCredentialKeys.smtpPassword(id))
        let both = await MailProviderSignIn.isStored(accountID: id, store: store, credentials: vault)
        XCTAssertTrue(both)

        let (serverless, other) = try makeStore(imapHost: "")
        try await vault.store(Data("imap".utf8), for: MailCredentialKeys.imapPassword(other))
        try await vault.store(Data("smtp".utf8), for: MailCredentialKeys.smtpPassword(other))
        let noServer = await MailProviderSignIn.isStored(accountID: other, store: serverless, credentials: vault)
        XCTAssertFalse(noServer, "a catalog account with no server can't sync from here")
    }
}
