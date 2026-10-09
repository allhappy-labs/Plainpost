import Combine
import Foundation

/// Runs the app runtime, and with it new-mail notification delivery, while
/// the account session allows the mailbox, whether or not a window is open.
/// The mailbox window only renders the runtime; closing it no longer shuts
/// the runtime down, and a hidden login launch starts it with no window.
///
/// Vault ruling (user, binding): the vault stays unlocked for the whole
/// login session. It locks only on sign-out or session end (the account
/// leaving `.active`/`.offlineLease`, which stops the runtime here), on an
/// explicit Lock Vault, or when the service terminates. It never locks on
/// window close, sleep or screen lock.
@MainActor
public final class PlainpostRuntimeLifetime {
    public enum Demand: Equatable, Sendable {
        case stopped
        case running(readOnly: Bool)
    }

    public static func demand(for presentation: AccountSessionViewModel.Presentation?) -> Demand {
        switch presentation {
        case .active: .running(readOnly: false)
        case .offlineLease: .running(readOnly: true)
        case .none, .signInRequired, .pendingApproval, .suspended, .cleanupRequired, .deleted,
             .recoveryRequired:
            .stopped
        }
    }

    private let start: @MainActor (Bool) -> Void
    private let stop: @MainActor () async -> Void
    private var requested: Demand = .stopped
    private var applied: Demand = .stopped
    private var tail: Task<Void, Never>?
    private var observation: AnyCancellable?

    public init(
        start: @escaping @MainActor (_ readOnly: Bool) -> Void,
        stop: @escaping @MainActor () async -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    public convenience init(applicationModel: PlainpostApplicationModel) {
        self.init(
            start: { [weak applicationModel] readOnly in applicationModel?.start(readOnly: readOnly) },
            stop: { [weak applicationModel] in await applicationModel?.shutdown() }
        )
    }

    /// `presentations` must publish on the main actor, as the account
    /// models' `@Published` properties do.
    public func observe(_ presentations: AnyPublisher<AccountSessionViewModel.Presentation?, Never>) {
        observation = presentations
            .sink { [weak self] presentation in
                MainActor.assumeIsolated { self?.apply(presentation) }
            }
    }

    /// Transitions run one at a time: `PlainpostApplicationModel` ignores a
    /// start issued while its shutdown is still running.
    public func apply(_ presentation: AccountSessionViewModel.Presentation?) {
        let demand = Self.demand(for: presentation)
        guard demand != requested else { return }
        requested = demand
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.requested == demand, self.applied != demand else { return }
            switch demand {
            case .stopped:
                await self.stop()
            case .running(let readOnly):
                self.start(readOnly)
            }
            self.applied = demand
        }
    }

    /// Returns once every requested transition has run (test seam).
    public func waitUntilIdle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }
}
