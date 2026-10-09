import Combine
import Foundation
import PlainpostAccountRuntime
import PlainpostCore

/// Retries the account session on a hidden login launch. At login Central
/// is often not reachable yet, or the login keychain is still locked, and
/// no window is open to retry. While the presentation is offline or needs
/// recovery for such a transient reason, this prepares the session again
/// when the network path becomes satisfied, the Mac wakes or the screen
/// unlocks, and otherwise on a bounded backoff (15 s doubling to 5 min).
@MainActor
public final class PlainpostSessionRetryDriver {
    public static let defaultBackoff: [Duration] = [
        .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300),
    ]
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let prepare: @MainActor () -> Void
    private let isHidden: @MainActor () -> Bool
    private let backoff: [Duration]
    private let sleep: Sleep
    private var eligible = false
    private var attempt = 0
    private var loop: Task<Void, Never>?

    public init(
        prepare: @escaping @MainActor () -> Void,
        isHidden: @escaping @MainActor () -> Bool,
        backoff: [Duration] = PlainpostSessionRetryDriver.defaultBackoff,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        precondition(!backoff.isEmpty)
        self.prepare = prepare
        self.isHidden = isHidden
        self.backoff = backoff
        self.sleep = sleep
    }

    deinit { loop?.cancel() }

    public var isRetrying: Bool { eligible }

    nonisolated public static func isEligible(
        presentation: AccountSessionViewModel.Presentation?,
        transientFailure: AccountSessionTransientFailure?
    ) -> Bool {
        guard transientFailure != nil else { return false }
        switch presentation {
        case .offlineLease, .recoveryRequired: return true
        default: return false
        }
    }

    public func update(
        presentation: AccountSessionViewModel.Presentation?,
        transientFailure: AccountSessionTransientFailure?
    ) {
        let now = Self.isEligible(presentation: presentation, transientFailure: transientFailure)
        guard now != eligible else { return }
        eligible = now
        attempt = 0
        if now {
            startLoop()
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    /// The network path became satisfied, the Mac woke or the screen
    /// unlocked: try at once and restart the backoff.
    public func conditionsMayHaveChanged() {
        guard eligible else { return }
        attempt = 0
        attemptPrepare()
        startLoop()
    }

    private func attemptPrepare() {
        // An open window prepares the session itself, and a user may be in
        // the middle of a recovery flow there.
        guard isHidden() else { return }
        prepare()
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.backoff[min(self.attempt, self.backoff.count - 1)]
                let sleep = self.sleep
                do { try await sleep(delay) } catch { return }
                guard !Task.isCancelled, self.eligible else { return }
                self.attempt += 1
                self.attemptPrepare()
            }
        }
    }
}

/// What the menu bar shows about background state.
public struct PlainpostMenuBarStatus: Equatable, Sendable {
    public static let foreignServiceMessage =
        "Another Plainpost installation is running the background service."
    public static let lockedMessage = "Unlock Plainpost to receive notifications"
    public static let offlineMessage = "Plainpost can't reach its server. It will keep retrying."
    public static let keychainMessage = "Waiting for your login keychain to unlock."

    /// Most important first.
    public let messages: [String]
    public let offersUnlock: Bool
    public let offersLock: Bool

    public init(
        vaultState: PlainpostVaultLaunchState,
        presentation: AccountSessionViewModel.Presentation?,
        transientFailure: AccountSessionTransientFailure?,
        ownership: PlainpostServiceOwnership,
        lockError: String? = nil
    ) {
        var messages: [String] = []
        if let lockError { messages.append(lockError) }
        if case .foreign = ownership { messages.append(Self.foreignServiceMessage) }
        let sessionAllowsMailbox = presentation?.allowsMailbox == true
        if vaultState == .locked, sessionAllowsMailbox { messages.append(Self.lockedMessage) }
        if PlainpostSessionRetryDriver.isEligible(presentation: presentation, transientFailure: transientFailure) {
            switch transientFailure {
            case .network: messages.append(Self.offlineMessage)
            case .credentialsUnavailable: messages.append(Self.keychainMessage)
            case nil: break
            }
        }
        self.messages = messages
        offersUnlock = vaultState == .locked && sessionAllowsMailbox
        offersLock = vaultState == .ready && sessionAllowsMailbox
    }
}

/// Keeps the account session recovering while no window is open, on every
/// launch: a hidden login launch that meets an offline Central, and a
/// manual launch whose background refresh fails after its window closed
/// (for example on wake). The app feeds it system triggers.
@MainActor
public final class PlainpostSessionRecoveryMonitor {
    private final class ModelBox {
        weak var model: AccountSessionViewModel?
    }

    public let driver: PlainpostSessionRetryDriver
    private let box = ModelBox()
    private var observation: AnyCancellable?
    private var lastPathSatisfied: Bool?

    public init(
        accountModels: AnyPublisher<AccountSessionViewModel?, Never>,
        isHidden: @escaping @MainActor () -> Bool,
        backoff: [Duration] = PlainpostSessionRetryDriver.defaultBackoff,
        sleep: @escaping PlainpostSessionRetryDriver.Sleep = { try await Task.sleep(for: $0) }
    ) {
        let box = box
        driver = PlainpostSessionRetryDriver(
            prepare: { box.model?.refreshInBackground() },
            isHidden: isHidden,
            backoff: backoff,
            sleep: sleep
        )
        observation = accountModels
            .map { model -> AnyPublisher<(AccountSessionViewModel?, AccountSessionViewModel.Presentation?, AccountSessionTransientFailure?), Never> in
                guard let model else { return Just((nil, nil, nil)).eraseToAnyPublisher() }
                return model.$presentation
                    .combineLatest(model.$transientFailure)
                    .map { [weak model] presentation, failure in (model, presentation, failure) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] model, presentation, failure in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.box.model = model
                    self.driver.update(presentation: presentation, transientFailure: failure)
                }
            }
    }

    /// Network path updates; a change to satisfied triggers a retry.
    public func networkPathChanged(satisfied: Bool) {
        defer { lastPathSatisfied = satisfied }
        if satisfied, lastPathSatisfied == false {
            driver.conditionsMayHaveChanged()
        }
    }

    /// Wake, session activation or screen unlock.
    public func conditionsMayHaveChanged() {
        driver.conditionsMayHaveChanged()
    }
}
