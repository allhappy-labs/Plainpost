import CryptoKit
import Foundation
import XCTest
#if canImport(Security)
import Security
#endif
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class AccountCredentialStoreTests: XCTestCase {
    func testRecoveryControllerIgnoresInstalledExpiredSession() async throws {
        let backing = InMemoryAccountSecretStore()
        let service = "com.marynavdovenko.Plainpost.AccountTests.ExpiredRecovery"
        let store = AccountCredentialStore(secretStore: backing, service: service)
        let (activation, material) = try genesisActivationFixture()
        let expired = try AccountSessionCredentials(
            accountID: activation.accountID,
            deviceID: activation.deviceID,
            accessToken: "expired-access",
            accessExpiresAt: Date(timeIntervalSince1970: 1),
            refreshCredential: Data(repeating: 7, count: 32),
            offlineLease: "expired-lease"
        )
        try store.commitActivation(activation, credentials: expired, genesisMaterial: material)
        let manifest = try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore())
        let client = try AccountAPIClient(
            transport: FailingRecoveryTransport(),
            credentialStore: store,
            manifestStore: manifest
        )

        let controller = try store.makeRecoveryLifecycleController(
            client: client,
            manifestStore: manifest,
            platform: .macos,
            authenticate: { _ in true }
        )

        do {
            _ = try await controller.recover(
                identityToken: "identity-token",
                appleNonce: Data(repeating: 8, count: 32)
            )
            XCTFail("the failing transport must stop recovery")
        } catch let failure as AccountRecoveryFailure {
            XCTAssertEqual(failure, .serverPreparation)
        }
    }

    func testDefaultCredentialAndTrustStoresDoNotRequestMacSharedGroup() throws {
        let backing = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(
            secretStore: backing,
            service: "com.marynavdovenko.Plainpost.AccountTests.Default"
        )

        _ = try store.loadOrCreateDeviceIdentity()

        XCTAssertFalse(backing.records.isEmpty)
        XCTAssertTrue(backing.records.keys.allSatisfy { $0.accessGroup == nil })
    }

    func testExplicitSharedAccessGroupScopesCredentialAndTrustRecords() throws {
        let backing = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(
            secretStore: backing,
            service: "com.marynavdovenko.Plainpost.AccountTests.SharedGroup",
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )

        _ = try store.loadOrCreateDeviceIdentity()

        XCTAssertFalse(backing.records.isEmpty)
        XCTAssertTrue(backing.records.keys.allSatisfy {
            $0.accessGroup == PlainpostAccountSharedKeychain.accessGroup
        })
    }

    func testGroupedCredentialStoreDoesNotReadLegacyUngroupedIdentityMaterial() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "com.marynavdovenko.Plainpost.AccountTests.LegacyGroup"
        try backing.replace(
            Data(repeating: 7, count: 32),
            key: AccountSecretKey(service: service, account: "identity.signing.v1"),
            attributes: .deviceOnly
        )
        try backing.replace(
            Data(repeating: 8, count: 32),
            key: AccountSecretKey(service: service, account: "identity.agreement.v1"),
            attributes: .deviceOnly
        )

        let store = AccountCredentialStore(
            secretStore: backing,
            service: service,
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )
        _ = try store.loadOrCreateDeviceIdentity()

        XCTAssertNotNil(backing.records[AccountSecretKey(
            service: service,
            account: "identity.signing.v1",
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )])
        XCTAssertNotNil(backing.records[AccountSecretKey(
            service: service,
            account: "identity.agreement.v1",
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )])
    }

    func testGroupedIdentityCanBeResolvedByIndependentServiceStoreInstance() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "com.marynavdovenko.Plainpost.AccountTests.CrossProcess"
        let first = AccountCredentialStore(
            secretStore: backing,
            service: service,
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )
        let created = try first.loadOrCreateDeviceIdentity()
        let second = AccountCredentialStore(
            secretStore: backing,
            service: service,
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )

        XCTAssertEqual(try second.loadOrCreateDeviceIdentity().publicBundle, created.publicBundle)
    }

    func testProductionActivationAtomicallyStoresGenesisMaterialWithSessionCredentials() throws {
        let backing = InMemoryAccountSecretStore(), service = "com.marynavdovenko.Plainpost.AccountTests.AtomicActivation"
        let store = AccountCredentialStore(secretStore: backing, service: service)
        let (activation, material) = try genesisActivationFixture(), account = activation.accountID, device = activation.deviceID
        let credentials = try AccountSessionCredentials(accountID: account, deviceID: device, accessToken: "access", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: 7, count: 32), offlineLease: "lease")
        try store.commitActivation(activation, credentials: credentials, genesisMaterial: material)
        XCTAssertEqual(try store.loadSession()?.credentials, credentials)
        XCTAssertEqual(backing.records.filter { $0.key.service == service && $0.key.account.contains("session") }.count, 1)
        XCTAssertTrue(backing.records.values.contains(where: { $0.value.range(of: Data(material.base64EncodedString().utf8)) != nil }))
    }
    func testCrossInstanceSessionRotationUsesSecretLayerCompareAndSwap() throws {
        let backing = InMemoryAccountSecretStore(), service = "com.marynavdovenko.Plainpost.AccountTests.CrossInstanceCAS"
        let first = AccountCredentialStore(secretStore: backing, service: service), second = AccountCredentialStore(secretStore: backing, service: service)
        let (activation, material) = try genesisActivationFixture(), account = activation.accountID, device = activation.deviceID
        func credentials(_ byte: UInt8) throws -> AccountSessionCredentials { try AccountSessionCredentials(accountID: account, deviceID: device, accessToken: "access-\(byte)", accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshCredential: Data(repeating: byte, count: 32), offlineLease: "lease-\(byte)") }
        let original = try credentials(1), winner = try credentials(2), loser = try credentials(3)
        try first.commitActivation(activation, credentials: original, genesisMaterial: material)
        XCTAssertTrue(try first.replaceSession(ifCurrent: original, with: winner))
        XCTAssertFalse(try second.replaceSession(ifCurrent: original, with: loser))
        XCTAssertEqual(try second.loadSession()?.credentials, winner)
    }

    func testGenesisActivationRecoversEveryInterruptedJournalStepOnRelaunch() throws {
        for interruptedStep in ["journal", "trust", "session", "marker"] {
            let backing = InMemoryAccountSecretStore()
            let credentialService = "com.marynavdovenko.Plainpost.AccountTests.Activation.\(interruptedStep)"
            let trustService = credentialService + ".Trust"
            let fence = TestCredentialAccountOperationFence()
            let trustStore = AccountTrustStore(secretStore: backing, service: trustService, operationFence: fence)
            let store = AccountCredentialStore(
                secretStore: backing,
                service: credentialService,
                secureEnclaveIdentityProvider: nil,
                secureEnclaveIdentityResolver: nil,
                secureEnclaveAgreementProvider: nil,
                secureEnclaveAgreementResolver: nil,
                trustStore: trustStore
            )
            let (activation, material) = try genesisActivationFixture()
            let credentials = try activationCredentials(for: activation, byte: 9)
            store.testAfterActivationStep = { step in
                if step == interruptedStep { throw AccountRuntimeError.transportFailure }
            }

            XCTAssertThrowsError(try store.commitActivation(activation, credentials: credentials, genesisMaterial: material))

            let relaunchedTrustStore = AccountTrustStore(secretStore: backing, service: trustService, operationFence: fence)
            let relaunched = AccountCredentialStore(
                secretStore: backing,
                service: credentialService,
                secureEnclaveIdentityProvider: nil,
                secureEnclaveIdentityResolver: nil,
                secureEnclaveAgreementProvider: nil,
                secureEnclaveAgreementResolver: nil,
                trustStore: relaunchedTrustStore
            )
            XCTAssertEqual(try relaunched.loadSession()?.credentials, credentials)
            XCTAssertEqual(try relaunchedTrustStore.loadKeyMaterial(for: activation.accountID)?.combined, material)
            XCTAssertEqual(try relaunchedTrustStore.loadCheckpoint(for: activation.accountID)?.commitDigest, AccountTranscript.trustCommitDigest(try XCTUnwrap(activation.currentTrustCommit)))
            XCTAssertNil(backing.records[.init(service: credentialService, account: "activation.journal.v1")])
            XCTAssertNotNil(backing.records[.init(service: credentialService, account: "activation.committed.v1")])
        }
    }

    func testGenesisActivationDirectExactRetryResumesEveryInterruptedJournalStep() throws {
        for interruptedStep in ["journal", "trust", "session", "marker"] {
            let backing = InMemoryAccountSecretStore()
            let credentialService = "com.marynavdovenko.Plainpost.AccountTests.DirectActivation.\(interruptedStep)"
            let trustService = credentialService + ".Trust"
            let fence = TestCredentialAccountOperationFence()
            let trustStore = AccountTrustStore(secretStore: backing, service: trustService, operationFence: fence)
            let store = AccountCredentialStore(
                secretStore: backing,
                service: credentialService,
                secureEnclaveIdentityProvider: nil,
                secureEnclaveIdentityResolver: nil,
                secureEnclaveAgreementProvider: nil,
                secureEnclaveAgreementResolver: nil,
                trustStore: trustStore
            )
            let (activation, material) = try genesisActivationFixture()
            let credentials = try activationCredentials(for: activation, byte: 19)
            store.testAfterActivationStep = { step in
                if step == interruptedStep { throw AccountRuntimeError.transportFailure }
            }
            XCTAssertThrowsError(try store.commitActivation(activation, credentials: credentials, genesisMaterial: material))

            store.testAfterActivationStep = nil
            XCTAssertNoThrow(try store.commitActivation(activation, credentials: credentials, genesisMaterial: material))
            XCTAssertEqual(try store.loadSession()?.credentials, credentials)
            XCTAssertEqual(try trustStore.loadKeyMaterial(for: activation.accountID)?.combined, material)
            XCTAssertNil(backing.records[.init(service: credentialService, account: "activation.journal.v1")])
            XCTAssertNotNil(backing.records[.init(service: credentialService, account: "activation.committed.v1")])

            let conflicting = try activationCredentials(for: activation, byte: 20)
            XCTAssertThrowsError(try store.commitActivation(activation, credentials: conflicting, genesisMaterial: material))
            XCTAssertEqual(try store.loadSession()?.credentials, credentials)
        }
    }

    func testPendingActivationCannotBypassVerifiedTrustPromotion() throws {
        let backing = InMemoryAccountSecretStore()
        let credentialService = "com.marynavdovenko.Plainpost.AccountTests.PendingActivation"
        let trustService = credentialService + ".Trust"
        let trustStore = AccountTrustStore(secretStore: backing, service: trustService, operationFence: TestCredentialAccountOperationFence())
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let device = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let activation = AccountActivation(accountID: account, deviceID: device, mode: .pending)
        let credentials = try activationCredentials(for: activation, byte: 10)
        let store = AccountCredentialStore(
            secretStore: backing,
            service: credentialService,
            secureEnclaveIdentityProvider: nil,
            secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil,
            secureEnclaveAgreementResolver: nil,
            trustStore: trustStore
        )

        try store.commitPendingActivation(activation, credentials: credentials)
        XCTAssertThrowsError(try store.commitActivation(activation, credentials: credentials, genesisMaterial: nil))

        XCTAssertNil(try trustStore.loadState(for: account))
        XCTAssertEqual(try store.loadSession(), try AccountSession(provisional: activation, credentials: credentials))
        XCTAssertNil(backing.records[.init(service: credentialService, account: "activation.journal.v1")])
        XCTAssertNil(backing.records[.init(service: credentialService, account: "activation.committed.v1")])
    }

    func testProtocolDefaultCannotPromotePendingActivationWithoutVerifiedTrust() throws {
        let store = DefaultActivationCredentialStore()
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            mode: .pending
        )
        let credentials = try activationCredentials(for: activation, byte: 11)

        XCTAssertThrowsError(try store.commitActivation(activation, credentials: credentials, genesisMaterial: nil))
        XCTAssertNil(try store.loadSession())
    }

    func testGenesisActivationJournalAndPublicationAreInsideTheAccountFence() throws {
        let backing = InMemoryAccountSecretStore()
        let fence = ObservedCredentialAccountOperationFence()
        let secrets = FenceCheckingSecretStore(backing: backing, fence: fence)
        let credentialService = "com.marynavdovenko.Plainpost.AccountTests.FencedActivation"
        let trustStore = AccountTrustStore(secretStore: secrets, service: credentialService + ".Trust", operationFence: fence)
        let store = AccountCredentialStore(
            secretStore: secrets,
            service: credentialService,
            secureEnclaveIdentityProvider: nil,
            secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil,
            secureEnclaveAgreementResolver: nil,
            trustStore: trustStore
        )
        let (activation, material) = try genesisActivationFixture()

        try store.commitActivation(activation, credentials: activationCredentials(for: activation, byte: 11), genesisMaterial: material)

        XCTAssertEqual(secrets.unfencedActivationWrites, [])
    }

    func testCompetingGenesisActivationCannotReplaceCommittedCredentials() throws {
        let backing = InMemoryAccountSecretStore()
        let fence = TestCredentialAccountOperationFence()
        let service = "com.marynavdovenko.Plainpost.AccountTests.CompetingActivation"
        let trustService = service + ".Trust"
        func store() -> AccountCredentialStore {
            AccountCredentialStore(
                secretStore: backing,
                service: service,
                secureEnclaveIdentityProvider: nil,
                secureEnclaveIdentityResolver: nil,
                secureEnclaveAgreementProvider: nil,
                secureEnclaveAgreementResolver: nil,
                trustStore: AccountTrustStore(secretStore: backing, service: trustService, operationFence: fence)
            )
        }
        let (activation, material) = try genesisActivationFixture()
        let winner = try activationCredentials(for: activation, byte: 12)
        let conflicting = try activationCredentials(for: activation, byte: 13)
        let first = store(), second = store()

        try first.commitActivation(activation, credentials: winner, genesisMaterial: material)
        XCTAssertNoThrow(try second.commitActivation(activation, credentials: winner, genesisMaterial: material))
        XCTAssertThrowsError(try second.commitActivation(activation, credentials: conflicting, genesisMaterial: material))
        XCTAssertEqual(try first.loadSession()?.credentials, winner)
    }
    #if canImport(Security)
    func testSecureEnclaveDERParserAcceptsRequiredPositivePaddingAndNormalizesHighS() throws {
        let r = Data([0x80]) + Data(repeating: 0, count: 31)
        let highS = try XCTUnwrap(Data(hexCredential: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632550"))
        let raw = try AccountCredentialStore.rawP256Signature(fromDER: derSignature(r: r, s: highS))

        XCTAssertEqual(raw.prefix(32), r)
        XCTAssertEqual(raw.suffix(32), Data(repeating: 0, count: 31) + Data([1]))
        XCTAssertNoThrow(try AccountWireCodec.validateLowSSignature(raw))
    }

    func testSecureEnclaveDERParserRejectsNonCanonicalOrOutOfRangeIntegers() throws {
        let one = Data(repeating: 0, count: 31) + Data([1])
        let order = try XCTUnwrap(Data(hexCredential: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551"))
        XCTAssertThrowsError(try AccountCredentialStore.rawP256Signature(fromDER: Data([0x30, 0x07, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01, 0x01])))
        XCTAssertThrowsError(try AccountCredentialStore.rawP256Signature(fromDER: Data([0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0x01])))
        XCTAssertThrowsError(try AccountCredentialStore.rawP256Signature(fromDER: Data([0x30, 0x81, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01])))
        XCTAssertThrowsError(try AccountCredentialStore.rawP256Signature(fromDER: derSignature(r: order, s: one)))
    }
    #endif

    func testSupportedSecureEnclavePathStoresAnOpaqueSigningReferenceRatherThanARawSigningScalar() throws {
        let secrets = InMemoryAccountSecretStore()
        let signing = try P256.Signing.PrivateKey(rawRepresentation: scalar(11))
        let opaque = try AccountOpaqueSigningIdentity(
            publicKey: signing.publicKey.x963Representation,
            persistentReference: Data("test-secure-enclave-reference".utf8),
            sign: { transcript in try signing.signature(for: transcript).rawRepresentation }
        )
        let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(12))
        let opaqueAgreement = try AccountOpaqueAgreementIdentity(
            publicKey: agreement.publicKey.x963Representation,
            persistentReference: Data("test-secure-enclave-agreement-reference".utf8),
            sharedSecret: { peer in
                AccountSharedSecret(try agreement.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer)))
            }
        )
        let store = AccountCredentialStore(
            secretStore: secrets,
            service: "com.marynavdovenko.Plainpost.AccountSecureEnclaveTests",
            secureEnclaveIdentityProvider: { opaque },
            secureEnclaveIdentityResolver: { _ in opaque },
            secureEnclaveAgreementProvider: { opaqueAgreement },
            secureEnclaveAgreementResolver: { _ in opaqueAgreement }
        )

        let identity = try store.loadOrCreateDeviceIdentity()

        XCTAssertEqual(identity.publicBundle.signingKey, signing.publicKey.x963Representation)
        let record = try XCTUnwrap(secrets.records[.init(service: "com.marynavdovenko.Plainpost.AccountSecureEnclaveTests", account: "identity.signing.v1")])
        XCTAssertNotEqual(record.value, scalar(11))
        XCTAssertTrue(record.value.starts(with: Data("plainpost-secure-enclave-reference.v1:".utf8)))
        let agreementRecord = try XCTUnwrap(secrets.records[.init(service: "com.marynavdovenko.Plainpost.AccountSecureEnclaveTests", account: "identity.agreement.v1")])
        XCTAssertNotEqual(agreementRecord.value, scalar(12))
        XCTAssertTrue(agreementRecord.value.starts(with: Data("plainpost-secure-enclave-agreement.v1:".utf8)))
    }

    func testLoadOrCreateIdentityUsesDistinctThisDeviceOnlyNonSynchronizableRecords() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests")
        let first = try store.loadOrCreateDeviceIdentity()
        let reopened = try AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests")
            .loadOrCreateDeviceIdentity()

        XCTAssertEqual(first.publicBundle, reopened.publicBundle)
        XCTAssertEqual(secrets.records.count, 2)
        XCTAssertTrue(secrets.records.values.allSatisfy { $0.attributes.accessibility == .afterFirstUnlockThisDeviceOnly && !$0.attributes.synchronizable })
    }

    func testCorruptIdentityFailsClosedAndSessionReplacementDoesNotPersistAppleFields() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests")
        _ = try store.loadOrCreateDeviceIdentity()
        try secrets.replace(Data("corrupt".utf8), key: .init(service: "com.marynavdovenko.Plainpost.AccountTests", account: "identity.signing.v1"), attributes: .deviceOnly)
        XCTAssertThrowsError(try store.loadOrCreateDeviceIdentity())

        try store.saveSession(.provisional(accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"), mode: .pending))
        let encoded = try XCTUnwrap(secrets.records[.init(service: "com.marynavdovenko.Plainpost.AccountTests", account: "bootstrap.provisional-activation.v1")]?.value)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apple"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
    }

    func testDeviceIdentityExposesOnlySigningOperationsForItsSigningRole() throws {
        // A tiny signing scalar such as 9 makes the public key 9G. CryptoKit's
        // P-256 verifier on macOS then rejects about 2.5% of valid
        // signatures, which Go's crypto/ecdsa accepts. Scalars 5, 13, 15,
        // 17, 29, and 33 do the same. That made this test flaky, so it
        // signs with a full-width fixed scalar, like a real generated key.
        let identity = try AccountDeviceIdentity(signingPrivateKey: nonDegenerateSigningScalar, agreementPrivateKey: scalar(10))
        let message = Data("role-isolated signing".utf8)
        let publicKey = try P256.Signing.PublicKey(x963Representation: identity.publicBundle.signingKey)
        for _ in 0..<64 {
            let signature = try identity.signature(for: message)
            XCTAssertNoThrow(try AccountWireCodec.validateLowSSignature(signature))
            XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
        }
    }

    func testLowSNormalizationKeepsFixedWidthScalarsAcrossShortHighAndBoundaryValues() throws {
        func hex(_ value: String) throws -> Data { try XCTUnwrap(Data(hexCredential: value)) }
        let shortR = Data(repeating: 0, count: 31) + Data([1])
        let shortS = Data(repeating: 0, count: 3) + Data(repeating: 0xAB, count: 29)
        let half = try hex("7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")
        let cases: [(name: String, s: Data, expected: Data)] = [
            ("short low s is untouched", shortS, shortS),
            ("half order is already low", half, half),
            ("half order plus one maps to half order", try hex("7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A9"), half),
            ("high s gains a leading zero byte", try hex("FFFEFDFBFBFAF9F9F7F6F5F4F3F2F1F0ACD5E89A9302886DDBA0B0A7E0460732"), try hex("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")),
            ("borrow chain yields a leading zero byte", try hex("FEFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632552"), try hex("00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")),
            ("order minus one maps to one", try hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632550"), Data(repeating: 0, count: 31) + Data([1])),
        ]
        for testCase in cases {
            let normalized = AccountDeviceIdentity.normalizedLowS(shortR + testCase.s)
            XCTAssertEqual(normalized.count, 64, testCase.name)
            XCTAssertEqual(normalized.prefix(32), shortR, testCase.name)
            XCTAssertEqual(Data(normalized.suffix(32)), testCase.expected, testCase.name)
            XCTAssertNoThrow(try AccountWireCodec.validateLowSSignature(normalized), testCase.name)
            XCTAssertEqual(try AccountWireCodec.normalizedLowSSignature(shortR + testCase.s), normalized, testCase.name)
            #if canImport(Security)
            XCTAssertEqual(try AccountCredentialStore.rawP256Signature(fromDER: derSignature(r: shortR, s: testCase.s)), normalized, testCase.name)
            #endif
        }
    }

    func testCommittedActivationSucceedsWhenLegacyCleanupFailsAndRelaunchUsesAuthoritativeRecord() throws {
        let backing = InMemoryAccountSecretStore()
        let secrets = LegacyDeleteFailingSecretStore(backing: backing)
        let service = "com.marynavdovenko.Plainpost.AccountCleanupTests"
        let legacyKey = AccountSecretKey(service: service, account: "session.v1")
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            mode: .genesis
        )
        try backing.replace(try JSONEncoder().encode(AccountSession.provisional(accountID: activation.accountID, deviceID: activation.deviceID, mode: .pending)), key: legacyKey, attributes: .deviceOnly)
        let store = AccountCredentialStore(secretStore: secrets, service: service)

        XCTAssertNoThrow(try store.commitProvisionalActivation(activation, genesisMaterial: Data(repeating: 7, count: 64)))

        let relaunched = AccountCredentialStore(secretStore: secrets, service: service)
        XCTAssertEqual(try relaunched.loadSession(), .provisional(accountID: activation.accountID, deviceID: activation.deviceID, mode: .genesis))
        XCTAssertNotNil(backing.records[legacyKey])
    }

    func testDeviceLabelsStayDeviceOnlyBoundedAndArePurgedWithAccountAuthority() throws {
        let backing = InMemoryAccountSecretStore()
        let service = "com.marynavdovenko.Plainpost.AccountTests.DeviceLabels"
        let store = AccountCredentialStore(secretStore: backing, service: service)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let deviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")

        try store.saveDeviceLabel("Kitchen Mac", accountID: accountID, deviceID: deviceID)

        XCTAssertEqual(try store.loadDeviceLabel(accountID: accountID, deviceID: deviceID), "Kitchen Mac")
        let record = try XCTUnwrap(backing.records[.init(service: service, account: "device-labels.v1")])
        XCTAssertEqual(record.attributes, .deviceOnly)
        XCTAssertThrowsError(try store.saveDeviceLabel(" bad\nlabel ", accountID: accountID, deviceID: deviceID))
        try store.purgeAccountAuthority(accountID: accountID)
        XCTAssertNil(backing.records[.init(service: service, account: "device-labels.v1")])
    }

    // Task 1 spike: a persistent-reference lookup that also names an access
    // group fails with errSecParam (-50), so the service could never resolve
    // a Secure Enclave identity from the AccountShared group. A persistent
    // reference already names exactly one item; the lookup carries no group.
    func testSecureEnclaveKeyLookupByPersistentReferenceNeverNamesAnAccessGroup() {
        #if canImport(Security)
        let reference = Data([1, 2, 3, 4])
        let query = AccountCredentialStore.secureEnclaveKeyQuery(persistentReference: reference)
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertEqual(query[kSecValuePersistentRef as String] as? Data, reference)
        XCTAssertEqual(query[kSecReturnRef as String] as? Bool, true)
        #endif
    }
}

private struct FailingRecoveryTransport: AccountHTTPTransport {
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        throw AccountRuntimeError.transportFailure
    }
}

private func scalar(_ value: UInt8) -> Data { Data(repeating: 0, count: 31) + Data([value]) }
// SHA-256 of "plainpost.device-identity.signing-role-test". It is a
// full-width scalar below the P-256 order.
private let nonDegenerateSigningScalar = Data(hexCredential: "63e7af4b79aa2f3d3f11db6c3b83195f2c29b4a4aaebee414df6e165d96e984a")!

private final class DefaultActivationCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    private var session: AccountSession?
    func loadOrCreateDeviceIdentity() throws -> AccountDeviceIdentity { try .generate() }
    func loadSession() throws -> AccountSession? { session }
    func saveSession(_ session: AccountSession) throws { self.session = session }
    func clearSession() throws { session = nil }
    func commitProvisionalActivation(_: AccountActivation, genesisMaterial _: Data?) throws {}
}

func genesisActivationFixture() throws -> (AccountActivation, Data) {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let genesis = try XCTUnwrap(root["genesisTrustCommit"] as? [String: Any])
    let object = try XCTUnwrap(genesis["commit"])
    let commit = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    let inputs = try XCTUnwrap(root["testOnlyInputs"] as? [String: Any])
    let mailbox = try XCTUnwrap(Data(hexCredential: try XCTUnwrap(inputs["mailboxMatchingKeyHex"] as? String)))
    let metadata = try XCTUnwrap(Data(hexCredential: try XCTUnwrap(inputs["metadataKeyHex"] as? String)))
    let member = try XCTUnwrap(commit.state.members.first)
    return (
        AccountActivation(accountID: commit.state.accountID, deviceID: member.deviceID, mode: .genesis, currentTrustCommit: commit),
        mailbox + metadata
    )
}

func activationCredentials(for activation: AccountActivation, byte: UInt8) throws -> AccountSessionCredentials {
    try AccountSessionCredentials(
        accountID: activation.accountID,
        deviceID: activation.deviceID,
        accessToken: "access-\(byte)",
        accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        refreshCredential: Data(repeating: byte, count: 32),
        offlineLease: "lease-\(byte)"
    )
}

private final class TestCredentialAccountOperationFence: AccountOperationFencing, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    func withLock<T>(accountID _: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class ObservedCredentialAccountOperationFence: AccountOperationFencing, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let depthLock = NSLock()
    private var depth = 0
    var isHeld: Bool { depthLock.lock(); defer { depthLock.unlock() }; return depth > 0 }
    func withLock<T>(accountID _: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        lock.lock()
        depthLock.lock(); depth += 1; depthLock.unlock()
        defer {
            depthLock.lock(); depth -= 1; depthLock.unlock()
            lock.unlock()
        }
        return try operation()
    }
}

private final class FenceCheckingSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore
    private let fence: ObservedCredentialAccountOperationFence
    private let lock = NSLock()
    private(set) var unfencedActivationWrites: [String] = []
    init(backing: InMemoryAccountSecretStore, fence: ObservedCredentialAccountOperationFence) { self.backing = backing; self.fence = fence }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        if key.account.hasPrefix("activation.") || key.account == "session.credentials.v1" {
            lock.lock(); if !fence.isHeld { unfencedActivationWrites.append(key.account) }; lock.unlock()
        }
        try backing.replace(value, key: key, attributes: attributes)
    }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        if key.account.hasPrefix("activation.") || key.account == "session.credentials.v1" {
            lock.lock(); if !fence.isHeld { unfencedActivationWrites.append(key.account) }; lock.unlock()
        }
        return try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes)
    }
    func delete(_ key: AccountSecretKey) throws { try backing.delete(key) }
}

#if canImport(Security)
private func derSignature(r: Data, s: Data) -> Data {
    func integer(_ value: Data) -> Data {
        var canonical = Data(value.drop { $0 == 0 })
        if canonical.isEmpty { canonical = Data([0]) }
        if canonical[0] & 0x80 != 0 { canonical.insert(0, at: 0) }
        return Data([0x02, UInt8(canonical.count)]) + canonical
    }
    let body = integer(r) + integer(s)
    return Data([0x30, UInt8(body.count)]) + body
}
#endif

private final class LegacyDeleteFailingSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let backing: InMemoryAccountSecretStore
    init(backing: InMemoryAccountSecretStore) { self.backing = backing }
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { try backing.load(key) }
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws { try backing.replace(value, key: key, attributes: attributes) }
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool { try backing.compareAndSwap(expected: expected, replacement: replacement, key: key, attributes: attributes) }
    func delete(_ key: AccountSecretKey) throws { if key.account == "session.v1" { throw AccountRuntimeError.secretUnavailable }; try backing.delete(key) }
}

private extension Data {
    init?(hexCredential: String) { guard hexCredential.count.isMultiple(of: 2) else { return nil }; self = Data(stride(from: 0, to: hexCredential.count, by: 2).compactMap { UInt8(hexCredential.dropFirst($0).prefix(2), radix: 16) }); guard count == hexCredential.count / 2 else { return nil } }
}
