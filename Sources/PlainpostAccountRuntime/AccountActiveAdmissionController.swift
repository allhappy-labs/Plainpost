import Combine
import CryptoKit
import Foundation
import PlainpostAccountProtocol

/// Active-owner half of the central admission rendezvous. Discovery and relay
/// are central control-plane operations; all SAS and trust-state decisions stay
/// in the local trust coordinator.
@MainActor
public final class AccountActiveAdmissionController: ObservableObject {
    public struct PendingPrompt: Equatable, Sendable {
        public let selection: Int
        public let platform: AccountPlatform
        /// Opaque, stable identity of one pending request. Views use it only to
        /// remember a per-request dismissal; it carries no key material.
        public let requestID: String
        public init(selection: Int, platform: AccountPlatform, requestID: String) {
            self.selection = selection
            self.platform = platform
            self.requestID = requestID
        }
    }
    public struct ConfirmationPrompt: Equatable, Sendable {
        public let matchingCode: String
        public let expiresAt: Date
        public init(matchingCode: String, expiresAt: Date) {
            self.matchingCode = matchingCode
            self.expiresAt = expiresAt
        }
    }
    /// Bounded failure classes. Views get a reason they can explain without
    /// seeing transport, protocol, or trust internals.
    public enum FailureReason: Hashable, Sendable {
        /// The pending request or its offer window closed, or it can no longer
        /// be approved. Retrying the same request cannot succeed.
        case expired
        /// Central or the other device could not be reached.
        case unreachable
        case other

        public init(classifying error: any Error) {
            switch error {
            case AccountProtocolError.invalidTrustHandshake, is OfferWindowClosed: self = .expired
            case AccountRuntimeError.transportFailure, is URLError: self = .unreachable
            default: self = .other
            }
        }
    }
    public enum State: Sendable {
        case idle([PendingPrompt])
        case awaitingResponse
        case awaitingConfirmation(ConfirmationPrompt)
        case failed(FailureReason)
    }
    private struct OfferWindowClosed: Error {}
    @Published public private(set) var state: State = .idle([])
    private let rendezvous: any AccountAdmissionRendezvous
    private let coordinator: AccountTrustCoordinator
    private let client: AccountAPIClient
    private let credentials: AccountSessionCredentials
    private let identity: AccountDeviceIdentity
    private let now: @Sendable () -> Date
    private var task: Task<Void,Never>?
    private var generation: UInt64 = 0
    private var attempt: AccountAdmissionAttemptLease?
    private var pendingDevices: [AccountPendingDevice] = []
    private var approvalCapability: AccountDeviceApprovalCapability?
    private var pendingApproval: (pending: AccountPendingDevice, response: AccountTrustAdmissionResponseEnvelopeV1, context: AccountDeviceApprovalContext, lease: AccountAdmissionAttemptLease)?

    public init(rendezvous: any AccountAdmissionRendezvous, coordinator: AccountTrustCoordinator, client: AccountAPIClient, credentials: AccountSessionCredentials, identity: AccountDeviceIdentity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rendezvous=rendezvous; self.coordinator=coordinator; self.client=client; self.credentials=credentials; self.identity=identity; self.now=now
    }
    deinit { task?.cancel(); attempt?.cancel(); if let approvalCapability { Task { await approvalCapability.cancel() } } }

    public func refresh() {
        generation &+= 1; let expected=generation; task?.cancel(); attempt?.cancel(); attempt=nil; cancelApprovalCapability()
        task=Task { [weak self] in
            guard let self else{return}
            do {
                // A device that recovered keeps its keys under a new device ID, so its own
                // abandoned approval request can still be pending; it never approves itself.
                let pending=try await rendezvous.listPending().filter { $0.publicBundle != identity.publicBundle }; guard generation==expected else{return}
                pendingDevices = pending
                state = .idle(pending.enumerated().map { PendingPrompt(selection: $0.offset, platform: $0.element.platform, requestID: Self.requestID(for: $0.element)) })
            }
            catch { guard generation==expected else{return}; state = .failed(FailureReason(classifying: error)) }
        }
    }

    public func begin(_ prompt: PendingPrompt) {
        guard pendingDevices.indices.contains(prompt.selection), pendingDevices[prompt.selection].platform == prompt.platform, Self.requestID(for: pendingDevices[prompt.selection]) == prompt.requestID else { state = .failed(.expired); return }
        let pending = pendingDevices[prompt.selection]
        generation &+= 1; let expected=generation; task?.cancel(); attempt?.cancel(); attempt=nil; pendingApproval=nil; cancelApprovalCapability(); state = .awaitingResponse
        task=Task { [weak self] in
            guard let self else{return}
            do {
                let offer=try await coordinator.beginApproval(of: pending)
                let localEnvelope = try AccountWireCodec.decodeAdmissionOfferEnvelope(AccountWireCodec.encodeAdmissionOfferEnvelope(offer))
                let cancel=try AccountTrustAdmissionCancelEnvelopeV1(offerDigest: localEnvelope.offerDigest)
                let lease = AccountAdmissionAttemptLease { [rendezvous] in
                    try? await rendezvous.cancel(cancel, for: pending.deviceID)
                }
                guard generation == expected else { lease.cancel(); return }
                attempt = lease
                let offerExpiry = Date(timeIntervalSince1970: TimeInterval(offer.expiresAtUnixMilliseconds.value)/1000)
                let offerEnvelope=try await rendezvous.submitOffer(offer, for: pending.deviceID)
                guard offerEnvelope == localEnvelope else { throw AccountRuntimeError.untrustedResponse }
                while !Task.isCancelled, generation==expected {
                    do {
                        let responseEnvelope=try await rendezvous.fetchResponse(for: pending.deviceID)
                        guard responseEnvelope.offerDigest==offerEnvelope.offerDigest, responseEnvelope.response.offer==offer else { throw AccountRuntimeError.untrustedResponse }
                        let matching=try await coordinator.authenticationString(for: responseEnvelope.response)
                        let responseWire=try AccountWireCodec.encodeAdmissionResponseEnvelope(responseEnvelope)
                        let context=try AccountDeviceApprovalContext(pendingID: pending.deviceID.rawValue, offerDigest: offerEnvelope.offerDigest, responseDigest: Data(SHA256.hash(data: responseWire)), generation: expected, matchingCode: matching, expiresAt: Date(timeIntervalSince1970: TimeInterval(offer.expiresAtUnixMilliseconds.value)/1000))
                        guard generation==expected else { lease.cancel(); return }
                        pendingApproval = (pending, responseEnvelope, context, lease)
                        state = .awaitingConfirmation(ConfirmationPrompt(matchingCode: matching, expiresAt: context.expiresAt)); return
                    } catch {
                        // The other device can only answer inside the offer
                        // window; stop waiting once it closes.
                        guard now() < offerExpiry else { throw OfferWindowClosed() }
                        try await Task.sleep(for:.milliseconds(500))
                    }
                }
            } catch {
                guard generation==expected else{return}
                attempt?.cancel(); attempt=nil; cancelApprovalCapability(); state = .failed(FailureReason(classifying: error))
            }
        }
    }

    public func currentApprovalCapability() -> AccountDeviceApprovalCapability? { approvalCapability }

    /// Recent Apple authorization is kept method-local and converted into a
    /// one-time, exact add-device authorization before biometric approval.
    public func authorizeCurrentApproval(identityToken: String, appleNonce: Data) async throws -> AccountDeviceApprovalCapability {
        guard let pendingApproval, appleNonce.count == 32, !identityToken.isEmpty else { throw AccountRuntimeError.untrustedResponse }
        let expected = generation
        let context = pendingApproval.context
        guard Date() < context.expiresAt, let head = try await coordinator.currentTrustCommit() else { throw AccountRuntimeError.untrustedResponse }
        let authorization = try await client.issueStepUp(action: .addDevice, targetDeviceID: pendingApproval.pending.deviceID, currentCommitDigest: AccountTranscript.trustCommitDigest(head), identityToken: identityToken, appleNonce: appleNonce, credentials: credentials, device: identity)
        guard generation == expected, self.pendingApproval?.context == context else { throw AccountRuntimeError.cancelled }
        let responseEnvelope = pendingApproval.response
        let lease = pendingApproval.lease
        let capability = AccountDeviceApprovalCapability(context: context, approve: { [weak self, coordinator, client, credentials, identity] in
            do {
                guard let self, await self.isCurrentApproval(generation: expected, context: context) else { throw AccountRuntimeError.cancelled }
                let candidate = try await coordinator.makeAdmissionCandidate(responseEnvelope.response, authenticationConfirmed: true)
                guard case .admission = candidate.evidence else { throw AccountRuntimeError.untrustedResponse }
                guard await self.isCurrentApproval(generation: expected, context: context) else { throw AccountRuntimeError.cancelled }
                let accepted = try await client.submitLifecycle(authorization: authorization, candidate: candidate, credentials: credentials, device: identity)
                guard accepted == candidate, await self.isCurrentApproval(generation: expected, context: context) else { throw AccountRuntimeError.untrustedResponse }
                try await coordinator.acceptHistory([accepted])
                lease.finish()
            } catch {
                lease.cancel()
                throw error
            }
        }, cancel: { [coordinator] in
            _ = try? await coordinator.approve(responseEnvelope.response, authenticationConfirmed: false)
            lease.cancel()
        })
        approvalCapability = capability
        return capability
    }

    public func cancel() { generation &+= 1; task?.cancel(); task=nil; attempt?.cancel(); attempt=nil; pendingApproval=nil; cancelApprovalCapability(); pendingDevices=[]; state = .idle([]) }

    private static func requestID(for pending: AccountPendingDevice) -> String {
        AccountWireCodec.encodeBase64URL(pending.exchangeRequestDigest)
    }

    private func cancelApprovalCapability() {
        guard let capability = approvalCapability else { return }
        approvalCapability = nil
        Task { await capability.cancel() }
    }

    private func isCurrentApproval(generation expected: UInt64, context: AccountDeviceApprovalContext) -> Bool {
        generation == expected && approvalCapability?.context == context
    }
}
