import CryptoKit
import Foundation
import XCTest
@testable import PlainpostNodeTransport

final class NodeSessionVectorTests: XCTestCase {
    // This catches transcript field reordering or a platform-specific integer
    // encoding before a request can be signed on a client.
    func testSessionV1VectorMatchesGo() throws {
        let fixture = try NodeSessionFixture.load()
        XCTAssertEqual(try NodeSessionTranscript.endpoint(fixture.endpoint), fixture.endpointTranscript)
        XCTAssertEqual(try NodeSessionTranscript.activationV2(fixture.activation), fixture.activationTranscript)
        XCTAssertEqual(try NodeSessionTranscript.request(fixture.request), fixture.requestTranscript)
        XCTAssertEqual(Data(SHA256.hash(data: fixture.requestTranscript)), fixture.requestDigest)
        XCTAssertEqual(Data(SHA256.hash(data: fixture.requestBody)), fixture.request.bodySHA256)
    }

    func testSessionV1RejectsOutOfContractValues() throws {
        let fixture = try NodeSessionFixture.load()
        XCTAssertThrowsError(try SignedRequestV1(accountID: fixture.request.accountID, clientID: fixture.request.clientID, nodeID: fixture.request.nodeID, trustEpoch: fixture.request.trustEpoch, audience: fixture.request.audience, sequence: 0, method: fixture.request.method, path: fixture.request.path, bodySHA256: fixture.request.bodySHA256, issuedAt: fixture.request.issuedAt, signature: fixture.request.signature))
        XCTAssertEqual(NodeSessionLimits.maximumRequestBodyBytes, 1_048_576)
    }

    func testSessionV1RequestTranscriptExcludesEnvelopeSignature() throws {
        let fixture = try NodeSessionFixture.load()
        var signature = fixture.request.signature
        signature[signature.startIndex] ^= 0xff
        let altered = try SignedRequestV1(accountID: fixture.request.accountID, clientID: fixture.request.clientID, nodeID: fixture.request.nodeID, trustEpoch: fixture.request.trustEpoch, audience: fixture.request.audience, sequence: fixture.request.sequence, method: fixture.request.method, path: fixture.request.path, bodySHA256: fixture.request.bodySHA256, issuedAt: fixture.request.issuedAt, signature: signature)
        XCTAssertEqual(try NodeSessionTranscript.request(fixture.request), try NodeSessionTranscript.request(altered))
    }

    func testSessionV1AcceptanceCorpus() throws {
        let fixture = try NodeSessionFixture.load(), corpus = try acceptanceCorpus()
        for item in try XCTUnwrap(corpus["requestCases"] as? [[String: Any]]) {
            let field: String = try fixtureValue(item, "field"), raw: String = try fixtureValue(item, "value"), accepted: Bool = try fixtureValue(item, "accepted")
            let name: String = try fixtureValue(item, "name")
            var accountID = fixture.request.accountID, sequence = fixture.request.sequence, method = fixture.request.method, audience = fixture.request.audience, path = fixture.request.path, issuedAt = fixture.request.issuedAt
            switch field { case "accountID": accountID = raw; case "sequence": sequence = UInt64(raw) ?? 0; case "method": method = raw; case "audience": audience = raw; case "path": path = raw; case "issuedAt": issuedAt = raw; default: XCTFail("unknown field \(field)"); continue }
            let outcome = Result { try SignedRequestV1(accountID: accountID, clientID: fixture.request.clientID, nodeID: fixture.request.nodeID, trustEpoch: fixture.request.trustEpoch, audience: audience, sequence: sequence, method: method, path: path, bodySHA256: fixture.request.bodySHA256, issuedAt: issuedAt, signature: fixture.request.signature) }
            XCTAssertEqual(didSucceed(outcome), accepted, name)
        }
        for item in try XCTUnwrap(corpus["endpointCases"] as? [[String: Any]]) {
            let raw: String = try fixtureValue(item, "ciphertext"), accepted: Bool = try fixtureValue(item, "accepted")
            let name: String = try fixtureValue(item, "name")
            let outcome = Result { try EndpointEnvelopeV1(ciphertext: NodeSessionWire.decodeBase64URL(raw)) }
            XCTAssertEqual(didSucceed(outcome), accepted, name)
        }
        for item in try XCTUnwrap(corpus["bodyCases"] as? [[String: Any]]) {
            let unit: String = try fixtureValue(item, "unit"), repeatCount: Int = try fixtureValue(item, "repeat"), accepted: Bool = try fixtureValue(item, "accepted")
            let name: String = try fixtureValue(item, "name")
            XCTAssertEqual(didSucceed(Result { try NodeSessionWire.validateRequestBody(Data(String(repeating: unit, count: repeatCount).utf8)) }), accepted, name)
        }
    }

    func testEnrollmentMaterialVectorMatchesGo() throws {
        let vector = try EnrollmentMaterialFixture.load()
        let setupCode = try NodeEnrollmentMaterial.deriveSetupCode(setupSeed: vector.setupSeed, claimNonce: vector.claimNonce, nodeID: vector.nodeID, signingPublicKey: vector.signingPublicKey, agreementPublicKey: vector.agreementPublicKey, noiseStaticPublicKey: vector.noiseStaticPublicKey, expiresAt: vector.expiresAt)
        XCTAssertEqual(setupCode, vector.setupCode)
        XCTAssertEqual(NodeEnrollmentMaterial.setupVerifier(setupCode), vector.setupVerifier)
        let material = try NodeEnrollmentMaterial.endpointMaterial(nodeID: vector.nodeID, signingPublicKey: vector.signingPublicKey, agreementPublicKey: vector.agreementPublicKey, noiseStaticPublicKey: vector.noiseStaticPublicKey, setupCode: setupCode, endpoint: vector.endpoint, expiresAt: vector.expiresAt)
        XCTAssertEqual(material.context, vector.endpointContext)
        XCTAssertEqual(material.salt, vector.endpointSalt)
        XCTAssertEqual(material.key, vector.endpointKey)
        XCTAssertEqual(material.aad, vector.endpointAAD)
        XCTAssertEqual(try NodeEnrollmentMaterial.sealEndpoint(endpoint: vector.endpoint, key: material.key, aad: material.aad, nonce: vector.endpointNonce), vector.endpointCiphertext)
        let claim = try NodeEnrollmentMaterial.claimProofTranscript(claimID: vector.claimID, nodeID: vector.nodeID, signingPublicKey: vector.signingPublicKey, agreementPublicKey: vector.agreementPublicKey, noiseStaticPublicKey: vector.noiseStaticPublicKey, endpointDigest: vector.endpointDigest, createdAt: vector.claimCreatedAt, expiresAt: vector.expiresAt)
        XCTAssertEqual(NodeEnrollmentMaterial.displayCode(claimProofTranscript: claim), vector.displayCode)
        let fixture = try NodeSessionFixture.load()
        for (name, expected) in vector.activationSubstitutionTranscripts {
            var value = fixture.activation
            switch name {
            case "result": value = try ActivationRequestV2(resultWire: Data([fixture.activation.resultWire[0] ^ 1]) + fixture.activation.resultWire.dropFirst(), refreshWire: fixture.activation.refreshWire, leaseWire: fixture.activation.leaseWire, trustCommitWire: fixture.activation.trustCommitWire, admissionEvidenceWire: fixture.activation.admissionEvidenceWire, claimProofSignature: fixture.activation.claimProofSignature)
            case "refresh": value = try ActivationRequestV2(resultWire: fixture.activation.resultWire, refreshWire: Data([fixture.activation.refreshWire[0] ^ 1]) + fixture.activation.refreshWire.dropFirst(), leaseWire: fixture.activation.leaseWire, trustCommitWire: fixture.activation.trustCommitWire, admissionEvidenceWire: fixture.activation.admissionEvidenceWire, claimProofSignature: fixture.activation.claimProofSignature)
            case "lease": value = try ActivationRequestV2(resultWire: fixture.activation.resultWire, refreshWire: fixture.activation.refreshWire, leaseWire: Data([fixture.activation.leaseWire[0] ^ 1]) + fixture.activation.leaseWire.dropFirst(), trustCommitWire: fixture.activation.trustCommitWire, admissionEvidenceWire: fixture.activation.admissionEvidenceWire, claimProofSignature: fixture.activation.claimProofSignature)
            case "trust": value = try ActivationRequestV2(resultWire: fixture.activation.resultWire, refreshWire: fixture.activation.refreshWire, leaseWire: fixture.activation.leaseWire, trustCommitWire: Data([fixture.activation.trustCommitWire[0] ^ 1]) + fixture.activation.trustCommitWire.dropFirst(), admissionEvidenceWire: fixture.activation.admissionEvidenceWire, claimProofSignature: fixture.activation.claimProofSignature)
            case "evidence": value = try ActivationRequestV2(resultWire: fixture.activation.resultWire, refreshWire: fixture.activation.refreshWire, leaseWire: fixture.activation.leaseWire, trustCommitWire: fixture.activation.trustCommitWire, admissionEvidenceWire: Data([fixture.activation.admissionEvidenceWire[0] ^ 1]) + fixture.activation.admissionEvidenceWire.dropFirst(), claimProofSignature: fixture.activation.claimProofSignature)
            case "proof": value = try ActivationRequestV2(resultWire: fixture.activation.resultWire, refreshWire: fixture.activation.refreshWire, leaseWire: fixture.activation.leaseWire, trustCommitWire: fixture.activation.trustCommitWire, admissionEvidenceWire: fixture.activation.admissionEvidenceWire, claimProofSignature: Data([fixture.activation.claimProofSignature[0] ^ 1]) + fixture.activation.claimProofSignature.dropFirst())
            default: XCTFail("unknown activation field \(name)"); continue
            }
            XCTAssertEqual(try NodeSessionTranscript.activationV2(value), expected, name)
        }
    }

    func testActivationV2ExactFieldAndAggregateLimits() throws {
        let maximum = Data(repeating: 1, count: 64 * 1024)
        XCTAssertNoThrow(try ActivationRequestV2(resultWire: maximum, refreshWire: Data([1]), leaseWire: Data([1]), trustCommitWire: Data([1]), admissionEvidenceWire: Data([1]), claimProofSignature: Data(repeating: 1, count: 64)))
        XCTAssertThrowsError(try ActivationRequestV2(resultWire: Data(repeating: 1, count: 64 * 1024 + 1), refreshWire: Data([1]), leaseWire: Data([1]), trustCommitWire: Data([1]), admissionEvidenceWire: Data([1]), claimProofSignature: Data(repeating: 1, count: 64)))
        XCTAssertThrowsError(try ActivationRequestV2(resultWire: maximum, refreshWire: maximum, leaseWire: Data([1]), trustCommitWire: Data([1]), admissionEvidenceWire: Data([1]), claimProofSignature: Data(repeating: 1, count: 64)))
    }
}

private func acceptanceCorpus() throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-session-v1/fixtures/acceptance-v1.json")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as? [String: Any])
}

private func fixtureValue<T>(_ object: [String: Any], _ key: String) throws -> T { guard let result = object[key] as? T else { throw AcceptanceError.invalid }; return result }
private func didSucceed<Success>(_ result: Result<Success, Error>) -> Bool { if case .success = result { return true }; return false }
private enum AcceptanceError: Error { case invalid }

private struct EnrollmentMaterialFixture {
    let setupSeed, claimNonce, nodeID, signingPublicKey, agreementPublicKey, noiseStaticPublicKey, endpointNonce, setupCode, setupVerifier, endpointDigest, endpointContext, endpointSalt, endpointKey, endpointAAD, endpointCiphertext: Data
    let expiresAt, endpoint, claimID, claimCreatedAt, displayCode: String
    let activationSubstitutionTranscripts: [String: Data]
    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-session-v1/fixtures/enrollment-material-v1.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as? [String: Any])
        guard object["kind"] as? String == "node.enrollment-material.v1", let substitutions = object["activationSubstitutionTranscripts"] as? [String: String], Set(substitutions.keys) == Set(["result", "refresh", "lease", "trust", "evidence", "proof"]) else { throw FixtureError.invalid }
        func text(_ key: String) throws -> String { try XCTUnwrap(object[key] as? String) }
        func data(_ key: String) throws -> Data { try NodeSessionWire.decodeBase64URL(text(key)) }
        var mapped: [String: Data] = [:]
        for (name, value) in substitutions { mapped[name] = try NodeSessionWire.decodeBase64URL(value) }
        return try Self(setupSeed: data("setupSeed"), claimNonce: data("claimNonce"), nodeID: NodeSessionWire.uuid(text("nodeID")), signingPublicKey: data("signingPublicKey"), agreementPublicKey: data("agreementPublicKey"), noiseStaticPublicKey: data("noiseStaticPublicKey"), endpointNonce: data("endpointNonce"), setupCode: data("setupCode"), setupVerifier: data("setupVerifier"), endpointDigest: data("endpointDigest"), endpointContext: data("endpointContext"), endpointSalt: data("endpointSalt"), endpointKey: data("endpointKey"), endpointAAD: data("endpointAAD"), endpointCiphertext: data("endpointCiphertext"), expiresAt: text("expiresAt"), endpoint: text("endpoint"), claimID: text("claimID"), claimCreatedAt: text("claimCreatedAt"), displayCode: text("displayCode"), activationSubstitutionTranscripts: mapped)
    }
    private enum FixtureError: Error { case invalid }
}

private struct NodeSessionFixture {
    let endpoint: EndpointEnvelopeV1
    let activation: ActivationRequestV2
    let request: SignedRequestV1
    let requestBody: Data
    let endpointTranscript, activationTranscript, requestTranscript, requestDigest: Data

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-session-v1/fixtures/session-v1.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as? [String: Any])
        try exact(object, ["kind", "schemaVersion", "endpoint", "activation", "request", "requestBodyUTF8", "requestBodyLimit", "endpointTranscript", "activationTranscript", "requestTranscript", "requestDigest"])
        guard object["kind"] as? String == "node-session-v1.fixture", object["schemaVersion"] as? Int == 1, object["requestBodyLimit"] as? Int == NodeSessionLimits.maximumRequestBodyBytes else { throw FixtureError.invalid }
        let endpointObject = try XCTUnwrap(object["endpoint"] as? [String: Any]); try exact(endpointObject, ["kind", "ciphertext"])
        let activationObject = try XCTUnwrap(object["activation"] as? [String: Any]); try exact(activationObject, ["kind", "resultWire", "refreshWire", "leaseWire", "trustCommitWire", "admissionEvidenceWire", "claimProofSignature"])
        let requestObject = try XCTUnwrap(object["request"] as? [String: Any]); try exact(requestObject, ["kind", "accountID", "clientID", "nodeID", "trustEpoch", "audience", "sequence", "method", "path", "bodySHA256", "issuedAt", "signature"])
        let requestBody = Data((try value(object, "requestBodyUTF8") as String).utf8)
        guard requestBody.count <= NodeSessionLimits.maximumRequestBodyBytes else { throw FixtureError.invalid }
        guard try value(activationObject, "kind") as String == "node.activation.v2" else { throw FixtureError.invalid }
        return try Self(endpoint: EndpointEnvelopeV1(ciphertext: decode(endpointObject, "ciphertext")), activation: ActivationRequestV2(resultWire: decode(activationObject, "resultWire"), refreshWire: decode(activationObject, "refreshWire"), leaseWire: decode(activationObject, "leaseWire"), trustCommitWire: decode(activationObject, "trustCommitWire"), admissionEvidenceWire: decode(activationObject, "admissionEvidenceWire"), claimProofSignature: decode(activationObject, "claimProofSignature")), request: SignedRequestV1(accountID: try value(requestObject, "accountID"), clientID: try value(requestObject, "clientID"), nodeID: try value(requestObject, "nodeID"), trustEpoch: try positive(requestObject, "trustEpoch"), audience: try value(requestObject, "audience"), sequence: try positive(requestObject, "sequence"), method: try value(requestObject, "method"), path: try value(requestObject, "path"), bodySHA256: decode(requestObject, "bodySHA256"), issuedAt: try value(requestObject, "issuedAt"), signature: decode(requestObject, "signature")), requestBody: requestBody, endpointTranscript: decode(object, "endpointTranscript"), activationTranscript: decode(object, "activationTranscript"), requestTranscript: decode(object, "requestTranscript"), requestDigest: decode(object, "requestDigest"))
    }
    private static func exact(_ value: [String: Any], _ wanted: [String]) throws { guard Set(value.keys) == Set(wanted) else { throw FixtureError.invalid } }
    private static func value<T>(_ value: [String: Any], _ key: String) throws -> T { guard let result = value[key] as? T else { throw FixtureError.invalid }; return result }
    private static func positive(_ value: [String: Any], _ key: String) throws -> UInt64 { guard let raw: String = try self.value(value, key), let result = UInt64(raw), result > 0, String(result) == raw else { throw FixtureError.invalid }; return result }
    private static func decode(_ value: [String: Any], _ key: String) -> Data { try! NodeSessionWire.decodeBase64URL(try! self.value(value, key) as String) }
    private enum FixtureError: Error { case invalid }
}
