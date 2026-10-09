import Foundation
import XCTest
@testable import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

final class MicrosoftAccountSetupIntegrationTests: XCTestCase {
    private let address = EmailAddress("ada@example.test")
    private let clientID = "00000000-1111-4222-8333-444444444444"
    private let redirectURI = "com.plainpost.mail:/oauth/microsoft"

    func testGraphIdentityAndExchangeProtocolAcceptancePublishDirectAccount() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: address.rawValue, acceptedToken: "exchange-access")
        defer { fixture.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault()
        let http = MicrosoftSetupHTTP(email: address.rawValue)
        let provider = try makeProvider(http: http)
        let resolver = makeResolver(store: store, vault: vault, provider: provider)
        let service = AccountSetupService(
            store: store, credentials: vault,
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            microsoftOAuth: provider, credentialResolver: resolver, publishDirectMailSource: true)

        let result = try await service.addMicrosoftAccount(
            displayName: "Ada", email: address, authorization: code(), progress: { _ in })

        XCTAssertEqual(result.account.imapHost, "outlook.office365.com")
        XCTAssertEqual(result.account.smtpHost, "smtp.office365.com")
        XCTAssertEqual(try store.accountAuthentication(accountID: result.account.id).method, .microsoftOAuth)
        XCTAssertEqual(try store.accountAuthentication(accountID: result.account.id).state, .ready)
        let microsoftRefresh = try await vault.load(MailCredentialKeys.microsoftRefreshToken(result.account.id))
        let googleRefresh = try await vault.load(MailCredentialKeys.googleRefreshToken(result.account.id))
        let password = try await vault.load(MailCredentialKeys.imapPassword(result.account.id))
        XCTAssertEqual(microsoftRefresh, Data("graph-refresh".utf8))
        XCTAssertNil(googleRefresh)
        XCTAssertNil(password)
        XCTAssertGreaterThanOrEqual(fixture.acceptedAuthenticationCount, 3)
        let forms = await http.requestScopes
        XCTAssertEqual(forms, [MicrosoftMailOAuthProvider.exchangeScope, MicrosoftMailOAuthProvider.graphScope])
        XCTAssertFalse(fixture.transcript.contains("exchange-access"))
    }

    func testIdentityMismatchLeavesNoAccountOrCredential() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault()
        let provider = try makeProvider(http: MicrosoftSetupHTTP(email: "other@example.test"))
        let service = AccountSetupService(store: store, credentials: vault,
            microsoftOAuth: provider, credentialResolver: makeResolver(store: store, vault: vault, provider: provider),
            publishDirectMailSource: true)

        await XCTAssertThrowsAsync(try await service.addMicrosoftAccount(
            displayName: "Ada", email: address, authorization: code(), progress: { _ in })) {
            XCTAssertEqual($0 as? MicrosoftOAuthError, .identityMismatch)
        }
        XCTAssertTrue(store.accounts.isEmpty)
        let stored = try await vault.load(MailCredentialKeys.microsoftRefreshToken(accountID))
        XCTAssertNil(stored)
    }

    func testExchangeIMAPRefusalLeavesNoAccountOrCredential() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: address.rawValue, acceptedToken: "different-token")
        defer { fixture.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault()
        let provider = try makeProvider(http: MicrosoftSetupHTTP(email: address.rawValue))
        let service = AccountSetupService(store: store, credentials: vault,
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            microsoftOAuth: provider, credentialResolver: makeResolver(store: store, vault: vault, provider: provider),
            publishDirectMailSource: true)

        await XCTAssertThrowsAsync(try await service.addMicrosoftAccount(
            displayName: "Ada", email: address, authorization: code(), progress: { _ in })) {
            XCTAssertEqual($0 as? MicrosoftAccountSetupError, .incompatibleMailbox(service: "IMAP"))
        }
        XCTAssertTrue(store.accounts.isEmpty)
        let stored = try await vault.load(MailCredentialKeys.microsoftRefreshToken(accountID))
        XCTAssertNil(stored)
    }

    func testMicrosoftResolverRefreshesOnlyMicrosoftVaultRecordAndRotatesIt() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.microsoft.makeOAuthAccount(displayName: "Ada", email: address)
        try store.cacheAccounts([account])
        try store.setAccountAuthentication(accountID: account.id, method: .microsoftOAuth, state: .ready)
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.microsoftRefreshToken(account.id): Data("old-refresh".utf8),
            MailCredentialKeys.googleRefreshToken(account.id): Data("google-refresh".utf8)
        ])
        let http = MicrosoftSetupHTTP(email: address.rawValue)
        let resolver = makeResolver(store: store, vault: vault, provider: try makeProvider(http: http))

        let imap = try await resolver.imapAuthentication(for: account)
        let smtp = try await resolver.smtpAuthentication(for: account)

        XCTAssertEqual(imap, .xoauth2(accessToken: "exchange-access"))
        XCTAssertEqual(smtp, imap)
        let rotated = try await vault.load(MailCredentialKeys.microsoftRefreshToken(account.id))
        let google = try await vault.load(MailCredentialKeys.googleRefreshToken(account.id))
        XCTAssertEqual(rotated, Data("exchange-refresh".utf8))
        XCTAssertEqual(google, Data("google-refresh".utf8))
        let scopes = await http.requestScopes
        XCTAssertEqual(scopes, [MicrosoftMailOAuthProvider.exchangeScope])
    }

    func testMicrosoftBearerIsNotReleasedToEditedMailServer() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.microsoft.makeOAuthAccount(displayName: "Ada", email: address)
        try store.cacheAccounts([account])
        try store.setAccountAuthentication(accountID: account.id, method: .microsoftOAuth, state: .ready)
        let edited = Account(
            id: account.id, displayName: account.displayName, email: account.email,
            username: account.username, sentMailbox: account.sentMailbox,
            imapHost: "mail.example.test", imapPort: account.imapPort,
            smtpHost: "smtp.example.test", smtpPort: account.smtpPort)
        try store.cacheAccounts([edited])
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.microsoftRefreshToken(account.id): Data("refresh".utf8)
        ])
        let http = MicrosoftSetupHTTP(email: address.rawValue)
        let resolver = makeResolver(store: store, vault: vault, provider: try makeProvider(http: http))

        await XCTAssertThrowsAsync(try await resolver.imapAuthentication(for: edited)) {
            XCTAssertNotNil($0 as? PlainpostError)
        }
        await XCTAssertThrowsAsync(try await resolver.smtpAuthentication(for: edited)) {
            XCTAssertNotNil($0 as? PlainpostError)
        }
        let requestScopes = await http.requestScopes
        XCTAssertTrue(requestScopes.isEmpty)
    }

    func testRepeatedExchangeRejectionMarksMicrosoftGrantForReauthorization() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.microsoft.makeOAuthAccount(displayName: "Ada", email: address)
        try store.cacheAccounts([account])
        try store.setAccountAuthentication(accountID: account.id, method: .microsoftOAuth, state: .ready)
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.microsoftRefreshToken(account.id): Data("refresh".utf8)
        ])
        let resolver = makeResolver(store: store, vault: vault,
                                    provider: try makeProvider(http: MicrosoftSetupHTTP(email: address.rawValue)))

        await XCTAssertThrowsAsync(try await resolver.withIMAPAuthentication(for: account) { _ -> Int in
            throw MailAuthenticationError.rejected
        }) {
            XCTAssertEqual($0 as? MailCredentialError, .reauthorizationRequired)
        }
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .microsoftOAuth)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .reauthorizationRequired)
    }

    func testMicrosoftReauthorizationProvesMailProtocolsAndRestoresReadyState() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: address.rawValue, acceptedToken: "exchange-access")
        defer { fixture.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.microsoft.makeOAuthAccount(displayName: "Ada", email: address)
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(try AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        try store.setAccountAuthentication(accountID: account.id, method: .microsoftOAuth,
                                           state: .reauthorizationRequired)
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.microsoftRefreshToken(account.id): Data("old-refresh".utf8)
        ])
        let provider = try makeProvider(http: MicrosoftSetupHTTP(email: address.rawValue))
        let service = AccountSetupService(
            store: store, credentials: vault,
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            microsoftOAuth: provider, credentialResolver: makeResolver(store: store, vault: vault, provider: provider),
            publishDirectMailSource: true)

        try await service.replaceMicrosoftCredential(accountID: account.id, authorization: code())

        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
        let replacement = try await vault.load(MailCredentialKeys.microsoftRefreshToken(account.id))
        XCTAssertEqual(replacement, Data("graph-refresh".utf8))
        // Reauthorization proves IMAP and SMTP; it does not run an initial sync.
        XCTAssertGreaterThanOrEqual(fixture.acceptedAuthenticationCount, 2)
    }

    func testMicrosoftReauthorizationWrongIdentityKeepsOldGrant() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.microsoft.makeOAuthAccount(displayName: "Ada", email: address)
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(try AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        try store.setAccountAuthentication(accountID: account.id, method: .microsoftOAuth,
                                           state: .reauthorizationRequired)
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.microsoftRefreshToken(account.id): Data("old-refresh".utf8)
        ])
        let provider = try makeProvider(http: MicrosoftSetupHTTP(email: "other@example.test"))
        let service = AccountSetupService(
            store: store, credentials: vault,
            microsoftOAuth: provider, credentialResolver: makeResolver(store: store, vault: vault, provider: provider),
            publishDirectMailSource: true)

        await XCTAssertThrowsAsync(try await service.replaceMicrosoftCredential(
            accountID: account.id, authorization: code())) {
            XCTAssertEqual($0 as? MicrosoftOAuthError, .identityMismatch)
        }
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state,
                       .reauthorizationRequired)
        let retained = try await vault.load(MailCredentialKeys.microsoftRefreshToken(account.id))
        XCTAssertEqual(retained, Data("old-refresh".utf8))
    }

    func testFirstSyncFailureDeletesPublishedMicrosoftAccountAndRefreshToken() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: address.rawValue, acceptedToken: "exchange-access")
        defer { fixture.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault()
        let provider = try makeProvider(http: MicrosoftSetupHTTP(email: address.rawValue))
        let service = AccountSetupService(store: store, credentials: vault,
            inboxSyncOrchestrator: MicrosoftFailingFirstSync(),
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            microsoftOAuth: provider, credentialResolver: makeResolver(store: store, vault: vault, provider: provider),
            publishDirectMailSource: true)

        await XCTAssertThrowsAsync(try await service.addMicrosoftAccount(
            displayName: "Ada", email: address, authorization: code(), progress: { _ in }))
        XCTAssertTrue(store.accounts.isEmpty)
        let stored = try await vault.load(MailCredentialKeys.microsoftRefreshToken(accountID))
        XCTAssertNil(stored)
    }

    func testConcurrentSetupForSameAddressPreservesWinningRefreshToken() async throws {
        let address = self.address
        let firstAuthorization = code("auth-code-a")
        let secondAuthorization = code("auth-code-b")
        let fixture = try await XOAUTH2MailFixture.start(username: address.rawValue, acceptedToken: "exchange-access")
        defer { fixture.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = MicrosoftInstallRaceVault()
        let provider = try makeProvider(http: MicrosoftSetupHTTP(email: address.rawValue, uniqueRefresh: true))
        let tokenOwner = MicrosoftAccessTokenProvider(store: store, credentials: vault, tokens: provider)
        let resolver = MailCredentialResolver(
            store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(store: store, credentials: vault, tokens: nil),
            microsoftTokens: tokenOwner)
        let service = AccountSetupService(
            store: store, credentials: vault,
            inboxSyncOrchestrator: MicrosoftSuccessfulFirstSync(),
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            microsoftOAuth: provider, credentialResolver: resolver, publishDirectMailSource: true)
        let first = Task {
            try await service.addMicrosoftAccount(
                displayName: "Ada", email: address, authorization: firstAuthorization,
                progress: { _ in })
        }
        var firstStoreBlocked = false
        for _ in 0..<1_000 {
            if await vault.firstStoreBlocked { firstStoreBlocked = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(firstStoreBlocked, "The first setup must enter grant installation")
        let second = Task {
            try await service.addMicrosoftAccount(
                displayName: "Ada", email: address, authorization: secondAuthorization,
                progress: { _ in })
        }
        var secondQueued = false
        for _ in 0..<1_000 {
            if await tokenOwner.pendingGrantWrites(for: accountID) == 1 { secondQueued = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await vault.releaseFirstStore()
        XCTAssertTrue(secondQueued, "The second setup must queue behind the first grant")
        let firstOutcome = await first.result
        let secondOutcome = await second.result
        let outcomes = [firstOutcome, secondOutcome]
        XCTAssertEqual(outcomes.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(store.accounts.count, 1)
        let stored = try await vault.load(MailCredentialKeys.microsoftRefreshToken(accountID))
        let winningRefresh: String
        if case .success = firstOutcome {
            winningRefresh = "graph-refresh-a"
        } else {
            winningRefresh = "graph-refresh-b"
        }
        XCTAssertEqual(stored, Data(winningRefresh.utf8))
    }

    private var accountID: AccountID { MailProviderProfile.microsoft.makeOAuthAccount(displayName: "Ada", email: address).id }

    private func makeStore() throws -> (SQLiteMailStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("microsoft-setup-\(UUID()).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        return (store, url)
    }

    private func makeProvider(http: any MicrosoftOAuthHTTP) throws -> MicrosoftMailOAuthProvider {
        let client = try XCTUnwrap(MicrosoftOAuthPublicClient(
            clientID: clientID, redirectURI: redirectURI,
            registeredSchemes: ["com.plainpost.mail"], supportsPersonalAccounts: true))
        return MicrosoftMailOAuthProvider(client: client, http: http)
    }

    private func makeResolver(store: SQLiteMailStore, vault: InMemoryCredentialVault,
                              provider: MicrosoftMailOAuthProvider) -> MailCredentialResolver {
        MailCredentialResolver(store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(store: store, credentials: vault, tokens: nil),
            microsoftTokens: MicrosoftAccessTokenProvider(store: store, credentials: vault, tokens: provider))
    }

    private func code(_ value: String = "auth-code") -> MicrosoftAuthorizationCode {
        MicrosoftAuthorizationCode(code: value, verifier: String(repeating: "v", count: 43), redirectURI: redirectURI)
    }
}

private struct MicrosoftFailingFirstSync: AccountInboxSyncOrchestrating {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        throw PlainpostError.validationFailed("Fixture first sync failure")
    }
}

private struct MicrosoftSuccessfulFirstSync: AccountInboxSyncOrchestrating {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        IMAPSyncResult(syncedMessageCount: 0)
    }
}

private actor MicrosoftInstallRaceVault: CredentialVault {
    private let backing = InMemoryCredentialVault()
    private var firstStoreHold: CheckedContinuation<Void, Never>?
    private var hasHeldFirstStore = false
    private var releasedFirstStore = false
    private(set) var firstStoreBlocked = false

    func store(_ secret: Data, for key: CredentialRecordKey) async throws {
        if key.rawValue.hasSuffix(":microsoft-refresh-token") && !hasHeldFirstStore && !releasedFirstStore {
            hasHeldFirstStore = true
            firstStoreBlocked = true
            await withCheckedContinuation { firstStoreHold = $0 }
        }
        try await backing.store(secret, for: key)
    }

    func releaseFirstStore() {
        releasedFirstStore = true
        firstStoreHold?.resume()
        firstStoreHold = nil
    }

    func load(_ key: CredentialRecordKey) async throws -> Data? {
        try await backing.load(key)
    }

    func remove(_ key: CredentialRecordKey) async throws {
        try await backing.remove(key)
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey], create: @escaping @Sendable () throws -> [Data]
    ) async throws -> [Data?] {
        try await backing.loadOrCreate(keys, create: create)
    }
}

private actor MicrosoftSetupHTTP: MicrosoftOAuthHTTP {
    let email: String
    let uniqueRefresh: Bool
    private(set) var requestScopes: [String] = []
    init(email: String, uniqueRefresh: Bool = false) {
        self.email = email
        self.uniqueRefresh = uniqueRefresh
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if request.url?.host == "graph.microsoft.com" {
            body = #"{"mail":"\#(email)"}"#
        } else {
            var components = URLComponents()
            components.percentEncodedQuery = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
            let scope = components.queryItems?.first(where: { $0.name == "scope" })?.value ?? ""
            let source = components.queryItems?.first(where: { $0.name == "code" || $0.name == "refresh_token" })?.value ?? ""
            let suffix = uniqueRefresh ? (source.hasSuffix("-a") ? "-a" : "-b") : ""
            requestScopes.append(scope)
            if scope == MicrosoftMailOAuthProvider.exchangeScope {
                body = #"{"access_token":"exchange-access","refresh_token":"exchange-refresh\#(suffix)","expires_in":3600,"scope":"https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send","token_type":"Bearer"}"#
            } else {
                body = #"{"access_token":"graph-access","refresh_token":"graph-refresh\#(suffix)","expires_in":3600,"scope":"https://graph.microsoft.com/User.Read","token_type":"Bearer"}"#
            }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!)
    }
}
