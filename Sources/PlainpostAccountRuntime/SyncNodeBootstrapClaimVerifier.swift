import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

public protocol SyncNodeBootstrapClaimVerifying: Sendable {
    func verify(
        profile: SyncNodeBootstrapProfile,
        presentation: SyncNodeEnrollmentPresentation,
        claim: AccountNodeEnrollmentPublicClaimV1,
        setupCode: Data
    ) throws -> NodeEndpointURL
}

/// Intersects the protected Node presentation, Central's public claim, and
/// the locally provisioned installation pins before any account approval.
public struct SyncNodeBootstrapClaimVerifier: SyncNodeBootstrapClaimVerifying {
    public init() {}

    public func verify(
        profile: SyncNodeBootstrapProfile,
        presentation: SyncNodeEnrollmentPresentation,
        claim: AccountNodeEnrollmentPublicClaimV1,
        setupCode: Data
    ) throws -> NodeEndpointURL {
        do {
            let presentedSetupCode = try NodeSessionWire.decodeBase64URL(presentation.setupCode)
            let transcript = AccountTranscript.nodeEnrollmentClaimProof(claim)
            let transcriptDigest = Data(SHA256.hash(data: transcript))
            let fingerprintValue = transcriptDigest.prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            } % 1_000_000
            let signingDigest = Data(SHA256.hash(data: claim.signingPublicKey))
            guard setupCode == presentedSetupCode,
                  claim.nodeDeviceID == profile.nodeDeviceID,
                  signingDigest == profile.signingKeyDigest,
                  AccountWireCodec.parseTimestamp(claim.expiresAt) == presentation.expiresAt,
                  presentation.claimFingerprint == String(format: "%06u", fingerprintValue),
                  let ciphertext = claim.endpointCiphertext
            else { throw AccountRuntimeError.untrustedResponse }

            try AccountWireCodec.validateLowSSignature(presentation.claimProofSignature)
            let publicKey = try P256.Signing.PublicKey(x963Representation: claim.signingPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: presentation.claimProofSignature)
            guard publicKey.isValidSignature(signature, for: transcript) else {
                throw AccountRuntimeError.untrustedResponse
            }

            let endpoint = try NodeEndpointCipher.open(
                ciphertext: ciphertext,
                setupCode: setupCode,
                binding: try syncNodeEnrollmentClaimBinding(claim)
            )
            let canonicalEndpoint = try NodeEndpointURL(endpoint.absoluteString)
            guard canonicalEndpoint == profile.canonicalOrigin else {
                throw AccountRuntimeError.untrustedResponse
            }
            return canonicalEndpoint
        } catch let error as AccountRuntimeError {
            throw error
        } catch {
            throw AccountRuntimeError.untrustedResponse
        }
    }
}

func syncNodeEnrollmentClaimBinding(
    _ claim: AccountNodeEnrollmentPublicClaimV1
) throws -> NodeEndpointClaimBinding {
    guard let uuid = UUID(uuidString: claim.nodeDeviceID.rawValue) else {
        throw AccountRuntimeError.untrustedResponse
    }
    var raw = uuid.uuid
    return try NodeEndpointClaimBinding(
        nodeID: withUnsafeBytes(of: &raw) { Data($0) },
        signingPublicKey: claim.signingPublicKey,
        agreementPublicKey: claim.agreementPublicKey,
        noiseStaticPublicKey: claim.noiseStaticPublicKey,
        endpointDigest: claim.endpointDigest,
        expiresAt: claim.expiresAt
    )
}
