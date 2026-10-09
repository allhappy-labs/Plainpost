import CryptoKit
import Foundation
import PlainpostAccountProtocol

enum RootScopedManifestCache {
    static func key(prefix: String, rootKeyID: String, rootPublicKey: Data) -> AccountSecretKey {
        let identity = AccountTranscript.parts([
            Data("Plainpost.RootScopedManifestCache.v1".utf8),
            Data(rootKeyID.utf8),
            rootPublicKey,
        ])
        let suffix = SHA256.hash(data: identity).prefix(16).map { String(format: "%02x", $0) }.joined()
        return AccountSecretKey(service: "com.marynavdovenko.Plainpost.Account", account: "\(prefix).\(suffix)")
    }
}
