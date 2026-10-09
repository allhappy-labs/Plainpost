import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport

final class SyncNodeBootstrapClaimVerifierTests: XCTestCase {
    func testAcceptsLowSProofAndExactProvisionedIdentityAndOrigin() throws {
        let fixture = try BootstrapClaimFixture()

        let endpoint = try SyncNodeBootstrapClaimVerifier().verify(
            profile: fixture.profile,
            presentation: fixture.presentation,
            claim: fixture.claim,
            setupCode: fixture.setupCode
        )

        XCTAssertEqual(endpoint, fixture.profile.canonicalOrigin)
    }

    func testRejectsEveryProvisionedIdentityAndProofMismatch() throws {
        let fixture = try BootstrapClaimFixture()
        let verifier = SyncNodeBootstrapClaimVerifier()
        let wrongNode = try SyncNodeBootstrapProfile(
            canonicalOrigin: fixture.profile.canonicalOrigin,
            nodeDeviceID: AccountDeviceID("90000000-0000-4000-8000-000000000099"),
            signingKeyDigest: fixture.profile.signingKeyDigest,
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "central.test"
        )
        let wrongDigest = try SyncNodeBootstrapProfile(
            canonicalOrigin: fixture.profile.canonicalOrigin,
            nodeDeviceID: fixture.profile.nodeDeviceID,
            signingKeyDigest: Data(repeating: 9, count: 32),
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "central.test"
        )
        let wrongOrigin = try SyncNodeBootstrapProfile(
            canonicalOrigin: NodeEndpointURL("https://other.tail1234.ts.net:18443"),
            nodeDeviceID: fixture.profile.nodeDeviceID,
            signingKeyDigest: fixture.profile.signingKeyDigest,
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "central.test"
        )
        let invalidProof = try SyncNodeEnrollmentPresentation(
            setupCode: fixture.presentation.setupCode,
            expiresAt: fixture.presentation.expiresAt,
            claimProofSignature: AccountWireCodec.normalizedLowSSignature(
                P256.Signing.PrivateKey().signature(for: AccountTranscript.nodeEnrollmentClaimProof(fixture.claim)).rawRepresentation
            ),
            claimFingerprint: fixture.presentation.claimFingerprint
        )
        let wrongFingerprint = try SyncNodeEnrollmentPresentation(
            setupCode: fixture.presentation.setupCode,
            expiresAt: fixture.presentation.expiresAt,
            claimProofSignature: fixture.presentation.claimProofSignature,
            claimFingerprint: "999999"
        )

        for (profile, presentation) in [
            (wrongNode, fixture.presentation),
            (wrongDigest, fixture.presentation),
            (wrongOrigin, fixture.presentation),
            (fixture.profile, invalidProof),
            (fixture.profile, wrongFingerprint),
        ] {
            XCTAssertThrowsError(
                try verifier.verify(
                    profile: profile,
                    presentation: presentation,
                    claim: fixture.claim,
                    setupCode: fixture.setupCode
                )
            )
        }
    }
}

private struct BootstrapClaimFixture {
    let setupCode = Data(repeating: 4, count: 32)
    let profile: SyncNodeBootstrapProfile
    let presentation: SyncNodeEnrollmentPresentation
    let claim: AccountNodeEnrollmentPublicClaimV1

    init() throws {
        let origin = try NodeEndpointURL("https://node.tail1234.ts.net:18443")
        let nodeID = try AccountDeviceID("90000000-0000-4000-8000-000000000002")
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        let endpointDigest = Data(SHA256.hash(data: Data(origin.url.absoluteString.utf8)))
        let createdAt = "2099-09-06T10:00:00Z"
        let expiresAt = "2099-09-06T10:05:00Z"
        let unsigned = try AccountNodeEnrollmentPublicClaimV1(
            claimID: NodeEnrollmentClaimID("90000000-0000-4000-8000-000000000001"),
            nodeDeviceID: nodeID,
            signingPublicKey: signing.publicKey.x963Representation,
            agreementPublicKey: agreement.publicKey.x963Representation,
            noiseStaticPublicKey: Data(repeating: 5, count: 32),
            endpointDigest: endpointDigest,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        let binding = try Self.binding(unsigned)
        let ciphertext = try NodeEndpointCipher.sealForTesting(
            endpoint: origin.url.absoluteString,
            setupCode: setupCode,
            binding: binding,
            nonce: Data(repeating: 6, count: 12)
        )
        claim = try AccountNodeEnrollmentPublicClaimV1(
            claimID: unsigned.claimID,
            nodeDeviceID: unsigned.nodeDeviceID,
            signingPublicKey: unsigned.signingPublicKey,
            agreementPublicKey: unsigned.agreementPublicKey,
            noiseStaticPublicKey: unsigned.noiseStaticPublicKey,
            endpointCiphertext: ciphertext,
            endpointDigest: unsigned.endpointDigest,
            createdAt: unsigned.createdAt,
            expiresAt: unsigned.expiresAt
        )
        let transcript = AccountTranscript.nodeEnrollmentClaimProof(claim)
        let signature = try AccountWireCodec.normalizedLowSSignature(signing.signature(for: transcript).rawRepresentation)
        let digest = Data(SHA256.hash(data: transcript))
        let fingerprintValue = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        presentation = try SyncNodeEnrollmentPresentation(
            setupCode: NodeSessionWire.encodeBase64URL(setupCode),
            expiresAt: try XCTUnwrap(AccountWireCodec.parseTimestamp(expiresAt)),
            claimProofSignature: signature,
            claimFingerprint: String(format: "%06u", fingerprintValue)
        )
        profile = try SyncNodeBootstrapProfile(
            canonicalOrigin: origin,
            nodeDeviceID: nodeID,
            signingKeyDigest: Data(SHA256.hash(data: signing.publicKey.x963Representation)),
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "central.test"
        )
    }

    private static func binding(_ claim: AccountNodeEnrollmentPublicClaimV1) throws -> NodeEndpointClaimBinding {
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
}
