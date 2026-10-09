import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class AccountAPIClientHappyPathTests: XCTestCase {
    func testPendingBootstrapSendsNullCommitAndAtomicallyPersistsSessionActivation() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests")
        let identity = try AccountDeviceIdentity(signingPrivateKey: scalar(4), agreementPrivateKey: scalar(5))
        let transport = PendingBootstrapTransport(challengeTemplate: try fixturePendingChallenge())
        let client = try AccountAPIClient(
            transport: transport,
            credentialStore: store,
            manifestStore: try manifestStore(),
            baseURL: URL(string: "https://selected-central.example:8443")!
        )

        let activation = try await client.bootstrapAppleCredential(identityToken: "a.b.c", nonce: Data(0...31), device: identity)
        XCTAssertEqual(activation.mode, .pending)
        let requestCount = await transport.requestCount()
        let receivedFinalize = await transport.receivedPendingFinalize()
        let requestHosts = await transport.requestHosts()
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(receivedFinalize)
        XCTAssertEqual(requestHosts, ["selected-central.example", "selected-central.example"] as [String?])
        let stored = try XCTUnwrap(store.loadSession())
        XCTAssertEqual(stored.state, .provisional(AccountActivation(accountID: activation.accountID, deviceID: activation.deviceID, mode: .pending)))
        XCTAssertNotNil(stored.credentials, "pending DPoP credentials must remain scoped to admission without authorizing mailbox state")
        XCTAssertFalse(secrets.records.keys.contains { $0.account.contains("apple") || $0.account.contains("token") })
    }

    func testGenesisBootstrapBuildsOneSelfPackageAndPersistsMaterialOnlyAfterActivation() async throws {
        let secrets = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountGenesisTests")
        let identity = try store.loadOrCreateDeviceIdentity()
        let transport = GenesisBootstrapTransport(challengeTemplate: try fixtureGenesisChallenge())
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore())

        let activation = try await client.bootstrapAppleCredential(identityToken: "a.b.c", nonce: Data(repeating: 9, count: 32), device: identity)
        XCTAssertEqual(activation.mode, .genesis)
        let receivedPackage = await transport.receivedOneSelfPackage()
        XCTAssertTrue(receivedPackage)
        let activationRecord = try XCTUnwrap(secrets.records[.init(service: "com.marynavdovenko.Plainpost.AccountGenesisTests", account: "session.credentials.v1")]?.value)
        let activationObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: activationRecord) as? [String: Any])
        let materialText = try XCTUnwrap(activationObject["genesisMaterial"] as? String)
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: materialText)).count, 64)
        XCTAssertNil(secrets.records[.init(service: "com.marynavdovenko.Plainpost.AccountGenesisTests", account: "genesis.material.v1")])
        XCTAssertEqual(try store.loadSession()?.state, .active)
    }

    func testGenesisBootstrapUsesTheCredentialProtocolAtomicCommitRatherThanAConcreteStoreCast() async throws {
        let identity = try AccountDeviceIdentity(signingPrivateKey: scalar(7), agreementPrivateKey: scalar(8))
        let store = AtomicRecordingCredentialStore(identity: identity)
        let transport = GenesisBootstrapTransport(challengeTemplate: try fixtureGenesisChallenge())
        let client = try AccountAPIClient(transport: transport, credentialStore: store, manifestStore: try manifestStore())

        let activation = try await client.bootstrapAppleCredential(identityToken: "a.b.c", nonce: Data(repeating: 6, count: 32), device: identity)

        XCTAssertEqual(store.atomicCommits.count, 1)
        XCTAssertEqual(store.atomicCommits.first?.activation, activation)
        XCTAssertEqual(store.atomicCommits.first?.material?.count, 64)
        XCTAssertEqual(store.saveSessionCalls, 0)
    }

    private func manifestStore() throws -> BootstrapKeyManifestStore {
        // These Task 1 vectors deliberately use their public test root. They
        // must never inherit the app-bundled production trust anchor.
        let root = try XCTUnwrap(Data(base64URLEncoded: "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"))
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/central-bootstrap-manifest-test-v1.json")
        return try BootstrapKeyManifestStore(bundledManifest: Data(contentsOf: manifestURL), offlineRootKeyID: "plainpost-root-2026-01", offlineRootPublicKey: root, secretStore: InMemoryAccountSecretStore(), clock: { Date(timeIntervalSince1970: 1_785_751_320) })
    }
    private func fixturePendingChallenge() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let pending = try XCTUnwrap((root["bootstrapFinalize"] as? [String: Any])?["pending"] as? [String: Any])
        let message = try XCTUnwrap(pending["message"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: try XCTUnwrap(message["challenge"] as? [String: Any]))
    }
    private func fixtureGenesisChallenge() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let message = try XCTUnwrap((root["genesisBootstrapChallenge"] as? [String: Any])?["message"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: message)
    }
}

private final class AtomicRecordingCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    struct Commit: Equatable { let activation: AccountActivation; let material: Data? }
    private let identity: AccountDeviceIdentity
    private(set) var atomicCommits: [Commit] = []
    private(set) var saveSessionCalls = 0
    init(identity: AccountDeviceIdentity) { self.identity = identity }
    func loadOrCreateDeviceIdentity() throws -> AccountDeviceIdentity { identity }
    func loadSession() throws -> AccountSession? { nil }
    func saveSession(_ session: AccountSession) throws { saveSessionCalls += 1 }
    func clearSession() throws {}
    func commitProvisionalActivation(_ activation: AccountActivation, genesisMaterial: Data?) throws { atomicCommits.append(Commit(activation: activation, material: genesisMaterial)) }
    func commitActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials, genesisMaterial: Data?) throws { atomicCommits.append(Commit(activation: activation, material: genesisMaterial)) }
}

private actor PendingBootstrapTransport: AccountHTTPTransport {
    private let template: Data
    private var sent: [URLRequest] = []
    private var sawPendingFinalize = false
    init(challengeTemplate: Data) { template = challengeTemplate }
    func requestHosts() -> [String?] { sent.map { $0.url?.host } }
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        sent.append(request)
        switch sent.count {
        case 1:
            guard let body = request.httpBody else { throw AccountRuntimeError.transportFailure }
            let exchange = try AccountWireCodec.decodeExchangeRequest(body)
            let tokenDigest = Data(SHA256.hash(data: Data(exchange.appleIdentityToken.utf8)))
            let digest = Data(SHA256.hash(data: AccountTranscript.exchangeRequest(tokenDigest: tokenDigest, nonce: exchange.nonce, bundle: exchange.deviceBundle, proof: exchange.deviceProof)))
            var challenge = try JSONSerialization.jsonObject(with: template) as! [String: Any]
            challenge["exchangeRequestDigest"] = AccountWireCodec.encodeBase64URL(digest)
            let decoded = try AccountWireCodec.decodeBootstrapChallenge(try JSONSerialization.data(withJSONObject: challenge))
            challenge["serverSignature"] = AccountWireCodec.encodeBase64URL(try lowSSign(AccountTranscript.bootstrapChallenge(decoded), scalar: 2))
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json; charset=utf-8"], body: try JSONSerialization.data(withJSONObject: challenge))
        case 2:
            guard let body = request.httpBody else { throw AccountRuntimeError.transportFailure }
            let finalize = try AccountWireCodec.decodeBootstrapFinalize(body)
            guard finalize.challenge.mode == .pending, finalize.genesisCommit == nil else { throw AccountRuntimeError.untrustedResponse }
            sawPendingFinalize = true
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try activationBody(accountID: finalize.challenge.accountID, deviceID: finalize.challenge.deviceID, commit: fixtureGenesisCommitObject()))
        default: throw AccountRuntimeError.transportFailure
        }
    }
    func requestCount() -> Int { sent.count }
    func receivedPendingFinalize() -> Bool { sawPendingFinalize }
}

private actor GenesisBootstrapTransport: AccountHTTPTransport {
    private let template: Data
    private var receivedPackage = false
    init(challengeTemplate: Data) { template = challengeTemplate }
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        guard let body = request.httpBody else { throw AccountRuntimeError.transportFailure }
        if request.url?.path == "/v1/account/bootstrap/apple/begin" {
            let exchange = try AccountWireCodec.decodeExchangeRequest(body)
            let tokenDigest = Data(SHA256.hash(data: Data(exchange.appleIdentityToken.utf8)))
            let digest = Data(SHA256.hash(data: AccountTranscript.exchangeRequest(tokenDigest: tokenDigest, nonce: exchange.nonce, bundle: exchange.deviceBundle, proof: exchange.deviceProof)))
            var challenge = try JSONSerialization.jsonObject(with: template) as! [String: Any]
            challenge["exchangeRequestDigest"] = AccountWireCodec.encodeBase64URL(digest)
            challenge["publicBundle"] = ["signingKey": AccountWireCodec.encodeBase64URL(exchange.deviceBundle.signingKey), "agreementKey": AccountWireCodec.encodeBase64URL(exchange.deviceBundle.agreementKey)]
            let decoded = try AccountWireCodec.decodeBootstrapChallenge(try JSONSerialization.data(withJSONObject: challenge))
            challenge["serverSignature"] = AccountWireCodec.encodeBase64URL(try lowSSign(AccountTranscript.bootstrapChallenge(decoded), scalar: 2))
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: challenge))
        }
        let finalize = try AccountWireCodec.decodeBootstrapFinalize(body)
        guard finalize.challenge.mode == .genesis, let commit = finalize.genesisCommit, commit.keyPackages.count == 1, commit.keyPackages[0].recipientDeviceID == finalize.challenge.deviceID else { throw AccountRuntimeError.untrustedResponse }
        receivedPackage = true
        let requestObject = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try activationBody(accountID: finalize.challenge.accountID, deviceID: finalize.challenge.deviceID, commit: requestObject["genesisCommit"]!))
    }
    func receivedOneSelfPackage() -> Bool { receivedPackage }
}

private func scalar(_ lastByte: UInt8) -> Data { Data(repeating: 0, count: 31) + Data([lastByte]) }
private func fixtureGenesisCommitObject() throws -> Any { let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json"); let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]; return (((root["bootstrapFinalize"] as! [String: Any])["genesis"] as! [String: Any])["message"] as! [String: Any])["genesisCommit"]! }
private func activationBody(accountID: PlainpostAccountID, deviceID: AccountDeviceID, commit: Any) throws -> Data { let claims: [String: Any] = ["exp": NSNumber(value: Int64(2_000_000_000_000_000_000))]; let payload = AccountWireCodec.encodeBase64URL(try JSONSerialization.data(withJSONObject: claims)); return try JSONSerialization.data(withJSONObject: ["kind": "account.activation.v1", "accountID": accountID.rawValue, "deviceID": deviceID.rawValue, "accessToken": "e30.\(payload).AA", "refreshCredential": AccountWireCodec.encodeBase64URL(Data(repeating: 1, count: 32)), "offlineLease": "lease", "currentTrustCommit": commit]) }
private func lowSSign(_ transcript: Data, scalar privateScalarLastByte: UInt8) throws -> Data {
    let raw = try P256.Signing.PrivateKey(rawRepresentation: scalar(privateScalarLastByte)).signature(for: transcript).rawRepresentation
    let order = Data(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!
    let half = Data(hex: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")!
    let s = Data(raw.suffix(32))
    guard half.lexicographicallyPrecedes(s), s != half else { return raw }
    var result = Array(order); let source = Array(s); var borrow = 0
    for index in stride(from: 31, through: 0, by: -1) { let diff = Int(result[index]) - Int(source[index]) - borrow; if diff < 0 { result[index] = UInt8(diff + 256); borrow = 1 } else { result[index] = UInt8(diff); borrow = 0 } }
    return Data(raw.prefix(32)) + Data(result)
}

private extension Data {
    init?(base64URLEncoded value: String) {
        self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    init?(hex: String) { guard hex.count.isMultiple(of: 2) else { return nil }; self = Data(stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) }); guard count == hex.count / 2 else { return nil } }
}
