import Darwin
import Foundation

/// Test-only child-process credential transport. The fixed descriptor avoids
/// placing a descriptor number or a secret in argv or the environment.
public enum InheritedCredentialCapability {
    public static let fileDescriptor: Int32 = 198

    public static func readVault(required: Bool) async throws -> InMemoryCredentialVault? {
        try await readVault(required: required, descriptor: fileDescriptor)
    }

    static func readVault(required: Bool, descriptor: Int32) async throws -> InMemoryCredentialVault? {
        guard fcntl(descriptor, F_GETFD) != -1 else {
            if required { throw CredentialVaultError.clientUnauthorized }
            return nil
        }
        defer { _ = close(descriptor) }

        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        defer {
            _ = buffer.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw CredentialVaultError.ciphertextInvalid }
            guard payload.count + count <= CredentialCapabilityCodec.maximumPayloadLength else {
                throw CredentialVaultError.ciphertextInvalid
            }
            payload.append(contentsOf: buffer.prefix(count))
        }
        defer { payload.resetBytes(in: payload.indices) }
        return InMemoryCredentialVault(records: try CredentialCapabilityCodec.decode(payload))
    }
}
