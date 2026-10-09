import Combine
import Foundation
import PlainpostAccountProtocol

/// Deep UI seam for one pending-device admission attempt. Canonical relay
/// bytes and both nonces remain inside protocol/runtime modules; views see only
/// a six-digit matching code and terminal presentation state.
@MainActor
public final class AccountAdmissionController: ObservableObject {
    public enum State: Equatable, Sendable {
        case waiting
        case matchingCode(String)
        case admitted
        case expired
        case failed
    }

    @Published public private(set) var state: State = .waiting
    private let rendezvous: any AccountAdmissionRendezvous
    private let pending: AccountActivation
    private let publicBundle: AccountPublicKeyBundle
    private let poll: @Sendable () async -> AccountSessionState
    private let random: @Sendable (Int) throws -> Data
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var attempt: AccountAdmissionAttemptLease?

    /// How long a new device waits for a trusted device's offer: Central keeps a pending
    /// device for five minutes from sign-in.
    static let offerWaitLimit: TimeInterval = 300

    public init(rendezvous: any AccountAdmissionRendezvous, pending: AccountActivation, publicBundle: AccountPublicKeyBundle, poll: @escaping @Sendable () async -> AccountSessionState, random: @escaping @Sendable (Int) throws -> Data = AccountAPIClient.secureRandom, clock: @escaping @Sendable () -> Date = Date.init, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        guard pending.mode == .pending else { throw AccountRuntimeError.untrustedResponse }
        self.rendezvous = rendezvous; self.pending = pending; self.publicBundle = publicBundle; self.poll = poll; self.random = random
        self.clock = clock; self.sleep = sleep
    }

    deinit { task?.cancel(); attempt?.cancel() }

    public func start(now: Date = Date()) {
        generation &+= 1; let expected = generation
        task?.cancel(); attempt?.cancel(); attempt = nil; state = .waiting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Right after sign-in the trusted device usually hasn't posted its offer yet
                // (Central answers that there is none). Keep asking until one arrives or the
                // pending device's window closes, rather than failing into recovery.
                let startedAt = clock()
                let offerEnvelope: AccountTrustAdmissionOfferEnvelopeV1
                while true {
                    do {
                        offerEnvelope = try await rendezvous.fetchOffer(for: pending.deviceID)
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard clock().timeIntervalSince(startedAt) < Self.offerWaitLimit else {
                            if generation == expected { state = .expired }
                            return
                        }
                        try await sleep(.seconds(2))
                        guard !Task.isCancelled, generation == expected else { return }
                    }
                }
                let offer = offerEnvelope.offer
                guard offer.accountID == pending.accountID, offer.pendingDeviceID == pending.deviceID, offer.pendingPublicBundle == publicBundle else { throw AccountRuntimeError.untrustedResponse }
                let validatedAt = now.addingTimeInterval(clock().timeIntervalSince(startedAt))
                let nowMilliseconds = UInt64(max(0, validatedAt.timeIntervalSince1970 * 1_000))
                guard offer.createdAtUnixMilliseconds.value <= nowMilliseconds, nowMilliseconds < offer.expiresAtUnixMilliseconds.value else { throw AccountRuntimeError.untrustedResponse }
                let nonce = try random(32); guard nonce.count == 32, nonce != offer.existingNonce else { throw AccountRuntimeError.cryptographicFailure }
                let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: nonce)
                let envelope = try AccountTrustAdmissionResponseEnvelopeV1(offerDigest: offerEnvelope.offerDigest, response: response)
                let cancel = try AccountTrustAdmissionCancelEnvelopeV1(offerDigest: offerEnvelope.offerDigest)
                let lease = AccountAdmissionAttemptLease { [rendezvous, pending] in
                    try? await rendezvous.cancel(cancel, for: pending.deviceID)
                }
                guard generation == expected else { lease.cancel(); return }
                attempt = lease
                try await rendezvous.submitResponse(envelope, for: pending.deviceID)
                let code = try AccountTrustAuthentication.authenticationString(for: response)
                guard !Task.isCancelled, generation == expected else { lease.cancel(); return }
                state = .matchingCode(code)
                while !Task.isCancelled, generation == expected {
                    try await sleep(.seconds(1))
                    guard clock().timeIntervalSince1970 * 1_000 < Double(offer.expiresAtUnixMilliseconds.value) else {
                        lease.cancel(); if generation == expected { attempt = nil; state = .expired }; return
                    }
                    switch await poll() {
                    case .active: lease.finish(); state = .admitted; attempt = nil; return
                    case .suspended, .cleanupRequired, .deleted, .expired, .signInRequired: lease.cancel(); attempt = nil; state = .failed; return
                    case .provisional, .offlineLease: continue
                    }
                }
            } catch is CancellationError {
                if generation == expected { attempt?.cancel(); attempt = nil }
                return
            }
            catch {
                guard generation == expected else { return }
                attempt?.cancel(); attempt = nil
                state = .failed
            }
        }
    }

    public func cancel() {
        generation &+= 1; task?.cancel(); task = nil
        let current = attempt; attempt = nil; state = .waiting
        current?.cancel()
    }
}

final class AccountAdmissionAttemptLease: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () async -> Void)?

    init(cancel: @escaping @Sendable () async -> Void) { operation = cancel }

    func cancel() {
        let action = takeOperation()
        if let action { Task { await action() } }
    }

    func finish() { _ = takeOperation() }

    private func takeOperation() -> (@Sendable () async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        let action = operation; operation = nil; return action
    }

    deinit { cancel() }
}
