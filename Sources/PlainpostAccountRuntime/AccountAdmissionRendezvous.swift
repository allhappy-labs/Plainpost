import Foundation
import PlainpostAccountProtocol

public protocol AccountAdmissionRendezvous: Sendable {
    func listPending() async throws -> [AccountPendingDevice]
    func submitOffer(_ offer: TrustHandshakeOfferV1, for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1
    func fetchOffer(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1
    func submitResponse(_ response: AccountTrustAdmissionResponseEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws
    func fetchResponse(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionResponseEnvelopeV1
    func cancel(_ attempt: AccountTrustAdmissionCancelEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws
}

/// Pending-device adapter. Active-owner offer creation/response polling uses
/// the same API client methods but remains coordinator-owned so views never
/// receive canonical wire bytes or nonce material.
public actor CentralAccountAdmissionRendezvous: AccountAdmissionRendezvous {
    private let client: AccountAPIClient
    private let credentials: AccountSessionCredentials
    private let identity: AccountDeviceIdentity

    public init(client: AccountAPIClient, credentials: AccountSessionCredentials, identity: AccountDeviceIdentity) {
        self.client = client; self.credentials = credentials; self.identity = identity
    }

    public func fetchOffer(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 {
        let body = try await client.sendAccountRequest(method: "GET", path: path(pendingDeviceID, "offer"), credentials: credentials, device: identity, maximumResponseBytes: 4_096)
        return try AccountWireCodec.decodeAdmissionOfferEnvelope(body)
    }

    public func listPending() async throws -> [AccountPendingDevice] {
        let body = try await client.sendAccountRequest(method: "GET", path: "/v1/devices/pending", credentials: credentials, device: identity, maximumResponseBytes: 128 * 1024)
        return try AccountWireCodec.decodePendingDevices(body)
    }

    public func submitOffer(_ offer: TrustHandshakeOfferV1, for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 {
        let body = try AccountWireCodec.encodeAdmissionOfferEnvelope(offer)
        let returned = try await client.sendAccountRequest(method: "PUT", path: path(pendingDeviceID, "offer"), body: body, credentials: credentials, device: identity, maximumRequestBytes: 4_096, maximumResponseBytes: 4_096)
        let decoded = try AccountWireCodec.decodeAdmissionOfferEnvelope(returned)
        guard decoded.offer == offer else { throw AccountRuntimeError.untrustedResponse }
        return decoded
    }

    public func submitResponse(_ response: AccountTrustAdmissionResponseEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws {
        let body = try AccountWireCodec.encodeAdmissionResponseEnvelope(response)
        let returned = try await client.sendAccountRequest(method: "PUT", path: path(pendingDeviceID, "response"), body: body, credentials: credentials, device: identity, maximumRequestBytes: 8_192, maximumResponseBytes: 8_192)
        guard try AccountWireCodec.decodeAdmissionResponseEnvelope(returned) == response else { throw AccountRuntimeError.untrustedResponse }
    }

    public func fetchResponse(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionResponseEnvelopeV1 {
        let body = try await client.sendAccountRequest(method: "GET", path: path(pendingDeviceID, "response"), credentials: credentials, device: identity, maximumResponseBytes: 8_192)
        return try AccountWireCodec.decodeAdmissionResponseEnvelope(body)
    }

    public func cancel(_ attempt: AccountTrustAdmissionCancelEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws {
        let body = try AccountWireCodec.encodeAdmissionCancelEnvelope(attempt)
        _ = try await client.sendAccountRequest(method: "POST", path: path(pendingDeviceID, "cancel"), body: body, credentials: credentials, device: identity, maximumRequestBytes: 256, maximumResponseBytes: 256, expectedStatusCodes: [204])
    }

    private func path(_ pendingDeviceID: AccountDeviceID, _ suffix: String) -> String {
        "/v1/trust/admissions/\(pendingDeviceID.rawValue)/\(suffix)"
    }
}
