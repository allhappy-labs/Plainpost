import CryptoKit
import Foundation
@testable import PlainpostNodeTransport

// Vector-only deterministic material. It is deliberately test-local: Apple
// callers must not receive raw encryption keys, AAD, or caller-chosen nonce
// sealing APIs from the shipping transport module.
struct NodeEnrollmentEndpointMaterial: Equatable, Sendable {
    let context, salt, key, aad: Data
}

enum NodeEnrollmentMaterial {
    static func deriveSetupCode(setupSeed: Data, claimNonce: Data, nodeID: Data, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data, expiresAt: String) throws -> Data {
        guard setupSeed.count == 32, claimNonce.count == 32, validPublicIdentity(nodeID: nodeID, signingPublicKey: signingPublicKey, agreementPublicKey: agreementPublicKey, noiseStaticPublicKey: noiseStaticPublicKey), validWholeSecond(expiresAt) else { throw NodeSessionError.invalidValue }
        let info = framed([Data("Plainpost.SyncNodeSetupCode.v2".utf8), u16(2), nodeID, signingPublicKey, agreementPublicKey, noiseStaticPublicKey, Data(expiresAt.utf8)])
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: setupSeed), salt: claimNonce, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    static func setupVerifier(_ setupCode: Data) -> Data {
        Data(SHA256.hash(data: Data("Plainpost.SyncNodeSetupCodeVerifier.v1\0".utf8) + setupCode))
    }

    static func endpointMaterial(nodeID: Data, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data, setupCode: Data, endpoint: String, expiresAt: String) throws -> NodeEnrollmentEndpointMaterial {
        guard setupCode.count == 32, validPublicIdentity(nodeID: nodeID, signingPublicKey: signingPublicKey, agreementPublicKey: agreementPublicKey, noiseStaticPublicKey: noiseStaticPublicKey), validWholeSecond(expiresAt), validCanonicalEndpoint(endpoint) else { throw NodeSessionError.invalidValue }
        let digest = Data(SHA256.hash(data: Data(endpoint.utf8)))
        let context = framed([Data("Plainpost.NodeEndpointContext.v1".utf8), u16(1), nodeID, signingPublicKey, agreementPublicKey, noiseStaticPublicKey, digest, Data(expiresAt.utf8)])
        let salt = Data(SHA256.hash(data: context))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: setupCode), salt: salt, info: framed([Data("Plainpost.NodeEndpointKey.v1".utf8), u16(1)]), outputByteCount: 32)
        let aad = framed([Data("Plainpost.NodeEndpointAAD.v1".utf8), u16(1), nodeID, signingPublicKey, agreementPublicKey, noiseStaticPublicKey, digest, Data(expiresAt.utf8)])
        return NodeEnrollmentEndpointMaterial(context: context, salt: salt, key: key.withUnsafeBytes { Data($0) }, aad: aad)
    }

    static func sealEndpoint(endpoint: String, key: Data, aad: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 12, validCanonicalEndpoint(endpoint) else { throw NodeSessionError.invalidValue }
        let box = try AES.GCM.seal(Data(endpoint.utf8), using: SymmetricKey(data: key), nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
        return nonce + box.ciphertext + box.tag
    }

    static func claimProofTranscript(claimID: String, nodeID: Data, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data, endpointDigest: Data, createdAt: String, expiresAt: String) throws -> Data {
        guard NodeSessionWire.canonicalUUID(claimID), validPublicIdentity(nodeID: nodeID, signingPublicKey: signingPublicKey, agreementPublicKey: agreementPublicKey, noiseStaticPublicKey: noiseStaticPublicKey), endpointDigest.count == 32, validWholeSecond(createdAt), validWholeSecond(expiresAt) else { throw NodeSessionError.invalidValue }
        return framed([Data("Plainpost.SyncNodeClaimProof.v1".utf8), u16(1), try NodeSessionWire.uuid(claimID), nodeID, signingPublicKey, agreementPublicKey, noiseStaticPublicKey, endpointDigest, Data(createdAt.utf8), Data(expiresAt.utf8)])
    }

    static func displayCode(claimProofTranscript: Data) -> String {
        let digest = Data(SHA256.hash(data: claimProofTranscript))
        let value = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        return String(format: "%06u", value)
    }

    private static func validPublicIdentity(nodeID: Data, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data) -> Bool { nodeID.count == 16 && signingPublicKey.count == 65 && agreementPublicKey.count == 65 && noiseStaticPublicKey.count == 32 }
    private static func validWholeSecond(_ value: String) -> Bool { NodeSessionWire.parseWholeSecondTimestamp(value) != nil }
    private static func validCanonicalEndpoint(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.user == nil, parts.password == nil, parts.path.isEmpty, parts.query == nil, parts.fragment == nil, let host = parts.host, let port = parts.port, value == "https://\(host):\(port)", port > 0, validTailscaleFQDN(host) else { return false }
        return true
    }
    private static func validTailscaleFQDN(_ host: String) -> Bool {
        let bytes = Array(host.utf8)
        guard bytes.count <= 253, host == host.lowercased(), host.hasSuffix(".ts.net") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, labels.suffix(2).elementsEqual(["ts", "net"]) else { return false }
        return labels.allSatisfy { label in guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }; return label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 } }
    }
    private static func framed(_ values: [Data]) -> Data { values.reduce(into: Data()) { result, value in var count = UInt32(value.count).bigEndian; result += Data(bytes: &count, count: 4); result += value } }
    private static func u16(_ value: UInt16) -> Data { var item = value.bigEndian; return Data(bytes: &item, count: 2) }
}
