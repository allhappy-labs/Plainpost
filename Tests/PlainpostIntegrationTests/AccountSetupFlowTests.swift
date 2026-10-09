import XCTest
@testable import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostSecrets
import PlainpostTestSupport

final class AccountSetupFlowTests: XCTestCase {
    func testICloudProviderUsesFullAddressAndOneAppSpecificPassword() {
        let request = MailProviderProfile.icloud.makeRequest(
            displayName: "Personal",
            email: EmailAddress("person@icloud.com"),
            appPassword: "abcd efgh ijkl mnop"
        )

        XCTAssertEqual(request.imapHost, "imap.mail.me.com")
        XCTAssertEqual(request.imapPort, 993)
        XCTAssertEqual(request.smtpHost, "smtp.mail.me.com")
        XCTAssertEqual(request.smtpPort, 587)
        XCTAssertEqual(request.username, "person@icloud.com")
        XCTAssertEqual(request.imapPassword, "abcdefghijklmnop")
        XCTAssertEqual(request.smtpPassword, request.imapPassword)
        XCTAssertFalse(MailProviderProfile.icloud.storesSentMessagesAutomatically(for: Account(
            id: AccountID("acc_icloud"), displayName: "Personal",
            email: EmailAddress("person@icloud.com"),
            imapHost: request.imapHost, smtpHost: request.smtpHost
        )))
    }

    func testICloudDirectSetupPublishesReopenableAccountAndBothCredentialRecords() async throws {
        let fixture = try AccountSetupFixture(deleteFails: false, publishDirectMailSource: true)
        defer { fixture.cleanup() }
        let request = MailProviderProfile.icloud.makeRequest(
            displayName: "Personal", email: EmailAddress("person@icloud.com"),
            appPassword: "abcd efgh ijkl mnop"
        )

        let result = try await fixture.service.addAccount(request)
        let reopened = try SQLiteMailStore(path: fixture.dbURL.path)
        try reopened.migrate()
        XCTAssertEqual(reopened.accounts, [result.account])
        XCTAssertEqual(reopened.accounts.first?.username, "person@icloud.com")
        XCTAssertEqual(try reopened.explicitMailSource(accountID: result.account.id)?.kind, .direct)
        let imapKey = CredentialRecordKey(rawValue: "account:\(result.account.id.rawValue):imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:\(result.account.id.rawValue):smtp-password")
        let storedIMAP = try await fixture.credentials.load(imapKey)
        let storedSMTP = try await fixture.credentials.load(smtpKey)
        XCTAssertEqual(storedIMAP, Data("abcdefghijklmnop".utf8))
        XCTAssertEqual(storedSMTP, Data("abcdefghijklmnop".utf8))
    }

    func testICloudFailedSecondCredentialWriteLeavesNoPublishedAccountOrSecret() async throws {
        let credentials = FaultingCredentialVault(initial: [:], failingStoreCall: 2)
        let fixture = try AccountSetupFixture(
            deleteFails: false, credentials: credentials, publishDirectMailSource: true
        )
        defer { fixture.cleanup() }
        let request = MailProviderProfile.icloud.makeRequest(
            displayName: "Personal", email: EmailAddress("person@icloud.com"),
            appPassword: "abcd efgh ijkl mnop"
        )

        await XCTAssertThrowsErrorAsync { _ = try await fixture.service.addAccount(request) }

        let accountID = AccountID.stableAccountID(email: request.email)
        XCTAssertTrue(fixture.store.accounts.isEmpty)
        XCTAssertNil(try fixture.store.explicitMailSource(accountID: accountID))
        let storedIMAP = try await credentials.load(CredentialRecordKey(rawValue: "account:\(accountID.rawValue):imap-password"))
        let storedSMTP = try await credentials.load(CredentialRecordKey(rawValue: "account:\(accountID.rawValue):smtp-password"))
        XCTAssertNil(storedIMAP)
        XCTAssertNil(storedSMTP)
    }

    func testICloudCredentialReplacementRequiresSameAppSpecificPassword() async throws {
        let account = Account(
            id: AccountID("acc_icloud"), displayName: "Personal", email: EmailAddress("person@icloud.com"),
            imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com"
        )
        let fixture = try await CredentialReplacementFixture(account: account)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.replaceCredentials(
                accountID: account.id, imapPassword: "first", smtpPassword: "different"
            )
        }
        let previousIMAP = try await fixture.credentials.load(fixture.imapKey)
        let previousSMTP = try await fixture.credentials.load(fixture.smtpKey)
        XCTAssertEqual(previousIMAP, Data("old-imap".utf8))
        XCTAssertEqual(previousSMTP, Data("old-smtp".utf8))

        try await fixture.service.replaceCredentials(
            accountID: account.id, imapPassword: "abcd efgh", smtpPassword: "abcd\tefgh"
        )
        let storedIMAP = try await fixture.credentials.load(fixture.imapKey)
        let storedSMTP = try await fixture.credentials.load(fixture.smtpKey)
        XCTAssertEqual(storedIMAP, Data("abcdefgh".utf8))
        XCTAssertEqual(storedSMTP, Data("abcdefgh".utf8))
    }

    func testGmailProviderBuildsResolvedRequestFromOneAppPassword() {
        let request = MailProviderProfile.gmail.makeRequest(
            displayName: "Work",
            email: EmailAddress("person@company.example"),
            appPassword: "abcd efgh ijkl mnop"
        )

        XCTAssertEqual(request.displayName, "Work")
        XCTAssertEqual(request.email, EmailAddress("person@company.example"))
        XCTAssertEqual(request.imapHost, "imap.gmail.com")
        XCTAssertEqual(request.imapPort, 993)
        XCTAssertEqual(request.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(request.smtpPort, 587)
        XCTAssertEqual(request.username, "person@company.example")
        XCTAssertEqual(request.sentMailbox, "[Gmail]/Sent Mail")
        XCTAssertEqual(request.imapPassword, "abcdefghijklmnop")
        XCTAssertEqual(request.smtpPassword, "abcdefghijklmnop")
    }

    func testGmailProviderNormalizesAllWhitespaceInAppPassword() {
        XCTAssertEqual(
            MailProviderProfile.gmail.normalizedAppPassword("abcd\tefgh\nijkl mnop"),
            "abcdefghijklmnop"
        )
    }

    func testGmailProviderRecognizesServerManagedSentCopies() {
        let gmail = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "SMTP.GMAIL.COM"
        )
        let custom = Account(
            id: AccountID("acc_custom"),
            displayName: "Custom",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )

        XCTAssertTrue(MailProviderProfile.gmail.storesSentMessagesAutomatically(for: gmail))
        XCTAssertFalse(MailProviderProfile.gmail.storesSentMessagesAutomatically(for: custom))
    }

    func testAccountSetupRequestDefaultsMissingUsernameToEmail() {
        let request = AccountSetupRequest(
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            imapPort: 993,
            smtpHost: "smtp.example.com",
            smtpPort: 587,
            imapPassword: "imap-secret",
            smtpPassword: "smtp-secret"
        )

        XCTAssertEqual(request.username, "me@example.com")
    }

    func testAccountSetupRequestDefaultsMissingSentMailboxToSent() {
        let request = AccountSetupRequest(
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            imapPort: 993,
            smtpHost: "smtp.example.com",
            smtpPort: 587,
            imapPassword: "imap-secret",
            smtpPassword: "smtp-secret"
        )

        XCTAssertEqual(request.sentMailbox, "Sent")
    }

    func testAddsVerifiedAccountToSQLiteAndVaultWithoutPlaintextSecrets() async throws {
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
            .appendingPathComponent("plainpost-account-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let credentials = InMemoryCredentialVault()

        let store = try SQLiteMailStore(path: dbURL.path)
        let service = AccountSetupService(store: store, credentials: credentials)

        let result = try await service.addAccount(
            AccountSetupRequest(
                displayName: "Personal",
                email: EmailAddress("me@example.com"),
                imapHost: "127.0.0.1",
                imapPort: imap.port,
                smtpHost: "127.0.0.1",
                smtpPort: smtp.port,
                username: "me@example.com",
                imapPassword: "imap-secret",
                smtpPassword: "smtp-secret"
            )
        )

        XCTAssertEqual(result.account.id, AccountID("acc_me_example_com"))
        XCTAssertTrue(result.imapVerified)
        XCTAssertTrue(result.smtpVerified)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts, [result.account])
        XCTAssertEqual(reloaded.accounts[0].imapPort, imap.port)
        XCTAssertEqual(reloaded.accounts[0].smtpPort, smtp.port)
        XCTAssertEqual(reloaded.mailboxes.map(\.path), ["INBOX"])

        XCTAssertEqual(try reloaded.accountAuthentication(accountID: result.account.id).method, .password)
        XCTAssertEqual(try reloaded.accountAuthentication(accountID: result.account.id).state, .ready)

        let storedIMAP = try await credentials.load(
            CredentialRecordKey(rawValue: "account:acc_me_example_com:imap-password")
        )
        let storedSMTP = try await credentials.load(
            CredentialRecordKey(rawValue: "account:acc_me_example_com:smtp-password")
        )
        XCTAssertEqual(storedIMAP, Data("imap-secret".utf8))
        XCTAssertEqual(storedSMTP, Data("smtp-secret".utf8))

        let sqliteBytes = try Data(contentsOf: dbURL)
        let sqliteText = String(decoding: sqliteBytes, as: UTF8.self)
        XCTAssertFalse(sqliteText.contains("imap-secret"))
        XCTAssertFalse(sqliteText.contains("smtp-secret"))
    }

    func testAccountSetupDeletesMarkedVerificationDeliveryBeforeInitialSync() async throws {
        let fixture = try AccountSetupFixture(deleteFails: false)
        defer { fixture.cleanup() }

        let result = try await fixture.service.addAccount(fixture.request)

        XCTAssertTrue(result.smtpVerified)
        XCTAssertEqual(fixture.imap.deletedUIDs, [8])
        XCTAssertTrue(fixture.smtp.data?.contains("X-Plainpost-Account-Verification: v1") == true)
        XCTAssertEqual(fixture.syncer.reasons, [.accountSetup])
        XCTAssertEqual(fixture.syncer.deletedUIDSnapshots, [[8]])
    }

    func testAccountSetupContinuesSilentlyWhenVerificationDeleteFails() async throws {
        let fixture = try AccountSetupFixture(deleteFails: true)
        defer { fixture.cleanup() }

        let result = try await fixture.service.addAccount(fixture.request)

        XCTAssertEqual(result.account.email, EmailAddress("me@example.com"))
        XCTAssertTrue(result.smtpVerified)
        XCTAssertEqual(fixture.store.accounts.map(\.id), [result.account.id])
        XCTAssertEqual(fixture.syncer.reasons, [.accountSetup])
        XCTAssertEqual(fixture.syncer.deletedUIDSnapshots, [[]])
    }

    func testSecondVaultWriteFailureRestoresPreexistingCredentialsAndLeavesNoMetadata() async throws {
        let imapKey = CredentialRecordKey(
            rawValue: "account:acc_me_example_com:imap-password"
        )
        let smtpKey = CredentialRecordKey(
            rawValue: "account:acc_me_example_com:smtp-password"
        )
        let credentials = FaultingCredentialVault(
            initial: [
                imapKey: Data("old-imap".utf8),
                smtpKey: Data("old-smtp".utf8),
            ],
            failingStoreCall: 2
        )
        let fixture = try AccountSetupFixture(
            deleteFails: false,
            credentials: credentials
        )
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.addAccount(fixture.request)
        }

        let restoredIMAP = try await credentials.load(imapKey)
        let restoredSMTP = try await credentials.load(smtpKey)
        XCTAssertEqual(restoredIMAP, Data("old-imap".utf8))
        XCTAssertEqual(restoredSMTP, Data("old-smtp".utf8))
        XCTAssertTrue(fixture.store.accounts.isEmpty)
        XCTAssertTrue(fixture.store.mailboxes.isEmpty)
    }

    func testMetadataWriteFailureRemovesNewVaultRecordsAndRollsBackAccount() async throws {
        let credentials = InMemoryCredentialVault()
        let fixture = try AccountSetupFixture(
            deleteFails: false,
            credentials: credentials
        )
        defer { fixture.cleanup() }
        try fixture.store.migrate()
        try await fixture.store.databasePool.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER fail_account_setup
                    BEFORE INSERT ON accounts
                    BEGIN
                        SELECT RAISE(FAIL, 'injected account metadata failure');
                    END
                    """
            )
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.addAccount(fixture.request)
        }

        let imap = try await credentials.load(
            CredentialRecordKey(rawValue: "account:acc_me_example_com:imap-password")
        )
        let smtp = try await credentials.load(
            CredentialRecordKey(rawValue: "account:acc_me_example_com:smtp-password")
        )
        XCTAssertNil(imap)
        XCTAssertNil(smtp)
        XCTAssertTrue(fixture.store.accounts.isEmpty)
        XCTAssertTrue(fixture.store.mailboxes.isEmpty)
    }

    func testDirectSetupPublishesPasswordAuthenticationWithoutSeparateAuthWrite() async throws {
        let fixture = try AccountSetupFixture(deleteFails: false, publishDirectMailSource: true)
        defer { fixture.cleanup() }
        try fixture.store.migrate()
        try await fixture.store.databasePool.write { database in
            try database.execute(sql: """
                CREATE TRIGGER fail_auth_write
                BEFORE INSERT ON account_authentication
                BEGIN
                    SELECT RAISE(FAIL, 'injected authentication write failure');
                END
                """)
        }

        let result = try await fixture.service.addAccount(fixture.request)

        XCTAssertEqual(fixture.store.accounts.map(\.id), [result.account.id])
        XCTAssertEqual(fixture.store.mailboxes.map(\.path), ["INBOX"])
        XCTAssertEqual(try fixture.store.accountAuthentication(accountID: result.account.id).method, .password)
        XCTAssertEqual(try fixture.store.explicitMailSource(accountID: result.account.id)?.kind, .direct)
        XCTAssertEqual(fixture.syncer.reasons, [.accountSetup])
    }

    func testDirectSetupRefreshTokenRemovalFailureLeavesNoPublishedAccount() async throws {
        let accountID = AccountID("acc_me_example_com")
        let imapKey = CredentialRecordKey(rawValue: "account:acc_me_example_com:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc_me_example_com:smtp-password")
        let refreshKey = MailCredentialKeys.googleRefreshToken(accountID)
        let credentials = FaultingCredentialVault(
            initial: [
                imapKey: Data("old-imap".utf8),
                smtpKey: Data("old-smtp".utf8),
                refreshKey: Data("old-refresh".utf8),
            ],
            failingStoreCall: .max,
            failingRemoveKey: refreshKey
        )
        let fixture = try AccountSetupFixture(
            deleteFails: false, credentials: credentials, publishDirectMailSource: true
        )
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.addAccount(fixture.request)
        }

        XCTAssertTrue(fixture.store.accounts.isEmpty)
        XCTAssertTrue(fixture.store.mailboxes.isEmpty)
        XCTAssertNil(try fixture.store.explicitMailSource(accountID: accountID))
        let restoredIMAP = try await credentials.load(imapKey)
        let restoredSMTP = try await credentials.load(smtpKey)
        let restoredRefresh = try await credentials.load(refreshKey)
        XCTAssertEqual(restoredIMAP, Data("old-imap".utf8))
        XCTAssertEqual(restoredSMTP, Data("old-smtp".utf8))
        XCTAssertEqual(restoredRefresh, Data("old-refresh".utf8))
        XCTAssertTrue(fixture.syncer.reasons.isEmpty)
    }

    func testGmailProviderMatchesCanonicalEndpointsCaseInsensitively() {
        let gmail = Account(
            id: AccountID("acc_gmail"),
            displayName: "Gmail",
            email: EmailAddress("me@custom-domain.example"),
            imapHost: "IMAP.GMAIL.COM",
            smtpHost: "smtp.Gmail.com"
        )
        let customIMAP = Account(
            id: AccountID("acc_custom_imap"),
            displayName: "Custom IMAP",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.gmail.com"
        )
        let customSMTP = Account(
            id: AccountID("acc_custom_smtp"),
            displayName: "Custom SMTP",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.example.com"
        )

        XCTAssertTrue(MailProviderProfile.gmail.matches(gmail))
        XCTAssertFalse(MailProviderProfile.gmail.matches(customIMAP))
        XCTAssertFalse(MailProviderProfile.gmail.matches(customSMTP))
    }

    func testReplacementNormalizesMatchingGmailAppPasswordsBeforeStoring() async throws {
        let fixture = try await CredentialReplacementFixture(account: CredentialReplacementFixture.gmail)
        defer { fixture.cleanup() }

        try await fixture.service.replaceCredentials(
            accountID: fixture.account.id,
            imapPassword: "abcd efgh\nijkl mnop",
            smtpPassword: "abcd\tefgh ijkl mnop"
        )

        let storedIMAP = try await fixture.credentials.load(fixture.imapKey)
        let storedSMTP = try await fixture.credentials.load(fixture.smtpKey)
        XCTAssertEqual(storedIMAP, Data("abcdefghijklmnop".utf8))
        XCTAssertEqual(storedSMTP, Data("abcdefghijklmnop".utf8))
    }

    func testReplacementRejectsInvalidLengthGmailPasswordsWithoutMutatingCredentials() async throws {
        for replacement in ["abcdefghijklmno", "abcdefghijklmnopq"] {
            let imapKey = CredentialRecordKey(rawValue: "account:acc_gmail:imap-password")
            let smtpKey = CredentialRecordKey(rawValue: "account:acc_gmail:smtp-password")
            let credentials = FaultingCredentialVault(
                initial: [
                    imapKey: Data("old-imap".utf8),
                    smtpKey: Data("old-smtp".utf8),
                ],
                failingStoreCall: .max
            )
            let fixture = try await CredentialReplacementFixture(
                account: CredentialReplacementFixture.gmail,
                credentials: credentials,
                seedMissingCredentials: false
            )
            defer { fixture.cleanup() }

            await XCTAssertThrowsErrorAsync {
                try await fixture.service.replaceCredentials(
                    accountID: fixture.account.id,
                    imapPassword: replacement,
                    smtpPassword: replacement
                )
            }

            let operations = await credentials.recordedOperations()
            XCTAssertTrue(
                operations.isEmpty,
                "Invalid Gmail credentials must be rejected before vault access."
            )
            let storedIMAP = try await credentials.load(imapKey)
            let storedSMTP = try await credentials.load(smtpKey)
            XCTAssertEqual(storedIMAP, Data("old-imap".utf8))
            XCTAssertEqual(storedSMTP, Data("old-smtp".utf8))
        }
    }

    func testReplacementRejectsDifferingNormalizedGmailPasswordsWithoutMutatingCredentials() async throws {
        let imapKey = CredentialRecordKey(rawValue: "account:acc_gmail:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc_gmail:smtp-password")
        let credentials = FaultingCredentialVault(
            initial: [
                imapKey: Data("old-imap".utf8),
                smtpKey: Data("old-smtp".utf8),
            ],
            failingStoreCall: .max
        )
        let fixture = try await CredentialReplacementFixture(
            account: CredentialReplacementFixture.gmail,
            credentials: credentials,
            seedMissingCredentials: false
        )
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.replaceCredentials(
                accountID: fixture.account.id,
                imapPassword: "abcd efgh ijkl mnop",
                smtpPassword: "abcd efgh ijkl mnox"
            )
        }

        let operations = await credentials.recordedOperations()
        XCTAssertTrue(
            operations.isEmpty,
            "Differing Gmail credentials must be rejected before vault access."
        )
        let storedIMAP = try await credentials.load(imapKey)
        let storedSMTP = try await credentials.load(smtpKey)
        XCTAssertEqual(storedIMAP, Data("old-imap".utf8))
        XCTAssertEqual(storedSMTP, Data("old-smtp".utf8))
    }

    func testReplacementRestoresBothGmailCredentialsWhenSecondVaultWriteFails() async throws {
        let imapKey = CredentialRecordKey(rawValue: "account:acc_gmail:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc_gmail:smtp-password")
        let credentials = FaultingCredentialVault(
            initial: [
                imapKey: Data("old-imap".utf8),
                smtpKey: Data("old-smtp".utf8),
            ],
            failingStoreCall: 2
        )
        let fixture = try await CredentialReplacementFixture(
            account: CredentialReplacementFixture.gmail,
            credentials: credentials
        )
        defer { fixture.cleanup() }
        await credentials.resetRecordedOperations()

        await XCTAssertThrowsInjectedSecondStoreErrorAsync {
            try await fixture.service.replaceCredentials(
                accountID: fixture.account.id,
                imapPassword: "abcd efgh ijkl mnop",
                smtpPassword: "abcd efgh ijkl mnop"
            )
        }

        let operations = await credentials.recordedOperations()
        XCTAssertEqual(
            operations,
            [
                .load(imapKey),
                .load(smtpKey),
                .store(imapKey),
                .store(smtpKey),
                .store(imapKey),
                .store(smtpKey),
            ]
        )
        let restoredIMAP = try await credentials.load(imapKey)
        let restoredSMTP = try await credentials.load(smtpKey)
        XCTAssertEqual(restoredIMAP, Data("old-imap".utf8))
        XCTAssertEqual(restoredSMTP, Data("old-smtp".utf8))
    }

    func testReplacementRemovesNewIMAPCredentialWhenSecondWriteFailsWithNoPriorRecords() async throws {
        let imapKey = CredentialRecordKey(rawValue: "account:acc_gmail:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc_gmail:smtp-password")
        let credentials = FaultingCredentialVault(initial: [:], failingStoreCall: 2)
        let fixture = try await CredentialReplacementFixture(
            account: CredentialReplacementFixture.gmail,
            credentials: credentials,
            seedMissingCredentials: false
        )
        defer { fixture.cleanup() }
        await credentials.resetRecordedOperations()

        await XCTAssertThrowsInjectedSecondStoreErrorAsync {
            try await fixture.service.replaceCredentials(
                accountID: fixture.account.id,
                imapPassword: "abcd efgh ijkl mnop",
                smtpPassword: "abcd efgh ijkl mnop"
            )
        }

        let operations = await credentials.recordedOperations()
        XCTAssertEqual(
            operations,
            [
                .load(imapKey),
                .load(smtpKey),
                .store(imapKey),
                .store(smtpKey),
                .remove(imapKey),
                .remove(smtpKey),
            ]
        )
        let restoredIMAP = try await credentials.load(imapKey)
        let restoredSMTP = try await credentials.load(smtpKey)
        XCTAssertNil(restoredIMAP)
        XCTAssertNil(restoredSMTP)
    }

    func testReplacementRemovesNewIMAPAndRestoresSMTPWhenSecondWriteFails() async throws {
        let imapKey = CredentialRecordKey(rawValue: "account:acc_gmail:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc_gmail:smtp-password")
        let credentials = FaultingCredentialVault(
            initial: [smtpKey: Data("old-smtp".utf8)],
            failingStoreCall: 2
        )
        let fixture = try await CredentialReplacementFixture(
            account: CredentialReplacementFixture.gmail,
            credentials: credentials,
            seedMissingCredentials: false
        )
        defer { fixture.cleanup() }
        await credentials.resetRecordedOperations()

        await XCTAssertThrowsInjectedSecondStoreErrorAsync {
            try await fixture.service.replaceCredentials(
                accountID: fixture.account.id,
                imapPassword: "abcd efgh ijkl mnop",
                smtpPassword: "abcd efgh ijkl mnop"
            )
        }

        let operations = await credentials.recordedOperations()
        XCTAssertEqual(
            operations,
            [
                .load(imapKey),
                .load(smtpKey),
                .store(imapKey),
                .store(smtpKey),
                .remove(imapKey),
                .store(smtpKey),
            ]
        )
        let restoredIMAP = try await credentials.load(imapKey)
        let restoredSMTP = try await credentials.load(smtpKey)
        XCTAssertNil(restoredIMAP)
        XCTAssertEqual(restoredSMTP, Data("old-smtp".utf8))
    }

    func testReplacementPreservesNonGmailWhitespaceExactly() async throws {
        let fixture = try await CredentialReplacementFixture(account: CredentialReplacementFixture.custom)
        defer { fixture.cleanup() }

        try await fixture.service.replaceCredentials(
            accountID: fixture.account.id,
            imapPassword: "imap secret\nwith tab\t",
            smtpPassword: "smtp secret with spaces"
        )

        let storedIMAP = try await fixture.credentials.load(fixture.imapKey)
        let storedSMTP = try await fixture.credentials.load(fixture.smtpKey)
        XCTAssertEqual(storedIMAP, Data("imap secret\nwith tab\t".utf8))
        XCTAssertEqual(storedSMTP, Data("smtp secret with spaces".utf8))
    }

    func testPasswordReplacementRefusesGoogleOAuthAccountsWithoutMutatingCredentials() async throws {
        let fixture = try await CredentialReplacementFixture(account: CredentialReplacementFixture.custom)
        defer { fixture.cleanup() }
        try fixture.store.setAccountAuthentication(accountID: fixture.account.id, method: .googleOAuth, state: .ready)
        let beforeIMAP = try await fixture.credentials.load(fixture.imapKey)

        do {
            try await fixture.service.replaceCredentials(
                accountID: fixture.account.id, imapPassword: "new-imap", smtpPassword: "new-smtp")
            XCTFail("a Google OAuth account accepted a password replacement")
        } catch PlainpostError.validationFailed(let message) {
            XCTAssertEqual(message, "This account signs in with Google. Use Sign in again instead of a password.")
        }

        let afterIMAP = try await fixture.credentials.load(fixture.imapKey)
        XCTAssertEqual(afterIMAP, beforeIMAP)
        XCTAssertEqual(try fixture.store.accountAuthentication(accountID: fixture.account.id).method, .googleOAuth)
    }

    func testPasswordReplacementClearsSignInAgainForAPasswordAccount() async throws {
        let fixture = try await CredentialReplacementFixture(account: CredentialReplacementFixture.custom)
        defer { fixture.cleanup() }
        // "Start Over with Saved Sign-ins" asks a password account to sign in again.
        try fixture.store.setAccountAuthentication(
            accountID: fixture.account.id, method: .password, state: .reauthorizationRequired)

        try await fixture.service.replaceCredentials(
            accountID: fixture.account.id, imapPassword: "new-imap", smtpPassword: "new-smtp")

        let authentication = try fixture.store.accountAuthentication(accountID: fixture.account.id)
        XCTAssertEqual(authentication.method, .password)
        XCTAssertEqual(authentication.state, .ready)
        XCTAssertEqual(try fixture.store.reauthorizationRequiredAccountIDs(), [])
    }

    func testDeleteAccountRoutesThroughSemanticVaultDeletion() async throws {
        let fixture = try await CredentialReplacementFixture(
            account: CredentialReplacementFixture.custom
        )
        defer { fixture.cleanup() }

        try await fixture.service.deleteAccount(accountID: fixture.account.id)

        XCTAssertFalse(fixture.store.accounts.contains { $0.id == fixture.account.id })
        let deletedIMAP = try await fixture.credentials.load(fixture.imapKey)
        let deletedSMTP = try await fixture.credentials.load(fixture.smtpKey)
        XCTAssertNil(deletedIMAP)
        XCTAssertNil(deletedSMTP)
    }
}

private enum SetupVerificationFailure: Error {
    case missingDelivery
    case delete
}

private enum FaultingCredentialVaultError: Error, Equatable {
    case injectedSecondStore
    case injectedRemove
}

private enum CredentialVaultOperation: Equatable, Sendable {
    case load(CredentialRecordKey)
    case store(CredentialRecordKey)
    case remove(CredentialRecordKey)
    case loadOrCreate([CredentialRecordKey])
}

private actor FaultingCredentialVault: CredentialVault {
    private var values: [CredentialRecordKey: Data]
    private let failingStoreCall: Int
    private let failingRemoveKey: CredentialRecordKey?
    private var storeCallCount = 0
    private var operations: [CredentialVaultOperation] = []

    init(
        initial: [CredentialRecordKey: Data],
        failingStoreCall: Int,
        failingRemoveKey: CredentialRecordKey? = nil
    ) {
        values = initial
        self.failingStoreCall = failingStoreCall
        self.failingRemoveKey = failingRemoveKey
    }

    func store(_ secret: Data, for key: CredentialRecordKey) throws {
        operations.append(.store(key))
        storeCallCount += 1
        if storeCallCount == failingStoreCall {
            throw FaultingCredentialVaultError.injectedSecondStore
        }
        values[key] = secret
    }

    func load(_ key: CredentialRecordKey) throws -> Data? {
        operations.append(.load(key))
        return values[key]
    }

    func remove(_ key: CredentialRecordKey) throws {
        operations.append(.remove(key))
        if key == failingRemoveKey {
            throw FaultingCredentialVaultError.injectedRemove
        }
        values.removeValue(forKey: key)
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        operations.append(.loadOrCreate(keys))
        let current = keys.map { values[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        guard created.count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        for (key, value) in zip(keys, created) { values[key] = value }
        return created.map(Optional.some)
    }

    func recordedOperations() -> [CredentialVaultOperation] {
        operations
    }

    func resetRecordedOperations() {
        operations.removeAll(keepingCapacity: true)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        // Expected.
    }
}

private func XCTAssertThrowsInjectedSecondStoreErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected the injected second-store error.", file: file, line: line)
    } catch let error as FaultingCredentialVaultError {
        XCTAssertEqual(error, .injectedSecondStore, file: file, line: line)
    } catch {
        XCTFail("Expected the injected second-store error.", file: file, line: line)
    }
}

private final class VerificationDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: String?

    var data: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func record(_ data: String) {
        lock.lock()
        storedData = data
        lock.unlock()
    }
}

private final class RecordingVerificationSMTPClient: SMTPClientProtocol, @unchecked Sendable {
    private let recorder: VerificationDeliveryRecorder

    init(recorder: VerificationDeliveryRecorder) {
        self.recorder = recorder
    }

    var data: String? { recorder.data }

    func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        recorder.record(data)
    }
}

private final class SetupVerificationIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private let recorder: VerificationDeliveryRecorder
    private let deleteFails: Bool
    private let lock = NSLock()
    private var deletedStorage: [Int] = []

    init(recorder: VerificationDeliveryRecorder, deleteFails: Bool) {
        self.recorder = recorder
        self.deleteFails = deleteFails
    }

    var deletedUIDs: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return deletedStorage
    }

    func login(username: String, password: String) async throws {}

    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(
            id: MailboxID("mbx_setup_inbox"),
            accountID: AccountID("acc_me_example_com"),
            name: "INBOX",
            path: "INBOX",
            specialUse: "\\Inbox"
        )]
    }

    func selectMailbox(_ path: String) async throws -> String {
        "* 1 EXISTS\n* OK [UIDVALIDITY 1] UIDs valid"
    }

    func allMessageUIDs() async throws -> [Int] { [7] }

    func messageUIDs(after uid: Int?) async throws -> [Int] {
        recorder.data == nil ? [] : [8]
    }

    func fetchHeader(uid: Int) async throws -> String {
        guard let data = recorder.data else { throw SetupVerificationFailure.missingDelivery }
        return data.components(separatedBy: "\r\n\r\n")[0]
    }

    func fetchBody(uid: Int) async throws -> String {
        guard let data = recorder.data else { throw SetupVerificationFailure.missingDelivery }
        return data
    }

    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}

    func delete(uid: Int) async throws {
        if deleteFails { throw SetupVerificationFailure.delete }
        recordDeleted(uid)
    }

    private func recordDeleted(_ uid: Int) {
        lock.lock()
        deletedStorage.append(uid)
        lock.unlock()
    }

    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

private final class RecordingAccountInboxSyncer: AccountInboxSyncOrchestrating, @unchecked Sendable {
    private let lock = NSLock()
    private let deletedUIDs: @Sendable () -> [Int]
    private var reasonStorage: [AccountInboxSyncReason] = []
    private var snapshotStorage: [[Int]] = []

    init(deletedUIDs: @escaping @Sendable () -> [Int]) {
        self.deletedUIDs = deletedUIDs
    }

    var reasons: [AccountInboxSyncReason] {
        lock.lock()
        defer { lock.unlock() }
        return reasonStorage
    }

    var deletedUIDSnapshots: [[Int]] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotStorage
    }

    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        record(reason: reason)
        return IMAPSyncResult(syncedMessageCount: 0)
    }

    private func record(reason: AccountInboxSyncReason) {
        lock.lock()
        reasonStorage.append(reason)
        snapshotStorage.append(deletedUIDs())
        lock.unlock()
    }
}

private final class CredentialReplacementFixture {
    static let gmail = Account(
        id: AccountID("acc_gmail"),
        displayName: "Gmail",
        email: EmailAddress("me@gmail.com"),
        imapHost: "imap.gmail.com",
        smtpHost: "smtp.gmail.com"
    )
    static let custom = Account(
        id: AccountID("acc_custom"),
        displayName: "Custom",
        email: EmailAddress("me@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )

    let dbURL: URL
    let account: Account
    let credentials: any CredentialVault
    let store: SQLiteMailStore
    let service: AccountSetupService
    let imapKey: CredentialRecordKey
    let smtpKey: CredentialRecordKey

    init(
        account: Account,
        credentials: any CredentialVault = InMemoryCredentialVault(),
        seedMissingCredentials: Bool = true
    ) async throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-credential-replacement-\(UUID().uuidString).sqlite")
        self.account = account
        self.credentials = credentials
        store = try SQLiteMailStore(path: dbURL.path)
        imapKey = CredentialRecordKey(rawValue: "account:\(account.id.rawValue):imap-password")
        smtpKey = CredentialRecordKey(rawValue: "account:\(account.id.rawValue):smtp-password")

        try store.migrate()
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(
                id: MailboxID("mbx_\(account.id.rawValue)_inbox"),
                accountID: account.id,
                name: "INBOX",
                path: "INBOX",
                specialUse: "\\Inbox"
            )
        )
        if seedMissingCredentials {
            if try await credentials.load(imapKey) == nil {
                try await credentials.store(Data("old-imap".utf8), for: imapKey)
            }
            if try await credentials.load(smtpKey) == nil {
                try await credentials.store(Data("old-smtp".utf8), for: smtpKey)
            }
        }
        service = AccountSetupService(store: store, credentials: credentials)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbURL)
    }
}

private final class AccountSetupFixture {
    let dbURL: URL
    let credentials: any CredentialVault
    let store: SQLiteMailStore
    let imap: SetupVerificationIMAPClient
    let smtp: RecordingVerificationSMTPClient
    let syncer: RecordingAccountInboxSyncer
    let service: AccountSetupService
    let request: AccountSetupRequest

    init(
        deleteFails: Bool,
        credentials: any CredentialVault = InMemoryCredentialVault(),
        publishDirectMailSource: Bool = false
    ) throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-verification-setup-\(UUID().uuidString).sqlite")
        self.credentials = credentials
        store = try SQLiteMailStore(path: dbURL.path)

        let recorder = VerificationDeliveryRecorder()
        let imap = SetupVerificationIMAPClient(recorder: recorder, deleteFails: deleteFails)
        let smtp = RecordingVerificationSMTPClient(recorder: recorder)
        let syncer = RecordingAccountInboxSyncer { imap.deletedUIDs }
        self.imap = imap
        self.smtp = smtp
        self.syncer = syncer
        self.service = AccountSetupService(
            store: store,
            credentials: credentials,
            inboxSyncOrchestrator: syncer,
            imapClientFactory: { _, _ in imap },
            smtpClientFactory: { _, _ in smtp },
            verificationCleanup: AccountVerificationCleanup(maximumAttempts: 1, sleep: { _ in }),
            publishDirectMailSource: publishDirectMailSource
        )
        request = AccountSetupRequest(
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            imapPort: 993,
            smtpHost: "smtp.example.com",
            smtpPort: 587,
            username: "custom-login",
            imapPassword: "imap-secret",
            smtpPassword: "smtp-secret"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbURL)
    }
}
