import CryptoKit
import Foundation

public struct NodeEndpointClaimBinding: Equatable, Sendable {
    public let nodeID, signingPublicKey, agreementPublicKey, noiseStaticPublicKey, endpointDigest: Data
    public let expiresAt: String

    public init(nodeID: Data, signingPublicKey: Data, agreementPublicKey: Data, noiseStaticPublicKey: Data, endpointDigest: Data, expiresAt: String) throws {
        guard nodeID.count == 16, signingPublicKey.count == 65, agreementPublicKey.count == 65,
              noiseStaticPublicKey.count == 32, endpointDigest.count == 32,
              NodeSessionWire.parseWholeSecondTimestamp(expiresAt) != nil
        else { throw NodeSessionError.invalidValue }
        self.nodeID = nodeID; self.signingPublicKey = signingPublicKey; self.agreementPublicKey = agreementPublicKey
        self.noiseStaticPublicKey = noiseStaticPublicKey; self.endpointDigest = endpointDigest; self.expiresAt = expiresAt
    }
}

public struct NodeEndpointURL: Equatable, Sendable {
    public let url: URL

    public init(_ canonicalValue: String) throws {
        guard let components = URLComponents(string: canonicalValue),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let host = components.host, host == host.lowercased(), Self.isMagicDNS(host),
			  let port = components.port,
              let url = components.url
        else { throw NodeSessionError.invalidValue }
        let expected = "https://\(host):\(port)"
        guard canonicalValue == expected, (1...65535).contains(port) else {
            throw NodeSessionError.invalidValue
        }
        self.url = url
    }

    private static func isMagicDNS(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, labels.suffix(2).elementsEqual(["ts", "net"]), host.utf8.count <= 253 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
        }
    }
}

public enum NodeEndpointCipher {
    /// Opens only an endpoint sealed by the Node's exact setup code and the
    /// complete public claim identity. Decrypted endpoints are revalidated
    /// before any network client can receive them.
    public static func open(ciphertext: Data, setupCode: Data, binding: NodeEndpointClaimBinding) throws -> URL {
        guard setupCode.count == 32, ciphertext.count >= 29, ciphertext.count <= 16 * 1024 else { throw NodeSessionError.invalidValue }
        let key = deriveKey(setupCode: setupCode, binding: binding)
        let nonce = Data(ciphertext.prefix(12)), encrypted = Data(ciphertext.dropFirst(12).dropLast(16)), tag = Data(ciphertext.suffix(16))
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: encrypted, tag: tag), using: key, authenticating: aad(binding))
        } catch { throw NodeSessionError.invalidValue }
        guard Data(SHA256.hash(data: plaintext)) == binding.endpointDigest,
              let value = String(data: plaintext, encoding: .utf8)
        else { throw NodeSessionError.invalidValue }
        return try NodeEndpointURL(value).url
    }

    /// Deterministic vector-only test seam. Shipping callers never select a
    /// nonce or obtain endpoint encryption material.
    public static func sealForTesting(endpoint: String, setupCode: Data, binding: NodeEndpointClaimBinding, nonce: Data) throws -> Data {
        guard setupCode.count == 32, nonce.count == 12, Data(SHA256.hash(data: Data(endpoint.utf8))) == binding.endpointDigest else { throw NodeSessionError.invalidValue }
        _ = try NodeEndpointURL(endpoint)
        do {
            let box = try AES.GCM.seal(Data(endpoint.utf8), using: deriveKey(setupCode: setupCode, binding: binding), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad(binding))
            return nonce + box.ciphertext + box.tag
        } catch { throw NodeSessionError.invalidValue }
    }

    private static func deriveKey(setupCode: Data, binding: NodeEndpointClaimBinding) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: setupCode), salt: Data(SHA256.hash(data: context(binding))), info: framed([Data("Plainpost.NodeEndpointKey.v1".utf8), u16(1)]), outputByteCount: 32)
    }
    private static func context(_ binding: NodeEndpointClaimBinding) -> Data { framed([Data("Plainpost.NodeEndpointContext.v1".utf8), u16(1), binding.nodeID, binding.signingPublicKey, binding.agreementPublicKey, binding.noiseStaticPublicKey, binding.endpointDigest, Data(binding.expiresAt.utf8)]) }
    private static func aad(_ binding: NodeEndpointClaimBinding) -> Data { framed([Data("Plainpost.NodeEndpointAAD.v1".utf8), u16(1), binding.nodeID, binding.signingPublicKey, binding.agreementPublicKey, binding.noiseStaticPublicKey, binding.endpointDigest, Data(binding.expiresAt.utf8)]) }
    private static func framed(_ values: [Data]) -> Data { values.reduce(into: Data()) { result, value in var count = UInt32(value.count).bigEndian; result += Data(bytes: &count, count: 4); result += value } }
    private static func u16(_ value: UInt16) -> Data { var value = value.bigEndian; return Data(bytes: &value, count: 2) }
}
