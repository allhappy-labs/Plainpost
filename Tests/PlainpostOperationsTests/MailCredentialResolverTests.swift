import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

final class MailCredentialResolverTests: XCTestCase {
    func testPasswordAccountsResolvePasswordsFromTheExistingKeys() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function, method: .password)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [
            CredentialRecordKey(rawValue: "account:\(account.id.rawValue):imap-password"): Data("imap-secret".utf8),
            CredentialRecordKey(rawValue: "account:\(account.id.rawValue):smtp-password"): Data("smtp-secret".utf8),
        ])
        let http = ScriptedGoogleOAuthHTTP(responses: [])
        let resolver = MailCredentialResolver(
            store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(
                store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http)))

        let imap = try await resolver.imapAuthentication(for: account)
        let smtp = try await resolver.smtpAuthentication(for: account)

        XCTAssertEqual(imap, .password("imap-secret"))
        XCTAssertEqual(smtp, .password("smtp-secret"))
        XCTAssertEqual(MailCredentialKeys.imapPassword(account.id).rawValue, "account:acc_ada_gmail_com:imap-password")
        XCTAssertEqual(MailCredentialKeys.smtpPassword(account.id).rawValue, "account:acc_ada_gmail_com:smtp-password")
        XCTAssertEqual(MailCredentialKeys.googleRefreshToken(account.id).rawValue, "account:acc_ada_gmail_com:google-refresh-token")
        let count = await http.requestCount
        XCTAssertEqual(count, 0)
    }

    func testRowlessAccountIsAPasswordAccountAndMissingPasswordIsUnavailable() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function, method: .password)
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = MailCredentialResolver.withoutGoogleOAuth(store: store, credentials: InMemoryCredentialVault())

        await XCTAssertThrowsAsync(try await resolver.imapAuthentication(for: account)) {
            XCTAssertEqual($0 as? MailCredentialError, .unavailable)
        }
    }

    func testGoogleAccountResolvesXOAUTH2ForIMAPAndSMTPWithOneRefresh() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "access-1"))])
        let resolver = makeResolver(store: store, vault: vault, http: http)

        let imap = try await resolver.imapAuthentication(for: account)
        let smtp = try await resolver.smtpAuthentication(for: account)

        XCTAssertEqual(imap, .xoauth2(accessToken: "access-1"))
        XCTAssertEqual(smtp, .xoauth2(accessToken: "access-1"))
        let count = await http.requestCount
        XCTAssertEqual(count, 1)
    }

    func testGoogleOAuthTokenIsNotReleasedToEditedServer() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)
        ])
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "private-token"))])
        let resolver = makeResolver(store: store, vault: vault, http: http)
        let edited = Account(
            id: account.id, displayName: account.displayName, email: account.email,
            username: account.username, sentMailbox: account.sentMailbox,
            imapHost: "mail.example.test", imapPort: account.imapPort,
            smtpHost: "smtp.example.test", smtpPort: account.smtpPort)
        try store.cacheAccounts([edited])

        await XCTAssertThrowsAsync(try await resolver.imapAuthentication(for: edited)) {
            XCTAssertNotNil($0 as? PlainpostError)
        }
        await XCTAssertThrowsAsync(try await resolver.smtpAuthentication(for: edited)) {
            XCTAssertNotNil($0 as? PlainpostError)
        }
        let requestCount = await http.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testGoogleAccountWithoutRefreshTokenIsUnavailable() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = makeResolver(store: store, vault: InMemoryCredentialVault(), http: ScriptedGoogleOAuthHTTP(responses: []))

        await XCTAssertThrowsAsync(try await resolver.smtpAuthentication(for: account)) {
            XCTAssertEqual($0 as? MailCredentialError, .unavailable)
        }
    }

    func testRejectedTokenRefreshesOnceThenMarksReauthorization() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [
            (200, tokenResponse(access: "access-1")),
            (200, tokenResponse(access: "access-2")),
        ])
        let resolver = makeResolver(store: store, vault: vault, http: http)
        let attempts = AuthenticationRecorder()

        await XCTAssertThrowsAsync(
            try await resolver.withIMAPAuthentication(for: account) { authentication -> Int in
                await attempts.record(authentication)
                throw MailAuthenticationError.rejected
            }
        ) {
            XCTAssertEqual($0 as? MailCredentialError, .reauthorizationRequired)
        }

        let recorded = await attempts.values
        XCTAssertEqual(recorded, [.xoauth2(accessToken: "access-1"), .xoauth2(accessToken: "access-2")])
        let count = await http.requestCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .reauthorizationRequired)
        await XCTAssertThrowsAsync(try await resolver.imapAuthentication(for: account)) {
            XCTAssertEqual($0 as? MailCredentialError, .reauthorizationRequired)
        }
    }

    func testRejectedTokenRecoversWithRefreshedToken() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [
            (200, tokenResponse(access: "stale")),
            (200, tokenResponse(access: "fresh")),
        ])
        let resolver = makeResolver(store: store, vault: vault, http: http)

        let value = try await resolver.withIMAPAuthentication(for: account) { authentication -> String in
            guard authentication == .xoauth2(accessToken: "fresh") else { throw MailAuthenticationError.rejected }
            return "synced"
        }

        XCTAssertEqual(value, "synced")
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
    }

    func testRefusalOfARefreshedTokenDoesNotMarkReauthorizationWhenANewGrantWasInstalledMeanwhile() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [
            (200, tokenResponse(access: "access-1")),
            (200, tokenResponse(access: "access-2")),
        ])
        let (resolver, _) = makeResolverAndProvider(store: store, vault: vault, http: http)
        let attempts = AuthenticationRecorder()

        await XCTAssertThrowsAsync(
            try await resolver.withIMAPAuthentication(for: account) { authentication -> Int in
                await attempts.record(authentication)
                if await attempts.values.count == 2 {
                    // The user reauthorizes while the refreshed token is being refused.
                    try await resolver.installGoogleGrant(
                        accessToken: "access-reauthorized", expiresAt: Date().addingTimeInterval(3600), for: account.id
                    ) {
                        try await vault.store(Data("1//reauthorized".utf8), for: key)
                    }
                }
                throw MailAuthenticationError.rejected
            }
        ) {
            XCTAssertEqual($0 as? MailAuthenticationError, .rejected)
        }

        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
        let next = try await resolver.imapAuthentication(for: account)
        XCTAssertEqual(next, .xoauth2(accessToken: "access-reauthorized"))
    }

    func testRejectionOfAnOldTokenKeepsATokenInstalledMeanwhile() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "access-1"))])
        let (resolver, _) = makeResolverAndProvider(store: store, vault: vault, http: http)
        let attempts = AuthenticationRecorder()

        let value = try await resolver.withIMAPAuthentication(for: account) { authentication -> String in
            await attempts.record(authentication)
            guard authentication == .xoauth2(accessToken: "access-installed") else {
                try await resolver.installGoogleGrant(
                    accessToken: "access-installed", expiresAt: Date().addingTimeInterval(3600), for: account.id
                ) {
                    try await vault.store(Data("1//installed".utf8), for: key)
                }
                throw MailAuthenticationError.rejected
            }
            return "synced"
        }

        XCTAssertEqual(value, "synced")
        let recorded = await attempts.values
        XCTAssertEqual(recorded, [.xoauth2(accessToken: "access-1"), .xoauth2(accessToken: "access-installed")])
        let count = await http.requestCount
        XCTAssertEqual(count, 1, "invalidating the rejected token must not drop the installed one")
    }

    func testSMTPRejectedTokenIsRefreshedAndRetriedOnceInPlace() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [
            (200, tokenResponse(access: "stale")),
            (200, tokenResponse(access: "fresh")),
        ])
        let (resolver, _) = makeResolverAndProvider(store: store, vault: vault, http: http)
        let server = ScriptedSMTPServer(acceptedToken: "fresh")
        let client = resolver.tokenRefreshingSMTPClient(for: account) { ScriptedSMTPClient(server: server) }

        let first = try await resolver.smtpAuthentication(for: account)
        try await client.send(
            username: account.username, authentication: first, from: account.email,
            to: [EmailAddress("bob@example.com")], data: "Subject: t\r\n\r\nbody")

        let attempts = await server.attempts
        XCTAssertEqual(attempts, [.xoauth2(accessToken: "stale"), .xoauth2(accessToken: "fresh")])
        let delivered = await server.deliveredCount
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
    }

    func testSMTPRefreshedTokenRefusedAgainMarksReauthorizationWithoutAThirdAttempt() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [
            (200, tokenResponse(access: "stale")),
            (200, tokenResponse(access: "also-refused")),
        ])
        let (resolver, _) = makeResolverAndProvider(store: store, vault: vault, http: http)
        let server = ScriptedSMTPServer(acceptedToken: "never")
        let client = resolver.tokenRefreshingSMTPClient(for: account) { ScriptedSMTPClient(server: server) }

        let first = try await resolver.smtpAuthentication(for: account)
        await XCTAssertThrowsAsync(
            try await client.send(
                username: account.username, authentication: first, from: account.email,
                to: [EmailAddress("bob@example.com")], data: "Subject: t\r\n\r\nbody")
        ) {
            XCTAssertEqual($0 as? MailCredentialError, .reauthorizationRequired)
        }
        let attempts = await server.attempts
        XCTAssertEqual(attempts.count, 2)
        let delivered = await server.deliveredCount
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .reauthorizationRequired)
    }

    func testSMTPFailuresOtherThanATokenRefusalAreNeverRetried() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8),
            MailCredentialKeys.smtpPassword(account.id): Data("pw".utf8),
        ])
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "access-1"))])
        let (resolver, _) = makeResolverAndProvider(store: store, vault: vault, http: http)
        let afterMailFrom: [any Error] = [
            SMTPClientError.deliveryUncertain,
            SMTPClientError.recipientRejected(EmailAddress("bob@example.com"), code: 550, message: "no"),
            SMTPClientError.unexpectedResponse("554 5.7.0 refused"),
            MailAuthenticationError.temporarilyRefused,
            SMTPClientError.authenticationFailed,
        ]
        let first = try await resolver.smtpAuthentication(for: account)
        for failure in afterMailFrom {
            let server = ScriptedSMTPServer(acceptedToken: "access-1", failure: failure)
            let client = resolver.tokenRefreshingSMTPClient(for: account) { ScriptedSMTPClient(server: server) }
            await XCTAssertThrowsAsync(
                try await client.send(
                    username: account.username, authentication: first, from: account.email,
                    to: [EmailAddress("bob@example.com")], data: "Subject: t\r\n\r\nbody")
            ) { _ in }
            let attempts = await server.attempts
            XCTAssertEqual(attempts.count, 1, "\(failure)")
        }

        try store.setAccountAuthentication(accountID: account.id, method: .password, state: .ready)
        let password = try await resolver.smtpAuthentication(for: account)
        let server = ScriptedSMTPServer(acceptedToken: "unused")
        let client = resolver.tokenRefreshingSMTPClient(for: account) { ScriptedSMTPClient(server: server) }
        await XCTAssertThrowsAsync(
            try await client.send(
                username: account.username, authentication: password, from: account.email,
                to: [EmailAddress("bob@example.com")], data: "Subject: t\r\n\r\nbody")
        ) {
            XCTAssertEqual($0 as? MailAuthenticationError, .rejected)
        }
        let passwordAttempts = await server.attempts
        XCTAssertEqual(passwordAttempts, [.password("pw")], "passwords are never retried")
        let count = await http.requestCount
        XCTAssertEqual(count, 1)
    }

    func testPasswordRejectionIsNeverRetried() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function, method: .password)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.imapPassword(account.id): Data("pw".utf8)])
        let resolver = makeResolver(store: store, vault: vault, http: ScriptedGoogleOAuthHTTP(responses: []))
        let attempts = AuthenticationRecorder()

        await XCTAssertThrowsAsync(
            try await resolver.withIMAPAuthentication(for: account) { authentication -> Int in
                await attempts.record(authentication)
                throw MailAuthenticationError.rejected
            }
        ) {
            XCTAssertEqual($0 as? MailAuthenticationError, .rejected)
        }
        let recorded = await attempts.values
        XCTAssertEqual(recorded, [.password("pw")])
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .password)
    }

    func testLockedVaultPassesThroughForPasswordAndGoogleAccounts() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function, method: .password)
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = MailCredentialResolver(
            store: store, credentials: LockedCredentialVault(),
            googleTokens: GoogleAccessTokenProvider(
                store: store, credentials: LockedCredentialVault(),
                tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: ScriptedGoogleOAuthHTTP(responses: []))))

        await XCTAssertThrowsAsync(try await resolver.imapAuthentication(for: account)) {
            XCTAssertEqual($0 as? CredentialVaultError, .locked)
        }
        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        await XCTAssertThrowsAsync(try await resolver.smtpAuthentication(for: account)) {
            XCTAssertEqual($0 as? CredentialVaultError, .locked)
        }
    }

    func testResolverWithoutGoogleClientFailsOnlyGoogleAccounts() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8),
            MailCredentialKeys.imapPassword(account.id): Data("pw".utf8),
        ])
        let resolver = MailCredentialResolver.withoutGoogleOAuth(store: store, credentials: vault)

        await XCTAssertThrowsAsync(try await resolver.imapAuthentication(for: account)) {
            XCTAssertEqual($0 as? MailCredentialError, .oauthNotConfigured)
        }
        try store.setAccountAuthentication(accountID: account.id, method: .password, state: .ready)
        let password = try await resolver.imapAuthentication(for: account)
        XCTAssertEqual(password, .password("pw"))
    }

    func testDirectCredentialKeysAreReadOnlyThroughTheResolver() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let allowed: Set<String> = [
            "PlainpostAccounts/GoogleAccessTokenProvider.swift", // MailCredentialKeys
            "PlainpostDB/SQLiteMailStore.swift",                 // deletion intent (PlainpostDB cannot see MailCredentialKeys)
            "PlainpostSecrets/CredentialCapabilityCodec.swift",  // test capability allowlist
        ]
        var offenders: [String] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains(":imap-password") || text.contains(":smtp-password")
                    || text.contains(":google-refresh-token") || text.contains(":microsoft-refresh-token") else { continue }
            let relative = file.path.replacingOccurrences(of: sources.path + "/", with: "")
            if !allowed.contains(relative) { offenders.append(relative) }
        }
        XCTAssertEqual(offenders, [])
    }

    private func makeResolverAndProvider(
        store: SQLiteMailStore, vault: any CredentialVault, http: ScriptedGoogleOAuthHTTP
    ) -> (MailCredentialResolver, GoogleAccessTokenProvider) {
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))
        return (MailCredentialResolver(store: store, credentials: vault, googleTokens: provider), provider)
    }

    private func makeResolver(store: SQLiteMailStore, vault: any CredentialVault, http: ScriptedGoogleOAuthHTTP) -> MailCredentialResolver {
        MailCredentialResolver(
            store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(
                store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http)))
    }
}

private actor AuthenticationRecorder {
    private(set) var values: [MailAuthentication] = []
    func record(_ value: MailAuthentication) { values.append(value) }
}

/// Records every SMTP authentication attempt. A token other than
/// `acceptedToken` is refused the way SMTP refuses it: before `MAIL FROM`.
private actor ScriptedSMTPServer {
    private let acceptedToken: String
    private let failure: (any Error)?
    private(set) var attempts: [MailAuthentication] = []
    private(set) var deliveredCount = 0

    init(acceptedToken: String, failure: (any Error)? = nil) {
        self.acceptedToken = acceptedToken
        self.failure = failure
    }

    func submit(_ authentication: MailAuthentication) throws {
        attempts.append(authentication)
        guard authentication == .xoauth2(accessToken: acceptedToken) else {
            throw MailAuthenticationError.rejected
        }
        if let failure { throw failure }
        deliveredCount += 1
    }
}

private struct ScriptedSMTPClient: SMTPClientProtocol {
    let server: ScriptedSMTPServer

    func send(username: String, password: String, from: EmailAddress, to recipients: [EmailAddress], data: String) async throws {
        try await server.submit(.password(password))
    }

    func send(
        username: String, authentication: MailAuthentication, from: EmailAddress, to recipients: [EmailAddress], data: String
    ) async throws {
        try await server.submit(authentication)
    }
}
